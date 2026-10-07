//! FidelityFX Super Resolution 2 and 3 temporal upscalers. The SDK lives in
//! src/third_party/ffx_sdk and is reached through ffx/limn_ffx.cpp.
//! Internal to the renderer.
const std = @import("std");
const rhi = @import("../rhi/rhi.zig");
const features = @import("build_features");

/// Whether the SDK was built in (`-Dfidelityfx`).
pub const available = features.fidelityfx;

const Create = extern struct {
    physical_device: usize,
    device: usize,
    get_device_proc_addr: *const anyopaque,
    generation: u32,
    render_width: u32,
    render_height: u32,
    output_width: u32,
    output_height: u32,
};

const Image = extern struct {
    image: u64,
    format: i32,
    width: u32,
    height: u32,
};

const Frame = extern struct {
    command_buffer: usize,
    color: Image,
    depth: Image,
    motion: Image,
    output: Image,
    jitter: [2]f32,
    motion_scale: [2]f32,
    render_width: u32,
    render_height: u32,
    sharpness: f32,
    frame_milliseconds: f32,
    camera_near: f32,
    camera_fov_y: f32,
    reset: u32,
};

const Generate = extern struct {
    command_buffer: usize,
    shown: Image,
    output: Image,
    pq: u32,
    reset: u32,
};

const c = if (available) struct {
    extern fn limnFfxGenerateFrame(ffx: *anyopaque, frame: *const Generate) i32;
    extern fn limnFfxCreate(desc: *const Create) ?*anyopaque;
    extern fn limnFfxDispatch(ffx: *anyopaque, frame: *const Frame) i32;
    extern fn limnFfxDestroy(ffx: ?*anyopaque) void;
} else struct {};

pub const Generation = enum(u32) { fsr2 = 2, fsr3 = 3 };

/// An upscaler for one view at one pair of sizes.
pub const Upscaler = struct {
    handle: *anyopaque,
    generation: Generation,
    render_size: [2]u32,
    output_size: [2]u32,

    /// Null where the SDK is not built in or will not start on this GPU.
    pub fn create(device: *rhi.Device, generation: Generation, render_size: [2]u32, output_size: [2]u32) ?Upscaler {
        if (!available) return null;
        const handle = c.limnFfxCreate(&.{
            .physical_device = @intFromEnum(device.physical),
            .device = @intFromEnum(device.vkd.handle),
            .get_device_proc_addr = rhi.deviceProcAddr(),
            .generation = @intFromEnum(generation),
            .render_width = render_size[0],
            .render_height = render_size[1],
            .output_width = output_size[0],
            .output_height = output_size[1],
        }) orelse return null;
        return .{ .handle = handle, .generation = generation, .render_size = render_size, .output_size = output_size };
    }

    /// The GPU must have finished with every frame it was used in.
    pub fn destroy(self: Upscaler) void {
        if (available) c.limnFfxDestroy(self.handle);
    }

    pub const Inputs = struct {
        /// HDR color before tone mapping, depth and motion vectors at render
        /// size, and the output. All in `TextureState.shader_read`, and left so.
        color: rhi.Texture,
        depth: rhi.Texture,
        motion: rhi.Texture,
        output: rhi.Texture,
        /// This frame's subpixel jitter, as a fraction of the picture
        /// (`FrameConstants.jitter`).
        jitter: [2]f32,
        sharpness: f32,
        delta_time: f32,
        near: f32,
        fov_y: f32,
        /// Discards the history.
        reset: bool,
    };

    /// Records the upscaling. Rebinds the encoder's texture table before
    /// returning.
    pub fn dispatch(self: Upscaler, device: *rhi.Device, cmd: *rhi.CommandEncoder, inputs: Inputs) !void {
        if (!available) return error.FidelityFxUnavailable;
        const width: f32 = @floatFromInt(self.render_size[0]);
        const height: f32 = @floatFromInt(self.render_size[1]);
        const result = c.limnFfxDispatch(self.handle, &.{
            .command_buffer = @intFromEnum(cmd.command),
            .color = image(device, inputs.color),
            .depth = image(device, inputs.depth),
            .motion = image(device, inputs.motion),
            .output = image(device, inputs.output),
            .jitter = .{ inputs.jitter[0] * width * jitter_sign[0], inputs.jitter[1] * height * jitter_sign[1] },
            // Renderer motion is current minus previous as a fraction of the
            // picture; the upscaler wants previous minus current in pixels.
            .motion_scale = .{ -width, -height },
            .render_width = self.render_size[0],
            .render_height = self.render_size[1],
            .sharpness = std.math.clamp(inputs.sharpness, 0, 1),
            .frame_milliseconds = @max(inputs.delta_time * 1000, 0.01),
            .camera_near = inputs.near,
            .camera_fov_y = inputs.fov_y,
            .reset = @intFromBool(inputs.reset),
        });
        cmd.bindGlobals();
        if (result != 0) return error.FidelityFxFailed;
    }

    /// FSR 3 frame generation: writes to `output` the picture between the
    /// last `shown` and this one. After `dispatch` in the same frame; both
    /// textures in `shader_read`. False when there is none to show.
    pub fn generate(self: Upscaler, device: *rhi.Device, cmd: *rhi.CommandEncoder, shown: rhi.Texture, output: rhi.Texture, reset: bool) bool {
        if (!available) return false;
        const result = c.limnFfxGenerateFrame(self.handle, &.{
            .command_buffer = @intFromEnum(cmd.command),
            .shown = image(device, shown),
            .output = image(device, output),
            .pq = @intFromBool(device.hdr_active),
            .reset = @intFromBool(reset),
        });
        cmd.bindGlobals();
        return result == 1;
    }

    /// Sign of the upscaler's jitter relative to the renderer's projection.
    const jitter_sign = [2]f32{ 1, 1 };

    fn image(device: *rhi.Device, texture: rhi.Texture) Image {
        const resource = device.textureResource(texture);
        return .{
            .image = @intFromEnum(resource.image),
            .format = @intFromEnum(resource.vk_format),
            .width = resource.info.width,
            .height = resource.info.height,
        };
    }
};
