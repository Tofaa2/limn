//! Bloom, exposure and tone mapping of an HDR picture into the view's
//! target. Views without a scene go through this; views of a scene still
//! use `passes/post.zig`.
const scene_pass = @import("../scene_pass.zig");
const output_feature = @import("output.zig");
const ScenePass = @import("../scene_pass.zig").ScenePass;
const filled = @import("../api.zig").filled;
const render = @import("../renderer.zig");
const std = @import("std");
const rhi = @import("../../rhi/rhi.zig");
const gpu = @import("../gpu.zig");
const features = @import("../core/features.zig");
const renderer_state = @import("../state.zig");
const api = @import("../api.zig");

const ViewDesc = render.ViewDesc;
const Renderer = render.Renderer;
const ViewContext = features.ViewContext;
const Target = features.Target;

pub const name = "post";

pub const Settings = struct {
    /// Fraction of the image replaced by its blurred self; 0 disables bloom.
    bloom: f32 = 0.04,
    /// Bloom blur levels, 1..6; more spreads the glow wider.
    bloom_levels: u32 = 6,
    /// Adapt exposure to the picture's average brightness. False uses
    /// `Settings.post.exposure_compensation` alone.
    automatic_exposure: bool = true,
    /// How fast automatic exposure follows the picture, per second; it
    /// brightens at this rate and darkens 1.6 times faster.
    exposure_speed: f32 = 3,
    /// Stops added on top of automatic exposure, or the absolute exposure
    /// (as 2^EV) when automatic exposure is off.
    exposure_compensation: f32 = 0,
    /// Dimmest average brightness automatic exposure adapts to. Pictures
    /// darker than this stay dark instead of being brightened further, which
    /// is what keeps a night looking like one.
    exposure_darkest: f32 = 0.002,
    /// Darkening toward the corners of the picture, 0..1.
    vignette: f32 = 0,
    /// Film grain strength, 0..1.
    film_grain: f32 = 0,
    /// 0 is black and white, 1 unchanged, above 1 more vivid.
    saturation: f32 = 1,
    /// Contrast around middle grey; 1 unchanged.
    contrast: f32 = 1,
    /// White balance: negative cooler (bluer), positive warmer, -1..1.
    temperature: f32 = 0,
    /// Multiplies the picture before tone mapping, like a lens filter.
    color_filter: [3]f32 = .{ 1, 1, 1 },
    /// Color lookup table applied to the finished picture: a strip of N slices,
    /// N*N wide and N tall, in sRGB. Load it with `Renderer.images.create` and `srgb` false.
    color_lut: ?api.Image = null,
    /// Blend of the table's result, 0..1.
    color_lut_strength: f32 = 1,
    /// Red/blue fringing toward the corners, 0..1.
    chromatic_aberration: f32 = 0,
    /// Lens flare strength; 0 is none.
    lens_flare: f32 = 0,
    /// Blur what is out of focus; null for none.
    depth_of_field: ?DepthOfField = null,
    /// Blur what moves across the picture; null for none.
    motion_blur: ?MotionBlur = null,
};

pub const DepthOfField = struct {
    /// Depth of field aperture. 0 is off; 1 blurs distant things by about 24
    /// pixels at 1080p when focused close.
    aperture: f32 = 0.8,
    /// Distance in perfect focus.
    focus_distance: f32 = 10,
    /// Focus on what is at the middle of the picture instead.
    autofocus: bool = false,
    /// Autofocus rate, per second.
    autofocus_speed: f32 = 4,
    /// Largest blur radius, in pixels at 1080p.
    max_blur: f32 = 16,
    /// Depth of field samples per pixel, 4..128.
    samples: u32 = 32,
    /// Resolution the blur is gathered at.
    resolution: api.EffectResolution = .full,
    /// Aperture blades: bokeh gets this many sides; 0 is round.
    blades: u32 = 0,
};

pub const MotionBlur = struct {
    /// Motion blur: fraction of a frame the shutter stays open; 0 is off.
    strength: f32 = 0.5,
    /// Samples along each pixel's path, 2..64.
    samples: u32 = 10,
    /// Let moving things smear past their own outline.
    spread: bool = true,
};

pub fn preset(quality: api.Quality) Settings {
    _ = quality;
    return .{};
}

pub fn resolve(setting: *Settings, r: *features.Resolve) void {
    _ = setting;
    _ = r;
}

const Frame = struct {
    ctx: *ViewContext,
    hdr: Target,
    levels: [renderer_state.bloom_levels]Target,
    count: usize,
};

const BloomPush = extern struct { frame: u64, source: u32, first_level: u32, source_texel: [2]f32 };

/// Adds the passes that take `hdr`, which fills the view's region, to the
/// view's target.
/// Adds the feature's passes to a view of a scene. A path traced view leaves
/// out those whose result the tracer replaces.
pub fn declare(ctx: *ViewContext) !void {
    if (ctx.scene == null) return;
    const g = ctx.graph;
    try g.add(.{ .name = "lens", .stage = .lens, .always = true, .scope = false }, ctx, sceneLens);
    try g.add(.{ .name = "bloom and exposure", .stage = .exposure, .always = true, .scope = false }, ctx, sceneBloom);
    try g.add(.{ .name = "tone mapping", .stage = .tonemap, .always = true, .scope = false }, ctx, sceneTonemap);
}

fn sceneLens(ctx: *ViewContext) !void {
    const p = ctx.scene.?;
    const c = p.shared;
    c.resolved.* = try lensEffects(ctx.renderer, p, c.resolved.*);
}

fn sceneBloom(ctx: *ViewContext) !void {
    const p = ctx.scene.?;
    const c = p.shared;
    c.bloom_count = try bloomAndExposure(ctx.renderer, p, c.resolved.*);
}

fn sceneTonemap(ctx: *ViewContext) !void {
    const p = ctx.scene.?;
    const c = p.shared;
    try tonemapScene(ctx.renderer, p, c.resolved.*, c.bloom_count, ctx.output.texture, ctx.output.format);
}

/// Adds the passes that take `hdr`, which fills the view's region, to the
/// view's target.
pub fn declareFlat(ctx: *ViewContext, hdr: Target) !void {
    const g = ctx.graph;
    const settings = ctx.settings;
    const region = ctx.output.region;
    const frame = try ctx.make(Frame);
    frame.* = .{ .ctx = ctx, .hdr = hdr, .levels = undefined, .count = std.math.clamp(settings.post.bloom_levels, 1, renderer_state.bloom_levels) };
    for (frame.levels[0..frame.count], 0..) |*level, at| {
        level.* = try g.transient(.{
            .name = "bloom",
            .width = @max(region.width >> @intCast(at + 1), 1),
            .height = @max(region.height >> @intCast(at + 1), 1),
            .format = renderer_state.bloom_format,
            .usage = .{ .sampled = true, .color_attachment = true },
        });
    }
    const levels = frame.levels[0..frame.count];
    try g.add(.{ .name = "bloom", .stage = .exposure, .reads = &.{hdr}, .writes = levels }, frame, reduce);
    try g.add(.{ .name = "exposure", .stage = .exposure, .reads = levels[frame.count - 1 ..], .always = true }, frame, meter);
    if (settings.post.bloom > 0 and frame.count > 1)
        try g.add(.{ .name = "bloom upsample", .stage = .exposure, .reads = levels[1..], .writes = levels[0 .. frame.count - 1] }, frame, spread);
    try g.add(.{
        .name = "tonemap",
        .stage = .tonemap,
        .reads = &.{ hdr, levels[0] },
        .color = &.{.{ .target = g.slot(.picture).?, .load = ctx.output.load, .clear = ctx.output.clear }},
    }, frame, tonemap);
    ctx.output.load = .load;
}

fn texel(ctx: *ViewContext, target: Target) [2]f32 {
    const info = ctx.device.textureInfo(ctx.graph.texture(target));
    return .{ 1.0 / @as(f32, @floatFromInt(info.width)), 1.0 / @as(f32, @floatFromInt(info.height)) };
}

fn reduce(frame: *Frame) !void {
    const ctx = frame.ctx;
    const cmd = ctx.cmd;
    var source = frame.hdr;
    for (frame.levels[0..frame.count], 0..) |level, at| {
        try cmd.beginRendering(.{ .color = &.{.{ .texture = ctx.graph.texture(level), .load = .discard }} });
        cmd.bindPipeline(try ctx.renderer.pipelines.get(.bloom_down));
        cmd.pushConstants(BloomPush{ .frame = ctx.frame_address, .source = ctx.index(source), .first_level = @intFromBool(at == 0), .source_texel = texel(ctx, source) });
        cmd.drawFullscreen();
        cmd.endRendering();
        cmd.transition(ctx.graph.texture(level), .shader_read);
        source = level;
    }
}

fn meter(frame: *Frame) !void {
    const ctx = frame.ctx;
    const cmd = ctx.cmd;
    const settings = ctx.settings;
    const view = ctx.view.?;
    const smallest = ctx.index(frame.levels[frame.count - 1]);
    cmd.bindPipeline(try ctx.renderer.pipelines.get(.exposure));
    cmd.pushConstants(extern struct {
        frame: u64,
        source: u32,
        automatic: u32,
        compensation: f32,
        min_luminance: f32,
        max_luminance: f32,
        speed: f32,
        reset: u32,
        depth: u32,
        focus_speed: f32,
        pad: u32 = 0,
    }{
        .frame = ctx.frame_address,
        .source = smallest,
        .automatic = @intFromBool(settings.post.automatic_exposure),
        .compensation = std.math.pow(f32, 2, settings.post.exposure_compensation),
        .min_luminance = std.math.clamp(settings.post.exposure_darkest, 1e-5, 64),
        .max_luminance = 64,
        .speed = @max(settings.post.exposure_speed, 0.01),
        .reset = @intFromBool(view.exposure_reset),
        .depth = smallest,
        .focus_speed = 1,
    });
    cmd.dispatch(1, 1, 1);
    cmd.sync(.compute_to_all);
    view.exposure_reset = false;
}

fn spread(frame: *Frame) !void {
    const ctx = frame.ctx;
    const cmd = ctx.cmd;
    var level: usize = frame.count - 1;
    while (level > 0) : (level -= 1) {
        const into = ctx.graph.texture(frame.levels[level - 1]);
        try cmd.beginRendering(.{ .color = &.{.{ .texture = into, .load = .load }} });
        cmd.bindPipeline(try ctx.renderer.pipelines.get(.bloom_up));
        cmd.pushConstants(BloomPush{ .frame = ctx.frame_address, .source = ctx.index(frame.levels[level]), .first_level = 0, .source_texel = texel(ctx, frame.levels[level]) });
        cmd.drawFullscreen();
        cmd.endRendering();
        cmd.transition(into, .shader_read);
    }
}

fn tonemap(frame: *Frame) !void {
    const ctx = frame.ctx;
    const cmd = ctx.cmd;
    const region = ctx.output.region;
    var push = gradingPush(ctx.renderer, ctx.desc.*, ctx.output.format, false);
    push.frame = ctx.frame_address;
    push.color = ctx.index(frame.hdr);
    push.bloom = ctx.index(frame.levels[0]);
    push.bloom_scale = 1.0 / @as(f32, @floatFromInt(frame.count));
    push.sharpen = 0;
    push.origin = .{ @intCast(region.x), @intCast(region.y) };
    cmd.setViewport(region.x, region.y, region.width, region.height);
    cmd.bindPipeline(try tonemapPipeline(ctx.renderer, ctx.output.format));
    cmd.pushConstants(push);
    cmd.drawFullscreen();
}

/// Push constants of tonemap.frag.
pub const TonemapPush = extern struct {
    frame: u64,
    color: u32,
    bloom: u32,
    bloom_strength: f32,
    encode_srgb: u32,
    sharpen: f32,
    bloom_scale: f32,
    passthrough: u32,
    /// Top-left corner of the area being written, in target pixels.
    origin: [2]i32 = .{ 0, 0 },
    vignette: f32 = 0,
    grain: f32 = 0,
    saturation: f32 = 1,
    contrast: f32 = 1,
    color_filter: [3]f32 = .{ 1, 1, 1 },
    aberration: f32 = 0,
    hdr_paper_white: f32 = 200,
    hdr_peak: f32 = 1000,
    lut: u32 = gpu.invalid_id,
    lut_strength: f32 = 1,
    flare: f32 = 0,
    flare_pad: u32 = 0,
};

/// The tone mapping pipeline for `format`, created on first use.
pub fn tonemapPipeline(renderer: *Renderer, format: rhi.Format) !rhi.Pipeline {
    for (renderer.tonemap_pipelines.items) |entry| if (entry.format == format) return entry.pipeline;
    const pipeline = try renderer.device.createGraphicsPipeline(.{
        .name = "tonemap",
        .vertex = render.shaderCode("fullscreen.vert.spv"),
        .fragment = render.shaderCode("tonemap.frag.spv"),
        .color_targets = &.{.{ .format = format }},
        .cull = .none,
    });
    try renderer.tonemap_pipelines.append(renderer.gpa, .{ .format = format, .pipeline = pipeline });
    return pipeline;
}

/// Depth of field, then motion blur. They run after TAA so the history stays
/// sharp.
pub fn lensEffects(renderer: *Renderer, p: *const ScenePass, picture: rhi.Texture) !rhi.Texture {
    const device = renderer.device;
    const cmd = p.cmd;
    const desc = p.desc;
    const settings = p.settings;
    const view = p.view;
    const height = p.height;
    const debugging = p.debugging;
    const frame_address = p.frame_address;
    var resolved = picture;
    const dof_on = (if (settings.post.depth_of_field) |on| on.aperture else 0) > 0;
    const blur_on = (if (settings.post.motion_blur) |on| on.strength else 0) > 0;
    const lens_targets: ?[2]rhi.Texture = if (!dof_on and !blur_on) null else .{
        try p.keep(renderer, "depth of field", p.resolved_width, p.resolved_height, render.hdr_format),
        try p.keep(renderer, "motion blur", p.resolved_width, p.resolved_height, render.hdr_format),
    };
    const dof_scale = filled(settings.post.depth_of_field).resolution;
    const dof_reduced: ?rhi.Texture = if (dof_on and dof_scale != .full)
        try p.keep(renderer, "depth of field (reduced)", ScenePass.scaled(dof_scale, p.resolved_width), ScenePass.scaled(dof_scale, p.resolved_height), render.hdr_format)
    else
        null;
    if (lens_targets) |lens| if (!debugging) {
        const scale = @as(f32, @floatFromInt(height)) / 1080.0;
        if ((if (settings.post.depth_of_field) |on| on.aperture else 0) > 0) {
            cmd.beginScope("depth of field");
            const focus: f32 = if (filled(settings.post.depth_of_field).autofocus) -1 else @max(filled(settings.post.depth_of_field).focus_distance, desc.camera.near);
            const strength = (if (settings.post.depth_of_field) |on| on.aperture else 0) * 24 * scale;
            const max_radius = @max(filled(settings.post.depth_of_field).max_blur, 1) * scale;
            const gather_target = dof_reduced orelse lens[0];
            try cmd.beginRendering(.{ .color = &.{.{ .texture = gather_target, .load = .discard }} });
            cmd.bindPipeline(try renderer.pipelines.get(.dof));
            cmd.pushConstants(extern struct { frame: u64, color: u32, depth: u32, focus: f32, strength: f32, max_radius: f32, taps: i32, blades: u32, pad: u32 = 0 }{
                .frame = frame_address,
                .color = device.textureIndex(resolved),
                .depth = device.textureIndex(view.depth),
                .focus = focus,
                .strength = strength,
                .max_radius = max_radius,
                .taps = @intCast(std.math.clamp(filled(settings.post.depth_of_field).samples, 4, 128)),
                .blades = @min(filled(settings.post.depth_of_field).blades, 16),
            });
            cmd.drawFullscreen();
            cmd.endRendering();
            cmd.transition(gather_target, .shader_read);
            if (dof_reduced) |reduced| {
                try cmd.beginRendering(.{ .color = &.{.{ .texture = lens[0], .load = .discard }} });
                cmd.bindPipeline(try renderer.pipelines.get(.dof_composite));
                cmd.pushConstants(extern struct { frame: u64, color: u32, blurred: u32, depth: u32, focus: f32, strength: f32, max_radius: f32 }{
                    .frame = frame_address,
                    .color = device.textureIndex(resolved),
                    .blurred = device.textureIndex(reduced),
                    .depth = device.textureIndex(view.depth),
                    .focus = focus,
                    .strength = strength,
                    .max_radius = max_radius,
                });
                cmd.drawFullscreen();
                cmd.endRendering();
                cmd.transition(lens[0], .shader_read);
            }
            cmd.endScope();
            resolved = lens[0];
        }
        if ((if (settings.post.motion_blur) |on| on.strength else 0) > 0) {
            cmd.beginScope("motion blur");
            try cmd.beginRendering(.{ .color = &.{.{ .texture = lens[1], .load = .discard }} });
            cmd.bindPipeline(try renderer.pipelines.get(.motion_blur));
            cmd.pushConstants(extern struct { frame: u64, color: u32, motion: u32, shutter: f32, max_length: f32, taps: i32, spread: u32 }{
                .frame = frame_address,
                .color = device.textureIndex(resolved),
                .motion = device.textureIndex(view.motion),
                .shutter = std.math.clamp((if (settings.post.motion_blur) |on| on.strength else 0), 0, 2),
                .max_length = 0.06,
                .taps = @intCast(std.math.clamp(filled(settings.post.motion_blur).samples, 2, 64)),
                .spread = @intFromBool(filled(settings.post.motion_blur).spread),
            });
            cmd.drawFullscreen();
            cmd.endRendering();
            cmd.transition(lens[1], .shader_read);
            cmd.endScope();
            resolved = lens[1];
        }
    };
    return resolved;
}

/// Builds the bloom chain and meters exposure from its smallest level. Returns
/// the level count.
pub fn bloomAndExposure(renderer: *Renderer, p: *const ScenePass, resolved: rhi.Texture) !usize {
    const device = renderer.device;
    const cmd = p.cmd;
    const settings = p.settings;
    const view_data = p.view_data;
    const view = p.view;
    const frame_address = p.frame_address;
    cmd.beginScope("bloom");
    var source = resolved;
    const bloom_count: usize = std.math.clamp(settings.post.bloom_levels, 1, render.bloom_levels);
    const bloom_chain = try bloomLevels(renderer, p);
    for (bloom_chain[0..bloom_count], 0..) |level, index| {
        const source_info = device.textureInfo(source);
        try cmd.beginRendering(.{ .color = &.{.{ .texture = level, .load = .discard }} });
        cmd.bindPipeline(try renderer.pipelines.get(.bloom_down));
        cmd.pushConstants(BloomPush{
            .frame = frame_address,
            .source = device.textureIndex(source),
            .first_level = @intFromBool(index == 0),
            .source_texel = .{ 1.0 / @as(f32, @floatFromInt(source_info.width)), 1.0 / @as(f32, @floatFromInt(source_info.height)) },
        });
        cmd.drawFullscreen();
        cmd.endRendering();
        cmd.transition(level, .shader_read);
        source = level;
    }
    cmd.endScope();

    cmd.beginScope("exposure");
    cmd.bindPipeline(try renderer.pipelines.get(.exposure));
    cmd.pushConstants(extern struct {
        frame: u64,
        source: u32,
        automatic: u32,
        compensation: f32,
        min_luminance: f32,
        max_luminance: f32,
        speed: f32,
        reset: u32,
        depth: u32,
        focus_speed: f32,
        pad: u32 = 0,
    }{
        .frame = frame_address,
        .source = device.textureIndex(bloom_chain[bloom_count - 1]),
        .automatic = @intFromBool(settings.post.automatic_exposure),
        .compensation = std.math.pow(f32, 2, settings.post.exposure_compensation),
        .min_luminance = std.math.clamp(settings.post.exposure_darkest, 1e-5, 64),
        .max_luminance = 64,
        .speed = @max(settings.post.exposure_speed, 0.01),
        .reset = @intFromBool(view_data.exposure_reset),
        .depth = device.textureIndex(view.depth),
        .focus_speed = @max(filled(settings.post.depth_of_field).autofocus_speed, 0.01),
    });
    cmd.dispatch(1, 1, 1);
    cmd.sync(.compute_to_all);
    view_data.exposure_reset = false;
    cmd.endScope();

    if (settings.post.bloom > 0) {
        cmd.beginScope("bloom upsample");
        var level: usize = bloom_count - 1;
        while (level > 0) : (level -= 1) {
            const source_info = device.textureInfo(bloom_chain[level]);
            try cmd.beginRendering(.{ .color = &.{.{ .texture = bloom_chain[level - 1], .load = .load }} });
            cmd.bindPipeline(try renderer.pipelines.get(.bloom_up));
            cmd.pushConstants(BloomPush{
                .frame = frame_address,
                .source = device.textureIndex(bloom_chain[level]),
                .first_level = 0,
                .source_texel = .{ 1.0 / @as(f32, @floatFromInt(source_info.width)), 1.0 / @as(f32, @floatFromInt(source_info.height)) },
            });
            cmd.drawFullscreen();
            cmd.endRendering();
            cmd.transition(bloom_chain[level - 1], .shader_read);
        }
        cmd.endScope();
    }
    return bloom_count;
}

/// Tone maps into the view's target, at its size and encoding, with bloom, lens
/// and grading effects.
pub fn tonemapScene(renderer: *Renderer, p: *const ScenePass, picture: rhi.Texture, bloom_count: usize, target: rhi.Texture, target_format: rhi.Format) !void {
    const device = renderer.device;
    const cmd = p.cmd;
    const desc = p.desc;
    const settings = p.settings;
    const debugging = p.debugging;
    const frame_address = p.frame_address;
    var resolved = picture;
    const upscaling = p.resolved_width != p.output_width or p.resolved_height != p.output_height;
    const upscaled_target: ?rhi.Texture = if (upscaling) try p.keep(renderer, "upscaled", p.output_width, p.output_height, render.hdr_format) else null;
    const upscaled_edges: ?rhi.Texture = if (upscaling and settings.resolution.upscaler == .fsr) try p.keep(renderer, "upscaled edges", p.output_width, p.output_height, render.hdr_format) else null;
    if (upscaled_target) |upscaled| {
        cmd.beginScope("upscale");
        if (upscaled_edges) |edges| {
            const from = [2]f32{ @floatFromInt(p.width), @floatFromInt(p.height) };
            const to = [2]f32{ @floatFromInt(p.output_width), @floatFromInt(p.output_height) };
            const Bits = struct {
                fn of(values: [4]f32) [4]u32 {
                    return .{ @bitCast(values[0]), @bitCast(values[1]), @bitCast(values[2]), @bitCast(values[3]) };
                }
            };
            try cmd.beginRendering(.{ .color = &.{.{ .texture = edges, .load = .discard }} });
            cmd.bindPipeline(try renderer.pipelines.get(.fsr_easu));
            cmd.pushConstants(extern struct { frame: u64, source: u32, pad: u32 = 0, con0: [4]u32, con1: [4]u32, con2: [4]u32, con3: [4]u32 }{
                .frame = frame_address,
                .source = device.textureIndex(resolved),
                .con0 = Bits.of(.{ from[0] / to[0], from[1] / to[1], 0.5 * from[0] / to[0] - 0.5, 0.5 * from[1] / to[1] - 0.5 }),
                .con1 = Bits.of(.{ 1 / from[0], 1 / from[1], 1 / from[0], -1 / from[1] }),
                .con2 = Bits.of(.{ -1 / from[0], 2 / from[1], 1 / from[0], 2 / from[1] }),
                .con3 = Bits.of(.{ 0, 4 / from[1], 0, 0 }),
            });
            cmd.drawFullscreen();
            cmd.endRendering();
            cmd.transition(edges, .shader_read);
            const sharpness = std.math.pow(f32, 2, -2 * (1 - std.math.clamp(settings.resolution.sharpen, 0, 1)));
            try cmd.beginRendering(.{ .color = &.{.{ .texture = upscaled, .load = .discard }} });
            cmd.bindPipeline(try renderer.pipelines.get(.fsr_rcas));
            cmd.pushConstants(extern struct { frame: u64, source: u32, pad: u32 = 0, con: [4]u32 }{
                .frame = frame_address,
                .source = device.textureIndex(edges),
                .con = Bits.of(.{ sharpness, sharpness, 0, 0 }),
            });
            cmd.drawFullscreen();
            cmd.endRendering();
        } else {
            try cmd.beginRendering(.{ .color = &.{.{ .texture = upscaled, .load = .discard }} });
            cmd.bindPipeline(try renderer.pipelines.get(.upscale));
            cmd.pushConstants(extern struct { frame: u64, source: u32, pad: u32 = 0 }{ .frame = frame_address, .source = device.textureIndex(resolved) });
            cmd.drawFullscreen();
            cmd.endRendering();
        }
        cmd.transition(upscaled, .shader_read);
        cmd.endScope();
        resolved = upscaled;
    }
    cmd.beginScope("tonemap");
    try cmd.beginRendering(.{ .color = &.{.{ .texture = target, .load = .discard }} });
    cmd.bindPipeline(try tonemapPipeline(renderer, target_format));
    var push = gradingPush(renderer, desc, target_format, debugging);
    push.frame = frame_address;
    push.color = device.textureIndex(resolved);
    push.bloom = device.textureIndex((try bloomLevels(renderer, p))[0]);
    push.bloom_scale = 1.0 / @as(f32, @floatFromInt(bloom_count));
    cmd.pushConstants(push);
    cmd.drawFullscreen();
    cmd.endRendering();
    cmd.endScope();
}

/// The view's bloom chain: each level half the size of the one before.
fn bloomLevels(renderer: *Renderer, p: *const ScenePass) ![render.bloom_levels]rhi.Texture {
    var levels: [render.bloom_levels]rhi.Texture = undefined;
    for (&levels, 0..) |*level, index| {
        level.* = try p.keep(renderer, bloom_names[index], @max(p.width >> @intCast(index + 1), 1), @max(p.height >> @intCast(index + 1), 1), @import("../state.zig").bloom_format);
    }
    return levels;
}

const bloom_names = [render.bloom_levels][:0]const u8{ "bloom 1", "bloom 2", "bloom 3", "bloom 4", "bloom 5", "bloom 6" };

/// The tone mapping push constants `desc.settings` ask for, without the
/// pictures to read.
pub fn gradingPush(renderer: *const Renderer, desc: ViewDesc, target_format: rhi.Format, debugging: bool) TonemapPush {
    const settings = desc.settings;
    return .{
        .frame = 0,
        .color = gpu.invalid_id,
        .bloom = gpu.invalid_id,
        .bloom_strength = settings.post.bloom,
        .encode_srgb = output_feature.outputEncoding(renderer, desc, target_format),
        .hdr_paper_white = @max(settings.output.paper_white, 1),
        .hdr_peak = @max(settings.output.peak, settings.output.paper_white),
        .sharpen = if (settings.resolution.temporal_antialiasing and !debugging) settings.resolution.sharpen else 0,
        .bloom_scale = 1,
        .passthrough = @intFromBool(debugging),
        .vignette = if (debugging) 0 else std.math.clamp(settings.post.vignette, 0, 1),
        .grain = if (debugging) 0 else @max(settings.post.film_grain, 0),
        .saturation = if (debugging) 1 else @max(settings.post.saturation, 0),
        .contrast = if (debugging) 1 else std.math.clamp(settings.post.contrast, 0.25, 4),
        .color_filter = .{
            settings.post.color_filter[0] * (1 + 0.25 * std.math.clamp(settings.post.temperature, -1, 1)),
            settings.post.color_filter[1],
            settings.post.color_filter[2] * (1 - 0.25 * std.math.clamp(settings.post.temperature, -1, 1)),
        },
        .aberration = if (debugging) 0 else std.math.clamp(settings.post.chromatic_aberration, 0, 1),
        .lut = if (debugging) gpu.invalid_id else if (settings.post.color_lut) |image| image.index else gpu.invalid_id,
        .lut_strength = std.math.clamp(settings.post.color_lut_strength, 0, 1),
        .flare = if (debugging) 0 else @max(settings.post.lens_flare, 0),
    };
}
