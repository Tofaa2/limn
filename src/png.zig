//! Minimal PNG encoder (stored deflate blocks) for screenshots and tests.
const std = @import("std");

/// Tightly packed RGBA8 pixels, top row first.
pub const Image = struct {
    width: u32,
    height: u32,
    pixels: []const u8,
};

/// Writes `image` as an uncompressed 8-bit RGBA PNG at `path`, replacing any
/// existing file. Fails with `error.InvalidImageData` when `pixels.len` is
/// not `width * height * 4`.
pub fn write(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    image: Image,
) !void {
    const row_bytes = try std.math.mul(usize, image.width, 4);
    const raw_len = try std.math.mul(usize, row_bytes + 1, image.height);
    const pixel_bytes = try std.math.mul(usize, row_bytes, image.height);
    if (image.pixels.len != pixel_bytes) return error.InvalidImageData;

    var raw = try allocator.alloc(u8, raw_len);
    defer allocator.free(raw);
    for (0..image.height) |row| {
        const dst = row * (row_bytes + 1);
        const source_row = row;
        raw[dst] = 0;
        @memcpy(raw[dst + 1 ..][0..row_bytes], image.pixels[source_row * row_bytes ..][0..row_bytes]);
    }

    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);
    try bytes.appendSlice(allocator, "\x89PNG\r\n\x1a\n");
    var header: [13]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], image.width, .big);
    std.mem.writeInt(u32, header[4..8], image.height, .big);
    header[8] = 8;
    header[9] = 6;
    @memset(header[10..], 0);
    try appendChunk(allocator, &bytes, "IHDR", &header);

    var compressed: std.ArrayList(u8) = .empty;
    defer compressed.deinit(allocator);
    try compressed.appendSlice(allocator, &.{ 0x78, 0x01 });
    var offset: usize = 0;
    while (offset < raw.len) {
        const block_len: u16 = @intCast(@min(raw.len - offset, std.math.maxInt(u16)));
        const final: u8 = if (offset + block_len == raw.len) 1 else 0;
        try compressed.append(allocator, final);
        try compressed.append(allocator, @truncate(block_len));
        try compressed.append(allocator, @truncate(block_len >> 8));
        const inverse = ~block_len;
        try compressed.append(allocator, @truncate(inverse));
        try compressed.append(allocator, @truncate(inverse >> 8));
        try compressed.appendSlice(allocator, raw[offset .. offset + block_len]);
        offset += block_len;
    }
    const adler = std.hash.Adler32.hash(raw);
    var checksum: [4]u8 = undefined;
    std.mem.writeInt(u32, &checksum, adler, .big);
    try compressed.appendSlice(allocator, &checksum);
    try appendChunk(allocator, &bytes, "IDAT", compressed.items);
    try appendChunk(allocator, &bytes, "IEND", &.{});

    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, bytes.items);
}

fn appendChunk(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    kind: *const [4]u8,
    data: []const u8,
) !void {
    var length: [4]u8 = undefined;
    std.mem.writeInt(u32, &length, @intCast(data.len), .big);
    try output.appendSlice(allocator, &length);
    try output.appendSlice(allocator, kind);
    try output.appendSlice(allocator, data);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    var encoded_crc: [4]u8 = undefined;
    std.mem.writeInt(u32, &encoded_crc, crc.final(), .big);
    try output.appendSlice(allocator, &encoded_crc);
}
