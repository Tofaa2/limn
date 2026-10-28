//! The Vulkan entry points the RHI calls, as vulkan-zig lists them: every
//! command of the registry, null where the driver has none.
const vk = @import("vulkan");

pub const BaseDispatch = vk.BaseDispatch;
pub const InstanceDispatch = vk.InstanceDispatch;
pub const DeviceDispatch = vk.DeviceDispatch;

pub const Base = vk.BaseWrapper;
/// `Instance` points at one of these, so it must not move.
pub const InstanceWrapper = vk.InstanceWrapper;
pub const Instance = vk.InstanceProxy;
/// `Device` points at one of these, so it must not move.
pub const DeviceWrapper = vk.DeviceWrapper;
pub const Device = vk.DeviceProxy;
