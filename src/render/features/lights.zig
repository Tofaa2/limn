//! Sorts a view's local lights and decals into clusters for shading to look up.
const rhi = @import("../../rhi/rhi.zig");
const math = @import("../../math.zig");
const pipelines_module = @import("../renderer/pipelines.zig");
const cluster_push = @import("../shaders/push/cluster.zig");
const features = @import("../core/features.zig");
const graph = @import("../core/graph.zig");
const prepareLights = @import("../renderer/scene_lights.zig").prepareLights;
const scene_pass = @import("../scene_pass.zig");
const ray_scene = @import("../scene/ray_scene.zig");
const renderer_state = @import("../state.zig");
const gpu = @import("../gpu.zig");
const api = @import("../api.zig");
const shading = @import("shading.zig");
const std = @import("std");

const cluster_far = renderer_state.cluster_far;
const cluster_near = renderer_state.cluster_near;
const ViewContext = features.ViewContext;
const Mat4 = math.Mat4;

/// `Shared` values this feature's `prepare` sets.
pub const provides = .{"lighting"};

/// Lists the scene's lights for this view and which of them cast shadows,
/// and makes room for the clusters' lists of them.
pub fn prepare(ctx: *ViewContext) !void {
    const p = ctx.scene orelse return;
    const settings = p.settings;
    const renderer = ctx.renderer;
    const traced = (if (settings.shadows) |shadows| shadows.traced_lights else false) and ray_scene.ready(p.scene, p.scene_frame);
    const lighting = try ctx.make(scene_pass.Lighting);
    lighting.* = try prepareLights(renderer, p.scene, p.arena, settings.shadows != null, p.desc.camera.position, traced);
    p.shared.lighting = lighting;
    const room = listRoom(lighting.records, p.scene.decals.items, p.view_matrix, p.proj_unjittered);
    const wanted: u32 = @intCast(@min(@max(room, 1), std.math.maxInt(u32) / 4));
    if (renderer.internal.cluster_lights == null or renderer.internal.cluster_lights_capacity < wanted) {
        if (renderer.internal.cluster_lights) |old| ctx.device.destroyBuffer(old);
        renderer.internal.cluster_lights = null;
        const capacity = wanted + wanted / 4;
        renderer.internal.cluster_lights = try ctx.device.createBuffer(.{ .name = "light cluster lists", .size = @as(u64, capacity) * @sizeOf(u32), .usage = .{ .storage = true } });
        renderer.internal.cluster_lights_capacity = capacity;
    }
    const c = ctx.constants;
    c.lights.light_count = lighting.light_count;
    c.lights.lights = lighting.lights;
    c.lights.shadow_tiles = lighting.tiles;
    c.lights.clusters = ctx.device.bufferAddress(renderer.internal.clusters);
    c.lights.light_indices = ctx.device.bufferAddress(renderer.internal.cluster_lights.?);
    c.lights.cluster_z_scale = renderer_state.cluster_z_scale;
    c.lights.cluster_z_bias = -@log2(renderer_state.cluster_near) * renderer_state.cluster_z_scale;
    c.lights.ltc_table = ctx.device.textureIndex(renderer.internal.ltc_table);
}

/// Most cluster list entries the lights and decals can take: for each, the
/// clusters its view-space box overlaps, one cluster wider all round. What
/// `cluster.slang` lists is never more.
fn listRoom(lights: []const gpu.Light, decals: []const api.DecalDesc, view: Mat4, proj: Mat4) u64 {
    var total: u64 = 0;
    for (lights) |light| {
        total += if (light.flags & gpu.light_directional != 0) gpu.cluster_count else sphereRoom(light.position, light.range, view, proj);
    }
    for (decals) |decal| {
        const bounds = shading.decalBounds(decal.transform);
        total += sphereRoom(bounds[0..3].*, bounds[3], view, proj);
    }
    return total;
}

/// The clusters a sphere's view-space box overlaps, one cluster wider all
/// round.
fn sphereRoom(position: math.Vec3, range: f32, view: Mat4, proj: Mat4) u64 {
    const z_bias = -@log2(cluster_near) * renderer_state.cluster_z_scale;
    const center = math.transformPoint(view, position);
    if (-center[2] + range <= 0) return 0;
    const near_depth = @max(-center[2] - range, 1e-4);
    const slices = [2]f32{ @log2(near_depth) * renderer_state.cluster_z_scale + z_bias, @log2(-center[2] + range) * renderer_state.cluster_z_scale + z_bias };
    const z_cells = cellSpan(slices[0], slices[1], gpu.clusters_z);
    var low: [2]f32 = .{ std.math.inf(f32), std.math.inf(f32) };
    var high: [2]f32 = .{ -std.math.inf(f32), -std.math.inf(f32) };
    var whole = false;
    for (0..8) |corner| {
        const at = math.Vec4{
            center[0] + (if (corner & 1 != 0) range else -range),
            center[1] + (if (corner & 2 != 0) range else -range),
            center[2] + (if (corner & 4 != 0) range else -range),
            1,
        };
        const clip = math.transformVec4(proj, at);
        if (clip[3] <= 1e-4) {
            whole = true;
            break;
        }
        for (0..2) |axis| {
            low[axis] = @min(low[axis], clip[axis] / clip[3]);
            high[axis] = @max(high[axis], clip[axis] / clip[3]);
        }
    }
    const x_cells: u64 = if (whole) gpu.clusters_x else cellSpan((low[0] * 0.5 + 0.5) * gpu.clusters_x, (high[0] * 0.5 + 0.5) * gpu.clusters_x, gpu.clusters_x);
    const y_cells: u64 = if (whole) gpu.clusters_y else cellSpan((low[1] * 0.5 + 0.5) * gpu.clusters_y, (high[1] * 0.5 + 0.5) * gpu.clusters_y, gpu.clusters_y);
    return x_cells * y_cells * z_cells;
}

/// Cells from the one `from` falls in to the one `to` falls in, widened by
/// one each side and kept within `cells`.
fn cellSpan(from: f32, to: f32, cells: u32) u64 {
    const top: f32 = @floatFromInt(cells - 1);
    const first = std.math.clamp(@floor(from) - 1, 0, top);
    const last = std.math.clamp(@floor(to) + 1, 0, top);
    return @intFromFloat(@max(last - first, 0) + 1);
}

pub fn declare(ctx: *ViewContext) !void {
    if (ctx.scene == null) return;
    const g = ctx.graph;
    const internal = &ctx.renderer.internal;
    const written = rhi.BufferAccess{ .compute_write = true, .compute_read = true, .transfer_write = true };
    try g.add(.{ .name = "light clusters", .stage = .lighting, .always = true, .scope = false, .buffers = &.{
        .{ .resource = try g.importBuffer(internal.clusters), .access = written },
        .{ .resource = try g.importBuffer(internal.cluster_lights.?), .access = written },
        .{ .resource = try g.importBuffer(internal.cluster_cursors), .access = written },
    } }, ctx, clusterLights);
}

/// What a pass that shades with the view's lights or decals declares: it
/// reads the clusters and their lists.
pub fn reads(ctx: *ViewContext) ![2]graph.BufferUse {
    const g = ctx.graph;
    const internal = &ctx.renderer.internal;
    return .{
        .{ .resource = try g.importBuffer(internal.clusters), .access = .{ .graphics_read = true } },
        .{ .resource = try g.importBuffer(internal.cluster_lights.?), .access = .{ .graphics_read = true } },
    };
}

fn clusterLights(ctx: *ViewContext) !void {
    const p = ctx.scene.?;
    const c = p.shared;
    const self = ctx.renderer;
    const cmd = p.cmd;
    const light_count = c.lighting.light_count;
    if (light_count == 0 and p.scene.decals.items.len == 0) return;
    const push = cluster_push.Push{
        .frame = p.frame_address,
        .cursors = ctx.device.bufferAddress(self.internal.cluster_cursors),
        .z_near = cluster_near,
        .z_ratio = std.math.pow(f32, cluster_far / cluster_near, 1.0 / @as(f32, gpu.clusters_z)),
        .capacity = self.internal.cluster_lights_capacity,
    };
    cmd.beginScope("light clusters");
    cmd.fillBuffer(self.internal.cluster_cursors, 0, @sizeOf(u32), 0);
    cmd.dependency(.{ .transfer_write = true }, .{ .compute_read = true, .compute_write = true });
    cmd.bindPipeline(try self.internal.pipelines.of(clusterPipeline));
    cmd.pushConstants(push);
    cmd.dispatch(gpu.cluster_count, 1, 1);
    cmd.dependency(.{ .compute_write = true }, .{ .compute_read = true, .graphics_read = true });
    cmd.endScope();
}

fn clusterPipeline(_: *rhi.Device) pipelines_module.Desc {
    return .{ .compute = .{ .name = "light clusters", .shader = pipelines_module.shaderCode("cluster.comp.spv") } };
}
