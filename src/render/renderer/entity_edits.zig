//! Entity transforms and edits, queued or made under the renderer lock. Internal to the renderer.
const std = @import("std");
const math = @import("../../math.zig");
const api = @import("../api.zig");
const renderer_state = @import("../state.zig");
const render = @import("../renderer.zig");

const Renderer = render.Renderer;
const Mat4 = math.Mat4;
const Entity = api.Entity;
const Scene = api.Scene;
const EntityData = renderer_state.EntityData;
const EntityEdit = renderer_state.EntityEdit;
const EntityMark = renderer_state.EntityMark;

/// Takes the lock if nothing holds it. The entity setters use it so as
/// not to wait for a frame that is being recorded; see `queueEdit`.
pub fn tryLock(self: *Renderer) bool {
    if (!self.internal.mutex.tryLock()) return false;
    if (self.internal.pending_any.load(.acquire)) applyPending(self);
    return true;
}

/// Leaves an entity edit to be made, in order, before anything else next
/// uses the lock, so that the caller does not wait for a frame.
pub fn queueEdit(self: *Renderer, entity: Entity, change: EntityEdit.Change) void {
    queueEdits(self, &.{.{ .entity = entity, .change = change }});
}

/// `queueEdit` for several edits under one lock of the queue.
pub fn queueEdits(self: *Renderer, edits: []const EntityEdit) void {
    const queued = queued: {
        self.internal.pending_mutex.lockUncancelable(self.internal.io);
        defer self.internal.pending_mutex.unlock(self.internal.io);
        self.internal.pending.appendSlice(self.internal.gpa, edits) catch break :queued false;
        self.internal.pending_any.store(true, .release);
        break :queued true;
    };
    if (queued) return;
    self.lock();
    defer self.unlock();
    for (edits) |edit| applyEdit(self, edit);
}

/// The bookkeeping of a live entity. Needs the lock, as do the calls below.
pub fn markOf(self: *Renderer, entity: Entity) ?*EntityMark {
    if (entity.index >= self.internal.entity_marks.items.len) return null;
    const mark = &self.internal.entity_marks.items[entity.index];
    return if (mark.handle == @as(u64, @bitCast(entity))) mark else null;
}

/// An entity's transform; the identity for a stale handle.
pub fn transformOf(self: *Renderer, entity: Entity) Mat4 {
    return if (markOf(self, entity) != null) self.internal.entity_transforms.items[entity.index] else math.identity;
}

/// Gives an entity a transform, relative to its parent if it has one. A
/// teleport is not motion.
pub fn moveEntity(self: *Renderer, entity: Entity, transform: Mat4, teleport: bool) void {
    const mark = markOf(self, entity) orelse return;
    if (!mark.related) {
        _ = placeEntity(self, entity, mark, transform, teleport);
        return;
    }
    const data = self.entities.internal.table.get(entity) orelse return;
    data.local = transform;
    followParent(self, entity, data, teleport);
}

/// Places a related entity under its parent from its `local` transform, and
/// its children after it.
pub fn followParent(self: *Renderer, entity: Entity, data: *const EntityData, teleport: bool) void {
    const mark = markOf(self, entity) orelse return;
    const world = if (data.parent) |parent| math.mul(transformOf(self, parent), data.local) else data.local;
    if (!placeEntity(self, entity, mark, world, teleport) and !teleport) return;
    for (data.children.items) |child| if (self.entities.internal.table.get(child)) |child_data| followParent(self, child, child_data, teleport);
}

/// Writes an entity's world transform; false when it was there already.
fn placeEntity(self: *Renderer, entity: Entity, mark: *EntityMark, world: Mat4, teleport: bool) bool {
    const slot = &self.internal.entity_transforms.items[entity.index];
    if (teleport) {
        self.internal.entity_previous.items[entity.index] = world;
    } else if (std.mem.eql(f32, slot, &world)) return false;
    slot.* = world;
    noteEdited(self, entity.index, mark, if (teleport) EntityMark.teleported else EntityMark.moved);
    return true;
}

/// Has an entity's instance records written again.
pub fn restyleEntity(self: *Renderer, entity: Entity) void {
    const mark = markOf(self, entity) orelse return;
    noteEdited(self, entity.index, mark, EntityMark.restyled);
}

/// Starts the bookkeeping of a new entity.
pub fn markEntity(self: *Renderer, entity: Entity, scene: Scene, transform: Mat4) !void {
    const needed = @as(usize, entity.index) + 1;
    if (self.internal.entity_marks.items.len < needed) {
        try self.internal.entity_transforms.ensureTotalCapacity(self.internal.gpa, needed);
        try self.internal.entity_previous.ensureTotalCapacity(self.internal.gpa, needed);
        try self.internal.entity_marks.ensureTotalCapacity(self.internal.gpa, needed);
        try self.internal.entity_spans.ensureTotalCapacity(self.internal.gpa, needed);
        @memset(self.internal.entity_transforms.addManyAsSliceAssumeCapacity(needed - self.internal.entity_transforms.items.len), math.identity);
        @memset(self.internal.entity_previous.addManyAsSliceAssumeCapacity(needed - self.internal.entity_previous.items.len), math.identity);
        @memset(self.internal.entity_marks.addManyAsSliceAssumeCapacity(needed - self.internal.entity_marks.items.len), .{});
        @memset(self.internal.entity_spans.addManyAsSliceAssumeCapacity(needed - self.internal.entity_spans.items.len), .{});
    }
    self.internal.entity_transforms.items[entity.index] = transform;
    self.internal.entity_previous.items[entity.index] = transform;
    self.internal.entity_marks.items[entity.index] = .{ .handle = @bitCast(entity), .scene = scene };
    self.internal.entity_spans.items[entity.index] = .{};
}

/// Makes the queued edits, in the order they were queued.
pub fn applyPending(self: *Renderer) void {
    {
        self.internal.pending_mutex.lockUncancelable(self.internal.io);
        defer self.internal.pending_mutex.unlock(self.internal.io);
        std.mem.swap(std.ArrayList(EntityEdit), &self.internal.pending, &self.internal.applying);
        self.internal.pending_any.store(false, .release);
    }
    for (self.internal.applying.items) |edit| applyEdit(self, edit);
    self.internal.applying.clearRetainingCapacity();
}

/// Makes one entity edit. Needs the lock.
pub fn applyEdit(self: *Renderer, edit: EntityEdit) void {
    switch (edit.change) {
        .transform => |transform| moveEntity(self, edit.entity, transform, false),
        .teleport => |transform| moveEntity(self, edit.entity, transform, true),
        .tint => |tint| if (self.entities.internal.table.get(edit.entity)) |data| {
            if (data.tint == tint) return;
            data.tint = tint;
            restyleEntity(self, edit.entity);
        },
        .params => |params| if (self.entities.internal.table.get(edit.entity)) |data| {
            if (std.mem.eql(f32, &data.params, &params)) return;
            data.params = params;
            restyleEntity(self, edit.entity);
        },
        .pose => |pose| if (self.entities.internal.table.get(edit.entity)) |data| {
            data.pose = pose;
        },
    }
}

/// Lists an entity among its scene's edited ones, with what changed.
pub fn noteEdited(self: *Renderer, index: u32, mark: *EntityMark, change: u32) void {
    const wanted = change | EntityMark.listed;
    if (mark.bits & wanted == wanted) return;
    const scene = self.scenes.internal.table.get(mark.scene) orelse return;
    const whole = EntityMark.restyled | EntityMark.teleported;
    if (change & whole != 0 and mark.bits & whole == 0) scene.restyled_entries += mark.layout_count;
    mark.bits |= change;
    if (mark.bits & EntityMark.listed != 0) return;
    scene.edited.append(self.internal.gpa, index) catch {
        scene.records_valid = false;
        return;
    };
    scene.edited_entries += mark.layout_count;
    mark.bits |= EntityMark.listed;
}
