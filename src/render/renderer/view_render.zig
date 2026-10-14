//! Drawing one view: its scene and draw lists through a graph of passes. Internal to the renderer.
const std = @import("std");
const upscaling = @import("../techniques/upscaling.zig");
const shadows_feature = @import("../features/shadows.zig");
const shading_feature = @import("../features/shading.zig");
const clouds_feature = @import("../features/clouds.zig");
const post_feature = @import("../features/post.zig");
const global_illumination_feature = @import("../features/global_illumination.zig");
const filled = @import("../api.zig").filled;
const rhi = @import("../../rhi/rhi.zig");
const math = @import("../../math.zig");
const gpu = @import("../gpu.zig");
const api = @import("../api.zig");
const renderer_state = @import("../state.zig");
const scene_pass = @import("../scene_pass.zig");
const graph_module = @import("../core/graph.zig");
const features = @import("../core/features.zig");
const canvas = @import("../features/canvas.zig");
const post = @import("../features/post.zig");
const ray_scene = @import("../scene/ray_scene.zig");
const render = @import("../renderer.zig");

const Renderer = render.Renderer;
const Vec3 = math.Vec3;
const Graph = graph_module.Graph;
const ViewContext = features.ViewContext;
const ScenePass = scene_pass.ScenePass;
const SunShadows = scene_pass.SunShadows;
const Lighting = scene_pass.Lighting;
const Scene = api.Scene;
const Zone = renderer_state.Zone;
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
const ReflectionTargets = renderer_state.ReflectionTargets;
const buildPendingBlas = @import("scene_update.zig").buildPendingBlas;
const view_math = @import("view_math.zig");
const halton = @import("view_math.zig").halton;
const prepareLights = @import("scene_update.zig").prepareLights;
const prepareScene = @import("scene_update.zig").prepareScene;
const applySceneUpdate = @import("scene_update.zig").applySceneUpdate;
const targetWritten = @import("views.zig").targetWritten;

/// Copies the picture of a view that fills part of its target into place.
const Composite = struct {
    ctx: *ViewContext,
    picture: rhi.Texture,
    format: rhi.Format,
    region: Region,

    fn run(self: *Composite) !void {
        const ctx = self.ctx;
        const cmd = ctx.cmd;
        cmd.setViewport(self.region.x, self.region.y, self.region.width, self.region.height);
        cmd.bindPipeline(try post_feature.tonemapPipeline(ctx.renderer, self.format));
        cmd.pushConstants(post_feature.TonemapPush{
            .frame = ctx.frame_address,
            .color = ctx.device.textureIndex(self.picture),
            .bloom = gpu.invalid_id,
            .bloom_strength = 0,
            .encode_srgb = 0,
            .sharpen = 0,
            .bloom_scale = 0,
            .passthrough = 1,
            .origin = .{ @intCast(self.region.x), @intCast(self.region.y) },
        });
        cmd.drawFullscreen();
    }
};

pub fn renderView(self: *Renderer, frame: rhi.Frame, requested: ViewDesc, delta_time: f32, arena: *FrameArena) !void {
    const view_zone = Zone.start(self.options.profiler, "render view");
    defer view_zone.stop();
    const device = self.device;
    const cmd = frame.cmd;
    var desc = requested;
    var resolving = features.Resolve{
        .caps = device.caps,
        .scene = desc.scene != null,
        .debugging = desc.settings.debug_view != .none,
        .temporal_antialiasing = desc.settings.resolution.temporal_antialiasing,
        .orthographic = desc.camera.orthographic != null,
        .upscalers = upscaling.Availability.of(device, self.dlss),
        .nrd = @import("../nrd.zig").available and device.caps.storage_images,
        .upscaler = desc.settings.resolution.upscaler,
        .path_tracing = self.pathTracing(),
        .downgrades = &self.downgrades,
    };
    features.resolve(&desc.settings, &resolving);
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

    var graph: Graph = undefined;
    graph.clear();
    var scratch_bytes: [16 << 10]u8 align(16) = undefined;
    var scratch = std.heap.FixedBufferAllocator.init(&scratch_bytes);
    var constants: gpu.FrameConstants = undefined;
    var ctx = ViewContext{
        .renderer = self,
        .device = device,
        .cmd = cmd,
        .arena = arena,
        .graph = &graph,
        .scratch = scratch.allocator(),
        .desc = &desc,
        .settings = &desc.settings,
        .view = null,
        .output = .{ .texture = target, .format = info.format, .region = region, .load = load, .clear = desc.clear_color },
        .constants = &constants,
        .frame_address = 0,
    };

    if (desc.scene) |scene_handle| {
        try self.ensureSceneResources(cmd);
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
        ctx.view = view;
        ctx.output = .{
            .texture = color,
            .format = info.format,
            .region = .{ .x = 0, .y = 0, .width = region.width, .height = region.height },
            .load = .load,
            .clear = desc.clear_color,
        };
        const picture = try graph.import(color);
        graph.publish(.picture, picture);
        graph.want(picture);
        var composite = Composite{ .ctx = &ctx, .picture = color, .format = info.format, .region = region };
        if (!whole) try graph.add(.{
            .name = "view composite",
            .stage = .present,
            .reads = &.{picture},
            .color = &.{.{ .target = try graph.import(target), .load = load, .clear = desc.clear_color }},
            .always = true,
        }, &composite, Composite.run);
        const render_scale = std.math.clamp(desc.settings.resolution.scale, 0.25, 2);
        const internal_width: u32 = @max(@as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(region.width)) * render_scale))), 1);
        const internal_height: u32 = @max(@as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(region.height)) * render_scale))), 1);
        try renderScene(self, &ctx, frame, scene_handle, scene, view, color, internal_width, internal_height, region.width, region.height, delta_time);
        view.kept.collect(device, self.frame_index);
    } else {
        const picture = try graph.import(target);
        graph.publish(.picture, picture);
        graph.want(picture);
        if (canvas.lit(&desc)) {
            const view = self.views.table.get(desc.view orelse self.main_view) orelse return error.InvalidView;
            if (view.last_frame == self.frame_index) return error.ViewUsedTwice;
            if (view.last_frame +% 1 != self.frame_index) view.exposure_reset = true;
            view.last_frame = self.frame_index;
            ctx.view = view;
            const frame_constants = try arena.alloc(device, gpu.FrameConstants, 1);
            constants = std.mem.zeroes(gpu.FrameConstants);
            constants.resolution = .{ @floatFromInt(region.width), @floatFromInt(region.height) };
            constants.inv_resolution = .{ 1.0 / @as(f32, @floatFromInt(region.width)), 1.0 / @as(f32, @floatFromInt(region.height)) };
            constants.near = desc.camera.near;
            constants.depth_terms = view_math.depthTerms(desc.camera);
            constants.frame_index = @truncate(self.frame_index);
            constants.time = self.time;
            constants.delta_time = delta_time;
            constants.sampler_linear_clamp = device.samplerIndex(self.sampler_linear_clamp);
            constants.sampler_nearest_clamp = device.samplerIndex(self.sampler_nearest_clamp);
            constants.sampler_linear_repeat = device.samplerIndex(self.sampler_linear_repeat);
            constants.exposure = device.bufferAddress(view.exposure);
            ctx.frame_address = frame_constants.address;
            const hdr = try graph.transient(.{ .name = "hdr", .width = region.width, .height = region.height, .format = hdr_format, .usage = .{ .sampled = true, .color_attachment = true } });
            graph.publish(.hdr, hdr);
            try post.declareFlat(&ctx, hdr);
            try features.declare(&ctx);
            frame_constants.items[0] = constants;
            try graph.execute(self.gpa, device, cmd, &self.target_pool, self.frame_index);
            view.kept.collect(device, self.frame_index);
        } else {
            if (desc.passes.len != 0 and ctx.output.load == .clear) {
                try graph.add(.{ .name = "clear", .stage = .prepare, .color = &.{.{ .target = picture, .load = .clear, .clear = ctx.output.clear }}, .always = true, .scope = false }, &ctx, cleared);
                ctx.output.load = .load;
            }
            try features.declare(&ctx);
            try graph.execute(self.gpa, device, cmd, &self.target_pool, self.frame_index);
        }
    }
    if (desc.target == .texture) cmd.transition(target, .shader_read);
}

fn cleared(_: *ViewContext) !void {}

/// Draws `scene` through `view` into `target`, with the view's draw lists.
fn renderScene(
    self: *Renderer,
    ctx: *ViewContext,
    frame: rhi.Frame,
    scene_handle: Scene,
    scene: *SceneData,
    view_data: *ViewData,
    target: rhi.Texture,
    width: u32,
    height: u32,
    /// Size of the area of the target this view fills; differs from
    /// `width` x `height` when a render scale is set.
    output_width: u32,
    output_height: u32,
    delta_time: f32,
) !void {
    const device = self.device;
    const cmd = frame.cmd;
    const desc = ctx.desc.*;
    const arena = ctx.arena;
    const settings = desc.settings;
    const first_view = self.frame_scene_views == 0;
    self.frame_scene_views += 1;

    cmd.beginScope("scene update");
    const fresh_scene = scene.prepared_frame != self.frame_index;
    if (fresh_scene) {
        scene.prepared = try prepareScene(self, scene, arena);
        scene.prepared_frame = self.frame_index;
        try applySceneUpdate(self, cmd, scene, scene.prepared.update);
    }
    const scene_frame = scene.prepared;
    try cmd.flushUploads();
    try buildPendingBlas(self, cmd, frame.index);
    cmd.endScope();

    const temporal_upscale = (settings.resolution.upscaler == .temporal or settings.resolution.upscaler == .fsr2 or settings.resolution.upscaler == .fsr3 or settings.resolution.upscaler == .dlss) and settings.resolution.temporal_antialiasing and settings.debug_view == .none and (output_width > width or output_height > height);
    const resolved_width = if (temporal_upscale) output_width else width;
    const resolved_height = if (temporal_upscale) output_height else height;
    if (view_data.state == null or view_data.state.?.width != width or view_data.state.?.height != height or
        view_data.state.?.resolved_width != resolved_width or view_data.state.?.resolved_height != resolved_height)
    {
        if (view_data.state) |*old| old.deinit(device);
        view_data.state = null;
        view_data.state = try ViewState.init(device, width, height, resolved_width, resolved_height);
        view_data.upscaler.forgive();
        view_data.exposure_reset = true;
        view_data.camera_known = false;
    }
    const view = &view_data.state.?;
    std.mem.swap(rhi.Texture, &view.depth, &view.previous_depth);
    std.mem.swap(rhi.Texture, &view.motion, &view.previous_motion);
    if (view_data.last_frame +% 1 != self.frame_index) {
        view_data.camera_known = false;
        view.history_valid = false;
    }

    const aspect = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));
    const view_matrix = math.lookTo(desc.camera.position, desc.camera.forward, desc.camera.up);
    const proj_unjittered = view_math.cameraProjection(desc.camera, aspect);
    const vantage = view_math.vantage(desc.camera);
    var jitter: [2]f32 = .{ 0, 0 };
    var proj = proj_unjittered;
    const debugging = settings.debug_view != .none;
    if (settings.resolution.temporal_antialiasing and !debugging) {
        const upscale_area = @as(f32, @floatFromInt(output_width)) * @as(f32, @floatFromInt(output_height)) / (@as(f32, @floatFromInt(width)) * @as(f32, @floatFromInt(height)));
        const jitter_count: u64 = if ((settings.resolution.upscaler == .temporal or settings.resolution.upscaler == .fsr2 or settings.resolution.upscaler == .fsr3 or settings.resolution.upscaler == .dlss) and upscale_area > 1) @intFromFloat(@min(@ceil(8 * upscale_area), 64)) else 8;
        const sample: u32 = @intCast(view_data.frames % jitter_count + 1);
        const offset = [2]f32{ halton(sample, 2) - 0.5, halton(sample, 3) - 0.5 };
        jitter = .{ offset[0] / @as(f32, @floatFromInt(width)), offset[1] / @as(f32, @floatFromInt(height)) };
        proj = view_math.shifted(proj, desc.camera, .{ 2 * jitter[0], 2 * jitter[1] });
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
    const shadows_enabled = (settings.shadows != null) and sun_enabled and scene.ref_count != 0;
    const has_geometry = scene.ref_count != 0;
    const instance_total: u32 = @as(u32, @intCast(scene.layout.items.len)) + scene.static_count;
    const mark_seen = has_geometry and instance_total != 0 and
        (if (self.options.textures.streaming) |streaming| streaming.skip_occluded else false);
    const lod_scale: f32 = if (settings.geometry.lod_error_pixels > 0)
        @abs(proj_unjittered[5]) * @as(f32, @floatFromInt(height)) * 0.5 / settings.geometry.lod_error_pixels * vantage.scale
    else
        0;
    var culling: scene_pass.CullState = undefined;
    var resolved: rhi.Texture = undefined;
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
        .resolved_width = resolved_width,
        .resolved_height = resolved_height,
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
        .occlusion = settings.geometry.occlusion_culling and has_geometry,
        .mark_seen = mark_seen,
        .lod = .{ vantage.position[0], vantage.position[1], vantage.position[2], lod_scale },
        .lod_band = if (lod_scale > 0) 1 + std.math.clamp(settings.geometry.lod_cross_fade, 0, 1) else 1,
        .sun_shadows = shadows_enabled,
        .culling = &culling,
        .resolved = &resolved,
    };
    const colored_shadows = shadows_enabled and filled(settings.shadows).colored and filled(settings.shadows).transparent;
    if (colored_shadows and view_data.shadow_color == null) {
        view_data.shadow_color = try device.createTexture(.{
            .name = "shadow tint",
            .width = @max(self.options.shadows.resolution / 2, 1),
            .height = @max(self.options.shadows.resolution / 2, 1),
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
    const cascade_plan = shadows_feature.updateCascades(self, &pass, shadows_enabled);
    const cascades = view_data.cascade_cache.cascades;
    if (shadows_enabled and view_data.shadow_map == null) {
        view_data.shadow_map = try device.createTexture(.{
            .name = "shadow cascades",
            .width = self.options.shadows.resolution,
            .height = self.options.shadows.resolution,
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

    try ray_scene.prepare(self, scene, scene_frame, ray_scene.wanted(self, scene, settings), fresh_scene);
    const gi = try global_illumination_feature.prepareGi(self, scene, scene_frame, settings, desc.camera.position);
    const traced_shadows = (if (settings.shadows) |shadows| shadows.traced_lights else false) and ray_scene.ready(scene, scene_frame);
    const lighting = try prepareLights(self, scene, arena, (settings.shadows != null), desc.camera.position, traced_shadows);
    const local_shadows = shadows_feature.planLocalShadows(self, &pass, &lighting);
    const cloud_address = try clouds_feature.prepareClouds(self, &pass);
    var flags: u32 = 0;
    if (shadows_enabled) flags |= gpu.frame_flags.shadows;
    if (environment != null) flags |= gpu.frame_flags.environment;
    const probes = try shading_feature.reflectionProbeList(self, &pass);
    const fluid_list = try arena.alloc(device, gpu.FluidList, 1);
    fluid_list.items[0] = .{};
    if (colored_shadows) flags |= gpu.frame_flags.colored_shadows;
    if (cloud_address != 0 and scene.clouds.?.shadow > 0) flags |= gpu.frame_flags.cloud_shadows;

    const decals_address = try shading_feature.writeDecals(self, &pass);
    const constants = try arena.alloc(device, gpu.FrameConstants, 1);
    const shadow_tlas: u64 = if (traced_shadows) device.accelerationAddress(scene.tlas.?) else 0;
    ctx.constants.* = .{
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
        .depth_terms = view_math.depthTerms(desc.camera),
        .eye_axis = math.normalize(desc.camera.forward),
        .parallel = @floatFromInt(@intFromBool(desc.camera.orthographic != null)),
        .sun_direction = math.scale(sun_travel, -1),
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
        .contact_depth = if (!debugging) device.textureIndex(view.depth) else gpu.invalid_id,
        .tlas_low = @truncate(shadow_tlas),
        .tlas_high = @truncate(shadow_tlas >> 32),
        .shadow_color = if (colored_shadows) device.textureIndex(view_data.shadow_color.?) else gpu.invalid_id,
        .vertices = device.bufferAddress(self.vertices.get()),
        .indices = device.bufferAddress(self.indices.get()),
        .meshlets = device.bufferAddress(self.meshlets.get()),
        .meshes = device.bufferAddress(self.meshes.get()),
        .materials = device.bufferAddress(self.materials.pool.get()),
        .instances = scene_frame.instances,
        .previous_transforms = scene_frame.previous_transforms,
        .vsm = 0,
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
    pass.frame_address = constants.address;
    ctx.frame_address = constants.address;
    ctx.scene = &pass;
    ctx.output.depth = view.depth;
    const g = ctx.graph;
    g.publish(.depth, try g.import(view.depth));
    g.publish(.visibility, try g.import(view.visibility));
    g.publish(.motion, try g.import(view.motion));
    g.publish(.hdr, try g.import(view.hdr));
    const count_readback = self.count_readback[@intCast(frame.index % rhi.frames_in_flight)];
    if (first_view) {
        const counted = device.mappedSlice(u32, count_readback);
        self.stats.meshlets_drawn = counted[0] + counted[1] + counted[main_late_view * 2] + counted[main_late_view * 2 + 1];
        self.stats.shadow_meshlets_drawn = 0;
        for (1..1 + gpu.cascade_count) |index| self.stats.shadow_meshlets_drawn += counted[index * 2] + counted[index * 2 + 1];
        self.stats.instances_drawn = counted[view_count * 2];
    }

    var shared = scene_pass.Shared{
        .frame = frame,
        .arena = arena,
        .delta_time = delta_time,
        .sun = &sun_shadows,
        .lighting = &lighting,
        .local_shadows = &local_shadows,
        .gi = gi,
        .shadow_tlas = shadow_tlas,
        .colored_shadows = colored_shadows,
        .cloud_address = cloud_address,
        .fluid_list = &fluid_list.items[0],
        .shadows_enabled = shadows_enabled,
        .first_view = first_view,
        .fresh_scene = fresh_scene,
        .instance_total = instance_total,
        .count_readback = count_readback,
        .culling = &culling,
        .resolved = &resolved,
    };
    pass.shared = &shared;
    pass.tracing = settings.path_tracing != null and !debugging and view_data.path_traced;
    try features.declare(ctx);
    constants.items[0] = ctx.constants.*;
    try g.execute(self.gpa, device, cmd, &self.target_pool, self.frame_index);
    view_data.path_traced = shared.path_traced;

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
}
