//! A scene's bodies of water.
const render = @import("../renderer.zig");
const scene_pass = @import("../scene_pass.zig");
const gpu = @import("../gpu.zig");
const math = @import("../../math.zig");
const transparency_feature = @import("transparency.zig");
const features = @import("../core/features.zig");

const ScenePass = scene_pass.ScenePass;
const water_quads = render.water_quads;
const Renderer = render.Renderer;
const ViewContext = features.ViewContext;

/// Adds the feature's passes to a view of a scene. A path traced view leaves
/// out those whose result the tracer replaces.
pub fn declare(ctx: *ViewContext) !void {
    if (ctx.scene == null) return;
    const g = ctx.graph;
    try g.add(.{ .name = "water", .stage = .transparent, .always = true, .scope = false }, ctx, water);
}

fn water(ctx: *ViewContext) !void {
    const p = ctx.scene.?;
    try drawWater(ctx.renderer, p);
}

/// Draws the scene's water surfaces and the underwater view.
pub fn drawWater(renderer: *Renderer, p: *const ScenePass) !void {
    const device = renderer.device;
    const cmd = p.cmd;
    const desc = p.desc;
    const scene = p.scene;
    const view = p.view;
    const debugging = p.debugging;
    const frame_address = p.frame_address;
    if (scene.waters.items.len != 0 and !debugging) {
        const copy = try transparency_feature.sceneCopy(renderer, p);
        cmd.beginScope("water");
        try transparency_feature.copyScene(renderer, p, copy);
        try cmd.beginRendering(.{ .color = &.{.{ .texture = view.hdr, .load = .load }} });
        cmd.bindPipeline(try renderer.pipelines.get(.water));
        for (scene.waters.items) |item| {
            const state = renderer.waters.table.get(item) orelse continue;
            if (state.params_frame != renderer.frame_index) continue;
            cmd.pushConstants(extern struct { frame: u64, water: u64, depth: u32, scene: u32, quads: u32, pad: u32 = 0 }{
                .frame = frame_address,
                .water = state.params,
                .depth = device.textureIndex(view.depth),
                .scene = device.textureIndex(copy),
                .quads = water_quads,
            });
            cmd.draw(water_quads * water_quads * 6, 1, 0, 0);
        }
        cmd.endRendering();
        cmd.transition(view.hdr, .shader_read);
        var any_depth = false;
        for (scene.waters.items) |item| {
            const state = renderer.waters.table.get(item) orelse continue;
            if (state.params_frame == renderer.frame_index and state.desc.write_depth) any_depth = true;
        }
        if (any_depth) {
            try cmd.beginRendering(.{ .depth = .{ .texture = view.depth, .load = .load } });
            cmd.bindPipeline(try renderer.pipelines.get(.water_depth));
            for (scene.waters.items) |item| {
                const state = renderer.waters.table.get(item) orelse continue;
                if (state.params_frame != renderer.frame_index or !state.desc.write_depth) continue;
                cmd.pushConstants(extern struct { frame: u64, water: u64, depth: u32, scene: u32, quads: u32, pad: u32 = 0 }{
                    .frame = frame_address,
                    .water = state.params,
                    .depth = gpu.invalid_id,
                    .scene = gpu.invalid_id,
                    .quads = water_quads,
                });
                cmd.draw(water_quads * water_quads * 6, 1, 0, 0);
            }
            cmd.endRendering();
            cmd.transition(view.depth, .shader_read);
        }
        for (scene.waters.items) |item| {
            const state = renderer.waters.table.get(item) orelse continue;
            if (state.params_frame != renderer.frame_index or !state.desc.underwater) continue;
            const local = math.transformPoint(math.inverse(state.desc.transform), desc.camera.position);
            if (local[1] >= 0 or @abs(local[0]) > 0.5 or @abs(local[2]) > 0.5) continue;
            try transparency_feature.copyScene(renderer, p, copy);
            try cmd.beginRendering(.{ .color = &.{.{ .texture = view.hdr, .load = .discard }} });
            cmd.bindPipeline(try renderer.pipelines.get(.underwater));
            cmd.pushConstants(extern struct { frame: u64, water: u64, depth: u32, scene: u32 }{
                .frame = frame_address,
                .water = state.params,
                .depth = device.textureIndex(view.depth),
                .scene = device.textureIndex(copy),
            });
            cmd.drawFullscreen();
            cmd.endRendering();
            cmd.transition(view.hdr, .shader_read);
            break;
        }
        cmd.endScope();
    }
}
