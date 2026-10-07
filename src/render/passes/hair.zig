//! Hair simulation and drawing. Internal to the renderer.
const std = @import("std");
const rhi = @import("../../rhi/rhi.zig");
const math = @import("../../math.zig");
const gpu = @import("../gpu.zig");
const render = @import("../renderer.zig");
const scene_pass = @import("../scene_pass.zig");

const Renderer = render.Renderer;
const ScenePass = scene_pass.ScenePass;

/// Push constants of hair.vert and hair.frag (`HAIR_PUSH` in hair.glsl).
const HairPush = extern struct {
    frame: u64,
    points: u64,
    previous_points: u64,
    transform: [16]f32,
    previous_transform: [16]f32,
    root_color: [3]f32,
    root_width: f32,
    tip_color: [3]f32,
    tip_width: f32,
    points_per_strand: u32,
    roughness: f32,
    spread: f32,
    pad: f32 = 0,
};

/// Must match `Params` in hair_sim.comp.
const SimulationParams = extern struct {
    rest: u64,
    current: u64,
    next: u64,
    density_before: u64,
    density_now: u64,
    transform: [16]f32,
    world_to_field: [16]f32,
    gravity: [3]f32,
    damping: f32,
    wind: [3]f32,
    gustiness: f32,
    field_low: [3]f32,
    field_cell: f32,
    density_low_before: [3]f32,
    density_cell_before: f32,
    density_low_now: [3]f32,
    density_cell_now: f32,
    time: f32,
    dt: f32,
    previous_dt: f32,
    stiffness: f32,
    root_stiffness: f32,
    field_scale: f32,
    margin: f32,
    volume: f32,
    strand_count: u32,
    points_per_strand: u32,
    collider_count: u32,
    reset: u32,
    field_texture: u32,
    field_size: u32,
    density_size: u32,
    pad: u32 = 0,
    colliders: [render.max_hair_colliders][4]f32,
};

/// Maximum simulation step, in seconds.
const longest_step = 1.0 / 30.0;

const density_size = render.hair_density_size;
const density_bytes = density_size * density_size * density_size * @sizeOf(u32);

/// Steps the scene's simulated hair.
pub fn simulateHair(renderer: *Renderer, p: *const ScenePass, delta_time: f32) !void {
    const device = renderer.device;
    const cmd = p.cmd;
    const dt = @min(delta_time, longest_step);
    if (dt <= 0) return;
    var any = false;
    for (p.scene.hairs.items) |handle| {
        const hair = renderer.hairs.get(handle) orelse continue;
        if (hair.simulation == null) continue;
        if (hair.moving == null) {
            var made: [4]?rhi.Buffer = @splat(null);
            errdefer for (made) |buffer| if (buffer) |value| device.destroyBuffer(value);
            const size = @as(u64, hair.strands) * hair.desc.points_per_strand * 16;
            for (made[0..2]) |*buffer| buffer.* = try device.createBuffer(.{ .name = "hair in motion", .size = size, .usage = .{ .storage = true } });
            for (made[2..4]) |*buffer| buffer.* = try device.createBuffer(.{ .name = "hair density", .size = density_bytes, .usage = .{ .storage = true, .copy_dst = true } });
            hair.moving = .{ .points = .{ made[0].?, made[1].? }, .density = .{ made[2].?, made[3].? } };
        }
        const moving = &hair.moving.?;
        if (!any) cmd.sync(.all_to_transfer);
        any = true;
        cmd.fillBuffer(moving.density[1 - moving.current], 0, density_bytes, 0);
        if (moving.steps == 0) cmd.fillBuffer(moving.density[moving.current], 0, density_bytes, 0);
    }
    if (!any) return;
    cmd.sync(.transfer_to_all);
    cmd.beginScope("hair simulation");
    cmd.bindPipeline(renderer.pipelines.hair_simulation);
    for (p.scene.hairs.items) |handle| {
        const hair = renderer.hairs.get(handle) orelse continue;
        const simulation = hair.simulation orelse continue;
        const moving = &hair.moving.?;
        const next = 1 - moving.current;
        const scale = math.maxScale(hair.desc.transform);
        const middle = math.transformPoint(hair.desc.transform, hair.bounds[0..3].*);
        const half = hair.bounds[3] * scale * 1.5;
        const density_low = [3]f32{ middle[0] - half, middle[1] - half, middle[2] - half };
        const density_cell = 2 * half / @as(f32, density_size);
        const field: ?*render.CollisionFieldState = if (simulation.field) |field_handle| renderer.collision_fields.get(field_handle) else null;
        const params = try p.arena.alloc(device, SimulationParams, 1);
        params.items[0] = .{
            .rest = device.bufferAddress(hair.points),
            .current = device.bufferAddress(moving.points[moving.current]),
            .next = device.bufferAddress(moving.points[next]),
            .density_before = device.bufferAddress(moving.density[moving.current]),
            .density_now = device.bufferAddress(moving.density[next]),
            .transform = hair.desc.transform,
            .world_to_field = math.inverse(simulation.field_transform),
            .gravity = simulation.gravity,
            .damping = std.math.clamp(simulation.damping, 0, 1),
            .wind = simulation.wind,
            .gustiness = simulation.gustiness,
            .field_low = if (field) |state| state.low else .{ 0, 0, 0 },
            .field_cell = if (field) |state| state.cell else 1,
            .density_low_before = if (moving.steps == 0) density_low else moving.density_low,
            .density_cell_before = if (moving.steps == 0) density_cell else moving.density_cell,
            .density_low_now = density_low,
            .density_cell_now = density_cell,
            .time = renderer.time,
            .dt = dt,
            .previous_dt = moving.previous_dt,
            .stiffness = simulation.stiffness,
            .root_stiffness = simulation.root_stiffness,
            .field_scale = @max(math.maxScale(simulation.field_transform), 1e-9),
            .margin = @max(simulation.margin, 0),
            .volume = @max(simulation.volume, 0),
            .strand_count = hair.strands,
            .points_per_strand = hair.desc.points_per_strand,
            .collider_count = hair.collider_count,
            // Two reset steps fill both point buffers.
            .reset = @intFromBool(moving.steps < 2),
            .field_texture = if (field) |state| device.textureIndex(state.texture) else gpu.invalid_id,
            .field_size = if (field) |state| state.size else 1,
            .density_size = density_size,
            .colliders = hair.colliders,
        };
        cmd.pushConstants(extern struct { frame: u64, params: u64 }{ .frame = p.frame_address, .params = params.address });
        cmd.dispatch((hair.strands + 63) / 64, 1, 1);
        moving.current = next;
        moving.steps +|= 1;
        moving.previous_dt = dt;
        moving.density_low = density_low;
        moving.density_cell = density_cell;
    }
    cmd.sync(.compute_to_all);
    cmd.endScope();
}

/// Draws the scene's hair into a sun shadow map in the open render pass, with
/// `view_proj` or into virtual shadow map page `page` if not 0. `texel` is the
/// world size of a shadow texel.
pub fn drawHairShadows(renderer: *Renderer, p: *const ScenePass, view_proj: [16]f32, texel: f32, page: u64) void {
    const device = renderer.device;
    const cmd = p.cmd;
    if (p.scene.hairs.items.len == 0) return;
    cmd.bindPipeline(renderer.pipelines.hair_shadow);
    for (p.scene.hairs.items) |handle| {
        const hair = renderer.hairs.get(handle) orelse continue;
        const moving = if (hair.moving) |moving| (if (moving.steps != 0) moving else null) else null;
        const width = hair.desc.width * (if (moving != null) math.maxScale(hair.desc.transform) else 1);
        const spread = hair.desc.spread * (if (moving != null) math.maxScale(hair.desc.transform) else 1);
        const least = texel * 0.75 / (if (moving != null) 1 else @max(math.maxScale(hair.desc.transform), 1e-9));
        cmd.pushConstants(extern struct { frame: u64, points: u64, page: u64, view_proj: [16]f32, transform: [16]f32, light: [3]f32, root_width: f32, tip_width: f32, least_width: f32, points_per_strand: u32, paged: u32, spread: f32, pad: f32 = 0 }{
            .frame = p.frame_address,
            .points = device.bufferAddress(if (moving) |state| state.points[state.current] else hair.points),
            .page = page,
            .view_proj = view_proj,
            .transform = if (moving != null) math.identity else hair.desc.transform,
            .light = math.normalize(p.scene.sun.direction),
            .root_width = width,
            .tip_width = width * std.math.clamp(hair.desc.taper, 0, 1),
            .least_width = least,
            .points_per_strand = hair.desc.points_per_strand,
            .paged = @intFromBool(page != 0),
            .spread = spread,
        });
        cmd.draw(hair.stretches * 6, @max(hair.desc.copies, 1), 0, 0);
    }
}

/// Draws the scene's hair over the lit scene, writing depth.
pub fn drawHair(renderer: *Renderer, p: *const ScenePass) !void {
    const device = renderer.device;
    const cmd = p.cmd;
    const view = p.view;
    if (p.scene.hairs.items.len == 0 or p.debugging) return;
    cmd.beginScope("hair");
    try cmd.beginRendering(.{
        .color = &.{ .{ .texture = view.hdr, .load = .load }, .{ .texture = view.motion, .load = .load } },
        .depth = .{ .texture = view.depth, .load = .load },
    });
    cmd.bindPipeline(renderer.pipelines.hair);
    for (p.scene.hairs.items) |handle| {
        const hair = renderer.hairs.get(handle) orelse continue;
        const moving = if (hair.moving) |moving| (if (moving.steps != 0) moving else null) else null;
        const in_world: f32 = if (moving != null) math.maxScale(hair.desc.transform) else 1;
        const width = hair.desc.width * in_world;
        cmd.pushConstants(HairPush{
            .frame = p.frame_address,
            .points = device.bufferAddress(if (moving) |state| state.points[state.current] else hair.points),
            .previous_points = device.bufferAddress(if (moving) |state| state.points[1 - state.current] else hair.points),
            .transform = if (moving != null) math.identity else hair.desc.transform,
            .previous_transform = if (moving != null) math.identity else hair.shown_transform orelse hair.desc.transform,
            .root_color = hair.desc.root_color,
            .root_width = width,
            .tip_color = hair.desc.tip_color,
            .tip_width = width * std.math.clamp(hair.desc.taper, 0, 1),
            .points_per_strand = hair.desc.points_per_strand,
            .roughness = hair.desc.roughness,
            .spread = hair.desc.spread * in_world,
        });
        cmd.draw(hair.stretches * 6, @max(hair.desc.copies, 1), 0, 0);
        hair.shown_transform = hair.desc.transform;
    }
    cmd.endRendering();
    cmd.transition(view.hdr, .shader_read);
    cmd.transition(view.motion, .shader_read);
    cmd.transition(view.depth, .shader_read);
    cmd.endScope();
}
