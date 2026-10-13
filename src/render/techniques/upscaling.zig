//! The vendor upscalers a view can resolve with and the frame generators
//! that go with them, behind one set of inputs and one lifecycle.
const std = @import("std");
const rhi = @import("../../rhi/rhi.zig");
const api = @import("../api.zig");
const slot = @import("../core/slot.zig");
const ffx = @import("../ffx.zig");
const dlss = @import("../dlss.zig");

pub const Technique = enum {
    fsr2,
    fsr3,
    dlss_super_resolution,
    /// Denoises a path traced picture while it upscales.
    dlss_ray_reconstruction,

    pub fn label(self: Technique) [:0]const u8 {
        return switch (self) {
            .fsr2, .fsr3 => "fidelityfx super resolution",
            .dlss_super_resolution => "dlss super resolution",
            .dlss_ray_reconstruction => "dlss ray reconstruction",
        };
    }
};

/// What a backend is started for.
pub const Key = struct {
    technique: Technique,
    render_size: [2]u32,
    output_size: [2]u32,
};

/// What this device and build can run.
pub const Availability = struct {
    fidelityfx: bool = false,
    dlss_super_resolution: bool = false,
    dlss_ray_reconstruction: bool = false,

    pub fn of(device: *const rhi.Device, library: dlss.Library) Availability {
        const storage = device.caps.storage_images;
        return .{
            .fidelityfx = ffx.available and storage,
            .dlss_super_resolution = storage and library.offers(.super_resolution),
            .dlss_ray_reconstruction = storage and library.offers(.ray_reconstruction),
        };
    }

    pub fn has(self: Availability, technique: Technique) bool {
        return switch (technique) {
            .fsr2, .fsr3 => self.fidelityfx,
            .dlss_super_resolution => self.dlss_super_resolution,
            .dlss_ray_reconstruction => self.dlss_ray_reconstruction,
        };
    }
};

/// What a denoising upscaler reads besides the picture.
pub const Guides = struct {
    /// What the surface seen scatters, and what it reflects.
    diffuse_albedo: rhi.Texture,
    specular_albedo: rhi.Texture,
    /// World normal, roughness in alpha.
    normal_roughness: rhi.Texture,
};

pub const Inputs = struct {
    /// HDR color before tone mapping, depth and motion vectors at render
    /// size, and the output at its own. All in `TextureState.shader_read`,
    /// and left so.
    color: rhi.Texture,
    depth: rhi.Texture,
    motion: rhi.Texture,
    output: rhi.Texture,
    guides: ?Guides = null,
    /// This frame's subpixel jitter, as a fraction of the picture.
    jitter: [2]f32,
    camera: api.Camera,
    world_to_view: [16]f32,
    view_to_clip: [16]f32,
    delta_time: f32,
    /// Discards the history.
    reset: bool,
};

pub const Running = union(enum) {
    fidelityfx: ffx.Upscaler,
    dlss: dlss.Upscaler,

    pub const Context = struct { device: *rhi.Device, cmd: *rhi.CommandEncoder };

    pub fn start(context: Context, key: Key) ?Running {
        return switch (key.technique) {
            .fsr2, .fsr3 => .{ .fidelityfx = ffx.Upscaler.create(context.device, if (key.technique == .fsr2) .fsr2 else .fsr3, key.render_size, key.output_size) orelse return null },
            .dlss_super_resolution, .dlss_ray_reconstruction => .{ .dlss = dlss.Upscaler.create(
                context.device,
                context.cmd,
                if (key.technique == .dlss_ray_reconstruction) .ray_reconstruction else .super_resolution,
                key.render_size,
                key.output_size,
            ) orelse return null },
        };
    }

    pub fn destroy(self: *Running) void {
        switch (self.*) {
            inline else => |backend| backend.destroy(),
        }
    }

    /// Records the upscaling of `inputs.color` into `inputs.output`.
    pub fn dispatch(self: *Running, device: *rhi.Device, cmd: *rhi.CommandEncoder, inputs: Inputs) !void {
        switch (self.*) {
            .fidelityfx => |backend| try backend.dispatch(device, cmd, .{
                .color = inputs.color,
                .depth = inputs.depth,
                .motion = inputs.motion,
                .output = inputs.output,
                .jitter = inputs.jitter,
                .sharpness = 0,
                .delta_time = inputs.delta_time,
                .near = inputs.camera.near,
                .fov_y = inputs.camera.fov_y,
                .reset = inputs.reset,
            }),
            .dlss => |backend| {
                cmd.transition(inputs.output, .external);
                defer cmd.transition(inputs.output, .shader_read);
                try backend.dispatch(device, cmd, .{
                    .color = inputs.color,
                    .depth = inputs.depth,
                    .motion = inputs.motion,
                    .output = inputs.output,
                    .diffuse_albedo = if (inputs.guides) |guides| guides.diffuse_albedo else null,
                    .specular_albedo = if (inputs.guides) |guides| guides.specular_albedo else null,
                    .normal_roughness = if (inputs.guides) |guides| guides.normal_roughness else null,
                    .jitter = inputs.jitter,
                    .world_to_view = inputs.world_to_view,
                    .view_to_clip = inputs.view_to_clip,
                    .delta_time = inputs.delta_time,
                    .reset = inputs.reset,
                });
            },
        }
    }

    /// What makes frames between the ones this backend upscales, if it can.
    pub fn generator(self: *const Running) ?Generator {
        return switch (self.*) {
            .fidelityfx => |backend| if (backend.generation == .fsr3) .{ .fsr3 = backend } else null,
            .dlss => null,
        };
    }
};

pub const Slot = slot.Slot(Running, Key);

/// Makes a picture to show between two rendered ones.
pub const Generator = union(enum) {
    fsr3: ffx.Upscaler,

    /// Writes the picture between the last one shown and `shown` to
    /// `output`. False when there is none to show this frame.
    pub fn generate(self: Generator, device: *rhi.Device, cmd: *rhi.CommandEncoder, shown: rhi.Texture, output: rhi.Texture, reset: bool) !bool {
        return switch (self) {
            .fsr3 => |backend| backend.generate(device, cmd, shown, output, reset),
        };
    }
};
