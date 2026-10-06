//! The passes that work on a view's whole picture once its scene has been
//! drawn: temporal antialiasing, the lens effects, bloom and exposure, and
//! tone mapping into the view's target. Internal to the renderer.
const std = @import("std");
const rhi = @import("../../rhi/rhi.zig");
const gpu = @import("../gpu.zig");
const render = @import("../renderer.zig");
const ScenePass = @import("../scene_pass.zig").ScenePass;

const Renderer = render.Renderer;
const ViewDesc = render.ViewDesc;

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

/// 0: the target's format encodes by itself. 1: sRGB by hand. 2: HDR10.
pub fn outputEncoding(renderer: *const Renderer, desc: ViewDesc, format: rhi.Format) u32 {
    const plain: u32 = @intFromBool(!format.isSrgb());
    return switch (desc.settings.output_encoding) {
        .auto => if (desc.target == .backbuffer and renderer.device.hdr_active) 2 else plain,
        .srgb => plain,
        .hdr10 => 2,
    };
}

/// The tone mapping pipeline for a target of `format`, built the first
/// time a target of that format is drawn to.
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

/// Temporal antialiasing: joins the picture with the view's history.
/// Returns the picture the passes after it carry on from.
pub fn resolveTemporal(renderer: *Renderer, p: *const ScenePass, path_traced: bool) !rhi.Texture {
    const device = renderer.device;
    const cmd = p.cmd;
    const settings = p.settings;
    const view_data = p.view_data;
    const view = p.view;
    const debugging = p.debugging;
    const frame_address = p.frame_address;
    var resolved = view.hdr;
    // A path-traced picture is already an average over frames.
    if (settings.temporal_antialiasing and !debugging and !path_traced) {
        cmd.beginScope("temporal antialiasing");
        const current = view.history[@intCast(view_data.frames & 1)];
        const previous = view.history[@intCast((view_data.frames + 1) & 1)];
        try cmd.beginRendering(.{ .color = &.{.{ .texture = current, .load = .discard }} });
        cmd.bindPipeline(renderer.pipelines.taa);
        cmd.pushConstants(extern struct { frame: u64, color: u32, history: u32, motion: u32, depth: u32, history_valid: u32, pad: u32 = 0 }{
            .frame = frame_address,
            .color = device.textureIndex(view.hdr),
            .history = device.textureIndex(previous),
            .motion = device.textureIndex(view.motion),
            .depth = device.textureIndex(view.depth),
            .history_valid = @intFromBool(view.history_valid),
        });
        cmd.drawFullscreen();
        cmd.endRendering();
        cmd.transition(current, .shader_read);
        cmd.endScope();
        resolved = current;
        view.history_valid = true;
    } else {
        view.history_valid = false;
    }
    return resolved;
}

/// Depth of field, then motion blur, each into its own target. They
/// come after antialiasing so the history stays sharp.
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
    if (view.lens) |lens| if (!debugging) {
        const scale = @as(f32, @floatFromInt(height)) / 1080.0;
        if (settings.dof_aperture > 0) {
            cmd.beginScope("depth of field");
            const focus: f32 = if (settings.dof_autofocus) -1 else @max(settings.dof_focus_distance, desc.camera.near);
            const strength = settings.dof_aperture * 24 * scale;
            const max_radius = @max(settings.dof_max_blur, 1) * scale;
            // Gathered straight into the full-size target, or into a
            // smaller one that is then joined with the sharp picture.
            const gather_target = view.dof_reduced orelse lens[0];
            try cmd.beginRendering(.{ .color = &.{.{ .texture = gather_target, .load = .discard }} });
            cmd.bindPipeline(renderer.pipelines.dof);
            cmd.pushConstants(extern struct { frame: u64, color: u32, depth: u32, focus: f32, strength: f32, max_radius: f32, taps: i32, blades: u32, pad: u32 = 0 }{
                .frame = frame_address,
                .color = device.textureIndex(resolved),
                .depth = device.textureIndex(view.depth),
                .focus = focus,
                .strength = strength,
                .max_radius = max_radius,
                .taps = @intCast(std.math.clamp(settings.dof_samples, 4, 128)),
                .blades = @min(settings.dof_blades, 16),
            });
            cmd.drawFullscreen();
            cmd.endRendering();
            cmd.transition(gather_target, .shader_read);
            if (view.dof_reduced) |reduced| {
                try cmd.beginRendering(.{ .color = &.{.{ .texture = lens[0], .load = .discard }} });
                cmd.bindPipeline(renderer.pipelines.dof_composite);
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
        if (settings.motion_blur > 0) {
            cmd.beginScope("motion blur");
            try cmd.beginRendering(.{ .color = &.{.{ .texture = lens[1], .load = .discard }} });
            cmd.bindPipeline(renderer.pipelines.motion_blur);
            cmd.pushConstants(extern struct { frame: u64, color: u32, motion: u32, shutter: f32, max_length: f32, taps: i32, spread: u32 }{
                .frame = frame_address,
                .color = device.textureIndex(resolved),
                .motion = device.textureIndex(view.motion),
                .shutter = std.math.clamp(settings.motion_blur, 0, 2),
                .max_length = 0.06,
                .taps = @intCast(std.math.clamp(settings.motion_blur_samples, 2, 64)),
                .spread = @intFromBool(settings.motion_blur_spread),
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

/// Builds the bloom chain from the picture and meters the exposure
/// from its smallest level. Returns how many levels the chain has.
pub fn bloomAndExposure(renderer: *Renderer, p: *const ScenePass, resolved: rhi.Texture) !usize {
    const device = renderer.device;
    const cmd = p.cmd;
    const settings = p.settings;
    const view_data = p.view_data;
    const view = p.view;
    const frame_address = p.frame_address;
    cmd.beginScope("bloom");
    const BloomPush = extern struct { frame: u64, source: u32, first_level: u32, source_texel: [2]f32 };
    var source = resolved;
    const bloom_count: usize = std.math.clamp(settings.bloom_levels, 1, render.bloom_levels);
    for (view.bloom[0..bloom_count], 0..) |level, index| {
        const source_info = device.textureInfo(source);
        try cmd.beginRendering(.{ .color = &.{.{ .texture = level, .load = .discard }} });
        cmd.bindPipeline(renderer.pipelines.bloom_down);
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

    // The smallest level doubles as the luminance meter. It is read
    // before the upsample chain, which never writes to it.
    cmd.beginScope("exposure");
    cmd.bindPipeline(renderer.pipelines.exposure);
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
        .source = device.textureIndex(view.bloom[bloom_count - 1]),
        .automatic = @intFromBool(settings.automatic_exposure),
        .compensation = std.math.pow(f32, 2, settings.exposure_compensation),
        .min_luminance = 0.002,
        .max_luminance = 64,
        .speed = 1.6,
        .reset = @intFromBool(view_data.exposure_reset),
        .depth = device.textureIndex(view.depth),
        .focus_speed = @max(settings.dof_autofocus_speed, 0.01),
    });
    cmd.dispatch(1, 1, 1);
    cmd.sync(.compute_to_all);
    view_data.exposure_reset = false;
    cmd.endScope();

    if (settings.bloom > 0) {
        cmd.beginScope("bloom upsample");
        var level: usize = bloom_count - 1;
        while (level > 0) : (level -= 1) {
            const source_info = device.textureInfo(view.bloom[level]);
            try cmd.beginRendering(.{ .color = &.{.{ .texture = view.bloom[level - 1], .load = .load }} });
            cmd.bindPipeline(renderer.pipelines.bloom_up);
            cmd.pushConstants(BloomPush{
                .frame = frame_address,
                .source = device.textureIndex(view.bloom[level]),
                .first_level = 0,
                .source_texel = .{ 1.0 / @as(f32, @floatFromInt(source_info.width)), 1.0 / @as(f32, @floatFromInt(source_info.height)) },
            });
            cmd.drawFullscreen();
            cmd.endRendering();
            cmd.transition(view.bloom[level - 1], .shader_read);
        }
        cmd.endScope();
    }
    return bloom_count;
}

/// Tone maps the picture into the view's target, at the target's size
/// and in its encoding, with bloom and the lens and grading effects.
pub fn tonemapScene(renderer: *Renderer, p: *const ScenePass, picture: rhi.Texture, bloom_count: usize, target: rhi.Texture, target_format: rhi.Format) !void {
    const device = renderer.device;
    const cmd = p.cmd;
    const desc = p.desc;
    const settings = p.settings;
    const view = p.view;
    const debugging = p.debugging;
    const frame_address = p.frame_address;
    var resolved = picture;
    if (view.upscaled) |upscaled| {
        // The scene was rendered at another resolution than the output.
        cmd.beginScope("upscale");
        try cmd.beginRendering(.{ .color = &.{.{ .texture = upscaled, .load = .discard }} });
        cmd.bindPipeline(renderer.pipelines.upscale);
        cmd.pushConstants(extern struct { frame: u64, source: u32, pad: u32 = 0 }{ .frame = frame_address, .source = device.textureIndex(resolved) });
        cmd.drawFullscreen();
        cmd.endRendering();
        cmd.transition(upscaled, .shader_read);
        cmd.endScope();
        resolved = upscaled;
    }
    cmd.beginScope("tonemap");
    try cmd.beginRendering(.{ .color = &.{.{ .texture = target, .load = .discard }} });
    cmd.bindPipeline(try tonemapPipeline(renderer, target_format));
    cmd.pushConstants(TonemapPush{
        .frame = frame_address,
        .color = device.textureIndex(resolved),
        .bloom = device.textureIndex(view.bloom[0]),
        .bloom_strength = settings.bloom,
        .encode_srgb = outputEncoding(renderer, desc, target_format),
        .hdr_paper_white = @max(settings.hdr_paper_white, 1),
        .hdr_peak = @max(settings.hdr_peak, settings.hdr_paper_white),
        .sharpen = if (settings.temporal_antialiasing and !debugging) settings.sharpen else 0,
        .bloom_scale = 1.0 / @as(f32, @floatFromInt(bloom_count)),
        .passthrough = @intFromBool(debugging),
        .vignette = if (debugging) 0 else std.math.clamp(settings.vignette, 0, 1),
        .grain = if (debugging) 0 else @max(settings.film_grain, 0),
        .saturation = if (debugging) 1 else @max(settings.saturation, 0),
        .contrast = if (debugging) 1 else std.math.clamp(settings.contrast, 0.25, 4),
        // Temperature shifts the balance between red and blue.
        .color_filter = .{
            settings.color_filter[0] * (1 + 0.25 * std.math.clamp(settings.temperature, -1, 1)),
            settings.color_filter[1],
            settings.color_filter[2] * (1 - 0.25 * std.math.clamp(settings.temperature, -1, 1)),
        },
        .aberration = if (debugging) 0 else std.math.clamp(settings.chromatic_aberration, 0, 1),
        .lut = if (debugging) gpu.invalid_id else if (settings.color_lut) |image| image.index else gpu.invalid_id,
        .lut_strength = std.math.clamp(settings.color_lut_strength, 0, 1),
        .flare = if (debugging) 0 else @max(settings.lens_flare, 0),
    });
    cmd.drawFullscreen();
    cmd.endRendering();
    cmd.endScope();
}
