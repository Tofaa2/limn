//! Transparent surfaces drawn over the opaque scene: liquids, water and blended
//! meshes. Internal to the renderer.
const std = @import("std");
const rhi = @import("../../rhi/rhi.zig");
const math = @import("../../math.zig");
const gpu = @import("../gpu.zig");
const render = @import("../renderer.zig");
const scene_pass = @import("../scene_pass.zig");

const Renderer = render.Renderer;
const water_quads = render.water_quads;
const TransparentDraw = render.TransparentDraw;
const hdr_format = render.hdr_format;
const shaderCode = render.shaderCode;
const ScenePass = scene_pass.ScenePass;

/// Copies the scene color into `copy`, for passes that refract it.
pub fn copyScene(renderer: *Renderer, p: *const ScenePass, copy: rhi.Texture) !void {
    const cmd = p.cmd;
    try cmd.beginRendering(.{ .color = &.{.{ .texture = copy, .load = .discard }} });
    cmd.bindPipeline(renderer.pipelines.copy);
    cmd.pushConstants(extern struct { frame: u64, source: u32, pad: u32 = 0 }{ .frame = p.frame_address, .source = renderer.device.textureIndex(p.view.hdr) });
    cmd.drawFullscreen();
    cmd.endRendering();
    cmd.transition(copy, .shader_read);
}

/// Draws the scene's liquids as smoothed, refracting surfaces.
pub fn drawLiquids(renderer: *Renderer, p: *const ScenePass) !void {
    const device = renderer.device;
    const cmd = p.cmd;
    const scene = p.scene;
    const view = p.view;
    const debugging = p.debugging;
    const frame_address = p.frame_address;
    if (scene.liquids.items.len != 0 and !debugging) liquid: {
        const targets = view.liquid orelse break :liquid;
        const copy = view.scene_copy orelse break :liquid;
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
            cmd.bindPipeline(renderer.pipelines.liquid_depth);
            cmd.pushConstants(particle_push);
            cmd.draw(state.live * 6, 1, 0, 0);
            cmd.endRendering();
            cmd.transition(targets.depth, .shader_read);
            try cmd.beginRendering(.{ .color = &.{.{ .texture = targets.thickness, .load = .clear, .clear = .{ 0, 0, 0, 0 } }} });
            cmd.bindPipeline(renderer.pipelines.liquid_thickness);
            cmd.pushConstants(particle_push);
            cmd.draw(state.live * 6, 1, 0, 0);
            cmd.endRendering();
            cmd.transition(targets.thickness, .shader_read);
            const BlurPush = extern struct { frame: u64, source: u32, raw: u32, direction: [2]f32, width: f32, edge: f32 };
            cmd.bindPipeline(renderer.pipelines.liquid_blur);
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
            try copyScene(renderer, p, copy);
            try cmd.beginRendering(.{ .color = &.{.{ .texture = view.hdr, .load = .load }} });
            cmd.bindPipeline(renderer.pipelines.liquid);
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
                cmd.bindPipeline(renderer.pipelines.liquid_surface);
                cmd.pushConstants(extern struct { frame: u64, distance: u32, pad: u32 = 0 }{ .frame = frame_address, .distance = device.textureIndex(targets.smooth[1]) });
                cmd.drawFullscreen();
                cmd.endRendering();
                cmd.transition(view.depth, .shader_read);
                cmd.transition(view.motion, .shader_read);
            }
        }
    }
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
    if (scene.waters.items.len != 0 and !debugging) water: {
        const copy = view.scene_copy orelse break :water;
        cmd.beginScope("water");
        try copyScene(renderer, p, copy);
        try cmd.beginRendering(.{ .color = &.{.{ .texture = view.hdr, .load = .load }} });
        cmd.bindPipeline(renderer.pipelines.water);
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
            cmd.bindPipeline(renderer.pipelines.water_depth);
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
            try copyScene(renderer, p, copy);
            try cmd.beginRendering(.{ .color = &.{.{ .texture = view.hdr, .load = .discard }} });
            cmd.bindPipeline(renderer.pipelines.underwater);
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

/// The weighted blended OIT pipeline, created on first use.
pub fn forwardWeightedPipeline(renderer: *Renderer) !rhi.Pipeline {
    if (renderer.pipelines.forward_weighted) |made| return made;
    const made = try renderer.device.createGraphicsPipeline(.{
        .name = "forward transparent (weighted)",
        .vertex = shaderCode("forward.vert.spv"),
        .fragment = shaderCode("forward_weighted.frag.spv"),
        .color_targets = &.{ .{ .format = hdr_format, .blend = .additive }, .{ .format = .rg16_float, .blend = .alpha }, .{ .format = .r8_unorm, .blend = .revealage } },
        .depth = .{ .write = false, .compare = .greater_or_equal },
        .cull = .none,
    });
    renderer.pipelines.forward_weighted = made;
    return made;
}

/// The depth peeling pipeline, created on first use.
pub fn forwardPeelPipeline(renderer: *Renderer) !rhi.Pipeline {
    if (renderer.pipelines.forward_peel) |made| return made;
    const made = try renderer.device.createGraphicsPipeline(.{
        .name = "forward transparent (peel)",
        .vertex = shaderCode("forward.vert.spv"),
        .fragment = shaderCode("forward_peel.frag.spv"),
        .color_targets = &.{.{ .format = hdr_format }},
        .depth = .{ .write = true, .compare = .greater },
        .cull = .none,
    });
    renderer.pipelines.forward_peel = made;
    return made;
}

/// Draws the scene's blended surfaces as `Settings.transparency` selects.
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
        if (view.scene_copy) |copy| {
            try copyScene(renderer, p, copy);
            behind = device.textureIndex(copy);
        }
        const ForwardPush = extern struct { frame: u64, instance: u32, mode: u32, scene: u32, opaque_depth: u32 = gpu.invalid_id, peel_depth: u32 = gpu.invalid_id, pad: u32 = 0 };
        if (view.peel) |peel| {
            try cmd.beginRendering(.{ .color = &.{.{ .texture = peel.accumulation, .load = .clear, .clear = .{ 0, 0, 0, 0 } }} });
            cmd.endRendering();
            const layers = std.math.clamp(settings.transparency_layers, 1, 16);
            for (0..layers) |layer| {
                const depth_now = peel.depth[layer % 2];
                const depth_before = peel.depth[(layer + 1) % 2];
                try cmd.beginRendering(.{
                    .color = &.{.{ .texture = peel.layer, .load = .clear, .clear = .{ 0, 0, 0, 0 } }},
                    .depth = .{ .texture = depth_now, .clear = 0 },
                });
                cmd.bindPipeline(try forwardPeelPipeline(renderer));
                cmd.bindIndexBuffer(renderer.indices.buffer, 0, .uint32);
                for (scene.transparent.items) |draw| {
                    cmd.pushConstants(ForwardPush{
                        .frame = frame_address,
                        .instance = draw.instance,
                        .mode = 2,
                        .scene = behind,
                        .opaque_depth = device.textureIndex(view.depth),
                        .peel_depth = if (layer == 0) gpu.invalid_id else device.textureIndex(depth_before),
                    });
                    cmd.drawIndexed(draw.index_count, 1, draw.first_index, 0, 0);
                }
                cmd.endRendering();
                cmd.transition(peel.layer, .shader_read);
                cmd.transition(depth_now, .shader_read);
                try cmd.beginRendering(.{ .color = &.{.{ .texture = peel.accumulation, .load = .load }} });
                cmd.bindPipeline(renderer.pipelines.peel_under);
                cmd.pushConstants(extern struct { frame: u64, source: u32, pad: u32 = 0 }{ .frame = frame_address, .source = device.textureIndex(peel.layer) });
                cmd.drawFullscreen();
                cmd.endRendering();
            }
            cmd.transition(peel.accumulation, .shader_read);
            try cmd.beginRendering(.{ .color = &.{.{ .texture = view.hdr, .load = .load }} });
            cmd.bindPipeline(renderer.pipelines.peel_composite);
            cmd.pushConstants(extern struct { frame: u64, source: u32, pad: u32 = 0 }{ .frame = frame_address, .source = device.textureIndex(peel.accumulation) });
            cmd.drawFullscreen();
            cmd.endRendering();
        } else if (view.oit) |oit| {
            try cmd.beginRendering(.{
                .color = &.{
                    .{ .texture = oit.accumulation, .load = .clear, .clear = .{ 0, 0, 0, 0 } },
                    .{ .texture = view.motion, .load = .load },
                    .{ .texture = oit.reveal, .load = .clear, .clear = .{ 1, 1, 1, 1 } },
                },
                .depth = .{ .texture = view.depth, .load = .load },
            });
            cmd.bindPipeline(try forwardWeightedPipeline(renderer));
            cmd.bindIndexBuffer(renderer.indices.buffer, 0, .uint32);
            for (scene.transparent.items) |draw| {
                cmd.pushConstants(ForwardPush{ .frame = frame_address, .instance = draw.instance, .mode = 1, .scene = behind });
                cmd.drawIndexed(draw.index_count, 1, draw.first_index, 0, 0);
            }
            cmd.endRendering();
            cmd.transition(oit.accumulation, .shader_read);
            cmd.transition(oit.reveal, .shader_read);
            try cmd.beginRendering(.{ .color = &.{.{ .texture = view.hdr, .load = .load }} });
            cmd.bindPipeline(renderer.pipelines.oit_composite);
            cmd.pushConstants(extern struct { frame: u64, accumulation: u32, reveal: u32 }{
                .frame = frame_address,
                .accumulation = device.textureIndex(oit.accumulation),
                .reveal = device.textureIndex(oit.reveal),
            });
            cmd.drawFullscreen();
            cmd.endRendering();
        } else {
            renderer.transparent_order.clearRetainingCapacity();
            try renderer.transparent_order.appendSlice(renderer.gpa, scene.transparent.items);
            for (renderer.transparent_order.items) |*draw| draw.depth = -math.transformPoint(view_matrix, draw.center)[2];
            std.mem.sort(TransparentDraw, renderer.transparent_order.items, {}, struct {
                fn farther(_: void, a: TransparentDraw, b: TransparentDraw) bool {
                    return a.depth > b.depth;
                }
            }.farther);
            const forward_target = rhi.RenderingDesc{
                .color = &.{ .{ .texture = view.hdr, .load = .load }, .{ .texture = view.motion, .load = .load } },
                .depth = .{ .texture = view.depth, .load = .load },
            };
            try cmd.beginRendering(forward_target);
            cmd.bindPipeline(renderer.pipelines.forward);
            cmd.bindIndexBuffer(renderer.indices.buffer, 0, .uint32);
            var drawn_any = false;
            for (renderer.transparent_order.items) |draw| {
                if (settings.layered_refraction and draw.transmissive and drawn_any) if (view.scene_copy) |copy| {
                    cmd.endRendering();
                    cmd.transition(view.hdr, .shader_read);
                    try copyScene(renderer, p, copy);
                    try cmd.beginRendering(forward_target);
                    cmd.bindPipeline(renderer.pipelines.forward);
                    cmd.bindIndexBuffer(renderer.indices.buffer, 0, .uint32);
                };
                cmd.pushConstants(ForwardPush{ .frame = frame_address, .instance = draw.instance, .mode = 0, .scene = behind });
                cmd.drawIndexed(draw.index_count, 1, draw.first_index, 0, 0);
                drawn_any = true;
            }
            cmd.endRendering();
        }
        cmd.transition(view.hdr, .shader_read);
        cmd.transition(view.motion, .shader_read);
        cmd.transition(view.depth, .shader_read);
        cmd.endScope();
    }
}
