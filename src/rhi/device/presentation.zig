//! The swapchain: acquiring, pacing and presenting its images. Internal to the device.
const std = @import("std");
const vk = @import("vulkan");
const types = @import("../types.zig");
const device_module = @import("../device.zig");

const Device = device_module.Device;
const FrameData = device_module.FrameData;
const FrameGenerator = device_module.FrameGenerator;
const frames_in_flight = device_module.frames_in_flight;
const registerTexture = @import("textures.zig").registerTexture;

/// Format of the swapchain images.
pub fn backbufferFormat(self: *Device) !types.Format {
    if (self.swapchain == null) return error.NoSurface;
    if (self.swapchain.?.handle == .null_handle) try recreateSwapchain(self);
    return switch (self.swapchain.?.format.format) {
        .b8g8r8a8_srgb => .bgra8_srgb,
        .b8g8r8a8_unorm => .bgra8_unorm,
        .r8g8b8a8_srgb => .rgba8_srgb,
        .r8g8b8a8_unorm => .rgba8_unorm,
        .a2b10g10r10_unorm_pack32 => .a2b10g10r10_unorm,
        else => error.UnsupportedSurfaceFormat,
    };
}

/// Swapchain image size in pixels, which may differ from `resize`. Zero
/// when headless and before the swapchain exists.
pub fn backbufferSize(self: *const Device) [2]u32 {
    const swapchain = self.swapchain orelse return .{ 0, 0 };
    return .{ swapchain.extent.width, swapchain.extent.height };
}

/// Tells the swapchain the window's framebuffer size changed.
pub fn resize(self: *Device, width: u32, height: u32) void {
    if (self.swapchain) |*swapchain| {
        if (swapchain.requested_width == width and swapchain.requested_height == height) return;
        swapchain.requested_width = width;
        swapchain.requested_height = height;
        swapchain.dirty = true;
    }
}

/// Takes effect at the next swapchain rebuild. No-op when headless.
pub fn setVsync(self: *Device, vsync: bool) void {
    if (self.swapchain) |*swapchain| {
        if (swapchain.vsync == vsync) return;
        swapchain.vsync = vsync;
        swapchain.dirty = true;
    }
}

/// With a generator every frame presents two images: the generator's,
/// then the backbuffer half a frame later. Needs `storage_images`; takes
/// effect at the next swapchain rebuild. No-op when headless.
pub fn setFrameGenerator(self: *Device, generator: ?FrameGenerator) void {
    const swapchain = if (self.swapchain) |*value| value else return;
    if ((self.frame_generator == null) != (generator == null)) swapchain.dirty = true;
    self.frame_generator = generator;
}

/// Rebuilds the swapchain if the window changed. False while the window
/// has no drawable area; always true when headless.
pub fn prepareSurface(self: *Device) !bool {
    const swapchain = if (self.swapchain) |*value| value else return true;
    if (swapchain.requested_width == 0 or swapchain.requested_height == 0) return false;
    if (swapchain.dirty or swapchain.stale or swapchain.handle == .null_handle) {
        finishPacedPresent(self);
        try recreateSwapchain(self);
    }
    return true;
}

/// May block on the compositor. False if the swapchain went out of date.
/// May run outside a device lock.
pub fn acquireImage(self: *Device) !bool {
    const swapchain = if (self.swapchain) |*value| value else return true;
    const frame = &self.frames[@intCast(self.frame_number % frames_in_flight)];
    swapchain.image_index = acquire(self, frame.image_available) catch |err| switch (err) {
        error.OutOfDateKHR => {
            swapchain.stale = true;
            return false;
        },
        else => return err,
    };
    return true;
}

/// Blocks for the next swapchain image. While a paced present is
/// outstanding it polls instead, so as not to hold the swapchain from it.
fn acquire(self: *Device, semaphore: vk.Semaphore) !u32 {
    const swapchain = &self.swapchain.?;
    while (true) {
        const timeout: u64 = if (self.pacing.load(.acquire)) 0 else std.math.maxInt(u64);
        self.swapchain_mutex.lockUncancelable(self.io);
        const acquired = self.vkd.acquireNextImageKHR(swapchain.handle, timeout, semaphore, .null_handle);
        self.swapchain_mutex.unlock(self.io);
        const result = try acquired;
        switch (result.result) {
            .timeout, .not_ready => self.io.sleep(std.Io.Duration.fromNanoseconds(100_000), .awake) catch {},
            else => {
                if (result.result == .suboptimal_khr) swapchain.stale = true;
                return result.image_index;
            },
        }
    }
}

/// Has the generator make the picture before this frame's and puts it in
/// a second swapchain image. Leaves `Swapchain.generated_index` null when
/// there is none.
pub fn recordGeneratedFrame(self: *Device, frame: *FrameData) void {
    const swapchain = &self.swapchain.?;
    swapchain.generated_index = null;
    const generator = self.frame_generator orelse return;
    const shown, const output = swapchain.generated orelse return;
    const cmd = &self.encoder;
    cmd.beginScope("frame generation");
    defer cmd.endScope();
    cmd.copyTexture(swapchain.textures.items[swapchain.image_index], shown);
    cmd.transition(shown, .shader_read);
    cmd.transition(output, .shader_read);
    if (!generator.generate(generator.context, cmd, shown, output)) return;
    const index = acquire(self, frame.generated_available) catch {
        swapchain.stale = true;
        return;
    };
    const image = swapchain.textures.items[index];
    self.textureResource(image).states[0] = .undefined;
    cmd.copyTexture(output, image);
    cmd.transition(output, .shader_read);
    cmd.transition(image, .present);
    swapchain.generated_index = index;
}

/// Marks the image acquired for `frame` as never presented: the swapchain
/// and the acquire semaphore are recreated before the next frame.
pub fn abandonAcquiredImage(self: *Device, frame: *FrameData) void {
    const swapchain = if (self.swapchain) |*value| value else return;
    swapchain.stale = true;
    frame.acquire_abandoned = true;
}

/// May block on vsync. May run outside a device lock.
pub fn presentFrame(self: *Device) !void {
    const swapchain = if (self.swapchain) |*value| value else return;
    if (!swapchain.present_pending) return;
    swapchain.present_pending = false;
    finishPacedPresent(self);
    const now = std.Io.Timestamp.now(self.io, .awake);
    const interval: i96 = if (self.last_present) |last| @min(last.durationTo(now).nanoseconds, 100 * std.time.ns_per_ms) else 0;
    self.last_present = now;
    const generated = swapchain.generated_index orelse return present(self, swapchain.image_index);
    swapchain.generated_index = null;
    try present(self, generated);
    if (!swapchain.fifo) {
        self.pacing.store(true, .release);
        self.paced_mutex.lockUncancelable(self.io);
        defer self.paced_mutex.unlock(self.io);
        if (self.io.concurrent(presentPaced, .{ self, swapchain.image_index, now.addDuration(.fromNanoseconds(@divTrunc(interval, 2))) })) |future| {
            self.paced = future;
            return;
        } else |_| self.pacing.store(false, .release);
    }
    try present(self, swapchain.image_index);
}

fn present(self: *Device, image: u32) !void {
    const swapchain = &self.swapchain.?;
    self.swapchain_mutex.lockUncancelable(self.io);
    defer self.swapchain_mutex.unlock(self.io);
    self.queue_mutex.lockUncancelable(self.io);
    defer self.queue_mutex.unlock(self.io);
    _ = self.presented.fetchAdd(1, .monotonic);
    const result = self.vkd.queuePresentKHR(self.queue, &.{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = @ptrCast(&swapchain.render_finished.items[image]),
        .swapchain_count = 1,
        .p_swapchains = @ptrCast(&swapchain.handle),
        .p_image_indices = @ptrCast(&image),
    }) catch |err| switch (err) {
        error.OutOfDateKHR => vk.Result.suboptimal_khr,
        else => return err,
    };
    if (result == .suboptimal_khr) swapchain.stale = true;
}

fn presentPaced(self: *Device, image: u32, at: std.Io.Timestamp) void {
    const wait = std.Io.Timestamp.now(self.io, .awake).durationTo(at);
    if (wait.nanoseconds > 0) self.io.sleep(wait, .awake) catch {};
    present(self, image) catch {
        self.swapchain.?.stale = true;
    };
    self.pacing.store(false, .release);
}

pub fn finishPacedPresent(self: *Device) void {
    self.paced_mutex.lockUncancelable(self.io);
    defer self.paced_mutex.unlock(self.io);
    if (self.paced) |*future| future.await(self.io);
    self.paced = null;
}

fn recreateSwapchain(self: *Device) !void {
    const swapchain = &self.swapchain.?;
    try self.vkd.deviceWaitIdle();
    const capabilities = try self.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(self.physical, self.surface);
    const formats = try self.instance.getPhysicalDeviceSurfaceFormatsAllocKHR(self.physical, self.surface, self.gpa);
    defer self.gpa.free(formats);
    const modes = try self.instance.getPhysicalDeviceSurfacePresentModesAllocKHR(self.physical, self.surface, self.gpa);
    defer self.gpa.free(modes);
    if (formats.len == 0 or modes.len == 0) return error.SurfaceUnsupported;

    var format = formats[0];
    for (formats) |candidate| {
        if (candidate.color_space != .srgb_nonlinear_khr) continue;
        if (candidate.format == .b8g8r8a8_srgb or candidate.format == .r8g8b8a8_srgb) {
            format = candidate;
            break;
        }
    }
    swapchain_hdr: {
        self.hdr_active = false;
        if (!self.hdr_wanted) break :swapchain_hdr;
        for (formats) |candidate| {
            if (candidate.color_space == .hdr10_st2084_ext and candidate.format == .a2b10g10r10_unorm_pack32) {
                format = candidate;
                self.hdr_active = true;
                break;
            }
        }
    }
    const usage = capabilities.supported_usage_flags;
    const generating = self.frame_generator != null and self.storage_images and usage.transfer_src_bit and usage.transfer_dst_bit;
    var present_mode: vk.PresentModeKHR = .fifo_khr;
    if (!swapchain.vsync) {
        for (modes) |mode| if (mode == .mailbox_khr) {
            present_mode = mode;
        };
        for (modes) |mode| if (mode == .immediate_khr) {
            present_mode = mode;
        };
    }
    const extent: vk.Extent2D = if (capabilities.current_extent.width != std.math.maxInt(u32))
        capabilities.current_extent
    else
        .{
            .width = std.math.clamp(swapchain.requested_width, capabilities.min_image_extent.width, capabilities.max_image_extent.width),
            .height = std.math.clamp(swapchain.requested_height, capabilities.min_image_extent.height, capabilities.max_image_extent.height),
        };
    if (extent.width == 0 or extent.height == 0) return error.SurfaceUnsupported;
    var image_count = @max(capabilities.min_image_count + 1, 3) + @as(u32, @intFromBool(generating));
    if (capabilities.max_image_count != 0) image_count = @min(image_count, capabilities.max_image_count);
    var composite_alpha: vk.CompositeAlphaFlagsKHR = .{ .opaque_bit_khr = true };
    if (!capabilities.supported_composite_alpha.opaque_bit_khr) composite_alpha = .{ .inherit_bit_khr = true };

    const old = swapchain.handle;
    const handle = try self.vkd.createSwapchainKHR(&.{
        .surface = self.surface,
        .min_image_count = image_count,
        .image_format = format.format,
        .image_color_space = format.color_space,
        .image_extent = extent,
        .image_array_layers = 1,
        .image_usage = .{ .color_attachment_bit = true, .transfer_src_bit = generating, .transfer_dst_bit = generating },
        .image_sharing_mode = .exclusive,
        .pre_transform = capabilities.current_transform,
        .composite_alpha = composite_alpha,
        .present_mode = present_mode,
        .clipped = .true,
        .old_swapchain = old,
    }, null);
    releaseSwapchainImages(self);
    if (old != .null_handle) self.vkd.destroySwapchainKHR(old, null);
    for (&self.frames) |*frame| {
        if (!frame.acquire_abandoned) continue;
        const fresh = try self.vkd.createSemaphore(&.{}, null);
        self.vkd.destroySemaphore(frame.image_available, null);
        frame.image_available = fresh;
        const fresh_generated = try self.vkd.createSemaphore(&.{}, null);
        self.vkd.destroySemaphore(frame.generated_available, null);
        frame.generated_available = fresh_generated;
        frame.acquire_abandoned = false;
    }
    swapchain.handle = handle;
    swapchain.fifo = present_mode == .fifo_khr;
    swapchain.format = format;
    swapchain.extent = extent;
    swapchain.dirty = false;
    swapchain.stale = false;

    const images = try self.vkd.getSwapchainImagesAllocKHR(handle, self.gpa);
    defer self.gpa.free(images);
    const texture_format: types.Format = switch (format.format) {
        .b8g8r8a8_srgb => .bgra8_srgb,
        .b8g8r8a8_unorm => .bgra8_unorm,
        .r8g8b8a8_srgb => .rgba8_srgb,
        .r8g8b8a8_unorm => .rgba8_unorm,
        .a2b10g10r10_unorm_pack32 => .a2b10g10r10_unorm,
        else => return error.UnsupportedSurfaceFormat,
    };
    for (images) |image| {
        try swapchain.textures.append(self.gpa, try registerTexture(self, image, null, .{
            .width = extent.width,
            .height = extent.height,
            .format = texture_format,
            .mip_levels = 1,
            .layers = 1,
            .kind = .@"2d",
        }, false));
        try swapchain.render_finished.append(self.gpa, try self.vkd.createSemaphore(&.{}, null));
    }
    if (generating) swapchain.generated = createGeneratedTextures(self, texture_format, extent) catch null;
}

fn createGeneratedTextures(self: *Device, format: types.Format, extent: vk.Extent2D) ![2]types.Texture {
    const plain: types.Format = switch (format) {
        .bgra8_srgb => .bgra8_unorm,
        .rgba8_srgb => .rgba8_unorm,
        else => format,
    };
    var desc = types.TextureDesc{ .name = "frame generation", .width = extent.width, .height = extent.height, .format = plain, .usage = .{ .sampled = true, .copy_src = true, .copy_dst = true } };
    const shown = try self.createTexture(desc);
    errdefer self.destroyTexture(shown);
    desc.usage = .{ .sampled = true, .copy_src = true, .storage = true };
    return .{ shown, try self.createTexture(desc) };
}

fn releaseSwapchainImages(self: *Device) void {
    const swapchain = &self.swapchain.?;
    if (swapchain.generated) |textures| for (textures) |texture| self.destroyTexture(texture);
    swapchain.generated = null;
    for (swapchain.textures.items) |texture| {
        const resource = self.textures.remove(texture) orelse continue;
        self.vkd.destroyImageView(resource.view, null);
    }
    for (swapchain.render_finished.items) |semaphore| self.vkd.destroySemaphore(semaphore, null);
    swapchain.textures.clearRetainingCapacity();
    swapchain.render_finished.clearRetainingCapacity();
}

pub fn destroySwapchain(self: *Device) void {
    if (self.swapchain == null) return;
    finishPacedPresent(self);
    releaseSwapchainImages(self);
    const swapchain = &self.swapchain.?;
    swapchain.textures.deinit(self.gpa);
    swapchain.render_finished.deinit(self.gpa);
    if (swapchain.handle != .null_handle) self.vkd.destroySwapchainKHR(swapchain.handle, null);
    self.swapchain = null;
}
