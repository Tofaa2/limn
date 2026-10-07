//! Impostors: baking their atlases and drawing them. Internal to the renderer.
const std = @import("std");
const rhi = @import("../../rhi/rhi.zig");
const gpu = @import("../gpu.zig");
const math = @import("../../math.zig");
const render = @import("../renderer.zig");
const scene_pass = @import("../scene_pass.zig");

const Renderer = render.Renderer;
const ScenePass = scene_pass.ScenePass;
const Vec3 = math.Vec3;

/// Tiles per atlas side. Must match `impostor_frames` in impostor.glsl.
pub const frames = 8;

/// Must match `impostorUnfold` in impostor.glsl.
fn unfold(place: [2]f32) Vec3 {
    const e = [2]f32{ place[0] * 2 - 1, place[1] * 2 - 1 };
    var direction = Vec3{ e[0], e[1], 1 - @abs(e[0]) - @abs(e[1]) };
    if (direction[2] < 0) {
        const x = (1 - @abs(direction[1])) * @as(f32, if (direction[0] >= 0) 1 else -1);
        const y = (1 - @abs(direction[0])) * @as(f32, if (direction[1] >= 0) 1 else -1);
        direction[0] = x;
        direction[1] = y;
    }
    return math.normalize(direction);
}

/// Right and up of a tile's capture camera. Must match `impostorBasis` in
/// impostor.glsl.
fn basis(toward: Vec3) [2]Vec3 {
    const hint: Vec3 = if (@abs(toward[1]) < 0.999) .{ 0, 1, 0 } else .{ 1, 0, 0 };
    const right = math.normalize(math.cross(hint, toward));
    return .{ right, math.cross(toward, right) };
}

/// Bakes the atlases of impostors added since the last frame.
pub fn bakeImpostors(renderer: *Renderer, p: *const ScenePass) !void {
    const device = renderer.device;
    const cmd = p.cmd;
    const scene = p.scene;
    for (scene.groups.items) |group_handle| {
        const group = renderer.instance_groups.get(group_handle) orelse continue;
        const impostor = if (group.impostor) |*state| state else continue;
        if (impostor.baked) continue;
        const model = renderer.models.get(group.model) orelse continue;
        if (model.state != .ready or !model.geometry_resident) continue;
        const source = &model.source.?;
        if (source.instances.len != 1) continue;
        const mesh = model.meshes[source.instances[0].mesh];
        const bounds = source.meshes[source.instances[0].mesh];
        const size = impostor.resolution * frames;
        const depth = try device.createTexture(.{ .name = "impostor depth", .width = size, .height = size, .format = .depth32_float, .usage = .{ .depth_attachment = true } });
        defer device.destroyTexture(depth);
        cmd.beginScope("impostor bake");
        try cmd.beginRendering(.{
            .color = &.{ .{ .texture = impostor.color, .load = .clear, .clear = .{ 0, 0, 0, 0 } }, .{ .texture = impostor.normal, .load = .clear, .clear = .{ 0.5, 0.5, 1, 0 } } },
            .depth = .{ .texture = depth, .clear = 0, .store = false },
        });
        cmd.bindPipeline(renderer.pipelines.impostor_bake);
        cmd.bindIndexBuffer(renderer.indices.buffer, 0, .uint32);
        for (0..frames) |row| for (0..frames) |column| {
            const toward = unfold(.{ (@as(f32, @floatFromInt(column)) + 0.5) / frames, (@as(f32, @floatFromInt(row)) + 0.5) / frames });
            const camera = basis(toward);
            cmd.setViewport(@intCast(column * impostor.resolution), @intCast(row * impostor.resolution), impostor.resolution, impostor.resolution);
            cmd.pushConstants(extern struct { frame: u64, node: [16]f32, center: [3]f32, radius: f32, right: [3]f32, vertex_offset: u32, up: [3]f32, material: u32, toward: [3]f32, pad: f32 = 0 }{
                .frame = p.frame_address,
                .node = math.identity,
                .center = bounds.bounds_center,
                .radius = @max(bounds.bounds_radius, 1e-6),
                .right = camera[0],
                .vertex_offset = mesh.vertex_offset,
                .up = camera[1],
                .material = mesh.material,
                .toward = toward,
            });
            cmd.drawIndexed(mesh.lod0_index_count, 1, mesh.index_offset, 0, 0);
        };
        cmd.endRendering();
        cmd.transition(impostor.color, .shader_read);
        cmd.transition(impostor.normal, .shader_read);
        cmd.endScope();
        impostor.baked = true;
        scene.static_version += 1;
    }
}

/// Draws the instances culling listed as impostors.
pub fn drawImpostors(renderer: *Renderer, p: *const ScenePass) !void {
    const device = renderer.device;
    const cmd = p.cmd;
    const scene = p.scene;
    const view = p.view;
    if (scene.impostor_count == 0 or p.debugging) return;
    const table = scene.impostor_table orelse return;
    const list = scene.impostor_list orelse return;
    const bounds = scene.static_cull orelse return;
    cmd.beginScope("impostors");
    try cmd.beginRendering(.{
        .color = &.{ .{ .texture = view.hdr, .load = .load }, .{ .texture = view.motion, .load = .load } },
        .depth = .{ .texture = view.depth, .load = .load },
    });
    cmd.bindPipeline(renderer.pipelines.impostor);
    cmd.pushConstants(extern struct { frame: u64, impostors: u64, instances: u64, list: u64, entity_instances: u32, pad: u32 = 0 }{
        .frame = p.frame_address,
        .impostors = device.bufferAddress(table),
        .instances = device.bufferAddress(bounds),
        .list = device.bufferAddress(list),
        .entity_instances = @intCast(scene.layout.items.len),
    });
    cmd.drawIndirect(renderer.impostor_draw, 0);
    cmd.endRendering();
    cmd.transition(view.hdr, .shader_read);
    cmd.transition(view.motion, .shader_read);
    cmd.transition(view.depth, .shader_read);
    cmd.endScope();
}
