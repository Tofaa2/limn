//! Volumetric clouds of a scene that has them.
const rhi = @import("../../rhi/rhi.zig");
const pipelines_module = @import("../renderer/pipelines.zig");
const cloud_passes_push = @import("../shaders/push/cloud_passes.zig");
const scene_pass = @import("../scene_pass.zig");
const render = @import("../renderer.zig");
const gpu = @import("../gpu.zig");
const math = @import("../../math.zig");
const filled = @import("../api.zig").filled;
const std = @import("std");
const api = @import("../api.zig");
const features = @import("../core/features.zig");

const ScenePass = scene_pass.ScenePass;
const cloud_noise_tiles = render.cloud_noise_tiles;
const cloud_noise_size = render.cloud_noise_size;
const cloud_weather_size = render.cloud_weather_size;
const Renderer = render.Renderer;
const Vec3 = math.Vec3;
const ViewContext = features.ViewContext;

pub const name = "clouds";

pub const Settings = struct {
    resolution: api.EffectResolution = .half,
    /// Samples along each cloud ray, 8..256, and toward the sun from each,
    /// 1..16.
    steps: u32 = 48,
    light_steps: u32 = 6,
    /// How far clouds are drawn, in world units; they fade out before it.
    distance: f32 = 60_000,
    /// Average clouds over frames; without it they are grainy.
    temporal_filter: bool = true,
};

pub fn preset(quality: api.Quality) ?Settings {
    return switch (quality) {
        .ultra => .{},
        .high => .{},
        .medium => .{ .steps = 32 },
        .low => .{ .resolution = .quarter, .steps = 24 },
    };
}

pub fn resolve(setting: *?Settings, r: *features.Resolve) void {
    _ = setting;
    _ = r;
}

/// Adds the feature's passes to a view of a scene. A path traced view leaves
/// out those whose result the tracer replaces.
/// Writes the scene's clouds for the shaders that read them.
pub fn prepare(ctx: *ViewContext) !void {
    const p = ctx.scene orelse return;
    const address = try prepareClouds(ctx.renderer, p);
    p.shared.cloud_address = address;
    ctx.constants.clouds.layer = address;
    if (address != 0 and p.scene.clouds.?.shadow > 0) ctx.constants.clouds.shadows = 1;
}

pub fn declare(ctx: *ViewContext) !void {
    if (ctx.scene == null) return;
    const g = ctx.graph;
    try g.add(.{ .name = "clouds", .stage = .sky, .always = true, .scope = false }, ctx, clouds);
}

fn clouds(ctx: *ViewContext) !void {
    const p = ctx.scene.?;
    const c = p.shared;
    if (c.cloud_address != 0 and !p.debugging) try drawClouds(ctx.renderer, p, c.cloud_address);
}

/// Uploads the cloud layer's parameters for this view and returns their
/// address, or 0 without clouds. Creates the noise volume on first use.
pub fn prepareClouds(renderer: *Renderer, p: *const ScenePass) !u64 {
    const device = renderer.device;
    const cmd = p.cmd;
    const arena = p.arena;
    const desc = p.desc;
    const settings = p.settings;
    const scene = p.scene;
    const view = p.view;
    const delta_time = p.delta_time;
    var cloud_address: u64 = 0;
    if (scene.clouds != null and settings.clouds != null) clouds: {
        const layer = scene.clouds orelse break :clouds;
        if (renderer.internal.cloud_noise == null) {
            const noise = try device.createTexture(.{
                .name = "cloud noise",
                .width = cloud_noise_size[0] * cloud_noise_tiles,
                .height = cloud_noise_size[1] * (cloud_noise_size[2] / cloud_noise_tiles),
                .format = .rgba8_unorm,
                .usage = .{ .sampled = true, .color_attachment = true },
            });
            renderer.internal.cloud_noise = noise;
            try cmd.beginRendering(.{ .color = &.{.{ .texture = noise, .load = .discard }} });
            cmd.bindPipeline(try renderer.internal.pipelines.of(cloudNoisePipeline));
            cmd.pushConstants(cloud_passes_push.NoisePush{ .size = cloud_noise_size, .tiles_x = cloud_noise_tiles });
            cmd.drawFullscreen();
            cmd.endRendering();
        }
        if (renderer.internal.cloud_weather == null) {
            const weather = try device.createTexture(.{
                .name = "cloud weather",
                .width = cloud_weather_size,
                .height = cloud_weather_size,
                .format = .rgba8_unorm,
                .usage = .{ .sampled = true, .color_attachment = true },
            });
            renderer.internal.cloud_weather = weather;
            try cmd.beginRendering(.{ .color = &.{.{ .texture = weather, .load = .discard }} });
            cmd.bindPipeline(try renderer.internal.pipelines.of(cloudWeatherPipeline));
            cmd.pushConstants(cloud_passes_push.WeatherPush{ .size = cloud_weather_size });
            cmd.drawFullscreen();
            cmd.endRendering();
        }
        const period = 9000 * @max(layer.scale, 0.01);
        if (scene.cloud_time != renderer.internal.time) {
            const elapsed = renderer.internal.time - scene.cloud_time;
            inline for (0..3) |axis| scene.cloud_drift[axis] = @mod(scene.cloud_drift[axis] + @as(f64, layer.wind[axis]) * elapsed, period * 64);
            scene.cloud_time = renderer.internal.time;
        }
        var offset: Vec3 = undefined;
        inline for (0..3) |axis| offset[axis] = @floatCast(@mod(scene.origin[axis] - scene.cloud_drift[axis], period * 64));
        const cloud_width = ScenePass.scaled(filled(settings.clouds).resolution, p.width);
        const cloud_height = ScenePass.scaled(filled(settings.clouds).resolution, p.height);
        const targets = try p.view_data.kept.history(renderer.internal.gpa, device, .{ .name = "clouds", .width = cloud_width, .height = cloud_height, .format = render.hdr_format, .usage = .{ .sampled = true, .color_attachment = true } }, renderer.internal.frame_index);
        const bottom = @max(layer.bottom, 0);
        const bottom_altitude: f64 = bottom;
        if (layer.lightning > 0 and renderer.internal.time - scene.flash_start > 0.6 and renderer.internal.time != scene.flash_checked) {
            var random = std.Random.DefaultPrng.init(renderer.internal.frame_index *% 0x9e3779b97f4a7c15 +% 0x51ed);
            const draw = random.random();
            if (draw.float(f32) < layer.lightning / 60.0 * delta_time) {
                scene.flash_start = renderer.internal.time;
                scene.flash_position = .{
                    scene.origin[0] + desc.camera.position[0] + (draw.float(f32) - 0.5) * 8000,
                    bottom_altitude + @max(layer.thickness, 1) * (0.3 + 0.4 * draw.float(f32)),
                    scene.origin[2] + desc.camera.position[2] + (draw.float(f32) - 0.5) * 8000,
                };
            }
        }
        scene.flash_checked = renderer.internal.time;
        scene.flash_brightness = 0;
        const flash_age = renderer.internal.time - scene.flash_start;
        if (layer.lightning > 0 and flash_age >= 0 and flash_age < 0.6) {
            for ([_]f32{ 0, 0.11, 0.19 }) |stroke| {
                if (flash_age >= stroke) scene.flash_brightness += @exp(-(flash_age - stroke) * 22);
            }
            scene.flash_brightness *= @max(layer.lightning_brightness, 0);
        }
        const flash = [4]f32{
            @floatCast(scene.flash_position[0] - scene.origin[0]),
            @floatCast(scene.flash_position[1] - scene.origin[1]),
            @floatCast(scene.flash_position[2] - scene.origin[2]),
            scene.flash_brightness,
        };
        const params = try arena.alloc(device, gpu.Clouds, 1);
        params.items[0] = .{
            .offset = offset,
            .period = period,
            .albedo = layer.color,
            .density = @max(layer.density, 0),
            .bottom = bottom,
            .top = bottom + @max(layer.thickness, 1),
            .coverage = std.math.clamp(layer.coverage, 0, 1),
            .detail = std.math.clamp(layer.detail, 0, 1),
            .planet_radius = @max(layer.planet_radius, 1000),
            .max_distance = @max(filled(settings.clouds).distance, 100),
            .variation = std.math.clamp(layer.variation, 0, 2),
            .ambient = @max(layer.ambient, 0),
            .noise = device.textureIndex(renderer.internal.cloud_noise.?),
            .steps = @intCast(std.math.clamp(filled(settings.clouds).steps, 8, 256)),
            .light_steps = @intCast(std.math.clamp(filled(settings.clouds).light_steps, 1, 16)),
            .history = if (targets.previous != null and filled(settings.clouds).temporal_filter) device.textureIndex(targets.previous.?) else gpu.invalid_id,
            .history_blend = 0.1,
            .anisotropy = std.math.clamp(layer.anisotropy, 0, 0.95),
            .depth = device.textureIndex(view.depth),
            .shadow_strength = std.math.clamp(layer.shadow, 0, 1),
            .cirrus = std.math.clamp(layer.cirrus, 0, 1),
            .anvil = std.math.clamp(layer.anvil, 0, 1),
            .weather = if (layer.weather) |image| image.index else device.textureIndex(renderer.internal.cloud_weather.?),
            .weather_size = if (layer.weather_size > 0) layer.weather_size else period * 16,
            .flash = flash,
            .pattern = device.textureIndex(renderer.internal.cloud_weather.?),
            .repeat_sampler = device.samplerIndex(renderer.internal.sampler_linear_repeat),
            .curl = std.math.clamp(layer.curl, 0, 1),
            .kind = std.math.clamp(layer.kind, 0, 1),
        };
        cloud_address = params.address;
        if (scene.environment) |handle_value| if (renderer.environments.table.get(handle_value)) |sky_entry| {
            if ((sky_entry.sky_desc != null or sky_entry.state == .ready) and layer.environment_interval > 0 and
                (sky_entry.clouds == null or renderer.internal.time - sky_entry.cloud_bake_time >= layer.environment_interval))
            {
                sky_entry.clouds = params.items[0];
                sky_entry.cloud_bake_time = renderer.internal.time;
                sky_entry.cloud_to_sun = math.scale(math.normalize(scene.sun.direction), -1);
                sky_entry.cloud_sunlight = math.scale(scene.sun.color, scene.sun.intensity);
                sky_entry.sky_dirty = true;
                renderer.internal.skies_dirty = true;
            }
        };
    }
    if (scene.clouds == null) if (scene.environment) |handle_value| if (renderer.environments.table.get(handle_value)) |sky_entry| {
        if (sky_entry.clouds != null) {
            sky_entry.clouds = null;
            sky_entry.sky_dirty = true;
            renderer.internal.skies_dirty = true;
        }
    };
    return cloud_address;
}

/// Ray-marches the cloud layer and composites it.
pub fn drawClouds(renderer: *Renderer, p: *const ScenePass, cloud_address: u64) !void {
    const device = renderer.device;
    const cmd = p.cmd;
    const view = p.view;
    const frame_address = p.frame_address;
    const current = p.view_data.kept.latest("clouds", renderer.internal.frame_index).?;
    cmd.beginScope("clouds");
    try cmd.beginRendering(.{ .color = &.{.{ .texture = current, .load = .discard }} });
    cmd.bindPipeline(try renderer.internal.pipelines.of(cloudPipeline));
    cmd.pushConstants(cloud_passes_push.MarchPush{ .frame = frame_address, .clouds = cloud_address });
    cmd.drawFullscreen();
    cmd.endRendering();
    try cmd.beginRendering(.{ .color = &.{.{ .texture = view.hdr, .load = .load }} });
    cmd.bindPipeline(try renderer.internal.pipelines.of(cloudCompositePipeline));
    cmd.pushConstants(cloud_passes_push.CompositePush{ .frame = frame_address, .clouds = cloud_address, .cloud_texture = device.textureIndex(current) });
    cmd.drawFullscreen();
    cmd.endRendering();
    cmd.endScope();
}

fn cloudNoisePipeline(_: *rhi.Device) pipelines_module.Desc {
    return pipelines_module.pass("cloud noise", pipelines_module.shaderCode("cloud_noise.frag.spv"), &.{.{ .format = .rgba8_unorm }});
}

fn cloudWeatherPipeline(_: *rhi.Device) pipelines_module.Desc {
    return pipelines_module.pass("cloud weather", pipelines_module.shaderCode("cloud_weather.frag.spv"), &.{.{ .format = .rgba8_unorm }});
}

fn cloudPipeline(_: *rhi.Device) pipelines_module.Desc {
    return pipelines_module.pass("clouds", pipelines_module.shaderCode("cloud.frag.spv"), &.{.{ .format = pipelines_module.hdr_format }});
}

fn cloudCompositePipeline(_: *rhi.Device) pipelines_module.Desc {
    return pipelines_module.pass("cloud composite", pipelines_module.shaderCode("cloud_composite.frag.spv"), &.{.{ .format = pipelines_module.hdr_format, .blend = .premultiplied }});
}
