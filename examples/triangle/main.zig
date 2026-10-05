//! The smallest program on the RHI: one pipeline, one draw, no renderer.
const std = @import("std");
const gfx = @import("limn");
const rhi = gfx.rhi;
const Window = @import("window").Window;
const frameLimit = @import("window").frameLimit;

const Push = extern struct { time: f32, aspect: f32 };

pub fn main(init: std.process.Init) !void {
    const limit = try frameLimit(init);
    const window = try Window.init(1280, 720, "RHI triangle");
    defer window.deinit();

    const device = try rhi.Device.init(init.gpa, init.io, .{
        .application_name = "triangle",
        .surface = try window.surface(true),
    });
    defer device.deinit();

    const pipeline = try device.createGraphicsPipeline(.{
        .name = "triangle",
        .vertex = @embedFile("triangle.vert.spv"),
        .fragment = @embedFile("triangle.frag.spv"),
        .color_targets = &.{.{ .format = try device.backbufferFormat() }},
        .cull = .none,
    });
    defer device.destroyPipeline(pipeline);

    var frames: u64 = 0;
    while (!window.shouldClose() and (limit == null or frames < limit.?)) {
        window.pollEvents();
        const size = window.framebufferSize();
        device.resize(size[0], size[1]);
        const frame = (try device.beginFrame()) orelse continue;
        try frame.cmd.beginRendering(.{ .color = &.{.{
            .texture = frame.backbuffer.?,
            .clear = .{ 0.02, 0.02, 0.03, 1 },
        }} });
        frame.cmd.bindPipeline(pipeline);
        frame.cmd.pushConstants(Push{
            .time = @floatCast(window.time()),
            .aspect = @as(f32, @floatFromInt(size[0])) / @as(f32, @floatFromInt(@max(size[1], 1))),
        });
        frame.cmd.drawFullscreen();
        frame.cmd.endRendering();
        try device.endFrame();
        frames += 1;
    }
    try device.waitIdle();
    if (device.validationErrorCount() != 0) return error.ValidationFailed;
}
