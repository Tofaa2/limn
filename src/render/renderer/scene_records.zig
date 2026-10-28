//! Writing a scene's instance records each frame: every record at once, or only the changes, across threads. Internal to the renderer.
const std = @import("std");
const rhi = @import("../../rhi/rhi.zig");
const math = @import("../../math.zig");
const gpu = @import("../gpu.zig");
const renderer_state = @import("../state.zig");
const render = @import("../renderer.zig");

const Renderer = render.Renderer;
const Mat4 = math.Mat4;
const max_movers = renderer_state.max_movers;
const SceneData = renderer_state.SceneData;
const max_worker_threads = renderer_state.max_worker_threads;
const prepare_batch = renderer_state.prepare_batch;
const move_batch = renderer_state.move_batch;
const PrepareChunk = renderer_state.PrepareChunk;
const EntryInfo = renderer_state.EntryInfo;
const EntityMark = renderer_state.EntityMark;
const InstanceMove = renderer_state.InstanceMove;
const InstanceRewrite = renderer_state.InstanceRewrite;

const workerThreads = @import("scene_update.zig").workerThreads;
const scene_layout = @import("scene_layout.zig");
const noteMover = scene_layout.noteMover;
const worldSphere = scene_layout.worldSphere;
const rigidRecord = scene_layout.rigidRecord;
const tlasInstance = scene_layout.tlasInstance;
const dead_record = scene_layout.dead_record;

/// Every record of a scene's unskinned entities, written a batch of layout
/// entries at a time on any thread. A batch writes only its own entries'
/// records, spheres and ray-tracing instances, and its own chunk.
pub const PrepareWhole = struct {
    renderer: *Renderer,
    scene: *SceneData,
    records: []gpu.Instance,
    previous: [][12]f32,
    tlas: []rhi.AccelerationInstance,
    chunks: []PrepareChunk,

    const Batch = fn (PrepareWhole, usize) void;

    /// Runs `work` for every batch, across threads when there are enough.
    pub fn spread(prepare: PrepareWhole, comptime work: Batch) void {
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
    pub fn finish(prepare: PrepareWhole, chunk_index: usize) void {
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

    pub fn batch(prepare: PrepareWhole, chunk_index: usize) void {
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
pub const Changes = struct {
    renderer: *Renderer,
    scene: *SceneData,
    moves: []InstanceMove,
    move_count: u32 = 0,
    rewrites: []InstanceRewrite,
    rewrite_count: u32 = 0,
    any_moving: bool = false,
    tlas_changed: bool = false,

    /// Gives an unskinned entry a new transform. `flags` are `InstanceMove`'s.
    pub fn move(changes: *Changes, index: u32, info: *EntryInfo, transform: Mat4, flags: u32) void {
        changes.moves[changes.move_count] = .{ .instance = index, .tlas_slot = info.tlas_slot, .flags = flags, .transform = gpu.affine(transform) };
        changes.move_count += 1;
        changes.place(index, info, transform, flags & InstanceMove.moved != 0, flags != InstanceMove.keep);
    }

    /// Writes an unskinned entry's whole record.
    pub fn rewrite(changes: *Changes, index: u32, info: *EntryInfo, record: gpu.Instance, previous: Mat4, transform: Mat4, changed: bool) void {
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
pub const MoveShare = struct {
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
    pub const block = 256;
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
pub fn moveThreads(self: *Renderer, scene: *const SceneData) usize {
    return std.math.clamp(scene.edited.items.len / move_batch, 1, workerThreads(self));
}

/// Hands the edited entities that only move to threads, when there are
/// enough of them. What it leaves in `scene.edited` is still to be done.
pub fn moveAcrossThreads(self: *Renderer, scene: *SceneData, changes: *Changes, room: u32) !void {
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
