//! What happens to the picture after the scene is drawn: each effect on
//! its own key, so its part in the result can be seen by switching it.
//!
//!   1 bloom            2 depth of field     3 motion blur
//!   4 vignette         5 film grain         6 color fringes
//!   7 lens flare       8 warm grade         9 sharpening
//!   0 antialiasing     U render at 67% and upscale
//!   X exposure by hand or automatic
//!   A/D orbit the camera, Space pauses
//!
//! `--all 1` starts with everything on. `--frames N`,
//! `--screenshot file.png`.
const std = @import("std");
const gfx = @import("limn");
const math = gfx.math;
const glfw = @import("glfw");
const helpers = @import("window");
const Stage = helpers.Stage;

pub fn main(init: std.process.Init) !void {
    var stage = try Stage.create(init, "Limn post effects", .{});
    const renderer = stage.renderer;
    const scene = try renderer.createScene();

    const sky_desc = gfx.SkyDesc{ .sun_direction = .{ 0.55, -0.22, -0.8 } };
    renderer.setEnvironment(scene, try renderer.createSky(sky_desc), 1);
    renderer.setSun(scene, gfx.skySun(sky_desc));

    var box_positions: [24][3]f32 = undefined;
    var box_indices: [36]u32 = undefined;
    helpers.boxMesh(.{ 0.5, 0.5, 0.5 }, &box_positions, &box_indices);
    const block = try renderer.createModel(&.{.{ .positions = &box_positions, .indices = &box_indices, .material = .{ .base_color = .{ 0.6, 0.6, 0.62, 1 }, .metallic = 0, .roughness = 0.45 } }});
    _ = try renderer.spawn(scene, .{ .model = block, .transform = math.mul(math.translation(.{ 0, -0.25, 0 }), math.scaling(.{ 60, 0.5, 60 })), .tint = .{ 0.5, 0.5, 0.52 } });
    var posts: [40]math.Mat4 = undefined;
    for (&posts, 0..) |*post, index| {
        const along: f32 = @floatFromInt(index / 2);
        const side: f32 = if (index % 2 == 0) -1 else 1;
        post.* = math.mul(math.translation(.{ side * 2.2, 1, 4 - along * 2.6 }), math.scaling(.{ 0.3, 2, 0.3 }));
    }
    _ = try renderer.createInstances(scene, block, &posts);
    const lamp_colors = [_][3]f32{ .{ 14, 3, 1 }, .{ 1.5, 10, 4 }, .{ 2, 5, 16 }, .{ 14, 10, 1 } };
    var lamps: [lamp_colors.len]gfx.Entity = undefined;
    var sphere_positions: [helpers.sphere_vertex_count][3]f32 = undefined;
    var sphere_normals: [helpers.sphere_vertex_count][3]f32 = undefined;
    var sphere_indices: [helpers.sphere_index_count]u32 = undefined;
    helpers.sphereMesh(0.22, &sphere_positions, &sphere_normals, &sphere_indices);
    for (lamp_colors, &lamps) |color, *lamp| {
        const model = try renderer.createModel(&.{.{ .positions = &sphere_positions, .normals = &sphere_normals, .indices = &sphere_indices, .material = .{ .base_color = .{ 0, 0, 0, 1 }, .emissive = color, .metallic = 0, .roughness = 0.5 } }});
        lamp.* = try renderer.spawn(scene, .{ .model = model });
    }
    const helmet = try renderer.loadModel("examples/assets/DamagedHelmet.glb");
    _ = try renderer.spawn(scene, .{ .model = helmet, .transform = math.mul(math.translation(.{ 0, 1.3, 0 }), math.mul(math.rotationY(0.5), math.rotationX(std.math.pi * 0.5))) });
    try renderer.waitUntilLoaded();

    const Effect = enum { bloom, dof, motion_blur, vignette, grain, fringes, flare, grade, sharpen, antialiasing, upscale, manual_exposure };
    const names = [_]struct { key: []const u8, name: []const u8, code: c_int }{
        .{ .key = "1", .name = "bloom", .code = glfw.GLFW_KEY_1 },
        .{ .key = "2", .name = "depth of field", .code = glfw.GLFW_KEY_2 },
        .{ .key = "3", .name = "motion blur", .code = glfw.GLFW_KEY_3 },
        .{ .key = "4", .name = "vignette", .code = glfw.GLFW_KEY_4 },
        .{ .key = "5", .name = "film grain", .code = glfw.GLFW_KEY_5 },
        .{ .key = "6", .name = "color fringes", .code = glfw.GLFW_KEY_6 },
        .{ .key = "7", .name = "lens flare", .code = glfw.GLFW_KEY_7 },
        .{ .key = "8", .name = "warm grade", .code = glfw.GLFW_KEY_8 },
        .{ .key = "9", .name = "sharpening", .code = glfw.GLFW_KEY_9 },
        .{ .key = "0", .name = "antialiasing", .code = glfw.GLFW_KEY_0 },
        .{ .key = "U", .name = "render at 67%", .code = glfw.GLFW_KEY_U },
        .{ .key = "X", .name = "exposure by hand", .code = glfw.GLFW_KEY_X },
    };
    var on = std.EnumArray(Effect, bool).initFill(false);
    on.set(.bloom, true);
    on.set(.sharpen, true);
    on.set(.antialiasing, true);
    {
        var arguments = try init.minimal.args.iterateAllocator(init.gpa);
        defer arguments.deinit();
        while (arguments.next()) |argument| {
            if (std.mem.eql(u8, argument, "--all")) for ([_]Effect{ .dof, .motion_blur, .vignette, .grain, .fringes, .flare, .grade }) |effect| on.set(effect, true);
        }
    }

    var list = gfx.DrawList.init(init.gpa);
    defer list.deinit();
    const font = renderer.defaultFont();
    var orbit: f32 = 0.15;
    var clock: f32 = 0;
    var moving = true;
    var hud_buffer: [96]u8 = undefined;

    while (stage.begin()) |tick| {
        for (names, 0..) |entry, index| {
            if (stage.keyPressed(entry.code)) {
                const effect: Effect = @enumFromInt(index);
                on.set(effect, !on.get(effect));
            }
        }
        if (stage.keyDown(glfw.GLFW_KEY_A)) orbit -= tick.dt * 0.8;
        if (stage.keyDown(glfw.GLFW_KEY_D)) orbit += tick.dt * 0.8;
        if (stage.keyPressed(glfw.GLFW_KEY_SPACE)) moving = !moving;
        if (moving) clock += tick.dt;

        for (lamps, 0..) |lamp, index| {
            const angle = clock * 2.2 + @as(f32, @floatFromInt(index)) * std.math.tau / lamps.len;
            renderer.setTransform(lamp, math.translation(.{ @cos(angle) * 1.6, 1.3 + 0.5 * @sin(angle * 0.7), @sin(angle) * 1.6 }));
        }

        const settings = gfx.Settings{
            .shadow_distance = 60,
            .bloom = if (on.get(.bloom)) 0.08 else 0,
            .dof_aperture = if (on.get(.dof)) 1.2 else 0,
            .dof_focus_distance = 7,
            .motion_blur = if (on.get(.motion_blur)) 0.6 else 0,
            .vignette = if (on.get(.vignette)) 0.45 else 0,
            .film_grain = if (on.get(.grain)) 0.35 else 0,
            .chromatic_aberration = if (on.get(.fringes)) 0.6 else 0,
            .lens_flare = if (on.get(.flare)) 0.5 else 0,
            .temperature = if (on.get(.grade)) 0.35 else 0,
            .saturation = if (on.get(.grade)) 1.2 else 1,
            .contrast = if (on.get(.grade)) 1.12 else 1,
            .sharpen = if (on.get(.sharpen)) 0.35 else 0,
            .temporal_antialiasing = on.get(.antialiasing),
            .render_scale = if (on.get(.upscale)) 0.67 else 1,
            .automatic_exposure = !on.get(.manual_exposure),
            .exposure_compensation = if (on.get(.manual_exposure)) -0.5 else 0,
        };

        list.clear();
        try list.rect(.{ .x = 12, .y = 12, .width = 300, .height = 54 + 19 * @as(f32, @floatFromInt(names.len)) }, gfx.Color.rgba(10, 12, 20, 180));
        try list.text(font, try std.fmt.bufPrint(&hud_buffer, "{d:.0} fps · gpu {d:.2} ms", .{ stage.fps, stage.gpu_ms }), .{ 24, 20 }, .{ .size = 16 });
        for (names, 0..) |entry, index| {
            const y = 46 + 19 * @as(f32, @floatFromInt(index));
            const lit = on.get(@enumFromInt(index));
            try list.text(font, entry.key, .{ 24, y }, .{ .size = 14, .color = gfx.Color.hex(0x9aa7d0) });
            try list.text(font, entry.name, .{ 50, y }, .{ .size = 14 });
            try list.text(font, if (lit) "on" else "off", .{ 250, y }, .{ .size = 14, .color = if (lit) gfx.Color.hex(0x3ddc97) else gfx.Color.hex(0x7c8499) });
        }

        const eye = math.Vec3{ @sin(orbit) * 7, 1.9, @cos(orbit) * 7 };
        try stage.end(try renderer.render(.{
            .views = &.{.{
                .scene = scene,
                .camera = gfx.Camera.lookAt(eye, .{ 0, 1.2, 0 }),
                .draw_lists = &.{&list},
                .target = stage.target(),
                .settings = settings,
            }},
            .delta_time = tick.dt,
        }));
    }
    try stage.finish();
}
