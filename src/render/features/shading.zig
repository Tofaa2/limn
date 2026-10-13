//! How lit surfaces are shaded.
const scene_pass = @import("../scene_pass.zig");
const filled = @import("../api.zig").filled;
const reflections_feature = @import("reflections.zig");
const render = @import("../renderer.zig");
const rhi = @import("../../rhi/rhi.zig");
const math = @import("../../math.zig");
const gpu = @import("../gpu.zig");
const std = @import("std");
const global_illumination_feature = @import("global_illumination.zig");
const api = @import("../api.zig");
const features = @import("../core/features.zig");

const Lighting = scene_pass.Lighting;
const ReflectionTargets = render.ReflectionTargets;
const runShadeVariantJob = render.runShadeVariantJob;
const shadeVariantDesc = render.shadeVariantDesc;
const ShadeVariantJob = render.ShadeVariantJob;
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
pub fn declare(ctx: *ViewContext) !void {
    const p = ctx.scene orelse return;
    const own = p.settings.shading;
    if (own.specular_antialiasing) ctx.constants.flags |= gpu.frame_flags.specular_aa;
    ctx.constants.aerial = if (own.aerial_model == .sky) -@max(own.aerial_perspective, 0) else @max(own.aerial_perspective, 0);
    const g = ctx.graph;
    var reads: [2]features.Target = undefined;
    var count: usize = 0;
    for ([_]features.graph.Slot{ .ambient_occlusion, .occluder_light }) |slot| if (g.slot(slot)) |target| {
        reads[count] = target;
        count += 1;
    };
    try g.add(.{ .name = "shading", .stage = .surfaces, .reads = reads[0..count], .always = true, .scope = false }, ctx, shade);
}

fn shade(ctx: *ViewContext) !void {
    const p = ctx.scene.?;
    const c = p.shared;
    const g = ctx.graph;
    c.reflections = try shadeScene(ctx.renderer, p, c.lighting, ctx.constants.flags, c.shadow_tlas, c.colored_shadows, c.gathered_gi, .{
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
            const probe = renderer.probes.table.get(probe_handle) orelse continue;
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
        .image = if (decal.image) |image| image.index else gpu.invalid_id,
        .angle_fade = decal.angle_fade,
        .emissive = decal.emissive,
        .roughness = decal.roughness orelse -1,
        .normal_image = if (decal.normal_image) |image| image.index else gpu.invalid_id,
        .normal_strength = decal.normal_strength,
        .bounds = .{ decal.transform[12], decal.transform[13], decal.transform[14], 0.5 * @sqrt(math.dot(decal.transform[0..3].*, decal.transform[0..3].*) + math.dot(decal.transform[4..7].*, decal.transform[4..7].*) + math.dot(decal.transform[8..11].*, decal.transform[8..11].*)) },
    };
    return decals.address;
}

/// The shading pipeline for a view: the exact feature set if built, else a
/// ready superset while the exact one compiles on a worker thread.
pub fn shadePipeline(renderer: *Renderer, reflective: bool, needed: u32) !rhi.Pipeline {
    const full_id: render.PipelineId = if (reflective) .shade_reflective else .shade;
    const full = renderer.pipelines.peek(full_id);
    if (!renderer.options.shader_variants) return renderer.pipelines.get(full_id);
    var requested = false;
    var stand_in: ?rhi.Pipeline = null;
    for (renderer.shade_variants.items) |*variant| {
        if (variant.reflective != reflective) continue;
        if (variant.job) |job| if (job.done.load(.acquire)) {
            job.group.cancel(job.io);
            if (job.compiled) |compiled| {
                variant.pipeline = renderer.device.adoptPipeline(compiled, "shading (variant)") catch null;
            } else if (job.failure) |err| std.log.warn("shading variant did not compile: {}", .{err});
            renderer.gpa.destroy(job);
            variant.job = null;
        };
        if (variant.features == needed) {
            requested = true;
            if (variant.pipeline) |ready| return ready;
        } else if (variant.features & needed == needed) {
            if (variant.pipeline) |ready| stand_in = stand_in orelse ready;
        }
    }
    if (!requested) {
        if (full == null and stand_in == null) {
            const constants = [1]u32{needed};
            const made = try renderer.device.createGraphicsPipeline(shadeVariantDesc(renderer.device, reflective, &constants));
            errdefer renderer.device.destroyPipeline(made);
            try renderer.shade_variants.append(renderer.gpa, .{ .reflective = reflective, .features = needed, .pipeline = made });
            return made;
        }
        const job = try renderer.gpa.create(ShadeVariantJob);
        errdefer renderer.gpa.destroy(job);
        job.* = .{ .device = renderer.device, .io = renderer.io, .reflective = reflective, .constants = .{needed} };
        try renderer.shade_variants.append(renderer.gpa, .{ .reflective = reflective, .features = needed, .job = job });
        job.group.concurrent(renderer.io, runShadeVariantJob, .{job}) catch job.group.async(renderer.io, runShadeVariantJob, .{job});
    }
    return stand_in orelse renderer.pipelines.get(full_id);
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
/// Returns the targets it filled for the reflection pass, if any.
pub fn shadeScene(renderer: *Renderer, p: *const ScenePass, lighting: *const Lighting, flags: u32, shadow_tlas: u64, colored_shadows: bool, gathered_gi: ?rhi.Texture, occluded: Occluded) !?ReflectionTargets {
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
        cmd.bindPipeline(try renderer.pipelines.get(.shading_rate));
        cmd.pushConstants(extern struct { frame: u64, history: u32, depth: u32, tile: u32, contrast: f32 }{
            .frame = frame_address,
            .history = device.textureIndex(view.history[@intCast((view_data.frames + 1) & 1)]),
            .depth = device.textureIndex(view.depth),
            .tile = device.caps.shading_rate_tile,
            .contrast = @max(settings.shading.variable_rate_contrast, 0),
        });
        cmd.drawFullscreen();
        cmd.endRendering();
        cmd.endScope();
        shading_rate = rates;
    };
    cmd.beginScope("shading");
    if (view.history_valid) cmd.transition(view.previous_depth, .shader_read);
    const reflections_on = (settings.reflections != null) and !debugging;
    const reflections: ?ReflectionTargets = if (reflections_on) try reflections_feature.reflectionTargets(renderer, p) else null;
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
    const ShadePush = extern struct { frame: u64, visibility: u32, ao: u32, debug_view: u32, gi: u32, material_shader: u32, shadow_history: u32, bounce: u32, bounce_strength: f32, shadow_depth: u32 = gpu.invalid_id };
    var shade_push = ShadePush{
        .frame = frame_address,
        .visibility = device.textureIndex(view.visibility),
        .ao = if (occluded.occlusion) |texture| device.textureIndex(texture) else gpu.invalid_id,
        .bounce = if (occluded.light) |texture| device.textureIndex(texture) else gpu.invalid_id,
        .bounce_strength = if (settings.ambient_occlusion) |occlusion| occlusion.bounce else 0,
        .debug_view = @intFromEnum(settings.debug_view),
        .gi = if (gathered_gi) |texture| device.textureIndex(texture) else gpu.invalid_id,
        .material_shader = 0,
        .shadow_history = if (filled(settings.shadows).light_filter and settings.resolution.temporal_antialiasing and view.history_valid and !debugging)
            device.textureIndex(view.history[@intCast((view_data.frames + 1) & 1)])
        else
            gpu.invalid_id,
    };
    if (shade_push.shadow_history != gpu.invalid_id) shade_push.shadow_depth = device.textureIndex(view.previous_depth);
    for (renderer.materials.shaders, renderer.materials.shader_users, 0..) |shader, users, slot| {
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
    if (flags & gpu.frame_flags.fluid_shadows != 0) shade_features |= gpu.shade_features.fluid_shadows;
    if (flags & gpu.frame_flags.cloud_shadows != 0) shade_features |= gpu.shade_features.cloud_shadows;
    if (scene.decals.items.len != 0) shade_features |= gpu.shade_features.decals;
    if (renderer.texture_transform_users != 0) shade_features |= gpu.shade_features.texture_transforms;
    if (colored_shadows) shade_features |= gpu.shade_features.colored_shadows;
    if (global_illumination_feature.probes(settings.global_illumination).probe_relocation) shade_features |= gpu.shade_features.gi_relocation;
    if (settings.shading.aerial_perspective > 0) shade_features |= gpu.shade_features.aerial;
    cmd.bindPipeline(try shadePipeline(renderer, reflections != null, shade_features));
    cmd.pushConstants(shade_push);
    cmd.drawFullscreen();
    for (renderer.materials.shaders, 0..) |shader, slot| {
        if ((custom_shaders >> @intCast(slot)) & 1 == 0) continue;
        shade_push.material_shader = @intCast(slot);
        cmd.bindPipeline(if (reflections != null) shader.?.reflective else shader.?.plain);
        cmd.pushConstants(shade_push);
        cmd.drawFullscreen();
    }
    cmd.endRendering();
    cmd.transition(view.hdr, .shader_read);
    cmd.transition(view.motion, .shader_read);
    cmd.endScope();
    return reflections;
}
