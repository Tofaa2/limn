//! The frame loop, and command encoders submitted outside it. Internal to the device.
const std = @import("std");
const vk = @import("vulkan");
const types = @import("../types.zig");
const device_module = @import("../device.zig");

const Device = device_module.Device;
const CommandEncoder = @import("../command.zig").CommandEncoder;
const Detached = device_module.Detached;
const Frame = device_module.Frame;
const FrameData = device_module.FrameData;
const PendingUpload = device_module.PendingUpload;
const abandonAcquiredImage = @import("presentation.zig").abandonAcquiredImage;
const collectGarbage = @import("objects.zig").collectGarbage;
const finishPacedPresent = @import("presentation.zig").finishPacedPresent;
const frames_in_flight = device_module.frames_in_flight;
const max_timing_scopes = device_module.max_timing_scopes;
const recordGeneratedFrame = @import("presentation.zig").recordGeneratedFrame;

/// Queues a copy ordered with the pending uploads; `source` is destroyed
/// once it is recorded.
pub fn queueBufferCopy(self: *Device, source: types.Buffer, destination: types.Buffer, size: u64) !void {
    try self.uploads.append(self.gpa, .{ .copy = .{ .source = source, .destination = destination, .size = size } });
}

/// `waitForFrame` + `prepareSurface` + `acquireImage` + `startFrame`.
/// Returns null when there is nothing to draw to; try again next time.
pub fn beginFrame(self: *Device) !?Frame {
    try self.waitForFrame();
    if (!try self.prepareSurface()) return null;
    if (!try self.acquireImage()) return null;
    return try self.startFrame();
}

/// Submits the frame and presents the backbuffer if there is one.
pub fn endFrame(self: *Device) !void {
    try self.submitFrame();
    try self.presentFrame();
}

/// Blocks until the GPU has finished the frame whose slot is reused next.
/// Touches no shared device state.
pub fn waitForFrame(self: *Device) !void {
    const frame = &self.frames[@intCast(self.frame_number % frames_in_flight)];
    _ = try self.vkd.waitForFences(&.{frame.fence}, .true, std.math.maxInt(u64));
}

/// Begins recording, after `waitForFrame` and `acquireImage`. On failure
/// the acquired image is abandoned.
pub fn startFrame(self: *Device) !Frame {
    std.debug.assert(!self.in_frame);
    const frame = &self.frames[@intCast(self.frame_number % frames_in_flight)];
    errdefer abandonAcquiredImage(self, frame);
    collectTimings(self, frame);
    collectGarbage(self, false);
    var backbuffer: ?types.Texture = null;
    if (self.swapchain) |*swapchain| {
        backbuffer = swapchain.textures.items[swapchain.image_index];
        self.textureResource(backbuffer.?).states[0] = .undefined;
    }
    try self.vkd.resetCommandPool(frame.pool, .{});
    try self.vkd.beginCommandBuffer(frame.command, &.{ .flags = .{ .one_time_submit_bit = true } });
    frame.scope_count = 0;
    self.vkd.cmdResetQueryPool(frame.command, frame.query_pool, 0, max_timing_scopes * 2);
    self.encoder = .{ .device = self, .command = frame.command, .frame = frame };
    self.in_frame = true;
    self.encoder.bindGlobals();
    try self.encoder.flushUploads();
    return .{ .cmd = &self.encoder, .backbuffer = backbuffer, .index = self.frame_number };
}

/// Ends recording and submits. On failure the image is abandoned and the
/// slot's fence is left signaled.
pub fn submitFrame(self: *Device) !void {
    std.debug.assert(self.in_frame);
    const frame = &self.frames[@intCast(self.frame_number % frames_in_flight)];
    std.debug.assert(self.encoder.scope_depth == 0);
    errdefer {
        self.in_frame = false;
        abandonAcquiredImage(self, frame);
    }
    const presenting = self.swapchain != null;
    if (presenting) {
        recordGeneratedFrame(self, frame);
        self.encoder.transition(self.swapchain.?.textures.items[self.swapchain.?.image_index], .present);
    }
    try self.vkd.endCommandBuffer(frame.command);
    self.in_frame = false;

    try self.vkd.resetFences(&.{frame.fence});
    errdefer if (self.vkd.createFence(&.{ .flags = .{ .signaled_bit = true } }, null)) |signaled| {
        self.vkd.destroyFence(frame.fence, null);
        frame.fence = signaled;
    } else |_| {};
    const command_info = vk.CommandBufferSubmitInfo{ .command_buffer = frame.command, .device_mask = 0 };
    var wait_info: [2]vk.SemaphoreSubmitInfo = undefined;
    var signal_info: [2]vk.SemaphoreSubmitInfo = undefined;
    var semaphore_count: u32 = 0;
    if (self.swapchain) |*swapchain| {
        const acquired = [2]vk.Semaphore{ frame.image_available, frame.generated_available };
        const indices = [2]?u32{ swapchain.image_index, swapchain.generated_index };
        for (acquired, indices) |semaphore, index| {
            const image = index orelse continue;
            wait_info[semaphore_count] = .{ .semaphore = semaphore, .value = 0, .stage_mask = .{ .all_commands_bit = true }, .device_index = 0 };
            signal_info[semaphore_count] = .{
                .semaphore = swapchain.render_finished.items[image],
                .value = 0,
                .stage_mask = .{ .all_commands_bit = true },
                .device_index = 0,
            };
            semaphore_count += 1;
        }
    }
    self.queue_mutex.lockUncancelable(self.io);
    defer self.queue_mutex.unlock(self.io);
    try self.vkd.queueSubmit2(self.queue, &.{.{
        .wait_semaphore_info_count = semaphore_count,
        .p_wait_semaphore_infos = &wait_info,
        .command_buffer_info_count = 1,
        .p_command_buffer_infos = @ptrCast(&command_info),
        .signal_semaphore_info_count = semaphore_count,
        .p_signal_semaphore_infos = &signal_info,
    }}, frame.fence);
    if (self.swapchain) |*swapchain| swapchain.present_pending = true;
    frame.submitted = true;
    self.frame_number += 1;
}

/// Closes the open render pass and timing scopes of a frame whose
/// recording failed. `submitFrame` must still follow.
pub fn closeFailedFrame(self: *Device) void {
    std.debug.assert(self.in_frame);
    if (self.encoder.rendering) self.encoder.endRendering();
    while (self.encoder.scope_depth > 0) self.encoder.endScope();
}

/// `vkDeviceWaitIdle` with the queue held, since presenting may run on
/// another thread.
pub fn waitQueue(self: *Device) !void {
    self.queue_mutex.lockUncancelable(self.io);
    defer self.queue_mutex.unlock(self.io);
    try self.vkd.deviceWaitIdle();
}

/// Blocks until every submitted frame has finished on the GPU.
pub fn waitIdle(self: *Device) !void {
    finishPacedPresent(self);
    try waitQueue(self);
    if (!self.in_frame) collectGarbage(self, true);
}

/// Records and submits every queued upload, blocking until done.
pub fn flushUploadsBlocking(self: *Device) !void {
    std.debug.assert(!self.in_frame);
    if (self.uploads.items.len == 0) return;
    var encoder = try self.beginImmediate();
    try encoder.flushUploads();
    try self.endImmediate();
    collectGarbage(self, true);
}

/// Staged bytes no flush has recorded yet, including cancelled uploads.
pub fn pendingUploadBytes(self: *const Device) u64 {
    return self.pending_upload_bytes;
}

/// Starts a command buffer for the second queue, or null where the GPU
/// has one queue. While it runs it must not touch what a frame writes nor
/// write what a frame reads. Finish with `submitDetached`.
pub fn beginDetached(self: *Device) !?CommandEncoder {
    if (self.detached_queue == null) return null;
    var command: vk.CommandBuffer = undefined;
    try self.vkd.allocateCommandBuffers(&.{
        .command_pool = self.detached_pool,
        .level = .primary,
        .command_buffer_count = 1,
    }, @ptrCast(&command));
    errdefer self.vkd.freeCommandBuffers(self.detached_pool, &.{command});
    try self.vkd.beginCommandBuffer(command, &.{ .flags = .{ .one_time_submit_bit = true } });
    var encoder = CommandEncoder{ .device = self, .command = command, .frame = null };
    encoder.bindGlobals();
    return encoder;
}

/// Submits without waiting; poll `detachedDone`, then `releaseDetached`.
pub fn submitDetached(self: *Device, encoder: CommandEncoder) !Detached {
    errdefer self.vkd.freeCommandBuffers(self.detached_pool, &.{encoder.command});
    try self.vkd.endCommandBuffer(encoder.command);
    const fence = try self.vkd.createFence(&.{}, null);
    errdefer self.vkd.destroyFence(fence, null);
    const command_info = vk.CommandBufferSubmitInfo{ .command_buffer = encoder.command, .device_mask = 0 };
    try self.vkd.queueSubmit2(self.detached_queue.?, &.{.{
        .command_buffer_info_count = 1,
        .p_command_buffer_infos = @ptrCast(&command_info),
    }}, fence);
    self.detached_outstanding += 1;
    return .{ .command = encoder.command, .fence = fence };
}

pub fn detachedDone(self: *Device, job: Detached) bool {
    return (self.vkd.getFenceStatus(job.fence) catch return false) == .success;
}

/// Waits for the job if it is still running.
pub fn releaseDetached(self: *Device, job: Detached) void {
    _ = self.vkd.waitForFences(&.{job.fence}, .true, std.math.maxInt(u64)) catch {};
    self.vkd.destroyFence(job.fence, null);
    self.vkd.freeCommandBuffers(self.detached_pool, &.{job.command});
    self.detached_outstanding -= 1;
}

/// Starts a one-off command buffer; finish with `endImmediate`.
pub fn beginImmediate(self: *Device) !CommandEncoder {
    std.debug.assert(!self.in_frame);
    try self.vkd.resetCommandPool(self.immediate_pool, .{});
    try self.vkd.beginCommandBuffer(self.immediate_command, &.{ .flags = .{ .one_time_submit_bit = true } });
    var encoder = CommandEncoder{ .device = self, .command = self.immediate_command, .frame = null };
    encoder.bindGlobals();
    return encoder;
}

/// Submits and blocks until the GPU is idle, then runs all deferred
/// destruction. The encoder must not be used afterwards.
pub fn endImmediate(self: *Device) !void {
    try self.vkd.endCommandBuffer(self.immediate_command);
    const fence = try self.vkd.createFence(&.{}, null);
    defer self.vkd.destroyFence(fence, null);
    const command_info = vk.CommandBufferSubmitInfo{ .command_buffer = self.immediate_command, .device_mask = 0 };
    {
        self.queue_mutex.lockUncancelable(self.io);
        defer self.queue_mutex.unlock(self.io);
        try self.vkd.queueSubmit2(self.queue, &.{.{
            .command_buffer_info_count = 1,
            .p_command_buffer_infos = @ptrCast(&command_info),
        }}, fence);
    }
    _ = try self.vkd.waitForFences(&.{fence}, .true, std.math.maxInt(u64));
    try self.waitIdle();
}

pub fn createStaging(self: *Device, data: []const u8) !types.Buffer {
    const staging = try self.createBuffer(.{
        .name = "staging",
        .size = data.len,
        .usage = .{ .copy_src = true },
        .memory = .cpu_to_gpu,
    });
    @memcpy(self.mapped(staging)[0..data.len], data);
    return staging;
}

/// Called by `CommandEncoder.flushUploads`; use that. The caller owns the
/// list (free with `gpa`) and must record and destroy its staging buffers.
pub fn takeUploads(self: *Device) std.ArrayList(PendingUpload) {
    const result = self.uploads;
    self.uploads = .empty;
    self.pending_upload_bytes = 0;
    return result;
}

fn collectTimings(self: *Device, frame: *FrameData) void {
    if (!frame.submitted or frame.scope_count == 0) return;
    var raw: [max_timing_scopes * 2]u64 = undefined;
    _ = self.vkd.getQueryPoolResults(
        frame.query_pool,
        0,
        frame.scope_count * 2,
        @sizeOf(u64) * frame.scope_count * 2,
        &raw,
        @sizeOf(u64),
        .{ .@"64_bit" = true },
    ) catch return;
    const period: f64 = self.properties.limits.timestamp_period;
    for (frame.scopes[0..frame.scope_count], 0..) |scope, index| {
        const ticks = raw[index * 2 + 1] -% raw[index * 2];
        self.timings[index] = .{
            .name = scope.name,
            .milliseconds = @floatCast(@as(f64, @floatFromInt(ticks)) * period / 1e6),
            .depth = scope.depth,
        };
    }
    self.timing_count = frame.scope_count;
}
