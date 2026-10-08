//! Graphics and compute pipelines and their shader modules. Internal to the device.
const std = @import("std");
const vk = @import("vulkan");
const types = @import("../types.zig");
const device_module = @import("../device.zig");

const Device = device_module.Device;
const PipelineResource = device_module.PipelineResource;
const retire = @import("objects.zig").retire;
const setName = @import("objects.zig").setName;
const vkCompareOp = @import("textures.zig").vkCompareOp;
const vkFormat = device_module.vkFormat;

/// `compileGraphicsPipeline` followed by `adoptPipeline`.
pub fn createGraphicsPipeline(self: *Device, desc: types.GraphicsPipelineDesc) !types.Pipeline {
    const compiled = try self.compileGraphicsPipeline(self.gpa, desc);
    return self.adoptPipeline(compiled, desc.name);
}

/// Compiled by `compileGraphicsPipeline`, not yet adopted.
pub const CompiledPipeline = struct { handle: vk.Pipeline };

/// Registers a compiled pipeline. Render thread only.
pub fn adoptPipeline(self: *Device, compiled: CompiledPipeline, label: [:0]const u8) !types.Pipeline {
    errdefer self.vkd.destroyPipeline(compiled.handle, null);
    setName(self, .pipeline, @intFromEnum(compiled.handle), label);
    return try self.pipelines.insert(.{ .handle = compiled.handle, .bind_point = .graphics });
}

/// Frees a compiled pipeline that will not be adopted.
pub fn discardPipeline(self: *const Device, compiled: CompiledPipeline) void {
    self.vkd.destroyPipeline(compiled.handle, null);
}

/// Compiles without registering. May be called from any thread, also
/// during rendering; `gpa` must be safe to use there. At most 16 shader
/// constants, 16 vertex attributes and 8 color targets.
pub fn compileGraphicsPipeline(self: *const Device, gpa: std.mem.Allocator, desc: types.GraphicsPipelineDesc) !CompiledPipeline {
    const vertex = if (desc.mesh == null) try shaderModule(self, gpa, desc.vertex) else .null_handle;
    defer if (vertex != .null_handle) self.vkd.destroyShaderModule(vertex, null);
    const mesh = if (desc.mesh) |bytes| try shaderModule(self, gpa, bytes) else .null_handle;
    defer if (mesh != .null_handle) self.vkd.destroyShaderModule(mesh, null);
    const task = if (desc.task) |bytes| try shaderModule(self, gpa, bytes) else .null_handle;
    defer if (task != .null_handle) self.vkd.destroyShaderModule(task, null);
    const fragment = if (desc.fragment) |bytes| try shaderModule(self, gpa, bytes) else .null_handle;
    defer if (fragment != .null_handle) self.vkd.destroyShaderModule(fragment, null);
    var constant_entries: [16]vk.SpecializationMapEntry = undefined;
    if (desc.fragment_constants.len > constant_entries.len) return error.TooManyShaderConstants;
    for (desc.fragment_constants, 0..) |_, index| constant_entries[index] = .{
        .constant_id = @intCast(index),
        .offset = @intCast(index * @sizeOf(u32)),
        .size = @sizeOf(u32),
    };
    const constants = vk.SpecializationInfo{
        .map_entry_count = @intCast(desc.fragment_constants.len),
        .p_map_entries = &constant_entries,
        .data_size = desc.fragment_constants.len * @sizeOf(u32),
        .p_data = @ptrCast(desc.fragment_constants.ptr),
    };
    var stages: [3]vk.PipelineShaderStageCreateInfo = undefined;
    var geometry_stages: u32 = 0;
    if (desc.mesh == null) {
        stages[0] = .{ .stage = .{ .vertex_bit = true }, .module = vertex, .p_name = "main" };
        geometry_stages = 1;
    } else {
        if (desc.task != null) {
            stages[0] = .{ .stage = .{ .task_bit_ext = true }, .module = task, .p_name = "main" };
            geometry_stages = 1;
        }
        stages[geometry_stages] = .{ .stage = .{ .mesh_bit_ext = true }, .module = mesh, .p_name = "main" };
        geometry_stages += 1;
    }
    stages[geometry_stages] = .{ .stage = .{ .fragment_bit = true }, .module = fragment, .p_name = "main", .p_specialization_info = if (desc.fragment_constants.len != 0) &constants else null };

    var attributes: [16]vk.VertexInputAttributeDescription = undefined;
    var binding = vk.VertexInputBindingDescription{ .binding = 0, .stride = 0, .input_rate = .vertex };
    var attribute_count: u32 = 0;
    if (desc.vertex_layout) |layout| {
        if (layout.attributes.len > attributes.len) return error.TooManyVertexAttributes;
        binding.stride = layout.stride;
        for (layout.attributes, 0..) |attribute, index| attributes[index] = .{
            .location = attribute.location,
            .binding = 0,
            .format = switch (attribute.format) {
                .float2 => .r32g32_sfloat,
                .float3 => .r32g32b32_sfloat,
                .float4 => .r32g32b32a32_sfloat,
                .unorm8x4 => .r8g8b8a8_unorm,
                .uint1 => .r32_uint,
            },
            .offset = attribute.offset,
        };
        attribute_count = @intCast(layout.attributes.len);
    }
    const vertex_input = vk.PipelineVertexInputStateCreateInfo{
        .vertex_binding_description_count = if (desc.vertex_layout != null) 1 else 0,
        .p_vertex_binding_descriptions = @ptrCast(&binding),
        .vertex_attribute_description_count = attribute_count,
        .p_vertex_attribute_descriptions = &attributes,
    };
    const assembly = vk.PipelineInputAssemblyStateCreateInfo{
        .topology = switch (desc.topology) {
            .triangle_list => .triangle_list,
            .line_list => .line_list,
        },
        .primitive_restart_enable = .false,
    };
    const viewport = vk.PipelineViewportStateCreateInfo{ .viewport_count = 1, .scissor_count = 1 };
    const depth_state = desc.depth orelse types.DepthState{ .@"test" = false, .write = false };
    const rasterization = vk.PipelineRasterizationStateCreateInfo{
        .depth_clamp_enable = if (depth_state.clamp) .true else .false,
        .rasterizer_discard_enable = .false,
        .polygon_mode = .fill,
        .cull_mode = switch (desc.cull) {
            .none => .{},
            .front => .{ .front_bit = true },
            .back => .{ .back_bit = true },
        },
        .front_face = .counter_clockwise,
        .depth_bias_enable = if (depth_state.bias != null) .true else .false,
        .depth_bias_constant_factor = if (depth_state.bias) |bias| bias.constant else 0,
        .depth_bias_clamp = 0,
        .depth_bias_slope_factor = if (depth_state.bias) |bias| bias.slope else 0,
        .line_width = 1,
    };
    const multisample = vk.PipelineMultisampleStateCreateInfo{
        .rasterization_samples = .{ .@"1_bit" = true },
        .sample_shading_enable = .false,
        .min_sample_shading = 0,
        .alpha_to_coverage_enable = .false,
        .alpha_to_one_enable = .false,
    };
    const stencil = vk.StencilOpState{
        .fail_op = .keep,
        .pass_op = .keep,
        .depth_fail_op = .keep,
        .compare_op = .always,
        .compare_mask = 0,
        .write_mask = 0,
        .reference = 0,
    };
    const depth_stencil = vk.PipelineDepthStencilStateCreateInfo{
        .depth_test_enable = if (desc.depth != null and depth_state.@"test") .true else .false,
        .depth_write_enable = if (desc.depth != null and depth_state.write) .true else .false,
        .depth_compare_op = vkCompareOp(depth_state.compare),
        .depth_bounds_test_enable = .false,
        .stencil_test_enable = .false,
        .front = stencil,
        .back = stencil,
        .min_depth_bounds = 0,
        .max_depth_bounds = 1,
    };
    var blend_attachments: [8]vk.PipelineColorBlendAttachmentState = undefined;
    var color_formats: [8]vk.Format = undefined;
    if (desc.color_targets.len > blend_attachments.len) return error.TooManyColorTargets;
    for (desc.color_targets, 0..) |target, index| {
        color_formats[index] = vkFormat(target.format);
        blend_attachments[index] = blendState(target.blend);
    }
    const blend = vk.PipelineColorBlendStateCreateInfo{
        .logic_op_enable = .false,
        .logic_op = .copy,
        .attachment_count = @intCast(desc.color_targets.len),
        .p_attachments = &blend_attachments,
        .blend_constants = .{ 0, 0, 0, 0 },
    };
    const dynamic_states = [_]vk.DynamicState{ .viewport, .scissor };
    const dynamic = vk.PipelineDynamicStateCreateInfo{
        .dynamic_state_count = dynamic_states.len,
        .p_dynamic_states = &dynamic_states,
    };
    const rendering = vk.PipelineRenderingCreateInfo{
        .view_mask = 0,
        .color_attachment_count = @intCast(desc.color_targets.len),
        .p_color_attachment_formats = &color_formats,
        .depth_attachment_format = if (desc.depth) |depth| vkFormat(depth.format) else .undefined,
        .stencil_attachment_format = .undefined,
    };
    const shading_rate = vk.PipelineFragmentShadingRateStateCreateInfoKHR{
        .p_next = &rendering,
        .fragment_size = .{ .width = 1, .height = 1 },
        .combiner_ops = .{ .keep_khr, .replace_khr },
    };
    var result: [1]vk.Pipeline = undefined;
    _ = try self.vkd.createGraphicsPipelines(self.pipeline_cache, &.{.{
        .p_next = if (self.shading_rate_tile != 0) @as(?*const anyopaque, &shading_rate) else @as(?*const anyopaque, &rendering),
        .flags = .{ .rendering_fragment_shading_rate_attachment_bit_khr = self.shading_rate_tile != 0 },
        .stage_count = if (desc.fragment != null) geometry_stages + 1 else geometry_stages,
        .p_stages = &stages,
        .p_vertex_input_state = &vertex_input,
        .p_input_assembly_state = &assembly,
        .p_viewport_state = &viewport,
        .p_rasterization_state = &rasterization,
        .p_multisample_state = &multisample,
        .p_depth_stencil_state = &depth_stencil,
        .p_color_blend_state = &blend,
        .p_dynamic_state = &dynamic,
        .layout = self.pipeline_layout,
        .subpass = 0,
        .base_pipeline_index = -1,
    }}, null, &result);
    return .{ .handle = result[0] };
}

/// Compiles on the calling thread and registers the pipeline.
pub fn createComputePipeline(self: *Device, desc: types.ComputePipelineDesc) !types.Pipeline {
    const module = try createShaderModule(self, desc.shader);
    defer self.vkd.destroyShaderModule(module, null);
    var result: [1]vk.Pipeline = undefined;
    _ = try self.vkd.createComputePipelines(self.pipeline_cache, &.{.{
        .stage = .{ .stage = .{ .compute_bit = true }, .module = module, .p_name = "main" },
        .layout = self.pipeline_layout,
        .base_pipeline_index = -1,
    }}, null, &result);
    errdefer self.vkd.destroyPipeline(result[0], null);
    setName(self, .pipeline, @intFromEnum(result[0]), desc.name);
    return try self.pipelines.insert(.{ .handle = result[0], .bind_point = .compute });
}

/// Deferred like `destroyBuffer`, so the frame that last draws with it
/// may destroy it.
pub fn destroyPipeline(self: *Device, pipeline: types.Pipeline) void {
    const resource = self.pipelines.remove(pipeline) orelse return;
    retire(self, .{ .pipeline = resource.handle });
}

/// Panics on a stale handle. The pointer is valid until a pipeline is
/// created or destroyed.
pub fn pipelineResource(self: *Device, pipeline: types.Pipeline) *PipelineResource {
    return self.pipelines.get(pipeline) orelse @panic("stale or invalid pipeline handle");
}

/// The shader stages push constants and the table of textures reach.
pub fn shaderStages(self: *const Device) vk.ShaderStageFlags {
    return .{ .vertex_bit = true, .fragment_bit = true, .compute_bit = true, .task_bit_ext = self.mesh_shaders, .mesh_bit_ext = self.mesh_shaders };
}

fn createShaderModule(self: *Device, bytes: []const u8) !vk.ShaderModule {
    return shaderModule(self, self.gpa, bytes);
}

fn shaderModule(self: *const Device, gpa: std.mem.Allocator, bytes: []const u8) !vk.ShaderModule {
    if (bytes.len == 0 or bytes.len % 4 != 0) return error.InvalidSpirv;
    const words = try gpa.alloc(u32, bytes.len / 4);
    defer gpa.free(words);
    @memcpy(std.mem.sliceAsBytes(words), bytes);
    return self.vkd.createShaderModule(&.{ .code_size = bytes.len, .p_code = words.ptr }, null);
}

pub fn persistPipelineCache(self: *Device) !void {
    const path = self.pipeline_cache_path orelse return;
    var size: usize = 0;
    _ = try self.vkd.getPipelineCacheData(self.pipeline_cache, &size, null);
    const data = try self.gpa.alloc(u8, size);
    defer self.gpa.free(data);
    _ = try self.vkd.getPipelineCacheData(self.pipeline_cache, &size, data.ptr);
    const file = try std.Io.Dir.cwd().createFile(self.io, path, .{});
    defer file.close(self.io);
    try file.writeStreamingAll(self.io, data[0..size]);
}

fn blendState(mode: types.BlendMode) vk.PipelineColorBlendAttachmentState {
    const write_all = vk.ColorComponentFlags{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true };
    return switch (mode) {
        .none => .{
            .blend_enable = .false,
            .src_color_blend_factor = .one,
            .dst_color_blend_factor = .zero,
            .color_blend_op = .add,
            .src_alpha_blend_factor = .one,
            .dst_alpha_blend_factor = .zero,
            .alpha_blend_op = .add,
            .color_write_mask = write_all,
        },
        .alpha => .{
            .blend_enable = .true,
            .src_color_blend_factor = .src_alpha,
            .dst_color_blend_factor = .one_minus_src_alpha,
            .color_blend_op = .add,
            .src_alpha_blend_factor = .one,
            .dst_alpha_blend_factor = .one_minus_src_alpha,
            .alpha_blend_op = .add,
            .color_write_mask = write_all,
        },
        .premultiplied => .{
            .blend_enable = .true,
            .src_color_blend_factor = .one,
            .dst_color_blend_factor = .one_minus_src_alpha,
            .color_blend_op = .add,
            .src_alpha_blend_factor = .one,
            .dst_alpha_blend_factor = .one_minus_src_alpha,
            .alpha_blend_op = .add,
            .color_write_mask = write_all,
        },
        .tint => .{
            .blend_enable = .true,
            .src_color_blend_factor = .dst_color,
            .dst_color_blend_factor = .zero,
            .color_blend_op = .add,
            .src_alpha_blend_factor = .one,
            .dst_alpha_blend_factor = .one,
            .alpha_blend_op = .min,
            .color_write_mask = write_all,
        },
        .minimum, .maximum => .{
            .blend_enable = .true,
            .src_color_blend_factor = .one,
            .dst_color_blend_factor = .one,
            .color_blend_op = if (mode == .minimum) .min else .max,
            .src_alpha_blend_factor = .one,
            .dst_alpha_blend_factor = .one,
            .alpha_blend_op = if (mode == .minimum) .min else .max,
            .color_write_mask = write_all,
        },
        .under => .{
            .blend_enable = .true,
            .src_color_blend_factor = .one_minus_dst_alpha,
            .dst_color_blend_factor = .one,
            .color_blend_op = .add,
            .src_alpha_blend_factor = .one_minus_dst_alpha,
            .dst_alpha_blend_factor = .one,
            .alpha_blend_op = .add,
            .color_write_mask = write_all,
        },
        .revealage => .{
            .blend_enable = .true,
            .src_color_blend_factor = .zero,
            .dst_color_blend_factor = .one_minus_src_color,
            .color_blend_op = .add,
            .src_alpha_blend_factor = .zero,
            .dst_alpha_blend_factor = .one_minus_src_alpha,
            .alpha_blend_op = .add,
            .color_write_mask = write_all,
        },
        .additive => .{
            .blend_enable = .true,
            .src_color_blend_factor = .one,
            .dst_color_blend_factor = .one,
            .color_blend_op = .add,
            .src_alpha_blend_factor = .one,
            .dst_alpha_blend_factor = .one,
            .alpha_blend_op = .add,
            .color_write_mask = write_all,
        },
    };
}
