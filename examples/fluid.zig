//! Simulated smoke and fire: a 3D fluid standing in the scene, and a 2D
//! one drawn as a picture in the corner.
//!
//!   F        fire on or off (fuel at the source)
//!   G        smoke on or off
//!   Left/Right  wind
//!   Up/Down  swirl (vorticity) up or down
//!   B        box sealed or open
//!   R        empty the fluid
//!   A/D      orbit
//!
//! `--scene-obstacles 1` lets the fluid find the ball by itself;
//! `--sharp-velocity 1` turns on error-corrected advection of the flow.
//!
//! `--frames N`, `--screenshot file.png`.
const std = @import("std");
const gfx = @import("limn");
const math = gfx.math;
const glfw = @import("glfw");
const Stage = @import("window").Stage;
const boxMesh = @import("window").boxMesh;

pub fn main(init: std.process.Init) !void {
    var stage = try Stage.create(init, "Limn fluid", .{});
    const renderer = stage.renderer;
    const scene = try renderer.createScene();
    const sky = gfx.SkyDesc{ .sun_direction = .{ -0.55, -0.6, -0.4 } };
    renderer.setSun(scene, gfx.skySun(sky));
    renderer.setEnvironment(scene, try renderer.createSky(sky), 1);

    var positions: [3][24][3]f32 = undefined;
    var indices: [3][36]u32 = undefined;
    boxMesh(.{ 30, 0.25, 30 }, &positions[0], &indices[0]);
    boxMesh(.{ 0.55, 0.12, 0.55 }, &positions[1], &indices[1]);
    boxMesh(.{ 0.5, 1.4, 0.5 }, &positions[2], &indices[2]);
    const ground = try renderer.createModel(&.{.{ .positions = &positions[0], .indices = &indices[0], .material = .{ .base_color = .{ 0.3, 0.3, 0.32, 1 }, .metallic = 0, .roughness = 0.85 } }});
    const hearth = try renderer.createModel(&.{.{ .positions = &positions[1], .indices = &indices[1], .material = .{ .base_color = .{ 0.12, 0.1, 0.09, 1 }, .metallic = 0, .roughness = 0.9 } }});
    const pillar = try renderer.createModel(&.{.{ .positions = &positions[2], .indices = &indices[2], .material = .{ .base_color = .{ 0.7, 0.66, 0.6, 1 }, .metallic = 0, .roughness = 0.7 } }});
    _ = try renderer.spawn(scene, .{ .model = ground, .transform = math.translation(.{ 0, -0.25, 0 }) });
    _ = try renderer.spawn(scene, .{ .model = hearth, .transform = math.translation(.{ 0, 0.12, 0 }) });
    _ = try renderer.spawn(scene, .{ .model = pillar, .transform = math.translation(.{ -3.2, 1.4, -1.5 }) });
    _ = try renderer.spawn(scene, .{ .model = pillar, .transform = math.translation(.{ 3.0, 1.4, -2.2 }) });
    // A ball hung in the flames; the fluid is told about it below.
    const helpers = @import("window");
    var ball_positions: [helpers.sphere_vertex_count][3]f32 = undefined;
    var ball_normals: [helpers.sphere_vertex_count][3]f32 = undefined;
    var ball_indices: [helpers.sphere_index_count]u32 = undefined;
    helpers.sphereMesh(0.45, &ball_positions, &ball_normals, &ball_indices);
    const ball = try renderer.createModel(&.{.{ .positions = &ball_positions, .normals = &ball_normals, .indices = &ball_indices, .material = .{ .base_color = .{ 0.2, 0.2, 0.22, 1 }, .metallic = 1, .roughness = 0.35 } }});
    _ = try renderer.spawn(scene, .{ .model = ball, .transform = math.translation(.{ 0, 2.6, 0 }) });
    try renderer.waitUntilLoaded();

    // The fire: a box 4 wide and 6 tall standing on the hearth.
    // `--scene-obstacles 1`: instead of describing the ball to the fluid,
    // let it find the scene's geometry by itself.
    var scene_obstacles = false;
    // `--sharp-velocity 1`: error-corrected advection for the flow too.
    var sharp_velocity = false;
    var arguments = try init.minimal.args.iterateAllocator(init.gpa);
    defer arguments.deinit();
    while (arguments.next()) |argument| {
        if (std.mem.eql(u8, argument, "--scene-obstacles")) scene_obstacles = true;
        if (std.mem.eql(u8, argument, "--sharp-velocity")) sharp_velocity = true;
    }
    var fire_on = true;
    var smoke_on = true;
    var desc = gfx.FluidDesc{
        .transform = math.mul(math.translation(.{ 0, 3.24, 0 }), math.scaling(.{ 4, 6, 4 })),
        // The ball, in the box's own coordinates.
        .obstacles = &.{.{ .sphere = .{ .center = .{ 0.5, (2.6 - 0.24) / 6.0, 0.5 }, .radius = 0.45 / 6.0 } }},
    };
    if (scene_obstacles) {
        desc.obstacles = &.{};
        desc.scene_obstacles = true;
    }
    desc.sharp_velocity = sharp_velocity;
    // The corrected flow keeps its own swirls; it needs far less put back.
    if (sharp_velocity) desc.vorticity = 4;
    const fluid = try renderer.createFluid(scene, desc);
    // The same solver in 2D, shown as a picture.
    const flat = try renderer.createFluid(scene, .{
        .resolution = .{ 128, 128, 1 },
        // Out of sight below the ground: only its picture is used.
        .transform = math.mul(math.translation(.{ 0, -50, 0 }), math.scaling(.{ 1, 1, 0.3 })),
        .sources = &.{.{ .position = .{ 0.5, 0.06, 0.5 }, .radius = 0.06, .velocity = .{ 0, 0.6, 0 }, .fuel = 6, .temperature = 6 }},
        .vorticity = 20,
        .absorption = 14,
        // Only its picture is shown; it need not light anything.
        .light = 0,
    });
    const flat_picture = try renderer.fluidImage(flat);
    // Embers: particles that ride the fire's flow, streak, and bounce off
    // the ground when they fall out of it.
    _ = try renderer.createEmitter(scene, .{
        .position = .{ 0, 0.5, 0 },
        .radius = 0.25,
        .capacity = 512,
        .rate = 120,
        .lifetime = .{ 1.5, 3.5 },
        .spread = 0.6,
        .speed = .{ 0.5, 1.5 },
        .gravity = .{ 0, -1.2, 0 },
        .drag = 0.3,
        .size = .{ 0.07, 0.02 },
        .color_start = .{ 8, 3.2, 0.6, 1 },
        .color_end = .{ 3, 0.4, 0.05, 0 },
        .blend = .additive,
        .lit = false,
        .fluid = fluid,
        .fluid_follow = 4,
        .collide = true,
        .stretch = 0.03,
    });

    var list = gfx.DrawList.init(init.gpa);
    defer list.deinit();
    const font = renderer.defaultFont();
    var orbit: f32 = 0.4;
    var wind: f32 = 0;
    var hud_buffer: [200]u8 = undefined;

    while (stage.begin()) |tick| {
        if (stage.keyPressed(glfw.GLFW_KEY_F)) fire_on = !fire_on;
        if (stage.keyPressed(glfw.GLFW_KEY_G)) smoke_on = !smoke_on;
        if (stage.keyPressed(glfw.GLFW_KEY_B)) desc.walls = if (desc.walls == .closed) .floor else .closed;
        if (stage.keyPressed(glfw.GLFW_KEY_R)) renderer.resetFluid(fluid);
        if (stage.keyDown(glfw.GLFW_KEY_RIGHT)) wind = @min(wind + tick.dt * 0.4, 0.6);
        if (stage.keyDown(glfw.GLFW_KEY_LEFT)) wind = @max(wind - tick.dt * 0.4, -0.6);
        if (stage.keyDown(glfw.GLFW_KEY_UP)) desc.vorticity = @min(desc.vorticity + tick.dt * 10, 40);
        if (stage.keyDown(glfw.GLFW_KEY_DOWN)) desc.vorticity = @max(desc.vorticity - tick.dt * 10, 0);
        if (stage.keyDown(glfw.GLFW_KEY_A)) orbit -= tick.dt * 0.8;
        if (stage.keyDown(glfw.GLFW_KEY_D)) orbit += tick.dt * 0.8;
        orbit += tick.dt * 0.05;

        desc.wind = .{ wind, 0, 0 };
        // The source flickers a little, as a real fire's base does.
        const flicker = 1 + 0.25 * @sin(tick.time * 9.0) * @sin(tick.time * 5.3);
        desc.sources = &.{.{
            .position = .{ 0.5 + 0.02 * @sin(tick.time * 2.1), 0.05, 0.5 + 0.02 * @cos(tick.time * 1.7) },
            .radius = 0.07,
            .velocity = .{ 0, 0.45, 0 },
            .fuel = if (fire_on) 7 * flicker else 0,
            .temperature = if (fire_on) 7 else 0,
            .smoke = if (smoke_on and !fire_on) 4 else 0,
        }};
        desc.soot = if (smoke_on) 0.6 else 0;
        try renderer.setFluid(fluid, desc);

        list.clear();
        const stats = renderer.getStats();
        try list.rect(.{ .x = 12, .y = 12, .width = 440, .height = 100 }, gfx.Color.rgba(10, 12, 20, 180));
        try list.text(font, try std.fmt.bufPrint(&hud_buffer, "{d:.0} fps · gpu {d:.2} ms · cpu {d:.2} ms\nswirl {d:.0} · wind {d:.2}", .{
            stage.fps, stage.gpu_ms, stats.cpu_ms, desc.vorticity, wind,
        }), .{ 24, 20 }, .{ .size = 16 });
        const on = gfx.Color.hex(0x3ddc97);
        const off = gfx.Color.hex(0x7c8499);
        try list.text(font, "fire", .{ 24, 66 }, .{ .size = 14 });
        try list.text(font, if (fire_on) "on" else "off", .{ 56, 66 }, .{ .size = 14, .color = if (fire_on) on else off });
        try list.text(font, "smoke", .{ 100, 66 }, .{ .size = 14 });
        try list.text(font, if (smoke_on) "on" else "off", .{ 148, 66 }, .{ .size = 14, .color = if (smoke_on) on else off });
        try list.text(font, "box", .{ 192, 66 }, .{ .size = 14 });
        try list.text(font, if (desc.walls == .closed) "sealed" else "open", .{ 222, 66 }, .{ .size = 14, .color = if (desc.walls == .closed) on else off });
        try list.text(font, "F fire · G smoke · B box · R empty · arrows wind and swirl · A/D orbit", .{ 24, 88 }, .{ .size = 13, .color = gfx.Color.hex(0x9aa7d0) });
        // The 2D fluid, as a picture.
        const panel = gfx.Rect{ .x = @as(f32, @floatFromInt(tick.size[0])) - 268, .y = 12, .width = 256, .height = 256 };
        try list.rect(panel, gfx.Color.rgba(6, 7, 12, 230));
        try list.image(flat_picture, panel, .{});
        try list.text(font, "2D fluid (fluidImage)", .{ panel.x + 8, panel.y + 6 }, .{ .size = 13, .color = gfx.Color.hex(0x9aa7d0) });

        const eye = math.Vec3{ @sin(orbit) * 11, 3.6, @cos(orbit) * 11 };
        try stage.end(try renderer.render(.{
            .views = &.{.{
                .scene = scene,
                .camera = gfx.Camera.lookAt(eye, .{ 0, 2.6, 0 }),
                .draw_lists = &.{&list},
                .target = stage.target(),
                .settings = .{ .shadow_distance = 60, .global_illumination = scene_obstacles },
            }},
            .delta_time = tick.dt,
        }));
    }
    try stage.finish();
}
