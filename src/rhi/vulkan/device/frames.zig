//! The frame loop, and command encoders submitted outside it. Internal to the device.
const std = @import("std");
const vk = @import("vulkan");
const types = @import("../../types.zig");
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
const max_parallel = device_module.max_parallel;
const recordGeneratedFrame = @import("presentation.zig").recordGeneratedFrame;
const presentation = @import("presentation.zig");

/// Queues a copy ordered with the pending uploads; `source` is destroyed
/// once it is recorded.
pub fn queueBufferCopy(self: *Device, source: types.Buffer, destination: types.Buffer, size: u64) !void {
    try self.uploads.append(self.gpa, .{ .copy = .{ .source = source, .destination = destination, .size = size } });
}

/// `waitForFrame` + `prepareSurface` + `acquireImage` + `startFrame`.
/// Returns null when there is nothing to draw to; try again next time.
pub fn beginFrame(self: *Device) !?Frame {
    try waitForFrame(self);
    if (!try presentation.prepareSurface(self)) return null;
    if (!try presentation.acquireImage(self)) return null;
    return try startFrame(self);
}

/// Submits the frame and presents the backbuffer if there is one.
pub fn endFrame(self: *Device) !void {
    try submitFrame(self);
    try presentation.presentFrame(self);
}

/// Blocks until the GPU has finished the frame whose slot is reused next.
/// Touches no shared device state but `failDevice`'s test counter.
pub fn waitForFrame(self: *Device) !void {
    if (self.faked_lost) return error.DeviceLost;
    if (self.lose_after) |*left| {
        if (left.* == 0) {
            self.faked_lost = true;
            return error.DeviceLost;
        }
        left.* -= 1;
    }
    const frame = &self.frames[@intCast(self.frame_number % frames_in_flight)];
    _ = self.vkd.waitForFences(&.{frame.fence}, .true, std.math.maxInt(u64)) catch |err| {
        if (err == error.DeviceLost) reportFault(self);
        return err;
    };
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
    for (frame.worker_pools) |pool| if (pool != .null_handle) try self.vkd.resetCommandPool(pool, .{});
    if (frame.async_pool != .null_handle) try self.vkd.resetCommandPool(frame.async_pool, .{});
    frame.submit_count = 0;
    frame.async_planned = false;
    frame.async_recorded = false;
    frame.wait_from = std.math.maxInt(u32);
    frame.split_taken = 0;
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
    self.encoder.settle();
    const presenting = self.swapchain != null;
    if (presenting) {
        recordGeneratedFrame(self, frame);
        self.encoder.transition(self.swapchain.?.textures.items[self.swapchain.?.image_index], .present);
    }
    self.encoder.flush();
    try self.vkd.endCommandBuffer(self.encoder.command);
    self.encoder.submitInto(frame);
    self.in_frame = false;

    try self.vkd.resetFences(&.{frame.fence});
    errdefer if (self.vkd.createFence(&.{ .flags = .{ .signaled_bit = true } }, null)) |signaled| {
        self.vkd.destroyFence(frame.fence, null);
        frame.fence = signaled;
    } else |_| {};
    var command_infos: [2 * max_parallel + 4]vk.CommandBufferSubmitInfo = undefined;
    for (frame.submits[0..frame.submit_count], command_infos[0..frame.submit_count]) |command, *info| info.* = .{ .command_buffer = command, .device_mask = 0 };
    var wait_info: [3]vk.SemaphoreSubmitInfo = undefined;
    var signal_info: [3]vk.SemaphoreSubmitInfo = undefined;
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
    signal_info[semaphore_count] = .{ .semaphore = self.frame_timeline, .value = self.frame_number + 1, .stage_mask = .{ .all_commands_bit = true }, .device_index = 0 };
    var wait_count = semaphore_count;
    var first_waiting: u32 = 0;
    self.queue_mutex.lockUncancelable(self.io);
    defer self.queue_mutex.unlock(self.io);
    if (frame.async_recorded) {
        self.async_encoder.flush();
        try self.vkd.endCommandBuffer(frame.async_command);
        const after_previous = vk.SemaphoreSubmitInfo{ .semaphore = self.frame_timeline, .value = self.frame_number, .stage_mask = .{ .all_commands_bit = true }, .device_index = 0 };
        const done = vk.SemaphoreSubmitInfo{ .semaphore = self.async_timeline, .value = self.frame_number + 1, .stage_mask = .{ .all_commands_bit = true }, .device_index = 0 };
        try self.vkd.queueSubmit2(self.async_queue.?, &.{.{
            .wait_semaphore_info_count = 1,
            .p_wait_semaphore_infos = @ptrCast(&after_previous),
            .command_buffer_info_count = 1,
            .p_command_buffer_infos = &.{.{ .command_buffer = frame.async_command, .device_mask = 0 }},
            .signal_semaphore_info_count = 1,
            .p_signal_semaphore_infos = @ptrCast(&done),
        }}, .null_handle);
        wait_info[wait_count] = .{ .semaphore = self.async_timeline, .value = self.frame_number + 1, .stage_mask = .{ .all_commands_bit = true }, .device_index = 0 };
        wait_count += 1;
        first_waiting = @min(frame.wait_from, frame.submit_count - 1);
    }
    const batches = [2]vk.SubmitInfo2{ .{
        .command_buffer_info_count = first_waiting,
        .p_command_buffer_infos = &command_infos,
    }, .{
        .wait_semaphore_info_count = wait_count,
        .p_wait_semaphore_infos = &wait_info,
        .command_buffer_info_count = frame.submit_count - first_waiting,
        .p_command_buffer_infos = command_infos[first_waiting..].ptr,
        .signal_semaphore_info_count = semaphore_count + 1,
        .p_signal_semaphore_infos = &signal_info,
    } };
    try self.vkd.queueSubmit2(self.queue, if (first_waiting == 0) batches[1..] else &batches, frame.fence);
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
    try self.endImmediate(&encoder);
    if (self.ring.fenced == self.ring.head) self.ring = .{};
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

/// Submits without waiting; poll `detachedDone`, then `releaseDetached`. The
/// job starts once frame `after` is done on the GPU, so it may read what that
/// frame uploads.
pub fn submitDetached(self: *Device, encoder: CommandEncoder, after: u64) !Detached {
    var settled = encoder;
    settled.settle();
    errdefer self.vkd.freeCommandBuffers(self.detached_pool, &.{encoder.command});
    try self.vkd.endCommandBuffer(encoder.command);
    const value = self.detached_signaled + 1;
    const command_info = vk.CommandBufferSubmitInfo{ .command_buffer = encoder.command, .device_mask = 0 };
    const wait = vk.SemaphoreSubmitInfo{ .semaphore = self.frame_timeline, .value = after + 1, .stage_mask = .{ .all_commands_bit = true }, .device_index = 0 };
    const signal = vk.SemaphoreSubmitInfo{ .semaphore = self.detached_timeline, .value = value, .stage_mask = .{ .all_commands_bit = true }, .device_index = 0 };
    try self.vkd.queueSubmit2(self.detached_queue.?, &.{.{
        .wait_semaphore_info_count = 1,
        .p_wait_semaphore_infos = @ptrCast(&wait),
        .command_buffer_info_count = 1,
        .p_command_buffer_infos = @ptrCast(&command_info),
        .signal_semaphore_info_count = 1,
        .p_signal_semaphore_infos = @ptrCast(&signal),
    }}, .null_handle);
    self.detached_signaled = value;
    self.detached_outstanding += 1;
    return .{ .command = @intFromEnum(encoder.command), .value = value, .after = after };
}

/// How far the detached jobs have got: those signalling up to this are done.
pub fn detachedReached(self: *Device) u64 {
    return self.vkd.getSemaphoreCounterValue(self.detached_timeline) catch 0;
}

pub fn detachedDone(self: *Device, job: Detached) bool {
    return detachedReached(self) >= job.value;
}

/// The frame the job waits for has been submitted, so waiting for the job
/// cannot block on frames not yet recorded.
pub fn detachedStarted(self: *const Device, job: Detached) bool {
    return self.frame_number > job.after;
}

/// Waits for the job if it is still running; only once `detachedStarted`.
pub fn releaseDetached(self: *Device, job: Detached) void {
    _ = self.vkd.waitSemaphores(&.{ .semaphore_count = 1, .p_semaphores = @ptrCast(&self.detached_timeline), .p_values = @ptrCast(&job.value) }, std.math.maxInt(u64)) catch {};
    self.vkd.freeCommandBuffers(self.detached_pool, &.{@as(vk.CommandBuffer, @enumFromInt(job.command))});
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
pub fn endImmediate(self: *Device, encoder: *CommandEncoder) !void {
    encoder.settle();
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

const staging_ring_size = 32 * 1024 * 1024;

/// Where `createStaging` put the data.
pub const Staging = struct {
    buffer: types.Buffer,
    offset: u64 = 0,

    /// The buffer is the data's own, for the upload to destroy.
    pub fn owned(self: Staging, device: *const Device) bool {
        return !device_module.sameHandle(self.buffer, device.staging_ring);
    }
};

/// Copies `data` into the staging ring, or into a buffer of its own when it
/// is a quarter of the ring or more or the ring is full.
pub fn createStaging(self: *Device, data: []const u8) !Staging {
    if (data.len < staging_ring_size / 4) if (try ringSpace(self, data.len)) |offset| {
        @memcpy(self.mapped(self.staging_ring)[@intCast(offset)..][0..data.len], data);
        return .{ .buffer = self.staging_ring, .offset = offset };
    };
    const staging = try self.createBuffer(.{
        .name = "staging",
        .size = data.len,
        .usage = .{ .copy_src = true },
        .memory = .cpu_to_gpu,
    });
    @memcpy(self.mapped(staging)[0..data.len], data);
    return .{ .buffer = staging };
}

fn ringSpace(self: *Device, size: usize) !?u64 {
    if (!self.staging_ring.isValid()) self.staging_ring = try self.createBuffer(.{
        .name = "staging ring",
        .size = staging_ring_size,
        .usage = .{ .copy_src = true },
        .memory = .cpu_to_gpu,
    });
    retireRing(self);
    const ring = &self.ring;
    if (ring.head == ring.tail) ring.* = .{};
    const length = std.mem.alignForward(u64, size, 16);
    var offset = ring.head;
    if (ring.head >= ring.tail) {
        if (staging_ring_size - ring.head < length) {
            if (length >= ring.tail) return null;
            offset = 0;
        }
    } else if (ring.tail - ring.head <= length) return null;
    ring.head = offset + length;
    return offset;
}

fn retireRing(self: *Device) void {
    const ring = &self.ring;
    if (ring.fence_count == 0) return;
    const reached = self.vkd.getSemaphoreCounterValue(self.frame_timeline) catch return;
    var done: u32 = 0;
    while (done < ring.fence_count and ring.fences[done].value <= reached) : (done += 1) ring.tail = ring.fences[done].end;
    std.mem.copyForwards(device_module.StagingRing.Fence, ring.fences[0 .. ring.fence_count - done], ring.fences[done..ring.fence_count]);
    ring.fence_count -= done;
}

/// Called once uploads are recorded: what was staged so far is free again
/// when the frame being recorded has finished. Earlier submissions are done
/// by then too, so this covers immediate encoders as well.
pub fn fenceRing(self: *Device) void {
    const ring = &self.ring;
    if (ring.fenced == ring.head) return;
    const value = self.frame_number + 1;
    if (ring.fence_count == ring.fences.len) {
        ring.fences[ring.fence_count - 1] = .{ .end = ring.head, .value = value };
    } else {
        ring.fences[ring.fence_count] = .{ .end = ring.head, .value = value };
        ring.fence_count += 1;
    }
    ring.fenced = ring.head;
}

/// Called by `CommandEncoder.flushUploads`; use that. The caller owns the
/// list, gives it back with `returnUploads`, and destroys the staging
/// buffers that are its own.
pub fn takeUploads(self: *Device) std.ArrayList(PendingUpload) {
    const result = self.uploads;
    self.uploads = self.spare_uploads;
    self.spare_uploads = .empty;
    self.pending_upload_bytes = 0;
    return result;
}

/// Gives back a list from `takeUploads` once its uploads are recorded.
pub fn returnUploads(self: *Device, list: std.ArrayList(PendingUpload)) void {
    var spare = list;
    spare.clearRetainingCapacity();
    if (self.spare_uploads.capacity >= spare.capacity) return spare.deinit(self.gpa);
    self.spare_uploads.deinit(self.gpa);
    self.spare_uploads = spare;
}

fn collectTimings(self: *Device, frame: *FrameData) void {
    const scope_count: u32 = @min(frame.scope_count, max_timing_scopes);
    if (!frame.submitted or scope_count == 0) return;
    var raw: [max_timing_scopes * 2]u64 = undefined;
    _ = self.vkd.getQueryPoolResults(
        frame.query_pool,
        0,
        scope_count * 2,
        @sizeOf(u64) * scope_count * 2,
        &raw,
        @sizeOf(u64),
        .{ .@"64_bit" = true },
    ) catch return;
    const period: f64 = self.properties.limits.timestamp_period;
    for (frame.scopes[0..scope_count], 0..) |scope, index| {
        const ticks = raw[index * 2 + 1] -% raw[index * 2];
        self.timings[index] = .{
            .name = scope.name,
            .milliseconds = @floatCast(@as(f64, @floatFromInt(ticks)) * period / 1e6),
            .depth = scope.depth,
            .work = scope.work,
        };
    }
    self.timing_count = scope_count;
}

/// Logs where a lost device faulted, when the driver says: each address,
/// what was done there and the buffer it falls in.
pub fn reportFault(self: *Device) void {
    if (!self.device_fault) return;
    var counts = vk.DeviceFaultCountsEXT{};
    _ = self.vkd.getDeviceFaultInfoEXT(&counts, null) catch return;
    var addresses: [16]vk.DeviceFaultAddressInfoEXT = undefined;
    var vendors: [8]vk.DeviceFaultVendorInfoEXT = undefined;
    counts.address_info_count = @min(counts.address_info_count, addresses.len);
    counts.vendor_info_count = @min(counts.vendor_info_count, vendors.len);
    counts.vendor_binary_size = 0;
    var info = vk.DeviceFaultInfoEXT{ .description = undefined, .p_address_infos = &addresses[0], .p_vendor_infos = &vendors[0] };
    _ = self.vkd.getDeviceFaultInfoEXT(&counts, &info) catch return;
    std.log.err("device lost: {s}", .{std.mem.sliceTo(&info.description, 0)});
    for (addresses[0..counts.address_info_count]) |entry| {
        var buffer_name: []const u8 = "no buffer";
        var offset: u64 = 0;
        var below: ?device_module.BufferResource = null;
        for (0..self.buffers.slotCount()) |slot_index| if (self.buffers.slotAt(slot_index).value) |resource| {
            if (resource.address <= entry.reported_address and (below == null or resource.address > below.?.address)) below = resource;
            if (entry.reported_address < resource.address or entry.reported_address >= resource.address + resource.size) continue;
            buffer_name = std.mem.sliceTo(&resource.name, 0);
            offset = entry.reported_address - resource.address;
        };
        if (offset == 0) if (below) |nearest| std.log.err("  nearest buffer below: {s}, {d} bytes, ends {d} bytes before", .{ std.mem.sliceTo(&nearest.name, 0), nearest.size, entry.reported_address -| (nearest.address + nearest.size) });
        std.log.err("  fault type {d} (1 read, 2 write, 3 execute) at 0x{x} (within 0x{x}): {s} + {d}", .{ @intFromEnum(entry.address_type), entry.reported_address, entry.address_precision, buffer_name, offset });
    }
    for (vendors[0..counts.vendor_info_count]) |vendor| std.log.err("  {s} (code 0x{x}, data 0x{x})", .{ std.mem.sliceTo(&vendor.description, 0), vendor.vendor_fault_code, vendor.vendor_fault_data });
}

/// Gives `count` encoders that may record on as many threads at once, after
/// what the frame's encoder recorded so far and before what it records after
/// `joinParallel`. Until then the frame's encoder records nothing, device
/// texture states stay as they are, and resources may be made, destroyed
/// and given views only through the device's own calls, which lock.
pub fn beginParallel(self: *Device, count: u32) ![]CommandEncoder {
    std.debug.assert(self.in_frame and self.parallel_count == 0 and count != 0 and count <= max_parallel);
    const frame = &self.frames[@intCast(self.frame_number % frames_in_flight)];
    self.encoder.settle();
    for (0..count) |index| {
        if (frame.worker_pools[index] == .null_handle) {
            const pool = try self.vkd.createCommandPool(&.{ .queue_family_index = self.queue_family }, null);
            errdefer self.vkd.destroyCommandPool(pool, null);
            try self.vkd.allocateCommandBuffers(&.{ .command_pool = pool, .level = .primary, .command_buffer_count = 1 }, @ptrCast(&frame.worker_commands[index]));
            frame.worker_pools[index] = pool;
        }
    }
    self.encoder.flush();
    try self.vkd.endCommandBuffer(self.encoder.command);
    self.encoder.submitInto(frame);
    for (0..count) |index| {
        try self.vkd.beginCommandBuffer(frame.worker_commands[index], &.{ .flags = .{ .one_time_submit_bit = true } });
        if (index >= self.parallel_made) {
            self.parallel_states[index] = .{ .gpa = self.gpa };
            self.parallel_made = @intCast(index + 1);
        }
        self.parallel_states[index].entries.clearRetainingCapacity();
        self.parallel_states[index].failed = false;
        self.parallel[index] = .{ .device = self, .command = frame.worker_commands[index], .frame = frame, .local = &self.parallel_states[index], .split_slot = @intCast(index) };
        self.parallel[index].bindGlobals();
        self.parallel_count += 1;
    }
    return self.parallel[0..count];
}

/// Ends the encoders `beginParallel` gave, in order. Before each one goes
/// what moves the textures it used from the states the ones before left to
/// those it found; the device's states become those the last one left. The
/// frame's encoder goes on in a command buffer of its own after them.
pub fn joinParallel(self: *Device) !void {
    const frame = &self.frames[@intCast(self.frame_number % frames_in_flight)];
    const encoders = self.parallel[0..self.parallel_count];
    const states = self.parallel_states[0..self.parallel_count];
    defer self.parallel_count = 0;
    var failed = false;
    for (encoders, states, 0..) |*encoder, *local, index| {
        std.debug.assert(encoder.scope_depth == 0 and !encoder.rendering);
        encoder.settle();
        failed = failed or local.failed;
        for (local.entries.items) |entry| {
            const resource = self.textures.get(entry.texture) orelse continue;
            resource.states[entry.mip] = entry.state;
        }
        if (index + 1 < encoders.len) for (states[index + 1].entries.items) |entry| {
            const resource = self.textures.get(entry.texture) orelse continue;
            const now = resource.states[entry.mip];
            if (now != entry.found) encoder.moveMip(entry.texture, entry.mip, now, entry.found);
        };
        inline for (std.meta.fields(types.Work)) |field| @field(self.encoder.work, field.name) += @field(encoder.work, field.name);
        encoder.flush();
        try self.vkd.endCommandBuffer(encoder.command);
        encoder.submitInto(frame);
    }
    if (frame.tail == .null_handle) try self.vkd.allocateCommandBuffers(&.{ .command_pool = frame.pool, .level = .primary, .command_buffer_count = 1 }, @ptrCast(&frame.tail));
    try self.vkd.beginCommandBuffer(frame.tail, &.{ .flags = .{ .one_time_submit_bit = true } });
    self.encoder.command = frame.tail;
    self.encoder.bindGlobals();
    if (failed) return error.OutOfMemory;
}

/// Says, while the frame is being planned, that it will record async
/// compute: encoders then wait for it from their first `awaitAsync`. Does
/// nothing without an async queue.
pub fn planAsync(self: *Device) void {
    std.debug.assert(self.in_frame);
    if (self.async_queue == null) return;
    self.frames[@intCast(self.frame_number % frames_in_flight)].async_planned = true;
}

/// The frame's encoder for the async queue, held by the caller until
/// `releaseAsync`; null when the frame planned none. Its work runs once the
/// previous frame is done, beside this frame's work before its first
/// `awaitAsync`. Only buffers and pipelines; no texture transitions.
pub fn acquireAsync(self: *Device) !?*CommandEncoder {
    const frame = &self.frames[@intCast(self.frame_number % frames_in_flight)];
    if (!frame.async_planned) return null;
    self.async_mutex.lockUncancelable(self.io);
    errdefer self.async_mutex.unlock(self.io);
    if (!frame.async_recorded) {
        if (frame.async_pool == .null_handle) {
            frame.async_pool = try self.vkd.createCommandPool(&.{ .queue_family_index = self.queue_family }, null);
            try self.vkd.allocateCommandBuffers(&.{ .command_pool = frame.async_pool, .level = .primary, .command_buffer_count = 1 }, @ptrCast(&frame.async_command));
        }
        try self.vkd.beginCommandBuffer(frame.async_command, &.{ .flags = .{ .one_time_submit_bit = true } });
        self.async_encoder = .{ .device = self, .command = frame.async_command, .frame = null };
        self.async_encoder.bindGlobals();
        frame.async_recorded = true;
    }
    return &self.async_encoder;
}

/// Lets go of the encoder `acquireAsync` gave.
pub fn releaseAsync(self: *Device) void {
    self.async_mutex.unlock(self.io);
}
