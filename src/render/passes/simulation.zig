//! GPU simulation: liquids, water surfaces, smoke and fire. Internal to the
//! renderer.
const std = @import("std");
const rhi = @import("../../rhi/rhi.zig");
const math = @import("../../math.zig");
const gpu = @import("../gpu.zig");
const render = @import("../renderer.zig");

const Mat4 = math.Mat4;
const Vec3 = math.Vec3;
const Renderer = render.Renderer;
const WaterDesc = render.WaterDesc;
const EmitterDesc = render.EmitterDesc;
const FrameArena = render.FrameArena;
const SceneData = render.SceneData;
const liquid_cell_slots = render.liquid_cell_slots;
const packTint = render.packTint;

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

/// Steps every liquid of a scene, once per frame.
pub fn simulateLiquids(renderer: *Renderer, cmd: *rhi.CommandEncoder, scene: *SceneData, arena: *FrameArena, delta_time: f32) !void {
    if (scene.liquids.items.len == 0) return;
    const device = renderer.device;
    cmd.beginScope("liquid simulation");
    defer cmd.endScope();
    const Push = extern struct { liquid: u64, particles: u64, counts: u64, cells: u64, mode: u32, flip: u32 };
    for (scene.liquids.items) |item| {
        const state = renderer.liquids.table.get(item) orelse continue;
        const desc = state.desc;
        const box = liquidBox(desc.transform);
        const radius = desc.particle_radius;
        const spacing = radius * 2;
        const frame_dt = steadyStep(&state.time_owed, delta_time * desc.time_scale);
        const substeps = std.math.clamp(desc.substeps, 1, 8);
        const dt = frame_dt / @as(f32, @floatFromInt(substeps));
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
            .seed = @truncate(renderer.frame_index *% 2654435761),
            .color = desc.color,
            .murk = @max(desc.murk, 0),
            .source_count = state.source_count,
            .sphere_count = 0,
            .refraction = @max(desc.refraction, 0),
            .keep = @exp(-@max(desc.damping, 0) * dt),
            .viscosity = std.math.clamp(desc.viscosity, 0, 1),
            .detail = std.math.clamp(desc.ripple_detail, 0, 2),
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
            const entity = renderer.entities.table.get(entity_handle) orelse continue;
            if (!entity.visible) continue;
            const model = renderer.models.table.get(entity.model) orelse continue;
            if (model.state != .ready) continue;
            const center = math.sub(math.transformPoint(renderer.transformOf(entity_handle), model.info.bounds_center), box.corner);
            const reach = model.info.bounds_radius * math.maxScale(renderer.transformOf(entity_handle));
            const local = Vec3{ math.dot(center, box.axes[0]), math.dot(center, box.axes[1]), math.dot(center, box.axes[2]) };
            var inside = true;
            inline for (0..3) |axis| {
                if (local[axis] < -reach or local[axis] > box.extent[axis] + reach) inside = false;
            }
            if (!inside or reach > @min(box.extent[0], @min(box.extent[1], box.extent[2])) * 0.45) continue;
            record.spheres[record.sphere_count] = .{ local[0], local[1], local[2], reach };
            record.sphere_count += 1;
        };

        cmd.bindPipeline(renderer.pipelines.liquid_sim);
        var push = Push{
            .liquid = 0,
            .particles = device.bufferAddress(state.particles),
            .counts = device.bufferAddress(state.counts),
            .cells = device.bufferAddress(state.cells),
            .mode = 0,
            .flip = 0,
        };
        const steps: u32 = if (frame_dt > 0) substeps else 0;
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
                const per_layer = @max(@round(std.math.pi * mouth * mouth / (spacing * spacing)), 1);
                const layers_a_second = if (source.rate > 0) source.rate / per_layer else speed / spacing;
                state.owed[index] += layers_a_second * dt;
                const room: u32 = (state.capacity - state.live) / @as(u32, @intFromFloat(per_layer));
                const layers: u32 = @min(@as(u32, @intFromFloat(@floor(state.owed[index]))), room);
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
        cmd.sync(.all_to_transfer);
        cmd.copyBuffer(records.buffer, state.params_buffer, records.offset, 0, records.items.len * stride);
        cmd.sync(.transfer_to_all);
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
            cmd.sync(.all_to_transfer);
            cmd.fillBuffer(state.counts, 0, @as(u64, state.cell_count) * @sizeOf(u32), 0);
            cmd.sync(.transfer_to_all);
            push.mode = 1;
            cmd.pushConstants(push);
            cmd.dispatch(groups, 1, 1);
            cmd.sync(.compute_to_all);
            var flip: u32 = 0;
            for (0..std.math.clamp(desc.iterations, 1, 8)) |_| {
                push.flip = flip;
                push.mode = 2;
                cmd.pushConstants(push);
                cmd.dispatch(groups, 1, 1);
                cmd.sync(.compute_to_all);
                push.mode = 3;
                cmd.pushConstants(push);
                cmd.dispatch(groups, 1, 1);
                cmd.sync(.compute_to_all);
                flip ^= 1;
            }
            push.flip = flip;
            push.mode = 4;
            cmd.pushConstants(push);
            cmd.dispatch(groups, 1, 1);
            cmd.sync(.compute_to_all);
            push.mode = 5;
            cmd.pushConstants(push);
            cmd.dispatch(groups, 1, 1);
            cmd.sync(.compute_to_all);
        }
        state.params = params_address + (records.items.len - 1) * stride;
        state.params_frame = renderer.frame_index;
        if (state.proxy) |stand_in| if (renderer.entities.table.get(stand_in)) |proxy| {
            const volume = @as(f32, @floatFromInt(state.live)) * spacing * spacing * spacing;
            const filled = std.math.clamp(volume / (box.extent[0] * box.extent[1] * box.extent[2]), 0.002, 1);
            renderer.moveEntity(stand_in, math.mul(desc.transform, math.mul(math.translation(.{ 0, -0.5 + filled * 0.5, 0 }), math.scaling(.{ 1, filled, 1 }))), false);
            if (proxy.tint != packTint(desc.color)) {
                proxy.tint = packTint(desc.color);
                renderer.restyleEntity(stand_in);
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
        const state = renderer.waters.table.get(item) orelse continue;
        const desc = state.desc;
        if (!state.cleared) {
            for (state.state) |texture| {
                try cmd.beginRendering(.{ .color = &.{.{ .texture = texture, .load = .clear, .clear = .{ 0, 0, 0, 0 } }} });
                cmd.endRendering();
                cmd.transition(texture, .shader_read);
            }
            state.cleared = true;
        }
        const dt = steadyStep(&state.time_owed, delta_time * desc.time_scale);
        const t = desc.transform;
        const width = @max(math.length(.{ t[0], t[1], t[2] }), 1e-6);
        const up = @max(math.length(.{ t[4], t[5], t[6] }), 1e-6);
        state.rain_pending += @max(desc.rain, 0) * dt;
        var random = std.Random.DefaultPrng.init(renderer.frame_index *% 0x9e3779b97f4a7c15 +% 7);
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
                const entity = renderer.entities.table.get(entity_handle) orelse continue;
                if (!entity.visible or renderer.entity_marks.items[entity_handle.index].travelled < 1e-4) continue;
                const model = renderer.models.table.get(entity.model) orelse continue;
                if (model.state != .ready) continue;
                const center = math.transformPoint(renderer.transformOf(entity_handle), model.info.bounds_center);
                const radius = model.info.bounds_radius * math.maxScale(renderer.transformOf(entity_handle));
                const local = math.transformPoint(to_sheet, center);
                const above = local[1] * up;
                if (@abs(above) >= radius or @abs(local[0]) > 0.5 or @abs(local[2]) > 0.5) continue;
                const cut = @sqrt(radius * radius - above * above);
                const speed = renderer.entity_marks.items[entity_handle.index].travelled / @max(delta_time, 1e-4);
                if (speed * cut > splash_strength) {
                    splash_strength = speed * cut;
                    splash_at = math.transformPoint(t, .{ local[0], 0, local[2] });
                    splash_radius = cut;
                    splash_speed = speed;
                }
                state.ripples[state.ripple_count] = .{
                    .position = .{ local[0] + 0.5, local[2] + 0.5 },
                    .radius = @min(cut, radius) / width,
                    .depth = @min(renderer.entity_marks.items[entity_handle.index].travelled * 0.35 * desc.object_ripples, radius * 0.5) / up,
                };
                state.ripple_count += 1;
            }
        }
        if (state.splash) |spraying| if (renderer.emitters.table.get(spraying)) |emitter| {
            var spray = splashDesc(desc);
            if (splash_strength > 0.15) {
                spray.position = splash_at;
                spray.radius = splash_radius * 0.7;
                spray.rate = @min(desc.splashes * splash_strength * 600, 6000);
                spray.speed = .{ 0.4 + splash_speed * 0.25, 1.2 + splash_speed * 0.6 };
            }
            emitter.desc = spray;
        };
        var record = gpu.Water{
            .transform = t,
            .size = .{ @intCast(state.size[0]), @intCast(state.size[1]) },
            .state = device.textureIndex(state.state[state.current]),
            .sampler_linear = device.samplerIndex(renderer.sampler_linear_clamp),
            .dt = dt,
            .speed = @max(desc.wave_speed, 0) * @as(f32, @floatFromInt(state.size[0])) / width,
            .keep = @exp(-@max(desc.damping, 0) * dt),
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
            .ripples = state.ripples,
        };
        state.ripple_count = 0;
        const params = try arena.alloc(device, gpu.Water, 2);
        params.items[0] = record;
        if (dt > 0) {
            const new = 1 - state.current;
            try cmd.beginRendering(.{ .color = &.{.{ .texture = state.state[new], .load = .discard }} });
            cmd.bindPipeline(renderer.pipelines.water_sim);
            cmd.pushConstants(extern struct { water: u64 }{ .water = params.address });
            cmd.drawFullscreen();
            cmd.endRendering();
            cmd.transition(state.state[new], .shader_read);
            state.current = new;
            record.state = device.textureIndex(state.state[new]);
        }
        params.items[1] = record;
        state.params = params.address + @sizeOf(gpu.Water);
        state.params_frame = renderer.frame_index;
    }
}

/// Steps every fluid of a scene and uploads its description for drawing.
pub fn simulateFluids(renderer: *Renderer, cmd: *rhi.CommandEncoder, scene: *SceneData, arena: *FrameArena, delta_time: f32) !void {
    if (scene.fluids.items.len == 0) return;
    const device = renderer.device;
    cmd.beginScope("fluid simulation");
    defer cmd.endScope();
    for (scene.fluids.items) |item| {
        const state = renderer.fluids.table.get(item) orelse continue;
        const desc = state.desc;
        if (!state.cleared) {
            for (state.textures()) |texture| {
                try cmd.beginRendering(.{ .color = &.{.{ .texture = texture.*, .load = .clear, .clear = .{ 0, 0, 0, 0 } }} });
                cmd.endRendering();
                cmd.transition(texture.*, .shader_read);
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
            .sampler_linear = device.samplerIndex(renderer.sampler_linear_clamp),
            .sampler_nearest = device.samplerIndex(renderer.sampler_nearest_clamp),
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
        state.params_frame = renderer.frame_index;
        const Push = extern struct { fluid: u64, a: u32 = 0, b: u32 = 0, c: u32 = 0, pad: u32 = 0 };
        params.items[0].solid = device.textureIndex(state.solid);
        const scene_tlas: u64 = if (desc.scene_obstacles and device.ray_tracing and scene.tlas_hash != 0)
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
                cmd.bindPipeline(if (scene_tlas != 0) renderer.pipelines.fluid_solid_traced else renderer.pipelines.fluid_solid);
                cmd.pushConstants(extern struct { fluid: u64, tlas: u64 }{ .fluid = address, .tlas = scene_tlas });
                cmd.drawFullscreen();
                cmd.endRendering();
                cmd.transition(state.solid, .shader_read);
            }
        }
        if (dt > 0) {
            const old = state.current;
            const new = 1 - old;
            if (desc.sharp_advection) {
                try cmd.beginRendering(.{ .color = &.{ .{ .texture = state.carried, .load = .discard }, .{ .texture = state.carried_velocity, .load = .discard } } });
                cmd.bindPipeline(renderer.pipelines.fluid_carry);
                cmd.pushConstants(Push{ .fluid = address, .a = device.textureIndex(state.velocity[old]), .b = device.textureIndex(state.scalars[old]) });
                cmd.drawFullscreen();
                cmd.endRendering();
                cmd.transition(state.carried, .shader_read);
                cmd.transition(state.carried_velocity, .shader_read);
            }
            try cmd.beginRendering(.{ .color = &.{
                .{ .texture = state.velocity[new], .load = .discard },
                .{ .texture = state.scalars[new], .load = .discard },
            } });
            cmd.bindPipeline(renderer.pipelines.fluid_advect);
            cmd.pushConstants(Push{ .fluid = address, .a = device.textureIndex(state.velocity[old]), .b = device.textureIndex(state.scalars[old]), .c = if (desc.sharp_advection) device.textureIndex(state.carried) else gpu.invalid_id, .pad = if (desc.sharp_advection and desc.sharp_velocity) device.textureIndex(state.carried_velocity) else gpu.invalid_id });
            cmd.drawFullscreen();
            cmd.endRendering();
            cmd.transition(state.velocity[new], .shader_read);
            cmd.transition(state.scalars[new], .shader_read);

            try cmd.beginRendering(.{ .color = &.{.{ .texture = state.curl, .load = .discard }} });
            cmd.bindPipeline(renderer.pipelines.fluid_curl);
            cmd.pushConstants(Push{ .fluid = address, .a = device.textureIndex(state.velocity[new]) });
            cmd.drawFullscreen();
            cmd.endRendering();
            cmd.transition(state.curl, .shader_read);

            try cmd.beginRendering(.{ .color = &.{.{ .texture = state.velocity[old], .load = .discard }} });
            cmd.bindPipeline(renderer.pipelines.fluid_force);
            cmd.pushConstants(Push{ .fluid = address, .a = device.textureIndex(state.velocity[new]), .b = device.textureIndex(state.scalars[new]), .c = device.textureIndex(state.curl) });
            cmd.drawFullscreen();
            cmd.endRendering();
            cmd.transition(state.velocity[old], .shader_read);

            try cmd.beginRendering(.{ .color = &.{.{ .texture = state.divergence, .load = .discard }} });
            cmd.bindPipeline(renderer.pipelines.fluid_divergence);
            cmd.pushConstants(Push{ .fluid = address, .a = device.textureIndex(state.velocity[old]) });
            cmd.drawFullscreen();
            cmd.endRendering();
            cmd.transition(state.divergence, .shader_read);

            cmd.bindPipeline(renderer.pipelines.fluid_pressure);
            for (0..std.math.clamp(desc.pressure_iterations, 1, 200)) |_| {
                const from = state.pressure_current;
                const to = 1 - from;
                try cmd.beginRendering(.{ .color = &.{.{ .texture = state.pressure[to], .load = .discard }} });
                cmd.bindPipeline(renderer.pipelines.fluid_pressure);
                cmd.pushConstants(Push{ .fluid = address, .a = device.textureIndex(state.pressure[from]), .b = device.textureIndex(state.divergence) });
                cmd.drawFullscreen();
                cmd.endRendering();
                cmd.transition(state.pressure[to], .shader_read);
                state.pressure_current = to;
            }

            try cmd.beginRendering(.{ .color = &.{.{ .texture = state.velocity[new], .load = .discard }} });
            cmd.bindPipeline(renderer.pipelines.fluid_project);
            cmd.pushConstants(Push{ .fluid = address, .a = device.textureIndex(state.velocity[old]), .b = device.textureIndex(state.pressure[state.pressure_current]) });
            cmd.drawFullscreen();
            cmd.endRendering();
            cmd.transition(state.velocity[new], .shader_read);
            state.current = new;
        }
        params.items[0].scalars = device.textureIndex(state.scalars[state.current]);
        params.items[0].velocity = device.textureIndex(state.velocity[state.current]);
        if (state.picture) |picture| {
            try cmd.beginRendering(.{ .color = &.{.{ .texture = picture, .load = .discard }} });
            cmd.bindPipeline(renderer.pipelines.fluid_present);
            cmd.pushConstants(Push{ .fluid = address });
            cmd.drawFullscreen();
            cmd.endRendering();
            cmd.transition(picture, .shader_read);
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
                    cmd.bindPipeline(renderer.pipelines.fluid_present);
                    cmd.pushConstants(Push{ .fluid = address });
                    cmd.drawFullscreen();
                    state.flipbook_recorded += 1;
                }
                cmd.endRendering();
                cmd.transition(sheet, .shader_read);
            }
            if (dt > 0) state.flipbook_wait = (state.flipbook_wait + 1) % @max(book.interval, 1);
        }
    }
}
