//! Bakes the lightmaps a scene has asked for, a little each frame.
const rhi = @import("../../rhi/rhi.zig");
const pipelines_module = @import("../renderer/pipelines.zig");
const lightmap_push = @import("../shaders/push/lightmap.zig");
const render = @import("../renderer.zig");
const restyleEntity = @import("../renderer/entity_edits.zig").restyleEntity;
const transformOf = @import("../renderer/entity_edits.zig").transformOf;
const scene_pass = @import("../scene_pass.zig");
const math = @import("../../math.zig");
const features = @import("../core/features.zig");

const ScenePass = scene_pass.ScenePass;
const Renderer = render.Renderer;
const ViewContext = features.ViewContext;

/// Adds the feature's passes to a view of a scene. A path traced view leaves
/// out those whose result the tracer replaces.
pub fn declare(ctx: *ViewContext) !void {
    if (ctx.scene == null) return;
    const g = ctx.graph;
    try g.add(.{ .name = "lightmaps", .stage = .lighting, .always = true, .scope = false }, ctx, lightmaps);
}

fn lightmaps(ctx: *ViewContext) !void {
    const p = ctx.scene.?;
    if (!p.fresh_scene) return;
    try bakeLightmaps(ctx.renderer, p);
}

/// Accumulates one more round into every unfinished lightmap of the scene and
/// publishes the result for shading. Does nothing without a TLAS.
pub fn bakeLightmaps(renderer: *Renderer, p: *const ScenePass) !void {
    const device = renderer.device;
    const cmd = p.cmd;
    const scene = p.scene;
    if (!device.caps.ray_tracing or scene.lightmaps_baking == 0) return;
    const bake = try renderer.internal.pipelines.of(lightmapBakePipeline);
    const tlas = scene.tlas orelse return;
    if (scene.tlas_hash == 0 or scene.tlas_hash != p.scene_frame.tlas_hash) return;
    var baking: u32 = 0;
    for (scene.entities.items) |handle| {
        const entity = renderer.entities.internal.table.get(handle) orelse continue;
        const lightmap = if (entity.lightmap) |*state| state else continue;
        if (lightmap.rounds >= lightmap.wanted) continue;
        baking += 1;
        const model = renderer.models.internal.table.get(entity.model) orelse continue;
        if (model.state != .ready or !model.geometry_resident) continue;
        const source = &model.source.?;
        const from = lightmap.gathered[lightmap.rounds & 1];
        const into = lightmap.gathered[(lightmap.rounds + 1) & 1];
        cmd.beginScope("lightmap");
        try cmd.beginRendering(.{ .color = &.{.{ .texture = into, .load = .clear, .clear = .{ 0, 0, 0, 0 } }} });
        cmd.bindPipeline(bake);
        cmd.bindIndexBuffer(renderer.internal.indices.get(), 0, .uint32);
        for (source.instances) |instance| {
            const mesh = model.meshes[instance.mesh];
            if (mesh.blend) continue;
            cmd.pushConstants(lightmap_push.BakePush{
                .frame = p.frame_address,
                .tlas = device.accelerationAddress(tlas),
                .transform = math.mul(transformOf(renderer, handle), model.node_world[instance.node]),
                .vertex_offset = mesh.vertex_offset,
                .gathered_texture = device.textureIndex(from),
                .rounds = lightmap.rounds,
                .rays = lightmap.rays,
                .reach = lightmap.reach,
            });
            cmd.drawIndexed(mesh.lod0_index_count, 1, mesh.index_offset, 0, 0);
        }
        cmd.endRendering();
        try cmd.beginRendering(.{ .color = &.{.{ .texture = lightmap.shown, .load = .discard }} });
        cmd.bindPipeline(try renderer.internal.pipelines.of(lightmapDilatePipeline));
        cmd.pushConstants(lightmap_push.DilatePush{ .frame = p.frame_address, .source_texture = device.textureIndex(into) });
        cmd.drawFullscreen();
        cmd.endRendering();
        cmd.endScope();
        lightmap.rounds += 1;
        if (lightmap.rounds == 1) restyleEntity(renderer, handle);
    }
    scene.lightmaps_baking = baking;
}

fn lightmapBakePipeline(_: *rhi.Device) pipelines_module.Desc {
    return .{ .graphics = .{
        .name = "lightmap bake",
        .vertex = pipelines_module.shaderCode("lightmap_bake.vert.spv"),
        .fragment = pipelines_module.shaderCode("lightmap_bake.frag.spv"),
        .color_targets = &.{.{ .format = pipelines_module.hdr_format }},
        .cull = .none,
    } };
}

fn lightmapDilatePipeline(_: *rhi.Device) pipelines_module.Desc {
    return pipelines_module.pass("lightmap dilate", pipelines_module.shaderCode("lightmap_dilate.frag.spv"), &.{.{ .format = pipelines_module.hdr_format }});
}
