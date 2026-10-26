//! Images and light profiles. Internal to the renderer.
const std = @import("std");
const renderer_state = @import("../state.zig");
const rhi = @import("../../rhi/rhi.zig");
const gltf = @import("../../asset/gltf.zig");
const ktx2 = @import("../../asset/ktx2.zig");
const texture_codec = @import("texture_codec");
const png = @import("../../png.zig");
const gpu = @import("../gpu.zig");
const api = @import("../api.zig");
const render = @import("../renderer.zig");
const materials_module = @import("materials.zig");

const Renderer = render.Renderer;
const Image = api.Image;
const MaterialTextures = renderer_state.MaterialTextures;

/// Textures usable by draw lists and materials.
pub const Images = struct {
    internal: Internal = .{},

    /// Not part of the API.
    pub const Internal = struct {
        list: std.ArrayList(renderer_state.ImageEntry) = .empty,
        /// The id of the image at each bindless texture index, 0 where there is none.
        live: std.ArrayList(u32) = .empty,
        /// View targets lent out by `views.targetImage`, so each keeps one id.
        targets: std.ArrayList(Target) = .empty,
        next_id: u32 = 1,

        const Target = struct { texture: rhi.Texture, id: u32 };

        pub fn deinit(internal: *Internal, gpa: std.mem.Allocator, device: *rhi.Device) void {
            for (internal.list.items) |entry| device.destroyTexture(entry.texture);
            internal.list.deinit(gpa);
            internal.live.deinit(gpa);
            internal.targets.deinit(gpa);
        }
    };

    fn renderer(images: *Images) *Renderer {
        return @alignCast(@fieldParentPtr("images", images));
    }

    /// False once `image` is destroyed, for a view target's image once the
    /// target is, and for an image of another renderer.
    pub fn valid(images: *const Images, image: Image) bool {
        return image.id != 0 and image.index < images.internal.live.items.len and images.internal.live.items[image.index] == image.id;
    }

    /// The texture index the GPU samples `image` by; `gpu.invalid_id`, which
    /// samples nothing, for null and for an image that is no longer valid.
    pub fn indexOf(images: *const Images, image: ?Image) u32 {
        const value = image orelse return gpu.invalid_id;
        return if (images.valid(value)) value.index else gpu.invalid_id;
    }

    /// Creates an image for draw lists and materials.
    pub fn create(images: *Images, desc: api.ImageDesc) !Image {
        const self = images.renderer();
        if (!desc.compressed or !self.device.caps.bc_textures) return images.createLimited(desc.width, desc.height, desc.pixels, desc.srgb, desc.mip_levels);
        if (desc.pixels.len != @as(usize, desc.width) * desc.height * 4) return error.InvalidTextureData;
        const chain = try texture_codec.encodeBc7Chain(self.internal.gpa, desc.pixels, desc.width, desc.height, desc.srgb);
        defer self.internal.gpa.free(chain);
        return createImageFromLevels(self, .{
            .width = desc.width,
            .height = desc.height,
            .format = .bc7,
            .srgb = desc.srgb,
            .levels = texture_codec.mipCount(desc.width, desc.height),
            .data = chain,
        });
    }

    /// Like `create`, with at most `levels` mips; 0 means the full chain. An
    /// atlas wants no more than its smallest cell can be halved, or cells
    /// run into each other in the small mips.
    fn createLimited(images: *Images, width: u32, height: u32, pixels: []const u8, srgb: bool, levels: u32) !Image {
        const self = images.renderer();
        self.lock();
        defer self.unlock();
        const device = self.device;
        const texture = try device.createTexture(.{
            .name = "image",
            .width = width,
            .height = height,
            .format = if (srgb) .rgba8_srgb else .rgba8_unorm,
            .usage = .{ .sampled = true, .copy_dst = true },
            .mip_levels = if (levels == 0) rhi.TextureDesc.fullMipCount(width, height) else @min(levels, rhi.TextureDesc.fullMipCount(width, height)),
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
        var decoded = try gltf.loadImage(self.internal.gpa, self.internal.io, path);
        defer decoded.deinit();
        return .{ .width = decoded.width, .height = decoded.height, .pixels = try gpa.dupe(u8, decoded.data) };
    }

    /// Decodes a PNG/JPEG/TGA/BMP file into an sRGB image with full mips, or
    /// loads a KTX2 file as is. Blocks until it is on the GPU. Fails with
    /// `error.UnsupportedTextureFormat` for a KTX2 cube, array or missing BC.
    pub fn load(images: *Images, path: []const u8) !Image {
        const self = images.renderer();
        const bytes = try gltf.readFile(self.internal.gpa, self.internal.io, path);
        defer self.internal.gpa.free(bytes);
        if (ktx2.isKtx2(bytes)) {
            const texture = try ktx2.read(self.internal.gpa, bytes, renderer_state.basisTarget(self.device.caps));
            defer self.internal.gpa.free(texture.data);
            return createImageFromLevels(self, texture);
        }
        var decoded = try gltf.loadImage(self.internal.gpa, self.internal.io, path);
        defer decoded.deinit();
        return self.images.create(.{ .width = decoded.width, .height = decoded.height, .pixels = decoded.data, .srgb = true });
    }

    /// Compresses an RGBA8 picture to BC7 with full mips and writes it as a
    /// KTX2 file.
    pub fn writeKtx2(images: *Images, path: []const u8, desc: api.ImageDesc) !void {
        const self = images.renderer();
        const width = desc.width;
        const height = desc.height;
        const srgb = desc.srgb;
        if (desc.pixels.len != @as(usize, width) * height * 4) return error.InvalidTextureData;
        const chain = try texture_codec.encodeBc7Chain(self.internal.gpa, desc.pixels, width, height, srgb);
        defer self.internal.gpa.free(chain);
        const file = try ktx2.write(self.internal.gpa, .{
            .width = width,
            .height = height,
            .format = .bc7,
            .srgb = srgb,
            .levels = texture_codec.mipCount(width, height),
            .data = chain,
        });
        defer self.internal.gpa.free(file);
        try std.Io.Dir.cwd().writeFile(self.internal.io, .{ .sub_path = path, .data = file });
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
        return self.images.create(.{ .width = width, .height = 1, .pixels = &pixels, .srgb = false });
    }

    /// Loads an IES LM-63 light distribution: brightness by angle from the
    /// fixture's axis, averaged around it.
    pub fn loadLightProfile(images: *Images, path: []const u8) !Image {
        const self = images.renderer();
        const bytes = try gltf.readFile(self.internal.gpa, self.internal.io, path);
        defer self.internal.gpa.free(bytes);
        const values = try parseIes(self.internal.gpa, bytes);
        defer self.internal.gpa.free(values);
        return self.images.createLightProfile(values);
    }

    /// Replaces a rectangle of an image made by `create` with tightly packed
    /// RGBA8 pixels, `region` from the top-left corner. The smaller mip
    /// levels keep what they hold.
    pub fn update(images: *Images, image: Image, region: api.Region, pixels: []const u8) !void {
        const self = images.renderer();
        self.lock();
        defer self.unlock();
        if (!self.images.valid(image)) return error.InvalidImage;
        for (self.images.internal.list.items) |owned| {
            if (owned.id == image.id) return self.device.uploadTextureRegion(owned.texture, 0, 0, .{ region.x, region.y, region.width, region.height }, pixels);
        }
        return error.InvalidImage;
    }

    /// Frees an image. Materials given it by `materials.setTextures` go back
    /// to their own textures; lights, decals, particles, water, clouds and
    /// color grading using it sample nothing; `Renderer.render` refuses draw
    /// lists that draw it with `error.InvalidImage`. Images the renderer does
    /// not own (such as a `views.targetImage`) are ignored.
    pub fn destroy(images: *Images, image: Image) void {
        const self = images.renderer();
        self.lock();
        defer self.unlock();
        if (!self.images.valid(image)) return;
        for (self.images.internal.list.items, 0..) |entry, index| {
            if (entry.id != image.id) continue;
            self.device.destroyTexture(entry.texture);
            _ = self.images.internal.list.swapRemove(index);
            self.images.internal.live.items[image.index] = 0;
            forgetMaterialImage(self, image);
            return;
        }
    }
};

/// Lists `texture` as an image of the renderer's own.
fn own(self: *Renderer, texture: rhi.Texture, index: u32, width: u32, height: u32) !Image {
    try self.images.internal.list.ensureUnusedCapacity(self.internal.gpa, 1);
    const id = try lend(self, index);
    self.images.internal.list.appendAssumeCapacity(.{ .texture = texture, .index = index, .id = id });
    return .{ .index = index, .width = width, .height = height, .id = id };
}

/// Marks texture index `index` as an image under a new id.
fn lend(self: *Renderer, index: u32) !u32 {
    const live = &self.images.internal.live;
    if (index >= live.items.len) try live.appendNTimes(self.internal.gpa, 0, index + 1 - live.items.len);
    const id = self.images.internal.next_id;
    self.images.internal.next_id +%= 1;
    if (self.images.internal.next_id == 0) self.images.internal.next_id = 1;
    live.items[index] = id;
    return id;
}

/// The image `views.targetImage` gives for `target`: the same one until the
/// target is destroyed.
pub fn targetImage(self: *Renderer, target: rhi.Texture, index: u32, width: u32, height: u32) !Image {
    for (self.images.internal.targets.items) |lent| if (std.meta.eql(lent.texture, target))
        return .{ .index = index, .width = width, .height = height, .id = lent.id };
    try self.images.internal.targets.ensureUnusedCapacity(self.internal.gpa, 1);
    const id = try lend(self, index);
    self.images.internal.targets.appendAssumeCapacity(.{ .texture = target, .id = id });
    return .{ .index = index, .width = width, .height = height, .id = id };
}

/// Ends the image lent out for `target`, before it is destroyed.
pub fn forgetTarget(self: *Renderer, target: rhi.Texture) void {
    for (self.images.internal.targets.items, 0..) |lent, index| {
        if (!std.meta.eql(lent.texture, target)) continue;
        for (self.images.internal.live.items) |*id| if (id.* == lent.id) {
            id.* = 0;
        };
        _ = self.images.internal.targets.swapRemove(index);
        return;
    }
}

/// Gives materials set to `image` their own textures back.
fn forgetMaterialImage(self: *Renderer, image: Image) void {
    for (self.models.internal.table.slots.items) |*slot| {
        const entry = if (slot.value) |*value| value else continue;
        for (entry.material_images, 0..) |*textures, index| {
            var used = false;
            inline for (@typeInfo(MaterialTextures).@"struct".fields) |field| {
                if (field.type == ?Image) if (@field(textures, field.name)) |set| if (set.id == image.id) {
                    @field(textures, field.name) = null;
                    used = true;
                };
            }
            if (!used or entry.state != .ready) continue;
            const source = entry.source orelse continue;
            self.internal.asset_generation += 1;
            const encoded = materials_module.encodeMaterial(self, entry, source.materials[index], index) catch continue;
            self.materials.internal.pool.write(self.device, entry.material_base + @as(u32, @intCast(index)), std.mem.asBytes(&encoded)) catch continue;
        }
    }
}

/// Makes an image from mip levels already in a GPU format.
fn createImageFromLevels(self: *Renderer, source: ktx2.Texture) !Image {
    self.lock();
    defer self.unlock();
    const device = self.device;
    if (source.faces != 1 or source.layers != 1) return error.UnsupportedTextureFormat;
    const readable = switch (source.format) {
        .rgba8, .rgba16f => true,
        .astc4x4 => device.caps.astc_textures,
        else => device.caps.bc_textures,
    };
    if (!readable) return error.UnsupportedTextureFormat;
    const format: rhi.Format = switch (source.format) {
        .bc7 => if (source.srgb) .bc7_srgb else .bc7_unorm,
        .bc1 => if (source.srgb) .bc1_srgb else .bc1_unorm,
        .bc3 => if (source.srgb) .bc3_srgb else .bc3_unorm,
        .bc4 => .bc4_unorm,
        .bc5 => .bc5_unorm,
        .bc6h => .bc6h_ufloat,
        .rgba8 => if (source.srgb) .rgba8_srgb else .rgba8_unorm,
        .rgba16f => .rgba16_float,
        .astc4x4 => if (source.srgb) .astc_4x4_srgb else .astc_4x4_unorm,
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
    for (numbers.items) |number| if (!std.math.isFinite(number)) return error.InvalidIes;
    const multiplier = numbers.items[2];
    if (!(numbers.items[3] >= 2 and numbers.items[3] <= 4096 and numbers.items[4] >= 1 and numbers.items[4] <= 4096)) return error.InvalidIes;
    const vertical: usize = @intFromFloat(numbers.items[3]);
    const horizontal: usize = @intFromFloat(numbers.items[4]);
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
