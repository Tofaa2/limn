//! Immediate-mode drawing: shapes, images and text, on screen and in the
//! world.
//!
//! A `DrawList` is plain CPU data owned by whoever records into it. Recording
//! takes no locks and touches no renderer state, so each thread can fill its
//! own list; the lists are handed to `Renderer.render`, which draws them in
//! order after the scene.
//!
//! Screen-space calls take pixels with the origin at the top-left corner.
//! World-space calls (`*3d`) take world units and are depth-tested against
//! the scene. Colors are 8-bit sRGB.
const std = @import("std");
const math = @import("../math.zig");
const font_module = @import("font_baker").font;
const text_layout = @import("text_layout.zig");

/// A loaded font (`font_baker.font.Font`), re-exported so text calls can
/// be written against this module alone. The draw list only borrows fonts:
/// one must outlive every list drawn with it.
pub const Font = font_module.Font;

/// An 8-bit color as it is written in an image editor or in CSS: red,
/// green and blue are sRGB-encoded (the renderer converts them to linear
/// light itself) and `a` is opacity, 0 clear to 255 opaque. Four bytes in
/// r, g, b, a order; stored in each `Vertex` as is.
pub const Color = extern struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    /// Opaque white. As an image tint it leaves the image unchanged.
    pub const white: Color = .{ .r = 255, .g = 255, .b = 255 };
    /// Opaque black.
    pub const black: Color = .{ .r = 0, .g = 0, .b = 0 };
    /// Fully clear; draws nothing.
    pub const transparent: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };

    /// Opaque color from sRGB components, 0..255 each.
    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return .{ .r = r, .g = g, .b = b };
    }

    /// Color from sRGB components and an opacity, 0..255 each.
    pub fn rgba(r: u8, g: u8, b: u8, a: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    /// From 0xRRGGBB.
    pub fn hex(value: u24) Color {
        return .{ .r = @truncate(value >> 16), .g = @truncate(value >> 8), .b = @truncate(value) };
    }

    /// The same color with its opacity replaced (not multiplied) by
    /// `alpha`.
    pub fn withAlpha(self: Color, alpha: u8) Color {
        return .{ .r = self.r, .g = self.g, .b = self.b, .a = alpha };
    }
};

/// A texture usable by draw lists. A plain value: safe to copy and to use
/// from any thread until the image is destroyed.
pub const Image = struct {
    /// Index in the renderer's bindless texture table.
    index: u32,
    /// Size in pixels.
    width: u32,
    height: u32,
};

/// An axis-aligned rectangle: `x`, `y` is its top-left corner, with y
/// growing downward. In pixels of the current transform for screen-space
/// calls and clips, and in image pixels for `ImageOptions.source`.
pub const Rect = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
};

/// 2D affine transform: `x' = a*x + c*y + tx`, `y' = b*x + d*y + ty`.
pub const Transform2D = struct {
    a: f32 = 1,
    b: f32 = 0,
    c: f32 = 0,
    d: f32 = 1,
    tx: f32 = 0,
    ty: f32 = 0,

    /// Leaves points where they are; what a cleared draw list starts with.
    pub const identity: Transform2D = .{};

    /// Moves points by `x`, `y` pixels.
    pub fn translation(x: f32, y: f32) Transform2D {
        return .{ .tx = x, .ty = y };
    }

    /// Scales about the origin by `x` horizontally and `y` vertically.
    pub fn scaling(x: f32, y: f32) Transform2D {
        return .{ .a = x, .d = y };
    }

    /// Clockwise on screen (y points down), in radians.
    pub fn rotation(angle: f32) Transform2D {
        const s = @sin(angle);
        const c = @cos(angle);
        return .{ .a = c, .b = s, .c = -s, .d = c };
    }

    /// Applies `inner` first, then `self`.
    pub fn mul(self: Transform2D, inner: Transform2D) Transform2D {
        return .{
            .a = self.a * inner.a + self.c * inner.b,
            .b = self.b * inner.a + self.d * inner.b,
            .c = self.a * inner.c + self.c * inner.d,
            .d = self.b * inner.c + self.d * inner.d,
            .tx = self.a * inner.tx + self.c * inner.ty + self.tx,
            .ty = self.b * inner.tx + self.d * inner.ty + self.ty,
        };
    }

    /// Where the transform puts the point `p`.
    pub fn apply(self: Transform2D, p: [2]f32) [2]f32 {
        return .{ self.a * p[0] + self.c * p[1] + self.tx, self.b * p[0] + self.d * p[1] + self.ty };
    }

    /// A 2D camera: world point `center` lands on `screen_center`, scaled by
    /// `zoom` and rotated by `angle`.
    pub fn camera(center: [2]f32, zoom: f32, angle: f32, screen_center: [2]f32) Transform2D {
        return translation(screen_center[0], screen_center[1])
            .mul(rotation(-angle))
            .mul(scaling(zoom, zoom))
            .mul(translation(-center[0], -center[1]));
    }

    fn scale(self: Transform2D) f32 {
        return @sqrt(@abs(self.a * self.d - self.b * self.c));
    }
};

/// Where each line of text sits relative to the position it is drawn at:
/// `left` starts there, `center` is centered on it and `right` ends
/// there. Lines are aligned one by one, each by its own width.
pub const Alignment = enum { left, center, right };

/// How `DrawList.text` draws a string. The slices are only read during
/// the call.
pub const TextOptions = struct {
    /// Pixels per em.
    size: f32 = 16,
    color: Color = .white,
    alignment: Alignment = .left,
    /// Draws a one-pixel-offset copy underneath, for legibility over scenes.
    shadow: ?Color = null,
    /// Fonts to take glyphs from when the main font lacks them (another
    /// script, symbols, emoji outlines), tried in order.
    fallback: []const *const Font = &.{},
    /// Ligatures, Arabic letter forms and right-to-left runs. Costs nothing
    /// for text that has none of them.
    shaping: bool = true,
    /// The language of the text, as OpenType names it (`"ROM "`,
    /// `"SRB "`, ...), for letters a font draws differently in it.
    language: ?[4]u8 = null,
    /// Font features to apply besides the usual ligatures and contextual
    /// forms, by their OpenType names (`"smcp"`, `"salt"`, `"case"`,
    /// `"dlig"`, ...). The glyphs they bring in must be in the atlas:
    /// see `Renderer.prepareTextWith`.
    features: []const [4]u8 = &.{},
};

/// How `DrawList.text3d` draws a string in the world.
pub const Text3dOptions = struct {
    /// World units per em.
    size: f32 = 0.25,
    color: Color = .white,
    alignment: Alignment = .center,
    /// Face the camera, anchored at `position`. When false the text lies in
    /// the XY plane of `transform`, reading along +X with +Y up.
    billboard: bool = true,
    /// Local-to-world matrix of the text's plane. Used only when
    /// `billboard` is false.
    transform: math.Mat4 = math.identity,
    /// Fonts to take a glyph from when the main one lacks it, in order.
    fallback: []const *const Font = &.{},
};

/// Shared with `shaders/draw.vert`.
pub const Vertex = extern struct {
    position: [3]f32,
    /// Camera-facing offset in world units (billboards), else zero.
    offset: [2]f32 = .{ 0, 0 },
    uv: [2]f32 = .{ 0, 0 },
    color: Color,
    /// `Mode` in the top byte, texture index in the low 24 bits.
    texture_mode: u32,
};

const Mode = enum(u32) {
    solid = 0,
    image = 1,
    text = 2,
    /// uv spans [-1, 1]; antialiased unit disc.
    circle = 3,
    /// uv spans [-1, 1]; antialiased box edges.
    smooth = 4,
    /// A world-space segment expanded to a pixel width in the vertex shader.
    line3d = 5,
    image_nearest = 6,
    /// uv is the pixel offset from the center, `offset` half the size;
    /// radius and stroke width are packed into the texture bits.
    rounded = 7,
};

fn pack(mode: Mode, texture: u32) u32 {
    return @intFromEnum(mode) << 24 | (texture & 0x00ff_ffff);
}

/// Twice the signed area of triangle a, b, c.
fn cross2(a: [2]f32, b: [2]f32, c: [2]f32) f32 {
    return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]);
}

/// An outline built from lines and curves, for `DrawList.fillPath` and
/// `strokePath`. Curves are flattened into short segments as they are
/// added; `tolerance` is how far, in the path's own units, a segment may
/// stray from the true curve.
pub const Path = struct {
    gpa: std.mem.Allocator,
    /// The flattened outline so far, in order.
    points: std.ArrayList([2]f32) = .empty,
    /// Set by `close`: a stroke joins the last point back to the first.
    closed: bool = false,
    /// Largest distance a flattened curve may stray from the true one, in
    /// the path's units. Set it before adding curves; smaller is smoother
    /// and costs more points.
    tolerance: f32 = 0.25,

    /// An empty path. Nothing is allocated until points are added; `gpa`
    /// is kept for the point list.
    pub fn init(gpa: std.mem.Allocator) Path {
        return .{ .gpa = gpa };
    }

    /// Frees the points. Draw lists copy what they need when the path is
    /// filled or stroked, so it may be freed right after.
    pub fn deinit(self: *Path) void {
        self.points.deinit(self.gpa);
        self.* = undefined;
    }

    /// Removes every point and reopens the path, keeping its memory and
    /// `tolerance` for the next outline.
    pub fn clear(self: *Path) void {
        self.points.clearRetainingCapacity();
        self.closed = false;
    }

    /// Starts the outline at `p`.
    pub fn moveTo(self: *Path, p: [2]f32) !void {
        self.clear();
        try self.points.append(self.gpa, p);
    }

    /// Straight line from the current end of the outline to `p`.
    pub fn lineTo(self: *Path, p: [2]f32) !void {
        try self.points.append(self.gpa, p);
    }

    /// Quadratic curve to `end`, pulled toward `control`.
    pub fn quadTo(self: *Path, control: [2]f32, end: [2]f32) !void {
        const start = self.points.items[self.points.items.len - 1];
        // Raise to a cubic with the same shape.
        try self.cubicTo(
            .{ start[0] + (control[0] - start[0]) * 2 / 3, start[1] + (control[1] - start[1]) * 2 / 3 },
            .{ end[0] + (control[0] - end[0]) * 2 / 3, end[1] + (control[1] - end[1]) * 2 / 3 },
            end,
        );
    }

    /// Cubic Bezier curve to `end` with two control points.
    pub fn cubicTo(self: *Path, control_a: [2]f32, control_b: [2]f32, end: [2]f32) !void {
        const start = self.points.items[self.points.items.len - 1];
        // Enough segments that none strays further than the tolerance,
        // estimated from how far the control points are from the chord.
        const deviation = @max(
            @abs(cross2(start, end, control_a)),
            @abs(cross2(start, end, control_b)),
        ) / @max(@sqrt((end[0] - start[0]) * (end[0] - start[0]) + (end[1] - start[1]) * (end[1] - start[1])), 1e-6);
        const segments: usize = @intFromFloat(std.math.clamp(@ceil(@sqrt(deviation / @max(self.tolerance, 1e-3)) * 2), 1, 64));
        for (1..segments + 1) |index| {
            const t = @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(segments));
            const u = 1 - t;
            var p: [2]f32 = undefined;
            inline for (0..2) |axis| p[axis] = u * u * u * start[axis] + 3 * u * u * t * control_a[axis] + 3 * u * t * t * control_b[axis] + t * t * t * end[axis];
            try self.points.append(self.gpa, p);
        }
    }

    /// Arc of a circle around `center`, from `start_angle` to `end_angle`
    /// in radians (clockwise on screen), joined to the outline by a line.
    pub fn arc(self: *Path, center: [2]f32, radius: f32, start_angle: f32, end_angle: f32) !void {
        const sweep = end_angle - start_angle;
        const step = 2 * std.math.acos(1 - @min(self.tolerance / @max(radius, 1e-3), 1));
        const segments: usize = @intFromFloat(std.math.clamp(@ceil(@abs(sweep) / @max(step, 1e-3)), 1, 256));
        for (0..segments + 1) |index| {
            const angle = start_angle + sweep * @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(segments));
            try self.points.append(self.gpa, .{ center[0] + @cos(angle) * radius, center[1] + @sin(angle) * radius });
        }
    }

    /// Joins the end back to the start.
    pub fn close(self: *Path) void {
        self.closed = true;
    }
};

/// A grid of equally sized frames in one image, for animated sprites and
/// tile sets.
pub const SpriteSheet = struct {
    image: Image,
    columns: u32,
    rows: u32,

    /// Source rectangle of frame `index`, counting left to right, top to
    /// bottom. Pass it as `ImageOptions.source`.
    pub fn frame(self: SpriteSheet, index: u32) Rect {
        const width = @as(f32, @floatFromInt(self.image.width)) / @as(f32, @floatFromInt(self.columns));
        const height = @as(f32, @floatFromInt(self.image.height)) / @as(f32, @floatFromInt(self.rows));
        const wrapped = index % (self.columns * self.rows);
        return .{
            .x = @as(f32, @floatFromInt(wrapped % self.columns)) * width,
            .y = @as(f32, @floatFromInt(wrapped / self.columns)) * height,
            .width = width,
            .height = height,
        };
    }
};
/// The substitutions of fonts (see `Font.substitution`) for the scripts,
/// languages and features text has been drawn with, worked out once and
/// kept by a draw list for as long as it lives.
const SubstitutionCache = struct {
    const Entry = struct {
        font: u64,
        script: [4]u8,
        language: [4]u8,
        features: u64,
        /// Null when the font has nothing for these.
        with: ?font_module.Substitution,
    };
    /// More than this many and the oldest go: fonts come and go, and a
    /// program may draw with any number of feature sets.
    const limit = 32;

    entries: std.ArrayList(Entry) = .empty,

    fn deinit(self: *SubstitutionCache, gpa: std.mem.Allocator) void {
        for (self.entries.items) |*entry| if (entry.with) |*with| with.deinit(gpa);
        self.entries.deinit(gpa);
    }

    fn get(self: *SubstitutionCache, gpa: std.mem.Allocator, font: *const Font, shaping: font_module.Shaping) !?*const font_module.Substitution {
        const language = shaping.language orelse [4]u8{ 0, 0, 0, 0 };
        const features = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(shaping.features));
        for (self.entries.items) |*entry| {
            if (entry.font == font.id and entry.features == features and std.mem.eql(u8, &entry.script, &shaping.script) and std.mem.eql(u8, &entry.language, &language))
                return if (entry.with) |*with| with else null;
        }
        if (self.entries.items.len >= limit) {
            var oldest = self.entries.orderedRemove(0);
            if (oldest.with) |*with| with.deinit(gpa);
        }
        try self.entries.ensureUnusedCapacity(gpa, 1);
        const with = try font.substitution(gpa, shaping);
        self.entries.appendAssumeCapacity(.{ .font = font.id, .script = shaping.script, .language = language, .features = features, .with = with });
        const added = &self.entries.items[self.entries.items.len - 1];
        return if (added.with) |*kept| kept else null;
    }
};

/// Whether a character names a mark glyph of a right-to-left script (see
/// `font.glyph_codepoints_rtl_mark`).
fn isMarkName(codepoint: u21) bool {
    return codepoint >= font_module.glyph_codepoints_rtl_mark and codepoint < font_module.glyph_codepoints_rtl_mark + 0x10000;
}

/// A font and the ones that stand in for what it lacks.
const FontSet = struct {
    primary: *const Font,
    fallback: []const *const Font,
    /// See `TextOptions.language` and `TextOptions.features`.
    language: ?[4]u8 = null,
    features: []const [4]u8 = &.{},
    /// Where substitutions worked out for a font are kept, when there is
    /// such a place.
    cache: ?*SubstitutionCache = null,

    fn pick(self: FontSet, codepoint: u21) *const Font {
        if (self.primary.has(codepoint)) return self.primary;
        for (self.fallback) |font| if (font.has(codepoint)) return font;
        return self.primary;
    }

    /// Each font's own substitutions, run by run: a run is what one font
    /// draws of one script, with what has no script of its own going
    /// along.
    fn substitute(context: *const anyopaque, gpa: std.mem.Allocator, line: []const u21, out: *std.ArrayList(u21)) anyerror!void {
        const self: *const FontSet = @ptrCast(@alignCast(context));
        var start: usize = 0;
        while (start < line.len) {
            var script = text_layout.scriptOf(line[start]);
            const font = self.pick(line[start]);
            var end = start + 1;
            while (end < line.len) : (end += 1) {
                const c = line[end];
                if (text_layout.scriptOf(c)) |own| {
                    if (script) |current| {
                        if (!std.mem.eql(u8, &own, &current)) break;
                    } else script = own;
                    if (self.pick(c) != font) break;
                } else if (!font.has(c) and self.pick(c) != font) break;
            }
            const run = line[start..end];
            start = end;
            const tag = script orelse "DFLT".*;
            const shaping = font_module.Shaping{ .script = tag, .language = self.language, .features = self.features };
            // Where the font has nothing for a script (or a glyph is not
            // baked), the run stays as typed; Arabic is then joined
            // through its presentation forms further on.
            const done = if (self.cache) |cache|
                if (try cache.get(gpa, font, shaping)) |with| try font.substituteWith(gpa, run, with, out) else false
            else
                try font.substitute(gpa, run, shaping, out);
            if (!done)
                try out.appendSlice(gpa, run);
        }
    }

    /// The ligature, if any, of the font that draws the first character.
    fn ligature(context: *const anyopaque, rest: []const u21) ?text_layout.LigatureMatch {
        const self: *const FontSet = @ptrCast(@alignCast(context));
        const match = self.pick(rest[0]).ligature(rest) orelse return null;
        return .{ .consumed = match.consumed, .codepoint = match.codepoint };
    }

    fn covers(context: *const anyopaque, codepoint: u21) bool {
        const self: *const FontSet = @ptrCast(@alignCast(context));
        if (self.primary.has(codepoint)) return true;
        for (self.fallback) |font| if (font.has(codepoint)) return true;
        return false;
    }
};

/// The geometry recorded for one space of a draw list (screen or world):
/// an indexed triangle list in draw order, which the renderer uploads and
/// draws as is. Owned by its `DrawList`.
pub const Batch = struct {
    vertices: std.ArrayList(Vertex) = .empty,
    /// Three per triangle, each an index into `vertices`.
    indices: std.ArrayList(u32) = .empty,
    /// Where the clip rectangle changes, in index order. Empty means the
    /// whole batch is unclipped.
    clips: std.ArrayList(ClipRange) = .empty,

    /// A clip rectangle and where it takes effect: indices from
    /// `first_index` up to the next range's (or the end of the batch) are
    /// drawn clipped to `rect`, in untransformed screen pixels; null is
    /// unclipped.
    pub const ClipRange = struct { first_index: u32, rect: ?Rect };

    fn quad(self: *Batch, gpa: std.mem.Allocator, corners: [4]Vertex) !void {
        const base: u32 = @intCast(self.vertices.items.len);
        try self.vertices.appendSlice(gpa, &corners);
        try self.indices.appendSlice(gpa, &.{ base, base + 1, base + 2, base, base + 2, base + 3 });
    }
};

/// One frame's worth of 2D and world-space drawing, recorded on the CPU
/// and handed to `Renderer.render`. Things are drawn in the order they
/// were recorded, later over earlier. Typical use: `clear` at the start of
/// a frame, record, render, and keep the list for the next frame.
///
/// A list is not thread safe, but separate lists share nothing, so each
/// thread can record into its own. Drawing calls return an error when an
/// allocation fails; what was recorded before stays valid.
pub const DrawList = struct {
    gpa: std.mem.Allocator,
    /// Screen-space geometry, in pixels from the top-left corner.
    screen: Batch = .{},
    /// World-space geometry from the `*3d` calls, depth-tested against
    /// the scene.
    world: Batch = .{},
    /// The current 2D transform, applied to screen-space calls as they
    /// are recorded. Change it with `pushTransform` and `popTransform`.
    transform: Transform2D = .identity,
    /// Soften the edges of filled polygons, convex shapes and triangles
    /// over one pixel, as lines and circles are. Off draws them with the
    /// hard edges of plain triangles (and without the extra vertices).
    antialias_fills: bool = true,
    transform_stack: [16]Transform2D = undefined,
    transform_depth: u8 = 0,
    /// The current clip rectangle in screen pixels, or null for none.
    /// Change it with `pushClip` and `popClip`.
    clip: ?Rect = null,
    clip_stack: [16]?Rect = undefined,
    clip_depth: u8 = 0,
    glyph_scratch: std.ArrayList(u21) = .empty,
    /// The fonts' substitutions for what text has been drawn with.
    substitutions: SubstitutionCache = .{},

    /// An empty list. Nothing is allocated until something is drawn;
    /// `gpa` is kept and used for all of the list's memory.
    pub fn init(gpa: std.mem.Allocator) DrawList {
        return .{ .gpa = gpa };
    }

    /// Frees everything the list holds. It must not be in use by a
    /// `Renderer.render` call. Fonts and images it drew with are not
    /// touched.
    pub fn deinit(self: *DrawList) void {
        self.screen.vertices.deinit(self.gpa);
        self.screen.indices.deinit(self.gpa);
        self.screen.clips.deinit(self.gpa);
        self.glyph_scratch.deinit(self.gpa);
        self.substitutions.deinit(self.gpa);
        self.world.vertices.deinit(self.gpa);
        self.world.indices.deinit(self.gpa);
        self.* = undefined;
    }

    /// Empties the list, keeping its memory for the next frame.
    pub fn clear(self: *DrawList) void {
        self.screen.vertices.clearRetainingCapacity();
        self.screen.indices.clearRetainingCapacity();
        self.screen.clips.clearRetainingCapacity();
        self.clip = null;
        self.clip_depth = 0;
        self.world.vertices.clearRetainingCapacity();
        self.world.indices.clearRetainingCapacity();
        self.transform = .identity;
        self.transform_depth = 0;
    }

    /// Whether nothing has been recorded since the last `clear`, on
    /// screen or in the world.
    pub fn isEmpty(self: *const DrawList) bool {
        return self.screen.indices.items.len == 0 and self.world.indices.items.len == 0;
    }

    // ---------------------------------------------------------- transforms

    /// Composes `transform` onto the current 2D transform until the
    /// matching `popTransform`. Affects screen-space calls only. Pushes
    /// nest up to 16 deep.
    pub fn pushTransform(self: *DrawList, transform: Transform2D) void {
        std.debug.assert(self.transform_depth < self.transform_stack.len);
        self.transform_stack[self.transform_depth] = self.transform;
        self.transform_depth += 1;
        self.transform = self.transform.mul(transform);
    }

    /// Restores the transform that was current before the matching
    /// `pushTransform`. What was already drawn keeps the transform it was
    /// drawn with.
    pub fn popTransform(self: *DrawList) void {
        std.debug.assert(self.transform_depth > 0);
        self.transform_depth -= 1;
        self.transform = self.transform_stack[self.transform_depth];
    }

    // ------------------------------------------------------------ clipping

    /// Restricts screen-space drawing to `r` (in the current transform's
    /// coordinates) until the matching `popClip`. Nested clips intersect.
    /// The clip is an axis-aligned rectangle on screen: under a rotation it
    /// is the bounding box of `r`. Pushes nest up to 16 deep.
    pub fn pushClip(self: *DrawList, r: Rect) !void {
        std.debug.assert(self.clip_depth < self.clip_stack.len);
        var low = [2]f32{ std.math.inf(f32), std.math.inf(f32) };
        var high = [2]f32{ -std.math.inf(f32), -std.math.inf(f32) };
        for ([4][2]f32{ .{ r.x, r.y }, .{ r.x + r.width, r.y }, .{ r.x, r.y + r.height }, .{ r.x + r.width, r.y + r.height } }) |corner| {
            const p = self.transform.apply(corner);
            inline for (0..2) |axis| {
                low[axis] = @min(low[axis], p[axis]);
                high[axis] = @max(high[axis], p[axis]);
            }
        }
        if (self.clip) |outer| {
            low = .{ @max(low[0], outer.x), @max(low[1], outer.y) };
            high = .{ @min(high[0], outer.x + outer.width), @min(high[1], outer.y + outer.height) };
        }
        self.clip_stack[self.clip_depth] = self.clip;
        self.clip_depth += 1;
        try self.setClip(.{ .x = low[0], .y = low[1], .width = @max(high[0] - low[0], 0), .height = @max(high[1] - low[1], 0) });
    }

    /// Restores the clip that was current before the matching `pushClip`
    /// (none, for the outermost). Can fail only by running out of memory
    /// while recording the change.
    pub fn popClip(self: *DrawList) !void {
        std.debug.assert(self.clip_depth > 0);
        self.clip_depth -= 1;
        try self.setClip(self.clip_stack[self.clip_depth]);
    }

    fn setClip(self: *DrawList, clip: ?Rect) !void {
        self.clip = clip;
        const first: u32 = @intCast(self.screen.indices.items.len);
        // Replace a range nothing was drawn in rather than leaving it empty.
        if (self.screen.clips.items.len != 0 and self.screen.clips.items[self.screen.clips.items.len - 1].first_index == first) {
            self.screen.clips.items[self.screen.clips.items.len - 1].rect = clip;
        } else {
            try self.screen.clips.append(self.gpa, .{ .first_index = first, .rect = clip });
        }
    }

    // -------------------------------------------------------------- shapes

    /// A rectangle with a different color at each corner (top-left,
    /// top-right, bottom-right, bottom-left), blended across it.
    pub fn rectGradient(self: *DrawList, r: Rect, colors: [4]Color) !void {
        const mode = pack(.solid, 0);
        try self.screen.quad(self.gpa, .{
            self.screenVertex(.{ r.x, r.y }, .{ 0, 0 }, colors[0], mode),
            self.screenVertex(.{ r.x + r.width, r.y }, .{ 0, 0 }, colors[1], mode),
            self.screenVertex(.{ r.x + r.width, r.y + r.height }, .{ 0, 0 }, colors[2], mode),
            self.screenVertex(.{ r.x, r.y + r.height }, .{ 0, 0 }, colors[3], mode),
        });
    }

    /// Top-to-bottom gradient.
    pub fn rectGradientVertical(self: *DrawList, r: Rect, top: Color, bottom: Color) !void {
        try self.rectGradient(r, .{ top, top, bottom, bottom });
    }

    /// Left-to-right gradient.
    pub fn rectGradientHorizontal(self: *DrawList, r: Rect, left: Color, right: Color) !void {
        try self.rectGradient(r, .{ left, right, right, left });
    }

    /// How `roundedRect` draws its rectangle.
    pub const RoundedOptions = struct {
        /// Corner radius in pixels.
        radius: f32 = 8,
        /// Draw only an outline this thick, inside the rectangle; 0 fills.
        stroke: f32 = 0,
        /// Optional top-to-bottom gradient end color.
        bottom_color: ?Color = null,
    };

    /// Antialiased rectangle with rounded corners, filled or outlined.
    pub fn roundedRect(self: *DrawList, r: Rect, color: Color, options: RoundedOptions) !void {
        const half = [2]f32{ r.width * 0.5, r.height * 0.5 };
        const radius = std.math.clamp(options.radius, 0, @min(half[0], half[1]));
        // Radius and stroke ride in the texture bits, in quarter pixels.
        const packed_radius: u32 = @intFromFloat(@min(radius * 4, 4095));
        const packed_stroke: u32 = @intFromFloat(std.math.clamp(options.stroke * 4, 0, 4095));
        const mode = pack(.rounded, packed_radius | packed_stroke << 12);
        const pad = 1.0 / @max(self.transform.scale(), 1e-6);
        const bottom = options.bottom_color orelse color;
        const corners = [4][2]f32{ .{ -half[0] - pad, -half[1] - pad }, .{ half[0] + pad, -half[1] - pad }, .{ half[0] + pad, half[1] + pad }, .{ -half[0] - pad, half[1] + pad } };
        var vertices: [4]Vertex = undefined;
        for (corners, &vertices, 0..) |corner, *vertex, index| {
            vertex.* = self.screenVertex(.{ r.x + half[0] + corner[0], r.y + half[1] + corner[1] }, corner, if (index < 2) color else bottom, mode);
            // Half the size, for the distance computation in the shader.
            vertex.offset = half;
        }
        try self.screen.quad(self.gpa, vertices);
    }

    /// Emits a filled outline with soft edges: the fill is drawn half a
    /// pixel inside the outline and a strip that fades to nothing half a
    /// pixel outside it. Returns the index of the first fill vertex; the
    /// caller adds the fill's triangles over vertices `base + i`.
    fn outlineVertices(self: *DrawList, points: []const [2]f32, color: Color) !u32 {
        const base: u32 = @intCast(self.screen.vertices.items.len);
        const mode = pack(.solid, 0);
        if (!self.antialias_fills) {
            for (points) |p| try self.screen.vertices.append(self.gpa, self.screenVertex(p, .{ 0, 0 }, color, mode));
            return base;
        }
        var area: f32 = 0;
        for (points, 0..) |p, index| {
            const q = points[(index + 1) % points.len];
            area += p[0] * q[1] - q[0] * p[1];
        }
        // Which way is out depends on the order the outline was given in.
        const outward: f32 = if (area >= 0) 1 else -1;
        const half_pixel = 0.5 / @max(self.transform.scale(), 1e-6);
        const count: u32 = @intCast(points.len);
        try self.screen.vertices.ensureUnusedCapacity(self.gpa, points.len * 2);
        try self.screen.indices.ensureUnusedCapacity(self.gpa, points.len * 6);
        const faded = color.withAlpha(0);
        for (points, 0..) |p, index| {
            const before = points[(index + points.len - 1) % points.len];
            const after = points[(index + 1) % points.len];
            // The corner's outward direction: between the normals of the
            // two edges that meet here, longer the sharper the corner.
            const n0 = edgeNormal(before, p, outward);
            const n1 = edgeNormal(p, after, outward);
            var miter = [2]f32{ n0[0] + n1[0], n0[1] + n1[1] };
            const length_squared = miter[0] * miter[0] + miter[1] * miter[1];
            if (length_squared > 1e-6) {
                // 2 / |n0 + n1|^2 keeps both edges half a pixel away; capped
                // so a needle-sharp corner does not shoot off.
                const scale = @min(2 / length_squared, 4.0);
                miter = .{ miter[0] * scale, miter[1] * scale };
            } else miter = n0;
            self.screen.vertices.appendAssumeCapacity(self.screenVertex(.{ p[0] - miter[0] * half_pixel, p[1] - miter[1] * half_pixel }, .{ 0, 0 }, color, mode));
        }
        for (points, 0..) |p, index| {
            const before = points[(index + points.len - 1) % points.len];
            const after = points[(index + 1) % points.len];
            const n0 = edgeNormal(before, p, outward);
            const n1 = edgeNormal(p, after, outward);
            var miter = [2]f32{ n0[0] + n1[0], n0[1] + n1[1] };
            const length_squared = miter[0] * miter[0] + miter[1] * miter[1];
            if (length_squared > 1e-6) {
                const scale = @min(2 / length_squared, 4.0);
                miter = .{ miter[0] * scale, miter[1] * scale };
            } else miter = n0;
            self.screen.vertices.appendAssumeCapacity(self.screenVertex(.{ p[0] + miter[0] * half_pixel, p[1] + miter[1] * half_pixel }, .{ 0, 0 }, faded, mode));
            const i: u32 = @intCast(index);
            const next = (i + 1) % count;
            self.screen.indices.appendSliceAssumeCapacity(&.{ base + i, base + next, base + count + next, base + i, base + count + next, base + count + i });
        }
        return base;
    }

    /// Fills a convex polygon given in order around its outline.
    pub fn fillConvex(self: *DrawList, points: []const [2]f32, color: Color) !void {
        if (points.len < 3) return;
        const base = try self.outlineVertices(points, color);
        for (1..points.len - 1) |index| {
            try self.screen.indices.appendSlice(self.gpa, &.{ base, base + @as(u32, @intCast(index)), base + @as(u32, @intCast(index)) + 1 });
        }
    }

    /// Fills any simple polygon (one that does not cross itself), convex
    /// or not, by cutting off one corner triangle at a time.
    pub fn fillPolygon(self: *DrawList, points: []const [2]f32, color: Color) !void {
        if (points.len < 3) return;
        const base = try self.outlineVertices(points, color);
        var remaining: std.ArrayList(u32) = .empty;
        defer remaining.deinit(self.gpa);
        try remaining.ensureTotalCapacity(self.gpa, points.len);
        var area: f32 = 0;
        for (points, 0..) |p, index| {
            const q = points[(index + 1) % points.len];
            area += p[0] * q[1] - q[0] * p[1];
            remaining.appendAssumeCapacity(@intCast(index));
        }
        const winding: f32 = if (area >= 0) 1 else -1;
        var guard: usize = 0;
        while (remaining.items.len > 3 and guard < points.len * points.len) : (guard += 1) {
            const count = remaining.items.len;
            var clipped = false;
            for (0..count) |i| {
                const ia = remaining.items[(i + count - 1) % count];
                const ib = remaining.items[i];
                const ic = remaining.items[(i + 1) % count];
                const a = points[ia];
                const b = points[ib];
                const c = points[ic];
                // A corner that bends the same way as the whole outline...
                if (cross2(a, b, c) * winding <= 0) continue;
                // ...and has no other point inside it is an ear.
                var blocked = false;
                for (remaining.items) |other| {
                    if (other == ia or other == ib or other == ic) continue;
                    const p = points[other];
                    if (cross2(a, b, p) * winding >= 0 and cross2(b, c, p) * winding >= 0 and cross2(c, a, p) * winding >= 0) {
                        blocked = true;
                        break;
                    }
                }
                if (blocked) continue;
                try self.screen.indices.appendSlice(self.gpa, &.{ base + ia, base + ib, base + ic });
                _ = remaining.orderedRemove(i);
                clipped = true;
                break;
            }
            if (!clipped) break;
        }
        if (remaining.items.len == 3)
            try self.screen.indices.appendSlice(self.gpa, &.{ base + remaining.items[0], base + remaining.items[1], base + remaining.items[2] });
    }

    /// Antialiased line through `points` with round joins and ends; `closed`
    /// connects the last point back to the first.
    pub fn polyline(self: *DrawList, points: []const [2]f32, thickness: f32, color: Color, closed: bool) !void {
        if (points.len < 2) return;
        const segments = if (closed) points.len else points.len - 1;
        for (0..segments) |index| try self.line(points[index], points[(index + 1) % points.len], thickness, color);
        // Discs at the corners fill the wedges between segments. They only
        // look right for opaque colors; translucent strokes show overlap.
        if (thickness > 1.5) for (points) |p| try self.circle(p, thickness * 0.5, color);
    }

    /// Fills the outline a `Path` describes (see `fillPolygon`).
    pub fn fillPath(self: *DrawList, path: *const Path, color: Color) !void {
        try self.fillPolygon(path.points.items, color);
    }

    /// Strokes the outline a `Path` describes.
    pub fn strokePath(self: *DrawList, path: *const Path, thickness: f32, color: Color) !void {
        try self.polyline(path.points.items, thickness, color, path.closed);
    }

    // ------------------------------------------------------------- sprites

    /// Draws an image whose border stays its own size while the middle
    /// stretches: panels, buttons and speech bubbles from one small image.
    /// `border` is left, top, right, bottom in image pixels; `scale`
    /// enlarges the border on screen.
    pub fn nineSlice(self: *DrawList, img: Image, destination: Rect, border: [4]f32, scale: f32, options: ImageOptions) !void {
        const source = options.source orelse Rect{ .x = 0, .y = 0, .width = @floatFromInt(img.width), .height = @floatFromInt(img.height) };
        const source_x = [4]f32{ source.x, source.x + border[0], source.x + source.width - border[2], source.x + source.width };
        const source_y = [4]f32{ source.y, source.y + border[1], source.y + source.height - border[3], source.y + source.height };
        // If the destination is smaller than the two borders, they shrink.
        const fit_x = @min(1, destination.width / @max((border[0] + border[2]) * scale, 1e-6));
        const fit_y = @min(1, destination.height / @max((border[1] + border[3]) * scale, 1e-6));
        const target_x = [4]f32{ destination.x, destination.x + border[0] * scale * fit_x, destination.x + destination.width - border[2] * scale * fit_x, destination.x + destination.width };
        const target_y = [4]f32{ destination.y, destination.y + border[1] * scale * fit_y, destination.y + destination.height - border[3] * scale * fit_y, destination.y + destination.height };
        var piece = options;
        for (0..3) |row| for (0..3) |column| {
            const width = target_x[column + 1] - target_x[column];
            const height = target_y[row + 1] - target_y[row];
            if (width <= 0 or height <= 0) continue;
            piece.source = .{ .x = source_x[column], .y = source_y[row], .width = source_x[column + 1] - source_x[column], .height = source_y[row + 1] - source_y[row] };
            try self.image(img, .{ .x = target_x[column], .y = target_y[row], .width = width, .height = height }, piece);
        };
    }

    // -------------------------------------------------------------- screen

    fn screenVertex(self: *const DrawList, p: [2]f32, uv: [2]f32, color: Color, texture_mode: u32) Vertex {
        const transformed = self.transform.apply(p);
        return .{ .position = .{ transformed[0], transformed[1], 0 }, .uv = uv, .color = color, .texture_mode = texture_mode };
    }

    fn screenQuad(self: *DrawList, r: Rect, uv: [4]f32, color: Color, texture_mode: u32) !void {
        try self.screen.quad(self.gpa, .{
            self.screenVertex(.{ r.x, r.y }, .{ uv[0], uv[1] }, color, texture_mode),
            self.screenVertex(.{ r.x + r.width, r.y }, .{ uv[2], uv[1] }, color, texture_mode),
            self.screenVertex(.{ r.x + r.width, r.y + r.height }, .{ uv[2], uv[3] }, color, texture_mode),
            self.screenVertex(.{ r.x, r.y + r.height }, .{ uv[0], uv[3] }, color, texture_mode),
        });
    }

    /// Filled rectangle in one color. Its edges are not antialiased, so
    /// under a rotation they show steps.
    pub fn rect(self: *DrawList, r: Rect, color: Color) !void {
        try self.screenQuad(r, .{ 0, 0, 0, 0 }, color, pack(.solid, 0));
    }

    /// Border of `r`, `thickness` pixels wide and lying wholly inside it,
    /// drawn as four rectangles that do not overlap (so translucent
    /// colors stay even at the corners).
    pub fn rectOutline(self: *DrawList, r: Rect, thickness: f32, color: Color) !void {
        try self.rect(.{ .x = r.x, .y = r.y, .width = r.width, .height = thickness }, color);
        try self.rect(.{ .x = r.x, .y = r.y + r.height - thickness, .width = r.width, .height = thickness }, color);
        try self.rect(.{ .x = r.x, .y = r.y + thickness, .width = thickness, .height = r.height - 2 * thickness }, color);
        try self.rect(.{ .x = r.x + r.width - thickness, .y = r.y + thickness, .width = thickness, .height = r.height - 2 * thickness }, color);
    }

    /// Filled triangle.
    pub fn triangle(self: *DrawList, a: [2]f32, b: [2]f32, c: [2]f32, color: Color) !void {
        const base = try self.outlineVertices(&.{ a, b, c }, color);
        try self.screen.indices.appendSlice(self.gpa, &.{ base, base + 1, base + 2 });
    }

    /// Antialiased line segment.
    pub fn line(self: *DrawList, a: [2]f32, b: [2]f32, thickness: f32, color: Color) !void {
        const dx = b[0] - a[0];
        const dy = b[1] - a[1];
        const length = @sqrt(dx * dx + dy * dy);
        if (length < 1e-6) return;
        // Half a pixel of padding gives the edge falloff room.
        const half = thickness * 0.5 + 0.5 / @max(self.transform.scale(), 1e-6);
        const nx = -dy / length * half;
        const ny = dx / length * half;
        const mode = pack(.smooth, 0);
        try self.screen.quad(self.gpa, .{
            self.screenVertex(.{ a[0] + nx, a[1] + ny }, .{ -1, 1 }, color, mode),
            self.screenVertex(.{ b[0] + nx, b[1] + ny }, .{ 1, 1 }, color, mode),
            self.screenVertex(.{ b[0] - nx, b[1] - ny }, .{ 1, -1 }, color, mode),
            self.screenVertex(.{ a[0] - nx, a[1] - ny }, .{ -1, -1 }, color, mode),
        });
    }

    /// Antialiased filled circle.
    pub fn circle(self: *DrawList, center: [2]f32, radius: f32, color: Color) !void {
        try self.screenQuad(
            .{ .x = center[0] - radius, .y = center[1] - radius, .width = radius * 2, .height = radius * 2 },
            .{ -1, -1, 1, 1 },
            color,
            pack(.circle, 0),
        );
    }

    /// How `image` and `nineSlice` draw their image.
    pub const ImageOptions = struct {
        /// Sub-rectangle of the image in pixels; the whole image by default.
        source: ?Rect = null,
        /// Multiplies the image's color and opacity; white leaves it as is.
        tint: Color = .white,
        /// Nearest-neighbour sampling, for pixel art.
        pixelated: bool = false,
    };

    /// Draws `img` stretched over `destination`.
    pub fn image(self: *DrawList, img: Image, destination: Rect, options: ImageOptions) !void {
        const w: f32 = @floatFromInt(img.width);
        const h: f32 = @floatFromInt(img.height);
        const uv: [4]f32 = if (options.source) |s|
            .{ s.x / w, s.y / h, (s.x + s.width) / w, (s.y + s.height) / h }
        else
            .{ 0, 0, 1, 1 };
        try self.screenQuad(destination, uv, options.tint, pack(if (options.pixelated) .image_nearest else .image, img.index));
    }

    /// Draws UTF-8 `string` with its top-left corner at `position` (or the
    /// top-center / top-right for other alignments). `\n` starts a new line.
    pub fn text(self: *DrawList, font: *const Font, string: []const u8, position: [2]f32, options: TextOptions) !void {
        if (options.shadow) |shadow| {
            var shadowed = options;
            shadowed.shadow = null;
            shadowed.color = shadow;
            const offset = @max(1, options.size / 16);
            try self.text(font, string, .{ position[0] + offset, position[1] + offset }, shadowed);
        }
        const fonts = FontSet{ .primary = font, .fallback = options.fallback, .language = options.language, .features = options.features, .cache = &self.substitutions };
        var lines = std.mem.splitScalar(u8, string, '\n');
        var baseline = position[1] + font.ascent * options.size;
        while (lines.next()) |line_text| : (baseline += font.line_height * options.size) {
            const glyphs = try self.lineGlyphs(fonts, line_text, options.shaping);
            const width = lineWidth(fonts, glyphs, options.size);
            const start = position[0] - switch (options.alignment) {
                .left => 0,
                .center => width * 0.5,
                .right => width,
            };
            _ = try self.emitGlyphs(fonts, glyphs, .{ start, baseline }, options.size, options.color);
        }
    }

    /// Decodes one line into `self.glyph_scratch`, shaped if it needs it.
    fn lineGlyphs(self: *DrawList, fonts: FontSet, line_text: []const u8, shaping: bool) ![]const u21 {
        self.glyph_scratch.clearRetainingCapacity();
        if (shaping and (fonts.language != null or fonts.features.len != 0 or text_layout.mayBeSubstituted(line_text))) {
            try text_layout.shapeLine(self.gpa, line_text, .{ .context = &fonts, .has = FontSet.covers, .substitute = FontSet.substitute }, &self.glyph_scratch);
        } else {
            var iterator = font_module.Utf8Iterator{ .bytes = line_text };
            while (iterator.next()) |codepoint| try self.glyph_scratch.append(self.gpa, codepoint);
        }
        return self.glyph_scratch.items;
    }

    fn lineWidth(fonts: FontSet, glyphs: []const u21, size: f32) f32 {
        var width: f32 = 0;
        var previous: ?u21 = null;
        var mark_below: ?u21 = null;
        // The part of a ligature the next mark belongs to, when shaping
        // said which.
        var component: u8 = 0;
        for (glyphs) |codepoint| {
            // A change of spacing worked out while the run was shaped.
            if (font_module.spacingOf(codepoint)) |ems| {
                width += ems;
                continue;
            }
            if (font_module.componentOf(codepoint)) |part| {
                // Marks on different parts do not stack on each other.
                if (part != component) mark_below = null;
                component = part;
                continue;
            }
            const source = fonts.pick(codepoint);
            // A mark set on the letter before it takes no room.
            if (previous) |base| if (source.markPlacement(base, component, mark_below, .{ 0, 0 }, codepoint) != null) {
                mark_below = codepoint;
                continue;
            };
            // A mark the font does not place takes no room either.
            if (isMarkName(codepoint)) continue;
            mark_below = null;
            if (previous) |left| {
                width += source.kern(left, codepoint);
                if (source.cursive(left, codepoint)) |join| width += join[0];
            }
            width += source.glyph(codepoint).advance;
            previous = codepoint;
            component = 0;
        }
        return width * size;
    }

    /// Draws text in columns, as Chinese, Japanese and Korean are set
    /// when written downward: each character upright and centered in its
    /// column, columns running from right to left at each line break.
    /// `position` is the top of the first column, at its middle. A font
    /// made for it is used as it means to be: its forms for text set
    /// downward (brackets and long marks turned, small letters and
    /// punctuation moved; the `vert` feature, once those glyphs are baked
    /// with `Renderer.prepareTextWith` and that feature) and its own
    /// advances down the column. With a font that has neither, every
    /// character takes a square one `size` tall. Letters of scripts
    /// written across are stacked the same way rather than turned on
    /// their side. Of `options`, `size`, `color`, `shadow`, `fallback` and
    /// `language` are used.
    pub fn textVertical(self: *DrawList, font: *const Font, string: []const u8, position: [2]f32, options: TextOptions) !void {
        if (options.shadow) |shadow| {
            var shadowed = options;
            shadowed.shadow = null;
            shadowed.color = shadow;
            const offset = @max(1, options.size / 16);
            try self.textVertical(font, string, .{ position[0] + offset, position[1] + offset }, shadowed);
        }
        const fonts = FontSet{ .primary = font, .fallback = options.fallback, .language = options.language, .features = &.{"vert".*}, .cache = &self.substitutions };
        const size = options.size;
        var column = position[0];
        var lines = std.mem.splitScalar(u8, string, '\n');
        while (lines.next()) |line_text| : (column -= font.line_height * size) {
            const glyphs = try self.lineGlyphs(fonts, line_text, true);
            var top = position[1];
            // Where the last full-size character was set, for marks on it.
            var base_top = top;
            var base_height = size;
            for (glyphs) |codepoint| {
                // Spacing and ligature parts worked out for text set across
                // mean nothing down a column.
                if (font_module.spacingOf(codepoint) != null or font_module.componentOf(codepoint) != null) continue;
                const source = fonts.pick(codepoint);
                const baked = source.baked();
                const glyph = baked.glyph(codepoint);
                // A combining mark stays on the character above it.
                const mark = (codepoint >= 0x300 and codepoint <= 0x36f) or (codepoint >= 0x3099 and codepoint <= 0x309a);
                // The font's own advance down the column, or a square; a
                // space in a font without such advances takes half of one,
                // as it does between words set across.
                const height = if (glyph.advance_down > 0) glyph.advance_down * size else if (codepoint == ' ') size * 0.5 else size;
                const cell_top = if (mark) base_top else top;
                const cell_height = if (mark) base_height else height;
                // Upright and centered: the character keeps its own shape, and
                // its advance across becomes the room it is centered in.
                const left = column - glyph.advance * 0.5 * size;
                const baseline = cell_top + (cell_height - size) * 0.5 + source.ascent * size / (source.ascent + source.descent);
                if (glyph.plane[2] > glyph.plane[0]) try self.screenQuad(.{
                    .x = left + glyph.plane[0] * size,
                    .y = baseline - glyph.plane[3] * size,
                    .width = (glyph.plane[2] - glyph.plane[0]) * size,
                    .height = (glyph.plane[3] - glyph.plane[1]) * size,
                }, glyph.uv, options.color, pack(.text, baked.texture_index));
                if (mark) continue;
                base_top = top;
                base_height = height;
                top += height;
            }
        }
    }

    /// Emits quads for `glyphs` starting at `pen` on the baseline; returns
    /// where the pen ends up.
    fn emitGlyphs(self: *DrawList, fonts: FontSet, glyphs: []const u21, pen_start: [2]f32, size: f32, color: Color) !f32 {
        var pen = pen_start[0];
        var previous: ?u21 = null;
        // Where the letter before was set, for marks that sit on it.
        var base_pen = pen;
        // The mark last set on that letter and where, for marks that stack.
        var mark_below: ?u21 = null;
        // The part of a ligature the next mark belongs to, when shaping
        // said which.
        var component: u8 = 0;
        var mark_at: [2]f32 = .{ 0, 0 };
        // How far above the baseline the letters stand, in ems: in a
        // cursive script each letter hangs on the one after it.
        var rise: f32 = 0;
        for (glyphs) |codepoint| {
            // Each glyph comes from the first font that has it, so a line
            // can mix scripts no single font covers.
            if (font_module.spacingOf(codepoint)) |ems| {
                // A change of spacing worked out while the run was shaped.
                pen += ems * size;
                continue;
            }
            if (font_module.componentOf(codepoint)) |part| {
                // Marks on different parts do not stack on each other.
                if (part != component) mark_below = null;
                component = part;
                continue;
            }
            const source = fonts.pick(codepoint);
            // One bake for both the glyph and the atlas it points into.
            const baked = source.baked();
            const glyph = baked.glyph(codepoint);
            if (previous) |base| if (source.markPlacement(base, component, mark_below, mark_at, codepoint)) |offset| {
                mark_below = codepoint;
                mark_at = offset;
                // A combining mark: on its letter, where the font says.
                if (glyph.plane[2] > glyph.plane[0]) try self.screenQuad(.{
                    .x = base_pen + (offset[0] + glyph.plane[0]) * size,
                    .y = pen_start[1] - (offset[1] + rise + glyph.plane[3]) * size,
                    .width = (glyph.plane[2] - glyph.plane[0]) * size,
                    .height = (glyph.plane[3] - glyph.plane[1]) * size,
                }, glyph.uv, color, pack(.text, baked.texture_index));
                continue;
            };
            if (isMarkName(codepoint)) {
                // A mark the font does not place: where the pen is.
                if (glyph.plane[2] > glyph.plane[0]) try self.screenQuad(.{
                    .x = pen + glyph.plane[0] * size,
                    .y = pen_start[1] - (rise + glyph.plane[3]) * size,
                    .width = (glyph.plane[2] - glyph.plane[0]) * size,
                    .height = (glyph.plane[3] - glyph.plane[1]) * size,
                }, glyph.uv, color, pack(.text, baked.texture_index));
                continue;
            }
            if (previous) |left| {
                pen += source.kern(left, codepoint) * size;
                if (source.cursive(left, codepoint)) |join| {
                    pen += join[0] * size;
                    rise += join[1];
                } else rise = 0;
            }
            base_pen = pen;
            mark_below = null;
            previous = codepoint;
            component = 0;
            if (glyph.plane[2] > glyph.plane[0]) {
                // Glyph planes are y-up from the baseline; the screen is y-down.
                try self.screenQuad(.{
                    .x = pen + glyph.plane[0] * size,
                    .y = pen_start[1] - (rise + glyph.plane[3]) * size,
                    .width = (glyph.plane[2] - glyph.plane[0]) * size,
                    .height = (glyph.plane[3] - glyph.plane[1]) * size,
                }, glyph.uv, color, pack(.text, baked.texture_index));
            }
            pen += glyph.advance * size;
        }
        return pen;
    }

    /// One stretch of text in its own font, size and color.
    pub const TextRun = struct {
        /// UTF-8; only read during the `richText` call.
        text: []const u8,
        /// Null for each of these takes the one in `RichTextOptions`.
        font: ?*const Font = null,
        /// Pixels per em.
        size: ?f32 = null,
        color: ?Color = null,
    };

    /// How `richText` lays out its runs, and what runs that leave their
    /// font, size or color unset are drawn with.
    pub const RichTextOptions = struct {
        /// Used by runs that do not set their own.
        font: *const Font,
        /// Pixels per em.
        size: f32 = 16,
        color: Color = .white,
        /// Wrap at word boundaries to this width in pixels; null never wraps.
        max_width: ?f32 = null,
        alignment: Alignment = .left,
        /// Multiplies the distance between lines.
        line_spacing: f32 = 1,
        /// Fonts to take a glyph from when a run's font lacks it, in order.
        fallback: []const *const Font = &.{},
    };

    /// Draws several runs of text as one flowing paragraph: mixed fonts,
    /// sizes and colors share a baseline on each line, words wrap at
    /// `max_width`, and `\n` in any run starts a new line. Returns the size
    /// of the block drawn.
    pub fn richText(self: *DrawList, runs: []const TextRun, position: [2]f32, options: RichTextOptions) ![2]f32 {
        const Word = struct { run: usize, text: []const u8, width: f32, space: f32, line_break: bool };
        var words: std.ArrayList(Word) = .empty;
        defer words.deinit(self.gpa);
        for (runs, 0..) |run, run_index| {
            const fonts = FontSet{ .primary = run.font orelse options.font, .fallback = options.fallback, .cache = &self.substitutions };
            const size = run.size orelse options.size;
            const space = fonts.primary.glyph(' ').advance * size;
            var rest = run.text;
            while (rest.len != 0) {
                const end = std.mem.indexOfAny(u8, rest, " \n") orelse rest.len;
                const word = rest[0..end];
                const separator: u8 = if (end < rest.len) rest[end] else 0;
                const glyphs = try self.lineGlyphs(fonts, word, true);
                try words.append(self.gpa, .{
                    .run = run_index,
                    .text = word,
                    .width = lineWidth(fonts, glyphs, size),
                    .space = if (separator == ' ') space else 0,
                    .line_break = separator == '\n',
                });
                rest = rest[@min(end + 1, rest.len)..];
            }
        }

        var extent = [2]f32{ 0, 0 };
        var y = position[1];
        var first: usize = 0;
        while (first < words.items.len) {
            // Take words until the line is full or a break is asked for.
            var width: f32 = 0;
            var ascent: f32 = 0;
            var descent: f32 = 0;
            var line_height: f32 = 0;
            var last = first;
            while (last < words.items.len) : (last += 1) {
                const word = words.items[last];
                const added = (if (last > first) words.items[last - 1].space else 0) + word.width;
                if (options.max_width) |limit| if (last > first and width + added > limit) break;
                width += added;
                const run = runs[word.run];
                const font = run.font orelse options.font;
                const size = run.size orelse options.size;
                ascent = @max(ascent, font.ascent * size);
                descent = @max(descent, font.descent * size);
                line_height = @max(line_height, font.line_height * size);
                if (word.line_break) {
                    last += 1;
                    break;
                }
            }
            var pen = position[0] - switch (options.alignment) {
                .left => 0,
                .center => width * 0.5,
                .right => width,
            };
            for (words.items[first..last], first..) |word, index| {
                const run = runs[word.run];
                const fonts = FontSet{ .primary = run.font orelse options.font, .fallback = options.fallback, .cache = &self.substitutions };
                const glyphs = try self.lineGlyphs(fonts, word.text, true);
                pen = try self.emitGlyphs(fonts, glyphs, .{ pen, y + ascent }, run.size orelse options.size, run.color orelse options.color);
                if (index + 1 < last) pen += word.space;
            }
            extent[0] = @max(extent[0], width);
            y += @max(line_height, ascent + descent) * options.line_spacing;
            first = last;
        }
        extent[1] = y - position[1];
        return extent;
    }

    // --------------------------------------------------------------- world

    /// Filled quad; corners in order around the perimeter.
    pub fn quad3d(self: *DrawList, corners: [4]math.Vec3, color: Color) !void {
        const mode = pack(.solid, 0);
        try self.world.quad(self.gpa, .{
            .{ .position = corners[0], .color = color, .texture_mode = mode },
            .{ .position = corners[1], .color = color, .texture_mode = mode },
            .{ .position = corners[2], .color = color, .texture_mode = mode },
            .{ .position = corners[3], .color = color, .texture_mode = mode },
        });
    }

    /// Line between two world points with a constant on-screen `thickness`
    /// in pixels.
    pub fn line3d(self: *DrawList, a: math.Vec3, b: math.Vec3, thickness: f32, color: Color) !void {
        const mode = pack(.line3d, 0);
        // Each vertex carries the far endpoint in `offset`+`uv.x` and its
        // side (signed half thickness) in `uv.y`.
        const half = thickness * 0.5;
        try self.world.quad(self.gpa, .{
            .{ .position = a, .offset = .{ b[0], b[1] }, .uv = .{ b[2], half }, .color = color, .texture_mode = mode },
            .{ .position = b, .offset = .{ a[0], a[1] }, .uv = .{ a[2], -half }, .color = color, .texture_mode = mode },
            .{ .position = b, .offset = .{ a[0], a[1] }, .uv = .{ a[2], half }, .color = color, .texture_mode = mode },
            .{ .position = a, .offset = .{ b[0], b[1] }, .uv = .{ b[2], -half }, .color = color, .texture_mode = mode },
        });
    }

    /// Wireframe axis-aligned box.
    pub fn box3d(self: *DrawList, minimum: math.Vec3, maximum: math.Vec3, thickness: f32, color: Color) !void {
        const x = [2]f32{ minimum[0], maximum[0] };
        const y = [2]f32{ minimum[1], maximum[1] };
        const z = [2]f32{ minimum[2], maximum[2] };
        for (0..2) |i| for (0..2) |j| {
            try self.line3d(.{ x[0], y[i], z[j] }, .{ x[1], y[i], z[j] }, thickness, color);
            try self.line3d(.{ x[i], y[0], z[j] }, .{ x[i], y[1], z[j] }, thickness, color);
            try self.line3d(.{ x[i], y[j], z[0] }, .{ x[i], y[j], z[1] }, thickness, color);
        };
    }

    /// Camera-facing image centered on `position`; `size` in world units.
    pub fn billboard(self: *DrawList, img: Image, position: math.Vec3, size: [2]f32, tint: Color) !void {
        const mode = pack(.image, img.index);
        const hx = size[0] * 0.5;
        const hy = size[1] * 0.5;
        try self.world.quad(self.gpa, .{
            .{ .position = position, .offset = .{ -hx, hy }, .uv = .{ 0, 0 }, .color = tint, .texture_mode = mode },
            .{ .position = position, .offset = .{ hx, hy }, .uv = .{ 1, 0 }, .color = tint, .texture_mode = mode },
            .{ .position = position, .offset = .{ hx, -hy }, .uv = .{ 1, 1 }, .color = tint, .texture_mode = mode },
            .{ .position = position, .offset = .{ -hx, -hy }, .uv = .{ 0, 1 }, .color = tint, .texture_mode = mode },
        });
    }

    /// Text in the world. With `billboard` it faces the camera, vertically
    /// centered on `position`; otherwise it is laid out in the XY plane of
    /// `options.transform` with `position` as the local origin offset.
    pub fn text3d(self: *DrawList, font: *const Font, string: []const u8, position: math.Vec3, options: Text3dOptions) !void {
        const size = options.size;
        var line_count: f32 = 1;
        for (string) |byte| {
            if (byte == '\n') line_count += 1;
        }
        // Center the block vertically around the anchor.
        var baseline = (line_count * font.line_height * 0.5 - font.ascent) * size;
        var lines = std.mem.splitScalar(u8, string, '\n');
        while (lines.next()) |line_text| : (baseline -= font.line_height * size) {
            // Shaped like 2D text: ligatures, joined forms, right-to-left.
            const fonts = FontSet{ .primary = font, .fallback = options.fallback, .cache = &self.substitutions };
            const glyphs = try self.lineGlyphs(fonts, line_text, true);
            var pen = -switch (options.alignment) {
                .left => 0,
                .center => lineWidth(fonts, glyphs, size) * 0.5,
                .right => lineWidth(fonts, glyphs, size),
            };
            var previous: ?u21 = null;
            var glyph_index: usize = 0;
            var base_pen = pen;
            var mark_below: ?u21 = null;
            // The part of a ligature the next mark belongs to, when shaping
            // said which.
            var component: u8 = 0;
            var mark_at: [2]f32 = .{ 0, 0 };
            var rise: f32 = 0;
            // Appending vertices never touches the glyph list.
            while (glyph_index < glyphs.len) : (glyph_index += 1) {
                const codepoint = glyphs[glyph_index];
                if (font_module.spacingOf(codepoint)) |ems| {
                    pen += ems * size;
                    continue;
                }
                if (font_module.componentOf(codepoint)) |part| {
                    // Marks on different parts do not stack on each other.
                    if (part != component) mark_below = null;
                    component = part;
                    continue;
                }
                // As in 2D, each glyph comes from the first font that has it.
                const source = fonts.pick(codepoint);
                const baked = source.baked();
                const mode = pack(.text, baked.texture_index);
                const glyph = baked.glyph(codepoint);
                // A combining mark is set on the letter before it and
                // takes no room; the pen is put back after it is drawn.
                const anchored: ?[2]f32 = if (previous) |base| source.markPlacement(base, component, mark_below, mark_at, codepoint) else null;
                const pen_after = pen;
                var raise: f32 = 0;
                if (anchored) |offset| {
                    pen = base_pen + offset[0] * size;
                    raise = (offset[1] + rise) * size;
                    mark_below = codepoint;
                    mark_at = offset;
                } else {
                    if (previous) |left| {
                        pen += source.kern(left, codepoint) * size;
                        if (source.cursive(left, codepoint)) |join| {
                            pen += join[0] * size;
                            rise += join[1];
                        } else rise = 0;
                    }
                    raise = rise * size;
                    base_pen = pen;
                    mark_below = null;
                }
                if (anchored == null) previous = codepoint;
                if (glyph.plane[2] > glyph.plane[0]) {
                    const left = pen + glyph.plane[0] * size;
                    const right = pen + glyph.plane[2] * size;
                    const bottom = baseline + raise + glyph.plane[1] * size;
                    const top = baseline + raise + glyph.plane[3] * size;
                    const local = [4][2]f32{ .{ left, top }, .{ right, top }, .{ right, bottom }, .{ left, bottom } };
                    const uvs = [4][2]f32{
                        .{ glyph.uv[0], glyph.uv[1] },
                        .{ glyph.uv[2], glyph.uv[1] },
                        .{ glyph.uv[2], glyph.uv[3] },
                        .{ glyph.uv[0], glyph.uv[3] },
                    };
                    var corners: [4]Vertex = undefined;
                    for (&corners, local, uvs) |*corner, p, uv| {
                        corner.* = if (options.billboard)
                            .{ .position = position, .offset = p, .uv = uv, .color = options.color, .texture_mode = mode }
                        else
                            .{
                                .position = math.transformPoint(options.transform, .{ position[0] + p[0], position[1] + p[1], position[2] }),
                                .uv = uv,
                                .color = options.color,
                                .texture_mode = mode,
                            };
                    }
                    try self.world.quad(self.gpa, corners);
                }
                pen = if (anchored != null) pen_after else pen + glyph.advance * size;
            }
        }
    }
};

fn alignmentOffset(font: *const Font, line_text: []const u8, size: f32, alignment: Alignment) f32 {
    return switch (alignment) {
        .left => 0,
        .center => font.measure(line_text, size)[0] * 0.5,
        .right => font.measure(line_text, size)[0],
    };
}

comptime {
    std.debug.assert(@sizeOf(Vertex) == 36);
}

test "transform composition applies the inner transform first" {
    const t = Transform2D.translation(10, 0).mul(Transform2D.scaling(2, 2));
    const p = t.apply(.{ 3, 4 });
    try std.testing.expectApproxEqAbs(@as(f32, 16), p[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 8), p[1], 1e-6);
    const camera = Transform2D.camera(.{ 100, 50 }, 2, 0, .{ 400, 300 });
    const center = camera.apply(.{ 100, 50 });
    try std.testing.expectApproxEqAbs(@as(f32, 400), center[0], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 300), center[1], 1e-4);
}

test "draw list batches quads and honours the transform stack" {
    var list = DrawList.init(std.testing.allocator);
    defer list.deinit();
    list.pushTransform(.translation(5, 5));
    try list.rect(.{ .x = 0, .y = 0, .width = 10, .height = 10 }, .white);
    list.popTransform();
    try list.circle(.{ 0, 0 }, 4, .black);
    try list.line3d(.{ 0, 0, 0 }, .{ 1, 0, 0 }, 2, .white);
    try std.testing.expectEqual(@as(usize, 8), list.screen.vertices.items.len);
    try std.testing.expectEqual(@as(usize, 12), list.screen.indices.items.len);
    try std.testing.expectEqual(@as(usize, 6), list.world.indices.items.len);
    try std.testing.expectApproxEqAbs(@as(f32, 5), list.screen.vertices.items[0].position[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -4), list.screen.vertices.items[4].position[0], 1e-6);
    list.clear();
    try std.testing.expect(list.isEmpty());
}

/// Unit normal of the edge from `a` to `b`, pointing out of an outline
/// whose winding sign is `outward`.
fn edgeNormal(a: [2]f32, b: [2]f32, outward: f32) [2]f32 {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const length = @sqrt(dx * dx + dy * dy);
    if (length < 1e-9) return .{ 0, 0 };
    return .{ dy / length * outward, -dx / length * outward };
}

test "filled shapes get a fringe that fades out around them" {
    var list = DrawList.init(std.testing.allocator);
    defer list.deinit();
    const square = [_][2]f32{ .{ 10, 10 }, .{ 30, 10 }, .{ 30, 30 }, .{ 10, 30 } };
    try list.fillConvex(&square, Color.rgb(255, 0, 0));
    // Four fill vertices half a pixel inside, four clear ones half a pixel
    // outside; two fill triangles and two per edge of fringe.
    try std.testing.expectEqual(@as(usize, 8), list.screen.vertices.items.len);
    try std.testing.expectEqual(@as(usize, 6 + 4 * 6), list.screen.indices.items.len);
    const inner = list.screen.vertices.items[0];
    const outer = list.screen.vertices.items[4];
    try std.testing.expectApproxEqAbs(@as(f32, 10.5), inner.position[0], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 9.5), outer.position[0], 1e-4);
    try std.testing.expectEqual(@as(u8, 255), inner.color.a);
    try std.testing.expectEqual(@as(u8, 0), outer.color.a);
    // The other way round the outline, out is still out.
    list.clear();
    const reversed = [_][2]f32{ .{ 10, 30 }, .{ 30, 30 }, .{ 30, 10 }, .{ 10, 10 } };
    try list.fillConvex(&reversed, Color.rgb(255, 0, 0));
    try std.testing.expectApproxEqAbs(@as(f32, 30.5), list.screen.vertices.items[4].position[1], 1e-4);
    // Without it, plain triangles.
    list.clear();
    list.antialias_fills = false;
    try list.fillConvex(&square, Color.rgb(255, 0, 0));
    try std.testing.expectEqual(@as(usize, 4), list.screen.vertices.items.len);
}
