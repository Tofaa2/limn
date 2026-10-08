//! Path tracing: the same room drawn the usual way and by following
//! light through it. The traced picture starts noisy and clears as frames
//! are gathered, for as long as nothing moves; soft shadows, light
//! bouncing between colored walls and reflections of reflections come
//! out of the one method rather than from a technique each.
//!
//! The renderer asks the GPU whether it can trace rays. If it can, they
//! are traced by its hardware; if not, by a shader walking a tree built
//! on the CPU, which gives the same picture more slowly. `--software 1`
//! does without the hardware even where it is there.
//!
//!   P        path tracing on and off
//!   Up/Down  bounces
//!   A/D      orbit the camera (the picture starts over)
//!
//! `--orbit 1` keeps the camera circling. `--frames N`,
//! `--screenshot file.png`.
const std = @import("std");
const gfx = @import("limn");
const math = gfx.math;
const glfw = @import("glfw");
const helpers = @import("window");
const Stage = helpers.Stage;

pub fn main(init: std.process.Init) !void {
    var options = gfx.Options{ .path_tracing_fallback = true };
    var traced = true;
    var orbiting = false;
    {
        var arguments = try init.minimal.args.iterateAllocator(init.gpa);
        defer arguments.deinit();
        while (arguments.next()) |argument| {
            if (std.mem.eql(u8, argument, "--software")) options.ray_tracing = false;
            if (std.mem.eql(u8, argument, "--raster")) traced = false;
            if (std.mem.eql(u8, argument, "--orbit")) orbiting = true;
        }
    }
    var stage = try Stage.create(init, "Limn path tracing", options);
    const renderer = stage.renderer;
    const scene = try renderer.createScene();

    const sky_desc = gfx.SkyDesc{ .sun_direction = .{ -0.35, -0.8, -0.45 } };
    renderer.setEnvironment(scene, try renderer.createSky(sky_desc), 1);
    renderer.setSun(scene, gfx.skySun(sky_desc));

    var box_positions: [24][3]f32 = undefined;
    var box_indices: [36]u32 = undefined;
    helpers.boxMesh(.{ 0.5, 0.5, 0.5 }, &box_positions, &box_indices);
    const Wall = struct { color: [4]f32, at: math.Vec3, size: math.Vec3, roughness: f32 = 0.9 };
    const walls = [_]Wall{
        .{ .color = .{ 0.75, 0.75, 0.72, 1 }, .at = .{ 0, -0.1, 0 }, .size = .{ 9, 0.2, 7 }, .roughness = 0.35 },
        .{ .color = .{ 0.75, 0.1, 0.08, 1 }, .at = .{ -4.4, 1.6, 0 }, .size = .{ 0.2, 3.2, 7 } },
        .{ .color = .{ 0.1, 0.6, 0.12, 1 }, .at = .{ 4.4, 1.6, 0 }, .size = .{ 0.2, 3.2, 7 } },
        .{ .color = .{ 0.78, 0.78, 0.76, 1 }, .at = .{ 0, 1.6, -3.4 }, .size = .{ 9, 3.2, 0.2 } },
        .{ .color = .{ 0.78, 0.78, 0.76, 1 }, .at = .{ 1.6, 3.3, -0.8 }, .size = .{ 5.8, 0.2, 5.4 } },
        .{ .color = .{ 0.8, 0.8, 0.8, 1 }, .at = .{ 2.4, 0.75, -1.4 }, .size = .{ 1.2, 1.5, 1.2 } },
    };
    for (walls) |wall| {
        const model = try renderer.createModel(&.{.{ .positions = &box_positions, .indices = &box_indices, .material = .{ .base_color = wall.color, .metallic = 0, .roughness = wall.roughness } }});
        _ = try renderer.spawn(scene, .{ .model = model, .transform = math.mul(math.translation(wall.at), math.scaling(wall.size)) });
    }
    const bar = try renderer.createModel(&.{.{ .positions = &box_positions, .indices = &box_indices, .material = .{ .base_color = .{ 0, 0, 0, 1 }, .emissive = .{ 9, 6.5, 3.5 }, .metallic = 0, .roughness = 0.5 } }});
    _ = try renderer.spawn(scene, .{ .model = bar, .transform = math.mul(math.translation(.{ 2.6, 3.0, -1.2 }), math.scaling(.{ 2.4, 0.08, 0.3 })) });

    var sphere_positions: [helpers.sphere_vertex_count][3]f32 = undefined;
    var sphere_normals: [helpers.sphere_vertex_count][3]f32 = undefined;
    var sphere_indices: [helpers.sphere_index_count]u32 = undefined;
    helpers.sphereMesh(0.7, &sphere_positions, &sphere_normals, &sphere_indices);
    const Ball = struct { material: gfx.Material, at: math.Vec3 };
    const balls = [_]Ball{
        .{ .material = .{ .base_color = .{ 0.95, 0.95, 0.95, 1 }, .metallic = 1, .roughness = 0.03 }, .at = .{ -2.3, 0.7, -0.6 } },
        .{ .material = .{ .base_color = .{ 1.0, 0.77, 0.34, 1 }, .metallic = 1, .roughness = 0.25 }, .at = .{ -0.5, 0.7, 0.9 } },
        .{ .material = .{ .base_color = .{ 0.2, 0.35, 0.8, 1 }, .metallic = 0, .roughness = 0.15 }, .at = .{ 0.9, 0.7, -0.9 } },
    };
    for (balls) |ball| {
        const model = try renderer.createModel(&.{.{ .positions = &sphere_positions, .normals = &sphere_normals, .indices = &sphere_indices, .material = ball.material }});
        _ = try renderer.spawn(scene, .{ .model = model, .transform = math.translation(ball.at) });
    }
    const helmet = try renderer.loadModel("examples/assets/DamagedHelmet.glb");
    _ = try renderer.spawn(scene, .{ .model = helmet, .transform = math.mul(math.translation(.{ -3.0, 1.0, 1.8 }), math.mul(math.rotationY(0.9), math.mul(math.rotationX(std.math.pi * 0.5), math.uniformScaling(0.8)))) });
    try renderer.waitUntilLoaded();

    var list = gfx.DrawList.init(init.gpa);
    defer list.deinit();
    const font = renderer.defaultFont();
    var bounces: u32 = 5;
    var orbit: f32 = 0.2;
    var hud_buffer: [160]u8 = undefined;

    while (stage.begin()) |tick| {
        if (stage.keyPressed(glfw.GLFW_KEY_P)) traced = !traced;
        if (stage.keyPressed(glfw.GLFW_KEY_UP)) bounces = @min(bounces + 1, 16);
        if (stage.keyPressed(glfw.GLFW_KEY_DOWN)) bounces = @max(bounces - 1, 1);
        if (stage.keyDown(glfw.GLFW_KEY_A)) orbit -= tick.dt * 0.6;
        if (stage.keyDown(glfw.GLFW_KEY_D)) orbit += tick.dt * 0.6;
        if (orbiting) orbit += tick.dt * 0.35;

        list.clear();
        const stats = renderer.getStats();
        try list.rect(.{ .x = 12, .y = 12, .width = 560, .height = 58 }, gfx.Color.rgba(10, 12, 20, 180));
        const line = if (traced)
            try std.fmt.bufPrint(&hud_buffer, "{d:.0} fps · gpu {d:.2} ms · path traced by {s} · {d} bounces · {d} frames gathered", .{ stage.fps, stage.gpu_ms, switch (renderer.pathTracing()) {
                .hardware => "the GPU's ray tracing",
                .shader => "a shader",
                .unavailable => "nothing",
            }, bounces, stats.path_traced_frames })
        else
            try std.fmt.bufPrint(&hud_buffer, "{d:.0} fps · gpu {d:.2} ms · the usual picture", .{ stage.fps, stage.gpu_ms });
        try list.text(font, line, .{ 24, 20 }, .{ .size = 16 });
        try list.text(font, "P path tracing · Up/Down bounces · A/D orbit", .{ 24, 46 }, .{ .size = 13, .color = gfx.Color.hex(0x9aa7d0) });

        const eye = math.Vec3{ @sin(orbit) * 9.5, 3.0, @cos(orbit) * 9.5 };
        try stage.end(try renderer.render(.{
            .views = &.{.{
                .scene = scene,
                .camera = gfx.Camera.lookAt(eye, .{ 0, 1.1, -0.5 }),
                .draw_lists = &.{&list},
                .target = stage.target(),
                .settings = .{
                    .shadow_distance = 30,
                    .path_tracing = traced,
                    .path_tracing_bounces = bounces,
                },
            }},
            .delta_time = tick.dt,
        }));
    }
    try stage.finish();
}
