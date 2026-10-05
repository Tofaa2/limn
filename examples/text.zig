//! Text: one built-in font drawn sharp at any size, ligatures, right to
//! left and mixed lines, scripts whose letters join, stack and reorder
//! (each from a font loaded here), runs of different sizes and colors
//! wrapped as one block, columns set downward, and words standing in a
//! 3D scene.
//!
//! `--frames N`, `--screenshot file.png`.
const std = @import("std");
const gfx = @import("limn");
const math = gfx.math;
const helpers = @import("window");
const Stage = helpers.Stage;
const Color = gfx.Color;

const fonts_dir = "examples/assets/fonts/";

/// A line in a script the built-in font does not hold, with the font that
/// does.
const Sample = struct {
    script: []const u8,
    file: []const u8,
    text: []const u8,
    right_to_left: bool = false,
};

const samples = [_]Sample{
    .{ .script = "Telugu", .file = "NotoSansTelugu-Regular.ttf", .text = "తెలుగు  స్త్రీ ప్రేమ విద్య" },
    .{ .script = "Kannada", .file = "NotoSansKannada-Regular.ttf", .text = "ಕನ್ನಡ  ಕೊ ಕೋ ಕೈ" },
    .{ .script = "Sinhala", .file = "NotoSansSinhala-Regular.ttf", .text = "ශ්‍රී  කො කෝ කෞ" },
    .{ .script = "Khmer", .file = "NotoSansKhmer-Regular.ttf", .text = "ខ្មែរ  កោ កៅ កៃ" },
    .{ .script = "Myanmar", .file = "NotoSansMyanmar-Regular.ttf", .text = "မြန်မာ  ကြေ က္က" },
    .{ .script = "Tibetan", .file = "NotoSerifTibetan-Regular.ttf", .text = "བོད་ བཀྲ་ཤིས་ རྒྱལ" },
    .{ .script = "Javanese", .file = "NotoSansJavanese-Regular.ttf", .text = "ꦗꦮ ꦏꦺꦴ ꦲꦏ꧀ꦱꦫ" },
    .{ .script = "Mongolian", .file = "NotoSansMongolian-Regular.ttf", .text = "ᠮᠣᠩᠭᠣᠯ ᠪᠢᠴᠢᠭ" },
    .{ .script = "Urdu (Nastaliq)", .file = "NotoNastaliqUrdu-Regular.ttf", .text = "اردو پاکستان کتاب ہے", .right_to_left = true },
};

const hebrew = "שלום עולם";
const arabic = "السلام عليكم";
const mixed = "Left to right, then מימין לשמאל and back.";

pub fn main(init: std.process.Init) !void {
    var stage = try Stage.create(init, "Limn text", .{});
    const renderer = stage.renderer;
    const scene = try renderer.createScene();
    const sky_desc = gfx.SkyDesc{ .sun_direction = .{ -0.4, -0.6, -0.5 } };
    renderer.setEnvironment(scene, try renderer.createSky(sky_desc), 1);
    renderer.setSun(scene, gfx.skySun(sky_desc));
    var box_positions: [24][3]f32 = undefined;
    var box_indices: [36]u32 = undefined;
    helpers.boxMesh(.{ 6, 0.05, 6 }, &box_positions, &box_indices);
    const floor = try renderer.createModel(&.{.{ .positions = &box_positions, .indices = &box_indices, .material = .{ .base_color = .{ 0.3, 0.32, 0.36, 1 }, .metallic = 0, .roughness = 0.4 } }});
    _ = try renderer.spawn(scene, .{ .model = floor });

    // The built-in font starts with Latin letters; anything else it holds
    // is baked when asked for, as are its ligatures.
    const font = renderer.defaultFont();
    try renderer.prepareText(font, hebrew ++ arabic ++ mixed ++ "→·“”");
    try renderer.prepareLigatures(font);

    // A font per script. Only the characters named are baked, and the
    // glyphs that shaping turns them into along with them.
    var loaded: [samples.len]*const gfx.Font = undefined;
    for (samples, &loaded) |sample, *slot| {
        var path_buffer: [128]u8 = undefined;
        slot.* = try renderer.loadFont(try std.fmt.bufPrint(&path_buffer, fonts_dir ++ "{s}", .{sample.file}), &.{.{ 32, 126 }});
        try renderer.prepareText(slot.*, sample.text);
    }
    try renderer.waitUntilLoaded();

    var list = gfx.DrawList.init(init.gpa);
    defer list.deinit();
    const label = Color.hex(0x9aa7d0);
    var hud_buffer: [64]u8 = undefined;

    while (stage.begin()) |tick| {
        list.clear();
        const left = gfx.Rect{ .x = 24, .y = 24, .width = 560, .height = 672 };
        try list.roundedRect(left, Color.rgba(12, 14, 22, 225), .{ .radius = 14 });
        var y: f32 = left.y + 16;
        // One atlas, any size: the glyphs are stored as distances, not
        // pixels, so they stay sharp.
        for ([_]f32{ 11, 16, 26, 40, 58 }) |size| {
            try list.text(font, "Sharp at any size", .{ left.x + 20, y }, .{ .size = size });
            y += size * 1.25;
        }
        y += 6;
        try list.text(font, "office affluent fjord flight", .{ left.x + 20, y }, .{ .size = 22 });
        try list.text(font, "ligatures", .{ left.x + 400, y + 6 }, .{ .size = 13, .color = label });
        y += 30;
        try list.text(font, "office affluent fjord flight", .{ left.x + 20, y }, .{ .size = 22, .shaping = false, .color = Color.hex(0x7c8499) });
        try list.text(font, "without", .{ left.x + 400, y + 6 }, .{ .size = 13, .color = label });
        y += 40;
        try list.text(font, "Outlined by a shadow", .{ left.x + 20, y }, .{ .size = 24, .color = Color.hex(0xffd23f), .shadow = Color.rgba(0, 0, 0, 220) });
        y += 44;
        // Right-to-left lines are right-aligned, as their readers expect.
        try list.text(font, hebrew, .{ left.x + left.width - 20, y }, .{ .size = 26, .alignment = .right });
        try list.text(font, "Hebrew", .{ left.x + 20, y + 8 }, .{ .size = 13, .color = label });
        y += 36;
        try list.text(font, arabic, .{ left.x + left.width - 20, y }, .{ .size = 26, .alignment = .right });
        try list.text(font, "Arabic", .{ left.x + 20, y + 8 }, .{ .size = 13, .color = label });
        y += 40;
        try list.text(font, mixed, .{ left.x + 20, y }, .{ .size = 18 });
        y += 40;
        // Runs with their own size and color, wrapped as one block.
        _ = try list.richText(&.{
            .{ .text = "Rich text " },
            .{ .text = "mixes ", .color = Color.hex(0x3ddc97) },
            .{ .text = "sizes ", .size = 28, .color = Color.hex(0xffd23f) },
            .{ .text = "and colors on one baseline, and wraps where the panel ends, however long the sentence turns out to be." },
        }, .{ left.x + 20, y }, .{ .font = font, .size = 17, .max_width = left.width - 40 });

        const right = gfx.Rect{ .x = 608, .y = 24, .width = 648, .height = 468 };
        try list.roundedRect(right, Color.rgba(12, 14, 22, 225), .{ .radius = 14 });
        for (samples, loaded, 0..) |sample, sample_font, index| {
            const row = right.y + 14 + 47 * @as(f32, @floatFromInt(index));
            try list.text(font, sample.script, .{ right.x + 20, row + 9 }, .{ .size = 13, .color = label });
            if (sample.right_to_left) {
                try list.text(sample_font, sample.text, .{ right.x + right.width - 20, row }, .{ .size = 28, .alignment = .right });
            } else {
                try list.text(sample_font, sample.text, .{ right.x + 160, row }, .{ .size = 28 });
            }
        }

        // Columns read downward, from right to left.
        try list.textVertical(font, "TOP\nDOWN", .{ 1226, 504 }, .{ .size = 26, .color = Color.hex(0x3ddc97) });

        // Text in the scene: facing the camera, or lying where it is put.
        const turn = tick.time * 0.4;
        try list.text3d(font, "Always faces you", .{ 2.6, 1.0, 0 }, .{ .size = 0.3 });
        try list.text3d(font, "Fixed in the world", .{ 0, 0, 0 }, .{
            .size = 0.34,
            .billboard = false,
            .color = Color.hex(0xffd23f),
            .transform = math.mul(math.translation(.{ 2.6, 0.25, 0 }), math.rotationY(@sin(turn) * 0.9)),
        });
        try list.text(font, try std.fmt.bufPrint(&hud_buffer, "{d:.0} fps · gpu {d:.2} ms", .{ stage.fps, stage.gpu_ms }), .{ 1256, 690 }, .{ .size = 14, .alignment = .right, .color = label });

        try stage.end(try renderer.render(.{
            .views = &.{.{
                .scene = scene,
                .camera = gfx.Camera.lookAt(.{ -1.2, 1.6, 6.5 }, .{ -1.2, 2.6, 0 }),
                .draw_lists = &.{&list},
                .target = stage.target(),
            }},
            .delta_time = tick.dt,
        }));
    }
    try stage.finish();
}
