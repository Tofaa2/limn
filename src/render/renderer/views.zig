//! Views and the targets they draw into. Internal to the renderer.
const std = @import("std");
const handle = @import("../../handle.zig");
const renderer_state = @import("../state.zig");
const rhi = @import("../../rhi/rhi.zig");
const gpu = @import("../gpu.zig");
const api = @import("../api.zig");
const render = @import("../renderer.zig");

const Renderer = render.Renderer;
const View = api.View;
const Image = api.Image;

/// Per-camera state and the targets views draw into.
pub const Views = struct {
    table: handle.HandleTable(renderer_state.ViewData, api.ViewTag),

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
        if (std.meta.eql(view, self.main_view)) return;
        var removed = self.views.table.remove(view) orelse return;
        removed.deinit(self.device);
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
        cmd.transition(texture, .shader_read);
        try self.device.endImmediate();
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
        cmd.transition(texture, .shader_read);
        try self.device.endImmediate();
        return texture;
    }

    /// Its `targetImage` images must not be drawn afterwards.
    pub fn destroyTarget(views: *Views, target: rhi.Texture) void {
        const self = views.renderer();
        self.lock();
        defer self.unlock();
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
        return .{ .index = self.device.textureIndex(target), .width = info.width, .height = info.height };
    }
};

pub fn insertView(self: *Renderer) !View {
    const device = self.device;
    const exposure = try device.createBuffer(.{ .name = "exposure", .size = @sizeOf(gpu.Exposure), .usage = .{ .storage = true } });
    errdefer device.destroyBuffer(exposure);
    try device.uploadBuffer(exposure, 0, std.mem.asBytes(&gpu.Exposure{ .exposure = 1, .average_luminance = 0, .focus = 0 }));
    return self.views.table.insert(.{ .exposure = exposure });
}

pub fn targetWritten(self: *const Renderer, target: rhi.Texture) bool {
    for (self.frame_targets[0..self.frame_target_count]) |written| if (std.meta.eql(written, target)) return true;
    return false;
}
