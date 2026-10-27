//! Simple 3D at its smallest cost: a field of boxes drawn with
//! `Settings.lightweight`, a few of them moving, and a HUD of what each
//! frame records, read from `Stats.commands`.
//!
//!   L        lightweight or everything on
//!   Up/Down  more or fewer boxes
//!   A/D      orbit
//!
//! `--boxes N` starts with N boxes; `--full 1` starts with everything on.
//! `--frames N`, `--screenshot file.png`.
const std = @import("std");
const gfx = @import("limn");
const math = gfx.math;
const glfw = @import("glfw");
const helpers = @import("window");
const Stage = helpers.Stage;

const max_boxes = 100_000;
const moving_boxes = 32;

fn boxAt(index: usize, count: usize, time: f32) math.Mat4 {
    const side: usize = @max(std.math.sqrt(count), 1);
    const column: f32 = @floatFromInt(index % side);
    const row: f32 = @floatFromInt(index / side);
    const half: f32 = @as(f32, @floatFromInt(side)) / 2;
    const lift: f32 = if (index < moving_boxes) 0.6 + 0.5 * @sin(time * 2 + column) else 0;
    return math.translation(.{ (column - half) * 1.6, lift, (row - half) * 1.6 });
}

pub fn main(init: std.process.Init) !void {
    var stage = try Stage.create(init, "Limn lightweight", .{});
    const renderer = stage.renderer;
    const scene = try renderer.scenes.create();
    const sky = gfx.SkyDesc{ .sun_direction = .{ -0.4, -0.75, -0.5 } };
    renderer.scenes.setSun(scene, gfx.skySun(sky));
    renderer.scenes.setEnvironment(scene, .{ .environment = try renderer.environments.createSky(sky), .intensity = 1 });

    var positions: [24][3]f32 = undefined;
    var indices: [36]u32 = undefined;
    helpers.boxMesh(.{ 0.5, 0.5, 0.5 }, &positions, &indices);
    const box = try renderer.models.create(&.{.{ .positions = &positions, .indices = &indices, .material = .{ .base_color = .{ 0.75, 0.45, 0.2, 1 }, .metallic = 0, .roughness = 0.6 } }});

    var count: usize = 2000;
    var full = false;
    {
        var arguments = try init.minimal.args.iterateAllocator(init.gpa);
        defer arguments.deinit();
        while (arguments.next()) |argument| {
            if (std.mem.eql(u8, argument, "--boxes")) count = std.math.clamp(try std.fmt.parseInt(usize, arguments.next() orelse return error.MissingArgument, 10), 1, max_boxes);
            if (std.mem.eql(u8, argument, "--full")) full = true;
        }
    }
    const boxes = try init.gpa.alloc(gfx.Entity, max_boxes);
    defer init.gpa.free(boxes);
    var spawned: usize = 0;
    try renderer.waitUntilLoaded();

    var list = gfx.DrawList.init(init.gpa);
    defer list.deinit();
    const font = renderer.fonts.default();
    var orbit: f32 = 0.6;
    var hud: [320]u8 = undefined;

    while (stage.begin()) |tick| {
        if (stage.keyPressed(glfw.GLFW_KEY_L)) full = !full;
        if (stage.keyPressed(glfw.GLFW_KEY_UP)) count = @min(count * 2, max_boxes);
        if (stage.keyPressed(glfw.GLFW_KEY_DOWN)) count = @max(count / 2, 1);
        if (stage.keyDown(glfw.GLFW_KEY_A)) orbit -= tick.dt * 0.8;
        if (stage.keyDown(glfw.GLFW_KEY_D)) orbit += tick.dt * 0.8;
        while (spawned < count) : (spawned += 1) boxes[spawned] = try renderer.entities.create(scene, .{ .model = box, .transform = boxAt(spawned, count, tick.time) });
        while (spawned > count) {
            spawned -= 1;
            renderer.entities.destroy(boxes[spawned]);
        }
        for (boxes[0..@min(moving_boxes, spawned)], 0..) |entity, index| renderer.entities.setTransform(entity, boxAt(index, count, tick.time));

        const stats = stage.stats();
        const work = stats.commands;
        list.clear();
        try list.rect(.{ .x = 12, .y = 12, .width = 560, .height = 112 }, gfx.Color.rgba(10, 12, 20, 190));
        try list.text(font, try std.fmt.bufPrint(&hud, "{s} · {d} boxes · {d:.0} fps · gpu {d:.2} ms · cpu {d:.3} ms\n{d} passes · {d} draws + {d} indirect · {d} dispatches\n{d} barriers · {d} binds · {d:.1} KiB written for the GPU", .{
            if (full) "everything on" else "lightweight",
            count,
            stage.fps,
            stage.gpu_ms,
            stats.cpu_ms,
            work.render_passes,
            work.draws,
            work.indirect_draws,
            work.dispatches,
            work.barriers,
            work.pipeline_binds,
            @as(f32, @floatFromInt(stats.frame_data_bytes)) / 1024,
        }), .{ 24, 20 }, .{ .size = 16 });
        try list.text(font, "L lightweight / everything on · Up/Down boxes · A/D orbit", .{ 24, 100 }, .{ .size = 13, .color = gfx.Color.hex(0x9aa7d0) });

        const reach: f32 = 10 + @as(f32, @floatFromInt(std.math.sqrt(count))) * 0.9;
        const eye = math.Vec3{ @sin(orbit) * reach, reach * 0.55, @cos(orbit) * reach };
        try stage.end(try renderer.render(.{
            .views = &.{.{
                .scene = scene,
                .camera = gfx.Camera.lookAt(eye, .{ 0, 0, 0 }),
                .draw_lists = &.{.{ .list = &list }},
                .target = stage.target(),
                .settings = if (full) .{} else gfx.Settings.lightweight,
            }},
            .delta_time = tick.dt,
        }));
    }
    try stage.finish();
}
