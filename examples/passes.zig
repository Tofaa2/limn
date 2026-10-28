//! The application's own GPU work inside a lit scene, through
//! `ViewDesc.passes`: a compute shader moves a few balls, a pass marches rays
//! into them and draws the blob into the scene's color, depth and motion and
//! into the sun's and a spot light's shadow maps, a tone curve of its own
//! replaces the renderer's (`Settings.post.tone_curve` off), and ink lines
//! are drawn from the scene's depth over the finished picture. The shaders are
//! `examples/shaders/passes.slang`, which includes the renderer's
//! `common.slang` for its frame constants and texture tables.
//!
//!   1  the blob on or off
//!   2  own tone curve or the renderer's
//!   3  ink lines on or off
//!   A/D      orbit
//!
//! `--frames N`, `--screenshot file.png`.
const std = @import("std");
const gfx = @import("limn");
const rhi = gfx.rhi;
const math = gfx.math;
const glfw = @import("glfw");
const helpers = @import("window");
const Stage = helpers.Stage;

const orb_count = 7;

const Orb = extern struct { position: [3]f32, radius: f32, previous: [3]f32, pad: f32 = 0 };
const MovePush = extern struct { orbs: u64, count: u32, time: f32 };
const OrbsPush = extern struct { frame: u64, orbs: u64, count: u32, pad: u32 = 0 };
const CopyPush = extern struct { source_texture: u32, exposure: f32 };
const OutlinePush = extern struct { frame: u64, depth_texture: u32, strength: f32 };
const ShadowPush = extern struct { to_world: math.Mat4, orbs: u64, count: u32, pad: u32 = 0 };
const LightShadowPush = extern struct { view_proj: math.Mat4, to_world: math.Mat4, orbs: u64, count: u32, pad: u32 = 0 };

/// What the passes keep between frames. Pipelines are made on first use,
/// when the formats they draw into are known.
const Effects = struct {
    device: *rhi.Device,
    orbs: rhi.Buffer,
    move: rhi.Pipeline,
    blob: ?rhi.Pipeline = null,
    copy: ?rhi.Pipeline = null,
    curve: ?rhi.Pipeline = null,
    outline: ?rhi.Pipeline = null,
    shadow: ?rhi.Pipeline = null,
    light_shadow: ?rhi.Pipeline = null,
    /// The scene's HDR color, copied so the curve can read it while
    /// drawing into the original.
    picture: ?rhi.Texture = null,
    time: f32 = 0,

    fn deinit(fx: *Effects) void {
        for ([_]?rhi.Pipeline{ fx.blob, fx.copy, fx.curve, fx.outline, fx.shadow, fx.light_shadow, fx.move }) |pipeline| if (pipeline) |value| fx.device.destroyPipeline(value);
        if (fx.picture) |texture| fx.device.destroyTexture(texture);
        fx.device.destroyBuffer(fx.orbs);
    }

    fn of(context: ?*anyopaque) *Effects {
        return @ptrCast(@alignCast(context.?));
    }

    fn drawBlob(context: ?*anyopaque, pass: gfx.PassContext) !void {
        const fx = of(context);
        const cmd = pass.cmd;
        cmd.bindPipeline(fx.move);
        cmd.pushConstants(MovePush{ .orbs = fx.device.bufferAddress(fx.orbs), .count = orb_count, .time = fx.time });
        cmd.dispatch(1, 1, 1);
        cmd.sync(.compute_to_all);

        const depth = pass.depth.?;
        const motion = pass.motion.?;
        if (fx.blob == null) fx.blob = try fx.device.createGraphicsPipeline(.{
            .name = "blob",
            .vertex = @embedFile("passes_fullscreen.vert.spv"),
            .fragment = @embedFile("passes_blob.frag.spv"),
            .color_targets = &.{ .{ .format = pass.color_format }, .{ .format = fx.device.textureInfo(motion).format } },
            .depth = .{ .format = fx.device.textureInfo(depth).format },
            .cull = .none,
        });
        try cmd.beginRendering(.{
            .color = &.{ .{ .texture = pass.color, .load = .load }, .{ .texture = motion, .load = .load } },
            .depth = .{ .texture = depth, .load = .load },
        });
        cmd.bindPipeline(fx.blob.?);
        cmd.pushConstants(OrbsPush{ .frame = pass.frame, .orbs = fx.device.bufferAddress(fx.orbs), .count = orb_count });
        cmd.drawFullscreen();
        cmd.endRendering();
    }

    fn toneCurve(context: ?*anyopaque, pass: gfx.PassContext) !void {
        const fx = of(context);
        const cmd = pass.cmd;
        const device = fx.device;
        if (fx.picture) |texture| {
            const info = device.textureInfo(texture);
            if (info.width != pass.width or info.height != pass.height) {
                device.destroyTexture(texture);
                fx.picture = null;
            }
        }
        if (fx.picture == null) fx.picture = try device.createTexture(.{
            .name = "picture copy",
            .width = pass.width,
            .height = pass.height,
            .format = pass.color_format,
            .usage = .{ .sampled = true, .color_attachment = true },
        });
        if (fx.copy == null) {
            fx.copy = try device.createGraphicsPipeline(.{ .name = "picture copy", .vertex = @embedFile("passes_fullscreen.vert.spv"), .fragment = @embedFile("passes_copy.frag.spv"), .color_targets = &.{.{ .format = pass.color_format }}, .cull = .none });
            fx.curve = try device.createGraphicsPipeline(.{ .name = "tone curve", .vertex = @embedFile("passes_fullscreen.vert.spv"), .fragment = @embedFile("passes_curve.frag.spv"), .color_targets = &.{.{ .format = pass.color_format }}, .cull = .none });
        }
        try cmd.beginRendering(.{ .color = &.{.{ .texture = fx.picture.?, .load = .discard }} });
        cmd.bindPipeline(fx.copy.?);
        cmd.pushConstants(CopyPush{ .source_texture = device.textureIndex(pass.color), .exposure = 1 });
        cmd.drawFullscreen();
        cmd.endRendering();
        try cmd.beginRendering(.{ .color = &.{.{ .texture = pass.color, .load = .discard }} });
        cmd.bindPipeline(fx.curve.?);
        cmd.pushConstants(CopyPush{ .source_texture = device.textureIndex(fx.picture.?), .exposure = 2.5 });
        cmd.drawFullscreen();
        cmd.endRendering();
    }

    /// The blob as a caster in each sun shadow cascade redrawn this frame.
    fn castShadow(context: ?*anyopaque, pass: gfx.PassContext) !void {
        const fx = of(context);
        const cmd = pass.cmd;
        const map = pass.depth.?;
        if (fx.shadow == null) fx.shadow = try fx.device.createGraphicsPipeline(.{
            .name = "blob shadow",
            .vertex = @embedFile("passes_fullscreen.vert.spv"),
            .fragment = @embedFile("passes_shadow.frag.spv"),
            .depth = .{ .format = fx.device.textureInfo(map).format, .compare = .less_or_equal },
            .cull = .none,
        });
        try cmd.beginRendering(.{ .depth = .{ .texture = map, .layer = pass.layer, .load = .load } });
        cmd.bindPipeline(fx.shadow.?);
        cmd.pushConstants(ShadowPush{ .to_world = math.inverse(pass.view_projection), .orbs = fx.device.bufferAddress(fx.orbs), .count = orb_count });
        cmd.drawFullscreen();
        cmd.endRendering();
    }

    /// The blob as a caster in each spot and point light tile redrawn this frame.
    fn castLightShadow(context: ?*anyopaque, pass: gfx.PassContext) !void {
        const fx = of(context);
        const cmd = pass.cmd;
        const atlas = pass.depth.?;
        if (fx.light_shadow == null) fx.light_shadow = try fx.device.createGraphicsPipeline(.{
            .name = "blob light shadow",
            .vertex = @embedFile("passes_fullscreen.vert.spv"),
            .fragment = @embedFile("passes_light_shadow.frag.spv"),
            .depth = .{ .format = fx.device.textureInfo(atlas).format, .compare = .greater_or_equal },
            .cull = .none,
        });
        try cmd.beginRendering(.{ .depth = .{ .texture = atlas, .load = .load } });
        cmd.setViewport(pass.origin[0], pass.origin[1], pass.width, pass.height);
        cmd.bindPipeline(fx.light_shadow.?);
        cmd.pushConstants(LightShadowPush{ .view_proj = pass.view_projection, .to_world = math.inverse(pass.view_projection), .orbs = fx.device.bufferAddress(fx.orbs), .count = orb_count });
        cmd.drawFullscreen();
        cmd.endRendering();
    }

    fn ink(context: ?*anyopaque, pass: gfx.PassContext) !void {
        const fx = of(context);
        const cmd = pass.cmd;
        if (fx.outline == null) fx.outline = try fx.device.createGraphicsPipeline(.{
            .name = "ink",
            .vertex = @embedFile("passes_fullscreen.vert.spv"),
            .fragment = @embedFile("passes_outline.frag.spv"),
            .color_targets = &.{.{ .format = pass.color_format, .blend = .alpha }},
            .cull = .none,
        });
        try cmd.beginRendering(.{ .color = &.{.{ .texture = pass.color, .load = .load }} });
        cmd.bindPipeline(fx.outline.?);
        cmd.pushConstants(OutlinePush{ .frame = pass.frame, .depth_texture = fx.device.textureIndex(pass.depth.?), .strength = 0.85 });
        cmd.drawFullscreen();
        cmd.endRendering();
    }
};

pub fn main(init: std.process.Init) !void {
    var stage = try Stage.create(init, "Limn passes", .{});
    const renderer = stage.renderer;
    const device = renderer.device;
    const scene = try renderer.scenes.create();
    const sky = gfx.SkyDesc{ .sun_direction = .{ -0.5, -0.55, -0.4 } };
    renderer.scenes.setSun(scene, gfx.skySun(sky));
    renderer.scenes.setEnvironment(scene, .{ .environment = try renderer.environments.createSky(sky), .intensity = 1 });

    var positions: [24][3]f32 = undefined;
    var indices: [36]u32 = undefined;
    helpers.boxMesh(.{ 0.5, 0.5, 0.5 }, &positions, &indices);
    const stone = try renderer.models.create(&.{.{ .positions = &positions, .indices = &indices, .material = .{ .base_color = .{ 0.6, 0.58, 0.54, 1 }, .metallic = 0, .roughness = 0.8 } }});
    const Box = struct { at: math.Vec3, size: math.Vec3 };
    for ([_]Box{
        .{ .at = .{ 0, -0.1, 0 }, .size = .{ 12, 0.2, 12 } },
        .{ .at = .{ -1.8, 1.0, -1.2 }, .size = .{ 0.5, 2.0, 0.5 } },
        .{ .at = .{ 1.7, 0.75, -1.6 }, .size = .{ 0.5, 1.5, 0.5 } },
        .{ .at = .{ 0.4, 0.3, 1.6 }, .size = .{ 1.2, 0.6, 0.6 } },
    }) |box| _ = try renderer.entities.create(scene, .{ .model = stone, .transform = math.mul(math.translation(box.at), math.scaling(box.size)) });
    try renderer.scenes.setLights(scene, &.{.{ .kind = .spot, .position = .{ 2.6, 4.2, 2.2 }, .direction = .{ -0.55, -0.75, -0.45 }, .color = .{ 1.0, 0.75, 0.45 }, .intensity = 600, .range = 14, .outer_angle = 0.6, .cast_shadows = true }});
    try renderer.waitUntilLoaded();

    const orbs = try device.createBuffer(.{ .name = "orbs", .size = orb_count * @sizeOf(Orb), .usage = .{ .storage = true }, .memory = .cpu_to_gpu });
    @memset(device.mapped(orbs)[0 .. orb_count * @sizeOf(Orb)], 0);
    var fx = Effects{
        .device = device,
        .orbs = orbs,
        .move = try device.createComputePipeline(.{ .name = "move orbs", .shader = @embedFile("passes_move.comp.spv") }),
    };
    errdefer fx.deinit();

    var list = gfx.DrawList.init(init.gpa);
    defer list.deinit();
    const font = renderer.fonts.default();
    var orbit: f32 = 0.5;
    var blob_on = true;
    var curve_on = true;
    var ink_on = true;
    var passes: [5]gfx.Pass = undefined;

    while (stage.begin()) |tick| {
        if (stage.keyPressed(glfw.GLFW_KEY_1)) blob_on = !blob_on;
        if (stage.keyPressed(glfw.GLFW_KEY_2)) curve_on = !curve_on;
        if (stage.keyPressed(glfw.GLFW_KEY_3)) ink_on = !ink_on;
        if (stage.keyDown(glfw.GLFW_KEY_A)) orbit -= tick.dt * 0.8;
        if (stage.keyDown(glfw.GLFW_KEY_D)) orbit += tick.dt * 0.8;
        fx.time = tick.time;

        var count: usize = 0;
        if (blob_on) {
            passes[count] = .{ .stage = .after_opaque, .context = &fx, .run = Effects.drawBlob };
            passes[count + 1] = .{ .stage = .sun_shadow, .context = &fx, .run = Effects.castShadow };
            passes[count + 2] = .{ .stage = .light_shadow, .context = &fx, .run = Effects.castLightShadow };
            count += 3;
        }
        if (curve_on) {
            passes[count] = .{ .stage = .after_resolve, .context = &fx, .run = Effects.toneCurve };
            count += 1;
        }
        if (ink_on) {
            passes[count] = .{ .stage = .after_tonemap, .reads = &.{.depth}, .context = &fx, .run = Effects.ink };
            count += 1;
        }
        var settings = gfx.Settings{};
        settings.post.tone_curve = !curve_on;

        list.clear();
        try list.rect(.{ .x = 12, .y = 12, .width = 470, .height = 58 }, gfx.Color.rgba(10, 12, 20, 190));
        try list.text(font, "1 blob · 2 own tone curve · 3 ink lines · A/D orbit", .{ 24, 22 }, .{ .size = 15 });
        var line: [96]u8 = undefined;
        try list.text(font, try std.fmt.bufPrint(&line, "blob {s} · curve {s} · ink {s}", .{ if (blob_on) "on" else "off", if (curve_on) "own" else "renderer's", if (ink_on) "on" else "off" }), .{ 24, 46 }, .{ .size = 13, .color = gfx.Color.hex(0x9aa7d0) });

        const eye = math.Vec3{ @sin(orbit) * 6.5, 3.2, @cos(orbit) * 6.5 };
        try stage.end(try renderer.render(.{
            .views = &.{.{
                .scene = scene,
                .camera = gfx.Camera.lookAt(eye, .{ 0, 1.0, 0 }),
                .draw_lists = &.{.{ .list = &list }},
                .target = stage.target(),
                .settings = settings,
                .passes = passes[0..count],
            }},
            .delta_time = tick.dt,
        }));
    }
    try device.waitIdle();
    fx.deinit();
    try stage.finish();
}
