//! Command recording for one frame. The encoder tracks texture state per
//! mip and derives layout transitions. Sampled textures rest in
//! `shader_read`: `beginRendering` and the copies move theirs out, and
//! they return before the next work that could sample them.
const std = @import("std");
const vk = @import("vulkan");
const types = @import("../types.zig");
const device_module = @import("device.zig");
const acceleration = @import("device/acceleration.zig");
const pipelines = @import("device/pipelines.zig");
const textures = @import("device/textures.zig");
const Device = device_module.Device;

/// Records into one command buffer: a frame's (`Frame.cmd`) or one from
/// `Device.beginImmediate`. A resource may be destroyed once the commands
/// using it are recorded. Not thread-safe.
pub const CommandEncoder = struct {
    device: *Device,
    command: vk.CommandBuffer,
    /// Null for immediate command buffers, which carry no timings.
    frame: ?*device_module.FrameData,
    /// Timing slot of each open `beginScope`, innermost last.
    scope_stack: [8]u32 = undefined,
    scope_depth: u8 = 0,
    /// True between `beginRendering` and `endRendering`.
    rendering: bool = false,
    /// What has been recorded so far.
    work: types.Work = .{},
    /// Mips of sampled textures left in an attachment or copy state, owed a
    /// return to `shader_read`.
    owed: [max_owed]Mip = undefined,
    owed_count: u8 = 0,
    /// The attachments of the open rendering.
    attached: [9]Mip = undefined,
    attached_count: u8 = 0,

    const max_owed = 64;

    const Mip = struct {
        texture: types.Texture,
        mip: u32,
        /// Layers drawn into since the last barrier on the mip; a bit per
        /// layer, the last standing for every layer from 63 on.
        drawn: u64 = 0,

        fn in(self: Mip, list: []const Mip) bool {
            for (list) |other| {
                if (other.texture == self.texture and other.mip == self.mip) return true;
            }
            return false;
        }
    };

    fn pipelineBarrier(self: *CommandEncoder, info: *const vk.DependencyInfo) void {
        self.work.barriers += 1;
        self.work.image_barriers += info.image_memory_barrier_count;
        self.device.vkd.cmdPipelineBarrier2(self.command, info);
    }

    fn owe(self: *CommandEncoder, entry: Mip) void {
        const resource = self.device.textures.get(entry.texture) orelse return;
        if (resource.bindless_index == null) return;
        for (self.owed[0..self.owed_count]) |*other| {
            if (other.texture == entry.texture and other.mip == entry.mip) {
                other.drawn |= entry.drawn;
                return;
            }
        }
        if (self.owed_count == max_owed) self.settleExcept(&.{});
        self.owed[self.owed_count] = entry;
        self.owed_count += 1;
    }

    /// Returns every owed texture to `shader_read`, for work that samples
    /// textures without the encoder seeing it: an external SDK recording
    /// into the command buffer. Draws, dispatches and submits do it
    /// themselves.
    pub fn settle(self: *CommandEncoder) void {
        self.settleExcept(&.{});
    }

    /// As `settle`, leaving the mips in `keep` as they are and owed.
    fn settleExcept(self: *CommandEncoder, keep: []const Mip) void {
        var barriers: [max_owed]vk.ImageMemoryBarrier2 = undefined;
        var count: u32 = 0;
        var kept: u8 = 0;
        for (self.owed[0..self.owed_count]) |entry| {
            if (entry.in(keep)) {
                self.owed[kept] = entry;
                kept += 1;
                continue;
            }
            const resource = self.device.textures.get(entry.texture) orelse continue;
            const from = resource.states[entry.mip];
            switch (from) {
                .color_attachment, .depth_attachment, .copy_src, .copy_dst => {},
                else => continue,
            }
            barriers[count] = imageBarrier(self.device.caps.mesh_shaders, resource, entry.mip, 1, from, .shader_read);
            count += 1;
            resource.states[entry.mip] = .shader_read;
        }
        self.owed_count = kept;
        if (count == 0) return;
        self.pipelineBarrier(&.{
            .image_memory_barrier_count = count,
            .p_image_memory_barriers = &barriers,
        });
    }

    /// Binds the global descriptor table for both bind points.
    pub fn bindGlobals(self: *CommandEncoder) void {
        const vkd = self.device.vkd;
        vkd.cmdBindDescriptorSets(self.command, .graphics, self.device.pipeline_layout, 0, &.{self.device.descriptor_set}, &.{});
        vkd.cmdBindDescriptorSets(self.command, .compute, self.device.pipeline_layout, 0, &.{self.device.descriptor_set}, &.{});
    }

    /// Moves every mip of `texture` into `state`.
    pub fn transition(self: *CommandEncoder, texture: types.Texture, state: types.TextureState) void {
        const resource = self.device.textureResource(texture);
        var barriers: [device_module.max_mip_levels]vk.ImageMemoryBarrier2 = undefined;
        var count: u32 = 0;
        var mip: u32 = 0;
        while (mip < resource.info.mip_levels) {
            const from = resource.states[mip];
            var end = mip + 1;
            while (end < resource.info.mip_levels and resource.states[end] == from) end += 1;
            if (from != state) {
                barriers[count] = imageBarrier(self.device.caps.mesh_shaders, resource, mip, end - mip, from, state);
                count += 1;
            }
            mip = end;
        }
        if (count == 0) return;
        for (resource.states[0..resource.info.mip_levels]) |*value| value.* = state;
        self.pipelineBarrier(&.{
            .image_memory_barrier_count = count,
            .p_image_memory_barriers = &barriers,
        });
    }

    /// Moves a single mip (all layers) into `state`.
    pub fn transitionMip(self: *CommandEncoder, texture: types.Texture, mip: u32, state: types.TextureState) void {
        const resource = self.device.textureResource(texture);
        const from = resource.states[mip];
        if (from == state) return;
        const barrier = imageBarrier(self.device.caps.mesh_shaders, resource, mip, 1, from, state);
        resource.states[mip] = state;
        self.pipelineBarrier(&.{
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
            .acceleration_structure_build_bit_khr = self.device.caps.ray_tracing,
            .task_shader_bit_ext = self.device.caps.mesh_shaders,
            .mesh_shader_bit_ext = self.device.caps.mesh_shaders,
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
        self.pipelineBarrier(&.{
            .memory_barrier_count = 1,
            .p_memory_barriers = @ptrCast(&barrier),
        });
    }

    /// Begins a render pass, transitioning the attachments and setting a
    /// full-size viewport and scissor. Owed textures other than the
    /// attachments return to `shader_read` first.
    pub fn beginRendering(self: *CommandEncoder, desc: types.RenderingDesc) !void {
        std.debug.assert(!self.rendering);
        self.attached_count = 0;
        for (desc.color) |attachment| self.attach(.{ .texture = attachment.texture, .mip = attachment.mip, .drawn = layerBit(attachment.layer) });
        if (desc.depth) |attachment| self.attach(.{ .texture = attachment.texture, .mip = attachment.mip, .drawn = layerBit(attachment.layer) });
        errdefer {
            for (self.attached[0..self.attached_count]) |entry| self.owe(entry);
            self.attached_count = 0;
        }
        self.settleExcept(self.attached[0..self.attached_count]);
        for (desc.color) |attachment| self.redraw(attachment.texture, attachment.mip, attachment.layer, .color_attachment);
        if (desc.depth) |attachment| self.redraw(attachment.texture, attachment.mip, attachment.layer, .depth_attachment);
        var colors: [8]vk.RenderingAttachmentInfo = undefined;
        var extent: vk.Extent2D = .{ .width = 0, .height = 0 };
        for (desc.color, 0..) |attachment, index| {
            const resource = self.device.textureResource(attachment.texture);
            self.transitionMip(attachment.texture, attachment.mip, .color_attachment);
            extent = mipExtent(resource.info, attachment.mip);
            colors[index] = .{
                .image_view = try textures.subView(self.device, attachment.texture, attachment.mip, attachment.layer),
                .image_layout = .attachment_optimal,
                .resolve_mode = .{},
                .resolve_image_layout = .undefined,
                .load_op = loadOp(attachment.load),
                .store_op = .store,
                .clear_value = if (resource.info.format == .r32_uint or resource.info.format == .r8_uint)
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
                .image_view = try textures.subView(self.device, attachment.texture, attachment.mip, attachment.layer),
                .image_layout = .attachment_optimal,
                .resolve_mode = .{},
                .resolve_image_layout = .undefined,
                .load_op = loadOp(attachment.load),
                .store_op = if (attachment.store) .store else .dont_care,
                .clear_value = .{ .depth_stencil = .{ .depth = attachment.clear, .stencil = 0 } },
            };
        }
        var rate: vk.RenderingFragmentShadingRateAttachmentInfoKHR = undefined;
        if (desc.shading_rate) |texture| {
            self.transition(texture, .shading_rate);
            const tile = self.device.caps.shading_rate_tile;
            rate = .{
                .image_view = self.device.textureResource(texture).view,
                .image_layout = .fragment_shading_rate_attachment_optimal_khr,
                .shading_rate_attachment_texel_size = .{ .width = tile, .height = tile },
            };
        }
        self.work.render_passes += 1;
        self.device.vkd.cmdBeginRendering(self.command, &.{
            .p_next = if (desc.shading_rate != null) &rate else null,
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

    /// Sampled attachments are owed a return to `shader_read`.
    pub fn endRendering(self: *CommandEncoder) void {
        std.debug.assert(self.rendering);
        self.device.vkd.cmdEndRendering(self.command);
        self.rendering = false;
        for (self.attached[0..self.attached_count]) |entry| self.owe(entry);
        self.attached_count = 0;
    }

    fn layerBit(layer: u32) u64 {
        return @as(u64, 1) << @intCast(@min(layer, 63));
    }

    fn attach(self: *CommandEncoder, entry: Mip) void {
        for (self.attached[0..self.attached_count]) |*other| {
            if (other.texture == entry.texture and other.mip == entry.mip) {
                other.drawn |= entry.drawn;
                return;
            }
        }
        self.attached[self.attached_count] = entry;
        self.attached_count += 1;
    }

    /// Orders drawing into a layer that is still an attachment after the
    /// drawing that left it there. Other layers of the mip need no order.
    fn redraw(self: *CommandEncoder, texture: types.Texture, mip: u32, layer: u32, state: types.TextureState) void {
        const resource = self.device.textureResource(texture);
        if (resource.states[mip] != state) return;
        for (self.owed[0..self.owed_count]) |*entry| {
            if (entry.texture != texture or entry.mip != mip) continue;
            if (entry.drawn & layerBit(layer) == 0) return;
            entry.drawn = 0;
            break;
        }
        const barrier = imageBarrier(self.device.caps.mesh_shaders, resource, mip, 1, state, state);
        self.pipelineBarrier(&.{
            .image_memory_barrier_count = 1,
            .p_image_memory_barriers = @ptrCast(&barrier),
        });
    }

    /// Sets viewport and scissor to the same rectangle, in pixels from the
    /// top-left corner; depth range 0..1.
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

    /// Binds to the bind point the pipeline was created for. Globals and push
    /// constants stay valid across binds.
    pub fn bindPipeline(self: *CommandEncoder, pipeline: types.Pipeline) void {
        const resource = self.device.pipelineResource(pipeline);
        self.work.pipeline_binds += 1;
        self.device.vkd.cmdBindPipeline(self.command, resource.bind_point, resource.handle);
    }

    /// Pushes `value` (any extern struct up to 256 bytes) at offset 0.
    pub fn pushConstants(self: *CommandEncoder, value: anytype) void {
        const T = @TypeOf(value);
        comptime std.debug.assert(@sizeOf(T) <= device_module.push_constant_size);
        comptime std.debug.assert(@sizeOf(T) % 4 == 0);
        self.work.push_constants += 1;
        self.device.vkd.cmdPushConstants(self.command, self.device.pipeline_layout, pipelines.shaderStages(self.device), 0, @sizeOf(T), @ptrCast(&value));
    }

    /// Binds `buffer` from byte `offset` for pipelines with a `VertexLayout`.
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

    /// Binds `buffer` from byte `offset` as the index buffer.
    pub fn bindIndexBuffer(self: *CommandEncoder, buffer: types.Buffer, offset: u64, index_type: types.IndexType) void {
        self.device.vkd.cmdBindIndexBuffer(self.command, self.device.bufferResource(buffer).handle, offset, switch (index_type) {
            .uint16 => .uint16,
            .uint32 => .uint32,
        });
    }

    /// Non-indexed draw; inside a render pass. `first_instance` is the base of
    /// `gl_InstanceIndex`.
    pub fn draw(self: *CommandEncoder, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) void {
        self.work.draws += 1;
        self.device.vkd.cmdDraw(self.command, vertex_count, instance_count, first_vertex, first_instance);
    }

    /// `draw` with its four arguments read from `buffer` at `offset`. Needs
    /// `BufferUsage.indirect`.
    pub fn drawIndirect(self: *CommandEncoder, buffer: types.Buffer, offset: u64) void {
        self.work.indirect_draws += 1;
        self.device.vkd.cmdDrawIndirect(self.command, self.device.bufferResource(buffer).handle, offset, 1, 4 * @sizeOf(u32));
    }

    /// Draws one triangle covering the viewport; the vertex shader derives
    /// positions from `gl_VertexIndex`.
    pub fn drawFullscreen(self: *CommandEncoder) void {
        self.work.draws += 1;
        self.device.vkd.cmdDraw(self.command, 3, 1, 0, 0);
    }

    /// Indexed draw; inside a render pass. `vertex_offset` is added to every
    /// index.
    pub fn drawIndexed(
        self: *CommandEncoder,
        index_count: u32,
        instance_count: u32,
        first_index: u32,
        vertex_offset: i32,
        first_instance: u32,
    ) void {
        self.work.draws += 1;
        self.device.vkd.cmdDrawIndexed(self.command, index_count, instance_count, first_index, vertex_offset, first_instance);
    }

    /// Mesh shader draw with its three 32-bit task group counts read from
    /// `buffer` at `offset`. Needs `BufferUsage.indirect`.
    pub fn drawMeshTasksIndirect(self: *CommandEncoder, buffer: types.Buffer, offset: u64) void {
        self.work.indirect_draws += 1;
        self.device.vkd.cmdDrawMeshTasksIndirectEXT(self.command, self.device.bufferResource(buffer).handle, offset, 1, 3 * @sizeOf(u32));
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
        self.work.indirect_draws += 1;
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

    /// Runs the bound compute pipeline; outside a render pass. Buffer writes
    /// are not visible to later passes until `sync(.compute_to_all)`.
    pub fn dispatch(self: *CommandEncoder, x: u32, y: u32, z: u32) void {
        self.settle();
        self.work.dispatches += 1;
        self.device.vkd.cmdDispatch(self.command, x, y, z);
    }

    /// `dispatch` with its three 32-bit workgroup counts read from `buffer` at
    /// `offset`. Needs `BufferUsage.indirect`.
    pub fn dispatchIndirect(self: *CommandEncoder, buffer: types.Buffer, offset: u64) void {
        self.settle();
        self.work.dispatches += 1;
        self.device.vkd.cmdDispatchIndirect(self.command, self.device.bufferResource(buffer).handle, offset);
    }

    /// Fills with the repeated 32-bit `value`; `offset` and `size` must be
    /// multiples of 4. Outside a render pass; `sync(.transfer_to_all)` before
    /// the buffer is read.
    pub fn fillBuffer(self: *CommandEncoder, buffer: types.Buffer, offset: u64, size: u64, value: u32) void {
        self.work.transfers += 1;
        self.device.vkd.cmdFillBuffer(self.command, self.device.bufferResource(buffer).handle, offset, size, value);
    }

    /// `source` needs `copy_src`; the ranges must not overlap. Outside a render
    /// pass; `sync(.transfer_to_all)` before the destination is read.
    pub fn copyBuffer(self: *CommandEncoder, source: types.Buffer, destination: types.Buffer, source_offset: u64, destination_offset: u64, size: u64) void {
        self.work.transfers += 1;
        self.device.vkd.cmdCopyBuffer(
            self.command,
            self.device.bufferResource(source).handle,
            self.device.bufferResource(destination).handle,
            &.{.{ .src_offset = source_offset, .dst_offset = destination_offset, .size = size }},
        );
    }

    /// Records every staged upload and mip-generation request; outside a
    /// render pass. Uploaded textures end in `shader_read`.
    pub fn flushUploads(self: *CommandEncoder) !void {
        std.debug.assert(!self.rendering);
        const device = self.device;
        if (device.uploads.items.len == 0) return;
        const waits = try rewrites(device.gpa, device.uploads.items);
        defer device.gpa.free(waits);
        self.work.staged_bytes += device.pending_upload_bytes;
        var uploads = device.internal.takeUploads();
        defer uploads.deinit(device.gpa);
        for (uploads.items) |upload| switch (upload) {
            .buffer, .copy => {
                self.sync(.all_to_transfer);
                break;
            },
            else => {},
        };
        var copied_buffers = false;
        for (uploads.items, waits) |upload, wait| {
            if (wait) self.sync(.transfer_to_all);
            self.recordUpload(upload, &copied_buffers);
        }
        if (copied_buffers) self.sync(.transfer_to_all);
        for (uploads.items) |upload| switch (upload) {
            .texture => |copy| self.transition(copy.destination, .shader_read),
            else => {},
        };
    }

    fn recordUpload(self: *CommandEncoder, upload: device_module.PendingUpload, copied_buffers: *bool) void {
        const device = self.device;
        switch (upload) {
            .buffer => |copy| {
                self.copyBuffer(copy.staging, copy.destination, 0, copy.offset, copy.size);
                device.destroyBuffer(copy.staging);
                copied_buffers.* = true;
            },
            .texture => |copy| {
                const resource = device.textureResource(copy.destination);
                self.transitionMip(copy.destination, copy.mip, .copy_dst);
                const whole = mipExtent(resource.info, copy.mip);
                const region: [4]u32 = copy.region orelse .{ 0, 0, whole.width, whole.height };
                self.work.transfers += 1;
                device.vkd.cmdCopyBufferToImage(self.command, device.bufferResource(copy.staging).handle, resource.image, .transfer_dst_optimal, &.{.{
                    .buffer_offset = copy.offset,
                    .buffer_row_length = 0,
                    .buffer_image_height = 0,
                    .image_subresource = .{ .aspect_mask = resource.aspect, .mip_level = copy.mip, .base_array_layer = copy.layer, .layer_count = 1 },
                    .image_offset = .{ .x = @intCast(region[0]), .y = @intCast(region[1]), .z = 0 },
                    .image_extent = .{ .width = region[2], .height = region[3], .depth = 1 },
                }});
                if (copy.last) device.destroyBuffer(copy.staging);
            },
            .mips => |texture| self.generateMips(texture),
            .copy => |copy| {
                self.sync(.transfer_to_all);
                self.copyBuffer(copy.source, copy.destination, 0, 0, copy.size);
                device.destroyBuffer(copy.source);
                copied_buffers.* = true;
            },
        }
    }

    /// Copies mip 0 of `source` to `destination` texel for texel: same size,
    /// formats of the same texel size. Sampled ones return to `shader_read`
    /// before the next work that could sample them.
    pub fn copyTexture(self: *CommandEncoder, source: types.Texture, destination: types.Texture) void {
        self.settleExcept(&.{ .{ .texture = source, .mip = 0 }, .{ .texture = destination, .mip = 0 } });
        defer for ([_]types.Texture{ source, destination }) |texture| {
            for (0..self.device.textureResource(texture).info.mip_levels) |mip| self.owe(.{ .texture = texture, .mip = @intCast(mip) });
        };
        self.transition(source, .copy_src);
        self.transition(destination, .copy_dst);
        const from = self.device.textureResource(source);
        const to = self.device.textureResource(destination);
        self.work.transfers += 1;
        self.device.vkd.cmdCopyImage(self.command, from.image, .transfer_src_optimal, to.image, .transfer_dst_optimal, &.{.{
            .src_subresource = .{ .aspect_mask = from.aspect, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 },
            .src_offset = .{ .x = 0, .y = 0, .z = 0 },
            .dst_subresource = .{ .aspect_mask = to.aspect, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 },
            .dst_offset = .{ .x = 0, .y = 0, .z = 0 },
            .extent = .{ .width = from.info.width, .height = from.info.height, .depth = 1 },
        }});
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
            self.work.transfers += 1;
            self.device.vkd.cmdBlitImage(self.command, resource.image, .transfer_src_optimal, resource.image, .transfer_dst_optimal, &.{.{
                .src_subresource = .{ .aspect_mask = resource.aspect, .mip_level = mip - 1, .base_array_layer = 0, .layer_count = info.layers },
                .src_offsets = .{ .{ .x = 0, .y = 0, .z = 0 }, .{ .x = @intCast(source.width), .y = @intCast(source.height), .z = 1 } },
                .dst_subresource = .{ .aspect_mask = resource.aspect, .mip_level = mip, .base_array_layer = 0, .layer_count = info.layers },
                .dst_offsets = .{ .{ .x = 0, .y = 0, .z = 0 }, .{ .x = @intCast(destination.width), .y = @intCast(destination.height), .z = 1 } },
            }}, .linear);
        }
        self.transition(texture, .shader_read);
    }

    /// Builds a bottom-level structure from geometry already on the GPU.
    pub fn buildBlas(self: *CommandEncoder, blas: types.AccelerationStructure, desc: types.BlasDesc) !void {
        try self.buildBlases(&.{.{ .blas = blas, .desc = desc }});
    }

    /// As `buildBlas` for each, recorded together so the GPU may build them
    /// side by side.
    pub fn buildBlases(self: *CommandEncoder, builds: []const types.BlasBuild) !void {
        std.debug.assert(!self.rendering);
        self.rayQueryBarrier();
        self.work.builds += @intCast(builds.len);
        try acceleration.buildBlasesCommand(self.device, self.command, builds);
    }

    /// Asks for the size a structure built earlier in these commands compacts
    /// to; `Device.compactedBlasSize` has it once they have run.
    pub fn measureBlas(self: *CommandEncoder, blas: types.AccelerationStructure) !void {
        std.debug.assert(!self.rendering);
        self.accelerationBarrier();
        try acceleration.measureBlasCommand(self.device, self.command, blas);
    }

    /// Copies `source` into `destination`, made by
    /// `Device.createCompactBlas`, leaving out what it does not need.
    pub fn compactBlas(self: *CommandEncoder, source: types.AccelerationStructure, destination: types.AccelerationStructure) void {
        std.debug.assert(!self.rendering);
        self.accelerationBarrier();
        self.work.builds += 1;
        acceleration.compactBlasCommand(self.device, self.command, source, destination);
        self.accelerationBarrier();
    }

    /// Rebuilds from `instance_count` `AccelerationInstance` records at
    /// `instances_address`.
    pub fn buildTlas(self: *CommandEncoder, tlas: types.AccelerationStructure, instances_address: u64, instance_count: u32) void {
        std.debug.assert(!self.rendering);
        self.rayQueryBarrier();
        self.accelerationBarrier();
        self.work.builds += 1;
        acceleration.buildTlasCommand(self.device, self.command, tlas, instances_address, instance_count, false);
        self.accelerationBarrier();
    }

    /// As `buildTlas`, updating the last build in place when the structure
    /// is `TlasDesc.updatable` and the instance count has not changed: for
    /// instances that only moved.
    pub fn updateTlas(self: *CommandEncoder, tlas: types.AccelerationStructure, instances_address: u64, instance_count: u32) void {
        std.debug.assert(!self.rendering);
        self.rayQueryBarrier();
        self.accelerationBarrier();
        self.work.builds += 1;
        acceleration.buildTlasCommand(self.device, self.command, tlas, instances_address, instance_count, true);
        self.accelerationBarrier();
    }

    /// Lets a build overwrite a structure only once earlier ray queries,
    /// of this frame or one still in flight, are done with it.
    fn rayQueryBarrier(self: *CommandEncoder) void {
        const barrier = vk.MemoryBarrier2{
            .src_stage_mask = .{ .compute_shader_bit = true, .fragment_shader_bit = true },
            .dst_stage_mask = .{ .acceleration_structure_build_bit_khr = true },
        };
        self.pipelineBarrier(&.{
            .memory_barrier_count = 1,
            .p_memory_barriers = @ptrCast(&barrier),
        });
    }

    /// Makes builds visible to later builds and to ray queries.
    fn accelerationBarrier(self: *CommandEncoder) void {
        const barrier = vk.MemoryBarrier2{
            .src_stage_mask = .{ .acceleration_structure_build_bit_khr = true },
            .src_access_mask = .{ .acceleration_structure_write_bit_khr = true },
            .dst_stage_mask = .{ .acceleration_structure_build_bit_khr = true, .compute_shader_bit = true, .fragment_shader_bit = true },
            .dst_access_mask = .{ .acceleration_structure_read_bit_khr = true, .acceleration_structure_write_bit_khr = true },
        };
        self.pipelineBarrier(&.{
            .memory_barrier_count = 1,
            .p_memory_barriers = @ptrCast(&barrier),
        });
    }

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
            frame.scopes[index] = .{ .name = name, .depth = self.scope_depth, .work = self.work };
            frame.scope_count += 1;
            self.device.vkd.cmdWriteTimestamp2(self.command, .{ .all_commands_bit = true }, frame.query_pool, index * 2);
        }
        self.scope_stack[self.scope_depth] = index;
        self.scope_depth += 1;
    }

    /// Closes the innermost `beginScope`. All scopes must be closed before
    /// the frame is submitted.
    pub fn endScope(self: *CommandEncoder) void {
        if (self.device.debug_labels) self.device.vkd.cmdEndDebugUtilsLabelEXT(self.command);
        const frame = self.frameData() orelse return;
        self.scope_depth -= 1;
        const index = self.scope_stack[self.scope_depth];
        if (index == std.math.maxInt(u32)) return;
        frame.scopes[index].work = self.work.since(frame.scopes[index].work);
        self.device.vkd.cmdWriteTimestamp2(self.command, .{ .all_commands_bit = true }, frame.query_pool, index * 2 + 1);
    }

    fn frameData(self: *CommandEncoder) ?*FrameData {
        return self.frame;
    }
};

const FrameData = device_module.FrameData;

/// For each upload, whether it writes bytes an earlier one in `uploads`
/// also writes, so it must wait for that copy. Of a run of overlapping
/// buffer ranges, every upload but the first waits; of a texture level,
/// every upload after the first.
fn rewrites(gpa: std.mem.Allocator, uploads: []const device_module.PendingUpload) ![]bool {
    const waits = try gpa.alloc(bool, uploads.len);
    errdefer gpa.free(waits);
    @memset(waits, false);
    const Span = struct {
        texture: bool,
        target: u64,
        start: u64,
        end: u64,
        index: u32,

        fn before(_: void, a: @This(), b: @This()) bool {
            if (a.texture != b.texture) return b.texture;
            return if (a.target != b.target) a.target < b.target else if (a.start != b.start) a.start < b.start else a.index < b.index;
        }
    };
    var spans: std.ArrayList(Span) = .empty;
    defer spans.deinit(gpa);
    for (uploads, 0..) |upload, index| switch (upload) {
        .buffer => |copy| try spans.append(gpa, .{ .texture = false, .target = @bitCast(copy.destination), .start = copy.offset, .end = copy.offset + copy.size, .index = @intCast(index) }),
        .copy => |copy| try spans.append(gpa, .{ .texture = false, .target = @bitCast(copy.destination), .start = 0, .end = copy.size, .index = @intCast(index) }),
        .texture => |copy| try spans.append(gpa, .{ .texture = true, .target = @bitCast(copy.destination), .start = @as(u64, copy.mip) << 32 | copy.layer, .end = (@as(u64, copy.mip) << 32 | copy.layer) + 1, .index = @intCast(index) }),
        .mips => {},
    };
    if (spans.items.len < 2) return waits;
    std.mem.sort(Span, spans.items, {}, Span.before);
    var first: usize = 0;
    while (first < spans.items.len) {
        var last = first + 1;
        var end = spans.items[first].end;
        var earliest = spans.items[first].index;
        while (last < spans.items.len and spans.items[last].texture == spans.items[first].texture and spans.items[last].target == spans.items[first].target and spans.items[last].start < end) : (last += 1) {
            end = @max(end, spans.items[last].end);
            earliest = @min(earliest, spans.items[last].index);
        }
        if (last - first > 1) for (spans.items[first..last]) |span| {
            if (span.index != earliest) waits[span.index] = true;
        };
        first = last;
    }
    return waits;
}

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

/// `mesh_shaders` adds the task and mesh stages to `shader_read` and
/// `storage`, which also covers every graphics stage, for pipelines of the
/// application's that use textures there.
fn stateInfo(state: types.TextureState, mesh_shaders: bool) StateInfo {
    return switch (state) {
        .undefined => .{ .layout = .undefined, .stage = .{}, .access = .{} },
        .shader_read => .{
            .layout = .read_only_optimal,
            .stage = .{ .vertex_shader_bit = true, .fragment_shader_bit = true, .compute_shader_bit = true, .task_shader_bit_ext = mesh_shaders, .mesh_shader_bit_ext = mesh_shaders },
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
        .storage => .{
            .layout = .general,
            .stage = .{ .vertex_shader_bit = true, .fragment_shader_bit = true, .compute_shader_bit = true, .task_shader_bit_ext = mesh_shaders, .mesh_shader_bit_ext = mesh_shaders },
            .access = .{ .shader_storage_read_bit = true, .shader_storage_write_bit = true },
        },
        .external => .{
            .layout = .general,
            .stage = .{ .all_commands_bit = true },
            .access = .{ .memory_read_bit = true, .memory_write_bit = true },
        },
        .shading_rate => .{
            .layout = .fragment_shading_rate_attachment_optimal_khr,
            .stage = .{ .fragment_shading_rate_attachment_bit_khr = true },
            .access = .{ .fragment_shading_rate_attachment_read_bit_khr = true },
        },
        .present => .{ .layout = .present_src_khr, .stage = .{}, .access = .{} },
    };
}

/// A swapchain image leaving `undefined` waits in `all_commands`, the stage
/// its acquire semaphore is waited in, so the layout change follows it.
fn imageBarrier(
    mesh_shaders: bool,
    resource: *const device_module.TextureResource,
    base_mip: u32,
    mip_count: u32,
    from: types.TextureState,
    to: types.TextureState,
) vk.ImageMemoryBarrier2 {
    const source = stateInfo(from, mesh_shaders);
    const destination = stateInfo(to, mesh_shaders);
    const swapchain_image = resource.allocation == null;
    return .{
        .src_stage_mask = if (from == .undefined and swapchain_image) .{ .all_commands_bit = true } else source.stage,
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
