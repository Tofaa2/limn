//! GPU particles: six effects on a small stage, each switchable.
//!
//!   1 campfire   2 smoke   3 fountain   4 snow   5 orbiting spark   6 debris
//!   A/D orbit the camera, Space pauses the automatic orbit
//!
//! `--frames N` exits after N frames. `--screenshot file.png` renders
//! without a window and writes the last frame, for checking the picture.
const std = @import("std");
const gfx = @import("limn");
const math = gfx.math;
const glfw = @import("glfw");
const Window = @import("window").Window;

const Effect = struct {
    name: []const u8,
    /// Where its label floats.
    label: math.Vec3,
    emitters: []const gfx.EmitterDesc,
    handles: [2]gfx.Emitter = undefined,
    on: bool = true,
};

const fire_position = math.Vec3{ -4, 0.15, 0 };
const smoke_position = math.Vec3{ -1.5, 0.1, -2.5 };
const fountain_position = math.Vec3{ 1.5, 0.3, 0 };
const orb_center = math.Vec3{ 4.5, 1.6, -1 };

var effects = [_]Effect{
    .{
        .name = "campfire",
        .label = .{ -4, 2.0, 0 },
        .emitters = &.{
            // Flames: bright, short-lived, rising, additive.
            .{
                .position = fire_position,
                .radius = 0.22,
                .capacity = 512,
                .rate = 240,
                .lifetime = .{ 0.5, 1.0 },
                .spread = 0.25,
                .speed = .{ 0.6, 1.5 },
                .gravity = .{ 0, 1.3, 0 },
                .size = .{ 0.4, 0.08 },
                .color_start = .{ 6.0, 2.2, 0.5, 0.8 },
                .color_end = .{ 2.0, 0.2, 0.02, 0 },
                .blend = .additive,
                .lit = false,
            },
            // Embers: thrown wide, pulled back down.
            .{
                .position = fire_position,
                .radius = 0.1,
                .capacity = 256,
                .rate = 35,
                .lifetime = .{ 1.0, 2.2 },
                .spread = 0.8,
                .speed = .{ 1.5, 3.5 },
                .gravity = .{ 0, -3.5, 0 },
                .drag = 0.2,
                .size = .{ 0.035, 0.01 },
                .color_start = .{ 12, 6, 1.5, 1 },
                .color_end = .{ 6, 1, 0.1, 0 },
                // Each ember draws a short glowing arc behind it.
                .trail = 10,
                .trail_seconds = 0.35,
                .blend = .additive,
                .lit = false,
                .softness = 0,
            },
        },
    },
    .{
        .name = "smoke",
        .label = .{ -1.5, 3.4, -2.5 },
        // Lit: it takes the sun, its shadows and the ambient light.
        .emitters = &.{.{
            .position = smoke_position,
            .radius = 0.2,
            .capacity = 512,
            // Overlapping puffs layer correctly only drawn farthest first.
            .sorted = true,
            .rate = 40,
            .lifetime = .{ 4, 6 },
            .spread = 0.25,
            .speed = .{ 0.5, 1.0 },
            .gravity = .{ 0.12, 0.2, 0 },
            .drag = 0.3,
            .size = .{ 0.35, 2.2 },
            .color_start = .{ 0.75, 0.75, 0.8, 0.4 },
            .color_end = .{ 0.9, 0.9, 0.95, 0 },
        }},
    },
    .{
        .name = "fountain",
        .label = .{ 1.5, 3.3, 0 },
        .emitters = &.{.{
            .position = fountain_position,
            .radius = 0.05,
            .capacity = 4096,
            .rate = 1400,
            .lifetime = .{ 1.6, 2.2 },
            .spread = 0.22,
            .speed = .{ 5.5, 7.0 },
            .gravity = .{ 0, -9.8, 0 },
            .drag = 0.05,
            .size = .{ 0.05, 0.03 },
            // Droplets streak along their fall and splash off the basin.
            .collide = true,
            .bounce = 0.3,
            .stretch = 0.02,
            .color_start = .{ 0.9, 1.6, 3.0, 0.9 },
            .color_end = .{ 0.4, 0.8, 2.0, 0.2 },
            // Five color keys over a droplet's life: bright at the jet, deep
            // blue at the top, foam white as it lands. Four size keys.
            .color_curve = .init(&.{ .{ 1.4, 2.0, 3.2, 0.9 }, .{ 0.25, 0.6, 3.0, 0.9 }, .{ 0.3, 1.4, 2.6, 0.8 }, .{ 2.2, 2.6, 2.8, 0.7 }, .{ 0.4, 0.8, 2.0, 0.0 } }),
            .size_curve = .init(&.{ 0.05, 0.03, 0.045, 0.03 }),
            .blend = .additive,
            .lit = false,
            .softness = 0.05,
        }},
    },
    .{
        .name = "snow",
        .label = .{ 0, 4.6, 3 },
        // One large, slow emitter high above the whole stage.
        .emitters = &.{.{
            .position = .{ 0, 7, 0 },
            .radius = 8,
            .capacity = 8192,
            .rate = 900,
            .lifetime = .{ 7, 9 },
            .direction = .{ 0, -1, 0 },
            .spread = 0.5,
            .speed = .{ 0.6, 1.2 },
            .gravity = .{ 0.05, -0.15, 0.02 },
            .drag = 0.4,
            .size = .{ 0.035, 0.035 },
            // The air is already full of snow when the scene opens.
            .prewarm = 6,
            // Flakes stop where they land.
            .collide = true,
            .bounce = 0,
            .color_start = .{ 1, 1, 1, 0.9 },
            .color_end = .{ 1, 1, 1, 0.9 },
            .softness = 0.02,
        }},
    },
    .{
        .name = "orbiting spark",
        .label = .{ 4.5, 3.2, -1 },
        // The emitter itself moves every frame; see `orbPosition`.
        .emitters = &.{.{
            .position = orb_center,
            .radius = 0.05,
            .capacity = 2048,
            .rate = 700,
            .lifetime = .{ 0.8, 1.6 },
            .spread = std.math.pi,
            .speed = .{ 0.05, 0.5 },
            .drag = 1.5,
            .size = .{ 0.12, 0.01 },
            .color_start = .{ 3.0, 0.8, 5.0, 1 },
            // A third key: the trail flares yellow and swells partway along.
            .color_mid = .{ 6.0, 5.0, 0.6, 1 },
            .size_mid = 0.3,
            .mid = 0.35,
            .color_end = .{ 0.3, 0.4, 3.0, 0 },
            .blend = .additive,
            .lit = false,
        }},
    },
    .{
        .name = "debris",
        .label = .{ -2.5, 3.2, 3.0 },
        // Each particle is a small tumbling block rather than a sprite; the
        // mesh is filled in once the model exists (see `debris_effect`).
        .emitters = &.{.{
            .position = .{ -2.5, 0.2, 3.0 },
            // Each block leaves a streak of dust along its arc.
            .trail = 12,
            .trail_seconds = 0.5,
            .radius = 0.15,
            .capacity = 384,
            .rate = 90,
            .lifetime = .{ 2.0, 3.0 },
            .spread = 0.45,
            .speed = .{ 3.5, 6.0 },
            .gravity = .{ 0, -9.8, 0 },
            .drag = 0.1,
            .collide = true,
            .bounce = 0.45,
            .spin = 7,
            // Hot when thrown, cooling to stone, shrinking away at the end.
            .color_curve = .init(&.{ .{ 6.0, 2.0, 0.4, 1 }, .{ 1.2, 0.7, 0.45, 1 }, .{ 0.6, 0.56, 0.52, 1 }, .{ 0.6, 0.56, 0.52, 1 } }),
            .size_curve = .init(&.{ 0.16, 0.16, 0.16, 0.14, 0.0 }),
        }},
    },
};

/// The effect whose particles are drawn as a mesh.
const debris_effect = 5;

fn orbPosition(time: f32) math.Vec3 {
    return math.add(orb_center, .{ @cos(time * 2.2) * 1.3, @sin(time * 3.1) * 0.6, @sin(time * 2.2) * 1.3 });
}

fn boxMesh(half: [3]f32, positions: *[24][3]f32, indices: *[36]u32) void {
    for (0..6) |face| {
        const axis = face / 2;
        const sign: f32 = if (face % 2 == 0) 1 else -1;
        const u = (axis + 1) % 3;
        const v = (axis + 2) % 3;
        for (0..4) |corner| {
            var p: [3]f32 = undefined;
            p[axis] = sign * half[axis];
            p[u] = (if (corner == 1 or corner == 2) half[u] else -half[u]) * sign;
            p[v] = if (corner >= 2) half[v] else -half[v];
            positions[face * 4 + corner] = p;
        }
        const base: u32 = @intCast(face * 4);
        indices[face * 6 ..][0..6].* = .{ base, base + 1, base + 2, base, base + 2, base + 3 };
    }
}

pub fn main(init: std.process.Init) !void {
    var frame_limit: ?u64 = null;
    var screenshot: ?[]const u8 = null;
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--frames")) {
            frame_limit = try std.fmt.parseInt(u64, args.next() orelse return error.MissingArgument, 10);
        } else if (std.mem.eql(u8, arg, "--screenshot")) {
            screenshot = args.next() orelse return error.MissingArgument;
        } else return error.InvalidArgument;
    }
    const offscreen = screenshot != null;
    if (offscreen and frame_limit == null) frame_limit = 360;

    const window: ?Window = if (offscreen) null else try Window.init(1280, 720, "Limn particles");
    defer if (window) |value| value.deinit();
    const renderer = try gfx.Renderer.init(init.gpa, init.io, .{
        .application_name = "particles",
        .pipeline_cache_path = "zig-out/pipeline.cache",
        // The offscreen mode doubles as a self-check.
        .validation = offscreen,
        .surface = if (window) |value| try value.surface(true) else null,
    });
    defer renderer.deinit();
    const target: ?gfx.rhi.Texture = if (offscreen) try renderer.createTarget(1280, 720) else null;
    defer if (target) |texture| renderer.destroyTarget(texture);

    // The stage: a floor, a fire pit, a fountain basin and two pillars for
    // the smoke and snow to pass behind.
    var positions: [5][24][3]f32 = undefined;
    var indices: [5][36]u32 = undefined;
    boxMesh(.{ 12, 0.1, 12 }, &positions[0], &indices[0]);
    boxMesh(.{ 0.45, 0.12, 0.45 }, &positions[1], &indices[1]);
    boxMesh(.{ 0.6, 0.2, 0.6 }, &positions[2], &indices[2]);
    boxMesh(.{ 0.35, 2.0, 0.35 }, &positions[3], &indices[3]);
    boxMesh(.{ 0.35, 2.0, 0.35 }, &positions[4], &indices[4]);
    const placements = [5]math.Vec3{ .{ 0, -0.1, 0 }, .{ -4, 0.1, 0 }, .{ 1.5, 0.2, 0 }, .{ -1.2, 2, -4.5 }, .{ 3.2, 2, -3.6 } };
    const colors = [5][4]f32{ .{ 0.09, 0.095, 0.11, 1 }, .{ 0.08, 0.07, 0.07, 1 }, .{ 0.45, 0.47, 0.5, 1 }, .{ 0.55, 0.5, 0.45, 1 }, .{ 0.55, 0.5, 0.45, 1 } };
    const scene = try renderer.createScene();
    for (0..5) |index| {
        const model = try renderer.createModel(&.{.{
            .positions = &positions[index],
            .indices = &indices[index],
            .material = .{ .base_color = colors[index], .metallic = 0, .roughness = 0.8 },
        }});
        _ = try renderer.spawn(scene, .{ .model = model, .transform = math.translation(placements[index]) });
    }
    // A block one unit across for the debris; it is never spawned itself.
    var shard_positions: [24][3]f32 = undefined;
    var shard_indices: [36]u32 = undefined;
    boxMesh(.{ 0.5, 0.3, 0.4 }, &shard_positions, &shard_indices);
    const shard = try renderer.createModel(&.{.{ .positions = &shard_positions, .indices = &shard_indices, .material = .{} }});
    try renderer.waitUntilLoaded();
    // Moonlight from the side, so lit particles show a bright and a dark side.
    renderer.setSun(scene, .{ .direction = .{ -0.55, -0.6, -0.45 }, .color = .{ 0.75, 0.82, 1.0 }, .intensity = 2.5 });

    for (&effects) |*effect| {
        for (effect.emitters, 0..) |desc, index| effect.handles[index] = try renderer.createEmitter(scene, desc);
    }

    var list = gfx.DrawList.init(init.gpa);
    defer list.deinit();
    const font = renderer.defaultFont();
    var keys_down: [effects.len]bool = @splat(false);
    var orbit: f32 = 0.6;
    var auto_orbit = true;
    var space_down = false;
    var time: f32 = 0;
    var last = if (window) |value| value.time() else 0;
    var frames: u64 = 0;
    var hud_buffer: [96]u8 = undefined;
    var hud_text: []const u8 = "";
    var hud_time: f64 = last;
    var hud_frames: u32 = 0;

    while ((window == null or !window.?.shouldClose()) and (frame_limit == null or frames < frame_limit.?)) {
        var dt: f32 = 1.0 / 60.0;
        var size = [2]u32{ 1280, 720 };
        if (window) |value| {
            value.pollEvents();
            if (value.keyDown(glfw.GLFW_KEY_ESCAPE)) break;
            const now = value.time();
            dt = @floatCast(@min(now - last, 0.1));
            last = now;
            size = value.framebufferSize();
            renderer.resize(size[0], size[1]);

            for (&effects, 0..) |*effect, index| {
                const down = value.keyDown(glfw.GLFW_KEY_1 + @as(c_int, @intCast(index)));
                if (down and !keys_down[index]) effect.on = !effect.on;
                keys_down[index] = down;
            }
            const space = value.keyDown(glfw.GLFW_KEY_SPACE);
            if (space and !space_down) auto_orbit = !auto_orbit;
            space_down = space;
            if (value.keyDown(glfw.GLFW_KEY_A)) orbit -= dt * 1.2;
            if (value.keyDown(glfw.GLFW_KEY_D)) orbit += dt * 1.2;
        }
        if (auto_orbit) orbit += dt * 0.12;
        time += dt;

        // Emitters are plain data: switching one off is a rate of zero (the
        // particles in the air finish), and moving one is a new position.
        for (&effects, 0..) |*effect, effect_index| {
            for (effect.emitters, 0..) |base, index| {
                var desc = base;
                if (!effect.on) desc.rate = 0;
                if (effect_index == 4) desc.position = orbPosition(time);
                if (effect_index == debris_effect) desc.mesh = shard;
                renderer.setEmitter(effect.handles[index], desc);
            }
        }
        // The fire lights its surroundings, flickering a little.
        const flicker = 0.85 + 0.15 * @sin(time * 17) * @sin(time * 7.3);
        try renderer.setLights(scene, if (effects[0].on) &.{.{
            .position = math.add(fire_position, .{ 0, 0.6, 0 }),
            .color = .{ 1.0, 0.5, 0.18 },
            .intensity = 30 * flicker,
            .range = 9,
            .cast_shadows = true,
        }} else &.{});

        list.clear();
        const stats = renderer.getStats();
        try list.rect(.{ .x = 12, .y = 12, .width = 300, .height = 62 + 19 * @as(f32, effects.len) }, gfx.Color.rgba(10, 12, 20, 180));
        try list.text(font, hud_text, .{ 24, 20 }, .{ .size = 17 });
        for (&effects, 0..) |*effect, index| {
            const y = 46 + 19 * @as(f32, @floatFromInt(index));
            var key: [1]u8 = .{'1' + @as(u8, @intCast(index))};
            try list.text(font, &key, .{ 24, y }, .{ .size = 14, .color = gfx.Color.hex(0x9aa7d0) });
            try list.text(font, effect.name, .{ 48, y }, .{ .size = 14 });
            try list.text(font, if (effect.on) "on" else "off", .{ 230, y }, .{
                .size = 14,
                .color = if (effect.on) gfx.Color.hex(0x3ddc97) else gfx.Color.hex(0x7c8499),
            });
            try list.text3d(font, effect.name, effect.label, .{ .size = 0.22, .color = gfx.Color.rgba(255, 255, 255, if (effect.on) 220 else 70) });
        }
        try list.text(font, "A/D orbit · Space pause orbit", .{ 24, 50 + 19 * @as(f32, effects.len) }, .{ .size = 13, .color = gfx.Color.hex(0x9aa7d0) });

        const eye = math.Vec3{ @sin(orbit) * 11, 4.2, @cos(orbit) * 11 };
        const presented = try renderer.render(.{
            .views = &.{.{
                .scene = scene,
                .camera = gfx.Camera.lookAt(eye, .{ 0, 1.6, -0.5 }),
                .draw_lists = &.{&list},
                .target = if (target) |texture| .{ .texture = texture } else .backbuffer,
                // A night scene: without this the meter would brighten it to grey.
                .settings = .{ .shadow_distance = 40, .bloom = 0.06, .exposure_compensation = -1.6 },
            }},
            .delta_time = dt,
        });
        if (!presented) {
            try init.io.sleep(std.Io.Duration.fromMilliseconds(10), .awake);
            continue;
        }
        frames += 1;
        hud_frames += 1;
        const now: f64 = if (window) |value| value.time() else @as(f64, @floatFromInt(frames)) / 60.0;
        if (now - hud_time >= 0.5 or hud_text.len == 0) {
            var gpu_ms: f32 = 0;
            for (renderer.device.passTimings()) |timing| {
                if (timing.depth == 0) gpu_ms += timing.milliseconds;
            }
            hud_text = try std.fmt.bufPrint(&hud_buffer, "{d:.0} fps · gpu {d:.2} ms · {d} particle slots", .{
                @as(f64, @floatFromInt(hud_frames)) / @max(now - hud_time, 1e-3), gpu_ms, stats.particles,
            });
            hud_time = now;
            hud_frames = 0;
        }
    }

    try renderer.device.waitIdle();
    if (screenshot) |path| {
        const pixels = try renderer.device.readTexture(init.gpa, target.?);
        defer init.gpa.free(pixels);
        try gfx.png.write(init.gpa, init.io, path, .{ .width = 1280, .height = 720, .pixels = pixels });
    }
    if (renderer.device.validationErrorCount() != 0) return error.ValidationFailed;
}
