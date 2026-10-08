//! An open meadow to run through: rolling ground under a computed sky,
//! a hundred and forty thousand tufts of grass and a few hundred trees
//! swaying in the wind, rocks, a pond, clouds, and a few objects that
//! show what the materials can do. All of it is lit by the sun and the
//! sky alone, shadows and bounced light included.
//!
//!   Mouse       look around
//!   W A S D     move, the way the camera faces
//!   Shift       sprint
//!   Space       jump
//!   Z / X       camera closer / farther
//!   T (hold)    move the sun
//!   C           clouds on and off
//!
//! `--frames N`, `--screenshot file.png` (which runs a circle by itself).
const std = @import("std");
const gfx = @import("limn");
const glfw = @import("glfw");
const math = gfx.math;
const helpers = @import("window");
const Stage = helpers.Stage;

/// Width of the ground, in meters.
const field = 120.0;
const pond_center = [2]f32{ 16, -12 };
const pond_radius = 7.5;
const grass_count = 140_000;
const tree_count = 260;
const rock_count = 160;

/// Height of the ground at a point: low hills, and a hollow for the pond.
fn groundHeight(x: f32, z: f32) f32 {
    const dx = x - pond_center[0];
    const dz = z - pond_center[1];
    const distance = dx * dx + dz * dz;
    const level = @exp(-distance / (pond_radius * pond_radius * 6.25));
    const hills = hillsAt(x, z) * (1 - level) + hillsAt(pond_center[0], pond_center[1]) * level;
    return hills - 2.8 * @exp(-distance / (pond_radius * pond_radius));
}

fn hillsAt(x: f32, z: f32) f32 {
    return 2.4 * @sin(x * 0.043) * @cos(z * 0.037) + 1.1 * @sin(x * 0.11 + 1.7) * @sin(z * 0.093) + 0.3 * @sin(x * 0.29 + z * 0.23);
}

const pond_level = -1.15;

fn nearPond(x: f32, z: f32, margin: f32) bool {
    const dx = x - pond_center[0];
    const dz = z - pond_center[1];
    return dx * dx + dz * dz < (pond_radius + margin) * (pond_radius + margin);
}

/// A mesh being put together: triangles with a color at every corner.
const Shape = struct {
    positions: std.ArrayList([3]f32) = .empty,
    normals: std.ArrayList([3]f32) = .empty,
    colors: std.ArrayList([4]f32) = .empty,
    indices: std.ArrayList(u32) = .empty,

    fn deinit(self: *Shape, gpa: std.mem.Allocator) void {
        self.positions.deinit(gpa);
        self.normals.deinit(gpa);
        self.colors.deinit(gpa);
        self.indices.deinit(gpa);
    }

    fn vertex(self: *Shape, gpa: std.mem.Allocator, position: [3]f32, normal: [3]f32, color: [3]f32) !u32 {
        try self.positions.append(gpa, position);
        try self.normals.append(gpa, math.normalize(normal));
        try self.colors.append(gpa, .{ color[0], color[1], color[2], 1 });
        return @intCast(self.positions.items.len - 1);
    }

    fn triangle(self: *Shape, gpa: std.mem.Allocator, a: u32, b: u32, c: u32) !void {
        try self.indices.appendSlice(gpa, &.{ a, b, c });
    }

    /// A ring of sides narrowing from one radius to another: a trunk, or
    /// with a top radius of nothing, a cone.
    fn taper(self: *Shape, gpa: std.mem.Allocator, bottom: f32, top: f32, low_radius: f32, high_radius: f32, sides: u32, low_color: [3]f32, high_color: [3]f32) !void {
        const first: u32 = @intCast(self.positions.items.len);
        for (0..sides + 1) |side| {
            const angle = @as(f32, @floatFromInt(side)) / @as(f32, @floatFromInt(sides)) * std.math.tau;
            const out = [3]f32{ @cos(angle), (low_radius - high_radius) / @max(top - bottom, 1e-3), @sin(angle) };
            _ = try self.vertex(gpa, .{ @cos(angle) * low_radius, bottom, @sin(angle) * low_radius }, out, low_color);
            _ = try self.vertex(gpa, .{ @cos(angle) * high_radius, top, @sin(angle) * high_radius }, out, high_color);
        }
        for (0..sides) |side| {
            const corner = first + @as(u32, @intCast(side)) * 2;
            try self.triangle(gpa, corner, corner + 1, corner + 2);
            try self.triangle(gpa, corner + 2, corner + 1, corner + 3);
        }
    }

    fn desc(self: *const Shape, material: gfx.Material) gfx.MeshDesc {
        return .{ .positions = self.positions.items, .normals = self.normals.items, .colors = self.colors.items, .indices = self.indices.items, .material = material };
    }
};

/// The ground: a grid over the height function, greener on the flats,
/// earthier on the slopes and sandy by the water.
fn buildGround(gpa: std.mem.Allocator, shape: *Shape) !void {
    const cells = 200;
    for (0..cells + 1) |row| for (0..cells + 1) |column| {
        const x = (@as(f32, @floatFromInt(column)) / cells - 0.5) * field;
        const z = (@as(f32, @floatFromInt(row)) / cells - 0.5) * field;
        const step = 0.4;
        const normal = [3]f32{ groundHeight(x - step, z) - groundHeight(x + step, z), 2 * step, groundHeight(x, z - step) - groundHeight(x, z + step) };
        const slope = 1 - math.normalize(normal)[1];
        const patch = 0.5 + 0.5 * @sin(x * 0.37 + @sin(z * 0.21) * 2.0) * @cos(z * 0.33);
        var color = [3]f32{ 0.07 + 0.05 * patch, 0.17 + 0.07 * patch, 0.04 };
        const earth = std.math.clamp(slope * 9, 0, 1);
        color = .{ color[0] + (0.2 - color[0]) * earth, color[1] + (0.15 - color[1]) * earth, color[2] + (0.09 - color[2]) * earth };
        if (nearPond(x, z, 1.5)) color = .{ 0.33, 0.29, 0.2 };
        _ = try shape.vertex(gpa, .{ x, groundHeight(x, z), z }, normal, color);
    };
    for (0..cells) |row| for (0..cells) |column| {
        const corner: u32 = @intCast(row * (cells + 1) + column);
        try shape.triangle(gpa, corner, corner + cells + 1, corner + 1);
        try shape.triangle(gpa, corner + 1, corner + cells + 1, corner + cells + 2);
    };
}

/// One tuft: a handful of blades leaning out from a point, dark at the
/// root and light at the tip, shaded as if they all faced up so that a
/// field of them reads as one soft surface.
fn buildTuft(gpa: std.mem.Allocator, shape: *Shape, rng: std.Random) !void {
    const root = [3]f32{ 0.05, 0.13, 0.03 };
    const tip = [3]f32{ 0.36, 0.52, 0.14 };
    for (0..12) |_| {
        const turn = rng.float(f32) * std.math.tau;
        const lean = 0.1 + rng.float(f32) * 0.35;
        const height = 0.16 + rng.float(f32) * 0.2;
        const base = [3]f32{ (rng.float(f32) - 0.5) * 0.5, 0, (rng.float(f32) - 0.5) * 0.5 };
        const across = [3]f32{ @cos(turn), 0, @sin(turn) };
        const out = [3]f32{ -@sin(turn), 0, @cos(turn) };
        const normal = [3]f32{ out[0] * 0.35, 1, out[2] * 0.35 };
        var previous: [2]u32 = undefined;
        const levels = 3;
        for (0..levels) |level| {
            const along = @as(f32, @floatFromInt(level)) / levels;
            const half = 0.014 * (1 - along * 0.75);
            const bend = lean * along * along * height;
            const center = [3]f32{ base[0] + out[0] * bend, height * along, base[2] + out[2] * bend };
            const color = [3]f32{ root[0] + (tip[0] - root[0]) * along, root[1] + (tip[1] - root[1]) * along, root[2] + (tip[2] - root[2]) * along };
            const left = try shape.vertex(gpa, .{ center[0] - across[0] * half, center[1], center[2] - across[2] * half }, normal, color);
            const right = try shape.vertex(gpa, .{ center[0] + across[0] * half, center[1], center[2] + across[2] * half }, normal, color);
            if (level != 0) {
                try shape.triangle(gpa, previous[0], previous[1], left);
                try shape.triangle(gpa, previous[1], right, left);
            }
            previous = .{ left, right };
        }
        const top = try shape.vertex(gpa, .{ base[0] + out[0] * lean * height, height, base[2] + out[2] * lean * height }, normal, tip);
        try shape.triangle(gpa, previous[0], previous[1], top);
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var stage = try Stage.create(init, "Limn meadow", .{ .asset_cache_dir = "zig-out/asset-cache" });
    const renderer = stage.renderer;
    const scene = try renderer.createScene();
    var random = std.Random.DefaultPrng.init(7);
    const rng = random.random();

    var sun_height: f32 = 0.62;
    var sky = gfx.SkyDesc{ .sun_direction = .{ -0.55 * @cos(sun_height), -@sin(sun_height), -0.5 } };
    renderer.setSun(scene, gfx.skySun(sky));
    const environment = try renderer.createSky(sky);
    renderer.setEnvironment(scene, environment, 1);
    var clouds_on = true;
    const clouds = gfx.CloudDesc{ .coverage = 0.42, .cirrus = 0.3 };
    try renderer.setClouds(scene, clouds);

    var ground_shape = Shape{};
    defer ground_shape.deinit(gpa);
    try buildGround(gpa, &ground_shape);
    const ground = try renderer.createModel(&.{ground_shape.desc(.{ .metallic = 0, .roughness = 0.95 })});
    _ = try renderer.spawn(scene, .{ .model = ground });

    var tuft_shape = Shape{};
    defer tuft_shape.deinit(gpa);
    try buildTuft(gpa, &tuft_shape, rng);
    const tuft = try renderer.createModel(&.{tuft_shape.desc(.{ .metallic = 0, .roughness = 0.8, .double_sided = true, .sway = 0.9 })});

    var tree_shape = Shape{};
    defer tree_shape.deinit(gpa);
    try tree_shape.taper(gpa, 0, 1.6, 0.16, 0.1, 8, .{ 0.2, 0.13, 0.08 }, .{ 0.24, 0.16, 0.1 });
    for ([_][3]f32{ .{ 1.1, 3.0, 1.25 }, .{ 2.2, 4.1, 0.95 }, .{ 3.3, 5.2, 0.6 } }) |skirt|
        try tree_shape.taper(gpa, skirt[0], skirt[1], skirt[2], 0, 9, .{ 0.05, 0.16, 0.07 }, .{ 0.12, 0.3, 0.12 });
    const tree = try renderer.createModel(&.{tree_shape.desc(.{ .metallic = 0, .roughness = 0.85, .double_sided = true, .sway = 0.005 })});

    var ball_positions: [helpers.sphere_vertex_count][3]f32 = undefined;
    var ball_normals: [helpers.sphere_vertex_count][3]f32 = undefined;
    var ball_indices: [helpers.sphere_index_count]u32 = undefined;
    helpers.sphereMesh(0.5, &ball_positions, &ball_normals, &ball_indices);
    const Stuff = struct { color: [4]f32, metallic: f32, roughness: f32, clearcoat: f32 = 0 };
    const ball = struct {
        fn of(r: *gfx.Renderer, positions: []const [3]f32, normals: []const [3]f32, indices: []const u32, stuff: Stuff) !gfx.Model {
            return r.createModel(&.{.{ .positions = positions, .normals = normals, .indices = indices, .material = .{
                .base_color = stuff.color,
                .metallic = stuff.metallic,
                .roughness = stuff.roughness,
                .clearcoat = stuff.clearcoat,
            } }});
        }
    }.of;
    const rock = try ball(renderer, &ball_positions, &ball_normals, &ball_indices, .{ .color = .{ 0.36, 0.35, 0.33, 1 }, .metallic = 0, .roughness = 0.92 });
    const gold = try ball(renderer, &ball_positions, &ball_normals, &ball_indices, .{ .color = .{ 1.0, 0.77, 0.34, 1 }, .metallic = 1, .roughness = 0.18 });
    const chrome = try ball(renderer, &ball_positions, &ball_normals, &ball_indices, .{ .color = .{ 0.95, 0.95, 0.95, 1 }, .metallic = 1, .roughness = 0.03 });
    const lacquer = try ball(renderer, &ball_positions, &ball_normals, &ball_indices, .{ .color = .{ 0.55, 0.03, 0.03, 1 }, .metallic = 0, .roughness = 0.5, .clearcoat = 1 });
    var box_positions: [24][3]f32 = undefined;
    var box_indices: [36]u32 = undefined;
    helpers.boxMesh(.{ 0.5, 0.5, 0.5 }, &box_positions, &box_indices);
    const stone = try renderer.createModel(&.{.{ .positions = &box_positions, .indices = &box_indices, .material = .{ .base_color = .{ 0.6, 0.58, 0.54, 1 }, .metallic = 0, .roughness = 0.8 } }});

    const player_model = try renderer.loadModel("examples/assets/world/Rogue_Hooded.glb");
    const helmet = try renderer.loadModel("examples/assets/DamagedHelmet.glb");
    try renderer.waitUntilLoaded();

    {
        const transforms = try gpa.alloc(math.Mat4, grass_count);
        defer gpa.free(transforms);
        const colors = try gpa.alloc([3]f32, grass_count);
        defer gpa.free(colors);
        var placed: usize = 0;
        while (placed < grass_count) {
            const x = (rng.float(f32) - 0.5) * field * 0.92;
            const z = (rng.float(f32) - 0.5) * field * 0.92;
            if (nearPond(x, z, 0.6)) continue;
            const scale = 0.7 + rng.float(f32) * 0.9;
            transforms[placed] = math.mul(math.translation(.{ x, groundHeight(x, z) - 0.02, z }), math.mul(math.rotationY(rng.float(f32) * std.math.tau), math.scaling(.{ scale, scale * (0.8 + rng.float(f32) * 0.6), scale })));
            const patch = 0.5 + 0.5 * @sin(x * 0.19 + @sin(z * 0.13) * 2.5) * @cos(z * 0.17);
            colors[placed] = .{ 0.85 + 0.5 * patch, 0.9 + 0.2 * (1 - patch), 0.7 + 0.3 * rng.float(f32) };
            placed += 1;
        }
        const grass = try renderer.createInstances(scene, tuft, transforms);
        try renderer.setInstanceColors(grass, colors);
    }
    {
        const transforms = try gpa.alloc(math.Mat4, tree_count);
        defer gpa.free(transforms);
        var placed: usize = 0;
        while (placed < tree_count) {
            const x = (rng.float(f32) - 0.5) * field * 0.9;
            const z = (rng.float(f32) - 0.5) * field * 0.9;
            if (nearPond(x, z, 2.5) or x * x + z * z < 14 * 14) continue;
            const scale = 0.8 + rng.float(f32) * 1.1;
            transforms[placed] = math.mul(math.translation(.{ x, groundHeight(x, z) - 0.1, z }), math.mul(math.rotationY(rng.float(f32) * std.math.tau), math.uniformScaling(scale)));
            placed += 1;
        }
        _ = try renderer.createInstances(scene, tree, transforms);
    }
    {
        const transforms = try gpa.alloc(math.Mat4, rock_count);
        defer gpa.free(transforms);
        for (transforms) |*transform| {
            const x = (rng.float(f32) - 0.5) * field * 0.85;
            const z = (rng.float(f32) - 0.5) * field * 0.85;
            const size = 0.3 + rng.float(f32) * rng.float(f32) * 1.6;
            transform.* = math.mul(math.translation(.{ x, groundHeight(x, z) - size * 0.15, z }), math.mul(math.rotationY(rng.float(f32) * std.math.tau), math.scaling(.{ size * (0.8 + rng.float(f32) * 0.7), size * (0.45 + rng.float(f32) * 0.4), size })));
        }
        _ = try renderer.createInstances(scene, rock, transforms);
    }
    const display = [2]f32{ 3.5, -4.5 };
    const display_height = groundHeight(display[0], display[1]);
    _ = try renderer.spawn(scene, .{ .model = stone, .transform = math.mul(math.translation(.{ display[0], display_height + 0.45, display[1] }), math.scaling(.{ 0.9, 1.0, 0.9 })) });
    _ = try renderer.spawn(scene, .{ .model = helmet, .transform = math.mul(math.translation(.{ display[0], display_height + 1.55, display[1] }), math.mul(math.rotationY(2.4), math.mul(math.rotationX(std.math.pi * 0.5), math.uniformScaling(0.6)))) });
    for ([_]gfx.Model{ gold, chrome, lacquer }, 0..) |model, index| {
        const x = display[0] + 1.6 + @as(f32, @floatFromInt(index)) * 1.3;
        const z = display[1] + 0.6 * @as(f32, @floatFromInt(index));
        _ = try renderer.spawn(scene, .{ .model = model, .transform = math.translation(.{ x, groundHeight(x, z) + 0.5, z }) });
    }

    _ = try renderer.createWater(scene, .{
        .transform = math.mul(math.translation(.{ pond_center[0], hillsAt(pond_center[0], pond_center[1]) + pond_level, pond_center[1] }), math.scaling(.{ pond_radius * 2.2, 1, pond_radius * 2.2 })),
        .color = .{ 0.03, 0.09, 0.07 },
        .murk = 0.9,
        .rain = 0.6,
        .ripple_detail = 0.7,
    });

    var motes_desc = gfx.EmitterDesc{
        .radius = 9,
        .capacity = 600,
        .rate = 70,
        .lifetime = .{ 4, 8 },
        .direction = .{ 0.3, 1, 0.1 },
        .spread = 1.4,
        .speed = .{ 0.05, 0.3 },
        .gravity = .{ 0, 0.02, 0 },
        .drag = 0.2,
        .size = .{ 0.012, 0.03 },
        .color_start = .{ 1.0, 0.95, 0.7, 0.7 },
        .color_end = .{ 1.0, 0.95, 0.7, 0 },
        .softness = 0.1,
    };
    const motes = try renderer.createEmitter(scene, motes_desc);

    const player_info = renderer.modelInfo(player_model).?;
    const player_scale = 2.0 / @max(player_info.bounds_max[1] - player_info.bounds_min[1], 1e-3);
    const player = try renderer.spawn(scene, .{ .model = player_model });
    const clip_idle = renderer.findAnimation(player_model, "Idle") orelse 0;
    const clip_run = renderer.findAnimation(player_model, "Running_A") orelse clip_idle;
    const clip_jump = renderer.findAnimation(player_model, "Jump_Idle") orelse clip_idle;

    var list = gfx.DrawList.init(gpa);
    defer list.deinit();
    const font = renderer.defaultFont();
    var hud_buffer: [160]u8 = undefined;

    var position = [2]f32{ 0, 0 };
    var velocity = [2]f32{ 0, 0 };
    var height: f32 = 0;
    var rising: f32 = 0;
    var heading: f32 = 0;
    var airborne: f32 = 0;
    var clock_idle: f32 = 0;
    var clock_run: f32 = 0;
    var yaw: f32 = 0.6;
    var pitch: f32 = 0.22;
    var arm: f32 = 4.6;
    var last_cursor: ?[2]f64 = null;
    if (stage.window) |window| window.captureCursor(true);

    while (stage.begin()) |tick| {
        if (stage.keyDown(glfw.GLFW_KEY_Z)) arm = @max(arm - tick.dt * 5, 2.0);
        if (stage.keyDown(glfw.GLFW_KEY_X)) arm = @min(arm + tick.dt * 5, 20);
        if (stage.keyDown(glfw.GLFW_KEY_T)) {
            sun_height = @mod(sun_height + tick.dt * 0.2, std.math.pi);
            sky.sun_direction = .{ -0.55 * @cos(sun_height), -@max(@sin(sun_height), -0.05), -0.5 };
            renderer.setSky(environment, sky);
            renderer.setSun(scene, gfx.skySun(sky));
        }
        if (stage.keyPressed(glfw.GLFW_KEY_C)) {
            clouds_on = !clouds_on;
            try renderer.setClouds(scene, if (clouds_on) clouds else null);
        }

        if (stage.window) |window| {
            const cursor = window.cursor();
            if (last_cursor) |last| {
                yaw -= @as(f32, @floatCast(cursor[0] - last[0])) * 0.0028;
                pitch = std.math.clamp(pitch + @as(f32, @floatCast(cursor[1] - last[1])) * 0.0022, -0.35, 1.25);
            }
            last_cursor = cursor;
        }

        var want = [2]f32{ 0, 0 };
        if (stage.keyDown(glfw.GLFW_KEY_W)) want[1] += 1;
        if (stage.keyDown(glfw.GLFW_KEY_S)) want[1] -= 1;
        if (stage.keyDown(glfw.GLFW_KEY_D)) want[0] += 1;
        if (stage.keyDown(glfw.GLFW_KEY_A)) want[0] -= 1;
        var top_speed: f32 = if (stage.keyDown(glfw.GLFW_KEY_LEFT_SHIFT)) 8.0 else 5.0;
        if (stage.window == null) {
            want = .{ 0.35, 1 };
            yaw -= tick.dt * 0.25;
            top_speed = 4.5;
        }
        const ahead = [2]f32{ -@sin(yaw), -@cos(yaw) };
        const aside = [2]f32{ @cos(yaw), -@sin(yaw) };
        var goal = [2]f32{ ahead[0] * want[1] + aside[0] * want[0], ahead[1] * want[1] + aside[1] * want[0] };
        const goal_length = @sqrt(goal[0] * goal[0] + goal[1] * goal[1]);
        if (goal_length > 1e-3) goal = .{ goal[0] / goal_length * top_speed, goal[1] / goal_length * top_speed };
        const grip: f32 = if (height > 0) 3 else 12;
        const ease = 1 - @exp(-tick.dt * grip);
        velocity = .{ velocity[0] + (goal[0] - velocity[0]) * ease, velocity[1] + (goal[1] - velocity[1]) * ease };
        const speed = @sqrt(velocity[0] * velocity[0] + velocity[1] * velocity[1]);
        const half = field * 0.45;
        position = .{
            std.math.clamp(position[0] + velocity[0] * tick.dt, -half, half),
            std.math.clamp(position[1] + velocity[1] * tick.dt, -half, half),
        };
        if (speed > 0.3) {
            const facing = std.math.atan2(velocity[0], velocity[1]);
            const turn = @mod(facing - heading + std.math.pi, std.math.tau) - std.math.pi;
            heading += turn * (1 - @exp(-tick.dt * 14));
        }

        if (height <= 0 and stage.keyPressed(glfw.GLFW_KEY_SPACE)) rising = 6.2;
        if (height > 0 or rising > 0) {
            rising -= 18 * tick.dt;
            height += rising * tick.dt;
            if (height <= 0) {
                height = 0;
                rising = 0;
            }
        }
        const in_air: f32 = if (height > 0.05) 1 else 0;
        airborne += (in_air - airborne) * (1 - @exp(-tick.dt * 14));

        clock_idle += tick.dt;
        clock_run += tick.dt * (0.35 + speed / 5.0);
        var pose = gfx.Pose{
            .animation = clip_idle,
            .time = clock_idle,
            .blend = .{ .animation = clip_run, .time = clock_run, .weight = std.math.clamp(speed / 4.0, 0, 1) },
        };
        if (airborne > 0.01) pose.layers[0] = .{ .animation = clip_jump, .time = clock_idle, .weight = airborne };
        const floor = groundHeight(position[0], position[1]);
        const feet = math.Vec3{ position[0], floor + height, position[1] };
        renderer.setTransform(player, math.mul(math.translation(feet), math.mul(math.rotationY(heading), math.uniformScaling(player_scale))));
        renderer.setPose(player, pose);
        motes_desc.position = .{ feet[0], feet[1] + 1.5, feet[2] };
        renderer.setEmitter(motes, motes_desc);

        list.clear();
        const stats = renderer.getStats();
        try list.rect(.{ .x = 12, .y = 12, .width = 560, .height = 62 }, gfx.Color.rgba(10, 12, 20, 170));
        try list.text(font, try std.fmt.bufPrint(&hud_buffer, "{d:.0} fps · gpu {d:.2} ms · {d} instances · {d} of {d} meshlets drawn", .{ stage.fps, stage.gpu_ms, stats.instances, stats.meshlets_drawn, stats.meshlets }), .{ 24, 22 }, .{ .size = 16 });
        try list.text(font, "Mouse look · WASD move · Shift sprint · Space jump · Z/X zoom · hold T sun · C clouds", .{ 24, 48 }, .{ .size = 13, .color = gfx.Color.hex(0x9aa7d0) });

        const target = math.Vec3{ feet[0] + aside[0] * 0.45, floor + height * 0.6 + 1.55, feet[2] + aside[1] * 0.45 };
        var eye = math.Vec3{
            target[0] + @sin(yaw) * @cos(pitch) * arm,
            target[1] + @sin(pitch) * arm,
            target[2] + @cos(yaw) * @cos(pitch) * arm,
        };
        eye[1] = @max(eye[1], groundHeight(eye[0], eye[2]) + 0.35);
        try stage.end(try renderer.render(.{
            .views = &.{.{
                .scene = scene,
                .camera = gfx.Camera.lookAt(eye, target),
                .draw_lists = &.{&list},
                .target = stage.target(),
                .settings = .{
                    .shadow_distance = 90,
                    .aerial_perspective = 0.004,
                    .lens_flare = 0.15,
                    .contact_shadows = 0.3,
                },
            }},
            .delta_time = tick.dt,
        }));
    }
    try stage.finish();
}
