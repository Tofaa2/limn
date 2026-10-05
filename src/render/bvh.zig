//! A bounding volume hierarchy built on the CPU, for following rays in an
//! ordinary shader on GPUs without ray tracing. The same tree is used at
//! two levels: over the triangles of a mesh, built once, and over the
//! instances of a scene, built each frame.
const std = @import("std");

/// One node (`BvhNode` in trace.glsl), 32 bytes. An inner node has
/// `count` 0 and its two children at `first` and `first + 1`; a leaf
/// holds `count` items, `first` being where they start in the order the
/// build returns.
pub const Node = extern struct {
    min: [3]f32,
    first: u32,
    max: [3]f32,
    count: u32,
};

/// What `build` returns. Freed with `deinit`.
pub const Tree = struct {
    /// The root is node 0. Never empty: a tree of nothing is one leaf
    /// with no items and a box nothing can hit.
    nodes: []Node,
    /// The items in the order the leaves refer to them: `order[i]` is the
    /// index, in what was passed to `build`, of the item at place `i`.
    order: []u32,

    /// Frees the nodes and the order with the allocator `build` was given.
    pub fn deinit(self: *Tree, gpa: std.mem.Allocator) void {
        gpa.free(self.nodes);
        gpa.free(self.order);
    }
};

const Box = struct {
    min: [3]f32 = @splat(std.math.inf(f32)),
    max: [3]f32 = @splat(-std.math.inf(f32)),

    fn add(self: *Box, lo: [3]f32, hi: [3]f32) void {
        inline for (0..3) |axis| {
            self.min[axis] = @min(self.min[axis], lo[axis]);
            self.max[axis] = @max(self.max[axis], hi[axis]);
        }
    }

    fn halfArea(self: Box) f32 {
        const x = self.max[0] - self.min[0];
        const y = self.max[1] - self.min[1];
        const z = self.max[2] - self.min[2];
        if (x < 0) return 0;
        return x * y + y * z + z * x;
    }
};

const bins = 12;

/// Builds a tree over items given by their boxes (`lo[i]` to `hi[i]`),
/// splitting where the surface area heuristic says rays are saved most,
/// until no leaf holds more than `leaf_size` items.
pub fn build(gpa: std.mem.Allocator, lo: []const [3]f32, hi: []const [3]f32, leaf_size: u32) !Tree {
    std.debug.assert(lo.len == hi.len);
    const count: u32 = @intCast(lo.len);
    const order = try gpa.alloc(u32, count);
    errdefer gpa.free(order);
    for (order, 0..) |*slot, index| slot.* = @intCast(index);
    var nodes: std.ArrayList(Node) = .empty;
    errdefer nodes.deinit(gpa);
    try nodes.ensureTotalCapacity(gpa, @max(@as(usize, count) * 2, 1));

    var root = Box{};
    for (lo, hi) |low, high| root.add(low, high);
    nodes.appendAssumeCapacity(.{ .min = root.min, .first = 0, .max = root.max, .count = count });
    if (count == 0) return .{ .nodes = try nodes.toOwnedSlice(gpa), .order = order };

    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(gpa);
    try stack.append(gpa, 0);
    while (stack.pop()) |node_index| {
        const node = nodes.items[node_index];
        if (node.count <= leaf_size) continue;
        const items = order[node.first..][0..node.count];

        // Where the middles of the items lie: the split is searched there.
        var middles = Box{};
        for (items) |item| {
            var middle: [3]f32 = undefined;
            inline for (0..3) |axis| middle[axis] = (lo[item][axis] + hi[item][axis]) * 0.5;
            middles.add(middle, middle);
        }
        var best_cost = std.math.inf(f32);
        var best_axis: usize = 0;
        var best_bin: usize = 0;
        for (0..3) |axis| {
            const extent = middles.max[axis] - middles.min[axis];
            if (!(extent > 1e-12)) continue;
            var boxes: [bins]Box = @splat(.{});
            var counts: [bins]u32 = @splat(0);
            const scale = bins / extent;
            for (items) |item| {
                const middle = (lo[item][axis] + hi[item][axis]) * 0.5;
                const bin: usize = @min(@as(usize, @intFromFloat(@max((middle - middles.min[axis]) * scale, 0))), bins - 1);
                boxes[bin].add(lo[item], hi[item]);
                counts[bin] += 1;
            }
            // Cost of every place to cut, from what lies to its right.
            var right_area: [bins]f32 = undefined;
            var right_count: [bins]u32 = undefined;
            var running = Box{};
            var total: u32 = 0;
            var bin: usize = bins;
            while (bin > 1) {
                bin -= 1;
                running.add(boxes[bin].min, boxes[bin].max);
                total += counts[bin];
                right_area[bin] = running.halfArea();
                right_count[bin] = total;
            }
            running = .{};
            total = 0;
            for (1..bins) |cut| {
                running.add(boxes[cut - 1].min, boxes[cut - 1].max);
                total += counts[cut - 1];
                if (total == 0 or right_count[cut] == 0) continue;
                const cost = running.halfArea() * @as(f32, @floatFromInt(total)) + right_area[cut] * @as(f32, @floatFromInt(right_count[cut]));
                if (cost < best_cost) {
                    best_cost = cost;
                    best_axis = axis;
                    best_bin = cut;
                }
            }
        }

        var left_count: u32 = 0;
        if (best_cost < std.math.inf(f32)) {
            const extent = middles.max[best_axis] - middles.min[best_axis];
            const scale = bins / extent;
            // Items left of the cut to the front.
            var back: usize = items.len;
            var front: usize = 0;
            while (front < back) {
                const item = items[front];
                const middle = (lo[item][best_axis] + hi[item][best_axis]) * 0.5;
                const bin: usize = @min(@as(usize, @intFromFloat(@max((middle - middles.min[best_axis]) * scale, 0))), bins - 1);
                if (bin < best_bin) {
                    front += 1;
                } else {
                    back -= 1;
                    std.mem.swap(u32, &items[front], &items[back]);
                }
            }
            left_count = @intCast(front);
        }
        // Items all in one place cannot be told apart: halve them.
        if (left_count == 0 or left_count == node.count) left_count = node.count / 2;

        var left = Box{};
        var right = Box{};
        for (items[0..left_count]) |item| left.add(lo[item], hi[item]);
        for (items[left_count..]) |item| right.add(lo[item], hi[item]);
        const child: u32 = @intCast(nodes.items.len);
        try nodes.append(gpa, .{ .min = left.min, .first = node.first, .max = left.max, .count = left_count });
        try nodes.append(gpa, .{ .min = right.min, .first = node.first + left_count, .max = right.max, .count = node.count - left_count });
        nodes.items[node_index].first = child;
        nodes.items[node_index].count = 0;
        try stack.append(gpa, child);
        try stack.append(gpa, child + 1);
    }
    return .{ .nodes = try nodes.toOwnedSlice(gpa), .order = order };
}

test "every item ends up in exactly one leaf whose box holds it" {
    const gpa = std.testing.allocator;
    var random = std.Random.DefaultPrng.init(3);
    const rng = random.random();
    var lo: [500][3]f32 = undefined;
    var hi: [500][3]f32 = undefined;
    for (&lo, &hi) |*low, *high| {
        inline for (0..3) |axis| {
            low[axis] = rng.float(f32) * 100;
            high[axis] = low[axis] + rng.float(f32) * 3;
        }
    }
    // A run of identical items, which no cut can separate.
    for (100..140) |index| {
        lo[index] = .{ 5, 5, 5 };
        hi[index] = .{ 6, 6, 6 };
    }
    var tree = try build(gpa, &lo, &hi, 4);
    defer tree.deinit(gpa);
    var seen: [500]u32 = @splat(0);
    for (tree.nodes) |node| {
        if (node.count == 0) {
            try std.testing.expect(node.first + 1 < tree.nodes.len);
            continue;
        }
        try std.testing.expect(node.count <= 4);
        for (tree.order[node.first..][0..node.count]) |item| {
            seen[item] += 1;
            inline for (0..3) |axis| {
                try std.testing.expect(node.min[axis] <= lo[item][axis]);
                try std.testing.expect(node.max[axis] >= hi[item][axis]);
            }
        }
    }
    for (seen) |times| try std.testing.expectEqual(@as(u32, 1), times);
}

test "a tree of nothing is one empty leaf" {
    var tree = try build(std.testing.allocator, &.{}, &.{}, 4);
    defer tree.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), tree.nodes.len);
    try std.testing.expectEqual(@as(u32, 0), tree.nodes[0].count);
}
