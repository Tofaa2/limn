//! Skeletal animation: four copies of one character, each showing one way
//! of combining clips.
//!
//!   1  cross-fade     idle -> walk -> run and back, by a single weight
//!   2  masked layer   waves from the spine up while the legs walk
//!   3  additive layer nods on top of a run without disturbing it
//!   4  both           runs, waves and nods at once
//!
//!   Space pauses time, L switches all layers off to show the base clips,
//!   A/D orbit the camera. `--frames N`, `--screenshot file.png`.
const std = @import("std");
const gfx = @import("limn");
const math = gfx.math;
const glfw = @import("glfw");
const Stage = @import("window").Stage;
const boxMesh = @import("window").boxMesh;

const Clips = struct {
    idle: u32,
    walk: u32,
    run: u32,
    wave: u32,
    nod: u32,
    /// The bone the upper body hangs off. It has to be a bone of the
    /// skeleton; a mesh node of a similar name would mask nothing.
    spine: ?u32,
};

const labels = [4][]const u8{ "cross-fade", "masked layer", "additive layer", "both layers" };

pub fn main(init: std.process.Init) !void {
    var stage = try Stage.create(init, "Limn animation", .{ .asset_cache_dir = "zig-out/asset-cache" });
    const renderer = stage.renderer;

    const scene = try renderer.createScene();
    var positions: [24][3]f32 = undefined;
    var indices: [36]u32 = undefined;
    boxMesh(.{ 9, 0.1, 5 }, &positions, &indices);
    const floor = try renderer.createModel(&.{.{
        .positions = &positions,
        .indices = &indices,
        .material = .{ .base_color = .{ 0.22, 0.23, 0.26, 1 }, .metallic = 0, .roughness = 0.7 },
    }});
    _ = try renderer.spawn(scene, .{ .model = floor, .transform = math.translation(.{ 0, -0.1, 0 }) });

    const robot = try renderer.loadModel("examples/assets/world/RobotExpressive.glb");
    const environment = try renderer.loadEnvironment("examples/assets/world/venice_sunset_1k.hdr", 24);
    try renderer.waitUntilLoaded();
    renderer.setEnvironment(scene, environment, 0.5);
    renderer.setSun(scene, .{ .direction = .{ -0.5, -0.8, -0.4 }, .color = .{ 1.0, 0.93, 0.82 }, .intensity = 5 });

    var robots: [4]gfx.Entity = undefined;
    for (&robots, 0..) |*entity, index| {
        const x = (@as(f32, @floatFromInt(index)) - 1.5) * 3.2;
        entity.* = try renderer.spawn(scene, .{
            .model = robot,
            .transform = math.mul(math.translation(.{ x, 0, 0 }), math.uniformScaling(0.5)),
        });
    }
    const clips = Clips{
        .idle = renderer.findAnimation(robot, "Idle") orelse 0,
        .walk = renderer.findAnimation(robot, "Walking") orelse 0,
        .run = renderer.findAnimation(robot, "Running") orelse 0,
        .wave = renderer.findAnimation(robot, "Wave") orelse 0,
        .nod = renderer.findAnimation(robot, "Yes") orelse 0,
        .spine = renderer.findNode(robot, "Abdomen"),
    };

    var list = gfx.DrawList.init(init.gpa);
    defer list.deinit();
    const font = renderer.defaultFont();
    var paused = false;
    var layers_on = true;
    var clock: f32 = 0;
    var orbit: f32 = 0;
    var hud_buffer: [96]u8 = undefined;

    while (stage.begin()) |tick| {
        if (stage.keyPressed(glfw.GLFW_KEY_SPACE)) paused = !paused;
        if (stage.keyPressed(glfw.GLFW_KEY_L)) layers_on = !layers_on;
        if (stage.keyDown(glfw.GLFW_KEY_A)) orbit -= tick.dt;
        if (stage.keyDown(glfw.GLFW_KEY_D)) orbit += tick.dt;
        if (!paused) clock += tick.dt;

        const gait = 1 - @cos(clock * 0.7);
        const crossfade: gfx.Pose = if (gait < 1)
            .{ .animation = clips.idle, .time = clock, .blend = .{ .animation = clips.walk, .time = clock, .weight = gait } }
        else
            .{ .animation = clips.walk, .time = clock, .blend = .{ .animation = clips.run, .time = clock, .weight = gait - 1 } };

        var masked = gfx.Pose{ .animation = clips.walk, .time = clock };
        var additive = gfx.Pose{ .animation = clips.run, .time = clock };
        var both = gfx.Pose{ .animation = clips.run, .time = clock };
        if (layers_on) {
            const wave = gfx.Pose.Blend{ .animation = clips.wave, .time = clock, .weight = 1, .root = clips.spine };
            const nod = gfx.Pose.Blend{ .animation = clips.nod, .time = clock, .weight = 1, .additive = true };
            masked.layers[0] = wave;
            additive.layers[0] = nod;
            both.layers[0] = wave;
            both.layers[1] = nod;
        }
        for (robots, [4]gfx.Pose{ crossfade, masked, additive, both }) |entity, pose| renderer.setPose(entity, pose);

        list.clear();
        for (labels, 0..) |label, index| {
            const x = (@as(f32, @floatFromInt(index)) - 1.5) * 3.2;
            try list.text3d(font, label, .{ x, 2.75, 0 }, .{ .size = 0.2 });
        }
        var gait_buffer: [48]u8 = undefined;
        const gait_text = if (gait < 1)
            try std.fmt.bufPrint(&gait_buffer, "idle {d:.0}% · walk {d:.0}%", .{ (1 - gait) * 100, gait * 100 })
        else
            try std.fmt.bufPrint(&gait_buffer, "walk {d:.0}% · run {d:.0}%", .{ (2 - gait) * 100, (gait - 1) * 100 });
        try list.text3d(font, gait_text, .{ -1.5 * 3.2, 2.45, 0 }, .{ .size = 0.13, .color = gfx.Color.hex(0x9aa7d0) });

        try list.rect(.{ .x = 12, .y = 12, .width = 330, .height = 96 }, gfx.Color.rgba(10, 12, 20, 180));
        try list.text(font, try std.fmt.bufPrint(&hud_buffer, "{d:.0} fps · gpu {d:.2} ms", .{ stage.fps, stage.gpu_ms }), .{ 24, 20 }, .{ .size = 17 });
        const rows = [_]struct { key: []const u8, label: []const u8, state: []const u8, on: bool }{
            .{ .key = "L", .label = "layers", .state = if (layers_on) "on" else "off", .on = layers_on },
            .{ .key = "Space", .label = "time", .state = if (paused) "paused" else "running", .on = !paused },
        };
        for (rows, 0..) |row, index| {
            const y = 46 + 19 * @as(f32, @floatFromInt(index));
            try list.text(font, row.key, .{ 24, y }, .{ .size = 14, .color = gfx.Color.hex(0x9aa7d0) });
            try list.text(font, row.label, .{ 80, y }, .{ .size = 14 });
            try list.text(font, row.state, .{ 230, y }, .{ .size = 14, .color = if (row.on) gfx.Color.hex(0x3ddc97) else gfx.Color.hex(0x7c8499) });
        }
        try list.text(font, "A/D orbit", .{ 24, 86 }, .{ .size = 13, .color = gfx.Color.hex(0x9aa7d0) });

        const eye = math.Vec3{ @sin(orbit) * 9.5, 2.4, @cos(orbit) * 9.5 };
        try stage.end(try renderer.render(.{
            .views = &.{.{
                .scene = scene,
                .camera = gfx.Camera.lookAt(eye, .{ 0, 1.2, 0 }),
                .draw_lists = &.{&list},
                .target = stage.target(),
                .settings = .{ .shadow_distance = 30 },
            }},
            .delta_time = tick.dt,
        }));
    }
    try stage.finish();
}
