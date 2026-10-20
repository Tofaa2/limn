//! How see-through surfaces are drawn.
const pipelines_module = @import("../renderer/pipelines.zig");
const forward_push = @import("../shaders/push/forward.zig");
const fullscreen_push = @import("../shaders/push/fullscreen.zig");
const oit_composite_push = @import("../shaders/push/oit_composite.zig");
const renderer_state = @import("../state.zig");
const scene_pass = @import("../scene_pass.zig");
const render = @import("../renderer.zig");
const gpu = @import("../gpu.zig");
const math = @import("../../math.zig");
const std = @import("std");
const rhi = @import("../../rhi/rhi.zig");
const api = @import("../api.zig");
const features = @import("../core/features.zig");

const OitTargets = renderer_state.OitTargets;
const PeelTargets = renderer_state.PeelTargets;
const TransparentDraw = render.TransparentDraw;
const ScenePass = scene_pass.ScenePass;
const Renderer = render.Renderer;
const ViewContext = features.ViewContext;

pub const name = "transparency";

pub const Settings = struct {
    /// How overlapping transparent surfaces are combined.
    mode: api.TransparencyMode = .sorted,
    /// Layers of the `.peeled` mode, 1..16.
    layers: u32 = 4,
    /// Refractive surfaces also show the transparent surfaces behind them, at
    /// one scene-color copy per such surface. `.sorted` transparency only.
    layered_refraction: bool = false,
};

pub fn preset(quality: api.Quality) Settings {
    _ = quality;
    return .{};
}

pub fn resolve(setting: *Settings, r: *features.Resolve) void {
    _ = setting;
    _ = r;
}

/// Adds the feature's passes to a view of a scene. A path traced view leaves
/// out those whose result the tracer replaces.
pub fn declare(ctx: *ViewContext) !void {
    const p = ctx.scene orelse return;
    if (p.tracing) return;
    const g = ctx.graph;
    try g.add(.{ .name = "transparency", .stage = .transparent, .always = true, .scope = false }, ctx, transparency);
}

fn transparency(ctx: *ViewContext) !void {
    const p = ctx.scene.?;
    try drawTransparency(ctx.renderer, p);
}

/// Copies the scene color into `copy`, for passes that refract it.
pub fn copyScene(renderer: *Renderer, p: *const ScenePass, copy: rhi.Texture) !void {
    const cmd = p.cmd;
    try cmd.beginRendering(.{ .color = &.{.{ .texture = copy, .load = .discard }} });
    cmd.bindPipeline(try renderer.internal.pipelines.of(copyPipeline));
    cmd.pushConstants(fullscreen_push.CopyPush{ .frame = p.frame_address, .source_texture = renderer.device.textureIndex(p.view.hdr) });
    cmd.drawFullscreen();
    cmd.endRendering();
}

/// Draws the scene's blended surfaces as `Settings.transparency.mode` selects.
pub fn drawTransparency(renderer: *Renderer, p: *const ScenePass) !void {
    const device = renderer.device;
    const cmd = p.cmd;
    const settings = p.settings;
    const scene = p.scene;
    const view = p.view;
    const debugging = p.debugging;
    const view_matrix = p.view_matrix;
    const frame_address = p.frame_address;
    if (scene.transparent.items.len != 0 and !debugging) {
        cmd.beginScope("transparency");
        var behind: u32 = gpu.invalid_id;
        const scene_copy: ?rhi.Texture = if (scene.transmissive or scene.waters.items.len != 0 or scene.liquids.items.len != 0) try sceneCopy(renderer, p) else null;
        if (scene_copy) |copy| {
            try copyScene(renderer, p, copy);
            behind = device.textureIndex(copy);
        }
        const peel_targets: ?PeelTargets = if (settings.transparency.mode != .peeled) null else .{
            .layer = try p.keep(renderer, "peel layer", p.width, p.height, render.hdr_format),
            .accumulation = try p.keep(renderer, "peel accumulation", p.width, p.height, render.hdr_format),
            .depth = .{
                try p.keepAs(renderer, .{ .name = "peel depth", .width = p.width, .height = p.height, .format = .depth32_float, .usage = .{ .sampled = true, .depth_attachment = true } }),
                try p.keepAs(renderer, .{ .name = "peel depth (other)", .width = p.width, .height = p.height, .format = .depth32_float, .usage = .{ .sampled = true, .depth_attachment = true } }),
            },
        };
        const oit_targets: ?OitTargets = if (settings.transparency.mode != .weighted) null else .{
            .accumulation = try p.keep(renderer, "transparency accumulation", p.width, p.height, render.hdr_format),
            .reveal = try p.keep(renderer, "transparency reveal", p.width, p.height, .r8_unorm),
        };
        const ForwardPush = forward_push.ForwardPush;
        if (peel_targets) |peel| {
            try cmd.beginRendering(.{ .color = &.{.{ .texture = peel.accumulation, .load = .clear, .clear = .{ 0, 0, 0, 0 } }} });
            cmd.endRendering();
            const layers = std.math.clamp(settings.transparency.layers, 1, 16);
            for (0..layers) |layer| {
                const depth_now = peel.depth[layer % 2];
                const depth_before = peel.depth[(layer + 1) % 2];
                try cmd.beginRendering(.{
                    .color = &.{.{ .texture = peel.layer, .load = .clear, .clear = .{ 0, 0, 0, 0 } }},
                    .depth = .{ .texture = depth_now, .clear = 0 },
                });
                cmd.bindPipeline(try renderer.internal.pipelines.of(forwardPeelPipeline));
                cmd.bindIndexBuffer(renderer.internal.indices.get(), 0, .uint32);
                for (scene.transparent.items) |draw| {
                    cmd.pushConstants(ForwardPush{
                        .frame = frame_address,
                        .instance_index = draw.instance,
                        .mode = 2,
                        .scene_texture = behind,
                        .opaque_depth = device.textureIndex(view.depth),
                        .peel_depth = if (layer == 0) gpu.invalid_id else device.textureIndex(depth_before),
                    });
                    cmd.drawIndexed(draw.index_count, 1, draw.first_index, 0, 0);
                }
                cmd.endRendering();
                try cmd.beginRendering(.{ .color = &.{.{ .texture = peel.accumulation, .load = .load }} });
                cmd.bindPipeline(try renderer.internal.pipelines.of(peelUnderPipeline));
                cmd.pushConstants(fullscreen_push.CopyPush{ .frame = frame_address, .source_texture = device.textureIndex(peel.layer) });
                cmd.drawFullscreen();
                cmd.endRendering();
            }
            try cmd.beginRendering(.{ .color = &.{.{ .texture = view.hdr, .load = .load }} });
            cmd.bindPipeline(try renderer.internal.pipelines.of(peelCompositePipeline));
            cmd.pushConstants(fullscreen_push.CopyPush{ .frame = frame_address, .source_texture = device.textureIndex(peel.accumulation) });
            cmd.drawFullscreen();
            cmd.endRendering();
        } else if (oit_targets) |oit| {
            try cmd.beginRendering(.{
                .color = &.{
                    .{ .texture = oit.accumulation, .load = .clear, .clear = .{ 0, 0, 0, 0 } },
                    .{ .texture = view.motion, .load = .load },
                    .{ .texture = oit.reveal, .load = .clear, .clear = .{ 1, 1, 1, 1 } },
                },
                .depth = .{ .texture = view.depth, .load = .load },
            });
            cmd.bindPipeline(try renderer.internal.pipelines.of(forwardWeightedPipeline));
            cmd.bindIndexBuffer(renderer.internal.indices.get(), 0, .uint32);
            for (scene.transparent.items) |draw| {
                cmd.pushConstants(ForwardPush{ .frame = frame_address, .instance_index = draw.instance, .mode = 1, .scene_texture = behind });
                cmd.drawIndexed(draw.index_count, 1, draw.first_index, 0, 0);
            }
            cmd.endRendering();
            try cmd.beginRendering(.{ .color = &.{.{ .texture = view.hdr, .load = .load }} });
            cmd.bindPipeline(try renderer.internal.pipelines.of(oitCompositePipeline));
            cmd.pushConstants(oit_composite_push.Push{
                .frame = frame_address,
                .accumulation_texture = device.textureIndex(oit.accumulation),
                .reveal_texture = device.textureIndex(oit.reveal),
            });
            cmd.drawFullscreen();
            cmd.endRendering();
        } else {
            renderer.internal.transparent_order.clearRetainingCapacity();
            try renderer.internal.transparent_order.appendSlice(renderer.internal.gpa, scene.transparent.items);
            for (renderer.internal.transparent_order.items) |*draw| draw.depth = -math.transformPoint(view_matrix, draw.center)[2];
            std.mem.sort(TransparentDraw, renderer.internal.transparent_order.items, {}, struct {
                fn farther(_: void, a: TransparentDraw, b: TransparentDraw) bool {
                    return a.depth > b.depth;
                }
            }.farther);
            const forward_target = rhi.RenderingDesc{
                .color = &.{ .{ .texture = view.hdr, .load = .load }, .{ .texture = view.motion, .load = .load } },
                .depth = .{ .texture = view.depth, .load = .load },
            };
            try cmd.beginRendering(forward_target);
            cmd.bindPipeline(try renderer.internal.pipelines.of(forwardPipeline));
            cmd.bindIndexBuffer(renderer.internal.indices.get(), 0, .uint32);
            var drawn_any = false;
            for (renderer.internal.transparent_order.items) |draw| {
                if (settings.transparency.layered_refraction and draw.transmissive and drawn_any) if (scene_copy) |copy| {
                    cmd.endRendering();
                    try copyScene(renderer, p, copy);
                    try cmd.beginRendering(forward_target);
                    cmd.bindPipeline(try renderer.internal.pipelines.of(forwardPipeline));
                    cmd.bindIndexBuffer(renderer.internal.indices.get(), 0, .uint32);
                };
                cmd.pushConstants(ForwardPush{ .frame = frame_address, .instance_index = draw.instance, .mode = 0, .scene_texture = behind });
                cmd.drawIndexed(draw.index_count, 1, draw.first_index, 0, 0);
                drawn_any = true;
            }
            cmd.endRendering();
        }
        cmd.endScope();
    }
}

/// The scene before see-through surfaces, for them to refract.
pub fn sceneCopy(renderer: *Renderer, p: *const ScenePass) !rhi.Texture {
    return p.keep(renderer, "scene behind glass", p.width, p.height, render.hdr_format);
}

fn forwardPipeline(_: *rhi.Device) pipelines_module.Desc {
    return .{ .graphics = .{
        .name = "forward transparent",
        .vertex = pipelines_module.shaderCode("forward.vert.spv"),
        .fragment = pipelines_module.shaderCode("forward.frag.spv"),
        .color_targets = &.{ .{ .format = pipelines_module.hdr_format, .blend = .premultiplied }, .{ .format = .rg16_float, .blend = .alpha } },
        .depth = .{ .write = false, .compare = .greater_or_equal },
        .cull = .none,
    } };
}

fn forwardWeightedPipeline(_: *rhi.Device) pipelines_module.Desc {
    return .{ .graphics = .{
        .name = "forward transparent (weighted)",
        .vertex = pipelines_module.shaderCode("forward.vert.spv"),
        .fragment = pipelines_module.shaderCode("forward_weighted.frag.spv"),
        .color_targets = &.{ .{ .format = pipelines_module.hdr_format, .blend = .additive }, .{ .format = .rg16_float, .blend = .alpha }, .{ .format = .r8_unorm, .blend = .revealage } },
        .depth = .{ .write = false, .compare = .greater_or_equal },
        .cull = .none,
    } };
}

fn oitCompositePipeline(_: *rhi.Device) pipelines_module.Desc {
    return pipelines_module.pass("transparency composite", pipelines_module.shaderCode("oit_composite.frag.spv"), &.{.{ .format = pipelines_module.hdr_format, .blend = .alpha }});
}

fn forwardPeelPipeline(_: *rhi.Device) pipelines_module.Desc {
    return .{ .graphics = .{
        .name = "forward transparent (peel)",
        .vertex = pipelines_module.shaderCode("forward.vert.spv"),
        .fragment = pipelines_module.shaderCode("forward_peel.frag.spv"),
        .color_targets = &.{.{ .format = pipelines_module.hdr_format }},
        .depth = .{ .write = true, .compare = .greater },
        .cull = .none,
    } };
}

fn peelUnderPipeline(_: *rhi.Device) pipelines_module.Desc {
    return pipelines_module.pass("peel under", pipelines_module.shaderCode("copy.frag.spv"), &.{.{ .format = pipelines_module.hdr_format, .blend = .under }});
}

fn peelCompositePipeline(_: *rhi.Device) pipelines_module.Desc {
    return pipelines_module.pass("peel composite", pipelines_module.shaderCode("copy.frag.spv"), &.{.{ .format = pipelines_module.hdr_format, .blend = .premultiplied }});
}

fn copyPipeline(_: *rhi.Device) pipelines_module.Desc {
    return pipelines_module.pass("copy", pipelines_module.shaderCode("copy.frag.spv"), &.{.{ .format = pipelines_module.hdr_format }});
}
