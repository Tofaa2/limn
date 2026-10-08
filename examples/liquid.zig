//! A volume of liquid: a block of water let go at one end of a tank, a
//! jet pouring in at the other, and a ball wading through.
//!
//!   A / D    orbit
//!   Space    start over
//!
//! `--frames N`, `--screenshot file.png`.
const std = @import("std");
const gfx = @import("limn");
const glfw = @import("glfw");
const math = gfx.math;
const helpers = @import("window");
const Stage = helpers.Stage;

pub fn main(init: std.process.Init) !void {
    var stage = try Stage.create(init, "Limn liquid", .{});
    const renderer = stage.renderer;
    const scene = try renderer.createScene();
    const sky = gfx.SkyDesc{ .sun_direction = .{ -0.45, -0.75, -0.5 } };
    renderer.setSun(scene, gfx.skySun(sky));
    const environment = try renderer.createSky(sky);
    renderer.setEnvironment(scene, environment, 1);

    var positions: [1][24][3]f32 = undefined;
    var indices: [1][36]u32 = undefined;
    helpers.boxMesh(.{ 0.5, 0.5, 0.5 }, &positions[0], &indices[0]);
    const stone = try renderer.createModel(&.{.{ .positions = &positions[0], .indices = &indices[0], .material = .{ .base_color = .{ 0.62, 0.6, 0.56, 1 }, .metallic = 0, .roughness = 0.8 } }});
    const ground = try renderer.createModel(&.{.{ .positions = &positions[0], .indices = &indices[0], .material = .{ .base_color = .{ 0.32, 0.34, 0.36, 1 }, .metallic = 0, .roughness = 0.9 } }});
    const Box = struct { model: gfx.Model, at: math.Vec3, size: math.Vec3 };
    const boxes = [_]Box{
        .{ .model = ground, .at = .{ 0, -0.1, 0 }, .size = .{ 16, 0.2, 16 } },
        .{ .model = stone, .at = .{ 0, 0.15, -1.1 }, .size = .{ 4.4, 0.3, 0.2 } },
        .{ .model = stone, .at = .{ 0, 0.15, 1.1 }, .size = .{ 4.4, 0.3, 0.2 } },
        .{ .model = stone, .at = .{ -2.1, 0.15, 0 }, .size = .{ 0.2, 0.3, 2.0 } },
        .{ .model = stone, .at = .{ 2.1, 0.15, 0 }, .size = .{ 0.2, 0.3, 2.0 } },
        .{ .model = stone, .at = .{ -0.6, 1.0, -1.8 }, .size = .{ 0.3, 2.0, 0.3 } },
        .{ .model = stone, .at = .{ 1.2, 0.5, -2.4 }, .size = .{ 0.3, 1.0, 0.3 } },
    };
    for (boxes) |box| _ = try renderer.spawn(scene, .{ .model = box.model, .transform = math.mul(math.translation(box.at), math.scaling(box.size)) });
    var ball_positions: [helpers.sphere_vertex_count][3]f32 = undefined;
    var ball_normals: [helpers.sphere_vertex_count][3]f32 = undefined;
    var ball_indices: [helpers.sphere_index_count]u32 = undefined;
    helpers.sphereMesh(0.3, &ball_positions, &ball_normals, &ball_indices);
    const ball_model = try renderer.createModel(&.{.{ .positions = &ball_positions, .normals = &ball_normals, .indices = &ball_indices, .material = .{ .base_color = .{ 0.9, 0.3, 0.12, 1 }, .metallic = 0, .roughness = 0.4 } }});
    const ball = try renderer.spawn(scene, .{ .model = ball_model, .transform = math.translation(.{ 0.6, 0.3, 0 }) });
    helpers.sphereMesh(0.7, &ball_positions, &ball_normals, &ball_indices);
    const mirror = try renderer.createModel(&.{.{ .positions = &ball_positions, .normals = &ball_normals, .indices = &ball_indices, .material = .{ .base_color = .{ 0.95, 0.95, 0.95, 1 }, .metallic = 1, .roughness = 0.03 } }});
    _ = try renderer.spawn(scene, .{ .model = mirror, .transform = math.translation(.{ 1.2, 1.7, -2.4 }) });
    try renderer.waitUntilLoaded();

    const desc = gfx.LiquidDesc{
        .transform = math.mul(math.translation(.{ 0, 1.25, 0 }), math.scaling(.{ 4, 2.5, 2 })),
        .capacity = 40000,
        .fill = .{ 0.3, 0.55, 1.0 },
        .sources = &.{.{ .position = .{ 1.7, 2.0, 0 }, .velocity = .{ -2.2, -0.3, 0 }, .radius = 0.12 }},
    };
    var liquid = try renderer.createLiquid(scene, desc);

    var list = gfx.DrawList.init(init.gpa);
    defer list.deinit();
    const font = renderer.defaultFont();
    var orbit: f32 = 0.5;
    var hud_buffer: [200]u8 = undefined;

    while (stage.begin()) |tick| {
        if (stage.keyDown(glfw.GLFW_KEY_A)) orbit -= tick.dt * 0.8;
        if (stage.keyDown(glfw.GLFW_KEY_D)) orbit += tick.dt * 0.8;
        if (stage.keyPressed(glfw.GLFW_KEY_SPACE)) {
            renderer.destroyLiquid(liquid);
            liquid = try renderer.createLiquid(scene, desc);
        }
        renderer.setTransform(ball, math.translation(.{ @sin(tick.time * 0.8) * 1.2, 0.35, 0 }));

        list.clear();
        try list.rect(.{ .x = 12, .y = 12, .width = 430, .height = 62 }, gfx.Color.rgba(10, 12, 20, 180));
        try list.text(font, try std.fmt.bufPrint(&hud_buffer, "{d:.0} fps · gpu {d:.2} ms · {d} particles", .{ stage.fps, stage.gpu_ms, renderer.liquidParticles(liquid) }), .{ 24, 22 }, .{ .size = 18 });
        try list.text(font, "Space start over · A/D orbit", .{ 24, 48 }, .{ .size = 13, .color = gfx.Color.hex(0x9aa7d0) });

        const eye = math.Vec3{ @sin(orbit) * 4.6, 2.1, @cos(orbit) * 4.6 };
        try stage.end(try renderer.render(.{
            .views = &.{.{
                .scene = scene,
                .camera = gfx.Camera.lookAt(eye, .{ 0, 0.9, 0 }),
                .draw_lists = &.{&list},
                .target = stage.target(),
                .settings = .{ .shadow_distance = 40 },
            }},
            .delta_time = tick.dt,
        }));
    }
    for (renderer.device.passTimings()) |timing| {
        if (std.mem.startsWith(u8, timing.name, "liquid")) std.log.info("gpu: {s} {d:.3} ms", .{ timing.name, timing.milliseconds });
    }
    try stage.finish();
}
