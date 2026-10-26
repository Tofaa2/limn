//! A view's frame as a graph of passes. Each pass names a stage and the
//! targets it reads and draws into; the graph runs the passes stage by
//! stage, leaves out those whose results nothing asks for, lends short-lived
//! targets from a pool for as long as they are in use, and moves every
//! target between layouts.
const std = @import("std");
const rhi = @import("../../rhi/rhi.zig");
const targets = @import("targets.zig");

/// The points of a frame, in the order they run. Passes of one stage run in
/// the order they were added.
pub const Stage = enum {
    /// Simulation and per-frame buffers.
    prepare,
    /// Deformed geometry, the ray scene, culling, depth and visibility.
    geometry,
    shadows,
    /// What shading reads besides shadows: light lists, occlusion, probes.
    lighting,
    /// Surfaces are lit into the HDR picture.
    surfaces,
    sky,
    reflections,
    after_opaque,
    transparent,
    volumes,
    after_transparency,
    /// Antialiasing and upscaling.
    resolve,
    /// Drawn into the resolved HDR picture, before lens effects and bloom.
    resolved,
    lens,
    exposure,
    /// Into display colors, in the view's target.
    tonemap,
    after_tonemap,
    overlay,
    present,
};

/// Well-known targets, published by the pass that makes them and looked up
/// by those that use them.
pub const Slot = enum {
    depth,
    visibility,
    motion,
    /// The HDR picture as it stands.
    hdr,
    ambient_occlusion,
    /// LightDesc bounced off nearby surfaces, found with the occlusion.
    occluder_light,
    /// LightDesc from the irradiance probes gathered at a reduced resolution,
    /// which shading upsamples; absent when shading reads the probes itself.
    diffuse_gi,
    /// What shading writes for the reflection technique: each surface's
    /// mirror weight and roughness, and its normal and sky visibility.
    reflection_weight,
    reflection_surface,
    /// The view's output, in display colors.
    picture,
};

/// A target of one frame's graph.
pub const Target = enum(u16) { _ };

/// A buffer of one frame's graph, and a pass's use of one. The graph puts a
/// barrier before a pass whose uses must wait for earlier passes' writes, or
/// whose writes must wait for earlier reads.
pub const Resource = enum(u16) { _ };

pub const BufferUse = struct {
    resource: Resource,
    access: rhi.BufferAccess,
};

pub const Color = struct {
    target: Target,
    load: rhi.LoadOp = .discard,
    clear: [4]f32 = .{ 0, 0, 0, 0 },
};

pub const Depth = struct {
    target: Target,
    load: rhi.LoadOp = .load,
    clear: f32 = 0,
};

pub const PassDesc = struct {
    name: [:0]const u8,
    stage: Stage,
    /// Sampled by the pass.
    reads: []const Target = &.{},
    /// Drawn into by the pass with its own `beginRendering` calls.
    writes: []const Target = &.{},
    /// With `depth`, the attachments the graph begins rendering into before
    /// the pass runs.
    color: []const Color = &.{},
    depth: ?Depth = null,
    /// Buffers the pass reads or writes, and how.
    buffers: []const BufferUse = &.{},
    /// Runs whether or not anything uses what it writes.
    always: bool = false,
    /// Wrap the pass in a profiler scope of its name.
    scope: bool = true,
};

pub const max_passes = 96;
pub const max_targets = 128;
pub const max_resources = 64;
const max_links = 768;
const max_colors = 256;
const max_uses = 256;

const Span = struct { first: u16 = 0, count: u16 = 0 };

const Pass = struct {
    name: [:0]const u8,
    stage: Stage,
    reads: Span,
    writes: Span,
    color: Span,
    uses: Span,
    depth: ?Depth,
    always: bool,
    scope: bool,
    context: *anyopaque,
    run: *const fn (context: *anyopaque) anyerror!void,
};

const Node = struct {
    texture: ?rhi.Texture,
    /// Set for a target lent from the pool while it is in use.
    transient: ?rhi.TextureDesc = null,
    wanted: bool = false,
    /// Steps of the plan at which a pooled target is first and last named.
    used: bool = false,
    first: u16 = 0,
    last: u16 = 0,
};

/// What an imported buffer is taken to have been read by before the graph
/// runs, as views share buffers: its first write waits for all of it.
const earlier_reads = rhi.BufferAccess{ .compute_read = true, .graphics_read = true, .indirect = true, .index = true, .vertex_input = true, .transfer_read = true, .build_read = true };

const BufferNode = struct {
    buffer: rhi.Buffer,
    wanted: bool = false,
    /// While the graph runs: writes since the last barrier that waited for
    /// them, what the last write was made visible to, and reads since it.
    written: rhi.BufferAccess = .{},
    visible: rhi.BufferAccess = .{},
    read: rhi.BufferAccess = .{},
};

/// The passes to run, in order, with the lifetimes of pooled targets.
pub const Plan = struct {
    order: [max_passes]u8 = undefined,
    count: usize = 0,

    pub fn passes(self: *const Plan) []const u8 {
        return self.order[0..self.count];
    }
};

pub const Graph = struct {
    nodes: [max_targets]Node = undefined,
    node_count: usize = 0,
    passes: [max_passes]Pass = undefined,
    pass_count: usize = 0,
    links: [max_links]Target = undefined,
    link_count: usize = 0,
    colors: [max_colors]Color = undefined,
    color_count: usize = 0,
    buffers: [max_resources]BufferNode = undefined,
    buffer_count: usize = 0,
    uses: [max_uses]BufferUse = undefined,
    use_count: usize = 0,
    slots: std.EnumArray(Slot, ?Target) = .initFill(null),
    /// Set by `stage` for `record`.
    staged: ?Plan = null,

    /// Empties a graph in place. Unlike assigning `Graph{}`, it does not
    /// write the storage of passes and targets that are not there yet.
    pub fn clear(self: *Graph) void {
        self.node_count = 0;
        self.pass_count = 0;
        self.link_count = 0;
        self.color_count = 0;
        self.buffer_count = 0;
        self.use_count = 0;
        self.slots = .initFill(null);
        self.staged = null;
    }

    fn node(self: *Graph, value: Node) !Target {
        if (self.node_count == max_targets) return error.TooManyTargets;
        self.nodes[self.node_count] = value;
        self.node_count += 1;
        return @enumFromInt(self.node_count - 1);
    }

    /// A texture that exists outside the graph. It may hold a picture
    /// already and keeps the one drawn into it.
    pub fn import(self: *Graph, made: rhi.Texture) !Target {
        return self.node(.{ .texture = made });
    }

    /// A target that lives from the first pass that writes it to the last
    /// that reads it. Its texture is known only while a pass runs.
    pub fn transient(self: *Graph, desc: rhi.TextureDesc) !Target {
        return self.node(.{ .texture = null, .transient = desc });
    }

    /// A buffer that exists outside the graph. Barriers for work outside the
    /// graph stay with that work.
    pub fn importBuffer(self: *Graph, buffer: rhi.Buffer) !Resource {
        for (self.buffers[0..self.buffer_count], 0..) |known, index| {
            if (known.buffer == buffer) return @enumFromInt(index);
        }
        if (self.buffer_count == max_resources) return error.TooManyTargets;
        self.buffers[self.buffer_count] = .{ .buffer = buffer };
        self.buffer_count += 1;
        return @enumFromInt(self.buffer_count - 1);
    }

    /// Asks for what is written into `resource` to be made: passes that
    /// lead to it run.
    pub fn wantBuffer(self: *Graph, resource: Resource) void {
        self.buffers[@intFromEnum(resource)].wanted = true;
    }

    pub fn publish(self: *Graph, name: Slot, target: Target) void {
        self.slots.set(name, target);
    }

    pub fn slot(self: *const Graph, name: Slot) ?Target {
        return self.slots.get(name);
    }

    /// Asks for `target` to be made: passes that lead to it run.
    pub fn want(self: *Graph, target: Target) void {
        self.nodes[@intFromEnum(target)].wanted = true;
    }

    /// The texture behind `target`. For a transient target, only inside a
    /// pass that names it.
    pub fn texture(self: *const Graph, target: Target) rhi.Texture {
        return self.nodes[@intFromEnum(target)].texture.?;
    }

    fn link(self: *Graph, items: []const Target) !Span {
        if (self.link_count + items.len > max_links) return error.TooManyPasses;
        @memcpy(self.links[self.link_count..][0..items.len], items);
        self.link_count += items.len;
        return .{ .first = @intCast(self.link_count - items.len), .count = @intCast(items.len) };
    }

    fn linked(self: *const Graph, span: Span) []const Target {
        return self.links[span.first..][0..span.count];
    }

    fn colored(self: *const Graph, span: Span) []const Color {
        return self.colors[span.first..][0..span.count];
    }

    fn used(self: *const Graph, span: Span) []const BufferUse {
        return self.uses[span.first..][0..span.count];
    }

    /// What a pass must wait for before its buffer uses: the earlier writes
    /// its uses read or overwrite and the earlier reads its writes replace.
    /// Records the pass's uses as done.
    fn bufferWaits(self: *Graph, pass: *const Pass) struct { from: rhi.BufferAccess, to: rhi.BufferAccess } {
        var from = rhi.BufferAccess{};
        var to = rhi.BufferAccess{};
        for (self.used(pass.uses)) |use| {
            const made = &self.buffers[@intFromEnum(use.resource)];
            const reads = use.access.reads();
            const unseen: rhi.BufferAccess = @bitCast(@as(u16, @bitCast(reads)) & ~@as(u16, @bitCast(made.visible)));
            if (!made.written.empty() and (!unseen.empty() or use.access.writes())) {
                from = from.merge(made.written);
                to = to.merge(use.access);
            }
            if (use.access.writes() and !made.read.empty()) {
                from = from.merge(made.read);
                to = to.merge(use.access);
            }
        }
        for (self.used(pass.uses)) |use| {
            const made = &self.buffers[@intFromEnum(use.resource)];
            if (use.access.writes()) {
                made.written = @bitCast(@as(u16, @bitCast(use.access)) & ~@as(u16, @bitCast(use.access.reads())));
                made.visible = .{};
                made.read = .{};
            } else if (!made.written.empty()) {
                made.visible = made.visible.merge(use.access);
            }
            made.read = made.read.merge(use.access.reads());
        }
        return .{ .from = from, .to = to };
    }

    /// Adds a pass that calls `run(context)`; `context` is a pointer that
    /// stays valid until the graph has run.
    pub fn add(self: *Graph, desc: PassDesc, context: anytype, comptime run: anytype) !void {
        const Context = @TypeOf(context);
        const Thunk = struct {
            fn call(raw: *anyopaque) anyerror!void {
                return run(@as(Context, @ptrCast(@alignCast(raw))));
            }
        };
        if (self.pass_count == max_passes) return error.TooManyPasses;
        if (self.color_count + desc.color.len > max_colors) return error.TooManyPasses;
        if (self.use_count + desc.buffers.len > max_uses) return error.TooManyPasses;
        @memcpy(self.colors[self.color_count..][0..desc.color.len], desc.color);
        self.color_count += desc.color.len;
        @memcpy(self.uses[self.use_count..][0..desc.buffers.len], desc.buffers);
        self.use_count += desc.buffers.len;
        self.passes[self.pass_count] = .{
            .name = desc.name,
            .stage = desc.stage,
            .reads = try self.link(desc.reads),
            .writes = try self.link(desc.writes),
            .color = .{ .first = @intCast(self.color_count - desc.color.len), .count = @intCast(desc.color.len) },
            .uses = .{ .first = @intCast(self.use_count - desc.buffers.len), .count = @intCast(desc.buffers.len) },
            .depth = desc.depth,
            .always = desc.always,
            .scope = desc.scope,
            .context = @ptrCast(context),
            .run = Thunk.call,
        };
        self.pass_count += 1;
    }

    /// Decides which passes run and in what order, and from which pass to
    /// which each pooled target is held. Fails when a pass reads a pooled
    /// target that no earlier pass has drawn.
    pub fn plan(self: *Graph) !Plan {
        var sorted: [max_passes]u8 = undefined;
        for (0..self.pass_count) |index| {
            var place = index;
            while (place > 0 and @intFromEnum(self.passes[sorted[place - 1]].stage) > @intFromEnum(self.passes[index].stage)) : (place -= 1)
                sorted[place] = sorted[place - 1];
            sorted[place] = @intCast(index);
        }

        var needed: [max_targets]bool = undefined;
        for (self.nodes[0..self.node_count], 0..) |*made, index| {
            needed[index] = made.wanted;
            made.used = false;
        }
        var needed_buffers: [max_resources]bool = undefined;
        for (self.buffers[0..self.buffer_count], 0..) |made, index| needed_buffers[index] = made.wanted;
        var live: [max_passes]bool = @splat(false);
        var position = self.pass_count;
        while (position > 0) {
            position -= 1;
            const pass = &self.passes[sorted[position]];
            var runs = pass.always;
            for (self.linked(pass.writes)) |target| runs = runs or needed[@intFromEnum(target)];
            for (self.colored(pass.color)) |color| runs = runs or needed[@intFromEnum(color.target)];
            if (pass.depth) |depth| runs = runs or needed[@intFromEnum(depth.target)];
            for (self.used(pass.uses)) |use| runs = runs or (use.access.writes() and needed_buffers[@intFromEnum(use.resource)]);
            if (!runs) continue;
            live[position] = true;
            for (self.linked(pass.reads)) |target| needed[@intFromEnum(target)] = true;
            for (self.used(pass.uses)) |use| {
                if (!use.access.reads().empty()) needed_buffers[@intFromEnum(use.resource)] = true;
            }
            for (self.colored(pass.color)) |color| {
                if (color.load == .load) needed[@intFromEnum(color.target)] = true;
            }
            if (pass.depth) |depth| {
                if (depth.load == .load) needed[@intFromEnum(depth.target)] = true;
            }
        }

        var result = Plan{};
        var drawn: [max_targets]bool = undefined;
        for (self.nodes[0..self.node_count], 0..) |made, index| drawn[index] = made.transient == null;
        for (sorted[0..self.pass_count], 0..) |index, at| {
            if (!live[at]) continue;
            const pass = &self.passes[index];
            const step: u16 = @intCast(result.count);
            for (self.linked(pass.reads)) |target| {
                if (!drawn[@intFromEnum(target)]) return error.ReadBeforeDrawn;
                self.touch(target, step);
            }
            for (self.colored(pass.color)) |color| {
                if (color.load == .load and !drawn[@intFromEnum(color.target)]) return error.ReadBeforeDrawn;
                self.touch(color.target, step);
                drawn[@intFromEnum(color.target)] = true;
            }
            if (pass.depth) |depth| {
                if (depth.load == .load and !drawn[@intFromEnum(depth.target)]) return error.ReadBeforeDrawn;
                self.touch(depth.target, step);
                drawn[@intFromEnum(depth.target)] = true;
            }
            for (self.linked(pass.writes)) |target| {
                self.touch(target, step);
                drawn[@intFromEnum(target)] = true;
            }
            result.order[result.count] = index;
            result.count += 1;
        }
        return result;
    }

    fn touch(self: *Graph, target: Target, step: u16) void {
        const made = &self.nodes[@intFromEnum(target)];
        if (made.transient == null) return;
        if (!made.used) {
            made.first = step;
            made.used = true;
        }
        made.last = step;
    }

    /// Plans the passes and lends the pooled targets from the pool in the
    /// order the passes take and give them back, so a later target may reuse
    /// an earlier one's texture. After this `record` records the passes, on any
    /// thread, while the pool goes on to other graphs.
    pub fn stage(self: *Graph, gpa: std.mem.Allocator, device: *rhi.Device, pool: *targets.Pool, frame: u64) !void {
        const planned = try self.plan();
        var held: [max_targets]bool = @splat(false);
        defer for (self.nodes[0..self.node_count], 0..) |made, index| {
            if (held[index]) pool.release(made.texture.?);
        };
        for (0..planned.count) |step| {
            for (self.nodes[0..self.node_count], 0..) |*made, target| {
                const desc = made.transient orelse continue;
                if (held[target] or !made.used or made.first != step) continue;
                made.texture = try pool.acquire(gpa, device, desc, frame);
                held[target] = true;
            }
            for (self.nodes[0..self.node_count], 0..) |made, target| {
                if (!held[target] or made.last != step) continue;
                pool.release(made.texture.?);
                held[target] = false;
            }
        }
        self.staged = planned;
    }

    /// Stages and runs the graph.
    pub fn execute(self: *Graph, gpa: std.mem.Allocator, device: *rhi.Device, cmd: *rhi.CommandEncoder, pool: *targets.Pool, frame: u64) !void {
        try self.stage(gpa, device, pool, frame);
        try self.record(cmd);
    }

    /// Records the passes `stage` planned. Targets a pass names are in the
    /// shader-read state when it runs, apart from the attachments rendering
    /// has begun into; what it writes besides attachments is returned to it
    /// afterwards.
    pub fn record(self: *Graph, cmd: *rhi.CommandEncoder) !void {
        const planned = self.staged orelse return error.GraphNotStaged;
        self.staged = null;
        for (self.buffers[0..self.buffer_count]) |*made| {
            made.written = .{};
            made.visible = .{};
            made.read = earlier_reads;
        }
        for (planned.passes()) |index| {
            const pass = &self.passes[index];
            const waits = self.bufferWaits(pass);
            if (pass.scope) cmd.beginScope(pass.name);
            for (self.linked(pass.reads)) |target| cmd.transition(self.texture(target), .shader_read);
            cmd.dependency(waits.from, waits.to);
            const attached = pass.color.count != 0 or pass.depth != null;
            if (attached) {
                var colors: [8]rhi.ColorAttachment = undefined;
                const wanted = self.colored(pass.color);
                for (wanted, 0..) |color, at| colors[at] = .{ .texture = self.texture(color.target), .load = color.load, .clear = color.clear };
                try cmd.beginRendering(.{
                    .color = colors[0..wanted.len],
                    .depth = if (pass.depth) |depth| .{ .texture = self.texture(depth.target), .load = depth.load, .clear = depth.clear } else null,
                });
            }
            const outcome = pass.run(pass.context);
            if (attached) cmd.endRendering();
            if (pass.scope) cmd.endScope();
            try outcome;
            for (self.linked(pass.writes)) |target| cmd.transition(self.texture(target), .shader_read);
        }
    }
};

const Trace = struct {};

fn skip(_: *Trace) !void {}

fn shape(name: [:0]const u8) rhi.TextureDesc {
    return .{ .name = name, .width = 4, .height = 4, .format = .rgba8_unorm, .usage = .{ .sampled = true, .color_attachment = true } };
}

test "passes run by stage, and those nothing asks for are left out" {
    var trace = Trace{};
    var graph = Graph{};
    const output = try graph.import(std.mem.zeroes(rhi.Texture));
    const lit = try graph.transient(shape("lit"));
    const unused = try graph.transient(shape("unused"));
    graph.want(output);
    try graph.add(.{ .name = "tonemap", .stage = .tonemap, .reads = &.{lit}, .color = &.{.{ .target = output }} }, &trace, skip);
    try graph.add(.{ .name = "unused", .stage = .surfaces, .color = &.{.{ .target = unused }} }, &trace, skip);
    try graph.add(.{ .name = "fog", .stage = .volumes, .color = &.{.{ .target = lit, .load = .load }} }, &trace, skip);
    try graph.add(.{ .name = "shade", .stage = .surfaces, .color = &.{.{ .target = lit }} }, &trace, skip);
    try graph.add(.{ .name = "simulate", .stage = .prepare, .always = true }, &trace, skip);
    const planned = try graph.plan();
    try std.testing.expectEqualSlices(u8, &.{ 4, 3, 2, 0 }, planned.passes());
    try std.testing.expectEqual(@as(u16, 1), graph.nodes[@intFromEnum(lit)].first);
    try std.testing.expectEqual(@as(u16, 3), graph.nodes[@intFromEnum(lit)].last);
}

test "a pass cannot read a pooled target before it is drawn" {
    var trace = Trace{};
    var graph = Graph{};
    const output = try graph.import(std.mem.zeroes(rhi.Texture));
    const lit = try graph.transient(shape("lit"));
    graph.want(output);
    try graph.add(.{ .name = "tonemap", .stage = .tonemap, .reads = &.{lit}, .color = &.{.{ .target = output }} }, &trace, skip);
    try std.testing.expectError(error.ReadBeforeDrawn, graph.plan());
}

test "buffer uses wait for the writes they read and the reads they overwrite" {
    var trace = Trace{};
    var graph = Graph{};
    const lists = try graph.importBuffer(std.mem.zeroes(rhi.Buffer));
    try graph.add(.{ .name = "fill", .stage = .lighting, .always = true, .buffers = &.{.{ .resource = lists, .access = .{ .compute_write = true } }} }, &trace, skip);
    try graph.add(.{ .name = "shade", .stage = .surfaces, .always = true, .buffers = &.{.{ .resource = lists, .access = .{ .graphics_read = true } }} }, &trace, skip);
    try graph.add(.{ .name = "forward", .stage = .transparent, .always = true, .buffers = &.{.{ .resource = lists, .access = .{ .graphics_read = true } }} }, &trace, skip);
    try graph.add(.{ .name = "refill", .stage = .overlay, .always = true, .buffers = &.{.{ .resource = lists, .access = .{ .compute_write = true } }} }, &trace, skip);
    const fill = graph.bufferWaits(&graph.passes[0]);
    try std.testing.expect(fill.from.empty());
    const shade = graph.bufferWaits(&graph.passes[1]);
    try std.testing.expectEqual(rhi.BufferAccess{ .compute_write = true }, shade.from);
    try std.testing.expectEqual(rhi.BufferAccess{ .graphics_read = true }, shade.to);
    const forward = graph.bufferWaits(&graph.passes[2]);
    try std.testing.expect(forward.from.empty());
    const refill = graph.bufferWaits(&graph.passes[3]);
    try std.testing.expectEqual(rhi.BufferAccess{ .compute_write = true, .graphics_read = true }, refill.from);
}
