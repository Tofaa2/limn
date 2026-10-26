//! Which of a scene's geometry a view draws, and at what detail.
const pipelines_module = @import("../renderer/pipelines.zig");
const skin_push = @import("../shaders/push/skin.zig");
const hiz_push = @import("../shaders/push/hiz.zig");
const pick_push = @import("../shaders/push/pick.zig");
const scene_pass = @import("../scene_pass.zig");
const render = @import("../renderer.zig");
const filled = @import("../api.zig").filled;
const gpu = @import("../gpu.zig");
const std = @import("std");
const api = @import("../api.zig");
const features = @import("../core/features.zig");
const renderer_state = @import("../state.zig");
const ray_scene = @import("../scene/ray_scene.zig");
const rhi = @import("../../rhi/rhi.zig");

const ViewState = render.ViewState;
const InstanceCullPush = scene_pass.InstanceCullPush;
const Lighting = scene_pass.Lighting;
const CullPush = scene_pass.CullPush;
const CullState = scene_pass.CullState;
const SunShadows = scene_pass.SunShadows;
const main_late_view = render.main_late_view;
const local_view_base = render.local_view_base;
const local_shadow_tiles_per_side = render.local_shadow_tiles_per_side;
const view_math = @import("../renderer/view_math.zig");
const cullView = render.cullView;
const DrawPush = scene_pass.DrawPush;
const SkinJob = render.SkinJob;
const BoundsJob = render.BoundsJob;
const ModelMesh = render.ModelMesh;
const ScenePass = scene_pass.ScenePass;
const Renderer = render.Renderer;
const view_count = renderer_state.view_count;
const Zone = renderer_state.Zone;
const ViewContext = features.ViewContext;

pub const name = "geometry";

pub const Settings = struct {
    /// Cull geometry hidden behind what was visible last frame. Never drops
    /// visible geometry.
    occlusion_culling: bool = true,
    /// Screen-space error in pixels at which meshes switch to a coarser LOD; 0
    /// always draws full detail.
    lod_error_pixels: f32 = 1,
    /// Cross-fade LODs by dithering over this share of the switching distance
    /// (0.25 is typical); 0 switches at once.
    lod_cross_fade: f32 = 0,
};

pub fn preset(quality: api.Quality) Settings {
    _ = quality;
    return .{};
}

pub fn resolve(setting: *Settings, r: *features.Resolve) void {
    _ = setting;
    _ = r;
}

/// Adds the feature's passes to a view of a scene. A path traced view leaves
/// out those whose result the tracer replaces.
pub fn declare(ctx: *ViewContext) !void {
    const p = ctx.scene orelse return;
    const renderer = ctx.renderer;
    try fitCullBuffers(renderer, p, p.shared.instance_total);
    if (p.mark_seen) {
        const slot: usize = @intCast(p.shared.frame.index % rhi.frames_in_flight);
        p.scene.seen_tags[slot] = .{ .layout_version = p.scene.layout_version, .count = p.shared.instance_total, .valid = true };
    }
    if (renderer.internal.pick_request) |request| if (std.meta.eql(request.view, p.desc.view orelse renderer.internal.main_view)) {
        p.shared.pick = request;
        renderer.internal.pick_request = null;
    };
    const g = ctx.graph;
    try g.add(.{ .name = "reset culling", .stage = .prepare, .always = true, .scope = false }, ctx, resetCulling);
    try g.add(.{ .name = "deformed geometry", .stage = .geometry, .always = true, .scope = false }, ctx, deform);
    try g.add(.{ .name = "ray scene", .stage = .geometry, .always = true, .scope = false }, ctx, buildRayScene);
    try g.add(.{ .name = "culling", .stage = .geometry, .always = true, .scope = false }, ctx, cullPass);
    try g.add(.{ .name = "visibility", .stage = .geometry, .always = true, .scope = false }, ctx, visibility);
    try g.add(.{ .name = "picks", .stage = .geometry, .always = true, .scope = false }, ctx, picks);
}

fn resetCulling(ctx: *ViewContext) !void {
    const p = ctx.scene.?;
    const c = p.shared;
    try resetCullBuffers(ctx.renderer, p, c.instance_total);
}

fn deform(ctx: *ViewContext) !void {
    const p = ctx.scene.?;
    if (!p.has_geometry) return;
    const zone = Zone.start(ctx.renderer.options.profiler, "deformed geometry");
    defer zone.stop();
    try skinScene(ctx.renderer, p);
}

fn buildRayScene(ctx: *ViewContext) !void {
    const p = ctx.scene.?;
    ray_scene.build(p.cmd, p.scene, p.scene_frame);
}

fn cullPass(ctx: *ViewContext) !void {
    const p = ctx.scene.?;
    const c = p.shared;
    c.culling.* = try cullScene(ctx.renderer, p, c.sun, c.lighting, c.local_shadows.draw);
}

fn visibility(ctx: *ViewContext) !void {
    const p = ctx.scene.?;
    const c = p.shared;
    const self = ctx.renderer;
    const cmd = p.cmd;
    const scene = p.scene;
    try drawSceneVisibility(self, p, c.sun, c.culling);
    if (c.first_view) {
        cmd.copyBuffer(self.internal.cull_counts, c.count_readback, 0, 0, view_count * 2 * @sizeOf(u32));
        if (scene.seen) |seen| cmd.copyBuffer(seen, c.count_readback, @as(u64, c.instance_total) * @sizeOf(u32), view_count * 2 * @sizeOf(u32), @sizeOf(u32));
    }
    if (p.mark_seen) {
        const slot: usize = @intCast(c.frame.index % rhi.frames_in_flight);
        cmd.copyBuffer(scene.seen.?, scene.seen_readback[slot].?, 0, 0, @as(u64, c.instance_total) * @sizeOf(u32));
    }
}

/// Picks of this view are answered here, from depth and the visibility
/// buffer.
fn picks(ctx: *ViewContext) !void {
    const p = ctx.scene.?;
    try recordPick(ctx.renderer, p);
}

/// Meshlet headroom in the draw command buffer beyond the scene's count.
const cull_headroom = 1 << 16;

/// What culling keeps for a view from frame to frame.
pub const View = struct {
    /// One word per meshlet reference: was it visible last frame.
    visibility: ?rhi.Buffer = null,
    visibility_capacity: u32 = 0,
    /// One word per instance of the instance groups: seen last frame
    /// (`InstanceVisibility` in cull_view.slang).
    instance_visibility: ?rhi.Buffer = null,
    instance_visibility_capacity: u32 = 0,
    /// The scene and layout the visibility words are for.
    visibility_scene: ?render.Scene = null,
    visibility_layout: u64 = 0,
    /// Depth pyramid for occlusion culling: power-of-two, full mip chain.
    hiz: ?rhi.Texture = null,
    hiz_width: u32 = 0,
    hiz_height: u32 = 0,
    hiz_mips: u32 = 0,
    /// Last frame's visibility words do not fit this frame's scene: they
    /// are cleared before culling.
    reset_visibility: bool = false,

    pub fn init(_: *rhi.Device) !View {
        return .{};
    }

    pub fn deinit(self: *View, device: *rhi.Device) void {
        if (self.visibility) |buffer| device.destroyBuffer(buffer);
        if (self.instance_visibility) |buffer| device.destroyBuffer(buffer);
        if (self.hiz) |texture| device.destroyTexture(texture);
    }

    /// Makes the pyramid for a picture of `width` by `height`.
    fn fitPyramid(self: *View, device: *rhi.Device, width: u32, height: u32) !void {
        const hiz_width = std.math.floorPowerOfTwo(u32, @max(width, 2));
        const hiz_height = std.math.floorPowerOfTwo(u32, @max(height, 2));
        if (self.hiz != null and self.hiz_width == hiz_width and self.hiz_height == hiz_height) return;
        if (self.hiz) |texture| device.destroyTexture(texture);
        self.hiz = null;
        self.hiz_mips = rhi.TextureDesc.fullMipCount(hiz_width, hiz_height);
        self.hiz = try device.createTexture(.{
            .name = "depth pyramid",
            .width = hiz_width,
            .height = hiz_height,
            .format = .r32_float,
            .usage = .{ .sampled = true, .color_attachment = true, .storage = device.caps.storage_images },
            .mip_levels = self.hiz_mips,
        });
        self.hiz_width = hiz_width;
        self.hiz_height = hiz_height;
    }
};

/// Makes the buffers culling writes big enough for the scene: instance seen
/// flags, last frame's meshlet visibility and the impostor list. Runs while
/// the view is planned, before any view records.
pub fn fitCullBuffers(renderer: *Renderer, p: *const ScenePass, instance_total: u32) !void {
    const device = renderer.device;
    const scene_handle = p.scene_handle;
    const scene = p.scene;
    const view_data = p.view_data;
    const mark_seen = p.mark_seen;
    const own = try features.stateOf(view_data, device, @This());
    try own.fitPyramid(device, p.view.width, p.view.height);
    if (instance_total + 1 > scene.seen_capacity or (mark_seen and scene.seen_readback[0] == null)) {
        if (scene.seen) |buffer| device.destroyBuffer(buffer);
        scene.seen = null;
        for (&scene.seen_readback) |*readback| {
            if (readback.*) |buffer| device.destroyBuffer(buffer);
            readback.* = null;
        }
        scene.seen_tags = @splat(.{});
        scene.seen_capacity = 0;
        const capacity = @max(instance_total + 1 + @min(instance_total / 2, cull_headroom), 1024);
        const size = @as(u64, capacity) * @sizeOf(u32);
        scene.seen = try device.createBuffer(.{ .name = "instances seen", .size = size, .usage = .{ .storage = true, .copy_src = true } });
        if (mark_seen) for (&scene.seen_readback) |*readback| {
            readback.* = try device.createBuffer(.{ .name = "instances seen readback", .size = size, .usage = .{}, .memory = .gpu_to_cpu });
        };
        scene.seen_capacity = capacity;
    }

    var visibility_reset = false;
    if (scene.refs_capacity != 0 and own.visibility_capacity < scene.refs_capacity) {
        if (own.visibility) |buffer| device.destroyBuffer(buffer);
        own.visibility = null;
        own.visibility = try device.createBuffer(.{
            .name = "meshlet visibility",
            .size = @as(u64, scene.refs_capacity) * @sizeOf(u32),
            .usage = .{ .storage = true },
        });
        own.visibility_capacity = scene.refs_capacity;
        visibility_reset = true;
    }
    if (scene.static_count > own.instance_visibility_capacity) {
        if (own.instance_visibility) |buffer| device.destroyBuffer(buffer);
        own.instance_visibility = null;
        const capacity = scene.static_count + @min(scene.static_count / 2, cull_headroom);
        own.instance_visibility = try device.createBuffer(.{
            .name = "instance visibility",
            .size = @as(u64, capacity) * @sizeOf(u32),
            .usage = .{ .storage = true },
        });
        own.instance_visibility_capacity = capacity;
        visibility_reset = true;
    }
    if (own.visibility_scene == null or !std.meta.eql(own.visibility_scene.?, scene_handle) or
        own.visibility_layout != scene.layout_version) visibility_reset = true;
    own.visibility_scene = scene_handle;
    own.visibility_layout = scene.layout_version;
    own.reset_visibility = own.reset_visibility or visibility_reset;
    if (scene.impostor_count != 0 and scene.static_count > scene.impostor_list_capacity) {
        if (scene.impostor_list) |buffer| device.destroyBuffer(buffer);
        scene.impostor_list = null;
        const capacity = scene.static_count + @min(scene.static_count / 2, cull_headroom);
        scene.impostor_list = try device.createBuffer(.{ .name = "impostor list", .size = @as(u64, capacity) * @sizeOf(u32), .usage = .{ .storage = true } });
        scene.impostor_list_capacity = capacity;
    }
    const views_wanted: u32 = if (filled(p.settings.shadows).virtual) view_count else if (p.shared.lighting.tile_count == 0) local_view_base else render.vsm_view_base;
    const masked_wanted = if (p.lod_band > 1) scene.ref_count else scene.masked_ref_count;
    if (renderer.internal.cull_commands == null or scene.ref_count > renderer.internal.cull_capacity or masked_wanted > renderer.internal.cull_masked_capacity or views_wanted > renderer.internal.cull_views) {
        if (renderer.internal.cull_commands) |buffer| device.destroyBuffer(buffer);
        renderer.internal.cull_commands = null;
        const capacity = scene.ref_count + @min(scene.ref_count / 2, cull_headroom);
        const masked_capacity = @max(@min(masked_wanted + @min(masked_wanted / 2, cull_headroom), capacity), 1);
        const views = @max(renderer.internal.cull_views, views_wanted);
        renderer.internal.cull_commands = try device.createBuffer(.{
            .name = "cull commands",
            .size = (@as(u64, capacity) + masked_capacity) * views * commandSize(renderer),
            .usage = .{ .storage = true, .indirect = true },
        });
        renderer.internal.cull_capacity = capacity;
        renderer.internal.cull_masked_capacity = masked_capacity;
        renderer.internal.cull_views = views;
    }

    const static_refs = scene.ref_count - scene.entity_ref_capacity;
    if (static_refs > scene.candidate_capacity or views_wanted > scene.candidate_views) {
        if (scene.candidates) |buffer| device.destroyBuffer(buffer);
        scene.candidates = null;
        const capacity = static_refs + @min(static_refs / 2, cull_headroom);
        const views = @max(scene.candidate_views, views_wanted);
        scene.candidates = try device.createBuffer(.{
            .name = "cull candidates",
            .size = @as(u64, @max(capacity, 1)) * views * @sizeOf(u32),
            .usage = .{ .storage = true },
        });
        scene.candidate_capacity = capacity;
        scene.candidate_views = views;
    }
}

/// Clears the buffers culling writes: draw counts, instance seen flags and,
/// after a change of scene or layout, last frame's meshlet visibility.
pub fn resetCullBuffers(renderer: *Renderer, p: *const ScenePass, instance_total: u32) !void {
    const device = renderer.device;
    const cmd = p.cmd;
    const scene = p.scene;
    const own = try features.stateOf(p.view_data, device, @This());
    const visibility_reset = own.reset_visibility;
    own.reset_visibility = false;
    const fresh_scene = p.fresh_scene;
    cmd.dependency(.{ .compute_read = true, .compute_write = true, .graphics_read = true, .indirect = true, .transfer_read = true }, .{ .transfer_write = true });
    cmd.fillBuffer(renderer.internal.cull_counts, 0, view_count * 2 * @sizeOf(u32), 0);
    const dispatches = try p.arena.alloc(device, gpu.CullDispatch, view_count);
    @memset(dispatches.items, .{ .x = (scene.entity_ref_count + 63) / 64 });
    cmd.copyBuffer(dispatches.buffer, renderer.internal.cull_dispatch, dispatches.offset, 0, view_count * @sizeOf(gpu.CullDispatch));
    if (scene.impostor_count != 0) {
        const draw = try p.arena.alloc(device, gpu.DrawIndirect, 1);
        draw.items[0] = .{ .vertex_count = 6 };
        cmd.copyBuffer(draw.buffer, renderer.internal.impostor_draw, draw.offset, 0, @sizeOf(gpu.DrawIndirect));
    }
    if (device.caps.mesh_shaders) {
        const draws = try p.arena.alloc(device, gpu.MeshDraw, view_count * 2);
        @memset(draws.items, .{});
        cmd.copyBuffer(draws.buffer, renderer.internal.cull_mesh_draws, draws.offset, 0, view_count * 2 * @sizeOf(gpu.MeshDraw));
    }
    if (fresh_scene) cmd.fillBuffer(scene.seen.?, 0, (@as(u64, instance_total) + 1) * @sizeOf(u32), 0);
    if (visibility_reset) {
        if (own.visibility) |buffer| cmd.fillBuffer(buffer, 0, @as(u64, own.visibility_capacity) * @sizeOf(u32), 1);
        if (own.instance_visibility) |buffer| cmd.fillBuffer(buffer, 0, @as(u64, own.instance_visibility_capacity) * @sizeOf(u32), 1);
    }
    cmd.dependency(.{ .transfer_write = true }, .{ .compute_read = true, .compute_write = true, .indirect = true, .graphics_read = true });
}

/// Triangles of `mesh`, for building its BLAS.
pub fn blasGeometry(renderer: *Renderer, mesh: ModelMesh) rhi.BlasGeometry {
    return .{
        .vertices = renderer.internal.vertices.get(),
        .vertex_offset = @as(u64, mesh.vertex_offset) * @sizeOf(gpu.Vertex),
        .vertex_count = mesh.vertex_count,
        .vertex_stride = @sizeOf(gpu.Vertex),
        .indices = renderer.internal.indices.get(),
        .index_offset = @as(u64, mesh.index_offset) * @sizeOf(u32),
        .index_count = mesh.lod0_index_count,
        .solid = !mesh.alpha_tested,
    };
}

/// Builds the structure `pick` gives for each of `meshes`, in batches.
pub fn buildMeshBlases(renderer: *Renderer, cmd: *rhi.CommandEncoder, meshes: []const ModelMesh, comptime pick: fn (ModelMesh) ?rhi.AccelerationStructure) !void {
    var geometries: [16]rhi.BlasGeometry = undefined;
    var builds: [16]rhi.BlasBuild = undefined;
    var count: usize = 0;
    for (meshes) |mesh| {
        const blas = pick(mesh) orelse continue;
        geometries[count] = blasGeometry(renderer, mesh);
        builds[count] = .{ .blas = blas, .desc = .{ .geometries = geometries[count..][0..1] } };
        count += 1;
        if (count == builds.len) {
            try cmd.buildBlases(&builds);
            count = 0;
        }
    }
    if (count != 0) try cmd.buildBlases(builds[0..count]);
}

/// Skins and morphs the scene's meshes, then updates their meshlet bounds and
/// BLASes.
pub fn skinScene(renderer: *Renderer, p: *const ScenePass) !void {
    const device = renderer.device;
    const cmd = p.cmd;
    const arena = p.arena;
    const scene = p.scene;
    const scene_frame = p.scene_frame;
    const fresh_scene = p.fresh_scene;
    cmd.beginScope("skinning");
    if (fresh_scene and scene.skin_jobs.items.len != 0) {
        var group_count: u32 = 0;
        for (scene.skin_jobs.items) |*job| {
            job.first_group = group_count;
            group_count += (job.vertex_count + 63) / 64;
        }
        const jobs = try arena.alloc(device, SkinJob, scene.skin_jobs.items.len);
        @memcpy(jobs.items, scene.skin_jobs.items);
        const group_jobs = try arena.alloc(device, u32, group_count);
        for (scene.skin_jobs.items, 0..) |job, index| {
            @memset(group_jobs.items[job.first_group..][0 .. (job.vertex_count + 63) / 64], @intCast(index));
        }
        cmd.bindPipeline(try renderer.internal.pipelines.of(skinPipeline));
        const weights = try arena.alloc(device, f32, @max(scene.skin_weights.items.len, 1));
        weights.items[0] = 0;
        @memcpy(weights.items[0..scene.skin_weights.items.len], scene.skin_weights.items);
        cmd.pushConstants(skin_push.SkinPush{
            .weights = weights.address,
            .vertices = device.bufferAddress(renderer.internal.vertices.get()),
            .skin = device.bufferAddress(renderer.internal.skin_vertices.get()),
            .joints = scene_frame.joints,
            .morph = device.bufferAddress(renderer.internal.morph_deltas.get()),
            .jobs = jobs.address,
            .group_jobs = group_jobs.address,
            .group_count = group_count,
        });
        cmd.dispatch(@min(group_count, 1024), (group_count + 1023) / 1024, 1);
    }
    if (fresh_scene and scene.bounds_jobs.items.len != 0) {
        cmd.dependency(.{ .compute_write = true }, .{ .compute_read = true });
        var group_count: u32 = 0;
        for (scene.bounds_jobs.items) |*job| {
            job.first_group = group_count;
            group_count += (job.meshlet_count + 63) / 64;
        }
        const jobs = try arena.alloc(device, BoundsJob, scene.bounds_jobs.items.len);
        @memcpy(jobs.items, scene.bounds_jobs.items);
        const group_jobs = try arena.alloc(device, u32, group_count);
        for (scene.bounds_jobs.items, 0..) |job, index| {
            @memset(group_jobs.items[job.first_group..][0 .. (job.meshlet_count + 63) / 64], @intCast(index));
        }
        cmd.bindPipeline(try renderer.internal.pipelines.of(skinBoundsPipeline));
        cmd.pushConstants(skin_push.BoundsPush{
            .vertices = device.bufferAddress(renderer.internal.vertices.get()),
            .indices = device.bufferAddress(renderer.internal.indices.get()),
            .meshlets = device.bufferAddress(renderer.internal.meshlets.get()),
            .bounds = device.bufferAddress(scene.skin_bounds.?),
            .jobs = jobs.address,
            .group_jobs = group_jobs.address,
            .group_count = group_count,
        });
        cmd.dispatch(@min(group_count, 1024), (group_count + 1023) / 1024, 1);
    }
    if (fresh_scene and scene.blas_jobs.items.len != 0 and scene.tlas != null) {
        cmd.dependency(.{ .compute_write = true }, .{ .build_read = true });
        const jobs = scene.blas_jobs.items;
        const budget: usize = if (renderer.options.ray_tracing.dynamic_refits == 0) jobs.len else @min(renderer.options.ray_tracing.dynamic_refits, jobs.len);
        const first = scene.refit_cursor % jobs.len;
        scene.refit_cursor = (first + budget) % jobs.len;
        for (jobs, 0..) |job, index| {
            const turn = (index + jobs.len - first) % jobs.len < budget;
            if (!turn and device.accelerationBuilt(job.blas)) continue;
            var geometry = blasGeometry(renderer, job.mesh);
            geometry.vertex_offset = @as(u64, job.vertex_offset) * @sizeOf(gpu.Vertex);
            try cmd.buildBlas(job.blas, .{ .geometries = &.{geometry}, .dynamic = true });
        }
    }
    cmd.endScope();
}

/// Offset of a culling view's draw commands; `bucket` is 0 for opaque and 1 for
/// alpha-tested meshlets.
pub fn commandOffset(renderer: *const Renderer, view_index: usize, bucket: usize) u64 {
    const per_view = @as(u64, renderer.internal.cull_capacity) + renderer.internal.cull_masked_capacity;
    return (view_index * per_view + bucket * renderer.internal.cull_capacity) * commandSize(renderer);
}

/// Bytes culling writes per drawn meshlet: a draw command, a draw command
/// that is not indexed where draws pull their indices, or a bare reference
/// with mesh shaders.
fn commandSize(renderer: *const Renderer) u64 {
    if (renderer.device.caps.mesh_shaders) return @sizeOf(u32);
    return if (pulledDraws(renderer)) 4 * @sizeOf(u32) else @sizeOf(gpu.DrawCommand);
}

/// Visibility draws are not indexed and pull their indices in the vertex
/// shader, which hands the fragment shader the triangle: the device has
/// neither mesh shaders nor `SV_PrimitiveID`.
pub fn pulledDraws(renderer: *const Renderer) bool {
    return pipelines_module.pulledDraws(renderer.device);
}

/// Draws one of a view's two meshlet lists with the bound pipeline. `bucket` 0:
/// opaque; 1: alpha-tested, two-sided or fading.
pub fn drawMeshlets(renderer: *Renderer, cmd: *rhi.CommandEncoder, push: DrawPush, view_index: usize, bucket: usize, max_draws: u32) void {
    const counts_offset = (view_index * 2 + bucket) * @sizeOf(u32);
    if (renderer.device.caps.mesh_shaders) {
        var with_list = push;
        with_list.list = renderer.device.bufferAddress(renderer.internal.cull_commands.?) + commandOffset(renderer, view_index, bucket);
        with_list.count = renderer.device.bufferAddress(renderer.internal.cull_counts) + counts_offset;
        cmd.pushConstants(with_list);
        cmd.drawMeshTasksIndirect(renderer.internal.cull_mesh_draws, (view_index * 2 + bucket) * @sizeOf(gpu.MeshDraw));
        return;
    }
    cmd.pushConstants(push);
    const most = if (bucket == 0) max_draws else @min(max_draws, renderer.internal.cull_masked_capacity);
    if (pulledDraws(renderer)) {
        cmd.drawIndirectCount(renderer.internal.cull_commands.?, commandOffset(renderer, view_index, bucket), renderer.internal.cull_counts, counts_offset, most);
        return;
    }
    cmd.drawIndexedIndirectCount(renderer.internal.cull_commands.?, commandOffset(renderer, view_index, bucket), renderer.internal.cull_counts, counts_offset, most);
}

/// Culls for each of the frame's views: the camera (early phase with occlusion
/// culling), the cascades being redrawn and local shadow tiles.
pub fn cullScene(renderer: *Renderer, p: *const ScenePass, sun: *const SunShadows, lighting: *const Lighting, draw_local_shadows: bool) !CullState {
    const device = renderer.device;
    const cmd = p.cmd;
    const arena = p.arena;
    const desc = p.desc;
    const settings = p.settings;
    const scene = p.scene;
    const view_data = p.view_data;
    const view_matrix = p.view_matrix;
    const own = try features.stateOf(view_data, device, @This());
    const proj_unjittered = p.proj_unjittered;
    const view_proj_unjittered = p.view_proj_unjittered;
    const sun_travel = p.sun_travel;
    const occlusion = p.occlusion;
    const lod_band = p.lod_band;
    const frame_address = p.frame_address;
    const cascades = sun.cascades;
    const cascade_update = sun.update;
    const cascade_total = sun.count;
    if (!p.has_geometry) return std.mem.zeroes(CullState);
    var cull_push: CullPush = undefined;
    var cull_views_address: u64 = 0;
    var receiver_culled: [gpu.cascade_count]bool = @splat(false);
    cmd.beginScope("culling");
    const cull_views = try arena.alloc(device, gpu.CullView, view_count);
    const vantage = view_math.vantage(desc.camera);
    const parallel_far: f32 = if (desc.camera.orthographic) |parallel| @max(parallel.far, desc.camera.near * 2) else 0;
    cull_views.items[0] = cullView(view_proj_unjittered, vantage.position, .perspective);
    cull_views.items[0].far = parallel_far;
    cull_views.items[0].p00 = proj_unjittered[0];
    cull_views.items[0].p11 = proj_unjittered[5];
    cull_views.items[0].near = desc.camera.near;
    cull_views.items[0].view = view_matrix;
    for (0..gpu.cascade_count) |cascade|
        cull_views.items[1 + cascade] = cullView(cascades.view_proj[cascade], desc.camera.position, .shadow);
    cull_views.items[main_late_view] = cull_views.items[0];
    for (0..lighting.tile_count) |tile| cull_views.items[local_view_base + tile] = lighting.tile_views[tile];
    const lod_scale = p.lod[3];
    for (cull_views.items) |*cull| {
        cull.lens_shift = view_math.lensShift(proj_unjittered, desc.camera);
        cull.lod_camera = vantage.position;
        cull.lod_scale = lod_scale;
        cull.blended_casters = 0;
        cull.lod_band = 1;
        cull.min_radius = 0;
    }
    if (filled(settings.shadows).lod == .light and settings.geometry.lod_error_pixels > 0) {
        const tile_pixels: f32 = @floatFromInt(renderer.options.shadows.local_resolution / std.math.clamp(renderer.options.shadows.local_tiles_per_side, 1, local_shadow_tiles_per_side));
        for (cull_views.items[local_view_base..][0..lighting.tile_count]) |*cull| {
            cull.lod_camera = cull.camera_position;
            cull.lod_scale = tile_pixels * 0.5 / settings.geometry.lod_error_pixels;
        }
    }
    if (filled(settings.shadows).small_feature_texels > 0) for (0..gpu.cascade_count) |cascade| {
        cull_views.items[1 + cascade].min_radius = cascades.texel_size[cascade] * filled(settings.shadows).small_feature_texels * 0.5;
    };
    if (filled(settings.shadows).receiver_culling) for (0..cascade_total) |cascade| {
        if (filled(settings.shadows).cascade_stagger and cascade != 0) continue;
        receiver_culled[cascade] = true;
        const cull = &cull_views.items[1 + cascade];
        cull.receiver_culling = if (occlusion and desc.camera.orthographic == null) 2 else 1;
        cull.receiver_view = view_matrix;
        cull.receiver_p00 = proj_unjittered[0];
        cull.receiver_p11 = proj_unjittered[5];
        cull.receiver_near = desc.camera.near;
        cull.light_travel = sun_travel;
        cull.receiver_margin = filled(settings.shadows).softness + cascades.texel_size[cascade] * 6;
        @memcpy(cull.receiver_planes[0..4], cull_views.items[0].planes[0..4]);
        const starts = if (cascade == 0) desc.camera.near else cascades.splits[cascade - 1] * 0.9;
        cull.receiver_planes[4] = .{ -view_matrix[2], -view_matrix[6], -view_matrix[10], -view_matrix[14] - starts };
        cull.receiver_planes[5] = .{ view_matrix[2], view_matrix[6], view_matrix[10], view_matrix[14] + cascades.splits[cascade] };
    };
    cull_views.items[0].lod_band = lod_band;
    cull_views.items[main_late_view].lod_band = lod_band;
    if (filled(settings.shadows).transparent) for (cull_views.items, 0..) |*cull, index| {
        if (index != 0 and index != main_late_view) cull.blended_casters = 1;
    };
    cull_views_address = cull_views.address;
    cull_push = .{
        .frame = frame_address,
        .view = 0,
        .commands = 0,
        .counts = 0,
        .visibility = if (own.visibility) |buffer| device.bufferAddress(buffer) else 0,
        .ref_count = scene.ref_count,
        .bucket_capacity = renderer.internal.cull_capacity,
        .masked_capacity = renderer.internal.cull_masked_capacity,
        .phase = 0,
        .hiz_texture = device.textureIndex(own.hiz.?),
        .hiz_size = .{ @floatFromInt(own.hiz_width), @floatFromInt(own.hiz_height) },
        .skin_bounds = device.bufferAddress(scene.skin_bounds orelse renderer.internal.cull_counts),
        .seen = device.bufferAddress(scene.seen orelse renderer.internal.cull_counts),
        .entity_refs = scene.entity_ref_count,
        .seen_total = scene.entity_capacity + scene.static_count,
        .instance_visibility = device.bufferAddress(own.instance_visibility orelse renderer.internal.cull_counts),
        .entity_instances = scene.entity_capacity,
    };
    var culled: [view_count]bool = @splat(false);
    for (0..view_count) |index| {
        const is_cascade = index >= 1 and index <= gpu.cascade_count;
        const is_local = draw_local_shadows and index >= local_view_base and index < local_view_base + lighting.tile_count;
        if (index != 0 and !(is_cascade and cascade_update[(index -| 1) % gpu.cascade_count]) and !is_local) continue;
        if (is_cascade and occlusion and receiver_culled[index - 1]) continue;
        culled[index] = true;
    }
    var phases: [view_count]u32 = @splat(0);
    if (occlusion) phases[0] = 1;
    try cullViews(renderer, p, &cull_push, cull_views_address, &culled, &phases);
    cmd.endScope();
    return .{ .push = cull_push, .views = cull_views_address, .receiver_culled = receiver_culled };
}

/// Culls the views marked in `views`, each in its given phase: instance groups'
/// instances first, then meshlets.
pub fn cullViews(renderer: *Renderer, p: *const ScenePass, push: *CullPush, views_address: u64, views: *const [view_count]bool, phases: *const [view_count]u32) !void {
    const device = renderer.device;
    const cmd = p.cmd;
    const scene = p.scene;
    const candidates = if (scene.candidates) |buffer| device.bufferAddress(buffer) else 0;
    const dispatches = device.bufferAddress(renderer.internal.cull_dispatch);
    if (scene.static_count != 0) if (scene.static_cull) |bounds| {
        cmd.bindPipeline(try renderer.internal.pipelines.of(cullInstancesPipeline));
        for (views, 0..) |wanted, index| {
            if (!wanted) continue;
            cmd.pushConstants(InstanceCullPush{
                .frame = push.frame,
                .view = views_address + index * @sizeOf(gpu.CullView),
                .instances = device.bufferAddress(bounds),
                .candidates = candidates + @as(u64, index) * scene.candidate_capacity * @sizeOf(u32),
                .dispatch = dispatches + index * @sizeOf(gpu.CullDispatch),
                .visibility = push.instance_visibility,
                .instance_count = scene.static_count,
                .phase = phases[index],
                .hiz_texture = push.hiz_texture,
                .entity_refs = scene.entity_ref_count,
                .hiz_size = push.hiz_size,
                .impostors = if (scene.impostor_table) |table| device.bufferAddress(table) else 0,
                .impostor_list = if (scene.impostor_list) |list| device.bufferAddress(list) else 0,
                .impostor_draw = device.bufferAddress(renderer.internal.impostor_draw),
                .impostor_view = @intFromBool(scene.impostor_count != 0 and scene.impostor_list != null and (index == 0 or index == main_late_view)),
            });
            cmd.dispatch((scene.static_count + 63) / 64, 1, 1);
        }
        cmd.dependency(.{ .compute_write = true }, .{ .compute_read = true, .compute_write = true, .indirect = true });
    };
    cmd.bindPipeline(try renderer.internal.pipelines.of(cullPipeline));
    for (views, 0..) |wanted, index| {
        if (!wanted) continue;
        push.view = views_address + index * @sizeOf(gpu.CullView);
        push.commands = device.bufferAddress(renderer.internal.cull_commands.?) + commandOffset(renderer, index, 0);
        push.counts = device.bufferAddress(renderer.internal.cull_counts) + index * 2 * @sizeOf(u32);
        push.phase = phases[index];
        push.mark_seen = @intFromBool(scene.seen != null and (index == 0 or index == main_late_view));
        push.candidates = candidates + @as(u64, index) * scene.candidate_capacity * @sizeOf(u32);
        push.dispatch = dispatches + index * @sizeOf(gpu.CullDispatch);
        push.mesh_lists = if (device.caps.mesh_shaders) 1 else if (pulledDraws(renderer)) 2 else 0;
        push.lists = push.commands;
        push.mesh_draws = device.bufferAddress(renderer.internal.cull_mesh_draws) + index * 2 * @sizeOf(gpu.MeshDraw);
        cmd.pushConstants(push.*);
        cmd.dispatchIndirect(renderer.internal.cull_dispatch, index * @sizeOf(gpu.CullDispatch));
    }
    cmd.dependency(.{ .compute_write = true }, .{ .indirect = true, .graphics_read = true, .compute_read = true, .transfer_read = true });
}

/// Draws what culling listed for `view_index`, opaque then alpha-tested.
pub fn drawVisibility(renderer: *Renderer, cmd: *rhi.CommandEncoder, push: DrawPush, view_index: usize, max_draws: u32) !void {
    cmd.bindIndexBuffer(renderer.internal.indices.get(), 0, .uint32);
    cmd.bindPipeline(try renderer.internal.pipelines.of(visibilityPipeline));
    drawMeshlets(renderer, cmd, push, view_index, 0, max_draws);
    cmd.bindPipeline(try renderer.internal.pipelines.of(visibilityMaskedPipeline));
    drawMeshlets(renderer, cmd, push, view_index, 1, max_draws);
}

/// Builds the mip chain of farthest depths.
pub fn buildDepthPyramid(renderer: *Renderer, cmd: *rhi.CommandEncoder, view: *ViewState, own: *View) !void {
    const device = renderer.device;
    const Push = hiz_push.RasterPush;
    const sampler = device.samplerIndex(renderer.internal.sampler_nearest_clamp);
    if (device.caps.storage_images) {
        cmd.bindPipeline(try renderer.internal.pipelines.of(hizComputePipeline));
        for (0..own.hiz_mips) |mip| {
            const level: u32 = @intCast(mip);
            if (mip != 0) cmd.transitionMip(own.hiz.?, level - 1, .shader_read);
            cmd.transitionMip(own.hiz.?, level, .storage);
            const width = @max(own.hiz_width >> @intCast(mip), 1);
            const height = @max(own.hiz_height >> @intCast(mip), 1);
            cmd.pushConstants(hiz_push.ComputePush{
                .source_texture = device.textureIndex(if (mip == 0) view.depth else own.hiz.?),
                .sampler_index = sampler,
                .first = @intFromBool(mip == 0),
                .source_lod = if (mip == 0) 0 else @intCast(mip - 1),
                .target = try device.storageIndex(own.hiz.?, level, 0),
                .size = .{ @intCast(width), @intCast(height) },
            });
            cmd.dispatch((width + 7) / 8, (height + 7) / 8, 1);
        }
        cmd.transition(own.hiz.?, .shader_read);
        return;
    }
    for (0..own.hiz_mips) |mip| {
        if (mip != 0) cmd.transitionMip(own.hiz.?, @intCast(mip - 1), .shader_read);
        try cmd.beginRendering(.{ .color = &.{.{ .texture = own.hiz.?, .mip = @intCast(mip), .load = .discard }} });
        cmd.bindPipeline(try renderer.internal.pipelines.of(hizPipeline));
        cmd.pushConstants(Push{
            .source_texture = device.textureIndex(if (mip == 0) view.depth else own.hiz.?),
            .sampler_index = sampler,
            .first = @intFromBool(mip == 0),
            .source_lod = if (mip == 0) 0 else @intCast(mip - 1),
            .texel = .{ 1.0 / @as(f32, @floatFromInt(own.hiz_width)), 1.0 / @as(f32, @floatFromInt(own.hiz_height)) },
        });
        cmd.drawFullscreen();
        cmd.endRendering();
    }
}

/// Draws the visibility buffer and depth; with occlusion culling, a second
/// phase draws what the first phase's depth did not hide.
pub fn drawSceneVisibility(renderer: *Renderer, p: *const ScenePass, sun: *const SunShadows, culling: *const CullState) !void {
    const cmd = p.cmd;
    const desc = p.desc;
    const scene = p.scene;
    const view = p.view;
    const view_proj = p.view_proj;
    const has_geometry = p.has_geometry;
    const occlusion = p.occlusion;
    const visibility_lod = p.lod;
    const lod_band = p.lod_band;
    const frame_address = p.frame_address;
    const cascade_update = sun.update;
    const cull_views_address = culling.views;
    const receiver_culled = culling.receiver_culled;
    var cull_push = culling.push;
    cmd.beginScope("visibility");
    try cmd.beginRendering(.{
        .color = &.{.{ .texture = view.visibility, .clear_uint = .{ gpu.invalid_id, 0, 0, 0 } }},
        .depth = .{ .texture = view.depth, .clear = 0 },
    });
    if (has_geometry) try drawVisibility(renderer, cmd, DrawPush{ .frame = frame_address, .view_proj = view_proj, .lod = visibility_lod, .lod_band = lod_band, .lod_near = desc.camera.near }, 0, scene.ref_count);
    cmd.endRendering();
    cmd.endScope();

    if (occlusion) {
        cmd.beginScope("occlusion culling");
        try buildDepthPyramid(renderer, cmd, view, try features.stateOf(p.view_data, renderer.device, @This()));
        var culled: [view_count]bool = @splat(false);
        var phases: [view_count]u32 = @splat(0);
        culled[main_late_view] = true;
        phases[main_late_view] = 2;
        for (0..gpu.cascade_count) |cascade| culled[1 + cascade] = receiver_culled[cascade] and cascade_update[cascade];
        try cullViews(renderer, p, &cull_push, cull_views_address, &culled, &phases);
        try cmd.beginRendering(.{
            .color = &.{.{ .texture = view.visibility, .load = .load }},
            .depth = .{ .texture = view.depth, .load = .load },
        });
        try drawVisibility(renderer, cmd, DrawPush{ .frame = frame_address, .view_proj = view_proj, .lod = visibility_lod, .lod_band = lod_band, .lod_near = desc.camera.near }, main_late_view, scene.ref_count);
        cmd.endRendering();
        cmd.endScope();
    }
}

/// Answers a pending `pick` from this view's visibility buffer.
pub fn recordPick(renderer: *Renderer, p: *const ScenePass) !void {
    const device = renderer.device;
    const cmd = p.cmd;
    const frame = p.frame;
    const desc = p.desc;
    const scene_handle = p.scene_handle;
    const scene = p.scene;
    const view = p.view;
    const width = p.width;
    const height = p.height;
    const output_width = p.output_width;
    const output_height = p.output_height;
    const frame_address = p.frame_address;
    if (p.shared.pick) |request| {
        const slot: usize = @intCast(frame.index % rhi.frames_in_flight);
        if (request.pixel[0] < output_width and request.pixel[1] < output_height) {
            cmd.beginScope("pick");
            cmd.sync(.transfer_to_all);
            cmd.bindPipeline(try renderer.internal.pipelines.of(pickPipeline));
            cmd.pushConstants(pick_push.Push{
                .frame = frame_address,
                .result = device.bufferAddress(renderer.internal.pick_buffer),
                .visibility_texture = device.textureIndex(view.visibility),
                .depth_texture = device.textureIndex(view.depth),
                .pixel = .{
                    @intCast(@min(@as(u64, request.pixel[0]) * width / output_width, width - 1)),
                    @intCast(@min(@as(u64, request.pixel[1]) * height / output_height, height - 1)),
                },
            });
            cmd.dispatch(1, 1, 1);
            cmd.dependency(.{ .compute_write = true }, .{ .transfer_read = true });
            cmd.copyBuffer(renderer.internal.pick_buffer, renderer.internal.pick_readback[slot], 0, 0, @sizeOf(gpu.Pick));
            cmd.endScope();
            renderer.internal.pick_pending[slot] = .{
                .pixel = request.pixel,
                .scene = scene_handle,
                .layout_version = scene.layout_version,
                .depth_terms = view_math.depthTerms(desc.camera),
            };
        } else {
            renderer.internal.pick_result = .{ .pixel = request.pixel, .hit = null };
        }
    }
}

fn skinPipeline(_: *rhi.Device) pipelines_module.Desc {
    return .{ .compute = .{ .name = "skin", .shader = pipelines_module.shaderCode("skin.comp.spv") } };
}

fn skinBoundsPipeline(_: *rhi.Device) pipelines_module.Desc {
    return .{ .compute = .{ .name = "skin bounds", .shader = pipelines_module.shaderCode("skin_bounds.comp.spv") } };
}

fn cullPipeline(_: *rhi.Device) pipelines_module.Desc {
    return .{ .compute = .{ .name = "cull", .shader = pipelines_module.shaderCode("cull.comp.spv") } };
}

fn cullInstancesPipeline(_: *rhi.Device) pipelines_module.Desc {
    return .{ .compute = .{ .name = "cull instances", .shader = pipelines_module.shaderCode("cull_instances.comp.spv") } };
}

fn hizPipeline(_: *rhi.Device) pipelines_module.Desc {
    return pipelines_module.pass("depth pyramid", pipelines_module.shaderCode("hiz.frag.spv"), &.{.{ .format = .r32_float }});
}

fn hizComputePipeline(_: *rhi.Device) pipelines_module.Desc {
    return .{ .compute = .{ .name = "depth pyramid", .shader = pipelines_module.shaderCode("hiz.comp.spv") } };
}

fn visibilityPipeline(device: *rhi.Device) pipelines_module.Desc {
    return .{ .graphics = .{
        .name = "visibility",
        .vertex = pipelines_module.visibilityVertex(device),
        .mesh = if (device.caps.mesh_shaders) pipelines_module.shaderCode("visibility.mesh.spv") else null,
        .task = if (device.caps.mesh_shaders) pipelines_module.shaderCode("visibility.task.spv") else null,
        .fragment = if (pipelines_module.pulledDraws(device)) pipelines_module.shaderCode("visibility_pulled.frag.spv") else pipelines_module.shaderCode("visibility.frag.spv"),
        .color_targets = &.{.{ .format = .r32_uint }},
        .depth = .{},
        .cull = .back,
    } };
}

fn visibilityMaskedPipeline(device: *rhi.Device) pipelines_module.Desc {
    return .{ .graphics = .{
        .name = "visibility masked",
        .vertex = pipelines_module.visibilityVertex(device),
        .mesh = if (device.caps.mesh_shaders) pipelines_module.shaderCode("visibility.mesh.spv") else null,
        .task = if (device.caps.mesh_shaders) pipelines_module.shaderCode("visibility.task.spv") else null,
        .fragment = if (pipelines_module.pulledDraws(device)) pipelines_module.shaderCode("visibility_masked_pulled.frag.spv") else pipelines_module.shaderCode("visibility_masked.frag.spv"),
        .color_targets = &.{.{ .format = .r32_uint }},
        .depth = .{},
        .cull = .none,
    } };
}

fn pickPipeline(_: *rhi.Device) pipelines_module.Desc {
    return .{ .compute = .{ .name = "pick", .shader = pipelines_module.shaderCode("pick.comp.spv") } };
}
