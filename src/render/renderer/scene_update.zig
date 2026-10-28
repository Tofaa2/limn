//! A scene's per-frame GPU state: poses, instance records, skinning and acceleration structures. Internal to the renderer.
const pipelines_module = @import("pipelines.zig");
const instance_update_push = @import("../shaders/push/instance_update.zig");
const std = @import("std");
const geometry_feature = @import("../features/geometry.zig");
const rhi = @import("../../rhi/rhi.zig");
const math = @import("../../math.zig");
const gpu = @import("../gpu.zig");
const animation = @import("../animation.zig");
const api = @import("../api.zig");
const renderer_state = @import("../state.zig");
const scene_pass = @import("../scene_pass.zig");
const render = @import("../renderer.zig");

const Renderer = render.Renderer;
const Mat4 = math.Mat4;
const Vec3 = math.Vec3;
const SceneFrame = scene_pass.SceneFrame;
const Entity = api.Entity;
const Zone = renderer_state.Zone;
const Pool = renderer_state.Pool;
const FrameArena = renderer_state.FrameArena;
const ModelEntry = renderer_state.ModelEntry;
const SceneData = renderer_state.SceneData;
const no_skin = renderer_state.no_skin;
const max_worker_threads = renderer_state.max_worker_threads;
const prepare_batch = renderer_state.prepare_batch;
const EntryInfo = renderer_state.EntryInfo;
const EntityMark = renderer_state.EntityMark;
const InstanceMove = renderer_state.InstanceMove;
const InstanceRewrite = renderer_state.InstanceRewrite;
const Glowing = renderer_state.Glowing;
const pose_batch = renderer_state.pose_batch;
const buildSceneTree = @import("models.zig").buildSceneTree;
const groupDriver = @import("scenes.zig").groupDriver;

const scene_layout = @import("scene_layout.zig");
const scene_records = @import("scene_records.zig");
const noteMover = scene_layout.noteMover;
const rebuildLayout = scene_layout.rebuildLayout;
const applyStructure = scene_layout.applyStructure;
const rigidRecord = scene_layout.rigidRecord;
const tlasInstance = scene_layout.tlasInstance;
const PrepareWhole = scene_records.PrepareWhole;
const Changes = scene_records.Changes;
const MoveShare = scene_records.MoveShare;
const moveThreads = scene_records.moveThreads;
const moveAcrossThreads = scene_records.moveAcrossThreads;

/// Computes node matrices of the scene's animated entities for this
/// frame, across threads when there are enough.
fn evaluatePoses(self: *Renderer, scene: *SceneData) !void {
    const zone = Zone.start(self.options.profiler, "poses");
    defer zone.stop();
    const posed = scene.posed.items;
    const most_nodes = scene.posed_nodes;
    const count = posed.len;
    if (count == 0) return;
    const threads = std.math.clamp(count / pose_batch, 1, workerThreads(self));
    for (self.internal.pose_scratch[0..threads]) |*scratch| try scratch.resize(self.internal.gpa, most_nodes * 3);
    if (threads == 1) return poseEntities(self, posed, self.internal.pose_scratch[0].items);
    var group: std.Io.Group = .init;
    const share = (count + threads - 1) / threads;
    for (1..threads) |index| {
        const batch = posed[@min(index * share, count)..@min((index + 1) * share, count)];
        group.concurrent(self.internal.io, poseEntities, .{ self, batch, self.internal.pose_scratch[index].items }) catch
            poseEntities(self, batch, self.internal.pose_scratch[index].items);
    }
    poseEntities(self, posed[0..@min(share, count)], self.internal.pose_scratch[0].items);
    group.await(self.internal.io) catch {};
}

/// Runs on any thread. Writes only each entity's own node matrices; no
/// two batches share an entity.
fn poseEntities(self: *Renderer, entities: []const Entity, scratch: []animation.Local) void {
    for (entities) |handle_value| {
        const entity = self.entities.internal.table.get(handle_value).?;
        const model = self.models.internal.table.get(entity.model).?;
        std.mem.swap([]Mat4, &entity.node_world, &entity.previous_node_world);
        animation.evaluate(&model.source.?, model.pose_order, entity.pose, scratch, entity.node_world);
        if (entity.history_frames == 0) @memcpy(entity.previous_node_world, entity.node_world);
    }
}

/// Threads the per-frame scene work may use, the rendering thread included.
pub fn workerThreads(self: *Renderer) usize {
    return switch (self.options.worker_threads) {
        0 => @min(std.Thread.getCpuCount() catch 1, max_worker_threads),
        else => |asked| @min(asked, max_worker_threads),
    };
}

/// Makes `slot` a buffer of at least `count` values of `size` bytes. Returns
/// whether it is a new one.
fn ensureBuffer(self: *Renderer, slot: *?rhi.Buffer, capacity: *u32, count: usize, size: u64, name: [:0]const u8, usage: rhi.BufferUsage) !bool {
    if (slot.* != null and capacity.* >= count) return false;
    if (slot.*) |old| self.device.destroyBuffer(old);
    slot.* = null;
    capacity.* = @intCast(@max(count + count / 2, 64));
    slot.* = try self.device.createBuffer(.{ .name = name, .size = @as(u64, capacity.*) * size, .usage = usage });
    return true;
}

/// Brings a scene's instance records, joint matrices and ray-tracing
/// instances up to date and queues the skinning jobs. Entities that did not
/// change cost nothing unless the layout did.
pub fn prepareScene(self: *Renderer, scene: *SceneData, arena: *FrameArena) !SceneFrame {
    const zone = Zone.start(self.options.profiler, "prepare scene");
    defer zone.stop();
    const device = self.device;
    scene.movers.clearRetainingCapacity();
    scene.movers_overflow = false;
    if (scene.layout_dirty or scene.layout_generation != self.internal.asset_generation) {
        try rebuildLayout(self, scene);
    } else if (scene.added.items.len != 0 or scene.removed.items.len != 0 or scene.quarantine.items.len != 0) {
        if (!try applyStructure(self, scene)) try rebuildLayout(self, scene);
    }
    const layout = scene.layout.items;
    const entries = scene.entries.items;
    const entity_count = layout.len;
    const entity_base = scene.entity_capacity;
    const total = entity_base + scene.static_count;
    const records = &scene.instance_slots[0];
    const group_rays = device.caps.ray_tracing and scene.static_count != 0 and scene.static_count <= self.options.ray_tracing.instance_limit;
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
        scene.records_valid = false;
    }
    if (try ensureBuffer(self, &scene.previous, &scene.previous_capacity, entity_base, @sizeOf([12]f32), "previous transforms", .{ .storage = true, .copy_dst = true }))
        scene.records_valid = false;
    const rigid_room = if (group_rays) scene.entity_tlas_capacity else scene.rigid_tlas;
    const tlas_room = rigid_room + (if (group_rays) scene.static_count else 0) + scene.skinned_entries;
    if (try ensureBuffer(self, &scene.tlas_instances, &scene.tlas_instances_capacity, tlas_room, @sizeOf(rhi.AccelerationInstance), "ray tracing instances", .{ .storage = true, .copy_dst = true, .acceleration_input = true })) {
        scene.records_valid = false;
        scene.static_tlas_uploaded = false;
    }
    const tree_wanted = scene.trace_wanted and !device.caps.ray_tracing and self.options.ray_tracing.software_path_tracing;
    if (tree_wanted) scene.records_valid = false;
    const whole = !scene.records_valid;

    const joints = try arena.alloc(device, Mat4, scene.joint_count);
    scene.skin_jobs.clearRetainingCapacity();
    scene.skin_weights.clearRetainingCapacity();
    scene.bounds_jobs.clearRetainingCapacity();
    scene.blas_jobs.clearRetainingCapacity();
    try evaluatePoses(self, scene);
    for (scene.hairs.items) |hair_handle| {
        const hair = self.hairs.internal.table.get(hair_handle) orelse continue;
        if (hair.simulation == null) continue;
        const center = math.transformPoint(hair.desc.transform, hair.bounds[0..3].*);
        noteMover(self, scene, .{ center[0], center[1], center[2], hair.bounds[3] * math.maxScale(hair.desc.transform) * 1.6 });
    }

    var update = scene_pass.SceneUpdate{ .whole = whole, .entity_count = @intCast(entity_count), .rigid_tlas = rigid_room };
    var staged_records: []gpu.Instance = &.{};
    var staged_previous: [][12]f32 = &.{};
    var changes = Changes{ .renderer = self, .scene = scene, .moves = &.{}, .rewrites = &.{} };
    var whole_prepare: ?PrepareWhole = null;
    if (whole) {
        const staged = try arena.alloc(device, gpu.Instance, entity_count);
        const staged_before = try arena.alloc(device, [12]f32, entity_count);
        const staged_tlas = try arena.alloc(device, rhi.AccelerationInstance, rigid_room);
        @memset(staged_tlas.items, std.mem.zeroes(rhi.AccelerationInstance));
        staged_records = staged.items;
        staged_previous = staged_before.items;
        update.records = .{ .buffer = staged.buffer, .offset = staged.offset };
        update.previous = .{ .buffer = staged_before.buffer, .offset = staged_before.offset };
        update.tlas = .{ .buffer = staged_tlas.buffer, .offset = staged_tlas.offset };
        try self.internal.prepare_chunks.resize(self.internal.gpa, scene.chunk_stale.items.len);
        whole_prepare = PrepareWhole{
            .renderer = self,
            .scene = scene,
            .records = staged_records,
            .previous = staged_previous,
            .tlas = staged_tlas.items,
            .chunks = self.internal.prepare_chunks.items,
        };
        const prepare = whole_prepare.?;
        prepare.spread(PrepareWhole.batch);
        for (prepare.chunks) |chunk| changes.any_moving = changes.any_moving or chunk.any_moving;
        scene.settling.clearRetainingCapacity();
        for (entries, 0..) |info, index| {
            if (info.bits & EntryInfo.moved == 0) continue;
            noteMover(self, scene, scene.spheres.items[index]);
            if (info.bits & EntryInfo.posed == 0) scene.settling.append(self.internal.gpa, .{ @intCast(index), layout[index].entity.index }) catch {
                scene.layout_dirty = true;
            };
        }
        @memset(scene.chunk_stale.items, true);
        changes.tlas_changed = true;
    } else {
        var edited_entries: usize = 0;
        for (scene.edited.items) |slot| edited_entries += self.internal.entity_marks.items[slot].layout_count;
        edited_entries = @max(edited_entries, scene.edited_entries);
        const threaded_room: u32 = if (moveThreads(self, scene) == 1) 0 else @intCast(edited_entries + edited_entries / 8 + max_worker_threads * MoveShare.block);
        const moves = try arena.alloc(device, InstanceMove, edited_entries + scene.settling.items.len + scene.posed_entries + threaded_room);
        const rewrites = try arena.alloc(device, InstanceRewrite, @min(entity_count, scene.restyled_entries + scene.posed_entries));
        changes.moves = moves.items;
        changes.rewrites = rewrites.items;
        update.moves = moves.address;
        update.rewrites = rewrites.address;
        std.mem.swap(std.ArrayList([2]u32), &scene.settling, &self.internal.scratch_settling);
        scene.settling.clearRetainingCapacity();
        for (self.internal.scratch_settling.items) |pair| {
            const mark = &self.internal.entity_marks.items[pair[1]];
            const info = &entries[pair[0]];
            if (mark.bits & EntityMark.listed != 0 or info.bits & EntryInfo.moved == 0) continue;
            changes.move(pair[0], info, math.mul(self.internal.entity_transforms.items[pair[1]], info.rest.?.*), InstanceMove.keep);
            mark.travelled = 0;
        }

        try moveAcrossThreads(self, scene, &changes, threaded_room);
        var deferred: usize = 0;
        for (scene.edited.items) |slot| {
            const mark = &self.internal.entity_marks.items[slot];
            if (mark.handle == 0 or mark.bits & EntityMark.listed == 0 or self.scenes.internal.table.get(mark.scene) != scene) continue;
            mark.bits &= ~EntityMark.listed;
            const now = self.internal.entity_transforms.items[slot];
            const before = &self.internal.entity_previous.items[slot];
            const changed = !std.mem.eql(f32, &now, before);
            const jumped = mark.bits & EntityMark.teleported != 0;
            const whole_records = mark.bits & EntityMark.restyled != 0 or (jumped and changed);
            const flags: u32 = if (jumped) 0 else if (changed) InstanceMove.moved | InstanceMove.keep else InstanceMove.keep;
            var animated = false;
            for (entries[mark.layout_first..][0..mark.layout_count], mark.layout_first..) |*info, index| {
                const rest = info.rest orelse {
                    animated = true;
                    continue;
                };
                if (info.bits & EntryInfo.skinned != 0) {
                    animated = true;
                    continue;
                }
                const transform = math.mul(now, rest.*);
                if (whole_records) {
                    const entry = layout[index];
                    const entity = self.entities.internal.table.get(entry.entity).?;
                    const model = self.models.internal.table.get(entity.model).?;
                    const record = rigidRecord(self, entity, model, model.source.?.instances[entry.model_instance].mesh, transform, !changed, info.bits & EntryInfo.glows != 0);
                    changes.rewrite(@intCast(index), info, record, math.mul(before.*, rest.*), transform, changed or jumped);
                } else changes.move(@intCast(index), info, transform, flags);
                if (info.bits & EntryInfo.moved != 0) scene.settling.append(self.internal.gpa, .{ @intCast(index), slot }) catch {
                    scene.layout_dirty = true;
                };
            }
            if (animated) {
                scene.edited.items[deferred] = slot;
                deferred += 1;
                continue;
            }
            mark.travelled = if (jumped) 0 else math.length(math.sub(now[12..15].*, before[12..15].*));
            before.* = now;
            mark.bits = 0;
        }
        scene.edited.shrinkRetainingCapacity(deferred);
    }

    const parity: u32 = @intCast(self.internal.frame_index & 1);
    const skinned_tlas = try arena.alloc(device, rhi.AccelerationInstance, scene.skinned_entries);
    var skinned_tlas_count: u32 = 0;
    var joint_cursor: u32 = 0;
    var bounds_cursor: u32 = 0;
    var skinned_vertices: u32 = 0;
    for (scene.posed.items) |handle_value| {
        const slot = handle_value.index;
        const mark = &self.internal.entity_marks.items[slot];
        const entity = self.entities.internal.table.get(handle_value).?;
        const model = self.models.internal.table.get(entity.model).?;
        const source = &model.source.?;
        const now = self.internal.entity_transforms.items[slot];
        const before = self.internal.entity_previous.items[slot];
        const entity_changed = !std.mem.eql(f32, &now, &before);
        const jumped = mark.bits & EntityMark.teleported != 0;
        const restyled = mark.bits & EntityMark.restyled != 0;
        var shared_skin: ?u32 = null;
        var shared_joints: u32 = 0;
        var shared_center: Vec3 = .{ 0, 0, 0 };
        var shared_radius: f32 = 0;
        for (entries[mark.layout_first..][0..mark.layout_count], mark.layout_first..) |*info, instance_index| {
            const index: u32 = @intCast(instance_index);
            const model_instance = layout[instance_index].model_instance;
            const instance = source.instances[model_instance];
            if (info.bits & EntryInfo.skinned == 0) {
                if (whole or info.rest != null) continue;
                const node_changed = !std.mem.eql(f32, &entity.node_world[instance.node], &entity.previous_node_world[instance.node]);
                const changed = entity_changed or node_changed;
                const transform = math.mul(now, entity.node_world[instance.node]);
                if (restyled or (jumped and changed)) {
                    const record = rigidRecord(self, entity, model, instance.mesh, transform, !changed, info.bits & EntryInfo.glows != 0);
                    changes.rewrite(index, info, record, math.mul(before, entity.previous_node_world[instance.node]), transform, changed or jumped);
                } else if (changed or jumped) {
                    changes.move(index, info, transform, if (jumped) 0 else InstanceMove.moved | InstanceMove.keep);
                } else if (info.bits & EntryInfo.moved != 0) {
                    changes.move(index, info, transform, InstanceMove.keep);
                }
                continue;
            }

            const mesh = model.meshes[instance.mesh];
            const skin_base = entity.skin_offsets[model_instance];
            const skin = source.skins[instance.skin.?];
            if (shared_skin == null or shared_skin.? != instance.skin.?) {
                shared_skin = instance.skin.?;
                shared_joints = joint_cursor;
                var minimum: Vec3 = @splat(std.math.inf(f32));
                var model_minimum: Vec3 = @splat(std.math.inf(f32));
                var model_maximum: Vec3 = @splat(-std.math.inf(f32));
                var maximum: Vec3 = @splat(-std.math.inf(f32));
                for (skin.joints, skin.inverse_bind, 0..) |joint, inverse_bind, joint_index| {
                    joints.items[joint_cursor + joint_index] = math.mul(entity.node_world[joint], inverse_bind);
                    const position = math.transformPoint(now, entity.node_world[joint][12..15].*);
                    inline for (0..3) |axis| {
                        model_minimum[axis] = @min(model_minimum[axis], entity.node_world[joint][12 + axis]);
                        model_maximum[axis] = @max(model_maximum[axis], entity.node_world[joint][12 + axis]);
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
            const padding = model.info.bounds_radius * 0.25 * math.maxScale(now);
            noteMover(self, scene, .{ center[0], center[1], center[2], shared_radius + padding });
            const current = skin_base + parity * mesh.vertex_count;
            const own_bounds = self.options.geometry.skinned_meshlet_bounds and mesh.meshlet_count != 0;
            const previous = skin_base + (1 - parity) * mesh.vertex_count;
            changes.any_moving = true;
            const record = gpu.Instance{
                .transform = gpu.affine(now),
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
            if (whole) {
                staged_records[index] = record;
                staged_previous[index] = gpu.affine(before);
            } else {
                changes.rewrites[changes.rewrite_count] = .{ .instance = index, .previous = gpu.affine(before), .record = record };
                changes.rewrite_count += 1;
            }
            const drawn_center = math.transformPoint(now, info.center);
            scene.spheres.items[index] = .{ drawn_center[0], drawn_center[1], drawn_center[2], 0 };
            var morph_weights = source.meshes[instance.mesh].morph_weights;
            if (mesh.morph_targets != 0) {
                if (entity.pose) |pose| animation.poseWeights(source, pose, instance.node, morph_weights[0..mesh.morph_targets]);
                if (entity.morph_weights) |override| morph_weights = override;
            }
            entity.bounds_offsets[model_instance] = gpu.invalid_id;
            if (own_bounds) {
                entity.bounds_offsets[model_instance] = bounds_cursor;
                try scene.bounds_jobs.append(self.internal.gpa, .{ .vertex_offset = current, .meshlet_offset = mesh.meshlet_offset, .meshlet_count = mesh.meshlet_count, .bounds_offset = bounds_cursor });
                bounds_cursor += mesh.meshlet_count;
            }
            const weights_offset: u32 = @intCast(scene.skin_weights.items.len);
            try scene.skin_weights.appendSlice(self.internal.gpa, morph_weights[0..mesh.morph_targets]);
            try scene.skin_jobs.append(self.internal.gpa, .{
                .source_offset = mesh.vertex_offset,
                .destination_offset = current,
                .skin_offset = mesh.skin_offset.?,
                .joint_offset = shared_joints,
                .vertex_count = mesh.vertex_count,
                .morph_offset = mesh.morph_offset orelse 0,
                .target_count = mesh.morph_targets,
                .weights_offset = weights_offset,
            });
            if (self.options.ray_tracing.dynamic_geometry and device.caps.ray_tracing and !mesh.blend) {
                var dynamic_geometry = geometry_feature.blasGeometry(self, mesh);
                dynamic_geometry.vertex_offset = @as(u64, current) * @sizeOf(gpu.Vertex);
                const slot_blas = &entity.skin_blas[model_instance];
                if (slot_blas.* == null) slot_blas.* = try device.createBlas(.{ .geometries = &.{dynamic_geometry}, .dynamic = true });
                try scene.blas_jobs.append(self.internal.gpa, .{ .blas = slot_blas.*.?, .vertex_offset = current, .mesh = mesh });
                skinned_tlas.items[skinned_tlas_count] = tlasInstance(device, slot_blas.*.?, instance_index, false, now);
                skinned_tlas_count += 1;
                changes.tlas_changed = true;
            }
            skinned_vertices += mesh.vertex_count;
        }
        if (!whole and mark.bits == 0) mark.travelled = 0;
        entity.history_frames +|= 1;
    }
    if (whole_prepare) |prepare| prepare.spread(PrepareWhole.finish);
    for (scene.edited.items) |slot| {
        const mark = &self.internal.entity_marks.items[slot];
        if (whole) {
            if (mark.handle == 0 or self.scenes.internal.table.get(mark.scene) != scene) continue;
        } else {
            const now = self.internal.entity_transforms.items[slot];
            const before = &self.internal.entity_previous.items[slot];
            mark.travelled = if (mark.bits & EntityMark.teleported != 0) 0 else math.length(math.sub(now[12..15].*, before[12..15].*));
            before.* = now;
        }
        mark.bits = 0;
    }
    scene.edited.clearRetainingCapacity();
    scene.edited_entries = 0;
    scene.restyled_entries = 0;
    scene.records_valid = true;

    var bounds = [2]Vec3{ @splat(std.math.inf(f32)), @splat(-std.math.inf(f32)) };
    for (scene.chunk_stale.items, scene.chunk_bounds.items, 0..) |*stale, *chunk_bounds, chunk_index| {
        if (stale.*) {
            stale.* = false;
            chunk_bounds.* = .{ @splat(std.math.inf(f32)), @splat(-std.math.inf(f32)) };
            const start = chunk_index * prepare_batch;
            const end = @min(start + prepare_batch, entity_count);
            for (entries[start..end], scene.spheres.items[start..end]) |info, sphere| {
                if (info.tlas_slot == gpu.invalid_id) continue;
                inline for (0..3) |axis| {
                    chunk_bounds[0][axis] = @min(chunk_bounds[0][axis], sphere[axis] - sphere[3]);
                    chunk_bounds[1][axis] = @max(chunk_bounds[1][axis], sphere[axis] + sphere[3]);
                }
            }
        }
        inline for (0..3) |axis| {
            bounds[0][axis] = @min(bounds[0][axis], chunk_bounds[0][axis]);
            bounds[1][axis] = @max(bounds[1][axis], chunk_bounds[1][axis]);
        }
    }

    try scene.transparent.resize(self.internal.gpa, scene.blended.items.len);
    for (scene.transparent.items, scene.blended.items) |*draw, blended| {
        draw.* = blended;
        draw.center = scene.spheres.items[blended.instance][0..3].*;
    }
    scene.transmissive = scene.blended_transmissive;
    const glowing = try arena.alloc(device, Glowing, scene.glowing.items.len);
    @memcpy(glowing.items, scene.glowing.items);

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
        const group = self.instances.internal.table.get(group_handle) orelse continue;
        if (group.driver != null) driven = true;
    }
    if (driven or records.static_version != scene.static_version or records.entity_base != entity_base) {
        self.internal.scratch_instances.clearRetainingCapacity();
        self.internal.scratch_static_cull.clearRetainingCapacity();
        try self.internal.scratch_static_cull.ensureTotalCapacity(self.internal.gpa, scene.static_count);
        self.internal.scratch_impostors.clearRetainingCapacity();
        scene.static_transparent.clearRetainingCapacity();
        scene.static_transmissive = false;
        try self.internal.scratch_instances.ensureTotalCapacity(self.internal.gpa, scene.static_count);
        for (scene.groups.items) |group_handle| {
            const group = self.instances.internal.table.get(group_handle) orelse continue;
            if (group.per_copy == 0) continue;
            const model = self.models.internal.table.get(group.model) orelse continue;
            const source = &model.source.?;
            const driver = groupDriver(self, group, source.instances.len);
            var impostor_index: u32 = 0;
            if (group.impostor) |impostor| if (impostor.baked and group.per_copy == 1 and driver == null) {
                const whole_mesh = source.meshes[source.instances[0].mesh];
                try self.internal.scratch_impostors.append(self.internal.gpa, .{
                    .center = whole_mesh.bounds_center,
                    .radius = whole_mesh.bounds_radius,
                    .color_texture = device.textureIndex(impostor.color),
                    .normal_texture = device.textureIndex(impostor.normal),
                    .pixels = impostor.pixels,
                });
                impostor_index = @intCast(self.internal.scratch_impostors.items.len);
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
                        record.previous_vertex_offset = if (entity.history_frames > 1) skin_base + (1 - parity) * mesh.vertex_count else current;
                        record.flags = gpu.instance_skinned | gpu.instance_moving;
                        record.bounds_offset = entity.bounds_offsets[model_instance];
                        changes.any_moving = true;
                        if (!noted) noteMover(self, scene, record.bounding_sphere);
                        noted = true;
                    }
                    const range = scene.static_ranges.items[self.internal.scratch_instances.items.len];
                    self.internal.scratch_static_cull.appendAssumeCapacity(.{
                        .sphere = if (skin_base != no_skin) record.bounding_sphere else .{ center[0], center[1], center[2], source.meshes[instance.mesh].bounds_radius * math.maxScale(world) },
                        .first_ref = range[0],
                        .ref_count = range[1],
                        .impostor = impostor_index,
                    });
                    if (mesh.blend) {
                        if (source.materials[source.meshes[instance.mesh].material].transmission > 0) scene.static_transmissive = true;
                        try scene.static_transparent.append(self.internal.gpa, .{
                            .instance = @intCast(entity_base + self.internal.scratch_instances.items.len),
                            .first_index = mesh.index_offset,
                            .index_count = mesh.lod0_index_count,
                            .center = center,
                            .transmissive = source.materials[source.meshes[instance.mesh].material].transmission > 0,
                        });
                    }
                    self.internal.scratch_instances.appendAssumeCapacity(record);
                }
            }
        }
        if (self.internal.scratch_instances.items.len != 0) try device.uploadBuffer(
            records.buffer.?,
            @as(u64, entity_base) * @sizeOf(gpu.Instance),
            std.mem.sliceAsBytes(self.internal.scratch_instances.items),
        );
        if (self.internal.scratch_static_cull.items.len > scene.static_cull_capacity) {
            if (scene.static_cull) |old| device.destroyBuffer(old);
            scene.static_cull = null;
            const capacity: u32 = @intCast(self.internal.scratch_static_cull.items.len + @min(self.internal.scratch_static_cull.items.len / 2, 1 << 16));
            scene.static_cull = try device.createBuffer(.{
                .name = "instance bounds",
                .size = @as(u64, capacity) * @sizeOf(gpu.StaticCull),
                .usage = .{ .storage = true, .copy_dst = true },
            });
            scene.static_cull_capacity = capacity;
        }
        if (self.internal.scratch_static_cull.items.len != 0) try device.uploadBuffer(scene.static_cull.?, 0, std.mem.sliceAsBytes(self.internal.scratch_static_cull.items));
        scene.impostor_count = @intCast(self.internal.scratch_impostors.items.len);
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
        if (scene.impostor_count != 0) try device.uploadBuffer(scene.impostor_table.?, 0, std.mem.sliceAsBytes(self.internal.scratch_impostors.items));
        records.static_version = scene.static_version;
        records.entity_base = entity_base;
    }
    if (scene.static_transmissive) scene.transmissive = true;
    try scene.transparent.appendSlice(self.internal.gpa, scene.static_transparent.items);
    var tlas_count = rigid_room;
    if (group_rays) {
        if (driven or scene.static_tlas_version != scene.static_version or scene.static_tlas_base != entity_base) {
            scene.static_tlas.clearRetainingCapacity();
            var record: u32 = entity_base;
            for (scene.groups.items) |group_handle| {
                const group = self.instances.internal.table.get(group_handle) orelse continue;
                if (group.per_copy == 0) continue;
                const model = self.models.internal.table.get(group.model) orelse continue;
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
                        try scene.static_tlas.append(self.internal.gpa, tlasInstance(device, blas, record, false, t));
                    }
                }
            }
            scene.static_tlas_version = scene.static_version;
            scene.static_tlas_base = entity_base;
            scene.static_tlas_uploaded = false;
        }
        if (!scene.static_tlas_uploaded or whole) {
            if (scene.static_tlas.items.len != 0) try device.uploadBuffer(
                scene.tlas_instances.?,
                @as(u64, rigid_room) * @sizeOf(rhi.AccelerationInstance),
                std.mem.sliceAsBytes(scene.static_tlas.items),
            );
            scene.static_tlas_uploaded = true;
            changes.tlas_changed = true;
        }
        tlas_count += @intCast(scene.static_tlas.items.len);
    }
    update.skinned_tlas = .{ .buffer = skinned_tlas.buffer, .offset = skinned_tlas.offset };
    update.skinned_tlas_count = skinned_tlas_count;
    update.skinned_tlas_first = tlas_count;
    tlas_count += skinned_tlas_count;
    update.move_count = changes.move_count;
    update.rewrite_count = changes.rewrite_count;
    if (changes.tlas_changed or scene.tlas_content == 0) scene.tlas_content += 1;

    if (tree_wanted) {
        scene.trace_wanted = false;
        try buildSceneTree(self, scene, staged_records);
    }
    return .{
        .instances = device.bufferAddress(records.buffer.?),
        .previous_transforms = device.bufferAddress(scene.previous.?),
        .update = update,
        .joints = joints.address,
        .skinned_vertices = skinned_vertices,
        .any_moving = changes.any_moving,
        .tlas_instances = device.bufferAddress(scene.tlas_instances.?),
        .tlas_count = tlas_count,
        .tlas_hash = scene.tlas_content,
        .glowing = glowing.address,
        .glowing_count = @intCast(scene.glowing.items.len),
        .bounds = bounds,
    };
}

/// Records the GPU side of `prepareScene`: copies and compute passes that
/// bring the scene's instance buffers up to date.
pub fn applySceneUpdate(self: *Renderer, cmd: *rhi.CommandEncoder, scene: *SceneData, update: scene_pass.SceneUpdate) !void {
    const tlas_size = @sizeOf(rhi.AccelerationInstance);
    const copies = update.whole or update.skinned_tlas_count != 0;
    if (copies) cmd.sync(.all_to_transfer);
    if (update.whole and update.entity_count != 0) {
        cmd.copyBuffer(update.records.buffer, scene.instance_slots[0].buffer.?, update.records.offset, 0, @as(u64, update.entity_count) * @sizeOf(gpu.Instance));
        cmd.copyBuffer(update.previous.buffer, scene.previous.?, update.previous.offset, 0, @as(u64, update.entity_count) * @sizeOf([12]f32));
    }
    if (update.whole and update.rigid_tlas != 0)
        cmd.copyBuffer(update.tlas.buffer, scene.tlas_instances.?, update.tlas.offset, 0, @as(u64, update.rigid_tlas) * tlas_size);
    if (update.skinned_tlas_count != 0)
        cmd.copyBuffer(update.skinned_tlas.buffer, scene.tlas_instances.?, update.skinned_tlas.offset, @as(u64, update.skinned_tlas_first) * tlas_size, @as(u64, update.skinned_tlas_count) * tlas_size);
    if (copies) cmd.sync(.transfer_to_all);
    if (update.move_count == 0 and update.rewrite_count == 0) return;
    const Push = instance_update_push.Push;
    var push = Push{
        .records = self.device.bufferAddress(scene.instance_slots[0].buffer.?),
        .previous = self.device.bufferAddress(scene.previous.?),
        .tlas = self.device.bufferAddress(scene.tlas_instances.?),
        .updates = update.moves,
        .count = update.move_count,
    };
    if (update.move_count != 0) {
        cmd.bindPipeline(try self.internal.pipelines.of(instanceMovesPipeline));
        cmd.pushConstants(push);
        cmd.dispatch((update.move_count + 63) / 64, 1, 1);
    }
    if (update.rewrite_count != 0) {
        push.updates = update.rewrites;
        push.count = update.rewrite_count;
        cmd.bindPipeline(try self.internal.pipelines.of(instanceRewritesPipeline));
        cmd.pushConstants(push);
        cmd.dispatch((update.rewrite_count + 63) / 64, 1, 1);
    }
    cmd.sync(.compute_to_all);
}

/// Closes gaps in the vertex and index pools: when a quarter or more of
/// a pool's span is free, moves its last mesh into the first gap that
/// holds it, one mesh per pool per frame. Returns whether anything moved.
pub fn compactGeometry(self: *Renderer, cmd: *rhi.CommandEncoder) !bool {
    var moved = false;
    inline for (.{ "vertices", "indices" }) |name| {
        const pool: *Pool = &@field(self.internal, name);
        const vertices = comptime std.mem.eql(u8, name, "vertices");
        var free_inside: u64 = 0;
        for (pool.ranges.free_ranges.items) |range| free_inside += range.count;
        if (free_inside * 4 >= pool.ranges.top and @as(u64, pool.ranges.top) * pool.stride >= 1 << 20) find: {
            var last_entry: ?*ModelEntry = null;
            var last_mesh: usize = 0;
            var last_end: u32 = 0;
            for (0..self.models.internal.table.slotCount()) |slot_index| if (self.models.internal.table.slotAt(slot_index).value) |*entry| {
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
                pool.ranges.free(self.internal.gpa, new, count);
                break :find;
            }
            cmd.sync(.all_to_transfer);
            cmd.copyBuffer(pool.get(), pool.get(), @as(u64, old) * pool.stride, @as(u64, new) * pool.stride, @as(u64, count) * pool.stride);
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
                try self.internal.meshes.write(self.device, entry.mesh_base + @as(u32, @intCast(last_mesh)), std.mem.asBytes(&record));
            }
            for (0..self.scenes.internal.table.slotCount()) |slot_index| if (self.scenes.internal.table.slotAt(slot_index).value) |*scene| {
                scene.static_version += 1;
                scene.layout_dirty = true;
            };
            self.internal.stats.geometry_bytes_compacted += @as(u64, count) * pool.stride;
            pool.free(self, old, count);
            moved = true;
        }
    }
    return moved;
}

fn instanceMovesPipeline(_: *rhi.Device) pipelines_module.Desc {
    return .{ .compute = .{ .name = "instance moves", .shader = pipelines_module.shaderCode("instance_moves.comp.spv") } };
}

fn instanceRewritesPipeline(_: *rhi.Device) pipelines_module.Desc {
    return .{ .compute = .{ .name = "instance rewrites", .shader = pipelines_module.shaderCode("instance_rewrites.comp.spv") } };
}
