//! Materials: their GPU records, samplers and custom shaders. Internal to the renderer.
const std = @import("std");
const rhi = @import("../../rhi/rhi.zig");
const gltf = @import("../../asset/gltf.zig");
const gpu = @import("../gpu.zig");
const api = @import("../api.zig");
const renderer_state = @import("../state.zig");
const render = @import("../renderer.zig");

const Renderer = render.Renderer;
const Model = api.Model;
const MaterialShader = api.MaterialShader;
const hdr_format = renderer_state.hdr_format;
const MaterialTextures = renderer_state.MaterialTextures;
const ModelEntry = renderer_state.ModelEntry;
const uvMatrix = renderer_state.uvMatrix;
const transformSlot = renderer_state.transformSlot;
const uvSetBit = renderer_state.uvSetBit;
const shade_reflective_targets = renderer_state.shade_reflective_targets;
const shaderCode = @import("pipelines.zig").shaderCode;

fn textureIndex(self: *Renderer, entry: *ModelEntry, reference: ?gltf.TextureRef) u32 {
    const ref = reference orelse return gpu.invalid_id;
    const texture = entry.textures[ref.image] orelse return gpu.invalid_id;
    return self.device.textureIndex(texture);
}

/// Shared material samplers; `anisotropic` for color and normal maps.
fn materialSampler(self: *Renderer, data: gltf.SamplerData, anisotropic: bool) !rhi.Sampler {
    const key = @as(usize, @intFromBool(anisotropic)) * 18 + @as(usize, @intFromBool(data.linear)) * 9 +
        @as(usize, @intFromEnum(data.repeat_u)) * 3 + @intFromEnum(data.repeat_v);
    if (self.material_samplers[key]) |sampler| return sampler;
    const filter: rhi.Filter = if (data.linear) .linear else .nearest;
    const sampler = try self.device.createSampler(.{
        .min_filter = .linear,
        .mag_filter = filter,
        .address_u = addressMode(data.repeat_u),
        .address_v = addressMode(data.repeat_v),
        .max_anisotropy = if (anisotropic) self.options.texture_anisotropy else self.options.data_texture_anisotropy,
    });
    self.material_samplers[key] = sampler;
    return sampler;
}

/// Registers a custom material. `spirv` is a fragment shader that defines
/// `CUSTOM_MATERIAL`, includes "shade.glsl" and defines
/// `customMaterial()`; see `examples/shaders/lava.frag`.
pub fn createMaterialShader(self: *Renderer, spirv: []const u8) !MaterialShader {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    for (self.material_shaders[1..], 1..) |*slot, index| {
        if (slot.* != null) continue;
        const plain = try self.device.createGraphicsPipeline(.{
            .name = "custom material",
            .vertex = shaderCode("fullscreen.vert.spv"),
            .fragment = spirv,
            .color_targets = &.{ .{ .format = hdr_format }, .{ .format = .rg16_float } },
            .cull = .none,
        });
        errdefer self.device.destroyPipeline(plain);
        slot.* = .{
            .plain = plain,
            .reflective = try self.device.createGraphicsPipeline(.{
                .name = "custom material (reflective)",
                .vertex = shaderCode("fullscreen.vert.spv"),
                .fragment = spirv,
                .color_targets = &shade_reflective_targets,
                .cull = .none,
            }),
        };
        return .{ .slot = @intCast(index) };
    }
    return error.TooManyMaterialShaders;
}

/// Materials still using the shader fall back to the standard material.
pub fn destroyMaterialShader(self: *Renderer, shader: MaterialShader) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (shader.slot == 0 or shader.slot >= self.material_shaders.len) return;
    if (self.material_shaders[shader.slot]) |pipelines| {
        self.device.destroyPipeline(pipelines.plain);
        self.device.destroyPipeline(pipelines.reflective);
    }
    self.material_shaders[shader.slot] = null;
}

/// Sets a loaded model's material shader and parameters. `material` null
/// applies to all materials; `shader` null restores the standard one. The
/// model must have finished loading.
pub fn setMaterialShader(self: *Renderer, model: Model, material: ?u32, shader: ?MaterialShader, params: [4]f32) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const entry = self.models.get(model) orelse return error.InvalidModel;
    if (entry.state != .ready) return error.ModelNotReady;
    const materials = entry.source.?.materials;
    if (material) |index| if (index >= materials.len) return error.InvalidMaterial;
    for (materials, 0..) |*item, index| {
        if (material) |only| if (only != index) continue;
        self.material_shader_users[if (item.shader < self.material_shaders.len) item.shader else 0] -= 1;
        item.shader = if (shader) |value| value.slot else 0;
        item.params = params;
        const encoded = try encodeMaterial(self, entry, item.*, index);
        self.material_shader_users[encoded.shader] += 1;
        try self.materials.write(self.device, entry.material_base + @as(u32, @intCast(index)), std.mem.asBytes(&encoded));
    }
}

/// Sets a model material's textures from images. `material` null applies
/// to all. Color images should be sRGB, data images linear. The images
/// must outlive the model's use of them.
pub fn setMaterialTextures(self: *Renderer, model: Model, material: ?u32, textures: MaterialTextures) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const entry = self.models.get(model) orelse return error.InvalidModel;
    const source = entry.source orelse return error.ModelNotReady;
    const count = source.materials.len;
    if (material) |index| if (index >= count) return error.InvalidMaterial;
    if (entry.material_images.len == 0) {
        entry.material_images = try self.gpa.alloc(MaterialTextures, count);
        @memset(entry.material_images, .{});
    }
    for (entry.material_images, 0..) |*images, index| {
        if (material) |only| if (only != index) continue;
        images.* = textures;
    }
    if (entry.state != .ready) return;
    for (source.materials, 0..) |item, index| {
        if (material) |only| if (only != index) continue;
        const encoded = try encodeMaterial(self, entry, item, index);
        try self.materials.write(self.device, entry.material_base + @as(u32, @intCast(index)), std.mem.asBytes(&encoded));
    }
}

pub fn encodeMaterial(self: *Renderer, entry: *ModelEntry, material: gltf.Material, index: usize) !gpu.Material {
    const device = self.device;
    const sampler_source = material.base_color_texture orelse material.normal_texture orelse
        material.metallic_roughness_texture orelse material.emissive_texture orelse material.occlusion_texture;
    var flags: u32 = 0;
    if (material.alpha_mode == .mask) flags |= gpu.material_alpha_test;
    if (material.alpha_mode == .blend or material.transmission > 0) flags |= gpu.material_blend;
    if (material.double_sided) flags |= gpu.material_double_sided;
    if (material.specular_glossiness) flags |= gpu.material_specular_glossiness;
    var encoded: gpu.Material = .{
        .base_color = material.base_color,
        .emissive = material.emissive,
        .metallic = material.metallic,
        .roughness = material.roughness,
        .normal_scale = material.normal_scale,
        .occlusion_strength = material.occlusion_strength,
        .alpha_cutoff = material.alpha_cutoff,
        .base_color_texture = textureIndex(self, entry, material.base_color_texture),
        .normal_texture = textureIndex(self, entry, material.normal_texture),
        .metallic_roughness_texture = textureIndex(self, entry, material.metallic_roughness_texture),
        .occlusion_texture = textureIndex(self, entry, material.occlusion_texture),
        .emissive_texture = textureIndex(self, entry, material.emissive_texture),
        .clearcoat_texture = textureIndex(self, entry, material.clearcoat_texture),
        .clearcoat_roughness_texture = textureIndex(self, entry, material.clearcoat_roughness_texture),
        .clearcoat_normal_texture = textureIndex(self, entry, material.clearcoat_normal_texture),
        .clearcoat_normal_scale = material.clearcoat_normal_scale,
        .sheen_color_texture = textureIndex(self, entry, material.sheen_color_texture),
        .sheen_roughness_texture = textureIndex(self, entry, material.sheen_roughness_texture),
        .uv_sets = uvSetBit(material.base_color_texture, 0) | uvSetBit(material.normal_texture, 1) | uvSetBit(material.metallic_roughness_texture, 2) | uvSetBit(material.occlusion_texture, 3) | uvSetBit(material.emissive_texture, 4) | uvSetBit(material.clearcoat_texture, 5) | uvSetBit(material.clearcoat_roughness_texture, 6) | uvSetBit(material.clearcoat_normal_texture, 7) | uvSetBit(material.sheen_color_texture, 8) | uvSetBit(material.sheen_roughness_texture, 9),
        .sampler_index = device.samplerIndex(try materialSampler(self, if (sampler_source) |ref| ref.sampler else .{}, true)),
        .detail_sampler = device.samplerIndex(try materialSampler(self, if (sampler_source) |ref| ref.sampler else .{}, false)),
        .flags = flags,
        .shader = if (material.specular_glossiness) 0 else if (material.shader < self.material_shaders.len) material.shader else 0,
        .params = if (material.specular_glossiness) .{ material.specular[0], material.specular[1], material.specular[2], 0 } else material.params,
        .uv_transform = uvMatrix(material.uv_scale, material.uv_rotation),
        .texture_transforms = transformSlot(entry, index),
        .sway = material.sway,
        .uv_offset = material.uv_offset,
        .clearcoat = std.math.clamp(material.clearcoat, 0, 1),
        .clearcoat_roughness = std.math.clamp(material.clearcoat_roughness, 0, 1),
        .transmission = std.math.clamp(material.transmission, 0, 1),
        .ior = @max(material.ior, 1),
        .thickness = @max(material.thickness, 0),
        .sheen_color = material.sheen_color,
        .sheen_roughness = std.math.clamp(material.sheen_roughness, 0.07, 1),
        .anisotropy = std.math.clamp(material.anisotropy, 0, 1),
        .anisotropy_rotation = material.anisotropy_rotation,
        .subsurface = std.math.clamp(material.subsurface, 0, 1),
    };
    if (index < entry.material_images.len) {
        const images = entry.material_images[index];
        inline for (.{
            .{ "base_color", "base_color_texture" },
            .{ "normal", "normal_texture" },
            .{ "metallic_roughness", "metallic_roughness_texture" },
            .{ "occlusion", "occlusion_texture" },
            .{ "emissive", "emissive_texture" },
            .{ "clearcoat", "clearcoat_texture" },
            .{ "clearcoat_roughness", "clearcoat_roughness_texture" },
            .{ "clearcoat_normal", "clearcoat_normal_texture" },
            .{ "sheen_color", "sheen_color_texture" },
            .{ "sheen_roughness", "sheen_roughness_texture" },
        }) |pair| {
            if (@field(images, pair[0])) |image| @field(encoded, pair[1]) = image.index;
        }
    }
    return encoded;
}

fn addressMode(mode: gltf.SamplerData.AddressMode) rhi.AddressMode {
    return switch (mode) {
        .repeat => .repeat,
        .mirrored_repeat => .mirrored_repeat,
        .clamp_to_edge => .clamp_to_edge,
    };
}
