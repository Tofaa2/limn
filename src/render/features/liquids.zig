//! The surfaces of a scene's simulated liquids.
const rhi = @import("../../rhi/rhi.zig");
const pipelines_module = @import("../renderer/pipelines.zig");
const liquid_push = @import("../shaders/push/liquid.zig");
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
            .thickness = try p.keep(renderer, "liquid thickness", p.width, p.height, .rg16_float),
            .smooth = .{
                try p.keep(renderer, "liquid surface", p.width, p.height, .r32_float),
                try p.keep(renderer, "liquid surface (other)", p.width, p.height, .r32_float),
            },
        };
        cmd.beginScope("liquid");
        defer cmd.endScope();
        for (scene.liquids.items) |item| {
            const state = renderer.liquids.internal.table.get(item) orelse continue;
            const shown = state.shown(device, renderer.internal.frame_index) orelse continue;
            const radius = state.desc.particle_radius;
            const ParticlePush = liquid_push.SpherePush;
            const particle_push = ParticlePush{
                .frame = frame_address,
                .liquid = shown.liquid,
                .shapes = shown.shapes,
                .depth_texture = device.textureIndex(view.depth),
            };
            try cmd.beginRendering(.{ .depth = .{ .texture = targets.depth, .clear = 0 } });
            cmd.bindPipeline(try renderer.internal.pipelines.of(liquidDepthPipeline));
            cmd.pushConstants(particle_push);
            cmd.draw(shown.live * 6, 1, 0, 0);
            cmd.endRendering();
            try cmd.beginRendering(.{ .color = &.{.{ .texture = targets.thickness, .load = .clear, .clear = .{ 0, 0, 0, 0 } }} });
            cmd.bindPipeline(try renderer.internal.pipelines.of(liquidThicknessPipeline));
            cmd.pushConstants(particle_push);
            cmd.draw(shown.live * 6, 1, 0, 0);
            cmd.endRendering();
            const BlurPush = liquid_push.BlurPush;
            cmd.bindPipeline(try renderer.internal.pipelines.of(liquidBlurPipeline));
            var source = targets.depth;
            var raw: u32 = 1;
            for (0..2) |pass| {
                const smoothed = targets.smooth[pass % 2];
                try cmd.beginRendering(.{ .color = &.{.{ .texture = smoothed, .load = .discard }} });
                cmd.pushConstants(BlurPush{
                    .frame = frame_address,
                    .source_texture = device.textureIndex(source),
                    .raw = raw,
                    .direction = if (pass % 2 == 0) .{ 1, 0 } else .{ 0, 1 },
                    .width = radius * 5,
                    .edge = radius * 4,
                });
                cmd.drawFullscreen();
                cmd.endRendering();
                source = smoothed;
                raw = 0;
            }
            try transparency_feature.copyScene(renderer, p, copy);
            try cmd.beginRendering(.{ .color = &.{.{ .texture = view.hdr, .load = .load }} });
            cmd.bindPipeline(try renderer.internal.pipelines.of(liquidPipeline));
            cmd.pushConstants(liquid_push.ShadePush{
                .frame = frame_address,
                .liquid = shown.liquid,
                .distance_texture = device.textureIndex(targets.smooth[1]),
                .thickness_texture = device.textureIndex(targets.thickness),
                .scene_texture = device.textureIndex(copy),
                .depth_texture = device.textureIndex(view.depth),
            });
            cmd.drawFullscreen();
            cmd.endRendering();
            if (state.desc.write_depth) {
                try cmd.beginRendering(.{ .color = &.{.{ .texture = view.motion, .load = .load }}, .depth = .{ .texture = view.depth, .load = .load } });
                cmd.bindPipeline(try renderer.internal.pipelines.of(liquidSurfacePipeline));
                cmd.pushConstants(liquid_push.SurfacePush{ .frame = frame_address, .distance_texture = device.textureIndex(targets.smooth[1]) });
                cmd.drawFullscreen();
                cmd.endRendering();
            }
        }
    }
}

fn liquidSurfacePipeline(_: *rhi.Device) pipelines_module.Desc {
    return .{ .graphics = .{
        .name = "liquid surface depth",
        .vertex = pipelines_module.shaderCode("fullscreen.vert.spv"),
        .fragment = pipelines_module.shaderCode("liquid_surface.frag.spv"),
        .color_targets = &.{.{ .format = .rg16_float }},
        .depth = .{ .write = true, .compare = .greater },
        .cull = .none,
    } };
}

fn liquidDepthPipeline(_: *rhi.Device) pipelines_module.Desc {
    return .{ .graphics = .{
        .name = "liquid depth",
        .vertex = pipelines_module.shaderCode("liquid.vert.spv"),
        .fragment = pipelines_module.shaderCode("liquid_depth.frag.spv"),
        .depth = .{ .write = true, .compare = .greater },
        .cull = .none,
    } };
}

fn liquidThicknessPipeline(_: *rhi.Device) pipelines_module.Desc {
    return .{ .graphics = .{
        .name = "liquid thickness",
        .vertex = pipelines_module.shaderCode("liquid.vert.spv"),
        .fragment = pipelines_module.shaderCode("liquid_thickness.frag.spv"),
        .color_targets = &.{.{ .format = .rg16_float, .blend = .additive }},
        .cull = .none,
    } };
}

fn liquidBlurPipeline(_: *rhi.Device) pipelines_module.Desc {
    return pipelines_module.pass("liquid smoothing", pipelines_module.shaderCode("liquid_blur.frag.spv"), &.{.{ .format = .r32_float }});
}

fn liquidPipeline(_: *rhi.Device) pipelines_module.Desc {
    return pipelines_module.pass("liquid", pipelines_module.shaderCode("liquid.frag.spv"), &.{.{ .format = pipelines_module.hdr_format, .blend = .alpha }});
}
