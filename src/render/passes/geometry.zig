//! Getting a scene's geometry onto the screen: deforming what is skinned,
//! culling, and drawing the visibility buffer that everything after reads.
//! Internal to the renderer.
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
const Lighting = scene_pass.Lighting;

/// Makes room in the buffers the culling writes to, and empties them:
/// the draw counts, which instances the cameras drew, and which
/// meshlets this view saw last frame.
pub fn resetCullBuffers(renderer: *Renderer, p: *const ScenePass, instance_total: u32) !void {
    const device = renderer.device;
    const cmd = p.cmd;
    const scene_handle = p.scene_handle;
    const scene = p.scene;
    const scene_frame = p.scene_frame;
    const fresh_scene = p.fresh_scene;
    const view_data = p.view_data;
    const mark_seen = p.mark_seen;
    if (mark_seen and instance_total > scene.seen_capacity) {
        if (scene.seen) |buffer| device.destroyBuffer(buffer);
        scene.seen = null;
        for (&scene.seen_readback) |*readback| {
            if (readback.*) |buffer| device.destroyBuffer(buffer);
            readback.* = null;
        }
        scene.seen_tags = @splat(.{});
        scene.seen_capacity = @max(instance_total + instance_total / 2, 1024);
        const size = @as(u64, scene.seen_capacity) * @sizeOf(u32);
        scene.seen = try device.createBuffer(.{ .name = "instances seen", .size = size, .usage = .{ .storage = true, .copy_src = true } });
        for (&scene.seen_readback) |*readback|
            readback.* = try device.createBuffer(.{ .name = "instances seen readback", .size = size, .usage = .{}, .memory = .gpu_to_cpu });
    }

    // Which meshlets this view saw last frame, for occlusion culling.
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
    if (view_data.visibility_scene == null or !std.meta.eql(view_data.visibility_scene.?, scene_handle) or
        view_data.visibility_layout != scene.layout_version) visibility_reset = true;
    view_data.visibility_scene = scene_handle;
    view_data.visibility_layout = scene.layout_version;

    // Last frame's draws and shaders must finish reading these buffers
    // before this frame's fills and compute passes overwrite them.
    cmd.sync(.all_to_transfer);
    cmd.fillBuffer(renderer.cull_counts, 0, view_count * 2 * @sizeOf(u32), 0);
    if (mark_seen and fresh_scene) cmd.fillBuffer(scene.seen.?, 0, @as(u64, instance_total) * @sizeOf(u32), 0);
    if (fresh_scene and scene_frame.staged_size != 0)
        cmd.copyBuffer(scene_frame.staged_buffer, scene.instance_slots[0].buffer.?, scene_frame.staged_instances, 0, scene_frame.staged_size);
    if (visibility_reset) {
        // Meshlet references were renumbered, or this view has not seen
        // this scene before; start from "everything was visible" so
        // the first frame draws in a single phase.
        if (view_data.visibility) |buffer| cmd.fillBuffer(buffer, 0, @as(u64, view_data.visibility_capacity) * @sizeOf(u32), 1);
    }
    cmd.sync(.transfer_to_all);
}

/// The triangles of `mesh`, for building its ray tracing structure.
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

/// Deforms the scene's skinned and morphed meshes, then brings their
/// meshlet bounds and ray tracing structures up to date.
pub fn skinScene(renderer: *Renderer, p: *const ScenePass) !void {
    const device = renderer.device;
    const cmd = p.cmd;
    const arena = p.arena;
    const scene = p.scene;
    const scene_frame = p.scene_frame;
    const fresh_scene = p.fresh_scene;
    cmd.beginScope("skinning");
    if (fresh_scene and renderer.skin_jobs.items.len != 0) {
        // Every mesh in one dispatch: the jobs go to the GPU as a
        // table, with a second one saying which job each work
        // group of 64 vertices belongs to.
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
        // Never empty, so the shader always has a list to index.
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
        // Rows of 1024 groups, as skin.comp expects.
        cmd.dispatch(@min(group_count, 1024), (group_count + 1023) / 1024, 1);
    }
    if (fresh_scene and renderer.bounds_jobs.items.len != 0) {
        // The deformed meshes' meshlet bounds, from the vertices
        // just written; the culling below reads them.
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
        // Deformed meshes: rebuild each one's acceleration structure
        // from the vertices just written.
        cmd.sync(.compute_to_all);
        // With a limit, the structures take turns from where the
        // round stopped last frame.
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

/// Where one culling view's draw commands start in the command buffer;
/// `bucket` is 0 for opaque meshlets and 1 for alpha-tested ones.
pub fn commandOffset(renderer: *const Renderer, view_index: usize, bucket: usize) u64 {
    return (@as(u64, view_index) * 2 + bucket) * renderer.cull_capacity * @sizeOf(gpu.DrawCommand);
}

/// Lists what each of the frame's views draws: the camera (its early
/// phase, when occlusion culling is on), the shadow cascades being
/// redrawn and the local lights' shadow tiles.
pub fn cullScene(renderer: *Renderer, p: *const ScenePass, sun: *const SunShadows, lighting: *const Lighting, draw_local_shadows: bool) !CullState {
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
    const mark_seen = p.mark_seen;
    const lod_band = p.lod_band;
    const frame_address = p.frame_address;
    const cascades = sun.cascades;
    const cascade_update = sun.update;
    const cascade_total = sun.count;
    if (!p.has_geometry) return std.mem.zeroes(CullState);
    var cull_push: CullPush = undefined;
    var cull_views_address: u64 = 0;
    // Cascades that leave out casters whose shadows the camera cannot see.
    var receiver_culled: [gpu.cascade_count]bool = @splat(false);
    if (scene.ref_count > renderer.cull_capacity) {
        if (renderer.cull_commands) |buffer| device.destroyBuffer(buffer);
        renderer.cull_capacity = scene.ref_count + scene.ref_count / 2;
        renderer.cull_commands = try device.createBuffer(.{
            .name = "cull commands",
            .size = @as(u64, renderer.cull_capacity) * view_count * 2 * @sizeOf(gpu.DrawCommand),
            .usage = .{ .storage = true, .indirect = true },
        });
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
    // Every view picks levels of detail by the main camera, so a
    // shadow is cast by the same geometry the camera sees.
    const lod_scale = p.lod[3];
    for (cull_views.items) |*cull| {
        cull.lod_camera = desc.camera.position;
        cull.lod_scale = lod_scale;
        cull.blended_casters = 0;
        cull.lod_band = 1;
        cull.min_radius = 0;
    }
    if (settings.shadow_lod == .light and settings.lod_error_pixels > 0) {
        // A local light's shadow tiles pick detail by how large
        // things are in the tile, seen from the light.
        const tile_pixels: f32 = @floatFromInt(renderer.options.local_shadow_resolution / std.math.clamp(renderer.options.local_shadow_tiles_per_side, 1, local_shadow_tiles_per_side));
        for (cull_views.items[local_view_base..][0..lighting.tile_count]) |*cull| {
            cull.lod_camera = cull.camera_position;
            cull.lod_scale = tile_pixels * 0.5 / settings.lod_error_pixels;
        }
    }
    // Sun shadows can leave out what is smaller than a few texels
    // of the cascade it would be drawn into.
    if (settings.shadow_small_feature_texels > 0) for (0..gpu.cascade_count) |cascade| {
        cull_views.items[1 + cascade].min_radius = cascades.texel_size[cascade] * settings.shadow_small_feature_texels * 0.5;
    };
    // A cascade drawn afresh every frame can leave out casters
    // whose shadows fall on nothing the camera sees. With a depth
    // pyramid to test against, those cascades are culled once it
    // has been built.
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
        // The filter reads this far to the side of a point, and
        // the point itself is moved a few texels off its surface.
        cull.receiver_margin = settings.shadow_softness + cascades.texel_size[cascade] * 6;
        @memcpy(cull.receiver_planes[0..4], cull_views.items[0].planes[0..4]);
        // The cascade shadows the view from where the one before
        // starts handing over to it up to its own far end.
        const starts = if (cascade == 0) desc.camera.near else cascades.splits[cascade - 1] * 0.9;
        cull.receiver_planes[4] = .{ -view_matrix[2], -view_matrix[6], -view_matrix[10], -view_matrix[14] - starts };
        cull.receiver_planes[5] = .{ view_matrix[2], view_matrix[6], view_matrix[10], view_matrix[14] + cascades.splits[cascade] };
    };
    // Only the camera's own passes cross-fade; shadows are cast by
    // both levels while they trade places.
    cull_views.items[0].lod_band = lod_band;
    cull_views.items[main_late_view].lod_band = lod_band;
    // Every view but the camera's two is a shadow view.
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
        .phase = 0,
        .hiz_texture = device.textureIndex(view.hiz),
        .hiz_size = .{ @floatFromInt(view.hiz_width), @floatFromInt(view.hiz_height) },
        // Any readable buffer will do when nothing has bounds.
        .skin_bounds = device.bufferAddress(scene.skin_bounds orelse renderer.cull_counts),
        .seen = device.bufferAddress(scene.seen orelse renderer.cull_counts),
    };
    cmd.bindPipeline(renderer.pipelines.cull);
    // The main view (early phase when occlusion culling) and the
    // shadow cascades.
    for (0..view_count) |index| {
        const is_cascade = index >= 1 and index <= gpu.cascade_count;
        const is_local = draw_local_shadows and index >= local_view_base and index < local_view_base + lighting.tile_count;
        if (index != 0 and !(is_cascade and cascade_update[(index -| 1) % gpu.cascade_count]) and !is_local) continue;
        // Left for after the depth pyramid.
        if (is_cascade and occlusion and receiver_culled[index - 1]) continue;
        cull_push.view = cull_views_address + index * @sizeOf(gpu.CullView);
        cull_push.commands = device.bufferAddress(renderer.cull_commands.?) + commandOffset(renderer, index, 0);
        cull_push.counts = device.bufferAddress(renderer.cull_counts) + index * 2 * @sizeOf(u32);
        cull_push.phase = if (index == 0 and occlusion) 1 else 0;
        cull_push.mark_seen = @intFromBool(mark_seen and index == 0);
        cmd.pushConstants(cull_push);
        cmd.dispatch((scene.ref_count + 63) / 64, 1, 1);
    }
    cmd.sync(.compute_to_all);
    cmd.endScope();
    return .{ .push = cull_push, .views = cull_views_address, .receiver_culled = receiver_culled };
}

/// Draws what culling listed for `view_index`, opaque then alpha-tested,
/// into the render pass that is open.
pub fn drawVisibility(renderer: *Renderer, cmd: *rhi.CommandEncoder, push: anytype, view_index: usize, max_draws: u32) void {
    cmd.bindIndexBuffer(renderer.indices.buffer, 0, .uint32);
    cmd.pushConstants(push);
    const counts_offset = view_index * 2 * @sizeOf(u32);
    cmd.bindPipeline(renderer.pipelines.visibility);
    cmd.drawIndexedIndirectCount(renderer.cull_commands.?, commandOffset(renderer, view_index, 0), renderer.cull_counts, counts_offset, max_draws);
    cmd.bindPipeline(renderer.pipelines.visibility_masked);
    cmd.drawIndexedIndirectCount(renderer.cull_commands.?, commandOffset(renderer, view_index, 1), renderer.cull_counts, counts_offset + @sizeOf(u32), max_draws);
}

/// Reduces the depth buffer into a mip chain of farthest depths.
pub fn buildDepthPyramid(renderer: *Renderer, cmd: *rhi.CommandEncoder, view: *ViewState) !void {
    const device = renderer.device;
    const Push = extern struct { source: u32, sampler: u32, first: u32, source_lod: i32, texel: [2]f32 };
    const sampler = device.samplerIndex(renderer.sampler_nearest_clamp);
    cmd.transition(view.depth, .shader_read);
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

/// Draws the visibility buffer and depth: what the culling listed, and
/// with occlusion culling a second phase of what the depth of the
/// first shows was not hidden after all.
pub fn drawSceneVisibility(renderer: *Renderer, p: *const ScenePass, sun: *const SunShadows, culling: *const CullState) !void {
    const device = renderer.device;
    const cmd = p.cmd;
    const desc = p.desc;
    const scene = p.scene;
    const view = p.view;
    const view_proj = p.view_proj;
    const has_geometry = p.has_geometry;
    const occlusion = p.occlusion;
    const mark_seen = p.mark_seen;
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
        // Late phase: whatever the early pass left visible through the
        // depth pyramid gets drawn now.
        cmd.beginScope("occlusion culling");
        try buildDepthPyramid(renderer, cmd, view);
        cmd.bindPipeline(renderer.pipelines.cull);
        cull_push.view = cull_views_address + main_late_view * @sizeOf(gpu.CullView);
        cull_push.commands = device.bufferAddress(renderer.cull_commands.?) + commandOffset(renderer, main_late_view, 0);
        cull_push.counts = device.bufferAddress(renderer.cull_counts) + main_late_view * 2 * @sizeOf(u32);
        cull_push.phase = 2;
        cull_push.mark_seen = @intFromBool(mark_seen);
        cmd.pushConstants(cull_push);
        cmd.dispatch((scene.ref_count + 63) / 64, 1, 1);
        // The cascades that test casters against what the camera sees.
        for (0..gpu.cascade_count) |cascade| {
            if (!receiver_culled[cascade] or !cascade_update[cascade]) continue;
            cull_push.view = cull_views_address + (1 + cascade) * @sizeOf(gpu.CullView);
            cull_push.commands = device.bufferAddress(renderer.cull_commands.?) + commandOffset(renderer, 1 + cascade, 0);
            cull_push.counts = device.bufferAddress(renderer.cull_counts) + (1 + cascade) * 2 * @sizeOf(u32);
            cull_push.phase = 0;
            cull_push.mark_seen = 0;
            cmd.pushConstants(cull_push);
            cmd.dispatch((scene.ref_count + 63) / 64, 1, 1);
        }
        cmd.sync(.compute_to_all);
        try cmd.beginRendering(.{
            .color = &.{.{ .texture = view.visibility, .load = .load }},
            .depth = .{ .texture = view.depth, .load = .load },
        });
        drawVisibility(renderer, cmd, DrawPush{ .frame = frame_address, .view_proj = view_proj, .lod = visibility_lod, .lod_band = lod_band, .lod_near = desc.camera.near }, main_late_view, scene.ref_count);
        cmd.endRendering();
        cmd.endScope();
    }
}

/// Answers a pending `pick` of this view from its visibility buffer.
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
            // The previous copy out of the buffer must finish first.
            cmd.sync(.transfer_to_all);
            cmd.bindPipeline(renderer.pipelines.pick);
            cmd.pushConstants(extern struct { frame: u64, result: u64, visibility: u32, depth: u32, pixel: [2]i32 }{
                .frame = frame_address,
                .result = device.bufferAddress(renderer.pick_buffer),
                .visibility = device.textureIndex(view.visibility),
                .depth = device.textureIndex(view.depth),
                // Asked in output pixels; the visibility buffer may be at another size.
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
