//! How lit surfaces are shaded.
const pipelines_module = @import("../renderer/pipelines.zig");
const shade_pass_push = @import("../shaders/push/shade.zig");
const subsurface_push = @import("../shaders/push/subsurface.zig");
const shading_rate_push = @import("../shaders/push/shading_rate.zig");
const scene_pass = @import("../scene_pass.zig");
const filled = @import("../api.zig").filled;
const reflections_feature = @import("reflections.zig");
const render = @import("../renderer.zig");
const rhi = @import("../../rhi/rhi.zig");
const math = @import("../../math.zig");
const gpu = @import("../gpu.zig");
const std = @import("std");
const lights_feature = @import("lights.zig");
const global_illumination_feature = @import("global_illumination.zig");
const api = @import("../api.zig");
const features = @import("../core/features.zig");
const resolution_feature = @import("resolution.zig");

const Lighting = scene_pass.Lighting;
const ReflectionTargets = render.ReflectionTargets;
const shadeVariantDesc = render.shadeVariantDesc;
const ProbeList = scene_pass.ProbeList;
const ScenePass = scene_pass.ScenePass;
const Renderer = render.Renderer;
const ViewContext = features.ViewContext;

pub const name = "shading";

pub const Settings = struct {
    /// Shade once per 2x2 pixels where last frame's picture was flat and
    /// smooth. Needs GPU shading-rate support and `Settings.resolution.temporal_antialiasing`.
    variable_rate: bool = false,
    /// Relative color variation a 16-pixel tile may have and still be shaded
    /// coarsely.
    variable_rate_contrast: f32 = 0.06,
    /// Widen highlights where normals vary faster than pixels can show.
    specular_antialiasing: bool = true,
    /// Haze per world unit fading distant opaque surfaces into the sky (0.0005
    /// shows at a kilometre); 0 for none. Needs an environment.
    aerial_perspective: f32 = 0,
    /// Light under the skin spreads across the screen from where it lands
    /// (separable subsurface scattering) for materials with `subsurface`, in
    /// place of the softened lighting they get alone.
    subsurface_scattering: bool = false,
    /// World units light travels beneath a surface of `subsurface` 1.
    subsurface_radius: f32 = 0.02,
    /// `.atmosphere` is air lit by sun and sky, scattering blue more than red;
    /// `.sky` fades to the sky behind.
    aerial_model: api.AerialModel = .atmosphere,
};

pub fn preset(quality: api.Quality) Settings {
    _ = quality;
    return .{};
}

pub fn resolve(setting: *Settings, r: *features.Resolve) void {
    if (!setting.variable_rate) return;
    if (r.caps.shading_rate_tile == 0) {
        setting.variable_rate = false;
        r.downgrade("shading.variable_rate", "on", "off", .unsupported);
    } else if (!r.temporal_antialiasing) {
        setting.variable_rate = false;
        r.downgrade("shading.variable_rate", "on", "off", .needs_temporal_antialiasing);
    }
}

/// Adds the pass that lights every visible surface.
/// Lists the reflection probes and decals shading reads.
pub fn prepare(ctx: *ViewContext) !void {
    const p = ctx.scene orelse return;
    const probes = try reflectionProbeList(ctx.renderer, p);
    ctx.constants.shading.probes = probes.address;
    ctx.constants.shading.probe_count = probes.count;
    ctx.constants.shading.decals = try writeDecals(ctx.renderer, p);
    ctx.constants.shading.decal_count = @intCast(p.scene.decals.items.len);
}

pub fn declare(ctx: *ViewContext) !void {
    const p = ctx.scene orelse return;
    const own = p.settings.shading;
    ctx.constants.shading.specular_aa = @intFromBool(own.specular_antialiasing);
    ctx.constants.shading.screen_subsurface = @intFromBool(own.subsurface_scattering and !p.debugging);
    ctx.constants.shading.aerial = if (own.aerial_model == .sky) -@max(own.aerial_perspective, 0) else @max(own.aerial_perspective, 0);
    const g = ctx.graph;
    const read_slots = [_]features.graph.Slot{ .ambient_occlusion, .occluder_light, .diffuse_gi };
    const reads = try ctx.make([read_slots.len]features.Target);
    var read_count: usize = 0;
    for (read_slots) |slot| if (g.slot(slot)) |target| {
        reads[read_count] = target;
        read_count += 1;
    };
    const writes = try ctx.make([2]features.Target);
    var write_count: usize = 0;
    for ([_]features.graph.Slot{ .reflection_weight, .reflection_surface }) |slot| if (g.slot(slot)) |target| {
        writes[write_count] = target;
        write_count += 1;
    };
    const light_reads = try lights_feature.reads(ctx);
    try g.add(.{ .name = "shading", .stage = .surfaces, .reads = reads[0..read_count], .writes = writes[0..write_count], .always = true, .scope = false, .buffers = &light_reads }, ctx, shade);
}

fn shade(ctx: *ViewContext) !void {
    const p = ctx.scene.?;
    const c = p.shared;
    const g = ctx.graph;
    const texture = struct {
        fn of(graph: *features.Graph, slot: features.graph.Slot) ?rhi.Texture {
            return graph.texture(graph.slot(slot) orelse return null);
        }
    }.of;
    const weight = texture(g, .reflection_weight);
    const surface = texture(g, .reflection_surface);
    try shadeScene(ctx.renderer, p, c.lighting, ctx.constants, c.shadow_tlas, c.colored_shadows, texture(g, .diffuse_gi), if (weight != null and surface != null) .{ .weight = weight.?, .surface = surface.? } else null, .{
        .occlusion = if (g.slot(.ambient_occlusion)) |target| g.texture(target) else null,
        .light = if (g.slot(.occluder_light)) |target| g.texture(target) else null,
    });
}

/// The scene's reflection probes that are captured; one being captured now is
/// left out.
pub fn reflectionProbeList(renderer: *Renderer, p: *const ScenePass) !ProbeList {
    const device = renderer.device;
    const arena = p.arena;
    const scene = p.scene;
    var probe_list: u64 = 0;
    var probe_count: u32 = 0;
    if (scene.probes.items.len != 0) {
        const list = try arena.alloc(device, gpu.ReflectionProbe, scene.probes.items.len);
        for (scene.probes.items) |probe_handle| {
            const probe = renderer.reflection_probes.internal.table.get(probe_handle) orelse continue;
            if (!probe.captured or probe.capturing) continue;
            list.items[probe_count] = .{
                .center = probe.desc.position,
                .specular = device.textureIndex(probe.cubes.specular.?),
                .extent = .{ @max(probe.desc.extent[0], 1e-3), @max(probe.desc.extent[1], 1e-3), @max(probe.desc.extent[2], 1e-3) },
                .fade = std.math.clamp(probe.desc.fade, 1e-3, 1),
                .intensity = @max(probe.desc.intensity, 0),
                .irradiance = device.textureIndex(probe.cubes.irradiance.?),
            };
            probe_count += 1;
        }
        probe_list = list.address;
    }
    return .{ .address = probe_list, .count = probe_count };
}

/// Uploads the scene's decals and returns the address.
pub fn writeDecals(renderer: *Renderer, p: *const ScenePass) !u64 {
    const device = renderer.device;
    const arena = p.arena;
    const scene = p.scene;
    const decals = try arena.alloc(device, gpu.Decal, scene.decals.items.len);
    for (scene.decals.items, decals.items) |decal, *out| out.* = .{
        .world_to_decal = math.inverse(decal.transform),
        .color = decal.color,
        .image = renderer.images.indexOf(decal.image),
        .angle_fade = decal.angle_fade,
        .emissive = decal.emissive,
        .roughness = decal.roughness orelse -1,
        .normal_image = renderer.images.indexOf(decal.normal_image),
        .normal_strength = decal.normal_strength,
        .bounds = .{ decal.transform[12], decal.transform[13], decal.transform[14], 0.5 * @sqrt(math.dot(decal.transform[0..3].*, decal.transform[0..3].*) + math.dot(decal.transform[4..7].*, decal.transform[4..7].*) + math.dot(decal.transform[8..11].*, decal.transform[8..11].*)) },
    };
    return decals.address;
}

/// The shading pipeline for a view: the exact feature set if built, else a
/// ready superset while the exact one compiles on a worker thread.
pub fn shadePipeline(renderer: *Renderer, reflective: bool, needed: u32) !rhi.Pipeline {
    const device = renderer.device;
    const full_desc = if (reflective) fullShadeReflectivePipeline(device) else fullShadePipeline(device);
    if (!renderer.options.shader_variants) return renderer.internal.pipelines.get(full_desc);
    const exact = [1]u32{needed};
    const exact_desc = pipelines_module.Desc{ .graphics = shadeVariantDesc(device, reflective, &exact) };
    if (renderer.internal.pipelines.peek(exact_desc)) |ready| return ready;
    if (renderer.options.deterministic) return renderer.internal.pipelines.get(exact_desc);
    var known = false;
    var stand_in: ?rhi.Pipeline = null;
    for (renderer.internal.shade_variants.items) |variant| {
        if (variant.reflective != reflective) continue;
        if (variant.features == needed) known = true;
        if (variant.features & needed != needed or stand_in != null) continue;
        const constants = [1]u32{variant.features};
        stand_in = renderer.internal.pipelines.peek(.{ .graphics = shadeVariantDesc(device, reflective, &constants) });
    }
    if (!known) try renderer.internal.shade_variants.append(renderer.internal.gpa, .{ .reflective = reflective, .features = needed });
    if (stand_in == null and renderer.internal.pipelines.peek(full_desc) == null) return renderer.internal.pipelines.get(exact_desc);
    if (try renderer.internal.pipelines.getLater(exact_desc)) |ready| return ready;
    return stand_in orelse renderer.internal.pipelines.get(full_desc);
}

/// The view's shading rate tiles; null where the GPU has no such thing.
fn shadingRates(renderer: *Renderer, p: *const ScenePass) !?rhi.Texture {
    const tile = renderer.device.caps.shading_rate_tile;
    if (tile == 0) return null;
    return try p.keepAs(renderer, .{
        .name = "shading rate",
        .width = (p.width + tile - 1) / tile,
        .height = (p.height + tile - 1) / tile,
        .format = .r8_uint,
        .usage = .{ .color_attachment = true, .shading_rate = true },
    });
}

/// What ambient occlusion found for shading to use.
pub const Occluded = struct { occlusion: ?rhi.Texture, light: ?rhi.Texture };

/// Material evaluation and lighting in one pass from the visibility buffer.
/// What shading writes for the reflection technique.
pub const ReflectionOutputs = struct { weight: rhi.Texture, surface: rhi.Texture };

/// Writes `reflections` too, when the view has reflections.
pub fn shadeScene(renderer: *Renderer, p: *const ScenePass, lighting: *const Lighting, constants: *const gpu.FrameConstants, shadow_tlas: u64, colored_shadows: bool, gathered_gi: ?rhi.Texture, reflections: ?ReflectionOutputs, occluded: Occluded) !void {
    const device = renderer.device;
    const cmd = p.cmd;
    const settings = p.settings;
    const scene = p.scene;
    const view_data = p.view_data;
    const view = p.view;
    const debugging = p.debugging;
    const frame_address = p.frame_address;
    var shading_rate: ?rhi.Texture = null;
    if (settings.shading.variable_rate and settings.resolution.temporal_antialiasing and view.history_valid and !debugging) if (try shadingRates(renderer, p)) |rates| {
        cmd.beginScope("shading rate");
        try cmd.beginRendering(.{ .color = &.{.{ .texture = rates, .load = .discard }} });
        cmd.bindPipeline(try renderer.internal.pipelines.of(shadingRatePipeline));
        cmd.pushConstants(shading_rate_push.Push{
            .frame = frame_address,
            .history_texture = device.textureIndex((try resolution_feature.history(renderer, view_data))[@intCast((view_data.frames + 1) & 1)]),
            .depth_texture = device.textureIndex(view.depth),
            .tile = device.caps.shading_rate_tile,
            .contrast = @max(settings.shading.variable_rate_contrast, 0),
        });
        cmd.drawFullscreen();
        cmd.endRendering();
        cmd.endScope();
        shading_rate = rates;
    };
    cmd.beginScope("shading");
    if (reflections) |targets| {
        try cmd.beginRendering(.{ .color = &.{
            .{ .texture = view.hdr, .load = .discard },
            .{ .texture = view.motion, .load = .discard },
            .{ .texture = targets.weight, .load = .discard },
            .{ .texture = targets.surface, .load = .discard },
        }, .shading_rate = shading_rate });
    } else {
        try cmd.beginRendering(.{ .color = &.{
            .{ .texture = view.hdr, .load = .discard },
            .{ .texture = view.motion, .load = .discard },
        }, .shading_rate = shading_rate });
    }
    const ShadePush = shade_pass_push.Push;
    var shade_push = ShadePush{
        .frame = frame_address,
        .visibility_texture = device.textureIndex(view.visibility),
        .ao_texture = if (occluded.occlusion) |texture| device.textureIndex(texture) else gpu.invalid_id,
        .bounce_texture = if (occluded.light) |texture| device.textureIndex(texture) else gpu.invalid_id,
        .bounce_strength = if (settings.ambient_occlusion) |occlusion| occlusion.bounce else 0,
        .debug_view = @intFromEnum(settings.debug_view),
        .gi_texture = if (gathered_gi) |texture| device.textureIndex(texture) else gpu.invalid_id,
        .material_shader = 0,
        .shadow_history = if (filled(settings.shadows).light_filter and settings.resolution.temporal_antialiasing and view.history_valid and !debugging)
            device.textureIndex((try resolution_feature.history(renderer, view_data))[@intCast((view_data.frames + 1) & 1)])
        else
            gpu.invalid_id,
    };
    if (shade_push.shadow_history != gpu.invalid_id) shade_push.shadow_depth = device.textureIndex(view.previous_depth);
    for (renderer.materials.internal.shaders, renderer.materials.internal.shader_users, 0..) |shader, users, slot| {
        if (shader != null and users != 0) shade_push.material_shader |= @as(u32, 1) << @intCast(slot);
    }
    const custom_shaders = shade_push.material_shader;
    var shade_features: u32 = 0;
    if (lighting.light_count != 0) {
        shade_features |= gpu.shade_features.local_lights;
        if (shadow_tlas != 0) shade_features |= gpu.shade_features.traced_light_shadows;
        for (scene.lights.items) |light| if (light.source_radius > 0) {
            shade_features |= gpu.shade_features.sized_lights;
            break;
        };
    }
    if (constants.fluids.shadows != 0) shade_features |= gpu.shade_features.fluid_shadows;
    if (constants.clouds.shadows != 0) shade_features |= gpu.shade_features.cloud_shadows;
    if (scene.decals.items.len != 0) shade_features |= gpu.shade_features.decals;
    if (renderer.internal.texture_transform_users != 0) shade_features |= gpu.shade_features.texture_transforms;
    if (colored_shadows) shade_features |= gpu.shade_features.colored_shadows;
    if (global_illumination_feature.probes(settings.global_illumination).probe_relocation) shade_features |= gpu.shade_features.gi_relocation;
    if (settings.shading.aerial_perspective > 0) shade_features |= gpu.shade_features.aerial;
    cmd.bindPipeline(try shadePipeline(renderer, reflections != null, shade_features));
    cmd.pushConstants(shade_push);
    cmd.drawFullscreen();
    for (renderer.materials.internal.shaders, 0..) |shader, slot| {
        if ((custom_shaders >> @intCast(slot)) & 1 == 0) continue;
        shade_push.material_shader = @intCast(slot);
        cmd.bindPipeline(if (reflections != null) shader.?.reflective else shader.?.plain);
        cmd.pushConstants(shade_push);
        cmd.drawFullscreen();
    }
    cmd.endRendering();
    if (settings.shading.subsurface_scattering and !debugging) try scatterBeneath(renderer, p, shade_push);
    cmd.endScope();
}

/// `Settings.shading.subsurface_scattering`: the diffuse light of subsurface
/// pixels, blurred across and then down the screen, added to the picture in
/// place of their own.
fn scatterBeneath(renderer: *Renderer, p: *const ScenePass, shade_push: shade_pass_push.Push) !void {
    const device = renderer.device;
    const cmd = p.cmd;
    const view = p.view;
    const light = try p.keep(renderer, "subsurface light", p.width, p.height, render.hdr_format);
    const across = try p.keep(renderer, "subsurface across", p.width, p.height, render.hdr_format);
    var push = shade_push;
    push.material_shader = 0;
    try cmd.beginRendering(.{ .color = &.{
        .{ .texture = light, .load = .clear, .clear = .{ 0, 0, 0, 0 } },
        .{ .texture = view.motion, .load = .load },
    } });
    cmd.bindPipeline(try renderer.internal.pipelines.of(subsurfaceShadePipeline));
    cmd.pushConstants(push);
    cmd.drawFullscreen();
    cmd.endRendering();
    const radius = @max(p.settings.shading.subsurface_radius, 0);
    try cmd.beginRendering(.{ .color = &.{.{ .texture = across, .load = .discard }} });
    cmd.bindPipeline(try renderer.internal.pipelines.of(subsurfaceBlurPipeline));
    cmd.pushConstants(subsurface_push.BlurPush{ .frame = p.frame_address, .source = device.textureIndex(light), .original = device.textureIndex(light), .depth = device.textureIndex(view.depth), .last = 0, .direction = .{ 1, 0 }, .radius = radius });
    cmd.drawFullscreen();
    cmd.endRendering();
    try cmd.beginRendering(.{ .color = &.{.{ .texture = view.hdr, .load = .load }} });
    cmd.bindPipeline(try renderer.internal.pipelines.of(subsurfaceAddPipeline));
    cmd.pushConstants(subsurface_push.BlurPush{ .frame = p.frame_address, .source = device.textureIndex(across), .original = device.textureIndex(light), .depth = device.textureIndex(view.depth), .last = 1, .direction = .{ 0, 1 }, .radius = radius });
    cmd.drawFullscreen();
    cmd.endRendering();
}

fn subsurfaceShadePipeline(device: *rhi.Device) pipelines_module.Desc {
    return pipelines_module.pass("subsurface light", if (device.caps.ray_tracing) pipelines_module.shaderCode("shade_rt_subsurface.frag.spv") else pipelines_module.shaderCode("shade_subsurface.frag.spv"), &pipelines_module.shade_plain_targets);
}

fn subsurfaceBlurPipeline(_: *rhi.Device) pipelines_module.Desc {
    return pipelines_module.pass("subsurface blur", pipelines_module.shaderCode("subsurface_blur.frag.spv"), &.{.{ .format = render.hdr_format }});
}

fn subsurfaceAddPipeline(_: *rhi.Device) pipelines_module.Desc {
    return pipelines_module.pass("subsurface add", pipelines_module.shaderCode("subsurface_blur.frag.spv"), &.{.{ .format = render.hdr_format, .blend = .additive }});
}

fn shadingRatePipeline(_: *rhi.Device) pipelines_module.Desc {
    return pipelines_module.pass("shading rate", pipelines_module.shaderCode("shading_rate.frag.spv"), &.{.{ .format = .r8_uint }});
}

fn fullShadePipeline(device: *rhi.Device) pipelines_module.Desc {
    return pipelines_module.pass("shading", if (device.caps.ray_tracing) pipelines_module.shaderCode("shade_rt_plain.frag.spv") else pipelines_module.shaderCode("shade_plain.frag.spv"), &pipelines_module.shade_plain_targets);
}

fn fullShadeReflectivePipeline(device: *rhi.Device) pipelines_module.Desc {
    return pipelines_module.pass("shading (reflective)", if (device.caps.ray_tracing) pipelines_module.shaderCode("shade_rt.frag.spv") else pipelines_module.shaderCode("shade.frag.spv"), &pipelines_module.shade_reflective_targets);
}
