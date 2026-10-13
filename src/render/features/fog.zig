//! Height fog lit by the sun and local lights.
const scene_pass = @import("../scene_pass.zig");
const render = @import("../renderer.zig");
const filled = @import("../api.zig").filled;
const std = @import("std");
const api = @import("../api.zig");
const features = @import("../core/features.zig");

const ScenePass = scene_pass.ScenePass;
const Renderer = render.Renderer;
const ViewContext = features.ViewContext;

pub const name = "fog";

pub const Settings = struct {
    /// Extinction of the volumetric fog per world unit; 0 disables it.
    density: f32 = 0.02,
    /// How quickly the fog thins with height.
    height_falloff: f32 = 0.08,
    /// Forward-scattering bias, 0 isotropic .. 1 all toward the viewer.
    anisotropy: f32 = 0.6,
    resolution: api.EffectResolution = .half,
    /// Samples along each fog ray, 4..128.
    steps: u32 = 12,
};

pub fn preset(quality: api.Quality) ?Settings {
    _ = quality;
    return null;
}

pub fn resolve(setting: *?Settings, r: *features.Resolve) void {
    _ = setting;
    _ = r;
}

/// Adds the feature's passes to a view of a scene. A path traced view leaves
/// out those whose result the tracer replaces.
pub fn declare(ctx: *ViewContext) !void {
    if (ctx.scene == null) return;
    const g = ctx.graph;
    try g.add(.{ .name = "fog", .stage = .volumes, .always = true, .scope = false }, ctx, drawFogPass);
}

fn drawFogPass(ctx: *ViewContext) !void {
    const p = ctx.scene.?;
    if ((if (p.settings.fog) |on| on.density else 0) > 0 and !p.debugging) try drawFog(ctx.renderer, p);
}

/// Ray-marches the fog and composites it.
pub fn drawFog(renderer: *Renderer, p: *const ScenePass) !void {
    const device = renderer.device;
    const cmd = p.cmd;
    const settings = p.settings;
    const view = p.view;
    const frame_address = p.frame_address;
    cmd.beginScope("volumetric fog");
    const fog = try p.keep(renderer, "fog", ScenePass.scaled(filled(settings.fog).resolution, p.width), ScenePass.scaled(filled(settings.fog).resolution, p.height), render.hdr_format);
    try cmd.beginRendering(.{ .color = &.{.{ .texture = fog, .load = .discard }} });
    cmd.bindPipeline(try renderer.pipelines.get(.fog));
    cmd.pushConstants(extern struct { frame: u64, depth: u32, density: f32, anisotropy: f32, height_falloff: f32, max_distance: f32, ambient: f32, step_count: i32, pad: u32 = 0 }{
        .frame = frame_address,
        .depth = device.textureIndex(view.depth),
        .density = (if (settings.fog) |on| on.density else 0),
        .anisotropy = std.math.clamp(filled(settings.fog).anisotropy, 0, 0.95),
        .height_falloff = filled(settings.fog).height_falloff,
        .max_distance = @max(filled(settings.shadows).distance, 1) * 2,
        .ambient = 1,
        .step_count = @intCast(std.math.clamp(filled(settings.fog).steps, 4, 128)),
    });
    cmd.drawFullscreen();
    cmd.endRendering();
    cmd.transition(fog, .shader_read);
    try cmd.beginRendering(.{ .color = &.{.{ .texture = view.hdr, .load = .load }} });
    cmd.bindPipeline(try renderer.pipelines.get(.fog_composite));
    cmd.pushConstants(extern struct { frame: u64, fog: u32, depth: u32 }{
        .frame = frame_address,
        .fog = device.textureIndex(fog),
        .depth = device.textureIndex(view.depth),
    });
    cmd.drawFullscreen();
    cmd.endRendering();
    cmd.transition(view.hdr, .shader_read);
    cmd.endScope();
}
