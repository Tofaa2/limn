//! Lighting the opaque scene: what shading reads besides the visibility
//! buffer, the shading pass itself, and the reflections laid over it.
//! Internal to the renderer.
const std = @import("std");
const rhi = @import("../../rhi/rhi.zig");
const math = @import("../../math.zig");
const gpu = @import("../gpu.zig");
const render = @import("../renderer.zig");
const scene_pass = @import("../scene_pass.zig");

const Renderer = render.Renderer;
const ReflectionTargets = render.ReflectionTargets;
const ShadeVariantJob = render.ShadeVariantJob;
const shadeVariantDesc = render.shadeVariantDesc;
const runShadeVariantJob = render.runShadeVariantJob;
const hdr_format = render.hdr_format;
const shaderCode = render.shaderCode;
const ScenePass = scene_pass.ScenePass;
const ProbeList = scene_pass.ProbeList;
const Lighting = scene_pass.Lighting;

/// The scene's reflection probes that have their pictures; one whose
/// pictures are being taken now is left out of them.
pub fn reflectionProbeList(renderer: *Renderer, p: *const ScenePass) !ProbeList {
    const device = renderer.device;
    const arena = p.arena;
    const scene = p.scene;
    var probe_list: u64 = 0;
    var probe_count: u32 = 0;
    if (scene.probes.items.len != 0) {
        const list = try arena.alloc(device, gpu.ReflectionProbe, scene.probes.items.len);
        for (scene.probes.items) |probe_handle| {
            const probe = renderer.probes.get(probe_handle) orelse continue;
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

/// Writes the scene's decals where the shaders read them and returns
/// the address.
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

/// Ambient occlusion from the depth buffer, and with it the light
/// that nearby surfaces bounce.
pub fn ambientOcclusion(renderer: *Renderer, p: *const ScenePass) !void {
    const device = renderer.device;
    const cmd = p.cmd;
    const desc = p.desc;
    const settings = p.settings;
    const view_data = p.view_data;
    const view = p.view;
    const debugging = p.debugging;
    const frame_address = p.frame_address;
    if (settings.ambient_occlusion) {
        cmd.beginScope("ambient occlusion");
        cmd.beginScope("ao depth");
        {
            // Linear depth pyramid for the horizon search.
            const info = device.textureInfo(view.ao_depth);
            const sampler = device.samplerIndex(renderer.sampler_nearest_clamp);
            for (0..info.mip_levels) |mip| {
                if (mip != 0) cmd.transitionMip(view.ao_depth, @intCast(mip - 1), .shader_read);
                try cmd.beginRendering(.{ .color = &.{.{ .texture = view.ao_depth, .mip = @intCast(mip), .load = .discard }} });
                cmd.bindPipeline(renderer.pipelines.ao_depth);
                cmd.pushConstants(extern struct { source: u32, sampler: u32, first: u32, source_lod: i32, near: f32 }{
                    .source = device.textureIndex(if (mip == 0) view.depth else view.ao_depth),
                    .sampler = sampler,
                    .first = @intFromBool(mip == 0),
                    .source_lod = if (mip == 0) 0 else @intCast(mip - 1),
                    .near = desc.camera.near,
                });
                cmd.drawFullscreen();
                cmd.endRendering();
            }
            cmd.transition(view.ao_depth, .shader_read);
        }
        cmd.endScope();
        // Light gathered along with the occlusion comes from last
        // frame's picture, which is there once antialiasing has
        // resolved one.
        const bounce_source: ?rhi.Texture = if (settings.ao_bounce > 0 and settings.temporal_antialiasing and view.history_valid and !debugging) view.history[@intCast((view_data.frames + 1) & 1)] else null;
        cmd.beginScope("ao trace");
        try cmd.beginRendering(.{ .color = &.{ .{ .texture = view.ao_raw, .load = .discard }, .{ .texture = view.bounce_raw, .load = .discard } } });
        cmd.bindPipeline(renderer.pipelines.gtao);
        cmd.pushConstants(extern struct { frame: u64, depth: u32, color: u32, radius: f32, intensity: f32, slice_count: i32, step_count: i32 }{
            .frame = frame_address,
            .depth = device.textureIndex(view.ao_depth),
            .color = if (bounce_source) |texture| device.textureIndex(texture) else gpu.invalid_id,
            .radius = settings.ao_radius,
            .intensity = settings.ao_intensity,
            .slice_count = @intCast(std.math.clamp(settings.ao_slices, 1, 8)),
            .step_count = @intCast(std.math.clamp(settings.ao_steps, 1, 32)),
        });
        cmd.drawFullscreen();
        cmd.endRendering();
        cmd.transition(view.ao_raw, .shader_read);
        cmd.transition(view.bounce_raw, .shader_read);
        cmd.endScope();
        // Write into the older of the two; the other is last frame's.
        std.mem.swap(rhi.Texture, &view.ao, &view.ao_history);
        const ao_temporal = settings.ao_temporal_filter and view.ao_history_valid;
        cmd.beginScope("ao filter");
        const FilterPush = extern struct { frame: u64, ao: u32, depth: u32, history: u32, blend: f32, bounce: u32 = gpu.invalid_id, bounce_history: u32 = gpu.invalid_id };
        var filter_push = FilterPush{
            .frame = frame_address,
            .ao = device.textureIndex(view.ao_raw),
            .depth = device.textureIndex(view.depth),
            .history = if (ao_temporal) device.textureIndex(view.ao_history) else gpu.invalid_id,
            .blend = 0.1,
        };
        if (bounce_source != null) {
            std.mem.swap(rhi.Texture, &view.bounce, &view.bounce_history);
            filter_push.bounce = device.textureIndex(view.bounce_raw);
            if (view.bounce_history_valid) filter_push.bounce_history = device.textureIndex(view.bounce_history);
            try cmd.beginRendering(.{ .color = &.{ .{ .texture = view.ao, .load = .discard }, .{ .texture = view.bounce, .load = .discard } } });
            cmd.bindPipeline(renderer.pipelines.gtao_bounce_denoise);
        } else {
            try cmd.beginRendering(.{ .color = &.{.{ .texture = view.ao, .load = .discard }} });
            cmd.bindPipeline(renderer.pipelines.gtao_denoise);
        }
        cmd.pushConstants(filter_push);
        cmd.drawFullscreen();
        cmd.endRendering();
        cmd.transition(view.ao, .shader_read);
        if (bounce_source != null) cmd.transition(view.bounce, .shader_read);
        cmd.endScope();
        view.ao_history_valid = true;
        view.bounce_history_valid = bounce_source != null;
        cmd.endScope();
    } else {
        view.ao_history_valid = false;
    }
}

/// The shading pass with every feature built in and no reflection
/// targets, made the first time it is needed.
pub fn plainShadePipeline(renderer: *Renderer) !rhi.Pipeline {
    if (renderer.pipelines.shade) |made| return made;
    const made = try renderer.device.createGraphicsPipeline(.{
        .name = "shading",
        .vertex = shaderCode("fullscreen.vert.spv"),
        .fragment = if (renderer.device.ray_tracing) shaderCode("shade_rt.frag.spv") else shaderCode("shade.frag.spv"),
        .color_targets = &.{ .{ .format = hdr_format }, .{ .format = .rg16_float } },
        .cull = .none,
    });
    renderer.pipelines.shade = made;
    return made;
}

/// The shading pipeline for a view: the build with exactly the
/// features it needs if that exists, otherwise one with more that is
/// ready, while the exact one is compiled on a worker thread.
pub fn shadePipeline(renderer: *Renderer, reflective: bool, needed: u32) !rhi.Pipeline {
    const full = if (reflective) renderer.pipelines.shade_reflective else renderer.pipelines.shade;
    if (!renderer.options.shader_variants) return full orelse try plainShadePipeline(renderer);
    var requested = false;
    var stand_in: ?rhi.Pipeline = null;
    for (renderer.shade_variants.items) |*variant| {
        if (variant.reflective != reflective) continue;
        if (variant.job) |job| if (job.done.load(.acquire)) {
            // Compiled, or failed: either way the job is over.
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
        // Nothing can stand in (the full pass is itself built on first
        // use when a view has no reflection targets): compile this one
        // now.
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
    return stand_in orelse full orelse try plainShadePipeline(renderer);
}

/// Material evaluation and lighting in one pass straight from the
/// visibility buffer; nothing is written to a G-buffer in between.
/// Returns the targets it filled for the reflection pass, if any.
pub fn shadeScene(renderer: *Renderer, p: *const ScenePass, lighting: *const Lighting, flags: u32, shadow_tlas: u64, colored_shadows: bool, gathered_gi: ?rhi.Texture) !?ReflectionTargets {
    const device = renderer.device;
    const cmd = p.cmd;
    const settings = p.settings;
    const scene = p.scene;
    const view_data = p.view_data;
    const view = p.view;
    const debugging = p.debugging;
    const frame_address = p.frame_address;
    cmd.beginScope("shading");
    // With reflections on, the pass also writes what the reflection
    // pass needs to know about each surface.
    const reflections_on = settings.screen_space_reflections and !debugging;
    if (view.reflections) |*targets| {
        // Write into the older of the two results; the other is history.
        if (reflections_on) std.mem.swap(rhi.Texture, &targets.traced, &targets.history) else targets.history_valid = false;
    }
    const reflections: ?ReflectionTargets = if (reflections_on) view.reflections else null;
    if (reflections) |targets| {
        try cmd.beginRendering(.{ .color = &.{
            .{ .texture = view.hdr, .load = .discard },
            .{ .texture = view.motion, .load = .discard },
            .{ .texture = targets.weight, .load = .discard },
            .{ .texture = targets.surface, .load = .discard },
        } });
    } else {
        try cmd.beginRendering(.{ .color = &.{
            .{ .texture = view.hdr, .load = .discard },
            .{ .texture = view.motion, .load = .discard },
        } });
    }
    const ShadePush = extern struct { frame: u64, visibility: u32, ao: u32, debug_view: u32, gi: u32, material_shader: u32, shadow_history: u32, bounce: u32, bounce_strength: f32 };
    var shade_push = ShadePush{
        .frame = frame_address,
        .visibility = device.textureIndex(view.visibility),
        .ao = device.textureIndex(view.ao),
        .bounce = if (settings.ambient_occlusion and view.bounce_history_valid) device.textureIndex(view.bounce) else gpu.invalid_id,
        .bounce_strength = @max(settings.ao_bounce, 0),
        .debug_view = @intFromEnum(settings.debug_view),
        .gi = if (gathered_gi) |texture| device.textureIndex(texture) else gpu.invalid_id,
        .material_shader = 0,
        // What temporal antialiasing resolved last frame.
        .shadow_history = if (settings.light_shadow_filter and settings.temporal_antialiasing and view.history_valid and !debugging)
            device.textureIndex(view.history[@intCast((view_data.frames + 1) & 1)])
        else
            gpu.invalid_id,
    };
    // Custom material shaders that some loaded material uses each get
    // a pass over their own pixels; the standard pass skips those.
    for (renderer.material_shaders, renderer.material_shader_users, 0..) |shader, users, slot| {
        if (shader != null and users != 0) shade_push.material_shader |= @as(u32, 1) << @intCast(slot);
    }
    const custom_shaders = shade_push.material_shader;
    // The optional shading code this view can reach; the pass is built
    // without the rest.
    var shade_features: u32 = 0;
    if (lighting.light_count != 0) {
        shade_features |= gpu.feature_local_lights;
        if (shadow_tlas != 0) shade_features |= gpu.feature_traced_light_shadows;
        for (scene.lights.items) |light| if (light.source_radius > 0) {
            shade_features |= gpu.feature_sized_lights;
            break;
        };
    }
    if (flags & gpu.frame_fluid_shadows != 0) shade_features |= gpu.feature_fluid_shadows;
    if (flags & gpu.frame_cloud_shadows != 0) shade_features |= gpu.feature_cloud_shadows;
    if (scene.decals.items.len != 0) shade_features |= gpu.feature_decals;
    if (renderer.texture_transform_users != 0) shade_features |= gpu.feature_texture_transforms;
    if (colored_shadows) shade_features |= gpu.feature_colored_shadows;
    if (settings.gi_probe_relocation) shade_features |= gpu.feature_gi_relocation;
    if (settings.aerial_perspective > 0) shade_features |= gpu.feature_aerial;
    cmd.bindPipeline(try shadePipeline(renderer, reflections != null, shade_features));
    cmd.pushConstants(shade_push);
    cmd.drawFullscreen();
    for (renderer.material_shaders, 0..) |shader, slot| {
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

/// Traces reflections across the screen (and, with `ray_traced`, past
/// it through the scene) and adds them to the picture.
pub fn drawReflections(renderer: *Renderer, p: *const ScenePass, targets: ReflectionTargets, ray_traced: bool) !void {
    const device = renderer.device;
    const cmd = p.cmd;
    const settings = p.settings;
    const scene = p.scene;
    const view = p.view;
    const frame_address = p.frame_address;
    cmd.transition(targets.weight, .shader_read);
    cmd.transition(targets.surface, .shader_read);
    cmd.beginScope("reflections");
    try cmd.beginRendering(.{ .color = &.{.{ .texture = targets.traced, .load = .discard }} });
    // With the scene's acceleration structure at hand, misses of
    // the screen trace are answered by real rays.
    const traced_tlas: u64 = if (settings.reflection_ray_tracing and ray_traced and device.ray_tracing)
        (if (scene.tlas) |tlas| device.accelerationAddress(tlas) else 0)
    else
        0;
    cmd.bindPipeline(if (traced_tlas != 0) renderer.pipelines.ssr_traced else renderer.pipelines.ssr);
    cmd.pushConstants(extern struct { frame: u64, depth: u32, color: u32, reflection: u32, surface: u32, max_roughness: f32, thickness: f32, max_distance: f32, step_count: i32, history: u32, history_blend: f32, tlas: u64 }{
        .frame = frame_address,
        .depth = device.textureIndex(view.depth),
        .color = device.textureIndex(view.hdr),
        .reflection = device.textureIndex(targets.weight),
        .surface = device.textureIndex(targets.surface),
        .max_roughness = std.math.clamp(settings.reflection_max_roughness, 0.05, 1),
        .thickness = @max(settings.reflection_thickness, 0.01),
        .max_distance = @max(settings.reflection_distance, 0.1),
        .step_count = @intCast(std.math.clamp(settings.reflection_steps, 4, 256)),
        .history = if (targets.history_valid and settings.reflection_temporal_filter) device.textureIndex(targets.history) else gpu.invalid_id,
        .history_blend = 0.12,
        .tlas = traced_tlas,
    });
    cmd.drawFullscreen();
    cmd.endRendering();
    cmd.transition(targets.traced, .shader_read);
    view.reflections.?.history_valid = true;
    try cmd.beginRendering(.{ .color = &.{.{ .texture = view.hdr, .load = .load }} });
    cmd.bindPipeline(renderer.pipelines.ssr_composite);
    cmd.pushConstants(extern struct { frame: u64, depth: u32, reflection: u32, surface: u32, traced: u32, max_roughness: f32, blur_taps: i32, reduced: u32, pad: u32 = 0 }{
        .frame = frame_address,
        .depth = device.textureIndex(view.depth),
        .reflection = device.textureIndex(targets.weight),
        .surface = device.textureIndex(targets.surface),
        .traced = device.textureIndex(targets.traced),
        .max_roughness = std.math.clamp(settings.reflection_max_roughness, 0.05, 1),
        .blur_taps = @intCast(@min(settings.reflection_blur_samples, 32)),
        .reduced = @intFromBool(settings.reflection_resolution != .full),
    });
    cmd.drawFullscreen();
    cmd.endRendering();
    cmd.transition(view.hdr, .shader_read);
    cmd.endScope();
}
