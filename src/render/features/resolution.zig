//! The size a view is rendered at and how it is antialiased and brought to the size of its target.
const pipelines_module = @import("../renderer/pipelines.zig");
const taa_push = @import("../shaders/push/taa.zig");
const render = @import("../renderer.zig");
const scene_pass = @import("../scene_pass.zig");
const path_tracing_feature = @import("path_tracing.zig");
const gpu = @import("../gpu.zig");
const upscaling = @import("../techniques/upscaling.zig");
const ScenePass = @import("../scene_pass.zig").ScenePass;
const rhi = @import("../../rhi/rhi.zig");
const std = @import("std");
const api = @import("../api.zig");
const features = @import("../core/features.zig");

const Renderer = render.Renderer;
const ViewContext = features.ViewContext;

pub const name = "resolution";

/// What a view keeps for antialiasing: this frame's resolved picture and the
/// last one, which swap every frame, and the vendor upscaler it runs.
pub const View = struct {
    history: [2]?rhi.Texture = .{ null, null },
    width: u32 = 0,
    height: u32 = 0,
    upscaler: upscaling.Slot = .{},

    pub fn init(_: *rhi.Device) !View {
        return .{};
    }

    pub fn deinit(self: *View, device: *rhi.Device) void {
        for (self.history) |texture| if (texture) |made| device.destroyTexture(made);
        self.upscaler.deinit(device);
    }

    /// Makes the pictures `width` by `height`.
    pub fn fit(self: *View, device: *rhi.Device, width: u32, height: u32) !void {
        if (self.history[0] != null and self.width == width and self.height == height) return;
        for (&self.history) |*texture| {
            if (texture.*) |made| device.destroyTexture(made);
            texture.* = null;
        }
        for (&self.history) |*texture| {
            texture.* = try device.createTexture(.{ .name = "taa history", .width = width, .height = height, .format = render.hdr_format, .usage = .{ .sampled = true, .color_attachment = true, .storage = device.caps.storage_images, .copy_dst = true } });
        }
        self.width = width;
        self.height = height;
    }
};

/// The view's resolved pictures, indexed by frame parity: `[frames & 1]` is
/// this frame's, the other the last.
pub fn history(renderer: *Renderer, view_data: *render.ViewData) ![2]rhi.Texture {
    const own = try features.stateOf(view_data, renderer.device, @This());
    return .{ own.history[0].?, own.history[1].? };
}

pub const Settings = struct {
    /// Scene resolution as a fraction of the output size; above 1 supersamples.
    /// Draw lists are always drawn at full size.
    scale: f32 = 1,
    /// How a picture rendered below output size is brought up to it.
    /// `.temporal`, `.fsr2`, `.fsr3` and `.dlss` need `temporal_antialiasing`.
    /// `.fsr2` and `.fsr3` also need storage images and `-Dfidelityfx`;
    /// `.dlss` an NVIDIA GPU and the DLSS SDK (`zig build dlss-sdk`), and
    /// it also antialiases at full size. `.fsr` is FSR 1, sharpened by
    /// `sharpen`. What cannot run is replaced by `.temporal` and reported
    /// in `Stats.downgraded`.
    upscaler: api.Upscaler = .temporal,
    /// Shows a generated picture between every two rendered, on a view
    /// that fills the backbuffer; presentation is then vsynced. `.fsr3`
    /// needs the `.fsr3` upscaler. Draw lists are interpolated with the
    /// scene.
    frame_generation: ?api.FrameGeneration = null,
    /// Temporal antialiasing (TAA). Several other settings rely on it to
    /// average out their noise.
    temporal_antialiasing: bool = true,
    /// Smooths the stair steps of edges from the finished picture alone
    /// (FXAA), so nothing smears or trails in motion. For a view with
    /// `temporal_antialiasing` off; it does not average the noise of soft
    /// shadows, reflections and the like as that does. Draw lists are drawn
    /// after it and stay as sharp as they are.
    edge_antialiasing: bool = false,
    /// Mip bias for material textures under TAA; negative is sharper.
    texture_mip_bias: f32 = -0.25,
    /// Strength of the post-TAA sharpening filter, 0..1.
    sharpen: f32 = 0.35,
};

pub fn preset(quality: api.Quality) Settings {
    return switch (quality) {
        .ultra => .{},
        .high => .{},
        .medium => .{},
        .low => .{ .scale = 0.75 },
    };
}

pub fn resolve(setting: *Settings, r: *features.Resolve) void {
    const wanted: ?upscaling.Technique = switch (setting.upscaler) {
        .fsr2 => .fsr2,
        .fsr3 => .fsr3,
        .dlss => .dlss_super_resolution,
        else => null,
    };
    if (wanted) |vendor| {
        const reason: ?api.DowngradeReason = if (r.orthographic)
            .unsupported
        else if (!setting.temporal_antialiasing)
            .needs_temporal_antialiasing
        else if (!r.upscalers.has(vendor))
            .unavailable
        else
            null;
        if (reason) |why| {
            r.downgrade("resolution.upscaler", @tagName(setting.upscaler), "temporal", why);
            setting.upscaler = .temporal;
        }
    }
    if (setting.frame_generation) |generation| {
        const upscaler_fits = switch (generation) {
            .fsr3 => setting.upscaler == .fsr3,
        };
        if (!upscaler_fits) {
            r.downgrade("resolution.frame_generation", @tagName(generation), "off", .unavailable);
            setting.frame_generation = null;
        }
    }
}

/// Adds the feature's passes to a view of a scene. A path traced view leaves
/// out those whose result the tracer replaces.
pub fn declare(ctx: *ViewContext) !void {
    const p = ctx.scene orelse return;
    if (p.settings.resolution.temporal_antialiasing and !p.debugging) {
        ctx.constants.temporal = 1;
        ctx.constants.texture_gradient_scale = std.math.pow(f32, 2, std.math.clamp(p.settings.resolution.texture_mip_bias, -2, 2));
    }
    const g = ctx.graph;
    try g.add(.{ .name = "temporal antialiasing", .stage = .resolve, .always = true, .scope = false }, ctx, antialias);
}

fn antialias(ctx: *ViewContext) !void {
    const p = ctx.scene.?;
    const c = p.shared;
    c.resolved.* = try resolveTemporal(ctx.renderer, p, c.path_traced);
}

/// The vendor technique the view's settings ask for, if any.
fn technique(p: *const ScenePass, reconstructing: bool) ?upscaling.Technique {
    return switch (p.settings.resolution.upscaler) {
        .fsr2 => .fsr2,
        .fsr3 => .fsr3,
        .dlss => if (reconstructing) .dlss_ray_reconstruction else .dlss_super_resolution,
        else => null,
    };
}

/// The view's upscaler running `wanted` at this frame's sizes, started if
/// it is not yet. Null where it is not asked for or will not run, which is
/// logged once and reported every frame.
pub fn upscalerFor(renderer: *Renderer, p: *const ScenePass, wanted: upscaling.Technique) !?*upscaling.Running {
    const device = renderer.device;
    if (!p.settings.resolution.temporal_antialiasing or p.debugging) return null;
    if (!upscaling.Availability.of(device, renderer.internal.dlss).has(wanted)) return null;
    const output_info = device.textureInfo((try history(renderer, p.view_data))[0]);
    const key = upscaling.Key{
        .technique = wanted,
        .render_size = .{ p.width, p.height },
        .output_size = .{ output_info.width, output_info.height },
    };
    const slot = &(try features.stateOf(p.view_data, device, @This())).upscaler;
    const was_refused = slot.refuses(key);
    const running = try slot.ensure(device, key, upscaling.Running.Context{ .device = device, .cmd = p.cmd }, upscaling.Running.start);
    if (running == null) refused(renderer, wanted, !was_refused);
    return running;
}

fn refused(renderer: *Renderer, wanted: upscaling.Technique, first: bool) void {
    const reconstruction = wanted == .dlss_ray_reconstruction;
    if (first) std.log.warn("{s} would not run; {s} stands in", .{ wanted.label(), if (reconstruction) "the built-in denoiser" else "temporal antialiasing" });
    renderer.internal.downgrades.add(if (reconstruction)
        .{ .feature = "path_tracing.denoiser", .requested = "ray_reconstruction", .used = "builtin", .reason = .unavailable }
    else
        .{ .feature = "resolution.upscaler", .requested = @tagName(wanted), .used = "temporal", .reason = .unavailable });
}

/// Resolves into `output` with the vendor upscaler the settings ask for,
/// in place of temporal antialiasing. Returns whether it did.
fn resolveWithUpscaler(renderer: *Renderer, p: *const ScenePass, output: rhi.Texture, path_traced: bool) !bool {
    const device = renderer.device;
    const cmd = p.cmd;
    const view_data = p.view_data;
    const view = p.view;
    const own = try features.stateOf(view_data, device, @This());
    const path_state = features.viewState(view_data, path_tracing_feature);
    const reconstructing = path_traced and path_state != null and path_state.?.reconstructing;
    const wanted = technique(p, reconstructing) orelse return false;
    const generating = p.settings.resolution.frame_generation != null and p.fills_backbuffer;
    const output_info = device.textureInfo(output);
    const enlarges = output_info.width > p.width or output_info.height > p.height;
    if ((wanted == .fsr2 or wanted == .fsr3) and !generating and !enlarges) return false;
    const running = try upscalerFor(renderer, p, wanted) orelse return false;
    const reset = !own.upscaler.continues(renderer.internal.frame_index) or !view.history_valid;
    cmd.beginScope(wanted.label());
    defer cmd.endScope();
    cmd.transition(output, .shader_read);
    running.dispatch(device, cmd, .{
        .color = view.hdr,
        .depth = view.depth,
        .motion = view.motion,
        .output = output,
        .guides = if (reconstructing) path_state.?.guides() else null,
        .jitter = p.jitter,
        .camera = p.desc.camera,
        .world_to_view = p.view_matrix,
        .view_to_clip = p.proj_unjittered,
        .delta_time = p.delta_time,
        .reset = reset,
    }) catch {
        own.upscaler.refuse();
        refused(renderer, wanted, true);
        return false;
    };
    if (generating) if (running.generator()) |generator| {
        renderer.internal.generating = generator;
        renderer.internal.generating_reset = reset;
    };
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
    const path_still = if (features.viewState(view_data, path_tracing_feature)) |state| state.still else 0;
    const still: f32 = @floatFromInt(path_still -| path_tracing_feature.frames_to_settle);
    const settled: f32 = if (path_traced) @min(still / path_tracing_feature.frames_to_hand_over, 1) else 0;
    if (settings.resolution.temporal_antialiasing and !debugging) {
        const pictures = try history(renderer, view_data);
        const current = pictures[@intCast(view_data.frames & 1)];
        const previous = pictures[@intCast((view_data.frames + 1) & 1)];
        if (try resolveWithUpscaler(renderer, p, current, path_traced)) {
            view.history_valid = true;
            return current;
        }
        cmd.beginScope("temporal antialiasing");
        try cmd.beginRendering(.{ .color = &.{.{ .texture = current, .load = .discard }} });
        cmd.bindPipeline(try renderer.internal.pipelines.of(taaPipeline));
        cmd.pushConstants(taa_push.Push{
            .frame = frame_address,
            .color_texture = device.textureIndex(view.hdr),
            .history_texture = device.textureIndex(previous),
            .motion_texture = device.textureIndex(view.motion),
            .depth_texture = device.textureIndex(view.depth),
            .history_valid = @intFromBool(view.history_valid),
            .settled = settled,
            .previous_motion_texture = if (view.history_valid) device.textureIndex(view.previous_motion) else gpu.invalid_id,
        });
        cmd.drawFullscreen();
        cmd.endRendering();
        cmd.endScope();
        resolved = current;
        view.history_valid = true;
    } else {
        view.history_valid = false;
    }
    return resolved;
}

fn taaPipeline(_: *rhi.Device) pipelines_module.Desc {
    return pipelines_module.pass("taa", pipelines_module.shaderCode("taa.frag.spv"), &.{.{ .format = pipelines_module.hdr_format }});
}
