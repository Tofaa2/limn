//! Images and light profiles. Internal to the renderer.
const std = @import("std");
const renderer_state = @import("../state.zig");
const rhi = @import("../../rhi/rhi.zig");
const gltf = @import("../../asset/gltf.zig");
const ktx2 = @import("../../asset/ktx2.zig");
const texture_codec = @import("texture_codec");
const png = @import("../../png.zig");
const api = @import("../api.zig");
const render = @import("../renderer.zig");

const Renderer = render.Renderer;
const Image = api.Image;

/// Textures usable by draw lists and materials.
pub const Images = struct {
    list: std.ArrayList(renderer_state.ImageEntry) = .empty,
    next_id: u32 = 1,

    fn renderer(images: *Images) *Renderer {
        return @alignCast(@fieldParentPtr("images", images));
    }

    /// As `images.create`, but stored as BC7 with a full mip chain. Falls back
    /// to `images.create` on a device without block compression.
    pub fn createCompressed(images: *Images, width: u32, height: u32, pixels: []const u8, srgb: bool) !Image {
        const self = images.renderer();
        if (!self.device.bc_textures) return self.images.create(width, height, pixels, srgb);
        if (pixels.len != @as(usize, width) * height * 4) return error.InvalidTextureData;
        const chain = try texture_codec.encodeBc7Chain(self.gpa, pixels, width, height, srgb);
        defer self.gpa.free(chain);
        return createImageFromLevels(self, .{
            .width = width,
            .height = height,
            .format = .bc7,
            .srgb = srgb,
            .levels = texture_codec.mipCount(width, height),
            .data = chain,
        });
    }

    /// Creates an image for draw lists from tightly packed RGBA8 pixels.
    /// `srgb`: true for color, false for data.
    pub fn create(images: *Images, width: u32, height: u32, pixels: []const u8, srgb: bool) !Image {
        const self = images.renderer();
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const device = self.device;
        const texture = try device.createTexture(.{
            .name = "image",
            .width = width,
            .height = height,
            .format = if (srgb) .rgba8_srgb else .rgba8_unorm,
            .usage = .{ .sampled = true, .copy_dst = true },
            .mip_levels = rhi.TextureDesc.fullMipCount(width, height),
        });
        errdefer device.destroyTexture(texture);
        try device.uploadTexture(texture, 0, 0, pixels);
        try device.generateMips(texture);
        const index = device.textureIndex(texture);
        return own(self, texture, index, width, height);
    }

    /// Decodes an image file to RGBA8. The pixels belong to `gpa`.
    pub fn readFile(images: *Images, gpa: std.mem.Allocator, path: []const u8) !png.Image {
        const self = images.renderer();
        var decoded = try gltf.loadImage(self.gpa, self.io, path);
        defer decoded.deinit();
        return .{ .width = decoded.width, .height = decoded.height, .pixels = try gpa.dupe(u8, decoded.data) };
    }

    /// Decodes a PNG/JPEG/TGA/BMP file into an sRGB image with full mips, or
    /// loads a KTX2 file as is. Blocks until it is on the GPU. Fails with
    /// `error.UnsupportedTextureFormat` for a KTX2 cube, array or missing BC.
    pub fn load(images: *Images, path: []const u8) !Image {
        const self = images.renderer();
        const bytes = try gltf.readFile(self.gpa, self.io, path);
        defer self.gpa.free(bytes);
        if (ktx2.isKtx2(bytes)) {
            const texture = try ktx2.read(self.gpa, bytes);
            defer self.gpa.free(texture.data);
            return createImageFromLevels(self, texture);
        }
        var decoded = try gltf.loadImage(self.gpa, self.io, path);
        defer decoded.deinit();
        return self.images.create(decoded.width, decoded.height, decoded.data, true);
    }

    /// Compresses an RGBA8 picture to BC7 with full mips and writes it as a
    /// KTX2 file.
    pub fn writeKtx2(images: *Images, path: []const u8, width: u32, height: u32, pixels: []const u8, srgb: bool) !void {
        const self = images.renderer();
        const chain = try texture_codec.encodeBc7Chain(self.gpa, pixels, width, height, srgb);
        defer self.gpa.free(chain);
        const file = try ktx2.write(self.gpa, .{
            .width = width,
            .height = height,
            .format = .bc7,
            .srgb = srgb,
            .levels = texture_codec.mipCount(width, height),
            .data = chain,
        });
        defer self.gpa.free(file);
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = file });
    }

    /// Makes a light profile from relative brightness values spread evenly
    /// from along the light's direction (first) to straight behind (last).
    /// Normalized so the brightest is 1.
    pub fn createLightProfile(images: *Images, values: []const f32) !Image {
        const self = images.renderer();
        if (values.len == 0) return error.EmptyProfile;
        var peak: f32 = 0;
        for (values) |value| peak = @max(peak, value);
        if (peak <= 0) return error.EmptyProfile;
        const width = 256;
        var pixels: [width * 4]u8 = undefined;
        for (0..width) |x| {
            const position = @as(f32, @floatFromInt(x)) / (width - 1) * @as(f32, @floatFromInt(values.len - 1));
            const low: usize = @intFromFloat(@floor(position));
            const high = @min(low + 1, values.len - 1);
            const value = (values[low] + (values[high] - values[low]) * (position - @floor(position))) / peak;
            const level: u8 = @intFromFloat(std.math.clamp(value, 0, 1) * 255 + 0.5);
            pixels[x * 4 ..][0..4].* = .{ level, level, level, 255 };
        }
        return self.images.create(width, 1, &pixels, false);
    }

    /// Loads an IES LM-63 light distribution: brightness by angle from the
    /// fixture's axis, averaged around it.
    pub fn loadLightProfile(images: *Images, path: []const u8) !Image {
        const self = images.renderer();
        const bytes = try gltf.readFile(self.gpa, self.io, path);
        defer self.gpa.free(bytes);
        const values = try parseIes(self.gpa, bytes);
        defer self.gpa.free(values);
        return self.images.createLightProfile(values);
    }

    /// Frees an image. It must not be used in any later frame. Images the
    /// renderer does not own (such as a `views.targetImage`) are ignored.
    pub fn destroy(images: *Images, image: Image) void {
        const self = images.renderer();
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.images.list.items, 0..) |entry, index| {
            if (entry.index != image.index or entry.id != image.id) continue;
            self.device.destroyTexture(entry.texture);
            _ = self.images.list.swapRemove(index);
            return;
        }
    }
};

/// Lists `texture` as an image of the renderer's own.
fn own(self: *Renderer, texture: rhi.Texture, index: u32, width: u32, height: u32) !Image {
    const id = self.images.next_id;
    try self.images.list.append(self.gpa, .{ .texture = texture, .index = index, .id = id });
    self.images.next_id +%= 1;
    if (self.images.next_id == 0) self.images.next_id = 1;
    return .{ .index = index, .width = width, .height = height, .id = id };
}

/// Makes an image from mip levels already in a GPU format.
fn createImageFromLevels(self: *Renderer, source: ktx2.Texture) !Image {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const device = self.device;
    if (source.faces != 1 or source.layers != 1) return error.UnsupportedTextureFormat;
    if (source.format != .rgba8 and source.format != .rgba16f and !device.bc_textures) return error.UnsupportedTextureFormat;
    const format: rhi.Format = switch (source.format) {
        .bc7 => if (source.srgb) .bc7_srgb else .bc7_unorm,
        .bc1 => if (source.srgb) .bc1_srgb else .bc1_unorm,
        .bc3 => if (source.srgb) .bc3_srgb else .bc3_unorm,
        .bc4 => .bc4_unorm,
        .bc5 => .bc5_unorm,
        .bc6h => .bc6h_ufloat,
        .rgba8 => if (source.srgb) .rgba8_srgb else .rgba8_unorm,
        .rgba16f => .rgba16_float,
    };
    const texture = try device.createTexture(.{
        .name = "image",
        .width = source.width,
        .height = source.height,
        .format = format,
        .usage = .{ .sampled = true, .copy_dst = true },
        .mip_levels = source.levels,
    });
    errdefer device.destroyTexture(texture);
    try device.uploadTextureLevels(texture, 0, 0, source.data);
    const index = device.textureIndex(texture);
    return own(self, texture, index, source.width, source.height);
}

/// Reads an IES LM-63 photometric file and returns brightness at 181
/// angles, 0 to 180 degrees from the fixture's axis.
fn parseIes(gpa: std.mem.Allocator, bytes: []const u8) ![]f32 {
    const tilt = std.mem.indexOf(u8, bytes, "TILT=") orelse return error.InvalidIes;
    const after_tilt = std.mem.indexOfScalarPos(u8, bytes, tilt, '\n') orelse return error.InvalidIes;
    var numbers: std.ArrayList(f32) = .empty;
    defer numbers.deinit(gpa);
    var tokens = std.mem.tokenizeAny(u8, bytes[after_tilt..], " \t\r\n,");
    while (tokens.next()) |token| try numbers.append(gpa, std.fmt.parseFloat(f32, token) catch return error.InvalidIes);
    if (numbers.items.len < 13) return error.InvalidIes;
    const multiplier = numbers.items[2];
    const vertical: usize = @intFromFloat(numbers.items[3]);
    const horizontal: usize = @intFromFloat(numbers.items[4]);
    if (vertical < 2 or horizontal < 1) return error.InvalidIes;
    if (numbers.items.len < 13 + vertical + horizontal + vertical * horizontal) return error.InvalidIes;
    const angles = numbers.items[13..][0..vertical];
    const candela = numbers.items[13 + vertical + horizontal ..][0 .. vertical * horizontal];

    const result = try gpa.alloc(f32, 181);
    errdefer gpa.free(result);
    for (result, 0..) |*out, degree| {
        const angle: f32 = @floatFromInt(degree);
        if (angle < angles[0] or angle > angles[vertical - 1]) {
            out.* = 0;
            continue;
        }
        var upper: usize = 1;
        while (upper < vertical - 1 and angles[upper] < angle) upper += 1;
        const span = angles[upper] - angles[upper - 1];
        const t = if (span > 0) (angle - angles[upper - 1]) / span else 0;
        var sum: f32 = 0;
        for (0..horizontal) |plane| {
            const low = candela[plane * vertical + upper - 1];
            const high = candela[plane * vertical + upper];
            sum += low + (high - low) * t;
        }
        out.* = sum / @as(f32, @floatFromInt(horizontal)) * multiplier;
    }
    return result;
}

test "an IES file becomes brightness by angle" {
    const file =
        \\IESNA:LM-63-2002
        \\[TEST] made up
        \\TILT=NONE
        \\1 1000 2 3 1 1 2 0 0 0
        \\1 1 100
        \\0 45 90
        \\0
        \\100 50 0
    ;
    const values = try parseIes(std.testing.allocator, file);
    defer std.testing.allocator.free(values);
    try std.testing.expectEqual(@as(usize, 181), values.len);
    try std.testing.expectApproxEqAbs(@as(f32, 200), values[0], 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 100), values[45], 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 150), values[22], 4);
    try std.testing.expectApproxEqAbs(@as(f32, 0), values[90], 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 0), values[120], 1e-3);
}
