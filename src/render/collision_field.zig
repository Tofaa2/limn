//! Signed distance field of a mesh on a cubic grid, negative inside.
//! Used to keep hair out of irregular shapes. Internal to the renderer.
const std = @import("std");

pub const Field = struct {
    /// Cells along each side.
    size: u32,
    /// Lowest corner of the grid and a cell's side length, in mesh units.
    low: [3]f32,
    cell: f32,
    /// One distance per cell, x fastest, then y, then z.
    distances: []f32,

    pub fn deinit(self: Field, gpa: std.mem.Allocator) void {
        gpa.free(self.distances);
    }

    pub fn at(self: Field, x: usize, y: usize, z: usize) f32 {
        return self.distances[x + (y + z * self.size) * self.size];
    }
};

const Crossing = struct {
    column: u32,
    z: f32,

    fn before(_: void, a: Crossing, b: Crossing) bool {
        return if (a.column != b.column) a.column < b.column else a.z < b.z;
    }
};

/// Grid size relative to the mesh's bounds.
const room = 1.25;

/// Builds the field of a triangle mesh. The mesh should be closed, or
/// open only downward along z: space under a surface counts as inside.
pub fn build(gpa: std.mem.Allocator, positions: []const [3]f32, indices: []const u32, resolution: u32) !Field {
    if (positions.len == 0 or indices.len < 3) return error.EmptyMesh;
    const size: usize = std.math.clamp(resolution, 8, 128);
    var lowest = positions[0];
    var highest = positions[0];
    for (positions) |position| inline for (0..3) |axis| {
        lowest[axis] = @min(lowest[axis], position[axis]);
        highest[axis] = @max(highest[axis], position[axis]);
    };
    var widest: f32 = 0;
    inline for (0..3) |axis| widest = @max(widest, highest[axis] - lowest[axis]);
    const side = @max(widest, 1e-6) * room;
    const cell = side / @as(f32, @floatFromInt(size));
    var low: [3]f32 = undefined;
    inline for (0..3) |axis| low[axis] = (lowest[axis] + highest[axis]) * 0.5 - side * 0.5;

    var crossings: std.ArrayList(Crossing) = .empty;
    defer crossings.deinit(gpa);
    const nudge = [2]f32{ cell * 0.0137, cell * 0.0071 };
    var triangle: usize = 0;
    while (triangle + 2 < indices.len) : (triangle += 3) {
        const a = positions[indices[triangle]];
        const b = positions[indices[triangle + 1]];
        const c = positions[indices[triangle + 2]];
        const area = (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]);
        if (@abs(area) < 1e-20) continue;
        const first = [2]usize{
            columnOf(@min(a[0], @min(b[0], c[0])), low[0], cell, size),
            columnOf(@min(a[1], @min(b[1], c[1])), low[1], cell, size),
        };
        const last = [2]usize{
            columnOf(@max(a[0], @max(b[0], c[0])), low[0], cell, size),
            columnOf(@max(a[1], @max(b[1], c[1])), low[1], cell, size),
        };
        for (first[1]..last[1] + 1) |y| for (first[0]..last[0] + 1) |x| {
            const px = low[0] + (@as(f32, @floatFromInt(x)) + 0.5) * cell + nudge[0];
            const py = low[1] + (@as(f32, @floatFromInt(y)) + 0.5) * cell + nudge[1];
            const wa = ((b[0] - px) * (c[1] - py) - (b[1] - py) * (c[0] - px)) / area;
            const wb = ((c[0] - px) * (a[1] - py) - (c[1] - py) * (a[0] - px)) / area;
            const wc = 1 - wa - wb;
            if (wa < 0 or wb < 0 or wc < 0) continue;
            try crossings.append(gpa, .{ .column = @intCast(x + y * size), .z = wa * a[2] + wb * b[2] + wc * c[2] });
        };
    }
    std.mem.sort(Crossing, crossings.items, {}, Crossing.before);

    const inside = try gpa.alloc(bool, size * size * size);
    defer gpa.free(inside);
    @memset(inside, false);
    var start: usize = 0;
    while (start < crossings.items.len) {
        const column = crossings.items[start].column;
        var end = start;
        while (end < crossings.items.len and crossings.items[end].column == column) end += 1;
        const run = crossings.items[start..end];
        var index: usize = 0;
        var from: f32 = -std.math.inf(f32);
        if (run.len % 2 == 0) {
            from = run[0].z;
            index = 1;
        }
        while (index < run.len) : (index += 2) {
            const to = run[index].z;
            for (0..size) |z| {
                const middle = low[2] + (@as(f32, @floatFromInt(z)) + 0.5) * cell;
                if (middle > from and middle < to) inside[column + z * size * size] = true;
            }
            if (index + 1 < run.len) from = run[index + 1].z;
        }
        start = end;
    }

    const distances = try gpa.alloc(f32, size * size * size);
    errdefer gpa.free(distances);
    const far = @as(f32, @floatFromInt(size)) * 4;
    for (0..size) |z| for (0..size) |y| for (0..size) |x| {
        const here = x + (y + z * size) * size;
        var beside = false;
        if (x > 0 and inside[here - 1] != inside[here]) beside = true;
        if (x + 1 < size and inside[here + 1] != inside[here]) beside = true;
        if (y > 0 and inside[here - size] != inside[here]) beside = true;
        if (y + 1 < size and inside[here + size] != inside[here]) beside = true;
        if (z > 0 and inside[here - size * size] != inside[here]) beside = true;
        if (z + 1 < size and inside[here + size * size] != inside[here]) beside = true;
        distances[here] = if (beside) 0.5 else far;
    };
    sweep(distances, size, false);
    sweep(distances, size, true);
    for (distances, inside) |*distance, is_inside| distance.* *= if (is_inside) -cell else cell;
    return .{ .size = @intCast(size), .low = low, .cell = cell, .distances = distances };
}

fn columnOf(value: f32, low: f32, cell: f32, size: usize) usize {
    const column = @floor((value - low) / cell);
    return @intFromFloat(std.math.clamp(column, 0, @as(f32, @floatFromInt(size - 1))));
}

/// One distance-propagation pass over the cells, forward or in reverse.
fn sweep(distances: []f32, size: usize, backward: bool) void {
    const count = size * size * size;
    const extent: isize = @intCast(size);
    for (0..count) |step| {
        const here = if (backward) count - 1 - step else step;
        const x: isize = @intCast(here % size);
        const y: isize = @intCast((here / size) % size);
        const z: isize = @intCast(here / (size * size));
        var least = distances[here];
        var dz: isize = -1;
        while (dz <= 0) : (dz += 1) {
            var dy: isize = -1;
            while (dy <= 1) : (dy += 1) {
                var dx: isize = -1;
                while (dx <= 1) : (dx += 1) {
                    if (dz == 0 and (dy > 0 or (dy == 0 and dx >= 0))) continue;
                    const sign: isize = if (backward) -1 else 1;
                    const nx = x + dx * sign;
                    const ny = y + dy * sign;
                    const nz = z + dz * sign;
                    if (nx < 0 or ny < 0 or nz < 0 or nx >= extent or ny >= extent or nz >= extent) continue;
                    const way = @sqrt(@as(f32, @floatFromInt(dx * dx + dy * dy + dz * dz)));
                    const neighbour: usize = @intCast(nx + (ny + nz * extent) * extent);
                    least = @min(least, distances[neighbour] + way);
                }
            }
        }
        distances[here] = least;
    }
}

test "a box is negative inside and grows with distance outside" {
    const gpa = std.testing.allocator;
    const positions = [_][3]f32{
        .{ -1, -1, -1 }, .{ 1, -1, -1 }, .{ 1, 1, -1 }, .{ -1, 1, -1 },
        .{ -1, -1, 1 },  .{ 1, -1, 1 },  .{ 1, 1, 1 },  .{ -1, 1, 1 },
    };
    const indices = [_]u32{
        0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7,
        0, 1, 5, 0, 5, 4, 2, 3, 7, 2, 7, 6,
        1, 2, 6, 1, 6, 5, 3, 0, 4, 3, 4, 7,
    };
    const field = try build(gpa, &positions, &indices, 32);
    defer field.deinit(gpa);
    const middle = field.at(16, 16, 16);
    try std.testing.expect(middle < -0.8 and middle > -1.2);
    try std.testing.expect(field.at(0, 16, 16) > 0.1);
    try std.testing.expect(field.at(16, 16, 31) > 0.1);
    try std.testing.expect(field.at(0, 0, 0) > field.at(0, 16, 16));
}
