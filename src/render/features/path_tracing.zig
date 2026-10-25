//! Path tracing in place of rasterized lighting.
const pipelines_module = @import("../renderer/pipelines.zig");
const pathtrace_push = @import("../shaders/push/pathtrace.zig");
const pathtrace_denoise_push = @import("../shaders/push/pathtrace_denoise.zig");
const ffx_reflections_push = @import("../shaders/push/ffx_reflections.zig");
const render = @import("../renderer.zig");
const scene_pass = @import("../scene_pass.zig");
const resolution_feature = @import("resolution.zig");
const filled = @import("../api.zig").filled;
const std = @import("std");
const nrd = @import("../nrd.zig");
const denoising = @import("../techniques/denoising.zig");
const math = @import("../../math.zig");
const rhi = @import("../../rhi/rhi.zig");
const api = @import("../api.zig");
const features = @import("../core/features.zig");
const targets_module = @import("../core/targets.zig");

const ScenePass = scene_pass.ScenePass;
const Renderer = render.Renderer;
const ViewContext = features.ViewContext;
const History = targets_module.History;
const Guides = @import("../techniques/upscaling.zig").Guides;

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
    /// How lamp and glow light is sampled at each surface. At most 1024
    /// glowing instances are sampled directly; others are found by rays only.
    direct: api.DirectSampling = .ris,
    /// What removes the noise; null only gathers over frames. `.builtin`
    /// averages indirect light over neighbouring pixels of the same surface
    /// while a pixel still varies between frames. `.ray_reconstruction` is
    /// DLSS, which needs `Settings.resolution.upscaler` to be `.dlss`, else
    /// `.builtin` stands in. `.nrd` is NVIDIA's ReLAX, for bounced light and
    /// reflections; where the build has no NRD, `.builtin` stands in.
    denoiser: ?api.Denoiser = .builtin,
    /// How `.nrd` is tuned.
    nrd: Nrd = .{},
};

/// See `Settings.path_tracing.nrd`.
pub const Nrd = struct {
    /// Most frames of history a pixel keeps, 1..255. More is smoother at
    /// rest and slower to follow what changes.
    history_frames: u32 = 30,
    /// Radius in pixels of a blur over the traced light before it is
    /// gathered; 0 for none. It hides noise where history is short, as
    /// behind something that moves, and softens contact shadows and color
    /// bleeding with it.
    blur_radius_pixels: f32 = 0,
};

/// What a view keeps for path tracing from frame to frame, besides its
/// targets, which are in the view's kept targets (see `Keep`).
pub const View = struct {
    /// The view was path traced last frame.
    traced: bool = false,
    /// What a denoising upscaler reads besides the picture, while the view
    /// is traced for one.
    guide_textures: ?Guides = null,
    /// NRD for this view and the camera it last saw.
    denoiser: denoising.Slot = .{},
    nrd_view: [16]f32 = math.identity,
    nrd_projection: [16]f32 = math.identity,
    nrd_frame: u32 = 0,
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
        self.denoiser.deinit(device);
        self.* = .{};
    }

    /// What a denoising upscaler reads besides the picture.
    pub fn guides(self: *const View) Guides {
        return self.guide_textures.?;
    }
};

/// Finds the view's path tracing targets in its kept targets, by name, at
/// this frame's size: made on first use and at a new size, freed once
/// path tracing stops asking for them. A history is continuous only when
/// it was drawn the frame before, so a gap, a cut or a new size starts
/// the gathering over.
const Keep = struct {
    kept: *targets_module.Kept,
    gpa: std.mem.Allocator,
    device: *rhi.Device,
    cmd: *rhi.CommandEncoder,
    frame: u64,
    width: u32,
    height: u32,

    fn of(renderer: *Renderer, p: *const ScenePass) Keep {
        return .{ .kept = &p.view_data.kept, .gpa = renderer.internal.gpa, .device = renderer.device, .cmd = p.cmd, .frame = renderer.internal.frame_index, .width = p.width, .height = p.height };
    }

    fn desc(keep: Keep, target_name: [:0]const u8, format: rhi.Format, divide: u32, usage: rhi.TextureUsage) rhi.TextureDesc {
        return .{ .name = target_name, .width = (keep.width + divide - 1) / divide, .height = (keep.height + divide - 1) / divide, .format = format, .usage = usage };
    }

    fn drawn(keep: Keep) rhi.TextureUsage {
        return .{ .sampled = true, .color_attachment = true, .storage = keep.device.caps.storage_images };
    }

    /// A target that starts cleared.
    fn one(keep: Keep, target_name: [:0]const u8, format: rhi.Format, divide: u32) !rhi.Texture {
        return keep.kept.singleCleared(keep.gpa, keep.device, keep.cmd, keep.desc(target_name, format, divide, keep.drawn()), keep.frame);
    }

    /// A target written whole before it is read, with `usage`.
    fn written(keep: Keep, target_name: [:0]const u8, format: rhi.Format, usage: rhi.TextureUsage) !rhi.Texture {
        return keep.kept.single(keep.gpa, keep.device, keep.desc(target_name, format, 1, usage), keep.frame);
    }

    /// This frame's picture and last frame's, both starting cleared.
    fn pair(keep: Keep, target_name: [:0]const u8, format: rhi.Format) !History {
        return keep.kept.historyCleared(keep.gpa, keep.device, keep.cmd, keep.desc(target_name, format, 1, keep.drawn()), keep.frame);
    }
};

/// What the tracer writes this frame, and what gathering keeps from frame
/// to frame.
const Targets = struct {
    signals: Signals,
    reservoir: History,
    accum: History,
    guide: History,
    soft: History,
    facing: History,
    surface: History,
    lamp: History,
    gloss: History,

    fn of(keep: Keep) !Targets {
        return .{
            .signals = .{
                .direct = try keep.one("path tracing: traced", .rgba32_float, 1),
                .albedo = try keep.one("path tracing: traced color", .rgba16_float, 1),
                .diffuse = try keep.one("path tracing: traced bounce light", .rgba32_float, 1),
                .facing = try keep.one("path tracing: traced facing", .rgba16_float, 1),
                .lamp = try keep.one("path tracing: traced lamp light", .rgba16_float, 1),
                .specular = try keep.one("path tracing: traced reflections", .rgba32_float, 1),
                .surface = try keep.one("path tracing: traced surface", .rgba16_float, 1),
            },
            .reservoir = try keep.pair("path tracing light samples", .rgba32_float),
            .accum = try keep.pair("path tracing", .rgba32_float),
            .guide = try keep.pair("path tracing guide", .rgba16_float),
            .soft = try keep.pair("path tracing grainy light", .rgba32_float),
            .facing = try keep.pair("path tracing facing", .rgba16_float),
            .surface = try keep.pair("path tracing surface", .rgba16_float),
            .lamp = try keep.pair("path tracing lamp light", .rgba16_float),
            .gloss = try keep.pair("path tracing reflections gathered", .rgba32_float),
        };
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
    r.rays = true;
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
    if (s.denoiser == .nrd and !r.nrd) {
        r.downgrade("path_tracing.denoiser", "nrd", "builtin", .unavailable);
        s.denoiser = .builtin;
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
    if (p.settings.path_tracing == null or p.debugging) {
        p.shared.path_traced = false;
        return;
    }
    p.shared.path_traced = try pathTrace(ctx.renderer, p, try ctx.state(@This()));
}

/// Step size in pixels of each pathtrace_denoise.slang pass; the short last one
/// removes the grid a wide step leaves.
const denoise_steps = [_]i32{ 1, 2, 4, 8, 3 };

const DenoisePush = pathtrace_denoise_push.DenoisePush;

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

/// `history_clip_weight` in ffx_reflections.slang; AMD's default.
const reflection_stability = 0.7;

/// The built-in denoiser's gathering, then NRD on the bounced light and the
/// reflections in place of the built-in filters. False where NRD will not
/// run, which is logged once and reported every frame.
fn denoiseWithNrd(renderer: *Renderer, p: *const ScenePass, keep: Keep, state: *View, signals: Signals, gathered: Gathered, reset: bool) !bool {
    const device = renderer.device;
    const cmd = p.cmd;
    const key = denoising.Key{ .size = state.size };
    const was_refused = state.denoiser.refuses(key);
    const running = try state.denoiser.ensure(device, key, device, denoising.Running.startNrd) orelse {
        if (!was_refused) std.log.warn("NRD would not start; the built-in denoiser stands in", .{});
        renderer.internal.downgrades.add(.{ .feature = "path_tracing.denoiser", .requested = "nrd", .used = "builtin", .reason = .unavailable });
        return false;
    };
    if (!state.denoiser.continues(renderer.internal.frame_index)) state.nrd_frame = 0;
    const packed_usage = rhi.TextureUsage{ .sampled = true, .color_attachment = true };
    const out_usage = rhi.TextureUsage{ .sampled = true, .storage = true };
    const normal = try keep.written("nrd: normal and roughness", .rgba16_float, packed_usage);
    const view_depth = try keep.written("nrd: view depth", .r32_float, packed_usage);
    const diffuse = try keep.written("nrd: bounced light", .rgba16_float, packed_usage);
    const specular = try keep.written("nrd: reflections", .rgba16_float, packed_usage);
    const diffuse_out = try keep.written("nrd: bounced light, denoised", .rgba16_float, out_usage);
    const specular_out = try keep.written("nrd: reflections, denoised", .rgba16_float, out_usage);
    const first = state.nrd_frame == 0;

    cmd.beginScope("nrd");
    defer cmd.endScope();
    const inputs = [_]rhi.Texture{ normal, view_depth, diffuse, specular };
    var attachments: [inputs.len]rhi.ColorAttachment = undefined;
    for (inputs, &attachments) |target, *attachment| attachment.* = .{ .texture = target, .load = .discard };
    try cmd.beginRendering(.{ .color = &attachments });
    cmd.bindPipeline(try renderer.internal.pipelines.of(nrdPackPipeline));
    cmd.pushConstants(pathtrace_denoise_push.NrdPackPush{
        .frame = p.frame_address,
        .surface = device.textureIndex(signals.surface),
        .diffuse = device.textureIndex(signals.diffuse),
        .specular = device.textureIndex(signals.specular),
        .albedo = device.textureIndex(signals.albedo),
        .depth = device.textureIndex(p.view.depth),
    });
    cmd.drawFullscreen();
    cmd.endRendering();
    cmd.transition(diffuse_out, .storage);
    cmd.transition(specular_out, .storage);

    var projection = p.proj_unjittered;
    projection[5] = -projection[5];
    projection[9] = -projection[9];
    projection[13] = -projection[13];
    const before_view = if (first) p.view_matrix else state.nrd_view;
    const before_projection = if (first) projection else state.nrd_projection;
    state.nrd_view = p.view_matrix;
    state.nrd_projection = projection;
    state.nrd_frame +%= 1;
    running.nrd.dispatch(device, cmd, .{
        .motion = p.view.motion,
        .normal_roughness = normal,
        .view_depth = view_depth,
        .diffuse = diffuse,
        .specular = specular,
        .diffuse_out = diffuse_out,
        .specular_out = specular_out,
        .view_to_clip = projection,
        .view_to_clip_previous = before_projection,
        .world_to_view = p.view_matrix,
        .world_to_view_previous = before_view,
        .jitter = .{ 0, 0 },
        .jitter_previous = .{ 0, 0 },
        .delta_time = p.delta_time,
        .frame_index = state.nrd_frame,
        .reset = reset or first,
        .history_frames = filled(p.settings.path_tracing).nrd.history_frames,
        .blur_radius = filled(p.settings.path_tracing).nrd.blur_radius_pixels,
    }) catch {
        state.denoiser.refuse();
        std.log.warn("NRD failed; the built-in denoiser stands in", .{});
        renderer.internal.downgrades.add(.{ .feature = "path_tracing.denoiser", .requested = "nrd", .used = "builtin", .reason = .unavailable });
        cmd.transition(diffuse_out, .shader_read);
        cmd.transition(specular_out, .shader_read);
        return false;
    };
    cmd.transition(diffuse_out, .shader_read);
    cmd.transition(specular_out, .shader_read);

    try cmd.beginRendering(.{ .color = &.{.{ .texture = p.view.hdr, .load = .discard }} });
    cmd.bindPipeline(try renderer.internal.pipelines.of(nrdComposePipeline));
    cmd.pushConstants(pathtrace_denoise_push.NrdComposePush{
        .frame = p.frame_address,
        .steady_texture = device.textureIndex(gathered.steady),
        .albedo_texture = device.textureIndex(gathered.albedo),
        .lamp_texture = device.textureIndex(gathered.lamp),
        .diffuse_texture = device.textureIndex(diffuse_out),
        .specular_texture = device.textureIndex(specular_out),
        .depth_texture = device.textureIndex(view_depth),
    });
    cmd.drawFullscreen();
    cmd.endRendering();
    return true;
}

/// The targets only a denoising upscaler reads, written whole by the tracer.
fn makeGuides(keep: Keep) !Guides {
    const usage = rhi.TextureUsage{ .sampled = true, .storage = true };
    return .{
        .diffuse_albedo = try keep.written("path tracing: scattered color", .rgba16_float, usage),
        .specular_albedo = try keep.written("path tracing: reflected color", .rgba16_float, usage),
        .normal_roughness = try keep.written("path tracing: normal and roughness", .rgba16_float, usage),
    };
}

/// Runs the reflection denoiser (ffx_reflections.slang) and returns its result,
/// which is also next frame's history.
fn denoiseReflections(renderer: *Renderer, p: *const ScenePass, keep: Keep, gloss: rhi.Texture, reach: rhi.Texture, surface: rhi.Texture, surface_history: rhi.Texture) !rhi.Texture {
    const device = renderer.device;
    const cmd = p.cmd;
    const samples_pair = try keep.pair("reflection denoise: samples", .r16_float);
    const resolved_pair = try keep.pair("reflection denoise: resolved", .rgba16_float);
    const reprojected = try keep.one("reflection denoise: reprojected", .rgba16_float, 1);
    const samples = samples_pair.current;
    const average = try keep.one("reflection denoise: average", .rgba16_float, 8);
    const prefiltered = try keep.one("reflection denoise: prefiltered", .rgba16_float, 1);
    const resolved = resolved_pair.current;
    cmd.beginScope("reflection denoise");
    defer cmd.endScope();

    try cmd.beginRendering(.{ .color = &.{ .{ .texture = reprojected, .load = .discard }, .{ .texture = samples, .load = .discard } } });
    cmd.bindPipeline(try renderer.internal.pipelines.of(reflectionReprojectPipeline));
    cmd.pushConstants(ffx_reflections_push.ReprojectPush{
        .frame = p.frame_address,
        .radiance_texture = device.textureIndex(gloss),
        .surface_texture = device.textureIndex(surface),
        .surface_history_texture = device.textureIndex(surface_history),
        .motion_texture = device.textureIndex(p.view.motion),
        .history_texture = device.textureIndex(resolved_pair.last),
        .samples_history_texture = device.textureIndex(samples_pair.last),
        .reach_texture = device.textureIndex(reach),
    });
    cmd.drawFullscreen();
    cmd.endRendering();

    try cmd.beginRendering(.{ .color = &.{.{ .texture = average, .load = .discard }} });
    cmd.bindPipeline(try renderer.internal.pipelines.of(reflectionAveragePipeline));
    cmd.pushConstants(ffx_reflections_push.AveragePush{
        .frame = p.frame_address,
        .radiance_texture = device.textureIndex(gloss),
        .reprojected_texture = device.textureIndex(reprojected),
        .samples_texture = device.textureIndex(samples),
    });
    cmd.drawFullscreen();
    cmd.endRendering();

    try cmd.beginRendering(.{ .color = &.{.{ .texture = prefiltered, .load = .discard }} });
    cmd.bindPipeline(try renderer.internal.pipelines.of(reflectionPrefilterPipeline));
    cmd.pushConstants(ffx_reflections_push.PrefilterPush{
        .frame = p.frame_address,
        .radiance_texture = device.textureIndex(gloss),
        .reprojected_texture = device.textureIndex(reprojected),
        .surface_texture = device.textureIndex(surface),
        .average_texture = device.textureIndex(average),
    });
    cmd.drawFullscreen();
    cmd.endRendering();

    try cmd.beginRendering(.{ .color = &.{.{ .texture = resolved, .load = .discard }} });
    cmd.bindPipeline(try renderer.internal.pipelines.of(reflectionResolvePipeline));
    cmd.pushConstants(ffx_reflections_push.ResolvePush{
        .frame = p.frame_address,
        .prefiltered_texture = device.textureIndex(prefiltered),
        .reprojected_texture = device.textureIndex(reprojected),
        .samples_texture = device.textureIndex(samples),
        .surface_texture = device.textureIndex(surface),
        .average_texture = device.textureIndex(average),
        .history_clip_weight = reflection_stability,
    });
    cmd.drawFullscreen();
    cmd.endRendering();
    return resolved;
}

/// What the tracer hands whatever removes its noise: one frame's paths, at
/// render size, with nothing carried over from earlier frames. Depth and
/// motion vectors come with the view.
pub const Signals = struct {
    /// LightDesc that needs no filtering, as it reaches the eye. Alpha is 1
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
    /// LightDesc that needs no filtering, with the frames gathered in alpha.
    steady: rhi.Texture,
    /// Bounced light, still grainy, with its squared brightness in alpha.
    noisy: rhi.Texture,
    albedo: rhi.Texture,
    facing: rhi.Texture,
    surface: rhi.Texture,
    /// Last frame's `surface`.
    surface_history: rhi.Texture,
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
fn gather(renderer: *Renderer, p: *const ScenePass, targets: Targets, keeping: Keeping) !Gathered {
    const device = renderer.device;
    const cmd = p.cmd;
    const signals = targets.signals;
    const gathered = Gathered{ .steady = targets.accum.current, .noisy = targets.soft.current, .albedo = targets.guide.current, .facing = targets.facing.current, .surface = targets.surface.current, .surface_history = targets.surface.last, .lamp = targets.lamp.current, .gloss = targets.gloss.current };
    const outputs = [_]rhi.Texture{ gathered.steady, gathered.albedo, gathered.noisy, gathered.facing, gathered.lamp, gathered.gloss, gathered.surface };
    var attachments: [outputs.len]rhi.ColorAttachment = undefined;
    for (outputs, &attachments) |target, *attachment| attachment.* = .{ .texture = target, .load = .discard };
    cmd.beginScope("path tracing gather");
    defer cmd.endScope();
    try cmd.beginRendering(.{ .color = &attachments });
    cmd.bindPipeline(try renderer.internal.pipelines.of(pathGatherPipeline));
    cmd.pushConstants(pathtrace_denoise_push.GatherPush{
        .frame = p.frame_address,
        .color = device.textureIndex(signals.direct),
        .guide = device.textureIndex(signals.albedo),
        .soft = device.textureIndex(signals.diffuse),
        .facing = device.textureIndex(signals.facing),
        .lamp = device.textureIndex(signals.lamp),
        .gloss = device.textureIndex(signals.specular),
        .surface = device.textureIndex(signals.surface),
        .history_color = device.textureIndex(targets.accum.last),
        .history_guide = device.textureIndex(targets.guide.last),
        .history_soft = device.textureIndex(targets.soft.last),
        .history_facing = device.textureIndex(targets.facing.last),
        .history_lamp = device.textureIndex(targets.lamp.last),
        .history_gloss = device.textureIndex(targets.gloss.last),
        .history_surface = device.textureIndex(targets.surface.last),
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
    return gathered;
}

/// Puts the traced picture together in the scene color, with the built-in
/// denoiser when `smooth`: the reflection denoiser on the glossy part and
/// an edge-stopping blur in widening steps on the rest.
fn compose(renderer: *Renderer, p: *const ScenePass, keep: Keep, state: *View, signals: Gathered, smooth: bool) !void {
    const device = renderer.device;
    const cmd = p.cmd;
    cmd.beginScope("path tracing denoise");
    defer cmd.endScope();
    var denoise = DenoisePush{
        .frame = p.frame_address,
        .color_texture = device.textureIndex(signals.noisy),
        .guide_texture = device.textureIndex(signals.albedo),
        .step_size = 1,
        .gathered = state.gathered,
        .mode = .none,
        .steady_texture = device.textureIndex(signals.steady),
        .facing_texture = device.textureIndex(signals.facing),
        .gloss_texture = device.textureIndex(signals.gloss),
        .gloss_gathered_texture = device.textureIndex(signals.gloss),
        .lamp_texture = device.textureIndex(signals.lamp),
    };
    if (smooth) {
        denoise.gloss_texture = device.textureIndex(try denoiseReflections(renderer, p, keep, signals.gloss, signals.albedo, signals.surface, signals.surface_history));
        const between = [2]rhi.Texture{ try keep.one("path tracing filtered", .rgba16_float, 1), try keep.one("path tracing filtered (other)", .rgba16_float, 1) };
        for (denoise_steps[0 .. denoise_steps.len - 1], 0..) |step, run| {
            const smoothed = between[run % 2];
            denoise.step_size = step;
            denoise.mode = if (run == 0) .first else .between;
            try cmd.beginRendering(.{ .color = &.{.{ .texture = smoothed, .load = .discard }} });
            cmd.bindPipeline(try renderer.internal.pipelines.of(pathDenoisePipeline));
            cmd.pushConstants(denoise);
            cmd.drawFullscreen();
            cmd.endRendering();
            denoise.color_texture = device.textureIndex(smoothed);
        }
        denoise.step_size = denoise_steps[denoise_steps.len - 1];
        denoise.mode = .last;
    }
    try cmd.beginRendering(.{ .color = &.{.{ .texture = p.view.hdr, .load = .discard }} });
    cmd.bindPipeline(try renderer.internal.pipelines.of(pathDenoiseFinalPipeline));
    cmd.pushConstants(denoise);
    cmd.drawFullscreen();
    cmd.endRendering();
}

/// Puts the picture as traced this frame in the scene color for a denoising
/// upscaler, so that what is drawn after this pass is in what it is given.
fn handOver(renderer: *Renderer, p: *const ScenePass, signals: Signals) !void {
    const device = renderer.device;
    const cmd = p.cmd;
    try cmd.beginRendering(.{ .color = &.{.{ .texture = p.view.hdr, .load = .discard }} });
    cmd.bindPipeline(try renderer.internal.pipelines.of(pathDenoiseFinalPipeline));
    cmd.pushConstants(DenoisePush{
        .frame = p.frame_address,
        .color_texture = device.textureIndex(signals.diffuse),
        .guide_texture = device.textureIndex(signals.albedo),
        .step_size = 1,
        .gathered = 0,
        .mode = .none,
        .steady_texture = device.textureIndex(signals.direct),
        .facing_texture = device.textureIndex(signals.facing),
        .gloss_texture = device.textureIndex(signals.specular),
        .gloss_gathered_texture = device.textureIndex(signals.specular),
        .lamp_texture = device.textureIndex(signals.lamp),
    });
    cmd.drawFullscreen();
    cmd.endRendering();
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
        const keep = Keep.of(renderer, p);
        const targets = try Targets.of(keep);
        if (targets.accum.previous == null) {
            state.gathered = 0;
            state.reusable = false;
        }
        state.size = .{ width, height };
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
        const reservoir = targets.reservoir.current;
        const signals = targets.signals;
        cmd.beginScope("path tracing");
        const traced = [8]rhi.Texture{ signals.direct, signals.albedo, signals.diffuse, signals.facing, signals.lamp, signals.specular, signals.surface, reservoir };
        const in_compute = device.caps.storage_images;
        const guided = reconstructing and in_compute;
        state.guide_textures = if (guided) try makeGuides(keep) else null;
        const guide_list: [3]rhi.Texture = if (state.guide_textures) |guides| .{ guides.diffuse_albedo, guides.specular_albedo, guides.normal_roughness } else undefined;
        const beside: []const rhi.Texture = if (guided) &guide_list else &.{};
        var targets_address: u64 = 0;
        if (in_compute) {
            const indices = try p.arena.alloc(device, u32, traced.len + beside.len);
            for (traced, indices.items[0..traced.len]) |output, *slot| {
                cmd.transition(output, .storage);
                slot.* = try device.storageIndex(output, 0, 0);
            }
            for (beside, indices.items[traced.len..]) |output, *slot| {
                cmd.transition(output, .storage);
                slot.* = try device.storageIndex(output, 0, 0);
            }
            targets_address = indices.address;
        } else {
            var attachments: [traced.len]rhi.ColorAttachment = undefined;
            for (traced, &attachments) |output, *attachment| attachment.* = .{ .texture = output, .load = .discard };
            try cmd.beginRendering(.{ .color = &attachments });
        }
        cmd.bindPipeline(switch (filled(settings.path_tracing).direct) {
            .ris => if (in_compute) try renderer.internal.pipelines.of(pathTraceComputePipeline) else try renderer.internal.pipelines.of(pathTracePipeline),
        });
        cmd.pushConstants(pathtrace_push.Push{
            .frame = frame_address,
            .scene = where,
            .scene_instances = instances_address,
            .mesh_nodes = device.bufferAddress(renderer.internal.rays.bvh_nodes.get()),
            .mesh_items = device.bufferAddress(renderer.internal.rays.bvh_items.get()),
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
            .history_facing = device.textureIndex(targets.facing.last),
            .history_reservoir = device.textureIndex(targets.reservoir.last),
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

        const gathered = try gather(renderer, p, targets, .{
            .moved = moved,
            .reset = state.gathered == 0,
            .previous_eye = previous_eye,
            .history_limit = if (changed) changed_history else moving_history,
            .lamp_limit = if (changed) changed_lamp_history else if (moved) moving_history else still_history,
        });
        const denoiser: ?api.Denoiser = if (reconstructing) .ray_reconstruction else if (filled(settings.path_tracing).denoiser == .ray_reconstruction) .builtin else filled(settings.path_tracing).denoiser;
        switch (denoiser orelse .builtin) {
            .builtin => try compose(renderer, p, keep, state, gathered, denoiser != null),
            .ray_reconstruction => try handOver(renderer, p, signals),
            .nrd => if (!try denoiseWithNrd(renderer, p, keep, state, signals, gathered, state.gathered == 0)) try compose(renderer, p, keep, state, gathered, true),
        }
        state.gathered = @min(state.gathered + 1, still_history);
        state.reusable = true;
        renderer.internal.stats.path_traced_frames = state.gathered;
        renderer.internal.stats.path_tracing_hardware = device.caps.ray_tracing;
        path_traced = true;
    }
    if ((settings.path_tracing != null) and !debugging and !path_traced) renderer.internal.path_trace_misses +%= 1;
    return path_traced;
}

fn pathGatherPipeline(_: *rhi.Device) pipelines_module.Desc {
    return pipelines_module.pass("path tracing gather", pipelines_module.shaderCode("pathtrace_gather.frag.spv"), &.{ .{ .format = .rgba32_float }, .{ .format = .rgba16_float }, .{ .format = .rgba32_float }, .{ .format = .rgba16_float }, .{ .format = .rgba16_float }, .{ .format = .rgba32_float }, .{ .format = .rgba16_float } });
}

fn nrdComposePipeline(_: *rhi.Device) pipelines_module.Desc {
    return pipelines_module.pass("nrd compose", pipelines_module.shaderCode("nrd_compose.frag.spv"), &.{.{ .format = pipelines_module.hdr_format }});
}

fn nrdPackPipeline(_: *rhi.Device) pipelines_module.Desc {
    return pipelines_module.pass("nrd inputs", pipelines_module.shaderCode("nrd_pack.frag.spv"), &.{ .{ .format = .rgba16_float }, .{ .format = .r32_float }, .{ .format = .rgba16_float }, .{ .format = .rgba16_float } });
}

fn pathDenoisePipeline(_: *rhi.Device) pipelines_module.Desc {
    return pipelines_module.pass("path tracing denoise", pipelines_module.shaderCode("pathtrace_denoise.frag.spv"), &.{.{ .format = .rgba16_float }});
}

fn pathDenoiseFinalPipeline(_: *rhi.Device) pipelines_module.Desc {
    return pipelines_module.pass("path tracing denoise (last)", pipelines_module.shaderCode("pathtrace_denoise.frag.spv"), &.{.{ .format = pipelines_module.hdr_format }});
}

fn reflectionReprojectPipeline(_: *rhi.Device) pipelines_module.Desc {
    return pipelines_module.pass("reflection denoise: reproject", pipelines_module.shaderCode("ffx_reflections_reproject.frag.spv"), &.{ .{ .format = .rgba16_float }, .{ .format = .r16_float } });
}

fn reflectionAveragePipeline(_: *rhi.Device) pipelines_module.Desc {
    return pipelines_module.pass("reflection denoise: average", pipelines_module.shaderCode("ffx_reflections_average.frag.spv"), &.{.{ .format = .rgba16_float }});
}

fn reflectionPrefilterPipeline(_: *rhi.Device) pipelines_module.Desc {
    return pipelines_module.pass("reflection denoise: prefilter", pipelines_module.shaderCode("ffx_reflections_prefilter.frag.spv"), &.{.{ .format = .rgba16_float }});
}

fn reflectionResolvePipeline(_: *rhi.Device) pipelines_module.Desc {
    return pipelines_module.pass("reflection denoise: resolve", pipelines_module.shaderCode("ffx_reflections_resolve.frag.spv"), &.{.{ .format = .rgba16_float }});
}

fn pathTraceComputePipeline(device: *rhi.Device) pipelines_module.Desc {
    return .{ .compute = .{ .name = "path tracing", .shader = if (device.caps.ray_tracing) pipelines_module.shaderCode("pathtrace_rt.comp.spv") else pipelines_module.shaderCode("pathtrace.comp.spv") } };
}

fn pathTracePipeline(device: *rhi.Device) pipelines_module.Desc {
    return pipelines_module.pass("path tracing", if (device.caps.ray_tracing) pipelines_module.shaderCode("pathtrace_rt.frag.spv") else pipelines_module.shaderCode("pathtrace.frag.spv"), &.{ .{ .format = .rgba32_float }, .{ .format = .rgba16_float }, .{ .format = .rgba32_float }, .{ .format = .rgba16_float }, .{ .format = .rgba16_float }, .{ .format = .rgba32_float }, .{ .format = .rgba16_float }, .{ .format = .rgba32_float } });
}
