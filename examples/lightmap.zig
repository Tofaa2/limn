//! Baked lightmaps: a room lit through its open front and a gap in its
//! roof, with a red wall and a green one.
//!
//! The light that reaches each surface off the others (the red and green
//! that the walls throw on the floor and the boxes, the dimness of the
//! corners) is gathered into a texture for every slab of the room by
//! following rays, a little more each frame, and read from there in
//! place of the irradiance probes, which are spaced far too widely to
//! know one corner from the next. The baking is watched as it goes: the
//! lightmaps start out grainy and settle.
//!
//!   L        lightmaps, or the probes alone (turning them on bakes
//!            them again from the start)
//!   A/D      move the camera from side to side
//!
//! Needs a GPU that traces rays. `--probes 1` starts without lightmaps.
//! `--frames N`, `--screenshot file.png`.
const std = @import("std");
const gfx = @import("limn");
const math = gfx.math;
const glfw = @import("glfw");
const Stage = @import("window").Stage;

/// A box one unit a side whose six faces each have a patch of their own
/// in the second set of texture coordinates, which is what a lightmap is
/// laid out by: three patches across, two down, with a margin round each.
fn lightmappedBox(positions: *[24][3]f32, patches: *[24][2]f32, indices: *[36]u32) void {
    for (0..6) |face| {
        const axis = face / 2;
        const sign: f32 = if (face % 2 == 0) 1 else -1;
        const u = (axis + 1) % 3;
        const v = (axis + 2) % 3;
        for (0..4) |corner| {
            var position: [3]f32 = undefined;
            position[axis] = sign * 0.5;
            position[u] = (if (corner == 1 or corner == 2) @as(f32, 0.5) else -0.5) * sign;
            position[v] = if (corner >= 2) 0.5 else -0.5;
            positions[face * 4 + corner] = position;
            const column: f32 = @floatFromInt(face % 3);
            const row: f32 = @floatFromInt(face / 3);
            const x: f32 = if (corner == 1 or corner == 2) 0.94 else 0.06;
            const y: f32 = if (corner >= 2) 0.94 else 0.06;
            patches[face * 4 + corner] = .{ (column + x) / 3, (row + y) / 2 };
        }
        const base: u32 = @intCast(face * 4);
        indices[face * 6 ..][0..6].* = .{ base, base + 1, base + 2, base, base + 2, base + 3 };
    }
}

const Slab = struct {
    center: math.Vec3,
    size: math.Vec3,
    color: enum { white, red, green, blue },
    turn: f32 = 0,
};

/// The room and what stands in it.
const slabs = [_]Slab{
    .{ .center = .{ 0, -0.15, 0 }, .size = .{ 6.6, 0.3, 6.6 }, .color = .white },
    .{ .center = .{ 0, 3.15, -1.2 }, .size = .{ 6.6, 0.3, 4.2 }, .color = .white },
    .{ .center = .{ 0, 1.5, -3.15 }, .size = .{ 6.6, 3.0, 0.3 }, .color = .white },
    .{ .center = .{ -3.15, 1.5, 0 }, .size = .{ 0.3, 3.0, 6.0 }, .color = .red },
    .{ .center = .{ 3.15, 1.5, 0 }, .size = .{ 0.3, 3.0, 6.0 }, .color = .green },
    .{ .center = .{ -1.1, 0.9, -1.2 }, .size = .{ 1.2, 1.8, 1.2 }, .color = .white, .turn = 0.35 },
    .{ .center = .{ 1.2, 0.45, 0.4 }, .size = .{ 0.9, 0.9, 0.9 }, .color = .blue, .turn = -0.3 },
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var baked = true;
    {
        var arguments = try init.minimal.args.iterateAllocator(gpa);
        defer arguments.deinit();
        while (arguments.next()) |argument| {
            if (std.mem.eql(u8, argument, "--probes")) baked = false;
        }
    }
    var stage = try Stage.create(init, "Limn lightmap", .{});
    const renderer = stage.renderer;
    const scene = try renderer.createScene();
    const sky = gfx.SkyDesc{ .sun_direction = .{ 0.25, -0.8, -0.55 } };
    renderer.setSun(scene, gfx.skySun(sky));
    renderer.setEnvironment(scene, try renderer.createSky(sky), 1);

    var positions: [24][3]f32 = undefined;
    var patches: [24][2]f32 = undefined;
    var indices: [36]u32 = undefined;
    lightmappedBox(&positions, &patches, &indices);
    const colors = [_][4]f32{ .{ 0.85, 0.85, 0.85, 1 }, .{ 0.8, 0.12, 0.1, 1 }, .{ 0.15, 0.7, 0.18, 1 }, .{ 0.2, 0.3, 0.8, 1 } };
    var models: [colors.len]gfx.Model = undefined;
    for (colors, &models) |color, *model| model.* = try renderer.createModel(&.{.{
        .positions = &positions,
        .uvs1 = &patches,
        .indices = &indices,
        .material = .{ .base_color = color, .metallic = 0, .roughness = 0.9 },
    }});
    try renderer.waitUntilLoaded();
    var entities: [slabs.len]gfx.Entity = undefined;
    for (slabs, &entities) |slab, *entity| entity.* = try renderer.spawn(scene, .{
        .model = models[@intFromEnum(slab.color)],
        .transform = math.mul(math.translation(slab.center), math.mul(math.rotationY(slab.turn), math.scaling(slab.size))),
    });

    var list = gfx.DrawList.init(gpa);
    defer list.deinit();
    const font = renderer.defaultFont();
    var text: [256]u8 = undefined;
    var wanted = baked;
    var applied = false;
    var unavailable = false;
    var side: f32 = 0;

    while (stage.begin()) |tick| {
        if (stage.keyPressed(glfw.GLFW_KEY_L)) wanted = !wanted;
        if (stage.keyDown(glfw.GLFW_KEY_A)) side -= tick.dt * 2;
        if (stage.keyDown(glfw.GLFW_KEY_D)) side += tick.dt * 2;
        side = std.math.clamp(side, -3, 3);
        if (wanted != applied) {
            applied = wanted;
            for (entities) |entity| renderer.bakeLightmap(entity, if (wanted) .{ .resolution = 192, .frames = 300, .rays = 24, .reach = 60 } else null) catch |failure| switch (failure) {
                error.RayTracingUnavailable => unavailable = true,
                else => return failure,
            };
        }
        var progress: f32 = 1;
        for (entities) |entity| progress = @min(progress, renderer.lightmapProgress(entity) orelse 1);

        list.clear();
        try list.rect(.{ .x = 12, .y = 12, .width = 520, .height = 96 }, gfx.Color.rgba(8, 10, 18, 190));
        try list.text(font, if (unavailable)
            "Lightmaps need a GPU that traces rays"
        else if (!applied)
            "Bounce light: irradiance probes"
        else if (progress < 1)
            try std.fmt.bufPrint(&text, "Bounce light: lightmaps, baking {d:.0}%", .{progress * 100})
        else
            "Bounce light: baked lightmaps", .{ 24, 20 }, .{ .size = 20 });
        try list.text(font, try std.fmt.bufPrint(&text, "{d} lightmaps of 192 x 192 · {d:.1} ms GPU · {d:.0} fps", .{ entities.len, stage.gpu_ms, stage.fps }), .{ 24, 50 }, .{ .size = 15 });
        try list.text(font, "L lightmaps or probes · A/D move", .{ 24, 80 }, .{ .size = 13, .color = gfx.Color.hex(0x9aa7d0) });

        try stage.end(try renderer.render(.{
            .views = &.{.{
                .scene = scene,
                .camera = gfx.Camera.lookAt(.{ side, 1.6, 5.4 }, .{ 0, 1.4, -1 }),
                .draw_lists = &.{&list},
                .target = stage.target(),
                .settings = .{ .shadow_distance = 30, .global_illumination = true },
            }},
            .delta_time = tick.dt,
        }));
    }
    try stage.finish();
}
