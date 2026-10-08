//! Several views in one frame: the window split between two cameras, a
//! third camera rendered into a texture and shown as an inset, and a 2D
//! layer drawn across all of it. Each view keeps its own settings, so
//! the right half shows one of the debug pictures.
//!
//!   V        what the right half shows
//!   Space    pause
//!
//! `--frames N`, `--screenshot file.png`.
const std = @import("std");
const gfx = @import("limn");
const math = gfx.math;
const glfw = @import("glfw");
const helpers = @import("window");
const Stage = helpers.Stage;

pub fn main(init: std.process.Init) !void {
    var stage = try Stage.create(init, "Limn views", .{});
    const renderer = stage.renderer;
    const scene = try renderer.createScene();

    const sky_desc = gfx.SkyDesc{ .sun_direction = .{ -0.5, -0.6, -0.4 } };
    renderer.setEnvironment(scene, try renderer.createSky(sky_desc), 1);
    renderer.setSun(scene, gfx.skySun(sky_desc));

    var box_positions: [24][3]f32 = undefined;
    var box_indices: [36]u32 = undefined;
    helpers.boxMesh(.{ 0.5, 0.5, 0.5 }, &box_positions, &box_indices);
    const block = try renderer.createModel(&.{.{ .positions = &box_positions, .indices = &box_indices, .material = .{ .base_color = .{ 0.7, 0.7, 0.72, 1 }, .metallic = 0, .roughness = 0.6 } }});
    _ = try renderer.spawn(scene, .{ .model = block, .transform = math.mul(math.translation(.{ 0, -0.25, 0 }), math.scaling(.{ 40, 0.5, 40 })), .tint = .{ 0.45, 0.5, 0.42 } });
    var towers: [64]math.Mat4 = undefined;
    var colors: [64][3]f32 = undefined;
    for (&towers, &colors, 0..) |*tower, *color, index| {
        const seed: f32 = @floatFromInt(index);
        const x = (@as(f32, @floatFromInt(index % 8)) - 3.5) * 3.4;
        const z = (@as(f32, @floatFromInt(index / 8)) - 3.5) * 3.4;
        const tall = 0.8 + 3.2 * (0.5 + 0.5 * @sin(seed * 2.4));
        tower.* = math.mul(math.translation(.{ x, tall * 0.5, z }), math.scaling(.{ 1.3, tall, 1.3 }));
        color.* = .{ 0.6 + 0.4 * @sin(seed), 0.6 + 0.4 * @sin(seed * 1.7 + 1), 0.6 + 0.4 * @sin(seed * 2.3 + 2) };
    }
    const group = try renderer.createInstances(scene, block, &towers);
    try renderer.setInstanceColors(group, &colors);
    const fox_model = try renderer.loadModel("examples/assets/world/Fox.glb");
    const fox = try renderer.spawn(scene, .{ .model = fox_model });
    try renderer.waitUntilLoaded();
    const run = renderer.findAnimation(fox_model, "Run") orelse 0;
    const run_length = if (renderer.animationInfo(fox_model, run)) |clip| clip.duration else 1;

    const right_view = try renderer.createView();
    const chase_view = try renderer.createView();
    const chase_target = try renderer.createTarget(480, 270);

    var list = gfx.DrawList.init(init.gpa);
    defer list.deinit();
    var overlay = gfx.DrawList.init(init.gpa);
    defer overlay.deinit();
    const font = renderer.defaultFont();
    const modes = [_]struct { name: []const u8, view: gfx.DebugView }{
        .{ .name = "meshlets", .view = .meshlets },
        .{ .name = "normals", .view = .normal },
        .{ .name = "the same, from behind", .view = .none },
    };
    var mode: usize = 0;
    var clock: f32 = 0;
    var moving = true;
    var hud_buffer: [96]u8 = undefined;

    while (stage.begin()) |tick| {
        if (stage.keyPressed(glfw.GLFW_KEY_V)) mode = (mode + 1) % modes.len;
        if (stage.keyPressed(glfw.GLFW_KEY_SPACE)) moving = !moving;
        if (moving) clock += tick.dt;

        const angle = clock * 0.5;
        const place = math.Vec3{ @sin(angle) * 15.2, 0, @cos(angle) * 15.2 };
        renderer.setTransform(fox, math.mul(math.translation(place), math.mul(math.rotationY(angle + std.math.pi * 0.5), math.uniformScaling(0.02))));
        renderer.setPose(fox, .{ .animation = run, .time = @mod(clock * 1.2, run_length) });

        const size = tick.size;
        const half = size[0] / 2;
        const overview = gfx.Camera.lookAt(.{ @sin(clock * 0.1) * 30, 16, @cos(clock * 0.1) * 30 }, .{ 0, 1, 0 });
        const behind = gfx.Camera.lookAt(.{ -@sin(clock * 0.1) * 30, 9, -@cos(clock * 0.1) * 30 }, .{ 0, 1, 0 });
        const forward = math.Vec3{ @cos(angle), 0, -@sin(angle) };
        const chase = gfx.Camera.lookAt(math.add(math.sub(place, math.scale(forward, 4.5)), .{ 0, 2.2, 0 }), math.add(place, .{ 0, 0.8, 0 }));

        list.clear();
        try list.text3d(font, "fox", math.add(place, .{ 0, 2.2, 0 }), .{ .size = 0.5 });
        overlay.clear();
        const width: f32 = @floatFromInt(size[0]);
        const height: f32 = @floatFromInt(size[1]);
        try overlay.rect(.{ .x = @as(f32, @floatFromInt(half)) - 1, .y = 0, .width = 2, .height = height }, gfx.Color.white);
        try overlay.rect(.{ .x = 14, .y = height - 288, .width = 484, .height = 274 }, gfx.Color.white);
        try overlay.image(renderer.targetImage(chase_target), .{ .x = 16, .y = height - 286, .width = 480, .height = 270 }, .{});
        try overlay.text(font, "a third camera, rendered to a texture", .{ 24, height - 280 }, .{ .size = 13, .shadow = gfx.Color.rgba(0, 0, 0, 200) });
        try overlay.rect(.{ .x = 12, .y = 12, .width = 330, .height = 58 }, gfx.Color.rgba(10, 12, 20, 180));
        try overlay.text(font, try std.fmt.bufPrint(&hud_buffer, "{d:.0} fps · gpu {d:.2} ms · 3 views", .{ stage.fps, stage.gpu_ms }), .{ 24, 20 }, .{ .size = 16 });
        try overlay.text(font, "V right half · Space pause", .{ 24, 46 }, .{ .size = 13, .color = gfx.Color.hex(0x9aa7d0) });
        try overlay.text(font, modes[mode].name, .{ width - 20, 20 }, .{ .size = 16, .alignment = .right, .shadow = gfx.Color.rgba(0, 0, 0, 200) });

        try stage.end(try renderer.render(.{
            .views = &.{
                .{ .view = chase_view, .scene = scene, .camera = chase, .target = .{ .texture = chase_target }, .settings = .{ .shadow_distance = 50 } },
                .{
                    .scene = scene,
                    .camera = overview,
                    .draw_lists = &.{&list},
                    .target = stage.target(),
                    .region = .{ .x = 0, .y = 0, .width = half, .height = size[1] },
                    .settings = .{ .shadow_distance = 70 },
                },
                .{
                    .view = right_view,
                    .scene = scene,
                    .camera = if (modes[mode].view == .none) behind else overview,
                    .draw_lists = &.{&list},
                    .target = stage.target(),
                    .region = .{ .x = half, .y = 0, .width = size[0] - half, .height = size[1] },
                    .settings = .{ .shadow_distance = 70, .debug_view = modes[mode].view },
                },
                .{ .draw_lists = &.{&overlay}, .target = stage.target() },
            },
            .delta_time = tick.dt,
        }));
    }
    try stage.finish();
}
