//! Draw lists: 2D and text drawn over or into a view. Internal to the renderer.
const std = @import("std");
const rhi = @import("../../rhi/rhi.zig");
const math = @import("../../math.zig");
const gpu = @import("../gpu.zig");
const draw_list = @import("../draw_list.zig");
const api = @import("../api.zig");
const renderer_state = @import("../state.zig");
const post_passes = @import("../passes/post.zig");
const render = @import("../renderer.zig");

const Renderer = render.Renderer;
const font_module = @import("font_baker").font;
const Mat4 = math.Mat4;
const Vec3 = math.Vec3;
const Zone = renderer_state.Zone;
const Region = api.Region;
const ViewDesc = api.ViewDesc;
const FrameArena = renderer_state.FrameArena;
const Output = renderer_state.Output;
const DrawPipelines = renderer_state.DrawPipelines;
const shaderCode = @import("pipelines.zig").shaderCode;

/// Draws the draw lists over the finished scene, or over a cleared target
/// when there is no scene.
pub fn renderDrawLists(self: *Renderer, cmd: *rhi.CommandEncoder, desc: ViewDesc, output: Output, arena: *FrameArena) !void {
    const zone = Zone.start(self.options.profiler, "draw lists");
    defer zone.stop();
    const device = self.device;
    const region = output.region;
    var any_world = false;
    var any_screen = false;
    for (desc.draw_lists) |list| {
        any_world = any_world or list.world.indices.items.len != 0;
        any_screen = any_screen or list.screen.indices.items.len != 0;
    }
    var load = output.load;
    if (!any_world and !any_screen) {
        if (load != .clear) return;
        try cmd.beginRendering(.{ .color = &.{.{ .texture = output.texture, .load = .clear, .clear = output.clear }} });
        cmd.endRendering();
        return;
    }

    cmd.beginScope("draw lists");
    defer cmd.endScope();
    const pipelines = try drawPipelines(self, output.format);
    const width: f32 = @floatFromInt(region.width);
    const height: f32 = @floatFromInt(region.height);
    const Push = extern struct {
        vertices: u64,
        indices: u64,
        transform: Mat4,
        camera_right: Vec3,
        encode_srgb: u32,
        camera_up: Vec3,
        sdf_spread: f32,
        viewport: [2]f32,
        sampler_linear: u32,
        sampler_nearest: u32,
        /// Scene depth to test against, or `invalid_id`.
        depth_texture: u32,
        /// HDR10 targets: brightness of white in nits.
        hdr_paper_white: f32,
        origin: [2]f32,
        /// 1 to read text from the three-channel field.
        sharp_text: u32,
        pad: u32 = 0,
    };
    var push = Push{
        .vertices = 0,
        .indices = 0,
        .transform = math.identity,
        .camera_right = .{ 1, 0, 0 },
        .encode_srgb = post_passes.outputEncoding(self, desc, output.format),
        .camera_up = .{ 0, 1, 0 },
        .sdf_spread = font_module.sdf_spread,
        .viewport = .{ width, height },
        .sampler_linear = device.samplerIndex(self.sampler_linear_clamp),
        .sampler_nearest = device.samplerIndex(self.sampler_nearest_clamp),
        .depth_texture = gpu.invalid_id,
        .hdr_paper_white = @max(desc.settings.hdr_paper_white, 1),
        .origin = .{ @floatFromInt(region.x), @floatFromInt(region.y) },
        .sharp_text = @intFromBool(desc.settings.sharp_text),
    };

    if (any_world) {
        const view_matrix = math.lookTo(desc.camera.position, desc.camera.forward, desc.camera.up);
        const inv_view = math.inverse(view_matrix);
        var projection = math.perspective(desc.camera.fov_y, width / height, desc.camera.near);
        projection[8] = -desc.camera.lens_shift[0] * height / width;
        projection[9] = -desc.camera.lens_shift[1];
        push.transform = math.mul(projection, view_matrix);
        push.camera_right = inv_view[0..3].*;
        push.camera_up = inv_view[4..7].*;
        try cmd.beginRendering(.{ .color = &.{.{ .texture = output.texture, .load = load, .clear = output.clear }} });
        cmd.setViewport(region.x, region.y, region.width, region.height);
        load = .load;
        push.depth_texture = if (output.depth) |texture| device.textureIndex(texture) else gpu.invalid_id;
        cmd.bindPipeline(pipelines.flat);
        for (desc.draw_lists) |list| try drawBatch(self, cmd, arena, &list.world, &push, region);
        cmd.endRendering();
    }
    if (any_screen) {
        push.transform = .{
            2 / width, 0,          0, 0,
            0,         2 / height, 0, 0,
            0,         0,          1, 0,
            -1,        -1,         0, 1,
        };
        push.depth_texture = gpu.invalid_id;
        push.camera_right = .{ 0, 0, 0 };
        push.camera_up = .{ 0, 0, 0 };
        try cmd.beginRendering(.{ .color = &.{.{ .texture = output.texture, .load = load, .clear = output.clear }} });
        cmd.setViewport(region.x, region.y, region.width, region.height);
        cmd.bindPipeline(pipelines.flat);
        for (desc.draw_lists) |list| try drawBatch(self, cmd, arena, &list.screen, &push, region);
        cmd.endRendering();
    }
}

fn drawBatch(self: *Renderer, cmd: *rhi.CommandEncoder, arena: *FrameArena, batch: *const draw_list.Batch, push: anytype, region: Region) !void {
    if (batch.indices.items.len == 0) return;
    const vertices = try arena.alloc(self.device, draw_list.Vertex, batch.vertices.items.len);
    const indices = try arena.alloc(self.device, u32, batch.indices.items.len);
    @memcpy(vertices.items, batch.vertices.items);
    @memcpy(indices.items, batch.indices.items);
    push.vertices = vertices.address;
    push.indices = indices.address;
    cmd.pushConstants(push.*);
    self.stats.draw_list_triangles += @intCast(batch.indices.items.len / 3);
    const total: u32 = @intCast(batch.indices.items.len);
    if (batch.clips.items.len == 0) {
        cmd.draw(total, 1, 0, 0);
        return;
    }
    defer cmd.setScissor(region.x, region.y, region.width, region.height);
    var first: u32 = 0;
    var clip: ?draw_list.Rect = null;
    for (batch.clips.items, 0..) |range, index| {
        if (range.first_index > first) {
            applyClip(self, cmd, clip, region);
            cmd.draw(range.first_index - first, 1, first, 0);
        }
        first = range.first_index;
        clip = range.rect;
        if (index + 1 == batch.clips.items.len and total > first) {
            applyClip(self, cmd, clip, region);
            cmd.draw(total - first, 1, first, 0);
        }
    }
}

fn applyClip(self: *Renderer, cmd: *rhi.CommandEncoder, clip: ?draw_list.Rect, region: Region) void {
    _ = self;
    const rect = clip orelse return cmd.setScissor(region.x, region.y, region.width, region.height);
    const x0 = std.math.clamp(rect.x, 0, @as(f32, @floatFromInt(region.width)));
    const y0 = std.math.clamp(rect.y, 0, @as(f32, @floatFromInt(region.height)));
    const x1 = std.math.clamp(rect.x + rect.width, x0, @as(f32, @floatFromInt(region.width)));
    const y1 = std.math.clamp(rect.y + rect.height, y0, @as(f32, @floatFromInt(region.height)));
    cmd.setScissor(
        region.x + @as(u32, @intFromFloat(@floor(x0))),
        region.y + @as(u32, @intFromFloat(@floor(y0))),
        @intFromFloat(@ceil(x1) - @floor(x0)),
        @intFromFloat(@ceil(y1) - @floor(y0)),
    );
}

fn drawPipelines(self: *Renderer, format: rhi.Format) !DrawPipelines {
    for (self.draw_pipelines.items) |entry| if (entry.format == format) return entry;
    const entry = DrawPipelines{
        .format = format,
        .flat = try self.device.createGraphicsPipeline(.{
            .name = "draw list",
            .vertex = shaderCode("draw.vert.spv"),
            .fragment = shaderCode("draw.frag.spv"),
            .color_targets = &.{.{ .format = format, .blend = .alpha }},
            .cull = .none,
        }),
        .depth_tested = try self.device.createGraphicsPipeline(.{
            .name = "draw list (world)",
            .vertex = shaderCode("draw.vert.spv"),
            .fragment = shaderCode("draw.frag.spv"),
            .color_targets = &.{.{ .format = format, .blend = .alpha }},
            .depth = .{ .write = false, .compare = .greater_or_equal },
            .cull = .none,
        }),
    };
    try self.draw_pipelines.append(self.gpa, entry);
    return entry;
}
