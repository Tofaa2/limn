//! Hair and the collision fields it is simulated against. Internal to the renderer.
const std = @import("std");
const handle = @import("../../handle.zig");
const math = @import("../../math.zig");
const api = @import("../api.zig");
const renderer_state = @import("../state.zig");
const collision_field = @import("../collision_field.zig");
const render = @import("../renderer.zig");

const Renderer = render.Renderer;
const Mat4 = math.Mat4;
const Vec3 = math.Vec3;
const Scene = api.Scene;
const Hair = api.Hair;
const HairDesc = api.HairDesc;
const HairSimulation = api.HairSimulation;
const CollisionField = api.CollisionField;
const HairState = renderer_state.HairState;

/// Strands of hair, fur or grass, and the shapes they are kept out of.
pub const Hairs = struct {
    table: handle.HandleTable(renderer_state.HairState, api.HairTag),
    fields: handle.HandleTable(renderer_state.CollisionFieldState, api.CollisionFieldTag),

    fn renderer(hairs: *Hairs) *Renderer {
        return @alignCast(@fieldParentPtr("hairs", hairs));
    }

    /// Adds strands of hair, fur or grass to a scene (see `HairDesc`).
    pub fn create(hairs: *Hairs, scene: Scene, desc: HairDesc) !Hair {
        const self = hairs.renderer();
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const data = self.scenes.table.get(scene) orelse return error.InvalidScene;
        if (desc.points_per_strand < 2 or desc.points.len < desc.points_per_strand or desc.points.len % desc.points_per_strand != 0) return error.InvalidHair;
        if (desc.simulation != null and desc.points_per_strand > 64) return error.TooManyPointsPerStrand;
        const Point = extern struct { position: [3]f32, along: f32 };
        const staged = try self.gpa.alloc(Point, desc.points.len);
        defer self.gpa.free(staged);
        const last: f32 = @floatFromInt(desc.points_per_strand - 1);
        for (staged, desc.points, 0..) |*point, position, index| {
            point.* = .{ .position = position, .along = @as(f32, @floatFromInt(index % desc.points_per_strand)) / last };
        }
        const points = try self.device.createBuffer(.{
            .name = "hair",
            .size = staged.len * @sizeOf(Point),
            .usage = .{ .storage = true, .copy_dst = true },
        });
        errdefer self.device.destroyBuffer(points);
        try self.device.uploadBuffer(points, 0, std.mem.sliceAsBytes(staged));
        var kept = desc;
        kept.points = &.{};
        kept.simulation = null;
        const strands: u32 = @intCast(desc.points.len / desc.points_per_strand);
        const hair = try self.hairs.table.insert(.{ .scene = scene, .desc = kept, .points = points, .stretches = strands * (desc.points_per_strand - 1), .strands = strands });
        errdefer _ = self.hairs.table.remove(hair);
        try data.hairs.append(self.gpa, hair);
        const state = self.hairs.table.get(hair).?;
        var low: Vec3 = desc.points[0];
        var high: Vec3 = desc.points[0];
        for (desc.points) |position| inline for (0..3) |axis| {
            low[axis] = @min(low[axis], position[axis]);
            high[axis] = @max(high[axis], position[axis]);
        };
        const middle = math.scale(math.add(low, high), 0.5);
        state.bounds = .{ middle[0], middle[1], middle[2], math.length(math.sub(high, middle)) };
        setHairMotion(state, desc.simulation);
        return hair;
    }

    /// Builds a distance field of a mesh for `HairSimulation.field`, with
    /// `resolution` (8 to 128) cells per side. The mesh should be closed, or
    /// open only downward along its z axis.
    pub fn createCollisionField(hairs: *Hairs, positions: []const [3]f32, indices: []const u32, resolution: u32) !CollisionField {
        const self = hairs.renderer();
        const field = try collision_field.build(self.gpa, positions, indices, resolution);
        defer field.deinit(self.gpa);
        const halves = try self.gpa.alloc(f16, field.distances.len);
        defer self.gpa.free(halves);
        for (halves, field.distances) |*half, distance| half.* = @floatCast(distance);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const texture = try self.device.createTexture(.{
            .name = "collision field",
            .width = field.size,
            .height = field.size,
            .layers = field.size,
            .kind = .@"2d_array",
            .format = .r16_float,
            .usage = .{ .sampled = true, .copy_dst = true },
        });
        errdefer self.device.destroyTexture(texture);
        const per_layer = @as(usize, field.size) * field.size;
        for (0..field.size) |layer| try self.device.uploadTexture(texture, 0, @intCast(layer), std.mem.sliceAsBytes(halves[layer * per_layer ..][0..per_layer]));
        return self.hairs.fields.insert(.{ .texture = texture, .low = field.low, .cell = field.cell, .size = field.size });
    }

    /// A stale handle is ignored.
    pub fn destroyCollisionField(hairs: *Hairs, field: CollisionField) void {
        const self = hairs.renderer();
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const removed = self.hairs.fields.remove(field) orelse return;
        self.device.destroyTexture(removed.texture);
    }

    /// Sets a hair's simulation (wind, colliders, stiffness); null freezes
    /// it as combed. A stale handle is ignored.
    pub fn setSimulation(hairs: *Hairs, hair: Hair, simulation: ?HairSimulation) void {
        const self = hairs.renderer();
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const state = self.hairs.table.get(hair) orelse return;
        setHairMotion(state, simulation);
        if (simulation == null) if (state.moving) |moving| {
            for (moving.points) |buffer| self.device.destroyBuffer(buffer);
            for (moving.density) |buffer| self.device.destroyBuffer(buffer);
            state.moving = null;
        };
    }

    /// Sets the hair-to-world transform. A stale handle is ignored.
    pub fn setTransform(hairs: *Hairs, hair: Hair, transform: Mat4) void {
        const self = hairs.renderer();
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const state = self.hairs.table.get(hair) orelse return;
        state.desc.transform = transform;
    }

    /// A stale handle is ignored.
    pub fn destroy(hairs: *Hairs, hair: Hair) void {
        const self = hairs.renderer();
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const removed = self.hairs.table.remove(hair) orelse return;
        freeHair(self, removed);
        const scene = self.scenes.table.get(removed.scene) orelse return;
        for (scene.hairs.items, 0..) |item, index| if (std.meta.eql(item, hair)) {
            _ = scene.hairs.orderedRemove(index);
            break;
        };
    }
};

fn setHairMotion(state: *HairState, simulation: ?HairSimulation) void {
    state.simulation = simulation;
    state.collider_count = 0;
    const wanted = simulation orelse return;
    state.collider_count = @intCast(@min(wanted.colliders.len, renderer_state.max_hair_colliders));
    @memcpy(state.colliders[0..state.collider_count], wanted.colliders[0..state.collider_count]);
    state.simulation.?.colliders = &.{};
}

pub fn freeHair(self: *Renderer, state: HairState) void {
    self.device.destroyBuffer(state.points);
    if (state.moving) |moving| {
        for (moving.points) |buffer| self.device.destroyBuffer(buffer);
        for (moving.density) |buffer| self.device.destroyBuffer(buffer);
    }
}
