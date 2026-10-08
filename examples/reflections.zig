//! Glossy surfaces and reflections: a polished checkered floor, a row of
//! spheres from mirror-smooth to rough, lacquered and metal ones behind
//! them, and glowing blocks that drift around so their reflections move.
//!
//!   R        screen-space reflections on/off (off: surfaces mirror only the sky)
//!   F        temporal filter of the reflections on/off
//!   H        trace the reflections at full or half resolution
//!   Up/Down  roughest surface that still gets reflections
//!   O        depth of field, M motion blur
//!   L        the extra lights: a lantern with a size, a spot through a
//!            window frame, a lamp with a ring-shaped profile, a fill light
//!   T        hold to move the sun through the day
//!   A/D      orbit the camera, Space pauses the moving blocks
//!
//! `--half 1`, `--frames N`, `--screenshot file.png`.
const std = @import("std");
const gfx = @import("limn");
const math = gfx.math;
const glfw = @import("glfw");
const helpers = @import("window");
const Stage = helpers.Stage;

const tile = 1.5;
const tiles_per_side = 16;

pub fn main(init: std.process.Init) !void {
    var stage = try Stage.create(init, "Limn reflections", .{});
    const renderer = stage.renderer;
    const scene = try renderer.createScene();

    var sky_desc = gfx.SkyDesc{ .sun_direction = .{ -0.55, -0.5, -0.4 } };
    var sun_height: f32 = 0.52;
    const sky = try renderer.createSky(sky_desc);
    renderer.setEnvironment(scene, sky, 1);
    renderer.setSun(scene, gfx.skySun(sky_desc));

    var box_positions: [24][3]f32 = undefined;
    var box_indices: [36]u32 = undefined;
    helpers.boxMesh(.{ tile * 0.5, 0.05, tile * 0.5 }, &box_positions, &box_indices);
    const dark_tile = try renderer.createModel(&.{.{
        .positions = &box_positions,
        .indices = &box_indices,
        .material = .{ .base_color = .{ 0.03, 0.03, 0.035, 1 }, .metallic = 0, .roughness = 0.06 },
    }});
    const light_tile = try renderer.createModel(&.{.{
        .positions = &box_positions,
        .indices = &box_indices,
        .material = .{ .base_color = .{ 0.55, 0.53, 0.5, 1 }, .metallic = 0, .roughness = 0.16 },
    }});
    var dark: [tiles_per_side * tiles_per_side / 2]math.Mat4 = undefined;
    var light: [tiles_per_side * tiles_per_side / 2]math.Mat4 = undefined;
    var dark_count: usize = 0;
    var light_count: usize = 0;
    for (0..tiles_per_side) |z| for (0..tiles_per_side) |x| {
        const position = math.Vec3{
            (@as(f32, @floatFromInt(x)) - tiles_per_side / 2 + 0.5) * tile,
            -0.05,
            (@as(f32, @floatFromInt(z)) - tiles_per_side / 2 + 0.5) * tile,
        };
        if ((x + z) % 2 == 0) {
            dark[dark_count] = math.translation(position);
            dark_count += 1;
        } else {
            light[light_count] = math.translation(position);
            light_count += 1;
        }
    };
    _ = try renderer.createInstances(scene, dark_tile, dark[0..dark_count]);
    _ = try renderer.createInstances(scene, light_tile, light[0..light_count]);

    var sphere_positions: [helpers.sphere_vertex_count][3]f32 = undefined;
    var sphere_normals: [helpers.sphere_vertex_count][3]f32 = undefined;
    var sphere_indices: [helpers.sphere_index_count]u32 = undefined;
    helpers.sphereMesh(0.6, &sphere_positions, &sphere_normals, &sphere_indices);
    const front = 7;
    var roughness_values: [front]f32 = undefined;
    for (0..front) |index| {
        const roughness = 0.03 + 0.095 * @as(f32, @floatFromInt(index));
        roughness_values[index] = roughness;
        const model = try renderer.createModel(&.{.{
            .positions = &sphere_positions,
            .normals = &sphere_normals,
            .indices = &sphere_indices,
            .material = .{ .base_color = .{ 0.6, 0.6, 0.62, 1 }, .metallic = 0, .roughness = roughness },
        }});
        _ = try renderer.spawn(scene, .{ .model = model, .transform = math.translation(.{ (@as(f32, @floatFromInt(index)) - 3) * 1.6, 0.6, 1.5 }) });
    }
    const back = [_]struct { name: []const u8, material: gfx.Material }{
        .{ .name = "gold", .material = .{ .base_color = .{ 1.0, 0.77, 0.34, 1 }, .metallic = 1, .roughness = 0.12 } },
        .{ .name = "copper", .material = .{ .base_color = .{ 0.95, 0.64, 0.54, 1 }, .metallic = 1, .roughness = 0.3 } },
        .{ .name = "chrome", .material = .{ .base_color = .{ 0.9, 0.9, 0.92, 1 }, .metallic = 1, .roughness = 0.03 } },
        .{ .name = "paint", .material = .{ .base_color = .{ 0.6, 0.03, 0.03, 1 }, .metallic = 0, .roughness = 0.6 } },
        .{ .name = "lacquer", .material = .{ .base_color = .{ 0.6, 0.03, 0.03, 1 }, .metallic = 0, .roughness = 0.6, .clearcoat = 1, .clearcoat_roughness = 0.03 } },
    };
    for (back, 0..) |item, index| {
        const model = try renderer.createModel(&.{.{
            .positions = &sphere_positions,
            .normals = &sphere_normals,
            .indices = &sphere_indices,
            .material = item.material,
        }});
        _ = try renderer.spawn(scene, .{ .model = model, .transform = math.translation(.{ (@as(f32, @floatFromInt(index)) - 2) * 2.0, 0.6, -1.6 }) });
    }

    helpers.boxMesh(.{ 0.25, 0.9, 0.25 }, &box_positions, &box_indices);
    const glow_colors = [_][3]f32{ .{ 6, 0.6, 0.3 }, .{ 0.3, 5, 1.2 }, .{ 0.5, 1.2, 7 }, .{ 6, 4, 0.4 } };
    var glow: [glow_colors.len]gfx.Entity = undefined;
    for (glow_colors, &glow) |color, *entity| {
        const model = try renderer.createModel(&.{.{
            .positions = &box_positions,
            .indices = &box_indices,
            .material = .{ .base_color = .{ 0.02, 0.02, 0.02, 1 }, .emissive = color, .metallic = 0, .roughness = 0.5 },
        }});
        entity.* = try renderer.spawn(scene, .{ .model = model });
    }
    try renderer.waitUntilLoaded();

    var cookie_pixels: [64 * 64 * 4]u8 = undefined;
    for (0..64) |y| for (0..64) |x| {
        const bar = x % 21 < 3 or y % 21 < 3;
        const level: u8 = if (bar) 0 else 255;
        cookie_pixels[(y * 64 + x) * 4 ..][0..4].* = .{ level, level, level, 255 };
    };
    const cookie = try renderer.createImage(64, 64, &cookie_pixels, false);
    const profile = try renderer.createLightProfile(&.{ 0.25, 0.4, 1.0, 0.7, 0.15, 0.0, 0.0 });
    var lights_on = true;

    var list = gfx.DrawList.init(init.gpa);
    defer list.deinit();
    const font = renderer.defaultFont();
    var settings = gfx.Settings{ .shadow_distance = 40, .bloom = 0.06, .dof_focus_distance = 9 };
    {
        var arguments = try init.minimal.args.iterateAllocator(init.gpa);
        defer arguments.deinit();
        while (arguments.next()) |argument| {
            if (std.mem.eql(u8, argument, "--half")) settings.reflection_resolution = .half;
        }
    }
    var orbit: f32 = 0.35;
    var moving = true;
    var clock: f32 = 0;
    var hud_buffer: [96]u8 = undefined;
    var value_buffers: [8][24]u8 = undefined;

    while (stage.begin()) |tick| {
        if (stage.keyPressed(glfw.GLFW_KEY_R)) settings.screen_space_reflections = !settings.screen_space_reflections;
        if (stage.keyPressed(glfw.GLFW_KEY_F)) settings.reflection_temporal_filter = !settings.reflection_temporal_filter;
        if (stage.keyPressed(glfw.GLFW_KEY_H)) settings.reflection_resolution = if (settings.reflection_resolution == .full) .half else .full;
        if (stage.keyPressed(glfw.GLFW_KEY_UP)) settings.reflection_max_roughness = @min(settings.reflection_max_roughness + 0.1, 1.0);
        if (stage.keyPressed(glfw.GLFW_KEY_DOWN)) settings.reflection_max_roughness = @max(settings.reflection_max_roughness - 0.1, 0.1);
        if (stage.keyPressed(glfw.GLFW_KEY_SPACE)) moving = !moving;
        if (stage.keyPressed(glfw.GLFW_KEY_L)) lights_on = !lights_on;
        if (stage.keyPressed(glfw.GLFW_KEY_O)) settings.dof_aperture = if (settings.dof_aperture > 0) 0 else 0.8;
        if (stage.keyPressed(glfw.GLFW_KEY_M)) settings.motion_blur = if (settings.motion_blur > 0) 0 else 0.5;
        if (stage.keyDown(glfw.GLFW_KEY_A)) orbit -= tick.dt * 0.8;
        if (stage.keyDown(glfw.GLFW_KEY_D)) orbit += tick.dt * 0.8;
        if (stage.keyDown(glfw.GLFW_KEY_T)) {
            sun_height = @mod(sun_height + tick.dt * 0.25, std.math.pi);
            sky_desc.sun_direction = .{ -0.55 * @cos(sun_height), -@max(@sin(sun_height), -0.05), -0.4 };
            renderer.setSky(sky, sky_desc);
            renderer.setSun(scene, gfx.skySun(sky_desc));
        }
        if (moving) clock += tick.dt;

        for (glow, 0..) |entity, index| {
            const angle = clock * 0.45 + @as(f32, @floatFromInt(index)) * std.math.tau / glow.len;
            renderer.setTransform(entity, math.mul(
                math.translation(.{ @cos(angle) * 6.5, 0.9 + 0.25 * @sin(clock * 1.3 + @as(f32, @floatFromInt(index))), @sin(angle) * 5.0 }),
                math.rotationY(-angle),
            ));
        }

        try renderer.setLights(scene, if (lights_on) &.{
            .{ .position = .{ -4.5, 1.6, 3.2 }, .color = .{ 1.0, 0.75, 0.45 }, .intensity = 14, .range = 9, .source_radius = 0.45 },
            .{ .kind = .spot, .position = .{ 5.0, 4.5, 3.5 }, .direction = .{ -0.35, -1.0, -0.15 }, .color = .{ 0.8, 0.9, 1.0 }, .intensity = 160, .range = 12, .inner_angle = 0.45, .outer_angle = 0.5, .cookie = cookie, .cast_shadows = true },
            .{ .kind = .spot, .position = .{ 0, 3.2, -4.2 }, .direction = .{ 0, -1, 0 }, .color = .{ 1.0, 0.95, 0.85 }, .intensity = 60, .range = 9, .inner_angle = 1.3, .outer_angle = 1.4, .profile = profile },
            .{ .kind = .directional, .position = .{ 0, 0, 0 }, .direction = .{ 0.7, -0.3, 0.6 }, .color = .{ 0.5, 0.6, 1.0 }, .intensity = 0.25 },
        } else &.{});

        list.clear();
        for (roughness_values, 0..) |roughness, index| {
            const label = try std.fmt.bufPrint(&value_buffers[index], "{d:.2}", .{roughness});
            try list.text3d(font, label, .{ (@as(f32, @floatFromInt(index)) - 3) * 1.6, 1.45, 1.5 }, .{ .size = 0.16 });
        }
        try list.text3d(font, "roughness", .{ -3 * 1.6 - 1.2, 1.45, 1.5 }, .{ .size = 0.16, .color = gfx.Color.hex(0x9aa7d0) });
        for (back, 0..) |item, index| {
            try list.text3d(font, item.name, .{ (@as(f32, @floatFromInt(index)) - 2) * 2.0, 1.5, -1.6 }, .{ .size = 0.18 });
        }

        try list.rect(.{ .x = 12, .y = 12, .width = 400, .height = 180 }, gfx.Color.rgba(10, 12, 20, 180));
        try list.text(font, try std.fmt.bufPrint(&hud_buffer, "{d:.0} fps · gpu {d:.2} ms", .{ stage.fps, stage.gpu_ms }), .{ 24, 20 }, .{ .size = 17 });
        var limit_buffer: [16]u8 = undefined;
        const rows = [_]struct { key: []const u8, label: []const u8, state: []const u8, on: bool }{
            .{ .key = "R", .label = "screen-space reflections", .state = if (settings.screen_space_reflections) "on" else "off (sky only)", .on = settings.screen_space_reflections },
            .{ .key = "F", .label = "temporal filter", .state = if (settings.reflection_temporal_filter) "on" else "off", .on = settings.reflection_temporal_filter },
            .{ .key = "Up/Dn", .label = "roughness limit", .state = try std.fmt.bufPrint(&limit_buffer, "{d:.1}", .{settings.reflection_max_roughness}), .on = true },
            .{ .key = "L", .label = "lantern, cookie, profile", .state = if (lights_on) "on" else "off", .on = lights_on },
            .{ .key = "O", .label = "depth of field", .state = if (settings.dof_aperture > 0) "on" else "off", .on = settings.dof_aperture > 0 },
            .{ .key = "M", .label = "motion blur", .state = if (settings.motion_blur > 0) "on" else "off", .on = settings.motion_blur > 0 },
        };
        for (rows, 0..) |row, index| {
            const y = 46 + 19 * @as(f32, @floatFromInt(index));
            try list.text(font, row.key, .{ 24, y }, .{ .size = 14, .color = gfx.Color.hex(0x9aa7d0) });
            try list.text(font, row.label, .{ 84, y }, .{ .size = 14 });
            try list.text(font, row.state, .{ 290, y }, .{ .size = 14, .color = if (row.on) gfx.Color.hex(0x3ddc97) else gfx.Color.hex(0x7c8499) });
        }
        try list.text(font, "A/D orbit · Space pause blocks · hold T time of day", .{ 24, 165 }, .{ .size = 13, .color = gfx.Color.hex(0x9aa7d0) });

        const eye = math.Vec3{ @sin(orbit) * 10.5, 2.6, @cos(orbit) * 10.5 };
        try stage.end(try renderer.render(.{
            .views = &.{.{
                .scene = scene,
                .camera = gfx.Camera.lookAt(eye, .{ 0, 0.7, 0 }),
                .draw_lists = &.{&list},
                .target = stage.target(),
                .settings = settings,
            }},
            .delta_time = tick.dt,
        }));
    }
    try stage.finish();
}
