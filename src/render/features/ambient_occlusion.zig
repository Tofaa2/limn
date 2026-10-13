//! Screen-space ambient occlusion (GTAO) with the light nearby occluders
//! bounce: a depth pyramid, a trace below full resolution, and a filter that
//! upsamples and blends over frames.
const std = @import("std");
const view_math = @import("../renderer/view_math.zig");
const rhi = @import("../../rhi/rhi.zig");
const gpu = @import("../gpu.zig");
const api = @import("../api.zig");
const features = @import("../core/features.zig");
const renderer_state = @import("../state.zig");

const ViewContext = features.ViewContext;
const Target = features.Target;

pub const name = "ambient_occlusion";

pub const Settings = struct {
    /// World-space radius searched for occluders.
    radius: f32 = 1.2,
    /// Exponent applied to the occlusion term; higher is darker.
    intensity: f32 = 1.3,
    /// Blend occlusion over frames; it then lags fast motion slightly.
    temporal_filter: bool = true,
    /// Strength of bounce light from nearby occluders; 0 for none. Needs
    /// `Settings.resolution.temporal_antialiasing`.
    bounce: f32 = 1,
    /// Resolution the occlusion is traced at.
    resolution: api.EffectResolution = .half,
    /// Directions per pixel, 1..8.
    slices: u32 = 2,
    /// Samples per direction, 1..32.
    steps: u32 = 5,
};

const depth_mips = 5;

pub fn preset(quality: api.Quality) ?Settings {
    return switch (quality) {
        .ultra, .high => .{},
        .medium => .{ .bounce = 0 },
        .low => .{ .bounce = 0, .slices = 1 },
    };
}

pub fn resolve(setting: *?Settings, r: *features.Resolve) void {
    if (!r.scene) setting.* = null;
    const s = &(setting.* orelse return);
    s.slices = std.math.clamp(s.slices, 1, 8);
    s.steps = std.math.clamp(s.steps, 1, 32);
    s.bounce = @max(s.bounce, 0);
    if (s.bounce > 0 and !r.temporal_antialiasing) {
        s.bounce = 0;
        r.downgrade("ambient_occlusion.bounce", "on", "off", .needs_temporal_antialiasing);
    }
    if (r.debugging) s.bounce = 0;
}

const Frame = struct {
    ctx: *ViewContext,
    settings: Settings,
    depth: Target,
    pyramid: Target,
    traced: Target,
    traced_light: Target,
    occlusion: features.ViewContext.History,
    light: ?features.ViewContext.History,
    /// Last frame's picture, which the bounce light is read from.
    seen: ?Target,
};

pub fn declare(ctx: *ViewContext) !void {
    const settings = ctx.settings.ambient_occlusion orelse return;
    const p = ctx.scene orelse return;
    const g = ctx.graph;
    const color = rhi.TextureUsage{ .sampled = true, .color_attachment = true };
    const width = renderer_state.scaledExtent(settings.resolution, p.width);
    const height = renderer_state.scaledExtent(settings.resolution, p.height);

    const frame = try ctx.make(Frame);
    const seen: ?Target = if (settings.bounce > 0 and p.view.history_valid)
        try g.import(p.view.history[@intCast((p.view_data.frames + 1) & 1)])
    else
        null;
    frame.* = .{
        .ctx = ctx,
        .settings = settings,
        .depth = g.slot(.depth).?,
        .pyramid = try g.transient(.{ .name = "ao depth", .width = width, .height = height, .format = .r16_float, .usage = color, .mip_levels = @min(depth_mips, rhi.TextureDesc.fullMipCount(width, height)) }),
        .traced = try g.transient(.{ .name = "ao raw", .width = width, .height = height, .format = .rg16_float, .usage = color }),
        .traced_light = try g.transient(.{ .name = "bounce raw", .width = width, .height = height, .format = .rgba16_float, .usage = color }),
        .occlusion = try ctx.history(.{ .name = "ao", .width = p.width, .height = p.height, .format = .r16_float, .usage = color }),
        .light = if (seen != null) try ctx.history(.{ .name = "bounce", .width = p.width, .height = p.height, .format = .rgba16_float, .usage = color }) else null,
        .seen = seen,
    };
    ctx.constants.flags |= gpu.frame_flags.ambient_occlusion;
    g.publish(.ambient_occlusion, frame.occlusion.current);
    if (frame.light) |light| g.publish(.occluder_light, light.current);

    try g.add(.{ .name = "ao depth", .stage = .lighting, .reads = &.{frame.depth}, .writes = &.{frame.pyramid} }, frame, reduceDepth);
    const traced_from = [2]Target{ frame.pyramid, seen orelse frame.pyramid };
    try g.add(.{
        .name = "ao trace",
        .stage = .lighting,
        .reads = traced_from[0..if (seen != null) 2 else 1],
        .color = &.{ .{ .target = frame.traced }, .{ .target = frame.traced_light } },
    }, frame, trace);

    var reads: [5]Target = undefined;
    var count: usize = 0;
    for ([_]?Target{ frame.traced, frame.depth, frame.occlusion.previous, if (frame.light != null) frame.traced_light else null, if (frame.light) |light| light.previous else null }) |read| {
        if (read) |target| {
            reads[count] = target;
            count += 1;
        }
    }
    const filtered = [2]features.graph.Color{ .{ .target = frame.occlusion.current }, .{ .target = if (frame.light) |light| light.current else frame.occlusion.current } };
    try g.add(.{
        .name = "ao filter",
        .stage = .lighting,
        .reads = reads[0..count],
        .color = filtered[0..if (frame.light != null) 2 else 1],
    }, frame, filter);
}

fn reduceDepth(frame: *Frame) !void {
    const ctx = frame.ctx;
    const cmd = ctx.cmd;
    const device = ctx.device;
    const pyramid = ctx.graph.texture(frame.pyramid);
    const sampler = device.samplerIndex(ctx.renderer.sampler_nearest_clamp);
    for (0..device.textureInfo(pyramid).mip_levels) |mip| {
        if (mip != 0) cmd.transitionMip(pyramid, @intCast(mip - 1), .shader_read);
        try cmd.beginRendering(.{ .color = &.{.{ .texture = pyramid, .mip = @intCast(mip), .load = .discard }} });
        cmd.bindPipeline(try ctx.renderer.pipelines.get(.ao_depth));
        cmd.pushConstants(extern struct { source: u32, sampler: u32, first: u32, source_lod: i32, terms: [4]f32 }{
            .source = if (mip == 0) ctx.index(frame.depth) else device.textureIndex(pyramid),
            .sampler = sampler,
            .first = @intFromBool(mip == 0),
            .source_lod = if (mip == 0) 0 else @intCast(mip - 1),
            .terms = view_math.depthTerms(ctx.desc.camera),
        });
        cmd.drawFullscreen();
        cmd.endRendering();
    }
}

fn trace(frame: *Frame) !void {
    const ctx = frame.ctx;
    const cmd = ctx.cmd;
    cmd.bindPipeline(try ctx.renderer.pipelines.get(.gtao));
    cmd.pushConstants(extern struct { frame: u64, depth: u32, color: u32, radius: f32, intensity: f32, slice_count: i32, step_count: i32 }{
        .frame = ctx.frame_address,
        .depth = ctx.index(frame.pyramid),
        .color = if (frame.seen) |seen| ctx.index(seen) else gpu.invalid_id,
        .radius = frame.settings.radius,
        .intensity = frame.settings.intensity,
        .slice_count = @intCast(frame.settings.slices),
        .step_count = @intCast(frame.settings.steps),
    });
    cmd.drawFullscreen();
}

fn filter(frame: *Frame) !void {
    const ctx = frame.ctx;
    const cmd = ctx.cmd;
    const previous = if (frame.settings.temporal_filter) frame.occlusion.previous else null;
    cmd.bindPipeline(try ctx.renderer.pipelines.get(if (frame.light != null) .gtao_bounce_denoise else .gtao_denoise));
    cmd.pushConstants(extern struct { frame: u64, ao: u32, depth: u32, history: u32, blend: f32, bounce: u32, bounce_history: u32 }{
        .frame = ctx.frame_address,
        .ao = ctx.index(frame.traced),
        .depth = ctx.index(frame.depth),
        .history = if (previous) |target| ctx.index(target) else gpu.invalid_id,
        .blend = 0.1,
        .bounce = if (frame.light != null) ctx.index(frame.traced_light) else gpu.invalid_id,
        .bounce_history = if (frame.light) |light| (if (light.previous) |target| ctx.index(target) else gpu.invalid_id) else gpu.invalid_id,
    });
    cmd.drawFullscreen();
}
