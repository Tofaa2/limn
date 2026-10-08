//! Liquid volumes. Internal to the renderer.
const std = @import("std");
const gpu = @import("../gpu.zig");
const api = @import("../api.zig");
const renderer_state = @import("../state.zig");
const simulation_passes = @import("../passes/simulation.zig");
const render = @import("../renderer.zig");

const Renderer = render.Renderer;
const Scene = api.Scene;
const Entity = api.Entity;
const Liquid = api.Liquid;
const LiquidDesc = api.LiquidDesc;
const max_liquids = renderer_state.max_liquids;
const liquid_cell_slots = renderer_state.liquid_cell_slots;
const LiquidState = renderer_state.LiquidState;

pub fn createLiquid(self: *Renderer, scene: Scene, desc: LiquidDesc) !Liquid {
    const liquid = try createLiquidAlone(self, scene, desc);
    attachLiquidProxy(self, scene, liquid, desc) catch |err| std.log.debug("liquid: no stand-in for rays: {s}", .{@errorName(err)});
    return liquid;
}

/// Gives a liquid the see-through box that rays hit in its place.
fn attachLiquidProxy(self: *Renderer, scene: Scene, liquid: Liquid, desc: LiquidDesc) !void {
    if (!self.device.ray_tracing) return;
    const model = self.liquid_proxy_model orelse made: {
        const positions = [8][3]f32{ .{ -0.5, -0.5, -0.5 }, .{ 0.5, -0.5, -0.5 }, .{ 0.5, 0.5, -0.5 }, .{ -0.5, 0.5, -0.5 }, .{ -0.5, -0.5, 0.5 }, .{ 0.5, -0.5, 0.5 }, .{ 0.5, 0.5, 0.5 }, .{ -0.5, 0.5, 0.5 } };
        const indices = [36]u32{ 0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7, 0, 1, 5, 0, 5, 4, 3, 6, 2, 3, 7, 6, 0, 4, 7, 0, 7, 3, 1, 2, 6, 1, 6, 5 };
        const created = try self.createModel(&.{.{ .positions = &positions, .indices = &indices, .material = .{ .base_color = .{ 1, 1, 1, 0.7 }, .metallic = 0, .roughness = 0.05, .alpha_mode = .blend, .double_sided = true } }});
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.liquid_proxy_model == null) self.liquid_proxy_model = created;
        break :made self.liquid_proxy_model.?;
    };
    const entity = try self.spawn(scene, .{ .model = model, .transform = desc.transform, .visible = false, .tint = desc.color });
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const data = self.entities.get(entity) orelse return;
    data.rays_only = true;
    data.visible = true;
    if (self.liquids.get(liquid)) |state| state.proxy = entity;
    if (self.scenes.get(scene)) |scene_data| scene_data.layout_dirty = true;
}

fn createLiquidAlone(self: *Renderer, scene: Scene, desc: LiquidDesc) !Liquid {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const data = self.scenes.get(scene) orelse return error.InvalidScene;
    if (data.liquids.items.len == max_liquids) return error.TooManyLiquids;
    const device = self.device;
    const radius = std.math.clamp(desc.particle_radius, 0.002, 10);
    const reach = radius * 4;
    const box = simulation_passes.liquidBox(desc.transform);
    var grid: [3]i32 = undefined;
    var cell_count: u64 = 1;
    inline for (0..3) |axis| {
        grid[axis] = @intFromFloat(@max(@ceil(box.extent[axis] / reach), 1));
        cell_count *= @intCast(grid[axis]);
    }
    if (cell_count > 2 * 1024 * 1024) return error.LiquidTooFine;
    const capacity = std.math.clamp(desc.capacity, 64, 1 << 20);
    var block: [3]u32 = undefined;
    inline for (0..3) |axis| block[axis] = @intFromFloat(@max(@floor(std.math.clamp(desc.fill[axis], 0, 1) * box.extent[axis] / (radius * 2) - 1), 0));
    const particles = try device.createBuffer(.{ .name = "liquid particles", .size = @as(u64, capacity) * @sizeOf(gpu.LiquidParticle), .usage = .{ .storage = true } });
    errdefer device.destroyBuffer(particles);
    const counts = try device.createBuffer(.{ .name = "liquid grid counts", .size = cell_count * @sizeOf(u32), .usage = .{ .storage = true } });
    errdefer device.destroyBuffer(counts);
    const cells = try device.createBuffer(.{ .name = "liquid grid", .size = cell_count * liquid_cell_slots * @sizeOf(u32), .usage = .{ .storage = true } });
    errdefer device.destroyBuffer(cells);
    const params_buffer = try device.createBuffer(.{ .name = "liquid steps", .size = 8 * @sizeOf(gpu.Liquid), .usage = .{ .storage = true } });
    errdefer device.destroyBuffer(params_buffer);
    var state = LiquidState{
        .scene = scene,
        .desc = desc,
        .capacity = capacity,
        .particles = particles,
        .counts = counts,
        .cells = cells,
        .params_buffer = params_buffer,
        .cell_count = @intCast(cell_count),
        .grid = grid,
        .block = block,
    };
    state.desc.particle_radius = radius;
    state.setSources(desc.sources);
    const liquid = try self.liquids.insert(state);
    errdefer _ = self.liquids.remove(liquid);
    try data.liquids.append(self.gpa, liquid);
    return liquid;
}

/// Replaces a liquid's description. Box size, particle radius, capacity
/// and the starting block keep their creation values.
pub fn setLiquid(self: *Renderer, liquid: Liquid, desc: LiquidDesc) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const state = self.liquids.get(liquid) orelse return error.InvalidLiquid;
    const radius = state.desc.particle_radius;
    state.desc = desc;
    state.desc.particle_radius = radius;
    state.setSources(desc.sources);
}

/// Particles of a liquid currently in use.
pub fn liquidParticles(self: *Renderer, liquid: Liquid) u32 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const state = self.liquids.get(liquid) orelse return 0;
    return state.live;
}

/// A stale handle is ignored.
pub fn destroyLiquid(self: *Renderer, liquid: Liquid) void {
    var proxy: ?Entity = null;
    defer if (proxy) |entity| self.despawn(entity);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var removed = self.liquids.remove(liquid) orelse return;
    proxy = removed.proxy;
    removed.deinit(self.device);
    const scene = self.scenes.get(removed.scene) orelse return;
    for (scene.liquids.items, 0..) |item, index| if (std.meta.eql(item, liquid)) {
        _ = scene.liquids.orderedRemove(index);
        break;
    };
}
