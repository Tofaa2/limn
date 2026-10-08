//! Scene geometry: skinning, culling and the visibility buffer. Internal to the
//! renderer.
const std = @import("std");
const rhi = @import("../../rhi/rhi.zig");
const gpu = @import("../gpu.zig");
const render = @import("../renderer.zig");
const scene_pass = @import("../scene_pass.zig");

const Renderer = render.Renderer;
const view_count = render.view_count;
const BoundsJob = render.BoundsJob;
const SkinJob = render.SkinJob;
const cullView = render.cullView;
const local_shadow_tiles_per_side = render.local_shadow_tiles_per_side;
const local_view_base = render.local_view_base;
const main_late_view = render.main_late_view;
const ModelMesh = render.ModelMesh;
const ViewState = render.ViewState;
const ScenePass = scene_pass.ScenePass;
const SunShadows = scene_pass.SunShadows;
const CullState = scene_pass.CullState;
const DrawPush = scene_pass.DrawPush;
const CullPush = scene_pass.CullPush;
const InstanceCullPush = scene_pass.InstanceCullPush;
const Lighting = scene_pass.Lighting;

/// Meshlet headroom in the draw command buffer beyond the scene's count.
const cull_headroom = 1 << 16;

/// Sizes and clears the buffers culling writes: draw counts, instance seen
/// flags and last frame's meshlet visibility.
pub fn resetCullBuffers(renderer: *Renderer, p: *const ScenePass, instance_total: u32) !void {
    const device = renderer.device;
    const cmd = p.cmd;
    const scene_handle = p.scene_handle;
    const scene = p.scene;
    const scene_frame = p.scene_frame;
    const fresh_scene = p.fresh_scene;
    const view_data = p.view_data;
    const mark_seen = p.mark_seen;
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
    if (scene.refs_capacity != 0 and view_data.visibility_capacity < scene.refs_capacity) {
        if (view_data.visibility) |buffer| device.destroyBuffer(buffer);
        view_data.visibility = null;
        view_data.visibility = try device.createBuffer(.{
            .name = "meshlet visibility",
            .size = @as(u64, scene.refs_capacity) * @sizeOf(u32),
            .usage = .{ .storage = true },
        });
        view_data.visibility_capacity = scene.refs_capacity;
        visibility_reset = true;
    }
    if (scene.static_count > view_data.instance_visibility_capacity) {
        if (view_data.instance_visibility) |buffer| device.destroyBuffer(buffer);
        view_data.instance_visibility = null;
        const capacity = scene.static_count + @min(scene.static_count / 2, cull_headroom);
        view_data.instance_visibility = try device.createBuffer(.{
            .name = "instance visibility",
            .size = @as(u64, capacity) * @sizeOf(u32),
            .usage = .{ .storage = true },
        });
        view_data.instance_visibility_capacity = capacity;
        visibility_reset = true;
    }
    if (view_data.visibility_scene == null or !std.meta.eql(view_data.visibility_scene.?, scene_handle) or
        view_data.visibility_layout != scene.layout_version) visibility_reset = true;
    view_data.visibility_scene = scene_handle;
    view_data.visibility_layout = scene.layout_version;

    cmd.sync(.all_to_transfer);
    cmd.fillBuffer(renderer.cull_counts, 0, view_count * 2 * @sizeOf(u32), 0);
    const dispatches = try p.arena.alloc(device, gpu.CullDispatch, view_count);
    @memset(dispatches.items, .{ .x = (scene.entity_ref_count + 63) / 64 });
    cmd.copyBuffer(dispatches.buffer, renderer.cull_dispatch, dispatches.offset, 0, view_count * @sizeOf(gpu.CullDispatch));
    if (scene.impostor_count != 0) {
        if (scene.static_count > scene.impostor_list_capacity) {
            if (scene.impostor_list) |buffer| device.destroyBuffer(buffer);
            scene.impostor_list = null;
            const capacity = scene.static_count + @min(scene.static_count / 2, cull_headroom);
            scene.impostor_list = try device.createBuffer(.{ .name = "impostor list", .size = @as(u64, capacity) * @sizeOf(u32), .usage = .{ .storage = true } });
            scene.impostor_list_capacity = capacity;
        }
        const draw = try p.arena.alloc(device, gpu.DrawIndirect, 1);
        draw.items[0] = .{ .vertex_count = 6 };
        cmd.copyBuffer(draw.buffer, renderer.impostor_draw, draw.offset, 0, @sizeOf(gpu.DrawIndirect));
    }
    if (device.mesh_shaders) {
        const draws = try p.arena.alloc(device, gpu.MeshDraw, view_count * 2);
        @memset(draws.items, .{});
        cmd.copyBuffer(draws.buffer, renderer.cull_mesh_draws, draws.offset, 0, view_count * 2 * @sizeOf(gpu.MeshDraw));
    }
    if (fresh_scene) cmd.fillBuffer(scene.seen.?, 0, (@as(u64, instance_total) + 1) * @sizeOf(u32), 0);
    if (fresh_scene and scene_frame.staged_size != 0)
        cmd.copyBuffer(scene_frame.staged_buffer, scene.instance_slots[0].buffer.?, scene_frame.staged_instances, 0, scene_frame.staged_size);
    if (visibility_reset) {
        if (view_data.visibility) |buffer| cmd.fillBuffer(buffer, 0, @as(u64, view_data.visibility_capacity) * @sizeOf(u32), 1);
        if (view_data.instance_visibility) |buffer| cmd.fillBuffer(buffer, 0, @as(u64, view_data.instance_visibility_capacity) * @sizeOf(u32), 1);
    }
    cmd.sync(.transfer_to_all);
}

/// Triangles of `mesh`, for building its BLAS.
pub fn blasDesc(renderer: *Renderer, mesh: ModelMesh) rhi.BlasDesc {
    return .{
        .vertices = renderer.vertices.buffer,
        .vertex_offset = @as(u64, mesh.vertex_offset) * @sizeOf(gpu.Vertex),
        .vertex_count = mesh.vertex_count,
        .vertex_stride = @sizeOf(gpu.Vertex),
        .indices = renderer.indices.buffer,
        .index_offset = @as(u64, mesh.index_offset) * @sizeOf(u32),
        .index_count = mesh.lod0_index_count,
    };
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
    if (fresh_scene and renderer.skin_jobs.items.len != 0) {
        var group_count: u32 = 0;
        for (renderer.skin_jobs.items) |*job| {
            job.first_group = group_count;
            group_count += (job.vertex_count + 63) / 64;
        }
        const jobs = try arena.alloc(device, SkinJob, renderer.skin_jobs.items.len);
        @memcpy(jobs.items, renderer.skin_jobs.items);
        const group_jobs = try arena.alloc(device, u32, group_count);
        for (renderer.skin_jobs.items, 0..) |job, index| {
            @memset(group_jobs.items[job.first_group..][0 .. (job.vertex_count + 63) / 64], @intCast(index));
        }
        cmd.bindPipeline(renderer.pipelines.skin);
        const weights = try arena.alloc(device, f32, @max(renderer.skin_weights.items.len, 1));
        weights.items[0] = 0;
        @memcpy(weights.items[0..renderer.skin_weights.items.len], renderer.skin_weights.items);
        cmd.pushConstants(extern struct { vertices: u64, skin: u64, joints: u64, morph: u64, jobs: u64, group_jobs: u64, weights: u64, group_count: u32, pad: u32 = 0 }{
            .weights = weights.address,
            .vertices = device.bufferAddress(renderer.vertices.buffer),
            .skin = device.bufferAddress(renderer.skin_vertices.buffer),
            .joints = scene_frame.joints,
            .morph = device.bufferAddress(renderer.morph_deltas.buffer),
            .jobs = jobs.address,
            .group_jobs = group_jobs.address,
            .group_count = group_count,
        });
        cmd.dispatch(@min(group_count, 1024), (group_count + 1023) / 1024, 1);
    }
    if (fresh_scene and renderer.bounds_jobs.items.len != 0) {
        cmd.sync(.compute_to_all);
        var group_count: u32 = 0;
        for (renderer.bounds_jobs.items) |*job| {
            job.first_group = group_count;
            group_count += (job.meshlet_count + 63) / 64;
        }
        const jobs = try arena.alloc(device, BoundsJob, renderer.bounds_jobs.items.len);
        @memcpy(jobs.items, renderer.bounds_jobs.items);
        const group_jobs = try arena.alloc(device, u32, group_count);
        for (renderer.bounds_jobs.items, 0..) |job, index| {
            @memset(group_jobs.items[job.first_group..][0 .. (job.meshlet_count + 63) / 64], @intCast(index));
        }
        cmd.bindPipeline(renderer.pipelines.skin_bounds);
        cmd.pushConstants(extern struct { vertices: u64, indices: u64, meshlets: u64, bounds: u64, jobs: u64, group_jobs: u64, group_count: u32, pad: u32 = 0 }{
            .vertices = device.bufferAddress(renderer.vertices.buffer),
            .indices = device.bufferAddress(renderer.indices.buffer),
            .meshlets = device.bufferAddress(renderer.meshlets.buffer),
            .bounds = device.bufferAddress(scene.skin_bounds.?),
            .jobs = jobs.address,
            .group_jobs = group_jobs.address,
            .group_count = group_count,
        });
        cmd.dispatch(@min(group_count, 1024), (group_count + 1023) / 1024, 1);
    }
    if (fresh_scene and renderer.blas_jobs.items.len != 0 and scene.tlas != null) {
        cmd.sync(.compute_to_all);
        const jobs = renderer.blas_jobs.items;
        const budget: usize = if (renderer.options.gi_dynamic_refits == 0) jobs.len else @min(renderer.options.gi_dynamic_refits, jobs.len);
        const first = renderer.refit_cursor % jobs.len;
        renderer.refit_cursor = (first + budget) % jobs.len;
        for (jobs, 0..) |job, index| {
            const turn = (index + jobs.len - first) % jobs.len < budget;
            if (!turn and device.accelerationBuilt(job.blas)) continue;
            var job_desc = blasDesc(renderer, job.mesh);
            job_desc.vertex_offset = @as(u64, job.vertex_offset) * @sizeOf(gpu.Vertex);
            job_desc.dynamic = true;
            try cmd.buildBlas(job.blas, job_desc);
        }
    }
    cmd.endScope();
}

/// Offset of a culling view's draw commands; `bucket` is 0 for opaque and 1 for
/// alpha-tested meshlets.
pub fn commandOffset(renderer: *const Renderer, view_index: usize, bucket: usize) u64 {
    const per_view = @as(u64, renderer.cull_capacity) + renderer.cull_masked_capacity;
    return (view_index * per_view + bucket * renderer.cull_capacity) * commandSize(renderer);
}

/// Bytes culling writes per drawn meshlet: a draw command, or a bare reference
/// with mesh shaders.
fn commandSize(renderer: *const Renderer) u64 {
    return if (renderer.device.mesh_shaders) @sizeOf(u32) else @sizeOf(gpu.DrawCommand);
}

/// Draws one of a view's two meshlet lists with the bound pipeline. `bucket` 0:
/// opaque; 1: alpha-tested, two-sided or fading.
pub fn drawMeshlets(renderer: *Renderer, cmd: *rhi.CommandEncoder, push: DrawPush, view_index: usize, bucket: usize, max_draws: u32) void {
    const counts_offset = (view_index * 2 + bucket) * @sizeOf(u32);
    if (renderer.device.mesh_shaders) {
        var with_list = push;
        with_list.list = renderer.device.bufferAddress(renderer.cull_commands.?) + commandOffset(renderer, view_index, bucket);
        with_list.count = renderer.device.bufferAddress(renderer.cull_counts) + counts_offset;
        cmd.pushConstants(with_list);
        cmd.drawMeshTasksIndirect(renderer.cull_mesh_draws, (view_index * 2 + bucket) * @sizeOf(gpu.MeshDraw));
        return;
    }
    cmd.pushConstants(push);
    cmd.drawIndexedIndirectCount(renderer.cull_commands.?, commandOffset(renderer, view_index, bucket), renderer.cull_counts, counts_offset, if (bucket == 0) max_draws else @min(max_draws, renderer.cull_masked_capacity));
}

/// Culls for each of the frame's views: the camera (early phase with occlusion
/// culling), the cascades being redrawn and local shadow tiles.
pub fn cullScene(renderer: *Renderer, p: *const ScenePass, sun: *const SunShadows, lighting: *const Lighting, draw_local_shadows: bool) !CullState {
    const views_wanted: u32 = if (p.settings.virtual_shadow_maps) view_count else if (lighting.tile_count == 0) local_view_base else render.vsm_view_base;
    const device = renderer.device;
    const cmd = p.cmd;
    const arena = p.arena;
    const desc = p.desc;
    const settings = p.settings;
    const scene = p.scene;
    const view_data = p.view_data;
    const view = p.view;
    const view_matrix = p.view_matrix;
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
    const masked_wanted = if (p.lod_band > 1) scene.ref_count else scene.masked_ref_count;
    if (renderer.cull_commands == null or scene.ref_count > renderer.cull_capacity or masked_wanted > renderer.cull_masked_capacity or views_wanted > renderer.cull_views) {
        if (renderer.cull_commands) |buffer| device.destroyBuffer(buffer);
        renderer.cull_commands = null;
        const capacity = scene.ref_count + @min(scene.ref_count / 2, cull_headroom);
        const masked_capacity = @max(@min(masked_wanted + @min(masked_wanted / 2, cull_headroom), capacity), 1);
        const views = @max(renderer.cull_views, views_wanted);
        renderer.cull_commands = try device.createBuffer(.{
            .name = "cull commands",
            .size = (@as(u64, capacity) + masked_capacity) * views * commandSize(renderer),
            .usage = .{ .storage = true, .indirect = true },
        });
        renderer.cull_capacity = capacity;
        renderer.cull_masked_capacity = masked_capacity;
        renderer.cull_views = views;
    }

    const static_refs = scene.ref_count - scene.entity_ref_count;
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
    cmd.beginScope("culling");
    const cull_views = try arena.alloc(device, gpu.CullView, view_count);
    cull_views.items[0] = cullView(view_proj_unjittered, desc.camera.position, .perspective);
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
        cull.lens_shift = .{ -proj_unjittered[8], -proj_unjittered[9] };
        cull.lod_camera = desc.camera.position;
        cull.lod_scale = lod_scale;
        cull.blended_casters = 0;
        cull.lod_band = 1;
        cull.min_radius = 0;
    }
    if (settings.shadow_lod == .light and settings.lod_error_pixels > 0) {
        const tile_pixels: f32 = @floatFromInt(renderer.options.local_shadow_resolution / std.math.clamp(renderer.options.local_shadow_tiles_per_side, 1, local_shadow_tiles_per_side));
        for (cull_views.items[local_view_base..][0..lighting.tile_count]) |*cull| {
            cull.lod_camera = cull.camera_position;
            cull.lod_scale = tile_pixels * 0.5 / settings.lod_error_pixels;
        }
    }
    if (settings.shadow_small_feature_texels > 0) for (0..gpu.cascade_count) |cascade| {
        cull_views.items[1 + cascade].min_radius = cascades.texel_size[cascade] * settings.shadow_small_feature_texels * 0.5;
    };
    if (settings.shadow_receiver_culling) for (0..cascade_total) |cascade| {
        if (settings.shadow_cascade_stagger and cascade != 0) continue;
        receiver_culled[cascade] = true;
        const cull = &cull_views.items[1 + cascade];
        cull.receiver_culling = if (occlusion) 2 else 1;
        cull.receiver_view = view_matrix;
        cull.receiver_p00 = proj_unjittered[0];
        cull.receiver_p11 = proj_unjittered[5];
        cull.receiver_near = desc.camera.near;
        cull.light_travel = sun_travel;
        cull.receiver_margin = settings.shadow_softness + cascades.texel_size[cascade] * 6;
        @memcpy(cull.receiver_planes[0..4], cull_views.items[0].planes[0..4]);
        const starts = if (cascade == 0) desc.camera.near else cascades.splits[cascade - 1] * 0.9;
        cull.receiver_planes[4] = .{ -view_matrix[2], -view_matrix[6], -view_matrix[10], -view_matrix[14] - starts };
        cull.receiver_planes[5] = .{ view_matrix[2], view_matrix[6], view_matrix[10], view_matrix[14] + cascades.splits[cascade] };
    };
    cull_views.items[0].lod_band = lod_band;
    cull_views.items[main_late_view].lod_band = lod_band;
    if (settings.transparent_shadows) for (cull_views.items, 0..) |*cull, index| {
        if (index != 0 and index != main_late_view) cull.blended_casters = 1;
    };
    cull_views_address = cull_views.address;
    cull_push = .{
        .frame = frame_address,
        .view = 0,
        .commands = 0,
        .counts = 0,
        .visibility = if (view_data.visibility) |buffer| device.bufferAddress(buffer) else 0,
        .ref_count = scene.ref_count,
        .bucket_capacity = renderer.cull_capacity,
        .masked_capacity = renderer.cull_masked_capacity,
        .phase = 0,
        .hiz_texture = device.textureIndex(view.hiz),
        .hiz_size = .{ @floatFromInt(view.hiz_width), @floatFromInt(view.hiz_height) },
        .skin_bounds = device.bufferAddress(scene.skin_bounds orelse renderer.cull_counts),
        .seen = device.bufferAddress(scene.seen orelse renderer.cull_counts),
        .entity_refs = scene.entity_ref_count,
        .seen_total = @as(u32, @intCast(scene.layout.items.len)) + scene.static_count,
        .instance_visibility = device.bufferAddress(view_data.instance_visibility orelse renderer.cull_counts),
        .entity_instances = @intCast(scene.layout.items.len),
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
    cullViews(renderer, p, &cull_push, cull_views_address, &culled, &phases);
    cmd.endScope();
    return .{ .push = cull_push, .views = cull_views_address, .receiver_culled = receiver_culled };
}

/// Culls the views marked in `views`, each in its given phase: instance groups'
/// instances first, then meshlets.
pub fn cullViews(renderer: *Renderer, p: *const ScenePass, push: *CullPush, views_address: u64, views: *const [view_count]bool, phases: *const [view_count]u32) void {
    const device = renderer.device;
    const cmd = p.cmd;
    const scene = p.scene;
    const candidates = if (scene.candidates) |buffer| device.bufferAddress(buffer) else 0;
    const dispatches = device.bufferAddress(renderer.cull_dispatch);
    if (scene.static_count != 0) if (scene.static_cull) |bounds| {
        cmd.bindPipeline(renderer.pipelines.cull_instances);
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
                .impostor_draw = device.bufferAddress(renderer.impostor_draw),
                .impostor_view = @intFromBool(scene.impostor_count != 0 and scene.impostor_list != null and (index == 0 or index == main_late_view)),
            });
            cmd.dispatch((scene.static_count + 63) / 64, 1, 1);
        }
        cmd.sync(.compute_to_all);
    };
    cmd.bindPipeline(renderer.pipelines.cull);
    for (views, 0..) |wanted, index| {
        if (!wanted) continue;
        push.view = views_address + index * @sizeOf(gpu.CullView);
        push.commands = device.bufferAddress(renderer.cull_commands.?) + commandOffset(renderer, index, 0);
        push.counts = device.bufferAddress(renderer.cull_counts) + index * 2 * @sizeOf(u32);
        push.phase = phases[index];
        push.mark_seen = @intFromBool(scene.seen != null and (index == 0 or index == main_late_view));
        push.candidates = candidates + @as(u64, index) * scene.candidate_capacity * @sizeOf(u32);
        push.dispatch = dispatches + index * @sizeOf(gpu.CullDispatch);
        push.mesh_lists = @intFromBool(device.mesh_shaders);
        push.lists = push.commands;
        push.mesh_draws = device.bufferAddress(renderer.cull_mesh_draws) + index * 2 * @sizeOf(gpu.MeshDraw);
        cmd.pushConstants(push.*);
        cmd.dispatchIndirect(renderer.cull_dispatch, index * @sizeOf(gpu.CullDispatch));
    }
    cmd.sync(.compute_to_all);
}

/// Draws what culling listed for `view_index`, opaque then alpha-tested.
pub fn drawVisibility(renderer: *Renderer, cmd: *rhi.CommandEncoder, push: DrawPush, view_index: usize, max_draws: u32) void {
    cmd.bindIndexBuffer(renderer.indices.buffer, 0, .uint32);
    cmd.bindPipeline(renderer.pipelines.visibility);
    drawMeshlets(renderer, cmd, push, view_index, 0, max_draws);
    cmd.bindPipeline(renderer.pipelines.visibility_masked);
    drawMeshlets(renderer, cmd, push, view_index, 1, max_draws);
}

/// Builds the mip chain of farthest depths.
pub fn buildDepthPyramid(renderer: *Renderer, cmd: *rhi.CommandEncoder, view: *ViewState) !void {
    const device = renderer.device;
    const Push = extern struct { source: u32, sampler: u32, first: u32, source_lod: i32, texel: [2]f32 };
    const sampler = device.samplerIndex(renderer.sampler_nearest_clamp);
    cmd.transition(view.depth, .shader_read);
    if (renderer.pipelines.hiz_compute) |pipeline| {
        cmd.bindPipeline(pipeline);
        for (0..view.hiz_mips) |mip| {
            const level: u32 = @intCast(mip);
            if (mip != 0) cmd.transitionMip(view.hiz, level - 1, .shader_read);
            cmd.transitionMip(view.hiz, level, .storage);
            const width = @max(view.hiz_width >> @intCast(mip), 1);
            const height = @max(view.hiz_height >> @intCast(mip), 1);
            cmd.pushConstants(extern struct { source: u32, sampler: u32, first: u32, source_lod: i32, target: u32, pad: u32 = 0, size: [2]i32 }{
                .source = device.textureIndex(if (mip == 0) view.depth else view.hiz),
                .sampler = sampler,
                .first = @intFromBool(mip == 0),
                .source_lod = if (mip == 0) 0 else @intCast(mip - 1),
                .target = try device.storageIndex(view.hiz, level),
                .size = .{ @intCast(width), @intCast(height) },
            });
            cmd.dispatch((width + 7) / 8, (height + 7) / 8, 1);
        }
        cmd.transition(view.hiz, .shader_read);
        return;
    }
    for (0..view.hiz_mips) |mip| {
        if (mip != 0) cmd.transitionMip(view.hiz, @intCast(mip - 1), .shader_read);
        try cmd.beginRendering(.{ .color = &.{.{ .texture = view.hiz, .mip = @intCast(mip), .load = .discard }} });
        cmd.bindPipeline(renderer.pipelines.hiz);
        cmd.pushConstants(Push{
            .source = device.textureIndex(if (mip == 0) view.depth else view.hiz),
            .sampler = sampler,
            .first = @intFromBool(mip == 0),
            .source_lod = if (mip == 0) 0 else @intCast(mip - 1),
            .texel = .{ 1.0 / @as(f32, @floatFromInt(view.hiz_width)), 1.0 / @as(f32, @floatFromInt(view.hiz_height)) },
        });
        cmd.drawFullscreen();
        cmd.endRendering();
    }
    cmd.transition(view.hiz, .shader_read);
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
    if (has_geometry) drawVisibility(renderer, cmd, DrawPush{ .frame = frame_address, .view_proj = view_proj, .lod = visibility_lod, .lod_band = lod_band, .lod_near = desc.camera.near }, 0, scene.ref_count);
    cmd.endRendering();
    cmd.endScope();

    if (occlusion) {
        cmd.beginScope("occlusion culling");
        try buildDepthPyramid(renderer, cmd, view);
        var culled: [view_count]bool = @splat(false);
        var phases: [view_count]u32 = @splat(0);
        culled[main_late_view] = true;
        phases[main_late_view] = 2;
        for (0..gpu.cascade_count) |cascade| culled[1 + cascade] = receiver_culled[cascade] and cascade_update[cascade];
        cullViews(renderer, p, &cull_push, cull_views_address, &culled, &phases);
        try cmd.beginRendering(.{
            .color = &.{.{ .texture = view.visibility, .load = .load }},
            .depth = .{ .texture = view.depth, .load = .load },
        });
        drawVisibility(renderer, cmd, DrawPush{ .frame = frame_address, .view_proj = view_proj, .lod = visibility_lod, .lod_band = lod_band, .lod_near = desc.camera.near }, main_late_view, scene.ref_count);
        cmd.endRendering();
        cmd.endScope();
    }
}

/// Answers a pending `pick` from this view's visibility buffer.
pub fn recordPick(renderer: *Renderer, p: *const ScenePass) void {
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
    if (renderer.pick_request) |request| if (std.meta.eql(request.view, desc.view orelse renderer.main_view)) {
        renderer.pick_request = null;
        const slot: usize = @intCast(frame.index % rhi.frames_in_flight);
        if (request.pixel[0] < output_width and request.pixel[1] < output_height) {
            cmd.beginScope("pick");
            cmd.sync(.transfer_to_all);
            cmd.bindPipeline(renderer.pipelines.pick);
            cmd.pushConstants(extern struct { frame: u64, result: u64, visibility: u32, depth: u32, pixel: [2]i32 }{
                .frame = frame_address,
                .result = device.bufferAddress(renderer.pick_buffer),
                .visibility = device.textureIndex(view.visibility),
                .depth = device.textureIndex(view.depth),
                .pixel = .{
                    @intCast(@min(@as(u64, request.pixel[0]) * width / output_width, width - 1)),
                    @intCast(@min(@as(u64, request.pixel[1]) * height / output_height, height - 1)),
                },
            });
            cmd.dispatch(1, 1, 1);
            cmd.sync(.compute_to_all);
            cmd.copyBuffer(renderer.pick_buffer, renderer.pick_readback[slot], 0, 0, @sizeOf(gpu.Pick));
            cmd.endScope();
            renderer.pick_pending[slot] = .{
                .pixel = request.pixel,
                .scene = scene_handle,
                .layout_version = scene.layout_version,
                .near = desc.camera.near,
            };
        } else {
            renderer.pick_result = .{ .pixel = request.pixel, .hit = null };
        }
    };
}
