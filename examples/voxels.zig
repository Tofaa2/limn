//! A small planet made of voxels, about fifty million of them.
//!
//! The planet is cut into chunks of 32 voxels a side. A chunk is worked
//! out and turned into triangles on a worker thread when the camera comes
//! to where it can be seen, and dropped again once it has gone below the
//! horizon, so flying round the planet streams it in ahead and out behind.
//! Each chunk is one model; the renderer cuts it into meshlets, makes its
//! levels of detail, and from there on culls and draws all of them on the
//! GPU with a handful of indirect draws. The sun goes round the planet
//! once every two minutes.
//!
//!   Space    fly by hand, or go back to the flight round the planet
//!   WASD     fly, Q/E down and up, Shift faster; the mouse looks
//!   B        the edges of the chunks nearby
//!   Tab      a color per meshlet, then per triangle
//!   T        hold to hurry the sun
//!   P        stop and resume the streaming of chunks
//!
//! `--altitude N` flies N voxels above the ground instead of skimming it:
//! from a few hundred up, half the planet is in view and loaded at once.
//! `--frames N`, `--screenshot file.png`.
const std = @import("std");
const gfx = @import("limn");
const math = gfx.math;
const glfw = @import("glfw");
const Stage = @import("window").Stage;

const chunk_size = 32;
/// Chunks along each side of the cube the planet sits in.
const span = 16;
const half_world = chunk_size * span / 2;
const planet_radius = 222.0;
/// How far the ground rises above and falls below `planet_radius`, and
/// the height the sea stands at.
const lowest = -12.0;
const highest = 30.0;
const sea_level = 3.0;
/// Chunks being worked out at once.
const jobs_at_once = 12;

const Material = enum(u8) { air, water, sand, grass, dirt, stone, rock, snow };

const palette = [_][4]f32{
    .{ 0, 0, 0, 1 },
    .{ 0.05, 0.22, 0.42, 1 },
    .{ 0.72, 0.64, 0.42, 1 },
    .{ 0.20, 0.42, 0.13, 1 },
    .{ 0.34, 0.24, 0.15, 1 },
    .{ 0.36, 0.36, 0.38, 1 },
    .{ 0.44, 0.41, 0.38, 1 },
    .{ 0.90, 0.92, 0.95, 1 },
};

fn lattice(x: i32, y: i32, z: i32) f32 {
    var h: u32 = @bitCast(x *% 374761393 +% y *% 668265263 +% z *% 1274126177);
    h = (h ^ (h >> 13)) *% 1274126177;
    h ^= h >> 16;
    return @as(f32, @floatFromInt(h & 0xffff)) / 32767.5 - 1.0;
}

/// Smooth noise between -1 and 1, one feature per unit.
fn noise(p: math.Vec3) f32 {
    const base = [3]f32{ @floor(p[0]), @floor(p[1]), @floor(p[2]) };
    const cell = [3]i32{ @intFromFloat(base[0]), @intFromFloat(base[1]), @intFromFloat(base[2]) };
    var t: [3]f32 = undefined;
    for (&t, 0..) |*value, axis| {
        const f = p[axis] - base[axis];
        value.* = f * f * (3 - 2 * f);
    }
    var total: f32 = 0;
    for (0..8) |corner| {
        const offset = [3]i32{ @intCast(corner & 1), @intCast((corner >> 1) & 1), @intCast(corner >> 2) };
        var weight: f32 = 1;
        for (0..3) |axis| weight *= if (offset[axis] == 1) t[axis] else 1 - t[axis];
        total += weight * lattice(cell[0] + offset[0], cell[1] + offset[1], cell[2] + offset[2]);
    }
    return total;
}

/// How high the ground stands above `planet_radius` in a direction from
/// the planet's middle: plains and sea beds, and ridges on the high ground.
fn groundHeight(direction: math.Vec3) f32 {
    var rolling: f32 = 0;
    var frequency: f32 = 2.1;
    var amplitude: f32 = 0.55;
    for (0..4) |_| {
        rolling += amplitude * noise(math.scale(direction, frequency));
        frequency *= 2.03;
        amplitude *= 0.5;
    }
    const ridge = 1 - @abs(noise(math.add(math.scale(direction, 6.3), .{ 11.5, 3.25, 7.75 })));
    const height = 5 + rolling * 22 + @max(rolling, 0) * ridge * ridge * 20;
    return std.math.clamp(height, lowest, highest);
}

/// What a voxel is made of, from where its middle is and how high the
/// ground stands there.
fn materialAt(center: math.Vec3, ground: f32) Material {
    const from_middle = math.length(center);
    const depth = planet_radius + ground - from_middle;
    if (depth <= 0) return if (from_middle < planet_radius + sea_level) .water else .air;
    if (depth > 4) return .stone;
    if (depth > 1.2) return .dirt;
    if (ground < sea_level + 1.5) return .sand;
    const latitude = @abs(center[1]) / from_middle;
    if (ground > 22 or latitude > 0.88) return .snow;
    if (ground > 15) return .rock;
    return .grass;
}

/// The triangles of one kind of surface in a chunk.
const Surface = struct {
    positions: std.ArrayList([3]f32) = .empty,
    normals: std.ArrayList([3]f32) = .empty,
    colors: std.ArrayList([4]f32) = .empty,
    indices: std.ArrayList(u32) = .empty,

    fn deinit(self: *Surface, gpa: std.mem.Allocator) void {
        self.positions.deinit(gpa);
        self.normals.deinit(gpa);
        self.colors.deinit(gpa);
        self.indices.deinit(gpa);
    }

    /// A rectangle of faces lying across `axis` at `plane`, from `low` to
    /// `high` along the two other axes, facing the way of `sign`.
    fn addQuad(self: *Surface, gpa: std.mem.Allocator, axis: usize, sign: i32, plane: f32, low: [2]f32, high: [2]f32, color: [4]f32) !void {
        const u = (axis + 1) % 3;
        const v = (axis + 2) % 3;
        const base: u32 = @intCast(self.positions.items.len);
        const corners = [4][2]f32{ low, .{ high[0], low[1] }, high, .{ low[0], high[1] } };
        var normal = [3]f32{ 0, 0, 0 };
        normal[axis] = @floatFromInt(sign);
        for (corners) |corner| {
            var position: [3]f32 = undefined;
            position[axis] = plane;
            position[u] = corner[0];
            position[v] = corner[1];
            try self.positions.append(gpa, position);
            try self.normals.append(gpa, normal);
            try self.colors.append(gpa, color);
        }
        const order: [6]u32 = if (sign > 0) .{ 0, 1, 2, 0, 2, 3 } else .{ 0, 2, 1, 0, 3, 2 };
        for (order) |corner| try self.indices.append(gpa, base + corner);
    }
};

/// A chunk worked out: what each voxel is made of, with one more all
/// round from the chunks beside it, to know which faces show.
const Voxels = struct {
    const side = chunk_size + 2;
    cells: [side * side * side]Material,

    fn at(self: *const Voxels, x: i32, y: i32, z: i32) Material {
        return self.cells[@intCast((x + 1) + (y + 1) * side + (z + 1) * side * side)];
    }

    /// Fills the chunk whose lowest corner is at `origin`. The ground's
    /// height is worked out every fourth voxel and blended between: it
    /// has nothing that fine in it.
    fn fill(self: *Voxels, origin: math.Vec3) void {
        const step = 4;
        const nodes = (side + step - 1) / step + 1;
        var heights: [nodes * nodes * nodes]f32 = undefined;
        for (0..nodes) |k| for (0..nodes) |j| for (0..nodes) |i| {
            const point = math.add(origin, .{ @as(f32, @floatFromInt(i * step)) - 1.5, @as(f32, @floatFromInt(j * step)) - 1.5, @as(f32, @floatFromInt(k * step)) - 1.5 });
            const distance = math.length(point);
            heights[i + j * nodes + k * nodes * nodes] = if (distance > 1e-3) groundHeight(math.scale(point, 1 / distance)) else highest;
        };
        for (0..side) |z| for (0..side) |y| for (0..side) |x| {
            const node = [3]usize{ x / step, y / step, z / step };
            const t = [3]f32{
                @as(f32, @floatFromInt(x % step)) / step,
                @as(f32, @floatFromInt(y % step)) / step,
                @as(f32, @floatFromInt(z % step)) / step,
            };
            var ground: f32 = 0;
            for (0..8) |corner| {
                const offset = [3]usize{ corner & 1, (corner >> 1) & 1, corner >> 2 };
                var weight: f32 = 1;
                for (0..3) |axis| weight *= if (offset[axis] == 1) t[axis] else 1 - t[axis];
                ground += weight * heights[(node[0] + offset[0]) + (node[1] + offset[1]) * nodes + (node[2] + offset[2]) * nodes * nodes];
            }
            const center = math.add(origin, .{ @as(f32, @floatFromInt(x)) - 0.5, @as(f32, @floatFromInt(y)) - 0.5, @as(f32, @floatFromInt(z)) - 0.5 });
            self.cells[x + y * side + z * side * side] = materialAt(center, ground);
        };
    }

    /// How many of the chunk's own voxels are not air.
    fn count(self: *const Voxels) u32 {
        var total: u32 = 0;
        for (0..chunk_size) |z| for (0..chunk_size) |y| for (0..chunk_size) |x| {
            if (self.at(@intCast(x), @intCast(y), @intCast(z)) != .air) total += 1;
        };
        return total;
    }

    /// The faces between a voxel and the air beside it, with neighbours of
    /// one material in a plane joined into rectangles as large as they go.
    fn mesh(self: *const Voxels, gpa: std.mem.Allocator, land: *Surface, sea: *Surface) !void {
        for (0..3) |axis| for ([_]i32{ 1, -1 }) |sign| {
            const u = (axis + 1) % 3;
            const v = (axis + 2) % 3;
            for (0..chunk_size) |slice| {
                var faces: [chunk_size][chunk_size]Material = undefined;
                for (0..chunk_size) |j| for (0..chunk_size) |i| {
                    var cell: [3]i32 = undefined;
                    cell[axis] = @intCast(slice);
                    cell[u] = @intCast(i);
                    cell[v] = @intCast(j);
                    var beside = cell;
                    beside[axis] += sign;
                    const material = self.at(cell[0], cell[1], cell[2]);
                    faces[j][i] = if (material != .air and self.at(beside[0], beside[1], beside[2]) == .air) material else .air;
                };
                for (0..chunk_size) |j| {
                    var i: usize = 0;
                    while (i < chunk_size) {
                        const material = faces[j][i];
                        if (material == .air) {
                            i += 1;
                            continue;
                        }
                        var width: usize = 1;
                        while (i + width < chunk_size and faces[j][i + width] == material) width += 1;
                        var height: usize = 1;
                        grow: while (j + height < chunk_size) : (height += 1) {
                            for (0..width) |step| if (faces[j + height][i + step] != material) break :grow;
                        }
                        for (0..height) |row| @memset(faces[j + row][i .. i + width], .air);
                        const plane: f32 = @floatFromInt(if (sign > 0) slice + 1 else slice);
                        const surface = if (material == .water) sea else land;
                        try surface.addQuad(gpa, axis, sign, plane, .{ @floatFromInt(i), @floatFromInt(j) }, .{ @floatFromInt(i + width), @floatFromInt(j + height) }, palette[@intFromEnum(material)]);
                        i += width;
                    }
                }
            }
        };
    }
};

const Chunk = struct {
    /// The chunk's place in the cube, in chunks.
    cell: [3]u8,
    state: enum { absent, building, loaded, bare } = .absent,
    model: ?gfx.Model = null,
    entity: ?gfx.Entity = null,
    /// How many voxels it holds, once it has been worked out.
    voxels: ?u32 = null,
    counting: bool = false,

    fn origin(self: Chunk) math.Vec3 {
        return .{
            @as(f32, @floatFromInt(self.cell[0])) * chunk_size - half_world,
            @as(f32, @floatFromInt(self.cell[1])) * chunk_size - half_world,
            @as(f32, @floatFromInt(self.cell[2])) * chunk_size - half_world,
        };
    }

    fn center(self: Chunk) math.Vec3 {
        return math.add(self.origin(), .{ chunk_size / 2, chunk_size / 2, chunk_size / 2 });
    }
};

/// What a worker hands back for a chunk.
const Built = struct {
    chunk: u32,
    voxels: u32,
    meshed: bool,
    model: ?gfx.Model = null,
    triangles: u32 = 0,
};

const World = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    renderer: *gfx.Renderer,
    scene: gfx.Scene,
    /// The chunks the planet's surface passes through.
    chunks: []Chunk,
    /// Voxels of the chunks that lie wholly under the ground.
    buried_voxels: u64,
    counted_voxels: u64 = 0,
    counted_chunks: u32 = 0,
    loaded: u32 = 0,
    triangles: u64 = 0,
    in_flight: u32 = 0,
    group: std.Io.Group = .init,
    mutex: std.Io.Mutex = .init,
    built: std.ArrayList(Built) = .empty,

    fn create(gpa: std.mem.Allocator, io: std.Io, renderer: *gfx.Renderer, scene: gfx.Scene) !World {
        var chunks: std.ArrayList(Chunk) = .empty;
        errdefer chunks.deinit(gpa);
        var buried: u64 = 0;
        const reach = chunk_size * 0.5 * @sqrt(3.0);
        for (0..span) |z| for (0..span) |y| for (0..span) |x| {
            const chunk = Chunk{ .cell = .{ @intCast(x), @intCast(y), @intCast(z) } };
            const distance = math.length(chunk.center());
            if (distance - reach > planet_radius + highest) continue;
            if (distance + reach < planet_radius + lowest) {
                buried += chunk_size * chunk_size * chunk_size;
                continue;
            }
            try chunks.append(gpa, chunk);
        };
        return .{ .gpa = gpa, .io = io, .renderer = renderer, .scene = scene, .chunks = try chunks.toOwnedSlice(gpa), .buried_voxels = buried };
    }

    /// Waits for the workers, then lets go of everything.
    fn deinit(self: *World) void {
        self.group.await(self.io) catch {};
        self.built.deinit(self.gpa);
        self.gpa.free(self.chunks);
    }

    /// Whether a chunk is on the camera's side of the horizon, with
    /// `margin` radians to spare.
    fn overHorizon(chunk: Chunk, eye: math.Vec3, margin: f32) bool {
        const center = chunk.center();
        const eye_distance = math.length(eye);
        const center_distance = math.length(center);
        const horizon = std.math.acos(@min((planet_radius + lowest) / eye_distance, 1.0));
        const across = std.math.asin(@min(chunk_size / center_distance, 1.0));
        const between = std.math.acos(std.math.clamp(math.dot(center, eye) / (center_distance * eye_distance), -1.0, 1.0));
        return between < horizon + across + margin;
    }

    /// Runs on a worker: works a chunk out and, when `meshed`, makes its
    /// model.
    fn build(self: *World, index: u32, meshed: bool) std.Io.Cancelable!void {
        var result = Built{ .chunk = index, .voxels = 0, .meshed = meshed };
        self.buildInto(&result) catch {};
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.built.append(self.gpa, result) catch {
            if (result.model) |model| self.renderer.destroyModel(model) catch {};
        };
    }

    fn buildInto(self: *World, result: *Built) !void {
        const gpa = std.heap.smp_allocator;
        const voxels = try gpa.create(Voxels);
        defer gpa.destroy(voxels);
        voxels.fill(self.chunks[result.chunk].origin());
        result.voxels = voxels.count();
        if (!result.meshed) return;
        var land = Surface{};
        defer land.deinit(gpa);
        var sea = Surface{};
        defer sea.deinit(gpa);
        try voxels.mesh(gpa, &land, &sea);
        var meshes: [2]gfx.MeshDesc = undefined;
        var mesh_count: usize = 0;
        if (land.indices.items.len != 0) {
            meshes[mesh_count] = .{ .positions = land.positions.items, .normals = land.normals.items, .colors = land.colors.items, .indices = land.indices.items, .material = .{ .metallic = 0, .roughness = 0.9 } };
            mesh_count += 1;
        }
        if (sea.indices.items.len != 0) {
            meshes[mesh_count] = .{ .positions = sea.positions.items, .normals = sea.normals.items, .colors = sea.colors.items, .indices = sea.indices.items, .material = .{ .metallic = 0, .roughness = 0.25 } };
            mesh_count += 1;
        }
        if (mesh_count == 0) return;
        result.triangles = @intCast((land.indices.items.len + sea.indices.items.len) / 3);
        result.model = try self.renderer.createModel(meshes[0..mesh_count]);
    }

    fn start(self: *World, index: u32, meshed: bool) void {
        self.in_flight += 1;
        self.group.concurrent(self.io, build, .{ self, index, meshed }) catch self.group.async(self.io, build, .{ self, index, meshed });
    }

    fn unload(self: *World, chunk: *Chunk) void {
        if (chunk.entity) |entity| self.renderer.despawn(entity);
        if (chunk.model) |model| self.renderer.destroyModel(model) catch {};
        chunk.entity = null;
        chunk.model = null;
        chunk.state = .absent;
        self.loaded -= 1;
    }

    /// Takes in what the workers have finished, drops the chunks that have
    /// gone below the horizon, and starts on the nearest that have come
    /// over it. Returns how many chunks in view are still to come.
    fn stream(self: *World, eye: math.Vec3, streaming: bool) !u32 {
        self.mutex.lockUncancelable(self.io);
        const finished = self.built.toOwnedSlice(self.gpa) catch &.{};
        self.mutex.unlock(self.io);
        defer self.gpa.free(finished);
        for (finished) |result| {
            self.in_flight -= 1;
            const chunk = &self.chunks[result.chunk];
            if (chunk.voxels == null) {
                chunk.voxels = result.voxels;
                self.counted_voxels += result.voxels;
                self.counted_chunks += 1;
            }
            chunk.counting = false;
            if (!result.meshed) continue;
            const model = result.model orelse {
                chunk.state = .bare;
                continue;
            };
            chunk.model = model;
            chunk.entity = try self.renderer.spawn(self.scene, .{ .model = model, .transform = math.translation(chunk.origin()) });
            chunk.state = .loaded;
            self.loaded += 1;
            self.triangles += result.triangles;
        }
        if (!streaming) return 0;

        var waiting: u32 = 0;
        var nearest: [jobs_at_once]?u32 = @splat(null);
        var nearest_distance: [jobs_at_once]f32 = @splat(std.math.inf(f32));
        for (self.chunks, 0..) |*chunk, index| {
            switch (chunk.state) {
                .loaded => if (!overHorizon(chunk.*, eye, 0.3)) self.unload(chunk),
                .bare => if (!overHorizon(chunk.*, eye, 0.3)) {
                    chunk.state = .absent;
                },
                .building => waiting += 1,
                .absent => if (overHorizon(chunk.*, eye, 0.15)) {
                    waiting += 1;
                    var distance = math.length(math.sub(chunk.center(), eye));
                    var candidate: ?u32 = @intCast(index);
                    for (&nearest, &nearest_distance) |*slot, *slot_distance| {
                        if (distance < slot_distance.*) {
                            std.mem.swap(?u32, slot, &candidate);
                            std.mem.swap(f32, slot_distance, &distance);
                        }
                    }
                },
            }
        }
        for (nearest) |candidate| {
            const index = candidate orelse break;
            if (self.in_flight >= jobs_at_once) break;
            self.chunks[index].state = .building;
            self.start(index, true);
        }
        if (waiting == 0) for (self.chunks, 0..) |*chunk, index| {
            if (self.in_flight >= jobs_at_once) break;
            if (chunk.voxels != null or chunk.counting or chunk.state == .building) continue;
            chunk.counting = true;
            self.start(@intCast(index), false);
        };
        return waiting;
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var altitude: ?f32 = null;
    {
        var arguments = try init.minimal.args.iterateAllocator(gpa);
        defer arguments.deinit();
        while (arguments.next()) |argument| {
            if (std.mem.eql(u8, argument, "--altitude")) altitude = try std.fmt.parseFloat(f32, arguments.next() orelse return error.MissingArgument);
        }
    }
    var stage = try Stage.create(init, "Limn voxel planet", .{});
    const renderer = stage.renderer;
    const scene = try renderer.createScene();
    const environment = try renderer.createSky(.{ .sun_direction = .{ 0, 1, 0 }, .stars = 40 });
    renderer.setEnvironment(scene, environment, 0.6);

    var world = try World.create(gpa, init.io, renderer, scene);
    defer world.deinit();

    var list = gfx.DrawList.init(gpa);
    defer list.deinit();
    const font = renderer.defaultFont();
    var text: [320]u8 = undefined;
    var by_hand = false;
    var edges = false;
    var streaming = true;
    var debug_view: gfx.DebugView = .none;
    var round: f32 = 0.6;
    var day: f32 = 0.9;
    var eye = math.Vec3{ 0, 0, planet_radius + 90 };
    var forward = math.Vec3{ 1, 0, 0 };
    var cursor: ?[2]f64 = null;

    eye = flight(round, altitude)[0];
    while (try world.stream(eye, true) != 0) try init.io.sleep(std.Io.Duration.fromMilliseconds(2), .awake);
    try renderer.waitUntilLoaded();

    while (stage.begin()) |tick| {
        if (stage.keyPressed(glfw.GLFW_KEY_SPACE)) {
            by_hand = !by_hand;
            cursor = null;
            if (stage.window) |window| window.captureCursor(by_hand);
        }
        if (stage.keyPressed(glfw.GLFW_KEY_B)) edges = !edges;
        if (stage.keyPressed(glfw.GLFW_KEY_P)) streaming = !streaming;
        if (stage.keyPressed(glfw.GLFW_KEY_TAB)) debug_view = switch (debug_view) {
            .none => .meshlets,
            .meshlets => .triangles,
            else => .none,
        };
        const turning: f32 = if (stage.keyDown(glfw.GLFW_KEY_T)) 1.2 else std.math.tau / 120.0;
        day += tick.dt * turning;

        var up = math.normalize(eye);
        if (by_hand) {
            if (stage.window) |window| {
                const now = window.cursor();
                if (cursor) |before| {
                    const turn: f32 = @floatCast((before[0] - now[0]) * 0.0025);
                    const tilt: f32 = @floatCast((before[1] - now[1]) * 0.0025);
                    const right = math.normalize(math.cross(forward, up));
                    forward = math.normalize(math.add(forward, math.add(math.scale(right, -turn), math.scale(up, tilt))));
                }
                cursor = now;
            }
            const right = math.normalize(math.cross(forward, up));
            const speed: f32 = if (stage.keyDown(glfw.GLFW_KEY_LEFT_SHIFT)) 160 else 45;
            var move = math.Vec3{ 0, 0, 0 };
            if (stage.keyDown(glfw.GLFW_KEY_W)) move = math.add(move, forward);
            if (stage.keyDown(glfw.GLFW_KEY_S)) move = math.sub(move, forward);
            if (stage.keyDown(glfw.GLFW_KEY_D)) move = math.add(move, right);
            if (stage.keyDown(glfw.GLFW_KEY_A)) move = math.sub(move, right);
            if (stage.keyDown(glfw.GLFW_KEY_E)) move = math.add(move, up);
            if (stage.keyDown(glfw.GLFW_KEY_Q)) move = math.sub(move, up);
            eye = math.add(eye, math.scale(move, speed * tick.dt));
            const from_middle = std.math.clamp(math.length(eye), planet_radius + highest + 3, planet_radius * 4);
            eye = math.scale(math.normalize(eye), from_middle);
        } else {
            round += tick.dt * 0.05;
            const placed = flight(round, altitude);
            eye = placed[0];
            forward = placed[1];
        }
        up = math.normalize(eye);

        const waiting = try world.stream(eye, streaming);

        const toward_sun = math.normalize(math.Vec3{ @cos(day), 0.25, @sin(day) });
        renderer.setSun(scene, .{ .direction = math.scale(toward_sun, -1), .color = .{ 1, 0.95, 0.88 }, .intensity = 4 });

        list.clear();
        if (edges) for (world.chunks) |chunk| {
            if (chunk.state != .loaded and chunk.state != .building) continue;
            if (math.length(math.sub(chunk.center(), eye)) > 150) continue;
            const low = chunk.origin();
            try list.box3d(low, math.add(low, .{ chunk_size, chunk_size, chunk_size }), 1.5, if (chunk.state == .loaded) gfx.Color.rgba(255, 210, 63, 160) else gfx.Color.rgba(255, 90, 90, 220));
        };
        const stats = renderer.getStats();
        const voxels = world.buried_voxels + world.counted_voxels;
        try list.rect(.{ .x = 12, .y = 12, .width = 500, .height = 172 }, gfx.Color.rgba(8, 10, 18, 190));
        try list.text(font, if (world.counted_chunks == world.chunks.len)
            try std.fmt.bufPrint(&text, "Limn · {d:.1} million voxel world", .{@as(f64, @floatFromInt(voxels)) / 1e6})
        else
            try std.fmt.bufPrint(&text, "Limn · {d:.1} million voxels counted so far", .{@as(f64, @floatFromInt(voxels)) / 1e6}), .{ 24, 20 }, .{ .size = 22 });
        try list.text(font, try std.fmt.bufPrint(&text, "{d} of {d} chunks loaded · {d} to come · {d} being built\n{d}k triangles · {d} meshlets drawn of {d}\n{d} indirect draws · {d:.1} ms GPU · {d:.2} ms CPU · {d:.0} fps", .{
            world.loaded, world.chunks.len, waiting, world.in_flight, stats.triangles / 1000, stats.meshlets_drawn, stats.meshlets, stats.indirect_draws, stage.gpu_ms, stats.cpu_ms, stage.fps,
        }), .{ 24, 52 }, .{ .size = 15 });
        try list.text(font, try std.fmt.bufPrint(&text, "Space {s} · B chunk edges · Tab {s} · P streaming {s} · hold T sun", .{
            if (by_hand) "flight (WASD QE, mouse)" else "fly by hand",
            switch (debug_view) {
                .meshlets => "meshlets",
                .triangles => "triangles",
                else => "lit",
            },
            if (streaming) "on" else "off",
        }), .{ 24, 126 }, .{ .size = 13, .color = gfx.Color.hex(0x9aa7d0) });
        try list.text(font, try std.fmt.bufPrint(&text, "altitude {d:.0} voxels", .{math.length(eye) - planet_radius}), .{ 24, 150 }, .{ .size = 13, .color = gfx.Color.hex(0x9aa7d0) });

        try stage.end(try renderer.render(.{
            .views = &.{.{
                .scene = scene,
                .camera = .{ .position = eye, .forward = forward, .up = up, .near = 0.5 },
                .draw_lists = &.{&list},
                .target = stage.target(),
                .settings = .{
                    .shadow_distance = 420,
                    .shadow_softness = 0.25,
                    .global_illumination = false,
                    .automatic_exposure = false,
                    .aerial_perspective = 0.0002,
                    .debug_view = debug_view,
                },
            }},
            .delta_time = tick.dt,
        }));
    }
    world.group.await(init.io) catch {};
    try stage.finish();
}

/// Where the flight round the planet is after `round` radians, and which
/// way it looks: ahead and down at the ground. It rises and dips as it
/// goes, unless told how high to stay.
fn flight(round: f32, height: ?f32) [2]math.Vec3 {
    const altitude = planet_radius + (height orelse 62 + @sin(round * 0.7) * 22);
    const outward = math.normalize(math.Vec3{ @cos(round), 0.45 * @sin(round * 0.6), @sin(round) });
    const ahead = math.normalize(math.Vec3{ @cos(round + 0.05), 0.45 * @sin((round + 0.05) * 0.6), @sin(round + 0.05) });
    const along = math.normalize(math.sub(ahead, outward));
    const down = 0.8 + 2.5 * (altitude - planet_radius) / planet_radius;
    return .{ math.scale(outward, altitude), math.normalize(math.sub(along, math.scale(outward, down))) };
}
