//! Draw lists: 2D shapes, images and text drawn into a view.
const canvas_push = @import("../shaders/push/canvas.zig");
const output_feature = @import("output.zig");
const std = @import("std");
const rhi = @import("../../rhi/rhi.zig");
const math = @import("../../math.zig");
const view_math = @import("../renderer/view_math.zig");
const hooks_feature = @import("hooks.zig");
const gpu = @import("../gpu.zig");
const draw_list = @import("../draw_list.zig");
const api = @import("../api.zig");
const features = @import("../core/features.zig");
const renderer_state = @import("../state.zig");
const render = @import("../renderer.zig");
const font_module = @import("font_baker").font;

const Renderer = render.Renderer;
const ViewContext = features.ViewContext;
const Mat4 = math.Mat4;
const Vec3 = math.Vec3;
const Region = api.Region;
const Output = renderer_state.Output;

pub const name = "canvas";

pub const Settings = struct {
    /// Draw text from a three-channel distance field, which keeps corners sharp
    /// at large sizes. False uses the single-channel field.
    sharp_text: bool = true,
};

pub fn preset(quality: api.Quality) Settings {
    _ = quality;
    return .{};
}

pub fn resolve(setting: *Settings, r: *features.Resolve) void {
    _ = setting;
    _ = r;
}

const max_shaders = 8;

/// `Renderer.canvas`: custom draw list shaders, and what the renderer keeps
/// to draw lists with.
pub const Canvas = struct {
    internal: Internal = .{},

    /// Not part of the API.
    pub const Internal = struct {
        shaders: [max_shaders]?[]u32 = @splat(null),
        /// Raised each time a slot's shader is destroyed.
        generations: [max_shaders]u32 = @splat(0),
        pipelines: std.ArrayList(Pipeline) = .empty,
        /// This frame's uploaded batches and what to draw of them, for every view.
        uploads: std.ArrayList(Upload) = .empty,
        ranges: std.ArrayList(Range) = .empty,
        /// GPU copies of batches that have been drawn unchanged for a while.
        retained: std.ArrayList(Retained) = .empty,
    };

    const Pipeline = struct { format: rhi.Format, blend: draw_list.Blend, shader: ?draw_list.CanvasShader, pipeline: rhi.Pipeline };

    fn renderer(canvas: *Canvas) *Renderer {
        return @alignCast(@fieldParentPtr("canvas", canvas));
    }

    /// Registers a fragment shader for draw lists (`DrawList.setShader`).
    /// `spirv` includes "canvas.slang", takes its `Varyings` and returns a
    /// color through `canvasEncode`; see `examples/shaders/scanlines.slang`.
    pub fn createShader(canvas: *Canvas, spirv: []const u8) !draw_list.CanvasShader {
        const self = canvas.renderer();
        self.lock();
        defer self.unlock();
        if (spirv.len == 0 or spirv.len % 4 != 0) return error.InvalidShader;
        for (&canvas.internal.shaders, 0..) |*slot, index| {
            if (slot.* != null) continue;
            const words = try self.internal.gpa.alloc(u32, spirv.len / 4);
            @memcpy(std.mem.sliceAsBytes(words), spirv);
            slot.* = words;
            return .{ .slot = @intCast(index), .generation = canvas.internal.generations[index] };
        }
        return error.TooManyCanvasShaders;
    }

    /// False once `shader` is destroyed.
    pub fn valid(canvas: *const Canvas, shader: draw_list.CanvasShader) bool {
        return shader.slot < max_shaders and canvas.internal.shaders[shader.slot] != null and canvas.internal.generations[shader.slot] == shader.generation;
    }

    /// `Renderer.render` refuses lists drawn with the shader afterwards
    /// (`error.InvalidShader`).
    pub fn destroyShader(canvas: *Canvas, shader: draw_list.CanvasShader) void {
        const self = canvas.renderer();
        self.lock();
        defer self.unlock();
        if (!canvas.valid(shader)) return;
        const words = canvas.internal.shaders[shader.slot].?;
        self.device.waitIdle() catch {};
        var index: usize = 0;
        while (index < canvas.internal.pipelines.items.len) {
            const entry = canvas.internal.pipelines.items[index];
            if (!std.meta.eql(entry.shader, @as(?draw_list.CanvasShader, shader))) {
                index += 1;
                continue;
            }
            self.device.destroyPipeline(entry.pipeline);
            _ = canvas.internal.pipelines.swapRemove(index);
        }
        self.internal.gpa.free(words);
        canvas.internal.shaders[shader.slot] = null;
        canvas.internal.generations[shader.slot] +%= 1;
    }

    fn pipeline(canvas: *Canvas, format: rhi.Format, blend: draw_list.Blend, shader: ?draw_list.CanvasShader) !rhi.Pipeline {
        const self = canvas.renderer();
        for (canvas.internal.pipelines.items) |entry| {
            if (entry.format == format and entry.blend == blend and std.meta.eql(entry.shader, shader)) return entry.pipeline;
        }
        const custom: ?[]const u32 = if (shader) |custom_shader| canvas.internal.shaders[custom_shader.slot] else null;
        const made = try self.device.createGraphicsPipeline(.{
            .name = "draw list",
            .vertex = render.shaderCode("draw.vert.spv"),
            .fragment = if (custom) |words| std.mem.sliceAsBytes(words) else render.shaderCode("draw.frag.spv"),
            .color_targets = &.{.{ .format = format, .blend = switch (blend) {
                .alpha => .alpha,
                .premultiplied => .premultiplied,
                .additive => .additive,
                .multiply => .tint,
            } }},
            .cull = .none,
        });
        try canvas.internal.pipelines.append(self.internal.gpa, .{ .format = format, .blend = blend, .shader = shader, .pipeline = made });
        return made;
    }
};

/// Fails with `error.InvalidImage`, `error.InvalidFont` or
/// `error.InvalidShader` when `list` draws with one destroyed since.
pub fn check(canvas: *Canvas, list: *const draw_list.DrawList) !void {
    const self = canvas.renderer();
    for (list.internal.images.keys()) |image| if (!self.images.valid(image)) return error.InvalidImage;
    for (list.internal.fonts.keys()) |font| if (!self.fonts.valid(font)) return error.InvalidFont;
    for ([_]*const draw_list.Batch{ &list.internal.screen, &list.internal.world }) |batch| {
        for (batch.states.items) |state| if (state.shader) |shader| if (!canvas.valid(shader)) return error.InvalidShader;
    }
}

/// Destroys the pipelines, which are made again when next needed.
pub fn resetPipelines(canvas: *Canvas, device: *rhi.Device) void {
    for (canvas.internal.pipelines.items) |entry| device.destroyPipeline(entry.pipeline);
    canvas.internal.pipelines.clearRetainingCapacity();
}

pub fn deinit(canvas: *Canvas, gpa: std.mem.Allocator, device: *rhi.Device) void {
    resetPipelines(canvas, device);
    canvas.internal.pipelines.deinit(gpa);
    for (canvas.internal.shaders) |slot| if (slot) |words| gpa.free(words);
    for (canvas.internal.retained.items) |entry| if (entry.buffer) |buffer| device.destroyBuffer(buffer);
    canvas.internal.retained.deinit(gpa);
    canvas.internal.uploads.deinit(gpa);
    canvas.internal.ranges.deinit(gpa);
}

/// Forgets last frame's uploads and drops the GPU copies of lists that
/// are no longer drawn.
pub fn beginFrame(canvas: *Canvas, device: *rhi.Device, frame: u64) void {
    canvas.internal.uploads.clearRetainingCapacity();
    canvas.internal.ranges.clearRetainingCapacity();
    var index: usize = 0;
    while (index < canvas.internal.retained.items.len) {
        const entry = canvas.internal.retained.items[index];
        if (frame -% entry.used <= retained_idle_frames) {
            index += 1;
            continue;
        }
        if (entry.buffer) |buffer| device.destroyBuffer(buffer);
        _ = canvas.internal.retained.swapRemove(index);
    }
}

/// Frames a batch is drawn unchanged before it gets a GPU copy of its own,
/// and frames that copy outlives the batch's last use.
const retained_after_frames = 2;
const retained_idle_frames = 8;

/// A batch that has been seen before: `key` tells whether it has changed.
const Retained = struct {
    list: u64,
    world: bool,
    key: [4]u64,
    unchanged: u32 = 0,
    used: u64,
    buffer: ?rhi.Buffer = null,
    upload: Upload = undefined,
};

/// Where a batch's vertices, indices and quads are on the GPU.
const Upload = struct { vertices: u64, indices: u64, quads: u64 };

/// A run of one batch drawn in one state.
const Range = struct {
    upload: u32,
    world: bool,
    first_index: u32,
    index_count: u32,
    first_quad: u32,
    quad_count: u32,
    clip: ?draw_list.Rect,
    blend: draw_list.Blend,
    layer: i16,
    shader: ?draw_list.CanvasShader,
};

const Push = canvas_push.Push;

/// The draw lists of one stage, and what they are drawn into.
const Layer = struct {
    ctx: *ViewContext,
    stage: api.DrawStage,
    /// This layer's part of `Canvas.ranges`, in drawing order.
    first_range: u32,
    range_count: u32,
    world: bool,
    /// Scene depth the world-space items are tested against.
    depth: ?features.Target,
};

/// Copies `batch` to the GPU for this frame, or finds the copy kept from
/// earlier frames, and returns its place in `Canvas.uploads`.
fn upload(ctx: *ViewContext, list: *const draw_list.DrawList, batch: *const draw_list.Batch, world: bool) !u32 {
    const self = ctx.renderer;
    const canvas = &self.canvas;
    const device = ctx.device;
    const frame = self.internal.frame_index;
    const key = [4]u64{ list.internal.generation, batch.vertices.items.len, batch.indices.items.len, batch.quads.items.len };
    const sizes = [3]u64{
        std.mem.alignForward(u64, batch.vertices.items.len * @sizeOf(draw_list.Vertex), 16),
        std.mem.alignForward(u64, batch.indices.items.len * @sizeOf(u32), 16),
        batch.quads.items.len * @sizeOf(draw_list.Quad),
    };
    const entry: *Retained = for (canvas.internal.retained.items) |*seen| {
        if (seen.list == list.internal.id and seen.world == world) break seen;
    } else blk: {
        try canvas.internal.retained.append(self.internal.gpa, .{ .list = list.internal.id, .world = world, .key = key, .used = frame });
        break :blk &canvas.internal.retained.items[canvas.internal.retained.items.len - 1];
    };
    if (!std.meta.eql(entry.key, key)) {
        if (entry.buffer) |buffer| device.destroyBuffer(buffer);
        entry.buffer = null;
        entry.key = key;
        entry.unchanged = 0;
    } else if (entry.used != frame) entry.unchanged += 1;
    entry.used = frame;

    var result: Upload = undefined;
    if (entry.buffer != null) {
        result = entry.upload;
    } else if (entry.unchanged >= retained_after_frames) {
        const buffer = try device.createBuffer(.{ .name = "draw list", .size = @max(sizes[0] + sizes[1] + sizes[2], 16), .usage = .{ .storage = true }, .memory = .cpu_to_gpu });
        const bytes = device.mapped(buffer);
        @memcpy(bytes[0 .. batch.vertices.items.len * @sizeOf(draw_list.Vertex)], std.mem.sliceAsBytes(batch.vertices.items));
        @memcpy(bytes[sizes[0]..][0 .. batch.indices.items.len * @sizeOf(u32)], std.mem.sliceAsBytes(batch.indices.items));
        @memcpy(bytes[sizes[0] + sizes[1] ..][0 .. batch.quads.items.len * @sizeOf(draw_list.Quad)], std.mem.sliceAsBytes(batch.quads.items));
        const address = device.bufferAddress(buffer);
        result = .{ .vertices = address, .indices = address + sizes[0], .quads = address + sizes[0] + sizes[1] };
        entry.buffer = buffer;
        entry.upload = result;
    } else {
        const vertices = try ctx.arena.alloc(device, draw_list.Vertex, batch.vertices.items.len);
        const indices = try ctx.arena.alloc(device, u32, batch.indices.items.len);
        const quads = try ctx.arena.alloc(device, draw_list.Quad, batch.quads.items.len);
        @memcpy(vertices.items, batch.vertices.items);
        @memcpy(indices.items, batch.indices.items);
        @memcpy(quads.items, batch.quads.items);
        result = .{ .vertices = vertices.address, .indices = indices.address, .quads = quads.address };
    }
    try canvas.internal.uploads.append(self.internal.gpa, result);
    _ = @atomicRmw(@TypeOf(self.internal.stats.draw_list_triangles), &self.internal.stats.draw_list_triangles, .Add, @intCast(batch.indices.items.len / 3 + batch.quads.items.len * 2), .monotonic);
    return @intCast(canvas.internal.uploads.items.len - 1);
}

/// Uploads the batches of `stage` and lists what to draw of them, lowest
/// layer first; within a layer world-space items, then screen-space ones,
/// each in the order recorded.
fn gather(ctx: *ViewContext, stage: api.DrawStage, depth: ?features.Target) !?*Layer {
    const self = ctx.renderer;
    const canvas = &self.canvas;
    const first: u32 = @intCast(canvas.internal.ranges.items.len);
    var any_world = false;
    for ([_]bool{ true, false }) |world| {
        for (ctx.desc.draw_lists) |entry| {
            if (entry.stage != stage) continue;
            const batch = if (world) &entry.list.internal.world else &entry.list.internal.screen;
            if (batch.isEmpty()) continue;
            any_world = any_world or world;
            const uploaded = try upload(ctx, entry.list, batch, world);
            const index_total: u32 = @intCast(batch.indices.items.len);
            const quad_total: u32 = @intCast(batch.quads.items.len);
            var state = draw_list.Batch.State{ .first_index = 0, .first_quad = 0, .clip = null, .blend = .alpha, .layer = 0, .shader = null };
            for (0..batch.states.items.len + 1) |next| {
                const until_index = if (next < batch.states.items.len) batch.states.items[next].first_index else index_total;
                const until_quad = if (next < batch.states.items.len) batch.states.items[next].first_quad else quad_total;
                if (until_index > state.first_index or until_quad > state.first_quad) try canvas.internal.ranges.append(self.internal.gpa, .{
                    .upload = uploaded,
                    .world = world,
                    .first_index = state.first_index,
                    .index_count = until_index - state.first_index,
                    .first_quad = state.first_quad,
                    .quad_count = until_quad - state.first_quad,
                    .clip = state.clip,
                    .blend = state.blend,
                    .layer = state.layer,
                    .shader = state.shader,
                });
                if (next < batch.states.items.len) state = batch.states.items[next];
            }
        }
    }
    const made = canvas.internal.ranges.items[first..];
    if (made.len == 0) return null;
    std.sort.block(Range, made, {}, struct {
        fn before(_: void, a: Range, b: Range) bool {
            return a.layer < b.layer;
        }
    }.before);
    const layer = try ctx.make(Layer);
    layer.* = .{ .ctx = ctx, .stage = stage, .first_range = first, .range_count = @intCast(made.len), .world = any_world, .depth = if (any_world or stage == .under) depth else null };
    return layer;
}

/// Whether a view without a scene draws any list as a scene, and so needs
/// an HDR picture and the passes that take it to the target.
pub fn lit(desc: *const api.ViewDesc) bool {
    for (desc.draw_lists) |layer| if (layer.stage != .overlay) return true;
    return hooks_feature.lit(desc);
}

/// Adds a pass for the lists of each stage that has any: those drawn as a
/// scene into the HDR picture, the rest over the view's finished picture. The
/// latter also clears the picture when nothing else has drawn into the target.
pub fn declare(ctx: *ViewContext) !void {
    const g = ctx.graph;
    const depth = g.slot(.depth);
    const reads = [1]features.Target{depth orelse undefined};
    const under = try gather(ctx, .under, depth);
    const scene = try gather(ctx, .scene, depth);
    if (ctx.scene != null) {
        if (under) |layer| if (g.slot(.hdr)) |hdr| if (depth != null)
            try g.add(.{ .name = "draw lists (under the scene)", .stage = .after_opaque, .reads = &reads, .color = &.{.{ .target = hdr, .load = .load }}, .always = true }, layer, drawUnder);
        if (scene) |layer| try g.add(.{ .name = "draw lists (scene)", .stage = .resolved, .reads = reads[0..@intFromBool(layer.depth != null)], .always = true }, layer, drawResolved);
    } else if (g.slot(.hdr)) |hdr| {
        if (under) |layer| {
            layer.depth = null;
            try g.add(.{ .name = "draw lists (under)", .stage = .resolved, .color = &.{.{ .target = hdr, .load = .clear, .clear = ctx.output.clear }} }, layer, drawLit);
        }
        if (scene != null or under == null) {
            const layer = scene orelse blk: {
                const empty = try ctx.make(Layer);
                empty.* = .{ .ctx = ctx, .stage = .scene, .first_range = 0, .range_count = 0, .world = false, .depth = null };
                break :blk empty;
            };
            try g.add(.{ .name = "draw lists (scene)", .stage = .resolved, .color = &.{.{ .target = hdr, .load = if (under != null) .load else .clear, .clear = ctx.output.clear }} }, layer, drawLit);
        }
    }
    const overlay = try gather(ctx, .overlay, depth);
    if (overlay == null and ctx.output.load != .clear) return;
    const layer = overlay orelse blk: {
        const empty = try ctx.make(Layer);
        empty.* = .{ .ctx = ctx, .stage = .overlay, .first_range = 0, .range_count = 0, .world = false, .depth = null };
        break :blk empty;
    };
    try g.add(.{
        .name = "draw lists",
        .stage = .overlay,
        .reads = reads[0..@intFromBool(layer.depth != null)],
        .color = &.{.{ .target = g.slot(.picture).?, .load = ctx.output.load, .clear = ctx.output.clear }},
        .always = true,
    }, layer, drawOverlay);
}

/// Where a layer lands: the pixels of its target it covers, and how that
/// target encodes color.
const Area = struct {
    region: Region,
    format: rhi.Format,
    encoding: u32,
};

fn drawOverlay(layer: *Layer) !void {
    const ctx = layer.ctx;
    const output = ctx.output;
    try draw(layer, .{ .region = output.region, .format = output.format, .encoding = output_feature.outputEncoding(ctx.renderer, ctx.desc.*, output.format) });
}

/// Into the HDR picture of a view without a scene, which the graph has
/// begun rendering into.
fn drawLit(layer: *Layer) !void {
    const region = layer.ctx.output.region;
    try draw(layer, .{ .region = .{ .x = 0, .y = 0, .width = region.width, .height = region.height }, .format = renderer_state.hdr_format, .encoding = 0 });
}

/// Into a scene view's HDR picture where no surface is, which the graph
/// has begun rendering into.
fn drawUnder(layer: *Layer) !void {
    const info = layer.ctx.device.textureInfo(layer.ctx.graph.texture(layer.ctx.graph.slot(.hdr).?));
    try draw(layer, .{ .region = .{ .x = 0, .y = 0, .width = info.width, .height = info.height }, .format = renderer_state.hdr_format, .encoding = 0 });
}

/// Into a scene view's picture once it is antialiased, whatever size that
/// left it at.
fn drawResolved(layer: *Layer) !void {
    const ctx = layer.ctx;
    const cmd = ctx.cmd;
    const picture = ctx.scene.?.resolved.*;
    const info = ctx.device.textureInfo(picture);
    try cmd.beginRendering(.{ .color = &.{.{ .texture = picture, .load = .load }} });
    const outcome = draw(layer, .{ .region = .{ .x = 0, .y = 0, .width = info.width, .height = info.height }, .format = info.format, .encoding = 0 });
    cmd.endRendering();
    try outcome;
}

fn draw(layer: *Layer, area: Area) !void {
    const ctx = layer.ctx;
    const self = ctx.renderer;
    const canvas = &self.canvas;
    const device = ctx.device;
    const cmd = ctx.cmd;
    const desc = ctx.desc;
    const region = area.region;
    if (layer.range_count == 0) return;
    const zone = renderer_state.Zone.start(self.options.profiler, "draw lists");
    defer zone.stop();
    const width: f32 = @floatFromInt(ctx.output.region.width);
    const height: f32 = @floatFromInt(ctx.output.region.height);
    const scale = [2]f32{ @as(f32, @floatFromInt(region.width)) / width, @as(f32, @floatFromInt(region.height)) / height };
    var push = Push{
        .vertices = 0,
        .indices = 0,
        .transform = math.identity,
        .camera_right = .{ 1, 0, 0 },
        .encode_srgb = area.encoding,
        .camera_up = .{ 0, 1, 0 },
        .sdf_spread = font_module.sdf_spread,
        .viewport = .{ @floatFromInt(region.width), @floatFromInt(region.height) },
        .sampler_linear = device.samplerIndex(self.internal.sampler_linear_clamp),
        .sampler_nearest = device.samplerIndex(self.internal.sampler_nearest_clamp),
        .depth_texture = gpu.invalid_id,
        .hdr_paper_white = @max(ctx.settings.output.paper_white_nits, 1),
        .origin = .{ @floatFromInt(region.x), @floatFromInt(region.y) },
        .sharp_text = @intFromBool(ctx.settings.canvas.sharp_text),
        .time = self.internal.time,
    };
    const screen_transform = Mat4{
        2 / width, 0,          0, 0,
        0,         2 / height, 0, 0,
        0,         0,          1, 0,
        -1,        -1,         0, 1,
    };
    var world_transform = math.identity;
    var camera_right: Vec3 = .{ 0, 0, 0 };
    var camera_up: Vec3 = .{ 0, 0, 0 };
    if (layer.world) {
        const view_matrix = math.lookTo(desc.camera.position, desc.camera.forward, desc.camera.up);
        const inv_view = math.inverse(view_matrix);
        const projection = view_math.cameraProjection(desc.camera, width / height);
        world_transform = math.mul(projection, view_matrix);
        camera_right = inv_view[0..3].*;
        camera_up = inv_view[4..7].*;
    }
    const depth_texture = if (layer.depth) |depth| ctx.index(depth) else gpu.invalid_id;
    cmd.setViewport(region.x, region.y, region.width, region.height);
    var bound: ?rhi.Pipeline = null;
    var clipped = false;
    for (canvas.internal.ranges.items[layer.first_range..][0..layer.range_count]) |range| {
        const pipeline = try canvas.pipeline(area.format, range.blend, range.shader);
        if (bound == null or !std.meta.eql(bound.?, pipeline)) {
            cmd.bindPipeline(pipeline);
            bound = pipeline;
        }
        if (range.clip) |rect| {
            applyClip(cmd, rect, region, scale);
            clipped = true;
        } else if (clipped) {
            cmd.setScissor(region.x, region.y, region.width, region.height);
            clipped = false;
        }
        const uploaded = canvas.internal.uploads.items[range.upload];
        push.vertices = uploaded.vertices;
        push.indices = uploaded.indices;
        push.quads = uploaded.quads;
        push.transform = if (range.world) world_transform else screen_transform;
        push.camera_right = if (range.world) camera_right else .{ 0, 0, 0 };
        push.camera_up = if (range.world) camera_up else .{ 0, 0, 0 };
        push.depth_texture = if (range.world or layer.stage == .under) depth_texture else gpu.invalid_id;
        push.under = @intFromBool(layer.stage == .under and layer.depth != null);
        if (range.index_count != 0) {
            push.unfold = 0;
            cmd.pushConstants(push);
            cmd.draw(range.index_count, 1, range.first_index, 0);
        }
        if (range.quad_count != 0) {
            push.unfold = 1;
            cmd.pushConstants(push);
            cmd.draw(range.quad_count * 6, 1, range.first_quad * 6, 0);
        }
    }
    if (clipped) cmd.setScissor(region.x, region.y, region.width, region.height);
}

/// `rect` is in the view's pixels; `scale` takes those to the pixels of `region`.
fn applyClip(cmd: *rhi.CommandEncoder, rect: draw_list.Rect, region: Region, scale: [2]f32) void {
    const x0 = std.math.clamp(rect.x * scale[0], 0, @as(f32, @floatFromInt(region.width)));
    const y0 = std.math.clamp(rect.y * scale[1], 0, @as(f32, @floatFromInt(region.height)));
    const x1 = std.math.clamp((rect.x + rect.width) * scale[0], x0, @as(f32, @floatFromInt(region.width)));
    const y1 = std.math.clamp((rect.y + rect.height) * scale[1], y0, @as(f32, @floatFromInt(region.height)));
    cmd.setScissor(
        region.x + @as(u32, @intFromFloat(@floor(x0))),
        region.y + @as(u32, @intFromFloat(@floor(y0))),
        @intFromFloat(@ceil(x1) - @floor(x0)),
        @intFromFloat(@ceil(y1) - @floor(y0)),
    );
}
