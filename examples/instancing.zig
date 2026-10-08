//! Instance groups: a forest of simple trees placed with one call.
//!
//!   Up/Down  double or halve the number of trees
//!   R        scatter them again (a new set of transforms)
//!   M        sway: rewrite every transform every frame
//!   A/D      orbit the camera
//!   T        hold to move the sun through the day (computed sky)
//!
//! The tree under the middle of the screen is picked and marked. Each tree
//! is two meshes (trunk and crown), so one copy is two GPU instances.
//! `--frames N`, `--screenshot file.png`.
const std = @import("std");
const gfx = @import("limn");
const math = gfx.math;
const glfw = @import("glfw");
const Stage = @import("window").Stage;
const boxMesh = @import("window").boxMesh;

const field = 220.0;

const Tree = struct {
    position: math.Vec3,
    turn: f32,
    scale: f32,

    fn transform(self: Tree, lean: f32) math.Mat4 {
        return math.mul(math.translation(self.position), math.mul(math.rotationY(self.turn), math.mul(math.rotationX(lean), math.uniformScaling(self.scale))));
    }
};

fn scatter(trees: []Tree, seed: u64) void {
    var random = std.Random.DefaultPrng.init(seed);
    const rng = random.random();
    for (trees) |*tree| tree.* = .{
        .position = .{ (rng.float(f32) - 0.5) * field, 0, (rng.float(f32) - 0.5) * field },
        .turn = rng.float(f32) * std.math.tau,
        .scale = 0.6 + rng.float(f32) * 0.9,
    };
}

pub fn main(init: std.process.Init) !void {
    var stage = try Stage.create(init, "Limn instancing", .{});
    const renderer = stage.renderer;
    const scene = try renderer.scenes.create();
    var sun_height: f32 = 0.55;
    var sky_desc = gfx.SkyDesc{ .sun_direction = .{ -0.5, -@sin(sun_height), -0.45 } };
    renderer.scenes.setSun(scene, gfx.skySun(sky_desc));
    const environment = try renderer.environments.createSky(sky_desc);
    renderer.scenes.setEnvironment(scene, environment, 1);

    var positions: [3][24][3]f32 = undefined;
    var indices: [3][36]u32 = undefined;
    boxMesh(.{ field * 0.6, 0.1, field * 0.6 }, &positions[0], &indices[0]);
    boxMesh(.{ 0.07, 0.5, 0.07 }, &positions[1], &indices[1]);
    boxMesh(.{ 0.32, 0.42, 0.32 }, &positions[2], &indices[2]);
    for (&positions[1]) |*p| p[1] += 0.5;
    for (&positions[2]) |*p| p[1] += 1.3;
    const ground = try renderer.models.create(&.{.{
        .positions = &positions[0],
        .indices = &indices[0],
        .material = .{ .base_color = .{ 0.16, 0.22, 0.12, 1 }, .metallic = 0, .roughness = 0.9 },
    }});
    _ = try renderer.entities.spawn(scene, .{ .model = ground, .transform = math.translation(.{ 0, -0.1, 0 }) });
    const tree = try renderer.models.create(&.{
        .{ .positions = &positions[1], .indices = &indices[1], .material = .{ .base_color = .{ 0.27, 0.17, 0.09, 1 }, .metallic = 0, .roughness = 0.9 } },
        .{ .positions = &positions[2], .indices = &indices[2], .material = .{ .base_color = .{ 0.12, 0.42, 0.14, 1 }, .metallic = 0, .roughness = 0.8 } },
    });
    try renderer.waitUntilLoaded();

    const max_trees = 1 << 18;
    const trees = try init.gpa.alloc(Tree, max_trees);
    defer init.gpa.free(trees);
    const transforms = try init.gpa.alloc(math.Mat4, max_trees);
    defer init.gpa.free(transforms);
    var count: usize = 1 << 14;
    var seed: u64 = 1;
    scatter(trees, seed);
    for (trees[0..count], transforms[0..count]) |item, *out| out.* = item.transform(0);
    const forest = try renderer.instances.create(scene, tree, transforms[0..count]);

    var list = gfx.DrawList.init(init.gpa);
    defer list.deinit();
    const font = renderer.fonts.default();
    var sway = false;
    var orbit: f32 = 0.5;
    var picked: ?u32 = null;
    var hud_buffer: [160]u8 = undefined;
    var pick_buffer: [64]u8 = undefined;

    while (stage.begin()) |tick| {
        var changed = false;
        if (stage.keyPressed(glfw.GLFW_KEY_UP) and count < max_trees) {
            count *= 2;
            changed = true;
        }
        if (stage.keyPressed(glfw.GLFW_KEY_DOWN) and count > 64) {
            count /= 2;
            changed = true;
        }
        if (stage.keyPressed(glfw.GLFW_KEY_R)) {
            seed += 1;
            scatter(trees, seed);
            changed = true;
        }
        if (stage.keyPressed(glfw.GLFW_KEY_M)) {
            sway = !sway;
            changed = true;
        }
        if (stage.keyDown(glfw.GLFW_KEY_A)) orbit -= tick.dt * 0.8;
        if (stage.keyDown(glfw.GLFW_KEY_D)) orbit += tick.dt * 0.8;
        orbit += tick.dt * 0.05;
        if (stage.keyDown(glfw.GLFW_KEY_T)) {
            sun_height = @mod(sun_height + tick.dt * 0.25, std.math.pi);
            sky_desc.sun_direction = .{ -0.5 * @cos(sun_height), -@max(@sin(sun_height), -0.05), -0.45 };
            renderer.environments.setSky(environment, sky_desc);
            renderer.scenes.setSun(scene, gfx.skySun(sky_desc));
        }

        if (changed or sway) {
            for (trees[0..count], transforms[0..count]) |item, *out| {
                const lean = if (sway) @sin(tick.time * 1.6 + item.position[0] * 0.25 + item.position[2] * 0.18) * 0.12 else 0;
                out.* = item.transform(lean);
            }
            try renderer.instances.set(forest, transforms[0..count]);
            if (changed) picked = null;
        }

        renderer.requestPick(null, .{ tick.size[0] / 2, tick.size[1] / 2 });
        if (renderer.takePick()) |result| {
            picked = if (result.hit) |hit| (if (hit.instances != null) hit.copy else null) else null;
        }

        list.clear();
        if (picked) |copy| if (copy < count) {
            const item = trees[copy];
            const low = math.add(item.position, .{ -0.4 * item.scale, 0, -0.4 * item.scale });
            const high = math.add(item.position, .{ 0.4 * item.scale, 1.8 * item.scale, 0.4 * item.scale });
            try list.box3d(low, high, 2, gfx.Color.hex(0xffd23f));
        };
        const stats = renderer.getStats();
        try list.rect(.{ .x = 12, .y = 12, .width = 420, .height = 118 }, gfx.Color.rgba(10, 12, 20, 180));
        try list.text(font, try std.fmt.bufPrint(&hud_buffer, "{d:.0} fps · gpu {d:.2} ms · cpu {d:.2} ms\n{d} trees · {d} gpu instances · {d}k triangles", .{
            stage.fps, stage.gpu_ms, stats.cpu_ms, count, stats.instances, stats.triangles / 1000,
        }), .{ 24, 20 }, .{ .size = 16 });
        try list.text(font, "M", .{ 24, 66 }, .{ .size = 14, .color = gfx.Color.hex(0x9aa7d0) });
        try list.text(font, "sway (rewrite every frame)", .{ 64, 66 }, .{ .size = 14 });
        try list.text(font, if (sway) "on" else "off", .{ 300, 66 }, .{ .size = 14, .color = if (sway) gfx.Color.hex(0x3ddc97) else gfx.Color.hex(0x7c8499) });
        try list.text(font, if (picked) |copy| try std.fmt.bufPrint(&pick_buffer, "aiming at tree #{d}", .{copy}) else "aiming at no tree", .{ 24, 86 }, .{ .size = 14 });
        try list.text(font, "Up/Down count · R scatter · A/D orbit · hold T time of day", .{ 24, 106 }, .{ .size = 13, .color = gfx.Color.hex(0x9aa7d0) });
        const center = [2]f32{ @floatFromInt(tick.size[0] / 2), @floatFromInt(tick.size[1] / 2) };
        try list.circle(center, 3, gfx.Color.rgba(255, 255, 255, 200));

        const eye = math.Vec3{ @sin(orbit) * 26, 9, @cos(orbit) * 26 };
        try stage.end(try renderer.render(.{
            .views = &.{.{
                .scene = scene,
                .camera = gfx.Camera.lookAt(eye, .{ 0, 1.0, 0 }),
                .draw_lists = &.{&list},
                .target = stage.target(),
                .settings = .{ .shadow_distance = 110, .global_illumination = false },
            }},
            .delta_time = tick.dt,
        }));
    }
    try stage.finish();
}
