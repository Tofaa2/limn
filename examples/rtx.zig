//! Ray tracing, a feature at a time, in Sponza. The example asks the
//! renderer whether the GPU traces rays and says so on screen. Where it
//! does, each key switches one use of it, so what it adds can be seen:
//!
//!   1        bounce light from probes that trace the scene
//!   2        reflections traced where the screen has no answer
//!   3        shadows of the lamp, traced and soft
//!   P        path tracing: the whole picture by following light
//!   D        NVIDIA DLSS: denoises the path traced picture, antialiases
//!            the other
//!   Up/Down  bounces of the path tracer
//!   C        next camera
//!   Space    stop and start the lamp
//!
//! Where the GPU does not trace rays, the three features fall back to
//! what the renderer does without them (sky light, screen-space
//! reflections, shadow maps), and path tracing runs in a shader instead,
//! more slowly. `--software 1` tries that on a GPU that could do better.
//!
//! `--path 1` starts path traced and `--dlss 1` with DLSS; `--drift 1` keeps
//! the camera swaying, to see the traced picture hold while it moves. `--frames N`,
//! `--screenshot file.png`.
const std = @import("std");
const gfx = @import("limn");
const math = gfx.math;
const glfw = @import("glfw");
const helpers = @import("window");
const Stage = helpers.Stage;

pub fn main(init: std.process.Init) !void {
    var options = gfx.Options{ .path_tracing_fallback = true, .asset_cache_dir = "zig-out/asset-cache" };
    var path_traced = false;
    var drifting = false;
    var dlss = false;
    {
        var arguments = try init.minimal.args.iterateAllocator(init.gpa);
        defer arguments.deinit();
        while (arguments.next()) |argument| {
            if (std.mem.eql(u8, argument, "--software")) options.ray_tracing = false;
            if (std.mem.eql(u8, argument, "--path")) path_traced = true;
            if (std.mem.eql(u8, argument, "--drift")) drifting = true;
            if (std.mem.eql(u8, argument, "--dlss")) dlss = true;
        }
    }
    var stage = try Stage.create(init, "Limn ray tracing", options);
    const renderer = stage.renderer;
    const support = renderer.pathTracing();
    const hardware = support == .hardware;
    const dlss_support = renderer.dlssSupport();
    const scene = try renderer.scenes.create();

    const sky_desc = gfx.SkyDesc{ .sun_direction = .{ -0.25, -1.0, 0.12 } };
    renderer.scenes.setEnvironment(scene, try renderer.environments.createSky(sky_desc), 1);
    renderer.scenes.setSun(scene, gfx.skySun(sky_desc));

    const sponza = try renderer.models.load("examples/assets/world/Sponza.glb");
    _ = try renderer.entities.spawn(scene, .{ .model = sponza });
    const helmet = try renderer.models.load("examples/assets/DamagedHelmet.glb");
    _ = try renderer.entities.spawn(scene, .{ .model = helmet, .transform = math.mul(math.translation(.{ 0.5, 1.3, -0.2 }), math.mul(math.rotationY(1.2), math.mul(math.rotationX(std.math.pi * 0.5), math.uniformScaling(0.7)))) });

    var sphere_positions: [helpers.sphere_vertex_count][3]f32 = undefined;
    var sphere_normals: [helpers.sphere_vertex_count][3]f32 = undefined;
    var sphere_indices: [helpers.sphere_index_count]u32 = undefined;
    helpers.sphereMesh(0.55, &sphere_positions, &sphere_normals, &sphere_indices);
    const mirror = try renderer.models.create(&.{.{ .positions = &sphere_positions, .normals = &sphere_normals, .indices = &sphere_indices, .material = .{ .base_color = .{ 0.95, 0.95, 0.95, 1 }, .metallic = 1, .roughness = 0.03 } }});
    const polished = try renderer.models.create(&.{.{ .positions = &sphere_positions, .normals = &sphere_normals, .indices = &sphere_indices, .material = .{ .base_color = .{ 0.75, 0.12, 0.1, 1 }, .metallic = 0, .roughness = 0.12 } }});
    _ = try renderer.entities.spawn(scene, .{ .model = mirror, .transform = math.translation(.{ 2.6, 0.55, 0.9 }) });
    _ = try renderer.entities.spawn(scene, .{ .model = polished, .transform = math.translation(.{ 2.4, 0.55, -1.2 }) });
    var box_positions: [24][3]f32 = undefined;
    var box_indices: [36]u32 = undefined;
    helpers.boxMesh(.{ 0.12, 0.7, 0.12 }, &box_positions, &box_indices);
    const glow = try renderer.models.create(&.{.{ .positions = &box_positions, .indices = &box_indices, .material = .{ .base_color = .{ 0, 0, 0, 1 }, .emissive = .{ 2, 9, 14 }, .metallic = 0, .roughness = 0.5 } }});
    _ = try renderer.entities.spawn(scene, .{ .model = glow, .transform = math.translation(.{ -2.2, 0.7, 0.6 }) });
    try renderer.waitUntilLoaded();

    const cameras = [_][2]math.Vec3{
        .{ .{ 6.5, 1.9, 1.5 }, .{ 0.0, 1.3, -0.2 } },
        .{ .{ -7.5, 2.4, -0.4 }, .{ 2.0, 1.6, 0.0 } },
        .{ .{ 4.6, 1.1, -0.2 }, .{ 2.5, 0.6, 0.4 } },
    };
    var camera: usize = 0;
    var bounce_light = true;
    var traced_reflections = true;
    var traced_shadows = true;
    var bounces: u32 = 4;
    var lamp_moving = true;
    var lamp_clock: f32 = 0;

    var list = gfx.DrawList.init(init.gpa);
    defer list.deinit();
    const font = renderer.fonts.default();
    var hud_buffer: [160]u8 = undefined;
    var count_buffer: [48]u8 = undefined;

    while (stage.begin()) |tick| {
        if (stage.keyPressed(glfw.GLFW_KEY_1)) bounce_light = !bounce_light;
        if (stage.keyPressed(glfw.GLFW_KEY_2)) traced_reflections = !traced_reflections;
        if (stage.keyPressed(glfw.GLFW_KEY_3)) traced_shadows = !traced_shadows;
        if (stage.keyPressed(glfw.GLFW_KEY_P)) path_traced = !path_traced;
        if (stage.keyPressed(glfw.GLFW_KEY_D)) dlss = !dlss;
        if (stage.keyPressed(glfw.GLFW_KEY_UP)) bounces = @min(bounces + 1, 16);
        if (stage.keyPressed(glfw.GLFW_KEY_DOWN)) bounces = @max(bounces - 1, 1);
        if (stage.keyPressed(glfw.GLFW_KEY_C)) camera = (camera + 1) % cameras.len;
        if (stage.keyPressed(glfw.GLFW_KEY_SPACE)) lamp_moving = !lamp_moving;
        if (lamp_moving) lamp_clock += tick.dt;

        try renderer.scenes.setLights(scene, &.{.{
            .position = .{ 1.5 + @sin(lamp_clock * 0.5) * 2.5, 2.2, @cos(lamp_clock * 0.37) * 0.9 },
            .color = .{ 1.0, 0.82, 0.6 },
            .intensity = 26,
            .range = 12,
            .source_radius = 0.25,
            .cast_shadows = true,
        }});

        list.clear();
        const stats = renderer.getStats();
        try list.rect(.{ .x = 12, .y = 12, .width = 520, .height = 188 }, gfx.Color.rgba(10, 12, 20, 190));
        try list.text(font, try std.fmt.bufPrint(&hud_buffer, "{d:.0} fps · gpu {d:.2} ms", .{ stage.fps, stage.gpu_ms }), .{ 24, 20 }, .{ .size = 17 });
        try list.text(font, switch (support) {
            .hardware => "This GPU traces rays: they go through its ray tracing.",
            .shader => "No ray tracing in use: fallbacks, and path tracing in a shader.",
            .unavailable => "No ray tracing here.",
        }, .{ 24, 44 }, .{ .size = 14, .color = if (hardware) gfx.Color.hex(0x3ddc97) else gfx.Color.hex(0xffd23f) });
        const rows = [_]struct { key: []const u8, label: []const u8, on: bool, state: []const u8 }{
            .{ .key = "1", .label = "bounce light", .on = bounce_light and hardware, .state = if (!hardware) "needs ray tracing" else if (bounce_light) "traced probes" else "sky light only" },
            .{ .key = "2", .label = "reflections", .on = traced_reflections and hardware, .state = if (!hardware) "screen only" else if (traced_reflections) "screen, then traced" else "screen only" },
            .{ .key = "3", .label = "lamp shadows", .on = traced_shadows and hardware, .state = if (!hardware) "shadow map" else if (traced_shadows) "traced, soft" else "shadow map" },
            .{ .key = "P", .label = "path tracing", .on = path_traced, .state = if (!path_traced) "off" else try std.fmt.bufPrint(&count_buffer, "{d} bounces · {d} frames", .{ bounces, stats.path_traced_frames }) },
            .{ .key = "D", .label = "DLSS", .on = dlss and (if (path_traced) dlss_support.ray_reconstruction else dlss_support.super_resolution), .state = if (!dlss) "off" else if (path_traced) (if (dlss_support.ray_reconstruction) "ray reconstruction" else "needs `zig build dlss-sdk` and an NVIDIA GPU") else if (dlss_support.super_resolution) "antialiasing" else "needs `zig build dlss-sdk` and an NVIDIA GPU" },
        };
        for (rows, 0..) |row, index| {
            const y = 70 + 20 * @as(f32, @floatFromInt(index));
            try list.text(font, row.key, .{ 24, y }, .{ .size = 14, .color = gfx.Color.hex(0x9aa7d0) });
            try list.text(font, row.label, .{ 52, y }, .{ .size = 14 });
            try list.text(font, row.state, .{ 190, y }, .{ .size = 14, .color = if (row.on) gfx.Color.hex(0x3ddc97) else gfx.Color.hex(0x7c8499) });
        }
        try list.text(font, "C camera · Up/Down bounces · Space lamp", .{ 24, 174 }, .{ .size = 13, .color = gfx.Color.hex(0x9aa7d0) });

        const drift: math.Vec3 = if (drifting) .{ (@cos(tick.time * 1.2) - 1) * 0.4, @sin(tick.time * 0.43) * 0.25, 0 } else .{ 0, 0, 0 };
        try stage.end(try renderer.render(.{
            .views = &.{.{
                .scene = scene,
                .camera = gfx.Camera.lookAt(math.add(cameras[camera][0], drift), cameras[camera][1]),
                .draw_lists = &.{&list},
                .target = stage.target(),
                .settings = .{
                    .shadow_distance = 40,
                    .global_illumination = bounce_light,
                    .reflection_ray_tracing = traced_reflections,
                    .ray_traced_light_shadows = traced_shadows,
                    .path_tracing = path_traced,
                    .path_tracing_bounces = bounces,
                    .upscaling = if (dlss) .dlss else .temporal,
                },
            }},
            .delta_time = tick.dt,
        }));
    }
    try stage.finish();
}
