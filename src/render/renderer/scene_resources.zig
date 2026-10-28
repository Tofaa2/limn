//! What only scenes use, made the first time a scene is drawn. Internal to the renderer.
const std = @import("std");
const rhi = @import("../../rhi/rhi.zig");
const gpu = @import("../gpu.zig");
const pipelines_module = @import("pipelines.zig");
const renderer_state = @import("../state.zig");
const render = @import("../renderer.zig");

const Renderer = render.Renderer;
const view_count = renderer_state.view_count;
/// Heitz et al. 2016, `src/third_party/ltc/LICENSE`: two 64 by 64 RGBA tables of f32.
const ltc_data = @embedFile("../../third_party/ltc/ltc.bin");

fn brdfLutPipeline(_: *rhi.Device) pipelines_module.Desc {
    return pipelines_module.pass("brdf lut", pipelines_module.shaderCode("brdf_lut.frag.spv"), &.{.{ .format = .rg16_float }});
}

/// Makes what only scenes use, the first time a scene is drawn: the
/// geometry pools, culling and picking buffers, shadow maps, light
/// clusters and the BRDF table. A renderer that draws no scene has none.
pub fn ensureSceneResources(self: *Renderer, cmd: *rhi.CommandEncoder) !void {
    if (self.internal.scene_ready) return;
    const device = self.device;
    inline for (.{ "vertices", "skin_vertices", "morph_deltas", "indices", "meshlets", "meshes" }) |name| try @field(self.internal, name).ensure(device);
    try self.internal.rays.ensure(device);
    try self.materials.internal.pool.ensure(device);

    var made: std.ArrayList(rhi.Buffer) = .empty;
    defer made.deinit(self.internal.gpa);
    errdefer for (made.items) |buffer| device.destroyBuffer(buffer);
    try made.ensureTotalCapacity(self.internal.gpa, 6 + 2 * rhi.frames_in_flight);
    const Local = struct {
        fn buffer(d: *rhi.Device, list: *std.ArrayList(rhi.Buffer), desc: rhi.BufferDesc) !rhi.Buffer {
            const result = try d.createBuffer(desc);
            list.appendAssumeCapacity(result);
            if (desc.memory == .gpu_to_cpu) @memset(d.mapped(result), 0);
            return result;
        }
    };
    const cull_counts = try Local.buffer(device, &made, .{ .name = "cull counts", .size = view_count * 2 * @sizeOf(u32), .usage = .{ .storage = true, .indirect = true, .copy_src = true } });
    const cull_mesh_draws = try Local.buffer(device, &made, .{ .name = "cull mesh draws", .size = view_count * 2 * @sizeOf(gpu.MeshDraw), .usage = .{ .storage = true, .indirect = true, .copy_dst = true } });
    const impostor_draw = try Local.buffer(device, &made, .{ .name = "impostor draw", .size = @sizeOf(gpu.DrawIndirect), .usage = .{ .storage = true, .indirect = true, .copy_dst = true } });
    const cull_dispatch = try Local.buffer(device, &made, .{ .name = "cull dispatch", .size = view_count * @sizeOf(gpu.CullDispatch), .usage = .{ .storage = true, .indirect = true, .copy_dst = true } });
    const clusters = try Local.buffer(device, &made, .{ .name = "light clusters", .size = gpu.cluster_count * @sizeOf(gpu.Cluster), .usage = .{ .storage = true } });
    const cluster_cursors = try Local.buffer(device, &made, .{ .name = "light cluster cursors", .size = gpu.cluster_count * @sizeOf(u32), .usage = .{ .storage = true, .copy_dst = true } });
    const pick_buffer = try Local.buffer(device, &made, .{ .name = "pick", .size = @sizeOf(gpu.Pick), .usage = .{ .storage = true, .copy_src = true } });
    var count_readback: [rhi.frames_in_flight]rhi.Buffer = undefined;
    for (&count_readback) |*buffer| buffer.* = try Local.buffer(device, &made, .{ .name = "cull count readback", .size = (view_count * 2 + 1) * @sizeOf(u32), .usage = .{}, .memory = .gpu_to_cpu });
    var pick_readback: [rhi.frames_in_flight]rhi.Buffer = undefined;
    for (&pick_readback) |*buffer| buffer.* = try Local.buffer(device, &made, .{ .name = "pick readback", .size = @sizeOf(gpu.Pick), .usage = .{}, .memory = .gpu_to_cpu });

    const local_shadow_map = try device.createTexture(.{
        .name = "local shadow atlas",
        .width = 1,
        .height = 1,
        .format = .depth32_float,
        .usage = .{ .sampled = true, .depth_attachment = true },
    });
    errdefer device.destroyTexture(local_shadow_map);
    const shadow_map = try device.createTexture(.{
        .name = "shadow fallback",
        .width = 1,
        .height = 1,
        .format = .depth32_float,
        .usage = .{ .sampled = true, .depth_attachment = true },
        .layers = gpu.cascade_count,
        .kind = .@"2d_array",
    });
    errdefer device.destroyTexture(shadow_map);
    const brdf_lut = try device.createTexture(.{
        .name = "brdf lut",
        .width = 128,
        .height = 128,
        .format = .rg16_float,
        .usage = .{ .sampled = true, .color_attachment = true },
    });
    errdefer device.destroyTexture(brdf_lut);
    const ltc_table = try device.createTexture(.{
        .name = "ltc table",
        .width = 64,
        .height = 128,
        .format = .rgba16_float,
        .usage = .{ .sampled = true, .copy_dst = true },
    });
    errdefer device.destroyTexture(ltc_table);
    const ltc_source: []align(1) const f32 = std.mem.bytesAsSlice(f32, ltc_data);
    const ltc_texels = try self.internal.gpa.alloc(f16, ltc_source.len);
    defer self.internal.gpa.free(ltc_texels);
    for (ltc_texels, ltc_source) |*texel, value| texel.* = @floatCast(value);
    try device.uploadTexture(ltc_table, 0, 0, std.mem.sliceAsBytes(ltc_texels));
    try cmd.flushUploads();

    const brdf_pipeline = try self.internal.pipelines.of(brdfLutPipeline);
    try cmd.beginRendering(.{ .color = &.{.{ .texture = brdf_lut, .load = .discard }} });
    cmd.bindPipeline(brdf_pipeline);
    cmd.drawFullscreen();
    cmd.endRendering();
    for (0..gpu.cascade_count) |cascade| {
        try cmd.beginRendering(.{ .depth = .{ .texture = shadow_map, .layer = @intCast(cascade), .clear = 1 } });
        cmd.endRendering();
    }
    try cmd.beginRendering(.{ .depth = .{ .texture = local_shadow_map, .clear = 0 } });
    cmd.endRendering();

    self.internal.cull_counts = cull_counts;
    self.internal.cull_mesh_draws = cull_mesh_draws;
    self.internal.impostor_draw = impostor_draw;
    self.internal.cull_dispatch = cull_dispatch;
    self.internal.clusters = clusters;
    self.internal.cluster_cursors = cluster_cursors;
    self.internal.pick_buffer = pick_buffer;
    self.internal.count_readback = count_readback;
    self.internal.pick_readback = pick_readback;
    self.internal.local_shadow_map = local_shadow_map;
    self.internal.shadow_map = shadow_map;
    self.internal.brdf_lut = brdf_lut;
    self.internal.ltc_table = ltc_table;
    self.internal.scene_ready = true;
}
