//! Command recording for one frame.
//!
//! The encoder tracks texture state per mip so callers only say what they are
//! about to do with a texture; layout transitions and their stage/access masks
//! are derived. `beginRendering` transitions its attachments itself.
const std = @import("std");
const vk = @import("vulkan");
const types = @import("types.zig");
const device_module = @import("device.zig");
const Device = device_module.Device;

const all_shader_stages = vk.ShaderStageFlags{ .vertex_bit = true, .fragment_bit = true, .compute_bit = true };

/// Records commands into one command buffer: the frame's (`Frame.cmd`) or
/// a one-off from `Device.beginImmediate`. Recording only queues work; the
/// GPU runs it after `Device.submitFrame` / `endImmediate`. A resource may
/// be destroyed once the commands that use it are recorded; deferred
/// destruction keeps it alive until the GPU is done. Not thread-safe:
/// record from the thread that owns the frame.
pub const CommandEncoder = struct {
    /// The device that created the encoder.
    device: *Device,
    /// Command buffer being recorded, for Vulkan calls the encoder lacks.
    command: vk.CommandBuffer,
    /// Null for immediate (blocking) command buffers, which carry no timings.
    frame: ?*device_module.FrameData,
    /// Timing slot of each open `beginScope`, innermost last.
    scope_stack: [8]u32 = undefined,
    /// Number of scopes currently open; at most 8.
    scope_depth: u8 = 0,
    /// True between `beginRendering` and `endRendering`.
    rendering: bool = false,

    /// Binds the global descriptor table for both bind points.
    pub fn bindGlobals(self: *CommandEncoder) void {
        const vkd = self.device.vkd;
        vkd.cmdBindDescriptorSets(self.command, .graphics, self.device.pipeline_layout, 0, &.{self.device.descriptor_set}, &.{});
        vkd.cmdBindDescriptorSets(self.command, .compute, self.device.pipeline_layout, 0, &.{self.device.descriptor_set}, &.{});
    }

    // ------------------------------------------------------------ transitions

    /// Moves every mip of `texture` into `state`.
    pub fn transition(self: *CommandEncoder, texture: types.Texture, state: types.TextureState) void {
        const resource = self.device.textureResource(texture);
        var barriers: [device_module.max_mip_levels]vk.ImageMemoryBarrier2 = undefined;
        var count: u32 = 0;
        // Coalesce runs of mips that share a source state into one barrier.
        var mip: u32 = 0;
        while (mip < resource.info.mip_levels) {
            const from = resource.states[mip];
            var end = mip + 1;
            while (end < resource.info.mip_levels and resource.states[end] == from) end += 1;
            if (from != state) {
                barriers[count] = imageBarrier(resource, mip, end - mip, from, state);
                count += 1;
            }
            mip = end;
        }
        if (count == 0) return;
        for (resource.states[0..resource.info.mip_levels]) |*value| value.* = state;
        self.device.vkd.cmdPipelineBarrier2(self.command, &.{
            .image_memory_barrier_count = count,
            .p_image_memory_barriers = &barriers,
        });
    }

    /// Moves a single mip (all layers) into `state`.
    pub fn transitionMip(self: *CommandEncoder, texture: types.Texture, mip: u32, state: types.TextureState) void {
        const resource = self.device.textureResource(texture);
        const from = resource.states[mip];
        if (from == state) return;
        const barrier = imageBarrier(resource, mip, 1, from, state);
        resource.states[mip] = state;
        self.device.vkd.cmdPipelineBarrier2(self.command, &.{
            .image_memory_barrier_count = 1,
            .p_image_memory_barriers = @ptrCast(&barrier),
        });
    }

    /// Declares a buffer hand-off between pipeline stages.
    pub fn sync(self: *CommandEncoder, kind: types.BufferSync) void {
        const shader_stages = vk.PipelineStageFlags2{
            .vertex_shader_bit = true,
            .fragment_shader_bit = true,
            .compute_shader_bit = true,
            .draw_indirect_bit = true,
            .vertex_input_bit = true,
            // Acceleration-structure builds read vertex, index and instance
            // buffers as shader reads at their own stage.
            .acceleration_structure_build_bit_khr = self.device.ray_tracing,
        };
        const shader_access = vk.AccessFlags2{
            .shader_read_bit = true,
            .shader_write_bit = true,
            .indirect_command_read_bit = true,
            .index_read_bit = true,
            .vertex_attribute_read_bit = true,
        };
        const barrier: vk.MemoryBarrier2 = switch (kind) {
            .compute_to_all => .{
                .src_stage_mask = .{ .compute_shader_bit = true },
                .src_access_mask = .{ .shader_write_bit = true },
                .dst_stage_mask = shader_stages.merge(.{ .all_transfer_bit = true }),
                .dst_access_mask = shader_access.merge(.{ .transfer_read_bit = true }),
            },
            .transfer_to_all => .{
                .src_stage_mask = .{ .all_transfer_bit = true },
                .src_access_mask = .{ .transfer_write_bit = true },
                .dst_stage_mask = shader_stages.merge(.{ .all_transfer_bit = true }),
                .dst_access_mask = shader_access.merge(.{ .transfer_read_bit = true, .transfer_write_bit = true }),
            },
            .all_to_transfer => .{
                .src_stage_mask = shader_stages.merge(.{ .all_transfer_bit = true }),
                .src_access_mask = shader_access.merge(.{ .transfer_read_bit = true, .transfer_write_bit = true }),
                .dst_stage_mask = .{ .all_transfer_bit = true },
                .dst_access_mask = .{ .transfer_read_bit = true, .transfer_write_bit = true },
            },
        };
        self.device.vkd.cmdPipelineBarrier2(self.command, &.{
            .memory_barrier_count = 1,
            .p_memory_barriers = @ptrCast(&barrier),
        });
    }

    // -------------------------------------------------------------- rendering

    /// Begins a render pass over the given attachments, transitioning them
    /// and setting a full-size viewport and scissor.
    pub fn beginRendering(self: *CommandEncoder, desc: types.RenderingDesc) !void {
        std.debug.assert(!self.rendering);
        var colors: [8]vk.RenderingAttachmentInfo = undefined;
        var extent: vk.Extent2D = .{ .width = 0, .height = 0 };
        for (desc.color, 0..) |attachment, index| {
            const resource = self.device.textureResource(attachment.texture);
            self.transitionMip(attachment.texture, attachment.mip, .color_attachment);
            extent = mipExtent(resource.info, attachment.mip);
            colors[index] = .{
                .image_view = try self.device.subView(attachment.texture, attachment.mip, attachment.layer),
                .image_layout = .attachment_optimal,
                .resolve_mode = .{},
                .resolve_image_layout = .undefined,
                .load_op = loadOp(attachment.load),
                .store_op = .store,
                .clear_value = if (resource.info.format == .r32_uint)
                    .{ .color = .{ .uint_32 = attachment.clear_uint } }
                else
                    .{ .color = .{ .float_32 = attachment.clear } },
            };
        }
        var depth: vk.RenderingAttachmentInfo = undefined;
        if (desc.depth) |attachment| {
            const resource = self.device.textureResource(attachment.texture);
            self.transitionMip(attachment.texture, attachment.mip, .depth_attachment);
            extent = mipExtent(resource.info, attachment.mip);
            depth = .{
                .image_view = try self.device.subView(attachment.texture, attachment.mip, attachment.layer),
                .image_layout = .attachment_optimal,
                .resolve_mode = .{},
                .resolve_image_layout = .undefined,
                .load_op = loadOp(attachment.load),
                .store_op = if (attachment.store) .store else .dont_care,
                .clear_value = .{ .depth_stencil = .{ .depth = attachment.clear, .stencil = 0 } },
            };
        }
        self.device.vkd.cmdBeginRendering(self.command, &.{
            .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = extent },
            .layer_count = 1,
            .view_mask = 0,
            .color_attachment_count = @intCast(desc.color.len),
            .p_color_attachments = &colors,
            .p_depth_attachment = if (desc.depth != null) &depth else null,
        });
        self.rendering = true;
        self.setViewport(0, 0, extent.width, extent.height);
    }

    /// Ends the pass started by `beginRendering`. The attachments stay in
    /// their attachment state; `transition` them before sampling or copying.
    pub fn endRendering(self: *CommandEncoder) void {
        std.debug.assert(self.rendering);
        self.device.vkd.cmdEndRendering(self.command);
        self.rendering = false;
    }

    /// Sets the viewport and the scissor to the same rectangle, in pixels
    /// from the top-left corner, with depth range 0..1. `beginRendering`
    /// already selects the whole attachment.
    pub fn setViewport(self: *CommandEncoder, x: u32, y: u32, width: u32, height: u32) void {
        self.device.vkd.cmdSetViewport(self.command, 0, &.{.{
            .x = @floatFromInt(x),
            .y = @floatFromInt(y),
            .width = @floatFromInt(width),
            .height = @floatFromInt(height),
            .min_depth = 0,
            .max_depth = 1,
        }});
        self.device.vkd.cmdSetScissor(self.command, 0, &.{.{
            .offset = .{ .x = @intCast(x), .y = @intCast(y) },
            .extent = .{ .width = width, .height = height },
        }});
    }

    /// Limits drawing to a rectangle without changing the viewport.
    pub fn setScissor(self: *CommandEncoder, x: u32, y: u32, width: u32, height: u32) void {
        self.device.vkd.cmdSetScissor(self.command, 0, &.{.{
            .offset = .{ .x = @intCast(x), .y = @intCast(y) },
            .extent = .{ .width = width, .height = height },
        }});
    }

    /// Binds a graphics or compute pipeline, to the bind point it was created
    /// for. All pipelines share one layout, so the global descriptor table
    /// and push constants stay valid across binds.
    pub fn bindPipeline(self: *CommandEncoder, pipeline: types.Pipeline) void {
        const resource = self.device.pipelineResource(pipeline);
        self.device.vkd.cmdBindPipeline(self.command, resource.bind_point, resource.handle);
    }

    /// Pushes `value` (any extern struct up to 256 bytes) at offset 0.
    pub fn pushConstants(self: *CommandEncoder, value: anytype) void {
        const T = @TypeOf(value);
        comptime std.debug.assert(@sizeOf(T) <= device_module.push_constant_size);
        comptime std.debug.assert(@sizeOf(T) % 4 == 0);
        self.device.vkd.cmdPushConstants(self.command, self.device.pipeline_layout, all_shader_stages, 0, @sizeOf(T), @ptrCast(&value));
    }

    /// Binds `buffer`, from byte `offset`, as the vertex buffer of pipelines
    /// that have a `VertexLayout`.
    pub fn bindVertexBuffer(self: *CommandEncoder, buffer: types.Buffer, offset: u64) void {
        self.device.vkd.cmdBindVertexBuffers(self.command, 0, &.{self.device.bufferResource(buffer).handle}, &.{offset});
    }

    /// Clears a rectangle of the depth attachment of the pass being drawn.
    pub fn clearDepthRect(self: *CommandEncoder, x: u32, y: u32, width: u32, height: u32, value: f32) void {
        self.device.vkd.cmdClearAttachments(self.command, &.{.{
            .aspect_mask = .{ .depth_bit = true },
            .color_attachment = 0,
            .clear_value = .{ .depth_stencil = .{ .depth = value, .stencil = 0 } },
        }}, &.{.{
            .rect = .{ .offset = .{ .x = @intCast(x), .y = @intCast(y) }, .extent = .{ .width = width, .height = height } },
            .base_array_layer = 0,
            .layer_count = 1,
        }});
    }

    /// Binds `buffer`, from byte `offset`, as the index buffer for
    /// `drawIndexed` and indexed indirect draws.
    pub fn bindIndexBuffer(self: *CommandEncoder, buffer: types.Buffer, offset: u64, index_type: types.IndexType) void {
        self.device.vkd.cmdBindIndexBuffer(self.command, self.device.bufferResource(buffer).handle, offset, switch (index_type) {
            .uint16 => .uint16,
            .uint32 => .uint32,
        });
    }

    /// Draws `vertex_count` vertices, without an index buffer, with the bound
    /// graphics pipeline. Must be inside a render pass. `first_instance` is
    /// the base of `gl_InstanceIndex`.
    pub fn draw(self: *CommandEncoder, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) void {
        self.device.vkd.cmdDraw(self.command, vertex_count, instance_count, first_vertex, first_instance);
    }

    /// Draws one triangle covering the viewport; pair with a vertex shader
    /// that derives positions from `gl_VertexIndex`.
    pub fn drawFullscreen(self: *CommandEncoder) void {
        self.device.vkd.cmdDraw(self.command, 3, 1, 0, 0);
    }

    /// Draws `index_count` indices from the bound index buffer, starting at
    /// `first_index`. `vertex_offset` is added to every index. Must be
    /// inside a render pass.
    pub fn drawIndexed(
        self: *CommandEncoder,
        index_count: u32,
        instance_count: u32,
        first_index: u32,
        vertex_offset: i32,
        first_instance: u32,
    ) void {
        self.device.vkd.cmdDrawIndexed(self.command, index_count, instance_count, first_index, vertex_offset, first_instance);
    }

    /// Multi-draw of `VkDrawIndexedIndirectCommand`s with a GPU-written count.
    pub fn drawIndexedIndirectCount(
        self: *CommandEncoder,
        commands: types.Buffer,
        commands_offset: u64,
        count: types.Buffer,
        count_offset: u64,
        max_draws: u32,
    ) void {
        self.device.vkd.cmdDrawIndexedIndirectCount(
            self.command,
            self.device.bufferResource(commands).handle,
            commands_offset,
            self.device.bufferResource(count).handle,
            count_offset,
            max_draws,
            @sizeOf(vk.DrawIndexedIndirectCommand),
        );
    }

    /// Runs the bound compute pipeline over `x` * `y` * `z` workgroups. Must
    /// be outside a render pass. Buffer writes are not visible to later
    /// passes until `sync(.compute_to_all)`.
    pub fn dispatch(self: *CommandEncoder, x: u32, y: u32, z: u32) void {
        self.device.vkd.cmdDispatch(self.command, x, y, z);
    }

    // ---------------------------------------------------------------- copies

    /// Fills `size` bytes from `offset` with the repeated 32-bit `value`.
    /// Both must be multiples of 4. Must be outside a render pass; follow
    /// with `sync(.transfer_to_all)` before the buffer is read.
    pub fn fillBuffer(self: *CommandEncoder, buffer: types.Buffer, offset: u64, size: u64, value: u32) void {
        self.device.vkd.cmdFillBuffer(self.command, self.device.bufferResource(buffer).handle, offset, size, value);
    }

    /// Copies `size` bytes between two buffers. `source` needs `copy_src`
    /// usage and the ranges must not overlap. Must be outside a render pass;
    /// follow with `sync(.transfer_to_all)` before the destination is read.
    pub fn copyBuffer(self: *CommandEncoder, source: types.Buffer, destination: types.Buffer, source_offset: u64, destination_offset: u64, size: u64) void {
        self.device.vkd.cmdCopyBuffer(
            self.command,
            self.device.bufferResource(source).handle,
            self.device.bufferResource(destination).handle,
            &.{.{ .src_offset = source_offset, .dst_offset = destination_offset, .size = size }},
        );
    }

    /// Records every staged upload and mip-generation request. Must be called
    /// outside a render pass. Uploaded textures end in `shader_read`.
    pub fn flushUploads(self: *CommandEncoder) !void {
        std.debug.assert(!self.rendering);
        const device = self.device;
        if (device.uploads.items.len == 0) return;
        var uploads = device.takeUploads();
        defer uploads.deinit(device.gpa);
        var copied_buffers = false;
        for (uploads.items) |upload| switch (upload) {
            .buffer => |copy| {
                self.copyBuffer(copy.staging, copy.destination, 0, copy.offset, copy.size);
                device.destroyBuffer(copy.staging);
                copied_buffers = true;
            },
            .texture => |copy| {
                const resource = device.textureResource(copy.destination);
                self.transitionMip(copy.destination, copy.mip, .copy_dst);
                const extent = mipExtent(resource.info, copy.mip);
                device.vkd.cmdCopyBufferToImage(self.command, device.bufferResource(copy.staging).handle, resource.image, .transfer_dst_optimal, &.{.{
                    .buffer_offset = copy.offset,
                    .buffer_row_length = 0,
                    .buffer_image_height = 0,
                    .image_subresource = .{ .aspect_mask = resource.aspect, .mip_level = copy.mip, .base_array_layer = copy.layer, .layer_count = 1 },
                    .image_offset = .{ .x = 0, .y = 0, .z = 0 },
                    .image_extent = .{ .width = extent.width, .height = extent.height, .depth = 1 },
                }});
                if (copy.last) device.destroyBuffer(copy.staging);
            },
            .mips => |texture| self.generateMips(texture),
            .copy => |copy| {
                // Earlier uploads into the source must land before it is read.
                self.sync(.transfer_to_all);
                self.copyBuffer(copy.source, copy.destination, 0, 0, copy.size);
                device.destroyBuffer(copy.source);
                copied_buffers = true;
            },
        };
        if (copied_buffers) self.sync(.transfer_to_all);
        for (uploads.items) |upload| switch (upload) {
            .texture => |copy| self.transition(copy.destination, .shader_read),
            else => {},
        };
    }

    /// Fills mips 1..n from mip 0 with linear blits and leaves the whole
    /// texture in `shader_read`.
    pub fn generateMips(self: *CommandEncoder, texture: types.Texture) void {
        const resource = self.device.textureResource(texture);
        const info = resource.info;
        var mip: u32 = 1;
        while (mip < info.mip_levels) : (mip += 1) {
            self.transitionMip(texture, mip - 1, .copy_src);
            self.transitionMip(texture, mip, .copy_dst);
            const source = mipExtent(info, mip - 1);
            const destination = mipExtent(info, mip);
            self.device.vkd.cmdBlitImage(self.command, resource.image, .transfer_src_optimal, resource.image, .transfer_dst_optimal, &.{.{
                .src_subresource = .{ .aspect_mask = resource.aspect, .mip_level = mip - 1, .base_array_layer = 0, .layer_count = info.layers },
                .src_offsets = .{ .{ .x = 0, .y = 0, .z = 0 }, .{ .x = @intCast(source.width), .y = @intCast(source.height), .z = 1 } },
                .dst_subresource = .{ .aspect_mask = resource.aspect, .mip_level = mip, .base_array_layer = 0, .layer_count = info.layers },
                .dst_offsets = .{ .{ .x = 0, .y = 0, .z = 0 }, .{ .x = @intCast(destination.width), .y = @intCast(destination.height), .z = 1 } },
            }}, .linear);
        }
        self.transition(texture, .shader_read);
    }

    // ------------------------------------------------ acceleration structures

    /// Builds a bottom-level structure from geometry already on the GPU.
    pub fn buildBlas(self: *CommandEncoder, blas: types.AccelerationStructure, desc: types.BlasDesc) !void {
        std.debug.assert(!self.rendering);
        try self.device.buildBlasCommand(self.command, blas, desc);
    }

    /// Rebuilds a top-level structure from `instance_count`
    /// `AccelerationInstance` records at `instances_address`. Bottom-level
    /// builds recorded earlier in this command buffer are synchronized.
    pub fn buildTlas(self: *CommandEncoder, tlas: types.AccelerationStructure, instances_address: u64, instance_count: u32) void {
        std.debug.assert(!self.rendering);
        self.accelerationBarrier();
        self.device.buildTlasCommand(self.command, tlas, instances_address, instance_count);
        self.accelerationBarrier();
    }

    /// Makes acceleration-structure builds visible to later builds and to
    /// ray queries in any shader stage.
    fn accelerationBarrier(self: *CommandEncoder) void {
        const barrier = vk.MemoryBarrier2{
            .src_stage_mask = .{ .acceleration_structure_build_bit_khr = true },
            .src_access_mask = .{ .acceleration_structure_write_bit_khr = true },
            .dst_stage_mask = .{ .acceleration_structure_build_bit_khr = true, .compute_shader_bit = true, .fragment_shader_bit = true },
            .dst_access_mask = .{ .acceleration_structure_read_bit_khr = true, .acceleration_structure_write_bit_khr = true },
        };
        self.device.vkd.cmdPipelineBarrier2(self.command, &.{
            .memory_barrier_count = 1,
            .p_memory_barriers = @ptrCast(&barrier),
        });
    }

    // ------------------------------------------------------------ diagnostics

    /// Opens a named GPU timing region (also a debug label under validation).
    /// `name` must outlive the frame; pass string literals.
    pub fn beginScope(self: *CommandEncoder, name: [:0]const u8) void {
        if (self.device.debug_labels) self.device.vkd.cmdBeginDebugUtilsLabelEXT(self.command, &.{
            .p_label_name = name.ptr,
            .color = .{ 0.4, 0.6, 1, 1 },
        });
        const frame = self.frameData() orelse return;
        if (self.scope_depth == self.scope_stack.len) @panic("timing scopes nested too deeply");
        var index: u32 = std.math.maxInt(u32);
        if (frame.scope_count < device_module.max_timing_scopes) {
            index = frame.scope_count;
            frame.scopes[index] = .{ .name = name, .depth = self.scope_depth };
            frame.scope_count += 1;
            self.device.vkd.cmdWriteTimestamp2(self.command, .{ .all_commands_bit = true }, frame.query_pool, index * 2);
        }
        self.scope_stack[self.scope_depth] = index;
        self.scope_depth += 1;
    }

    /// Closes the innermost `beginScope`. Every scope must be closed before
    /// the frame is submitted.
    pub fn endScope(self: *CommandEncoder) void {
        if (self.device.debug_labels) self.device.vkd.cmdEndDebugUtilsLabelEXT(self.command);
        const frame = self.frameData() orelse return;
        self.scope_depth -= 1;
        const index = self.scope_stack[self.scope_depth];
        if (index != std.math.maxInt(u32))
            self.device.vkd.cmdWriteTimestamp2(self.command, .{ .all_commands_bit = true }, frame.query_pool, index * 2 + 1);
    }

    fn frameData(self: *CommandEncoder) ?*FrameData {
        return self.frame;
    }
};

const FrameData = device_module.FrameData;

fn mipExtent(info: types.TextureInfo, mip: u32) vk.Extent2D {
    return .{
        .width = @max(info.width >> @intCast(mip), 1),
        .height = @max(info.height >> @intCast(mip), 1),
    };
}

fn loadOp(op: types.LoadOp) vk.AttachmentLoadOp {
    return switch (op) {
        .load => .load,
        .clear => .clear,
        .discard => .dont_care,
    };
}

const StateInfo = struct {
    layout: vk.ImageLayout,
    stage: vk.PipelineStageFlags2,
    access: vk.AccessFlags2,
};

fn stateInfo(state: types.TextureState) StateInfo {
    return switch (state) {
        .undefined => .{ .layout = .undefined, .stage = .{}, .access = .{} },
        .shader_read => .{
            .layout = .read_only_optimal,
            .stage = .{ .vertex_shader_bit = true, .fragment_shader_bit = true, .compute_shader_bit = true },
            .access = .{ .shader_read_bit = true },
        },
        .color_attachment => .{
            .layout = .attachment_optimal,
            .stage = .{ .color_attachment_output_bit = true },
            .access = .{ .color_attachment_read_bit = true, .color_attachment_write_bit = true },
        },
        .depth_attachment => .{
            .layout = .attachment_optimal,
            .stage = .{ .early_fragment_tests_bit = true, .late_fragment_tests_bit = true },
            .access = .{ .depth_stencil_attachment_read_bit = true, .depth_stencil_attachment_write_bit = true },
        },
        .copy_src => .{
            .layout = .transfer_src_optimal,
            .stage = .{ .all_transfer_bit = true },
            .access = .{ .transfer_read_bit = true },
        },
        .copy_dst => .{
            .layout = .transfer_dst_optimal,
            .stage = .{ .all_transfer_bit = true },
            .access = .{ .transfer_write_bit = true },
        },
        .present => .{ .layout = .present_src_khr, .stage = .{}, .access = .{} },
    };
}

fn imageBarrier(
    resource: *const device_module.TextureResource,
    base_mip: u32,
    mip_count: u32,
    from: types.TextureState,
    to: types.TextureState,
) vk.ImageMemoryBarrier2 {
    const source = stateInfo(from);
    const destination = stateInfo(to);
    return .{
        .src_stage_mask = source.stage,
        .src_access_mask = source.access,
        .dst_stage_mask = destination.stage,
        .dst_access_mask = destination.access,
        .old_layout = source.layout,
        .new_layout = destination.layout,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = resource.image,
        .subresource_range = .{
            .aspect_mask = resource.aspect,
            .base_mip_level = base_mip,
            .level_count = mip_count,
            .base_array_layer = 0,
            .layer_count = resource.info.layers,
        },
    };
}
