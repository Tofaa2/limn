//! NVIDIA DLSS: Super Resolution, which upscales and antialiases, and Ray
//! Reconstruction, which also denoises a path traced picture. The SDK is not
//! part of the source tree: `zig build dlss-sdk` fetches it, builds after
//! that have it in, and it is reached through dlss/limn_dlss.cpp. Internal to
//! the renderer.
const std = @import("std");
const rhi = @import("../rhi/rhi.zig");
const features = @import("build_features");

/// Whether the SDK was built in.
pub const available = features.dlss;

pub const Feature = enum(u32) { super_resolution = 1, ray_reconstruction = 2 };

const Start = extern struct {
    instance: usize,
    physical_device: usize,
    device: usize,
    get_instance_proc_addr: *const anyopaque,
    get_device_proc_addr: *const anyopaque,
    library_directory: [*:0]const u8,
    data_directory: [*:0]const u8,
    logging: u32,
};

const Create = extern struct {
    device: usize,
    command_buffer: usize,
    feature: u32,
    render_width: u32,
    render_height: u32,
    output_width: u32,
    output_height: u32,
};

const Image = extern struct {
    image: u64 = 0,
    view: u64 = 0,
    format: i32 = 0,
    width: u32 = 0,
    height: u32 = 0,
};

const Frame = extern struct {
    command_buffer: usize,
    color: Image,
    depth: Image,
    motion: Image,
    output: Image,
    diffuse_albedo: Image = .{},
    specular_albedo: Image = .{},
    normal_roughness: Image = .{},
    jitter: [2]f32,
    motion_scale: [2]f32,
    world_to_view: [16]f32,
    view_to_clip: [16]f32,
    frame_milliseconds: f32,
    reset: u32,
};

const c = if (available) struct {
    extern fn limnDlssStart(desc: *const Start) u32;
    extern fn limnDlssStop(device: usize) void;
    extern fn limnDlssCreate(desc: *const Create) ?*anyopaque;
    extern fn limnDlssDispatch(dlss: *anyopaque, frame: *const Frame) i32;
    extern fn limnDlssDestroy(dlss: ?*anyopaque) void;
} else struct {};

/// DLSS on one device: which features this GPU and driver offer.
pub const Library = struct {
    super_resolution: bool = false,
    ray_reconstruction: bool = false,

    /// Nothing is offered where the SDK is not built in, the GPU is not
    /// NVIDIA's or the driver lacks what DLSS asks for.
    pub fn start(device: *rhi.Device) Library {
        if (!available or !device.nvidia_ngx) return .{};
        const offered = c.limnDlssStart(&.{
            .instance = @intFromEnum(device.instance.handle),
            .physical_device = @intFromEnum(device.physical),
            .device = @intFromEnum(device.vkd.handle),
            .get_instance_proc_addr = rhi.instanceProcAddr(),
            .get_device_proc_addr = rhi.deviceProcAddr(),
            .library_directory = features.dlss_libraries,
            .data_directory = data_directory,
            .logging = @intFromBool(features.dlss_logging),
        });
        return .{
            .super_resolution = offered & @intFromEnum(Feature.super_resolution) != 0,
            .ray_reconstruction = offered & @intFromEnum(Feature.ray_reconstruction) != 0,
        };
    }

    /// Every `Upscaler` must be destroyed first.
    pub fn stop(self: Library, device: *rhi.Device) void {
        if (available and (self.super_resolution or self.ray_reconstruction)) c.limnDlssStop(@intFromEnum(device.vkd.handle));
    }

    pub fn offers(self: Library, feature: Feature) bool {
        return switch (feature) {
            .super_resolution => self.super_resolution,
            .ray_reconstruction => self.ray_reconstruction,
        };
    }

    const data_directory: [*:0]const u8 = if (@import("builtin").os.tag == .windows) "." else "/tmp";
};

/// One DLSS feature for one view at one pair of sizes.
pub const Upscaler = struct {
    handle: *anyopaque,
    feature: Feature,
    render_size: [2]u32,
    output_size: [2]u32,

    /// Records what DLSS needs to start into `cmd`. Null where DLSS will not
    /// start at these sizes.
    pub fn create(device: *rhi.Device, cmd: *rhi.CommandEncoder, feature: Feature, render_size: [2]u32, output_size: [2]u32) ?Upscaler {
        if (!available) return null;
        const handle = c.limnDlssCreate(&.{
            .device = @intFromEnum(device.vkd.handle),
            .command_buffer = @intFromEnum(cmd.command),
            .feature = @intFromEnum(feature),
            .render_width = render_size[0],
            .render_height = render_size[1],
            .output_width = output_size[0],
            .output_height = output_size[1],
        });
        cmd.bindGlobals();
        return .{ .handle = handle orelse return null, .feature = feature, .render_size = render_size, .output_size = output_size };
    }

    /// The GPU must have finished with every frame it was used in.
    pub fn destroy(self: Upscaler) void {
        if (available) c.limnDlssDestroy(self.handle);
    }

    pub const Inputs = struct {
        /// HDR color before tone mapping, depth and motion vectors at render
        /// size, in `TextureState.shader_read`. For Ray Reconstruction the
        /// color is the traced picture, neither gathered over frames nor
        /// denoised.
        color: rhi.Texture,
        depth: rhi.Texture,
        motion: rhi.Texture,
        /// At output size, in `TextureState.external`.
        output: rhi.Texture,
        /// Ray Reconstruction only: what the surface seen scatters, what it
        /// reflects, and its world normal with roughness in alpha.
        diffuse_albedo: ?rhi.Texture = null,
        specular_albedo: ?rhi.Texture = null,
        normal_roughness: ?rhi.Texture = null,
        /// This frame's subpixel jitter, as a fraction of the picture
        /// (`FrameConstants.jitter`).
        jitter: [2]f32,
        /// Row-major, as DLSS reads them.
        world_to_view: [16]f32,
        view_to_clip: [16]f32,
        delta_time: f32,
        /// Discards the history.
        reset: bool,
    };

    /// Records the upscaling. Rebinds the encoder's texture table before
    /// returning.
    pub fn dispatch(self: Upscaler, device: *rhi.Device, cmd: *rhi.CommandEncoder, inputs: Inputs) !void {
        if (!available) return error.DlssUnavailable;
        const width: f32 = @floatFromInt(self.render_size[0]);
        const height: f32 = @floatFromInt(self.render_size[1]);
        const result = c.limnDlssDispatch(self.handle, &.{
            .command_buffer = @intFromEnum(cmd.command),
            .color = image(device, inputs.color),
            .depth = image(device, inputs.depth),
            .motion = image(device, inputs.motion),
            .output = image(device, inputs.output),
            .diffuse_albedo = if (inputs.diffuse_albedo) |texture| image(device, texture) else .{},
            .specular_albedo = if (inputs.specular_albedo) |texture| image(device, texture) else .{},
            .normal_roughness = if (inputs.normal_roughness) |texture| image(device, texture) else .{},
            .jitter = .{ inputs.jitter[0] * width * jitter_sign[0], inputs.jitter[1] * height * jitter_sign[1] },
            .motion_scale = .{ -width, -height },
            .world_to_view = inputs.world_to_view,
            .view_to_clip = inputs.view_to_clip,
            .frame_milliseconds = @max(inputs.delta_time * 1000, 0.01),
            .reset = @intFromBool(inputs.reset),
        });
        cmd.bindGlobals();
        if (result != 0) return error.DlssFailed;
    }

    /// Sign of DLSS's jitter relative to the renderer's projection.
    const jitter_sign = [2]f32{ 1, 1 };

    fn image(device: *rhi.Device, texture: rhi.Texture) Image {
        const resource = device.textureResource(texture);
        return .{
            .image = @intFromEnum(resource.image),
            .view = @intFromEnum(resource.view),
            .format = @intFromEnum(resource.vk_format),
            .width = resource.info.width,
            .height = resource.info.height,
        };
    }
};
