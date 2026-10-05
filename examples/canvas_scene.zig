//! The 2D demo content, shared by the windowed `canvas` example and the
//! headless harness: a panning/zooming world of sprites and shapes under a
//! fixed HUD, drawn entirely with one `DrawList`.
const std = @import("std");
const gfx = @import("limn");

const Color = gfx.Color;

const hebrew = "שלום עולם";
const arabic = "مرحبا بالعالم";
const mixed = "Total: 42 שקלים (approx.)";

pub const Assets = struct {
    checker: gfx.Image,

    pub fn init(renderer: *gfx.Renderer) !Assets {
        // A tiny procedural sprite; `loadImage` does the same for files.
        var pixels: [8 * 8 * 4]u8 = undefined;
        for (0..8) |y| for (0..8) |x| {
            const light = (x + y) % 2 == 0;
            const edge = x == 0 or y == 0 or x == 7 or y == 7;
            const color: [4]u8 = if (edge) .{ 30, 30, 40, 255 } else if (light) .{ 255, 214, 92, 255 } else .{ 240, 120, 60, 255 };
            pixels[(y * 8 + x) * 4 ..][0..4].* = color;
        };
        // The text panel uses scripts outside the font's preloaded range;
        // their glyphs are baked on request.
        try renderer.prepareText(renderer.defaultFont(), hebrew ++ arabic ++ mixed ++ "→·\u{301}\u{308}\u{303}\u{302}");
        // The ligatures (fi, ffl, ...) come from the font's own table.
        try renderer.prepareLigatures(renderer.defaultFont());
        // Letters a language draws its own way, and a feature asked for by
        // name: the glyphs they bring in are baked on request too.
        try renderer.prepareTextWith(renderer.defaultFont(), "бгдпт i\u{30a} j\u{303}", "SRB ".*, &.{});
        try renderer.prepareTextWith(renderer.defaultFont(), "ag", null, &.{"salt".*});
        return .{ .checker = try renderer.createImage(8, 8, &pixels, true) };
    }

    pub fn deinit(self: Assets, renderer: *gfx.Renderer) void {
        renderer.destroyImage(self.checker);
    }
};

/// Records one frame of the demo into `list`.
pub fn draw(list: *gfx.DrawList, font: *const gfx.Font, assets: Assets, size: [2]f32, time: f32) !void {
    const width = size[0];
    const height = size[1];

    // ------------------------------------------------------------ world
    // Everything inside this transform lives in "world" pixels and is
    // viewed through a slowly drifting, zooming, rotating 2D camera.
    const zoom = 1.0 + 0.15 * @sin(time * 0.4);
    list.pushTransform(.camera(.{ 60 * @sin(time * 0.3), 30 * @cos(time * 0.2) }, zoom, 0.05 * @sin(time * 0.5), .{ width * 0.5, height * 0.5 }));
    var grid: f32 = -800;
    while (grid <= 800) : (grid += 80) {
        const color = if (grid == 0) Color.rgba(120, 140, 200, 255) else Color.rgba(60, 66, 90, 255);
        try list.line(.{ grid, -800 }, .{ grid, 800 }, 1, color);
        try list.line(.{ -800, grid }, .{ 800, grid }, 1, color);
    }
    for (0..24) |index| {
        const i: f32 = @floatFromInt(index);
        const angle = i * 0.2618 + time * (0.2 + 0.02 * i);
        const radius = 110 + 12 * i;
        const center = [2]f32{ @cos(angle) * radius, @sin(angle) * radius * 0.7 };
        const extent = 22 + 6 * @sin(time * 2 + i);
        // Each sprite spins around its own center.
        list.pushTransform(gfx.Transform2D.translation(center[0], center[1]).mul(.rotation(time + i)));
        try list.image(assets.checker, .{ .x = -extent, .y = -extent, .width = extent * 2, .height = extent * 2 }, .{
            .pixelated = true,
            .tint = if (index % 3 == 0) Color.rgb(160, 220, 255) else .white,
        });
        list.popTransform();
    }
    try list.circle(.{ 0, 0 }, 46, Color.hex(0x3ddc97));
    try list.circle(.{ 0, 0 }, 30, Color.hex(0x15202b));
    try list.triangle(.{ -18, -14 }, .{ 22, 0 }, .{ -18, 14 }, Color.hex(0xffd166));
    try list.text(font, "origin", .{ 0, 54 }, .{ .size = 18, .alignment = .center, .color = Color.hex(0xb8c4ff) });
    list.popTransform();

    // -------------------------------------------------------------- HUD
    try list.rect(.{ .x = 0, .y = 0, .width = width, .height = 54 }, Color.rgba(12, 14, 22, 215));
    try list.text(font, "2D canvas", .{ 18, 10 }, .{ .size = 30 });
    try list.text(font, "shapes · sprites · distance-field text", .{ width - 18, 18 }, .{
        .size = 17,
        .alignment = .right,
        .color = Color.hex(0x9aa7d0),
    });

    const panel = gfx.Rect{ .x = 18, .y = height - 178, .width = 372, .height = 160 };
    try list.rect(panel, Color.rgba(12, 14, 22, 200));
    try list.rectOutline(panel, 1, Color.rgba(120, 140, 200, 255));
    try list.text(font, "The same atlas at any size:", .{ panel.x + 14, panel.y + 10 }, .{ .size = 15, .color = Color.hex(0x9aa7d0) });
    var y = panel.y + 34;
    for ([_]f32{ 11, 16, 24, 40 }) |text_size| {
        try list.text(font, "Sphinx of black quartz, jügé ÀÉÎÕÜ ©", .{ panel.x + 14, y }, .{ .size = text_size });
        y += text_size * 1.25;
    }
    // Accents typed as separate combining marks, set on their letters by
    // the font's anchors, beside the same letters as single characters.
    try list.text(font, "e\u{301} a\u{308} n\u{303} E\u{301} o\u{302}  =  é ä ñ É ô", .{ panel.x + 300, panel.y + 8 }, .{ .size = 18 });
    // The font's own substitutions: by language, by feature, by context.
    try list.text(font, "бгдпт", .{ panel.x + 300, panel.y + 32 }, .{ .size = 18 });
    try list.text(font, "бгдпт", .{ panel.x + 362, panel.y + 32 }, .{ .size = 18, .language = "SRB ".*, .color = Color.hex(0xffd65c) });
    try list.text(font, "ag", .{ panel.x + 432, panel.y + 32 }, .{ .size = 18 });
    try list.text(font, "ag", .{ panel.x + 458, panel.y + 32 }, .{ .size = 18, .features = &.{"salt".*}, .color = Color.hex(0xffd65c) });
    try list.text(font, "i\u{30a} j\u{303}", .{ panel.x + 492, panel.y + 32 }, .{ .size = 18 });

    // A meter built from primitives.
    const level = 0.5 + 0.5 * @sin(time * 1.3);
    const bar = gfx.Rect{ .x = width - 250, .y = height - 46, .width = 232, .height = 22 };
    try list.rect(bar, Color.rgba(12, 14, 22, 220));
    try list.rect(.{ .x = bar.x + 3, .y = bar.y + 3, .width = (bar.width - 6) * level, .height = bar.height - 6 }, Color.hex(0x3ddc97));
    try list.text(font, "signal", .{ bar.x, bar.y - 22 }, .{ .size = 15, .shadow = .black });

    // --- Newer shapes: a card built from them, top right. ---
    const card = gfx.Rect{ .x = width - 330, .y = 72, .width = 312, .height = 250 };
    // Drop shadow, body with a vertical gradient, and a thin outline.
    try list.roundedRect(.{ .x = card.x + 3, .y = card.y + 5, .width = card.width, .height = card.height }, Color.rgba(0, 0, 0, 90), .{ .radius = 16 });
    try list.roundedRect(card, Color.hex(0x2a3350), .{ .radius = 16, .bottom_color = Color.hex(0x161b2c) });
    try list.roundedRect(card, Color.rgba(140, 160, 230, 255), .{ .radius = 16, .stroke = 1.5 });
    try list.text(font, "rounded · gradient · clipped", .{ card.x + 16, card.y + 12 }, .{ .size = 15, .color = Color.hex(0x9aa7d0) });

    // A horizontal gradient bar with rounded ends.
    try list.rectGradientHorizontal(.{ .x = card.x + 16, .y = card.y + 40, .width = card.width - 32, .height = 10 }, Color.hex(0x3ddc97), Color.hex(0x5b8cff));

    // Clipping: text scrolling inside a window smaller than itself.
    const window = gfx.Rect{ .x = card.x + 16, .y = card.y + 62, .width = card.width - 32, .height = 26 };
    try list.roundedRect(window, Color.rgba(0, 0, 0, 110), .{ .radius = 6 });
    try list.pushClip(window);
    const scroll = @mod(time * 60, 520);
    try list.text(font, "this line is wider than its window and scrolls behind the clip rectangle", .{ window.x + window.width - scroll, window.y + 4 }, .{ .size = 16 });
    try list.popClip();

    // A path with curves, filled and stroked: a heart.
    {
        var path = gfx.Path.init(list.gpa);
        defer path.deinit();
        const cx = card.x + 70;
        const cy = card.y + 150;
        const s = 26 + 2 * @sin(time * 4);
        try path.moveTo(.{ cx, cy + s * 0.9 });
        try path.cubicTo(.{ cx - s * 1.6, cy - s * 0.2 }, .{ cx - s * 0.8, cy - s * 1.3 }, .{ cx, cy - s * 0.45 });
        try path.cubicTo(.{ cx + s * 0.8, cy - s * 1.3 }, .{ cx + s * 1.6, cy - s * 0.2 }, .{ cx, cy + s * 0.9 });
        path.close();
        try list.fillPath(&path, Color.hex(0xff5d73));
        try list.strokePath(&path, 2, Color.hex(0xffd0d8));
    }
    // A concave polygon (a star) filled by ear clipping.
    {
        var star: [10][2]f32 = undefined;
        for (&star, 0..) |*point, index| {
            const angle = @as(f32, @floatFromInt(index)) * std.math.pi / 5.0 - std.math.pi / 2.0 + time * 0.5;
            const radius: f32 = if (index % 2 == 0) 32 else 14;
            point.* = .{ card.x + 160 + @cos(angle) * radius, card.y + 150 + @sin(angle) * radius };
        }
        try list.fillPolygon(&star, Color.hex(0xffd23f));
        try list.polyline(&star, 2, Color.hex(0x8a6a00), true);
    }
    // An arc gauge stroked along a path.
    {
        var path = gfx.Path.init(list.gpa);
        defer path.deinit();
        try path.arc(.{ card.x + 250, card.y + 156 }, 30, std.math.pi * 0.75, std.math.pi * (0.75 + 1.5 * level));
        try list.strokePath(&path, 6, Color.hex(0x3ddc97));
    }
    // Nine-slice: one 8x8 image stretched into panels of any size, its
    // one-texel border staying a constant width.
    try list.nineSlice(assets.checker, .{ .x = card.x + 16, .y = card.y + 200, .width = 120 + 60 * level, .height = 36 }, .{ 2, 2, 2, 2 }, 3, .{ .pixelated = true });
    try list.text(font, "nine-slice", .{ card.x + 210, card.y + 210 }, .{ .size = 15, .color = Color.hex(0x9aa7d0) });

    // --- Text: ligatures, right-to-left scripts, mixed runs. ---
    const words = gfx.Rect{ .x = width - 330, .y = 336, .width = 312, .height = 226 };
    try list.roundedRect(words, Color.rgba(12, 14, 22, 215), .{ .radius = 12 });
    try list.text(font, "office affluent fjord flight", .{ words.x + 14, words.y + 10 }, .{ .size = 20 });
    try list.text(font, "office affluent fjord flight", .{ words.x + 14, words.y + 34 }, .{ .size = 20, .shaping = false, .color = Color.hex(0x7c8499) });
    try list.text(font, "with and without ligatures", .{ words.x + 14, words.y + 58 }, .{ .size = 12, .color = Color.hex(0x9aa7d0) });
    // Right-to-left lines are right-aligned, as their readers expect.
    try list.text(font, hebrew, .{ words.x + words.width - 14, words.y + 78 }, .{ .size = 22, .alignment = .right });
    try list.text(font, arabic, .{ words.x + words.width - 14, words.y + 106 }, .{ .size = 22, .alignment = .right });
    try list.text(font, mixed, .{ words.x + 14, words.y + 136 }, .{ .size = 16 });
    // Rich text: runs with their own size and color, wrapped as one block.
    _ = try list.richText(&.{
        .{ .text = "Rich text " },
        .{ .text = "mixes ", .color = Color.hex(0x3ddc97) },
        .{ .text = "sizes ", .size = 22, .color = Color.hex(0xffd23f) },
        .{ .text = "and colors on one baseline and wraps at the panel's edge." },
    }, .{ words.x + 14, words.y + 162 }, .{ .font = font, .size = 14, .max_width = words.width - 28 });
}
