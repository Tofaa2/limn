//! Drawing one view: its scene through the frame graph of passes, then its draw lists. Internal to the renderer.
const std = @import("std");
const rhi = @import("../../rhi/rhi.zig");
const math = @import("../../math.zig");
const gpu = @import("../gpu.zig");
const api = @import("../api.zig");
const renderer_state = @import("../state.zig");
const scene_pass = @import("../scene_pass.zig");
const frame_graph = @import("../frame_graph.zig");
const geometry_passes = @import("../passes/geometry.zig");
const shadow_passes = @import("../passes/shadows.zig");
const shading_passes = @import("../passes/shading.zig");
const transparency_passes = @import("../passes/transparency.zig");
const volume_passes = @import("../passes/volumes.zig");
const path_tracing_pass = @import("../passes/path_tracing.zig");
const post_passes = @import("../passes/post.zig");
const simulation_passes = @import("../passes/simulation.zig");
const particle_passes = @import("../passes/particles.zig");
const hair_passes = @import("../passes/hair.zig");
const impostor_passes = @import("../passes/impostors.zig");
const lightmap_passes = @import("../passes/lightmaps.zig");
const virtual_shadow_passes = @import("../passes/virtual_shadows.zig");
const gi_passes = @import("../passes/gi.zig");
const render = @import("../renderer.zig");

const Renderer = render.Renderer;
const Vec3 = math.Vec3;
const ScenePass = scene_pass.ScenePass;
const SunShadows = scene_pass.SunShadows;
const Lighting = scene_pass.Lighting;
const Scene = api.Scene;
const Zone = renderer_state.Zone;
const EffectScales = renderer_state.EffectScales;
const Region = api.Region;
const PassStage = api.PassStage;
const ViewDesc = api.ViewDesc;
const hdr_format = renderer_state.hdr_format;
const view_count = renderer_state.view_count;
const main_late_view = renderer_state.main_late_view;
const cluster_near = renderer_state.cluster_near;
const cluster_far = renderer_state.cluster_far;
const cluster_z_scale = renderer_state.cluster_z_scale;
const env_specular_mips = renderer_state.env_specular_mips;
const FrameArena = renderer_state.FrameArena;
const EnvironmentEntry = renderer_state.EnvironmentEntry;
const SceneData = renderer_state.SceneData;
const ViewState = renderer_state.ViewState;
const ViewData = renderer_state.ViewData;
const GiVolume = renderer_state.GiVolume;
const ReflectionTargets = renderer_state.ReflectionTargets;
const buildPendingBlas = @import("scene_update.zig").buildPendingBlas;
const giScroll = @import("view_math.zig").giScroll;
const halton = @import("view_math.zig").halton;
const prepareLights = @import("scene_update.zig").prepareLights;
const prepareScene = @import("scene_update.zig").prepareScene;
const renderDrawLists = @import("canvas.zig").renderDrawLists;
const targetWritten = @import("views.zig").targetWritten;

pub fn renderView(self: *Renderer, frame: rhi.Frame, desc: ViewDesc, delta_time: f32, arena: *FrameArena) !void {
    const view_zone = Zone.start(self.options.profiler, "render view");
    defer view_zone.stop();
    const device = self.device;
    const cmd = frame.cmd;
    const target = switch (desc.target) {
        .backbuffer => frame.backbuffer orelse return error.NoSurface,
        .texture => |texture| texture,
    };
    if (!device.textureExists(target)) return error.InvalidTarget;
    const info = device.textureInfo(target);
    const region = desc.region orelse Region{ .x = 0, .y = 0, .width = info.width, .height = info.height };
    if (region.width == 0 or region.height == 0 or
        @as(u64, region.x) + region.width > info.width or @as(u64, region.y) + region.height > info.height)
        return error.InvalidRegion;
    const whole = region.width == info.width and region.height == info.height;
    const written = targetWritten(self, target);
    if (!written) {
        if (self.frame_target_count == self.frame_targets.len) return error.TooManyTargets;
        self.frame_targets[self.frame_target_count] = target;
        self.frame_target_count += 1;
    }
    const load: rhi.LoadOp = if (written) .load else .clear;

    if (desc.scene) |scene_handle| {
        const scene = self.scenes.table.get(scene_handle) orelse return error.InvalidScene;
        const view = self.views.table.get(desc.view orelse self.main_view) orelse return error.InvalidView;
        if (view.last_frame == self.frame_index) return error.ViewUsedTwice;
        var color = target;
        if (!whole) {
            if (view.output) |texture| {
                const current = device.textureInfo(texture);
                if (current.width != region.width or current.height != region.height or view.output_format != info.format) {
                    device.destroyTexture(texture);
                    view.output = null;
                }
            }
            if (view.output == null) {
                view.output = try device.createTexture(.{
                    .name = "view output",
                    .width = region.width,
                    .height = region.height,
                    .format = info.format,
                    .usage = .{ .sampled = true, .color_attachment = true },
                });
                view.output_format = info.format;
            }
            color = view.output.?;
        }
        const render_scale = std.math.clamp(desc.settings.render_scale, 0.25, 2);
        const internal_width: u32 = @max(@as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(region.width)) * render_scale))), 1);
        const internal_height: u32 = @max(@as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(region.height)) * render_scale))), 1);
        const frame_address = try renderScene(self, frame, desc, scene_handle, scene, view, color, info.format, internal_width, internal_height, region.width, region.height, delta_time, arena);
        try renderDrawLists(self, cmd, desc, .{
            .texture = color,
            .format = info.format,
            .region = .{ .x = 0, .y = 0, .width = region.width, .height = region.height },
            .load = .load,
            .clear = desc.clear_color,
            .depth = view.state.?.depth,
        }, arena);
        if (!whole) {
            cmd.beginScope("view composite");
            cmd.transition(color, .shader_read);
            try cmd.beginRendering(.{ .color = &.{.{ .texture = target, .load = load, .clear = desc.clear_color }} });
            cmd.setViewport(region.x, region.y, region.width, region.height);
            cmd.bindPipeline(try post_passes.tonemapPipeline(self, info.format));
            cmd.pushConstants(post_passes.TonemapPush{
                .frame = frame_address,
                .color = device.textureIndex(color),
                .bloom = gpu.invalid_id,
                .bloom_strength = 0,
                .encode_srgb = 0,
                .sharpen = 0,
                .bloom_scale = 0,
                .passthrough = 1,
                .origin = .{ @intCast(region.x), @intCast(region.y) },
            });
            cmd.drawFullscreen();
            cmd.endRendering();
            cmd.endScope();
        }
    } else {
        try renderDrawLists(self, cmd, desc, .{
            .texture = target,
            .format = info.format,
            .region = region,
            .load = load,
            .clear = desc.clear_color,
        }, arena);
    }
    if (desc.target == .texture) cmd.transition(target, .shader_read);
}

/// A scene view's frame as a graph of passes (`frame_graph.zig`). When
/// the view is path traced, passes whose output the tracer replaces are
/// left out.
const SceneGraph = struct {
    const Resource = enum {
        cull_buffers,
        simulated,
        particles_stepped,
        deformed,
        culled,
        visibility,
        sun_shadows,
        virtual_shadows,
        light_clusters,
        local_shadows,
        occlusion,
        probes,
        lightmaps,
        gathered_probes,
        lit,
        clouded,
        reflected,
        opaque_done,
        impostor_pictures,
        impostors,
        hair,
        liquids,
        water,
        transparent,
        smoke,
        fogged,
        particles,
        transparent_done,
        traced,
        resolved,
        lensed,
        bloom,
        picture,
    };
    const Graph = frame_graph.Graph(Resource, SceneGraph);

    renderer: *Renderer,
    pass: *const ScenePass,
    frame: rhi.Frame,
    arena: *FrameArena,
    delta_time: f32,
    sun: *const SunShadows,
    lighting: *const Lighting,
    local_shadows: *const scene_pass.LocalShadows,
    gi: ?*GiVolume,
    flags: u32,
    shadow_tlas: u64,
    colored_shadows: bool,
    cloud_address: u64,
    fluid_list: *gpu.FluidList,
    shadows_enabled: bool,
    first_view: bool,
    fresh_scene: bool,
    instance_total: u32,
    count_readback: rhi.Buffer,
    target: rhi.Texture,
    target_format: rhi.Format,
    /// The view's virtual shadow map for this frame, or 0.
    vsm_params: u64,
    culling: scene_pass.CullState = undefined,
    gathered_gi: ?rhi.Texture = null,
    reflections: ?ReflectionTargets = null,
    path_traced: bool = false,
    resolved: rhi.Texture = undefined,
    bloom_count: usize = 0,

    fn set(comptime resources: anytype) Graph.Set {
        var result = Graph.Set.initEmpty();
        inline for (resources) |resource| result.insert(resource);
        return result;
    }

    fn run(self: *SceneGraph) !void {
        const tracing = self.pass.settings.path_tracing and !self.pass.debugging and self.pass.view_data.path_traced;
        const passes = [_]Graph.Pass{
            .{ .name = "reset culling", .writes = set(.{.cull_buffers}), .run = resetCulling },
            .{ .name = "simulation", .reads = set(.{.cull_buffers}), .writes = set(.{.simulated}), .always = true, .run = simulate },
            .{ .name = "particle simulation", .reads = set(.{.simulated}), .writes = set(.{.particles_stepped}), .always = true, .run = stepParticles },
            .{ .name = "deformed geometry", .reads = set(.{.cull_buffers}), .writes = set(.{.deformed}), .run = deform },
            .{ .name = "culling", .reads = set(.{ .cull_buffers, .deformed }), .writes = set(.{.culled}), .run = cull },
            .{ .name = "visibility", .reads = set(.{.culled}), .writes = set(.{.visibility}), .run = drawVisibility },
            .{ .name = "sun shadows", .reads = set(.{.visibility}), .writes = set(.{.sun_shadows}), .run = sunShadows },
            .{ .name = "virtual shadows", .reads = set(.{ .visibility, .sun_shadows }), .writes = set(.{.virtual_shadows}), .run = virtualShadows },
            .{ .name = "light clusters", .reads = set(.{.simulated}), .writes = set(.{.light_clusters}), .run = clusterLights },
            .{ .name = "local shadows", .reads = set(.{ .visibility, .light_clusters }), .writes = set(.{.local_shadows}), .run = localShadows },
            .{ .name = "ambient occlusion", .reads = set(.{.visibility}), .writes = set(.{.occlusion}), .always = true, .run = occlusion },
            .{ .name = "probes", .reads = set(.{ .visibility, .sun_shadows }), .writes = set(.{.probes}), .always = true, .run = updateProbes },
            .{ .name = "lightmaps", .reads = set(.{.probes}), .writes = set(.{.lightmaps}), .always = true, .run = lightmaps },
            .{ .name = "probe gather", .reads = set(.{.probes}), .writes = set(.{.gathered_probes}), .run = gatherProbes },
            .{ .name = "shading", .reads = set(.{ .visibility, .sun_shadows, .virtual_shadows, .local_shadows, .light_clusters, .occlusion, .gathered_probes }), .writes = set(.{.lit}), .run = shade },
            .{ .name = "clouds", .reads = set(.{.lit}), .writes = set(.{.clouded}), .run = clouds },
            .{ .name = "reflections", .reads = set(.{.clouded}), .writes = set(.{.reflected}), .run = reflect },
            .{ .name = "after opaque", .reads = set(.{.reflected}), .writes = set(.{.opaque_done}), .run = afterOpaque },
            .{ .name = "impostor pictures", .reads = set(.{.cull_buffers}), .writes = set(.{.impostor_pictures}), .always = true, .run = impostorPictures },
            .{ .name = "impostors", .reads = set(.{ .opaque_done, .impostor_pictures }), .writes = set(.{.impostors}), .run = impostors },
            .{ .name = "hair", .reads = set(.{.impostors}), .writes = set(.{.hair}), .run = hair },
            .{ .name = "liquids", .reads = set(.{ .hair, .particles_stepped }), .writes = set(.{.liquids}), .run = liquids },
            .{ .name = "water", .reads = set(.{.liquids}), .writes = set(.{.water}), .run = water },
            .{ .name = "transparency", .reads = set(.{.water}), .writes = set(.{.transparent}), .run = transparency },
            .{ .name = "smoke", .reads = set(.{.transparent}), .writes = set(.{.smoke}), .run = smoke },
            .{ .name = "fog", .reads = set(.{.smoke}), .writes = set(.{.fogged}), .run = fog },
            .{ .name = "particles", .reads = set(.{.fogged}), .writes = set(.{.particles}), .run = particles },
            .{ .name = "after transparency", .reads = set(.{.particles}), .writes = set(.{.transparent_done}), .run = afterTransparency },
            .{ .name = "path tracing", .reads = if (tracing) set(.{ .lit, .probes }) else set(.{ .transparent_done, .probes }), .writes = set(.{.traced}), .run = trace },
            .{ .name = "temporal antialiasing", .reads = set(.{.traced}), .writes = set(.{.resolved}), .run = resolve },
            .{ .name = "lens", .reads = set(.{.resolved}), .writes = set(.{.lensed}), .run = lens },
            .{ .name = "bloom and exposure", .reads = set(.{.lensed}), .writes = set(.{.bloom}), .run = bloom },
            .{ .name = "tone mapping", .reads = set(.{.bloom}), .writes = set(.{.picture}), .run = tonemap },
        };
        try Graph.run(&passes, set(.{.picture}), self);
    }

    fn resetCulling(c: *SceneGraph) !void {
        try geometry_passes.resetCullBuffers(c.renderer, c.pass, c.instance_total);
    }

    fn simulate(c: *SceneGraph) !void {
        const p = c.pass;
        if (c.fresh_scene) try simulation_passes.simulateFluids(c.renderer, p.cmd, p.scene, c.arena, c.delta_time);
        if (c.fresh_scene) try simulation_passes.simulateWater(c.renderer, p.cmd, p.scene, c.arena, c.delta_time);
        if (c.fresh_scene) try simulation_passes.simulateLiquids(c.renderer, p.cmd, p.scene, c.arena, c.delta_time);
        if (c.fresh_scene) try hair_passes.simulateHair(c.renderer, p, c.delta_time);
        c.fluid_list.* = volume_passes.shadowingFluids(c.renderer, p);
        volume_passes.lightFluids(c.renderer, p, c.lighting);
    }

    /// Runs after fluids, which may carry particles. Collides with the
    /// depth this view drew last frame.
    fn stepParticles(c: *SceneGraph) !void {
        const p = c.pass;
        const device = c.renderer.device;
        if (c.fresh_scene) try particle_passes.simulateParticles(c.renderer, p.cmd, p.scene, c.arena, p.frame_address, c.delta_time, if (p.view_data.camera_known) device.textureIndex(p.view.depth) else null);
    }

    fn deform(c: *SceneGraph) !void {
        if (!c.pass.has_geometry) return;
        const zone = Zone.start(c.renderer.options.profiler, "deformed geometry");
        defer zone.stop();
        try geometry_passes.skinScene(c.renderer, c.pass);
    }

    fn cull(c: *SceneGraph) !void {
        c.culling = try geometry_passes.cullScene(c.renderer, c.pass, c.sun, c.lighting, c.local_shadows.draw);
    }

    fn drawVisibility(c: *SceneGraph) !void {
        const self = c.renderer;
        const p = c.pass;
        const cmd = p.cmd;
        const scene = p.scene;
        try geometry_passes.drawSceneVisibility(self, p, c.sun, &c.culling);
        if (c.first_view) {
            cmd.copyBuffer(self.cull_counts, c.count_readback, 0, 0, view_count * 2 * @sizeOf(u32));
            if (scene.seen) |seen| cmd.copyBuffer(seen, c.count_readback, @as(u64, c.instance_total) * @sizeOf(u32), view_count * 2 * @sizeOf(u32), @sizeOf(u32));
        }
        if (p.mark_seen) {
            const slot: usize = @intCast(c.frame.index % rhi.frames_in_flight);
            cmd.copyBuffer(scene.seen.?, scene.seen_readback[slot].?, 0, 0, @as(u64, c.instance_total) * @sizeOf(u32));
            scene.seen_tags[slot] = .{ .layout_version = scene.layout_version, .count = c.instance_total, .valid = true };
        }
    }

    fn sunShadows(c: *SceneGraph) !void {
        if (c.shadows_enabled) try shadow_passes.drawSunShadows(c.renderer, c.pass, c.sun);
    }

    fn virtualShadows(c: *SceneGraph) !void {
        if (c.vsm_params != 0) try virtual_shadow_passes.draw(c.renderer, c.pass, &c.culling, c.vsm_params);
    }

    fn clusterLights(c: *SceneGraph) !void {
        const self = c.renderer;
        const cmd = c.pass.cmd;
        if (c.lighting.light_count == 0 and c.pass.scene.decals.items.len == 0) return;
        cmd.beginScope("light clusters");
        cmd.bindPipeline(self.pipelines.cluster);
        cmd.pushConstants(extern struct { frame: u64, z_near: f32, z_ratio: f32 }{
            .frame = c.pass.frame_address,
            .z_near = cluster_near,
            .z_ratio = std.math.pow(f32, cluster_far / cluster_near, 1.0 / @as(f32, gpu.clusters_z)),
        });
        cmd.dispatch((gpu.cluster_count + 63) / 64, 1, 1);
        cmd.sync(.compute_to_all);
        cmd.endScope();
    }

    fn localShadows(c: *SceneGraph) !void {
        if (c.local_shadows.draw) try shadow_passes.drawLocalShadows(c.renderer, c.pass, c.lighting, c.local_shadows);
    }

    /// First pass to sample depth and the visibility buffer; picks of this
    /// view are answered here.
    fn occlusion(c: *SceneGraph) !void {
        const p = c.pass;
        p.cmd.transition(p.view.visibility, .shader_read);
        p.cmd.transition(p.view.depth, .shader_read);
        geometry_passes.recordPick(c.renderer, p);
        try shading_passes.ambientOcclusion(c.renderer, p);
    }

    fn updateProbes(c: *SceneGraph) !void {
        const self = c.renderer;
        const p = c.pass;
        const scene = p.scene;
        const volume = c.gi orelse return;
        if (scene.gi_updated_frame == self.frame_index) return;
        try gi_passes.updateGi(self, p.cmd, scene, volume, p.scene_frame, p.frame_address, p.settings, 0);
        if (scene.gi_coarse) |*coarse| {
            if (coarse.frames < 64 or self.frame_index % @max(p.settings.gi_coarse_interval, 1) == 0)
                try gi_passes.updateGi(self, p.cmd, scene, coarse, p.scene_frame, p.frame_address, p.settings, 1);
        }
        if (scene.gi_middle) |*middle| try gi_passes.updateGi(self, p.cmd, scene, middle, p.scene_frame, p.frame_address, p.settings, 2);
        scene.gi_updated_frame = self.frame_index;
    }

    fn lightmaps(c: *SceneGraph) !void {
        try lightmap_passes.bakeLightmaps(c.renderer, c.pass);
    }

    /// Optional reduced-resolution probe gather, upsampled by shading.
    fn gatherProbes(c: *SceneGraph) !void {
        const self = c.renderer;
        const p = c.pass;
        const cmd = p.cmd;
        if (c.gi == null) return;
        const texture = p.view.gi_gather orelse return;
        cmd.beginScope("gi gather");
        try cmd.beginRendering(.{ .color = &.{.{ .texture = texture, .load = .discard }} });
        cmd.bindPipeline(self.pipelines.gi_gather);
        cmd.pushConstants(extern struct { frame: u64, depth: u32, pad: u32 = 0 }{
            .frame = p.frame_address,
            .depth = self.device.textureIndex(p.view.depth),
        });
        cmd.drawFullscreen();
        cmd.endRendering();
        cmd.transition(texture, .shader_read);
        cmd.endScope();
        c.gathered_gi = texture;
    }

    fn shade(c: *SceneGraph) !void {
        c.reflections = try shading_passes.shadeScene(c.renderer, c.pass, c.lighting, c.flags, c.shadow_tlas, c.colored_shadows, c.gathered_gi);
    }

    fn clouds(c: *SceneGraph) !void {
        if (c.cloud_address != 0 and !c.pass.debugging) try volume_passes.drawClouds(c.renderer, c.pass, c.cloud_address);
    }

    fn reflect(c: *SceneGraph) !void {
        if (c.reflections) |targets| try shading_passes.drawReflections(c.renderer, c.pass, targets, c.gi != null);
    }

    fn afterOpaque(c: *SceneGraph) !void {
        const p = c.pass;
        try runPasses(c.renderer, p, .after_opaque, p.view.hdr, hdr_format, p.width, p.height);
    }

    fn impostorPictures(c: *SceneGraph) !void {
        try impostor_passes.bakeImpostors(c.renderer, c.pass);
    }

    fn impostors(c: *SceneGraph) !void {
        try impostor_passes.drawImpostors(c.renderer, c.pass);
    }

    fn hair(c: *SceneGraph) !void {
        try hair_passes.drawHair(c.renderer, c.pass);
    }

    fn liquids(c: *SceneGraph) !void {
        try transparency_passes.drawLiquids(c.renderer, c.pass);
    }

    fn water(c: *SceneGraph) !void {
        try transparency_passes.drawWater(c.renderer, c.pass);
    }

    fn transparency(c: *SceneGraph) !void {
        try transparency_passes.drawTransparency(c.renderer, c.pass);
    }

    fn smoke(c: *SceneGraph) !void {
        try volume_passes.drawFluids(c.renderer, c.pass);
    }

    fn fog(c: *SceneGraph) !void {
        if (c.pass.settings.fog_density > 0 and !c.pass.debugging) try volume_passes.drawFog(c.renderer, c.pass);
    }

    fn particles(c: *SceneGraph) !void {
        const p = c.pass;
        if (!p.debugging) try particle_passes.drawParticles(c.renderer, p.cmd, p.scene, p.view, p.frame_address, p.desc.camera.position);
    }

    fn afterTransparency(c: *SceneGraph) !void {
        const p = c.pass;
        try runPasses(c.renderer, p, .after_transparency, p.view.hdr, hdr_format, p.width, p.height);
    }

    fn trace(c: *SceneGraph) !void {
        c.path_traced = try path_tracing_pass.pathTrace(c.renderer, c.pass);
    }

    fn resolve(c: *SceneGraph) !void {
        c.resolved = try post_passes.resolveTemporal(c.renderer, c.pass, c.path_traced);
    }

    fn lens(c: *SceneGraph) !void {
        c.resolved = try post_passes.lensEffects(c.renderer, c.pass, c.resolved);
    }

    fn bloom(c: *SceneGraph) !void {
        c.bloom_count = try post_passes.bloomAndExposure(c.renderer, c.pass, c.resolved);
    }

    fn tonemap(c: *SceneGraph) !void {
        const p = c.pass;
        try post_passes.tonemapScene(c.renderer, p, c.resolved, c.bloom_count, c.target, c.target_format);
        try runPasses(c.renderer, p, .after_tonemap, c.target, c.target_format, p.output_width, p.output_height);
    }
};

/// Draws `scene` through `view` into `target` and returns the address
/// of the frame constants it used.
fn renderScene(
    self: *Renderer,
    frame: rhi.Frame,
    desc: ViewDesc,
    scene_handle: Scene,
    scene: *SceneData,
    view_data: *ViewData,
    target: rhi.Texture,
    target_format: rhi.Format,
    width: u32,
    height: u32,
    /// Size of the area of the target this view fills; differs from
    /// `width` x `height` when a render scale is set.
    output_width: u32,
    output_height: u32,
    delta_time: f32,
    arena: *FrameArena,
) !u64 {
    const device = self.device;
    const cmd = frame.cmd;
    var settings = desc.settings;
    if (settings.path_tracing and device.ray_tracing) settings.global_illumination = true;
    const first_view = self.frame_scene_views == 0;
    self.frame_scene_views += 1;

    cmd.beginScope("scene update");
    const fresh_scene = scene.prepared_frame != self.frame_index;
    if (fresh_scene) {
        scene.prepared = try prepareScene(self, scene, arena, @intCast(frame.index % rhi.frames_in_flight));
        scene.prepared_frame = self.frame_index;
    }
    const scene_frame = scene.prepared;
    try cmd.flushUploads();
    try buildPendingBlas(self, cmd, frame.index);
    cmd.endScope();

    const scales = EffectScales{
        .ao = settings.ao_resolution,
        .fog = settings.fog_resolution,
        .gi = settings.gi_resolution,
        .reflections = if (settings.screen_space_reflections) settings.reflection_resolution else null,
        .clouds = if (scene.clouds != null and settings.clouds) settings.cloud_resolution else null,
        .fluid = if (scene.fluids.items.len != 0 and settings.fluids) settings.fluid_resolution else null,
        .lens = settings.dof_aperture > 0 or settings.motion_blur > 0,
        .dof = if (settings.dof_aperture > 0 and settings.dof_resolution != .full) settings.dof_resolution else null,
        .oit = settings.transparency == .weighted,
        .peel = settings.transparency == .peeled,
        .refraction = scene.transmissive or scene.waters.items.len != 0 or scene.liquids.items.len != 0,
        .liquid = scene.liquids.items.len != 0,
        .output_width = output_width,
        .output_height = output_height,
        .fsr = settings.upscaling == .fsr,
        .temporal_upscale = (settings.upscaling == .temporal or settings.upscaling == .fsr2 or settings.upscaling == .fsr3) and settings.temporal_antialiasing and settings.debug_view == .none and (output_width > width or output_height > height),
    };
    if (view_data.state == null or view_data.state.?.width != width or view_data.state.?.height != height or
        !std.meta.eql(view_data.state.?.scales, scales))
    {
        if (view_data.state) |*old| old.deinit(device);
        view_data.state = null;
        view_data.state = try ViewState.init(device, width, height, scales);
        view_data.upscaler_refused = null;
        view_data.exposure_reset = true;
        view_data.camera_known = false;
    }
    const view = &view_data.state.?;
    if (view_data.last_frame +% 1 != self.frame_index) {
        view_data.camera_known = false;
        view.history_valid = false;
        view.ao_history_valid = false;
        if (view.reflections) |*targets| targets.history_valid = false;
        if (view.clouds) |*targets| targets.history_valid = false;
    }

    const aspect = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));
    const view_matrix = math.lookTo(desc.camera.position, desc.camera.forward, desc.camera.up);
    var proj_unjittered = math.perspective(desc.camera.fov_y, aspect, desc.camera.near);
    const lens_shift = [2]f32{ desc.camera.lens_shift[0] / aspect, desc.camera.lens_shift[1] };
    proj_unjittered[8] = -lens_shift[0];
    proj_unjittered[9] = -lens_shift[1];
    var jitter: [2]f32 = .{ 0, 0 };
    var proj = proj_unjittered;
    const debugging = settings.debug_view != .none;
    if (settings.temporal_antialiasing and !debugging) {
        const upscale_area = @as(f32, @floatFromInt(output_width)) * @as(f32, @floatFromInt(output_height)) / (@as(f32, @floatFromInt(width)) * @as(f32, @floatFromInt(height)));
        const jitter_count: u64 = if ((settings.upscaling == .temporal or settings.upscaling == .fsr2 or settings.upscaling == .fsr3) and upscale_area > 1) @intFromFloat(@min(@ceil(8 * upscale_area), 64)) else 8;
        const sample: u32 = @intCast(view_data.frames % jitter_count + 1);
        const offset = [2]f32{ halton(sample, 2) - 0.5, halton(sample, 3) - 0.5 };
        jitter = .{ offset[0] / @as(f32, @floatFromInt(width)), offset[1] / @as(f32, @floatFromInt(height)) };
        proj[8] -= 2 * jitter[0];
        proj[9] -= 2 * jitter[1];
    }
    const view_proj = math.mul(proj, view_matrix);
    const view_proj_unjittered = math.mul(proj_unjittered, view_matrix);
    {
        var since: Vec3 = undefined;
        inline for (0..3) |axis| since[axis] = @floatCast(view_data.scene_origin[axis] - scene.origin[axis]);
        if (since[0] != 0 or since[1] != 0 or since[2] != 0)
            view_data.previous_view_proj = math.mul(view_data.previous_view_proj, math.translation(math.scale(since, -1)));
        view_data.scene_origin = scene.origin;
    }
    if (!view_data.camera_known) view_data.previous_view_proj = view_proj_unjittered;

    const sun_travel = math.normalize(scene.sun.direction);
    const sun_enabled = scene.sun.intensity > 0 and math.dot(sun_travel, sun_travel) > 0.5;
    const shadows_enabled = settings.shadows and sun_enabled and scene.ref_count != 0;
    const has_geometry = scene.ref_count != 0;
    const instance_total: u32 = @as(u32, @intCast(scene.layout.items.len)) + scene.static_count;
    const mark_seen = has_geometry and instance_total != 0 and
        (if (self.options.texture_streaming) |streaming| streaming.skip_occluded else false);
    const lod_scale: f32 = if (settings.lod_error_pixels > 0)
        @abs(proj_unjittered[5]) * @as(f32, @floatFromInt(height)) * 0.5 / settings.lod_error_pixels
    else
        0;
    var pass = ScenePass{
        .frame = frame,
        .cmd = cmd,
        .arena = arena,
        .desc = desc,
        .settings = settings,
        .scene_handle = scene_handle,
        .scene = scene,
        .scene_frame = scene_frame,
        .fresh_scene = fresh_scene,
        .view_data = view_data,
        .view = view,
        .width = width,
        .height = height,
        .output_width = output_width,
        .output_height = output_height,
        .fills_backbuffer = if (frame.backbuffer) |backbuffer|
            std.meta.eql(backbuffer, target) and std.meta.eql(device.backbufferSize(), .{ output_width, output_height })
        else
            false,
        .delta_time = delta_time,
        .debugging = debugging,
        .aspect = aspect,
        .view_matrix = view_matrix,
        .proj_unjittered = proj_unjittered,
        .jitter = jitter,
        .view_proj = view_proj,
        .view_proj_unjittered = view_proj_unjittered,
        .sun_travel = sun_travel,
        .has_geometry = has_geometry,
        .occlusion = settings.occlusion_culling and has_geometry,
        .mark_seen = mark_seen,
        .lod = .{ desc.camera.position[0], desc.camera.position[1], desc.camera.position[2], lod_scale },
        .lod_band = if (lod_scale > 0) 1 + std.math.clamp(settings.lod_cross_fade, 0, 1) else 1,
    };
    const colored_shadows = shadows_enabled and settings.colored_shadows and settings.transparent_shadows;
    if (colored_shadows and view_data.shadow_color == null) {
        view_data.shadow_color = try device.createTexture(.{
            .name = "shadow tint",
            .width = @max(self.options.shadow_resolution / 2, 1),
            .height = @max(self.options.shadow_resolution / 2, 1),
            .format = .rgba8_unorm,
            .usage = .{ .sampled = true, .color_attachment = true },
            .layers = gpu.cascade_count,
            .kind = .@"2d_array",
        });
    }
    if (view_data.shadows_colored != colored_shadows) {
        view_data.shadows_colored = colored_shadows;
        view_data.cascade_cache.valid = false;
    }
    const cascade_plan = shadow_passes.updateCascades(self, &pass, shadows_enabled);
    const cascades = view_data.cascade_cache.cascades;
    if (shadows_enabled and view_data.shadow_map == null) {
        view_data.shadow_map = try device.createTexture(.{
            .name = "shadow cascades",
            .width = self.options.shadow_resolution,
            .height = self.options.shadow_resolution,
            .format = .depth32_float,
            .usage = .{ .sampled = true, .depth_attachment = true },
            .layers = gpu.cascade_count,
            .kind = .@"2d_array",
        });
    }
    const shadow_map = if (shadows_enabled) view_data.shadow_map.? else self.shadow_map;
    const sun_shadows = SunShadows{
        .enabled = shadows_enabled,
        .colored = colored_shadows,
        .map = shadow_map,
        .cascades = cascades,
        .count = cascade_plan.count,
        .update = cascade_plan.update,
    };

    const environment: ?*EnvironmentEntry = blk: {
        const entry = self.environments.table.get(scene.environment orelse break :blk null) orelse break :blk null;
        break :blk if (entry.state == .ready) entry else null;
    };

    const gi = try gi_passes.prepareGi(self, scene, scene_frame, settings, desc.camera.position);
    const gi_coarse: ?*const GiVolume = if (gi != null) (if (scene.gi_coarse) |*volume| volume else null) else null;
    const gi_middle: ?*const GiVolume = if (gi_coarse != null) (if (scene.gi_middle) |*volume| volume else null) else null;
    const traced_shadows = settings.ray_traced_light_shadows and gi != null and device.ray_tracing and scene.tlas != null;
    const lighting = try prepareLights(self, scene, arena, settings.shadows, desc.camera.position, traced_shadows);
    const local_shadows = shadow_passes.planLocalShadows(self, &pass, &lighting);
    const cloud_address = try volume_passes.prepareClouds(self, &pass);
    var flags: u32 = 0;
    if (shadows_enabled) flags |= gpu.frame_shadows;
    const vsm_params: u64 = if (shadows_enabled and settings.virtual_shadow_maps and !debugging) try virtual_shadow_passes.prepare(self, &pass, sun_travel) else 0;
    if (vsm_params != 0) flags |= gpu.frame_vsm;
    if (settings.ambient_occlusion) flags |= gpu.frame_ambient_occlusion;
    if (environment != null) flags |= gpu.frame_environment;
    if (gi != null) flags |= gpu.frame_gi;
    if (settings.temporal_antialiasing and !debugging) flags |= gpu.frame_temporal;
    if (settings.specular_antialiasing) flags |= gpu.frame_specular_aa;
    if (settings.screen_space_reflections and !debugging) flags |= gpu.frame_ssr;
    if (settings.gi_local_lights) flags |= gpu.frame_gi_local_lights;
    flags |= std.math.clamp(settings.light_shadow_rays, 1, 15) << 16;
    flags |= std.math.clamp(settings.gi_bounce_lights, 1, 1023) << 20;
    const probes = try shading_passes.reflectionProbeList(self, &pass);
    const fluid_list = try arena.alloc(device, gpu.FluidList, 1);
    fluid_list.items[0] = .{};
    if (settings.fluid_shadows and scene.fluids.items.len != 0) flags |= gpu.frame_fluid_shadows;
    if (colored_shadows) flags |= gpu.frame_colored_shadows;
    if (settings.reflect_transparent) flags |= gpu.frame_reflect_transparent;
    if (settings.fluid_rays and scene.fluids.items.len != 0) flags |= gpu.frame_fluid_rays;
    if (cloud_address != 0 and scene.clouds.?.shadow > 0) flags |= gpu.frame_cloud_shadows;

    const decals_address = try shading_passes.writeDecals(self, &pass);
    const constants = try arena.alloc(device, gpu.FrameConstants, 1);
    const shadow_tlas: u64 = if (traced_shadows) device.accelerationAddress(scene.tlas.?) else 0;
    constants.items[0] = .{
        .view = view_matrix,
        .proj = proj,
        .view_proj = view_proj,
        .inv_view_proj = math.inverse(view_proj),
        .view_proj_unjittered = view_proj_unjittered,
        .prev_view_proj_unjittered = view_data.previous_view_proj,
        .inv_view = math.inverse(view_matrix),
        .inv_proj = math.inverse(proj),
        .cascade_view_proj = cascades.view_proj,
        .cascade_splits = cascades.splits,
        .cascade_texel_size = cascades.texel_size,
        .camera_position = desc.camera.position,
        .near = desc.camera.near,
        .sun_direction = math.scale(sun_travel, -1),
        .shadow_softness = settings.shadow_softness,
        .sun_radiance = if (sun_enabled) math.scale(scene.sun.color, scene.sun.intensity) else .{ 0, 0, 0 },
        .env_intensity = scene.environment_intensity,
        .resolution = .{ @floatFromInt(width), @floatFromInt(height) },
        .inv_resolution = .{ 1.0 / @as(f32, @floatFromInt(width)), 1.0 / @as(f32, @floatFromInt(height)) },
        .jitter = jitter,
        .prev_jitter = view_data.previous_jitter,
        .frame_index = @truncate(self.frame_index),
        .time = self.time,
        .delta_time = delta_time,
        .flags = flags,
        .shadow_map = device.textureIndex(shadow_map),
        .shadow_sampler = device.samplerIndex(self.sampler_shadow),
        .env_specular = if (environment) |entry| device.textureIndex(entry.specular.?) else gpu.invalid_id,
        .env_irradiance = if (environment) |entry| device.textureIndex(entry.irradiance.?) else gpu.invalid_id,
        .env_sky = if (environment) |entry| device.textureIndex(entry.sky.?) else gpu.invalid_id,
        .brdf_lut = device.textureIndex(self.brdf_lut),
        .sampler_linear_clamp = device.samplerIndex(self.sampler_linear_clamp),
        .sampler_nearest_clamp = device.samplerIndex(self.sampler_nearest_clamp),
        .env_specular_mips = env_specular_mips,
        .light_count = lighting.light_count,
        .sampler_linear_repeat = device.samplerIndex(self.sampler_linear_repeat),
        .local_shadow_map = device.textureIndex(self.local_shadow_map),
        .local_shadow_sampler = device.samplerIndex(self.sampler_local_shadow),
        .cluster_z_scale = cluster_z_scale,
        .cluster_z_bias = -@log2(cluster_near) * cluster_z_scale,
        .gi_origin = if (gi) |volume| volume.origin else .{ 0, 0, 0 },
        .gi_spacing = if (gi) |volume| volume.spacing else 1,
        .gi_counts = if (gi) |volume| .{ @intCast(volume.counts[0]), @intCast(volume.counts[1]), @intCast(volume.counts[2]) } else .{ 2, 2, 2 },
        .gi_irradiance = if (gi) |volume| device.textureIndex(volume.irradiance) else gpu.invalid_id,
        .gi_visibility = if (gi) |volume| device.textureIndex(volume.visibility) else gpu.invalid_id,
        .gi_intensity = settings.gi_intensity,
        .gi_scroll = if (gi) |volume| giScroll(volume) else 0,
        .gi_offsets = if (gi) |volume| (if (settings.gi_probe_relocation and volume.offsets_valid) device.textureIndex(volume.offsets[volume.offset_turn]) else gpu.invalid_id) else gpu.invalid_id,
        .gi2_origin = if (gi_coarse) |volume| volume.origin else .{ 0, 0, 0 },
        .gi2_spacing = if (gi_coarse) |volume| volume.spacing else 1,
        .gi2_counts = if (gi_coarse) |volume| .{ @intCast(volume.counts[0]), @intCast(volume.counts[1]), @intCast(volume.counts[2]) } else .{ 2, 2, 2 },
        .gi2_irradiance = if (gi_coarse) |volume| device.textureIndex(volume.irradiance) else gpu.invalid_id,
        .gi2_visibility = if (gi_coarse) |volume| device.textureIndex(volume.visibility) else gpu.invalid_id,
        .gi2_scroll = if (gi_coarse) |volume| giScroll(volume) else 0,
        .gi3_origin = if (gi_middle) |volume| volume.origin else .{ 0, 0, 0 },
        .gi3_spacing = if (gi_middle) |volume| volume.spacing else 1,
        .gi3_counts = if (gi_middle) |volume| .{ @intCast(volume.counts[0]), @intCast(volume.counts[1]), @intCast(volume.counts[2]) } else .{ 2, 2, 2 },
        .gi3_irradiance = if (gi_middle) |volume| device.textureIndex(volume.irradiance) else gpu.invalid_id,
        .gi3_visibility = if (gi_middle) |volume| device.textureIndex(volume.visibility) else gpu.invalid_id,
        .gi3_scroll = if (gi_middle) |volume| giScroll(volume) else 0,
        .gi3_offsets = if (gi_middle) |volume| (if (settings.gi_probe_relocation and volume.offsets_valid) device.textureIndex(volume.offsets[volume.offset_turn]) else gpu.invalid_id) else gpu.invalid_id,
        .gi2_offsets = if (gi_coarse) |volume| (if (settings.gi_probe_relocation and volume.offsets_valid) device.textureIndex(volume.offsets[volume.offset_turn]) else gpu.invalid_id) else gpu.invalid_id,
        .shadow_taps = settings.shadow_samples,
        .contact_depth = if (!debugging) device.textureIndex(view.depth) else gpu.invalid_id,
        .contact_length = @max(settings.contact_shadows, 0),
        .tlas_low = @truncate(shadow_tlas),
        .tlas_high = @truncate(shadow_tlas >> 32),
        .aerial = if (settings.aerial_model == .sky) -@max(settings.aerial_perspective, 0) else @max(settings.aerial_perspective, 0),
        .shadow_color = if (colored_shadows) device.textureIndex(view_data.shadow_color.?) else gpu.invalid_id,
        .texture_gradient_scale = if (settings.temporal_antialiasing and !debugging) std.math.pow(f32, 2, std.math.clamp(settings.texture_mip_bias, -2, 2)) else 1,
        .vertices = device.bufferAddress(self.vertices.buffer),
        .indices = device.bufferAddress(self.indices.buffer),
        .meshlets = device.bufferAddress(self.meshlets.buffer),
        .meshes = device.bufferAddress(self.meshes.buffer),
        .materials = device.bufferAddress(self.materials.pool.buffer),
        .instances = scene_frame.instances,
        .previous_transforms = scene_frame.previous_transforms,
        .vsm = vsm_params,
        .meshlet_refs = if (scene.refs) |buffer| device.bufferAddress(buffer) else 0,
        .lights = lighting.lights,
        .clusters = device.bufferAddress(self.clusters),
        .shadow_tiles = lighting.tiles,
        .decal_count = @intCast(scene.decals.items.len),
        .decals = decals_address,
        .clouds = cloud_address,
        .fluids = fluid_list.address,
        .probes = probes.address,
        .probe_count = probes.count,
        .exposure = device.bufferAddress(view_data.exposure),
    };
    const frame_address = constants.address;
    pass.frame_address = frame_address;

    const count_readback = self.count_readback[@intCast(frame.index % rhi.frames_in_flight)];
    if (first_view) {
        const counted = device.mappedSlice(u32, count_readback);
        self.stats.meshlets_drawn = counted[0] + counted[1] + counted[main_late_view * 2] + counted[main_late_view * 2 + 1];
        self.stats.shadow_meshlets_drawn = 0;
        for (1..1 + gpu.cascade_count) |index| self.stats.shadow_meshlets_drawn += counted[index * 2] + counted[index * 2 + 1];
        self.stats.instances_drawn = counted[view_count * 2];
    }

    var graph = SceneGraph{
        .renderer = self,
        .pass = &pass,
        .frame = frame,
        .arena = arena,
        .delta_time = delta_time,
        .sun = &sun_shadows,
        .lighting = &lighting,
        .local_shadows = &local_shadows,
        .gi = gi,
        .flags = flags,
        .shadow_tlas = shadow_tlas,
        .colored_shadows = colored_shadows,
        .cloud_address = cloud_address,
        .fluid_list = &fluid_list.items[0],
        .shadows_enabled = shadows_enabled,
        .first_view = first_view,
        .fresh_scene = fresh_scene,
        .instance_total = instance_total,
        .count_readback = count_readback,
        .target = target,
        .target_format = target_format,
        .vsm_params = vsm_params,
    };
    try graph.run();
    view_data.path_traced = graph.path_traced;

    view_data.previous_view_proj = view_proj_unjittered;
    view_data.previous_jitter = jitter;
    view_data.frames += 1;
    view_data.last_frame = self.frame_index;
    view_data.camera_known = true;
    if (first_view) {
        self.stats.instances = instance_total;
        self.stats.meshlets = scene.ref_count;
        self.stats.triangles = scene.triangle_count;
        self.stats.skinned_vertices = scene_frame.skinned_vertices;
    }
    return frame_address;
}

/// Runs the application's passes for `stage`, which draw into `color`.
fn runPasses(self: *Renderer, p: *const ScenePass, stage: PassStage, color: rhi.Texture, color_format: rhi.Format, width: u32, height: u32) !void {
    const cmd = p.cmd;
    var ran = false;
    for (p.desc.passes) |pass| {
        if (pass.stage != stage) continue;
        cmd.beginScope("custom pass");
        defer cmd.endScope();
        try pass.run(pass.context, .{
            .cmd = cmd,
            .device = self.device,
            .stage = stage,
            .frame = p.frame_address,
            .color = color,
            .color_format = color_format,
            .depth = p.view.depth,
            .motion = p.view.motion,
            .width = width,
            .height = height,
        });
        ran = true;
    }
    if (!ran) return;
    if (stage != .after_tonemap) cmd.transition(color, .shader_read);
    cmd.transition(p.view.depth, .shader_read);
    cmd.transition(p.view.motion, .shader_read);
}
