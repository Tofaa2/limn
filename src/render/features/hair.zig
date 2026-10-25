//! Strands of a scene's hair.
const pipelines_module = @import("../renderer/pipelines.zig");
const hair_push = @import("../shaders/push/hair.zig");
const scene_pass = @import("../scene_pass.zig");
const gpu = @import("../gpu.zig");
const math = @import("../../math.zig");
const rhi = @import("../../rhi/rhi.zig");
const std = @import("std");
const render = @import("../renderer.zig");
const features = @import("../core/features.zig");

const ScenePass = scene_pass.ScenePass;
const Renderer = render.Renderer;
const density_size = render.hair_density_size;
const ViewContext = features.ViewContext;
const HairState = @import("../state.zig").HairState;

/// Adds the feature's passes to a view of a scene. A path traced view leaves
/// out those whose result the tracer replaces.
pub fn declare(ctx: *ViewContext) !void {
    const p = ctx.scene orelse return;
    if (p.tracing) return;
    const g = ctx.graph;
    try g.add(.{ .name = "hair", .stage = .transparent, .always = true, .scope = false }, ctx, drawHairPass);
}

fn drawHairPass(ctx: *ViewContext) !void {
    const p = ctx.scene.?;
    try drawHair(ctx.renderer, p);
}

const HairPush = hair_push.HairPush;

/// Must match `Params` in hair.slang.
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

const density_bytes = density_size * density_size * density_size * @sizeOf(u32);

/// Steps the scene's simulated hair.
pub fn simulateHair(renderer: *Renderer, p: *const ScenePass, delta_time: f32) !void {
    const device = renderer.device;
    const cmd = p.cmd;
    const dt = @min(delta_time, longest_step);
    if (dt <= 0) return;
    var any = false;
    for (p.scene.hairs.items) |handle| {
        const hair = renderer.hairs.internal.table.get(handle) orelse continue;
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
    cmd.bindPipeline(try renderer.internal.pipelines.of(hairSimulationPipeline));
    for (p.scene.hairs.items) |handle| {
        const hair = renderer.hairs.internal.table.get(handle) orelse continue;
        const simulation = hair.simulation orelse continue;
        const moving = &hair.moving.?;
        const next = 1 - moving.current;
        const scale = math.maxScale(hair.desc.transform);
        const middle = math.transformPoint(hair.desc.transform, hair.bounds[0..3].*);
        const half = hair.bounds[3] * scale * 1.5;
        const density_low = [3]f32{ middle[0] - half, middle[1] - half, middle[2] - half };
        const density_cell = 2 * half / @as(f32, density_size);
        const field: ?*render.CollisionFieldState = if (simulation.field) |field_handle| renderer.hairs.internal.fields.get(field_handle) else null;
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
            .time = renderer.internal.time,
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
            .reset = @intFromBool(moving.steps < 2),
            .field_texture = if (field) |state| device.textureIndex(state.texture) else gpu.invalid_id,
            .field_size = if (field) |state| state.size else 1,
            .density_size = density_size,
            .colliders = hair.colliders,
        };
        cmd.pushConstants(hair_push.SimPush{ .frame = p.frame_address, .params = params.address });
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

/// The grid round a hair as it is drawn: its low corner and cell size.
const Grid = struct { low: [3]f32, cell: f32 };

fn gridOf(hair: *const HairState) Grid {
    const middle = math.transformPoint(hair.desc.transform, hair.bounds[0..3].*);
    const half = hair.bounds[3] * math.maxScale(hair.desc.transform) * 1.5;
    return .{ .low = .{ middle[0] - half, middle[1] - half, middle[2] - half }, .cell = 2 * half / @as(f32, density_size) };
}

/// The points a hair is drawn from this frame, and the transform that
/// places them.
fn drawnPoints(hair: *const HairState) struct { points: rhi.Buffer, previous: rhi.Buffer, transform: [16]f32 } {
    if (hair.moving) |moving| if (moving.steps != 0) return .{ .points = moving.points[moving.current], .previous = moving.points[1 - moving.current], .transform = math.identity };
    return .{ .points = hair.points, .previous = hair.points, .transform = hair.desc.transform };
}

/// Uploads how a hair is drawn and returns its address.
fn uploadLook(renderer: *Renderer, p: *const ScenePass, hair: *const HairState) !u64 {
    const device = renderer.device;
    const scale = math.maxScale(hair.desc.transform);
    const in_world: f32 = if (hair.moving) |moving| (if (moving.steps != 0) scale else 1) else 1;
    const width = hair.desc.width * in_world;
    const grid = gridOf(hair);
    const look = try p.arena.alloc(device, hair_push.HairLook, 1);
    look.items[0] = .{
        .light = if (hair.shade) |shade| device.bufferAddress(shade.light) else 0,
        .root_color = hair.desc.root_color,
        .root_width = width,
        .tip_color = hair.desc.tip_color,
        .tip_width = width * std.math.clamp(hair.desc.taper, 0, 1),
        .grid_low = grid.low,
        .grid_cell = grid.cell,
        .roughness = hair.desc.roughness,
        .variation = std.math.clamp(hair.desc.variation, 0, 1),
        .spread = hair.desc.spread * scale,
        .clump = std.math.clamp(hair.desc.clump, 0, 1),
        .curl = @max(hair.desc.curl, 0) * scale,
        .curl_turns = hair.desc.curl_turns,
        .frizz = @max(hair.desc.frizz, 0) * scale,
        .points_per_strand = hair.desc.points_per_strand,
        .grid_size = density_size,
    };
    return look.address;
}

/// Draws the scene's hair into a sun shadow map in the open render pass, with
/// `view_proj` or into virtual shadow map page `page` if not 0. `texel` is the
/// world size of a shadow texel.
pub fn drawHairShadows(renderer: *Renderer, p: *const ScenePass, view_proj: [16]f32, texel: f32, page: u64) !void {
    const device = renderer.device;
    const cmd = p.cmd;
    if (p.scene.hairs.items.len == 0) return;
    cmd.bindPipeline(try renderer.internal.pipelines.of(hairShadowPipeline));
    for (p.scene.hairs.items) |handle| {
        const hair = renderer.hairs.internal.table.get(handle) orelse continue;
        const drawn = drawnPoints(hair);
        cmd.pushConstants(hair_push.ShadowPush{
            .frame = p.frame_address,
            .points = device.bufferAddress(drawn.points),
            .page = page,
            .look = try uploadLook(renderer, p, hair),
            .view_proj = view_proj,
            .transform = drawn.transform,
            .light = math.normalize(p.scene.sun.direction),
            .least_width = texel * 0.75,
            .paged = @intFromBool(page != 0),
        });
        cmd.draw(hair.stretches * 6, @max(hair.desc.copies, 1), 0, 0);
    }
}

const grid_bytes = density_size * density_size * density_size * @sizeOf(u32);
const light_bytes = density_size * density_size * density_size * 4 * @sizeOf(f32);

/// Counts each hair's points into its grid and works out how much light
/// reaches each cell of it.
fn lightHair(renderer: *Renderer, p: *const ScenePass) !void {
    const device = renderer.device;
    const cmd = p.cmd;
    cmd.sync(.all_to_transfer);
    for (p.scene.hairs.items) |handle| {
        const hair = renderer.hairs.internal.table.get(handle) orelse continue;
        if (hair.shade == null) {
            const counts = try device.createBuffer(.{ .name = "hair counts", .size = grid_bytes, .usage = .{ .storage = true, .copy_dst = true } });
            errdefer device.destroyBuffer(counts);
            const light = try device.createBuffer(.{ .name = "hair light", .size = light_bytes, .usage = .{ .storage = true } });
            hair.shade = .{ .counts = counts, .light = light };
        }
        cmd.fillBuffer(hair.shade.?.counts, 0, grid_bytes, 0);
    }
    cmd.sync(.transfer_to_all);
    cmd.bindPipeline(try renderer.internal.pipelines.of(hairCountPipeline));
    for (p.scene.hairs.items) |handle| {
        const hair = renderer.hairs.internal.table.get(handle) orelse continue;
        const drawn = drawnPoints(hair);
        const grid = gridOf(hair);
        const point_count = hair.strands * hair.desc.points_per_strand;
        cmd.pushConstants(hair_push.CountPush{
            .points = device.bufferAddress(drawn.points),
            .counts = device.bufferAddress(hair.shade.?.counts),
            .transform = drawn.transform,
            .grid_low = grid.low,
            .grid_cell = grid.cell,
            .point_count = point_count,
            .grid_size = density_size,
        });
        cmd.dispatch((point_count + 63) / 64, 1, 1);
    }
    cmd.sync(.compute_to_all);
    cmd.bindPipeline(try renderer.internal.pipelines.of(hairLightPipeline));
    for (p.scene.hairs.items) |handle| {
        const hair = renderer.hairs.internal.table.get(handle) orelse continue;
        const grid = gridOf(hair);
        const scale = math.maxScale(hair.desc.transform);
        const width = hair.desc.width * (1 + std.math.clamp(hair.desc.taper, 0, 1)) * 0.5 * scale;
        const copies: f32 = @floatFromInt(@max(hair.desc.copies, 1));
        cmd.pushConstants(hair_push.LightPush{
            .counts = device.bufferAddress(hair.shade.?.counts),
            .light = device.bufferAddress(hair.shade.?.light),
            .to_sun = math.scale(math.normalize(p.scene.sun.direction), -1),
            .fibre = std.math.pi / 4.0 * hair.segment * scale * width * copies / (grid.cell * grid.cell * grid.cell),
            .grid_cell = grid.cell,
            .grid_size = density_size,
        });
        cmd.dispatch((density_size * density_size * density_size + 63) / 64, 1, 1);
    }
    cmd.sync(.compute_to_all);
}

/// Draws the scene's hair over the lit scene, writing depth.
pub fn drawHair(renderer: *Renderer, p: *const ScenePass) !void {
    const device = renderer.device;
    const cmd = p.cmd;
    const view = p.view;
    if (p.scene.hairs.items.len == 0 or p.debugging) return;
    cmd.beginScope("hair");
    try lightHair(renderer, p);
    try cmd.beginRendering(.{
        .color = &.{ .{ .texture = view.hdr, .load = .load }, .{ .texture = view.motion, .load = .load } },
        .depth = .{ .texture = view.depth, .load = .load },
    });
    cmd.bindPipeline(try renderer.internal.pipelines.of(hairPipeline));
    for (p.scene.hairs.items) |handle| {
        const hair = renderer.hairs.internal.table.get(handle) orelse continue;
        const drawn = drawnPoints(hair);
        cmd.pushConstants(HairPush{
            .frame = p.frame_address,
            .points = device.bufferAddress(drawn.points),
            .previous_points = device.bufferAddress(drawn.previous),
            .look = try uploadLook(renderer, p, hair),
            .transform = drawn.transform,
            .previous_transform = if (hair.moving != null and hair.moving.?.steps != 0) math.identity else hair.shown_transform orelse hair.desc.transform,
        });
        cmd.draw(hair.stretches * 6, @max(hair.desc.copies, 1), 0, 0);
        hair.shown_transform = hair.desc.transform;
    }
    cmd.endRendering();
    cmd.endScope();
}

fn hairSimulationPipeline(_: *rhi.Device) pipelines_module.Desc {
    return .{ .compute = .{ .name = "hair simulation", .shader = pipelines_module.shaderCode("hair_sim.comp.spv") } };
}

fn hairCountPipeline(_: *rhi.Device) pipelines_module.Desc {
    return .{ .compute = .{ .name = "hair counts", .shader = pipelines_module.shaderCode("hair_count.comp.spv") } };
}

fn hairLightPipeline(_: *rhi.Device) pipelines_module.Desc {
    return .{ .compute = .{ .name = "hair light", .shader = pipelines_module.shaderCode("hair_light.comp.spv") } };
}

fn hairShadowPipeline(_: *rhi.Device) pipelines_module.Desc {
    return .{ .graphics = .{
        .name = "hair shadow",
        .vertex = pipelines_module.shaderCode("hair_shadow.vert.spv"),
        .fragment = pipelines_module.shaderCode("hair_shadow.frag.spv"),
        .depth = pipelines_module.shadow_depth,
        .cull = .none,
    } };
}
fn hairPipeline(_: *rhi.Device) pipelines_module.Desc {
    return .{ .graphics = .{
        .name = "hair",
        .vertex = pipelines_module.shaderCode("hair.vert.spv"),
        .fragment = pipelines_module.shaderCode("hair.frag.spv"),
        .color_targets = &.{ .{ .format = pipelines_module.hdr_format, .blend = .premultiplied }, .{ .format = .rg16_float, .blend = .alpha } },
        .depth = .{ .write = true, .compare = .greater_or_equal },
        .cull = .none,
    } };
}
