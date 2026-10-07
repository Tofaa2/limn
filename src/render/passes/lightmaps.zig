//! Progressive lightmap baking. Internal to the renderer.
const std = @import("std");
const rhi = @import("../../rhi/rhi.zig");
const math = @import("../../math.zig");
const render = @import("../renderer.zig");
const scene_pass = @import("../scene_pass.zig");

const Renderer = render.Renderer;
const ScenePass = scene_pass.ScenePass;

/// Accumulates one more round into every unfinished lightmap of the scene and
/// publishes the result for shading. Does nothing without a TLAS.
pub fn bakeLightmaps(renderer: *Renderer, p: *const ScenePass) !void {
    const device = renderer.device;
    const cmd = p.cmd;
    const scene = p.scene;
    const bake = renderer.pipelines.lightmap_bake orelse return;
    if (scene.lightmaps_baking == 0) return;
    const tlas = scene.tlas orelse return;
    if (scene.tlas_hash == 0 or scene.tlas_hash != p.scene_frame.tlas_hash) return;
    var baking: u32 = 0;
    for (scene.entities.items) |handle| {
        const entity = renderer.entities.get(handle) orelse continue;
        const lightmap = if (entity.lightmap) |*state| state else continue;
        if (lightmap.rounds >= lightmap.wanted) continue;
        baking += 1;
        const model = renderer.models.get(entity.model) orelse continue;
        if (model.state != .ready or !model.geometry_resident) continue;
        const source = &model.source.?;
        const from = lightmap.gathered[lightmap.rounds & 1];
        const into = lightmap.gathered[(lightmap.rounds + 1) & 1];
        cmd.beginScope("lightmap");
        // Uncovered texels keep their value from the other buffer.
        try cmd.beginRendering(.{ .color = &.{.{ .texture = into, .load = .clear, .clear = .{ 0, 0, 0, 0 } }} });
        cmd.bindPipeline(bake);
        cmd.bindIndexBuffer(renderer.indices.buffer, 0, .uint32);
        for (source.instances) |instance| {
            const mesh = model.meshes[instance.mesh];
            if (mesh.blend) continue;
            cmd.pushConstants(extern struct { frame: u64, tlas: u64, transform: [16]f32, vertex_offset: u32, gathered: u32, rounds: u32, rays: u32, reach: f32, pad: u32 = 0 }{
                .frame = p.frame_address,
                .tlas = device.accelerationAddress(tlas),
                .transform = math.mul(entity.transform, model.node_world[instance.node]),
                .vertex_offset = mesh.vertex_offset,
                .gathered = device.textureIndex(from),
                .rounds = lightmap.rounds,
                .rays = lightmap.rays,
                .reach = lightmap.reach,
            });
            cmd.drawIndexed(mesh.lod0_index_count, 1, mesh.index_offset, 0, 0);
        }
        cmd.endRendering();
        cmd.transition(into, .shader_read);
        try cmd.beginRendering(.{ .color = &.{.{ .texture = lightmap.shown, .load = .discard }} });
        cmd.bindPipeline(renderer.pipelines.lightmap_dilate);
        cmd.pushConstants(extern struct { frame: u64, source: u32, pad: u32 = 0 }{ .frame = p.frame_address, .source = device.textureIndex(into) });
        cmd.drawFullscreen();
        cmd.endRendering();
        cmd.transition(lightmap.shown, .shader_read);
        cmd.endScope();
        lightmap.rounds += 1;
    }
    scene.lightmaps_baking = baking;
}
