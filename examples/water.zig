//! A pool of simulated water: ripples spread, bounce off the edges and die
//! down; the surface mirrors the scene and shows the floor under it.
//!
//! A ball swims in circles and leaves a wake.
//!
//!   Space    drop something in at a random place
//!   R        rain on or off
//!   U        under the surface and back
//!   Up/Down  swell higher or lower
//!   M        murkier or clearer (hold)
//!   A/D      orbit
//!   T        hold to move the sun through the day
//!
//! `--dive 1`, `--frames N`, `--screenshot file.png`.
const std = @import("std");
const gfx = @import("limn");
const math = gfx.math;
const glfw = @import("glfw");
const Stage = @import("window").Stage;
const boxMesh = @import("window").boxMesh;

pub fn main(init: std.process.Init) !void {
    var stage = try Stage.create(init, "Limn water", .{});
    const renderer = stage.renderer;
    const scene = try renderer.scenes.create();
    var sun_height: f32 = 0.7;
    var sky = gfx.SkyDesc{ .sun_direction = .{ -0.5 * @cos(sun_height), -@sin(sun_height), -0.6 } };
    renderer.scenes.setSun(scene, gfx.skySun(sky));
    const environment = try renderer.environments.createSky(sky);
    renderer.scenes.setEnvironment(scene, environment, 1);

    var positions: [1][24][3]f32 = undefined;
    var indices: [1][36]u32 = undefined;
    boxMesh(.{ 0.5, 0.5, 0.5 }, &positions[0], &indices[0]);
    const stone = try renderer.models.create(&.{.{ .positions = &positions[0], .indices = &indices[0], .material = .{ .base_color = .{ 0.62, 0.6, 0.55, 1 }, .metallic = 0, .roughness = 0.8 } }});
    const tile = try renderer.models.create(&.{.{ .positions = &positions[0], .indices = &indices[0], .material = .{ .base_color = .{ 0.25, 0.45, 0.55, 1 }, .metallic = 0, .roughness = 0.5 } }});
    const red = try renderer.models.create(&.{.{ .positions = &positions[0], .indices = &indices[0], .material = .{ .base_color = .{ 0.75, 0.12, 0.08, 1 }, .metallic = 0, .roughness = 0.4 } }});
    const Box = struct { model: gfx.Model, at: math.Vec3, size: math.Vec3 };
    const boxes = [_]Box{
        .{ .model = tile, .at = .{ 0, -1.6, 0 }, .size = .{ 12, 0.2, 12 } },
        .{ .model = stone, .at = .{ 0, -0.9, -6.5 }, .size = .{ 14, 2.2, 1 } },
        .{ .model = stone, .at = .{ 0, -0.9, 6.5 }, .size = .{ 14, 2.2, 1 } },
        .{ .model = stone, .at = .{ -6.5, -0.9, 0 }, .size = .{ 1, 2.2, 12 } },
        .{ .model = stone, .at = .{ 6.5, -0.9, 0 }, .size = .{ 1, 2.2, 12 } },
        .{ .model = stone, .at = .{ -2.5, 0.2, -2.0 }, .size = .{ 0.9, 4.0, 0.9 } },
        .{ .model = stone, .at = .{ 2.8, 0.2, -3.0 }, .size = .{ 0.9, 4.0, 0.9 } },
        .{ .model = red, .at = .{ 1.0, -0.2, 1.5 }, .size = .{ 1.2, 1.2, 1.2 } },
        .{ .model = tile, .at = .{ -3.5, -1.2, 2.5 }, .size = .{ 1.5, 0.6, 1.5 } },
    };
    for (boxes) |box| _ = try renderer.entities.spawn(scene, .{ .model = box.model, .transform = math.mul(math.translation(box.at), math.scaling(box.size)) });
    const helpers = @import("window");
    var ball_positions: [helpers.sphere_vertex_count][3]f32 = undefined;
    var ball_normals: [helpers.sphere_vertex_count][3]f32 = undefined;
    var ball_indices: [helpers.sphere_index_count]u32 = undefined;
    helpers.sphereMesh(0.4, &ball_positions, &ball_normals, &ball_indices);
    const ball_model = try renderer.models.create(&.{.{ .positions = &ball_positions, .normals = &ball_normals, .indices = &ball_indices, .material = .{ .base_color = .{ 0.95, 0.75, 0.1, 1 }, .metallic = 0, .roughness = 0.3 } }});
    const ball = try renderer.entities.spawn(scene, .{ .model = ball_model, .transform = math.translation(.{ 3.6, -0.3, 0 }) });
    try renderer.waitUntilLoaded();

    var desc = gfx.WaterDesc{
        .transform = math.mul(math.translation(.{ 0, -0.25, 0 }), math.scaling(.{ 12, 1, 12 })),
        .rain = 6,
        .splashes = 1,
    };
    const water = try renderer.waters.create(scene, desc);

    var list = gfx.DrawList.init(init.gpa);
    defer list.deinit();
    const font = renderer.fonts.default();
    var orbit: f32 = 0.6;
    var random = std.Random.DefaultPrng.init(3);
    const rng = random.random();
    var hud_buffer: [200]u8 = undefined;
    var since_drop: f32 = 0;
    var dive = false;
    {
        var arguments = try init.minimal.args.iterateAllocator(init.gpa);
        defer arguments.deinit();
        while (arguments.next()) |argument| {
            if (std.mem.eql(u8, argument, "--dive")) dive = true;
        }
    }

    while (stage.begin()) |tick| {
        if (stage.keyPressed(glfw.GLFW_KEY_R)) desc.rain = if (desc.rain > 0) 0 else 6;
        if (stage.keyPressed(glfw.GLFW_KEY_U)) dive = !dive;
        if (stage.keyDown(glfw.GLFW_KEY_UP)) desc.swell = @min(desc.swell + tick.dt * 0.05, 0.25);
        if (stage.keyDown(glfw.GLFW_KEY_DOWN)) desc.swell = @max(desc.swell - tick.dt * 0.05, 0);
        if (stage.keyDown(glfw.GLFW_KEY_M)) desc.murk = if (desc.murk > 2.5) 0.1 else desc.murk * (1 + tick.dt);
        if (stage.keyDown(glfw.GLFW_KEY_A)) orbit -= tick.dt * 0.8;
        if (stage.keyDown(glfw.GLFW_KEY_D)) orbit += tick.dt * 0.8;
        orbit += tick.dt * 0.04;
        if (stage.keyDown(glfw.GLFW_KEY_T)) {
            sun_height = @mod(sun_height + tick.dt * 0.25, std.math.pi);
            sky.sun_direction = .{ -0.5 * @cos(sun_height), -@max(@sin(sun_height), -0.05), -0.6 };
            renderer.environments.setSky(environment, sky);
            renderer.scenes.setSun(scene, gfx.skySun(sky));
        }
        since_drop += tick.dt;
        if (stage.keyPressed(glfw.GLFW_KEY_SPACE) or since_drop > 0.9) {
            since_drop = 0;
            renderer.waters.addRipple(water, .{ (rng.float(f32) - 0.5) * 9, -0.25, (rng.float(f32) - 0.5) * 9 }, 0.45, 0.22);
        }
        renderer.entities.setTransform(ball, math.translation(.{ @cos(tick.time * 0.9) * 3.6, -0.3, @sin(tick.time * 0.9) * 3.6 }));
        try renderer.waters.set(water, desc);

        list.clear();
        const stats = renderer.getStats();
        try list.rect(.{ .x = 12, .y = 12, .width = 430, .height = 80 }, gfx.Color.rgba(10, 12, 20, 180));
        try list.text(font, try std.fmt.bufPrint(&hud_buffer, "{d:.0} fps · gpu {d:.2} ms · cpu {d:.2} ms\nrain {s} · swell {d:.2} m · murk {d:.2}", .{
            stage.fps, stage.gpu_ms, stats.cpu_ms, if (desc.rain > 0) "on" else "off", desc.swell, desc.murk,
        }), .{ 24, 20 }, .{ .size = 16 });
        try list.text(font, "Space drop · R rain · U dive · Up/Down swell · hold M murk · A/D orbit · hold T sun", .{ 24, 68 }, .{ .size = 13, .color = gfx.Color.hex(0x9aa7d0) });

        const eye = if (dive) math.Vec3{ @sin(orbit) * 4.5, -1.0, @cos(orbit) * 4.5 } else math.Vec3{ @sin(orbit) * 11, 2.6, @cos(orbit) * 11 };
        try stage.end(try renderer.render(.{
            .views = &.{.{
                .scene = scene,
                .camera = gfx.Camera.lookAt(eye, if (dive) .{ 0, -0.9, 0 } else .{ 0, -0.4, 0 }),
                .draw_lists = &.{&list},
                .target = stage.target(),
                .settings = .{ .shadow_distance = 50 },
            }},
            .delta_time = tick.dt,
        }));
    }
    try stage.finish();
}
