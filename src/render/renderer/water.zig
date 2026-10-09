//! Water surfaces. Internal to the renderer.
const std = @import("std");
const handle = @import("../../handle.zig");
const math = @import("../../math.zig");
const api = @import("../api.zig");
const renderer_state = @import("../state.zig");
const simulation_passes = @import("../passes/simulation.zig");
const render = @import("../renderer.zig");

const Renderer = render.Renderer;
const Vec3 = math.Vec3;
const Scene = api.Scene;
const Water = api.Water;
const WaterDesc = api.WaterDesc;
const max_waters = renderer_state.max_waters;
const WaterState = renderer_state.WaterState;
const createEmitterLocked = @import("emitters.zig").createEmitterLocked;
const destroyEmitterLocked = @import("emitters.zig").destroyEmitterLocked;

/// Sheets of simulated water.
pub const Waters = struct {
    table: handle.HandleTable(renderer_state.WaterState, api.WaterTag),

    fn renderer(waters: *Waters) *Renderer {
        return @alignCast(@fieldParentPtr("waters", waters));
    }

    /// Adds a sheet of simulated water to a scene.
    pub fn create(waters: *Waters, scene: Scene, desc: WaterDesc) !Water {
        const self = waters.renderer();
        self.lock();
        defer self.unlock();
        const data = self.scenes.table.get(scene) orelse return error.InvalidScene;
        if (data.waters.items.len == max_waters) return error.TooManyWaters;
        var state = WaterState{ .scene = scene, .desc = desc };
        if (desc.splashes > 0) state.splash = try createEmitterLocked(self, scene, simulation_passes.splashDesc(desc));
        errdefer if (state.splash) |emitter| destroyEmitterLocked(self, emitter);
        try createWaterTextures(self, &state);
        errdefer for (state.state) |texture| self.device.destroyTexture(texture);
        const water = try self.waters.table.insert(state);
        errdefer _ = self.waters.table.remove(water);
        try data.waters.append(self.gpa, water);
        return water;
    }

    /// Replaces a water surface's description. Changing the resolution
    /// flattens it.
    pub fn set(waters: *Waters, water: Water, desc: WaterDesc) !void {
        const self = waters.renderer();
        self.lock();
        defer self.unlock();
        const state = self.waters.table.get(water) orelse return;
        const resized = !std.mem.eql(u32, &desc.resolution, &state.desc.resolution);
        if (desc.splashes > 0 and state.splash == null) state.splash = try createEmitterLocked(self, state.scene, simulation_passes.splashDesc(desc));
        if (desc.splashes <= 0) if (state.splash) |emitter| {
            destroyEmitterLocked(self, emitter);
            state.splash = null;
        };
        state.desc = desc;
        if (resized) {
            for (state.state) |texture| self.device.destroyTexture(texture);
            try createWaterTextures(self, state);
        }
    }

    /// Dents the water at a world position; `radius` and `depth` in world
    /// units. At most 16 per frame; further ones are dropped.
    pub fn addRipple(waters: *Waters, water: Water, position: Vec3, radius: f32, depth: f32) void {
        const self = waters.renderer();
        self.lock();
        defer self.unlock();
        const state = self.waters.table.get(water) orelse return;
        if (state.ripple_count == state.ripples.len) return;
        const t = state.desc.transform;
        const local = math.transformPoint(math.inverse(t), position);
        const width = @max(math.length(.{ t[0], t[1], t[2] }), 1e-6);
        const up = @max(math.length(.{ t[4], t[5], t[6] }), 1e-6);
        state.ripples[state.ripple_count] = .{
            .position = .{ local[0] + 0.5, local[2] + 0.5 },
            .radius = radius / width,
            .depth = depth / up,
        };
        state.ripple_count += 1;
        const strength = depth * 12 * radius;
        if (strength > state.hit_strength) {
            state.hit_strength = strength;
            state.hit_at = math.transformPoint(t, .{ local[0], 0, local[2] });
            state.hit_radius = radius;
        }
    }

    /// Also frees the splash emitter it made. A stale handle is ignored.
    pub fn destroy(waters: *Waters, water: Water) void {
        const self = waters.renderer();
        self.lock();
        defer self.unlock();
        const removed = self.waters.table.remove(water) orelse return;
        if (removed.splash) |emitter| destroyEmitterLocked(self, emitter);
        for (removed.state) |texture| self.device.destroyTexture(texture);
        const scene = self.scenes.table.get(removed.scene) orelse return;
        for (scene.waters.items, 0..) |item, index| if (std.meta.eql(item, water)) {
            _ = scene.waters.orderedRemove(index);
            break;
        };
    }
};

fn createWaterTextures(self: *Renderer, state: *WaterState) !void {
    inline for (0..2) |axis| state.size[axis] = std.math.clamp(state.desc.resolution[axis], 16, 1024);
    var made: usize = 0;
    errdefer for (state.state[0..made]) |texture| self.device.destroyTexture(texture);
    for (&state.state) |*texture| {
        texture.* = try self.device.createTexture(.{
            .name = "water",
            .width = state.size[0],
            .height = state.size[1],
            .format = .rg16_float,
            .usage = .{ .sampled = true, .color_attachment = true },
        });
        made += 1;
    }
    state.cleared = false;
    state.current = 0;
}
