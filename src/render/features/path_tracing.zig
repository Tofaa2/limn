//! Path tracing in place of rasterized lighting.
const render = @import("../renderer.zig");
const scene_pass = @import("../scene_pass.zig");
const resolution_feature = @import("resolution.zig");
const filled = @import("../api.zig").filled;
const std = @import("std");
const rhi = @import("../../rhi/rhi.zig");
const api = @import("../api.zig");
const features = @import("../core/features.zig");

const ScenePass = scene_pass.ScenePass;
const Renderer = render.Renderer;
const ViewContext = features.ViewContext;

pub const name = "path_tracing";

pub const Settings = struct {
    /// Maximum bounces per path, 1..16; 1 is direct light only.
    bounces: u32 = 4,
    /// Paths per pixel per frame, 1..64.
    samples: u32 = 1,
    /// Most light a path may return through a rough bounce, before exposure.
    /// Lamp light on the surface seen is limited to eight times this; directly
    /// seen and mirrored light is not limited.
    clamp: f32 = 12,
    /// End a path in the bounce light probes at the first surface it reaches
    /// after a rough bounce, where the GPU traces rays. Much less noise; false
    /// follows every bounce, for a still picture left to gather.
    probes: bool = true,
    /// How lamp and glow light is sampled at each surface.
    direct: api.DirectSampling = .ris,
    /// What removes the noise; null only gathers over frames. `.builtin`
    /// averages indirect light over neighbouring pixels of the same surface
    /// while a pixel still varies between frames. `.ray_reconstruction` is
    /// DLSS, which needs `Settings.resolution.upscaler` to be `.dlss`, else
    /// `.builtin` stands in.
    denoiser: ?api.Denoiser = .builtin,
};

/// What a view keeps for path tracing from frame to frame.
pub const View = struct {
    /// What the tracer found this frame, before anything is gathered: the
    /// textures behind `Signals`.
    raw_color: ?rhi.Texture = null,
    raw_guide: ?rhi.Texture = null,
    raw_soft: ?rhi.Texture = null,
    raw_facing: ?rhi.Texture = null,
    raw_lamp: ?rhi.Texture = null,
    raw_gloss: ?rhi.Texture = null,
    raw_surface: ?rhi.Texture = null,
    /// What a denoising upscaler reads besides: see `guides`.
    raw_scatter: ?rhi.Texture = null,
    raw_reflect: ?rhi.Texture = null,
    raw_normal: ?rhi.Texture = null,
    /// The running average and last frame's, for reprojection.
    accum: ?rhi.Texture = null,
    accum_old: ?rhi.Texture = null,
    /// Albedo guide accumulated alongside.
    guide: ?rhi.Texture = null,
    guide_old: ?rhi.Texture = null,
    /// The noisy part of the picture.
    soft: ?rhi.Texture = null,
    soft_old: ?rhi.Texture = null,
    /// The two targets the built-in denoiser goes back and forth between.
    filtered: ?rhi.Texture = null,
    filtered_other: ?rhi.Texture = null,
    /// Normal and distance of what each pixel shows, seen through mirrors.
    facing: ?rhi.Texture = null,
    facing_old: ?rhi.Texture = null,
    /// Normal, roughness and distance of the primary hit.
    surface: ?rhi.Texture = null,
    surface_old: ?rhi.Texture = null,
    /// Lamp and glow light on the surface seen, over its color.
    lamp: ?rhi.Texture = null,
    lamp_old: ?rhi.Texture = null,
    /// The light sample each pixel keeps (`Reservoir` in pathtrace.slang).
    reservoir: ?rhi.Texture = null,
    reservoir_old: ?rhi.Texture = null,
    /// Glossy reflections as traced, and the reflection denoiser's
    /// (ffx_reflections.glsl) targets and history.
    gloss_gathered: ?rhi.Texture = null,
    gloss_gathered_old: ?rhi.Texture = null,
    reflection_reprojected: ?rhi.Texture = null,
    reflection_samples: ?rhi.Texture = null,
    reflection_samples_old: ?rhi.Texture = null,
    reflection_average: ?rhi.Texture = null,
    reflection_prefiltered: ?rhi.Texture = null,
    reflection_resolved: ?rhi.Texture = null,
    reflection_resolved_old: ?rhi.Texture = null,
    camera: api.Camera = .{},
    size: [2]u32 = .{ 0, 0 },
    /// Frames gathered.
    gathered: u32 = 0,
    /// Whether last frame's light samples and surfaces are there to reuse.
    reusable: bool = false,
    /// Frames since anything moved.
    still: u32 = 0,
    key: u64 = 0,
    /// Hash of where things and the sun were when the view was last traced.
    motion_key: u64 = 0,
    /// The picture was traced for a denoising upscaler this frame: the
    /// targets hold what that reads, not what is gathered.
    reconstructing: bool = false,

    pub fn init(_: *rhi.Device) !View {
        return .{};
    }

    pub fn deinit(self: *View, device: *rhi.Device) void {
        inline for (@typeInfo(View).@"struct".fields) |field| {
            if (field.type != ?rhi.Texture) continue;
            if (@field(self, field.name)) |texture| device.destroyTexture(texture);
        }
        self.* = .{};
    }

    /// What a denoising upscaler reads besides the picture.
    pub fn guides(self: *const View) @import("../techniques/upscaling.zig").Guides {
        return .{ .diffuse_albedo = self.raw_scatter.?, .specular_albedo = self.raw_reflect.?, .normal_roughness = self.raw_normal.? };
    }
};

pub fn preset(quality: api.Quality) ?Settings {
    _ = quality;
    return null;
}

pub fn resolve(setting: *?Settings, r: *features.Resolve) void {
    if (!r.scene) setting.* = null;
    if (setting.* != null and r.path_tracing == .unavailable) {
        setting.* = null;
        r.downgrade("path_tracing", "on", "off", .no_ray_tracing);
    }
    if (setting.* != null and r.orthographic) {
        setting.* = null;
        r.downgrade("path_tracing", "on", "off", .unsupported);
    }
    const s = &(setting.* orelse return);
    if (s.denoiser == .ray_reconstruction) {
        const reason: ?api.DowngradeReason = if (r.upscaler != .dlss or r.debugging or !r.upscalers.dlss_ray_reconstruction)
            .unavailable
        else if (!r.temporal_antialiasing)
            .needs_temporal_antialiasing
        else
            null;
        if (reason) |why| {
            r.downgrade("path_tracing.denoiser", "ray_reconstruction", "builtin", why);
            s.denoiser = .builtin;
        }
    }
}

/// Adds the tracer. On a view it has taken over it runs in place of the
/// lit surfaces; until then it runs last and only finds out whether it can.
pub fn declare(ctx: *ViewContext) !void {
    const p = ctx.scene orelse return;
    try ctx.graph.add(.{ .name = "path tracing", .stage = if (p.tracing) .surfaces else .after_transparency, .always = true, .scope = false }, ctx, trace);
}

fn trace(ctx: *ViewContext) !void {
    const p = ctx.scene.?;
    p.shared.path_traced = try pathTrace(ctx.renderer, p, try ctx.state(@This()));
}

/// Step size in pixels of each pathtrace_denoise.frag pass; the short last one
/// removes the grid a wide step leaves.
const denoise_steps = [_]i32{ 1, 2, 4, 8, 3 };

/// Push constants of pathtrace_denoise.frag.
const DenoisePush = extern struct {
    frame: u64,
    color: u32,
    guide: u32,
    step_size: i32,
    gathered: u32,
    mode: enum(u32) { first = 0, last = 1, none = 2, between = 3 },
    steady: u32,
    facing: u32,
    gloss: u32,
    gloss_gathered: u32,
    lamp: u32,
};

/// Frames after the camera stops before the accumulated image is antialiased by
/// itself, and frames over which TAA then fades out.
pub const frames_to_settle = 8;

pub const frames_to_hand_over = 16;

/// Most frames a pixel keeps while the camera moves, and while lights or
/// objects change, when what it kept may no longer be how it is lit.
const moving_history = 64;

const changed_history = 16;

const changed_lamp_history = 4;

const still_history = 8192;

/// `history_clip_weight` in ffx_reflections_resolve.frag; AMD's default.
const reflection_stability = 0.7;

/// Recreates a view's path tracing targets at this size and resets
/// accumulation. History targets start cleared.
fn makeTargets(device: *rhi.Device, cmd: *rhi.CommandEncoder, state: *View, width: u32, height: u32) !void {
    const targets = [_]struct { slot: *?rhi.Texture, name: [:0]const u8, format: rhi.Format, divide: u32 = 1 }{
        .{ .slot = &state.raw_color, .name = "path tracing: traced", .format = .rgba32_float },
        .{ .slot = &state.raw_guide, .name = "path tracing: traced color", .format = .rgba16_float },
        .{ .slot = &state.raw_soft, .name = "path tracing: traced bounce light", .format = .rgba32_float },
        .{ .slot = &state.raw_facing, .name = "path tracing: traced facing", .format = .rgba16_float },
        .{ .slot = &state.raw_lamp, .name = "path tracing: traced lamp light", .format = .rgba16_float },
        .{ .slot = &state.raw_gloss, .name = "path tracing: traced reflections", .format = .rgba32_float },
        .{ .slot = &state.raw_surface, .name = "path tracing: traced surface", .format = .rgba16_float },
        .{ .slot = &state.accum, .name = "path tracing", .format = .rgba32_float },
        .{ .slot = &state.accum_old, .name = "path tracing (last frame)", .format = .rgba32_float },
        .{ .slot = &state.guide, .name = "path tracing guide", .format = .rgba16_float },
        .{ .slot = &state.guide_old, .name = "path tracing guide (last frame)", .format = .rgba16_float },
        .{ .slot = &state.soft, .name = "path tracing grainy light", .format = .rgba32_float },
        .{ .slot = &state.soft_old, .name = "path tracing grainy light (last frame)", .format = .rgba32_float },
        .{ .slot = &state.filtered, .name = "path tracing filtered", .format = .rgba16_float },
        .{ .slot = &state.filtered_other, .name = "path tracing filtered (other)", .format = .rgba16_float },
        .{ .slot = &state.facing, .name = "path tracing facing", .format = .rgba16_float },
        .{ .slot = &state.facing_old, .name = "path tracing facing (last frame)", .format = .rgba16_float },
        .{ .slot = &state.surface, .name = "path tracing surface", .format = .rgba16_float },
        .{ .slot = &state.surface_old, .name = "path tracing surface (last frame)", .format = .rgba16_float },
        .{ .slot = &state.reservoir, .name = "path tracing light samples", .format = .rgba32_float },
        .{ .slot = &state.reservoir_old, .name = "path tracing light samples (last frame)", .format = .rgba32_float },
        .{ .slot = &state.lamp, .name = "path tracing lamp light", .format = .rgba16_float },
        .{ .slot = &state.lamp_old, .name = "path tracing lamp light (last frame)", .format = .rgba16_float },
        .{ .slot = &state.gloss_gathered, .name = "path tracing reflections gathered", .format = .rgba32_float },
        .{ .slot = &state.gloss_gathered_old, .name = "path tracing reflections gathered (last frame)", .format = .rgba32_float },
        .{ .slot = &state.reflection_reprojected, .name = "reflection denoise: reprojected", .format = .rgba16_float },
        .{ .slot = &state.reflection_samples, .name = "reflection denoise: samples", .format = .r16_float },
        .{ .slot = &state.reflection_samples_old, .name = "reflection denoise: samples (last frame)", .format = .r16_float },
        .{ .slot = &state.reflection_average, .name = "reflection denoise: average", .format = .rgba16_float, .divide = 8 },
        .{ .slot = &state.reflection_prefiltered, .name = "reflection denoise: prefiltered", .format = .rgba16_float },
        .{ .slot = &state.reflection_resolved, .name = "reflection denoise: resolved", .format = .rgba16_float },
        .{ .slot = &state.reflection_resolved_old, .name = "reflection denoise: resolved (last frame)", .format = .rgba16_float },
    };
    for (targets) |target| {
        if (target.slot.*) |old| device.destroyTexture(old);
        target.slot.* = null;
    }
    for ([_]*?rhi.Texture{ &state.raw_scatter, &state.raw_reflect, &state.raw_normal }) |slot| {
        if (slot.*) |old| device.destroyTexture(old);
        slot.* = null;
    }
    for (targets) |target| {
        const made = try device.createTexture(.{
            .name = target.name,
            .width = (width + target.divide - 1) / target.divide,
            .height = (height + target.divide - 1) / target.divide,
            .format = target.format,
            .usage = .{ .sampled = true, .color_attachment = true, .storage = device.caps.storage_images },
        });
        target.slot.* = made;
        try cmd.beginRendering(.{ .color = &.{.{ .texture = made, .load = .clear }} });
        cmd.endRendering();
        cmd.transition(made, .shader_read);
    }
    state.size = .{ width, height };
    state.gathered = 0;
    state.reusable = false;
}

/// Makes the targets only a denoising upscaler reads, the first time one is
/// used at this size.
fn makeGuides(device: *rhi.Device, state: *View) !void {
    const guides = [_]struct { slot: *?rhi.Texture, name: [:0]const u8 }{
        .{ .slot = &state.raw_scatter, .name = "path tracing: scattered color" },
        .{ .slot = &state.raw_reflect, .name = "path tracing: reflected color" },
        .{ .slot = &state.raw_normal, .name = "path tracing: normal and roughness" },
    };
    for (guides) |guide| {
        if (guide.slot.* != null) continue;
        guide.slot.* = try device.createTexture(.{
            .name = guide.name,
            .width = state.size[0],
            .height = state.size[1],
            .format = .rgba16_float,
            .usage = .{ .sampled = true, .storage = true },
        });
    }
}

/// Runs the reflection denoiser (ffx_reflections.glsl) and returns its result,
/// which is also next frame's history.
fn denoiseReflections(renderer: *Renderer, p: *const ScenePass, state: *View, gloss: rhi.Texture, reach: rhi.Texture, surface: rhi.Texture) !rhi.Texture {
    const device = renderer.device;
    const cmd = p.cmd;
    std.mem.swap(?rhi.Texture, &state.reflection_samples, &state.reflection_samples_old);
    std.mem.swap(?rhi.Texture, &state.reflection_resolved, &state.reflection_resolved_old);
    const reprojected = state.reflection_reprojected.?;
    const samples = state.reflection_samples.?;
    const average = state.reflection_average.?;
    const prefiltered = state.reflection_prefiltered.?;
    const resolved = state.reflection_resolved.?;
    cmd.beginScope("reflection denoise");
    defer cmd.endScope();

    try cmd.beginRendering(.{ .color = &.{ .{ .texture = reprojected, .load = .discard }, .{ .texture = samples, .load = .discard } } });
    cmd.bindPipeline(try renderer.pipelines.get(.reflection_reproject));
    cmd.pushConstants(extern struct { frame: u64, radiance: u32, surface: u32, surface_history: u32, motion: u32, history: u32, samples_history: u32, reach: u32 }{
        .frame = p.frame_address,
        .radiance = device.textureIndex(gloss),
        .surface = device.textureIndex(surface),
        .surface_history = device.textureIndex(state.surface_old.?),
        .motion = device.textureIndex(p.view.motion),
        .history = device.textureIndex(state.reflection_resolved_old.?),
        .samples_history = device.textureIndex(state.reflection_samples_old.?),
        .reach = device.textureIndex(reach),
    });
    cmd.drawFullscreen();
    cmd.endRendering();
    cmd.transition(reprojected, .shader_read);
    cmd.transition(samples, .shader_read);

    try cmd.beginRendering(.{ .color = &.{.{ .texture = average, .load = .discard }} });
    cmd.bindPipeline(try renderer.pipelines.get(.reflection_average));
    cmd.pushConstants(extern struct { frame: u64, radiance: u32, reprojected: u32, samples: u32, pad: u32 = 0 }{
        .frame = p.frame_address,
        .radiance = device.textureIndex(gloss),
        .reprojected = device.textureIndex(reprojected),
        .samples = device.textureIndex(samples),
    });
    cmd.drawFullscreen();
    cmd.endRendering();
    cmd.transition(average, .shader_read);

    try cmd.beginRendering(.{ .color = &.{.{ .texture = prefiltered, .load = .discard }} });
    cmd.bindPipeline(try renderer.pipelines.get(.reflection_prefilter));
    cmd.pushConstants(extern struct { frame: u64, radiance: u32, reprojected: u32, surface: u32, average: u32 }{
        .frame = p.frame_address,
        .radiance = device.textureIndex(gloss),
        .reprojected = device.textureIndex(reprojected),
        .surface = device.textureIndex(surface),
        .average = device.textureIndex(average),
    });
    cmd.drawFullscreen();
    cmd.endRendering();
    cmd.transition(prefiltered, .shader_read);

    try cmd.beginRendering(.{ .color = &.{.{ .texture = resolved, .load = .discard }} });
    cmd.bindPipeline(try renderer.pipelines.get(.reflection_resolve));
    cmd.pushConstants(extern struct { frame: u64, prefiltered: u32, reprojected: u32, samples: u32, surface: u32, average: u32, history_clip_weight: f32 }{
        .frame = p.frame_address,
        .prefiltered = device.textureIndex(prefiltered),
        .reprojected = device.textureIndex(reprojected),
        .samples = device.textureIndex(samples),
        .surface = device.textureIndex(surface),
        .average = device.textureIndex(average),
        .history_clip_weight = reflection_stability,
    });
    cmd.drawFullscreen();
    cmd.endRendering();
    cmd.transition(resolved, .shader_read);
    return resolved;
}

/// What the tracer hands whatever removes its noise: one frame's paths, at
/// render size, with nothing carried over from earlier frames. Depth and
/// motion vectors come with the view.
pub const Signals = struct {
    /// Light that needs no filtering, as it reaches the eye. Alpha is 1
    /// where the first surface is a mirror.
    direct: rhi.Texture,
    /// Color of the surface seen, through mirrors, with how far its
    /// reflections reach in alpha.
    albedo: rhi.Texture,
    /// Bounced light on that surface, over its color.
    diffuse: rhi.Texture,
    /// Its normal, and its distance in alpha, negative through a mirror.
    facing: rhi.Texture,
    /// Lamp and glow light on it, over its color.
    lamp: rhi.Texture,
    /// Glossy reflections in it.
    specular: rhi.Texture,
    /// Normal, roughness and distance of the first surface on the ray.
    surface: rhi.Texture,
};

/// `Signals` gathered over frames by the built-in denoiser.
const Gathered = struct {
    /// Light that needs no filtering, with the frames gathered in alpha.
    steady: rhi.Texture,
    /// Bounced light, still grainy, with its squared brightness in alpha.
    noisy: rhi.Texture,
    albedo: rhi.Texture,
    facing: rhi.Texture,
    surface: rhi.Texture,
    lamp: rhi.Texture,
    /// Glossy reflections, with the frames gathered in alpha.
    gloss: rhi.Texture,
};

/// How much of what was gathered a frame may keep.
const Keeping = struct {
    moved: bool,
    reset: bool,
    previous_eye: [3]f32,
    history_limit: f32,
    lamp_limit: f32,
};

/// The built-in denoiser's first step: blends this frame's signals into
/// what the view has gathered, following each surface to where it was last
/// frame, and starts over where a pixel shows something new.
fn gather(renderer: *Renderer, p: *const ScenePass, state: *View, signals: Signals, keeping: Keeping) !Gathered {
    const device = renderer.device;
    const cmd = p.cmd;
    const gathered = Gathered{ .steady = state.accum.?, .noisy = state.soft.?, .albedo = state.guide.?, .facing = state.facing.?, .surface = state.surface.?, .lamp = state.lamp.?, .gloss = state.gloss_gathered.? };
    const targets = [_]rhi.Texture{ gathered.steady, gathered.albedo, gathered.noisy, gathered.facing, gathered.lamp, gathered.gloss, gathered.surface };
    var attachments: [targets.len]rhi.ColorAttachment = undefined;
    for (targets, &attachments) |target, *attachment| attachment.* = .{ .texture = target, .load = .discard };
    cmd.beginScope("path tracing gather");
    defer cmd.endScope();
    try cmd.beginRendering(.{ .color = &attachments });
    cmd.bindPipeline(try renderer.pipelines.get(.path_gather));
    cmd.pushConstants(extern struct {
        frame: u64,
        color: u32,
        guide: u32,
        soft: u32,
        facing: u32,
        lamp: u32,
        gloss: u32,
        surface: u32,
        history_color: u32,
        history_guide: u32,
        history_soft: u32,
        history_facing: u32,
        history_lamp: u32,
        history_gloss: u32,
        history_surface: u32,
        motion: u32,
        depth: u32,
        moved: u32,
        reset: u32,
        history_limit: f32,
        lamp_limit: f32,
        previous_camera: [3]f32,
        pad: f32 = 0,
    }{
        .frame = p.frame_address,
        .color = device.textureIndex(signals.direct),
        .guide = device.textureIndex(signals.albedo),
        .soft = device.textureIndex(signals.diffuse),
        .facing = device.textureIndex(signals.facing),
        .lamp = device.textureIndex(signals.lamp),
        .gloss = device.textureIndex(signals.specular),
        .surface = device.textureIndex(signals.surface),
        .history_color = device.textureIndex(state.accum_old.?),
        .history_guide = device.textureIndex(state.guide_old.?),
        .history_soft = device.textureIndex(state.soft_old.?),
        .history_facing = device.textureIndex(state.facing_old.?),
        .history_lamp = device.textureIndex(state.lamp_old.?),
        .history_gloss = device.textureIndex(state.gloss_gathered_old.?),
        .history_surface = device.textureIndex(state.surface_old.?),
        .motion = device.textureIndex(p.view.motion),
        .depth = device.textureIndex(p.view.depth),
        .moved = @intFromBool(keeping.moved),
        .reset = @intFromBool(keeping.reset),
        .history_limit = keeping.history_limit,
        .lamp_limit = keeping.lamp_limit,
        .previous_camera = keeping.previous_eye,
    });
    cmd.drawFullscreen();
    cmd.endRendering();
    for (targets) |target| cmd.transition(target, .shader_read);
    return gathered;
}

/// Puts the traced picture together in the scene color, with the built-in
/// denoiser when `smooth`: the reflection denoiser on the glossy part and
/// an edge-stopping blur in widening steps on the rest.
fn compose(renderer: *Renderer, p: *const ScenePass, state: *View, signals: Gathered, smooth: bool) !void {
    const device = renderer.device;
    const cmd = p.cmd;
    cmd.beginScope("path tracing denoise");
    defer cmd.endScope();
    var denoise = DenoisePush{
        .frame = p.frame_address,
        .color = device.textureIndex(signals.noisy),
        .guide = device.textureIndex(signals.albedo),
        .step_size = 1,
        .gathered = state.gathered,
        .mode = .none,
        .steady = device.textureIndex(signals.steady),
        .facing = device.textureIndex(signals.facing),
        .gloss = device.textureIndex(signals.gloss),
        .gloss_gathered = device.textureIndex(signals.gloss),
        .lamp = device.textureIndex(signals.lamp),
    };
    if (smooth) {
        denoise.gloss = device.textureIndex(try denoiseReflections(renderer, p, state, signals.gloss, signals.albedo, signals.surface));
        const between = [2]rhi.Texture{ state.filtered.?, state.filtered_other.? };
        for (denoise_steps[0 .. denoise_steps.len - 1], 0..) |step, run| {
            const smoothed = between[run % 2];
            denoise.step_size = step;
            denoise.mode = if (run == 0) .first else .between;
            try cmd.beginRendering(.{ .color = &.{.{ .texture = smoothed, .load = .discard }} });
            cmd.bindPipeline(try renderer.pipelines.get(.path_denoise));
            cmd.pushConstants(denoise);
            cmd.drawFullscreen();
            cmd.endRendering();
            cmd.transition(smoothed, .shader_read);
            denoise.color = device.textureIndex(smoothed);
        }
        denoise.step_size = denoise_steps[denoise_steps.len - 1];
        denoise.mode = .last;
    }
    try cmd.beginRendering(.{ .color = &.{.{ .texture = p.view.hdr, .load = .discard }} });
    cmd.bindPipeline(try renderer.pipelines.get(.path_denoise_final));
    cmd.pushConstants(denoise);
    cmd.drawFullscreen();
    cmd.endRendering();
    cmd.transition(p.view.hdr, .shader_read);
}

/// Puts the picture as traced this frame in the scene color for a denoising
/// upscaler, so that what is drawn after this pass is in what it is given.
fn handOver(renderer: *Renderer, p: *const ScenePass, signals: Signals) !void {
    const device = renderer.device;
    const cmd = p.cmd;
    try cmd.beginRendering(.{ .color = &.{.{ .texture = p.view.hdr, .load = .discard }} });
    cmd.bindPipeline(try renderer.pipelines.get(.path_denoise_final));
    cmd.pushConstants(DenoisePush{
        .frame = p.frame_address,
        .color = device.textureIndex(signals.diffuse),
        .guide = device.textureIndex(signals.albedo),
        .step_size = 1,
        .gathered = 0,
        .mode = .none,
        .steady = device.textureIndex(signals.direct),
        .facing = device.textureIndex(signals.facing),
        .gloss = device.textureIndex(signals.specular),
        .gloss_gathered = device.textureIndex(signals.specular),
        .lamp = device.textureIndex(signals.lamp),
    });
    cmd.drawFullscreen();
    cmd.endRendering();
    cmd.transition(p.view.hdr, .shader_read);
}

/// Path traces the view if requested and the scene is ready; returns whether it
/// did.
pub fn pathTrace(renderer: *Renderer, p: *const ScenePass, state: *View) !bool {
    const device = renderer.device;
    const cmd = p.cmd;
    const desc = p.desc;
    const settings = p.settings;
    const scene = p.scene;
    const scene_frame = p.scene_frame;
    const view = p.view;
    const width = p.width;
    const height = p.height;
    const debugging = p.debugging;
    const frame_address = p.frame_address;
    var path_traced = false;
    if ((settings.path_tracing != null) and !debugging) trace: {
        scene.trace_wanted = true;
        var where: u64 = 0;
        var instances_address: u64 = 0;
        var content: u64 = 0;
        if (device.caps.ray_tracing) {
            const tlas = scene.tlas orelse break :trace;
            if (scene.tlas_hash == 0 or scene.tlas_hash != scene_frame.tlas_hash) break :trace;
            where = device.accelerationAddress(tlas);
            content = scene.tlas_hash;
        } else {
            if (!scene.trace_ready) break :trace;
            where = device.bufferAddress(scene.trace_nodes.?);
            instances_address = device.bufferAddress(scene.trace_instances.?);
            content = scene.trace_hash;
        }
        if (state.accum == null or state.size[0] != width or state.size[1] != height) {
            try makeTargets(device, cmd, state, width, height);
        }
        // What moves without changing the lighting much: the things in the scene
        // and the sun. Treated like a moving camera, which keeps more history
        // than a change of lamps does.
        var motion = std.hash.Wyhash.init(content);
        motion.update(std.mem.asBytes(&scene.sun.direction));
        motion.update(std.mem.asBytes(&scene.sun.color));
        motion.update(std.mem.asBytes(&scene.sun.intensity));
        const motion_key = motion.final();
        var key = std.hash.Wyhash.init(0);
        key.update(std.mem.asBytes(&scene.environment_intensity));
        for (scene.lights.items) |light| {
            key.update(std.mem.asBytes(&light.position));
            key.update(std.mem.asBytes(&light.direction));
            key.update(std.mem.asBytes(&light.color));
            key.update(std.mem.asBytes(&light.intensity));
            key.update(std.mem.asBytes(&light.range));
            key.update(std.mem.asBytes(&light.inner_angle));
            key.update(std.mem.asBytes(&light.outer_angle));
            key.update(std.mem.asBytes(&light.source_radius));
            key.update(&.{@intFromEnum(light.kind)});
        }
        key.update(std.mem.asBytes(&filled(settings.path_tracing).bounces));
        key.update(std.mem.asBytes(&filled(settings.path_tracing).clamp));
        key.update(std.mem.asBytes(&filled(settings.path_tracing).probes));
        const path_key = key.final();
        const reconstructing = filled(settings.path_tracing).denoiser == .ray_reconstruction and try resolution_feature.upscalerFor(renderer, p, .dlss_ray_reconstruction) != null;
        if (reconstructing != state.reconstructing) state.gathered = 0;
        state.reconstructing = reconstructing;
        const changed = path_key != state.key;
        state.key = path_key;
        if (changed) state.gathered = @min(state.gathered, changed_history);
        const shifted = motion_key != state.motion_key;
        state.motion_key = motion_key;
        const moved = !std.meta.eql(state.camera, desc.camera) or changed or shifted;
        const previous_eye = state.camera.position;
        state.camera = desc.camera;
        state.still = if (moved or state.gathered == 0) 0 else state.still +| 1;
        std.mem.swap(?rhi.Texture, &state.accum, &state.accum_old);
        std.mem.swap(?rhi.Texture, &state.guide, &state.guide_old);
        std.mem.swap(?rhi.Texture, &state.soft, &state.soft_old);
        std.mem.swap(?rhi.Texture, &state.facing, &state.facing_old);
        std.mem.swap(?rhi.Texture, &state.surface, &state.surface_old);
        std.mem.swap(?rhi.Texture, &state.gloss_gathered, &state.gloss_gathered_old);
        std.mem.swap(?rhi.Texture, &state.reservoir, &state.reservoir_old);
        std.mem.swap(?rhi.Texture, &state.lamp, &state.lamp_old);
        const reservoir = state.reservoir.?;
        const signals = Signals{
            .direct = state.raw_color.?,
            .albedo = state.raw_guide.?,
            .diffuse = state.raw_soft.?,
            .facing = state.raw_facing.?,
            .lamp = state.raw_lamp.?,
            .specular = state.raw_gloss.?,
            .surface = state.raw_surface.?,
        };
        cmd.beginScope("path tracing");
        const traced = [8]rhi.Texture{ signals.direct, signals.albedo, signals.diffuse, signals.facing, signals.lamp, signals.specular, signals.surface, reservoir };
        const in_compute = device.caps.storage_images;
        const guided = reconstructing and in_compute;
        if (guided) try makeGuides(device, state);
        const beside: []const rhi.Texture = if (guided) &.{ state.raw_scatter.?, state.raw_reflect.?, state.raw_normal.? } else &.{};
        var targets_address: u64 = 0;
        if (in_compute) {
            const targets = try p.arena.alloc(device, u32, traced.len + beside.len);
            for (traced, targets.items[0..traced.len]) |output, *slot| {
                cmd.transition(output, .storage);
                slot.* = try device.storageIndex(output, 0, 0);
            }
            for (beside, targets.items[traced.len..]) |output, *slot| {
                cmd.transition(output, .storage);
                slot.* = try device.storageIndex(output, 0, 0);
            }
            targets_address = targets.address;
        } else {
            var attachments: [traced.len]rhi.ColorAttachment = undefined;
            for (traced, &attachments) |output, *attachment| attachment.* = .{ .texture = output, .load = .discard };
            try cmd.beginRendering(.{ .color = &attachments });
        }
        cmd.bindPipeline(try renderer.pipelines.get(switch (filled(settings.path_tracing).direct) {
            .ris => if (in_compute) .path_trace_compute else .path_trace,
        }));
        cmd.pushConstants(extern struct {
            frame: u64,
            scene: u64,
            scene_instances: u64,
            mesh_nodes: u64,
            mesh_items: u64,
            gathered: u32,
            bounces: u32,
            samples: u32,
            clamp_radiance: f32,
            sun_radius: f32,
            light_count: u32,
            glowing: u64,
            glowing_count: u32,
            moved: u32,
            previous_camera: [3]f32,
            centered: u32,
            history_facing: u32,
            history_reservoir: u32,
            reusable: u32,
            motion: u32,
            depth: u32,
            probes: u32,
            reconstructed: u32,
            pad: u32 = 0,
            targets: u64,
        }{
            .frame = frame_address,
            .scene = where,
            .scene_instances = instances_address,
            .mesh_nodes = device.bufferAddress(renderer.bvh_nodes.get()),
            .mesh_items = device.bufferAddress(renderer.bvh_items.get()),
            .gathered = state.gathered,
            .bounces = std.math.clamp(filled(settings.path_tracing).bounces, 1, 16),
            .samples = std.math.clamp(filled(settings.path_tracing).samples, 1, 64),
            .clamp_radiance = @max(filled(settings.path_tracing).clamp, 0.01),
            .sun_radius = 0.0047,
            .light_count = 256,
            .glowing = scene_frame.glowing,
            .glowing_count = scene_frame.glowing_count,
            .moved = @intFromBool(moved),
            .previous_camera = previous_eye,
            .centered = @intFromBool(settings.resolution.temporal_antialiasing),
            .history_facing = device.textureIndex(state.facing_old.?),
            .history_reservoir = device.textureIndex(state.reservoir_old.?),
            .reusable = @intFromBool(state.reusable),
            .motion = device.textureIndex(view.motion),
            .depth = device.textureIndex(view.depth),
            .probes = @intFromBool(filled(settings.path_tracing).probes),
            .reconstructed = @intFromBool(guided),
            .targets = targets_address,
        });
        if (in_compute) {
            cmd.dispatch((width + 7) / 8, (height + 7) / 8, 1);
        } else {
            cmd.drawFullscreen();
            cmd.endRendering();
        }
        for (traced) |output| cmd.transition(output, .shader_read);
        for (beside) |output| cmd.transition(output, .shader_read);
        cmd.endScope();

        const gathered = try gather(renderer, p, state, signals, .{
            .moved = moved,
            .reset = state.gathered == 0,
            .previous_eye = previous_eye,
            .history_limit = if (changed) changed_history else moving_history,
            .lamp_limit = if (changed) changed_lamp_history else if (moved) moving_history else still_history,
        });
        const denoiser: ?api.Denoiser = if (reconstructing) .ray_reconstruction else filled(settings.path_tracing).denoiser;
        switch (denoiser orelse .builtin) {
            .builtin => try compose(renderer, p, state, gathered, denoiser != null),
            .ray_reconstruction => try handOver(renderer, p, signals),
        }
        state.gathered = @min(state.gathered + 1, still_history);
        state.reusable = true;
        renderer.stats.path_traced_frames = state.gathered;
        renderer.stats.path_tracing_hardware = device.caps.ray_tracing;
        path_traced = true;
    }
    if ((settings.path_tracing != null) and !debugging and !path_traced) renderer.path_trace_misses +%= 1;
    return path_traced;
}
