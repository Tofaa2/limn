//! Simulated smoke and fire: a 3D fluid standing in the scene, and a 2D
//! one drawn as a picture in the corner.
//!
//!   1-5      what the fire does: a ball hung in it, the ball swinging
//!            through it, a whirl, two jets meeting, smoke rings
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
//! `--act N` starts with act N. `--frames N`, `--screenshot file.png`.
const std = @import("std");
const gfx = @import("limn");
const math = gfx.math;
const glfw = @import("glfw");
const Stage = @import("window").Stage;
const boxMesh = @import("window").boxMesh;

/// What the fire is made to do; the number keys pick one.
const Act = enum {
    /// A ball hung still in the flames, which wrap around it.
    hung,
    /// The ball swings through the fire: the flames part around it and
    /// trail after it.
    pendulum,
    /// Four burners blowing around a circle wind the flames into a whirl
    /// about the ball.
    whirl,
    /// Two jets from either side meet at the ball and flatten against it.
    jets,
    /// No fire: puffs of smoke roll up into rings and break on the ball.
    rings,

    fn title(act: Act) []const u8 {
        return switch (act) {
            .hung => "1 ball in the flames",
            .pendulum => "2 swinging ball",
            .whirl => "3 fire whirl",
            .jets => "4 meeting jets",
            .rings => "5 smoke rings",
        };
    }

    /// How strongly swirls are put back into the flow to begin with.
    fn swirl(act: Act) f32 {
        return switch (act) {
            .hung, .pendulum => 12,
            .whirl => 5,
            .jets => 16,
            .rings => 3,
        };
    }
};

/// The fluid's box: 4 wide and deep and 6 tall, standing on the hearth.
const box_size = math.Vec3{ 4, 6, 4 };
const box_floor = 0.24;
const ball_radius = 0.45;

/// A point of the world in the box's own coordinates, 0..1 along each axis.
fn inBox(world: math.Vec3) math.Vec3 {
    return .{ world[0] / box_size[0] + 0.5, (world[1] - box_floor) / box_size[1], world[2] / box_size[2] + 0.5 };
}

/// Where the ball is at `time`.
fn ballAt(act: Act, time: f32) math.Vec3 {
    if (act != .pendulum) return .{ 0, 2.6, 0 };
    const swing = @sin(time * 1.6);
    return .{ 1.05 * swing, 2.2 + 0.5 * swing * swing, 0 };
}

/// The burners of an act at `time`, in the box's coordinates; returns how
/// many of `sources` it filled.
fn burners(act: Act, time: f32, fire_on: bool, smoke_on: bool, sources: *[4]gfx.FluidSource) usize {
    const flicker = 1 + 0.25 * @sin(time * 9.0) * @sin(time * 5.3);
    const fuel: f32 = if (fire_on) 7 * flicker else 0;
    const heat: f32 = if (fire_on) 7 else 0;
    const smoke: f32 = if (smoke_on and !fire_on) 4 else 0;
    switch (act) {
        .hung, .pendulum => {
            sources[0] = .{
                .position = .{ 0.5 + 0.02 * @sin(time * 2.1), 0.05, 0.5 + 0.02 * @cos(time * 1.7) },
                .radius = 0.07,
                .velocity = .{ 0, 0.45, 0 },
                .fuel = fuel,
                .temperature = heat,
                .smoke = smoke,
            };
            return 1;
        },
        .whirl => {
            for (sources, 0..) |*source, index| {
                const angle = time * 0.6 + @as(f32, @floatFromInt(index)) * std.math.pi / 2.0;
                const around = [2]f32{ @cos(angle), @sin(angle) };
                source.* = .{
                    .position = .{ 0.5 + 0.17 * around[0], 0.05, 0.5 + 0.17 * around[1] },
                    .radius = 0.05,
                    .velocity = .{ -0.75 * around[1], 0.4, 0.75 * around[0] },
                    .fuel = fuel * 0.6,
                    .temperature = heat * 0.6,
                    .smoke = smoke,
                };
            }
            return 4;
        },
        .jets => {
            const height = inBox(ballAt(act, time))[1];
            for (sources[0..2], [2]f32{ 1, -1 }) |*source, side| {
                source.* = .{
                    .position = .{ 0.5 - 0.36 * side, height - 0.02, 0.5 },
                    .radius = 0.045,
                    .velocity = .{ 1.1 * side, 0.05, 0 },
                    .fuel = fuel * 0.9,
                    .temperature = heat * 0.7,
                    .smoke = smoke,
                };
            }
            return 2;
        },
        .rings => {
            const puffing = @mod(time, 1.3) < 0.14;
            sources[0] = .{
                .position = .{ 0.5, 0.07, 0.5 },
                .radius = 0.055,
                .velocity = .{ 0, if (puffing) 2.2 else 0, 0 },
                .smoke = if (puffing and smoke_on) 22 else 0,
                .temperature = if (puffing) 1.2 else 0,
            };
            return 1;
        },
    }
}

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
    const helpers = @import("window");
    var ball_positions: [helpers.sphere_vertex_count][3]f32 = undefined;
    var ball_normals: [helpers.sphere_vertex_count][3]f32 = undefined;
    var ball_indices: [helpers.sphere_index_count]u32 = undefined;
    helpers.sphereMesh(ball_radius, &ball_positions, &ball_normals, &ball_indices);
    const ball = try renderer.createModel(&.{.{ .positions = &ball_positions, .normals = &ball_normals, .indices = &ball_indices, .material = .{ .base_color = .{ 0.2, 0.2, 0.22, 1 }, .metallic = 1, .roughness = 0.35 } }});
    const ball_entity = try renderer.spawn(scene, .{ .model = ball, .transform = math.translation(ballAt(.hung, 0)) });
    try renderer.waitUntilLoaded();

    var scene_obstacles = false;
    var sharp_velocity = false;
    var act = Act.hung;
    var arguments = try init.minimal.args.iterateAllocator(init.gpa);
    defer arguments.deinit();
    while (arguments.next()) |argument| {
        if (std.mem.eql(u8, argument, "--scene-obstacles")) scene_obstacles = true;
        if (std.mem.eql(u8, argument, "--sharp-velocity")) sharp_velocity = true;
        if (std.mem.eql(u8, argument, "--act")) {
            const number = try std.fmt.parseInt(usize, arguments.next() orelse return error.MissingArgument, 10);
            if (number < 1 or number > std.enums.values(Act).len) return error.InvalidArgument;
            act = std.enums.values(Act)[number - 1];
        }
    }
    var fire_on = true;
    var smoke_on = true;
    var desc = gfx.FluidDesc{
        .transform = math.mul(math.translation(.{ 0, box_floor + box_size[1] / 2.0, 0 }), math.scaling(box_size)),
        .obstacles = &.{.{ .sphere = .{ .center = inBox(ballAt(act, 0)), .radius = ball_radius / box_size[1] } }},
        .scene_obstacles = scene_obstacles,
        .sharp_velocity = sharp_velocity,
    };
    if (scene_obstacles) desc.obstacles = &.{};
    desc.vorticity = if (sharp_velocity) 4 else act.swirl();
    const fluid = try renderer.createFluid(scene, desc);
    const flat = try renderer.createFluid(scene, .{
        .resolution = .{ 128, 128, 1 },
        .transform = math.mul(math.translation(.{ 0, -50, 0 }), math.scaling(.{ 1, 1, 0.3 })),
        .sources = &.{.{ .position = .{ 0.5, 0.06, 0.5 }, .radius = 0.06, .velocity = .{ 0, 0.6, 0 }, .fuel = 6, .temperature = 6 }},
        .vorticity = 20,
        .absorption = 14,
        .light = 0,
    });
    const flat_picture = try renderer.fluidImage(flat);
    var ember_desc = gfx.EmitterDesc{
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
    };
    const ember_rate = ember_desc.rate;
    if (act == .rings) ember_desc.rate = 0;
    const embers = try renderer.createEmitter(scene, ember_desc);

    var list = gfx.DrawList.init(init.gpa);
    defer list.deinit();
    const font = renderer.defaultFont();
    var orbit: f32 = 0.4;
    var wind: f32 = 0;
    var hud_buffer: [200]u8 = undefined;

    var sources: [4]gfx.FluidSource = undefined;
    while (stage.begin()) |tick| {
        for (std.enums.values(Act), 0..) |chosen, index| {
            if (chosen == act or !stage.keyPressed(glfw.GLFW_KEY_1 + @as(c_int, @intCast(index)))) continue;
            act = chosen;
            desc.vorticity = if (sharp_velocity) 4 else act.swirl();
            renderer.resetFluid(fluid);
            ember_desc.rate = if (act == .rings) 0 else ember_rate;
            renderer.setEmitter(embers, ember_desc);
        }
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
        desc.sources = sources[0..burners(act, tick.time, fire_on, smoke_on, &sources)];
        desc.soot = if (smoke_on) 0.6 else 0;
        desc.smoke_loss = if (act == .rings) 0.12 else 0.45;
        desc.weight = if (act == .rings) 0 else 0.1;
        const ball_at = ballAt(act, tick.time);
        const ball_obstacle = [1]gfx.FluidObstacle{.{ .sphere = .{ .center = inBox(ball_at), .radius = ball_radius / box_size[1] } }};
        if (!scene_obstacles) desc.obstacles = &ball_obstacle;
        renderer.setTransform(ball_entity, math.translation(ball_at));
        try renderer.setFluid(fluid, desc);

        list.clear();
        const stats = renderer.getStats();
        try list.rect(.{ .x = 12, .y = 12, .width = 520, .height = 100 }, gfx.Color.rgba(10, 12, 20, 180));
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
        try list.text(font, act.title(), .{ 290, 66 }, .{ .size = 14, .color = on });
        try list.text(font, "1-5 acts · F fire · G smoke · B box · R empty · arrows wind and swirl · A/D orbit", .{ 24, 88 }, .{ .size = 13, .color = gfx.Color.hex(0x9aa7d0) });
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
