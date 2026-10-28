//! Command recording for one frame. The encoder tracks texture state per
//! mip and derives layout transitions. Sampled textures rest in
//! `shader_read`: `beginRendering` and the copies move theirs out, and
//! they return before the next work that could sample them. Barriers wait
//! for the next command that needs them and go into one call, with moves
//! of the same mips folded into one.
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
    /// Set for an encoder recorded beside others (`Device.beginParallel`):
    /// texture states are kept here instead of on the device, whose states
    /// stay as they were until `Device.joinParallel`.
    local: ?*LocalStates = null,
    /// Which of the frame's `split_commands` `awaitAsync` goes on in, and the
    /// ended command buffer it left behind.
    split_slot: u8 = device_module.max_parallel,
    before: vk.CommandBuffer = .null_handle,
    /// Barriers made since the last command, recorded together by `flush`.
    waiting: [max_waiting]Waiting = undefined,
    waiting_count: u8 = 0,
    /// Kept apart, not merged: one with the stages of two would make each
    /// wait for the other's work.
    waiting_memory: [max_waiting_memory]vk.MemoryBarrier2 = undefined,
    waiting_memory_count: u8 = 0,

    const max_owed = 64;
    const max_waiting = 96;
    const max_waiting_memory = 16;

    /// A layout change not yet recorded, with the mips it covers and the
    /// state it starts from, so a later move of the same mips folds into it.
    const Waiting = struct {
        texture: types.Texture,
        base_mip: u32,
        mip_count: u32,
        from: types.TextureState,
        barrier: vk.ImageMemoryBarrier2,
    };

    /// What an encoder recorded beside others did to texture states: each mip
    /// it touched, the state it found it in, and the one it left it in.
    pub const LocalStates = struct {
        gpa: std.mem.Allocator,
        entries: std.ArrayList(Entry) = .empty,
        /// A state could not be kept for want of memory; the frame fails.
        failed: bool = false,

        pub const Entry = struct { texture: types.Texture, mip: u32, found: types.TextureState, state: types.TextureState };

        pub fn deinit(self: *LocalStates) void {
            self.entries.deinit(self.gpa);
        }
    };

    /// The state of a mip as of the commands this encoder recorded so far.
    fn stateOf(self: *CommandEncoder, texture: types.Texture, resource: *const device_module.TextureResource, mip: u32) types.TextureState {
        const local = self.local orelse return resource.states[mip];
        for (local.entries.items) |entry| {
            if (entry.texture == texture and entry.mip == mip) return entry.state;
        }
        const found = resource.states[mip];
        local.entries.append(local.gpa, .{ .texture = texture, .mip = mip, .found = found, .state = found }) catch {
            local.failed = true;
        };
        return found;
    }

    fn setState(self: *CommandEncoder, texture: types.Texture, resource: *device_module.TextureResource, mip: u32, state: types.TextureState) void {
        const local = self.local orelse {
            resource.states[mip] = state;
            return;
        };
        for (local.entries.items) |*entry| {
            if (entry.texture != texture or entry.mip != mip) continue;
            entry.state = state;
            return;
        }
        local.entries.append(local.gpa, .{ .texture = texture, .mip = mip, .found = resource.states[mip], .state = state }) catch {
            local.failed = true;
        };
    }

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

    /// Records the waiting barriers as one call. Commands that need them call
    /// it, and so must code that records into `command` itself.
    pub fn flush(self: *CommandEncoder) void {
        if (self.waiting_count == 0 and self.waiting_memory_count == 0) return;
        std.debug.assert(!self.rendering);
        var barriers: [max_waiting]vk.ImageMemoryBarrier2 = undefined;
        for (self.waiting[0..self.waiting_count], 0..) |entry, index| barriers[index] = entry.barrier;
        self.work.barriers += 1;
        self.work.image_barriers += self.waiting_count;
        self.device.vkd.cmdPipelineBarrier2(self.command, &.{
            .memory_barrier_count = self.waiting_memory_count,
            .p_memory_barriers = &self.waiting_memory,
            .image_memory_barrier_count = self.waiting_count,
            .p_image_memory_barriers = &barriers,
        });
        self.waiting_count = 0;
        self.waiting_memory_count = 0;
    }

    /// Adds a move of mips from `from` to `to`. A waiting move of the same
    /// mips becomes one from where it started, or none when it started in
    /// the same read-only state, as nothing ran in between.
    fn waitImage(self: *CommandEncoder, texture: types.Texture, resource: *const device_module.TextureResource, base_mip: u32, mip_count: u32, from: types.TextureState, to: types.TextureState) void {
        var start = from;
        var folded = false;
        for (self.waiting[0..self.waiting_count], 0..) |entry, index| {
            if (entry.texture != texture) continue;
            if (entry.base_mip >= base_mip + mip_count or base_mip >= entry.base_mip + entry.mip_count) continue;
            if (entry.base_mip != base_mip or entry.mip_count != mip_count) {
                self.flush();
                break;
            }
            start = entry.from;
            folded = true;
            self.waiting_count -= 1;
            self.waiting[index] = self.waiting[self.waiting_count];
            break;
        }
        if (folded and start == to and (to == .shader_read or to == .copy_src)) return;
        if (self.waiting_count == max_waiting) self.flush();
        self.waiting[self.waiting_count] = .{
            .texture = texture,
            .base_mip = base_mip,
            .mip_count = mip_count,
            .from = start,
            .barrier = imageBarrier(self.device.caps.mesh_shaders, resource, base_mip, mip_count, start, to),
        };
        self.waiting_count += 1;
    }

    fn waitMemory(self: *CommandEncoder, barrier: vk.MemoryBarrier2) void {
        for (self.waiting_memory[0..self.waiting_memory_count]) |known| {
            if (known.src_stage_mask.toInt() == barrier.src_stage_mask.toInt() and known.src_access_mask.toInt() == barrier.src_access_mask.toInt() and
                known.dst_stage_mask.toInt() == barrier.dst_stage_mask.toInt() and known.dst_access_mask.toInt() == barrier.dst_access_mask.toInt()) return;
        }
        if (self.waiting_memory_count == max_waiting_memory) self.flush();
        self.waiting_memory[self.waiting_memory_count] = barrier;
        self.waiting_memory_count += 1;
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
        self.flush();
    }

    /// As `settle`, leaving the mips in `keep` as they are and owed.
    fn settleExcept(self: *CommandEncoder, keep: []const Mip) void {
        var kept: u8 = 0;
        for (self.owed[0..self.owed_count]) |entry| {
            if (entry.in(keep)) {
                self.owed[kept] = entry;
                kept += 1;
                continue;
            }
            const resource = self.device.textures.get(entry.texture) orelse continue;
            const from = self.stateOf(entry.texture, resource, entry.mip);
            switch (from) {
                .color_attachment, .depth_attachment, .copy_src, .copy_dst => {},
                else => continue,
            }
            self.waitImage(entry.texture, resource, entry.mip, 1, from, .shader_read);
            self.setState(entry.texture, resource, entry.mip, .shader_read);
        }
        self.owed_count = kept;
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
        var moved = false;
        var mip: u32 = 0;
        while (mip < resource.info.mip_levels) {
            const from = self.stateOf(texture, resource, mip);
            var end = mip + 1;
            while (end < resource.info.mip_levels and self.stateOf(texture, resource, end) == from) end += 1;
            if (from != state) {
                self.waitImage(texture, resource, mip, end - mip, from, state);
                moved = true;
            }
            mip = end;
        }
        if (!moved) return;
        for (0..resource.info.mip_levels) |level| self.setState(texture, resource, @intCast(level), state);
    }

    /// Records a barrier that moves a mip from `from` to `to` for commands
    /// recorded elsewhere, leaving this encoder's states as they are.
    pub fn moveMip(self: *CommandEncoder, texture: types.Texture, mip: u32, from: types.TextureState, to: types.TextureState) void {
        const resource = self.device.textures.get(texture) orelse return;
        self.waitImage(texture, resource, mip, 1, from, to);
    }

    /// Moves a single mip (all layers) into `state`.
    pub fn transitionMip(self: *CommandEncoder, texture: types.Texture, mip: u32, state: types.TextureState) void {
        const resource = self.device.textureResource(texture);
        const from = self.stateOf(texture, resource, mip);
        if (from == state) return;
        self.waitImage(texture, resource, mip, 1, from, state);
        self.setState(texture, resource, mip, state);
    }

    /// Declares a buffer hand-off between pipeline stages.
    pub fn sync(self: *CommandEncoder, kind: types.BufferSync) void {
        const reads = types.BufferAccess{ .compute_read = true, .graphics_read = true, .indirect = true, .index = true, .vertex_input = true, .transfer_read = true, .build_read = true };
        switch (kind) {
            .compute_to_all => self.dependency(.{ .compute_write = true }, reads),
            .transfer_to_all => self.dependency(.{ .transfer_write = true }, reads.merge(.{ .transfer_write = true })),
            .all_to_transfer => self.dependency(reads.merge(.{ .compute_write = true, .graphics_write = true, .transfer_write = true }), .{ .transfer_read = true, .transfer_write = true }),
        }
    }

    /// Makes buffer work in `from` finish, and its writes visible, before
    /// buffer work in `to`. Nothing is recorded when either is empty.
    pub fn dependency(self: *CommandEncoder, from: types.BufferAccess, to: types.BufferAccess) void {
        if (from.empty() or to.empty()) return;
        const source = bufferAccessInfo(from, self.device.caps.ray_tracing, self.device.caps.mesh_shaders);
        const destination = bufferAccessInfo(to, self.device.caps.ray_tracing, self.device.caps.mesh_shaders);
        if (@as(u64, @bitCast(source.stage)) == 0 or @as(u64, @bitCast(destination.stage)) == 0) return;
        self.waitMemory(.{
            .src_stage_mask = source.stage,
            .src_access_mask = if (from.writes()) source.access else .{},
            .dst_stage_mask = destination.stage,
            .dst_access_mask = if (from.writes()) destination.access else .{},
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
                .store_op = if (attachment.store) .store else .dont_care,
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
                .store_op = if (attachment.read_only) .none else if (attachment.store) .store else .dont_care,
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
        self.flush();
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
        if (self.stateOf(texture, resource, mip) != state) return;
        for (self.owed[0..self.owed_count]) |*entry| {
            if (entry.texture != texture or entry.mip != mip) continue;
            if (entry.drawn & layerBit(layer) == 0) return;
            entry.drawn = 0;
            break;
        }
        self.waitImage(texture, resource, mip, 1, state, state);
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

    /// As `drawIndexedIndirectCount` for draws that are not indexed: four
    /// words each, `VkDrawIndirectCommand`.
    pub fn drawIndirectCount(
        self: *CommandEncoder,
        commands: types.Buffer,
        commands_offset: u64,
        count: types.Buffer,
        count_offset: u64,
        max_draws: u32,
    ) void {
        self.work.indirect_draws += 1;
        self.device.vkd.cmdDrawIndirectCount(
            self.command,
            self.device.bufferResource(commands).handle,
            commands_offset,
            self.device.bufferResource(count).handle,
            count_offset,
            max_draws,
            @sizeOf(vk.DrawIndirectCommand),
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
        self.flush();
        self.work.transfers += 1;
        self.device.vkd.cmdFillBuffer(self.command, self.device.bufferResource(buffer).handle, offset, size, value);
    }

    /// `source` needs `copy_src`; the ranges must not overlap. Outside a render
    /// pass; `sync(.transfer_to_all)` before the destination is read.
    pub fn copyBuffer(self: *CommandEncoder, source: types.Buffer, destination: types.Buffer, source_offset: u64, destination_offset: u64, size: u64) void {
        self.flush();
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
        const uploads = device.internal.takeUploads();
        defer device.internal.returnUploads(uploads);
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
        device.internal.fenceRing();
        for (uploads.items) |upload| switch (upload) {
            .texture => |copy| self.transition(copy.destination, .shader_read),
            else => {},
        };
    }

    fn recordUpload(self: *CommandEncoder, upload: device_module.PendingUpload, copied_buffers: *bool) void {
        const device = self.device;
        switch (upload) {
            .buffer => |copy| {
                self.copyBuffer(copy.staging, copy.destination, copy.staging_offset, copy.offset, copy.size);
                if (ownsStaging(device, copy.staging)) device.destroyBuffer(copy.staging);
                copied_buffers.* = true;
            },
            .texture => |copy| {
                const resource = device.textureResource(copy.destination);
                self.transitionMip(copy.destination, copy.mip, .copy_dst);
                const whole = mipExtent(resource.info, copy.mip);
                const region: [4]u32 = copy.region orelse .{ 0, 0, whole.width, whole.height };
                self.flush();
                self.work.transfers += 1;
                device.vkd.cmdCopyBufferToImage(self.command, device.bufferResource(copy.staging).handle, resource.image, .transfer_dst_optimal, &.{.{
                    .buffer_offset = copy.offset,
                    .buffer_row_length = 0,
                    .buffer_image_height = 0,
                    .image_subresource = .{ .aspect_mask = resource.aspect, .mip_level = copy.mip, .base_array_layer = copy.layer, .layer_count = 1 },
                    .image_offset = .{ .x = @intCast(region[0]), .y = @intCast(region[1]), .z = 0 },
                    .image_extent = .{ .width = region[2], .height = region[3], .depth = 1 },
                }});
                if (copy.last and ownsStaging(device, copy.staging)) device.destroyBuffer(copy.staging);
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
        self.flush();
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
            self.flush();
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
        self.flush();
        try acceleration.buildBlasesCommand(self.device, self.command, builds);
    }

    /// Asks for the size a structure built earlier in these commands compacts
    /// to; `Device.compactedBlasSize` has it once they have run.
    pub fn measureBlas(self: *CommandEncoder, blas: types.AccelerationStructure) !void {
        std.debug.assert(!self.rendering);
        self.accelerationBarrier();
        self.flush();
        try acceleration.measureBlasCommand(self.device, self.command, blas);
    }

    /// Copies `source` into `destination`, made by
    /// `Device.createCompactBlas`, leaving out what it does not need.
    pub fn compactBlas(self: *CommandEncoder, source: types.AccelerationStructure, destination: types.AccelerationStructure) void {
        std.debug.assert(!self.rendering);
        self.accelerationBarrier();
        self.work.builds += 1;
        self.flush();
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
        self.flush();
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
        self.flush();
        acceleration.buildTlasCommand(self.device, self.command, tlas, instances_address, instance_count, true);
        self.accelerationBarrier();
    }

    /// Lets a build overwrite a structure only once earlier ray queries,
    /// of this frame or one still in flight, are done with it.
    fn rayQueryBarrier(self: *CommandEncoder) void {
        self.waitMemory(.{
            .src_stage_mask = .{ .compute_shader_bit = true, .fragment_shader_bit = true },
            .dst_stage_mask = .{ .acceleration_structure_build_bit_khr = true },
        });
    }

    /// Makes builds visible to later builds and to ray queries.
    fn accelerationBarrier(self: *CommandEncoder) void {
        self.waitMemory(.{
            .src_stage_mask = .{ .acceleration_structure_build_bit_khr = true },
            .src_access_mask = .{ .acceleration_structure_write_bit_khr = true },
            .dst_stage_mask = .{ .acceleration_structure_build_bit_khr = true, .compute_shader_bit = true, .fragment_shader_bit = true },
            .dst_access_mask = .{ .acceleration_structure_read_bit_khr = true, .acceleration_structure_write_bit_khr = true },
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
        const taken = @atomicRmw(u32, &frame.scope_count, .Add, 1, .monotonic);
        if (taken < device_module.max_timing_scopes) {
            index = taken;
            frame.scopes[index] = .{ .name = name, .depth = self.scope_depth, .work = self.work };
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

    /// Marks where the frame starts to need earlier frames' async compute: what
    /// is recorded from here on waits for it. Only the first call of an
    /// encoder counts, and only after a frame that recorded async work; the
    /// earliest mark in submission order is where the wait goes.
    pub fn awaitAsync(self: *CommandEncoder) !void {
        const frame = self.frame orelse return;
        const bit = @as(u16, 1) << @intCast(self.split_slot);
        if (frame.async_wait == 0 or self.before != .null_handle) return;
        if (@atomicRmw(u16, &frame.split_taken, .Or, bit, .monotonic) & bit != 0) return;
        std.debug.assert(!self.rendering);
        const device = self.device;
        const slot = &frame.split_commands[self.split_slot];
        if (slot.* == .null_handle) {
            const pool = if (self.split_slot < device_module.max_parallel) frame.worker_pools[self.split_slot] else frame.pool;
            try device.vkd.allocateCommandBuffers(&.{ .command_pool = pool, .level = .primary, .command_buffer_count = 1 }, @ptrCast(slot));
        }
        self.flush();
        try device.vkd.endCommandBuffer(self.command);
        self.before = self.command;
        try device.vkd.beginCommandBuffer(slot.*, &.{ .flags = .{ .one_time_submit_bit = true } });
        self.command = slot.*;
        self.bindGlobals();
    }

    /// Adds the encoder's ended command buffers to what its frame submits.
    pub fn submitInto(self: *CommandEncoder, frame: *FrameData) void {
        if (self.before != .null_handle) {
            frame.submits[frame.submit_count] = self.before;
            frame.submit_count += 1;
            frame.wait_from = @min(frame.wait_from, frame.submit_count);
            self.before = .null_handle;
        }
        frame.submits[frame.submit_count] = self.command;
        frame.submit_count += 1;
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

/// The staging buffer is the upload's own rather than the shared ring.
fn ownsStaging(device: *const device_module.Device, buffer: types.Buffer) bool {
    return !device_module.sameHandle(buffer, device.staging_ring);
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

const AccessInfo = struct { stage: vk.PipelineStageFlags2, access: vk.AccessFlags2 };

/// The stages and memory accesses of a set of buffer uses. Shader reads take
/// in acceleration structure reads when there is ray tracing, for ray
/// queries; `mesh_shaders` adds the task and mesh stages to graphics.
fn bufferAccessInfo(uses: types.BufferAccess, ray_tracing: bool, mesh_shaders: bool) AccessInfo {
    const graphics = vk.PipelineStageFlags2{ .vertex_shader_bit = true, .fragment_shader_bit = true, .task_shader_bit_ext = mesh_shaders, .mesh_shader_bit_ext = mesh_shaders };
    const shader_read = vk.AccessFlags2{ .shader_read_bit = true, .acceleration_structure_read_bit_khr = ray_tracing };
    var info = AccessInfo{ .stage = .{}, .access = .{} };
    if (uses.compute_read) {
        info.stage = info.stage.merge(.{ .compute_shader_bit = true });
        info.access = info.access.merge(shader_read);
    }
    if (uses.compute_write) {
        info.stage = info.stage.merge(.{ .compute_shader_bit = true });
        info.access = info.access.merge(.{ .shader_write_bit = true });
    }
    if (uses.graphics_read) {
        info.stage = info.stage.merge(graphics);
        info.access = info.access.merge(shader_read);
    }
    if (uses.graphics_write) {
        info.stage = info.stage.merge(graphics);
        info.access = info.access.merge(.{ .shader_write_bit = true });
    }
    if (uses.indirect) {
        info.stage = info.stage.merge(.{ .draw_indirect_bit = true });
        info.access = info.access.merge(.{ .indirect_command_read_bit = true });
    }
    if (uses.index) {
        info.stage = info.stage.merge(.{ .index_input_bit = true });
        info.access = info.access.merge(.{ .index_read_bit = true });
    }
    if (uses.vertex_input) {
        info.stage = info.stage.merge(.{ .vertex_attribute_input_bit = true });
        info.access = info.access.merge(.{ .vertex_attribute_read_bit = true });
    }
    if (uses.transfer_read) {
        info.stage = info.stage.merge(.{ .all_transfer_bit = true });
        info.access = info.access.merge(.{ .transfer_read_bit = true });
    }
    if (uses.transfer_write) {
        info.stage = info.stage.merge(.{ .all_transfer_bit = true });
        info.access = info.access.merge(.{ .transfer_write_bit = true });
    }
    if (ray_tracing and uses.build_read) {
        info.stage = info.stage.merge(.{ .acceleration_structure_build_bit_khr = true });
        info.access = info.access.merge(.{ .acceleration_structure_read_bit_khr = true, .shader_read_bit = true });
    }
    if (ray_tracing and uses.build_write) {
        info.stage = info.stage.merge(.{ .acceleration_structure_build_bit_khr = true });
        info.access = info.access.merge(.{ .acceleration_structure_write_bit_khr = true });
    }
    if (uses.host_read) {
        info.stage = info.stage.merge(.{ .host_bit = true });
        info.access = info.access.merge(.{ .host_read_bit = true });
    }
    return info;
}

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
