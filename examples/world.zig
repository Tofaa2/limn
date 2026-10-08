//! Third-person walk through Sponza.
//!
//!   WASD move, Shift run, Space jump, mouse orbits the camera
//!   Tab cycles debug views, T toggles TAA, F toggles fog, G toggles global
//!   illumination, L toggles extra lights, H toggles the HUD,
//!   P toggles the fire particles, hold E to wave, V toggles vsync,
//!   F5 recompiles the shaders from source and applies them,
//!   Esc quits
//!
//! Assets stream in while the window stays responsive: the sky appears
//! first, then the scene, then the character.
const std = @import("std");
const gfx = @import("limn");
const math = gfx.math;
const window_module = @import("window");
const glfw = window_module.glfw;
const Window = window_module.Window;

const Player = struct {
    position: math.Vec3 = .{ 2, 0, -0.4 },
    velocity: [2]f32 = .{ 0, 0 },
    vertical_velocity: f32 = 0,
    facing: f32 = -std.math.pi * 0.5,
    grounded: bool = true,
    /// 0 idle, 1 walking, 2 running; eased for animation cross-fades.
    gait: f32 = 0,

    const scale = 0.42;
    const walk_speed = 1.7;
    const run_speed = 4.6;

    fn update(self: *Player, window: Window, camera_yaw: f32, bounds: [2]math.Vec3, dt: f32) void {
        var input = [2]f32{ 0, 0 };
        if (window.keyDown(glfw.GLFW_KEY_A)) input[0] -= 1;
        if (window.keyDown(glfw.GLFW_KEY_D)) input[0] += 1;
        if (window.keyDown(glfw.GLFW_KEY_W)) input[1] += 1;
        if (window.keyDown(glfw.GLFW_KEY_S)) input[1] -= 1;
        const magnitude = @sqrt(input[0] * input[0] + input[1] * input[1]);
        const running = window.keyDown(glfw.GLFW_KEY_LEFT_SHIFT);
        var desired = [2]f32{ 0, 0 };
        if (magnitude > 0) {
            const forward = [2]f32{ @sin(camera_yaw), -@cos(camera_yaw) };
            const right = [2]f32{ @cos(camera_yaw), @sin(camera_yaw) };
            const speed: f32 = if (running) run_speed else walk_speed;
            desired = .{
                (right[0] * input[0] + forward[0] * input[1]) / magnitude * speed,
                (right[1] * input[0] + forward[1] * input[1]) / magnitude * speed,
            };
            const target = std.math.atan2(desired[0], desired[1]);
            const delta = @mod(target - self.facing + std.math.pi * 3.0, std.math.pi * 2.0) - std.math.pi;
            self.facing += std.math.clamp(delta, -12 * dt, 12 * dt);
        }
        const response = 1 - @exp(-12 * dt);
        self.velocity[0] += (desired[0] - self.velocity[0]) * response;
        self.velocity[1] += (desired[1] - self.velocity[1]) * response;
        self.position[0] = std.math.clamp(self.position[0] + self.velocity[0] * dt, bounds[0][0], bounds[1][0]);
        self.position[2] = std.math.clamp(self.position[2] + self.velocity[1] * dt, bounds[0][2], bounds[1][2]);

        if (self.grounded and window.keyDown(glfw.GLFW_KEY_SPACE)) {
            self.vertical_velocity = 4.2;
            self.grounded = false;
        }
        self.vertical_velocity -= 12 * dt;
        self.position[1] += self.vertical_velocity * dt;
        if (self.position[1] <= 0) {
            self.position[1] = 0;
            self.vertical_velocity = 0;
            self.grounded = true;
        }

        const speed = @sqrt(self.velocity[0] * self.velocity[0] + self.velocity[1] * self.velocity[1]);
        const target_gait: f32 = if (speed < 0.2) 0 else if (speed < walk_speed * 1.3) 1 else 2;
        self.gait += (target_gait - self.gait) * (1 - @exp(-8 * dt));
    }

    fn transform(self: Player) math.Mat4 {
        return math.mul(math.translation(self.position), math.mul(math.rotationY(self.facing), math.uniformScaling(scale)));
    }
};

const OrbitCamera = struct {
    yaw: f32 = -std.math.pi * 0.5,
    pitch: f32 = 0.12,
    distance: f32 = 3.4,
    target: math.Vec3 = .{ 2, 1.0, -0.4 },
    cursor: ?[2]f64 = null,

    fn update(self: *OrbitCamera, window: Window, focus: math.Vec3, dt: f32) gfx.Camera {
        const cursor = window.cursor();
        if (self.cursor) |previous| {
            self.yaw += @as(f32, @floatCast(cursor[0] - previous[0])) * 0.0025;
            self.pitch = std.math.clamp(self.pitch + @as(f32, @floatCast(cursor[1] - previous[1])) * 0.0025, -0.35, 1.3);
        }
        self.cursor = cursor;
        self.target = math.lerp(self.target, focus, 1 - @exp(-10 * dt));
        const forward = math.Vec3{ @cos(self.pitch) * @sin(self.yaw), -@sin(self.pitch), -@cos(self.pitch) * @cos(self.yaw) };
        var position = math.sub(self.target, math.scale(forward, self.distance));
        position[1] = @max(position[1], 0.2);
        return gfx.Camera.lookAt(position, self.target);
    }
};

const fog_density = 0.012;

const Clips = struct {
    idle: u32 = 0,
    walk: u32 = 0,
    run: u32 = 0,
    jump: u32 = 0,
    wave: u32 = 0,
    /// Root of the upper body, for layers that leave the legs alone.
    torso: ?u32 = null,
};

pub fn main(init: std.process.Init) !void {
    var frame_limit: ?u64 = null;
    var validation = false;
    var vsync = true;
    var hdr = false;
    var resize_test = false;
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--frames")) {
            frame_limit = try std.fmt.parseInt(u64, args.next() orelse return error.MissingArgument, 10);
        } else if (std.mem.eql(u8, arg, "--validation")) {
            validation = true;
        } else if (std.mem.eql(u8, arg, "--resize-test")) {
            resize_test = true;
        } else if (std.mem.eql(u8, arg, "--hdr")) {
            hdr = true;
        } else if (std.mem.eql(u8, arg, "--no-vsync")) {
            vsync = false;
        } else return error.InvalidArgument;
    }

    const window = try Window.init(1600, 900, "Limn world");
    defer window.deinit();
    window.captureCursor(true);

    const renderer = try gfx.Renderer.init(init.gpa, init.io, .{
        .application_name = "world",
        .validation = validation,
        .surface = try window.surface(vsync),
        .pipeline_cache_path = "zig-out/pipeline.cache",
        .hdr_output = hdr,
        .asset_cache_dir = "zig-out/asset-cache",
    });
    defer renderer.deinit();
    if (hdr) std.log.info("hdr output: {s}", .{if (renderer.hdrActive()) "active (HDR10)" else "not available on this display, using sRGB"});
    std.log.info("device: {s}", .{renderer.device.name()});

    const scene = try renderer.scenes.create();
    const environment = try renderer.environments.load("examples/assets/world/venice_sunset_2k.hdr", 24);
    const sponza = try renderer.models.load("examples/assets/world/Sponza.glb");
    const robot = try renderer.models.load("examples/assets/world/RobotExpressive.glb");
    renderer.scenes.setEnvironment(scene, environment, 1.0);
    renderer.scenes.setSun(scene, .{ .direction = .{ -0.42, -1.0, 0.18 }, .color = .{ 1.0, 0.93, 0.82 }, .intensity = 28 });
    _ = try renderer.entities.spawn(scene, .{ .model = sponza });
    const player_entity = try renderer.entities.spawn(scene, .{ .model = robot });

    var player = Player{};
    var camera = OrbitCamera{};
    var clips: ?Clips = null;
    var bounds = [2]math.Vec3{ .{ -100, 0, -100 }, .{ 100, 0, 100 } };
    var bounds_known = false;
    var settings = gfx.Settings{ .fog_density = fog_density };
    var keys = KeyLatch{};
    var animation_time: f32 = 0;
    var frames: u64 = 0;
    var last_time = window.time();
    var title_time = last_time;
    var title_frames: u32 = 0;
    var list = gfx.DrawList.init(init.gpa);
    defer list.deinit();
    var hud_buffer: [256]u8 = undefined;
    var hud_text: []const u8 = "";
    var aim_buffer: [64]u8 = undefined;
    var aim_text: []const u8 = "";
    var show_hud = true;
    const fire_position = math.Vec3{ 3.4, 0.1, -1.5 };
    const fire_desc = gfx.EmitterDesc{
        .position = fire_position,
        .radius = 0.18,
        .capacity = 512,
        .rate = 220,
        .lifetime = .{ 0.5, 1.0 },
        .spread = 0.25,
        .speed = .{ 0.6, 1.4 },
        .gravity = .{ 0, 1.2, 0 },
        .size = .{ 0.35, 0.08 },
        .color_start = .{ 6.0, 2.2, 0.5, 0.8 },
        .color_end = .{ 2.0, 0.2, 0.02, 0 },
        .blend = .additive,
        .lit = false,
    };
    const smoke_desc = gfx.EmitterDesc{
        .position = math.add(fire_position, .{ 0, 0.7, 0 }),
        .radius = 0.15,
        .capacity = 512,
        .rate = 45,
        .lifetime = .{ 3, 5 },
        .spread = 0.3,
        .speed = .{ 0.4, 0.9 },
        .gravity = .{ 0, 0.25, 0 },
        .drag = 0.3,
        .size = .{ 0.3, 1.6 },
        .color_start = .{ 0.55, 0.55, 0.6, 0.35 },
        .color_end = .{ 0.7, 0.7, 0.75, 0 },
    };
    const fire = try renderer.emitters.create(scene, fire_desc);
    const smoke = try renderer.emitters.create(scene, smoke_desc);
    var fire_on = true;
    var waving = false;
    var wave_weight: f32 = 0;
    var lanterns = false;
    const start = std.Io.Clock.Timestamp.now(init.io, .awake);
    var announced_ready = false;

    while (!window.shouldClose() and (frame_limit == null or frames < frame_limit.?)) {
        window.pollEvents();
        if (window.keyDown(glfw.GLFW_KEY_ESCAPE)) break;
        const now = window.time();
        const dt: f32 = @floatCast(std.math.clamp(now - last_time, 0.0, 0.1));
        last_time = now;

        if (keys.pressed(window, glfw.GLFW_KEY_TAB)) {
            const count = @typeInfo(gfx.DebugView).@"enum".fields.len;
            settings.debug_view = @enumFromInt((@intFromEnum(settings.debug_view) + 1) % count);
        }
        if (keys.pressed(window, glfw.GLFW_KEY_T)) settings.temporal_antialiasing = !settings.temporal_antialiasing;
        if (keys.pressed(window, glfw.GLFW_KEY_H)) show_hud = !show_hud;
        if (keys.pressed(window, glfw.GLFW_KEY_F5)) {
            if (renderer.shaders.reload()) |count| {
                std.log.info("reloaded {d} shaders", .{count});
            } else |err| std.log.err("shader reload failed: {s}", .{@errorName(err)});
        }
        if (keys.pressed(window, glfw.GLFW_KEY_P)) {
            fire_on = !fire_on;
            var stopped_fire = fire_desc;
            var stopped_smoke = smoke_desc;
            stopped_fire.rate = 0;
            stopped_smoke.rate = 0;
            renderer.emitters.set(fire, if (fire_on) fire_desc else stopped_fire);
            renderer.emitters.set(smoke, if (fire_on) smoke_desc else stopped_smoke);
        }
        if (keys.pressed(window, glfw.GLFW_KEY_G)) settings.global_illumination = !settings.global_illumination;
        if (keys.pressed(window, glfw.GLFW_KEY_L)) {
            lanterns = !lanterns;
            try renderer.scenes.setLights(scene, if (lanterns) &.{
                .{
                    .kind = .spot,
                    .position = .{ 7.0, 3.5, 0.6 },
                    .direction = .{ -1.0, -0.55, -0.15 },
                    .color = .{ 1.0, 0.85, 0.6 },
                    .intensity = 90,
                    .range = 16,
                    .inner_angle = 0.25,
                    .outer_angle = 0.42,
                    .cast_shadows = true,
                },
                .{ .position = .{ -4.0, 1.4, -3.6 }, .color = .{ 1.0, 0.5, 0.2 }, .intensity = 18, .range = 8, .cast_shadows = true },
                .{ .position = .{ -4.0, 1.4, 3.4 }, .color = .{ 0.3, 0.6, 1.0 }, .intensity = 18, .range = 8 },
            } else &.{});
        }
        if (keys.pressed(window, glfw.GLFW_KEY_F)) settings.fog_density = if (settings.fog_density > 0) 0 else fog_density;
        if (keys.pressed(window, glfw.GLFW_KEY_V)) {
            vsync = !vsync;
            renderer.device.setVsync(vsync);
        }

        if (!bounds_known) if (renderer.models.info(sponza)) |info| {
            bounds = .{ math.add(info.bounds_min, .{ 2.2, 0, 2.2 }), math.sub(info.bounds_max, .{ 2.2, 0, 2.2 }) };
            bounds_known = true;
        };
        if (clips == null and renderer.models.state(robot) == .ready) clips = .{
            .idle = renderer.models.findAnimation(robot, "Idle") orelse 0,
            .walk = renderer.models.findAnimation(robot, "Walking") orelse 0,
            .run = renderer.models.findAnimation(robot, "Running") orelse 0,
            .jump = renderer.models.findAnimation(robot, "Jump") orelse 0,
            .wave = renderer.models.findAnimation(robot, "Wave") orelse 0,
            .torso = renderer.models.findNode(robot, "Abdomen"),
        };
        if (!announced_ready and !renderer.isLoading()) {
            announced_ready = true;
            std.log.info("all assets streamed in after {d} ms", .{@divTrunc(start.untilNow(init.io).raw.nanoseconds, std.time.ns_per_ms)});
        }

        player.update(window, camera.yaw, bounds, dt);
        renderer.entities.setTransform(player_entity, player.transform());
        if (clips) |clip| {
            animation_time += dt;
            var pose: gfx.Pose = if (!player.grounded)
                .{ .animation = clip.jump, .time = animation_time }
            else if (player.gait < 1)
                .{ .animation = clip.idle, .time = animation_time, .blend = .{ .animation = clip.walk, .time = animation_time, .weight = player.gait } }
            else
                .{ .animation = clip.walk, .time = animation_time, .blend = .{ .animation = clip.run, .time = animation_time, .weight = player.gait - 1 } };
            waving = window.keyDown(glfw.GLFW_KEY_E);
            wave_weight += ((if (waving) @as(f32, 1) else 0) - wave_weight) * (1 - @exp(-10 * dt));
            if (wave_weight > 0.01) pose.layers[0] = .{ .animation = clip.wave, .time = animation_time, .weight = wave_weight, .root = clip.torso };
            renderer.entities.setPose(player_entity, pose);
        }

        if (resize_test and frames == 40) glfw.glfwSetWindowSize(window.handle, 1000, 620);
        if (resize_test and frames == 80) glfw.glfwSetWindowSize(window.handle, 1280, 720);
        const size = window.framebufferSize();
        renderer.resize(size[0], size[1]);
        renderer.requestPick(null, .{ size[0] / 2, size[1] / 2 });
        if (renderer.takePick()) |result| {
            aim_text = if (result.hit) |hit|
                try std.fmt.bufPrint(&aim_buffer, "\naiming at {s}, {d:.1} m", .{ if (std.meta.eql(hit.entity, player_entity)) "the robot" else "scenery", hit.distance })
            else
                "\naiming at the sky";
        }
        const focus = math.add(player.position, .{ 0, 1.0, 0 });
        list.clear();
        const font = renderer.fonts.default();
        if (show_hud) {
            const Toggle = struct { key: []const u8, label: []const u8, state: []const u8, on: bool };
            const on_off = struct {
                fn text(value: bool) []const u8 {
                    return if (value) "on" else "off";
                }
            }.text;
            const gi_available = renderer.device.ray_tracing;
            const toggles = [_]Toggle{
                .{ .key = "T", .label = "antialiasing", .state = on_off(settings.temporal_antialiasing), .on = settings.temporal_antialiasing },
                .{ .key = "F", .label = "fog", .state = on_off(settings.fog_density > 0), .on = settings.fog_density > 0 },
                .{
                    .key = "G",
                    .label = "global illumination",
                    .state = if (!gi_available) "not supported" else on_off(settings.global_illumination),
                    .on = gi_available and settings.global_illumination,
                },
                .{ .key = "L", .label = "lanterns", .state = on_off(lanterns), .on = lanterns },
                .{ .key = "P", .label = "fire particles", .state = on_off(fire_on), .on = fire_on },
                .{ .key = "E", .label = "wave (hold)", .state = if (waving) "waving" else "off", .on = waving },
                .{ .key = "V", .label = "vsync", .state = on_off(vsync), .on = vsync },
                .{ .key = "Tab", .label = "debug view", .state = @tagName(settings.debug_view), .on = settings.debug_view != .none },
            };
            const row_height: f32 = 19;
            const text_size = font.measure(hud_text, 17);
            const rows_top = 28 + text_size[1];
            const panel_height = rows_top + row_height * @as(f32, @floatFromInt(toggles.len)) + 30;
            try list.rect(.{ .x = 12, .y = 12, .width = @max(text_size[0] + 24, 330), .height = panel_height }, gfx.Color.rgba(10, 12, 20, 180));
            try list.text(font, hud_text, .{ 24, 20 }, .{ .size = 17 });
            for (toggles, 0..) |toggle, row| {
                const y = rows_top + row_height * @as(f32, @floatFromInt(row));
                try list.text(font, toggle.key, .{ 24, y }, .{ .size = 14, .color = gfx.Color.hex(0x9aa7d0) });
                try list.text(font, toggle.label, .{ 64, y }, .{ .size = 14 });
                try list.text(font, toggle.state, .{ 230, y }, .{
                    .size = 14,
                    .color = if (toggle.on) gfx.Color.hex(0x3ddc97) else gfx.Color.hex(0x7c8499),
                });
            }
            try list.text(font, "WASD move · Shift run · Space jump · H hide this", .{ 24, rows_top + row_height * @as(f32, @floatFromInt(toggles.len)) + 6 }, .{
                .size = 13,
                .color = gfx.Color.hex(0x9aa7d0),
            });
            try list.text3d(font, "RobotExpressive", math.add(player.position, .{ 0, 2.2, 0 }), .{ .size = 0.16 });
        }
        const presented = try renderer.render(.{
            .views = &.{.{
                .draw_lists = &.{&list},
                .scene = scene,
                .camera = camera.update(window, focus, dt),
                .settings = settings,
            }},
            .delta_time = dt,
        });
        if (!presented) {
            try init.io.sleep(std.Io.Duration.fromMilliseconds(10), .awake);
            continue;
        }
        frames += 1;
        title_frames += 1;

        if (now - title_time >= 0.5) {
            var gpu_ms: f32 = 0;
            for (renderer.device.passTimings()) |timing| {
                if (timing.depth == 0) gpu_ms += timing.milliseconds;
            }
            const stats = renderer.getStats();
            hud_text = try std.fmt.bufPrint(&hud_buffer, "{d:.0} fps · gpu {d:.2} ms\n{d} / {d} meshlets drawn · {d}k triangles{s}{s}{s}", .{
                @as(f64, @floatFromInt(title_frames)) / (now - title_time),
                gpu_ms,
                stats.meshlets_drawn,
                stats.meshlets,
                stats.triangles / 1000,
                if (stats.models_loading != 0) "\nstreaming assets..." else "",
                "",
                aim_text,
            });
            title_time = now;
            title_frames = 0;
        }
    }

    try renderer.device.waitIdle();
    if (renderer.device.validationErrorCount() != 0) return error.ValidationFailed;
}

/// Edge-triggered key presses for toggles.
const KeyLatch = struct {
    down: [glfw.GLFW_KEY_LAST + 1]bool = @splat(false),

    fn pressed(self: *KeyLatch, window: Window, key: c_int) bool {
        const is_down = window.keyDown(key);
        defer self.down[@intCast(key)] = is_down;
        return is_down and !self.down[@intCast(key)];
    }
};
