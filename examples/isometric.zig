//! A diorama seen through an orthographic camera: terraced blocks under a
//! low sun, and lamp-carrying markers drawn into the scene under bloom and
//! tone mapping, with name tags over it and a backdrop under it.
//!
//!   Q/E      turn the view a quarter
//!   Up/Down  zoom
//!   P        perspective camera, to compare
//!   Space    pause
//!
//! `--frames N`, `--screenshot file.png`.
const std = @import("std");
const gfx = @import("limn");
const math = gfx.math;
const glfw = @import("glfw");
const helpers = @import("window");
const Stage = helpers.Stage;

const side = 14;
const walker_names = [_][]const u8{ "Ada", "Brook", "Cyan", "Dove" };

fn terrace(x: f32, z: f32) f32 {
    const rolling = @sin(x * 0.55) * 1.1 + @cos(z * 0.45 + 0.6) * 1.1 + @sin((x + z) * 0.3) * 0.8;
    return @max(@round(rolling + 1.5) * 0.5, 0) + 0.5;
}

pub fn main(init: std.process.Init) !void {
    var stage = try Stage.create(init, "Limn isometric", .{});
    const renderer = stage.renderer;
    const scene = try renderer.scenes.create();

    const sky_desc = gfx.SkyDesc{ .sun_direction = .{ 0.6, -0.55, -0.2 } };
    renderer.scenes.setEnvironment(scene, .{ .environment = try renderer.environments.createSky(sky_desc), .intensity = 0.3 });
    renderer.scenes.setSun(scene, .{ .direction = sky_desc.sun_direction, .color = .{ 1.0, 0.9, 0.75 }, .intensity = 4 });

    var box_positions: [24][3]f32 = undefined;
    var box_indices: [36]u32 = undefined;
    helpers.boxMesh(.{ 0.5, 0.5, 0.5 }, &box_positions, &box_indices);
    const grass = try renderer.models.create(&.{.{ .positions = &box_positions, .indices = &box_indices, .material = .{ .base_color = .{ 0.36, 0.55, 0.27, 1 }, .metallic = 0, .roughness = 0.9 } }});
    const stone = try renderer.models.create(&.{.{ .positions = &box_positions, .indices = &box_indices, .material = .{ .base_color = .{ 0.56, 0.54, 0.5, 1 }, .metallic = 0, .roughness = 0.75 } }});
    var grass_blocks: [side * side]math.Mat4 = undefined;
    var stone_blocks: [side * side]math.Mat4 = undefined;
    var grass_count: usize = 0;
    var stone_count: usize = 0;
    for (0..side * side) |index| {
        const x = @as(f32, @floatFromInt(index % side)) - (side - 1) * 0.5;
        const z = @as(f32, @floatFromInt(index / side)) - (side - 1) * 0.5;
        const height = terrace(x, z);
        const block = math.mul(math.translation(.{ x, height * 0.5, z }), math.scaling(.{ 1, height, 1 }));
        if (height > 1.6) {
            stone_blocks[stone_count] = block;
            stone_count += 1;
        } else {
            grass_blocks[grass_count] = block;
            grass_count += 1;
        }
    }
    _ = try renderer.instances.create(scene, grass, grass_blocks[0..grass_count]);
    if (stone_count != 0) _ = try renderer.instances.create(scene, stone, stone_blocks[0..stone_count]);
    const dot = try renderer.images.create(.{ .width = 1, .height = 1, .pixels = &.{ 255, 255, 255, 255 } });
    try renderer.waitUntilLoaded();

    var world = gfx.DrawList.init(init.gpa);
    defer world.deinit();
    var hud = gfx.DrawList.init(init.gpa);
    defer hud.deinit();
    var backdrop = gfx.DrawList.init(init.gpa);
    defer backdrop.deinit();
    const font = renderer.fonts.default();
    var lights: [walker_names.len]gfx.LightDesc = undefined;
    var turn: f32 = 0;
    var turn_target: f32 = 0;
    var span: f32 = 13;
    var parallel = true;
    var moving = true;
    var clock: f32 = 0;
    var hud_buffer: [128]u8 = undefined;

    while (stage.begin()) |tick| {
        if (stage.keyPressed(glfw.GLFW_KEY_Q)) turn_target -= std.math.pi * 0.5;
        if (stage.keyPressed(glfw.GLFW_KEY_E)) turn_target += std.math.pi * 0.5;
        if (stage.keyPressed(glfw.GLFW_KEY_P)) parallel = !parallel;
        if (stage.keyPressed(glfw.GLFW_KEY_SPACE)) moving = !moving;
        if (stage.keyDown(glfw.GLFW_KEY_UP)) span = @max(span - tick.dt * 8, 4);
        if (stage.keyDown(glfw.GLFW_KEY_DOWN)) span = @min(span + tick.dt * 8, 30);
        turn += (turn_target - turn) * @min(tick.dt * 8, 1);
        if (moving) clock += tick.dt;

        world.clear();
        hud.clear();
        backdrop.clear();
        const width: f32 = @floatFromInt(tick.size[0]);
        const height: f32 = @floatFromInt(tick.size[1]);
        const bands = 32;
        for (0..bands) |band| {
            const along = @as(f32, @floatFromInt(band)) / bands;
            const shade = gfx.Color.rgb(@intFromFloat(18 + 40 * along), @intFromFloat(22 + 60 * along), @intFromFloat(48 + 90 * along));
            try backdrop.rect(.{ .x = 0, .y = height * along, .width = width, .height = height / bands + 1 }, shade);
        }
        for (walker_names, 0..) |name, index| {
            const seed: f32 = @floatFromInt(index);
            const x = @sin(clock * (0.23 + seed * 0.05) + seed * 2.1) * 5.5;
            const z = @cos(clock * (0.19 + seed * 0.04) + seed * 1.3) * 5.5;
            const ground = terrace(@round(x + 0.5) - 0.5, @round(z + 0.5) - 0.5);
            const hue = seed * 0.27;
            const color = math.Vec3{ 0.6 + 0.4 * @sin(hue * std.math.tau), 0.6 + 0.4 * @sin((hue + 0.33) * std.math.tau), 0.6 + 0.4 * @sin((hue + 0.66) * std.math.tau) };
            const tint = gfx.Color.rgb(@intFromFloat(color[0] * 255), @intFromFloat(color[1] * 255), @intFromFloat(color[2] * 255));
            lights[index] = .{ .position = .{ x, ground + 0.7, z }, .color = color, .intensity = 6, .range = 4, .source_radius = 0.1 };
            try world.billboard(dot, .{ x, ground + 0.45, z }, .{ 0.35, 0.7 }, tint);
            try hud.text3d(font, name, .{ x, ground + 1.1, z }, .{ .size = 0.32 });
        }
        try renderer.scenes.setLights(scene, &lights);

        try hud.rect(.{ .x = 12, .y = 12, .width = 430, .height = 58 }, gfx.Color.rgba(10, 12, 20, 180));
        try hud.text(font, try std.fmt.bufPrint(&hud_buffer, "{d:.0} fps · gpu {d:.2} ms · {s}", .{ stage.fps, stage.gpu_ms, if (parallel) "orthographic" else "perspective" }), .{ 24, 20 }, .{ .size = 16 });
        try hud.text(font, "Q/E turn · Up/Down zoom · P perspective · Space pause", .{ 24, 46 }, .{ .size = 13, .color = gfx.Color.hex(0x9aa7d0) });

        const angle = turn + std.math.pi * 0.25;
        const target = math.Vec3{ 0, 1, 0 };
        var camera = gfx.Camera.lookAt(math.add(target, .{ @sin(angle) * 30, 24.5, @cos(angle) * 30 }), target);
        camera.near = 20;
        if (parallel) camera.orthographic = .{ .height = span, .far = 120 } else camera.fov_y = 2 * std.math.atan(span * 0.5 / 46.0);
        try stage.end(try renderer.render(.{
            .views = &.{.{
                .scene = scene,
                .camera = camera,
                .draw_lists = &.{ .{ .list = &backdrop, .stage = .under }, .{ .list = &world, .stage = .scene }, .{ .list = &hud } },
                .target = stage.target(),
                .settings = .{
                    .shadows = .{ .distance = 80 },
                    .post = .{ .bloom = 0.06 },
                },
            }},
            .delta_time = tick.dt,
        }));
    }
    try stage.finish();
}
