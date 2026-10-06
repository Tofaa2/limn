//! Path tracing a view in place of the picture the other passes draw.
//! Internal to the renderer.
const std = @import("std");
const rhi = @import("../../rhi/rhi.zig");
const render = @import("../renderer.zig");
const scene_pass = @import("../scene_pass.zig");

const Renderer = render.Renderer;
const ScenePass = scene_pass.ScenePass;

/// Path traces the view in place of the picture drawn so far, when
/// that is asked for and the scene is ready to be traced; returns
/// whether it did. What follows (lens effects, exposure, tone mapping,
/// draw lists) works on the result as on any other.
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
            // Built this frame, by the bounce light's update.
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
            if (view_data.path_accum) |old| device.destroyTexture(old);
            if (view_data.path_guide) |old| device.destroyTexture(old);
            if (view_data.path_filtered) |old| device.destroyTexture(old);
            if (view_data.path_accum_old) |old| device.destroyTexture(old);
            if (view_data.path_guide_old) |old| device.destroyTexture(old);
            view_data.path_accum_old = null;
            view_data.path_guide_old = null;
            view_data.path_guide = null;
            view_data.path_filtered = null;
            view_data.path_accum = null;
            view_data.path_accum = try device.createTexture(.{ .name = "path tracing", .width = width, .height = height, .format = .rgba32_float, .usage = .{ .sampled = true, .color_attachment = true } });
            view_data.path_guide = try device.createTexture(.{ .name = "path tracing guide", .width = width, .height = height, .format = .rgba16_float, .usage = .{ .sampled = true, .color_attachment = true } });
            view_data.path_filtered = try device.createTexture(.{ .name = "path tracing filtered", .width = width, .height = height, .format = .rgba16_float, .usage = .{ .sampled = true, .color_attachment = true } });
            view_data.path_accum_old = try device.createTexture(.{ .name = "path tracing (last frame)", .width = width, .height = height, .format = .rgba32_float, .usage = .{ .sampled = true, .color_attachment = true } });
            view_data.path_guide_old = try device.createTexture(.{ .name = "path tracing guide (last frame)", .width = width, .height = height, .format = .rgba16_float, .usage = .{ .sampled = true, .color_attachment = true } });
            // Both pairs start empty, so that either can be read.
            inline for (.{ .{ view_data.path_accum.?, view_data.path_guide.? }, .{ view_data.path_accum_old.?, view_data.path_guide_old.? } }) |pair| {
                try cmd.beginRendering(.{ .color = &.{ .{ .texture = pair[0], .load = .clear }, .{ .texture = pair[1], .load = .clear } } });
                cmd.endRendering();
                cmd.transition(pair[0], .shader_read);
                cmd.transition(pair[1], .shader_read);
            }
            view_data.path_size = .{ width, height };
            view_data.path_gathered = 0;
        }
        // Anything the picture depends on changing starts it over. The
        // camera is not among them: a picture is carried along as it
        // moves (see pathtrace.frag).
        var key = std.hash.Wyhash.init(content);
        key.update(std.mem.asBytes(&scene.sun.direction));
        key.update(std.mem.asBytes(&scene.sun.color));
        key.update(std.mem.asBytes(&scene.sun.intensity));
        key.update(std.mem.asBytes(&scene.environment_intensity));
        // The lights by what they are, not by when they were last
        // set: an application that hands over the same lamps every
        // frame has not moved them.
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
        // This frame is written beside the last, which it reads.
        std.mem.swap(?rhi.Texture, &view_data.path_accum, &view_data.path_accum_old);
        std.mem.swap(?rhi.Texture, &view_data.path_guide, &view_data.path_guide_old);
        const accum = view_data.path_accum.?;
        cmd.beginScope("path tracing");
        const guide = view_data.path_guide.?;
        try cmd.beginRendering(.{ .color = &.{ .{ .texture = accum, .load = .discard }, .{ .texture = guide, .load = .discard } } });
        cmd.bindPipeline(renderer.pipelines.path_trace);
        cmd.pushConstants(extern struct { frame: u64, scene: u64, scene_instances: u64, mesh_nodes: u64, mesh_items: u64, gathered: u32, bounces: u32, samples: u32, clamp_radiance: f32, sun_radius: f32, light_count: u32, glowing: u64, glowing_count: u32, history_color: u32, history_guide: u32, moved: u32, previous_camera: [3]f32, reset: u32 }{
            .frame = frame_address,
            .scene = where,
            .scene_instances = instances_address,
            .mesh_nodes = device.bufferAddress(renderer.bvh_nodes.buffer),
            .mesh_items = device.bufferAddress(renderer.bvh_items.buffer),
            .gathered = view_data.path_gathered,
            .bounces = std.math.clamp(settings.path_tracing_bounces, 1, 16),
            .samples = std.math.clamp(settings.path_tracing_samples, 1, 64),
            .clamp_radiance = @max(settings.path_tracing_clamp, 0.01),
            // The sun as seen from the ground, about half a degree across.
            .sun_radius = 0.0047,
            .light_count = 256,
            .glowing = scene_frame.glowing,
            .glowing_count = scene_frame.glowing_count,
            .history_color = device.textureIndex(view_data.path_accum_old.?),
            .history_guide = device.textureIndex(view_data.path_guide_old.?),
            .moved = @intFromBool(camera_moved),
            .previous_camera = previous_eye,
            .reset = @intFromBool(view_data.path_gathered == 0),
        });
        cmd.drawFullscreen();
        cmd.endRendering();
        cmd.transition(accum, .shader_read);
        cmd.transition(guide, .shader_read);
        const DenoisePush = extern struct { frame: u64, color: u32, guide: u32, depth: u32, step_size: i32, gathered: u32, last: u32 };
        if (settings.path_tracing_denoise) {
            // The grain cleared in two runs, the second reaching
            // further; see pathtrace_denoise.frag.
            const filtered = view_data.path_filtered.?;
            try cmd.beginRendering(.{ .color = &.{.{ .texture = filtered, .load = .discard }} });
            cmd.bindPipeline(renderer.pipelines.path_denoise);
            cmd.pushConstants(DenoisePush{ .frame = frame_address, .color = device.textureIndex(accum), .guide = device.textureIndex(guide), .depth = device.textureIndex(view.depth), .step_size = 1, .gathered = view_data.path_gathered, .last = 0 });
            cmd.drawFullscreen();
            cmd.endRendering();
            cmd.transition(filtered, .shader_read);
            try cmd.beginRendering(.{ .color = &.{.{ .texture = view.hdr, .load = .discard }} });
            cmd.bindPipeline(renderer.pipelines.path_denoise_final);
            cmd.pushConstants(DenoisePush{ .frame = frame_address, .color = device.textureIndex(filtered), .guide = device.textureIndex(guide), .depth = device.textureIndex(view.depth), .step_size = 3, .gathered = view_data.path_gathered, .last = 1 });
            cmd.drawFullscreen();
            cmd.endRendering();
        } else {
            try cmd.beginRendering(.{ .color = &.{.{ .texture = view.hdr, .load = .discard }} });
            // No smoothing, but the surfaces' color is still to be put
            // back on the light that was gathered without it.
            cmd.bindPipeline(renderer.pipelines.path_denoise_final);
            cmd.pushConstants(DenoisePush{ .frame = frame_address, .color = device.textureIndex(accum), .guide = device.textureIndex(guide), .depth = device.textureIndex(view.depth), .step_size = 1, .gathered = view_data.path_gathered, .last = 2 });
            cmd.drawFullscreen();
            cmd.endRendering();
        }
        cmd.transition(view.hdr, .shader_read);
        cmd.endScope();
        // Past a few thousand frames another changes nothing that
        // the picture's numbers can hold.
        view_data.path_gathered = @min(view_data.path_gathered + 1, 8192);
        renderer.stats.path_traced_frames = view_data.path_gathered;
        renderer.stats.path_tracing_hardware = device.ray_tracing;
        path_traced = true;
    }
    return path_traced;
}
