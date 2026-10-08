//! A belt of asteroids around a planet, drawn by the GPU from start to end.
//!
//! The rocks are instance groups: their transforms are handed over once and
//! live on the GPU from then on. Every frame a compute pass tests each rock
//! against the camera's frustum and against what the frame has already
//! drawn, picks its level of detail, and writes the draw commands of what
//! is left into a buffer; the frame then draws that buffer with a handful
//! of indirect draws whose count the GPU fills in. Nothing on the CPU
//! walks the rocks, so the CPU time on screen stays where it is whether
//! the belt holds a hundred thousand or four million.
//!
//!   Up/Down  double or halve the number of rocks
//!   O        occlusion culling on and off
//!   L        levels of detail on and off
//!   S        shadows on and off
//!   I        far rocks as impostors (cards with a picture of the rock)
//!   Tab      a color per meshlet, to see the levels of detail change
//!   Space    stop and resume the flight
//!   A/D      look left and right of where the flight goes
//!
//! `--count N` starts with N rocks, `--impostors 1` with impostors on. `--frames N`, `--screenshot file.png`.
const std = @import("std");
const gfx = @import("limn");
const math = gfx.math;
const glfw = @import("glfw");
const window = @import("window");
const Stage = window.Stage;

const planet_radius = 2600.0;
const belt_inner = 4200.0;
const belt_outer = 9800.0;
const belt_thickness = 260.0;
/// A rock smaller than this many pixels across is drawn as its impostor,
/// when those are on.
const impostor_pixels = 14.0;

/// A rock's shape: a ball of triangles, each corner pushed in or out.
const Shape = struct {
    positions: [][3]f32,
    indices: []u32,

    /// A twenty-sided ball with every triangle split into four `splits`
    /// times, then made lumpy.
    fn create(gpa: std.mem.Allocator, splits: u32, seed: u64) !Shape {
        const t = (1.0 + @sqrt(5.0)) / 2.0;
        var positions: std.ArrayList([3]f32) = .empty;
        errdefer positions.deinit(gpa);
        var indices: std.ArrayList(u32) = .empty;
        errdefer indices.deinit(gpa);
        try positions.appendSlice(gpa, &.{
            .{ -1, t, 0 }, .{ 1, t, 0 }, .{ -1, -t, 0 }, .{ 1, -t, 0 },
            .{ 0, -1, t }, .{ 0, 1, t }, .{ 0, -1, -t }, .{ 0, 1, -t },
            .{ t, 0, -1 }, .{ t, 0, 1 }, .{ -t, 0, -1 }, .{ -t, 0, 1 },
        });
        try indices.appendSlice(gpa, &.{
            0, 11, 5, 0, 5,  1,  0,  1,  7,  0,  7, 10, 0, 10, 11,
            1, 5,  9, 5, 11, 4,  11, 10, 2,  10, 7, 6,  7, 1,  8,
            3, 9,  4, 3, 4,  2,  3,  2,  6,  3,  6, 8,  3, 8,  9,
            4, 9,  5, 2, 4,  11, 6,  2,  10, 8,  6, 7,  9, 8,  1,
        });
        var midpoints: std.AutoHashMap(u64, u32) = .init(gpa);
        defer midpoints.deinit();
        for (0..splits) |_| {
            midpoints.clearRetainingCapacity();
            var next: std.ArrayList(u32) = .empty;
            errdefer next.deinit(gpa);
            var triangle: usize = 0;
            while (triangle < indices.items.len) : (triangle += 3) {
                const corners = indices.items[triangle..][0..3].*;
                var middles: [3]u32 = undefined;
                for (0..3) |edge| {
                    const a = corners[edge];
                    const b = corners[(edge + 1) % 3];
                    const key = (@as(u64, @min(a, b)) << 32) | @max(a, b);
                    const entry = try midpoints.getOrPut(key);
                    if (!entry.found_existing) {
                        entry.value_ptr.* = @intCast(positions.items.len);
                        try positions.append(gpa, math.scale(math.add(positions.items[a], positions.items[b]), 0.5));
                    }
                    middles[edge] = entry.value_ptr.*;
                }
                try next.appendSlice(gpa, &.{
                    corners[0], middles[0], middles[2],
                    corners[1], middles[1], middles[0],
                    corners[2], middles[2], middles[1],
                    middles[0], middles[1], middles[2],
                });
            }
            indices.deinit(gpa);
            indices = next;
        }
        var random = std.Random.DefaultPrng.init(seed);
        const rng = random.random();
        const stretch = [3]f32{ 0.7 + rng.float(f32) * 0.6, 0.6 + rng.float(f32) * 0.5, 0.7 + rng.float(f32) * 0.6 };
        const phase = [3]f32{ rng.float(f32) * 9, rng.float(f32) * 9, rng.float(f32) * 9 };
        for (positions.items) |*position| {
            const unit = math.normalize(position.*);
            var height: f32 = 1;
            var frequency: f32 = 1.7;
            var amplitude: f32 = 0.22;
            for (0..4) |_| {
                height += amplitude * @sin(unit[0] * frequency + phase[0]) * @sin(unit[1] * frequency + phase[1]) * @sin(unit[2] * frequency + phase[2]);
                frequency *= 2.1;
                amplitude *= 0.5;
            }
            position.* = .{ unit[0] * height * stretch[0], unit[1] * height * stretch[1], unit[2] * height * stretch[2] };
        }
        return .{ .positions = try positions.toOwnedSlice(gpa), .indices = try indices.toOwnedSlice(gpa) };
    }

    fn deinit(self: Shape, gpa: std.mem.Allocator) void {
        gpa.free(self.positions);
        gpa.free(self.indices);
    }
};

/// How many rocks of a kind a belt of `count` rocks holds.
fn shareOf(kind: Kind, count: usize) usize {
    return @intFromFloat(@as(f64, @floatFromInt(count)) * kind.share);
}

/// The kinds of rock in the belt: how finely each is modelled, how large
/// its copies are, and what share of the belt is of that kind. Most of the
/// belt is gravel of a hundred triangles or so; the few boulders are
/// modelled finely enough for their levels of detail to matter.
const Kind = struct {
    splits: u32,
    size: [2]f32,
    share: f32,
    color: [4]f32,
};

const kinds = [_]Kind{
    .{ .splits = 1, .size = .{ 0.6, 3.5 }, .share = 0.475, .color = .{ 0.36, 0.33, 0.30, 1 } },
    .{ .splits = 1, .size = .{ 0.6, 3.5 }, .share = 0.475, .color = .{ 0.28, 0.27, 0.27, 1 } },
    .{ .splits = 2, .size = .{ 4, 14 }, .share = 0.045, .color = .{ 0.40, 0.34, 0.27, 1 } },
    .{ .splits = 4, .size = .{ 18, 70 }, .share = 0.0048, .color = .{ 0.33, 0.31, 0.29, 1 } },
    .{ .splits = 5, .size = .{ 90, 240 }, .share = 0.0002, .color = .{ 0.30, 0.28, 0.27, 1 } },
};

/// Where the flight is after going `along` radians round the planet, as
/// its distance from the planet's axis and its height in the belt. It
/// weaves in and out and up and down, and comes round to where it began.
fn flightPath(along: f32) [2]f32 {
    return .{
        (belt_inner + belt_outer) * 0.5 + @sin(along * 3) * (belt_outer - belt_inner) * 0.3,
        @sin(along * 5) * belt_thickness * 0.5,
    };
}

/// Fills `transforms` with rocks of one kind, scattered through the belt.
fn scatter(transforms: []math.Mat4, kind: Kind, seed: u64) void {
    var random = std.Random.DefaultPrng.init(seed);
    const rng = random.random();
    for (transforms) |*transform| {
        const size = kind.size[0] + (kind.size[1] - kind.size[0]) * std.math.pow(f32, rng.float(f32), 3);
        var radius: f32 = 0;
        var angle: f32 = 0;
        var height: f32 = 0;
        while (true) {
            radius = @sqrt(belt_inner * belt_inner + rng.float(f32) * (belt_outer * belt_outer - belt_inner * belt_inner));
            angle = rng.float(f32) * std.math.tau;
            height = (rng.float(f32) + rng.float(f32) + rng.float(f32) - 1.5) * belt_thickness;
            const path = flightPath(angle);
            if (@abs(radius - path[0]) > size * 1.5 + 6 or @abs(height - path[1]) > size * 1.5 + 6) break;
        }
        const turn = math.mul(math.rotationY(rng.float(f32) * std.math.tau), math.rotationX(rng.float(f32) * std.math.tau));
        transform.* = math.mul(math.translation(.{ @cos(angle) * radius, height, @sin(angle) * radius }), math.mul(turn, math.uniformScaling(size)));
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var count: usize = 1_000_000;
    var impostors = false;
    {
        var arguments = try init.minimal.args.iterateAllocator(gpa);
        defer arguments.deinit();
        while (arguments.next()) |argument| {
            if (std.mem.eql(u8, argument, "--count")) count = try std.fmt.parseInt(usize, arguments.next() orelse return error.MissingArgument, 10);
            if (std.mem.eql(u8, argument, "--impostors")) impostors = true;
        }
    }
    const max_count = 4_000_000;
    count = std.math.clamp(count, 1000, max_count);

    var stage = try Stage.create(init, "Limn asteroids", .{});
    const renderer = stage.renderer;
    const scene = try renderer.createScene();
    const sun_direction = math.normalize(math.Vec3{ -0.55, -0.35, -0.6 });
    renderer.setSun(scene, .{ .direction = sun_direction, .color = .{ 1, 0.96, 0.9 }, .intensity = 6 });
    const environment = try renderer.createSky(.{ .sun_direction = .{ 0, 1, 0 }, .stars = 40 });
    renderer.setEnvironment(scene, environment, 0.35);

    var models: [kinds.len]gfx.Model = undefined;
    for (kinds, &models, 0..) |kind, *model, index| {
        const shape = try Shape.create(gpa, kind.splits, 17 + index);
        defer shape.deinit(gpa);
        model.* = try renderer.createModel(&.{.{
            .positions = shape.positions,
            .indices = shape.indices,
            .material = .{ .base_color = kind.color, .metallic = 0, .roughness = 0.95 },
        }});
    }
    const planet = planet: {
        const positions = try gpa.create([window.sphere_vertex_count][3]f32);
        defer gpa.destroy(positions);
        const normals = try gpa.create([window.sphere_vertex_count][3]f32);
        defer gpa.destroy(normals);
        const indices = try gpa.create([window.sphere_index_count]u32);
        defer gpa.destroy(indices);
        window.sphereMesh(planet_radius, positions, normals, indices);
        break :planet try renderer.createModel(&.{.{
            .positions = positions,
            .normals = normals,
            .indices = indices,
            .material = .{ .base_color = .{ 0.62, 0.45, 0.30, 1 }, .metallic = 0, .roughness = 0.85 },
        }});
    };
    _ = try renderer.spawn(scene, .{ .model = planet, .transform = math.identity });
    try renderer.waitUntilLoaded();

    const transforms = try gpa.alloc(math.Mat4, max_count);
    defer gpa.free(transforms);
    var groups: [kinds.len]gfx.InstanceGroup = undefined;
    var placed: usize = 0;
    for (kinds, models, &groups, 0..) |kind, model, *group, index| {
        const share = shareOf(kind, count);
        scatter(transforms[0..share], kind, 100 + index);
        group.* = try renderer.createInstances(scene, model, transforms[0..share]);
        placed += share;
    }

    if (impostors) for (groups) |group| try renderer.setInstancesImpostor(group, .{ .pixels = impostor_pixels });

    var list = gfx.DrawList.init(gpa);
    defer list.deinit();
    const font = renderer.defaultFont();
    var occlusion = true;
    var detail = true;
    var shadows = true;
    var meshlet_view = false;
    var flying = true;
    var along: f32 = 0.4;
    var look: f32 = 0;
    var text: [256]u8 = undefined;
    var out_of_memory = false;
    var memory_limit: ?usize = null;

    while (stage.begin()) |tick| {
        var resize: ?usize = null;
        if (stage.keyPressed(glfw.GLFW_KEY_UP) and count < (memory_limit orelse max_count)) resize = @min(count * 2, memory_limit orelse max_count);
        if (stage.keyPressed(glfw.GLFW_KEY_DOWN) and count > 1000) resize = count / 2;
        if (out_of_memory) {
            out_of_memory = false;
            memory_limit = count / 2;
            resize = count / 2;
        }
        if (resize) |wanted| {
            count = wanted;
            placed = 0;
            for (kinds, groups, 0..) |kind, group, index| {
                const share = shareOf(kind, count);
                scatter(transforms[0..share], kind, 100 + index);
                try renderer.setInstances(group, transforms[0..share]);
                placed += share;
            }
        }
        if (stage.keyPressed(glfw.GLFW_KEY_O)) occlusion = !occlusion;
        if (stage.keyPressed(glfw.GLFW_KEY_L)) detail = !detail;
        if (stage.keyPressed(glfw.GLFW_KEY_S)) shadows = !shadows;
        if (stage.keyPressed(glfw.GLFW_KEY_I)) {
            impostors = !impostors;
            for (groups) |group| try renderer.setInstancesImpostor(group, if (impostors) .{ .pixels = impostor_pixels } else null);
        }
        if (stage.keyPressed(glfw.GLFW_KEY_TAB)) meshlet_view = !meshlet_view;
        if (stage.keyPressed(glfw.GLFW_KEY_SPACE)) flying = !flying;
        if (stage.keyDown(glfw.GLFW_KEY_A)) look += tick.dt * 0.9;
        if (stage.keyDown(glfw.GLFW_KEY_D)) look -= tick.dt * 0.9;
        if (flying) along += tick.dt * 0.012;

        const path = flightPath(along);
        const ahead = flightPath(along + 0.02);
        const eye = math.Vec3{ @cos(along) * path[0], path[1], @sin(along) * path[0] };
        const target = math.Vec3{ @cos(along + 0.02) * ahead[0], ahead[1], @sin(along + 0.02) * ahead[0] };
        const toward = math.normalize(math.sub(target, eye));
        const forward = math.Vec3{ toward[0] * @cos(look) - toward[2] * @sin(look), toward[1], toward[0] * @sin(look) + toward[2] * @cos(look) };

        const stats = renderer.getStats();
        list.clear();
        try list.rect(.{ .x = 12, .y = 12, .width = 500, .height = 170 }, gfx.Color.rgba(8, 10, 18, 190));
        try list.text(font, try std.fmt.bufPrint(&text, "{d} objects", .{placed + 1}), .{ 24, 20 }, .{ .size = 22 });
        try list.text(font, try std.fmt.bufPrint(&text, "{d} visible · {d} meshlets drawn of {d}\n{d} indirect draws · 0 draw calls per object · {d} million triangles\n{d:.1} ms GPU · {d:.2} ms CPU · {d:.0} fps", .{
            stats.instances_drawn, stats.meshlets_drawn, stats.meshlets, stats.indirect_draws, stats.triangles / 1_000_000, stage.gpu_ms, stats.cpu_ms, stage.fps,
        }), .{ 24, 52 }, .{ .size = 15 });
        const rows = [_]struct { key: []const u8, label: []const u8, on: bool }{
            .{ .key = "O", .label = "occlusion culling", .on = occlusion },
            .{ .key = "L", .label = "levels of detail", .on = detail },
            .{ .key = "S", .label = "shadows", .on = shadows },
            .{ .key = "I", .label = "impostors", .on = impostors },
        };
        for (rows, 0..) |row, index| {
            const x = 24 + @as(f32, @floatFromInt(index)) * 118;
            try list.text(font, row.key, .{ x, 124 }, .{ .size = 14, .color = gfx.Color.hex(0x9aa7d0) });
            try list.text(font, row.label, .{ x + 16, 124 }, .{ .size = 14, .color = if (row.on) gfx.Color.hex(0x3ddc97) else gfx.Color.hex(0x7c8499) });
        }
        try list.text(font, if (memory_limit) |limit| try std.fmt.bufPrint(&text, "The GPU's memory holds no more than about {d} here", .{limit}) else "Up/Down count · Tab meshlets · Space stop · A/D look", .{ 24, 152 }, .{ .size = 13, .color = gfx.Color.hex(0x9aa7d0) });

        const presented = renderer.render(.{
            .views = &.{.{
                .scene = scene,
                .camera = .{ .position = eye, .forward = forward, .near = 0.5 },
                .draw_lists = &.{&list},
                .target = stage.target(),
                .settings = .{
                    .occlusion_culling = occlusion,
                    .lod_error_pixels = if (detail) 1 else 0,
                    .shadows = shadows,
                    .shadow_distance = 1500,
                    .global_illumination = false,
                    .ambient_occlusion = false,
                    .automatic_exposure = false,
                    .debug_view = if (meshlet_view) .meshlets else .none,
                },
            }},
            .delta_time = tick.dt,
        }) catch |failure| switch (failure) {
            error.OutOfDeviceMemory, error.OutOfMemory => out_of_memory: {
                if (count <= 1000) return failure;
                out_of_memory = true;
                break :out_of_memory false;
            },
            else => return failure,
        };
        try stage.end(presented);
    }
    try stage.finish();
}
