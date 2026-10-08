//! Lamps at night: a hall of pillars lit by many small colored lights
//! that drift between them, a spot light that sweeps the floor and casts
//! shadows, and a glowing panel on the back wall.
//!
//!   Up/Down  more or fewer drifting lights
//!   S        shadows of the spot light on and off
//!   P        the panel on and off
//!   A/D      orbit the camera, Space pauses
//!
//! `--frames N`, `--screenshot file.png`.
const std = @import("std");
const gfx = @import("limn");
const math = gfx.math;
const glfw = @import("glfw");
const helpers = @import("window");
const Stage = helpers.Stage;

const max_drifting = 192;

pub fn main(init: std.process.Init) !void {
    var stage = try Stage.create(init, "Limn lights", .{});
    const renderer = stage.renderer;
    const scene = try renderer.createScene();

    const sky_desc = gfx.SkyDesc{ .sun_direction = .{ -0.3, -0.25, -0.5 } };
    renderer.setEnvironment(scene, try renderer.createSky(sky_desc), 0.02);
    renderer.setSun(scene, .{ .direction = sky_desc.sun_direction, .color = .{ 0.6, 0.7, 1.0 }, .intensity = 0.05 });

    var box_positions: [24][3]f32 = undefined;
    var box_indices: [36]u32 = undefined;
    helpers.boxMesh(.{ 0.5, 0.5, 0.5 }, &box_positions, &box_indices);
    const stone = try renderer.createModel(&.{.{ .positions = &box_positions, .indices = &box_indices, .material = .{ .base_color = .{ 0.55, 0.53, 0.5, 1 }, .metallic = 0, .roughness = 0.7 } }});
    const polished = try renderer.createModel(&.{.{ .positions = &box_positions, .indices = &box_indices, .material = .{ .base_color = .{ 0.3, 0.3, 0.32, 1 }, .metallic = 0, .roughness = 0.25 } }});
    _ = try renderer.spawn(scene, .{ .model = polished, .transform = math.mul(math.translation(.{ 0, -0.25, 0 }), math.scaling(.{ 40, 0.5, 30 })) });
    _ = try renderer.spawn(scene, .{ .model = stone, .transform = math.mul(math.translation(.{ 0, 3.5, -13 }), math.scaling(.{ 40, 7, 0.5 })) });
    var pillars: [5 * 8]math.Mat4 = undefined;
    for (&pillars, 0..) |*pillar, index| {
        const x = (@as(f32, @floatFromInt(index % 8)) - 3.5) * 4.0;
        const z = (@as(f32, @floatFromInt(index / 8)) - 2) * 4.5;
        pillar.* = math.mul(math.translation(.{ x, 2.5, z }), math.scaling(.{ 0.7, 5, 0.7 }));
    }
    _ = try renderer.createInstances(scene, stone, &pillars);
    var sphere_positions: [helpers.sphere_vertex_count][3]f32 = undefined;
    var sphere_normals: [helpers.sphere_vertex_count][3]f32 = undefined;
    var sphere_indices: [helpers.sphere_index_count]u32 = undefined;
    helpers.sphereMesh(0.9, &sphere_positions, &sphere_normals, &sphere_indices);
    const chrome = try renderer.createModel(&.{.{ .positions = &sphere_positions, .normals = &sphere_normals, .indices = &sphere_indices, .material = .{ .base_color = .{ 0.9, 0.9, 0.92, 1 }, .metallic = 1, .roughness = 0.15 } }});
    _ = try renderer.spawn(scene, .{ .model = chrome, .transform = math.translation(.{ 2, 0.9, 2.2 }) });
    const dot = try renderer.createImage(1, 1, &.{ 255, 255, 255, 255 }, true);
    try renderer.waitUntilLoaded();

    var list = gfx.DrawList.init(init.gpa);
    defer list.deinit();
    const font = renderer.defaultFont();
    var lights: [max_drifting + 2]gfx.Light = undefined;
    var drifting: usize = 64;
    var spot_shadows = true;
    var panel = true;
    var moving = true;
    var clock: f32 = 0;
    var orbit: f32 = 0.5;
    var hud_buffer: [128]u8 = undefined;

    while (stage.begin()) |tick| {
        if (stage.keyPressed(glfw.GLFW_KEY_UP)) drifting = @min(drifting * 2, max_drifting);
        if (stage.keyPressed(glfw.GLFW_KEY_DOWN)) drifting = @max(drifting / 2, 4);
        if (stage.keyPressed(glfw.GLFW_KEY_S)) spot_shadows = !spot_shadows;
        if (stage.keyPressed(glfw.GLFW_KEY_P)) panel = !panel;
        if (stage.keyPressed(glfw.GLFW_KEY_SPACE)) moving = !moving;
        if (stage.keyDown(glfw.GLFW_KEY_A)) orbit -= tick.dt * 0.7;
        if (stage.keyDown(glfw.GLFW_KEY_D)) orbit += tick.dt * 0.7;
        if (moving) clock += tick.dt;

        list.clear();
        var count: usize = 0;
        for (0..drifting) |index| {
            const seed: f32 = @floatFromInt(index);
            const position = math.Vec3{
                @sin(seed * 12.9898 + clock * (0.11 + 0.05 * @sin(seed))) * 15,
                0.5 + 1.6 * (0.5 + 0.5 * @sin(seed * 4.1 + clock * 0.6)),
                @cos(seed * 78.233 + clock * (0.09 + 0.04 * @cos(seed * 1.7))) * 10,
            };
            const hue = seed * 0.61803;
            const color = math.Vec3{ 0.55 + 0.45 * @sin(hue * std.math.tau), 0.55 + 0.45 * @sin((hue + 0.33) * std.math.tau), 0.55 + 0.45 * @sin((hue + 0.66) * std.math.tau) };
            lights[count] = .{ .position = position, .color = color, .intensity = 5, .range = 4.5, .source_radius = 0.05 };
            count += 1;
            try list.billboard(dot, position, .{ 0.07, 0.07 }, gfx.Color.rgb(@intFromFloat(color[0] * 255), @intFromFloat(color[1] * 255), @intFromFloat(color[2] * 255)));
        }
        lights[count] = .{
            .kind = .spot,
            .position = .{ 0, 6.5, 6 },
            .direction = .{ @sin(clock * 0.5) * 0.7, -1, -0.45 + @cos(clock * 0.37) * 0.3 },
            .color = .{ 1.0, 0.92, 0.8 },
            .intensity = 220,
            .range = 20,
            .inner_angle = 0.3,
            .outer_angle = 0.42,
            .cast_shadows = spot_shadows,
        };
        count += 1;
        if (panel) {
            lights[count] = .{ .kind = .rectangle, .position = .{ 0, 3, -12.6 }, .direction = .{ 0, -0.1, 1 }, .color = .{ 0.4, 0.75, 1.0 }, .intensity = 30, .range = 16, .source_length = 6, .source_height = 2.5 };
            count += 1;
            try list.quad3d(.{ .{ -3, 1.75, -12.7 }, .{ 3, 1.75, -12.7 }, .{ 3, 4.25, -12.7 }, .{ -3, 4.25, -12.7 } }, gfx.Color.rgb(140, 210, 255));
        }
        try renderer.setLights(scene, lights[0..count]);

        try list.rect(.{ .x = 12, .y = 12, .width = 470, .height = 58 }, gfx.Color.rgba(10, 12, 20, 180));
        try list.text(font, try std.fmt.bufPrint(&hud_buffer, "{d:.0} fps · gpu {d:.2} ms · {d} lights · spot shadows {s}", .{ stage.fps, stage.gpu_ms, count, if (spot_shadows) "on" else "off" }), .{ 24, 20 }, .{ .size = 16 });
        try list.text(font, "Up/Down count · S shadows · P panel · A/D orbit · Space pause", .{ 24, 46 }, .{ .size = 13, .color = gfx.Color.hex(0x9aa7d0) });

        const eye = math.Vec3{ @sin(orbit) * 17, 5.5, @cos(orbit) * 17 };
        try stage.end(try renderer.render(.{
            .views = &.{.{
                .scene = scene,
                .camera = gfx.Camera.lookAt(eye, .{ 0, 1.5, 0 }),
                .draw_lists = &.{&list},
                .target = stage.target(),
                .settings = .{ .shadow_distance = 40, .bloom = 0.08, .automatic_exposure = false, .exposure_compensation = 1.5 },
            }},
            .delta_time = tick.dt,
        }));
    }
    try stage.finish();
}
