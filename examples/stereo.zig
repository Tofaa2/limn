//! A stereo pair: the scene drawn once for each eye, side by side.
//!
//! `Camera.stereo` makes the two cameras from one: a little apart, both
//! looking the same way, each with its picture moved sideways so that
//! what is at the convergence distance falls in the same place in both.
//! Looked at with the eyes relaxed (or crossed, with the two swapped),
//! the halves fuse into one picture with depth: what is nearer than the
//! convergence distance stands out in front of the screen, the rest lies
//! behind it. A headset wants the same two views, in its two targets.
//!
//!   Up/Down     how far apart the eyes are
//!   Left/Right  the distance at which the two pictures agree
//!   X           swap the halves, for looking cross-eyed
//!   A/D         orbit the camera
//!
//! `--frames N`, `--screenshot file.png`.
const std = @import("std");
const gfx = @import("limn");
const math = gfx.math;
const glfw = @import("glfw");
const window = @import("window");
const Stage = window.Stage;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var stage = try Stage.create(init, "Limn stereo", .{});
    const renderer = stage.renderer;
    const scene = try renderer.createScene();
    const sky = gfx.SkyDesc{ .sun_direction = .{ -0.45, -0.7, -0.4 } };
    renderer.setSun(scene, gfx.skySun(sky));
    renderer.setEnvironment(scene, try renderer.createSky(sky), 1);
    const right_view = try renderer.createView();

    var positions: [24][3]f32 = undefined;
    var indices: [36]u32 = undefined;
    window.boxMesh(.{ 0.5, 0.5, 0.5 }, &positions, &indices);
    const block = try renderer.createModel(&.{.{
        .positions = &positions,
        .indices = &indices,
        .material = .{ .base_color = .{ 1, 1, 1, 1 }, .metallic = 0, .roughness = 0.7 },
    }});
    const ball_positions = try gpa.create([window.sphere_vertex_count][3]f32);
    defer gpa.destroy(ball_positions);
    const ball_normals = try gpa.create([window.sphere_vertex_count][3]f32);
    defer gpa.destroy(ball_normals);
    const ball_indices = try gpa.create([window.sphere_index_count]u32);
    defer gpa.destroy(ball_indices);
    window.sphereMesh(0.5, ball_positions, ball_normals, ball_indices);
    const ball = try renderer.createModel(&.{.{
        .positions = ball_positions,
        .normals = ball_normals,
        .indices = ball_indices,
        .material = .{ .base_color = .{ 1, 1, 1, 1 }, .metallic = 0, .roughness = 0.35 },
    }});

    var blocks: std.ArrayList(math.Mat4) = .empty;
    defer blocks.deinit(gpa);
    var block_colors: std.ArrayList([3]f32) = .empty;
    defer block_colors.deinit(gpa);
    var row: i32 = -14;
    while (row < 14) : (row += 1) {
        var column: i32 = -14;
        while (column < 14) : (column += 1) {
            try blocks.append(gpa, math.mul(math.translation(.{ @as(f32, @floatFromInt(column)) + 0.5, -0.05, @as(f32, @floatFromInt(row)) + 0.5 }), math.scaling(.{ 0.96, 0.1, 0.96 })));
            try block_colors.append(gpa, if (@mod(row + column, 2) == 0) .{ 0.7, 0.67, 0.6 } else .{ 0.32, 0.34, 0.4 });
        }
    }
    for (0..9) |index| {
        const z = 5 - @as(f32, @floatFromInt(index)) * 2.2;
        for ([_]f32{ -2.4, 2.4 }) |x| {
            try blocks.append(gpa, math.mul(math.translation(.{ x, 1.5, z }), math.scaling(.{ 0.35, 3, 0.35 })));
            try block_colors.append(gpa, .{ 0.75, 0.72, 0.68 });
        }
    }
    try renderer.setInstanceColors(try renderer.createInstances(scene, block, blocks.items), block_colors.items);
    var balls: std.ArrayList(math.Mat4) = .empty;
    defer balls.deinit(gpa);
    var ball_colors: std.ArrayList([3]f32) = .empty;
    defer ball_colors.deinit(gpa);
    for (0..12) |index| {
        const step: f32 = @floatFromInt(index);
        try balls.append(gpa, math.mul(math.translation(.{ @sin(step * 1.9) * 1.5, 1.0 + @cos(step * 1.3) * 0.6, 6.5 - step * 1.6 }), math.uniformScaling(0.45 + 0.25 * @sin(step * 0.7))));
        try ball_colors.append(gpa, .{ 0.55 + 0.4 * @sin(step * 1.1), 0.5 + 0.4 * @sin(step * 1.7 + 2), 0.5 + 0.4 * @sin(step * 2.3 + 4) });
    }
    try renderer.setInstanceColors(try renderer.createInstances(scene, ball, balls.items), ball_colors.items);
    try renderer.waitUntilLoaded();

    var list = gfx.DrawList.init(gpa);
    defer list.deinit();
    const font = renderer.defaultFont();
    var text: [200]u8 = undefined;
    var separation: f32 = 0.065;
    var convergence: f32 = 6;
    var swapped = false;
    var orbit: f32 = 0;

    while (stage.begin()) |tick| {
        if (stage.keyDown(glfw.GLFW_KEY_UP)) separation = @min(separation + tick.dt * 0.05, 0.4);
        if (stage.keyDown(glfw.GLFW_KEY_DOWN)) separation = @max(separation - tick.dt * 0.05, 0);
        if (stage.keyDown(glfw.GLFW_KEY_RIGHT)) convergence = @min(convergence + tick.dt * 3, 40);
        if (stage.keyDown(glfw.GLFW_KEY_LEFT)) convergence = @max(convergence - tick.dt * 3, 0.5);
        if (stage.keyPressed(glfw.GLFW_KEY_X)) swapped = !swapped;
        if (stage.keyDown(glfw.GLFW_KEY_A)) orbit -= tick.dt * 0.5;
        if (stage.keyDown(glfw.GLFW_KEY_D)) orbit += tick.dt * 0.5;

        const eye = math.Vec3{ @sin(orbit) * 9, 1.6, @cos(orbit) * 9 };
        const eyes = gfx.Camera.lookAt(eye, .{ 0, 1.2, 0 }).stereo(separation, convergence);
        const half = tick.size[0] / 2;
        const left: usize = if (swapped) 1 else 0;

        list.clear();
        try list.rect(.{ .x = 12, .y = 12, .width = 440, .height = 76 }, gfx.Color.rgba(8, 10, 18, 190));
        try list.text(font, try std.fmt.bufPrint(&text, "eyes {d:.0} mm apart · agree at {d:.1} m · {s}", .{ separation * 1000, convergence, if (swapped) "for crossed eyes" else "for relaxed eyes" }), .{ 24, 20 }, .{ .size = 16 });
        try list.text(font, try std.fmt.bufPrint(&text, "{d:.1} ms GPU for both · {d:.0} fps\nUp/Down apart · Left/Right distance · X swap · A/D orbit", .{ stage.gpu_ms, stage.fps }), .{ 24, 44 }, .{ .size = 13, .color = gfx.Color.hex(0x9aa7d0) });

        const settings = gfx.Settings{ .shadow_distance = 40, .global_illumination = false };
        try stage.end(try renderer.render(.{
            .views = &.{
                .{
                    .scene = scene,
                    .camera = eyes[left],
                    .draw_lists = &.{&list},
                    .target = stage.target(),
                    .region = .{ .x = 0, .y = 0, .width = half, .height = tick.size[1] },
                    .settings = settings,
                },
                .{
                    .view = right_view,
                    .scene = scene,
                    .camera = eyes[1 - left],
                    .target = stage.target(),
                    .region = .{ .x = half, .y = 0, .width = tick.size[0] - half, .height = tick.size[1] },
                    .settings = settings,
                },
            },
            .delta_time = tick.dt,
        }));
    }
    try stage.finish();
}
