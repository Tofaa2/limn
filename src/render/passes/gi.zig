//! Irradiance probe grids and the rays that update them. Internal to the
//! renderer.
const std = @import("std");
const rhi = @import("../../rhi/rhi.zig");
const math = @import("../../math.zig");
const render = @import("../renderer.zig");
const scene_pass = @import("../scene_pass.zig");

const Vec3 = math.Vec3;
const Renderer = render.Renderer;
const SceneData = render.SceneData;
const Settings = render.Settings;
const GiVolume = render.GiVolume;
const gi_probe_limit = render.gi_probe_limit;
const gi_irradiance_texels = render.gi_irradiance_texels;
const gi_visibility_texels = render.gi_visibility_texels;
const hdr_format = render.hdr_format;
const SceneFrame = scene_pass.SceneFrame;

/// Returns the volume in `slot` moved to `cell`, or a new one if the grid's
/// shape, spacing or ray count changed.
pub fn ensureGiVolume(renderer: *Renderer, slot: *?GiVolume, scene_origin: [3]f64, cell: [3]i32, counts: [3]u32, spacing: f32, rays_per_probe: u32) !*GiVolume {
    const device = renderer.device;
    var origin: Vec3 = undefined;
    inline for (0..3) |axis| origin[axis] = @floatCast(@as(f64, @floatFromInt(cell[axis])) * spacing - scene_origin[axis]);
    if (slot.*) |*volume| {
        const same = std.mem.eql(u32, &volume.counts, &counts) and volume.rays_per_probe == rays_per_probe and
            @abs(volume.spacing - spacing) < 1e-4;
        if (same) {
            // Probes are stored by world cell modulo the grid size; only cells
            // that wrapped are new.
            inline for (0..3) |axis| volume.shift[axis] = cell[axis] - volume.cell[axis];
            var kept: u64 = 1;
            var total: u64 = 1;
            inline for (0..3) |axis| {
                kept *= counts[axis] -| @abs(volume.shift[axis]);
                total *= counts[axis];
            }
            if (kept * 2 < total and volume.frames != 0) volume.frames = 1;
            volume.cell = cell;
            volume.origin = origin;
            return volume;
        }
        volume.deinit(device);
        slot.* = null;
    }
    const color = rhi.TextureUsage{ .sampled = true, .color_attachment = true };
    const tiles_x = counts[0] * counts[2];
    const probe_count = counts[0] * counts[1] * counts[2];
    var made = render.MadeTextures{ .device = device };
    errdefer made.destroy();
    slot.* = .{
        .origin = origin,
        .cell = cell,
        .spacing = spacing,
        .counts = counts,
        .rays_per_probe = rays_per_probe,
        .irradiance = try made.texture(.{
            .name = "gi irradiance",
            .width = tiles_x * gi_irradiance_texels,
            .height = counts[1] * gi_irradiance_texels,
            .format = hdr_format,
            .usage = color,
        }),
        .irradiance_fast = try made.texture(.{
            .name = "gi irradiance (fast)",
            .width = tiles_x * gi_irradiance_texels,
            .height = counts[1] * gi_irradiance_texels,
            .format = hdr_format,
            .usage = color,
        }),
        .visibility = try made.texture(.{
            .name = "gi visibility",
            .width = tiles_x * gi_visibility_texels,
            .height = counts[1] * gi_visibility_texels,
            .format = .rg16_float,
            .usage = color,
        }),
        .offsets = .{
            try made.texture(.{ .name = "gi probe offsets", .width = tiles_x, .height = counts[1], .format = .rgba16_float, .usage = color }),
            try made.texture(.{ .name = "gi probe offsets", .width = tiles_x, .height = counts[1], .format = .rgba16_float, .usage = color }),
        },
        .rays = try device.createBuffer(.{
            .name = "gi rays",
            .size = @as(u64, probe_count) * rays_per_probe * @sizeOf([4]f32),
            .usage = .{ .storage = true },
        }),
    };
    return &slot.*.?;
}

/// Sizes the probe volume and the TLAS for this frame. Returns null when global
/// illumination is off, unsupported or there is nothing to trace.
pub fn prepareGi(renderer: *Renderer, scene: *SceneData, scene_frame: SceneFrame, settings: Settings, camera_position: Vec3) !?*GiVolume {
    const device = renderer.device;
    const pipelines = renderer.gi_pipelines orelse return null;
    _ = pipelines;
    var gi_max_counts: [3]u32 = undefined;
    inline for (0..3) |axis| gi_max_counts[axis] = std.math.clamp(renderer.options.gi_max_probes[axis], 2, gi_probe_limit);
    if (!settings.global_illumination or scene_frame.tlas_count == 0) return null;
    if (scene.tlas == null or scene.tlas_capacity < scene_frame.tlas_count) {
        if (scene.tlas) |old| device.destroyAcceleration(old);
        scene.tlas = null;
        scene.tlas_capacity = @max(scene_frame.tlas_count * 2, 256);
        scene.tlas = try device.createTlas(scene.tlas_capacity);
        scene.tlas_hash = 0;
    }

    const bounds = scene.gi_bounds orelse scene_frame.bounds;
    const extent = math.sub(bounds[1], bounds[0]);
    const wanted = @max(settings.gi_probe_spacing, 0.25);
    var spacing = wanted;
    inline for (0..3) |axis| spacing = @max(spacing, extent[axis] / @as(f32, @floatFromInt(gi_max_counts[axis] - 1)));
    const stretched = spacing;
    const follow = settings.gi_follow_camera and scene.gi_bounds == null and spacing > wanted * settings.gi_follow_threshold;
    if (follow) spacing = wanted;
    var cell: [3]i32 = undefined;
    var counts: [3]u32 = undefined;
    inline for (0..3) |axis| {
        const first: i32 = @intFromFloat(@floor((bounds[0][axis] + scene.origin[axis]) / spacing));
        const needed: f32 = @floatCast(@ceil((bounds[1][axis] + scene.origin[axis]) / spacing) - @as(f64, @floatFromInt(first)) + 1);
        counts[axis] = std.math.clamp(@as(u32, @intFromFloat(@max(needed, 2))), 2, gi_max_counts[axis]);
        cell[axis] = if (follow and needed > @as(f32, @floatFromInt(gi_max_counts[axis])))
            @as(i32, @intFromFloat(@floor((camera_position[axis] + scene.origin[axis]) / spacing))) - @as(i32, @intCast(counts[axis] / 2))
        else
            first;
    }
    const rays_per_probe = std.math.clamp(settings.gi_rays, 16, 256);
    const main = try ensureGiVolume(renderer, &scene.gi, scene.origin, cell, counts, spacing, rays_per_probe);
    if (follow) {
        var coarse_cell: [3]i32 = undefined;
        var coarse_counts: [3]u32 = undefined;
        inline for (0..3) |axis| {
            const first: i32 = @intFromFloat(@floor((bounds[0][axis] + scene.origin[axis]) / stretched));
            const needed: f32 = @floatCast(@ceil((bounds[1][axis] + scene.origin[axis]) / stretched) - @as(f64, @floatFromInt(first)) + 1);
            coarse_counts[axis] = std.math.clamp(@as(u32, @intFromFloat(@max(needed, 2))), 2, gi_max_counts[axis]);
            coarse_cell[axis] = first;
        }
        _ = try ensureGiVolume(renderer, &scene.gi_coarse, scene.origin, coarse_cell, coarse_counts, stretched, rays_per_probe);
        const ratio = stretched / wanted;
        if (settings.gi_middle_ratio > 0 and ratio > settings.gi_middle_ratio) {
            const middle_spacing = wanted * @sqrt(ratio);
            var middle_cell: [3]i32 = undefined;
            var middle_counts: [3]u32 = undefined;
            inline for (0..3) |axis| {
                const first: i32 = @intFromFloat(@floor((bounds[0][axis] + scene.origin[axis]) / middle_spacing));
                const needed: f32 = @floatCast(@ceil((bounds[1][axis] + scene.origin[axis]) / middle_spacing) - @as(f64, @floatFromInt(first)) + 1);
                middle_counts[axis] = std.math.clamp(@as(u32, @intFromFloat(@max(needed, 2))), 2, gi_max_counts[axis]);
                middle_cell[axis] = if (needed > @as(f32, @floatFromInt(gi_max_counts[axis])))
                    @as(i32, @intFromFloat(@floor((camera_position[axis] + scene.origin[axis]) / middle_spacing))) - @as(i32, @intCast(middle_counts[axis] / 2))
                else
                    first;
            }
            _ = try ensureGiVolume(renderer, &scene.gi_middle, scene.origin, middle_cell, middle_counts, middle_spacing, rays_per_probe);
        } else if (scene.gi_middle) |*middle| {
            middle.deinit(device);
            scene.gi_middle = null;
        }
    } else if (scene.gi_coarse) |*coarse| {
        coarse.deinit(device);
        scene.gi_coarse = null;
        if (scene.gi_middle) |*middle| {
            middle.deinit(device);
            scene.gi_middle = null;
        }
    }
    return main;
}

/// Traces this frame's probe rays and blends them into the atlases.
pub fn updateGi(
    renderer: *Renderer,
    cmd: *rhi.CommandEncoder,
    scene: *SceneData,
    volume: *GiVolume,
    scene_frame: SceneFrame,
    frame_address: u64,
    settings: Settings,
    grid_index: u32,
) !void {
    const device = renderer.device;
    const pipelines = renderer.gi_pipelines.?;
    cmd.beginScope("global illumination");
    defer cmd.endScope();
    const tlas = scene.tlas.?;
    if (scene.tlas_hash != scene_frame.tlas_hash) {
        cmd.buildTlas(tlas, scene_frame.tlas_instances, scene_frame.tlas_count);
        scene.tlas_hash = scene_frame.tlas_hash;
    }

    const turn: f64 = @floatFromInt(renderer.frame_index + 1);
    const first: f32 = @floatCast(@mod(turn * 0.8191725133961645, 1.0));
    const second: f32 = @floatCast(@mod(turn * 0.6710436067037893, 1.0));
    const third: f32 = @floatCast(@mod(turn * 0.5497004779019703, 1.0));
    const rotation = math.fromQuat(.{
        @sqrt(1 - first) * @sin(std.math.tau * second),
        @sqrt(1 - first) * @cos(std.math.tau * second),
        @sqrt(first) * @sin(std.math.tau * third),
        @sqrt(first) * @cos(std.math.tau * third),
    });
    const rotation_columns = [3][4]f32{ rotation[0..4].*, rotation[4..8].*, rotation[8..12].* };
    // Clamp distances just beyond the neighbouring probes, to keep the moments
    // well conditioned.
    const max_distance = volume.spacing * 1.75 * 1.5;
    const probe_count = volume.probeCount();
    const moved = volume.shift[0] != 0 or volume.shift[1] != 0 or volume.shift[2] != 0;
    const stride: u32 = if (volume.frames < 200 or moved) 1 else std.math.clamp(settings.gi_update_interval, 1, 16);
    const phase: u32 = @intCast(renderer.frame_index % stride);

    cmd.bindPipeline(pipelines.trace);
    cmd.pushConstants(extern struct {
        frame: u64,
        rays: u64,
        tlas: u64,
        rotation: [3][4]f32,
        rays_per_probe: u32,
        probe_count: u32,
        multibounce: u32,
        max_distance: f32,
        probe_stride: u32,
        probe_phase: u32,
        grid: u32,
        skip_buried: u32,
    }{
        .frame = frame_address,
        .rays = device.bufferAddress(volume.rays),
        .tlas = device.accelerationAddress(tlas),
        .rotation = rotation_columns,
        .rays_per_probe = volume.rays_per_probe,
        .probe_count = probe_count,
        // Multibounce needs every grid in use written at least once.
        .multibounce = @intFromBool(volume.frames != 0 and
            (if (scene.gi) |other| other.frames != 0 else true) and
            (if (scene.gi_coarse) |other| other.frames != 0 else true) and
            (if (scene.gi_middle) |other| other.frames != 0 else true)),
        .probe_stride = stride,
        .probe_phase = phase,
        .grid = grid_index,
        .skip_buried = @intFromBool(settings.gi_skip_buried_probes),
        .max_distance = 1000,
    });
    cmd.dispatch((((probe_count + stride - 1) / stride) * volume.rays_per_probe + 63) / 64, 1, 1);
    cmd.sync(.compute_to_all);

    // Hysteresis: probes traced every `stride` frames blend more per update;
    // early updates weigh twice an even average until the steady rate.
    const settled = std.math.pow(f32, std.math.clamp(settings.gi_hysteresis, 0, 0.999), @floatFromInt(stride));
    const gathered: f32 = @floatFromInt(volume.frames);
    const hysteresis: f32 = if (volume.frames == 0) 0 else @min(settled, @max(0.8, 1 - 2 / (gathered + 2)));
    const UpdatePush = extern struct {
        frame: u64,
        rays: u64,
        rotation: [3][4]f32,
        rays_per_probe: u32,
        hysteresis: f32,
        max_distance: f32,
        probe_stride: u32,
        probe_phase: u32,
        fast_hysteresis: f32,
        /// Grid cells the volume moved by; probes that wrapped start over.
        shift: [3]i32,
        grid: u32,
    };
    const RelocatePush = extern struct { update: UpdatePush, previous_offsets: u32, pad: [3]u32 = .{ 0, 0, 0 } };
    const update_push = UpdatePush{
        .frame = frame_address,
        .rays = device.bufferAddress(volume.rays),
        .rotation = rotation_columns,
        .rays_per_probe = volume.rays_per_probe,
        .hysteresis = hysteresis,
        .max_distance = max_distance,
        .probe_stride = stride,
        .probe_phase = phase,
        .fast_hysteresis = if (volume.frames == 0) 0 else 0.9,
        .shift = volume.shift,
        .grid = grid_index,
    };
    const load: rhi.LoadOp = if (volume.frames == 0) .clear else .load;
    try cmd.beginRendering(.{ .color = &.{
        .{ .texture = volume.irradiance, .load = load },
        .{ .texture = volume.irradiance_fast, .load = load },
    } });
    cmd.bindPipeline(pipelines.irradiance);
    cmd.pushConstants(update_push);
    cmd.drawFullscreen();
    cmd.endRendering();
    cmd.transition(volume.irradiance_fast, .shader_read);
    const tolerance = std.math.clamp(settings.gi_change_tolerance, 0, 4);
    if (tolerance > 0 and volume.frames != 0) {
        const ClampPush = extern struct { frame: u64, fast: u32, scale: f32, offset: f32, pad: u32 = 0 };
        for ([_]rhi.Pipeline{ pipelines.clamp_upper, pipelines.clamp_lower }, [_]f32{ 1, -1 }) |pipeline, sign| {
            try cmd.beginRendering(.{ .color = &.{.{ .texture = volume.irradiance, .load = .load }} });
            cmd.bindPipeline(pipeline);
            cmd.pushConstants(ClampPush{
                .frame = frame_address,
                .fast = device.textureIndex(volume.irradiance_fast),
                .scale = @max(1 + sign * tolerance, 0),
                .offset = sign * 0.002,
            });
            cmd.drawFullscreen();
            cmd.endRendering();
        }
    }
    cmd.transition(volume.irradiance, .shader_read);
    try cmd.beginRendering(.{ .color = &.{.{ .texture = volume.visibility, .load = load }} });
    cmd.bindPipeline(pipelines.visibility);
    cmd.pushConstants(update_push);
    cmd.drawFullscreen();
    cmd.endRendering();
    cmd.transition(volume.visibility, .shader_read);
    if (settings.gi_probe_relocation) {
        // Relocation takes effect from the next frame's trace.
        const read = volume.offsets[volume.offset_turn];
        const write = volume.offsets[1 - volume.offset_turn];
        if (!volume.offsets_valid) {
            try cmd.beginRendering(.{ .color = &.{.{ .texture = read, .load = .clear, .clear = .{ 0, 0, 0, 0 } }} });
            cmd.endRendering();
            cmd.transition(read, .shader_read);
        }
        try cmd.beginRendering(.{ .color = &.{.{ .texture = write, .load = .discard }} });
        cmd.bindPipeline(pipelines.relocate);
        var relocate_push = RelocatePush{ .update = update_push, .previous_offsets = device.textureIndex(read) };
        relocate_push.update.grid = grid_index;
        cmd.pushConstants(relocate_push);
        cmd.drawFullscreen();
        cmd.endRendering();
        cmd.transition(write, .shader_read);
        volume.offset_turn = 1 - volume.offset_turn;
        volume.offsets_valid = true;
    } else volume.offsets_valid = false;
    volume.frames +|= 1;
    renderer.stats.gi_probes = probe_count;
}
