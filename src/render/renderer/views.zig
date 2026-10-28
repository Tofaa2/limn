//! Views and the targets they draw into. Internal to the renderer.
const std = @import("std");
const handle = @import("../../handle.zig");
const renderer_state = @import("../state.zig");
const rhi = @import("../../rhi/rhi.zig");
const gpu = @import("../gpu.zig");
const api = @import("../api.zig");
const render = @import("../renderer.zig");
const images_module = @import("images.zig");
const png = @import("../../png.zig");

const Renderer = render.Renderer;
const View = api.View;
const Image = api.Image;

/// Per-camera state and the targets views draw into.
pub const Views = struct {
    internal: Internal,

    /// Not part of the API.
    pub const Internal = struct {
        table: handle.HandleTable(renderer_state.ViewData, api.ViewTag),

        /// Frees what one of them holds, as when the renderer is destroyed.
        pub fn free(owner: *Renderer, entry: *renderer_state.ViewData) void {
            entry.deinit(owner.internal.gpa, owner.device);
        }
    };

    fn renderer(views: *Views) *Renderer {
        return @alignCast(@fieldParentPtr("views", views));
    }

    /// Creates persistent state for an extra camera. Its render targets are
    /// allocated on first use and follow the size it is drawn at.
    pub fn create(views: *Views) !View {
        const self = views.renderer();
        self.lock();
        defer self.unlock();
        return insertView(self);
    }

    /// The main view cannot be destroyed.
    pub fn destroy(views: *Views, view: View) void {
        const self = views.renderer();
        self.lock();
        defer self.unlock();
        if (std.meta.eql(view, self.internal.main_view)) return;
        var removed = self.views.internal.table.remove(view) orelse return;
        removed.deinit(self.internal.gpa, self.device);
    }

    /// Creates a texture views can draw into (`Target.texture`) and draw
    /// lists can show (`targetImage`).
    pub fn createTarget(views: *Views, width: u32, height: u32) !rhi.Texture {
        const self = views.renderer();
        self.lock();
        defer self.unlock();
        const texture = try self.device.createTexture(.{
            .name = "view target",
            .width = width,
            .height = height,
            .format = .rgba8_srgb,
            .usage = .{ .sampled = true, .color_attachment = true, .copy_src = true },
        });
        errdefer self.device.destroyTexture(texture);
        var cmd = try self.device.beginImmediate();
        try cmd.beginRendering(.{ .color = &.{.{ .texture = texture, .load = .clear, .clear = .{ 0, 0, 0, 1 } }} });
        cmd.endRendering();
        try self.device.endImmediate(&cmd);
        return texture;
    }

    /// As `createTarget`, in `format`, with memory another device can import;
    /// see `rhi.Device.exportTexture`. `error.SharedTexturesUnavailable`
    /// where the device cannot share.
    pub fn createSharedTarget(views: *Views, width: u32, height: u32, format: rhi.Format) !rhi.Texture {
        const self = views.renderer();
        self.lock();
        defer self.unlock();
        const texture = try self.device.createSharedTexture(.{
            .name = "shared view target",
            .width = width,
            .height = height,
            .format = format,
            .usage = .{ .sampled = true, .color_attachment = true, .copy_src = true, .copy_dst = true },
        });
        errdefer self.device.destroyTexture(texture);
        var cmd = try self.device.beginImmediate();
        try cmd.beginRendering(.{ .color = &.{.{ .texture = texture, .load = .clear, .clear = .{ 0, 0, 0, 1 } }} });
        cmd.endRendering();
        try self.device.endImmediate(&cmd);
        return texture;
    }

    /// Writes what views drew into `target` as an 8-bit RGBA PNG at `path`.
    /// Waits for the GPU; call between frames. Takes the formats views draw
    /// into: 8-bit RGBA or BGRA as stored, and half floats as linear color.
    /// Fails with `error.InvalidTarget` for a destroyed texture or one made
    /// without `copy_src`, `error.UnsupportedFormat` for other formats.
    pub fn saveTarget(views: *Views, target: rhi.Texture, path: []const u8) !void {
        const self = views.renderer();
        self.lock();
        defer self.unlock();
        if (!self.device.textureExists(target)) return error.InvalidTarget;
        const info = self.device.textureInfo(target);
        if (!info.usage.copy_src) return error.InvalidTarget;
        switch (info.format) {
            .rgba8_unorm, .rgba8_srgb, .bgra8_unorm, .bgra8_srgb, .rgba16_float => {},
            else => return error.UnsupportedFormat,
        }
        const gpa = self.internal.gpa;
        const raw = try self.device.readTexture(gpa, target);
        defer gpa.free(raw);
        const count = @as(usize, info.width) * info.height;
        const pixels = if (info.format == .rgba16_float) try gpa.alloc(u8, count * 4) else raw;
        defer if (info.format == .rgba16_float) gpa.free(pixels);
        switch (info.format) {
            .bgra8_unorm, .bgra8_srgb => for (0..count) |index| std.mem.swap(u8, &pixels[index * 4], &pixels[index * 4 + 2]),
            .rgba16_float => for (0..count) |index| inline for (0..4) |channel| {
                const half: f16 = @bitCast(std.mem.readInt(u16, raw[index * 8 + channel * 2 ..][0..2], .little));
                const value = std.math.clamp(@as(f32, half), 0, 1);
                const encoded = if (channel == 3) value else if (value <= 0.0031308) value * 12.92 else 1.055 * std.math.pow(f32, value, 1.0 / 2.4) - 0.055;
                pixels[index * 4 + channel] = @intFromFloat(encoded * 255 + 0.5);
            },
            else => {},
        }
        try png.write(gpa, self.internal.io, path, .{ .width = info.width, .height = info.height, .pixels = pixels });
    }

    /// Its `targetImage` image is no longer valid afterwards.
    pub fn destroyTarget(views: *Views, target: rhi.Texture) void {
        const self = views.renderer();
        self.lock();
        defer self.unlock();
        images_module.forgetTarget(self, target);
        self.device.destroyTexture(target);
    }

    /// A target texture as an image for a `DrawList`. Views listed earlier in
    /// the same frame have already drawn into it. `error.InvalidTarget` once
    /// the target is destroyed.
    pub fn targetImage(views: *Views, target: rhi.Texture) !Image {
        const self = views.renderer();
        self.lock();
        defer self.unlock();
        if (!self.device.textureExists(target)) return error.InvalidTarget;
        const info = self.device.textureInfo(target);
        return images_module.targetImage(self, target, self.device.textureIndex(target), info.width, info.height);
    }
};

pub fn insertView(self: *Renderer) !View {
    const device = self.device;
    const exposure = try device.createBuffer(.{ .name = "exposure", .size = @sizeOf(gpu.Exposure), .usage = .{ .storage = true } });
    errdefer device.destroyBuffer(exposure);
    try device.uploadBuffer(exposure, 0, std.mem.asBytes(&gpu.Exposure{ .exposure = 1, .average_luminance = 0, .focus = 0 }));
    return self.views.internal.table.insert(.{ .exposure = exposure });
}

pub fn targetWritten(self: *const Renderer, target: rhi.Texture) bool {
    for (self.internal.frame_targets[0..self.internal.frame_target_count]) |written| if (std.meta.eql(written, target)) return true;
    return false;
}
