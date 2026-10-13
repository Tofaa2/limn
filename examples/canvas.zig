//! A purely 2D application: no scene, just a draw list rendered to the
//! window. Shows shapes, sprites, a 2D camera and text. With `--lit` the
//! picture goes through bloom, exposure and tone mapping like a scene, and
//! only the frame rate is drawn over the result. `--effects` adds light
//! blended additively, a layer drawn out of order and a panel drawn with
//! the shader in `examples/shaders/scanlines.slang`.
const std = @import("std");
const gfx = @import("limn");
const Stage = @import("window").Stage;
const canvas_scene = @import("canvas_scene.zig");

pub fn main(init: std.process.Init) !void {
    var stage = try Stage.create(init, "Limn canvas", .{});
    const renderer = stage.renderer;

    const assets = try canvas_scene.Assets.init(renderer);
    var list = gfx.DrawList.init(init.gpa);
    defer list.deinit();
    var overlay = gfx.DrawList.init(init.gpa);
    defer overlay.deinit();
    var lit = false;
    var effects = false;
    {
        var arguments = try init.minimal.args.iterateAllocator(init.gpa);
        defer arguments.deinit();
        while (arguments.next()) |argument| {
            if (std.mem.eql(u8, argument, "--lit")) lit = true;
            if (std.mem.eql(u8, argument, "--effects")) effects = true;
        }
    }

    const scanlines = try renderer.canvas.createShader(@embedFile("scanlines.frag.spv"));
    var fps_buffer: [32]u8 = undefined;
    while (stage.begin()) |tick| {
        list.clear();
        overlay.clear();
        const size = [2]f32{ @floatFromInt(tick.size[0]), @floatFromInt(tick.size[1]) };
        try canvas_scene.draw(&list, renderer.fonts.default(), assets, size, tick.time);
        if (effects) {
            try list.setLayer(-1);
            try list.rect(.{ .x = size[0] * 0.5 - 260, .y = size[1] * 0.5 - 150, .width = 520, .height = 300 }, gfx.Color.rgba(40, 60, 120, 255));
            try list.setLayer(1);
            try list.setBlend(.additive);
            for (0..5) |index| {
                const phase = tick.time * 0.8 + @as(f32, @floatFromInt(index)) * 1.3;
                try list.circle(.{ size[0] * 0.5 + @cos(phase) * 220, size[1] * 0.5 + @sin(phase * 1.3) * 120 }, 46, gfx.Color.rgba(255, 150, 60, 120));
            }
            try list.setBlend(.alpha);
            try list.setShader(scanlines);
            try list.roundedRect(.{ .x = 40, .y = size[1] - 320, .width = 300, .height = 110 }, gfx.Color.rgba(30, 200, 160, 255), .{ .radius = 12 });
            try list.text(renderer.fonts.default(), "custom shader", .{ 62, size[1] - 280 }, .{ .size = 30 });
            try list.setShader(null);
            try list.setLayer(0);
        }
        const fps_text = try std.fmt.bufPrint(&fps_buffer, "{d:.0} fps", .{stage.fps});
        try overlay.text(renderer.fonts.default(), fps_text, .{ size[0] * 0.5, 16 }, .{ .size = 20, .alignment = .center });

        try stage.end(try renderer.render(.{
            .views = &.{.{
                .draw_lists = &.{ .{ .list = &list, .stage = if (lit) .scene else .overlay }, .{ .list = &overlay } },
                .clear_color = .{ 0.02, 0.025, 0.045, 1 },
                .target = stage.target(),
                .settings = .{ .post = .{ .automatic_exposure = false, .bloom = 0.25 } },
            }},
            .delta_time = tick.dt,
        }));
    }
    assets.deinit(renderer);
    try stage.finish();
}
