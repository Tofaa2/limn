const std = @import("std");
const vk = @import("vulkan");
const c = @import("volk");
const dispatch = @import("dispatch.zig");

var references: usize = 0;
var mutex: std.Io.Mutex = .init;

/// Loads the system Vulkan library through volk on the first call and
/// counts a reference on every call. Pair each success with `release`.
/// Safe to call from any thread. Fails with
/// `error.VulkanLoaderUnavailable` when no Vulkan loader is installed.
pub fn acquire(io: std.Io) !void {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    if (references == 0 and c.volkInitialize() != c.VK_SUCCESS)
        return error.VulkanLoaderUnavailable;
    references += 1;
}

/// Drops a reference taken by `acquire` and unloads the library with the
/// last one. No Vulkan call may be made after that.
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

/// Entry points usable without an instance, for creating one. Needs a
/// successful `acquire`. Entries the library lacks are left null, as
/// `vkEnumerateInstanceVersion` is on a Vulkan 1.0 loader.
pub fn base() dispatch.Base {
    return dispatch.Base.load(getInstanceProcAddr);
}

/// Loads the instance-level entry points for `handle`. This also points
/// volk's global instance functions at `handle`, so with several
/// instances alive the globals belong to whichever was loaded last; the
/// returned table is unaffected.
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

/// Loads the device-level entry points for `handle` straight from the
/// driver, skipping the loader's dispatch. Debug-utils commands come from
/// the globals of the instance loaded last; entries that cannot be
/// resolved are null.
pub fn device(io: std.Io, handle: vk.Device) dispatch.DeviceWrapper {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    var table: c.VolkDeviceTable = undefined;
    c.volkLoadDeviceTable(&table, @ptrFromInt(@intFromEnum(handle)));
    var result: dispatch.DeviceWrapper = undefined;
    inline for (@typeInfo(dispatch.DeviceDispatch).@"struct".fields) |field| {
        // Debug-utils commands are instance-level in volk; fall back to the
        // instance-loaded global for anything missing from the device table.
        @field(result.dispatch, field.name) = if (@hasField(c.VolkDeviceTable, field.name))
            @ptrCast(@field(table, field.name))
        else if (@hasDecl(c, field.name))
            @ptrCast(@field(c, field.name))
        else
            null;
    }
    return result;
}
