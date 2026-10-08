//! Virtual shadow maps beside the sun's shadow cascades.
//!
//! An avenue of thin posts and rails runs away from the camera, with the
//! sun low to one side, so the ground is striped with fine shadows as far
//! as can be seen. The cascades share one fixed number of texels over all
//! that distance. The virtual shadow map keeps fine pages only where the
//! picture needs them, and draws a page again only when something moves
//! in it: the time the shadow passes take is on screen for both.
//!
//!   V        virtual shadow maps on and off
//!   M        a ball rolls down the avenue, or stops (what moves makes
//!            the pages under it be drawn again)
//!   A/D      turn the camera
//!   T        hold to move the sun
//!
//! `--vsm 0` starts with the cascades alone. `--frames N`,
//! `--screenshot file.png`.
const std = @import("std");
const gfx = @import("limn");
const math = gfx.math;
const glfw = @import("glfw");
const window = @import("window");
const Stage = window.Stage;

const avenue_length = 160.0;
const post_spacing = 0.6;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var virtual = true;
    {
        var arguments = try init.minimal.args.iterateAllocator(gpa);
        defer arguments.deinit();
        while (arguments.next()) |argument| {
            if (std.mem.eql(u8, argument, "--vsm")) virtual = !std.mem.eql(u8, arguments.next() orelse "1", "0");
        }
    }
    var stage = try Stage.create(init, "Limn shadows", .{});
    const renderer = stage.renderer;
    const scene = try renderer.createScene();
    var sun_turn: f32 = 0.9;
    var sky = gfx.SkyDesc{ .sun_direction = .{ -@cos(sun_turn), -0.42, -@sin(sun_turn) * 0.4 } };
    renderer.setSun(scene, gfx.skySun(sky));
    const environment = try renderer.createSky(sky);
    renderer.setEnvironment(scene, environment, 1);

    var positions: [24][3]f32 = undefined;
    var indices: [36]u32 = undefined;
    window.boxMesh(.{ 0.5, 0.5, 0.5 }, &positions, &indices);
    const ground = try renderer.createModel(&.{.{
        .positions = &positions,
        .indices = &indices,
        .material = .{ .base_color = .{ 0.62, 0.60, 0.56, 1 }, .metallic = 0, .roughness = 0.85 },
    }});
    const wood = try renderer.createModel(&.{.{
        .positions = &positions,
        .indices = &indices,
        .material = .{ .base_color = .{ 0.33, 0.22, 0.13, 1 }, .metallic = 0, .roughness = 0.8 },
    }});
    const ball_positions = try gpa.create([window.sphere_vertex_count][3]f32);
    defer gpa.destroy(ball_positions);
    const ball_normals = try gpa.create([window.sphere_vertex_count][3]f32);
    defer gpa.destroy(ball_normals);
    const ball_indices = try gpa.create([window.sphere_index_count]u32);
    defer gpa.destroy(ball_indices);
    window.sphereMesh(0.6, ball_positions, ball_normals, ball_indices);
    const ball = try renderer.createModel(&.{.{
        .positions = ball_positions,
        .normals = ball_normals,
        .indices = ball_indices,
        .material = .{ .base_color = .{ 0.75, 0.2, 0.15, 1 }, .metallic = 0, .roughness = 0.4 },
    }});
    _ = try renderer.spawn(scene, .{ .model = ground, .transform = math.mul(math.translation(.{ 0, -0.5, -avenue_length * 0.5 }), math.scaling(.{ 60, 1, avenue_length + 40 })) });

    var bars: std.ArrayList(math.Mat4) = .empty;
    defer bars.deinit(gpa);
    for ([_]f32{ -2.2, 2.2 }) |x| {
        var z: f32 = 0;
        while (z < avenue_length) : (z += post_spacing) {
            try bars.append(gpa, math.mul(math.translation(.{ x, 0.75, -z }), math.scaling(.{ 0.05, 1.5, 0.05 })));
            try bars.append(gpa, math.mul(math.translation(.{ x, 0.9, -z - post_spacing * 0.5 }), math.mul(math.rotationX(0.7), math.scaling(.{ 0.02, 0.9, 0.02 }))));
        }
        for ([_]f32{ 0.45, 0.9, 1.35 }) |height| {
            try bars.append(gpa, math.mul(math.translation(.{ x, height, -avenue_length * 0.5 }), math.scaling(.{ 0.03, 0.04, avenue_length })));
        }
    }
    _ = try renderer.createInstances(scene, wood, bars.items);
    const roller = try renderer.spawn(scene, .{ .model = ball, .transform = math.translation(.{ 0, 0.6, -6 }) });
    try renderer.waitUntilLoaded();

    var list = gfx.DrawList.init(gpa);
    defer list.deinit();
    const font = renderer.defaultFont();
    var text: [256]u8 = undefined;
    var rolling = true;
    var rolled: f32 = 0;
    var look: f32 = 0;

    while (stage.begin()) |tick| {
        if (stage.keyPressed(glfw.GLFW_KEY_V)) virtual = !virtual;
        if (stage.keyPressed(glfw.GLFW_KEY_M)) rolling = !rolling;
        if (stage.keyDown(glfw.GLFW_KEY_A)) look += tick.dt * 0.7;
        if (stage.keyDown(glfw.GLFW_KEY_D)) look -= tick.dt * 0.7;
        if (stage.keyDown(glfw.GLFW_KEY_T)) {
            sun_turn += tick.dt * 0.4;
            sky.sun_direction = .{ -@cos(sun_turn), -0.42, -@sin(sun_turn) * 0.4 };
            renderer.setSky(environment, sky);
            renderer.setSun(scene, gfx.skySun(sky));
        }
        if (rolling) rolled += tick.dt;
        renderer.setTransform(roller, math.translation(.{ @sin(rolled * 0.5) * 1.2, 0.6, -6 - @mod(rolled * 3, 60) }));

        var cascades_ms: f32 = 0;
        var virtual_ms: f32 = 0;
        for (renderer.device.passTimings()) |timing| {
            if (std.mem.eql(u8, timing.name, "shadows")) cascades_ms = timing.milliseconds;
            if (std.mem.eql(u8, timing.name, "virtual shadows")) virtual_ms = timing.milliseconds;
        }
        list.clear();
        try list.rect(.{ .x = 12, .y = 12, .width = 520, .height = 112 }, gfx.Color.rgba(8, 10, 18, 190));
        try list.text(font, if (virtual) "Sun shadows: virtual shadow map" else "Sun shadows: cascades", .{ 24, 20 }, .{ .size = 20 });
        try list.text(font, try std.fmt.bufPrint(&text, "cascades {d:.2} ms · virtual pages {d:.2} ms · frame {d:.1} ms GPU\n{d:.0} fps", .{
            cascades_ms, if (virtual) virtual_ms else 0, stage.gpu_ms, stage.fps,
        }), .{ 24, 50 }, .{ .size = 15 });
        try list.text(font, try std.fmt.bufPrint(&text, "V virtual shadows · M ball {s} · A/D look · hold T sun", .{if (rolling) "rolls" else "rests"}), .{ 24, 98 }, .{ .size = 13, .color = gfx.Color.hex(0x9aa7d0) });

        try stage.end(try renderer.render(.{
            .views = &.{.{
                .scene = scene,
                .camera = .{ .position = .{ 0, 1.7, 3 }, .forward = .{ -@sin(look), -0.16, -@cos(look) } },
                .draw_lists = &.{&list},
                .target = stage.target(),
                .settings = .{
                    .shadow_distance = 140,
                    .virtual_shadow_maps = virtual,
                    .global_illumination = false,
                },
            }},
            .delta_time = tick.dt,
        }));
    }
    try stage.finish();
}
