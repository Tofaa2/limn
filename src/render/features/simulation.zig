//! Steps a scene's fluids, water, liquids, hair and particles once a frame.
const pipelines_module = @import("../renderer/pipelines.zig");
const liquid_push = @import("../shaders/push/liquid.zig");
const water_passes_push = @import("../shaders/push/water_passes.zig");
const ocean_push = @import("../shaders/push/ocean.zig");
const fluid_passes_push = @import("../shaders/push/fluid_passes.zig");
const render = @import("../renderer.zig");
const restyleEntity = @import("../renderer/entity_edits.zig").restyleEntity;
const moveEntity = @import("../renderer/entity_edits.zig").moveEntity;
const transformOf = @import("../renderer/entity_edits.zig").transformOf;
const hair_feature = @import("hair.zig");
const particles_feature = @import("particles.zig");
const fluids_feature = @import("fluids.zig");
const gpu = @import("../gpu.zig");
const WaterState = @import("../state.zig").WaterState;
const rhi = @import("../../rhi/rhi.zig");
const std = @import("std");
const math = @import("../../math.zig");
const features = @import("../core/features.zig");

const packTint = render.packTint;
const liquid_cell_slots = render.liquid_cell_slots;
const SceneData = render.SceneData;
const FrameArena = render.FrameArena;
const Renderer = render.Renderer;
const EmitterDesc = render.EmitterDesc;
const WaterDesc = render.WaterDesc;
const Mat4 = math.Mat4;
const Vec3 = math.Vec3;
const ViewContext = features.ViewContext;

/// Adds the feature's passes to a view of a scene. A path traced view leaves
/// out those whose result the tracer replaces.
pub fn declare(ctx: *ViewContext) !void {
    if (ctx.scene == null) return;
    const g = ctx.graph;
    try g.add(.{ .name = "simulation", .stage = .prepare, .always = true, .scope = false }, ctx, simulate);
    try g.add(.{ .name = "particle simulation", .stage = .prepare, .always = true, .scope = false }, ctx, stepParticles);
}

fn simulate(ctx: *ViewContext) !void {
    const p = ctx.scene.?;
    const c = p.shared;
    if (c.fresh_scene) try simulateFluids(ctx.renderer, p.cmd, p.scene, c.arena, c.delta_time);
    if (c.fresh_scene) try simulateWater(ctx.renderer, p.cmd, p.scene, c.arena, c.delta_time);
    if (c.fresh_scene) try simulateLiquids(ctx.renderer, p.cmd, p.scene, c.arena, c.delta_time);
    if (c.fresh_scene) try hair_feature.simulateHair(ctx.renderer, p, c.delta_time);
    c.fluid_list.* = fluids_feature.shadowingFluids(ctx.renderer, p);
    try fluids_feature.lightFluids(ctx.renderer, p, c.lighting);
}

/// Runs after fluids, which may carry particles. Collides with the
/// depth this view drew last frame.
fn stepParticles(ctx: *ViewContext) !void {
    const p = ctx.scene.?;
    const c = p.shared;
    const device = ctx.renderer.device;
    if (c.fresh_scene) try particles_feature.simulateParticles(ctx.renderer, p.cmd, p.scene, c.arena, p.frame_address, c.delta_time, if (p.view_data.camera_known) device.textureIndex(p.view.depth) else null);
}

/// A liquid's box: unit axes, size along each, and low corner.
pub const LiquidBox = struct { axes: [3]Vec3, extent: Vec3, corner: Vec3 };

/// The box `transform` makes of the unit cube centered on the origin.
pub fn liquidBox(transform: Mat4) LiquidBox {
    var box: LiquidBox = undefined;
    const center = Vec3{ transform[12], transform[13], transform[14] };
    box.corner = center;
    inline for (0..3) |axis| {
        const column = Vec3{ transform[axis * 4], transform[axis * 4 + 1], transform[axis * 4 + 2] };
        box.extent[axis] = @max(math.length(column), 1e-4);
        box.axes[axis] = math.scale(column, 1 / box.extent[axis]);
        box.corner = math.sub(box.corner, math.scale(column, 0.5));
    }
    return box;
}

/// Rest density in solver units: a lattice h / 2 apart.
pub fn liquidRestDensity() f32 {
    var sum: f32 = 0;
    var x: i32 = -2;
    while (x <= 2) : (x += 1) {
        var y: i32 = -2;
        while (y <= 2) : (y += 1) {
            var z: i32 = -2;
            while (z <= 2) : (z += 1) {
                const q2 = @as(f32, @floatFromInt(x * x + y * y + z * z)) * 0.25;
                if (q2 >= 1) continue;
                const w = 1 - q2;
                sum += 315.0 / (64.0 * std.math.pi) * w * w * w;
            }
        }
    }
    return sum;
}

/// Fixed-range time step: accumulates `elapsed` in `owed` until at least 1/200
/// s and steps at most 1/30 s, dropping the rest. Returns 0 for no step.
pub fn steadyStep(owed: *f32, elapsed: f32) f32 {
    if (!(elapsed > 0)) return 0;
    owed.* = @min(owed.* + elapsed, 1.0 / 30.0);
    if (owed.* < 1.0 / 200.0) return 0;
    const step = owed.*;
    owed.* = 0;
    return step;
}

/// Most water steps taken in one frame; time beyond them is dropped.
const max_water_steps = 8;

/// How many steps of exactly `step` seconds to take for `elapsed`, at most
/// `most`, carrying the remainder in `owed` and dropping time beyond `most`.
/// Solvers that keep velocity as a difference of positions, or step waves
/// near their stability limit, gain energy when the step changes from one
/// step to the next, so they never take a ragged one.
fn fixedSteps(owed: *f32, elapsed: f32, step: f32, most: u32) u32 {
    if (!(elapsed > 0) or !(step > 0)) return 0;
    owed.* = @min(owed.* + elapsed, step * @as(f32, @floatFromInt(most)));
    const steps: u32 = @intFromFloat(@floor(owed.* / step));
    owed.* -= @as(f32, @floatFromInt(steps)) * step;
    return steps;
}

/// Splash emitter of a water surface; emits only when something hits it.
pub fn splashDesc(desc: WaterDesc) EmitterDesc {
    const t = desc.transform;
    const tint = [3]f32{ 0.55 + desc.color[0] * 0.45, 0.6 + desc.color[1] * 0.4, 0.65 + desc.color[2] * 0.35 };
    return .{
        .capacity = 4096,
        .rate = 0,
        .lifetime = .{ 0.35, 0.9 },
        .direction = math.normalize(.{ t[4], t[5], t[6] }),
        .spread = 0.9,
        .gravity = .{ 0, -9.8, 0 },
        .drag = 0.6,
        .size = .{ 0.03, 0.07 },
        .color_start = .{ tint[0], tint[1], tint[2], 0.75 },
        .color_end = .{ tint[0], tint[1], tint[2], 0 },
        .softness = 0.05,
    };
}

/// How much larger than its particle a liquid's drawn shape is, so that
/// neighbouring shapes meet.
pub const liquid_swell = 1.5;

/// Steps every liquid of a scene, once per frame.
pub fn simulateLiquids(renderer: *Renderer, cmd: *rhi.CommandEncoder, scene: *SceneData, arena: *FrameArena, delta_time: f32) !void {
    if (scene.liquids.items.len == 0) return;
    const device = renderer.device;
    cmd.beginScope("liquid simulation");
    defer cmd.endScope();
    const Push = liquid_push.SimPush;
    for (scene.liquids.items) |item| {
        const state = renderer.liquids.internal.table.get(item) orelse continue;
        const desc = state.desc;
        const box = liquidBox(desc.transform);
        const radius = desc.particle_radius;
        const spacing = radius * 2;
        const substeps = std.math.clamp(desc.substeps, 1, 8);
        const dt = 1.0 / (60.0 * @as(f32, @floatFromInt(substeps)));
        const steps = fixedSteps(&state.time_owed, delta_time * desc.time_scale, dt, substeps * 2);
        const frame_dt = dt * @as(f32, @floatFromInt(steps));
        var record = gpu.Liquid{
            .from_box = .{
                box.axes[0][0], box.axes[0][1], box.axes[0][2], 0,
                box.axes[1][0], box.axes[1][1], box.axes[1][2], 0,
                box.axes[2][0], box.axes[2][1], box.axes[2][2], 0,
                box.corner[0],  box.corner[1],  box.corner[2],  1,
            },
            .extent = box.extent,
            .h = radius * 4,
            .cells = state.grid,
            .slots = liquid_cell_slots,
            .live_before = state.live,
            .live = state.live,
            .block_count = @min(state.block[0] * state.block[1] * state.block[2], state.capacity),
            .block_nx = @max(state.block[0], 1),
            .block_nz = @max(state.block[2], 1),
            .spacing = spacing,
            .dt = dt,
            .rest_density = liquidRestDensity(),
            .gravity = .{ math.dot(desc.gravity, box.axes[0]), math.dot(desc.gravity, box.axes[1]), math.dot(desc.gravity, box.axes[2]) },
            .radius = radius,
            .block_origin = .{ radius, radius, radius },
            .seed = @truncate(renderer.internal.frame_index *% 2654435761),
            .color = desc.color,
            .murk = @max(desc.murk, 0),
            .source_count = state.source_count,
            .sphere_count = 0,
            .refraction = @max(desc.refraction, 0),
            .keep = @exp(-@max(desc.damping, 0) * dt),
            .viscosity = std.math.clamp(desc.viscosity, 0, 1),
            .detail = std.math.clamp(desc.ripple_detail, 0, 2),
            .scatter = @max(desc.scatter, 0),
            .fill = spacing * spacing * spacing / (4.0 / 3.0 * std.math.pi * std.math.pow(f32, radius * liquid_swell, 3)),
            .foam = std.math.clamp(desc.foam, 0, 1),
            .foam_kept = @exp(-frame_dt * 1.5),
            .swell = liquid_swell,
            .frame_dt = frame_dt,
        };
        for (state.sources[0..state.source_count], record.sources[0..state.source_count]) |source, *out| {
            const from_corner = math.sub(source.position, box.corner);
            out.* = .{
                .position = .{ math.dot(from_corner, box.axes[0]), math.dot(from_corner, box.axes[1]), math.dot(from_corner, box.axes[2]) },
                .radius = @max(source.radius, radius),
                .velocity = .{ math.dot(source.velocity, box.axes[0]), math.dot(source.velocity, box.axes[1]), math.dot(source.velocity, box.axes[2]) },
            };
        }
        if (desc.obstacles) for (scene.entities.items) |entity_handle| {
            if (record.sphere_count == record.spheres.len) break;
            const entity = renderer.entities.internal.table.get(entity_handle) orelse continue;
            if (!entity.visible) continue;
            const model = renderer.models.internal.table.get(entity.model) orelse continue;
            if (model.state != .ready) continue;
            const center = math.sub(math.transformPoint(transformOf(renderer, entity_handle), model.info.bounds_center), box.corner);
            const reach = model.info.bounds_radius * math.maxScale(transformOf(renderer, entity_handle));
            const local = Vec3{ math.dot(center, box.axes[0]), math.dot(center, box.axes[1]), math.dot(center, box.axes[2]) };
            var inside = true;
            inline for (0..3) |axis| {
                if (local[axis] < -reach or local[axis] > box.extent[axis] + reach) inside = false;
            }
            if (!inside or reach > @min(box.extent[0], @min(box.extent[1], box.extent[2])) * 0.45) continue;
            record.spheres[record.sphere_count] = .{ local[0], local[1], local[2], reach };
            record.sphere_count += 1;
        };

        cmd.bindPipeline(try renderer.internal.pipelines.of(liquidSimPipeline));
        var push = Push{
            .liquid = 0,
            .particles = device.bufferAddress(state.particles),
            .shapes = device.bufferAddress(state.shapes),
            .counts = device.bufferAddress(state.counts),
            .cells = device.bufferAddress(state.cells),
            .mode = 0,
            .flip = 0,
        };
        const records = try arena.alloc(device, gpu.Liquid, @max(steps, 1));
        records.items[0] = record;
        for (0..steps) |step| {
            record.live_before = state.live;
            if (!state.started) {
                state.started = true;
                state.live = record.block_count;
            }
            for (state.sources[0..state.source_count], 0..) |source, index| {
                const speed = math.length(source.velocity);
                const mouth = @max(source.radius, radius);
                const per_layer = std.math.clamp(@round(std.math.pi * mouth * mouth / (spacing * spacing)), 1, @as(f32, @floatFromInt(state.capacity)));
                const layers_a_second = if (source.rate > 0) source.rate / per_layer else speed / spacing;
                state.owed[index] += layers_a_second * dt;
                const room: u32 = (state.capacity - state.live) / @as(u32, @intFromFloat(per_layer));
                const layers: u32 = @intFromFloat(@min(@floor(state.owed[index]), @as(f32, @floatFromInt(room))));
                state.owed[index] -= @floor(state.owed[index]);
                const born: u32 = layers * @as(u32, @intFromFloat(per_layer));
                record.sources[index].layer = per_layer;
                record.source_lead[index] = state.owed[index] * spacing;
                record.source_start[index] = state.live;
                state.live += born;
                record.source_end[index] = state.live;
            }
            record.live = state.live;
            record.seed +%= 0x9e3779b9;
            records.items[step] = record;
        }
        const stride = @sizeOf(gpu.Liquid);
        cmd.dependency(.{ .compute_read = true, .graphics_read = true }, .{ .transfer_write = true });
        cmd.copyBuffer(records.buffer, state.params_buffer, records.offset, 0, records.items.len * stride);
        cmd.dependency(.{ .transfer_write = true }, .{ .compute_read = true });
        const params_address = device.bufferAddress(state.params_buffer);
        for (0..steps) |step| {
            const live = records.items[step].live;
            if (live == 0) continue;
            push.liquid = params_address + step * stride;
            const groups = (live + 63) / 64;
            push.mode = 0;
            push.flip = 0;
            cmd.pushConstants(push);
            cmd.dispatch(groups, 1, 1);
            cmd.dependency(.{ .compute_read = true, .compute_write = true }, .{ .transfer_write = true });
            cmd.fillBuffer(state.counts, 0, @as(u64, state.cell_count) * @sizeOf(u32), 0);
            cmd.dependency(.{ .transfer_write = true }, .{ .compute_read = true, .compute_write = true });
            push.mode = 1;
            cmd.pushConstants(push);
            cmd.dispatch(groups, 1, 1);
            cmd.dependency(.{ .compute_write = true }, .{ .compute_read = true, .compute_write = true });
            if (renderer.options.deterministic) {
                push.mode = 6;
                cmd.pushConstants(push);
                cmd.dispatch((state.cell_count + 63) / 64, 1, 1);
                cmd.dependency(.{ .compute_write = true }, .{ .compute_read = true, .compute_write = true });
            }
            var flip: u32 = 0;
            for (0..std.math.clamp(desc.iterations, 1, 8)) |_| {
                push.flip = flip;
                push.mode = 2;
                cmd.pushConstants(push);
                cmd.dispatch(groups, 1, 1);
                cmd.dependency(.{ .compute_write = true }, .{ .compute_read = true, .compute_write = true });
                push.mode = 3;
                cmd.pushConstants(push);
                cmd.dispatch(groups, 1, 1);
                cmd.dependency(.{ .compute_write = true }, .{ .compute_read = true, .compute_write = true });
                flip ^= 1;
            }
            push.flip = flip;
            push.mode = 4;
            cmd.pushConstants(push);
            cmd.dispatch(groups, 1, 1);
            cmd.dependency(.{ .compute_write = true }, .{ .compute_read = true, .compute_write = true });
            push.mode = 5;
            cmd.pushConstants(push);
            cmd.dispatch(groups, 1, 1);
            cmd.dependency(.{ .compute_write = true }, .{ .compute_read = true, .compute_write = true });
        }
        if (steps != 0 and state.live != 0) {
            push.liquid = params_address + (steps - 1) * stride;
            push.mode = 7;
            cmd.pushConstants(push);
            cmd.dispatch((state.live + 63) / 64, 1, 1);
            cmd.dependency(.{ .compute_write = true }, .{ .compute_read = true, .graphics_read = true, .vertex_input = true, .indirect = true });
        }
        state.params = params_address + (records.items.len - 1) * stride;
        state.params_frame = renderer.internal.frame_index;
        if (state.proxy) |stand_in| if (renderer.entities.internal.table.get(stand_in)) |proxy| {
            const volume = @as(f32, @floatFromInt(state.live)) * spacing * spacing * spacing;
            const filled = std.math.clamp(volume / (box.extent[0] * box.extent[1] * box.extent[2]), 0.002, 1);
            moveEntity(renderer, stand_in, math.mul(desc.transform, math.mul(math.translation(.{ 0, -0.5 + filled * 0.5, 0 }), math.scaling(.{ 1, filled, 1 }))), false);
            if (proxy.tint != packTint(desc.color)) {
                proxy.tint = packTint(desc.color);
                restyleEntity(renderer, stand_in);
            }
        };
    }
}

/// Steps the scene's water surfaces and their splashes.
pub fn simulateWater(renderer: *Renderer, cmd: *rhi.CommandEncoder, scene: *SceneData, arena: *FrameArena, delta_time: f32) !void {
    if (scene.waters.items.len == 0) return;
    const device = renderer.device;
    cmd.beginScope("water simulation");
    defer cmd.endScope();
    for (scene.waters.items) |item| {
        const state = renderer.waters.internal.table.get(item) orelse continue;
        const desc = state.desc;
        if (!state.cleared) {
            for (state.state) |texture| {
                try cmd.beginRendering(.{ .color = &.{.{ .texture = texture, .load = .clear, .clear = .{ 0, 0, 0, 0 } }} });
                cmd.endRendering();
            }
            state.cleared = true;
        }
        const t = desc.transform;
        const width = @max(math.length(.{ t[0], t[1], t[2] }), 1e-6);
        const up = @max(math.length(.{ t[4], t[5], t[6] }), 1e-6);
        const cells_a_second = @max(desc.wave_speed, 0) * @as(f32, @floatFromInt(state.size[0])) / width;
        const step = std.math.clamp(0.65 / @max(cells_a_second, 1e-6), 1e-5, 1.0 / 60.0);
        const steps = fixedSteps(&state.time_owed, delta_time * desc.time_scale, step, max_water_steps);
        const dt = step * @as(f32, @floatFromInt(steps));
        state.rain_pending += @max(desc.rain, 0) * dt;
        var random = std.Random.DefaultPrng.init(renderer.internal.frame_index *% 0x9e3779b97f4a7c15 +% 7);
        const rng = random.random();
        while (state.rain_pending >= 1 and state.ripple_count < state.ripples.len) : (state.rain_pending -= 1) {
            state.ripples[state.ripple_count] = .{
                .position = .{ rng.float(f32), rng.float(f32) },
                .radius = 0.12 / width,
                .depth = 0.035 / up,
            };
            state.ripple_count += 1;
        }
        state.rain_pending = @min(state.rain_pending, 1);
        var splash_strength: f32 = state.hit_strength;
        var splash_at: Vec3 = state.hit_at;
        var splash_radius: f32 = state.hit_radius;
        var splash_speed: f32 = if (state.hit_strength > 0) 4 else 0;
        state.hit_strength = 0;
        if (desc.object_ripples > 0) {
            const to_sheet = math.inverse(t);
            for (scene.entities.items) |entity_handle| {
                if (state.ripple_count == state.ripples.len) break;
                const entity = renderer.entities.internal.table.get(entity_handle) orelse continue;
                if (!entity.visible or renderer.internal.entity_marks.items[entity_handle.index].travelled < 1e-4) continue;
                const model = renderer.models.internal.table.get(entity.model) orelse continue;
                if (model.state != .ready) continue;
                const center = math.transformPoint(transformOf(renderer, entity_handle), model.info.bounds_center);
                const radius = model.info.bounds_radius * math.maxScale(transformOf(renderer, entity_handle));
                const local = math.transformPoint(to_sheet, center);
                const above = local[1] * up;
                if (@abs(above) >= radius or @abs(local[0]) > 0.5 or @abs(local[2]) > 0.5) continue;
                const cut = @sqrt(radius * radius - above * above);
                const speed = renderer.internal.entity_marks.items[entity_handle.index].travelled / @max(delta_time, 1e-4);
                if (speed * cut > splash_strength) {
                    splash_strength = speed * cut;
                    splash_at = math.transformPoint(t, .{ local[0], 0, local[2] });
                    splash_radius = cut;
                    splash_speed = speed;
                }
                state.ripples[state.ripple_count] = .{
                    .position = .{ local[0] + 0.5, local[2] + 0.5 },
                    .radius = @min(cut, radius) / width,
                    .depth = @min(renderer.internal.entity_marks.items[entity_handle.index].travelled * 0.35 * desc.object_ripples, radius * 0.5) / up,
                };
                state.ripple_count += 1;
            }
        }
        if (state.splash) |spraying| if (renderer.emitters.internal.table.get(spraying)) |emitter| {
            var spray = splashDesc(desc);
            if (splash_strength > 0.15) {
                spray.position = splash_at;
                spray.radius = splash_radius * 0.7;
                spray.rate = @min(desc.splashes * splash_strength * 600, 6000);
                spray.speed = .{ 0.4 + splash_speed * 0.25, 1.2 + splash_speed * 0.6 };
            }
            emitter.desc = spray;
        };
        const ocean_heights: u64 = if (desc.ocean) |ocean| try runOcean(renderer, cmd, state, ocean, delta_time * desc.time_scale) else 0;
        var record = gpu.Water{
            .transform = t,
            .size = .{ @intCast(state.size[0]), @intCast(state.size[1]) },
            .state = device.textureIndex(state.state[state.current]),
            .sampler_linear = device.samplerIndex(renderer.internal.sampler_linear_clamp),
            .dt = step,
            .speed = cells_a_second,
            .keep = @exp(-@max(desc.damping, 0) * step),
            .ripple_count = state.ripple_count,
            .color = desc.color,
            .murk = @max(desc.murk, 0),
            .roughness = std.math.clamp(desc.roughness, 0, 1),
            .refraction = @max(desc.refraction, 0),
            .swell = @max(desc.swell, 0),
            .swell_length = @max(desc.swell_length, 0.01),
            .foam = std.math.clamp(desc.foam, 0, 1),
            .caustics = std.math.clamp(desc.caustics, 0, 1),
            .detail = std.math.clamp(desc.ripple_detail, 0, 2),
            .mask = renderer.images.indexOf(desc.mask),
            .ripples = state.ripples,
            .ocean = ocean_heights,
            .ocean_period = if (desc.ocean) |ocean| @max(ocean.period, 0.01) else 1,
        };
        if (steps > 0) state.ripple_count = 0;
        const params = try arena.alloc(device, gpu.Water, steps + 1);
        for (0..steps) |index| {
            params.items[index] = record;
            const new = 1 - state.current;
            try cmd.beginRendering(.{ .color = &.{.{ .texture = state.state[new], .load = .discard }} });
            cmd.bindPipeline(try renderer.internal.pipelines.of(waterSimPipeline));
            cmd.pushConstants(water_passes_push.SimPush{ .water = params.address + index * @sizeOf(gpu.Water) });
            cmd.drawFullscreen();
            cmd.endRendering();
            state.current = new;
            record.state = device.textureIndex(state.state[new]);
            record.ripple_count = 0;
        }
        params.items[steps] = record;
        state.params = params.address + steps * @sizeOf(gpu.Water);
        state.params_frame = renderer.internal.frame_index;
    }
}

/// Steps every fluid of a scene and uploads its description for drawing.
pub fn simulateFluids(renderer: *Renderer, cmd: *rhi.CommandEncoder, scene: *SceneData, arena: *FrameArena, delta_time: f32) !void {
    if (scene.fluids.items.len == 0) return;
    const device = renderer.device;
    cmd.beginScope("fluid simulation");
    defer cmd.endScope();
    for (scene.fluids.items) |item| {
        const state = renderer.fluids.internal.table.get(item) orelse continue;
        const desc = state.desc;
        if (!state.cleared) {
            for (state.textures()) |texture| {
                try cmd.beginRendering(.{ .color = &.{.{ .texture = texture.*, .load = .clear, .clear = .{ 0, 0, 0, 0 } }} });
                cmd.endRendering();
            }
            state.cleared = true;
            state.mask_key = 0;
        }
        const dt = steadyStep(&state.time_owed, delta_time * desc.time_scale);
        const cells: f32 = @floatFromInt(state.size[1]);
        const box_to_world = math.mul(desc.transform, math.translation(.{ -0.5, -0.5, -0.5 }));
        const params = try arena.alloc(device, gpu.Fluid, 1);
        params.items[0] = .{
            .world_to_box = math.inverse(box_to_world),
            .box_to_world = box_to_world,
            .size = .{ @intCast(state.size[0]), @intCast(state.size[1]), @intCast(state.size[2]) },
            .tiles_x = @intCast(state.tiles_x),
            .dt = dt,
            .buoyancy = desc.buoyancy,
            .weight = desc.weight,
            .vorticity = @max(desc.vorticity, 0),
            .velocity_keep = @exp(-@max(desc.velocity_loss, 0) * dt),
            .smoke_keep = @exp(-@max(desc.smoke_loss, 0) * dt),
            .heat_keep = @exp(-@max(desc.cooling, 0) * dt),
            .fuel_keep = @exp(-@max(desc.burn_rate, 0) * dt),
            .heat = desc.heat,
            .soot = desc.soot,
            .walls = @intFromEnum(desc.walls),
            .source_count = state.source_count,
            .wind = desc.wind,
            .absorption = @max(desc.absorption, 0),
            .smoke_color = desc.smoke_color,
            .fire_intensity = @max(desc.fire_intensity, 0),
            .fire_color = desc.fire_color,
            .shadow = std.math.clamp(desc.shadow, 0, 1),
            .sampler_linear = device.samplerIndex(renderer.internal.sampler_linear_clamp),
            .sampler_nearest = device.samplerIndex(renderer.internal.sampler_nearest_clamp),
            .scalars = 0,
            .anisotropy = std.math.clamp(desc.anisotropy, 0, 0.95),
            .ambient = @max(desc.ambient, 0),
            .sources = undefined,
            .obstacles = @splat(.{}),
            .obstacle_count = state.obstacle_count,
            .solid_mask = 0,
        };
        for (&params.items[0].sources, state.sources) |*out, source| out.* = .{
            .position = source.position,
            .radius = source.radius,
            .velocity = math.scale(source.velocity, cells),
            .smoke = source.smoke,
            .fuel = source.fuel,
            .temperature = source.temperature,
        };
        const grid = Vec3{ @floatFromInt(state.size[0]), cells, @floatFromInt(state.size[2]) };
        for (state.obstacles[0..state.obstacle_count], params.items[0].obstacles[0..state.obstacle_count]) |obstacle, *out| out.* = switch (obstacle) {
            .sphere => |sphere| .{ .a = Vec3{ sphere.center[0] * grid[0], sphere.center[1] * grid[1], sphere.center[2] * grid[2] }, .radius = @max(sphere.radius, 0) * cells },
            .box => |box| .{ .a = Vec3{ box.min[0] * grid[0], box.min[1] * grid[1], box.min[2] * grid[2] }, .b = Vec3{ box.max[0] * grid[0], box.max[1] * grid[1], box.max[2] * grid[2] }, .radius = -1 },
        };
        const address = params.address;
        state.params = address;
        state.params_frame = renderer.internal.frame_index;
        params.items[0].solid = device.textureIndex(state.solid);
        const scene_tlas: u64 = if (desc.scene_obstacles and device.caps.ray_tracing and scene.tlas_hash != 0)
            (if (scene.tlas) |tlas| device.accelerationAddress(tlas) else 0)
        else
            0;
        if (state.obstacle_count != 0 or scene_tlas != 0) {
            params.items[0].solid_mask = 1;
            var hasher = std.hash.Wyhash.init(0);
            hasher.update(std.mem.asBytes(&desc.transform));
            hasher.update(std.mem.asBytes(&state.size));
            hasher.update(std.mem.asBytes(&state.obstacle_count));
            for (state.obstacles[0..state.obstacle_count]) |obstacle| switch (obstacle) {
                .sphere => |sphere| {
                    hasher.update(std.mem.asBytes(&sphere.center));
                    hasher.update(std.mem.asBytes(&sphere.radius));
                },
                .box => |box| {
                    hasher.update(std.mem.asBytes(&box.min));
                    hasher.update(std.mem.asBytes(&box.max));
                },
            };
            hasher.update(std.mem.asBytes(&scene_tlas));
            if (scene_tlas != 0) hasher.update(std.mem.asBytes(&scene.tlas_hash));
            const mask_key = hasher.final() | 1;
            if (state.mask_key != mask_key) {
                state.mask_key = mask_key;
                try cmd.beginRendering(.{ .color = &.{.{ .texture = state.solid, .load = .discard }} });
                cmd.bindPipeline(if (scene_tlas != 0) try renderer.internal.pipelines.of(fluidSolidTracedPipeline) else try renderer.internal.pipelines.of(fluidSolidPipeline));
                cmd.pushConstants(fluid_passes_push.SolidPush{ .fluid = address, .tlas_low = @truncate(scene_tlas), .tlas_high = @truncate(scene_tlas >> 32) });
                cmd.drawFullscreen();
                cmd.endRendering();
            }
        }
        if (dt > 0) {
            const old = state.current;
            const new = 1 - old;
            if (desc.sharp_advection) {
                try cmd.beginRendering(.{ .color = &.{ .{ .texture = state.carried, .load = .discard }, .{ .texture = state.carried_velocity, .load = .discard } } });
                cmd.bindPipeline(try renderer.internal.pipelines.of(fluidCarryPipeline));
                cmd.pushConstants(fluid_passes_push.CarryPush{ .fluid = address, .velocity_texture = device.textureIndex(state.velocity[old]), .scalars_texture = device.textureIndex(state.scalars[old]) });
                cmd.drawFullscreen();
                cmd.endRendering();
            }
            try cmd.beginRendering(.{ .color = &.{
                .{ .texture = state.velocity[new], .load = .discard },
                .{ .texture = state.scalars[new], .load = .discard },
            } });
            cmd.bindPipeline(try renderer.internal.pipelines.of(fluidAdvectPipeline));
            cmd.pushConstants(fluid_passes_push.AdvectPush{ .fluid = address, .velocity_texture = device.textureIndex(state.velocity[old]), .scalars_texture = device.textureIndex(state.scalars[old]), .carried_texture = if (desc.sharp_advection) device.textureIndex(state.carried) else gpu.invalid_id, .carried_velocity_texture = if (desc.sharp_advection and desc.sharp_velocity) device.textureIndex(state.carried_velocity) else gpu.invalid_id });
            cmd.drawFullscreen();
            cmd.endRendering();

            try cmd.beginRendering(.{ .color = &.{.{ .texture = state.curl, .load = .discard }} });
            cmd.bindPipeline(try renderer.internal.pipelines.of(fluidCurlPipeline));
            cmd.pushConstants(fluid_passes_push.CurlPush{ .fluid = address, .velocity_texture = device.textureIndex(state.velocity[new]) });
            cmd.drawFullscreen();
            cmd.endRendering();

            try cmd.beginRendering(.{ .color = &.{.{ .texture = state.velocity[old], .load = .discard }} });
            cmd.bindPipeline(try renderer.internal.pipelines.of(fluidForcePipeline));
            cmd.pushConstants(fluid_passes_push.ForcePush{ .fluid = address, .velocity_texture = device.textureIndex(state.velocity[new]), .scalars_texture = device.textureIndex(state.scalars[new]), .curl_texture = device.textureIndex(state.curl) });
            cmd.drawFullscreen();
            cmd.endRendering();

            try cmd.beginRendering(.{ .color = &.{.{ .texture = state.divergence, .load = .discard }} });
            cmd.bindPipeline(try renderer.internal.pipelines.of(fluidDivergencePipeline));
            cmd.pushConstants(fluid_passes_push.DivergencePush{ .fluid = address, .velocity_texture = device.textureIndex(state.velocity[old]) });
            cmd.drawFullscreen();
            cmd.endRendering();

            cmd.bindPipeline(try renderer.internal.pipelines.of(fluidPressurePipeline));
            for (0..std.math.clamp(desc.pressure_iterations, 1, 200)) |_| {
                const from = state.pressure_current;
                const to = 1 - from;
                try cmd.beginRendering(.{ .color = &.{.{ .texture = state.pressure[to], .load = .discard }} });
                cmd.bindPipeline(try renderer.internal.pipelines.of(fluidPressurePipeline));
                cmd.pushConstants(fluid_passes_push.PressurePush{ .fluid = address, .pressure_texture = device.textureIndex(state.pressure[from]), .divergence_texture = device.textureIndex(state.divergence) });
                cmd.drawFullscreen();
                cmd.endRendering();
                state.pressure_current = to;
            }

            try cmd.beginRendering(.{ .color = &.{.{ .texture = state.velocity[new], .load = .discard }} });
            cmd.bindPipeline(try renderer.internal.pipelines.of(fluidProjectPipeline));
            cmd.pushConstants(fluid_passes_push.ProjectPush{ .fluid = address, .velocity_texture = device.textureIndex(state.velocity[old]), .pressure_texture = device.textureIndex(state.pressure[state.pressure_current]) });
            cmd.drawFullscreen();
            cmd.endRendering();
            state.current = new;
        }
        params.items[0].scalars = device.textureIndex(state.scalars[state.current]);
        params.items[0].velocity = device.textureIndex(state.velocity[state.current]);
        if (state.picture) |picture| {
            try cmd.beginRendering(.{ .color = &.{.{ .texture = picture, .load = .discard }} });
            cmd.bindPipeline(try renderer.internal.pipelines.of(fluidPresentPipeline));
            cmd.pushConstants(fluid_passes_push.PresentPush{ .fluid = address });
            cmd.drawFullscreen();
            cmd.endRendering();
        }
        if (state.flipbook) |sheet| {
            const book = state.flipbook_desc;
            const fresh = state.flipbook_recorded == 0 and state.flipbook_wait == 0;
            const due = state.flipbook_recorded < book.columns * book.rows and dt > 0 and state.flipbook_wait == 0;
            if (fresh or due) {
                try cmd.beginRendering(.{ .color = &.{.{ .texture = sheet, .load = if (fresh) .clear else .load, .clear = .{ 0, 0, 0, 0 } }} });
                if (due) {
                    const frame = state.flipbook_frame;
                    cmd.setViewport((state.flipbook_recorded % book.columns) * frame[0], (state.flipbook_recorded / book.columns) * frame[1], frame[0], frame[1]);
                    cmd.bindPipeline(try renderer.internal.pipelines.of(fluidPresentPipeline));
                    cmd.pushConstants(fluid_passes_push.PresentPush{ .fluid = address });
                    cmd.drawFullscreen();
                    state.flipbook_recorded += 1;
                }
                cmd.endRendering();
            }
            if (dt > 0) state.flipbook_wait = (state.flipbook_wait + 1) % @max(book.interval, 1);
        }
    }
}

fn fluidAdvectPipeline(_: *rhi.Device) pipelines_module.Desc {
    return pipelines_module.pass("fluid advect", pipelines_module.shaderCode("fluid_advect.frag.spv"), &.{ .{ .format = .rgba16_float }, .{ .format = .rgba16_float } });
}

fn fluidCurlPipeline(_: *rhi.Device) pipelines_module.Desc {
    return pipelines_module.pass("fluid curl", pipelines_module.shaderCode("fluid_curl.frag.spv"), &.{.{ .format = .rgba16_float }});
}

fn fluidForcePipeline(_: *rhi.Device) pipelines_module.Desc {
    return pipelines_module.pass("fluid forces", pipelines_module.shaderCode("fluid_force.frag.spv"), &.{.{ .format = .rgba16_float }});
}

fn fluidDivergencePipeline(_: *rhi.Device) pipelines_module.Desc {
    return pipelines_module.pass("fluid divergence", pipelines_module.shaderCode("fluid_divergence.frag.spv"), &.{.{ .format = .rg16_float }});
}

fn fluidPressurePipeline(_: *rhi.Device) pipelines_module.Desc {
    return pipelines_module.pass("fluid pressure", pipelines_module.shaderCode("fluid_pressure.frag.spv"), &.{.{ .format = .rg16_float }});
}

fn fluidProjectPipeline(_: *rhi.Device) pipelines_module.Desc {
    return pipelines_module.pass("fluid projection", pipelines_module.shaderCode("fluid_project.frag.spv"), &.{.{ .format = .rgba16_float }});
}

fn fluidPresentPipeline(_: *rhi.Device) pipelines_module.Desc {
    return pipelines_module.pass("fluid picture", pipelines_module.shaderCode("fluid_present.frag.spv"), &.{.{ .format = pipelines_module.hdr_format }});
}

fn waterSimPipeline(_: *rhi.Device) pipelines_module.Desc {
    return pipelines_module.pass("water simulation", pipelines_module.shaderCode("water_sim.frag.spv"), &.{.{ .format = .rg16_float }});
}

fn liquidSimPipeline(_: *rhi.Device) pipelines_module.Desc {
    return .{ .compute = .{ .name = "liquid simulation", .shader = pipelines_module.shaderCode("liquid_sim.comp.spv") } };
}

fn fluidSolidPipeline(_: *rhi.Device) pipelines_module.Desc {
    return pipelines_module.pass("fluid obstacles", pipelines_module.shaderCode("fluid_solid.frag.spv"), &.{.{ .format = .r8_unorm }});
}

fn fluidSolidTracedPipeline(device: *rhi.Device) pipelines_module.Desc {
    return pipelines_module.pass("fluid obstacles (scene)", if (device.caps.ray_tracing) pipelines_module.shaderCode("fluid_solid_rt.frag.spv") else pipelines_module.shaderCode("fluid_solid.frag.spv"), &.{.{ .format = .r8_unorm }});
}

fn fluidCarryPipeline(_: *rhi.Device) pipelines_module.Desc {
    return pipelines_module.pass("fluid carry", pipelines_module.shaderCode("fluid_carry.frag.spv"), &.{ .{ .format = .rgba16_float }, .{ .format = .rgba16_float } });
}

/// Advances `state`'s ocean by `seconds` and returns the address of its heights.
fn runOcean(renderer: *Renderer, cmd: *rhi.CommandEncoder, state: *WaterState, ocean: render.Ocean, seconds: f32) !u64 {
    const device = renderer.device;
    const cells = gpu.ocean_cells;
    const buffers = state.ocean orelse made: {
        const rows = try device.createBuffer(.{ .name = "ocean rows", .size = cells * cells * 8, .usage = .{ .storage = true } });
        errdefer device.destroyBuffer(rows);
        const heights = try device.createBuffer(.{ .name = "ocean heights", .size = cells * cells * 4, .usage = .{ .storage = true } });
        state.ocean = .{ rows, heights };
        break :made state.ocean.?;
    };
    state.ocean_time += seconds;
    const wind = @max(ocean.wind_speed, 0.1);
    const along = @sqrt(ocean.wind_direction[0] * ocean.wind_direction[0] + ocean.wind_direction[1] * ocean.wind_direction[1]);
    const direction: [2]f32 = if (along > 1e-6) .{ ocean.wind_direction[0] / along, ocean.wind_direction[1] / along } else .{ 1, 0 };
    const period = @max(ocean.period, 0.01);
    const wanted_rms = 0.21 * wind * wind / 9.81 / 4 * @max(ocean.height, 0);
    const push = ocean_push.Push{
        .rows = device.bufferAddress(buffers[0]),
        .heights = device.bufferAddress(buffers[1]),
        .time = state.ocean_time,
        .period = period,
        .scale = wanted_rms / @max(spectrumRms(wind, direction, period), 1e-12),
        .wind_speed = wind,
        .wind_direction = direction,
    };
    cmd.beginScope("ocean");
    defer cmd.endScope();
    cmd.bindPipeline(try renderer.internal.pipelines.of(oceanRowsPipeline));
    cmd.pushConstants(push);
    cmd.dispatch(cells, 1, 1);
    cmd.dependency(.{ .compute_write = true }, .{ .compute_read = true });
    cmd.bindPipeline(try renderer.internal.pipelines.of(oceanColumnsPipeline));
    cmd.pushConstants(push);
    cmd.dispatch(cells, 1, 1);
    cmd.dependency(.{ .compute_write = true }, .{ .graphics_read = true, .compute_read = true });
    return push.heights;
}

/// Root mean square height of the spectrum `ocean.slang` makes with unit
/// scale, so the scale can give the height the wind raises.
fn spectrumRms(wind: f32, direction: [2]f32, period: f32) f32 {
    const cells = gpu.ocean_cells;
    const reach = wind * wind / 9.81;
    const small = reach * 0.001;
    var total: f64 = 0;
    for (0..cells) |y| for (0..cells) |x| {
        const k = [2]f32{
            (@as(f32, @floatFromInt(x)) - cells / 2) * 2 * std.math.pi / period,
            (@as(f32, @floatFromInt(y)) - cells / 2) * 2 * std.math.pi / period,
        };
        const k2 = k[0] * k[0] + k[1] * k[1];
        if (k2 < 1e-8) continue;
        const toward = (k[0] * direction[0] + k[1] * direction[1]) / @sqrt(k2);
        total += @exp(-1 / (k2 * reach * reach)) / (k2 * k2) * toward * toward * @exp(-k2 * small * small);
    };
    return @floatCast(@sqrt(total));
}

fn oceanRowsPipeline(_: *rhi.Device) pipelines_module.Desc {
    return .{ .compute = .{ .name = "ocean rows", .shader = pipelines_module.shaderCode("ocean_rows.comp.spv") } };
}

fn oceanColumnsPipeline(_: *rhi.Device) pipelines_module.Desc {
    return .{ .compute = .{ .name = "ocean columns", .shader = pipelines_module.shaderCode("ocean_columns.comp.spv") } };
}
