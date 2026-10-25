//! A scene's particles.
const pipelines_module = @import("../renderer/pipelines.zig");
const particles_push = @import("../shaders/push/particles.zig");
const render = @import("../renderer.zig");
const math = @import("../../math.zig");
const gpu = @import("../gpu.zig");
const rhi = @import("../../rhi/rhi.zig");
const std = @import("std");
const features = @import("../core/features.zig");

const Emitter = render.Emitter;
const ViewState = render.ViewState;
const Vec3 = math.Vec3;
const ModelMesh = render.ModelMesh;
const EmitterData = render.EmitterData;
const max_curve_keys = render.max_curve_keys;
const SceneData = render.SceneData;
const FrameArena = render.FrameArena;
const Renderer = render.Renderer;
const ViewContext = features.ViewContext;

/// Adds the feature's passes to a view of a scene. A path traced view leaves
/// out those whose result the tracer replaces.
pub fn declare(ctx: *ViewContext) !void {
    if (ctx.scene == null) return;
    const g = ctx.graph;
    try g.add(.{ .name = "particles", .stage = .volumes, .always = true, .scope = false }, ctx, particles);
}

fn particles(ctx: *ViewContext) !void {
    const p = ctx.scene.?;
    if (!p.debugging) try drawParticles(ctx.renderer, p.cmd, p.scene, p.view, p.frame_address, p.desc.camera.position);
}

/// Steps every emitter of a scene by one frame.
pub fn simulateParticles(renderer: *Renderer, cmd: *rhi.CommandEncoder, scene: *SceneData, arena: *FrameArena, frame_address: u64, delta_time: f32, collision_depth: ?u32) !void {
    if (scene.emitters.items.len == 0) return;
    const device = renderer.device;
    cmd.beginScope("particle simulation");
    defer cmd.endScope();
    cmd.bindPipeline(try renderer.internal.pipelines.of(particleSimPipeline));
    for (scene.emitters.items) |handle_value| {
        const emitter = renderer.emitters.internal.table.get(handle_value) orelse continue;
        const desc = emitter.desc;
        const steps: u32 = if (emitter.warmed or desc.prewarm <= 0 or delta_time <= 0) 1 else @as(u32, @intFromFloat(@min(desc.prewarm / delta_time, 599))) + 1;
        emitter.warmed = true;
        var step: u32 = 0;
        while (step < steps) : (step += 1) {
            emitter.pending += @max(desc.rate, 0) * delta_time;
            const births: u32 = @min(@as(u32, @intFromFloat(@min(emitter.pending, 1e9))), emitter.capacity);
            emitter.pending -= @floatFromInt(births);
            const carrier: u64 = if (desc.fluid) |fluid| (if (renderer.fluids.internal.table.get(fluid)) |state| (if (state.params_frame == renderer.internal.frame_index) state.params else 0) else 0) else 0;
            var trail_record = false;
            const trail_interval = @max(desc.trail_seconds, 1e-3) / @as(f32, @floatFromInt(@max(emitter.trail_points, 1)));
            if (emitter.trail_points != 0) {
                emitter.trail_clock += delta_time;
                if (emitter.trail_clock >= trail_interval) {
                    emitter.trail_clock = @mod(emitter.trail_clock, trail_interval);
                    emitter.trail_head = (emitter.trail_head + 1) % emitter.trail_points;
                    trail_record = true;
                }
            }
            const params = try arena.alloc(device, gpu.Emitter, 1);
            params.items[0] = .{
                .position = desc.position,
                .radius = desc.radius,
                .direction = desc.direction,
                .spread = std.math.clamp(desc.spread, 0, std.math.pi),
                .gravity = desc.gravity,
                .drag = desc.drag,
                .color_start = desc.color_start,
                .color_end = desc.color_end,
                .lifetime = .{ @max(desc.lifetime[0], 1e-3), @max(desc.lifetime[1], 1e-3) },
                .speed = desc.speed,
                .size = desc.size,
                .spawn_start = emitter.cursor,
                .spawn_count = births,
                .capacity = emitter.capacity,
                .flags = (if (desc.blend == .additive) gpu.emitter_additive else 0) | (if (desc.lit) gpu.emitter_lit else 0) |
                    (if (carrier != 0) gpu.emitter_fluid else 0) | (if (desc.collide and collision_depth != null) gpu.emitter_collide else 0) | (if (emitter.order != null) gpu.emitter_sorted else 0),
                .image = renderer.images.indexOf(desc.image),
                .softness = desc.softness,
                .seed = @truncate(renderer.internal.frame_index *% 0x9e3779b97f4a7c15 >> 16),
                .shift = emitter.shift,
                .follow = @max(desc.fluid_follow, 0),
                .bounce = std.math.clamp(desc.bounce, 0, 1),
                .collision_depth = collision_depth orelse gpu.invalid_id,
                .stretch = @max(desc.stretch, 0),
                .sheet = .{ @max(desc.sheet[0], 1), @max(desc.sheet[1], 1) },
                .fluid = carrier,
                .color_mid = desc.color_mid orelse .{ 0, 0, 0, 0 },
                .size_mid = desc.size_mid orelse 0,
                .mid = std.math.clamp(desc.mid, 0.01, 0.99),
                .keys = (if (desc.color_mid != null) @as(u32, 1) else 0) | (if (desc.size_mid != null) @as(u32, 2) else 0),
                .curve_colors = desc.color_curve.keys,
                .curve_sizes = desc.size_curve.keys,
                .curve_counts = .{ @min(desc.color_curve.count, max_curve_keys), @min(desc.size_curve.count, max_curve_keys) },
                .trail_count = emitter.trail_points,
                .trail_head = emitter.trail_head,
                .trail_record = @intFromBool(trail_record),
                .trail_fraction = if (emitter.trail_points != 0) std.math.clamp(emitter.trail_clock / trail_interval, 0, 1) else 0,
            };
            emitter.shift = .{ 0, 0, 0 };
            emitter.cursor = (emitter.cursor + births) % emitter.capacity;
            emitter.frame_params = params.address;
            cmd.pushConstants(particles_push.SimPush{
                .trail = if (emitter.trail) |trail| device.bufferAddress(trail) else 0,
                .frame = frame_address,
                .emitter = params.address,
                .particles = device.bufferAddress(emitter.buffer),
            });
            cmd.dispatch((emitter.capacity + 63) / 64, 1, 1);
            if (step + 1 < steps) cmd.sync(.compute_to_all);
        }
    }
    cmd.sync(.compute_to_all);
}

/// The mesh an emitter's particles are drawn as, once loaded; null for sprites.
pub fn emitterMesh(renderer: *Renderer, emitter: *const EmitterData) ?ModelMesh {
    const model = emitter.desc.mesh orelse return null;
    const entry = renderer.models.internal.table.get(model) orelse return null;
    if (entry.state != .ready or entry.meshes.len == 0) return null;
    entry.geometry_pinned = true;
    if (!entry.geometry_resident) return null;
    const mesh = entry.meshes[0];
    if (mesh.skin_offset != null or mesh.lod0_index_count == 0) return null;
    return mesh;
}

/// Draws the scene's particles as sprites, trails or mesh instances.
pub fn drawParticles(renderer: *Renderer, cmd: *rhi.CommandEncoder, scene: *SceneData, view: *ViewState, frame_address: u64, camera_position: Vec3) !void {
    if (scene.emitters.items.len == 0) return;
    const device = renderer.device;
    cmd.beginScope("particles");
    defer cmd.endScope();
    for (scene.emitters.items) |handle_value| {
        const emitter = renderer.emitters.internal.table.get(handle_value) orelse continue;
        const order = emitter.order orelse continue;
        if (emitter.frame_params == 0) continue;
        const count = emitter.order_count;
        const order_address = device.bufferAddress(order);
        cmd.bindPipeline(try renderer.internal.pipelines.of(particleSortKeysPipeline));
        cmd.pushConstants(particles_push.SortKeysPush{
            .frame = frame_address,
            .particles = device.bufferAddress(emitter.buffer),
            .order = order_address,
            .capacity = emitter.capacity,
            .count = count,
        });
        cmd.dispatch((count + 63) / 64, 1, 1);
        cmd.sync(.compute_to_all);
        cmd.bindPipeline(try renderer.internal.pipelines.of(particleSortPipeline));
        var run: u32 = 2;
        while (run <= count) : (run *= 2) {
            var stride = run / 2;
            while (stride > 0) : (stride /= 2) {
                cmd.pushConstants(particles_push.SortPush{ .order = order_address, .count = count, .run = run, .stride = stride });
                cmd.dispatch((count + 63) / 64, 1, 1);
                cmd.sync(.compute_to_all);
            }
        }
    }
    var fallback = std.heap.stackFallback(64 * @sizeOf(Emitter), renderer.internal.gpa);
    const ordering = fallback.get();
    const ordered = try ordering.alloc(Emitter, scene.emitters.items.len);
    defer ordering.free(ordered);
    @memcpy(ordered, scene.emitters.items);
    const Farther = struct {
        renderer: *Renderer,
        camera: Vec3,

        fn distance(context: @This(), handle_value: Emitter) f32 {
            const emitter = context.renderer.emitters.internal.table.get(handle_value) orelse return 0;
            const delta = math.sub(emitter.desc.position, context.camera);
            return math.dot(delta, delta);
        }

        fn lessThan(context: @This(), a: Emitter, b: Emitter) bool {
            return context.distance(a) > context.distance(b);
        }
    };
    std.mem.sort(Emitter, ordered, Farther{ .renderer = renderer, .camera = camera_position }, Farther.lessThan);
    var mesh_total: u32 = 0;
    var mesh_pass = false;
    for (scene.emitters.items) |handle_value| {
        const emitter = renderer.emitters.internal.table.get(handle_value) orelse continue;
        if (emitter.frame_params == 0) continue;
        const mesh = emitterMesh(renderer, emitter) orelse continue;
        if (!mesh_pass) {
            try cmd.beginRendering(.{
                .color = &.{ .{ .texture = view.hdr, .load = .load }, .{ .texture = view.motion, .load = .load } },
                .depth = .{ .texture = view.depth, .load = .load },
            });
            cmd.bindPipeline(try renderer.internal.pipelines.of(particleMeshPipeline));
            cmd.bindIndexBuffer(renderer.internal.indices.get(), 0, .uint32);
            mesh_pass = true;
        }
        cmd.pushConstants(particles_push.MeshFragmentPush{
            .frame = frame_address,
            .emitter = emitter.frame_params,
            .particles = device.bufferAddress(emitter.buffer),
            .vertex_offset = mesh.vertex_offset,
            .spin = emitter.desc.spin,
        });
        cmd.drawIndexed(mesh.lod0_index_count, emitter.capacity, mesh.index_offset, 0, 0);
        mesh_total += emitter.capacity;
    }
    if (mesh_pass) {
        cmd.endRendering();
    }
    try cmd.beginRendering(.{ .color = &.{ .{ .texture = view.hdr, .load = .load }, .{ .texture = view.motion, .load = .load } } });
    cmd.bindPipeline(try renderer.internal.pipelines.of(particlesPipeline));
    var total: u32 = 0;
    for (ordered) |handle_value| {
        const emitter = renderer.emitters.internal.table.get(handle_value) orelse continue;
        if (emitter.frame_params == 0) continue;
        if (emitter.trail) |trail| {
            cmd.bindPipeline(try renderer.internal.pipelines.of(particleTrailsPipeline));
            cmd.pushConstants(particles_push.TrailVertexPush{
                .frame = frame_address,
                .emitter = emitter.frame_params,
                .particles = device.bufferAddress(emitter.buffer),
                .depth_texture = device.textureIndex(view.depth),
                .trail = device.bufferAddress(trail),
            });
            cmd.draw(emitter.capacity * emitter.trail_points * 6, 1, 0, 0);
            cmd.bindPipeline(try renderer.internal.pipelines.of(particlesPipeline));
        }
        if (emitterMesh(renderer, emitter) != null) continue;
        cmd.pushConstants(particles_push.SpriteFragmentPush{
            .frame = frame_address,
            .emitter = emitter.frame_params,
            .particles = device.bufferAddress(emitter.buffer),
            .depth_texture = device.textureIndex(view.depth),
            .order = if (emitter.order) |order| device.bufferAddress(order) else 0,
        });
        cmd.draw(emitter.capacity * 6, 1, 0, 0);
        total += emitter.capacity;
    }
    cmd.endRendering();
    renderer.internal.stats.particles = total + mesh_total;
}

fn particleSimPipeline(_: *rhi.Device) pipelines_module.Desc {
    return .{ .compute = .{ .name = "particle simulation", .shader = pipelines_module.shaderCode("particle_sim.comp.spv") } };
}

fn particleSortKeysPipeline(_: *rhi.Device) pipelines_module.Desc {
    return .{ .compute = .{ .name = "particle sort keys", .shader = pipelines_module.shaderCode("particle_sort_keys.comp.spv") } };
}

fn particleSortPipeline(_: *rhi.Device) pipelines_module.Desc {
    return .{ .compute = .{ .name = "particle sort", .shader = pipelines_module.shaderCode("particle_sort.comp.spv") } };
}

fn particlesPipeline(_: *rhi.Device) pipelines_module.Desc {
    return .{ .graphics = .{
        .name = "particles",
        .vertex = pipelines_module.shaderCode("particle.vert.spv"),
        .fragment = pipelines_module.shaderCode("particle.frag.spv"),
        .color_targets = &.{ .{ .format = pipelines_module.hdr_format, .blend = .premultiplied }, .{ .format = .rg16_float, .blend = .alpha } },
        .cull = .none,
    } };
}

fn particleTrailsPipeline(_: *rhi.Device) pipelines_module.Desc {
    return .{ .graphics = .{
        .name = "particle trails",
        .vertex = pipelines_module.shaderCode("particle_trail.vert.spv"),
        .fragment = pipelines_module.shaderCode("particle.frag.spv"),
        .color_targets = &.{ .{ .format = pipelines_module.hdr_format, .blend = .premultiplied }, .{ .format = .rg16_float, .blend = .alpha } },
        .cull = .none,
    } };
}

fn particleMeshPipeline(_: *rhi.Device) pipelines_module.Desc {
    return .{ .graphics = .{
        .name = "mesh particles",
        .vertex = pipelines_module.shaderCode("particle_mesh.vert.spv"),
        .fragment = pipelines_module.shaderCode("particle_mesh.frag.spv"),
        .color_targets = &.{ .{ .format = pipelines_module.hdr_format, .blend = .premultiplied }, .{ .format = .rg16_float, .blend = .alpha } },
        .depth = .{ .write = true, .compare = .greater_or_equal },
        .cull = .none,
    } };
}
