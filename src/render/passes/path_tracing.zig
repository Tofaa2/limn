//! Path tracing a view in place of the rasterized image. Internal to the
//! renderer.
const std = @import("std");
const rhi = @import("../../rhi/rhi.zig");
const render = @import("../renderer.zig");
const scene_pass = @import("../scene_pass.zig");

const Renderer = render.Renderer;
const ViewData = render.ViewData;
const ScenePass = scene_pass.ScenePass;

/// Step size in pixels of each pathtrace_denoise.frag pass; the short last one
/// removes the grid a wide step leaves.
const denoise_steps = [_]i32{ 1, 2, 4, 8, 3 };

/// Push constants of pathtrace_denoise.frag.
const DenoisePush = extern struct {
    frame: u64,
    color: u32,
    guide: u32,
    step_size: i32,
    gathered: u32,
    mode: enum(u32) { first = 0, last = 1, none = 2, between = 3 },
    steady: u32,
    facing: u32,
    gloss: u32,
    gloss_gathered: u32,
};

/// Frames after the camera stops before the accumulated image is antialiased by
/// itself, and frames over which TAA then fades out.
pub const frames_to_settle = 8;
pub const frames_to_hand_over = 16;

/// `history_clip_weight` in ffx_reflections_resolve.frag; AMD's default.
const reflection_stability = 0.7;

/// Recreates a view's path tracing targets at this size and resets
/// accumulation. History targets start cleared.
fn makeTargets(device: *rhi.Device, cmd: *rhi.CommandEncoder, view_data: *ViewData, width: u32, height: u32) !void {
    const targets = [_]struct { slot: *?rhi.Texture, name: [:0]const u8, format: rhi.Format, divide: u32 = 1 }{
        .{ .slot = &view_data.path_accum, .name = "path tracing", .format = .rgba32_float },
        .{ .slot = &view_data.path_accum_old, .name = "path tracing (last frame)", .format = .rgba32_float },
        .{ .slot = &view_data.path_guide, .name = "path tracing guide", .format = .rgba16_float },
        .{ .slot = &view_data.path_guide_old, .name = "path tracing guide (last frame)", .format = .rgba16_float },
        .{ .slot = &view_data.path_soft, .name = "path tracing grainy light", .format = .rgba32_float },
        .{ .slot = &view_data.path_soft_old, .name = "path tracing grainy light (last frame)", .format = .rgba32_float },
        .{ .slot = &view_data.path_filtered, .name = "path tracing filtered", .format = .rgba16_float },
        .{ .slot = &view_data.path_filtered_other, .name = "path tracing filtered (other)", .format = .rgba16_float },
        .{ .slot = &view_data.path_facing, .name = "path tracing facing", .format = .rgba16_float },
        .{ .slot = &view_data.path_facing_old, .name = "path tracing facing (last frame)", .format = .rgba16_float },
        .{ .slot = &view_data.path_surface, .name = "path tracing surface", .format = .rgba16_float },
        .{ .slot = &view_data.path_surface_old, .name = "path tracing surface (last frame)", .format = .rgba16_float },
        .{ .slot = &view_data.path_gloss, .name = "path tracing reflections", .format = .rgba16_float },
        .{ .slot = &view_data.path_gloss_gathered, .name = "path tracing reflections gathered", .format = .rgba32_float },
        .{ .slot = &view_data.path_gloss_gathered_old, .name = "path tracing reflections gathered (last frame)", .format = .rgba32_float },
        .{ .slot = &view_data.reflection_reprojected, .name = "reflection denoise: reprojected", .format = .rgba16_float },
        .{ .slot = &view_data.reflection_samples, .name = "reflection denoise: samples", .format = .r16_float },
        .{ .slot = &view_data.reflection_samples_old, .name = "reflection denoise: samples (last frame)", .format = .r16_float },
        .{ .slot = &view_data.reflection_average, .name = "reflection denoise: average", .format = .rgba16_float, .divide = 8 },
        .{ .slot = &view_data.reflection_prefiltered, .name = "reflection denoise: prefiltered", .format = .rgba16_float },
        .{ .slot = &view_data.reflection_resolved, .name = "reflection denoise: resolved", .format = .rgba16_float },
        .{ .slot = &view_data.reflection_resolved_old, .name = "reflection denoise: resolved (last frame)", .format = .rgba16_float },
    };
    for (targets) |target| {
        if (target.slot.*) |old| device.destroyTexture(old);
        target.slot.* = null;
    }
    for (targets) |target| {
        const made = try device.createTexture(.{
            .name = target.name,
            .width = (width + target.divide - 1) / target.divide,
            .height = (height + target.divide - 1) / target.divide,
            .format = target.format,
            .usage = .{ .sampled = true, .color_attachment = true },
        });
        target.slot.* = made;
        try cmd.beginRendering(.{ .color = &.{.{ .texture = made, .load = .clear }} });
        cmd.endRendering();
        cmd.transition(made, .shader_read);
    }
    view_data.path_size = .{ width, height };
    view_data.path_gathered = 0;
}

/// Runs the reflection denoiser (ffx_reflections.glsl) and returns its result,
/// which is also next frame's history.
fn denoiseReflections(renderer: *Renderer, p: *const ScenePass, gloss: rhi.Texture, surface: rhi.Texture) !rhi.Texture {
    const device = renderer.device;
    const cmd = p.cmd;
    const view_data = p.view_data;
    std.mem.swap(?rhi.Texture, &view_data.reflection_samples, &view_data.reflection_samples_old);
    std.mem.swap(?rhi.Texture, &view_data.reflection_resolved, &view_data.reflection_resolved_old);
    const reprojected = view_data.reflection_reprojected.?;
    const samples = view_data.reflection_samples.?;
    const average = view_data.reflection_average.?;
    const prefiltered = view_data.reflection_prefiltered.?;
    const resolved = view_data.reflection_resolved.?;
    cmd.beginScope("reflection denoise");
    defer cmd.endScope();

    try cmd.beginRendering(.{ .color = &.{ .{ .texture = reprojected, .load = .discard }, .{ .texture = samples, .load = .discard } } });
    cmd.bindPipeline(renderer.pipelines.reflection_reproject);
    cmd.pushConstants(extern struct { frame: u64, radiance: u32, surface: u32, surface_history: u32, motion: u32, history: u32, samples_history: u32 }{
        .frame = p.frame_address,
        .radiance = device.textureIndex(gloss),
        .surface = device.textureIndex(surface),
        .surface_history = device.textureIndex(view_data.path_surface_old.?),
        .motion = device.textureIndex(p.view.motion),
        .history = device.textureIndex(view_data.reflection_resolved_old.?),
        .samples_history = device.textureIndex(view_data.reflection_samples_old.?),
    });
    cmd.drawFullscreen();
    cmd.endRendering();
    cmd.transition(reprojected, .shader_read);
    cmd.transition(samples, .shader_read);

    try cmd.beginRendering(.{ .color = &.{.{ .texture = average, .load = .discard }} });
    cmd.bindPipeline(renderer.pipelines.reflection_average);
    cmd.pushConstants(extern struct { frame: u64, radiance: u32, reprojected: u32, samples: u32, pad: u32 = 0 }{
        .frame = p.frame_address,
        .radiance = device.textureIndex(gloss),
        .reprojected = device.textureIndex(reprojected),
        .samples = device.textureIndex(samples),
    });
    cmd.drawFullscreen();
    cmd.endRendering();
    cmd.transition(average, .shader_read);

    try cmd.beginRendering(.{ .color = &.{.{ .texture = prefiltered, .load = .discard }} });
    cmd.bindPipeline(renderer.pipelines.reflection_prefilter);
    cmd.pushConstants(extern struct { frame: u64, radiance: u32, reprojected: u32, surface: u32, average: u32 }{
        .frame = p.frame_address,
        .radiance = device.textureIndex(gloss),
        .reprojected = device.textureIndex(reprojected),
        .surface = device.textureIndex(surface),
        .average = device.textureIndex(average),
    });
    cmd.drawFullscreen();
    cmd.endRendering();
    cmd.transition(prefiltered, .shader_read);

    try cmd.beginRendering(.{ .color = &.{.{ .texture = resolved, .load = .discard }} });
    cmd.bindPipeline(renderer.pipelines.reflection_resolve);
    cmd.pushConstants(extern struct { frame: u64, prefiltered: u32, reprojected: u32, samples: u32, surface: u32, average: u32, history_clip_weight: f32 }{
        .frame = p.frame_address,
        .prefiltered = device.textureIndex(prefiltered),
        .reprojected = device.textureIndex(reprojected),
        .samples = device.textureIndex(samples),
        .surface = device.textureIndex(surface),
        .average = device.textureIndex(average),
        .history_clip_weight = reflection_stability,
    });
    cmd.drawFullscreen();
    cmd.endRendering();
    cmd.transition(resolved, .shader_read);
    return resolved;
}

/// Path traces the view if requested and the scene is ready; returns whether it
/// did.
pub fn pathTrace(renderer: *Renderer, p: *const ScenePass) !bool {
    const device = renderer.device;
    const cmd = p.cmd;
    const desc = p.desc;
    const settings = p.settings;
    const scene = p.scene;
    const scene_frame = p.scene_frame;
    const view_data = p.view_data;
    const view = p.view;
    const width = p.width;
    const height = p.height;
    const debugging = p.debugging;
    const frame_address = p.frame_address;
    var path_traced = false;
    if (settings.path_tracing and !debugging) trace: {
        scene.trace_wanted = true;
        var where: u64 = 0;
        var instances_address: u64 = 0;
        var content: u64 = 0;
        if (device.ray_tracing) {
            const tlas = scene.tlas orelse break :trace;
            // The TLAS is built this frame by the GI update.
            if (scene.tlas_hash == 0 or scene.tlas_hash != scene_frame.tlas_hash) break :trace;
            where = device.accelerationAddress(tlas);
            content = scene.tlas_hash;
        } else {
            if (!scene.trace_ready) break :trace;
            where = device.bufferAddress(scene.trace_nodes.?);
            instances_address = device.bufferAddress(scene.trace_instances.?);
            content = scene.trace_hash;
        }
        if (view_data.path_accum == null or view_data.path_size[0] != width or view_data.path_size[1] != height) {
            try makeTargets(device, cmd, view_data, width, height);
        }
        var key = std.hash.Wyhash.init(content);
        key.update(std.mem.asBytes(&scene.sun.direction));
        key.update(std.mem.asBytes(&scene.sun.color));
        key.update(std.mem.asBytes(&scene.sun.intensity));
        key.update(std.mem.asBytes(&scene.environment_intensity));
        for (scene.lights.items) |light| {
            key.update(std.mem.asBytes(&light.position));
            key.update(std.mem.asBytes(&light.direction));
            key.update(std.mem.asBytes(&light.color));
            key.update(std.mem.asBytes(&light.intensity));
            key.update(std.mem.asBytes(&light.range));
            key.update(std.mem.asBytes(&light.inner_angle));
            key.update(std.mem.asBytes(&light.outer_angle));
            key.update(std.mem.asBytes(&light.source_radius));
            key.update(&.{@intFromEnum(light.kind)});
        }
        key.update(std.mem.asBytes(&settings.path_tracing_bounces));
        key.update(std.mem.asBytes(&settings.path_tracing_clamp));
        const path_key = key.final();
        if (path_key != view_data.path_key) {
            view_data.path_key = path_key;
            view_data.path_gathered = 0;
        }
        const camera_moved = !std.meta.eql(view_data.path_camera, desc.camera);
        const previous_eye = view_data.path_camera.position;
        view_data.path_camera = desc.camera;
        view_data.path_still = if (camera_moved or view_data.path_gathered == 0) 0 else view_data.path_still +| 1;
        std.mem.swap(?rhi.Texture, &view_data.path_accum, &view_data.path_accum_old);
        std.mem.swap(?rhi.Texture, &view_data.path_guide, &view_data.path_guide_old);
        std.mem.swap(?rhi.Texture, &view_data.path_soft, &view_data.path_soft_old);
        std.mem.swap(?rhi.Texture, &view_data.path_facing, &view_data.path_facing_old);
        std.mem.swap(?rhi.Texture, &view_data.path_surface, &view_data.path_surface_old);
        std.mem.swap(?rhi.Texture, &view_data.path_gloss_gathered, &view_data.path_gloss_gathered_old);
        const accum = view_data.path_accum.?;
        const guide = view_data.path_guide.?;
        const soft = view_data.path_soft.?;
        const facing = view_data.path_facing.?;
        const surface = view_data.path_surface.?;
        const gloss = view_data.path_gloss.?;
        const gloss_gathered = view_data.path_gloss_gathered.?;
        cmd.beginScope("path tracing");
        try cmd.beginRendering(.{ .color = &.{ .{ .texture = accum, .load = .discard }, .{ .texture = guide, .load = .discard }, .{ .texture = soft, .load = .discard }, .{ .texture = facing, .load = .discard }, .{ .texture = gloss, .load = .discard }, .{ .texture = gloss_gathered, .load = .discard }, .{ .texture = surface, .load = .discard } } });
        cmd.bindPipeline(renderer.pipelines.path_trace);
        cmd.pushConstants(extern struct { frame: u64, scene: u64, scene_instances: u64, mesh_nodes: u64, mesh_items: u64, gathered: u32, bounces: u32, samples: u32, clamp_radiance: f32, sun_radius: f32, light_count: u32, glowing: u64, glowing_count: u32, history_color: u32, history_guide: u32, history_soft: u32, history_gloss: u32, moved: u32, previous_camera: [3]f32, reset: u32, centered: u32, history_facing: u32, history_surface: u32 }{
            .frame = frame_address,
            .scene = where,
            .scene_instances = instances_address,
            .mesh_nodes = device.bufferAddress(renderer.bvh_nodes.buffer),
            .mesh_items = device.bufferAddress(renderer.bvh_items.buffer),
            .gathered = view_data.path_gathered,
            .bounces = std.math.clamp(settings.path_tracing_bounces, 1, 16),
            .samples = std.math.clamp(settings.path_tracing_samples, 1, 64),
            .clamp_radiance = @max(settings.path_tracing_clamp, 0.01),
            // Angular radius of the sun, in radians.
            .sun_radius = 0.0047,
            .light_count = 256,
            .glowing = scene_frame.glowing,
            .glowing_count = scene_frame.glowing_count,
            .history_color = device.textureIndex(view_data.path_accum_old.?),
            .history_guide = device.textureIndex(view_data.path_guide_old.?),
            .history_soft = device.textureIndex(view_data.path_soft_old.?),
            .history_gloss = device.textureIndex(view_data.path_gloss_gathered_old.?),
            .moved = @intFromBool(camera_moved),
            .previous_camera = previous_eye,
            .reset = @intFromBool(view_data.path_gathered == 0),
            .centered = @intFromBool(settings.temporal_antialiasing),
            .history_facing = device.textureIndex(view_data.path_facing_old.?),
            .history_surface = device.textureIndex(view_data.path_surface_old.?),
        });
        cmd.drawFullscreen();
        cmd.endRendering();
        cmd.transition(accum, .shader_read);
        cmd.transition(guide, .shader_read);
        cmd.transition(soft, .shader_read);
        cmd.transition(facing, .shader_read);
        cmd.transition(gloss, .shader_read);
        cmd.transition(gloss_gathered, .shader_read);
        cmd.transition(surface, .shader_read);
        cmd.endScope();

        cmd.beginScope("path tracing denoise");
        var denoise = DenoisePush{
            .frame = frame_address,
            .color = device.textureIndex(soft),
            .guide = device.textureIndex(guide),
            .step_size = 1,
            .gathered = view_data.path_gathered,
            .mode = .none,
            .steady = device.textureIndex(accum),
            .facing = device.textureIndex(facing),
            .gloss = device.textureIndex(gloss),
            .gloss_gathered = device.textureIndex(gloss_gathered),
        };
        if (settings.path_tracing_denoise) {
            denoise.gloss = device.textureIndex(try denoiseReflections(renderer, p, gloss, surface));
            const between = [2]rhi.Texture{ view_data.path_filtered.?, view_data.path_filtered_other.? };
            for (denoise_steps[0 .. denoise_steps.len - 1], 0..) |step, run| {
                const smoothed = between[run % 2];
                denoise.step_size = step;
                denoise.mode = if (run == 0) .first else .between;
                try cmd.beginRendering(.{ .color = &.{.{ .texture = smoothed, .load = .discard }} });
                cmd.bindPipeline(renderer.pipelines.path_denoise);
                cmd.pushConstants(denoise);
                cmd.drawFullscreen();
                cmd.endRendering();
                cmd.transition(smoothed, .shader_read);
                denoise.color = device.textureIndex(smoothed);
            }
            denoise.step_size = denoise_steps[denoise_steps.len - 1];
            denoise.mode = .last;
        }
        try cmd.beginRendering(.{ .color = &.{.{ .texture = view.hdr, .load = .discard }} });
        cmd.bindPipeline(renderer.pipelines.path_denoise_final);
        cmd.pushConstants(denoise);
        cmd.drawFullscreen();
        cmd.endRendering();
        cmd.transition(view.hdr, .shader_read);
        cmd.endScope();
        view_data.path_gathered = @min(view_data.path_gathered + 1, 8192);
        renderer.stats.path_traced_frames = view_data.path_gathered;
        renderer.stats.path_tracing_hardware = device.ray_tracing;
        path_traced = true;
    }
    return path_traced;
}
