//! Volumetric clouds over hills and a ridge of mountains.
//!
//!   Up/Down     more or less cloud cover
//!   Left/Right  thinner or denser clouds
//!   W/S         climb or descend (fly up through the layer)
//!   A/D         turn
//!   T           hold to move the sun through the day
//!   C           clouds on or off
//!   F           temporal filter on or off (off shows the raw march)
//!
//! `--altitude N`, `--sun N`, `--night 1`, `--clear 1`, `--storm 1`, `--frames N`,
//! `--screenshot file.png`.
const std = @import("std");
const gfx = @import("limn");
const math = gfx.math;
const glfw = @import("glfw");
const Stage = @import("window").Stage;

pub fn main(init: std.process.Init) !void {
    var stage = try Stage.create(init, "Limn clouds", .{});
    const renderer = stage.renderer;
    const scene = try renderer.createScene();
    var sun_height: f32 = 0.75;
    var sky_desc = gfx.SkyDesc{ .sun_direction = .{ -0.6 * @cos(sun_height), -@sin(sun_height), -0.5 } };
    renderer.setSun(scene, gfx.skySun(sky_desc));
    const environment = try renderer.createSky(sky_desc);
    renderer.setEnvironment(scene, environment, 1);

    // Land for the sky to stand over: rolling hills that rise to a ridge
    // of mountains, colored by height and slope, with firs on the slopes
    // near the camera to give it scale.
    const cells = 360;
    const extent = 9000.0;
    const land_positions = try init.gpa.alloc([3]f32, (cells + 1) * (cells + 1));
    defer init.gpa.free(land_positions);
    const land_normals = try init.gpa.alloc([3]f32, land_positions.len);
    defer init.gpa.free(land_normals);
    const land_colors = try init.gpa.alloc([4]f32, land_positions.len);
    defer init.gpa.free(land_colors);
    const land_indices = try init.gpa.alloc(u32, cells * cells * 6);
    defer init.gpa.free(land_indices);
    for (0..cells + 1) |row| for (0..cells + 1) |column| {
        const x = (@as(f32, @floatFromInt(column)) / cells - 0.5) * extent;
        const z = (@as(f32, @floatFromInt(row)) / cells - 0.5) * extent;
        const height = landHeight(x, z);
        const step = 6.0;
        const normal = math.normalize(math.Vec3{ landHeight(x - step, z) - landHeight(x + step, z), 2 * step, landHeight(x, z - step) - landHeight(x, z + step) });
        const slope = 1 - normal[1];
        const patch = 0.5 + 0.5 * @sin(x * 0.011 + @sin(z * 0.007) * 2.0) * @cos(z * 0.009);
        var color = math.Vec3{ 0.10 + 0.05 * patch, 0.19 + 0.06 * patch, 0.06 };
        // Bare rock where it is steep, snow where it is high.
        color = math.lerp(color, .{ 0.27, 0.25, 0.23 }, std.math.clamp(slope * 5 - 0.6, 0, 1));
        color = math.lerp(color, .{ 0.85, 0.87, 0.9 }, std.math.clamp((height - 520 + 160 * slope) / 120, 0, 1));
        const index = row * (cells + 1) + column;
        land_positions[index] = .{ x, height, z };
        land_normals[index] = normal;
        land_colors[index] = .{ color[0], color[1], color[2], 1 };
    };
    for (0..cells) |row| for (0..cells) |column| {
        const corner: u32 = @intCast(row * (cells + 1) + column);
        land_indices[(row * cells + column) * 6 ..][0..6].* = .{ corner, corner + cells + 1, corner + 1, corner + 1, corner + cells + 1, corner + cells + 2 };
    };
    const land = try renderer.createModel(&.{.{ .positions = land_positions, .normals = land_normals, .colors = land_colors, .indices = land_indices, .material = .{ .metallic = 0, .roughness = 0.95 } }});
    _ = try renderer.spawn(scene, .{ .model = land });

    // A fir: a trunk and three skirts, each a ring of triangles to a point.
    var fir_positions: [4 * 9][3]f32 = undefined;
    var fir_normals: [4 * 9][3]f32 = undefined;
    var fir_colors: [4 * 9][4]f32 = undefined;
    var fir_indices: [4 * 8 * 3]u32 = undefined;
    const tiers = [4][3]f32{ .{ 0, 0.35, 0.05 }, .{ 0.22, 0.62, 0.26 }, .{ 0.45, 0.82, 0.2 }, .{ 0.66, 1.0, 0.13 } };
    for (tiers, 0..) |tier, tier_index| {
        const trunk = tier_index == 0;
        for (0..8) |side| {
            const angle = @as(f32, @floatFromInt(side)) / 8 * std.math.tau;
            const at = tier_index * 9 + side;
            fir_positions[at] = .{ @cos(angle) * tier[2], tier[0], @sin(angle) * tier[2] };
            fir_normals[at] = math.normalize(math.Vec3{ @cos(angle), 0.45, @sin(angle) });
            fir_colors[at] = if (trunk) .{ 0.2, 0.14, 0.09, 1 } else .{ 0.04, 0.12, 0.06, 1 };
            fir_indices[(tier_index * 8 + side) * 3 ..][0..3].* = .{ @intCast(at), @intCast(tier_index * 9 + 8), @intCast(tier_index * 9 + (side + 1) % 8) };
        }
        fir_positions[tier_index * 9 + 8] = .{ 0, tier[1], 0 };
        fir_normals[tier_index * 9 + 8] = .{ 0, 1, 0 };
        fir_colors[tier_index * 9 + 8] = if (trunk) .{ 0.2, 0.14, 0.09, 1 } else .{ 0.1, 0.24, 0.11, 1 };
    }
    const fir = try renderer.createModel(&.{.{ .positions = &fir_positions, .normals = &fir_normals, .colors = &fir_colors, .indices = &fir_indices, .material = .{ .metallic = 0, .roughness = 0.9, .double_sided = true } }});
    var random = std.Random.DefaultPrng.init(7);
    const rng = random.random();
    const firs = try init.gpa.alloc(math.Mat4, 6000);
    defer init.gpa.free(firs);
    var placed: usize = 0;
    while (placed < firs.len) {
        const x = (rng.float(f32) - 0.5) * 3600;
        const z = 200 - rng.float(f32) * 3200;
        const height = landHeight(x, z);
        // In stands, below the tree line, and not where the camera is.
        const stand = @sin(x * 0.013 + 1.0) * @cos(z * 0.011) + 0.4 * @sin(x * 0.041 + z * 0.037);
        if (stand < 0.15 or height > 430 or (@abs(x) < 40 and @abs(z - 60) < 60)) continue;
        const size = 9 + rng.float(f32) * 9;
        firs[placed] = math.mul(math.translation(.{ x, height - 0.5, z }), math.mul(math.rotationY(rng.float(f32) * std.math.tau), math.scaling(.{ size, size * (1.4 + rng.float(f32) * 0.6), size })));
        placed += 1;
    }
    _ = try renderer.createInstances(scene, fir, firs);
    try renderer.waitUntilLoaded();

    // A veil of high cloud over the main layer.
    var clouds = gfx.CloudDesc{ .cirrus = 0.35, .coverage = 0.42, .density = 0.03, .thickness = 2200, .variation = 0.9, .detail = 0.5 };
    // A little haze, so the mountains fade toward the sky.
    var settings = gfx.Settings{ .shadow_distance = 900, .global_illumination = false, .aerial_perspective = 0.0006 };
    var list = gfx.DrawList.init(init.gpa);
    defer list.deinit();
    const font = renderer.defaultFont();
    var altitude: f32 = 30;
    // `--altitude N` and `--sun N` (radians above the horizon) set the start.
    var arguments = try init.minimal.args.iterateAllocator(init.gpa);
    defer arguments.deinit();
    while (arguments.next()) |argument| {
        if (std.mem.eql(u8, argument, "--altitude")) altitude = try std.fmt.parseFloat(f32, arguments.next() orelse "30");
        if (std.mem.eql(u8, argument, "--sun")) sun_height = try std.fmt.parseFloat(f32, arguments.next() orelse "0.75");
        // `--clear 1`: no clouds at all, to look at the sky by itself.
        // `--pane 1`: a sheet of red glass above the plain, with tinted shadows on.
        if (std.mem.eql(u8, argument, "--pane")) {
            const corners = [_][3]f32{ .{ -30, 0, -20 }, .{ 30, 0, -20 }, .{ 30, 0, 20 }, .{ -30, 0, 20 } };
            const pane = try renderer.createModel(&.{.{
                .positions = &corners,
                .indices = &.{ 0, 2, 1, 0, 3, 2 },
                .material = .{ .base_color = .{ 0.9, 0.15, 0.1, 0.6 }, .metallic = 0, .roughness = 0.1, .alpha_mode = .blend, .double_sided = true },
            }});
            _ = try renderer.spawn(scene, .{ .model = pane, .transform = math.translation(.{ 0, 22, -110 }) });
            settings.colored_shadows = true;
        }
        if (std.mem.eql(u8, argument, "--clear")) {
            clouds.coverage = 0;
            clouds.cirrus = 0;
        }
        // `--storm 1`: a tall layer with storm cells that tower and spread,
        // and lightning in them.
        if (std.mem.eql(u8, argument, "--storm")) {
            clouds.thickness = 5000;
            clouds.coverage = 0.55;
            clouds.variation = 1.6;
            clouds.anvil = 1;
            clouds.lightning = 40;
            clouds.cirrus = 0;
        }
        // `--night 1`: the sun is down, with stars and a moon ahead.
        if (std.mem.eql(u8, argument, "--night")) {
            sun_height = -0.3;
            sky_desc.stars = 1;
            sky_desc.moon = 1;
            sky_desc.moon_direction = .{ 0.1, -0.35, 1 };
            clouds.coverage = 0.2;
        }
    }
    sky_desc.sun_direction = .{ -0.6 * @cos(sun_height), -@max(@sin(sun_height), -0.05), -0.5 };
    renderer.setSky(environment, sky_desc);
    renderer.setSun(scene, gfx.skySun(sky_desc));
    var heading: f32 = 0;
    var hud_buffer: [200]u8 = undefined;

    while (stage.begin()) |tick| {
        if (stage.keyDown(glfw.GLFW_KEY_UP)) clouds.coverage = @min(clouds.coverage + tick.dt * 0.3, 1);
        if (stage.keyDown(glfw.GLFW_KEY_DOWN)) clouds.coverage = @max(clouds.coverage - tick.dt * 0.3, 0);
        if (stage.keyDown(glfw.GLFW_KEY_RIGHT)) clouds.density = @min(clouds.density * (1 + tick.dt), 0.5);
        if (stage.keyDown(glfw.GLFW_KEY_LEFT)) clouds.density = @max(clouds.density / (1 + tick.dt), 0.002);
        if (stage.keyDown(glfw.GLFW_KEY_W)) altitude = @min(altitude * (1 + tick.dt * 1.5) + tick.dt * 20, 9000);
        if (stage.keyDown(glfw.GLFW_KEY_S)) altitude = @max((altitude - tick.dt * 20) / (1 + tick.dt * 1.5), 2);
        if (stage.keyDown(glfw.GLFW_KEY_A)) heading -= tick.dt * 0.8;
        if (stage.keyDown(glfw.GLFW_KEY_D)) heading += tick.dt * 0.8;
        if (stage.keyPressed(glfw.GLFW_KEY_C)) settings.clouds = !settings.clouds;
        if (stage.keyPressed(glfw.GLFW_KEY_F)) settings.cloud_temporal_filter = !settings.cloud_temporal_filter;
        if (stage.keyDown(glfw.GLFW_KEY_T)) {
            sun_height = @mod(sun_height + tick.dt * 0.25, std.math.pi);
            sky_desc.sun_direction = .{ -0.6 * @cos(sun_height), -@max(@sin(sun_height), -0.05), -0.5 };
            renderer.setSky(environment, sky_desc);
            renderer.setSun(scene, gfx.skySun(sky_desc));
        }
        try renderer.setClouds(scene, clouds);

        list.clear();
        const stats = renderer.getStats();
        try list.rect(.{ .x = 12, .y = 12, .width = 470, .height = 100 }, gfx.Color.rgba(10, 12, 20, 180));
        try list.text(font, try std.fmt.bufPrint(&hud_buffer, "{d:.0} fps · gpu {d:.2} ms · cpu {d:.2} ms\ncover {d:.2} · density {d:.3} · altitude {d:.0} m", .{
            stage.fps, stage.gpu_ms, stats.cpu_ms, clouds.coverage, clouds.density, altitude,
        }), .{ 24, 20 }, .{ .size = 16 });
        try list.text(font, "clouds", .{ 24, 66 }, .{ .size = 14 });
        try list.text(font, if (settings.clouds) "on" else "off", .{ 80, 66 }, .{ .size = 14, .color = if (settings.clouds) gfx.Color.hex(0x3ddc97) else gfx.Color.hex(0x7c8499) });
        try list.text(font, "temporal filter", .{ 130, 66 }, .{ .size = 14 });
        try list.text(font, if (settings.cloud_temporal_filter) "on" else "off", .{ 240, 66 }, .{ .size = 14, .color = if (settings.cloud_temporal_filter) gfx.Color.hex(0x3ddc97) else gfx.Color.hex(0x7c8499) });
        try list.text(font, "Up/Down cover · Left/Right density · W/S altitude · A/D turn · T sun · C · F", .{ 24, 88 }, .{ .size = 13, .color = gfx.Color.hex(0x9aa7d0) });

        const eye = math.Vec3{ 0, landHeight(0, 60) + altitude, 60 };
        const look = math.Vec3{ @sin(heading), 0.22, -@cos(heading) };
        try stage.end(try renderer.render(.{
            .views = &.{.{
                .scene = scene,
                .camera = .{ .position = eye, .forward = look },
                .draw_lists = &.{&list},
                .target = stage.target(),
                .settings = settings,
            }},
            .delta_time = tick.dt,
        }));
    }
    try stage.finish();
}

/// Height of the land at a point: low hills near the camera, a ridge of
/// mountains across the view further off.
fn landHeight(x: f32, z: f32) f32 {
    const hills = 55 * @sin(x * 0.0041) * @cos(z * 0.0036) + 22 * @sin(x * 0.011 + 1.3) * @sin(z * 0.0093) + 6 * @sin(x * 0.031 + z * 0.027);
    const far = std.math.clamp((-z - 900) / 1700, 0, 1);
    const ridge = far * far * (3 - 2 * far) * (430 + 190 * @sin(x * 0.0019 + 0.6) + 90 * @sin(x * 0.0052 + 2.0) + 45 * @sin(x * 0.013 + z * 0.004));
    return hills + ridge;
}
