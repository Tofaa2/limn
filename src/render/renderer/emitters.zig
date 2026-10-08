//! Particle emitters. Internal to the renderer.
const std = @import("std");
const rhi = @import("../../rhi/rhi.zig");
const gpu = @import("../gpu.zig");
const api = @import("../api.zig");
const render = @import("../renderer.zig");

const Renderer = render.Renderer;
const Scene = api.Scene;
const Emitter = api.Emitter;
const max_trail_points = api.max_trail_points;
const EmitterDesc = api.EmitterDesc;

/// Adds a GPU-simulated particle emitter to a scene.
pub fn createEmitter(self: *Renderer, scene: Scene, desc: EmitterDesc) !Emitter {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return createEmitterLocked(self, scene, desc);
}

/// `createEmitter` for a caller that holds the renderer's lock.
pub fn createEmitterLocked(self: *Renderer, scene: Scene, desc: EmitterDesc) !Emitter {
    const data = self.scenes.get(scene) orelse return error.InvalidScene;
    const capacity = std.math.clamp(desc.capacity, 1, 1 << 20);
    const buffer = try self.device.createBuffer(.{
        .name = "particles",
        .size = @as(u64, capacity) * @sizeOf(gpu.Particle),
        .usage = .{ .storage = true },
    });
    errdefer self.device.destroyBuffer(buffer);
    const zeros = try self.gpa.alloc(u8, capacity * @sizeOf(gpu.Particle));
    defer self.gpa.free(zeros);
    @memset(zeros, 0);
    try self.device.uploadBuffer(buffer, 0, zeros);
    const order_count = std.math.ceilPowerOfTwo(u32, capacity) catch capacity;
    const order: ?rhi.Buffer = if (desc.sorted) try self.device.createBuffer(.{
        .name = "particle order",
        .size = @as(u64, order_count) * 8,
        .usage = .{ .storage = true, .copy_src = true },
    }) else null;
    errdefer if (order) |value| self.device.destroyBuffer(value);
    const trail_points = @min(desc.trail, max_trail_points);
    const trail: ?rhi.Buffer = if (trail_points != 0) try self.device.createBuffer(.{
        .name = "particle trails",
        .size = @as(u64, capacity) * trail_points * 16,
        .usage = .{ .storage = true },
    }) else null;
    errdefer if (trail) |value| self.device.destroyBuffer(value);
    const emitter = try self.emitters.insert(.{ .scene = scene, .desc = desc, .buffer = buffer, .capacity = capacity, .order = order, .order_count = order_count, .trail = trail, .trail_points = trail_points });
    errdefer _ = self.emitters.remove(emitter);
    try data.emitters.append(self.gpa, emitter);
    return emitter;
}

/// For tests: a sorted emitter's sort keys in drawing order (smaller is
/// farther; dead slots come last). Waits for the GPU. Caller frees.
pub fn emitterSortKeys(self: *Renderer, gpa: std.mem.Allocator, emitter: Emitter) ![]f32 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const data = self.emitters.get(emitter) orelse return error.InvalidEmitter;
    const order = data.order orelse return error.EmitterNotSorted;
    const bytes = try self.device.readBuffer(gpa, order, @as(u64, data.order_count) * 8);
    defer gpa.free(bytes);
    const keys = try gpa.alloc(f32, data.order_count);
    for (keys, 0..) |*key, index| key.* = @bitCast(std.mem.readInt(u32, bytes[index * 8 ..][0..4], .little));
    return keys;
}

/// Replaces an emitter's description; `capacity` is ignored.
pub fn setEmitter(self: *Renderer, emitter: Emitter, desc: EmitterDesc) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (self.emitters.get(emitter)) |data| data.desc = desc;
}

/// Live particles vanish at once. A stale handle is ignored.
pub fn destroyEmitter(self: *Renderer, emitter: Emitter) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    destroyEmitterLocked(self, emitter);
}

/// `destroyEmitter` for a caller that holds the renderer's lock.
pub fn destroyEmitterLocked(self: *Renderer, emitter: Emitter) void {
    const removed = self.emitters.remove(emitter) orelse return;
    self.device.destroyBuffer(removed.buffer);
    if (removed.order) |order| self.device.destroyBuffer(order);
    if (removed.trail) |trail| self.device.destroyBuffer(trail);
    const scene = self.scenes.get(removed.scene) orelse return;
    for (scene.emitters.items, 0..) |item, index| if (std.meta.eql(item, emitter)) {
        _ = scene.emitters.swapRemove(index);
        break;
    };
}
