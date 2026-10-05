//! A material written by the application: molten rock, from
//! `examples/shaders/lava.frag`. The shader only says what the surface
//! is (its color, roughness, glow and normal) at each point; lighting,
//! shadows, reflections and antialiasing stay the renderer's. Each block
//! passes its own number to the shader, so one cools while the next
//! stays molten.
//!
//!   Up/Down  how brightly the cracks glow
//!   A/D      orbit the camera
//!
//! `--frames N`, `--screenshot file.png`.
const std = @import("std");
const gfx = @import("limn");
const math = gfx.math;
const glfw = @import("glfw");
const helpers = @import("window");
const Stage = helpers.Stage;

pub fn main(init: std.process.Init) !void {
    var stage = try Stage.create(init, "Limn custom material", .{});
    const renderer = stage.renderer;
    const scene = try renderer.createScene();

    const sky_desc = gfx.SkyDesc{ .sun_direction = .{ -0.5, -0.3, -0.6 } };
    renderer.setEnvironment(scene, try renderer.createSky(sky_desc), 0.6);
    renderer.setSun(scene, gfx.skySun(sky_desc));

    // The shader is compiled to SPIR-V by the build (see `build.zig`) and
    // handed over as bytes.
    const lava = try renderer.createMaterialShader(@embedFile("lava.frag.spv"));

    var sphere_positions: [helpers.sphere_vertex_count][3]f32 = undefined;
    var sphere_normals: [helpers.sphere_vertex_count][3]f32 = undefined;
    var sphere_indices: [helpers.sphere_index_count]u32 = undefined;
    helpers.sphereMesh(1.0, &sphere_positions, &sphere_normals, &sphere_indices);
    // `params` are the material's own numbers, read by the shader: here
    // the scale of the pattern and the strength of the glow.
    var glow: f32 = 3;
    const molten = try renderer.createModel(&.{.{
        .positions = &sphere_positions,
        .normals = &sphere_normals,
        .indices = &sphere_indices,
        .material = .{ .metallic = 0, .roughness = 0.8, .shader = lava.slot, .params = .{ 2.5, glow, 0, 0 } },
    }});
    var box_positions: [24][3]f32 = undefined;
    var box_indices: [36]u32 = undefined;
    helpers.boxMesh(.{ 0.5, 0.5, 0.5 }, &box_positions, &box_indices);
    const ground = try renderer.createModel(&.{.{ .positions = &box_positions, .indices = &box_indices, .material = .{ .base_color = .{ 0.12, 0.11, 0.1, 1 }, .metallic = 0, .roughness = 0.6 } }});
    _ = try renderer.spawn(scene, .{ .model = ground, .transform = math.mul(math.translation(.{ 0, -0.25, 0 }), math.scaling(.{ 30, 0.5, 30 })) });

    // Five of the same model. `params` on an entity are that entity's own
    // numbers: here how far it has cooled.
    const count = 5;
    var balls: [count]gfx.Entity = undefined;
    for (&balls, 0..) |*ball, index| {
        const cooled = @as(f32, @floatFromInt(index)) / (count - 1);
        ball.* = try renderer.spawn(scene, .{
            .model = molten,
            .transform = math.translation(.{ (@as(f32, @floatFromInt(index)) - (count - 1) * 0.5) * 2.6, 1.0, 0 }),
            .params = .{ cooled, 0, 0, 0 },
        });
    }
    try renderer.waitUntilLoaded();

    var list = gfx.DrawList.init(init.gpa);
    defer list.deinit();
    const font = renderer.defaultFont();
    var orbit: f32 = 0.3;
    var hud_buffer: [96]u8 = undefined;

    while (stage.begin()) |tick| {
        if (stage.keyDown(glfw.GLFW_KEY_A)) orbit -= tick.dt * 0.8;
        if (stage.keyDown(glfw.GLFW_KEY_D)) orbit += tick.dt * 0.8;
        var changed = false;
        if (stage.keyPressed(glfw.GLFW_KEY_UP)) {
            glow = @min(glow + 1, 10);
            changed = true;
        }
        if (stage.keyPressed(glfw.GLFW_KEY_DOWN)) {
            glow = @max(glow - 1, 0);
            changed = true;
        }
        // A material's shader and numbers can be replaced at any time.
        if (changed) try renderer.setMaterialShader(molten, null, lava, .{ 2.5, glow, 0, 0 });

        list.clear();
        try list.text3d(font, "molten", .{ -(count - 1) * 0.5 * 2.6, 2.4, 0 }, .{ .size = 0.2 });
        try list.text3d(font, "cooled", .{ (count - 1) * 0.5 * 2.6, 2.4, 0 }, .{ .size = 0.2 });
        try list.rect(.{ .x = 12, .y = 12, .width = 330, .height = 58 }, gfx.Color.rgba(10, 12, 20, 180));
        try list.text(font, try std.fmt.bufPrint(&hud_buffer, "{d:.0} fps · gpu {d:.2} ms · glow {d:.0}", .{ stage.fps, stage.gpu_ms, glow }), .{ 24, 20 }, .{ .size = 16 });
        try list.text(font, "Up/Down glow · A/D orbit", .{ 24, 46 }, .{ .size = 13, .color = gfx.Color.hex(0x9aa7d0) });

        const eye = math.Vec3{ @sin(orbit) * 10, 3.2, @cos(orbit) * 10 };
        try stage.end(try renderer.render(.{
            .views = &.{.{
                .scene = scene,
                .camera = gfx.Camera.lookAt(eye, .{ 0, 1, 0 }),
                .draw_lists = &.{&list},
                .target = stage.target(),
                .settings = .{ .shadow_distance = 30, .bloom = 0.08 },
            }},
            .delta_time = tick.dt,
        }));
    }
    try stage.finish();
}
