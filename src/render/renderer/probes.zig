//! Reflection probes and their capture. Internal to the renderer.
const pipelines_module = @import("pipelines.zig");
const environment_push = @import("../shaders/push/environment.zig");
const std = @import("std");
const handle = @import("../../handle.zig");
const rhi = @import("../../rhi/rhi.zig");
const math = @import("../../math.zig");
const api = @import("../api.zig");
const renderer_state = @import("../state.zig");
const render = @import("../renderer.zig");

const Renderer = render.Renderer;
const Vec3 = math.Vec3;
const Scene = api.Scene;
const ReflectionProbe = api.ReflectionProbe;
const ReflectionProbeDesc = api.ReflectionProbeDesc;
const max_reflection_probes = api.max_reflection_probes;
const FrameArena = renderer_state.FrameArena;
const ProbeData = renderer_state.ProbeData;
const ensureEnvironmentTextures = @import("environments.zig").ensureEnvironmentTextures;
const filterEnvironment = @import("environments.zig").filterEnvironment;
const freeEnvironment = @import("environments.zig").freeEnvironment;
const insertView = @import("views.zig").insertView;
const renderView = @import("view_render.zig").renderView;

/// Local reflection probes.
pub const Probes = struct {
    internal: Internal,

    /// Not part of the API.
    pub const Internal = struct {
        table: handle.HandleTable(renderer_state.ProbeData, api.ReflectionProbeTag),

        /// Frees what one of them holds, as when the renderer is destroyed.
        pub fn free(owner: *Renderer, entry: *renderer_state.ProbeData) void {
            freeProbe(owner, entry);
        }
    };

    fn renderer(probes: *Probes) *Renderer {
        return @alignCast(@fieldParentPtr("reflection_probes", probes));
    }

    /// Adds a local reflection probe. Its six faces are captured one per
    /// frame from the next frames that draw; call `probes.recapture`
    /// after the scene or its lighting changes.
    pub fn create(probes: *Probes, scene: Scene, desc: ReflectionProbeDesc) !ReflectionProbe {
        const self = probes.renderer();
        self.lock();
        defer self.unlock();
        const data = self.scenes.internal.table.get(scene) orelse return error.InvalidScene;
        if (data.probes.items.len >= max_reflection_probes) return error.TooManyReflectionProbes;
        const size = std.math.clamp(desc.resolution, 16, 1024);
        const target = try self.device.createTexture(.{
            .name = "reflection probe view",
            .width = size,
            .height = size,
            .format = .rgba8_srgb,
            .usage = .{ .sampled = true, .color_attachment = true },
        });
        errdefer self.device.destroyTexture(target);
        const view = try insertView(self);
        errdefer if (self.views.internal.table.remove(view)) |removed_view| {
            var removed = removed_view;
            removed.deinit(self.device);
        };
        const probe = try self.reflection_probes.internal.table.insert(.{ .scene = scene, .desc = desc, .target = target, .view = view, .cubes = .{ .max_radiance = desc.max_radiance } });
        errdefer _ = self.reflection_probes.internal.table.remove(probe);
        try data.probes.append(self.internal.gpa, probe);
        return probe;
    }

    /// A new position takes effect with the next `probes.recapture`.
    pub fn set(probes: *Probes, probe: ReflectionProbe, desc: ReflectionProbeDesc) void {
        const self = probes.renderer();
        self.lock();
        defer self.unlock();
        const data = self.reflection_probes.internal.table.get(probe) orelse return;
        const resolution = data.desc.resolution;
        data.desc = desc;
        data.desc.resolution = resolution;
        data.cubes.max_radiance = desc.max_radiance;
    }

    /// Asks for a probe to be captured again.
    pub fn recapture(probes: *Probes, probe: ReflectionProbe) void {
        const self = probes.renderer();
        self.lock();
        defer self.unlock();
        if (self.reflection_probes.internal.table.get(probe)) |data| data.dirty = true;
    }

    /// A stale handle is ignored.
    pub fn destroy(probes: *Probes, probe: ReflectionProbe) void {
        const self = probes.renderer();
        self.lock();
        defer self.unlock();
        render.destroyObject(self, "reflection_probes", "probes", probe);
    }
};

pub fn freeProbe(self: *Renderer, probe: *ProbeData) void {
    freeEnvironment(self, &probe.cubes);
    self.device.destroyTexture(probe.target);
    if (self.views.internal.table.remove(probe.view)) |removed_view| {
        var removed = removed_view;
        removed.deinit(self.internal.gpa, self.device);
    }
}

/// Captures the first waiting probe, one face per frame, and filters the
/// result into its reflection cube.
pub fn captureProbes(self: *Renderer, frame: rhi.Frame, delta_time: f32, arena: *FrameArena) !void {
    for (self.reflection_probes.internal.table.slots.items) |*slot| if (slot.value) |*probe| {
        if (!probe.dirty and probe.face == 0) continue;
        if (!probe.captured and probe.face == 0 and probe.waited < probe.desc.settle_frames) {
            probe.waited += 1;
            continue;
        }
        const scene = self.scenes.internal.table.get(probe.scene) orelse continue;
        if (scene.layout.items.len == 0 and scene.static_count == 0) continue;
        if (probe.face == 0) probe.dirty = false;
        probe.capturing = true;
        defer probe.capturing = false;
        const cmd = frame.cmd;
        const device = self.device;
        try ensureEnvironmentTextures(self, &probe.cubes);
        const faces = [6][2]Vec3{
            .{ .{ 1, 0, 0 }, .{ 0, 1, 0 } },  .{ .{ -1, 0, 0 }, .{ 0, 1, 0 } },
            .{ .{ 0, 1, 0 }, .{ 0, 0, -1 } }, .{ .{ 0, -1, 0 }, .{ 0, 0, 1 } },
            .{ .{ 0, 0, 1 }, .{ 0, 1, 0 } },  .{ .{ 0, 0, -1 }, .{ 0, 1, 0 } },
        };
        {
            const face = probe.face;
            const axes = faces[face];
            try renderView(self, frame, .{
                .view = probe.view,
                .scene = probe.scene,
                .camera = .{ .position = probe.desc.position, .forward = axes[0], .up = axes[1], .fov_y = std.math.pi * 0.5, .near = 0.05 },
                .target = .{ .texture = probe.target },
                .settings = .{
                    .resolution = .{ .temporal_antialiasing = false, .sharpen = 0 },
                    .reflections = null,
                    .geometry = .{ .occlusion_culling = false },
                    .post = .{ .automatic_exposure = false, .bloom = 0 },
                    .global_illumination = .{ .probes = .{ .follow_camera = false } },
                    .clouds = .{ .temporal_filter = false },
                    .shadows = .{ .cascade_stagger = false, .light_filter = false },
                    .ambient_occlusion = .{ .temporal_filter = false, .bounce = 0 },
                },
            }, delta_time, arena);
            const state = &(self.views.internal.table.get(probe.view).?.state orelse return);
            cmd.transition(state.hdr, .shader_read);
            const forward = axes[0];
            const right = math.normalize(math.cross(forward, axes[1]));
            const up = math.cross(right, forward);
            try cmd.beginRendering(.{ .color = &.{.{ .texture = probe.cubes.sky.?, .layer = @intCast(face), .load = .discard }} });
            cmd.bindPipeline(try self.internal.pipelines.of(probeFacePipeline));
            cmd.pushConstants(environment_push.ProbeFacePush{
                .source_texture = device.textureIndex(state.hdr),
                .sampler_index = device.samplerIndex(self.internal.sampler_linear_clamp),
                .face = @intCast(face),
                .max_radiance = probe.desc.max_radiance,
                .right = right,
                .up = up,
                .forward = forward,
            });
            cmd.drawFullscreen();
            cmd.endRendering();
        }
        probe.face += 1;
        if (probe.face < 6) return;
        probe.face = 0;
        cmd.generateMips(probe.cubes.sky.?);
        try filterEnvironment(self, &probe.cubes, cmd);
        probe.cubes.state = .ready;
        probe.captured = true;
        return;
    };
}

fn probeFacePipeline(_: *rhi.Device) pipelines_module.Desc {
    return pipelines_module.pass("probe face", pipelines_module.shaderCode("probe_face.frag.spv"), &.{.{ .format = pipelines_module.hdr_format }});
}
