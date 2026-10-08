//! DDS reader for block-compressed 2D textures: BC1, BC3, BC4, BC5, BC6H
//! (unsigned) and BC7, with either the legacy or the DX10 header.
const std = @import("std");

pub const Format = enum { bc1, bc3, bc4, bc5, bc6h, bc7 };

pub const Texture = struct {
    /// Size of the largest level, in texels.
    width: u32,
    height: u32,
    format: Format,
    /// The file marks its color as sRGB encoded. Legacy headers cannot say.
    srgb: bool,
    levels: u32,
    /// Levels back to back, largest first; a slice of the bytes read.
    data: []const u8,
};

const header_size = 4 + 124;
const dx10_size = 20;
const caps2_cubemap = 0x200;
const caps2_volume = 0x200000;

pub fn isDds(bytes: []const u8) bool {
    return bytes.len >= header_size and std.mem.eql(u8, bytes[0..4], "DDS ");
}

pub fn read(bytes: []const u8) !Texture {
    if (!isDds(bytes)) return error.NotDds;
    const height = word(bytes, 12);
    const width = word(bytes, 16);
    const levels = @max(word(bytes, 28), 1);
    if (width == 0 or height == 0 or width > 16384 or height > 16384 or levels > 15) return error.UnsupportedDds;
    if (levels > std.math.log2_int(u32, @max(width, height)) + 1) return error.UnsupportedDds;
    if (word(bytes, 112) & (caps2_cubemap | caps2_volume) != 0) return error.UnsupportedDds;
    const four_cc = bytes[84..88];
    var offset: usize = header_size;
    var srgb = false;
    const format: Format = if (std.mem.eql(u8, four_cc, "DX10")) dx10: {
        if (bytes.len < header_size + dx10_size) return error.TruncatedDds;
        offset += dx10_size;
        const dimension = word(bytes, header_size + 4);
        const array_size = word(bytes, header_size + 12);
        const cube = word(bytes, header_size + 8) & 4 != 0;
        if (dimension != 3 or array_size > 1 or cube) return error.UnsupportedDds;
        const dxgi = word(bytes, header_size);
        srgb = dxgi == 72 or dxgi == 78 or dxgi == 99;
        break :dx10 switch (dxgi) {
            70, 71, 72 => .bc1,
            76, 77, 78 => .bc3,
            79, 80 => .bc4,
            82, 83 => .bc5,
            95 => .bc6h,
            97, 98, 99 => .bc7,
            else => return error.UnsupportedDds,
        };
    } else if (std.mem.eql(u8, four_cc, "DXT1"))
        .bc1
    else if (std.mem.eql(u8, four_cc, "DXT5"))
        .bc3
    else if (std.mem.eql(u8, four_cc, "ATI1") or std.mem.eql(u8, four_cc, "BC4U"))
        .bc4
    else if (std.mem.eql(u8, four_cc, "ATI2") or std.mem.eql(u8, four_cc, "BC5U"))
        .bc5
    else
        return error.UnsupportedDds;

    const block_bytes: usize = if (format == .bc1 or format == .bc4) 8 else 16;
    var size: usize = 0;
    for (0..levels) |level| {
        const level_width = @max(width >> @intCast(level), 1);
        const level_height = @max(height >> @intCast(level), 1);
        size += @as(usize, (level_width + 3) / 4) * ((level_height + 3) / 4) * block_bytes;
    }
    if (bytes.len < offset + size) return error.TruncatedDds;
    return .{ .width = width, .height = height, .format = format, .srgb = srgb, .levels = levels, .data = bytes[offset..][0..size] };
}

fn word(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

test "a BC7 texture with a DX10 header and two levels is read" {
    var file: [header_size + dx10_size + 16 * 4 + 16]u8 = @splat(0);
    file[0..4].* = "DDS ".*;
    std.mem.writeInt(u32, file[12..16], 8, .little);
    std.mem.writeInt(u32, file[16..20], 8, .little);
    std.mem.writeInt(u32, file[28..32], 2, .little);
    file[84..88].* = "DX10".*;
    std.mem.writeInt(u32, file[header_size..][0..4], 99, .little);
    std.mem.writeInt(u32, file[header_size + 4 ..][0..4], 3, .little);
    file[file.len - 1] = 7;
    const texture = try read(&file);
    try std.testing.expectEqual(Format.bc7, texture.format);
    try std.testing.expect(texture.srgb);
    try std.testing.expectEqual(@as(u32, 2), texture.levels);
    try std.testing.expectEqual(@as(usize, 80), texture.data.len);
    try std.testing.expectEqual(@as(u8, 7), texture.data[79]);
    try std.testing.expectError(error.TruncatedDds, read(file[0 .. file.len - 1]));
}

test "too many levels and legacy cube maps are refused" {
    var file: [header_size + 32]u8 = @splat(0);
    file[0..4].* = "DDS ".*;
    std.mem.writeInt(u32, file[12..16], 4, .little);
    std.mem.writeInt(u32, file[16..20], 4, .little);
    file[84..88].* = "DXT5".*;
    std.mem.writeInt(u32, file[28..32], 4, .little);
    try std.testing.expectError(error.UnsupportedDds, read(&file));
    std.mem.writeInt(u32, file[28..32], 1, .little);
    std.mem.writeInt(u32, file[112..116], caps2_cubemap, .little);
    try std.testing.expectError(error.UnsupportedDds, read(&file));
    std.mem.writeInt(u32, file[112..116], 0, .little);
    try std.testing.expectEqual(Format.bc3, (try read(&file)).format);
}
