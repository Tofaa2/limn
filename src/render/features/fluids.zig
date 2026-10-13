//! Smoke and fire of a scene's fluids.
const scene_pass = @import("../scene_pass.zig");
const render = @import("../renderer.zig");
const filled = @import("../api.zig").filled;
const std = @import("std");
const gpu = @import("../gpu.zig");
const api = @import("../api.zig");
const features = @import("../core/features.zig");

const max_fluids = render.max_fluids;
const Lighting = scene_pass.Lighting;
const ScenePass = scene_pass.ScenePass;
const Renderer = render.Renderer;
const ViewContext = features.ViewContext;

pub const name = "fluids";

pub const Settings = struct {
    resolution: api.EffectResolution = .half,
    /// Samples along each ray through a fluid, 4..256, and toward the sun from
    /// each, 1..32.
    steps: u32 = 48,
    light_steps: u32 = 6,
    /// Smoke shadows what the sun lights behind it.
    shadows: bool = true,
    /// Fluids write motion vectors, so temporal antialiasing follows them.
    motion_vectors: bool = true,
    /// Ray-traced reflections and probe rays see smoke and fire.
    rays: bool = true,
};

pub fn preset(quality: api.Quality) ?Settings {
    return switch (quality) {
        .ultra => .{},
        .high => .{},
        .medium => .{ .steps = 32 },
        .low => .{ .resolution = .quarter, .steps = 24 },
    };
}

pub fn resolve(setting: *?Settings, r: *features.Resolve) void {
    _ = setting;
    _ = r;
}

/// Adds the feature's passes to a view of a scene. A path traced view leaves
/// out those whose result the tracer replaces.
pub fn declare(ctx: *ViewContext) !void {
    const p = ctx.scene orelse return;
    if (p.scene.fluids.items.len != 0) {
        const own = filled(p.settings.fluids);
        if (own.shadows) ctx.constants.flags |= gpu.frame_flags.fluid_shadows;
        if (own.rays) ctx.constants.flags |= gpu.frame_flags.fluid_rays;
    }
    const g = ctx.graph;
    try g.add(.{ .name = "smoke", .stage = .volumes, .always = true, .scope = false }, ctx, smoke);
}

fn smoke(ctx: *ViewContext) !void {
    const p = ctx.scene.?;
    try drawFluids(ctx.renderer, p);
}

/// The fluids stepped this frame that cast shadows.
pub fn shadowingFluids(renderer: *Renderer, p: *const ScenePass) gpu.FluidList {
    const scene = p.scene;
    var list = gpu.FluidList{};
    for (scene.fluids.items) |item| {
        const state = renderer.fluids.table.get(item) orelse continue;
        if (state.params_frame != renderer.frame_index or state.desc.shadow <= 0) continue;
        list.fluids[list.count] = state.params;
        list.count += 1;
    }
    if (list.count != 0) {
        for (list.fluids[list.count..]) |*slot| slot.* = list.fluids[0];
    }
    return list;
}

/// Writes the lights of the scene's fires into the light records after the
/// scene's own.
pub fn lightFluids(renderer: *Renderer, p: *const ScenePass, lighting: *const Lighting) !void {
    const cmd = p.cmd;
    const scene = p.scene;
    if (scene.fluids.items.len != 0) {
        var fluid_slot: u32 = @intCast(scene.lights.items.len);
        var bound = false;
        for (scene.fluids.items) |item| {
            const state = renderer.fluids.table.get(item) orelse continue;
            if (state.desc.light <= 0) continue;
            defer fluid_slot += 1;
            if (state.params_frame != renderer.frame_index) continue;
            if (!bound) cmd.bindPipeline(try renderer.pipelines.get(.fluid_light));
            bound = true;
            cmd.pushConstants(extern struct { fluid: u64, lights: u64, index: u32, scale: f32, tall: f32, pad: u32 = 0 }{ .fluid = state.params, .lights = lighting.lights, .index = fluid_slot, .scale = state.desc.light * 8, .tall = std.math.clamp(state.desc.light_tall, 0, 1) });
            cmd.dispatch(1, 1, 1);
        }
        if (bound) cmd.sync(.compute_to_all);
    }
}

/// Ray-marches the scene's smoke and fire and composites them.
pub fn drawFluids(renderer: *Renderer, p: *const ScenePass) !void {
    const device = renderer.device;
    const cmd = p.cmd;
    const settings = p.settings;
    const scene = p.scene;
    const view = p.view;
    const debugging = p.debugging;
    const frame_address = p.frame_address;
    if (settings.fluids != null and scene.fluids.items.len != 0) fluids: {
        if (debugging) break :fluids;
        var push = extern struct { frame: u64, depth: u32, count: u32, steps: i32, light_steps: i32, motion: u32, pad: u32 = 0, fluids: [max_fluids]u64 }{
            .motion = @intFromBool(filled(settings.fluids).motion_vectors),
            .frame = frame_address,
            .depth = device.textureIndex(view.depth),
            .count = 0,
            .steps = @intCast(std.math.clamp(filled(settings.fluids).steps, 4, 256)),
            .light_steps = @intCast(std.math.clamp(filled(settings.fluids).light_steps, 1, 32)),
            .fluids = @splat(0),
        };
        for (scene.fluids.items) |item| {
            const state = renderer.fluids.table.get(item) orelse continue;
            if (state.params_frame != renderer.frame_index) continue;
            push.fluids[push.count] = state.params;
            push.count += 1;
        }
        if (push.count == 0) break :fluids;
        for (push.fluids[push.count..]) |*slot| slot.* = push.fluids[0];
        cmd.beginScope("fluids");
        const fluid_width = ScenePass.scaled(filled(settings.fluids).resolution, p.width);
        const fluid_height = ScenePass.scaled(filled(settings.fluids).resolution, p.height);
        const fluid_target = try p.keep(renderer, "fluids", fluid_width, fluid_height, render.hdr_format);
        const fluid_motion = try p.keep(renderer, "fluid motion", fluid_width, fluid_height, .rgba16_float);
        try cmd.beginRendering(.{ .color = &.{ .{ .texture = fluid_target, .load = .discard }, .{ .texture = fluid_motion, .load = .discard } } });
        cmd.bindPipeline(try renderer.pipelines.get(.fluid));
        cmd.pushConstants(push);
        cmd.drawFullscreen();
        cmd.endRendering();
        cmd.transition(fluid_target, .shader_read);
        cmd.transition(fluid_motion, .shader_read);
        if (filled(settings.fluids).motion_vectors) {
            try cmd.beginRendering(.{ .color = &.{.{ .texture = view.motion, .load = .load }} });
            cmd.bindPipeline(try renderer.pipelines.get(.fluid_motion));
            cmd.pushConstants(extern struct { frame: u64, source: u32, pad: u32 = 0 }{ .frame = frame_address, .source = device.textureIndex(fluid_motion) });
            cmd.drawFullscreen();
            cmd.endRendering();
            cmd.transition(view.motion, .shader_read);
        }
        try cmd.beginRendering(.{ .color = &.{.{ .texture = view.hdr, .load = .load }} });
        cmd.bindPipeline(try renderer.pipelines.get(.fog_composite));
        cmd.pushConstants(extern struct { frame: u64, fog: u32, depth: u32 }{
            .frame = frame_address,
            .fog = device.textureIndex(fluid_target),
            .depth = device.textureIndex(view.depth),
        });
        cmd.drawFullscreen();
        cmd.endRendering();
        cmd.transition(view.hdr, .shader_read);
        cmd.endScope();
    }
}
