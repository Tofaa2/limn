//! Textures and samplers, and their slots in the bindless table. Internal to the device.
const std = @import("std");
const vk = @import("vulkan");
const types = @import("../types.zig");
const memory = @import("../memory.zig");
const device_module = @import("../device.zig");

const Device = device_module.Device;
const TextureResource = device_module.TextureResource;
const cancelUploads = @import("buffers.zig").cancelUploads;
const createStaging = @import("frames.zig").createStaging;
const waitQueue = @import("frames.zig").waitQueue;
const max_mip_levels = device_module.max_mip_levels;
const retire = @import("objects.zig").retire;
const setName = @import("objects.zig").setName;
const vkFormat = device_module.vkFormat;

/// Starts in `undefined` with no contents. A `sampled` texture takes one
/// of 16384 bindless slots. Fails with `error.InvalidTextureDesc` or
/// `error.BindlessTableFull`; format support is not checked.
pub fn createTexture(self: *Device, desc: types.TextureDesc) !types.Texture {
    if (desc.width == 0 or desc.height == 0 or desc.mip_levels == 0 or desc.mip_levels > max_mip_levels)
        return error.InvalidTextureDesc;
    const layers: u32 = if (desc.kind == .cube) 6 else desc.layers;
    const format = vkFormat(desc.format);
    const image = try self.vkd.createImage(&.{
        .flags = .{ .cube_compatible_bit = desc.kind == .cube },
        .image_type = .@"2d",
        .format = format,
        .extent = .{ .width = desc.width, .height = desc.height, .depth = 1 },
        .mip_levels = desc.mip_levels,
        .array_layers = layers,
        .samples = .{ .@"1_bit" = true },
        .tiling = .optimal,
        .usage = .{
            .sampled_bit = desc.usage.sampled,
            .storage_bit = desc.usage.storage,
            .fragment_shading_rate_attachment_bit_khr = desc.usage.shading_rate,
            .color_attachment_bit = desc.usage.color_attachment,
            .depth_stencil_attachment_bit = desc.usage.depth_attachment,
            .transfer_src_bit = desc.usage.copy_src or desc.mip_levels > 1,
            .transfer_dst_bit = desc.usage.copy_dst or desc.mip_levels > 1,
        },
        .sharing_mode = .exclusive,
        .initial_layout = .undefined,
    }, null);
    setName(self, .image, @intFromEnum(image), desc.name);
    errdefer self.vkd.destroyImage(image, null);
    const allocation = try self.allocator.allocate(self.vkd.getImageMemoryRequirements(image), .gpu, .image);
    errdefer self.allocator.free(allocation);
    try self.vkd.bindImageMemory(image, allocation.memory, allocation.offset);
    return registerTexture(self, image, allocation, .{
        .width = desc.width,
        .height = desc.height,
        .format = desc.format,
        .mip_levels = desc.mip_levels,
        .layers = layers,
        .kind = desc.kind,
    }, desc.usage.sampled);
}

pub fn registerTexture(
    self: *Device,
    image: vk.Image,
    allocation: ?memory.Allocation,
    info: types.TextureInfo,
    sampled: bool,
) !types.Texture {
    const format = vkFormat(info.format);
    const aspect: vk.ImageAspectFlags = if (info.format.isDepth()) .{ .depth_bit = true } else .{ .color_bit = true };
    const view = try self.vkd.createImageView(&.{
        .image = image,
        .view_type = switch (info.kind) {
            .@"2d" => .@"2d",
            .@"2d_array" => .@"2d_array",
            .cube => .cube,
        },
        .format = format,
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
        .subresource_range = .{
            .aspect_mask = aspect,
            .base_mip_level = 0,
            .level_count = info.mip_levels,
            .base_array_layer = 0,
            .layer_count = info.layers,
        },
    }, null);
    errdefer self.vkd.destroyImageView(view, null);
    var bindless_index: ?u32 = null;
    errdefer if (bindless_index) |slot| self.texture_slots.release(slot);
    if (sampled) {
        const slot = try self.texture_slots.allocate();
        bindless_index = slot;
        const image_info = vk.DescriptorImageInfo{
            .sampler = .null_handle,
            .image_view = view,
            .image_layout = .read_only_optimal,
        };
        self.vkd.updateDescriptorSets(&.{.{
            .dst_set = self.descriptor_set,
            .dst_binding = 0,
            .dst_array_element = slot,
            .descriptor_count = 1,
            .descriptor_type = .sampled_image,
            .p_image_info = @ptrCast(&image_info),
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        }}, &.{});
    }
    return self.textures.insert(.{
        .image = image,
        .allocation = allocation,
        .view = view,
        .info = info,
        .vk_format = format,
        .aspect = aspect,
        .bindless_index = bindless_index,
    });
}

/// Deferred like `destroyBuffer`, including the bindless slot. Backbuffers
/// must not be destroyed.
pub fn destroyTexture(self: *Device, texture: types.Texture) void {
    if (self.uploads.items.len != 0) cancelUploads(self, null, texture);
    var resource = self.textures.remove(texture) orelse return;
    for (resource.sub_views.items) |sub| retire(self, .{ .view = sub.view });
    resource.sub_views.deinit(self.gpa);
    for (resource.storage_slots.items) |storage| retire(self, .{ .storage_slot = storage.slot });
    resource.storage_slots.deinit(self.gpa);
    retire(self, .{ .view = resource.view });
    if (resource.bindless_index) |slot| retire(self, .{ .texture_slot = slot });
    if (resource.allocation != null) retire(self, .{ .image = .{ .handle = resource.image, .allocation = resource.allocation } });
}

/// Panics on a stale handle. The pointer is valid until a texture is
/// created or destroyed, including a swapchain rebuild.
pub fn textureResource(self: *Device, texture: types.Texture) *TextureResource {
    return self.textures.get(texture) orelse @panic("stale or invalid texture handle");
}

/// False for a stale or invalid handle.
pub fn textureExists(self: *Device, texture: types.Texture) bool {
    return self.textures.get(texture) != null;
}

/// Panics on a stale handle.
pub fn textureInfo(self: *Device, texture: types.Texture) types.TextureInfo {
    return self.textureResource(texture).info;
}

/// Index in the global `textures[]` shader array. Panics unless the
/// texture is `.sampled`.
pub fn textureIndex(self: *Device, texture: types.Texture) u32 {
    return self.textureResource(texture).bindless_index orelse @panic("texture was not created with .sampled usage");
}

/// Index of one mip in the storage image table (`STORAGE` in common.glsl).
/// Needs `TextureUsage.storage`; the mip must be in `TextureState.storage`
/// while the shader runs.
pub fn storageIndex(self: *Device, texture: types.Texture, mip: u32) !u32 {
    const resource = self.textureResource(texture);
    for (resource.storage_slots.items) |storage| if (storage.mip == mip) return storage.slot;
    const view = try self.subView(texture, mip, 0);
    const slot = try self.storage_slots.allocate();
    errdefer self.storage_slots.release(slot);
    try resource.storage_slots.append(self.gpa, .{ .mip = mip, .slot = slot });
    const image_info = vk.DescriptorImageInfo{ .sampler = .null_handle, .image_view = view, .image_layout = .general };
    self.vkd.updateDescriptorSets(&.{.{
        .dst_set = self.descriptor_set,
        .dst_binding = 2,
        .dst_array_element = slot,
        .descriptor_count = 1,
        .descriptor_type = .storage_image,
        .p_image_info = @ptrCast(&image_info),
        .p_buffer_info = undefined,
        .p_texel_buffer_view = undefined,
    }}, &.{});
    return slot;
}

/// View of a single mip/layer, used as a render attachment.
pub fn subView(self: *Device, texture: types.Texture, mip: u32, layer: u32) !vk.ImageView {
    const resource = self.textureResource(texture);
    if (resource.info.mip_levels == 1 and resource.info.layers == 1) return resource.view;
    for (resource.sub_views.items) |sub| if (sub.mip == mip and sub.layer == layer) return sub.view;
    const view = try self.vkd.createImageView(&.{
        .image = resource.image,
        .view_type = .@"2d",
        .format = resource.vk_format,
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
        .subresource_range = .{
            .aspect_mask = resource.aspect,
            .base_mip_level = mip,
            .level_count = 1,
            .base_array_layer = layer,
            .layer_count = 1,
        },
    }, null);
    errdefer self.vkd.destroyImageView(view, null);
    try resource.sub_views.append(self.gpa, .{ .mip = mip, .layer = layer, .view = view });
    return view;
}

/// Stages tightly packed pixel data for one mip of one layer.
pub fn uploadTexture(self: *Device, texture: types.Texture, mip: u32, layer: u32, data: []const u8) !void {
    const info = self.textureInfo(texture);
    const width = @max(info.width >> @intCast(mip), 1);
    const height = @max(info.height >> @intCast(mip), 1);
    if (data.len != info.format.dataSize(width, height)) return error.InvalidTextureData;
    const staging = try createStaging(self, data);
    errdefer self.destroyBuffer(staging);
    try self.uploads.append(self.gpa, .{ .texture = .{
        .staging = staging,
        .destination = texture,
        .mip = mip,
        .layer = layer,
    } });
    self.pending_upload_bytes += data.len;
}

/// Stages consecutive mips of one layer, from `first_mip`, packed back to
/// back in `data`.
pub fn uploadTextureLevels(self: *Device, texture: types.Texture, first_mip: u32, layer: u32, data: []const u8) !void {
    const info = self.textureInfo(texture);
    var total: usize = 0;
    var count: u32 = 0;
    while (total < data.len and first_mip + count < info.mip_levels) : (count += 1) {
        const mip = first_mip + count;
        total += @intCast(info.format.dataSize(@max(info.width >> @intCast(mip), 1), @max(info.height >> @intCast(mip), 1)));
    }
    if (total != data.len or count == 0) return error.InvalidTextureData;
    const staging = try createStaging(self, data);
    errdefer self.destroyBuffer(staging);
    try self.uploads.ensureUnusedCapacity(self.gpa, count);
    var offset: u64 = 0;
    for (0..count) |index| {
        const mip = first_mip + @as(u32, @intCast(index));
        self.uploads.appendAssumeCapacity(.{ .texture = .{
            .staging = staging,
            .destination = texture,
            .mip = mip,
            .layer = layer,
            .offset = offset,
            .last = index + 1 == count,
        } });
        offset += info.format.dataSize(@max(info.width >> @intCast(mip), 1), @max(info.height >> @intCast(mip), 1));
    }
    self.pending_upload_bytes += data.len;
}

/// Queues a blit chain filling every mip above 0, after earlier uploads.
pub fn generateMips(self: *Device, texture: types.Texture) !void {
    try self.uploads.append(self.gpa, .{ .mips = texture });
}

/// Reads back mip 0 / layer 0. Blocks until the GPU is idle; not for use
/// during a frame.
pub fn readTexture(self: *Device, gpa: std.mem.Allocator, texture: types.Texture) ![]u8 {
    std.debug.assert(!self.in_frame);
    const info = self.textureInfo(texture);
    const size = @as(u64, info.width) * info.height * info.format.bytesPerPixel();
    const staging = try self.createBuffer(.{ .name = "readback", .size = size, .usage = .{}, .memory = .gpu_to_cpu });
    defer self.destroyBuffer(staging);
    try waitQueue(self);
    var encoder = try self.beginImmediate();
    const previous = self.textureResource(texture).states[0];
    encoder.transition(texture, .copy_src);
    self.vkd.cmdCopyImageToBuffer(encoder.command, self.textureResource(texture).image, .transfer_src_optimal, self.bufferResource(staging).handle, &.{.{
        .buffer_offset = 0,
        .buffer_row_length = 0,
        .buffer_image_height = 0,
        .image_subresource = .{ .aspect_mask = self.textureResource(texture).aspect, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 },
        .image_offset = .{ .x = 0, .y = 0, .z = 0 },
        .image_extent = .{ .width = info.width, .height = info.height, .depth = 1 },
    }});
    if (previous != .undefined) encoder.transition(texture, previous);
    try self.endImmediate();
    return gpa.dupe(u8, self.mapped(staging)[0..@intCast(size)]);
}

/// Takes one of 256 bindless slots; `error.BindlessTableFull` beyond that.
pub fn createSampler(self: *Device, desc: types.SamplerDesc) !types.Sampler {
    const anisotropy = std.math.clamp(desc.max_anisotropy, 1, self.properties.limits.max_sampler_anisotropy);
    const handle = try self.vkd.createSampler(&.{
        .mag_filter = vkFilter(desc.mag_filter),
        .min_filter = vkFilter(desc.min_filter),
        .mipmap_mode = if (desc.mip_filter == .linear) .linear else .nearest,
        .address_mode_u = vkAddressMode(desc.address_u),
        .address_mode_v = vkAddressMode(desc.address_v),
        .address_mode_w = vkAddressMode(desc.address_w),
        .mip_lod_bias = 0,
        .anisotropy_enable = if (anisotropy > 1) .true else .false,
        .max_anisotropy = anisotropy,
        .compare_enable = if (desc.compare != null) .true else .false,
        .compare_op = vkCompareOp(desc.compare orelse .always),
        .min_lod = 0,
        .max_lod = desc.max_lod,
        .border_color = .float_opaque_white,
        .unnormalized_coordinates = .false,
    }, null);
    errdefer self.vkd.destroySampler(handle, null);
    const slot = try self.sampler_slots.allocate();
    errdefer self.sampler_slots.release(slot);
    const image_info = vk.DescriptorImageInfo{ .sampler = handle, .image_view = .null_handle, .image_layout = .undefined };
    self.vkd.updateDescriptorSets(&.{.{
        .dst_set = self.descriptor_set,
        .dst_binding = 1,
        .dst_array_element = slot,
        .descriptor_count = 1,
        .descriptor_type = .sampler,
        .p_image_info = @ptrCast(&image_info),
        .p_buffer_info = undefined,
        .p_texel_buffer_view = undefined,
    }}, &.{});
    return try self.samplers.insert(.{ .handle = handle, .bindless_index = slot });
}

/// Deferred like `destroyBuffer`.
pub fn destroySampler(self: *Device, sampler: types.Sampler) void {
    const resource = self.samplers.remove(sampler) orelse return;
    retire(self, .{ .sampler = resource.handle });
    retire(self, .{ .sampler_slot = resource.bindless_index });
}

/// Index in the global `samplers[]` shader array. Panics on a stale
/// handle.
pub fn samplerIndex(self: *Device, sampler: types.Sampler) u32 {
    return (self.samplers.get(sampler) orelse @panic("stale or invalid sampler handle")).bindless_index;
}

fn vkFilter(filter: types.Filter) vk.Filter {
    return if (filter == .linear) .linear else .nearest;
}

fn vkAddressMode(mode: types.AddressMode) vk.SamplerAddressMode {
    return switch (mode) {
        .repeat => .repeat,
        .mirrored_repeat => .mirrored_repeat,
        .clamp_to_edge => .clamp_to_edge,
        .clamp_to_border => .clamp_to_border,
    };
}

pub fn vkCompareOp(op: types.CompareOp) vk.CompareOp {
    return switch (op) {
        .never => .never,
        .less => .less,
        .equal => .equal,
        .less_or_equal => .less_or_equal,
        .greater => .greater,
        .not_equal => .not_equal,
        .greater_or_equal => .greater_or_equal,
        .always => .always,
    };
}
