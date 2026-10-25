//! How a view's picture is encoded for its target.
const render = @import("../renderer.zig");
const rhi = @import("../../rhi/rhi.zig");
const api = @import("../api.zig");
const features = @import("../core/features.zig");

const ViewDesc = render.ViewDesc;
const Renderer = render.Renderer;

pub const name = "output";

pub const Settings = struct {
    /// `.auto` is sRGB, or HDR10 for the window when `Options.hdr_output` got
    /// an HDR surface.
    encoding: api.OutputEncoding = .auto,
    /// HDR10 only: brightness of white, in nits.
    paper_white_nits: f32 = 200,
    /// HDR10 only: peak brightness of the display, in nits.
    peak_nits: f32 = 1000,
};

pub fn preset(quality: api.Quality) Settings {
    _ = quality;
    return .{};
}

pub fn resolve(setting: *Settings, r: *features.Resolve) void {
    _ = setting;
    _ = r;
}

pub fn declare(ctx: *features.ViewContext) !void {
    _ = ctx;
}

/// 0: the target format encodes. 1: sRGB. 2: HDR10.
pub fn outputEncoding(renderer: *const Renderer, desc: ViewDesc, format: rhi.Format) u32 {
    const plain: u32 = @intFromBool(!format.isSrgb());
    return switch (desc.settings.output.encoding) {
        .auto => if (desc.target == .backbuffer and renderer.device.hdr_active) 2 else plain,
        .srgb => plain,
        .hdr10 => 2,
    };
}
