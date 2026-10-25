//! Bounce light from grids of probes that trace the scene.
const pipelines_module = @import("../renderer/pipelines.zig");
const gi_passes_push = @import("../shaders/push/gi_passes.zig");
const scene_pass = @import("../scene_pass.zig");
const ray_scene = @import("../scene/ray_scene.zig");
const math = @import("../../math.zig");
const render = @import("../renderer.zig");
const rhi = @import("../../rhi/rhi.zig");
const std = @import("std");
const gpu = @import("../gpu.zig");
const giScroll = @import("../renderer/view_math.zig").giScroll;
const api = @import("../api.zig");
const features = @import("../core/features.zig");
const renderer_state = @import("../state.zig");
const ScenePass = @import("../scene_pass.zig").ScenePass;
const filled = @import("../api.zig").filled;

const FrameArena = render.FrameArena;
const SceneFrame = scene_pass.SceneFrame;
const gi_probe_limit = render.gi_probe_limit;
const SceneData = render.SceneData;
const gi_visibility_texels = render.gi_visibility_texels;
const gi_irradiance_texels = render.gi_irradiance_texels;
const GiVolume = render.GiVolume;
const Renderer = render.Renderer;
const Vec3 = math.Vec3;
const hdr_format = renderer_state.hdr_format;
const ViewContext = features.ViewContext;

pub const name = "global_illumination";

/// How light bounced off the scene is found; one technique at a time.
pub const Settings = union(enum) {
    /// Irradiance probes in grids, a few of them retraced each frame.
    probes: Probes,
};

/// The probe settings of `setting`, or the defaults where it is off.
pub fn probes(setting: ?Settings) Probes {
    return if (setting) |chosen| switch (chosen) {
        .probes => |own| own,
    } else .{};
}

pub const Probes = struct {
    /// Distance between probes; grows automatically for large scenes.
    probe_spacing: f32 = 1.5,
    /// Rays traced per probe per frame, 16..256.
    rays: u32 = 128,
    /// Multiplies the probes' indirect light.
    intensity: f32 = 1,
    /// Resolution probe irradiance is evaluated at. Below `.full` it uses
    /// geometric normals, losing normal-map detail in indirect light.
    resolution: api.EffectResolution = .full,
    /// Each probe is re-traced once every this many frames, 1..16.
    update_interval: u32 = 4,
    /// Probes farther than this from the camera are re-traced an eighth as
    /// often, which is what pays for `Settings.global_illumination.rays`. 0 treats all alike.
    far_distance: f32 = 30,
    /// Share of a probe's previous value kept each frame, 0..1. Large changes
    /// bypass it; see `Settings.global_illumination.change_tolerance`.
    hysteresis: f32 = 0.998,
    /// In a scene too large for the grid at `Settings.global_illumination.probe_spacing`: true keeps that
    /// spacing in a grid that follows the camera, plus a coarse grid over the
    /// whole scene; false uses only the coarse grid.
    follow_camera: bool = true,
    /// How much wider than `Settings.global_illumination.probe_spacing` the spacing must get to cover the
    /// scene before the following grid is used.
    follow_threshold: f32 = 1.25,
    /// Once nothing the probes can see has moved and no light has changed
    /// for a few seconds, each probe is re-traced once every this many
    /// frames, 1..64; the usual rate returns with the first change. What
    /// probes cannot be told has changed, such as a glowing texture that
    /// plays, is followed at this rate. 0 never slows down.
    idle_interval: u32 = 16,
    /// Frames between updates of the coarse grid behind a following one.
    coarse_interval: u32 = 1,
    /// Most grids used at once, 1..4: the following one, the coarse one and
    /// following ones between them.
    cascades: u32 = 3,
    /// A grid is added between two whose spacings differ by more than this
    /// multiple, while `cascades` allows. 0 never adds one.
    cascade_ratio: f32 = 6,
    /// Local lights light what probe and reflection rays hit, at a shadow ray
    /// per light in range per hit.
    local_lights: bool = true,
    /// Local lights whose light bounces: the first this many of the scene's
    /// list, up to 1023.
    bounce_lights: u32 = 32,
    /// Trace probes that sit inside geometry only every eighth turn.
    skip_buried_probes: bool = false,
    /// Move probes out of walls and away from nearby surfaces, within their
    /// cells. Costs a pass per probe update and eight texture fetches per
    /// shaded pixel.
    probe_relocation: bool = false,
    /// How far a probe's steady estimate may sit above its fast one (0.25 =
    /// 25%) before it follows at once. It may sit two and a half times as far
    /// below, so a ray that lands on a lamp does not flash the probe. 0 turns
    /// it off.
    change_tolerance: f32 = 0.3,
};

pub fn preset(quality: api.Quality) ?Settings {
    return switch (quality) {
        .ultra => .{ .probes = .{} },
        .high => .{ .probes = .{ .rays = 64 } },
        .medium => null,
        .low => null,
    };
}

pub fn resolve(setting: *?Settings, r: *features.Resolve) void {
    if (!r.scene) setting.* = null;
    if (setting.* != null and !r.caps.ray_tracing) {
        setting.* = null;
        r.downgrade("global_illumination", "probes", "off", .no_ray_tracing);
    }
    if (setting.* != null) r.rays = true;
}

/// Adds the feature's passes to a view of a scene. A path traced view leaves
/// out those whose result the tracer replaces.
/// Places and fills the probe grids for this frame.
pub fn prepare(ctx: *ViewContext) !void {
    const p = ctx.scene orelse return;
    p.shared.gi = try prepareGi(ctx.renderer, p.scene, p.scene_frame, p.settings, p.desc.camera.position);
}

pub fn declare(ctx: *ViewContext) !void {
    const p = ctx.scene orelse return;
    describe(ctx, p);
    const g = ctx.graph;
    try g.add(.{ .name = "probes", .stage = .lighting, .always = true, .scope = false }, ctx, updateProbes);
    if (p.shared.gi == null) return;
    const reduced = probes(p.settings.global_illumination).resolution;
    if (reduced == .full) return;
    const gathered = try ctx.kept(.{ .name = "gi gather", .width = ScenePass.scaled(reduced, p.width), .height = ScenePass.scaled(reduced, p.height), .format = hdr_format, .usage = .{ .sampled = true, .color_attachment = true } });
    g.publish(.diffuse_gi, gathered);
    try g.add(.{ .name = "gi gather", .stage = .lighting, .color = &.{.{ .target = gathered }}, .always = true }, ctx, gatherProbes);
}

/// Fills in the frame constants that are this feature's.
fn describe(ctx: *ViewContext, p: *const ScenePass) void {
    const own = probes(p.settings.global_illumination);
    const constants = ctx.constants;
    constants.gi.gi_intensity = own.intensity;
    constants.gi.local_lights = @intFromBool(own.local_lights);
    constants.gi.bounce_lights = std.math.clamp(own.bounce_lights, 1, 1023);
    if (p.shared.gi == null) return;
    constants.gi.enabled = 1;
    constants.gi.gi_cascade_count = p.scene.gi_cascade_count;
    for (p.scene.gi_cascades[0..p.scene.gi_cascade_count], 0..) |*slot, index| {
        const volume = &slot.*.?;
        constants.gi.gi_cascades[index] = .{
            .origin = volume.origin,
            .spacing = volume.spacing,
            .counts = .{ @intCast(volume.counts[0]), @intCast(volume.counts[1]), @intCast(volume.counts[2]) },
            .irradiance = ctx.device.textureIndex(volume.irradiance),
            .visibility = ctx.device.textureIndex(volume.visibility),
            .scroll = giScroll(volume),
            .offsets = if (own.probe_relocation and volume.offsets_valid) ctx.device.textureIndex(volume.offsets[volume.offset_turn]) else gpu.invalid_id,
        };
    }
}

fn updateProbes(ctx: *ViewContext) !void {
    const p = ctx.scene.?;
    const c = p.shared;
    const self = ctx.renderer;
    const scene = p.scene;
    if (c.gi == null) return;
    if (scene.gi_updated_frame == self.internal.frame_index) return;
    const count = scene.gi_cascade_count;
    const last = count - 1;
    noteChanges(scene, p.scene_frame.tlas_hash);
    try updateGi(self, p.cmd, scene, &scene.gi_cascades[0].?, p.arena, p.frame_address, p.settings, 0);
    if (last != 0) {
        const coarse = &scene.gi_cascades[last].?;
        if (coarse.frames < 64 or self.internal.frame_index % @max(probes(p.settings.global_illumination).coarse_interval, 1) == 0)
            try updateGi(self, p.cmd, scene, coarse, p.arena, p.frame_address, p.settings, last);
    }
    for (1..@max(last, 1)) |index| try updateGi(self, p.cmd, scene, &scene.gi_cascades[index].?, p.arena, p.frame_address, p.settings, @intCast(index));
    scene.gi_updated_frame = self.internal.frame_index;
}

/// The reduced-resolution probe gather, which the graph has begun rendering
/// into; shading upsamples it.
fn gatherProbes(ctx: *ViewContext) !void {
    const p = ctx.scene.?;
    const self = ctx.renderer;
    const cmd = p.cmd;
    cmd.bindPipeline(try self.internal.pipelines.of(giGatherPipeline));
    cmd.pushConstants(gi_passes_push.GatherPush{
        .frame = p.frame_address,
        .depth_texture = self.device.textureIndex(p.view.depth),
    });
    cmd.drawFullscreen();
}

/// Most probes across X times Z: the atlases lay them side by side, 16 texels
/// each, and a texture is at most 32768 wide.
const gi_atlas_tiles = 2048;

/// Ray `index` of `count` spread evenly over the sphere.
fn sphericalFibonacci(index: f32, count: f32) Vec3 {
    const phi = std.math.tau * @mod(index * 0.618033988749895, 1.0);
    const cos_theta = 1 - (2 * index + 1) / count;
    const sin_theta = @sqrt(std.math.clamp(1 - cos_theta * cos_theta, 0, 1));
    return .{ @cos(phi) * sin_theta, @sin(phi) * sin_theta, cos_theta };
}

/// Returns the volume in `slot` moved to `cell`, or a new one if the grid's
/// shape, spacing or ray count changed.
pub fn ensureGiVolume(renderer: *Renderer, slot: *?GiVolume, scene_origin: [3]f64, cell: [3]i32, counts: [3]u32, spacing: f32, rays_per_probe: u32) !*GiVolume {
    const device = renderer.device;
    var origin: Vec3 = undefined;
    inline for (0..3) |axis| origin[axis] = @floatCast(@as(f64, @floatFromInt(cell[axis])) * spacing - scene_origin[axis]);
    if (slot.*) |*volume| {
        const same = std.mem.eql(u32, &volume.counts, &counts) and volume.rays_per_probe == rays_per_probe and
            @abs(volume.spacing - spacing) < 1e-4;
        if (same) {
            inline for (0..3) |axis| volume.shift[axis] = cell[axis] - volume.cell[axis];
            var kept: u64 = 1;
            var total: u64 = 1;
            inline for (0..3) |axis| {
                kept *= counts[axis] -| @abs(volume.shift[axis]);
                total *= counts[axis];
            }
            if (kept * 2 < total and volume.frames != 0) volume.frames = 1;
            volume.cell = cell;
            volume.origin = origin;
            return volume;
        }
        volume.deinit(device);
        slot.* = null;
    }
    const color = rhi.TextureUsage{ .sampled = true, .color_attachment = true };
    const tiles_x = counts[0] * counts[2];
    const probe_count = counts[0] * counts[1] * counts[2];
    var made = render.MadeTextures{ .device = device };
    errdefer made.destroy();
    slot.* = .{
        .origin = origin,
        .cell = cell,
        .spacing = spacing,
        .counts = counts,
        .rays_per_probe = rays_per_probe,
        .irradiance = try made.texture(.{
            .name = "gi irradiance",
            .width = tiles_x * gi_irradiance_texels,
            .height = counts[1] * gi_irradiance_texels,
            .format = hdr_format,
            .usage = color,
        }),
        .irradiance_fast = try made.texture(.{
            .name = "gi irradiance (fast)",
            .width = tiles_x * gi_irradiance_texels,
            .height = counts[1] * gi_irradiance_texels,
            .format = hdr_format,
            .usage = color,
        }),
        .visibility = try made.texture(.{
            .name = "gi visibility",
            .width = tiles_x * gi_visibility_texels,
            .height = counts[1] * gi_visibility_texels,
            .format = .rg16_float,
            .usage = color,
        }),
        .offsets = .{
            try made.texture(.{ .name = "gi probe offsets", .width = tiles_x, .height = counts[1], .format = .rgba16_float, .usage = color }),
            try made.texture(.{ .name = "gi probe offsets", .width = tiles_x, .height = counts[1], .format = .rgba16_float, .usage = color }),
        },
        .rays = try device.createBuffer(.{
            .name = "gi rays",
            .size = @as(u64, probe_count) * rays_per_probe * @sizeOf([4]f32),
            .usage = .{ .storage = true },
        }),
    };
    return &slot.*.?;
}

/// Sizes the probe volume for this frame. Returns null when global
/// illumination is off, unsupported or there is nothing to trace. The volumes
/// belong to the scene: its first view in a frame shapes them and later views
/// share them.
pub fn prepareGi(renderer: *Renderer, scene: *SceneData, scene_frame: SceneFrame, settings: api.Settings, camera_position: Vec3) !?*GiVolume {
    const device = renderer.device;
    if (!device.caps.ray_tracing) return null;
    var gi_max_counts: [3]u32 = undefined;
    inline for (0..3) |axis| gi_max_counts[axis] = std.math.clamp(renderer.options.ray_tracing.max_probes[axis], 2, gi_probe_limit);
    while (gi_max_counts[0] * gi_max_counts[2] > gi_atlas_tiles) {
        const widest: usize = if (gi_max_counts[0] >= gi_max_counts[2]) 0 else 2;
        gi_max_counts[widest] -= 1;
    }
    if (!(settings.global_illumination != null) or !ray_scene.ready(scene, scene_frame)) return null;

    if (scene.gi_frame == renderer.internal.frame_index) {
        if (scene.gi_cascades[0]) |*volume| return volume;
    }
    scene.gi_frame = renderer.internal.frame_index;

    const own = probes(settings.global_illumination);
    const bounds = scene.gi_bounds orelse scene_frame.bounds;
    inline for (0..3) |axis| if (!(bounds[1][axis] >= bounds[0][axis]) or !std.math.isFinite(bounds[1][axis] - bounds[0][axis])) return null;
    const extent = math.sub(bounds[1], bounds[0]);
    const wanted = @max(own.probe_spacing, 0.25);
    var stretched = wanted;
    inline for (0..3) |axis| stretched = @max(stretched, extent[axis] / @as(f32, @floatFromInt(gi_max_counts[axis] - 1)));
    const follow = own.follow_camera and scene.gi_bounds == null and stretched > wanted * own.follow_threshold;

    var spacings: [gpu.gi_cascade_max]f32 = undefined;
    var count: u32 = 1;
    spacings[0] = stretched;
    if (follow) {
        const ratio = stretched / wanted;
        const limit = std.math.clamp(own.cascades, 2, gpu.gi_cascade_max);
        var between: u32 = 0;
        if (own.cascade_ratio > 0) {
            while (between + 2 < limit and std.math.pow(f32, ratio, 1 / @as(f32, @floatFromInt(between + 1))) > own.cascade_ratio) between += 1;
        }
        count = between + 2;
        for (0..count) |index| {
            const along = @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(count - 1));
            spacings[index] = if (index + 1 == count) stretched else if (index == 0) wanted else if (count == 3) wanted * @sqrt(ratio) else wanted * std.math.pow(f32, ratio, along);
        }
    }
    const rays_per_probe = std.math.clamp(own.rays, 16, 256);
    for (spacings[0..count], 0..) |spacing, index| {
        const follows = follow and index + 1 != count;
        var cell: [3]i32 = undefined;
        var counts: [3]u32 = undefined;
        inline for (0..3) |axis| {
            const first = gridIndex(@floor((bounds[0][axis] + scene.origin[axis]) / spacing));
            const needed: f32 = @floatCast(@ceil((bounds[1][axis] + scene.origin[axis]) / spacing) - @as(f64, @floatFromInt(first)) + 1);
            counts[axis] = @intFromFloat(std.math.clamp(needed, 2, @as(f32, @floatFromInt(gi_max_counts[axis]))));
            cell[axis] = if (follows and needed > @as(f32, @floatFromInt(gi_max_counts[axis])))
                gridIndex(@floor((camera_position[axis] + scene.origin[axis]) / spacing)) - @as(i32, @intCast(counts[axis] / 2))
            else
                first;
        }
        _ = try ensureGiVolume(renderer, &scene.gi_cascades[index], scene.origin, cell, counts, spacing, rays_per_probe);
    }
    for (scene.gi_cascades[count..]) |*slot| {
        if (slot.*) |*volume| volume.deinit(device);
        slot.* = null;
    }
    scene.gi_cascade_count = count;
    return &scene.gi_cascades[0].?;
}

/// Frames the scene must stay as it is before probes are updated less often.
const frames_to_idle = 600;

/// While geometry is still, the atlas of distances is blended once in this
/// many rounds of probe updates.
const idle_visibility_rounds = 8;

/// Counts the frames since the geometry probes see, and the light on it,
/// last changed.
fn noteChanges(scene: *SceneData, geometry: u64) void {
    var lighting = std.hash.Wyhash.init(0);
    lighting.update(std.mem.asBytes(&scene.sun.direction));
    lighting.update(std.mem.asBytes(&scene.sun.color));
    lighting.update(std.mem.asBytes(&scene.sun.intensity));
    lighting.update(std.mem.asBytes(&scene.environment));
    lighting.update(std.mem.asBytes(&scene.environment_intensity));
    for (scene.lights.items) |light| {
        lighting.update(std.mem.asBytes(&light.position));
        lighting.update(std.mem.asBytes(&light.direction));
        lighting.update(std.mem.asBytes(&light.color));
        lighting.update(std.mem.asBytes(&light.intensity));
        lighting.update(std.mem.asBytes(&light.range));
        lighting.update(std.mem.asBytes(&light.inner_angle));
        lighting.update(std.mem.asBytes(&light.outer_angle));
        lighting.update(&.{@intFromEnum(light.kind)});
    }
    const lighting_key = lighting.final();
    const unsteady = scene.fluids.items.len != 0 or scene.clouds != null;
    scene.gi_geometry_still = if (geometry == scene.gi_geometry_key) scene.gi_geometry_still +| 1 else 0;
    scene.gi_geometry_key = geometry;
    scene.gi_lighting_still = if (lighting_key == scene.gi_lighting_key and !unsteady) @min(scene.gi_lighting_still +| 1, scene.gi_geometry_still) else 0;
    scene.gi_lighting_key = lighting_key;
}

fn everyCascadeLit(scene: *const SceneData) bool {
    for (scene.gi_cascades) |slot| {
        if (slot) |volume| if (volume.frames == 0) return false;
    }
    return true;
}

/// Traces this frame's probe rays and blends them into the atlases.
pub fn updateGi(
    renderer: *Renderer,
    cmd: *rhi.CommandEncoder,
    scene: *SceneData,
    volume: *GiVolume,
    arena: *FrameArena,
    frame_address: u64,
    settings: api.Settings,
    grid_index: u32,
) !void {
    const device = renderer.device;
    cmd.beginScope("global illumination");
    defer cmd.endScope();
    const tlas = scene.tlas.?;

    const turn: f64 = @floatFromInt(renderer.internal.frame_index + 1);
    const first: f32 = @floatCast(@mod(turn * 0.8191725133961645, 1.0));
    const second: f32 = @floatCast(@mod(turn * 0.6710436067037893, 1.0));
    const third: f32 = @floatCast(@mod(turn * 0.5497004779019703, 1.0));
    const rotation = math.fromQuat(.{
        @sqrt(1 - first) * @sin(std.math.tau * second),
        @sqrt(1 - first) * @cos(std.math.tau * second),
        @sqrt(first) * @sin(std.math.tau * third),
        @sqrt(first) * @cos(std.math.tau * third),
    });
    const directions = try arena.alloc(device, [4]f32, volume.rays_per_probe);
    for (directions.items, 0..) |*out, ray| {
        const way = math.transformDirection(rotation, sphericalFibonacci(@floatFromInt(ray), @floatFromInt(volume.rays_per_probe)));
        out.* = .{ way[0], way[1], way[2], 0 };
    }
    const max_distance = volume.spacing * 1.75 * 1.5;
    const probe_count = volume.probeCount();
    const moved = volume.shift[0] != 0 or volume.shift[1] != 0 or volume.shift[2] != 0;
    const own = probes(settings.global_illumination);
    const fresh = volume.frames < 200 or (moved and grid_index + 1 >= scene.gi_cascade_count);
    const idle = !fresh and own.idle_interval != 0 and scene.gi_lighting_still >= frames_to_idle;
    const usual = std.math.clamp(own.update_interval, 1, 16);
    const stride: u32 = if (fresh) 1 else if (idle) @max(usual, @min(own.idle_interval, 64)) else usual;
    const distances_due = fresh or scene.gi_geometry_still < frames_to_idle or (renderer.internal.frame_index / stride) % idle_visibility_rounds == 0;
    const phase: u32 = @intCast(renderer.internal.frame_index % stride);

    const far_distance: f32 = if (fresh) 0 else @max(probes(settings.global_illumination).far_distance, 0);
    const update_turn: u32 = @truncate(renderer.internal.frame_index / stride);

    cmd.beginScope("gi trace");
    cmd.bindPipeline(try renderer.internal.pipelines.of(giTracePipeline));
    cmd.pushConstants(gi_passes_push.TracePush{
        .frame = frame_address,
        .rays = device.bufferAddress(volume.rays),
        .tlas = device.accelerationAddress(tlas),
        .directions = directions.address,
        .rays_per_probe = volume.rays_per_probe,
        .probe_count = probe_count,
        .multibounce = @intFromBool(volume.frames != 0 and everyCascadeLit(scene)),
        .probe_stride = stride,
        .probe_phase = phase,
        .grid = grid_index,
        .skip_buried = @intFromBool(probes(settings.global_illumination).skip_buried_probes),
        .far_distance = far_distance,
        .turn = update_turn,
        .max_distance = 1000,
    });
    cmd.dispatch((((probe_count + stride - 1) / stride) * volume.rays_per_probe + 63) / 64, 1, 1);
    cmd.sync(.compute_to_all);
    cmd.endScope();

    const settled = std.math.pow(f32, std.math.clamp(probes(settings.global_illumination).hysteresis, 0, 0.999), @floatFromInt(stride));
    const gathered: f32 = @floatFromInt(volume.frames);
    const hysteresis: f32 = if (volume.frames == 0) 0 else @min(settled, @max(0.8, 1 - 2 / (gathered + 2)));
    const fast_hysteresis = 0.97;
    const raise_reluctance = 2.5;
    const UpdatePush = gi_passes_push.UpdatePush;
    const RelocatePush = gi_passes_push.RelocatePush;
    const update_push = UpdatePush{
        .frame = frame_address,
        .rays = device.bufferAddress(volume.rays),
        .directions = directions.address,
        .rays_per_probe = volume.rays_per_probe,
        .hysteresis = hysteresis,
        .max_distance = max_distance,
        .probe_stride = stride,
        .probe_phase = phase,
        .fast_hysteresis = if (volume.frames == 0) 0 else fast_hysteresis,
        .shift = volume.shift,
        .grid_index = grid_index,
        .far_distance = far_distance,
        .turn = update_turn,
        .axis = math.transformDirection(rotation, .{ 0, 0, 1 }),
    };
    const load: rhi.LoadOp = if (volume.frames == 0) .clear else .load;
    cmd.beginScope("gi irradiance");
    try cmd.beginRendering(.{ .color = &.{
        .{ .texture = volume.irradiance, .load = load },
        .{ .texture = volume.irradiance_fast, .load = load },
    } });
    cmd.bindPipeline(try renderer.internal.pipelines.of(giIrradiancePipeline));
    cmd.pushConstants(update_push);
    cmd.drawFullscreen();
    cmd.endRendering();
    const tolerance = std.math.clamp(probes(settings.global_illumination).change_tolerance, 0, 4);
    if (tolerance > 0 and volume.frames != 0) {
        const ClampPush = gi_passes_push.ClampPush;
        for ([_]rhi.Pipeline{ try renderer.internal.pipelines.of(giClampUpperPipeline), try renderer.internal.pipelines.of(giClampLowerPipeline) }, [_]f32{ 1, -1 }) |pipeline, sign| {
            try cmd.beginRendering(.{ .color = &.{.{ .texture = volume.irradiance, .load = .load }} });
            cmd.bindPipeline(pipeline);
            cmd.pushConstants(ClampPush{
                .frame = frame_address,
                .fast_texture = device.textureIndex(volume.irradiance_fast),
                .scale = if (sign > 0) 1 + tolerance else @max(1 - tolerance * raise_reluctance, 0),
                .offset = sign * 0.002,
            });
            cmd.drawFullscreen();
            cmd.endRendering();
        }
    }
    cmd.endScope();
    if (distances_due) {
        cmd.beginScope("gi visibility");
        try cmd.beginRendering(.{ .color = &.{.{ .texture = volume.visibility, .load = load }} });
        cmd.bindPipeline(try renderer.internal.pipelines.of(giVisibilityPipeline));
        cmd.pushConstants(update_push);
        cmd.drawFullscreen();
        cmd.endRendering();
        cmd.transition(volume.visibility, .shader_read);
        cmd.endScope();
    }
    if (probes(settings.global_illumination).probe_relocation) {
        cmd.beginScope("gi relocation");
        defer cmd.endScope();
        const read = volume.offsets[volume.offset_turn];
        const write = volume.offsets[1 - volume.offset_turn];
        if (!volume.offsets_valid) {
            try cmd.beginRendering(.{ .color = &.{.{ .texture = read, .load = .clear, .clear = .{ 0, 0, 0, 0 } }} });
            cmd.endRendering();
        }
        try cmd.beginRendering(.{ .color = &.{.{ .texture = write, .load = .discard }} });
        cmd.bindPipeline(try renderer.internal.pipelines.of(giRelocatePipeline));
        var relocate_push = RelocatePush{ .update = update_push, .previous_offsets = device.textureIndex(read) };
        relocate_push.update.grid_index = grid_index;
        cmd.pushConstants(relocate_push);
        cmd.drawFullscreen();
        cmd.endRendering();
        volume.offset_turn = 1 - volume.offset_turn;
        volume.offsets_valid = true;
    } else volume.offsets_valid = false;
    volume.frames +|= 1;
    renderer.internal.stats.gi_probes = probe_count;
}

fn giGatherPipeline(_: *rhi.Device) pipelines_module.Desc {
    return pipelines_module.pass("gi gather", pipelines_module.shaderCode("gi_gather.frag.spv"), &.{.{ .format = pipelines_module.hdr_format }});
}

fn giTracePipeline(_: *rhi.Device) pipelines_module.Desc {
    return .{ .compute = .{ .name = "gi trace", .shader = pipelines_module.shaderCode("gi_trace.comp.spv") } };
}

fn giIrradiancePipeline(_: *rhi.Device) pipelines_module.Desc {
    return .{ .graphics = .{
        .name = "gi irradiance",
        .vertex = pipelines_module.shaderCode("fullscreen.vert.spv"),
        .fragment = pipelines_module.shaderCode("gi_irradiance.frag.spv"),
        .color_targets = &.{ .{ .format = pipelines_module.hdr_format, .blend = .alpha }, .{ .format = pipelines_module.hdr_format, .blend = .alpha } },
        .cull = .none,
    } };
}

fn giClampUpperPipeline(_: *rhi.Device) pipelines_module.Desc {
    return .{ .graphics = .{
        .name = "gi clamp upper",
        .vertex = pipelines_module.shaderCode("fullscreen.vert.spv"),
        .fragment = pipelines_module.shaderCode("gi_clamp.frag.spv"),
        .color_targets = &.{.{ .format = pipelines_module.hdr_format, .blend = .minimum }},
        .cull = .none,
    } };
}

fn giRelocatePipeline(_: *rhi.Device) pipelines_module.Desc {
    return .{ .graphics = .{
        .name = "gi relocate",
        .vertex = pipelines_module.shaderCode("fullscreen.vert.spv"),
        .fragment = pipelines_module.shaderCode("gi_relocate.frag.spv"),
        .color_targets = &.{.{ .format = .rgba16_float }},
        .cull = .none,
    } };
}

fn giClampLowerPipeline(_: *rhi.Device) pipelines_module.Desc {
    return .{ .graphics = .{
        .name = "gi clamp lower",
        .vertex = pipelines_module.shaderCode("fullscreen.vert.spv"),
        .fragment = pipelines_module.shaderCode("gi_clamp.frag.spv"),
        .color_targets = &.{.{ .format = pipelines_module.hdr_format, .blend = .maximum }},
        .cull = .none,
    } };
}

fn giVisibilityPipeline(_: *rhi.Device) pipelines_module.Desc {
    return .{ .graphics = .{
        .name = "gi visibility",
        .vertex = pipelines_module.shaderCode("fullscreen.vert.spv"),
        .fragment = pipelines_module.shaderCode("gi_visibility.frag.spv"),
        .color_targets = &.{.{ .format = .rg16_float, .blend = .alpha }},
        .cull = .none,
    } };
}

/// A probe grid cell index along one axis, held within reach of `i32` so a
/// far-off scene origin or volume cannot overflow it.
fn gridIndex(cell: f64) i32 {
    return @intFromFloat(std.math.clamp(cell, -(1 << 30), 1 << 30));
}
