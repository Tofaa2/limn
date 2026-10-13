//! Reflections traced on screen and, where the GPU traces rays, through the scene.
const scene_pass = @import("../scene_pass.zig");
const gpu = @import("../gpu.zig");
const std = @import("std");
const render = @import("../renderer.zig");
const rhi = @import("../../rhi/rhi.zig");
const filled = @import("../api.zig").filled;
const api = @import("../api.zig");
const features = @import("../core/features.zig");
const ray_scene = @import("../scene/ray_scene.zig");

const ScenePass = scene_pass.ScenePass;
const ReflectionTargets = render.ReflectionTargets;
const Renderer = render.Renderer;
const ViewContext = features.ViewContext;

pub const name = "reflections";

pub const Settings = struct {
    /// Resolution the reflection rays are traced at.
    resolution: api.EffectResolution = .full,
    /// Surfaces rougher than this reflect only the sky.
    max_roughness: f32 = 0.5,
    /// Samples along each reflection ray, 4..256.
    steps: u32 = 32,
    /// How far a reflection ray travels, in world units.
    distance: f32 = 30,
    /// Assumed thickness of surfaces a ray passes behind.
    thickness: f32 = 0.3,
    /// Average reflections over frames; moving reflections trail slightly.
    temporal_filter: bool = true,
    /// Trace a ray where the screen has no reflection. Needs ray tracing. Hits
    /// are shaded with sun and probe or sky light, without
    /// highlights. Animated meshes are hit only with
    /// `Options.ray_tracing.dynamic_geometry`, transparent ones with `Settings.reflections.transparent`.
    ray_tracing: bool = true,
    /// Ray-traced reflections show the nearest transparent surface along the
    /// ray, at a second ray where one is hit.
    transparent: bool = true,
    /// Roughness blur samples, 0..32; 0 leaves reflections sharp.
    blur_samples: u32 = 8,
};

pub fn preset(quality: api.Quality) ?Settings {
    return switch (quality) {
        .ultra => .{},
        .high => .{ .resolution = .half },
        .medium => .{ .resolution = .half },
        .low => null,
    };
}

pub fn resolve(setting: *?Settings, r: *features.Resolve) void {
    const s = &(setting.* orelse return);
    if (s.ray_tracing and !r.caps.ray_tracing) {
        s.ray_tracing = false;
        r.downgrade("reflections.ray_tracing", "on", "off", .no_ray_tracing);
    }
}

/// Adds the feature's passes to a view of a scene. A path traced view leaves
/// out those whose result the tracer replaces.
pub fn declare(ctx: *ViewContext) !void {
    const p = ctx.scene orelse return;
    if (p.settings.reflections != null and !p.debugging) ctx.constants.flags |= gpu.frame_flags.ssr;
    if (filled(p.settings.reflections).transparent) ctx.constants.flags |= gpu.frame_flags.reflect_transparent;
    if (p.tracing) return;
    const g = ctx.graph;
    try g.add(.{ .name = "reflections", .stage = .reflections, .always = true, .scope = false }, ctx, reflect);
}

fn reflect(ctx: *ViewContext) !void {
    const p = ctx.scene.?;
    const c = p.shared;
    if (c.reflections) |targets| try drawReflections(ctx.renderer, p, targets, ray_scene.current(p.scene, p.scene_frame) != null);
}

/// The view's reflection targets for this frame, kept from frame to frame
/// while reflections stay on.
pub fn reflectionTargets(renderer: *Renderer, p: *const ScenePass) !ReflectionTargets {
    const device = renderer.device;
    const kept = &p.view_data.kept;
    const frame = renderer.frame_index;
    const color = rhi.TextureUsage{ .sampled = true, .color_attachment = true };
    const scale = filled(p.settings.reflections).resolution;
    const traced = try kept.history(renderer.gpa, device, .{ .name = "reflections", .width = @import("../state.zig").scaledExtent(scale, p.width), .height = @import("../state.zig").scaledExtent(scale, p.height), .format = render.hdr_format, .usage = color }, frame);
    return .{
        .weight = try kept.single(renderer.gpa, device, .{ .name = "reflection weight", .width = p.width, .height = p.height, .format = render.hdr_format, .usage = color }, frame),
        .surface = try kept.single(renderer.gpa, device, .{ .name = "reflection surface", .width = p.width, .height = p.height, .format = render.hdr_format, .usage = color }, frame),
        .traced = traced.current,
        .history = traced.previous orelse traced.current,
        .history_valid = traced.previous != null,
    };
}

/// Traces screen-space reflections (and, with `ray_traced`, rays through the
/// scene) and composites them.
pub fn drawReflections(renderer: *Renderer, p: *const ScenePass, targets: ReflectionTargets, ray_traced: bool) !void {
    const device = renderer.device;
    const cmd = p.cmd;
    const settings = p.settings;
    const scene = p.scene;
    const view = p.view;
    const frame_address = p.frame_address;
    cmd.transition(targets.weight, .shader_read);
    cmd.transition(targets.surface, .shader_read);
    cmd.beginScope("reflections");
    try cmd.beginRendering(.{ .color = &.{.{ .texture = targets.traced, .load = .discard }} });
    const traced_tlas: u64 = if (filled(settings.reflections).ray_tracing and ray_traced and device.caps.ray_tracing)
        (if (scene.tlas) |tlas| device.accelerationAddress(tlas) else 0)
    else
        0;
    cmd.bindPipeline(if (traced_tlas != 0) try renderer.pipelines.get(.ssr_traced) else try renderer.pipelines.get(.ssr));
    cmd.pushConstants(extern struct { frame: u64, depth: u32, color: u32, reflection: u32, surface: u32, max_roughness: f32, thickness: f32, max_distance: f32, step_count: i32, history: u32, history_blend: f32, tlas: u64 }{
        .frame = frame_address,
        .depth = device.textureIndex(view.depth),
        .color = device.textureIndex(view.hdr),
        .reflection = device.textureIndex(targets.weight),
        .surface = device.textureIndex(targets.surface),
        .max_roughness = std.math.clamp(filled(settings.reflections).max_roughness, 0.05, 1),
        .thickness = @max(filled(settings.reflections).thickness, 0.01),
        .max_distance = @max(filled(settings.reflections).distance, 0.1),
        .step_count = @intCast(std.math.clamp(filled(settings.reflections).steps, 4, 256)),
        .history = if (targets.history_valid and filled(settings.reflections).temporal_filter) device.textureIndex(targets.history) else gpu.invalid_id,
        .history_blend = 0.12,
        .tlas = traced_tlas,
    });
    cmd.drawFullscreen();
    cmd.endRendering();
    cmd.transition(targets.traced, .shader_read);
    try cmd.beginRendering(.{ .color = &.{.{ .texture = view.hdr, .load = .load }} });
    cmd.bindPipeline(try renderer.pipelines.get(.ssr_composite));
    cmd.pushConstants(extern struct { frame: u64, depth: u32, reflection: u32, surface: u32, traced: u32, max_roughness: f32, blur_taps: i32, reduced: u32, pad: u32 = 0 }{
        .frame = frame_address,
        .depth = device.textureIndex(view.depth),
        .reflection = device.textureIndex(targets.weight),
        .surface = device.textureIndex(targets.surface),
        .traced = device.textureIndex(targets.traced),
        .max_roughness = std.math.clamp(filled(settings.reflections).max_roughness, 0.05, 1),
        .blur_taps = @intCast(@min(filled(settings.reflections).blur_samples, 32)),
        .reduced = @intFromBool(filled(settings.reflections).resolution != .full),
    });
    cmd.drawFullscreen();
    cmd.endRendering();
    cmd.transition(view.hdr, .shader_read);
    cmd.endScope();
}
