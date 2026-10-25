//! Smoke and fire of a scene's fluids.
const rhi = @import("../../rhi/rhi.zig");
const pipelines_module = @import("../renderer/pipelines.zig");
const fluid_passes_push = @import("../shaders/push/fluid_passes.zig");
const fog_push = @import("../shaders/push/fog.zig");
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
/// Makes the list of fluids that shading reads, filled as fluids draw.
pub fn prepare(ctx: *ViewContext) !void {
    const p = ctx.scene orelse return;
    const list = try p.arena.alloc(ctx.device, gpu.FluidList, 1);
    list.items[0] = .{};
    p.shared.fluid_list = &list.items[0];
    ctx.constants.fluids.list = list.address;
}

pub fn declare(ctx: *ViewContext) !void {
    const p = ctx.scene orelse return;
    if (p.scene.fluids.items.len != 0) {
        const own = filled(p.settings.fluids);
        if (own.shadows) ctx.constants.fluids.shadows = 1;
        if (own.rays) ctx.constants.fluids.rays = 1;
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
        const state = renderer.fluids.internal.table.get(item) orelse continue;
        if (state.params_frame != renderer.internal.frame_index or state.desc.shadow <= 0) continue;
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
            const state = renderer.fluids.internal.table.get(item) orelse continue;
            if (state.desc.light <= 0) continue;
            defer fluid_slot += 1;
            if (state.params_frame != renderer.internal.frame_index) continue;
            if (!bound) cmd.bindPipeline(try renderer.internal.pipelines.of(fluidLightPipeline));
            bound = true;
            cmd.pushConstants(fluid_passes_push.LightPush{ .fluid = state.params, .lights = lighting.lights, .index = fluid_slot, .scale = state.desc.light * 8, .tall = std.math.clamp(state.desc.light_tall, 0, 1) });
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
        var push = fluid_passes_push.VolumePush{
            .motion = @intFromBool(filled(settings.fluids).motion_vectors),
            .frame = frame_address,
            .depth_texture = device.textureIndex(view.depth),
            .count = 0,
            .steps = @intCast(std.math.clamp(filled(settings.fluids).steps, 4, 256)),
            .light_steps = @intCast(std.math.clamp(filled(settings.fluids).light_steps, 1, 32)),
            .motion_pad = 0,
            .fluids = @splat(0),
        };
        for (scene.fluids.items) |item| {
            const state = renderer.fluids.internal.table.get(item) orelse continue;
            if (state.params_frame != renderer.internal.frame_index) continue;
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
        cmd.bindPipeline(try renderer.internal.pipelines.of(fluidPipeline));
        cmd.pushConstants(push);
        cmd.drawFullscreen();
        cmd.endRendering();
        if (filled(settings.fluids).motion_vectors) {
            try cmd.beginRendering(.{ .color = &.{.{ .texture = view.motion, .load = .load }} });
            cmd.bindPipeline(try renderer.internal.pipelines.of(fluidMotionPipeline));
            cmd.pushConstants(fluid_passes_push.MotionPush{ .frame = frame_address, .source_texture = device.textureIndex(fluid_motion) });
            cmd.drawFullscreen();
            cmd.endRendering();
        }
        try cmd.beginRendering(.{ .color = &.{.{ .texture = view.hdr, .load = .load }} });
        cmd.bindPipeline(try renderer.internal.pipelines.of(pipelines_module.fogCompositePipeline));
        cmd.pushConstants(fog_push.CompositePush{
            .frame = frame_address,
            .fog_texture = device.textureIndex(fluid_target),
            .depth_texture = device.textureIndex(view.depth),
        });
        cmd.drawFullscreen();
        cmd.endRendering();
        cmd.endScope();
    }
}

fn fluidPipeline(_: *rhi.Device) pipelines_module.Desc {
    return pipelines_module.pass("fluids", pipelines_module.shaderCode("fluid.frag.spv"), &.{ .{ .format = pipelines_module.hdr_format }, .{ .format = .rgba16_float } });
}

fn fluidMotionPipeline(_: *rhi.Device) pipelines_module.Desc {
    return pipelines_module.pass("fluid motion", pipelines_module.shaderCode("fluid_motion.frag.spv"), &.{.{ .format = .rg16_float, .blend = .alpha }});
}

fn fluidLightPipeline(_: *rhi.Device) pipelines_module.Desc {
    return .{ .compute = .{ .name = "fluid light", .shader = pipelines_module.shaderCode("fluid_light.comp.spv") } };
}
