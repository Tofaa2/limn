//! Volumes between the camera and the scene: clouds, smoke, fire and fog.
//! Internal to the renderer.
const std = @import("std");
const rhi = @import("../../rhi/rhi.zig");
const math = @import("../../math.zig");
const gpu = @import("../gpu.zig");
const render = @import("../renderer.zig");
const scene_pass = @import("../scene_pass.zig");

const Vec3 = math.Vec3;
const Renderer = render.Renderer;
const cloud_noise_size = render.cloud_noise_size;
const cloud_noise_tiles = render.cloud_noise_tiles;
const max_fluids = render.max_fluids;
const ScenePass = scene_pass.ScenePass;
const Lighting = scene_pass.Lighting;

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
    if (view.clouds) |*targets| clouds: {
        const layer = scene.clouds orelse break :clouds;
        if (renderer.cloud_noise == null) {
            const noise = try device.createTexture(.{
                .name = "cloud noise",
                .width = cloud_noise_size[0] * cloud_noise_tiles,
                .height = cloud_noise_size[1] * (cloud_noise_size[2] / cloud_noise_tiles),
                .format = .rgba8_unorm,
                .usage = .{ .sampled = true, .color_attachment = true },
            });
            renderer.cloud_noise = noise;
            try cmd.beginRendering(.{ .color = &.{.{ .texture = noise, .load = .discard }} });
            cmd.bindPipeline(renderer.pipelines.cloud_noise);
            cmd.pushConstants(extern struct { size: [3]i32, tiles_x: i32 }{ .size = cloud_noise_size, .tiles_x = cloud_noise_tiles });
            cmd.drawFullscreen();
            cmd.endRendering();
            cmd.transition(noise, .shader_read);
        }
        const period = 9000 * @max(layer.scale, 0.01);
        if (scene.cloud_time != renderer.time) {
            const elapsed = renderer.time - scene.cloud_time;
            inline for (0..3) |axis| scene.cloud_drift[axis] = @mod(scene.cloud_drift[axis] + @as(f64, layer.wind[axis]) * elapsed, period * 64);
            scene.cloud_time = renderer.time;
        }
        var offset: Vec3 = undefined;
        inline for (0..3) |axis| offset[axis] = @floatCast(@mod(scene.origin[axis] - scene.cloud_drift[axis], period * 64));
        std.mem.swap(rhi.Texture, &targets.current, &targets.history);
        const bottom = @max(layer.bottom, 0);
        const bottom_altitude: f64 = bottom;
        if (layer.lightning > 0 and renderer.time - scene.flash_start > 0.6 and renderer.time != scene.flash_checked) {
            var random = std.Random.DefaultPrng.init(renderer.frame_index *% 0x9e3779b97f4a7c15 +% 0x51ed);
            const draw = random.random();
            if (draw.float(f32) < layer.lightning / 60.0 * delta_time) {
                scene.flash_start = renderer.time;
                scene.flash_position = .{
                    scene.origin[0] + desc.camera.position[0] + (draw.float(f32) - 0.5) * 8000,
                    bottom_altitude + @max(layer.thickness, 1) * (0.3 + 0.4 * draw.float(f32)),
                    scene.origin[2] + desc.camera.position[2] + (draw.float(f32) - 0.5) * 8000,
                };
            }
        }
        scene.flash_checked = renderer.time;
        scene.flash_brightness = 0;
        const flash_age = renderer.time - scene.flash_start;
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
            .max_distance = @max(settings.cloud_distance, 100),
            .variation = std.math.clamp(layer.variation, 0, 2),
            .ambient = @max(layer.ambient, 0),
            .noise = device.textureIndex(renderer.cloud_noise.?),
            .steps = @intCast(std.math.clamp(settings.cloud_steps, 8, 256)),
            .light_steps = @intCast(std.math.clamp(settings.cloud_light_steps, 1, 16)),
            .history = if (targets.history_valid and settings.cloud_temporal_filter) device.textureIndex(targets.history) else gpu.invalid_id,
            .history_blend = 0.1,
            .anisotropy = std.math.clamp(layer.anisotropy, 0, 0.95),
            .depth = device.textureIndex(view.depth),
            .shadow_strength = std.math.clamp(layer.shadow, 0, 1),
            .cirrus = std.math.clamp(layer.cirrus, 0, 1),
            .anvil = std.math.clamp(layer.anvil, 0, 1),
            .flash = flash,
        };
        cloud_address = params.address;
        if (scene.environment) |handle_value| if (renderer.environments.get(handle_value)) |sky_entry| {
            if ((sky_entry.sky_desc != null or sky_entry.state == .ready) and layer.environment_interval > 0 and
                (sky_entry.clouds == null or renderer.time - sky_entry.cloud_bake_time >= layer.environment_interval))
            {
                sky_entry.clouds = params.items[0];
                sky_entry.cloud_bake_time = renderer.time;
                // A loaded environment has no sun: its clouds use the scene's.
                sky_entry.cloud_to_sun = math.scale(math.normalize(scene.sun.direction), -1);
                sky_entry.cloud_sunlight = math.scale(scene.sun.color, scene.sun.intensity);
                sky_entry.sky_dirty = true;
                renderer.skies_dirty = true;
            }
        };
    }
    if (scene.clouds == null) if (scene.environment) |handle_value| if (renderer.environments.get(handle_value)) |sky_entry| {
        if (sky_entry.clouds != null) {
            sky_entry.clouds = null;
            sky_entry.sky_dirty = true;
            renderer.skies_dirty = true;
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
    const targets = &view.clouds.?;
    cmd.beginScope("clouds");
    const CloudPush = extern struct { frame: u64, clouds: u64, texture: u32 = 0, pad: u32 = 0 };
    try cmd.beginRendering(.{ .color = &.{.{ .texture = targets.current, .load = .discard }} });
    cmd.bindPipeline(renderer.pipelines.cloud);
    cmd.pushConstants(CloudPush{ .frame = frame_address, .clouds = cloud_address });
    cmd.drawFullscreen();
    cmd.endRendering();
    cmd.transition(targets.current, .shader_read);
    targets.history_valid = true;
    try cmd.beginRendering(.{ .color = &.{.{ .texture = view.hdr, .load = .load }} });
    cmd.bindPipeline(renderer.pipelines.cloud_composite);
    cmd.pushConstants(CloudPush{ .frame = frame_address, .clouds = cloud_address, .texture = device.textureIndex(targets.current) });
    cmd.drawFullscreen();
    cmd.endRendering();
    cmd.transition(view.hdr, .shader_read);
    cmd.endScope();
}

/// The fluids stepped this frame that cast shadows.
pub fn shadowingFluids(renderer: *Renderer, p: *const ScenePass) gpu.FluidList {
    const scene = p.scene;
    var list = gpu.FluidList{};
    for (scene.fluids.items) |item| {
        const state = renderer.fluids.get(item) orelse continue;
        if (state.params_frame != renderer.frame_index or state.desc.shadow <= 0) continue;
        list.fluids[list.count] = state.params;
        list.count += 1;
    }
    if (list.count != 0) {
        for (list.fluids[list.count..]) |*slot| slot.* = list.fluids[0];
    }
    return list;
}

/// Writes the lights of the scene's fires into the light records after the
/// scene's own.
pub fn lightFluids(renderer: *Renderer, p: *const ScenePass, lighting: *const Lighting) void {
    const cmd = p.cmd;
    const scene = p.scene;
    if (scene.fluids.items.len != 0) {
        var fluid_slot: u32 = @intCast(scene.lights.items.len);
        var bound = false;
        for (scene.fluids.items) |item| {
            const state = renderer.fluids.get(item) orelse continue;
            if (state.desc.light <= 0) continue;
            defer fluid_slot += 1;
            if (state.params_frame != renderer.frame_index) continue;
            if (!bound) cmd.bindPipeline(renderer.pipelines.fluid_light);
            bound = true;
            cmd.pushConstants(extern struct { fluid: u64, lights: u64, index: u32, scale: f32, tall: f32, pad: u32 = 0 }{ .fluid = state.params, .lights = lighting.lights, .index = fluid_slot, .scale = state.desc.light * 8, .tall = std.math.clamp(state.desc.light_tall, 0, 1) });
            cmd.dispatch(1, 1, 1);
        }
        if (bound) cmd.sync(.compute_to_all);
    }
}

/// Ray-marches the scene's smoke and fire and composites them.
pub fn drawFluids(renderer: *Renderer, p: *const ScenePass) !void {
    const device = renderer.device;
    const cmd = p.cmd;
    const settings = p.settings;
    const scene = p.scene;
    const view = p.view;
    const debugging = p.debugging;
    const frame_address = p.frame_address;
    if (view.fluid) |fluid_target| fluids: {
        if (debugging) break :fluids;
        var push = extern struct { frame: u64, depth: u32, count: u32, steps: i32, light_steps: i32, motion: u32, pad: u32 = 0, fluids: [max_fluids]u64 }{
            .motion = @intFromBool(settings.fluid_motion_vectors),
            .frame = frame_address,
            .depth = device.textureIndex(view.depth),
            .count = 0,
            .steps = @intCast(std.math.clamp(settings.fluid_steps, 4, 256)),
            .light_steps = @intCast(std.math.clamp(settings.fluid_light_steps, 1, 32)),
            .fluids = @splat(0),
        };
        for (scene.fluids.items) |item| {
            const state = renderer.fluids.get(item) orelse continue;
            if (state.params_frame != renderer.frame_index) continue;
            push.fluids[push.count] = state.params;
            push.count += 1;
        }
        if (push.count == 0) break :fluids;
        // Unused slots hold a valid fluid: helper invocations may dereference
        // them.
        for (push.fluids[push.count..]) |*slot| slot.* = push.fluids[0];
        cmd.beginScope("fluids");
        const fluid_motion = view.fluid_motion.?;
        try cmd.beginRendering(.{ .color = &.{ .{ .texture = fluid_target, .load = .discard }, .{ .texture = fluid_motion, .load = .discard } } });
        cmd.bindPipeline(renderer.pipelines.fluid);
        cmd.pushConstants(push);
        cmd.drawFullscreen();
        cmd.endRendering();
        cmd.transition(fluid_target, .shader_read);
        cmd.transition(fluid_motion, .shader_read);
        if (settings.fluid_motion_vectors) {
            try cmd.beginRendering(.{ .color = &.{.{ .texture = view.motion, .load = .load }} });
            cmd.bindPipeline(renderer.pipelines.fluid_motion);
            cmd.pushConstants(extern struct { frame: u64, source: u32, pad: u32 = 0 }{ .frame = frame_address, .source = device.textureIndex(fluid_motion) });
            cmd.drawFullscreen();
            cmd.endRendering();
            cmd.transition(view.motion, .shader_read);
        }
        try cmd.beginRendering(.{ .color = &.{.{ .texture = view.hdr, .load = .load }} });
        cmd.bindPipeline(renderer.pipelines.fog_composite);
        cmd.pushConstants(extern struct { frame: u64, fog: u32, depth: u32 }{
            .frame = frame_address,
            .fog = device.textureIndex(fluid_target),
            .depth = device.textureIndex(view.depth),
        });
        cmd.drawFullscreen();
        cmd.endRendering();
        cmd.transition(view.hdr, .shader_read);
        cmd.endScope();
    }
}

/// Ray-marches the fog and composites it.
pub fn drawFog(renderer: *Renderer, p: *const ScenePass) !void {
    const device = renderer.device;
    const cmd = p.cmd;
    const settings = p.settings;
    const view = p.view;
    const frame_address = p.frame_address;
    cmd.beginScope("volumetric fog");
    try cmd.beginRendering(.{ .color = &.{.{ .texture = view.fog, .load = .discard }} });
    cmd.bindPipeline(renderer.pipelines.fog);
    cmd.pushConstants(extern struct { frame: u64, depth: u32, density: f32, anisotropy: f32, height_falloff: f32, max_distance: f32, ambient: f32, step_count: i32, pad: u32 = 0 }{
        .frame = frame_address,
        .depth = device.textureIndex(view.depth),
        .density = settings.fog_density,
        .anisotropy = std.math.clamp(settings.fog_anisotropy, 0, 0.95),
        .height_falloff = settings.fog_height_falloff,
        .max_distance = @max(settings.shadow_distance, 1) * 2,
        .ambient = 1,
        .step_count = @intCast(std.math.clamp(settings.fog_steps, 4, 128)),
    });
    cmd.drawFullscreen();
    cmd.endRendering();
    cmd.transition(view.fog, .shader_read);
    try cmd.beginRendering(.{ .color = &.{.{ .texture = view.hdr, .load = .load }} });
    cmd.bindPipeline(renderer.pipelines.fog_composite);
    cmd.pushConstants(extern struct { frame: u64, fog: u32, depth: u32 }{
        .frame = frame_address,
        .fog = device.textureIndex(view.fog),
        .depth = device.textureIndex(view.depth),
    });
    cmd.drawFullscreen();
    cmd.endRendering();
    cmd.transition(view.hdr, .shader_read);
    cmd.endScope();
}
