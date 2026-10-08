//! What a material can be: a grid of spheres from plastic to metal and
//! from polished to rough, and a row of the rarer kinds (glass, lacquer,
//! velvet, brushed metal, wax), lit only by a photographed studio.
//!
//!   E        switch between the studio and a computed sky
//!   A/D      orbit the camera
//!
//! `--frames N`, `--screenshot file.png`.
const std = @import("std");
const gfx = @import("limn");
const math = gfx.math;
const glfw = @import("glfw");
const helpers = @import("window");
const Stage = helpers.Stage;

const columns = 7;
const rows = 4;
const spacing = 1.35;

pub fn main(init: std.process.Init) !void {
    var stage = try Stage.create(init, "Limn materials", .{});
    const renderer = stage.renderer;
    const scene = try renderer.scenes.create();

    const studio = try renderer.environments.load("examples/assets/studio_small_03_1k.hdr", 64);
    const sky_desc = gfx.SkyDesc{ .sun_direction = .{ -0.5, -0.6, -0.45 } };
    const sky = try renderer.environments.createSky(sky_desc);
    var outdoors = false;
    renderer.scenes.setEnvironment(scene, studio, 1);
    renderer.scenes.setSun(scene, .{ .direction = sky_desc.sun_direction, .intensity = 0 });

    var positions: [helpers.sphere_vertex_count][3]f32 = undefined;
    var normals: [helpers.sphere_vertex_count][3]f32 = undefined;
    var indices: [helpers.sphere_index_count]u32 = undefined;
    helpers.sphereMesh(0.5, &positions, &normals, &indices);

    for (0..rows) |row| for (0..columns) |column| {
        const metallic = @as(f32, @floatFromInt(row)) / (rows - 1);
        const roughness = 0.04 + 0.96 * @as(f32, @floatFromInt(column)) / (columns - 1);
        const model = try renderer.models.create(&.{.{
            .positions = &positions,
            .normals = &normals,
            .indices = &indices,
            .material = .{ .base_color = .{ 0.82, 0.3, 0.16, 1 }, .metallic = metallic, .roughness = roughness },
        }});
        _ = try renderer.entities.spawn(scene, .{ .model = model, .transform = math.translation(.{
            (@as(f32, @floatFromInt(column)) - (columns - 1) * 0.5) * spacing,
            1.2 + @as(f32, @floatFromInt(row)) * spacing,
            -1.5,
        }) });
    };

    const special = [_]struct { name: []const u8, material: gfx.Material }{
        .{ .name = "glass", .material = .{ .base_color = .{ 0.9, 0.97, 1.0, 1 }, .metallic = 0, .roughness = 0.03, .transmission = 1, .ior = 1.5, .thickness = 0.6 } },
        .{ .name = "tinted glass", .material = .{ .base_color = .{ 0.95, 0.55, 0.2, 1 }, .metallic = 0, .roughness = 0.12, .transmission = 1, .ior = 1.45, .thickness = 0.8 } },
        .{ .name = "lacquer", .material = .{ .base_color = .{ 0.5, 0.02, 0.03, 1 }, .metallic = 0, .roughness = 0.55, .clearcoat = 1, .clearcoat_roughness = 0.03 } },
        .{ .name = "velvet", .material = .{ .base_color = .{ 0.16, 0.03, 0.22, 1 }, .metallic = 0, .roughness = 0.9, .sheen_color = .{ 0.9, 0.6, 1.0 }, .sheen_roughness = 0.35 } },
        .{ .name = "brushed metal", .material = .{ .base_color = .{ 0.85, 0.86, 0.9, 1 }, .metallic = 1, .roughness = 0.35, .anisotropy = 0.9 } },
        .{ .name = "wax", .material = .{ .base_color = .{ 0.9, 0.78, 0.6, 1 }, .metallic = 0, .roughness = 0.45, .subsurface = 1 } },
        .{ .name = "glowing", .material = .{ .base_color = .{ 0.02, 0.02, 0.02, 1 }, .emissive = .{ 0.4, 2.5, 4.0 }, .metallic = 0, .roughness = 0.5 } },
    };
    for (special, 0..) |item, index| {
        const model = try renderer.models.create(&.{.{ .positions = &positions, .normals = &normals, .indices = &indices, .material = item.material }});
        _ = try renderer.entities.spawn(scene, .{ .model = model, .transform = math.translation(.{ (@as(f32, @floatFromInt(index)) - @as(f32, special.len - 1) * 0.5) * spacing, 0.5, 1.2 }) });
    }

    var box_positions: [24][3]f32 = undefined;
    var box_indices: [36]u32 = undefined;
    helpers.boxMesh(.{ 9, 0.05, 6 }, &box_positions, &box_indices);
    const floor = try renderer.models.create(&.{.{ .positions = &box_positions, .indices = &box_indices, .material = .{ .base_color = .{ 0.2, 0.2, 0.21, 1 }, .metallic = 0, .roughness = 0.35 } }});
    _ = try renderer.entities.spawn(scene, .{ .model = floor, .transform = math.translation(.{ 0, -0.05, 0 }) });
    const helmet = try renderer.models.load("examples/assets/DamagedHelmet.glb");
    _ = try renderer.entities.spawn(scene, .{ .model = helmet, .transform = math.mul(math.translation(.{ 6.2, 1.0, 0.3 }), math.mul(math.rotationY(-0.7), math.rotationX(std.math.pi * 0.5))) });
    try renderer.waitUntilLoaded();

    var list = gfx.DrawList.init(init.gpa);
    defer list.deinit();
    const font = renderer.fonts.default();
    var orbit: f32 = 0.25;
    var hud_buffer: [96]u8 = undefined;

    while (stage.begin()) |tick| {
        if (stage.keyDown(glfw.GLFW_KEY_A)) orbit -= tick.dt * 0.8;
        if (stage.keyDown(glfw.GLFW_KEY_D)) orbit += tick.dt * 0.8;
        if (stage.keyPressed(glfw.GLFW_KEY_E)) {
            outdoors = !outdoors;
            renderer.scenes.setEnvironment(scene, if (outdoors) sky else studio, 1);
            renderer.scenes.setSun(scene, if (outdoors) gfx.skySun(sky_desc) else .{ .direction = sky_desc.sun_direction, .intensity = 0 });
        }

        list.clear();
        for (special, 0..) |item, index|
            try list.text3d(font, item.name, .{ (@as(f32, @floatFromInt(index)) - @as(f32, special.len - 1) * 0.5) * spacing, 1.2, 1.2 }, .{ .size = 0.13 });
        try list.text3d(font, "rougher to the right", .{ 0, 1.2 + rows * spacing - 0.55, -1.5 }, .{ .size = 0.16, .color = gfx.Color.hex(0x9aa7d0) });
        try list.text3d(font, "more metal upward", .{ -(columns + 1) * 0.5 * spacing, 1.2 + (rows - 1) * 0.5 * spacing, -1.5 }, .{ .size = 0.16, .color = gfx.Color.hex(0x9aa7d0) });
        try list.rect(.{ .x = 12, .y = 12, .width = 380, .height = 58 }, gfx.Color.rgba(10, 12, 20, 180));
        try list.text(font, try std.fmt.bufPrint(&hud_buffer, "{d:.0} fps · gpu {d:.2} ms · lit by {s}", .{ stage.fps, stage.gpu_ms, if (outdoors) "the sky" else "a studio photograph" }), .{ 24, 20 }, .{ .size = 16 });
        try list.text(font, "E environment · A/D orbit", .{ 24, 46 }, .{ .size = 13, .color = gfx.Color.hex(0x9aa7d0) });

        const eye = math.Vec3{ @sin(orbit) * 11, 3.4, @cos(orbit) * 11 };
        try stage.end(try renderer.render(.{
            .views = &.{.{
                .scene = scene,
                .camera = gfx.Camera.lookAt(eye, .{ 0.6, 2.2, 0 }),
                .draw_lists = &.{&list},
                .target = stage.target(),
                .settings = .{ .shadow_distance = 30 },
            }},
            .delta_time = tick.dt,
        }));
    }
    try stage.finish();
}
