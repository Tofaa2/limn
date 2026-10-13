//! The surfaces of a scene's simulated liquids.
const render = @import("../renderer.zig");
const renderer_state = @import("../state.zig");
const scene_pass = @import("../scene_pass.zig");
const transparency_feature = @import("transparency.zig");
const features = @import("../core/features.zig");

const ScenePass = scene_pass.ScenePass;
const LiquidTargets = renderer_state.LiquidTargets;
const Renderer = render.Renderer;
const ViewContext = features.ViewContext;

/// Adds the feature's passes to a view of a scene. A path traced view leaves
/// out those whose result the tracer replaces.
pub fn declare(ctx: *ViewContext) !void {
    const p = ctx.scene orelse return;
    if (p.tracing) return;
    const g = ctx.graph;
    try g.add(.{ .name = "liquids", .stage = .transparent, .always = true, .scope = false }, ctx, liquids);
}

fn liquids(ctx: *ViewContext) !void {
    const p = ctx.scene.?;
    try drawLiquids(ctx.renderer, p);
}

/// Draws the scene's liquids as smoothed, refracting surfaces.
pub fn drawLiquids(renderer: *Renderer, p: *const ScenePass) !void {
    const device = renderer.device;
    const cmd = p.cmd;
    const scene = p.scene;
    const view = p.view;
    const debugging = p.debugging;
    const frame_address = p.frame_address;
    if (scene.liquids.items.len != 0 and !debugging) {
        const copy = try transparency_feature.sceneCopy(renderer, p);
        const targets = LiquidTargets{
            .depth = try p.keepAs(renderer, .{ .name = "liquid depth", .width = p.width, .height = p.height, .format = .depth32_float, .usage = .{ .sampled = true, .depth_attachment = true } }),
            .thickness = try p.keep(renderer, "liquid thickness", p.width, p.height, .r16_float),
            .smooth = .{
                try p.keep(renderer, "liquid surface", p.width, p.height, .r32_float),
                try p.keep(renderer, "liquid surface (other)", p.width, p.height, .r32_float),
            },
        };
        cmd.beginScope("liquid");
        defer cmd.endScope();
        for (scene.liquids.items) |item| {
            const state = renderer.liquids.table.get(item) orelse continue;
            if (state.params_frame != renderer.frame_index or state.live == 0) continue;
            const radius = state.desc.particle_radius;
            const ParticlePush = extern struct { frame: u64, liquid: u64, particles: u64, depth: u32, swell: f32 };
            const particle_push = ParticlePush{
                .frame = frame_address,
                .liquid = state.params,
                .particles = device.bufferAddress(state.particles),
                .depth = device.textureIndex(view.depth),
                .swell = 1.7,
            };
            try cmd.beginRendering(.{ .depth = .{ .texture = targets.depth, .clear = 0 } });
            cmd.bindPipeline(try renderer.pipelines.get(.liquid_depth));
            cmd.pushConstants(particle_push);
            cmd.draw(state.live * 6, 1, 0, 0);
            cmd.endRendering();
            cmd.transition(targets.depth, .shader_read);
            try cmd.beginRendering(.{ .color = &.{.{ .texture = targets.thickness, .load = .clear, .clear = .{ 0, 0, 0, 0 } }} });
            cmd.bindPipeline(try renderer.pipelines.get(.liquid_thickness));
            cmd.pushConstants(particle_push);
            cmd.draw(state.live * 6, 1, 0, 0);
            cmd.endRendering();
            cmd.transition(targets.thickness, .shader_read);
            const BlurPush = extern struct { frame: u64, source: u32, raw: u32, direction: [2]f32, width: f32, edge: f32 };
            cmd.bindPipeline(try renderer.pipelines.get(.liquid_blur));
            var source = targets.depth;
            var raw: u32 = 1;
            for (0..2) |pass| {
                const smoothed = targets.smooth[pass % 2];
                try cmd.beginRendering(.{ .color = &.{.{ .texture = smoothed, .load = .discard }} });
                cmd.pushConstants(BlurPush{
                    .frame = frame_address,
                    .source = device.textureIndex(source),
                    .raw = raw,
                    .direction = if (pass % 2 == 0) .{ 1, 0 } else .{ 0, 1 },
                    .width = radius * 5,
                    .edge = radius * 4,
                });
                cmd.drawFullscreen();
                cmd.endRendering();
                cmd.transition(smoothed, .shader_read);
                source = smoothed;
                raw = 0;
            }
            try transparency_feature.copyScene(renderer, p, copy);
            try cmd.beginRendering(.{ .color = &.{.{ .texture = view.hdr, .load = .load }} });
            cmd.bindPipeline(try renderer.pipelines.get(.liquid));
            cmd.pushConstants(extern struct { frame: u64, liquid: u64, distance: u32, thickness: u32, scene: u32, depth: u32 }{
                .frame = frame_address,
                .liquid = state.params,
                .distance = device.textureIndex(targets.smooth[1]),
                .thickness = device.textureIndex(targets.thickness),
                .scene = device.textureIndex(copy),
                .depth = device.textureIndex(view.depth),
            });
            cmd.drawFullscreen();
            cmd.endRendering();
            cmd.transition(view.hdr, .shader_read);
            if (state.desc.write_depth) {
                try cmd.beginRendering(.{ .color = &.{.{ .texture = view.motion, .load = .load }}, .depth = .{ .texture = view.depth, .load = .load } });
                cmd.bindPipeline(try renderer.pipelines.get(.liquid_surface));
                cmd.pushConstants(extern struct { frame: u64, distance: u32, pad: u32 = 0 }{ .frame = frame_address, .distance = device.textureIndex(targets.smooth[1]) });
                cmd.drawFullscreen();
                cmd.endRendering();
                cmd.transition(view.depth, .shader_read);
                cmd.transition(view.motion, .shader_read);
            }
        }
    }
}
