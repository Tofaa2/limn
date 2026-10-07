//! Binary form of a processed `gltf.Model` for the asset cache. Texture
//! pixels are not stored; textures are referenced by texture-cache key.
const std = @import("std");

/// Bump when any serialized type changes.
pub const version: u32 = 25;
const magic = [4]u8{ 'R', 'M', 'D', 'L' };

/// True for types whose bytes can be copied as they are.
fn isPlain(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int, .float => true,
        .array => |array| isPlain(array.child),
        .@"struct" => |info| info.layout == .@"extern" and blk: {
            for (info.fields) |field| if (!isPlain(field.type)) break :blk false;
            break :blk true;
        },
        else => false,
    };
}

/// Appends `value` in the cache's binary form: plain types as raw native-endian
/// bytes, bool/enum as one byte, optional as presence byte + value, slice as
/// u64 length + items, struct as fields in declaration order.
pub fn put(gpa: std.mem.Allocator, out: *std.ArrayList(u8), value: anytype) !void {
    const T = @TypeOf(value);
    if (comptime isPlain(T)) return out.appendSlice(gpa, std.mem.asBytes(&value));
    switch (@typeInfo(T)) {
        .bool => try out.append(gpa, @intFromBool(value)),
        .@"enum" => try out.append(gpa, @intCast(@intFromEnum(value))),
        .optional => {
            try out.append(gpa, @intFromBool(value != null));
            if (value) |inner| try put(gpa, out, inner);
        },
        .array => for (value) |item| try put(gpa, out, item),
        .pointer => |pointer| {
            comptime std.debug.assert(pointer.size == .slice);
            try out.appendSlice(gpa, std.mem.asBytes(&@as(u64, value.len)));
            if (comptime isPlain(pointer.child)) {
                try out.appendSlice(gpa, std.mem.sliceAsBytes(value));
            } else for (value) |item| try put(gpa, out, item);
        },
        .@"struct" => |info| inline for (info.fields) |field| try put(gpa, out, @field(value, field.name)),
        else => @compileError("cannot serialize " ++ @typeName(T)),
    }
}

/// Reads back what `put` wrote, in the same order with the same types.
/// `bytes` is an unsealed payload (see `unseal`) and is borrowed.
pub const Reader = struct {
    bytes: []const u8,
    cursor: usize = 0,

    fn take(self: *Reader, count: usize) ![]const u8 {
        if (count > self.bytes.len - self.cursor) return error.CorruptCache;
        defer self.cursor += count;
        return self.bytes[self.cursor..][0..count];
    }

    /// Reads the next value as `T`. Slices are allocated from `arena` and never
    /// freed individually. Truncated data or an unknown enum value gives
    /// `error.CorruptCache`.
    pub fn get(self: *Reader, arena: std.mem.Allocator, comptime T: type) !T {
        if (comptime isPlain(T)) {
            var value: T = undefined;
            @memcpy(std.mem.asBytes(&value), try self.take(@sizeOf(T)));
            return value;
        }
        switch (@typeInfo(T)) {
            .bool => return (try self.take(1))[0] != 0,
            .@"enum" => return std.enums.fromInt(T, (try self.take(1))[0]) orelse error.CorruptCache,
            .optional => |optional| {
                if ((try self.take(1))[0] == 0) return null;
                return try self.get(arena, optional.child);
            },
            .array => |array| {
                var value: T = undefined;
                for (&value) |*item| item.* = try self.get(arena, array.child);
                return value;
            },
            .pointer => |pointer| {
                const count = try self.get(arena, u64);
                if (count > self.bytes.len) return error.CorruptCache;
                const items = try arena.alignedAlloc(pointer.child, .of(pointer.child), @intCast(count));
                if (comptime isPlain(pointer.child)) {
                    @memcpy(std.mem.sliceAsBytes(items), try self.take(items.len * @sizeOf(pointer.child)));
                } else for (items) |*item| item.* = try self.get(arena, pointer.child);
                return items;
            },
            .@"struct" => |info| {
                var value: T = undefined;
                inline for (info.fields) |field| @field(value, field.name) = try self.get(arena, field.type);
                return value;
            },
            else => @compileError("cannot deserialize " ++ @typeName(T)),
        }
    }
};

/// Wraps a payload with a header and a checksum.
pub fn seal(gpa: std.mem.Allocator, payload: []const u8) ![]u8 {
    const out = try gpa.alloc(u8, 16 + payload.len);
    out[0..4].* = magic;
    std.mem.writeInt(u32, out[4..8], version, .little);
    std.mem.writeInt(u64, out[8..16], std.hash.Wyhash.hash(version, payload), .little);
    @memcpy(out[16..], payload);
    return out;
}

/// Returns the payload of a sealed file, or null if foreign or damaged.
pub fn unseal(bytes: []const u8) ?[]const u8 {
    if (bytes.len < 16 or !std.mem.eql(u8, bytes[0..4], &magic)) return null;
    if (std.mem.readInt(u32, bytes[4..8], .little) != version) return null;
    const payload = bytes[16..];
    if (std.mem.readInt(u64, bytes[8..16], .little) != std.hash.Wyhash.hash(version, payload)) return null;
    return payload;
}

test "round trip through the cache format" {
    const Inner = struct { name: []const u8, weight: ?f32, kind: enum { a, b } };
    const Outer = struct { values: []const u32, items: []const Inner, flag: bool, matrix: ?[4]f32 };
    const original = Outer{
        .values = &.{ 1, 2, 3 },
        .items = &.{ .{ .name = "one", .weight = 0.5, .kind = .b }, .{ .name = "", .weight = null, .kind = .a } },
        .flag = true,
        .matrix = .{ 1, 2, 3, 4 },
    };
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    try put(std.testing.allocator, &bytes, original);
    const sealed = try seal(std.testing.allocator, bytes.items);
    defer std.testing.allocator.free(sealed);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var reader = Reader{ .bytes = unseal(sealed).? };
    const copy = try reader.get(arena.allocator(), Outer);
    try std.testing.expectEqualSlices(u32, original.values, copy.values);
    try std.testing.expectEqualStrings("one", copy.items[0].name);
    try std.testing.expectEqual(@as(?f32, null), copy.items[1].weight);
    try std.testing.expect(copy.items[0].kind == .b and copy.flag and copy.matrix.?[3] == 4);

    sealed[20] ^= 1;
    try std.testing.expect(unseal(sealed) == null);
}
