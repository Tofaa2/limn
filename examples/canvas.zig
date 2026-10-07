//! A purely 2D application: no scene, just a draw list rendered to the
//! window. Shows shapes, sprites, a 2D camera and text.
const std = @import("std");
const gfx = @import("limn");
const Window = @import("window").Window;
const frameLimit = @import("window").frameLimit;
const canvas_scene = @import("canvas_scene.zig");

pub fn main(init: std.process.Init) !void {
    const limit = try frameLimit(init);
    const window = try Window.init(1280, 720, "Limn canvas");
    defer window.deinit();

    const renderer = try gfx.Renderer.init(init.gpa, init.io, .{
        .application_name = "canvas",
        .pipeline_cache_path = "zig-out/pipeline.cache",
        .surface = try window.surface(false),
    });
    defer renderer.deinit();

    const assets = try canvas_scene.Assets.init(renderer);
    defer assets.deinit(renderer);
    var list = gfx.DrawList.init(init.gpa);
    defer list.deinit();

    var frames: u64 = 0;
    var fps_buffer: [32]u8 = undefined;
    var fps_text: []const u8 = "";
    var fps_time = window.time();
    var fps_frames: u32 = 0;
    while (!window.shouldClose() and (limit == null or frames < limit.?)) {
        window.pollEvents();
        const size = window.framebufferSize();
        renderer.resize(size[0], size[1]);
        const now = window.time();

        list.clear();
        try canvas_scene.draw(&list, renderer.defaultFont(), assets, .{ @floatFromInt(size[0]), @floatFromInt(size[1]) }, @floatCast(now));
        try list.text(renderer.defaultFont(), fps_text, .{ @as(f32, @floatFromInt(size[0])) * 0.5, 16 }, .{ .size = 20, .alignment = .center });

        // No scene: the renderer clears to `clear_color` and draws the list.
        if (try renderer.render(.{ .views = &.{.{ .draw_lists = &.{&list}, .clear_color = .{ 0.02, 0.025, 0.045, 1 } }} })) {
            frames += 1;
            fps_frames += 1;
        } else {
            try init.io.sleep(std.Io.Duration.fromMilliseconds(10), .awake);
        }
        if (now - fps_time >= 0.5) {
            fps_text = try std.fmt.bufPrint(&fps_buffer, "{d:.0} fps", .{@as(f64, @floatFromInt(fps_frames)) / (now - fps_time)});
            fps_time = now;
            fps_frames = 0;
        }
    }
    try renderer.device.waitIdle();
    if (renderer.device.validationErrorCount() != 0) return error.ValidationFailed;
}
