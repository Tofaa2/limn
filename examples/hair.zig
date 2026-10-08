//! Hair that hangs, swings and blows about: ten thousand strands on a
//! head that turns from side to side.
//!
//! The strands are moved on the GPU (`HairDesc.simulation`): each is a
//! chain that hangs from its root, keeps its length, is drawn back toward
//! how it was combed, and stays out of a few spheres that stand in for
//! the head, the neck and the shoulders.
//!
//! The hair and the head are Cem Yuksel's, which are free to download and
//! are not kept with these sources:
//!
//!   www.cemyuksel.com/research/hairmodels
//!
//! Put `wWavyThin.hair` and `woman.obj` (from `woman.zip`) in
//! `examples/assets/hair/`, or name others with `--model file.hair` and
//! `--head file.obj`. Without them the example combs a head of hair of
//! its own onto a ball.
//!
//!   H        the head turns, or holds still
//!   W        wind on and off
//!   S        the strands move, or stay as they were combed
//!   A/D      orbit the camera
//!
//! `--wind 1` starts with the wind on, `--still 1` with the head still.
//! `--frames N`, `--screenshot file.png`.
const std = @import("std");
const gfx = @import("limn");
const math = gfx.math;
const glfw = @import("glfw");
const window = @import("window");
const Stage = window.Stage;

/// Points every strand is drawn and moved with, whatever it came with.
const points_per_strand = 20;
/// World units to one of the hair files' (about a centimetre): the head
/// comes out twice life size, which leaves the strands room on screen.
const scale = 0.004;
const head_height = 1.5;

/// Spheres that stand in for the head the hair files were combed on: the
/// skull, the neck, the shoulders and the chest, in the files' own space
/// (z up).
const body = [_][4]f32{
    .{ -4, 0, 27, 34 },
    .{ -6, 0, -6, 22 },
    .{ -20, 30, -50, 24 },
    .{ -20, -30, -50, 24 },
    .{ -16, 0, -52, 28 },
};

fn readFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const bytes = try gpa.alloc(u8, @intCast(stat.size));
    errdefer gpa.free(bytes);
    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    try reader.interface.readSliceAll(bytes);
    return bytes;
}

/// `count` points spread evenly along a strand of any number of points.
fn resample(strand: []const [3]f32, out: [][3]f32) void {
    var total: f32 = 0;
    for (strand[1..], strand[0 .. strand.len - 1]) |point, before| total += math.length(math.sub(point, before));
    var stretch: usize = 0;
    var passed: f32 = 0;
    for (out, 0..) |*point, index| {
        const wanted = total * @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(out.len - 1));
        while (stretch + 2 < strand.len and passed + math.length(math.sub(strand[stretch + 1], strand[stretch])) < wanted) {
            passed += math.length(math.sub(strand[stretch + 1], strand[stretch]));
            stretch += 1;
        }
        const length = math.length(math.sub(strand[stretch + 1], strand[stretch]));
        const along = if (length > 1e-9) std.math.clamp((wanted - passed) / length, 0, 1) else 0;
        point.* = math.add(strand[stretch], math.scale(math.sub(strand[stretch + 1], strand[stretch]), along));
    }
}

/// Reads a HAIR file (the format is described on the page the files come
/// from) into strands of `points_per_strand` points each.
fn loadHair(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![][3]f32 {
    const bytes = try readFile(gpa, io, path);
    defer gpa.free(bytes);
    if (bytes.len < 128 or !std.mem.eql(u8, bytes[0..4], "HAIR")) return error.NotAHairFile;
    const strand_count = std.mem.readInt(u32, bytes[4..8], .little);
    const point_count = std.mem.readInt(u32, bytes[8..12], .little);
    const arrays = std.mem.readInt(u32, bytes[12..16], .little);
    const default_segments = std.mem.readInt(u32, bytes[16..20], .little);
    if (arrays & 2 == 0) return error.HairWithoutPoints;
    var offset: usize = 128;
    const has_segments = arrays & 1 != 0;
    const segments_at = offset;
    if (has_segments) offset += @as(usize, strand_count) * 2;
    if (bytes.len < offset + @as(usize, point_count) * 12) return error.HairFileTooShort;

    const out = try gpa.alloc([3]f32, @as(usize, strand_count) * points_per_strand);
    errdefer gpa.free(out);
    var strand_points: std.ArrayList([3]f32) = .empty;
    defer strand_points.deinit(gpa);
    var point: usize = 0;
    for (0..strand_count) |strand| {
        const segments: usize = if (has_segments) std.mem.readInt(u16, bytes[segments_at + strand * 2 ..][0..2], .little) else default_segments;
        if (point + segments + 1 > point_count or segments == 0) return error.HairFileTooShort;
        strand_points.clearRetainingCapacity();
        for (0..segments + 1) |index| {
            const at = offset + (point + index) * 12;
            try strand_points.append(gpa, .{
                @bitCast(std.mem.readInt(u32, bytes[at..][0..4], .little)),
                @bitCast(std.mem.readInt(u32, bytes[at + 4 ..][0..4], .little)),
                @bitCast(std.mem.readInt(u32, bytes[at + 8 ..][0..4], .little)),
            });
        }
        point += segments + 1;
        resample(strand_points.items, out[strand * points_per_strand ..][0..points_per_strand]);
    }
    return out;
}

/// A head of hair to go on the first of `body`'s spheres: strands that
/// leave the top of it and fall round it.
fn combHair(gpa: std.mem.Allocator, strand_count: usize) ![][3]f32 {
    const out = try gpa.alloc([3]f32, strand_count * points_per_strand);
    var random = std.Random.DefaultPrng.init(3);
    const rng = random.random();
    const skull = body[0];
    for (0..strand_count) |strand| {
        const height = 1 - rng.float(f32) * 1.15;
        const turn = rng.float(f32) * std.math.tau;
        const ring = @sqrt(@max(1 - height * height, 0));
        const out_from = math.Vec3{ ring * @cos(turn), ring * @sin(turn), height };
        const length = 55 + rng.float(f32) * 25;
        for (0..points_per_strand) |index| {
            const along = @as(f32, @floatFromInt(index)) / (points_per_strand - 1);
            var point = math.add(skull[0..3].*, math.scale(out_from, skull[3] * (1.01 + along * 0.25)));
            point[2] -= along * along * length;
            out[strand * points_per_strand + index] = point;
        }
    }
    return out;
}

const Mesh = struct {
    positions: [][3]f32,
    indices: []u32,

    fn deinit(self: Mesh, gpa: std.mem.Allocator) void {
        gpa.free(self.positions);
        gpa.free(self.indices);
    }
};

/// The positions and faces of a Wavefront OBJ file; faces of more than
/// three corners are cut into triangles.
fn loadObj(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !Mesh {
    const text = try readFile(gpa, io, path);
    defer gpa.free(text);
    var positions: std.ArrayList([3]f32) = .empty;
    errdefer positions.deinit(gpa);
    var indices: std.ArrayList(u32) = .empty;
    errdefer indices.deinit(gpa);
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |line| {
        var words = std.mem.tokenizeAny(u8, line, " \t");
        const kind = words.next() orelse continue;
        if (std.mem.eql(u8, kind, "v")) {
            var position: [3]f32 = undefined;
            for (&position) |*value| value.* = try std.fmt.parseFloat(f32, words.next() orelse return error.InvalidObj);
            try positions.append(gpa, position);
        } else if (std.mem.eql(u8, kind, "f")) {
            var corners: [2]u32 = undefined;
            var count: usize = 0;
            while (words.next()) |word| {
                const number = try std.fmt.parseInt(i64, word[0 .. std.mem.indexOfScalar(u8, word, '/') orelse word.len], 10);
                const index: u32 = @intCast(if (number < 0) @as(i64, @intCast(positions.items.len)) + number else number - 1);
                if (count >= 2) {
                    try indices.appendSlice(gpa, &.{ corners[0], corners[1], index });
                    corners[1] = index;
                } else corners[count] = index;
                count += 1;
            }
        }
    }
    if (positions.items.len == 0 or indices.items.len == 0) return error.InvalidObj;
    return .{ .positions = try positions.toOwnedSlice(gpa), .indices = try indices.toOwnedSlice(gpa) };
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var hair_path: []const u8 = "examples/assets/hair/wWavyThin.hair";
    var head_path: []const u8 = "examples/assets/hair/woman.obj";
    var windy = false;
    var turning = true;
    var arguments = try init.minimal.args.iterateAllocator(gpa);
    defer arguments.deinit();
    while (arguments.next()) |argument| {
        if (std.mem.eql(u8, argument, "--model")) hair_path = arguments.next() orelse return error.MissingArgument;
        if (std.mem.eql(u8, argument, "--head")) head_path = arguments.next() orelse return error.MissingArgument;
        if (std.mem.eql(u8, argument, "--wind")) windy = true;
        if (std.mem.eql(u8, argument, "--still")) turning = false;
    }

    var stage = try Stage.create(init, "Limn hair", .{});
    const renderer = stage.renderer;
    const scene = try renderer.createScene();
    const sky = gfx.SkyDesc{ .sun_direction = .{ -0.5, -0.75, -0.45 } };
    renderer.setSun(scene, gfx.skySun(sky));
    renderer.setEnvironment(scene, try renderer.createSky(sky), 1);

    var ground_positions: [24][3]f32 = undefined;
    var ground_indices: [36]u32 = undefined;
    window.boxMesh(.{ 6, 0.05, 6 }, &ground_positions, &ground_indices);
    const ground = try renderer.createModel(&.{.{
        .positions = &ground_positions,
        .indices = &ground_indices,
        .material = .{ .base_color = .{ 0.35, 0.36, 0.38, 1 }, .metallic = 0, .roughness = 0.8 },
    }});
    _ = try renderer.spawn(scene, .{ .model = ground, .transform = math.translation(.{ 0, -0.05, 0 }) });

    var from_file = true;
    const points = loadHair(gpa, init.io, hair_path) catch |failure| made: {
        std.log.info("{s}: {}; combing a head of hair instead", .{ hair_path, failure });
        from_file = false;
        break :made try combHair(gpa, 8000);
    };
    defer gpa.free(points);
    var head_field: ?gfx.CollisionField = null;
    const skin = gfx.Material{ .base_color = .{ 0.78, 0.60, 0.50, 1 }, .metallic = 0, .roughness = 0.6 };
    const head = head: {
        if (from_file) if (loadObj(gpa, init.io, head_path)) |mesh| {
            defer mesh.deinit(gpa);
            head_field = try renderer.createCollisionField(mesh.positions, mesh.indices, 64);
            break :head try renderer.createModel(&.{.{ .positions = mesh.positions, .indices = mesh.indices, .material = skin }});
        } else |failure| std.log.info("{s}: {}; a ball for a head instead", .{ head_path, failure });
        const ball_positions = try gpa.create([window.sphere_vertex_count][3]f32);
        defer gpa.destroy(ball_positions);
        const ball_normals = try gpa.create([window.sphere_vertex_count][3]f32);
        defer gpa.destroy(ball_normals);
        const ball_indices = try gpa.create([window.sphere_index_count]u32);
        defer gpa.destroy(ball_indices);
        window.sphereMesh(body[0][3], ball_positions, ball_normals, ball_indices);
        for (ball_positions) |*position| position.* = math.add(position.*, body[0][0..3].*);
        break :head try renderer.createModel(&.{.{ .positions = ball_positions, .normals = ball_normals, .indices = ball_indices, .material = skin }});
    };
    try renderer.waitUntilLoaded();

    const upright = math.mul(math.rotationX(-std.math.pi * 0.5), math.uniformScaling(scale));
    var placement = math.mul(math.translation(.{ 0, head_height, 0 }), upright);
    const head_entity = try renderer.spawn(scene, .{ .model = head, .transform = placement });
    var simulation = gfx.HairSimulation{};
    const hair = try renderer.createHair(scene, .{
        .points = points,
        .points_per_strand = points_per_strand,
        .transform = placement,
        .width = 0.26,
        .taper = 0.7,
        .copies = 4,
        .spread = 0.7,
        .root_color = .{ 0.16, 0.10, 0.05 },
        .tip_color = .{ 0.36, 0.25, 0.14 },
        .simulation = simulation,
    });

    var list = gfx.DrawList.init(gpa);
    defer list.deinit();
    const font = renderer.defaultFont();
    var text: [200]u8 = undefined;
    var moving = true;
    var orbit: f32 = 0.9;
    var turned: f32 = 0;
    var turn_time: f32 = 0;

    while (stage.begin()) |tick| {
        if (stage.keyPressed(glfw.GLFW_KEY_H)) turning = !turning;
        if (stage.keyPressed(glfw.GLFW_KEY_W)) windy = !windy;
        if (stage.keyPressed(glfw.GLFW_KEY_S)) moving = !moving;
        if (stage.keyDown(glfw.GLFW_KEY_A)) orbit -= tick.dt * 0.9;
        if (stage.keyDown(glfw.GLFW_KEY_D)) orbit += tick.dt * 0.9;

        if (turning) turn_time += tick.dt;
        turned = @sin(turn_time * 1.6) * 0.9;
        placement = math.mul(math.translation(.{ 0, head_height, 0 }), math.mul(math.rotationY(turned), upright));
        renderer.setTransform(head_entity, placement);
        renderer.setHairTransform(hair, placement);
        var colliders: [body.len][4]f32 = undefined;
        for (body, &colliders) |sphere, *collider| {
            const center = math.transformPoint(placement, sphere[0..3].*);
            collider.* = .{ center[0], center[1], center[2], sphere[3] * scale * 1.03 };
        }
        simulation.colliders = if (head_field == null) &colliders else &.{};
        simulation.field = head_field;
        simulation.field_transform = placement;
        simulation.wind = if (windy) .{ -4.5, 0.6, 2 } else .{ 0, 0, 0 };
        renderer.setHairSimulation(hair, if (moving) simulation else null);

        const stats = renderer.getStats();
        list.clear();
        try list.rect(.{ .x = 12, .y = 12, .width = 600, .height = 104 }, gfx.Color.rgba(8, 10, 18, 190));
        try list.text(font, try std.fmt.bufPrint(&text, "{d} strands moved on the GPU, each drawn 4 times · {d} points\n{d:.1} ms GPU · {d:.2} ms CPU · {d:.0} fps", .{
            points.len / points_per_strand, points.len, stage.gpu_ms, stats.cpu_ms, stage.fps,
        }), .{ 24, 20 }, .{ .size = 16 });
        const rows = [_]struct { key: []const u8, label: []const u8, on: bool }{
            .{ .key = "H", .label = "head turns", .on = turning },
            .{ .key = "W", .label = "wind", .on = windy },
            .{ .key = "S", .label = "strands move", .on = moving },
        };
        for (rows, 0..) |row, index| {
            const x = 24 + @as(f32, @floatFromInt(index)) * 140;
            try list.text(font, row.key, .{ x, 66 }, .{ .size = 14, .color = gfx.Color.hex(0x9aa7d0) });
            try list.text(font, row.label, .{ x + 18, 66 }, .{ .size = 14, .color = if (row.on) gfx.Color.hex(0x3ddc97) else gfx.Color.hex(0x7c8499) });
        }
        try list.text(font, if (from_file) "Hair and head: www.cemyuksel.com/research/hairmodels" else "A/D orbit · see the top of examples/hair.zig for real hair", .{ 24, 90 }, .{ .size = 13, .color = gfx.Color.hex(0x9aa7d0) });

        const eye = math.Vec3{ @sin(orbit) * 0.72, head_height + 0.1, @cos(orbit) * 0.72 };
        try stage.end(try renderer.render(.{
            .views = &.{.{
                .scene = scene,
                .camera = gfx.Camera.lookAt(eye, .{ 0, head_height + 0.02, 0 }),
                .draw_lists = &.{&list},
                .target = stage.target(),
                .settings = .{ .shadow_distance = 8, .global_illumination = false },
            }},
            .delta_time = tick.dt,
        }));
    }
    try stage.finish();
}
