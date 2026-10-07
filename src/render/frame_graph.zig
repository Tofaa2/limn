//! A frame as a graph of passes, ordered by the resources each reads and
//! makes; passes whose results nothing asks for are culled. A resource is
//! one stage of a target: each pass that writes a picture makes a new one.
const std = @import("std");

/// A graph over the resources named by the enum `Resource`, whose passes
/// are handed a `*Context`.
pub fn Graph(comptime Resource: type, comptime Context: type) type {
    return struct {
        pub const Set = std.EnumSet(Resource);

        pub const Pass = struct {
            name: []const u8,
            reads: Set = .initEmpty(),
            writes: Set = .initEmpty(),
            /// Runs whether or not anything reads what it writes.
            always: bool = false,
            run: *const fn (context: *Context) anyerror!void,
        };

        pub const max_passes = 64;

        /// Indices into `passes` in a run order that makes `wanted`: each after
        /// the passes it depends on, otherwise as declared. Passes that do not
        /// lead to `wanted` and are not `always` are left out. Fails if two
        /// passes make the same resource, one reads a resource none makes, or
        /// passes form a cycle.
        pub fn order(passes: []const Pass, wanted: Set, buffer: *[max_passes]u8) ![]const u8 {
            if (passes.len > max_passes) return error.TooManyPasses;
            var maker: std.EnumArray(Resource, ?u8) = .initFill(null);
            for (passes, 0..) |pass, index| {
                var written = pass.writes.iterator();
                while (written.next()) |resource| {
                    if (maker.get(resource) != null) return error.ResourceMadeTwice;
                    maker.set(resource, @intCast(index));
                }
            }

            var needed: [max_passes]bool = @splat(false);
            var stack: [max_passes]u8 = undefined;
            var depth: usize = 0;
            for (passes, 0..) |pass, index| {
                if (!pass.always and pass.writes.intersectWith(wanted).count() == 0) continue;
                needed[index] = true;
                stack[depth] = @intCast(index);
                depth += 1;
            }
            while (depth != 0) {
                depth -= 1;
                var read = passes[stack[depth]].reads.iterator();
                while (read.next()) |resource| {
                    const from = maker.get(resource) orelse return error.ResourceNeverMade;
                    if (needed[from]) continue;
                    needed[from] = true;
                    stack[depth] = from;
                    depth += 1;
                }
            }

            var placed: [max_passes]bool = @splat(false);
            var count: usize = 0;
            var total: usize = 0;
            for (needed[0..passes.len]) |is_needed| total += @intFromBool(is_needed);
            while (count < total) {
                const before = count;
                for (passes, 0..) |pass, index| {
                    if (!needed[index] or placed[index]) continue;
                    var ready = true;
                    var read = pass.reads.iterator();
                    while (read.next()) |resource| {
                        if (!placed[maker.get(resource).?]) ready = false;
                    }
                    if (!ready) continue;
                    placed[index] = true;
                    buffer[count] = @intCast(index);
                    count += 1;
                }
                if (count == before) return error.PassesDependInACircle;
            }
            return buffer[0..count];
        }

        /// Runs the passes `wanted` needs, in dependency order.
        pub fn run(passes: []const Pass, wanted: Set, context: *Context) !void {
            var buffer: [max_passes]u8 = undefined;
            for (try order(passes, wanted, &buffer)) |index| try passes[index].run(context);
        }
    };
}

test "passes run after what they read, and unused ones are left out" {
    const Resource = enum { a, b, c, unused };
    const Trace = struct {
        ran: [8]u8 = undefined,
        count: usize = 0,

        fn note(self: *@This(), letter: u8) void {
            self.ran[self.count] = letter;
            self.count += 1;
        }
    };
    const G = Graph(Resource, Trace);
    const Passes = struct {
        fn makesC(trace: *Trace) !void {
            trace.note('c');
        }
        fn makesB(trace: *Trace) !void {
            trace.note('b');
        }
        fn makesA(trace: *Trace) !void {
            trace.note('a');
        }
        fn makesUnused(trace: *Trace) !void {
            trace.note('u');
        }
        fn sideEffect(trace: *Trace) !void {
            trace.note('s');
        }
    };
    const passes = [_]G.Pass{
        .{ .name = "c from b", .reads = G.Set.initOne(.b), .writes = G.Set.initOne(.c), .run = Passes.makesC },
        .{ .name = "unused from a", .reads = G.Set.initOne(.a), .writes = G.Set.initOne(.unused), .run = Passes.makesUnused },
        .{ .name = "b from a", .reads = G.Set.initOne(.a), .writes = G.Set.initOne(.b), .run = Passes.makesB },
        .{ .name = "a", .writes = G.Set.initOne(.a), .run = Passes.makesA },
        .{ .name = "side effect", .reads = G.Set.initOne(.a), .always = true, .run = Passes.sideEffect },
    };
    var trace = Trace{};
    try G.run(&passes, G.Set.initOne(.c), &trace);
    try std.testing.expectEqualStrings("asbc", trace.ran[0..trace.count]);

    var buffer: [G.max_passes]u8 = undefined;
    const circle = [_]G.Pass{
        .{ .name = "a from b", .reads = G.Set.initOne(.b), .writes = G.Set.initOne(.a), .run = Passes.makesA },
        .{ .name = "b from a", .reads = G.Set.initOne(.a), .writes = G.Set.initOne(.b), .run = Passes.makesB },
    };
    try std.testing.expectError(error.PassesDependInACircle, G.order(&circle, G.Set.initOne(.a), &buffer));
    const twice = [_]G.Pass{
        .{ .name = "a", .writes = G.Set.initOne(.a), .run = Passes.makesA },
        .{ .name = "a again", .writes = G.Set.initOne(.a), .run = Passes.makesA },
    };
    try std.testing.expectError(error.ResourceMadeTwice, G.order(&twice, G.Set.initOne(.a), &buffer));
}
