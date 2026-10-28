//! How a scene's entities lay out in its instance, reference and ray-tracing slots, and the changes made to them in place. Internal to the renderer.
const std = @import("std");
const rhi = @import("../../rhi/rhi.zig");
const math = @import("../../math.zig");
const gpu = @import("../gpu.zig");
const api = @import("../api.zig");
const renderer_state = @import("../state.zig");
const render = @import("../renderer.zig");

const Renderer = render.Renderer;
const noteEdited = @import("entity_edits.zig").noteEdited;
const Mat4 = math.Mat4;
const Entity = api.Entity;
const Zone = renderer_state.Zone;
const max_movers = renderer_state.max_movers;
const ModelEntry = renderer_state.ModelEntry;
const SceneData = renderer_state.SceneData;
const no_skin = renderer_state.no_skin;
const prepare_batch = renderer_state.prepare_batch;
const LayoutEntry = renderer_state.LayoutEntry;
const EntryInfo = renderer_state.EntryInfo;
const EntityMark = renderer_state.EntityMark;
const EntitySpan = renderer_state.EntitySpan;
const EntityData = renderer_state.EntityData;
const max_glowing = renderer_state.max_glowing;
const resolveEntity = @import("scenes.zig").resolveEntity;

pub fn noteMover(self: *Renderer, scene: *SceneData, sphere: [4]f32) void {
    if (scene.movers.items.len >= max_movers) {
        scene.movers_overflow = true;
        return;
    }
    scene.movers.append(self.internal.gpa, sphere) catch {
        scene.movers_overflow = true;
    };
}

pub fn rebuildLayout(self: *Renderer, scene: *SceneData) !void {
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
pub const dead_record = gpu.Instance{
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
pub fn applyStructure(self: *Renderer, scene: *SceneData) !bool {
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
        noteEdited(self, handle.index, mark, EntityMark.restyled);
        scene.tlas_content += 1;
    }
    scene.added.clearRetainingCapacity();
    scene.entity_ref_count = scene.ref_ranges.top;
    scene.rigid_tlas = scene.tlas_ranges.top;
    try uploadEntityCull(self, scene);
    return true;
}

pub fn rigidRecord(self: *Renderer, entity: *const EntityData, model: *const ModelEntry, mesh_index: u32, transform: Mat4, still: bool, aimed: bool) gpu.Instance {
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

pub fn tlasInstance(device: *rhi.Device, blas: rhi.AccelerationStructure, instance_index: usize, blend: bool, t: Mat4) rhi.AccelerationInstance {
    return .{
        .transform = .{ t[0], t[4], t[8], t[12], t[1], t[5], t[9], t[13], t[2], t[6], t[10], t[14] },
        .custom_index_and_mask = (@as(u32, @intCast(instance_index)) & 0x00ff_ffff) | (if (blend) @as(u32, 0x0200_0000) else 0xff00_0000),
        .offset_and_flags = 0x0100_0000,
        .blas = device.accelerationAddress(blas),
    };
}

pub fn worldSphere(info: EntryInfo, transform: Mat4) [4]f32 {
    const center = math.transformPoint(transform, info.center);
    return .{ center[0], center[1], center[2], info.radius * math.maxScale(transform) };
}
