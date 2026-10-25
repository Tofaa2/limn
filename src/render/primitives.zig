//! Simple shapes as mesh data, for `Renderer.models.createPrimitive` or for
//! the application's own `MeshDesc`s. Centered on the origin, +Y up, with
//! normals, texture coordinates and counter-clockwise front faces.
const std = @import("std");
const math = @import("../math.zig");
const api = @import("api.zig");

const Vec3 = math.Vec3;

pub const Shape = union(enum) {
    /// `size` along X, Y and Z. Each face holds the whole texture.
    box: struct { size: Vec3 = .{ 1, 1, 1 } },
    /// Facing +Y in the XZ plane, `cells` squares a side.
    plane: struct { size: [2]f32 = .{ 1, 1 }, cells: [2]u32 = .{ 1, 1 } },
    /// `segments` around and `rings` from pole to pole.
    sphere: struct { radius: f32 = 0.5, segments: u32 = 32, rings: u32 = 16 },
    /// Along Y, capped.
    cylinder: struct { radius: f32 = 0.5, height: f32 = 1, segments: u32 = 32 },
    /// Along Y, point up, capped below.
    cone: struct { radius: f32 = 0.5, height: f32 = 1, segments: u32 = 32 },
    /// Along Y: `height` from tip to tip, half-spheres of `radius` at the ends.
    capsule: struct { radius: f32 = 0.25, height: f32 = 1, segments: u32 = 32, rings: u32 = 8 },
    /// In the XZ plane: `radius` to the middle of the tube, `tube` its radius.
    torus: struct { radius: f32 = 0.4, tube: f32 = 0.1, segments: u32 = 48, sides: u32 = 16 },
};

/// A shape's vertices and triangles; free with `deinit`.
pub const Mesh = struct {
    positions: [][3]f32,
    normals: [][3]f32,
    uvs: [][2]f32,
    indices: []u32,

    pub fn deinit(self: Mesh, gpa: std.mem.Allocator) void {
        gpa.free(self.positions);
        gpa.free(self.normals);
        gpa.free(self.uvs);
        gpa.free(self.indices);
    }

    /// As a `MeshDesc` that borrows this mesh's arrays.
    pub fn desc(self: Mesh, material: api.Material) api.MeshDesc {
        return .{ .positions = self.positions, .normals = self.normals, .uvs = self.uvs, .indices = self.indices, .material = material };
    }
};

/// Builds `shape`. Counts below what a shape needs (three segments, two
/// rings, one cell) are raised to it; `error.InvalidShape` for sizes that
/// are not positive and finite or for more than 2^24 vertices.
pub fn build(gpa: std.mem.Allocator, shape: Shape) !Mesh {
    var builder = Builder{ .gpa = gpa };
    errdefer builder.deinit();
    switch (shape) {
        .box => |box| {
            for (box.size) |size| try positive(size);
            const half = math.scale(box.size, 0.5);
            const faces = [6][3]Vec3{
                .{ .{ 1, 0, 0 }, .{ 0, 0, -1 }, .{ 0, 1, 0 } },
                .{ .{ -1, 0, 0 }, .{ 0, 0, 1 }, .{ 0, 1, 0 } },
                .{ .{ 0, 1, 0 }, .{ 1, 0, 0 }, .{ 0, 0, -1 } },
                .{ .{ 0, -1, 0 }, .{ 1, 0, 0 }, .{ 0, 0, 1 } },
                .{ .{ 0, 0, 1 }, .{ 1, 0, 0 }, .{ 0, 1, 0 } },
                .{ .{ 0, 0, -1 }, .{ -1, 0, 0 }, .{ 0, 1, 0 } },
            };
            for (faces) |face| {
                const normal, const right, const up = face;
                const base = builder.count();
                for ([4][2]f32{ .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 }, .{ 0, 0 } }) |uv| {
                    const along = math.add(math.scale(right, uv[0] * 2 - 1), math.scale(up, 1 - uv[1] * 2));
                    const corner = math.add(normal, along);
                    try builder.vertex(.{ corner[0] * half[0], corner[1] * half[1], corner[2] * half[2] }, normal, uv);
                }
                try builder.quad(base, base + 1, base + 2, base + 3);
            }
        },
        .plane => |plane| {
            try positive(plane.size[0]);
            try positive(plane.size[1]);
            const columns = @max(plane.cells[0], 1);
            const rows = @max(plane.cells[1], 1);
            try builder.grid(columns, rows, plane.size, struct {
                fn at(size: [2]f32, u: f32, v: f32) [2]Vec3 {
                    return .{ .{ (u - 0.5) * size[0], 0, (v - 0.5) * size[1] }, .{ 0, 1, 0 } };
                }
            }.at);
        },
        .sphere => |sphere| {
            try positive(sphere.radius);
            try builder.grid(@max(sphere.segments, 3), @max(sphere.rings, 2), sphere.radius, struct {
                fn at(radius: f32, u: f32, v: f32) [2]Vec3 {
                    const normal = around(u, v);
                    return .{ math.scale(normal, radius), normal };
                }
            }.at);
        },
        .cylinder => |cylinder| {
            try positive(cylinder.radius);
            try positive(cylinder.height);
            const segments = @max(cylinder.segments, 3);
            try builder.grid(segments, 1, [2]f32{ cylinder.radius, cylinder.height }, struct {
                fn at(size: [2]f32, u: f32, v: f32) [2]Vec3 {
                    const normal = ring(u);
                    return .{ .{ normal[0] * size[0], (0.5 - v) * size[1], normal[2] * size[0] }, normal };
                }
            }.at);
            try builder.cap(segments, cylinder.radius, cylinder.height * 0.5, true);
            try builder.cap(segments, cylinder.radius, -cylinder.height * 0.5, false);
        },
        .cone => |cone| {
            try positive(cone.radius);
            try positive(cone.height);
            const segments = @max(cone.segments, 3);
            const slope = cone.radius / cone.height;
            try builder.grid(segments, 1, [3]f32{ cone.radius, cone.height, slope }, struct {
                fn at(size: [3]f32, u: f32, v: f32) [2]Vec3 {
                    const out = ring(u);
                    const normal = math.normalize(.{ out[0], size[2], out[2] });
                    return .{ .{ out[0] * size[0] * v, (0.5 - v) * size[1], out[2] * size[0] * v }, normal };
                }
            }.at);
            try builder.cap(segments, cone.radius, -cone.height * 0.5, false);
        },
        .capsule => |capsule| {
            try positive(capsule.radius);
            try positive(capsule.height);
            const rings = @max(capsule.rings, 1);
            const straight = @max(capsule.height - capsule.radius * 2, 0);
            try builder.grid(@max(capsule.segments, 3), rings * 2 + 1, [3]f32{ capsule.radius, straight, @floatFromInt(rings) }, struct {
                fn at(size: [3]f32, u: f32, v: f32) [2]Vec3 {
                    const rows = size[2] * 2 + 1;
                    const row = @round(v * rows);
                    const top = row <= size[2];
                    const normal = around(u, (if (top) row else row - 1) / (size[2] * 2));
                    const lift = if (top) size[1] * 0.5 else -size[1] * 0.5;
                    return .{ .{ normal[0] * size[0], normal[1] * size[0] + lift, normal[2] * size[0] }, normal };
                }
            }.at);
        },
        .torus => |torus| {
            try positive(torus.radius);
            try positive(torus.tube);
            try builder.grid(@max(torus.segments, 3), @max(torus.sides, 3), [2]f32{ torus.radius, torus.tube }, struct {
                fn at(size: [2]f32, u: f32, v: f32) [2]Vec3 {
                    const out = ring(u);
                    const angle = -v * 2 * std.math.pi;
                    const normal = Vec3{ out[0] * @cos(angle), @sin(angle), out[2] * @cos(angle) };
                    return .{ math.add(math.scale(out, size[0]), math.scale(normal, size[1])), normal };
                }
            }.at);
        },
    }
    return builder.finish();
}

fn positive(value: f32) !void {
    if (!(value > 0) or !std.math.isFinite(value)) return error.InvalidShape;
}

/// The unit direction `u` of a turn around +Y from +Z, counter-clockwise
/// seen from above.
fn ring(u: f32) Vec3 {
    const angle = u * 2 * std.math.pi;
    return .{ @sin(angle), 0, @cos(angle) };
}

/// The unit direction `u` of a turn around +Y and `v` from the top pole to
/// the bottom one.
fn around(u: f32, v: f32) Vec3 {
    const out = ring(u);
    const angle = v * std.math.pi;
    return .{ out[0] * @sin(angle), @cos(angle), out[2] * @sin(angle) };
}

const Builder = struct {
    gpa: std.mem.Allocator,
    positions: std.ArrayList([3]f32) = .empty,
    normals: std.ArrayList([3]f32) = .empty,
    uvs: std.ArrayList([2]f32) = .empty,
    indices: std.ArrayList(u32) = .empty,

    fn deinit(self: *Builder) void {
        self.positions.deinit(self.gpa);
        self.normals.deinit(self.gpa);
        self.uvs.deinit(self.gpa);
        self.indices.deinit(self.gpa);
    }

    fn count(self: *const Builder) u32 {
        return @intCast(self.positions.items.len);
    }

    fn vertex(self: *Builder, position: Vec3, normal: Vec3, uv: [2]f32) !void {
        if (self.positions.items.len >= 1 << 24) return error.InvalidShape;
        try self.positions.append(self.gpa, position);
        try self.normals.append(self.gpa, normal);
        try self.uvs.append(self.gpa, uv);
    }

    /// Corners in counter-clockwise order seen from the front.
    fn quad(self: *Builder, a: u32, b: u32, c: u32, d: u32) !void {
        try self.indices.appendSlice(self.gpa, &.{ a, b, c, a, c, d });
    }

    /// `columns + 1` by `rows + 1` vertices from `at(context, u, v)`, which
    /// gives a position and normal; u runs left to right seen from the
    /// front, v top to bottom.
    fn grid(self: *Builder, columns: u32, rows: u32, context: anytype, comptime at: fn (@TypeOf(context), f32, f32) [2]Vec3) !void {
        if (@as(u64, columns + 1) * (rows + 1) >= 1 << 24) return error.InvalidShape;
        const base = self.count();
        for (0..rows + 1) |row| for (0..columns + 1) |column| {
            const u = @as(f32, @floatFromInt(column)) / @as(f32, @floatFromInt(columns));
            const v = @as(f32, @floatFromInt(row)) / @as(f32, @floatFromInt(rows));
            const position, const normal = at(context, u, v);
            try self.vertex(position, normal, .{ u, v });
        };
        const stride = columns + 1;
        for (0..rows) |row| for (0..columns) |column| {
            const corner = base + @as(u32, @intCast(row)) * stride + @as(u32, @intCast(column));
            try self.quad(corner + stride, corner + stride + 1, corner + 1, corner);
        };
    }

    /// A disc at height `y`, facing up or down.
    fn cap(self: *Builder, segments: u32, radius: f32, y: f32, up: bool) !void {
        const normal = Vec3{ 0, if (up) 1 else -1, 0 };
        const center = self.count();
        try self.vertex(.{ 0, y, 0 }, normal, .{ 0.5, 0.5 });
        for (0..segments + 1) |index| {
            const out = ring(@as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(segments)));
            try self.vertex(.{ out[0] * radius, y, out[2] * radius }, normal, .{ 0.5 + out[0] * 0.5, 0.5 - out[2] * (if (up) @as(f32, 0.5) else -0.5) });
        }
        for (0..segments) |index| {
            const at = center + 1 + @as(u32, @intCast(index));
            try self.indices.appendSlice(self.gpa, if (up) &.{ center, at, at + 1 } else &.{ center, at + 1, at });
        }
    }

    fn finish(self: *Builder) !Mesh {
        const positions = try self.positions.toOwnedSlice(self.gpa);
        errdefer self.gpa.free(positions);
        const normals = try self.normals.toOwnedSlice(self.gpa);
        errdefer self.gpa.free(normals);
        const uvs = try self.uvs.toOwnedSlice(self.gpa);
        errdefer self.gpa.free(uvs);
        return .{ .positions = positions, .normals = normals, .uvs = uvs, .indices = try self.indices.toOwnedSlice(self.gpa) };
    }
};

test "every shape faces out with unit normals" {
    const shapes = [_]Shape{
        .{ .box = .{ .size = .{ 2, 1, 3 } } }, .{ .plane = .{ .cells = .{ 3, 2 } } }, .{ .sphere = .{} },
        .{ .cylinder = .{} },                  .{ .cone = .{} },                      .{ .capsule = .{} },
        .{ .torus = .{} },
    };
    for (shapes) |shape| {
        const mesh = try build(std.testing.allocator, shape);
        defer mesh.deinit(std.testing.allocator);
        try std.testing.expect(mesh.indices.len % 3 == 0 and mesh.indices.len > 0);
        for (mesh.normals) |normal| try std.testing.expectApproxEqAbs(@as(f32, 1), math.length(normal), 1e-4);
        var index: usize = 0;
        while (index < mesh.indices.len) : (index += 3) {
            const a = mesh.positions[mesh.indices[index]];
            const b = mesh.positions[mesh.indices[index + 1]];
            const c = mesh.positions[mesh.indices[index + 2]];
            const face = math.cross(math.sub(b, a), math.sub(c, a));
            if (math.dot(face, face) < 1e-12) continue;
            const normal = math.add(math.add(mesh.normals[mesh.indices[index]], mesh.normals[mesh.indices[index + 1]]), mesh.normals[mesh.indices[index + 2]]);
            try std.testing.expect(math.dot(face, normal) > 0);
        }
    }
    try std.testing.expectError(error.InvalidShape, build(std.testing.allocator, .{ .sphere = .{ .radius = 0 } }));
}
