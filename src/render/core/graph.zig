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
    /// Light bounced off nearby surfaces, found with the occlusion.
    occluder_light,
    /// The view's output, in display colors.
    picture,
};

/// A target of one frame's graph.
pub const Target = enum(u16) { _ };

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
    /// Runs whether or not anything uses what it writes.
    always: bool = false,
    /// Wrap the pass in a profiler scope of its name.
    scope: bool = true,
};

pub const max_passes = 96;
pub const max_targets = 128;
const max_links = 768;
const max_colors = 256;

const Span = struct { first: u16 = 0, count: u16 = 0 };

const Pass = struct {
    name: [:0]const u8,
    stage: Stage,
    reads: Span,
    writes: Span,
    color: Span,
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
    slots: std.EnumArray(Slot, ?Target) = .initFill(null),

    /// Empties a graph in place. Unlike assigning `Graph{}`, it does not
    /// write the storage of passes and targets that are not there yet.
    pub fn clear(self: *Graph) void {
        self.node_count = 0;
        self.pass_count = 0;
        self.link_count = 0;
        self.color_count = 0;
        self.slots = .initFill(null);
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
        @memcpy(self.colors[self.color_count..][0..desc.color.len], desc.color);
        self.color_count += desc.color.len;
        self.passes[self.pass_count] = .{
            .name = desc.name,
            .stage = desc.stage,
            .reads = try self.link(desc.reads),
            .writes = try self.link(desc.writes),
            .color = .{ .first = @intCast(self.color_count - desc.color.len), .count = @intCast(desc.color.len) },
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
        var live: [max_passes]bool = @splat(false);
        var position = self.pass_count;
        while (position > 0) {
            position -= 1;
            const pass = &self.passes[sorted[position]];
            var runs = pass.always;
            for (self.linked(pass.writes)) |target| runs = runs or needed[@intFromEnum(target)];
            for (self.colored(pass.color)) |color| runs = runs or needed[@intFromEnum(color.target)];
            if (pass.depth) |depth| runs = runs or needed[@intFromEnum(depth.target)];
            if (!runs) continue;
            live[position] = true;
            for (self.linked(pass.reads)) |target| needed[@intFromEnum(target)] = true;
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

    /// Runs the planned passes. Targets a pass names are in the shader-read
    /// state when it runs, apart from the attachments rendering has begun
    /// into, and are returned to it afterwards.
    pub fn execute(self: *Graph, gpa: std.mem.Allocator, device: *rhi.Device, cmd: *rhi.CommandEncoder, pool: *targets.Pool, frame: u64) !void {
        const planned = try self.plan();
        var held: [max_targets]bool = @splat(false);
        defer for (self.nodes[0..self.node_count], 0..) |made, index| {
            if (held[index]) pool.release(made.texture.?);
        };
        for (planned.passes(), 0..) |index, step| {
            const pass = &self.passes[index];
            for (self.nodes[0..self.node_count], 0..) |*made, target| {
                const desc = made.transient orelse continue;
                if (held[target] or !made.used or made.first != step) continue;
                made.texture = try pool.acquire(gpa, device, desc, frame);
                held[target] = true;
            }
            if (pass.scope) cmd.beginScope(pass.name);
            for (self.linked(pass.reads)) |target| cmd.transition(self.texture(target), .shader_read);
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
            for (self.colored(pass.color)) |color| cmd.transition(self.texture(color.target), .shader_read);
            if (pass.depth) |depth| cmd.transition(self.texture(depth.target), .shader_read);
            for (self.linked(pass.writes)) |target| cmd.transition(self.texture(target), .shader_read);
            for (self.nodes[0..self.node_count], 0..) |made, target| {
                if (!held[target] or made.last != step) continue;
                pool.release(made.texture.?);
                held[target] = false;
            }
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
