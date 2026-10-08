const std = @import("std");
const vk = @import("vulkan");
const c = @import("volk");
const dispatch = @import("dispatch.zig");

var references: usize = 0;
var mutex: std.Io.Mutex = .init;

/// Loads the Vulkan library through volk on first use and counts a
/// reference; pair with `release`. Thread-safe. Fails with
/// `error.VulkanLoaderUnavailable`.
pub fn acquire(io: std.Io) !void {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    if (references == 0 and c.volkInitialize() != c.VK_SUCCESS)
        return error.VulkanLoaderUnavailable;
    references += 1;
}

/// Drops a reference; the last one unloads the library.
pub fn release(io: std.Io) void {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    std.debug.assert(references != 0);
    references -= 1;
    if (references == 0) c.volkFinalize();
}

fn getInstanceProcAddr(handle: vk.Instance, name: [*:0]const u8) callconv(.c) vk.PfnVoidFunction {
    return @ptrCast(c.vkGetInstanceProcAddr.?(
        @ptrFromInt(@intFromEnum(handle)),
        name,
    ));
}

/// Pre-instance entry points; needs a successful `acquire`. Entries the
/// library lacks are null.
pub fn base() dispatch.Base {
    return dispatch.Base.load(getInstanceProcAddr);
}

/// Instance-level entry points for `handle`. Also repoints volk's global
/// instance functions at `handle`.
pub fn instance(io: std.Io, handle: vk.Instance) dispatch.InstanceWrapper {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    c.volkLoadInstanceOnly(@ptrFromInt(@intFromEnum(handle)));
    var table: c.VolkInstanceTable = undefined;
    c.volkLoadInstanceTable(&table, @ptrFromInt(@intFromEnum(handle)));
    var result: dispatch.InstanceWrapper = undefined;
    inline for (@typeInfo(dispatch.InstanceDispatch).@"struct".fields) |field| {
        @field(result.dispatch, field.name) = if (@hasField(c.VolkInstanceTable, field.name))
            @ptrCast(@field(table, field.name))
        else
            @ptrCast(getInstanceProcAddr(handle, field.name));
    }
    return result;
}

/// Vulkan's `vkGetDeviceProcAddr`.
pub fn deviceProcAddr() *const anyopaque {
    return @ptrCast(c.vkGetDeviceProcAddr.?);
}

/// Device-level entry points for `handle`, loaded straight from the driver.
/// Unresolved entries are null.
pub fn device(io: std.Io, handle: vk.Device) dispatch.DeviceWrapper {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    var table: c.VolkDeviceTable = undefined;
    c.volkLoadDeviceTable(&table, @ptrFromInt(@intFromEnum(handle)));
    var result: dispatch.DeviceWrapper = undefined;
    inline for (@typeInfo(dispatch.DeviceDispatch).@"struct".fields) |field| {
        @field(result.dispatch, field.name) = if (@hasField(c.VolkDeviceTable, field.name))
            @ptrCast(@field(table, field.name))
        else if (@hasDecl(c, field.name))
            @ptrCast(@field(c, field.name))
        else
            null;
    }
    return result;
}
