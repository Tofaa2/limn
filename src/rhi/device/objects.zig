//! Debug names and the deferred destruction of Vulkan objects. Internal to the device.
const vk = @import("vulkan");
const device_module = @import("../device.zig");
const waitQueue = @import("frames.zig").waitQueue;

const Device = device_module.Device;
const Deletion = device_module.Deletion;
const frames_in_flight = device_module.frames_in_flight;

/// Names a Vulkan object for debuggers; no-op unless `debug_labels`.
pub fn setName(self: *Device, object_type: vk.ObjectType, handle: u64, label: [:0]const u8) void {
    if (!self.debug_labels) return;
    self.vkd.setDebugUtilsObjectNameEXT(&.{
        .object_type = object_type,
        .object_handle = handle,
        .p_object_name = label.ptr,
    }) catch {};
}

pub fn retire(self: *Device, object: Deletion) void {
    self.deletions.append(self.gpa, .{ .frame = self.frame_number, .object = object }) catch {
        waitQueue(self) catch {};
        destroyNow(self, object);
    };
}

/// Destroys retired objects no in-flight frame can reference.
pub fn collectGarbage(self: *Device, everything: bool) void {
    var write: usize = 0;
    for (self.deletions.items) |pending| {
        if (everything or (self.detached_outstanding == 0 and pending.frame + frames_in_flight <= self.frame_number)) {
            destroyNow(self, pending.object);
        } else {
            self.deletions.items[write] = pending;
            write += 1;
        }
    }
    self.deletions.items.len = write;
}

pub fn destroyNow(self: *Device, object: Deletion) void {
    switch (object) {
        .buffer => |buffer| {
            self.vkd.destroyBuffer(buffer.handle, null);
            self.allocator.free(buffer.allocation);
        },
        .image => |image| {
            self.vkd.destroyImage(image.handle, null);
            if (image.allocation) |allocation| self.allocator.free(allocation);
        },
        .view => |view| self.vkd.destroyImageView(view, null),
        .sampler => |sampler| self.vkd.destroySampler(sampler, null),
        .pipeline => |pipeline| self.vkd.destroyPipeline(pipeline, null),
        .acceleration => |acceleration| self.vkd.destroyAccelerationStructureKHR(acceleration, null),
        .texture_slot => |slot| self.texture_slots.release(slot),
        .storage_slot => |slot| self.storage_slots.release(slot),
        .sampler_slot => |slot| self.sampler_slots.release(slot),
    }
}
