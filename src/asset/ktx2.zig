//! KTX 2.0 reader and writer. Reads BC1/3/4/5/6H (unsigned)/7, RGBA8 and
//! RGBA16F, plain or Zstandard-compressed; Basis Universal payloads are
//! transcoded to BC7, or BC6H for HDR.
const std = @import("std");

pub const identifier = [12]u8{ 0xAB, 'K', 'T', 'X', ' ', '2', '0', 0xBB, '\r', '\n', 0x1A, '\n' };

/// BC formats are 4x4 blocks of 16 bytes (8 for `bc1` and `bc4`); `rgba8` is 4
/// bytes a texel, `rgba16f` 8. `bc6h` is unsigned.
pub const Format = enum { bc7, rgba8, bc1, bc3, bc4, bc5, bc6h, rgba16f };

pub const Texture = struct {
    /// Size of the largest level, in texels.
    width: u32,
    height: u32,
    format: Format,
    /// Always false for `bc4`, `bc5`, `bc6h` and `rgba16f`.
    srgb: bool,
    /// At least 1; each level is half the one before, rounded down, minimum 1.
    levels: u32,
    /// 6 for a cube map (+X, -X, +Y, -Y, +Z, -Z), otherwise 1.
    faces: u32 = 1,
    /// Array layers; 1 for a plain texture.
    layers: u32 = 1,
    /// Levels back to back, largest first; per level every layer, per layer
    /// every face. Owned by the caller.
    data: []u8,
};

const vk_r8g8b8a8_unorm = 37;
const vk_r8g8b8a8_srgb = 43;
const vk_r16g16b16a16_sfloat = 97;
const vk_bc7_unorm = 145;
const vk_bc7_srgb = 146;
const vk_bc1_rgba_unorm = 133;
const vk_bc1_rgba_srgb = 134;
const vk_bc1_rgb_unorm = 131;
const vk_bc1_rgb_srgb = 132;
const vk_bc3_unorm = 137;
const vk_bc3_srgb = 138;
const vk_bc4_unorm = 139;
const vk_bc5_unorm = 141;
const vk_bc6h_ufloat = 143;

/// Checks the identifier only.
pub fn isKtx2(bytes: []const u8) bool {
    return bytes.len >= identifier.len and std.mem.eql(u8, bytes[0..identifier.len], &identifier);
}

fn levelBytes(format: Format, width: u32, height: u32) usize {
    return switch (format) {
        .bc7, .bc3, .bc5, .bc6h => @as(usize, (width + 3) / 4) * ((height + 3) / 4) * 16,
        .bc1, .bc4 => @as(usize, (width + 3) / 4) * ((height + 3) / 4) * 8,
        .rgba8 => @as(usize, width) * height * 4,
        .rgba16f => @as(usize, width) * height * 8,
    };
}

pub fn read(gpa: std.mem.Allocator, bytes: []const u8) !Texture {
    if (!isKtx2(bytes) or bytes.len < 80) return error.InvalidKtx2;
    const vk_format = std.mem.readInt(u32, bytes[12..16], .little);
    const width = std.mem.readInt(u32, bytes[20..24], .little);
    const height = @max(std.mem.readInt(u32, bytes[24..28], .little), 1);
    const depth = std.mem.readInt(u32, bytes[28..32], .little);
    const layers = @max(std.mem.readInt(u32, bytes[32..36], .little), 1);
    const faces = std.mem.readInt(u32, bytes[36..40], .little);
    const levels = @max(std.mem.readInt(u32, bytes[40..44], .little), 1);
    const scheme = std.mem.readInt(u32, bytes[44..48], .little);
    if (width == 0 or width > 16384 or height > 16384 or levels > 15) return error.InvalidKtx2;
    if (depth > 1) return error.UnsupportedKtx2;
    if ((faces != 1 and faces != 6) or layers > 2048) return error.InvalidKtx2;
    if (faces == 6 and width != height) return error.InvalidKtx2;
    if (vk_format == 0) return readBasis(gpa, bytes);
    const images: usize = layers * faces;
    const format: Format, const srgb: bool = switch (vk_format) {
        vk_bc7_unorm => .{ .bc7, false },
        vk_bc7_srgb => .{ .bc7, true },
        vk_r8g8b8a8_unorm => .{ .rgba8, false },
        vk_r8g8b8a8_srgb => .{ .rgba8, true },
        vk_bc1_rgba_unorm, vk_bc1_rgb_unorm => .{ .bc1, false },
        vk_bc1_rgba_srgb, vk_bc1_rgb_srgb => .{ .bc1, true },
        vk_bc3_unorm => .{ .bc3, false },
        vk_bc3_srgb => .{ .bc3, true },
        vk_bc4_unorm => .{ .bc4, false },
        vk_bc5_unorm => .{ .bc5, false },
        vk_bc6h_ufloat => .{ .bc6h, false },
        vk_r16g16b16a16_sfloat => .{ .rgba16f, false },
        else => return error.UnsupportedKtx2,
    };
    if (scheme != 0 and scheme != 2) return error.UnsupportedKtx2;
    if (bytes.len < 80 + @as(usize, levels) * 24) return error.InvalidKtx2;

    var total: usize = 0;
    for (0..levels) |level| total += images * levelBytes(format, @max(width >> @intCast(level), 1), @max(height >> @intCast(level), 1));
    const data = try gpa.alloc(u8, total);
    errdefer gpa.free(data);
    var cursor: usize = 0;
    for (0..levels) |level| {
        const entry = bytes[80 + level * 24 ..][0..24];
        const offset = std.mem.readInt(u64, entry[0..8], .little);
        const length = std.mem.readInt(u64, entry[8..16], .little);
        const size = images * levelBytes(format, @max(width >> @intCast(level), 1), @max(height >> @intCast(level), 1));
        if (offset > bytes.len or length > bytes.len - offset) return error.InvalidKtx2;
        const stored = bytes[@intCast(offset)..][0..@intCast(length)];
        if (scheme == 0) {
            if (stored.len != size) return error.InvalidKtx2;
            @memcpy(data[cursor..][0..size], stored);
        } else {
            var input: std.Io.Reader = .fixed(stored);
            const window = try gpa.alloc(u8, std.compress.zstd.default_window_len + std.compress.zstd.block_size_max);
            defer gpa.free(window);
            var decompress = std.compress.zstd.Decompress.init(&input, window, .{});
            decompress.reader.readSliceAll(data[cursor..][0..size]) catch return error.InvalidKtx2;
        }
        cursor += size;
    }
    return .{ .width = width, .height = height, .format = format, .srgb = srgb, .levels = levels, .faces = faces, .layers = layers, .data = data };
}

// The Basis Universal transcoder (src/third_party/basisu/rnd_basis.cpp).
extern fn rnd_basis_open(data: [*]const u8, size: u32, info: *[8]u32) ?*anyopaque;
extern fn rnd_basis_level(handle: *anyopaque, level: u32, layer: u32, face: u32, out: [*]u8, blocks: u32, hdr: c_int) c_int;
extern fn rnd_basis_close(handle: *anyopaque) void;

/// Transcodes a Basis Universal KTX2 file to BC7, or BC6H for HDR.
fn readBasis(gpa: std.mem.Allocator, bytes: []const u8) !Texture {
    if (bytes.len > std.math.maxInt(u32)) return error.UnsupportedKtx2;
    var info: [8]u32 = undefined;
    const handle = rnd_basis_open(bytes.ptr, @intCast(bytes.len), &info) orelse return error.UnsupportedKtx2;
    defer rnd_basis_close(handle);
    const width = info[0];
    const height = @max(info[1], 1);
    const levels = @max(info[2], 1);
    const layers = @max(info[3], 1);
    const faces = info[4];
    const hdr = info[5] != 0;
    if (width == 0 or width > 16384 or height > 16384 or levels > 15) return error.InvalidKtx2;
    if ((faces != 1 and faces != 6) or layers > 2048) return error.InvalidKtx2;
    const format: Format = if (hdr) .bc6h else .bc7;
    var total: usize = 0;
    for (0..levels) |level| total += layers * faces * levelBytes(format, @max(width >> @intCast(level), 1), @max(height >> @intCast(level), 1));
    const data = try gpa.alloc(u8, total);
    errdefer gpa.free(data);
    var cursor: usize = 0;
    for (0..levels) |level| {
        const size = levelBytes(format, @max(width >> @intCast(level), 1), @max(height >> @intCast(level), 1));
        for (0..layers) |layer| for (0..faces) |face| {
            if (rnd_basis_level(handle, @intCast(level), @intCast(layer), @intCast(face), data[cursor..].ptr, @intCast(size / 16), @intFromBool(hdr)) == 0)
                return error.InvalidKtx2;
            cursor += size;
        };
    }
    return .{ .width = width, .height = height, .format = format, .srgb = info[6] != 0 and !hdr, .levels = levels, .faces = faces, .layers = layers, .data = data };
}

/// Returns the bytes written, or maxInt on bad data.
export fn rnd_zstd_decompress(dst: [*]u8, dst_capacity: usize, src: [*]const u8, src_size: usize) callconv(.c) usize {
    const failed = std.math.maxInt(usize);
    const gpa = std.heap.smp_allocator;
    var input: std.Io.Reader = .fixed(src[0..src_size]);
    const window = gpa.alloc(u8, std.compress.zstd.default_window_len + std.compress.zstd.block_size_max) catch return failed;
    defer gpa.free(window);
    var decompress = std.compress.zstd.Decompress.init(&input, window, .{});
    return decompress.reader.readSliceShort(dst[0..dst_capacity]) catch failed;
}

/// Declared decompressed size: maxInt when none is declared, maxInt - 1 when
/// `src` is not a Zstandard frame.
export fn rnd_zstd_content_size(src: [*]const u8, src_size: usize) callconv(.c) u64 {
    const unknown = std.math.maxInt(u64);
    const invalid = unknown - 1;
    if (src_size < 6 or std.mem.readInt(u32, src[0..4], .little) != 0xfd2fb528) return invalid;
    const descriptor = src[4];
    const single_segment = descriptor & 0x20 != 0;
    const dictionary_bytes: usize = switch (descriptor & 3) {
        0 => 0,
        1 => 1,
        2 => 2,
        else => 4,
    };
    const at: usize = 5 + @as(usize, @intFromBool(!single_segment)) + dictionary_bytes;
    const size_bytes: usize = switch (descriptor >> 6) {
        0 => if (single_segment) 1 else return unknown,
        1 => 2,
        2 => 4,
        else => 8,
    };
    if (src_size < at + size_bytes) return invalid;
    return switch (size_bytes) {
        1 => src[at],
        2 => @as(u64, std.mem.readInt(u16, src[at..][0..2], .little)) + 256,
        4 => std.mem.readInt(u32, src[at..][0..4], .little),
        else => std.mem.readInt(u64, src[at..][0..8], .little),
    };
}

/// Encodes an uncompressed-container KTX2 file. Result owned by the caller.
pub fn write(gpa: std.mem.Allocator, texture: Texture) ![]u8 {
    const levels = texture.levels;
    const images: usize = texture.layers * texture.faces;
    const dfd_length: u32 = 4 + 24;
    const header_length: usize = 80 + @as(usize, levels) * 24;
    const data_start = std.mem.alignForward(usize, header_length + dfd_length, 16);
    const out = try gpa.alloc(u8, data_start + std.mem.alignForward(usize, texture.data.len + @as(usize, levels) * 16, 16));
    errdefer gpa.free(out);
    @memset(out, 0);
    out[0..12].* = identifier;
    const vk_format: u32 = switch (texture.format) {
        .bc7 => if (texture.srgb) vk_bc7_srgb else vk_bc7_unorm,
        .bc1 => if (texture.srgb) vk_bc1_rgba_srgb else vk_bc1_rgba_unorm,
        .bc3 => if (texture.srgb) vk_bc3_srgb else vk_bc3_unorm,
        .bc4 => vk_bc4_unorm,
        .bc5 => vk_bc5_unorm,
        .bc6h => vk_bc6h_ufloat,
        .rgba16f => vk_r16g16b16a16_sfloat,
        .rgba8 => if (texture.srgb) vk_r8g8b8a8_srgb else vk_r8g8b8a8_unorm,
    };
    std.mem.writeInt(u32, out[12..16], vk_format, .little);
    std.mem.writeInt(u32, out[16..20], if (texture.format == .rgba16f) 2 else 1, .little); // type size
    std.mem.writeInt(u32, out[20..24], texture.width, .little);
    std.mem.writeInt(u32, out[24..28], texture.height, .little);
    std.mem.writeInt(u32, out[32..36], if (texture.layers > 1) texture.layers else 0, .little);
    std.mem.writeInt(u32, out[36..40], texture.faces, .little);
    std.mem.writeInt(u32, out[40..44], levels, .little);
    std.mem.writeInt(u32, out[48..52], @intCast(header_length), .little); // dfd offset
    std.mem.writeInt(u32, out[52..56], dfd_length, .little);
    std.mem.writeInt(u32, out[header_length..][0..4], dfd_length, .little);
    std.mem.writeInt(u16, out[header_length + 4 + 4 ..][0..2], 2, .little);
    std.mem.writeInt(u16, out[header_length + 4 + 6 ..][0..2], 24, .little);

    var offsets: [16]usize = undefined;
    var source: usize = 0;
    for (0..levels) |level| {
        offsets[level] = source;
        source += images * levelBytes(texture.format, @max(texture.width >> @intCast(level), 1), @max(texture.height >> @intCast(level), 1));
    }
    if (source != texture.data.len) return error.InvalidKtx2;
    var cursor = data_start;
    var level: usize = levels;
    while (level > 0) {
        level -= 1;
        const size = images * levelBytes(texture.format, @max(texture.width >> @intCast(level), 1), @max(texture.height >> @intCast(level), 1));
        cursor = std.mem.alignForward(usize, cursor, 16);
        @memcpy(out[cursor..][0..size], texture.data[offsets[level]..][0..size]);
        const entry = out[80 + level * 24 ..][0..24];
        std.mem.writeInt(u64, entry[0..8], cursor, .little);
        std.mem.writeInt(u64, entry[8..16], size, .little);
        std.mem.writeInt(u64, entry[16..24], size, .little);
        cursor += size;
    }
    return gpa.realloc(out, cursor);
}

test "a texture survives being written and read back" {
    var data: [(64 + 16) + 16]u8 = undefined;
    for (&data, 0..) |*byte, index| byte.* = @truncate(index * 7);
    const original = Texture{ .width = 8, .height = 8, .format = .bc7, .srgb = true, .levels = 3, .data = &data };
    const file = try write(std.testing.allocator, original);
    defer std.testing.allocator.free(file);
    try std.testing.expect(isKtx2(file));
    const copy = try read(std.testing.allocator, file);
    defer std.testing.allocator.free(copy.data);
    try std.testing.expectEqual(@as(u32, 8), copy.width);
    try std.testing.expectEqual(Format.bc7, copy.format);
    try std.testing.expect(copy.srgb);
    try std.testing.expectEqual(@as(u32, 3), copy.levels);
    try std.testing.expectEqualSlices(u8, &data, copy.data);

    try std.testing.expectError(error.InvalidKtx2, read(std.testing.allocator, file[0..40]));
}

test "the other block formats are read with their own block sizes" {
    inline for (.{ .{ Format.bc1, 8 }, .{ Format.bc4, 8 }, .{ Format.bc3, 16 }, .{ Format.bc5, 16 }, .{ Format.bc6h, 16 } }) |case| {
        var data: [16 * 16]u8 = undefined;
        for (&data, 0..) |*byte, index| byte.* = @truncate(index * 13 + 5);
        const payload = data[0 .. 16 * case[1]];
        const file = try write(std.testing.allocator, .{ .width = 16, .height = 16, .format = case[0], .srgb = false, .levels = 1, .data = payload });
        defer std.testing.allocator.free(file);
        const copy = try read(std.testing.allocator, file);
        defer std.testing.allocator.free(copy.data);
        try std.testing.expectEqual(case[0], copy.format);
        try std.testing.expectEqualSlices(u8, payload, copy.data);
    }
}

test "cube maps and arrays keep every face and layer of every level" {
    var cube: [6 * (128 + 32)]u8 = undefined;
    for (&cube, 0..) |*byte, index| byte.* = @truncate(index * 11 + 3);
    {
        const file = try write(std.testing.allocator, .{ .width = 4, .height = 4, .format = .rgba16f, .srgb = false, .levels = 2, .faces = 6, .data = &cube });
        defer std.testing.allocator.free(file);
        const copy = try read(std.testing.allocator, file);
        defer std.testing.allocator.free(copy.data);
        try std.testing.expectEqual(Format.rgba16f, copy.format);
        try std.testing.expectEqual(@as(u32, 6), copy.faces);
        try std.testing.expectEqual(@as(u32, 1), copy.layers);
        try std.testing.expectEqualSlices(u8, &cube, copy.data);
    }
    var array: [3 * 256]u8 = undefined;
    for (&array, 0..) |*byte, index| byte.* = @truncate(index * 5 + 1);
    const file = try write(std.testing.allocator, .{ .width = 8, .height = 8, .format = .rgba8, .srgb = true, .levels = 1, .layers = 3, .data = &array });
    defer std.testing.allocator.free(file);
    const copy = try read(std.testing.allocator, file);
    defer std.testing.allocator.free(copy.data);
    try std.testing.expectEqual(@as(u32, 3), copy.layers);
    try std.testing.expectEqual(@as(u32, 1), copy.faces);
    try std.testing.expectEqualSlices(u8, &array, copy.data);
}
