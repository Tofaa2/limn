//! Amazon Lumberyard Bistro: a street corner of 1.75 million triangles, 250
//! materials and a hundred lamps, by day and by night. The sun's shadows are
//! ray traced.
//!
//! The scene is not kept with these sources; see examples/assets/README.md.
//!
//!   N        day / night
//!   C        next viewpoint
//!   mouse    look (Tab frees the pointer)
//!   W A S D  fly, Space/Ctrl up and down, Shift faster
//!   P        pause the props' animations
//!
//! `--night 1`, `--view N`, `--at "x y z yaw pitch"` (as shown on screen),
//! `--frames N`, `--screenshot file.png`.
const std = @import("std");
const gfx = @import("limn");
const math = gfx.math;
const glfw = @import("glfw");
const window = @import("window");
const Stage = window.Stage;

const scene_path = "examples/assets/bistro/bistro.gltf";

/// Where to stand and which way to look: the street, the bar, the door from
/// inside, and the roofs.
const views = [_][2]math.Vec3{
    .{ .{ -26.4, 3.2, 11.2 }, .{ 0.96, -0.05, 0.28 } },
    .{ .{ -8, 2, 6 }, .{ 0.8, 0, 0.6 } },
    .{ .{ -8, 2, 6 }, .{ -0.91, -0.05, 0.41 } },
    .{ .{ -14, 9, -2 }, .{ 0.5, -0.35, 0.79 } },
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var night = false;
    var view: usize = 0;
    var start: ?[5]f32 = null;
    {
        var arguments = try init.minimal.args.iterateAllocator(gpa);
        defer arguments.deinit();
        while (arguments.next()) |argument| {
            if (std.mem.eql(u8, argument, "--night")) night = true;
            if (std.mem.eql(u8, argument, "--at")) {
                var numbers = std.mem.tokenizeScalar(u8, arguments.next() orelse return error.MissingArgument, ' ');
                var values: [5]f32 = undefined;
                for (&values) |*value| value.* = try std.fmt.parseFloat(f32, numbers.next() orelse return error.MissingArgument);
                start = values;
            }
            if (std.mem.eql(u8, argument, "--view")) view = try std.fmt.parseInt(usize, arguments.next() orelse return error.MissingArgument, 10) % views.len;
        }
    }
    std.Io.Dir.cwd().access(init.io, scene_path, .{}) catch {
        std.debug.print("The Bistro scene is missing. Fetch it with:\n  git clone --depth 1 https://github.com/zeux/niagara_bistro examples/assets/bistro\n", .{});
        return;
    };

    var stage = try Stage.create(init, "Limn Bistro", .{
        .asset_cache_dir = "zig-out/asset-cache",
        .texture_streaming = .{ .budget_bytes = 2 << 30 },
    });
    const renderer = stage.renderer;
    const scene = try renderer.scenes.create();

    const lights = try gfx.loadSceneLights(gpa, init.io, scene_path);
    defer gpa.free(lights);
    var sun_direction = math.Vec3{ -0.4, -1.0, -0.3 };
    var lamps: std.ArrayList(gfx.Light) = .empty;
    defer lamps.deinit(gpa);
    for (lights) |light| switch (light.kind) {
        .directional => sun_direction = light.direction,
        else => try lamps.append(gpa, .{
            .kind = if (light.kind == .spot) .spot else .point,
            .position = light.position,
            .direction = light.direction,
            .color = light.color,
            .intensity = light.intensity * 0.02,
            .range = if (light.range > 0) light.range else 8,
            .inner_angle = light.inner_angle,
            .outer_angle = light.outer_angle,
            .source_radius = 0.05,
        }),
    };

    const model = try renderer.models.load(scene_path);
    const bistro = try renderer.entities.spawn(scene, .{ .model = model });
    try renderer.waitUntilLoaded();

    var list = gfx.DrawList.init(gpa);
    defer list.deinit();
    const font = renderer.fonts.default();
    var text: [256]u8 = undefined;
    var eye = views[view][0];
    var yaw: f32 = std.math.atan2(views[view][1][0], -views[view][1][2]);
    var pitch: f32 = std.math.asin(views[view][1][1]);
    if (start) |values| {
        eye = values[0..3].*;
        yaw = values[3];
        pitch = values[4];
    }
    var applied_night: ?bool = null;
    var lit: std.ArrayList(gfx.Light) = .empty;
    defer lit.deinit(gpa);
    var animating = true;
    var clock: f32 = 0;
    var looking = stage.window != null;
    var pointer: ?[2]f64 = null;
    if (stage.window) |shown| shown.captureCursor(true);

    while (stage.begin()) |tick| {
        if (stage.keyPressed(glfw.GLFW_KEY_N)) night = !night;
        if (stage.keyPressed(glfw.GLFW_KEY_C)) {
            view = (view + 1) % views.len;
            eye = views[view][0];
            yaw = std.math.atan2(views[view][1][0], -views[view][1][2]);
            pitch = std.math.asin(views[view][1][1]);
        }
        if (stage.keyPressed(glfw.GLFW_KEY_P)) animating = !animating;
        if (animating) clock += tick.dt;
        renderer.entities.setPose(bistro, .{ .animation = 0, .time = clock, .every_clip = true });
        if (stage.window) |shown| {
            if (stage.keyPressed(glfw.GLFW_KEY_TAB)) {
                looking = !looking;
                shown.captureCursor(looking);
                pointer = null;
            }
            const at = shown.cursor();
            if (looking) if (pointer) |before| {
                yaw += @as(f32, @floatCast(at[0] - before[0])) * 0.0022;
                pitch = std.math.clamp(pitch - @as(f32, @floatCast(at[1] - before[1])) * 0.0022, -1.5, 1.5);
            };
            pointer = at;
        }
        const forward = math.Vec3{ @sin(yaw) * @cos(pitch), @sin(pitch), -@cos(yaw) * @cos(pitch) };
        const right = math.normalize(math.cross(forward, .{ 0, 1, 0 }));
        const speed = tick.dt * @as(f32, if (stage.keyDown(glfw.GLFW_KEY_LEFT_SHIFT)) 12 else 4);
        if (stage.keyDown(glfw.GLFW_KEY_W)) eye = math.add(eye, math.scale(forward, speed));
        if (stage.keyDown(glfw.GLFW_KEY_S)) eye = math.add(eye, math.scale(forward, -speed));
        if (stage.keyDown(glfw.GLFW_KEY_D)) eye = math.add(eye, math.scale(right, speed));
        if (stage.keyDown(glfw.GLFW_KEY_A)) eye = math.add(eye, math.scale(right, -speed));
        if (stage.keyDown(glfw.GLFW_KEY_SPACE)) eye[1] += speed;
        if (stage.keyDown(glfw.GLFW_KEY_LEFT_CONTROL)) eye[1] -= speed;

        if (applied_night != night) {
            applied_night = night;
            const sky = gfx.SkyDesc{ .sun_direction = if (night) .{ 0.3, 0.25, 0.2 } else sun_direction, .intensity = if (night) 0.02 else 1 };
            renderer.scenes.setEnvironment(scene, try renderer.environments.createSky(sky), 1);
            const sun = gfx.skySun(sky);
            renderer.scenes.setSun(scene, .{ .direction = sun.direction, .color = sun.color, .intensity = 0 });
            lit.clearRetainingCapacity();
            try lit.append(gpa, .{ .kind = .directional, .position = .{ 0, 0, 0 }, .direction = sun.direction, .color = sun.color, .intensity = sun.intensity, .cast_shadows = true, .source_radius = 0.005 });
            try lit.appendSlice(gpa, lamps.items);
            try renderer.scenes.setLights(scene, lit.items);
        }

        const stats = renderer.getStats();
        list.clear();
        try list.rect(.{ .x = 12, .y = 12, .width = 700, .height = 96 }, gfx.Color.rgba(8, 10, 18, 190));
        try list.text(font, try std.fmt.bufPrint(&text, "Bistro, {s} · {d:.0} fps rendered, {d:.0} shown · gpu {d:.2} ms", .{ if (night) "night" else "day", stage.fps, stage.shown_fps, stage.gpu_ms }), .{ 24, 20 }, .{ .size = 17 });
        try list.text(font, try std.fmt.bufPrint(&text, "{d} instances, {d} drawn · {d} MB of textures on the GPU", .{
            stats.instances,
            stats.instances_drawn,
            stats.streamed_texture_bytes >> 20,
        }), .{ 24, 48 }, .{ .size = 14 });
        try list.text(font, try std.fmt.bufPrint(&text, "mouse look · WASD fly · Tab pointer · N night · C view · P pause · at {d:.1} {d:.1} {d:.1} {d:.2} {d:.2}", .{ eye[0], eye[1], eye[2], yaw, pitch }), .{ 24, 76 }, .{ .size = 13, .color = gfx.Color.hex(0x9aa7d0) });

        var camera = gfx.Camera.lookAt(eye, math.add(eye, forward));
        camera.fov_y = 0.9;
        try stage.end(try renderer.render(.{
            .views = &.{.{
                .scene = scene,
                .camera = camera,
                .draw_lists = &.{&list},
                .target = stage.target(),
                .settings = .{
                    .shadow_distance = 80,
                    .automatic_exposure = false,
                    .exposure_compensation = if (night) 3 else 1.3,
                },
            }},
            .delta_time = tick.dt,
        }));
    }
    try stage.finish();
}
