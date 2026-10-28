//! A scene's light records and their shadow atlas tiles, uploaded when they change. Internal to the renderer.
const std = @import("std");
const rhi = @import("../../rhi/rhi.zig");
const math = @import("../../math.zig");
const gpu = @import("../gpu.zig");
const renderer_state = @import("../state.zig");
const scene_pass = @import("../scene_pass.zig");
const render = @import("../renderer.zig");

const Renderer = render.Renderer;
const Vec3 = math.Vec3;
const Lighting = scene_pass.Lighting;
const max_local_shadow_views = renderer_state.max_local_shadow_views;
const local_shadow_tiles_per_side = renderer_state.local_shadow_tiles_per_side;
const FrameArena = renderer_state.FrameArena;
const SceneData = renderer_state.SceneData;
const cullView = @import("view_math.zig").cullView;

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
