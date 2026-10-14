//! NVIDIA Real-time Denoisers (NRD): ReLAX for a path traced picture's
//! bounced light and reflections. The SDK is not part of the source tree:
//! `zig build nrd-sdk` fetches and builds it, builds after that have it in,
//! and it is reached through nrd/limn_nrd.cpp. Internal to the renderer.
const std = @import("std");
const rhi = @import("../rhi/rhi.zig");
const features = @import("build_features");

/// Whether the SDK was built in.
pub const available = features.nrd;

const Create = extern struct {
    instance: usize,
    physical_device: usize,
    device: usize,
    get_instance_proc_addr: *const anyopaque,
    get_device_proc_addr: *const anyopaque,
    width: u32,
    height: u32,
};

const Frame = extern struct {
    command_buffer: usize,
    motion: u64,
    normal_roughness: u64,
    view_depth: u64,
    diffuse: u64,
    specular: u64,
    diffuse_out: u64,
    specular_out: u64,
    input_layout: i32,
    frame_index: u32,
    reset: u32,
    frame_milliseconds: f32,
    history_frames: u32,
    fast_history_frames: u32,
    blur_radius: f32,
    pad: f32 = 0,
    motion_scale: [2]f32,
    jitter: [2]f32,
    jitter_previous: [2]f32,
    view_to_clip: [16]f32,
    view_to_clip_previous: [16]f32,
    world_to_view: [16]f32,
    world_to_view_previous: [16]f32,
};

const c = if (available) struct {
    extern fn limnNrdCreate(desc: *const Create) ?*anyopaque;
    extern fn limnNrdDispatch(nrd: *anyopaque, frame: *const Frame) i32;
    extern fn limnNrdDestroy(nrd: ?*anyopaque) void;
} else struct {};

/// The image layout of `TextureState.shader_read`, which the inputs are in.
const read_layout: i32 = 1000314000;

/// The denoiser for one view at one size, with its own textures and history.
pub const Denoiser = struct {
    handle: *anyopaque,

    /// Null where NRD will not start.
    pub fn create(device: *rhi.Device, size: [2]u32) ?Denoiser {
        if (!available) return null;
        const native = rhi.native.device(device);
        const handle = c.limnNrdCreate(&.{
            .instance = native.instance,
            .physical_device = native.physical_device,
            .device = native.device,
            .get_instance_proc_addr = native.get_instance_proc_addr,
            .get_device_proc_addr = native.get_device_proc_addr,
            .width = size[0],
            .height = size[1],
        }) orelse return null;
        return .{ .handle = handle };
    }

    /// The GPU must have finished with every frame it was used in.
    pub fn destroy(self: *Denoiser) void {
        if (available) c.limnNrdDestroy(self.handle);
    }

    pub const Inputs = struct {
        /// Screen-space motion: last frame's place is the pixel's minus this.
        /// In `TextureState.shader_read`, as are the next four.
        motion: rhi.Texture,
        /// World normal of the first surface, and its roughness in alpha.
        normal_roughness: rhi.Texture,
        /// Its place along the view's Z axis, in view space.
        view_depth: rhi.Texture,
        /// Bounced light over the surface's color, and how far the bounce
        /// went in alpha.
        diffuse: rhi.Texture,
        /// Reflected light, and how far the reflection reached in alpha.
        specular: rhi.Texture,
        /// Where the denoised two go, in `TextureState.storage`.
        diffuse_out: rhi.Texture,
        specular_out: rhi.Texture,
        /// This frame's and last frame's matrices, without jitter, the
        /// projections with +Y up in clip space.
        view_to_clip: [16]f32,
        view_to_clip_previous: [16]f32,
        world_to_view: [16]f32,
        world_to_view_previous: [16]f32,
        /// Subpixel jitter in pixels, this frame's and last frame's.
        jitter: [2]f32,
        jitter_previous: [2]f32,
        delta_time: f32,
        frame_index: u32,
        /// Discards the history.
        reset: bool,
        /// Most frames of history a pixel keeps, and the radius in pixels of
        /// the blur ahead of gathering; 0 for none.
        history_frames: u32,
        blur_radius: f32,
    };

    /// Records the denoising. Rebinds the encoder's globals before returning.
    pub fn dispatch(self: *Denoiser, device: *rhi.Device, cmd: *rhi.CommandEncoder, inputs: Inputs) !void {
        if (!available) return error.NrdUnavailable;
        const result = c.limnNrdDispatch(self.handle, &.{
            .command_buffer = rhi.native.commandBuffer(cmd),
            .motion = rhi.native.image(device, inputs.motion).view,
            .normal_roughness = rhi.native.image(device, inputs.normal_roughness).view,
            .view_depth = rhi.native.image(device, inputs.view_depth).view,
            .diffuse = rhi.native.image(device, inputs.diffuse).view,
            .specular = rhi.native.image(device, inputs.specular).view,
            .diffuse_out = rhi.native.image(device, inputs.diffuse_out).view,
            .specular_out = rhi.native.image(device, inputs.specular_out).view,
            .input_layout = read_layout,
            .frame_index = inputs.frame_index,
            .reset = @intFromBool(inputs.reset),
            .frame_milliseconds = @max(inputs.delta_time * 1000, 0.01),
            .history_frames = std.math.clamp(inputs.history_frames, 1, 255),
            .fast_history_frames = std.math.clamp(inputs.history_frames / 5, 1, 255),
            .blur_radius = @max(inputs.blur_radius, 0),
            .motion_scale = .{ -1, -1 },
            .jitter = inputs.jitter,
            .jitter_previous = inputs.jitter_previous,
            .view_to_clip = inputs.view_to_clip,
            .view_to_clip_previous = inputs.view_to_clip_previous,
            .world_to_view = inputs.world_to_view,
            .world_to_view_previous = inputs.world_to_view_previous,
        });
        rhi.native.restore(cmd);
        if (result != 0) return error.NrdFailed;
    }
};
