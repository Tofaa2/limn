//! A scene's per-frame GPU state: poses, instances, lights and acceleration structures. Internal to the renderer.
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
const max_worker_threads = renderer_state.max_worker_threads;
const prepare_batch = renderer_state.prepare_batch;
const move_batch = renderer_state.move_batch;
const PrepareChunk = renderer_state.PrepareChunk;
const LayoutEntry = renderer_state.LayoutEntry;
const EntryInfo = renderer_state.EntryInfo;
const EntityMark = renderer_state.EntityMark;
const EntitySpan = renderer_state.EntitySpan;
const EntityData = renderer_state.EntityData;
const InstanceMove = renderer_state.InstanceMove;
const InstanceRewrite = renderer_state.InstanceRewrite;
const Glowing = renderer_state.Glowing;
const max_glowing = renderer_state.max_glowing;
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
    scene.movers.append(self.internal.gpa, sphere) catch {
        scene.movers_overflow = true;
    };
}

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

fn rebuildLayout(self: *Renderer, scene: *SceneData) !void {
    const zone = Zone.start(self.options.profiler, "rebuild layout");
    defer zone.stop();
    const gpa = self.internal.gpa;
    scene.layout.clearRetainingCapacity();
    scene.posed.clearRetainingCapacity();
    scene.posed_nodes = 0;
    scene.posed_entries = 0;
    scene.entries.clearRetainingCapacity();
    scene.blended.clearRetainingCapacity();
    scene.blended_transmissive = false;
    scene.glowing.clearRetainingCapacity();
    scene.settling.clearRetainingCapacity();
    scene.rigid_tlas = 0;
    scene.skinned_entries = 0;
    scene.records_valid = false;
    self.internal.scratch_refs.clearRetainingCapacity();
    scene.joint_count = 0;
    scene.triangle_count = 0;
    scene.masked_ref_count = 0;
    scene.added.clearRetainingCapacity();
    scene.removed.clearRetainingCapacity();
    scene.quarantine.clearRetainingCapacity();
    scene.entity_cull_items.clearRetainingCapacity();
    for (scene.entities.items) |entity_handle| {
        const entity = self.entities.internal.table.get(entity_handle) orelse continue;
        const mark = &self.internal.entity_marks.items[entity_handle.index];
        const span = &self.internal.entity_spans.items[entity_handle.index];
        mark.layout_first = @intCast(scene.layout.items.len);
        mark.layout_count = 0;
        span.* = .{};
        if (!entity.visible) continue;
        const model = self.models.internal.table.get(entity.model) orelse continue;
        if (model.state != .ready or !model.geometry_resident) continue;
        try resolveEntity(self, entity, model);
        span.* = entityShape(entity, model);
        span.layout_first = @intCast(scene.layout.items.len);
        span.ref_first = @intCast(self.internal.scratch_refs.items.len);
        span.tlas_first = scene.rigid_tlas;
        _ = try scene.layout.addManyAsSlice(gpa, span.layout_count);
        _ = try scene.entries.addManyAsSlice(gpa, span.layout_count);
        const refs = try self.internal.scratch_refs.addManyAsSlice(gpa, span.ref_count);
        try layEntity(self, scene, entity_handle, entity, model, span.*, refs);
        scene.rigid_tlas += span.tlas_count;
        mark.layout_count = span.layout_count;
    }
    const chunk_count = (scene.layout.items.len + prepare_batch - 1) / prepare_batch;
    try scene.spheres.resize(gpa, scene.layout.items.len);
    try scene.chunk_bounds.resize(gpa, chunk_count);
    try scene.chunk_stale.resize(gpa, chunk_count);
    scene.static_count = 0;
    scene.entity_ref_count = @intCast(self.internal.scratch_refs.items.len);
    scene.live_instances = @intCast(scene.layout.items.len);
    scene.live_refs = scene.entity_ref_count;
    const tlas_capacity = scene.entity_tlas_capacity;
    scene.entity_capacity = reserve(scene.entity_capacity, scene.layout.items.len);
    scene.entity_ref_capacity = reserve(scene.entity_ref_capacity, scene.entity_ref_count);
    scene.entity_tlas_capacity = reserve(scene.entity_tlas_capacity, scene.rigid_tlas);
    if (scene.entity_tlas_capacity != tlas_capacity) scene.static_tlas_uploaded = false;
    scene.entity_cull_items.shrinkRetainingCapacity(@min(scene.entity_cull_items.items.len, scene.entity_capacity));
    scene.entity_cull_dirty = .{ 0, scene.entity_capacity };
    try uploadEntityCull(self, scene);
    scene.instance_ranges.free_ranges.clearRetainingCapacity();
    scene.instance_ranges.top = @intCast(scene.layout.items.len);
    scene.instance_ranges.capacity = scene.entity_capacity;
    scene.ref_ranges.free_ranges.clearRetainingCapacity();
    scene.ref_ranges.top = scene.entity_ref_count;
    scene.ref_ranges.capacity = scene.entity_ref_capacity;
    scene.tlas_ranges.free_ranges.clearRetainingCapacity();
    scene.tlas_ranges.top = scene.rigid_tlas;
    scene.tlas_ranges.capacity = scene.entity_tlas_capacity;
    try self.internal.scratch_refs.appendNTimes(gpa, dead_ref, scene.entity_ref_capacity - scene.entity_ref_count);
    scene.static_ranges.clearRetainingCapacity();
    for (scene.groups.items) |group_handle| {
        const group = self.instances.internal.table.get(group_handle) orelse continue;
        group.base = scene.entity_capacity + scene.static_count;
        group.per_copy = 0;
        const model = self.models.internal.table.get(group.model) orelse continue;
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
                try scene.static_ranges.append(gpa, .{ @intCast(self.internal.scratch_refs.items.len), mesh.meshlet_count });
                if (mesh.masked) scene.masked_ref_count += mesh.meshlet_count;
                try self.internal.scratch_refs.ensureUnusedCapacity(gpa, mesh.meshlet_count);
                for (0..mesh.meshlet_count) |meshlet| self.internal.scratch_refs.appendAssumeCapacity(.{
                    .instance = instance_index,
                    .meshlet = mesh.meshlet_offset + @as(u32, @intCast(meshlet)),
                });
            }
        }
        scene.static_count += @as(u32, @intCast(group.transforms.len)) * group.per_copy;
    }
    scene.static_version += 1;
    const count: u32 = @intCast(self.internal.scratch_refs.items.len);
    if (count > scene.refs_capacity) {
        if (scene.refs) |buffer| self.device.destroyBuffer(buffer);
        scene.refs_capacity = @max(count + count / 2, 4096);
        scene.refs = try self.device.createBuffer(.{
            .name = "meshlet refs",
            .size = @as(u64, scene.refs_capacity) * @sizeOf(gpu.MeshletRef),
            .usage = .{ .storage = true },
        });
    }
    if (count != 0) try self.device.uploadBuffer(scene.refs.?, 0, std.mem.sliceAsBytes(self.internal.scratch_refs.items));
    scene.ref_count = count;
    scene.layout_dirty = false;
    scene.layout_version += 1;
    scene.layout_generation = self.internal.asset_generation;
}

/// Room kept for `needed` slots: what is kept already while it is enough and
/// not four times too much, else half as much again.
fn reserve(kept: u32, needed: usize) u32 {
    if (needed <= kept and needed * 4 >= kept) return kept;
    return @intCast(@max(needed + needed / 2, 64));
}

/// What fills entity slots, meshlet references and records no entity holds.
const dead_ref = gpu.MeshletRef{ .instance = gpu.invalid_id, .meshlet = 0 };
const dead_entry = LayoutEntry{ .entity = .invalid, .model_instance = 0, .first_of_entity = false };
const dead_info = EntryInfo{ .center = .{ 0, 0, 0 }, .radius = 0 };
const dead_record = gpu.Instance{
    .transform = @splat(0),
    .bounding_sphere = .{ 0, 0, 0, 0 },
    .mesh = gpu.invalid_id,
    .material = 0,
    .vertex_offset = 0,
    .previous_vertex_offset = 0,
    .flags = 0,
};
/// Frames a cleared span waits before it is reused, so that a pick or frame
/// still in flight cannot name the entity that takes it next.
const quarantine_frames = rhi.frames_in_flight + 2;

/// How many entity slots, meshlet references and ray-tracing instances a
/// visible entity takes, and what it adds to its scene's totals. Its skins
/// must be resolved.
fn entityShape(entity: *const EntityData, model: *const ModelEntry) EntitySpan {
    const source = &model.source.?;
    var span = EntitySpan{};
    for (source.instances, 0..) |instance, index| {
        const mesh = model.meshes[instance.mesh];
        const skinned = entity.skin_offsets[index] != no_skin;
        span.layout_count += 1;
        span.triangles += mesh.lod0_index_count / 3;
        if (skinned) {
            span.skinned += 1;
            span.joints += @intCast(source.skins[instance.skin.?].joints.len);
        } else if (mesh.blas != null) span.tlas_count += 1;
        if (skinned or (entity.node_world.len != 0 and model.node_moves[instance.node])) span.posed += 1;
        if (entity.rays_only) continue;
        span.ref_count += mesh.meshlet_count;
        if (mesh.masked) span.masked_refs += mesh.meshlet_count;
    }
    return span;
}

/// Writes a visible entity's layout entries and meshlet references at
/// `span`'s offsets, adds it to the scene's lists and totals, and leaves its
/// records to the caller. A texture given through `Materials.setTextures`
/// keeps a mesh from counting as glowing: only part of such a surface glows,
/// which sampling it as a whole would overstate.
fn layEntity(self: *Renderer, scene: *SceneData, handle: Entity, entity: *const EntityData, model: *const ModelEntry, span: EntitySpan, refs: []gpu.MeshletRef) !void {
    const gpa = self.internal.gpa;
    const source = &model.source.?;
    if (entity.node_world.len != 0 and source.instances.len != 0) {
        try scene.posed.append(gpa, handle);
        scene.posed_nodes = @max(scene.posed_nodes, entity.node_world.len);
    }
    var tlas_slot = span.tlas_first;
    var ref_at: usize = 0;
    for (source.instances, 0..) |instance, index| {
        const mesh = model.meshes[instance.mesh];
        const instance_index: u32 = span.layout_first + @as(u32, @intCast(index));
        scene.layout.items[instance_index] = .{ .entity = handle, .model_instance = @intCast(index), .first_of_entity = index == 0 };
        const bounds_of = source.meshes[instance.mesh];
        const material = source.materials[bounds_of.material];
        const skinned = entity.skin_offsets[index] != no_skin;
        var info = EntryInfo{ .center = bounds_of.bounds_center, .radius = bounds_of.bounds_radius };
        if (skinned) {
            info.bits |= EntryInfo.skinned;
        } else if (mesh.blas != null) {
            info.tlas_slot = tlas_slot;
            tlas_slot += 1;
        }
        if (skinned or (entity.node_world.len != 0 and model.node_moves[instance.node])) {
            info.bits |= EntryInfo.posed;
        } else info.rest = &model.node_world[instance.node];
        if (mesh.blend and !entity.rays_only) {
            if (material.transmission > 0) scene.blended_transmissive = true;
            try scene.blended.append(gpa, .{
                .instance = instance_index,
                .first_index = mesh.index_offset,
                .index_count = mesh.lod0_index_count,
                .center = .{ 0, 0, 0 },
                .transmissive = material.transmission > 0,
            });
        }
        const emissive_image = bounds_of.material < model.material_images.len and model.material_images[bounds_of.material].emissive != null;
        const glows = material.emissive_texture == null and !emissive_image and (material.emissive[0] > 0 or material.emissive[1] > 0 or material.emissive[2] > 0) and mesh.lod0_index_count >= 3 and !mesh.coarse;
        if (glows and scene.glowing.items.len < max_glowing) {
            try scene.glowing.append(gpa, .{ .instance = instance_index, .triangles = mesh.lod0_index_count / 3 });
            if (!skinned) info.bits |= EntryInfo.glows;
        }
        scene.entries.items[instance_index] = info;
        try setEntityCull(self, scene, instance_index, if (entity.rays_only) .{ 0, 0 } else .{ span.ref_first + @as(u32, @intCast(ref_at)), mesh.meshlet_count });
        if (entity.rays_only) continue;
        for (refs[ref_at..][0..mesh.meshlet_count], 0..) |*ref, meshlet| ref.* = .{
            .instance = instance_index,
            .meshlet = mesh.meshlet_offset + @as(u32, @intCast(meshlet)),
        };
        ref_at += mesh.meshlet_count;
    }
    scene.skinned_entries += span.skinned;
    scene.posed_entries += span.posed;
    scene.triangle_count += span.triangles;
    scene.joint_count += span.joints;
    scene.masked_ref_count += span.masked_refs;
}

/// Queues what an entity took of its scene to be cleared at the next
/// prepared frame. Lays out the whole scene again when it cannot queue.
pub fn forgetEntity(self: *Renderer, scene: *SceneData, span: EntitySpan) void {
    if (span.layout_count == 0 and span.ref_count == 0 and span.tlas_count == 0) return;
    scene.removed.append(self.internal.gpa, span) catch {
        scene.layout_dirty = true;
    };
}

/// Grows the layout's per-entry lists to `count` entries, the new ones dead.
fn growLayout(self: *Renderer, scene: *SceneData, count: usize) !void {
    const gpa = self.internal.gpa;
    if (scene.layout.items.len >= count) return;
    const old = scene.layout.items.len;
    @memset(try scene.layout.addManyAsSlice(gpa, count - old), dead_entry);
    @memset(try scene.entries.addManyAsSlice(gpa, count - old), dead_info);
    try scene.spheres.resize(gpa, count);
    @memset(scene.spheres.items[old..], .{ 0, 0, 0, 0 });
    const chunk_count = (count + prepare_batch - 1) / prepare_batch;
    const old_chunks = scene.chunk_stale.items.len;
    try scene.chunk_bounds.resize(gpa, chunk_count);
    try scene.chunk_stale.resize(gpa, chunk_count);
    @memset(scene.chunk_stale.items[old_chunks..], true);
}

/// Sets the meshlet references culling takes for entity slot `slot`, to be
/// uploaded with the next `uploadEntityCull`.
fn setEntityCull(self: *Renderer, scene: *SceneData, slot: u32, refs: [2]u32) !void {
    const items = &scene.entity_cull_items;
    if (items.items.len <= slot) try items.appendNTimes(self.internal.gpa, .{ 0, 0 }, slot + 1 - items.items.len);
    items.items[slot] = refs;
    scene.entity_cull_dirty = .{ @min(scene.entity_cull_dirty[0], slot), @max(scene.entity_cull_dirty[1], slot + 1) };
}

/// Uploads the entity slots changed since the last call, or all of them
/// into a new buffer when the slots kept for entities outgrew it.
fn uploadEntityCull(self: *Renderer, scene: *SceneData) !void {
    const device = self.device;
    if (scene.entity_cull_items.items.len < scene.entity_capacity) try scene.entity_cull_items.appendNTimes(self.internal.gpa, .{ 0, 0 }, scene.entity_capacity - scene.entity_cull_items.items.len);
    const items = scene.entity_cull_items.items;
    if (scene.entity_capacity > scene.entity_cull_capacity) {
        if (scene.entity_cull) |old| device.destroyBuffer(old);
        scene.entity_cull = null;
        scene.entity_cull = try device.createBuffer(.{ .name = "entity cull", .size = @as(u64, scene.entity_capacity) * @sizeOf([2]u32), .usage = .{ .storage = true } });
        scene.entity_cull_capacity = scene.entity_capacity;
        scene.entity_cull_dirty = .{ 0, @intCast(items.len) };
    }
    const first, const end = scene.entity_cull_dirty;
    scene.entity_cull_dirty = .{ std.math.maxInt(u32), 0 };
    if (first >= end or scene.entity_cull == null) return;
    try device.uploadBuffer(scene.entity_cull.?, @as(u64, first) * @sizeOf([2]u32), std.mem.sliceAsBytes(items[first..@min(end, items.len)]));
}

fn staleChunks(scene: *SceneData, first: u32, count: u32) void {
    if (count == 0) return;
    for (first / prepare_batch..(first + count - 1) / prepare_batch + 1) |chunk| scene.chunk_stale.items[chunk] = true;
}

/// Clears the spans of removed entities and lays out added ones in free
/// slots, uploading only what they touch. False when the slots kept for
/// entities run out, and the whole layout must be built again.
fn applyStructure(self: *Renderer, scene: *SceneData) !bool {
    const gpa = self.internal.gpa;
    const device = self.device;
    const frame = self.internal.frame_index;
    const zone = Zone.start(self.options.profiler, "structure");
    defer zone.stop();
    var kept: usize = 0;
    for (scene.quarantine.items) |span| {
        if (frame < span.freed_frame + quarantine_frames) {
            scene.quarantine.items[kept] = span;
            kept += 1;
            continue;
        }
        scene.instance_ranges.free(gpa, span.layout_first, span.layout_count);
        scene.ref_ranges.free(gpa, span.ref_first, span.ref_count);
        scene.tlas_ranges.free(gpa, span.tlas_first, span.tlas_count);
    }
    scene.quarantine.shrinkRetainingCapacity(kept);
    const tlas_live = device.caps.ray_tracing and scene.tlas_instances != null and scene.records_valid;

    if (scene.removed.items.len != 0) {
        try scene.quarantine.ensureUnusedCapacity(gpa, scene.removed.items.len);
        for (scene.removed.items) |removed| {
            var span = removed;
            const last = span.layout_first + span.layout_count;
            if (last > scene.layout.items.len) return false;
            for (scene.layout.items[span.layout_first..last], scene.entries.items[span.layout_first..last], scene.spheres.items[span.layout_first..last]) |*entry, *info, *sphere| {
                if (sphere[3] > 0) noteMover(self, scene, sphere.*);
                entry.* = dead_entry;
                info.* = dead_info;
                sphere.* = .{ 0, 0, 0, 0 };
            }
            staleChunks(scene, span.layout_first, span.layout_count);
            for (span.layout_first..last) |slot| try setEntityCull(self, scene, @intCast(slot), .{ 0, 0 });
            if (span.ref_count != 0) {
                self.internal.scratch_refs.clearRetainingCapacity();
                try self.internal.scratch_refs.appendNTimes(gpa, dead_ref, span.ref_count);
                try device.uploadBuffer(scene.refs.?, @as(u64, span.ref_first) * @sizeOf(gpu.MeshletRef), std.mem.sliceAsBytes(self.internal.scratch_refs.items));
            }
            if (span.tlas_count != 0 and tlas_live and span.tlas_first + span.tlas_count <= scene.tlas_instances_capacity) {
                const zeros: [16]rhi.AccelerationInstance = @splat(std.mem.zeroes(rhi.AccelerationInstance));
                var done: u32 = 0;
                while (done < span.tlas_count) {
                    const count = @min(span.tlas_count - done, zeros.len);
                    try device.uploadBuffer(scene.tlas_instances.?, @as(u64, span.tlas_first + done) * @sizeOf(rhi.AccelerationInstance), std.mem.sliceAsBytes(zeros[0..count]));
                    done += count;
                }
            }
            scene.skinned_entries -|= span.skinned;
            scene.posed_entries -|= span.posed;
            scene.triangle_count -|= span.triangles;
            scene.joint_count -|= span.joints;
            scene.masked_ref_count -|= span.masked_refs;
            scene.live_instances -|= span.layout_count;
            scene.live_refs -|= span.ref_count;
            span.freed_frame = frame;
            scene.quarantine.appendAssumeCapacity(span);
        }
        const layout = scene.layout.items;
        var blended: usize = 0;
        scene.blended_transmissive = false;
        for (scene.blended.items) |draw| if (layout[draw.instance].entity.isValid()) {
            scene.blended.items[blended] = draw;
            blended += 1;
            if (draw.transmissive) scene.blended_transmissive = true;
        };
        scene.blended.shrinkRetainingCapacity(blended);
        var glowing: usize = 0;
        for (scene.glowing.items) |glow| if (layout[glow.instance].entity.isValid()) {
            scene.glowing.items[glowing] = glow;
            glowing += 1;
        };
        scene.glowing.shrinkRetainingCapacity(glowing);
        var settling: usize = 0;
        for (scene.settling.items) |pair| if (layout[pair[0]].entity.isValid()) {
            scene.settling.items[settling] = pair;
            settling += 1;
        };
        scene.settling.shrinkRetainingCapacity(settling);
        var posed: usize = 0;
        for (scene.posed.items) |handle| if (self.entities.internal.table.get(handle) != null and self.internal.entity_marks.items[handle.index].layout_count != 0) {
            scene.posed.items[posed] = handle;
            posed += 1;
        };
        scene.posed.shrinkRetainingCapacity(posed);
        scene.removed.clearRetainingCapacity();
        scene.tlas_content += 1;
    }

    for (scene.added.items) |handle| {
        const entity = self.entities.internal.table.get(handle) orelse continue;
        const mark = &self.internal.entity_marks.items[handle.index];
        const owned = &self.internal.entity_spans.items[handle.index];
        if (!entity.visible or owned.layout_count != 0 or self.scenes.internal.table.get(mark.scene) != scene) continue;
        const model = self.models.internal.table.get(entity.model) orelse continue;
        if (model.state != .ready or !model.geometry_resident) continue;
        try resolveEntity(self, entity, model);
        var span = entityShape(entity, model);
        span.layout_first = scene.instance_ranges.alloc(span.layout_count) orelse return false;
        span.ref_first = scene.ref_ranges.alloc(span.ref_count) orelse return false;
        span.tlas_first = scene.tlas_ranges.alloc(span.tlas_count) orelse return false;
        try growLayout(self, scene, span.layout_first + span.layout_count);
        self.internal.scratch_refs.clearRetainingCapacity();
        const refs = try self.internal.scratch_refs.addManyAsSlice(gpa, span.ref_count);
        try layEntity(self, scene, handle, entity, model, span, refs);
        if (span.ref_count != 0) try device.uploadBuffer(scene.refs.?, @as(u64, span.ref_first) * @sizeOf(gpu.MeshletRef), std.mem.sliceAsBytes(refs));
        const source = &model.source.?;
        const now = self.internal.entity_transforms.items[handle.index];
        const node_world = if (entity.node_world.len != 0) entity.node_world else model.node_world;
        for (source.instances, scene.entries.items[span.layout_first..][0..span.layout_count], span.layout_first..) |instance, info, index| {
            if (info.bits & EntryInfo.skinned != 0) continue;
            const transform = math.mul(now, node_world[instance.node]);
            const sphere = worldSphere(info, transform);
            scene.spheres.items[index] = sphere;
            noteMover(self, scene, sphere);
            if (info.tlas_slot == gpu.invalid_id or !tlas_live or info.tlas_slot >= scene.tlas_instances_capacity) continue;
            const mesh = model.meshes[instance.mesh];
            const placed = [1]rhi.AccelerationInstance{tlasInstance(device, mesh.blas.?, index, mesh.blend, transform)};
            try device.uploadBuffer(scene.tlas_instances.?, @as(u64, info.tlas_slot) * @sizeOf(rhi.AccelerationInstance), std.mem.sliceAsBytes(&placed));
        }
        staleChunks(scene, span.layout_first, span.layout_count);
        owned.* = span;
        scene.live_instances += span.layout_count;
        scene.live_refs += span.ref_count;
        mark.layout_first = span.layout_first;
        mark.layout_count = span.layout_count;
        self.noteEdited(handle.index, mark, EntityMark.restyled);
        scene.tlas_content += 1;
    }
    scene.added.clearRetainingCapacity();
    scene.entity_ref_count = scene.ref_ranges.top;
    scene.rigid_tlas = scene.tlas_ranges.top;
    try uploadEntityCull(self, scene);
    return true;
}

fn rigidRecord(self: *Renderer, entity: *const EntityData, model: *const ModelEntry, mesh_index: u32, transform: Mat4, still: bool, aimed: bool) gpu.Instance {
    const mesh = model.meshes[mesh_index];
    return .{
        .transform = gpu.affine(transform),
        .bounding_sphere = .{ 0, 0, 0, 0 },
        .mesh = model.mesh_base + mesh_index,
        .material = mesh.material,
        .vertex_offset = mesh.vertex_offset,
        .previous_vertex_offset = mesh.vertex_offset,
        .coarse_error = if (mesh.coarse) mesh.coarse_error else 0,
        .flags = (if (still) 0 else gpu.instance_moving | gpu.instance_previous) | (if (entity.receive_decals) 0 else gpu.instance_no_decals) |
            (if (entity.rays_only) gpu.instance_proxy else 0) | (if (aimed) gpu.instance_aimed else 0),
        .tint = entity.tint,
        .lightmap = if (entity.lightmap) |lightmap| (if (lightmap.rounds != 0) self.device.textureIndex(lightmap.shown) else gpu.invalid_id) else gpu.invalid_id,
        .params = entity.params,
    };
}

fn tlasInstance(device: *rhi.Device, blas: rhi.AccelerationStructure, instance_index: usize, blend: bool, t: Mat4) rhi.AccelerationInstance {
    return .{
        .transform = .{ t[0], t[4], t[8], t[12], t[1], t[5], t[9], t[13], t[2], t[6], t[10], t[14] },
        .custom_index_and_mask = (@as(u32, @intCast(instance_index)) & 0x00ff_ffff) | (if (blend) @as(u32, 0x0200_0000) else 0xff00_0000),
        .offset_and_flags = 0x0100_0000,
        .blas = device.accelerationAddress(blas),
    };
}

fn worldSphere(info: EntryInfo, transform: Mat4) [4]f32 {
    const center = math.transformPoint(transform, info.center);
    return .{ center[0], center[1], center[2], info.radius * math.maxScale(transform) };
}

/// Every record of a scene's unskinned entities, written a batch of layout
/// entries at a time on any thread. A batch writes only its own entries'
/// records, spheres and ray-tracing instances, and its own chunk.
const PrepareWhole = struct {
    renderer: *Renderer,
    scene: *SceneData,
    records: []gpu.Instance,
    previous: [][12]f32,
    tlas: []rhi.AccelerationInstance,
    chunks: []PrepareChunk,

    const Batch = fn (PrepareWhole, usize) void;

    /// Runs `work` for every batch, across threads when there are enough.
    fn spread(prepare: PrepareWhole, comptime work: Batch) void {
        const self = prepare.renderer;
        const count = prepare.chunks.len;
        const threads = std.math.clamp(count / 2, 1, workerThreads(self));
        const Run = struct {
            fn run(shared: PrepareWhole, first: usize, last: usize) void {
                for (first..last) |chunk| work(shared, chunk);
            }
        };
        if (threads == 1) return Run.run(prepare, 0, count);
        var group: std.Io.Group = .init;
        const share = (count + threads - 1) / threads;
        for (1..threads) |index| {
            const first = @min(index * share, count);
            const last = @min((index + 1) * share, count);
            group.concurrent(self.internal.io, Run.run, .{ prepare, first, last }) catch Run.run(prepare, first, last);
        }
        Run.run(prepare, 0, @min(share, count));
        group.await(self.internal.io) catch {};
    }

    /// Ends the frame for each entity: what it is now is what it was.
    fn finish(prepare: PrepareWhole, chunk_index: usize) void {
        const self = prepare.renderer;
        const layout = prepare.scene.layout.items;
        const start = chunk_index * prepare_batch;
        for (layout[start..@min(start + prepare_batch, layout.len)]) |entry| {
            if (!entry.first_of_entity) continue;
            const slot = entry.entity.index;
            const now = self.internal.entity_transforms.items[slot];
            const before = &self.internal.entity_previous.items[slot];
            self.internal.entity_marks.items[slot].travelled = math.length(math.sub(now[12..15].*, before[12..15].*));
            before.* = now;
        }
    }

    fn batch(prepare: PrepareWhole, chunk_index: usize) void {
        const self = prepare.renderer;
        const scene = prepare.scene;
        const start = chunk_index * prepare_batch;
        const end = @min(start + prepare_batch, scene.layout.items.len);
        var chunk = PrepareChunk{};
        for (scene.layout.items[start..end], scene.entries.items[start..end], start..) |entry, *info, instance_index| {
            info.bits &= ~EntryInfo.moved;
            if (!entry.entity.isValid()) {
                prepare.records[instance_index] = dead_record;
                prepare.previous[instance_index] = @splat(0);
                continue;
            }
            if (info.bits & EntryInfo.skinned != 0) continue;
            const entity = self.entities.internal.table.get(entry.entity).?;
            const model = self.models.internal.table.get(entity.model).?;
            const instance = model.source.?.instances[entry.model_instance];
            const node_world = if (entity.node_world.len != 0) entity.node_world else model.node_world;
            const previous_node_world = if (entity.node_world.len != 0) entity.previous_node_world else model.node_world;
            const transform = math.mul(self.internal.entity_transforms.items[entry.entity.index], node_world[instance.node]);
            const previous_transform = math.mul(self.internal.entity_previous.items[entry.entity.index], previous_node_world[instance.node]);
            const still = std.mem.eql(f32, &transform, &previous_transform);
            if (!still) {
                info.bits |= EntryInfo.moved;
                chunk.any_moving = true;
            }
            prepare.previous[instance_index] = gpu.affine(previous_transform);
            prepare.records[instance_index] = rigidRecord(self, entity, model, instance.mesh, transform, still, info.bits & EntryInfo.glows != 0);
            scene.spheres.items[instance_index] = worldSphere(info.*, transform);
            if (info.tlas_slot == gpu.invalid_id) continue;
            const mesh = model.meshes[instance.mesh];
            prepare.tlas[info.tlas_slot] = tlasInstance(self.device, mesh.blas.?, instance_index, mesh.blend, transform);
        }
        prepare.chunks[chunk_index] = chunk;
    }
};

/// This frame's changes to the records of a scene whose other records are
/// still right: lists for instance_update.slang to apply.
const Changes = struct {
    renderer: *Renderer,
    scene: *SceneData,
    moves: []InstanceMove,
    move_count: u32 = 0,
    rewrites: []InstanceRewrite,
    rewrite_count: u32 = 0,
    any_moving: bool = false,
    tlas_changed: bool = false,

    /// Gives an unskinned entry a new transform. `flags` are `InstanceMove`'s.
    fn move(changes: *Changes, index: u32, info: *EntryInfo, transform: Mat4, flags: u32) void {
        changes.moves[changes.move_count] = .{ .instance = index, .tlas_slot = info.tlas_slot, .flags = flags, .transform = gpu.affine(transform) };
        changes.move_count += 1;
        changes.place(index, info, transform, flags & InstanceMove.moved != 0, flags != InstanceMove.keep);
    }

    /// Writes an unskinned entry's whole record.
    fn rewrite(changes: *Changes, index: u32, info: *EntryInfo, record: gpu.Instance, previous: Mat4, transform: Mat4, changed: bool) void {
        changes.rewrites[changes.rewrite_count] = .{ .instance = index, .tlas_slot = info.tlas_slot, .previous = gpu.affine(previous), .record = record };
        changes.rewrite_count += 1;
        changes.place(index, info, transform, record.flags & gpu.instance_moving != 0, changed);
    }

    fn place(changes: *Changes, index: u32, info: *EntryInfo, transform: Mat4, moved: bool, changed: bool) void {
        const scene = changes.scene;
        info.bits = if (moved) info.bits | EntryInfo.moved else info.bits & ~EntryInfo.moved;
        if (!changed) return;
        const sphere = worldSphere(info.*, transform);
        scene.spheres.items[index] = sphere;
        noteMover(changes.renderer, scene, sphere);
        if (moved) changes.any_moving = true;
        if (info.tlas_slot == gpu.invalid_id) return;
        scene.chunk_stale.items[index / prepare_batch] = true;
        changes.tlas_changed = true;
    }
};

/// A share of a scene's edited entities, handled on one thread: those whose
/// instances only move. The others are left at the start of the share for
/// the rendering thread.
const MoveShare = struct {
    changes: *const Changes,
    /// Next free block of `changes.moves`, and where the blocks end.
    cursor: *std.atomic.Value(u32),
    limit: u32,
    /// For each move from `base` on, the entry and entity slot if it must
    /// settle next frame, else `gpu.invalid_id`.
    settling: [][2]u32,
    base: u32,
    first: usize,
    last: usize,
    left_over: usize = 0,
    moved: u32 = 0,
    tlas_changed: bool = false,

    /// Moves a thread takes at a time.
    const block = 256;
    /// Most instances of an entity handled here.
    const most_entries = 16;

    fn run(share: *MoveShare) void {
        const self = share.changes.renderer;
        const scene = share.changes.scene;
        const moves = share.changes.moves;
        const edited = scene.edited.items;
        const entries = scene.entries.items;
        var at: u32 = 0;
        var room: u32 = 0;
        var left_over: usize = 0;
        var moved: u32 = 0;
        var tlas_changed = false;
        defer {
            share.pad(at, room);
            share.left_over = left_over;
            share.moved = moved;
            share.tlas_changed = tlas_changed;
        }
        for (edited[share.first..share.last]) |slot| {
            const mark = &self.internal.entity_marks.items[slot];
            const bits = @atomicLoad(u32, &mark.bits, .monotonic);
            if (mark.handle == 0 or bits & EntityMark.listed == 0 or self.scenes.internal.table.get(mark.scene) != scene) continue;
            const count = mark.layout_count;
            var simple = bits & (EntityMark.teleported | EntityMark.restyled) == 0 and count <= most_entries and (count == 0 or entries[mark.layout_first].rest != null);
            if (simple and room < count) {
                share.pad(at, room);
                at = share.cursor.fetchAdd(block, .monotonic);
                room = if (at + block <= share.limit) block else 0;
                simple = room != 0;
            }
            if (!simple) {
                edited[share.first + left_over] = slot;
                left_over += 1;
                continue;
            }
            if (@atomicRmw(u32, &mark.bits, .And, ~EntityMark.listed, .monotonic) & EntityMark.listed == 0) continue;
            const now = self.internal.entity_transforms.items[slot];
            const before = &self.internal.entity_previous.items[slot];
            const changed = !std.mem.eql(f32, &now, before);
            for (entries[mark.layout_first..][0..count], mark.layout_first..) |*info, index| {
                const transform = math.mul(now, info.rest.?.*);
                moves[at] = .{
                    .instance = @intCast(index),
                    .tlas_slot = info.tlas_slot,
                    .flags = if (changed) InstanceMove.moved | InstanceMove.keep else InstanceMove.keep,
                    .transform = gpu.affine(transform),
                };
                share.settling[at - share.base] = if (changed) .{ @intCast(index), slot } else @splat(gpu.invalid_id);
                at += 1;
                room -= 1;
                if (!changed) {
                    info.bits &= ~EntryInfo.moved;
                    continue;
                }
                info.bits |= EntryInfo.moved;
                scene.spheres.items[index] = worldSphere(info.*, transform);
                moved += 1;
                if (info.tlas_slot == gpu.invalid_id) continue;
                const stale = &scene.chunk_stale.items[index / prepare_batch];
                if (!@atomicLoad(bool, stale, .monotonic)) @atomicStore(bool, stale, true, .monotonic);
                tlas_changed = true;
            }
            mark.travelled = math.length(math.sub(now[12..15].*, before[12..15].*));
            before.* = now;
            @atomicStore(u32, &mark.bits, 0, .monotonic);
        }
    }

    /// Fills the rest of a block with moves that do nothing.
    fn pad(share: *MoveShare, at: u32, room: u32) void {
        if (room == 0) return;
        for (share.changes.moves[at..][0..room], share.settling[at - share.base ..][0..room]) |*move, *pair| {
            move.* = .{ .instance = gpu.invalid_id, .flags = 0, .transform = @splat(0) };
            pair.* = @splat(gpu.invalid_id);
        }
    }
};

/// Threads `moveAcrossThreads` splits the scene's edits over; 1 means none.
fn moveThreads(self: *Renderer, scene: *const SceneData) usize {
    return std.math.clamp(scene.edited.items.len / move_batch, 1, workerThreads(self));
}

/// Hands the edited entities that only move to threads, when there are
/// enough of them. What it leaves in `scene.edited` is still to be done.
fn moveAcrossThreads(self: *Renderer, scene: *SceneData, changes: *Changes, room: u32) !void {
    const edited = scene.edited.items;
    const threads = moveThreads(self, scene);
    if (threads == 1) return;
    const base = changes.move_count;
    try self.internal.scratch_moved.resize(self.internal.gpa, room);
    var cursor: std.atomic.Value(u32) = .init(base);
    var shares: [max_worker_threads]MoveShare = undefined;
    const share_size = (edited.len + threads - 1) / threads;
    for (shares[0..threads], 0..) |*share, index| share.* = .{
        .changes = changes,
        .cursor = &cursor,
        .limit = base + room,
        .settling = self.internal.scratch_moved.items,
        .base = base,
        .first = @min(index * share_size, edited.len),
        .last = @min((index + 1) * share_size, edited.len),
    };
    var group: std.Io.Group = .init;
    for (shares[1..threads]) |*share| group.concurrent(self.internal.io, MoveShare.run, .{share}) catch share.run();
    shares[0].run();
    group.await(self.internal.io) catch {};

    const end = @min(cursor.load(.monotonic), base + room - (room % MoveShare.block));
    changes.move_count = end;
    var kept: usize = 0;
    var moved: usize = 0;
    for (shares[0..threads]) |share| {
        std.mem.copyForwards(u32, edited[kept..], edited[share.first..][0..share.left_over]);
        kept += share.left_over;
        moved += share.moved;
        changes.tlas_changed = changes.tlas_changed or share.tlas_changed;
    }
    scene.edited.shrinkRetainingCapacity(kept);
    if (moved == 0) return;
    changes.any_moving = true;
    const listed = scene.movers.items.len + moved <= max_movers;
    if (!listed) scene.movers_overflow = true;
    try scene.settling.ensureUnusedCapacity(self.internal.gpa, moved);
    for (self.internal.scratch_moved.items[0 .. end - base]) |pair| {
        if (pair[0] == gpu.invalid_id) continue;
        scene.settling.appendAssumeCapacity(pair);
        if (listed) noteMover(self, scene, scene.spheres.items[pair[0]]);
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

/// Converts the scene's lights to GPU records and assigns shadow atlas
/// tiles to the ones that cast shadows. The scene's first view in a frame
/// ranks the lights; later views keep its choice, as they share the atlas.
pub fn prepareLights(self: *Renderer, scene: *SceneData, arena: *FrameArena, shadows: bool, camera_position: Vec3, traced_shadows: bool) !Lighting {
    const device = self.device;
    if (scene.lighting) |made| if (scene.lighting_frame == self.internal.frame_index and scene.lighting_shadows == shadows and scene.lighting_traced == traced_shadows) return made;
    var fluid_lights: usize = 0;
    for (scene.fluids.items) |item| {
        if (self.fluids.internal.table.get(item)) |state| fluid_lights += @intFromBool(state.desc.light > 0);
    }
    try scene.light_next.resize(self.internal.gpa, scene.lights.items.len + fluid_lights);
    const records = scene.light_next.items;
    const tiles = try arena.alloc(device, gpu.ShadowTile, max_local_shadow_views);
    var result = Lighting{
        .lights = 0,
        .tiles = tiles.address,
        .light_count = @intCast(records.len),
        .tile_count = 0,
        .tile_view_proj = undefined,
        .tile_views = undefined,
    };
    const tiles_per_side = std.math.clamp(self.options.shadows.local_tiles_per_side, 1, local_shadow_tiles_per_side);
    const tile_scale = 1.0 / @as(f32, @floatFromInt(tiles_per_side));
    const axes = [6]Vec3{ .{ 1, 0, 0 }, .{ -1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, -1, 0 }, .{ 0, 0, 1 }, .{ 0, 0, -1 } };
    try self.internal.scratch_granted.resize(self.internal.gpa, scene.lights.items.len);
    const granted = self.internal.scratch_granted.items;
    @memset(granted, false);
    const shared = shadows and scene.shadow_grants_frame == self.internal.frame_index and
        scene.shadow_grants_traced == traced_shadows and scene.shadow_grants.items.len == granted.len;
    if (shared) {
        @memcpy(granted, scene.shadow_grants.items);
    } else if (shadows) {
        const Candidate = render.LightRank;
        try self.internal.scratch_light_ranks.resize(self.internal.gpa, scene.lights.items.len);
        const candidates = self.internal.scratch_light_ranks.items;
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
        try scene.shadow_grants.resize(self.internal.gpa, granted.len);
        @memcpy(scene.shadow_grants.items, granted);
        scene.shadow_grants_frame = self.internal.frame_index;
        scene.shadow_grants_traced = traced_shadows;
    }
    result.tiles_key = std.hash.Wyhash.hash(tiles_per_side, std.mem.sliceAsBytes(granted));
    for (scene.lights.items, records[0..scene.lights.items.len], granted) |light, *out, has_tiles| {
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
            .cookie = self.images.indexOf(light.cookie),
            .profile = self.images.indexOf(light.profile),
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
        const state = self.fluids.internal.table.get(item) orelse continue;
        if (state.desc.light <= 0) continue;
        const t = state.desc.transform;
        const height = math.length(.{ t[4], t[5], t[6] });
        records[fluid_slot] = .{
            .position = .{ t[12], t[13], t[14] },
            .range = if (state.desc.light_range > 0) state.desc.light_range else height * 3,
            .color = .{ 0, 0, 0 },
            .flags = gpu.light_fire | (if (shadows) gpu.light_traced_shadow else 0),
            .source_radius = height * @max(state.desc.light_size, 0),
        };
        fluid_slot += 1;
    }
    result.lights = try uploadLights(self, scene);
    result.records = scene.light_uploaded.items;
    scene.lighting = result;
    scene.lighting_frame = self.internal.frame_index;
    scene.lighting_shadows = shadows;
    scene.lighting_traced = traced_shadows;
    return result;
}

/// Uploads the span of `light_next` that differs from what the scene's
/// light buffer holds, and returns the buffer's address; `light_uploaded`
/// then holds this frame's records.
fn uploadLights(self: *Renderer, scene: *SceneData) !u64 {
    return uploadChanged(gpu.Light, self.device, "lights", &scene.light_buffer, &scene.light_capacity, &scene.light_uploaded, &scene.light_next);
}

/// Uploads the span of `next` that differs from `uploaded`, the copy of what
/// `buffer` holds, growing the buffer when `next` outgrew it, then swaps the
/// two lists and returns the buffer's address.
pub fn uploadChanged(comptime T: type, device: *rhi.Device, name: [:0]const u8, buffer: *?rhi.Buffer, capacity: *u32, uploaded: *std.ArrayList(T), next: *std.ArrayList(T)) !u64 {
    const records = next.items;
    if (buffer.* == null or records.len > capacity.*) {
        if (buffer.*) |old| device.destroyBuffer(old);
        buffer.* = null;
        const room: u32 = @intCast(@max(records.len + records.len / 2, 16));
        buffer.* = try device.createBuffer(.{ .name = name, .size = @as(u64, room) * @sizeOf(T), .usage = .{ .storage = true } });
        capacity.* = room;
        uploaded.clearRetainingCapacity();
    }
    const old = uploaded.items;
    var first: usize = records.len;
    var end: usize = 0;
    for (records, 0..) |record, index| {
        if (index < old.len and std.meta.eql(record, old[index])) continue;
        first = @min(first, index);
        end = index + 1;
    }
    if (first < end) try device.uploadBuffer(buffer.*.?, @as(u64, first) * @sizeOf(T), std.mem.sliceAsBytes(records[first..end]));
    std.mem.swap(std.ArrayList(T), uploaded, next);
    return device.bufferAddress(buffer.*.?);
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
