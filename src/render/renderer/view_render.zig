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
const path_tracing_feature = @import("../features/path_tracing.zig");
const resolution_feature = @import("../features/resolution.zig");
const canvas = @import("../features/canvas.zig");
const post = @import("../features/post.zig");
const ray_scene = @import("../scene/ray_scene.zig");
const render = @import("../renderer.zig");
const ensureSceneResources = render.ensureSceneResources;

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
const buildPendingBlas = @import("../scene/ray_scene.zig").buildPendingBlas;
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
            .color_texture = ctx.device.textureIndex(self.picture),
            .bloom_texture = gpu.invalid_id,
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

/// A view planned for this frame by `stageView`, and everything its passes
/// point at until `recordView` and `finishView` are done with it.
pub const StagedView = struct {
    desc: ViewDesc = undefined,
    graph: Graph = undefined,
    scratch_bytes: [16 << 10]u8 align(16) = undefined,
    scratch: std.heap.FixedBufferAllocator = undefined,
    constants: gpu.FrameConstants = undefined,
    ctx: ViewContext = undefined,
    composite: Composite = undefined,
    pass: ScenePass = undefined,
    shared: scene_pass.Shared = undefined,
    culling: scene_pass.CullState = undefined,
    resolved: rhi.Texture = .invalid,
    no_fluids: gpu.FluidList = .{},
    /// What the view draws into, and whether it ends back in `shader_read`.
    target: rhi.Texture = undefined,
    sampled_target: bool = false,
    /// The view's own state, which `finishView` brings up to date.
    view_data: ?*ViewData = null,
    /// Set for a view of a scene.
    scene: ?*SceneData = null,
    first_view: bool = false,
    view_proj_unjittered: math.Mat4 = undefined,
    jitter: [2]f32 = .{ 0, 0 },

    /// Points the view's passes at `cmd` for `recordView`.
    pub fn recordInto(self: *StagedView, cmd: *rhi.CommandEncoder) void {
        self.ctx.cmd = cmd;
        if (self.scene != null) self.pass.cmd = cmd;
    }
};

/// Records a staged view's passes.
pub fn recordView(staged: *StagedView) !void {
    try staged.graph.record(staged.ctx.cmd);
    if (staged.sampled_target) staged.ctx.cmd.transition(staged.target, .shader_read);
}

/// Brings a recorded view's state and the frame's statistics up to date.
pub fn finishView(self: *Renderer, staged: *StagedView) void {
    const device = self.device;
    const view_data = staged.view_data orelse return;
    if (staged.scene) |scene| {
        if (features.viewState(view_data, path_tracing_feature)) |state| state.traced = staged.shared.path_traced;
        view_data.previous_view_proj = staged.view_proj_unjittered;
        view_data.previous_jitter = staged.jitter;
        view_data.frames += 1;
        view_data.camera_known = true;
        if (staged.first_view) {
            self.internal.stats.instances = scene.live_instances + scene.static_count;
            self.internal.stats.meshlets = scene.live_refs + (scene.ref_count - scene.entity_ref_capacity);
            self.internal.stats.triangles = scene.triangle_count;
            self.internal.stats.skinned_vertices = scene.prepared.skinned_vertices;
        }
    }
    view_data.kept.collect(device, self.internal.frame_index);
    features.collectViewStates(view_data, device);
}

/// Plans a view of this frame into `staged`: checks it, prepares its scene
/// and features and builds its graph, leaving the recording of its passes
/// to `recordView`.
pub fn stageView(self: *Renderer, frame: rhi.Frame, requested: ViewDesc, delta_time: f32, arena: *FrameArena, staged: *StagedView) !void {
    const view_zone = Zone.start(self.options.profiler, "render view");
    defer view_zone.stop();
    const device = self.device;
    const cmd = frame.cmd;
    staged.* = .{};
    staged.desc = requested;
    const desc = &staged.desc;
    var resolving = features.Resolve{
        .caps = device.caps,
        .scene = desc.scene != null,
        .debugging = desc.settings.debug_view != .none,
        .temporal_antialiasing = desc.settings.resolution.temporal_antialiasing,
        .orthographic = desc.camera.orthographic != null,
        .upscalers = upscaling.Availability.of(device, self.internal.dlss),
        .nrd = @import("../nrd.zig").available and device.caps.storage_images,
        .upscaler = desc.settings.resolution.upscaler,
        .path_tracing = pathTracingSupport(self),
        .downgrades = &self.internal.downgrades,
    };
    features.resolve(&desc.settings, &resolving);
    const target = switch (desc.target) {
        .backbuffer => frame.backbuffer orelse return error.NoSurface,
        .texture => |texture| texture,
    };
    if (!device.textureExists(target)) return error.InvalidTarget;
    const info = device.textureInfo(target);
    if (!info.usage.color_attachment or info.format.isDepth() or info.format.isBlockCompressed() or info.kind != .@"2d") return error.InvalidTarget;
    if (!desc.camera.valid()) return error.InvalidCamera;
    for (desc.draw_lists) |layer| try canvas.check(&self.canvas, layer.list);
    const region = desc.region orelse Region{ .x = 0, .y = 0, .width = info.width, .height = info.height };
    if (region.width == 0 or region.height == 0 or
        @as(u64, region.x) + region.width > info.width or @as(u64, region.y) + region.height > info.height)
        return error.InvalidRegion;
    const whole = region.width == info.width and region.height == info.height;
    const written = targetWritten(self, target);
    if (!written) {
        if (self.internal.frame_target_count == self.internal.frame_targets.len) return error.TooManyTargets;
        self.internal.frame_targets[self.internal.frame_target_count] = target;
        self.internal.frame_target_count += 1;
    }
    const load: rhi.LoadOp = if (written) .load else .clear;

    staged.graph.clear();
    const graph = &staged.graph;
    staged.scratch = std.heap.FixedBufferAllocator.init(&staged.scratch_bytes);
    staged.target = target;
    staged.sampled_target = desc.target == .texture;
    staged.ctx = ViewContext{
        .renderer = self,
        .device = device,
        .cmd = cmd,
        .arena = arena,
        .graph = graph,
        .scratch = staged.scratch.allocator(),
        .desc = desc,
        .settings = &desc.settings,
        .view = null,
        .output = .{ .texture = target, .format = info.format, .region = region, .load = load, .clear = desc.clear_color },
        .constants = &staged.constants,
        .frame_address = 0,
        .rays = resolving.rays,
    };
    const ctx = &staged.ctx;

    if (desc.scene) |scene_handle| {
        try ensureSceneResources(self, cmd);
        const scene = self.scenes.internal.table.get(scene_handle) orelse return error.InvalidScene;
        const view = self.views.internal.table.get(desc.view orelse self.internal.main_view) orelse return error.InvalidView;
        if (view.last_frame == self.internal.frame_index) return error.ViewUsedTwice;
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
        staged.composite = Composite{ .ctx = ctx, .picture = color, .format = info.format, .region = region };
        if (!whole) try graph.add(.{
            .name = "view composite",
            .stage = .present,
            .reads = &.{picture},
            .color = &.{.{ .target = try graph.import(target), .load = load, .clear = desc.clear_color }},
            .always = true,
        }, &staged.composite, Composite.run);
        const render_scale = std.math.clamp(desc.settings.resolution.scale, 0.25, 2);
        const internal_width: u32 = @max(@as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(region.width)) * render_scale))), 1);
        const internal_height: u32 = @max(@as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(region.height)) * render_scale))), 1);
        try renderScene(self, ctx, frame, scene_handle, scene, view, color, internal_width, internal_height, region.width, region.height, delta_time, staged);
        staged.view_data = view;
    } else {
        const picture = try graph.import(target);
        graph.publish(.picture, picture);
        graph.want(picture);
        if (canvas.lit(desc)) {
            const view = self.views.internal.table.get(desc.view orelse self.internal.main_view) orelse return error.InvalidView;
            if (view.last_frame == self.internal.frame_index) return error.ViewUsedTwice;
            if (view.last_frame +% 1 != self.internal.frame_index) view.exposure_reset = true;
            view.last_frame = self.internal.frame_index;
            ctx.view = view;
            const frame_constants = try arena.alloc(device, gpu.FrameConstants, 1);
            const constants = &staged.constants;
            constants.* = std.mem.zeroes(gpu.FrameConstants);
            constants.resolution = .{ @floatFromInt(region.width), @floatFromInt(region.height) };
            constants.inv_resolution = .{ 1.0 / @as(f32, @floatFromInt(region.width)), 1.0 / @as(f32, @floatFromInt(region.height)) };
            constants.near = desc.camera.near;
            constants.depth_terms = view_math.depthTerms(desc.camera);
            constants.frame_index = @truncate(self.internal.frame_index);
            constants.time = self.internal.time;
            constants.delta_time = delta_time;
            constants.sampler_linear_clamp = device.samplerIndex(self.internal.sampler_linear_clamp);
            constants.sampler_nearest_clamp = device.samplerIndex(self.internal.sampler_nearest_clamp);
            constants.sampler_linear_repeat = device.samplerIndex(self.internal.sampler_linear_repeat);
            constants.exposure = device.bufferAddress(view.exposure);
            ctx.frame_address = frame_constants.address;
            const hdr = try graph.transient(.{ .name = "hdr", .width = region.width, .height = region.height, .format = hdr_format, .usage = .{ .sampled = true, .color_attachment = true } });
            graph.publish(.hdr, hdr);
            try post.declareFlat(ctx, hdr);
            try features.declare(ctx);
            frame_constants.items[0] = constants.*;
            try graph.stage(self.internal.gpa, device, &self.internal.target_pool, self.internal.frame_index);
            staged.view_data = view;
        } else {
            if (desc.passes.len != 0 and ctx.output.load == .clear) {
                try graph.add(.{ .name = "clear", .stage = .prepare, .color = &.{.{ .target = picture, .load = .clear, .clear = ctx.output.clear }}, .always = true, .scope = false }, ctx, cleared);
                ctx.output.load = .load;
            }
            try features.declare(ctx);
            try graph.stage(self.internal.gpa, device, &self.internal.target_pool, self.internal.frame_index);
        }
    }
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
    staged: *StagedView,
) !void {
    const device = self.device;
    const cmd = frame.cmd;
    const desc = ctx.desc.*;
    const arena = ctx.arena;
    const settings = desc.settings;
    const first_view = self.internal.frame_scene_views == 0;
    self.internal.frame_scene_views += 1;

    cmd.beginScope("scene update");
    const fresh_scene = scene.prepared_frame != self.internal.frame_index;
    if (fresh_scene) {
        scene.prepared = try prepareScene(self, scene, arena);
        scene.prepared_frame = self.internal.frame_index;
        try applySceneUpdate(self, cmd, scene, scene.prepared.update);
    }
    const scene_frame = scene.prepared;
    try cmd.flushUploads();
    try buildPendingBlas(self, cmd, frame.index);
    cmd.endScope();

    const temporal_upscale = (settings.resolution.upscaler == .temporal or settings.resolution.upscaler == .fsr2 or settings.resolution.upscaler == .fsr3 or settings.resolution.upscaler == .dlss) and settings.resolution.temporal_antialiasing and settings.debug_view == .none and (output_width > width or output_height > height);
    const resolved_width = if (temporal_upscale) output_width else width;
    const resolved_height = if (temporal_upscale) output_height else height;
    const antialiasing = try features.stateOf(view_data, device, resolution_feature);
    if (view_data.state == null or view_data.state.?.width != width or view_data.state.?.height != height or
        view_data.state.?.resolved_width != resolved_width or view_data.state.?.resolved_height != resolved_height)
    {
        if (view_data.state) |*old| old.deinit(device);
        view_data.state = null;
        view_data.state = try ViewState.init(device, width, height, resolved_width, resolved_height);
        antialiasing.upscaler.forgive();
        view_data.exposure_reset = true;
        view_data.camera_known = false;
    }
    try antialiasing.fit(device, resolved_width, resolved_height);
    const view = &view_data.state.?;
    std.mem.swap(rhi.Texture, &view.depth, &view.previous_depth);
    std.mem.swap(rhi.Texture, &view.motion, &view.previous_motion);
    if (view_data.last_frame +% 1 != self.internal.frame_index or desc.cut) {
        view_data.camera_known = false;
        view.history_valid = false;
        view_data.kept.invalidate();
    }
    if (desc.cut) view_data.exposure_reset = true;

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
    const instance_total: u32 = scene.entity_capacity + scene.static_count;
    const mark_seen = has_geometry and instance_total != 0 and
        (if (self.options.textures.streaming) |streaming| streaming.skip_occluded else false);
    const lod_scale: f32 = if (settings.geometry.lod_error_pixels > 0)
        @abs(proj_unjittered[5]) * @as(f32, @floatFromInt(height)) * 0.5 / settings.geometry.lod_error_pixels * vantage.scale
    else
        0;
    staged.culling = std.mem.zeroes(scene_pass.CullState);
    staged.resolved = rhi.Texture.invalid;
    staged.pass = ScenePass{
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
        .culling = &staged.culling,
        .resolved = &staged.resolved,
    };
    const pass = &staged.pass;
    const environment: ?*EnvironmentEntry = blk: {
        const entry = self.environments.internal.table.get(scene.environment orelse break :blk null) orelse break :blk null;
        break :blk if (entry.state == .ready) entry else null;
    };

    try ray_scene.prepare(self, scene, scene_frame, ray_scene.wanted(self, scene, ctx.rays), fresh_scene);
    const constants = try arena.alloc(device, gpu.FrameConstants, 1);
    ctx.constants.* = .{
        .view = view_matrix,
        .proj = proj,
        .view_proj = view_proj,
        .inv_view_proj = math.inverse(view_proj),
        .view_proj_unjittered = view_proj_unjittered,
        .prev_view_proj_unjittered = view_data.previous_view_proj,
        .inv_view = math.inverse(view_matrix),
        .inv_proj = math.inverse(proj),
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
        .frame_index = @truncate(self.internal.frame_index),
        .time = self.internal.time,
        .delta_time = delta_time,
        .environment = @intFromBool(environment != null),
        .env_specular = if (environment) |entry| device.textureIndex(entry.specular.?) else gpu.invalid_id,
        .env_irradiance = if (environment) |entry| device.textureIndex(entry.irradiance.?) else gpu.invalid_id,
        .env_sky = if (environment) |entry| device.textureIndex(entry.sky.?) else gpu.invalid_id,
        .brdf_lut = device.textureIndex(self.internal.brdf_lut),
        .sampler_linear_clamp = device.samplerIndex(self.internal.sampler_linear_clamp),
        .sampler_nearest_clamp = device.samplerIndex(self.internal.sampler_nearest_clamp),
        .env_specular_mips = env_specular_mips,
        .sampler_linear_repeat = device.samplerIndex(self.internal.sampler_linear_repeat),
        .vertices = device.bufferAddress(self.internal.vertices.get()),
        .indices = device.bufferAddress(self.internal.indices.get()),
        .meshlets = device.bufferAddress(self.internal.meshlets.get()),
        .meshes = device.bufferAddress(self.internal.meshes.get()),
        .materials = device.bufferAddress(self.materials.internal.pool.get()),
        .instances = scene_frame.instances,
        .previous_transforms = scene_frame.previous_transforms,
        .meshlet_refs = if (scene.refs) |buffer| device.bufferAddress(buffer) else 0,
        .exposure = device.bufferAddress(view_data.exposure),
    };
    pass.frame_address = constants.address;
    ctx.frame_address = constants.address;
    ctx.scene = pass;
    ctx.output.depth = view.depth;
    const g = ctx.graph;
    g.publish(.depth, try g.import(view.depth));
    g.publish(.visibility, try g.import(view.visibility));
    g.publish(.motion, try g.import(view.motion));
    g.publish(.hdr, try g.import(view.hdr));
    const count_readback = self.internal.count_readback[@intCast(frame.index % rhi.frames_in_flight)];
    if (first_view) {
        const counted = device.mappedSlice(u32, count_readback);
        self.internal.stats.meshlets_drawn = counted[0] + counted[1] + counted[main_late_view * 2] + counted[main_late_view * 2 + 1];
        self.internal.stats.shadow_meshlets_drawn = 0;
        for (1..1 + gpu.cascade_count) |index| self.internal.stats.shadow_meshlets_drawn += counted[index * 2] + counted[index * 2 + 1];
        self.internal.stats.instances_drawn = counted[view_count * 2];
    }

    staged.no_fluids = .{};
    staged.shared = scene_pass.Shared{
        .frame = frame,
        .arena = arena,
        .delta_time = delta_time,
        .sun = &scene_pass.no_sun,
        .lighting = &scene_pass.no_lighting,
        .local_shadows = &scene_pass.no_local_shadows,
        .gi = null,
        .shadow_tlas = 0,
        .colored_shadows = false,
        .cloud_address = 0,
        .fluid_list = &staged.no_fluids,
        .shadows_enabled = shadows_enabled,
        .first_view = first_view,
        .fresh_scene = fresh_scene,
        .instance_total = instance_total,
        .count_readback = count_readback,
        .culling = &staged.culling,
        .resolved = &staged.resolved,
    };
    pass.shared = &staged.shared;
    const tracer = features.viewState(view_data, path_tracing_feature);
    pass.tracing = settings.path_tracing != null and !debugging and tracer != null and tracer.?.traced;
    try features.prepare(ctx);
    try features.declare(ctx);
    constants.items[0] = ctx.constants.*;
    try g.stage(self.internal.gpa, device, &self.internal.target_pool, self.internal.frame_index);
    view_data.last_frame = self.internal.frame_index;
    staged.scene = scene;
    staged.first_view = first_view;
    staged.view_proj_unjittered = view_proj_unjittered;
    staged.jitter = jitter;
}

/// How this renderer path traces, if it can.
pub fn pathTracingSupport(renderer: *const Renderer) api.PathTracingSupport {
    if (renderer.device.caps.ray_tracing) return .hardware;
    return if (renderer.options.ray_tracing.software_path_tracing) .shader else .unavailable;
}

/// Stages, records and finishes one view on the frame's encoder.
pub fn renderView(self: *Renderer, frame: rhi.Frame, requested: ViewDesc, delta_time: f32, arena: *FrameArena) !void {
    const staged = try self.internal.gpa.create(StagedView);
    defer self.internal.gpa.destroy(staged);
    try stageView(self, frame, requested, delta_time, arena, staged);
    staged.recordInto(frame.cmd);
    try recordView(staged);
    finishView(self, staged);
}

/// Stages the views of a frame in order and records them, a run of
/// consecutive views per thread when there are several views and
/// `Options.worker_threads` allows more than one, then finishes them.
pub fn renderViews(self: *Renderer, frame: rhi.Frame, views: []const ViewDesc, delta_time: f32, arena: *FrameArena) !void {
    try self.internal.staged_views.resize(self.internal.gpa, views.len);
    const staged = self.internal.staged_views.items;
    for (views, staged) |desc, *slot| try stageView(self, frame, desc, delta_time, arena, slot);
    var threads = @min(@import("scene_update.zig").workerThreads(self), rhi.max_parallel);
    for (views) |desc| for (desc.passes) |pass| {
        if (!pass.threaded) threads = 1;
    };
    var runs: [rhi.max_parallel + 1]usize = undefined;
    const run_count = splitRuns(staged, threads, &runs);
    if (run_count < 2) {
        for (staged) |*slot| {
            slot.recordInto(frame.cmd);
            try recordView(slot);
        }
    } else try recordInParallel(self, staged, runs[0 .. run_count + 1]);
    for (staged) |*slot| finishView(self, slot);
}

/// Cuts the views into at most `most` runs of consecutive views, as even as
/// it can, returning how many; `bounds` gets where each starts and, last,
/// the end. A cut never falls between views of one scene, whose passes hand
/// each other what they work out while they record.
fn splitRuns(staged: []const StagedView, most: usize, bounds: *[rhi.max_parallel + 1]usize) usize {
    var cuts: [rhi.max_parallel]usize = undefined;
    var cut_count: usize = 0;
    var start: usize = 0;
    var at: usize = 1;
    while (at < staged.len and cut_count + 1 < most) : (at += 1) {
        const left = staged.len - start;
        const runs_left = most - cut_count;
        if (at - start < (left + runs_left - 1) / runs_left) continue;
        if (!cuttable(staged, at)) continue;
        cuts[cut_count] = at;
        cut_count += 1;
        start = at;
    }
    bounds[0] = 0;
    for (cuts[0..cut_count], 1..) |cut, index| bounds[index] = cut;
    bounds[cut_count + 1] = staged.len;
    return cut_count + 1;
}

/// Whether no scene and no draw list is in views both before `at` and from
/// `at` on: recording a draw list keeps what it uploads in the list.
fn cuttable(staged: []const StagedView, at: usize) bool {
    for (staged[0..at]) |before| {
        for (staged[at..]) |after| {
            if (before.scene != null and after.scene == before.scene) return false;
            for (before.desc.draw_lists) |mine| for (after.desc.draw_lists) |theirs| {
                if (mine.list == theirs.list) return false;
            };
        }
    }
    return true;
}

fn recordInParallel(self: *Renderer, staged: []StagedView, bounds: []const usize) !void {
    const threads = bounds.len - 1;
    const encoders = try self.device.beginParallel(@intCast(threads));
    var failures: [rhi.max_parallel]?anyerror = @splat(null);
    var group: std.Io.Group = .init;
    for (1..threads) |index| {
        const chunk = staged[bounds[index]..bounds[index + 1]];
        group.concurrent(self.internal.io, recordRun, .{ chunk, &encoders[index], &failures[index] }) catch recordRun(chunk, &encoders[index], &failures[index]);
    }
    recordRun(staged[bounds[0]..bounds[1]], &encoders[0], &failures[0]);
    group.await(self.internal.io) catch {};
    try self.device.joinParallel();
    for (failures[0..threads]) |failure| if (failure) |err| return err;
}

/// Records consecutive staged views into one encoder, on any thread.
fn recordRun(run: []StagedView, encoder: *rhi.CommandEncoder, failure: *?anyerror) void {
    for (run) |*slot| {
        slot.recordInto(encoder);
        recordView(slot) catch |err| {
            failure.* = err;
            return;
        };
    }
}
