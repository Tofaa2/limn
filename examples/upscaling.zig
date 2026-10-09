//! Rendering fewer pixels than are shown: the three ways the picture is
//! brought up to size, and shading at a coarser rate where nothing would
//! be lost by it.
//!
//! A tiled yard with a lattice fence, which is all thin lines and hard
//! edges, is drawn at a fraction of the window's size and brought up to
//! it by a plain bicubic stretch, by temporal antialiasing building the
//! full picture out of several frames, or by AMD FidelityFX Super
//! Resolution 1. The GPU time is on screen: what each saves, and what it
//! costs in sharpness, can be seen side by side by switching.
//!
//!   1/2/3    bicubic stretch / temporal / FidelityFX Super Resolution 1
//!   4/5      FidelityFX Super Resolution 2 / 3: temporal, like 2, with
//!            AMD's far more careful rebuilding of the picture
//!   Up/Down  the share of the window's size the scene is drawn at
//!   V        variable-rate shading: flat stretches shaded once for
//!            every 2 by 2 pixels
//!   6        NVIDIA DLSS, on an NVIDIA GPU after `zig build dlss-sdk`
//!   G        FSR 3 frame generation (with 5, in a window)
//!   A/D      orbit the camera
//!
//! `--mode N` (1 to 6), `--scale X`, `--vrs 1`, `--framegen 1`. `--frames N`,
//! `--screenshot file.png`.
const std = @import("std");
const gfx = @import("limn");
const math = gfx.math;
const glfw = @import("glfw");
const window = @import("window");
const Stage = window.Stage;

const scales = [_]f32{ 0.5, 0.59, 0.67, 0.77, 1.0 };

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var mode: gfx.Upscaling = .fsr3;
    var scale_index: usize = 1;
    var coarse_shading = false;
    var frame_generation = false;
    {
        var arguments = try init.minimal.args.iterateAllocator(gpa);
        defer arguments.deinit();
        while (arguments.next()) |argument| {
            if (std.mem.eql(u8, argument, "--mode")) mode = switch (try std.fmt.parseInt(u32, arguments.next() orelse return error.MissingArgument, 10)) {
                1 => .spatial,
                2 => .temporal,
                3 => .fsr,
                4 => .fsr2,
                5 => .fsr3,
                else => .dlss,
            };
            if (std.mem.eql(u8, argument, "--scale")) {
                const wanted = try std.fmt.parseFloat(f32, arguments.next() orelse return error.MissingArgument);
                for (scales, 0..) |scale, index| {
                    if (@abs(scale - wanted) < @abs(scales[scale_index] - wanted)) scale_index = index;
                }
            }
            if (std.mem.eql(u8, argument, "--vrs")) coarse_shading = true;
            if (std.mem.eql(u8, argument, "--framegen")) frame_generation = true;
        }
    }
    var stage = try Stage.create(init, "Limn upscaling", .{});
    const renderer = stage.renderer;
    const scene = try renderer.scenes.create();
    const sky = gfx.SkyDesc{ .sun_direction = .{ -0.55, -0.6, -0.35 } };
    renderer.scenes.setSun(scene, gfx.skySun(sky));
    renderer.scenes.setEnvironment(scene, try renderer.environments.createSky(sky), 1);

    var positions: [24][3]f32 = undefined;
    var indices: [36]u32 = undefined;
    window.boxMesh(.{ 0.5, 0.5, 0.5 }, &positions, &indices);
    const block = try renderer.models.create(&.{.{
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
    const ball = try renderer.models.create(&.{.{
        .positions = ball_positions,
        .normals = ball_normals,
        .indices = ball_indices,
        .material = .{ .base_color = .{ 0.9, 0.85, 0.8, 1 }, .metallic = 1, .roughness = 0.25 },
    }});

    var tiles: std.ArrayList(math.Mat4) = .empty;
    defer tiles.deinit(gpa);
    var tile_colors: std.ArrayList([3]f32) = .empty;
    defer tile_colors.deinit(gpa);
    const half_tiles = 20;
    var row: i32 = -half_tiles;
    while (row < half_tiles) : (row += 1) {
        var column: i32 = -half_tiles;
        while (column < half_tiles) : (column += 1) {
            try tiles.append(gpa, math.mul(math.translation(.{ @as(f32, @floatFromInt(column)) + 0.5, -0.05, @as(f32, @floatFromInt(row)) + 0.5 }), math.scaling(.{ 0.96, 0.1, 0.96 })));
            try tile_colors.append(gpa, if (@mod(row + column, 2) == 0) .{ 0.72, 0.68, 0.6 } else .{ 0.3, 0.33, 0.38 });
        }
    }
    try renderer.instances.setColors(try renderer.instances.create(scene, block, tiles.items), tile_colors.items);

    var bars: std.ArrayList(math.Mat4) = .empty;
    defer bars.deinit(gpa);
    var bar_colors: std.ArrayList([3]f32) = .empty;
    defer bar_colors.deinit(gpa);
    var balls: std.ArrayList(math.Mat4) = .empty;
    defer balls.deinit(gpa);
    for (0..4) |side| {
        const turn = math.rotationY(@as(f32, @floatFromInt(side)) * std.math.pi * 0.5);
        var along: f32 = -8;
        while (along <= 8) : (along += 0.25) {
            try bars.append(gpa, math.mul(turn, math.mul(math.translation(.{ along, 0.8, -8 }), math.mul(math.rotationZ(0.6), math.scaling(.{ 0.025, 1.9, 0.025 })))));
            try bars.append(gpa, math.mul(turn, math.mul(math.translation(.{ along, 0.8, -8 }), math.mul(math.rotationZ(-0.6), math.scaling(.{ 0.025, 1.9, 0.025 })))));
        }
        for ([_]f32{ 0.03, 1.57 }) |height| try bars.append(gpa, math.mul(turn, math.mul(math.translation(.{ 0, height, -8 }), math.scaling(.{ 16.2, 0.06, 0.06 }))));
        try bars.append(gpa, math.mul(turn, math.mul(math.translation(.{ -8, 1.0, -8 }), math.scaling(.{ 0.18, 2.0, 0.18 }))));
        try balls.append(gpa, math.mul(turn, math.translation(.{ -8, 2.4, -8 })));
    }
    for (bars.items) |_| try bar_colors.append(gpa, .{ 0.2, 0.13, 0.08 });
    try renderer.instances.setColors(try renderer.instances.create(scene, block, bars.items), bar_colors.items);
    _ = try renderer.instances.create(scene, ball, balls.items);
    _ = try renderer.entities.spawn(scene, .{ .model = ball, .transform = math.mul(math.translation(.{ 0, 1.2, 0 }), math.uniformScaling(2.4)) });
    try renderer.waitUntilLoaded();

    var list = gfx.DrawList.init(gpa);
    defer list.deinit();
    const font = renderer.fonts.default();
    var text: [256]u8 = undefined;
    var orbit: f32 = 0.5;

    while (stage.begin()) |tick| {
        if (stage.keyPressed(glfw.GLFW_KEY_1)) mode = .spatial;
        if (stage.keyPressed(glfw.GLFW_KEY_2)) mode = .temporal;
        if (stage.keyPressed(glfw.GLFW_KEY_3)) mode = .fsr;
        if (stage.keyPressed(glfw.GLFW_KEY_4)) mode = .fsr2;
        if (stage.keyPressed(glfw.GLFW_KEY_5)) mode = .fsr3;
        if (stage.keyPressed(glfw.GLFW_KEY_6)) mode = .dlss;
        if (stage.keyPressed(glfw.GLFW_KEY_UP) and scale_index + 1 < scales.len) scale_index += 1;
        if (stage.keyPressed(glfw.GLFW_KEY_DOWN) and scale_index > 0) scale_index -= 1;
        if (stage.keyPressed(glfw.GLFW_KEY_V)) coarse_shading = !coarse_shading;
        if (stage.keyPressed(glfw.GLFW_KEY_G)) frame_generation = !frame_generation;
        if (stage.keyDown(glfw.GLFW_KEY_A)) orbit -= tick.dt * 0.6;
        if (stage.keyDown(glfw.GLFW_KEY_D)) orbit += tick.dt * 0.6;
        orbit += tick.dt * 0.04;

        const scale = scales[scale_index];
        var shading_ms: f32 = 0;
        for (renderer.device.passTimings()) |timing| {
            if (std.mem.eql(u8, timing.name, "shading")) shading_ms = timing.milliseconds;
        }
        list.clear();
        try list.rect(.{ .x = 12, .y = 12, .width = 560, .height = 116 }, gfx.Color.rgba(8, 10, 18, 190));
        try list.text(font, switch (mode) {
            .spatial => "Bicubic stretch",
            .temporal => "Temporal: built from several frames",
            .fsr => "FidelityFX Super Resolution 1",
            .fsr2 => "FidelityFX Super Resolution 2",
            .fsr3 => if (frame_generation) "FidelityFX Super Resolution 3 with frame generation" else "FidelityFX Super Resolution 3",
            .dlss => "NVIDIA DLSS",
        }, .{ 24, 20 }, .{ .size = 20 });
        try list.text(font, try std.fmt.bufPrint(&text, "drawn at {d} x {d}, shown at {d} x {d}\n{d:.2} ms GPU · shading {d:.2} ms · {d:.0} fps rendered, {d:.0} shown", .{
            @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(tick.size[0])) * scale))),
            @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(tick.size[1])) * scale))),
            tick.size[0],
            tick.size[1],
            stage.gpu_ms,
            shading_ms,
            stage.fps,
            stage.shown_fps,
        }), .{ 24, 50 }, .{ .size = 15 });
        try list.text(font, try std.fmt.bufPrint(&text, "1-6 upscaler · Up/Down size · V coarse shading {s} · G frame generation · A/D orbit", .{if (coarse_shading) "on" else "off"}), .{ 24, 100 }, .{ .size = 13, .color = gfx.Color.hex(0x9aa7d0) });

        const eye = math.Vec3{ @sin(orbit) * 13, 4.2, @cos(orbit) * 13 };
        try stage.end(try renderer.render(.{
            .views = &.{.{
                .scene = scene,
                .camera = gfx.Camera.lookAt(eye, .{ 0, 1.0, 0 }),
                .draw_lists = &.{&list},
                .target = stage.target(),
                .settings = .{
                    .render_scale = scale,
                    .upscaling = mode,
                    .frame_generation = frame_generation,
                    .variable_rate_shading = coarse_shading,
                    .shadow_distance = 45,
                    .global_illumination = false,
                },
            }},
            .delta_time = tick.dt,
        }));
    }
    try stage.finish();
}
