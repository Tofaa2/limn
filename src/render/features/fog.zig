//! Height fog lit by the sun and the sky.
const rhi = @import("../../rhi/rhi.zig");
const pipelines_module = @import("../renderer/pipelines.zig");
const fog_push = @import("../shaders/push/fog.zig");
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
    /// Extinction of the volumetric fog per world unit. 0 shows none but
    /// still runs it; `Settings.fog = null` turns it off.
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
    cmd.bindPipeline(try renderer.internal.pipelines.of(fogPipeline));
    cmd.pushConstants(fog_push.FogPush{
        .frame = frame_address,
        .depth_texture = device.textureIndex(view.depth),
        .density = (if (settings.fog) |on| on.density else 0),
        .anisotropy = std.math.clamp(filled(settings.fog).anisotropy, 0, 0.95),
        .height_falloff = filled(settings.fog).height_falloff,
        .max_distance = @max(filled(settings.shadows).distance, 1) * 2,
        .ambient = 1,
        .step_count = @intCast(std.math.clamp(filled(settings.fog).steps, 4, 128)),
    });
    cmd.drawFullscreen();
    cmd.endRendering();
    try cmd.beginRendering(.{ .color = &.{.{ .texture = view.hdr, .load = .load }} });
    cmd.bindPipeline(try renderer.internal.pipelines.of(pipelines_module.fogCompositePipeline));
    cmd.pushConstants(fog_push.CompositePush{
        .frame = frame_address,
        .fog_texture = device.textureIndex(fog),
        .depth_texture = device.textureIndex(view.depth),
    });
    cmd.drawFullscreen();
    cmd.endRendering();
    cmd.endScope();
}

fn fogPipeline(_: *rhi.Device) pipelines_module.Desc {
    return pipelines_module.pass("fog", pipelines_module.shaderCode("fog.frag.spv"), &.{.{ .format = pipelines_module.hdr_format }});
}
