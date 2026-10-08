//! Decals: pictures and stains projected onto whatever is there. A floor,
//! a wall and a ball share road markings, a wet patch that only changes
//! how the surface shines, a glowing sign and a mark that follows a
//! circle across all three.
//!
//!   A/D      orbit the camera, Space pauses the moving mark
//!
//! `--frames N`, `--screenshot file.png`.
const std = @import("std");
const gfx = @import("limn");
const math = gfx.math;
const glfw = @import("glfw");
const helpers = @import("window");
const Stage = helpers.Stage;

const size = 128;

/// A picture drawn here rather than loaded: `shape` says how opaque each
/// point is, given its place in -1..1.
fn drawImage(renderer: *gfx.Renderer, comptime shape: fn (x: f32, y: f32) f32) !gfx.Image {
    var pixels: [size * size * 4]u8 = undefined;
    for (0..size) |y| for (0..size) |x| {
        const u = (@as(f32, @floatFromInt(x)) + 0.5) / size * 2 - 1;
        const v = (@as(f32, @floatFromInt(y)) + 0.5) / size * 2 - 1;
        const alpha = std.math.clamp(shape(u, v), 0, 1);
        pixels[(y * size + x) * 4 ..][0..4].* = .{ 255, 255, 255, @intFromFloat(alpha * 255) };
    };
    return renderer.images.create(size, size, &pixels, true);
}

fn arrow(x: f32, y: f32) f32 {
    const shaft = @abs(x) < 0.16 and y > -0.1 and y < 0.85;
    const head = y < -0.1 and y > -0.85 and @abs(x) < (y + 0.85) * 0.75;
    return if (shaft or head) 1 else 0;
}

fn ring(x: f32, y: f32) f32 {
    const radius = @sqrt(x * x + y * y);
    return (1 - std.math.clamp(@abs(radius - 0.7) * 9 - 1, 0, 1));
}

fn blot(x: f32, y: f32) f32 {
    const angle = std.math.atan2(y, x);
    const edge = 0.62 + 0.14 * @sin(angle * 5) + 0.08 * @sin(angle * 11 + 1.3);
    return (edge - @sqrt(x * x + y * y)) * 6;
}

/// A decal's box: placed at `position`, looking along `direction`, as
/// wide and tall as `extent` and reaching `depth` into what it lands on.
fn project(position: math.Vec3, turn_y: f32, tilt_x: f32, extent: [2]f32, depth: f32) math.Mat4 {
    return math.mul(math.translation(position), math.mul(math.rotationY(turn_y), math.mul(math.rotationX(tilt_x), math.scaling(.{ extent[0], extent[1], depth }))));
}

pub fn main(init: std.process.Init) !void {
    var stage = try Stage.create(init, "Limn decals", .{});
    const renderer = stage.renderer;
    const scene = try renderer.scenes.create();

    const sky_desc = gfx.SkyDesc{ .sun_direction = .{ -0.45, -0.7, -0.5 } };
    renderer.scenes.setEnvironment(scene, try renderer.environments.createSky(sky_desc), 1);
    renderer.scenes.setSun(scene, gfx.skySun(sky_desc));

    var box_positions: [24][3]f32 = undefined;
    var box_indices: [36]u32 = undefined;
    helpers.boxMesh(.{ 0.5, 0.5, 0.5 }, &box_positions, &box_indices);
    const asphalt = try renderer.models.create(&.{.{ .positions = &box_positions, .indices = &box_indices, .material = .{ .base_color = .{ 0.13, 0.13, 0.14, 1 }, .metallic = 0, .roughness = 0.85 } }});
    const plaster = try renderer.models.create(&.{.{ .positions = &box_positions, .indices = &box_indices, .material = .{ .base_color = .{ 0.75, 0.72, 0.66, 1 }, .metallic = 0, .roughness = 0.8 } }});
    _ = try renderer.entities.spawn(scene, .{ .model = asphalt, .transform = math.mul(math.translation(.{ 0, -0.25, 0 }), math.scaling(.{ 24, 0.5, 16 })) });
    _ = try renderer.entities.spawn(scene, .{ .model = plaster, .transform = math.mul(math.translation(.{ 0, 2, -5 }), math.scaling(.{ 24, 4, 0.5 })) });
    var sphere_positions: [helpers.sphere_vertex_count][3]f32 = undefined;
    var sphere_normals: [helpers.sphere_vertex_count][3]f32 = undefined;
    var sphere_indices: [helpers.sphere_index_count]u32 = undefined;
    helpers.sphereMesh(1.2, &sphere_positions, &sphere_normals, &sphere_indices);
    const ball = try renderer.models.create(&.{.{ .positions = &sphere_positions, .normals = &sphere_normals, .indices = &sphere_indices, .material = .{ .base_color = .{ 0.8, 0.8, 0.8, 1 }, .metallic = 0, .roughness = 0.5 } }});
    _ = try renderer.entities.spawn(scene, .{ .model = ball, .transform = math.translation(.{ 3.5, 1.2, -1.5 }) });
    _ = try renderer.entities.spawn(scene, .{ .model = plaster, .transform = math.mul(math.translation(.{ -3.2, 0.6, 0.4 }), math.scaling(.{ 1.2, 1.2, 1.2 })), .receive_decals = false, .tint = .{ 0.9, 0.5, 0.3 } });

    const arrow_image = try drawImage(renderer, arrow);
    const ring_image = try drawImage(renderer, ring);
    const blot_image = try drawImage(renderer, blot);
    try renderer.waitUntilLoaded();

    var list = gfx.DrawList.init(init.gpa);
    defer list.deinit();
    const font = renderer.fonts.default();
    var orbit: f32 = 0.3;
    var clock: f32 = 0;
    var moving = true;
    var hud_buffer: [96]u8 = undefined;
    const down = -std.math.pi * 0.5;

    while (stage.begin()) |tick| {
        if (stage.keyDown(glfw.GLFW_KEY_A)) orbit -= tick.dt * 0.8;
        if (stage.keyDown(glfw.GLFW_KEY_D)) orbit += tick.dt * 0.8;
        if (stage.keyPressed(glfw.GLFW_KEY_SPACE)) moving = !moving;
        if (moving) clock += tick.dt;

        var decals: [16]gfx.DecalDesc = undefined;
        var count: usize = 0;
        for (0..5) |index| {
            decals[count] = .{ .transform = project(.{ (@as(f32, @floatFromInt(index)) - 2) * 3.2, 0, 3.2 }, std.math.pi * 0.5, down, .{ 1.0, 1.6 }, 0.5), .image = arrow_image, .color = .{ 0.95, 0.9, 0.75, 0.95 } };
            count += 1;
        }
        decals[count] = .{ .transform = project(.{ -1, 0, 0.6 }, 0.4, down, .{ 4.5, 3.2 }, 0.5), .image = blot_image, .color = .{ 0.05, 0.05, 0.06, 0.55 }, .roughness = 0.05 };
        count += 1;
        decals[count] = .{ .transform = project(.{ 3.2, 1.6, -2.6 }, 0, 0, .{ 4.2, 3.4 }, 6.0), .image = blot_image, .color = .{ 0.75, 0.08, 0.12, 0.92 }, .roughness = 0.3, .angle_fade = 0.05 };
        count += 1;
        decals[count] = .{ .transform = project(.{ -5.5, 2.2, -4.7 }, 0, 0, .{ 2.4, 2.4 }, 0.6), .image = ring_image, .color = .{ 0.2, 0.9, 1.0, 1 }, .emissive = 6 };
        count += 1;
        const mark = math.Vec3{ @sin(clock * 0.6) * 6, 0, @cos(clock * 0.6) * 3.5 - 0.5 };
        decals[count] = .{ .transform = project(mark, clock, down, .{ 1.8, 1.8 }, 3.0), .image = ring_image, .color = .{ 1.0, 0.75, 0.1, 1 }, .emissive = 2 };
        count += 1;
        try renderer.scenes.setDecals(scene, decals[0..count]);

        list.clear();
        try list.text3d(font, "opted out", .{ -3.2, 1.5, 0.4 }, .{ .size = 0.16 });
        try list.rect(.{ .x = 12, .y = 12, .width = 360, .height = 58 }, gfx.Color.rgba(10, 12, 20, 180));
        try list.text(font, try std.fmt.bufPrint(&hud_buffer, "{d:.0} fps · gpu {d:.2} ms · {d} decals", .{ stage.fps, stage.gpu_ms, count }), .{ 24, 20 }, .{ .size = 16 });
        try list.text(font, "A/D orbit · Space pause", .{ 24, 46 }, .{ .size = 13, .color = gfx.Color.hex(0x9aa7d0) });

        const eye = math.Vec3{ @sin(orbit) * 13, 5.5, @cos(orbit) * 13 };
        try stage.end(try renderer.render(.{
            .views = &.{.{
                .scene = scene,
                .camera = gfx.Camera.lookAt(eye, .{ 0, 0.8, -1 }),
                .draw_lists = &.{&list},
                .target = stage.target(),
                .settings = .{ .shadow_distance = 40 },
            }},
            .delta_time = tick.dt,
        }));
    }
    try stage.finish();
}
