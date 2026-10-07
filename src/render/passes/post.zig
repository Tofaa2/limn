//! Post-processing: temporal antialiasing, lens effects, bloom, exposure and
//! tone mapping into the view's target. Internal to the renderer.
const std = @import("std");
const rhi = @import("../../rhi/rhi.zig");
const gpu = @import("../gpu.zig");
const render = @import("../renderer.zig");
const ScenePass = @import("../scene_pass.zig").ScenePass;
const ffx = @import("../ffx.zig");
const path_tracing = @import("path_tracing.zig");

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

/// 0: the target format encodes. 1: sRGB. 2: HDR10.
pub fn outputEncoding(renderer: *const Renderer, desc: ViewDesc, format: rhi.Format) u32 {
    const plain: u32 = @intFromBool(!format.isSrgb());
    return switch (desc.settings.output_encoding) {
        .auto => if (desc.target == .backbuffer and renderer.device.hdr_active) 2 else plain,
        .srgb => plain,
        .hdr10 => 2,
    };
}

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

/// Resolves with FidelityFX Super Resolution 2 or 3 instead of TAA, when
/// requested, rendering below output size and available. Returns whether it
/// did.
fn resolveWithFidelityFx(renderer: *Renderer, p: *const ScenePass, output: rhi.Texture) !bool {
    const device = renderer.device;
    const cmd = p.cmd;
    const view_data = p.view_data;
    const view = p.view;
    const generation: ffx.Generation = switch (p.settings.upscaling) {
        .fsr2 => .fsr2,
        .fsr3 => .fsr3,
        else => return false,
    };
    if (!ffx.available or !device.storage_images) return false;
    const render_size = [2]u32{ p.width, p.height };
    const output_info = device.textureInfo(output);
    const output_size = [2]u32{ output_info.width, output_info.height };
    const generating = generation == .fsr3 and p.settings.frame_generation and p.fills_backbuffer;
    if (!generating and output_size[0] <= render_size[0] and output_size[1] <= render_size[1]) return false;
    if (view_data.upscaler) |upscaler| {
        if (upscaler.generation != generation or !std.meta.eql(upscaler.render_size, render_size) or !std.meta.eql(upscaler.output_size, output_size)) {
            // Frames using it may still be in flight.
            try device.waitIdle();
            upscaler.destroy();
            view_data.upscaler = null;
        }
    }
    var fresh = false;
    if (view_data.upscaler == null) {
        if (view_data.upscaler_refused) return false;
        view_data.upscaler = ffx.Upscaler.create(device, generation, render_size, output_size) orelse {
            std.log.warn("FidelityFX Super Resolution would not start; temporal upscaling stands in", .{});
            view_data.upscaler_refused = true;
            return false;
        };
        fresh = true;
    }
    cmd.beginScope("fidelityfx super resolution");
    cmd.transition(view.hdr, .shader_read);
    cmd.transition(view.depth, .shader_read);
    cmd.transition(view.motion, .shader_read);
    cmd.transition(output, .shader_read);
    try view_data.upscaler.?.dispatch(device, cmd, .{
        .color = view.hdr,
        .depth = view.depth,
        .motion = view.motion,
        .output = output,
        .jitter = p.jitter,
        // Sharpening happens in tone mapping.
        .sharpness = 0,
        .delta_time = p.delta_time,
        .near = p.desc.camera.near,
        .fov_y = p.desc.camera.fov_y,
        .reset = fresh or !view.history_valid,
    });
    cmd.endScope();
    if (generating) {
        renderer.generating = view_data.upscaler;
        renderer.generating_reset = fresh or !view.history_valid;
    }
    return true;
}

/// Temporal antialiasing. Returns the texture later passes continue from.
pub fn resolveTemporal(renderer: *Renderer, p: *const ScenePass, path_traced: bool) !rhi.Texture {
    const device = renderer.device;
    const cmd = p.cmd;
    const settings = p.settings;
    const view_data = p.view_data;
    const view = p.view;
    const debugging = p.debugging;
    const frame_address = p.frame_address;
    var resolved = view.hdr;
    const still: f32 = @floatFromInt(view_data.path_still -| path_tracing.frames_to_settle);
    const settled: f32 = if (path_traced) @min(still / path_tracing.frames_to_hand_over, 1) else 0;
    if (settings.temporal_antialiasing and !debugging) {
        const current = view.history[@intCast(view_data.frames & 1)];
        const previous = view.history[@intCast((view_data.frames + 1) & 1)];
        if (try resolveWithFidelityFx(renderer, p, current)) {
            view.history_valid = true;
            return current;
        }
        cmd.beginScope("temporal antialiasing");
        try cmd.beginRendering(.{ .color = &.{.{ .texture = current, .load = .discard }} });
        cmd.bindPipeline(renderer.pipelines.taa);
        cmd.pushConstants(extern struct { frame: u64, color: u32, history: u32, motion: u32, depth: u32, history_valid: u32, settled: f32 }{
            .frame = frame_address,
            .color = device.textureIndex(view.hdr),
            .history = device.textureIndex(previous),
            .motion = device.textureIndex(view.motion),
            .depth = device.textureIndex(view.depth),
            .history_valid = @intFromBool(view.history_valid),
            .settled = settled,
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
    if (view.lens) |lens| if (!debugging) {
        const scale = @as(f32, @floatFromInt(height)) / 1080.0;
        if (settings.dof_aperture > 0) {
            cmd.beginScope("depth of field");
            const focus: f32 = if (settings.dof_autofocus) -1 else @max(settings.dof_focus_distance, desc.camera.near);
            const strength = settings.dof_aperture * 24 * scale;
            const max_radius = @max(settings.dof_max_blur, 1) * scale;
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

    // The smallest level is the luminance meter; the upsample chain never
    // writes it.
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

/// Tone maps into the view's target, at its size and encoding, with bloom, lens
/// and grading effects.
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
        cmd.beginScope("upscale");
        if (view.upscaled_edges) |edges| {
            // FidelityFX Super Resolution 1: constants as in `FsrEasuCon` and
            // `FsrRcasCon`.
            const from = [2]f32{ @floatFromInt(p.width), @floatFromInt(p.height) };
            const to = [2]f32{ @floatFromInt(p.output_width), @floatFromInt(p.output_height) };
            const Bits = struct {
                fn of(values: [4]f32) [4]u32 {
                    return .{ @bitCast(values[0]), @bitCast(values[1]), @bitCast(values[2]), @bitCast(values[3]) };
                }
            };
            try cmd.beginRendering(.{ .color = &.{.{ .texture = edges, .load = .discard }} });
            cmd.bindPipeline(renderer.pipelines.fsr_easu);
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
            // RCAS sharpness: 2 stops down at `sharpen` 0, none at 1.
            const sharpness = std.math.pow(f32, 2, -2 * (1 - std.math.clamp(settings.sharpen, 0, 1)));
            try cmd.beginRendering(.{ .color = &.{.{ .texture = upscaled, .load = .discard }} });
            cmd.bindPipeline(renderer.pipelines.fsr_rcas);
            cmd.pushConstants(extern struct { frame: u64, source: u32, pad: u32 = 0, con: [4]u32 }{
                .frame = frame_address,
                .source = device.textureIndex(edges),
                .con = Bits.of(.{ sharpness, sharpness, 0, 0 }),
            });
            cmd.drawFullscreen();
            cmd.endRendering();
        } else {
            try cmd.beginRendering(.{ .color = &.{.{ .texture = upscaled, .load = .discard }} });
            cmd.bindPipeline(renderer.pipelines.upscale);
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
