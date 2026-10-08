//! A scene's per-frame GPU state: poses, instances, lights and acceleration structures. Internal to the renderer.
const std = @import("std");
const rhi = @import("../../rhi/rhi.zig");
const math = @import("../../math.zig");
const gpu = @import("../gpu.zig");
const animation = @import("../animation.zig");
const api = @import("../api.zig");
const renderer_state = @import("../state.zig");
const scene_pass = @import("../scene_pass.zig");
const geometry_passes = @import("../passes/geometry.zig");
const render = @import("../renderer.zig");

const Renderer = render.Renderer;
const Mat4 = math.Mat4;
const Vec3 = math.Vec3;
const SceneFrame = scene_pass.SceneFrame;
const Lighting = scene_pass.Lighting;
const Entity = api.Entity;
const Zone = renderer_state.Zone;
const max_local_shadow_views = renderer_state.max_local_shadow_views;
const max_movers = renderer_state.max_movers;
const local_shadow_tiles_per_side = renderer_state.local_shadow_tiles_per_side;
const Pool = renderer_state.Pool;
const FrameArena = renderer_state.FrameArena;
const ModelEntry = renderer_state.ModelEntry;
const SceneData = renderer_state.SceneData;
const no_skin = renderer_state.no_skin;
const max_pose_threads = renderer_state.max_pose_threads;
const pose_batch = renderer_state.pose_batch;
const buildSceneTree = @import("models.zig").buildSceneTree;
const cullView = @import("view_math.zig").cullView;
const groupDriver = @import("scenes.zig").groupDriver;
const resolveEntity = @import("scenes.zig").resolveEntity;

fn noteMover(self: *Renderer, scene: *SceneData, sphere: [4]f32) void {
    if (scene.movers.items.len >= max_movers) {
        scene.movers_overflow = true;
        return;
    }
    scene.movers.append(self.gpa, sphere) catch {
        scene.movers_overflow = true;
    };
}

/// Computes node matrices of the scene's animated entities for this
/// frame, across threads when there are enough.
fn evaluatePoses(self: *Renderer, scene: *SceneData) !void {
    const zone = Zone.start(self.options.profiler, "poses");
    defer zone.stop();
    self.posed.clearRetainingCapacity();
    var most_nodes: usize = 0;
    for (scene.layout.items) |entry| {
        if (!entry.first_of_entity) continue;
        const entity = self.entities.table.get(entry.entity).?;
        if (entity.node_world.len == 0) continue;
        try self.posed.append(self.gpa, entry.entity);
        most_nodes = @max(most_nodes, entity.node_world.len);
    }
    const count = self.posed.items.len;
    if (count == 0) return;
    const allowed: usize = switch (self.options.pose_threads) {
        0 => @min(std.Thread.getCpuCount() catch 1, max_pose_threads),
        else => |asked| @min(asked, max_pose_threads),
    };
    const threads = std.math.clamp(count / pose_batch, 1, allowed);
    for (self.pose_scratch[0..threads]) |*scratch| try scratch.resize(self.gpa, most_nodes * 3);
    if (threads == 1) return poseEntities(self, self.posed.items, self.pose_scratch[0].items);
    var group: std.Io.Group = .init;
    const share = (count + threads - 1) / threads;
    for (1..threads) |index| {
        const batch = self.posed.items[@min(index * share, count)..@min((index + 1) * share, count)];
        group.concurrent(self.io, poseEntities, .{ self, batch, self.pose_scratch[index].items }) catch
            poseEntities(self, batch, self.pose_scratch[index].items);
    }
    poseEntities(self, self.posed.items[0..@min(share, count)], self.pose_scratch[0].items);
    group.await(self.io) catch {};
}

/// Runs on any thread. Writes only each entity's own node matrices; no
/// two batches share an entity.
fn poseEntities(self: *Renderer, entities: []const Entity, scratch: []animation.Local) void {
    for (entities) |handle_value| {
        const entity = self.entities.table.get(handle_value).?;
        const model = self.models.table.get(entity.model).?;
        std.mem.swap([]Mat4, &entity.node_world, &entity.previous_node_world);
        animation.evaluate(&model.source.?, model.pose_order, entity.pose, scratch, entity.node_world);
        if (entity.history_frames == 0) @memcpy(entity.previous_node_world, entity.node_world);
    }
}

fn rebuildLayout(self: *Renderer, scene: *SceneData) !void {
    const zone = Zone.start(self.options.profiler, "rebuild layout");
    defer zone.stop();
    const gpa = self.gpa;
    scene.layout.clearRetainingCapacity();
    self.scratch_refs.clearRetainingCapacity();
    scene.joint_count = 0;
    scene.triangle_count = 0;
    scene.masked_ref_count = 0;
    for (scene.entities.items) |entity_handle| {
        const entity = self.entities.table.get(entity_handle) orelse continue;
        if (!entity.visible) continue;
        const model = self.models.table.get(entity.model) orelse continue;
        if (model.state != .ready or !model.geometry_resident) continue;
        try resolveEntity(self, entity, model);
        const source = &model.source.?;
        for (source.instances, 0..) |instance, index| {
            const mesh = model.meshes[instance.mesh];
            const instance_index: u32 = @intCast(scene.layout.items.len);
            try scene.layout.append(gpa, .{ .entity = entity_handle, .model_instance = @intCast(index), .first_of_entity = index == 0 });
            scene.triangle_count += mesh.lod0_index_count / 3;
            if (entity.skin_offsets[index] != no_skin) scene.joint_count += @intCast(source.skins[instance.skin.?].joints.len);
            if (entity.rays_only) continue;
            if (mesh.masked) scene.masked_ref_count += mesh.meshlet_count;
            try self.scratch_refs.ensureUnusedCapacity(gpa, mesh.meshlet_count);
            for (0..mesh.meshlet_count) |meshlet| self.scratch_refs.appendAssumeCapacity(.{
                .instance = instance_index,
                .meshlet = mesh.meshlet_offset + @as(u32, @intCast(meshlet)),
            });
        }
    }
    scene.static_count = 0;
    scene.entity_ref_count = @intCast(self.scratch_refs.items.len);
    scene.static_ranges.clearRetainingCapacity();
    for (scene.groups.items) |group_handle| {
        const group = self.instances.table.get(group_handle) orelse continue;
        group.base = @as(u32, @intCast(scene.layout.items.len)) + scene.static_count;
        group.per_copy = 0;
        const model = self.models.table.get(group.model) orelse continue;
        if (model.state != .ready or !model.geometry_resident) continue;
        const source = &model.source.?;
        group.per_copy = @intCast(source.instances.len);
        for (0..group.transforms.len) |copy| {
            var slot: u32 = 0;
            for (source.instances) |instance| {
                const mesh = model.meshes[instance.mesh];
                const instance_index = group.base + @as(u32, @intCast(copy)) * group.per_copy + slot;
                slot += 1;
                scene.triangle_count += mesh.lod0_index_count / 3;
                try scene.static_ranges.append(gpa, .{ @intCast(self.scratch_refs.items.len), mesh.meshlet_count });
                if (mesh.masked) scene.masked_ref_count += mesh.meshlet_count;
                try self.scratch_refs.ensureUnusedCapacity(gpa, mesh.meshlet_count);
                for (0..mesh.meshlet_count) |meshlet| self.scratch_refs.appendAssumeCapacity(.{
                    .instance = instance_index,
                    .meshlet = mesh.meshlet_offset + @as(u32, @intCast(meshlet)),
                });
            }
        }
        scene.static_count += @as(u32, @intCast(group.transforms.len)) * group.per_copy;
    }
    scene.static_version += 1;
    const count: u32 = @intCast(self.scratch_refs.items.len);
    if (count > scene.refs_capacity) {
        if (scene.refs) |buffer| self.device.destroyBuffer(buffer);
        scene.refs_capacity = @max(count + count / 2, 4096);
        scene.refs = try self.device.createBuffer(.{
            .name = "meshlet refs",
            .size = @as(u64, scene.refs_capacity) * @sizeOf(gpu.MeshletRef),
            .usage = .{ .storage = true },
        });
    }
    if (count != 0) try self.device.uploadBuffer(scene.refs.?, 0, std.mem.sliceAsBytes(self.scratch_refs.items));
    scene.ref_count = count;
    scene.layout_dirty = false;
    scene.layout_version += 1;
    scene.layout_generation = self.asset_generation;
}

/// `Glowing` in pathtrace.frag: an evenly emissive instance and the
/// triangle count of its full-detail level.
const Glowing = extern struct { instance: u32, triangles: u32 };

/// Most glowing instances path tracing samples directly.
const max_glowing = 1024;

/// Writes this frame's instance records and joint matrices and queues
/// the skinning jobs.
pub fn prepareScene(self: *Renderer, scene: *SceneData, arena: *FrameArena, slot: usize) !SceneFrame {
    const zone = Zone.start(self.options.profiler, "prepare scene");
    defer zone.stop();
    const device = self.device;
    if (scene.layout_dirty or scene.layout_generation != self.asset_generation) try rebuildLayout(self, scene);
    const entity_count = scene.layout.items.len;
    const total = entity_count + scene.static_count;
    const records = &scene.instance_slots[0];
    _ = slot;
    if (records.buffer == null or records.capacity < total) {
        if (records.buffer) |old| device.destroyBuffer(old);
        records.buffer = null;
        records.capacity = @intCast(@max(total + total / 2, 64));
        records.buffer = try device.createBuffer(.{
            .name = "instances",
            .size = @as(u64, records.capacity) * @sizeOf(gpu.Instance),
            .usage = .{ .storage = true, .copy_dst = true },
        });
        records.static_version = std.math.maxInt(u64);
    }
    const staged = try arena.alloc(device, gpu.Instance, entity_count);
    const instance_records = staged.items;
    const staged_previous = try arena.alloc(device, [12]f32, entity_count);
    const group_rays = device.ray_tracing and scene.static_count != 0 and scene.static_count <= self.options.gi_instance_limit;
    const tlas_instances = try arena.alloc(device, rhi.AccelerationInstance, scene.layout.items.len + (if (group_rays) scene.static_count else 0));
    var tlas_count: u32 = 0;
    var tlas_hasher = std.hash.Wyhash.init(0);
    var bounds = [2]Vec3{ @splat(std.math.inf(f32)), @splat(-std.math.inf(f32)) };
    const joints = try arena.alloc(device, Mat4, scene.joint_count);
    self.skin_jobs.clearRetainingCapacity();
    self.skin_weights.clearRetainingCapacity();
    self.bounds_jobs.clearRetainingCapacity();
    var bounds_cursor: u32 = 0;
    self.blas_jobs.clearRetainingCapacity();
    const parity: u32 = @intCast(self.frame_index & 1);
    var joint_cursor: u32 = 0;
    var shared_skin_entity: u32 = std.math.maxInt(u32);
    var shared_skin: u32 = 0;
    var shared_joints: u32 = 0;
    var shared_center: Vec3 = .{ 0, 0, 0 };
    var shared_radius: f32 = 0;
    var skinned_vertices: u32 = 0;
    var any_moving = false;

    try evaluatePoses(self, scene);
    scene.movers.clearRetainingCapacity();
    scene.movers_overflow = false;
    for (scene.hairs.items) |hair_handle| {
        const hair = self.hairs.table.get(hair_handle) orelse continue;
        if (hair.simulation == null) continue;
        const center = math.transformPoint(hair.desc.transform, hair.bounds[0..3].*);
        noteMover(self, scene, .{ center[0], center[1], center[2], hair.bounds[3] * math.maxScale(hair.desc.transform) * 1.6 });
    }
    scene.transparent.clearRetainingCapacity();
    scene.transmissive = false;

    const glowing = try arena.alloc(device, Glowing, max_glowing);
    var glowing_count: u32 = 0;
    for (scene.layout.items, instance_records, 0..) |entry, *out, instance_index| {
        const entity = self.entities.table.get(entry.entity).?;
        const model = self.models.table.get(entity.model).?;
        const source = &model.source.?;
        const node_world = if (entity.node_world.len != 0) entity.node_world else model.node_world;
        const previous_node_world = if (entity.node_world.len != 0) entity.previous_node_world else model.node_world;
        const instance = source.instances[entry.model_instance];
        const mesh = model.meshes[instance.mesh];
        const skin_base = entity.skin_offsets[entry.model_instance];
        var aimed = false;
        {
            const glow = source.materials[source.meshes[instance.mesh].material];
            if (glow.emissive_texture == null and (glow.emissive[0] > 0 or glow.emissive[1] > 0 or glow.emissive[2] > 0) and mesh.lod0_index_count >= 3 and !mesh.coarse and glowing_count < max_glowing) {
                glowing.items[glowing_count] = .{ .instance = @intCast(instance_index), .triangles = mesh.lod0_index_count / 3 };
                glowing_count += 1;
                aimed = true;
            }
        }
        defer if (mesh.blend and !entity.rays_only) {
            if (source.materials[source.meshes[instance.mesh].material].transmission > 0) scene.transmissive = true;
            scene.transparent.append(self.gpa, .{
                .instance = @intCast(instance_index),
                .first_index = mesh.index_offset,
                .index_count = mesh.lod0_index_count,
                .center = math.transformPoint(gpu.expand(out.transform), source.meshes[instance.mesh].bounds_center),
                .transmissive = source.materials[source.meshes[instance.mesh].material].transmission > 0,
            }) catch {};
        };

        if (skin_base == no_skin) {
            const transform = math.mul(entity.transform, node_world[instance.node]);
            const previous_transform = math.mul(entity.previous_transform, previous_node_world[instance.node]);
            if (!std.mem.eql(f32, &transform, &previous_transform)) {
                any_moving = true;
                const bounds_of = source.meshes[instance.mesh];
                const moved_center = math.transformPoint(transform, bounds_of.bounds_center);
                noteMover(self, scene, .{ moved_center[0], moved_center[1], moved_center[2], bounds_of.bounds_radius * math.maxScale(transform) });
            }
            staged_previous.items[instance_index] = gpu.affine(previous_transform);
            out.* = .{
                .transform = gpu.affine(transform),
                .bounding_sphere = .{ 0, 0, 0, 0 },
                .mesh = model.mesh_base + instance.mesh,
                .material = mesh.material,
                .vertex_offset = mesh.vertex_offset,
                .previous_vertex_offset = mesh.vertex_offset,
                .coarse_error = if (mesh.coarse) mesh.coarse_error else 0,
                .flags = (if (std.mem.eql(f32, &transform, &previous_transform)) 0 else gpu.instance_moving | gpu.instance_previous) | (if (entity.receive_decals) 0 else gpu.instance_no_decals) | (if (entity.rays_only) gpu.instance_proxy else 0) | (if (aimed) gpu.instance_aimed else 0),
                .tint = entity.tint,
                .lightmap = if (entity.lightmap) |lightmap| (if (lightmap.rounds != 0) device.textureIndex(lightmap.shown) else gpu.invalid_id) else gpu.invalid_id,
                .params = entity.params,
            };
            if (mesh.blas != null) {
                const center = math.transformPoint(transform, source.meshes[instance.mesh].bounds_center);
                const radius = source.meshes[instance.mesh].bounds_radius * math.maxScale(transform);
                inline for (0..3) |axis| {
                    bounds[0][axis] = @min(bounds[0][axis], center[axis] - radius);
                    bounds[1][axis] = @max(bounds[1][axis], center[axis] + radius);
                }
                const tlas_instance = rhi.AccelerationInstance{
                    .transform = .{
                        transform[0], transform[4], transform[8],  transform[12],
                        transform[1], transform[5], transform[9],  transform[13],
                        transform[2], transform[6], transform[10], transform[14],
                    },
                    .custom_index_and_mask = (@as(u32, @intCast(instance_index)) & 0x00ff_ffff) | (if (mesh.blend) @as(u32, 0x0200_0000) else 0xff00_0000),
                    .offset_and_flags = 0x0100_0000,
                    .blas = device.accelerationAddress(mesh.blas.?),
                };
                tlas_hasher.update(std.mem.asBytes(&tlas_instance));
                tlas_instances.items[tlas_count] = tlas_instance;
                tlas_count += 1;
            }
            continue;
        }

        const skin = source.skins[instance.skin.?];
        if (shared_skin_entity != entry.entity.index or shared_skin != instance.skin.?) {
            shared_skin_entity = entry.entity.index;
            shared_skin = instance.skin.?;
            shared_joints = joint_cursor;
            var minimum: Vec3 = @splat(std.math.inf(f32));
            var model_minimum: Vec3 = @splat(std.math.inf(f32));
            var model_maximum: Vec3 = @splat(-std.math.inf(f32));
            var maximum: Vec3 = @splat(-std.math.inf(f32));
            for (skin.joints, skin.inverse_bind, 0..) |joint, inverse_bind, index| {
                joints.items[joint_cursor + index] = math.mul(node_world[joint], inverse_bind);
                const position = math.transformPoint(entity.transform, node_world[joint][12..15].*);
                inline for (0..3) |axis| {
                    model_minimum[axis] = @min(model_minimum[axis], node_world[joint][12 + axis]);
                    model_maximum[axis] = @max(model_maximum[axis], node_world[joint][12 + axis]);
                }
                inline for (0..3) |axis| {
                    minimum[axis] = @min(minimum[axis], position[axis]);
                    maximum[axis] = @max(maximum[axis], position[axis]);
                }
            }
            joint_cursor += @intCast(skin.joints.len);
            shared_center = math.scale(math.add(minimum, maximum), 0.5);
            shared_radius = math.length(math.sub(maximum, minimum)) * 0.5;
            const model_center = math.scale(math.add(model_minimum, model_maximum), 0.5);
            entity.skin_bounds = .{ model_center[0], model_center[1], model_center[2], math.length(math.sub(model_maximum, model_minimum)) * 0.5 + model.info.bounds_radius * 0.25 };
        }
        const center = shared_center;
        const padding = model.info.bounds_radius * 0.25 * math.maxScale(entity.transform);
        noteMover(self, scene, .{ center[0], center[1], center[2], shared_radius + padding });
        const current = skin_base + parity * mesh.vertex_count;
        const own_bounds = self.options.skinned_meshlet_bounds and mesh.meshlet_count != 0;
        const previous = skin_base + (1 - parity) * mesh.vertex_count;
        any_moving = true;
        staged_previous.items[instance_index] = gpu.affine(entity.previous_transform);
        out.* = .{
            .transform = gpu.affine(entity.transform),
            .bounding_sphere = .{ center[0], center[1], center[2], shared_radius + padding },
            .mesh = model.mesh_base + instance.mesh,
            .material = mesh.material,
            .vertex_offset = current,
            .previous_vertex_offset = if (entity.history_frames != 0) previous else current,
            .flags = gpu.instance_skinned | gpu.instance_moving | gpu.instance_previous | (if (entity.receive_decals) 0 else gpu.instance_no_decals) | (if (entity.rays_only) gpu.instance_proxy else 0),
            .tint = entity.tint,
            .params = entity.params,
            .bounds_offset = if (own_bounds) bounds_cursor else gpu.invalid_id,
        };
        var morph_weights = source.meshes[instance.mesh].morph_weights;
        if (mesh.morph_targets != 0) {
            if (entity.pose) |pose| animation.poseWeights(source, pose, instance.node, morph_weights[0..mesh.morph_targets]);
            if (entity.morph_weights) |override| morph_weights = override;
        }
        entity.bounds_offsets[entry.model_instance] = gpu.invalid_id;
        if (own_bounds) {
            entity.bounds_offsets[entry.model_instance] = bounds_cursor;
            try self.bounds_jobs.append(self.gpa, .{ .vertex_offset = current, .meshlet_offset = mesh.meshlet_offset, .meshlet_count = mesh.meshlet_count, .bounds_offset = bounds_cursor });
            bounds_cursor += mesh.meshlet_count;
        }
        const weights_offset: u32 = @intCast(self.skin_weights.items.len);
        try self.skin_weights.appendSlice(self.gpa, morph_weights[0..mesh.morph_targets]);
        try self.skin_jobs.append(self.gpa, .{
            .source_offset = mesh.vertex_offset,
            .destination_offset = current,
            .skin_offset = mesh.skin_offset.?,
            .joint_offset = shared_joints,
            .vertex_count = mesh.vertex_count,
            .morph_offset = mesh.morph_offset orelse 0,
            .target_count = mesh.morph_targets,
            .weights_offset = weights_offset,
        });
        if (self.options.gi_dynamic_geometry and device.ray_tracing and !mesh.blend) {
            var dynamic_desc = geometry_passes.blasDesc(self, mesh);
            dynamic_desc.vertex_offset = @as(u64, current) * @sizeOf(gpu.Vertex);
            dynamic_desc.dynamic = true;
            const slot_blas = &entity.skin_blas[entry.model_instance];
            if (slot_blas.* == null) slot_blas.* = try device.createBlas(dynamic_desc);
            try self.blas_jobs.append(self.gpa, .{ .blas = slot_blas.*.?, .vertex_offset = current, .mesh = mesh });
            const t = entity.transform;
            const tlas_instance = rhi.AccelerationInstance{
                .transform = .{ t[0], t[4], t[8], t[12], t[1], t[5], t[9], t[13], t[2], t[6], t[10], t[14] },
                .custom_index_and_mask = (@as(u32, @intCast(instance_index)) & 0x00ff_ffff) | 0xff00_0000,
                .offset_and_flags = 0x0100_0000,
                .blas = device.accelerationAddress(slot_blas.*.?),
            };
            tlas_hasher.update(std.mem.asBytes(&tlas_instance));
            tlas_hasher.update(std.mem.asBytes(&self.frame_index));
            tlas_instances.items[tlas_count] = tlas_instance;
            tlas_count += 1;
        }
        skinned_vertices += mesh.vertex_count;
    }

    if (bounds_cursor > scene.skin_bounds_capacity) {
        if (scene.skin_bounds) |buffer| device.destroyBuffer(buffer);
        scene.skin_bounds = null;
        scene.skin_bounds_capacity = bounds_cursor + bounds_cursor / 2;
        scene.skin_bounds = try device.createBuffer(.{
            .name = "skinned meshlet bounds",
            .size = @as(u64, scene.skin_bounds_capacity) * 16,
            .usage = .{ .storage = true },
        });
    }

    var driven = false;
    for (scene.groups.items) |group_handle| {
        const group = self.instances.table.get(group_handle) orelse continue;
        if (group.driver != null) driven = true;
    }
    if (driven or records.static_version != scene.static_version or records.entity_count != entity_count) {
        self.scratch_instances.clearRetainingCapacity();
        self.scratch_static_cull.clearRetainingCapacity();
        try self.scratch_static_cull.ensureTotalCapacity(self.gpa, scene.static_count);
        self.scratch_impostors.clearRetainingCapacity();
        scene.static_transparent.clearRetainingCapacity();
        scene.static_transmissive = false;
        try self.scratch_instances.ensureTotalCapacity(self.gpa, scene.static_count);
        for (scene.groups.items) |group_handle| {
            const group = self.instances.table.get(group_handle) orelse continue;
            if (group.per_copy == 0) continue;
            const model = self.models.table.get(group.model) orelse continue;
            const source = &model.source.?;
            const driver = groupDriver(self, group, source.instances.len);
            var impostor_index: u32 = 0;
            if (group.impostor) |impostor| if (impostor.baked and group.per_copy == 1 and driver == null) {
                const whole = source.meshes[source.instances[0].mesh];
                try self.scratch_impostors.append(self.gpa, .{
                    .center = whole.bounds_center,
                    .radius = whole.bounds_radius,
                    .color_texture = device.textureIndex(impostor.color),
                    .normal_texture = device.textureIndex(impostor.normal),
                    .pixels = impostor.pixels,
                });
                impostor_index = @intCast(self.scratch_impostors.items.len);
            };
            for (group.transforms, 0..) |placement, copy_index| {
                const tint: u32 = if (group.tints.len == group.transforms.len) group.tints[copy_index] else 0xffffffff;
                const params: [4]f32 = if (group.params.len == group.transforms.len) group.params[copy_index] else .{ 0, 0, 0, 0 };
                var noted = false;
                for (source.instances, 0..) |instance, model_instance| {
                    const mesh = model.meshes[instance.mesh];
                    var world = math.mul(placement, model.node_world[instance.node]);
                    var record = gpu.Instance{
                        .transform = gpu.affine(world),
                        .bounding_sphere = .{ 0, 0, 0, 0 },
                        .mesh = model.mesh_base + instance.mesh,
                        .material = mesh.material,
                        .vertex_offset = mesh.vertex_offset,
                        .previous_vertex_offset = mesh.vertex_offset,
                        .coarse_error = if (mesh.coarse) mesh.coarse_error else 0,
                        .flags = 0,
                        .tint = tint,
                        .params = params,
                    };
                    var center = math.transformPoint(world, source.meshes[instance.mesh].bounds_center);
                    const skin_base = if (driver) |entity| entity.skin_offsets[model_instance] else no_skin;
                    if (skin_base != no_skin) {
                        const entity = driver.?;
                        const current = skin_base + parity * mesh.vertex_count;
                        center = math.transformPoint(placement, entity.skin_bounds[0..3].*);
                        const radius = entity.skin_bounds[3] * math.maxScale(placement);
                        world = placement;
                        record.transform = gpu.affine(placement);
                        record.bounding_sphere = .{ center[0], center[1], center[2], radius };
                        record.vertex_offset = current;
                        record.previous_vertex_offset = if (entity.history_frames != 0) skin_base + (1 - parity) * mesh.vertex_count else current;
                        record.flags = gpu.instance_skinned | gpu.instance_moving;
                        record.bounds_offset = entity.bounds_offsets[model_instance];
                        any_moving = true;
                        if (!noted) noteMover(self, scene, record.bounding_sphere);
                        noted = true;
                    }
                    const range = scene.static_ranges.items[self.scratch_instances.items.len];
                    self.scratch_static_cull.appendAssumeCapacity(.{
                        .sphere = if (skin_base != no_skin) record.bounding_sphere else .{ center[0], center[1], center[2], source.meshes[instance.mesh].bounds_radius * math.maxScale(world) },
                        .first_ref = range[0],
                        .ref_count = range[1],
                        .impostor = impostor_index,
                    });
                    if (mesh.blend) {
                        if (source.materials[source.meshes[instance.mesh].material].transmission > 0) scene.static_transmissive = true;
                        try scene.static_transparent.append(self.gpa, .{
                            .instance = @intCast(entity_count + self.scratch_instances.items.len),
                            .first_index = mesh.index_offset,
                            .index_count = mesh.lod0_index_count,
                            .center = center,
                            .transmissive = source.materials[source.meshes[instance.mesh].material].transmission > 0,
                        });
                    }
                    self.scratch_instances.appendAssumeCapacity(record);
                }
            }
        }
        if (self.scratch_instances.items.len != 0) try device.uploadBuffer(
            records.buffer.?,
            @as(u64, entity_count) * @sizeOf(gpu.Instance),
            std.mem.sliceAsBytes(self.scratch_instances.items),
        );
        if (self.scratch_static_cull.items.len > scene.static_cull_capacity) {
            if (scene.static_cull) |old| device.destroyBuffer(old);
            scene.static_cull = null;
            const capacity: u32 = @intCast(self.scratch_static_cull.items.len + @min(self.scratch_static_cull.items.len / 2, 1 << 16));
            scene.static_cull = try device.createBuffer(.{
                .name = "instance bounds",
                .size = @as(u64, capacity) * @sizeOf(gpu.StaticCull),
                .usage = .{ .storage = true, .copy_dst = true },
            });
            scene.static_cull_capacity = capacity;
        }
        if (self.scratch_static_cull.items.len != 0) try device.uploadBuffer(scene.static_cull.?, 0, std.mem.sliceAsBytes(self.scratch_static_cull.items));
        scene.impostor_count = @intCast(self.scratch_impostors.items.len);
        if (scene.impostor_count > scene.impostor_table_capacity) {
            if (scene.impostor_table) |old| device.destroyBuffer(old);
            scene.impostor_table = null;
            scene.impostor_table = try device.createBuffer(.{
                .name = "impostors",
                .size = @as(u64, scene.impostor_count) * @sizeOf(gpu.Impostor),
                .usage = .{ .storage = true, .copy_dst = true },
            });
            scene.impostor_table_capacity = scene.impostor_count;
        }
        if (scene.impostor_count != 0) try device.uploadBuffer(scene.impostor_table.?, 0, std.mem.sliceAsBytes(self.scratch_impostors.items));
        records.static_version = scene.static_version;
        records.entity_count = entity_count;
    }
    if (scene.static_transmissive) scene.transmissive = true;
    try scene.transparent.appendSlice(self.gpa, scene.static_transparent.items);
    if (group_rays) {
        if (driven or scene.static_tlas_version != scene.static_version or scene.static_tlas_base != entity_count) {
            scene.static_tlas.clearRetainingCapacity();
            var record: u32 = @intCast(entity_count);
            for (scene.groups.items) |group_handle| {
                const group = self.instances.table.get(group_handle) orelse continue;
                if (group.per_copy == 0) continue;
                const model = self.models.table.get(group.model) orelse continue;
                const source = &model.source.?;
                const driver = groupDriver(self, group, source.instances.len);
                for (group.transforms) |placement| {
                    for (source.instances, 0..) |instance, model_instance| {
                        const mesh = model.meshes[instance.mesh];
                        defer record += 1;
                        if (mesh.blend) continue;
                        const posed: ?rhi.AccelerationStructure = if (driver) |entity| (if (entity.skin_offsets[model_instance] != no_skin and model_instance < entity.skin_blas.len) entity.skin_blas[model_instance] else null) else null;
                        const blas = posed orelse mesh.blas orelse continue;
                        const t = if (posed != null) placement else math.mul(placement, model.node_world[instance.node]);
                        try scene.static_tlas.append(self.gpa, .{
                            .transform = .{ t[0], t[4], t[8], t[12], t[1], t[5], t[9], t[13], t[2], t[6], t[10], t[14] },
                            .custom_index_and_mask = (record & 0x00ff_ffff) | 0xff00_0000,
                            .offset_and_flags = 0x0100_0000,
                            .blas = device.accelerationAddress(blas),
                        });
                    }
                }
            }
            scene.static_tlas_version = scene.static_version;
            scene.static_tlas_base = entity_count;
        }
        @memcpy(tlas_instances.items[tlas_count..][0..scene.static_tlas.items.len], scene.static_tlas.items);
        tlas_count += @intCast(scene.static_tlas.items.len);
        tlas_hasher.update(std.mem.asBytes(&scene.static_version));
        if (driven) tlas_hasher.update(std.mem.asBytes(&self.frame_index));
    }

    for (scene.layout.items) |entry| {
        if (!entry.first_of_entity) continue;
        const entity = self.entities.table.get(entry.entity).?;
        entity.travelled = math.length(math.sub(entity.transform[12..15].*, entity.previous_transform[12..15].*));
        entity.previous_transform = entity.transform;
        entity.history_frames +|= 1;
    }
    if (scene.trace_wanted and !device.ray_tracing and self.options.path_tracing_fallback) {
        scene.trace_wanted = false;
        try buildSceneTree(self, scene, instance_records);
    }
    return .{
        .instances = device.bufferAddress(records.buffer.?),
        .previous_transforms = staged_previous.address,
        .staged_buffer = staged.buffer,
        .staged_instances = staged.offset,
        .staged_size = @as(u64, entity_count) * @sizeOf(gpu.Instance),
        .joints = joints.address,
        .skinned_vertices = skinned_vertices,
        .any_moving = any_moving,
        .tlas_instances = tlas_instances.address,
        .tlas_count = tlas_count,
        .tlas_hash = tlas_hasher.final() +% tlas_count,
        .glowing = glowing.address,
        .glowing_count = glowing_count,
        .bounds = bounds,
    };
}

/// Converts the scene's lights to GPU records and assigns shadow atlas
/// tiles to the ones that cast shadows. The scene's first view in a frame
/// ranks the lights; later views keep its choice, as they share the atlas.
pub fn prepareLights(self: *Renderer, scene: *SceneData, arena: *FrameArena, shadows: bool, camera_position: Vec3, traced_shadows: bool) !Lighting {
    const device = self.device;
    var fluid_lights: usize = 0;
    for (scene.fluids.items) |item| {
        if (self.fluids.table.get(item)) |state| fluid_lights += @intFromBool(state.desc.light > 0);
    }
    const lights = try arena.alloc(device, gpu.Light, scene.lights.items.len + fluid_lights);
    const tiles = try arena.alloc(device, gpu.ShadowTile, max_local_shadow_views);
    var result = Lighting{
        .lights = lights.address,
        .tiles = tiles.address,
        .light_count = @intCast(scene.lights.items.len + fluid_lights),
        .tile_count = 0,
        .tile_view_proj = undefined,
        .tile_views = undefined,
    };
    const tiles_per_side = std.math.clamp(self.options.local_shadow_tiles_per_side, 1, local_shadow_tiles_per_side);
    const tile_scale = 1.0 / @as(f32, @floatFromInt(tiles_per_side));
    const axes = [6]Vec3{ .{ 1, 0, 0 }, .{ -1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, -1, 0 }, .{ 0, 0, 1 }, .{ 0, 0, -1 } };
    const granted = try self.gpa.alloc(bool, scene.lights.items.len);
    defer self.gpa.free(granted);
    @memset(granted, false);
    const shared = shadows and scene.shadow_grants_frame == self.frame_index and
        scene.shadow_grants_traced == traced_shadows and scene.shadow_grants.items.len == granted.len;
    if (shared) {
        @memcpy(granted, scene.shadow_grants.items);
    } else if (shadows) {
        const Candidate = struct { index: u32, score: f32 };
        const candidates = try self.gpa.alloc(Candidate, scene.lights.items.len);
        defer self.gpa.free(candidates);
        var candidate_count: usize = 0;
        for (scene.lights.items, 0..) |light, index| {
            if (!light.cast_shadows or light.kind == .directional or light.kind == .rectangle) continue;
            if (traced_shadows and light.kind != .spot and light.source_length > 0) continue;
            const away = math.sub(light.position, camera_position);
            candidates[candidate_count] = .{ .index = @intCast(index), .score = light.intensity * @max(light.color[0], @max(light.color[1], light.color[2])) * light.range / (math.dot(away, away) + 1) };
            candidate_count += 1;
        }
        std.mem.sort(Candidate, candidates[0..candidate_count], {}, struct {
            fn higher(_: void, a: Candidate, b: Candidate) bool {
                return a.score > b.score;
            }
        }.higher);
        var tiles_left: u32 = tiles_per_side * tiles_per_side;
        for (candidates[0..candidate_count]) |candidate| {
            const needed: u32 = if (scene.lights.items[candidate.index].kind == .spot) 1 else 6;
            if (needed > tiles_left) continue;
            tiles_left -= needed;
            granted[candidate.index] = true;
        }
        try scene.shadow_grants.resize(self.gpa, granted.len);
        @memcpy(scene.shadow_grants.items, granted);
        scene.shadow_grants_frame = self.frame_index;
        scene.shadow_grants_traced = traced_shadows;
    }
    result.tiles_key = std.hash.Wyhash.hash(tiles_per_side, std.mem.sliceAsBytes(granted));
    for (scene.lights.items, lights.items[0..scene.lights.items.len], granted) |light, *out, has_tiles| {
        const direction = math.normalize(light.direction);
        const cos_outer = @cos(light.outer_angle);
        const cos_inner = @max(@cos(@min(light.inner_angle, light.outer_angle)), cos_outer + 1e-4);
        const cone_scale = 1.0 / (cos_inner - cos_outer);
        out.* = .{
            .position = light.position,
            .range = light.range,
            .color = math.scale(light.color, light.intensity),
            .flags = switch (light.kind) {
                .point => 0,
                .spot => gpu.light_spot,
                .directional => gpu.light_directional,
                .rectangle => gpu.light_rectangle,
            },
            .source_radius = @max(light.source_radius, 0),
            .source_length = if (light.kind == .point or light.kind == .rectangle) @max(light.source_length, 0) else 0,
            .source_height = if (light.kind == .rectangle) @max(light.source_height, 0) else 0,
            .cookie = if (light.cookie) |image| image.index else gpu.invalid_id,
            .profile = if (light.profile) |image| image.index else gpu.invalid_id,
            .direction = direction,
            .cone_scale = cone_scale,
            .cone_offset = -cos_outer * cone_scale,
        };
        const faces: u32 = if (light.kind == .spot) 1 else 6;
        if (!has_tiles) {
            if (shadows and light.cast_shadows) out.flags |= gpu.light_traced_shadow;
            continue;
        }
        out.flags |= (result.tile_count + 1) << 8;
        for (0..faces) |face| {
            const forward = if (light.kind == .spot) direction else axes[face];
            const up: Vec3 = if (@abs(forward[1]) > 0.99) .{ 0, 0, 1 } else .{ 0, 1, 0 };
            const fov: f32 = if (light.kind == .spot) @min(light.outer_angle * 2 + 0.05, 3.0) else 1.62;
            const view_proj = math.mul(math.perspective(fov, 1, 0.05), math.lookTo(light.position, forward, up));
            const index = result.tile_count;
            var cull = cullView(view_proj, light.position, .perspective);
            cull.planes[5] = .{ -forward[0], -forward[1], -forward[2], math.dot(forward, light.position) + light.range };
            cull.plane_count = 6;
            result.tile_views[index] = cull;
            result.tile_view_proj[index] = view_proj;
            tiles.items[index] = .{
                .view_proj = view_proj,
                .rect = .{
                    tile_scale,
                    tile_scale,
                    @as(f32, @floatFromInt(index % tiles_per_side)) * tile_scale,
                    @as(f32, @floatFromInt(index / tiles_per_side)) * tile_scale,
                },
            };
            result.tile_count += 1;
        }
    }
    var fluid_slot: usize = scene.lights.items.len;
    for (scene.fluids.items) |item| {
        const state = self.fluids.table.get(item) orelse continue;
        if (state.desc.light <= 0) continue;
        const t = state.desc.transform;
        const height = math.length(.{ t[4], t[5], t[6] });
        lights.items[fluid_slot] = .{
            .position = .{ t[12], t[13], t[14] },
            .range = if (state.desc.light_range > 0) state.desc.light_range else height * 3,
            .color = .{ 0, 0, 0 },
            .flags = gpu.light_fire | (if (shadows) gpu.light_traced_shadow else 0),
            .source_radius = height * @max(state.desc.light_size, 0),
        };
        fluid_slot += 1;
    }
    return result;
}

/// Closes gaps in the vertex and index pools: when a quarter or more of
/// a pool's span is free, moves its last mesh into the first gap that
/// holds it, one mesh per pool per frame. Returns whether anything moved.
pub fn compactGeometry(self: *Renderer, cmd: *rhi.CommandEncoder) !bool {
    var moved = false;
    inline for (.{ "vertices", "indices" }) |name| {
        const pool: *Pool = &@field(self, name);
        const vertices = comptime std.mem.eql(u8, name, "vertices");
        var free_inside: u64 = 0;
        for (pool.ranges.free_ranges.items) |range| free_inside += range.count;
        if (free_inside * 4 >= pool.ranges.top and @as(u64, pool.ranges.top) * pool.stride >= 1 << 20) find: {
            var last_entry: ?*ModelEntry = null;
            var last_mesh: usize = 0;
            var last_end: u32 = 0;
            for (self.models.table.slots.items) |*slot| if (slot.value) |*entry| {
                if (entry.state != .ready or !entry.geometry_resident or entry.geometry_coarse) continue;
                for (entry.meshes, 0..) |mesh, index| {
                    const end = if (vertices) mesh.vertex_offset + mesh.vertex_count else mesh.index_offset + mesh.index_count;
                    if (end > last_end) {
                        last_end = end;
                        last_entry = entry;
                        last_mesh = index;
                    }
                }
            };
            const entry = last_entry orelse break :find;
            if (last_end != pool.ranges.top or entry.blas_pending) break :find;
            const mesh = &entry.meshes[last_mesh];
            const count = if (vertices) mesh.vertex_count else mesh.index_count;
            const old = if (vertices) mesh.vertex_offset else mesh.index_offset;
            if (count == 0 or @as(u64, count) * pool.stride > 16 << 20) break :find;
            const new = pool.ranges.alloc(count) orelse break :find;
            if (new + count > old) {
                pool.ranges.free(self.gpa, new, count);
                break :find;
            }
            cmd.sync(.all_to_transfer);
            cmd.copyBuffer(pool.buffer, pool.buffer, @as(u64, old) * pool.stride, @as(u64, new) * pool.stride, @as(u64, count) * pool.stride);
            cmd.sync(.transfer_to_all);
            if (vertices) mesh.vertex_offset = new else mesh.index_offset = new;
            if (!vertices) {
                const source_mesh = entry.source.?.meshes[last_mesh];
                const record = gpu.Mesh{
                    .center = source_mesh.bounds_center,
                    .radius = source_mesh.bounds_radius,
                    .index_offset = mesh.index_offset,
                    .meshlet_offset = mesh.meshlet_offset,
                    .meshlet_count = mesh.meshlet_count,
                    .bvh = mesh.bvh_nodes orelse gpu.invalid_id,
                };
                try self.meshes.write(self.device, entry.mesh_base + @as(u32, @intCast(last_mesh)), std.mem.asBytes(&record));
            }
            for (self.scenes.table.slots.items) |*slot| if (slot.value) |*scene| {
                scene.static_version += 1;
            };
            self.stats.geometry_bytes_compacted += @as(u64, count) * pool.stride;
            pool.free(self, old, count);
            moved = true;
        }
    }
    return moved;
}

/// Builds acceleration structures of newly loaded models. With
/// `frame_index` and a second GPU queue they build asynchronously and are
/// adopted when done; otherwise `cmd` builds them at once. Must run after
/// their geometry uploads have been recorded.
pub fn buildPendingBlas(self: *Renderer, cmd: *rhi.CommandEncoder, frame_index: ?u64) !void {
    if (self.blas_pending == 0) return;
    const device = self.device;
    var still_pending: u32 = 0;
    var finished = false;
    for (self.models.table.slots.items) |*slot| if (slot.value) |*entry| {
        if (!entry.blas_pending) continue;
        const frame_now = frame_index orelse {
            if (entry.blas_job) |job| {
                device.releaseDetached(job);
                entry.blas_job = null;
            } else for (entry.meshes) |mesh| {
                if (mesh.blas_building orelse mesh.blas) |blas| try cmd.buildBlas(blas, geometry_passes.blasDesc(self, mesh));
            }
            finished = adoptBlas(self, entry) or finished;
            continue;
        };
        if (entry.blas_job) |job| {
            if (!device.detachedDone(job)) {
                still_pending += 1;
                continue;
            }
            device.releaseDetached(job);
            entry.blas_job = null;
            finished = adoptBlas(self, entry) or finished;
            continue;
        }
        var detached = false;
        for (entry.meshes) |mesh| detached = detached or mesh.blas_building != null;
        if (!detached) {
            entry.blas_pending = false;
            for (entry.meshes) |mesh| if (mesh.blas) |blas| try cmd.buildBlas(blas, geometry_passes.blasDesc(self, mesh));
            continue;
        }
        still_pending += 1;
        const carried = entry.blas_frame orelse {
            entry.blas_frame = frame_now;
            continue;
        };
        if (frame_now < carried + rhi.frames_in_flight) continue;
        var encoder = (try device.beginDetached()).?;
        for (entry.meshes) |mesh| if (mesh.blas_building) |blas| try encoder.buildBlas(blas, geometry_passes.blasDesc(self, mesh));
        entry.blas_job = try device.submitDetached(encoder);
    };
    self.blas_pending = still_pending;
    if (finished) self.asset_generation += 1;
}

/// Makes a model's finished acceleration structures the live ones.
/// Returns whether there were any.
fn adoptBlas(self: *Renderer, entry: *ModelEntry) bool {
    _ = self;
    var any = false;
    for (entry.meshes) |*mesh| if (mesh.blas_building) |built| {
        mesh.blas = built;
        mesh.blas_building = null;
        any = true;
    };
    entry.blas_pending = false;
    entry.blas_frame = null;
    return any;
}
