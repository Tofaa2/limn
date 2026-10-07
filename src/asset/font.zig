//! TrueType loading and signed-distance-field atlas baking. A `Font` holds
//! glyph metrics, kerning and one SDF atlas usable at any size.
const std = @import("std");
const opentype = @import("opentype.zig");
const indic = @import("indic.zig");
const arabic = @import("arabic.zig");

/// Pixels per em in the atlas.
pub const atlas_em: f32 = 40;
/// Distance, in atlas pixels, mapped to the 0..1 range on each side of the
/// outline. Shared with the text shader.
pub const sdf_spread: f32 = 5;

/// First and last codepoint, inclusive.
pub const Range = [2]u21;
/// Printable ASCII plus Latin-1.
pub const default_ranges: []const Range = &.{ .{ 32, 126 }, .{ 160, 255 } };

pub const Glyph = struct {
    /// A glyph with no character of its own gets one from a private range; see
    /// `glyph_codepoints`.
    codepoint: u21,
    /// Glyph index in the font file.
    id: u16 = 0,
    /// Horizontal advance, in ems.
    advance: f32,
    /// Vertical advance, in ems; 0 when the font has no vertical metrics.
    advance_down: f32 = 0,
    /// Quad corners relative to the pen on the baseline, in ems, y up: left,
    /// bottom, right, top. Zero-area for blank glyphs.
    plane: [4]f32 = .{ 0, 0, 0, 0 },
    /// Atlas texture coordinates: left, top, right, bottom.
    uv: [4]f32 = .{ 0, 0, 0, 0 },
};

/// One bake of a font. Immutable once a font points at it, so any thread may
/// read it.
pub const Baked = struct {
    /// Sorted by codepoint.
    glyphs: []Glyph,
    /// left << 32 | right to ems; see `kern`.
    kerning: std.AutoHashMapUnmanaged(u64, f32) = .empty,
    /// base << 32 | mark to the offset of the mark's origin from the base's, in
    /// ems, y up.
    marks: std.AutoHashMapUnmanaged(u64, [2]f32) = .empty,
    /// Keyed by `ligatureMarkKey`.
    ligature_marks: std.AutoHashMapUnmanaged(u64, [2]f32) = .empty,
    /// GPOS cursive attachment points.
    cursive: std.AutoHashMapUnmanaged(u21, Cursive) = .empty,
    /// Longest first.
    ligatures: []Ligature = &.{},
    /// In texels.
    atlas_width: u32,
    atlas_height: u32,
    /// R8 distance field, row-major, top row first. Freed once a later bake
    /// replaces this one.
    atlas: []u8,
    /// Three-channel distance field, three bytes a texel; see `colorEdges`.
    msdf: []u8 = &.{},
    /// Index in the renderer's bindless texture table; set by the renderer.
    texture_index: u32 = 0,
    /// Shelf packer state: the pen and the height of its shelf.
    pen: [2]u32 = .{ 1, 1 },
    shelf_height: u32 = 0,
    ranges: []Range,

    fn deinit(self: *Baked, gpa: std.mem.Allocator) void {
        gpa.free(self.glyphs);
        gpa.free(self.ranges);
        gpa.free(self.atlas);
        gpa.free(self.msdf);
        self.kerning.deinit(gpa);
        self.marks.deinit(gpa);
        self.ligature_marks.deinit(gpa);
        self.cursive.deinit(gpa);
        gpa.free(self.ligatures);
    }

    /// Falls back to '?' and then to the first baked glyph.
    pub fn glyph(self: *const Baked, codepoint: u21) *const Glyph {
        return self.find(codepoint) orelse self.find('?') orelse &self.glyphs[0];
    }

    /// Null when `codepoint` is not in this bake.
    pub fn find(self: *const Baked, codepoint: u21) ?*const Glyph {
        var low: usize = 0;
        var high: usize = self.glyphs.len;
        while (low < high) {
            const mid = (low + high) / 2;
            const value = self.glyphs[mid].codepoint;
            if (value == codepoint) return &self.glyphs[mid];
            if (value < codepoint) low = mid + 1 else high = mid;
        }
        return null;
    }

    /// Kerning adjustment, in ems.
    pub fn kern(self: *const Baked, left: u21, right: u21) f32 {
        return self.kerning.get(@as(u64, left) << 32 | right) orelse 0;
    }
};

/// Selects a font's substitutions.
pub const Shaping = struct {
    /// OpenType script tag (`latn`, `cyrl`, ...).
    script: opentype.Tag = "DFLT".*,
    /// OpenType language tag (`ROM `, `SRB `, ...); null for the script's
    /// default.
    language: ?opentype.Tag = null,
    /// Extra OpenType features (`smcp`, `salt`, `case`, `dlig`, ...); at most
    /// sixteen.
    features: []const opentype.Tag = &.{},
};

/// A font's substitutions for one script, language and feature set (see
/// `Font.substitution`).
pub const Substitution = struct {
    /// Point into the font's copy of the file.
    tables: Tables,
    layout: opentype.Layout,
    plan: opentype.Plan,
    /// Set for Indic scripts, which need reordering.
    forms: ?indic.Forms = null,
    /// Arabic joining forms; right to left.
    joined: bool = false,
    /// Mongolian joining forms; left to right.
    joining: bool = false,
    /// The font's contextual positioning for the same script.
    positions: ?Positions = null,

    const Positions = struct { layout: opentype.Layout, plan: opentype.Plan };

    /// The private range a glyph of this script is named in.
    fn nameOf(self: *const Substitution, id: u16) NameKind {
        if (!self.joined) return .ltr;
        return if (self.layout.isMark(id)) .rtl_mark else .rtl;
    }

    /// `gpa` must be the allocator given to `Font.substitution`.
    pub fn deinit(self: *Substitution, gpa: std.mem.Allocator) void {
        self.plan.deinit(gpa);
        if (self.positions) |*positions| positions.plan.deinit(gpa);
    }

    /// Substitutes `text` and applies contextual advances; false when neither
    /// changed anything.
    fn run(self: *const Substitution, gpa: std.mem.Allocator, text: []const u21, glyphs: *std.ArrayList(opentype.Glyph)) !bool {
        var changed = try self.substituted(gpa, text, glyphs);
        if (self.positions) |positions| {
            _ = positions.layout.substitutePlanned(gpa, glyphs, positions.plan) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => false,
            };
            for (glyphs.items) |shaped| {
                if (shaped.advance != 0) changed = true;
            }
        }
        return changed;
    }

    /// Substitutes `text`; false when nothing changed.
    fn substituted(self: *const Substitution, gpa: std.mem.Allocator, text: []const u21, glyphs: *std.ArrayList(opentype.Glyph)) !bool {
        if (self.joined or self.joining) {
            const masks = try gpa.alloc(u32, text.len);
            defer gpa.free(masks);
            arabic.forms(text, masks);
            try glyphs.ensureTotalCapacity(gpa, text.len);
            for (text, masks, 0..) |codepoint, mask, index| glyphs.appendAssumeCapacity(.{
                .id = @intCast((self.tables.glyphIndex(codepoint) catch 0) & 0xffff),
                .cluster = @intCast(index),
                .mask = mask,
            });
            return self.layout.substitutePlanned(gpa, glyphs, self.plan) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => false,
            };
        }
        if (self.forms) |forms| {
            var placed: std.ArrayList(indic.Placed) = .empty;
            defer placed.deinit(gpa);
            try indic.reorder(gpa, text, forms, &placed);
            try glyphs.ensureTotalCapacity(gpa, placed.items.len);
            for (placed.items) |item| glyphs.appendAssumeCapacity(.{
                .id = @intCast((self.tables.glyphIndex(item.codepoint) catch 0) & 0xffff),
                .cluster = item.index,
                .mask = item.mask,
            });
            _ = self.layout.substitutePlanned(gpa, glyphs, self.plan) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => false,
            };
            return true;
        }
        try glyphs.ensureTotalCapacity(gpa, text.len);
        for (text, 0..) |codepoint, index| glyphs.appendAssumeCapacity(.{ .id = @intCast((self.tables.glyphIndex(codepoint) catch 0) & 0xffff), .cluster = @intCast(index) });
        return self.layout.substitutePlanned(gpa, glyphs, self.plan) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => false,
        };
    }
};

/// Features applied to all text.
const usual_features = [_]opentype.Tag{ "ccmp".*, "locl".*, "rlig".*, "rclt".*, "liga".*, "calt".*, "clig".* };

/// The glyph's own character if it is baked under one, else its private name
/// of `kind`; null when not baked.
fn codepointOf(current: *const Baked, id: u16, kind: NameKind) ?u21 {
    var named: ?u21 = null;
    for (current.glyphs) |glyph| {
        if (glyph.id != id) continue;
        if (glyph.codepoint < glyph_codepoints_rtl_mark) return glyph.codepoint;
        if (nameKind(glyph.codepoint) == kind) named = glyph.codepoint;
    }
    return named;
}

/// The private ranges unmapped glyphs are named in. Text layout reads
/// direction and mark-ness from the range.
const NameKind = enum {
    ltr,
    rtl,
    rtl_mark,

    fn base(self: NameKind) u21 {
        return switch (self) {
            .ltr => glyph_codepoints,
            .rtl => glyph_codepoints_rtl,
            .rtl_mark => glyph_codepoints_rtl_mark,
        };
    }
};

fn nameKind(codepoint: u21) NameKind {
    if (codepoint >= glyph_codepoints_rtl) return .rtl;
    if (codepoint >= glyph_codepoints) return .ltr;
    return .rtl_mark;
}

/// Reading is safe from any number of threads, also while another thread
/// adds glyphs with `extend` and `adopt`: bakes are swapped in whole and old
/// ones stay valid until `deinit`.
pub const Font = struct {
    gpa: std.mem.Allocator,
    /// Baseline to the top of the line, in ems.
    ascent: f32,
    /// Baseline to the bottom of the line, in ems (positive).
    descent: f32,
    /// Baseline-to-baseline distance, in ems.
    line_height: f32,
    /// Replaced as a whole, never edited.
    current: std.atomic.Value(*Baked),
    /// Earlier bakes, kept alive for threads still reading them.
    retired: std.ArrayList(*Baked) = .empty,
    /// Unique among the fonts loaded in this process.
    id: u64 = 0,
    /// The font file, kept for `extend`.
    source: []u8 = &.{},

    /// Frees every bake and the copy of the font file. No thread may still be
    /// reading the font. The atlas texture belongs to the renderer.
    pub fn deinit(self: *Font) void {
        const now = self.current.load(.acquire);
        now.deinit(self.gpa);
        self.gpa.destroy(now);
        for (self.retired.items) |old| {
            old.deinit(self.gpa);
            self.gpa.destroy(old);
        }
        self.retired.deinit(self.gpa);
        self.gpa.free(self.source);
        self.* = undefined;
    }

    /// The bake in use. Take it once per piece of text so glyph positions and
    /// atlas match.
    pub fn baked(self: *const Font) *const Baked {
        return self.current.load(.acquire);
    }

    /// Falls back to '?' and then to the first baked glyph.
    pub fn glyph(self: *const Font, codepoint: u21) *const Glyph {
        return self.baked().glyph(codepoint);
    }

    /// Sets the atlas texture of the bake in use. Renderer only, before the
    /// font
    /// is shared.
    pub fn setTexture(self: *Font, texture_index: u32) void {
        self.current.load(.acquire).texture_index = texture_index;
    }

    /// Bakes the `codepoints` the font has and the atlas lacks into a new bake,
    /// not yet in use; null if there is nothing to add. Upload its atlas, set
    /// `texture_index`, then `adopt` or `discard`. Rebuilds the whole atlas.
    pub fn extend(self: *Font, codepoints: []const u21) !?*Baked {
        if (self.source.len == 0) return null;
        const tables = try Tables.init(self.source);
        var ranges: std.ArrayList(Range) = .empty;
        defer ranges.deinit(self.gpa);
        try ranges.appendSlice(self.gpa, self.baked().ranges);
        const known = ranges.items.len;
        for (codepoints) |codepoint| {
            if (self.has(codepoint)) continue;
            if ((tables.glyphIndex(codepoint) catch 0) == 0) continue;
            var listed = false;
            for (ranges.items[known..]) |range| if (range[0] == codepoint) {
                listed = true;
                break;
            };
            if (!listed) try ranges.append(self.gpa, .{ codepoint, codepoint });
        }
        if (ranges.items.len == known) return null;
        // Room to retire the bake in use, so that `adopt` cannot fail.
        try self.retired.ensureUnusedCapacity(self.gpa, 1);
        const next = try self.gpa.create(Baked);
        errdefer self.gpa.destroy(next);
        next.* = try bake(self.gpa, &tables, ranges.items, self.baked());
        return next;
    }

    /// Puts a bake from `extend` to use. Other threads finish with the old one.
    pub fn adopt(self: *Font, next: *Baked) void {
        const old = self.current.swap(next, .acq_rel);
        self.gpa.free(old.atlas);
        self.gpa.free(old.msdf);
        old.msdf = &.{};
        old.atlas = &.{};
        self.retired.appendAssumeCapacity(old);
    }

    /// Frees a bake from `extend` that will not be adopted.
    pub fn discard(self: *Font, next: *Baked) void {
        next.deinit(self.gpa);
        self.gpa.destroy(next);
    }

    /// Whether the font maps `codepoint` to a glyph.
    pub fn has(self: *const Font, codepoint: u21) bool {
        return self.baked().find(codepoint) != null;
    }

    /// Offset of `mark`'s origin from `base`'s, in ems, y up; null when the
    /// font
    /// does not place `mark` on `base`.
    pub fn markOffset(self: *const Font, base: u21, mark: u21) ?[2]f32 {
        return self.baked().marks.get(@as(u64, base) << 32 | mark);
    }

    /// Appends to `out` the characters to draw for `text` after the font's
    /// substitutions; unmapped glyphs appear as `glyph_codepoints`. Returns
    /// false, adding nothing, when nothing changes or a needed glyph is not
    /// baked (see `missingSubstitutes`).
    pub fn substitute(self: *const Font, gpa: std.mem.Allocator, text: []const u21, shaping: Shaping, out: *std.ArrayList(u21)) !bool {
        var with = (try self.substitution(gpa, shaping)) orelse return false;
        defer with.deinit(gpa);
        return self.substituteWith(gpa, text, &with, out);
    }

    /// Substitutions for one script, language and feature set, for reuse across
    /// runs. Null when the font has none. Owned by the caller; valid as long as
    /// the font.
    pub fn substitution(self: *const Font, gpa: std.mem.Allocator, shaping: Shaping) !?Substitution {
        if (self.source.len == 0) return null;
        const tables = Tables.init(self.source) catch return null;
        const layout = opentype.Layout.init(self.source, tables.gsub orelse return null, tables.gdef) catch return null;
        return shapingFor(gpa, tables, layout, shaping);
    }

    fn shapingFor(gpa: std.mem.Allocator, tables: Tables, layout: opentype.Layout, shaping: Shaping) !?Substitution {
        var made = (try substitutionFor(gpa, tables, layout, shaping)) orelse return null;
        errdefer made.deinit(gpa);
        if (tables.gpos) |gpos| if (opentype.Layout.initPositions(tables.reader.bytes, gpos, tables.gdef)) |positions| {
            var plan = positions.plan(gpa, shaping.script, shaping.language, &.{ "kern".*, "dist".* }, tables.glyph_count) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => opentype.Plan{ .lookups = &.{}, .starts = &.{}, .masks = &.{} },
            };
            var any = false;
            for (plan.starts) |set| {
                if (set.count() != 0) any = true;
            }
            if (any) made.positions = .{ .layout = positions, .plan = plan } else plan.deinit(gpa);
        } else |_| {};
        return made;
    }

    fn substitutionFor(gpa: std.mem.Allocator, tables: Tables, layout: opentype.Layout, shaping: Shaping) !?Substitution {
        var tags: [usual_features.len + 16]opentype.Tag = undefined;
        @memcpy(tags[0..usual_features.len], &usual_features);
        const extra = shaping.features[0..@min(shaping.features.len, 16)];
        if (indic.scriptOf(shaping.script)) |script| return indicScript(gpa, tables, layout, script, shaping.language, extra);
        if (std.mem.eql(u8, &shaping.script, "arab") or std.mem.eql(u8, &shaping.script, "mong")) return joinedScript(gpa, tables, layout, shaping.script, shaping.language, extra);
        if (std.mem.eql(u8, &shaping.script, "tibt")) {
            const stacking = [_]opentype.Tag{ "ccmp".*, "locl".*, "abvs".*, "blws".*, "psts".*, "rlig".*, "liga".*, "calt".*, "clig".* };
            var stacked: [stacking.len + 16]opentype.Tag = undefined;
            @memcpy(stacked[0..stacking.len], &stacking);
            @memcpy(stacked[stacking.len..][0..extra.len], extra);
            var plan = layout.plan(gpa, shaping.script, shaping.language, stacked[0 .. stacking.len + extra.len], tables.glyph_count) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return null,
            };
            if (plan.lookups.len == 0) {
                plan.deinit(gpa);
                return null;
            }
            return .{ .tables = tables, .layout = layout, .plan = plan };
        }
        @memcpy(tags[usual_features.len..][0..extra.len], extra);
        var plan = layout.plan(gpa, shaping.script, shaping.language, tags[0 .. usual_features.len + extra.len], tables.glyph_count) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
        if (plan.lookups.len == 0) {
            plan.deinit(gpa);
            return null;
        }
        return .{ .tables = tables, .layout = layout, .plan = plan };
    }

    /// Staged plan for Indic scripts: positional consonant forms one feature at
    /// a time, then ligatures and marks.
    fn indicScript(gpa: std.mem.Allocator, tables: Tables, layout: opentype.Layout, written: *const indic.Script, language: ?opentype.Tag, extra: []const opentype.Tag) !?Substitution {
        const Tag = opentype.Tag;
        const all = indic.mask_all;
        var dressing: [9 + 16]Tag = undefined;
        const usual = [_]Tag{ "pres".*, "abvs".*, "blws".*, "psts".*, "haln".*, "rlig".*, "liga".*, "calt".*, "clig".* };
        @memcpy(dressing[0..usual.len], &usual);
        @memcpy(dressing[usual.len..][0..extra.len], extra);
        const stages = [_]opentype.Stage{
            .{ .features = &.{ "locl".*, "ccmp".* }, .mask = all },
            .{ .features = &.{"nukt".*}, .mask = all },
            .{ .features = &.{"akhn".*}, .mask = all },
            .{ .features = &.{"rphf".*}, .mask = indic.mask_reph },
            .{ .features = &.{"rkrf".*}, .mask = all },
            .{ .features = &.{"pref".*}, .mask = indic.mask_post },
            .{ .features = &.{"blwf".*}, .mask = indic.mask_post },
            .{ .features = &.{"abvf".*}, .mask = indic.mask_post },
            .{ .features = &.{"half".*}, .mask = indic.mask_half },
            .{ .features = &.{"pstf".*}, .mask = indic.mask_post },
            .{ .features = &.{"vatu".*}, .mask = all },
            .{ .features = &.{"cjct".*}, .mask = all },
            .{ .features = &.{"init".*}, .mask = indic.mask_initial },
            .{ .features = dressing[0 .. usual.len + extra.len], .mask = all },
        };
        var script: Tag = written.tag;
        var plan = planOrNull(layout, gpa, script, language, &stages, tables.glyph_count) orelse return error.OutOfMemory;
        if (plan.lookups.len == 0) {
            plan.deinit(gpa);
            script = written.old_tag;
            plan = planOrNull(layout, gpa, script, language, &stages, tables.glyph_count) orelse return error.OutOfMemory;
        }
        errdefer plan.deinit(gpa);
        if (plan.lookups.len == 0) {
            plan.deinit(gpa);
            return null;
        }

        var forms = indic.Forms{ .script = written };
        const halant: u16 = @intCast((tables.glyphIndex(written.halant()) catch 0) & 0xffff);
        var glyphs: std.ArrayList(opentype.Glyph) = .empty;
        defer glyphs.deinit(gpa);
        try glyphs.ensureTotalCapacity(gpa, 8);
        {
            var reph = planOrNull(layout, gpa, script, language, &.{.{ .features = &.{"rphf".*} }}, tables.glyph_count) orelse return error.OutOfMemory;
            defer reph.deinit(gpa);
            const ra: u16 = @intCast((tables.glyphIndex(written.ra()) catch 0) & 0xffff);
            glyphs.appendSliceAssumeCapacity(&.{ .{ .id = ra }, .{ .id = halant } });
            if (written.joiners) glyphs.appendAssumeCapacity(.{ .id = @intCast((tables.glyphIndex(0x200d) catch 0) & 0xffff) });
            forms.reph = written.kinzi or (halant != 0 and ra != 0 and (layout.substitutePlanned(gpa, &glyphs, reph) catch false));
        }
        {
            var below = planOrNull(layout, gpa, script, language, &.{.{ .features = &.{ "blwf".*, "pstf".* } }}, tables.glyph_count) orelse return error.OutOfMemory;
            defer below.deinit(gpa);
            var codepoint: u21 = written.block + 0x15;
            while (below.lookups.len != 0 and codepoint < written.block + 0x80) : (codepoint += 1) {
                const consonant: u16 = @intCast((tables.glyphIndex(codepoint) catch 0) & 0xffff);
                if (consonant == 0 or halant == 0) continue;
                if (written.joiners) {
                    const joiner: u16 = @intCast((tables.glyphIndex(0x200d) catch 0) & 0xffff);
                    glyphs.clearRetainingCapacity();
                    glyphs.appendSliceAssumeCapacity(&.{ .{ .id = halant }, .{ .id = joiner }, .{ .id = consonant } });
                    if (layout.substitutePlanned(gpa, &glyphs, below) catch false) forms.below.set(codepoint - written.block);
                }
                for ([_][2]u16{ .{ halant, consonant }, .{ consonant, halant } }) |pair| {
                    glyphs.clearRetainingCapacity();
                    glyphs.appendSliceAssumeCapacity(&.{ .{ .id = pair[0] }, .{ .id = pair[1] } });
                    if (layout.substitutePlanned(gpa, &glyphs, below) catch false) forms.below.set(codepoint - written.block);
                }
            }
        }
        return .{ .tables = tables, .layout = layout, .plan = plan, .forms = forms };
    }

    /// Staged plan for Arabic: each joining form's feature on the letters that
    /// take it, then ligatures.
    fn joinedScript(gpa: std.mem.Allocator, tables: Tables, layout: opentype.Layout, script: opentype.Tag, language: ?opentype.Tag, extra: []const opentype.Tag) !?Substitution {
        const Tag = opentype.Tag;
        const all = arabic.mask_all;
        var dressing: [5 + 16]Tag = undefined;
        const usual = [_]Tag{ "rclt".*, "calt".*, "liga".*, "clig".*, "mset".* };
        @memcpy(dressing[0..usual.len], &usual);
        @memcpy(dressing[usual.len..][0..extra.len], extra);
        const stages = [_]opentype.Stage{
            .{ .features = &.{ "ccmp".*, "locl".* }, .mask = all },
            .{ .features = &.{"isol".*}, .mask = arabic.mask_isolated },
            .{ .features = &.{"fina".*}, .mask = arabic.mask_final },
            .{ .features = &.{"medi".*}, .mask = arabic.mask_medial },
            .{ .features = &.{"init".*}, .mask = arabic.mask_initial },
            .{ .features = &.{"rlig".*}, .mask = all },
            .{ .features = dressing[0 .. usual.len + extra.len], .mask = all },
        };
        var plan = planOrNull(layout, gpa, script, language, &stages, tables.glyph_count) orelse return error.OutOfMemory;
        if (plan.lookups.len == 0) {
            plan.deinit(gpa);
            return null;
        }
        const rtl = std.mem.eql(u8, &script, "arab");
        return .{ .tables = tables, .layout = layout, .plan = plan, .joined = rtl, .joining = !rtl };
    }

    /// An empty plan if the font's tables are invalid; null only on out of
    /// memory.
    fn planOrNull(layout: opentype.Layout, gpa: std.mem.Allocator, script: opentype.Tag, language: ?opentype.Tag, stages: []const opentype.Stage, glyph_count: u32) ?opentype.Plan {
        return layout.planStages(gpa, script, language, stages, glyph_count) catch |err| switch (err) {
            error.OutOfMemory => null,
            else => .{ .lookups = &.{}, .starts = &.{}, .masks = &.{} },
        };
    }

    /// `substitute` with a prepared `Substitution`.
    pub fn substituteWith(self: *const Font, gpa: std.mem.Allocator, text: []const u21, with: *const Substitution, out: *std.ArrayList(u21)) !bool {
        var glyphs: std.ArrayList(opentype.Glyph) = .empty;
        defer glyphs.deinit(gpa);
        if (!try with.run(gpa, text, &glyphs)) return false;
        const current = self.baked();
        const start = out.items.len;
        errdefer out.items.len = start;
        var across = false;
        for (glyphs.items) |shaped| {
            const original = text[shaped.cluster];
            if ((original == 0x200c or original == 0x200d) and (with.tables.glyphIndex(original) catch 0) == shaped.id) continue;
            const codepoint = if ((with.tables.glyphIndex(original) catch 0) == shaped.id) original else codepointOf(current, shaped.id, with.nameOf(shaped.id)) orelse {
                out.items.len = start;
                return false;
            };
            const spacing: ?u21 = if (shaped.advance != 0) spacingName(@as(f32, @floatFromInt(shaped.advance)) / with.tables.units_per_em, with.joined) else null;
            if (with.joined) if (spacing) |space| try out.append(gpa, space);
            if (shaped.component != 0) {
                try out.append(gpa, componentName(shaped.component, with.joined));
                across = true;
            } else if (across and with.layout.isMark(shaped.id)) {
                try out.append(gpa, componentName(255, with.joined));
            } else across = false;
            try out.append(gpa, codepoint);
            if (!with.joined) if (spacing) |space| try out.append(gpa, space);
        }
        return true;
    }

    /// Appends to `missing` the `glyph_codepoints` characters `substitute`
    /// needs
    /// for `text` that are not baked; add them with `extend`.
    pub fn missingSubstitutes(self: *const Font, gpa: std.mem.Allocator, text: []const u21, shaping: Shaping, missing: *std.ArrayList(u21)) !void {
        var with = (try self.substitution(gpa, shaping)) orelse return;
        defer with.deinit(gpa);
        var glyphs: std.ArrayList(opentype.Glyph) = .empty;
        defer glyphs.deinit(gpa);
        if (!try with.run(gpa, text, &glyphs)) return;
        const current = self.baked();
        for (glyphs.items) |shaped| {
            if ((with.tables.glyphIndex(text[shaped.cluster]) catch 0) == shaped.id or shaped.id == 0) continue;
            if (codepointOf(current, shaped.id, with.nameOf(shaped.id)) != null) continue;
            var coming = false;
            for (missing.items) |other| {
                if (other < glyph_codepoints_rtl_mark and (with.tables.glyphIndex(other) catch 0) == shaped.id) coming = true;
            }
            if (coming) continue;
            const codepoint = with.nameOf(shaped.id).base() + @as(u21, shaped.id);
            if (std.mem.indexOfScalar(u21, missing.items, codepoint) == null) try missing.append(gpa, codepoint);
        }
    }

    /// The baked ligature at the start of `rest`, if any.
    pub fn ligature(self: *const Font, rest: []const u21) ?LigatureMatch {
        for (self.baked().ligatures) |entry| {
            if (entry.len <= rest.len and std.mem.eql(u21, entry.sequence[0..entry.len], rest[0..entry.len]))
                return .{ .consumed = entry.len, .codepoint = entry.result };
        }
        return null;
    }

    /// The `glyph_codepoints` characters of ligature glyphs not yet baked whose
    /// parts all are. Caller frees.
    pub fn missingLigatures(self: *const Font, gpa: std.mem.Allocator) ![]u21 {
        var missing: std.ArrayList(u21) = .empty;
        errdefer missing.deinit(gpa);
        if (self.source.len == 0) return missing.toOwnedSlice(gpa);
        const tables = try Tables.init(self.source);
        var raw: std.ArrayList(RawLigature) = .empty;
        defer raw.deinit(gpa);
        try readGsubLigatures(gpa, &tables, &raw);
        const glyphs = self.baked().glyphs;
        const indices = try gpa.alloc(u32, glyphs.len);
        defer gpa.free(indices);
        for (glyphs, indices) |baked_glyph, *index| index.* = tables.glyphIndex(baked_glyph.codepoint) catch 0;
        for (raw.items) |entry| {
            if (std.mem.indexOfScalar(u32, indices, entry.result) != null) continue;
            var whole = true;
            for (entry.glyphs[0..entry.len]) |part| {
                if (std.mem.indexOfScalar(u32, indices, part) == null) whole = false;
            }
            const codepoint = glyph_codepoints + @as(u21, entry.result);
            if (whole and std.mem.indexOfScalar(u21, missing.items, codepoint) == null) try missing.append(gpa, codepoint);
        }
        return missing.toOwnedSlice(gpa);
    }

    /// Offset of `mark` following `base`: stacked on `below` (placed at
    /// `below_at`) when the font stacks the two, else on the base. Null when
    /// the
    /// font does not place it. `component` is the ligature part the mark
    /// follows
    /// (see `componentOf`), 0 when unknown.
    pub fn markPlacement(self: *const Font, base: u21, component: u8, below: ?u21, below_at: [2]f32, mark: u21) ?[2]f32 {
        if (below) |under| if (self.markOffset(under, mark)) |offset| return .{ below_at[0] + offset[0], below_at[1] + offset[1] };
        if (self.baked().ligature_marks.get(ligatureMarkKey(base, mark, if (component == 255) 0 else component))) |offset| return offset;
        return self.markOffset(base, mark);
    }

    /// Pen and height shift, in ems, of a cursive glyph against the one drawn
    /// to
    /// its left; null when the two do not join.
    pub fn cursive(self: *const Font, left: u21, right: u21) ?[2]f32 {
        const current = self.baked();
        const on_left = current.cursive.get(left) orelse return null;
        const on_right = current.cursive.get(right) orelse return null;
        if (runsRightToLeft(left) or runsRightToLeft(right)) {
            const entry = on_left.entry orelse return null;
            const exit = on_right.exit orelse return null;
            return .{ entry[0] - exit[0] - current.glyph(left).advance, entry[1] - exit[1] };
        }
        const exit = on_left.exit orelse return null;
        const entry = on_right.entry orelse return null;
        return .{ exit[0] - entry[0] - current.glyph(left).advance, exit[1] - entry[1] };
    }

    /// Kerning adjustment, in ems.
    pub fn kern(self: *const Font, left: u21, right: u21) f32 {
        return self.baked().kern(left, right);
    }

    /// Width and height of `text` at `size` (pixels or world units per em).
    /// Newlines start a new line.
    pub fn measure(self: *const Font, text: []const u8, size: f32) [2]f32 {
        var width: f32 = 0;
        var line_width: f32 = 0;
        var lines: f32 = 1;
        var previous: ?u21 = null;
        var mark_below: ?u21 = null;
        var iterator = Utf8Iterator{ .bytes = text };
        while (iterator.next()) |codepoint| {
            if (codepoint == '\n') {
                width = @max(width, line_width);
                line_width = 0;
                lines += 1;
                previous = null;
                continue;
            }
            if (previous) |base| if (self.markPlacement(base, 0, mark_below, .{ 0, 0 }, codepoint) != null) {
                mark_below = codepoint;
                continue;
            };
            mark_below = null;
            if (previous) |left| line_width += self.kern(left, codepoint);
            line_width += self.glyph(codepoint).advance;
            previous = codepoint;
        }
        return .{ @max(width, line_width) * size, lines * self.line_height * size };
    }
};

/// Whether a character is of a right-to-left script or names a glyph of one.
fn runsRightToLeft(codepoint: u21) bool {
    return switch (codepoint) {
        0x590...0x8ff, 0xfb1d...0xfdff, 0xfe70...0xfeff, 0xd0000...0xdffff, 0x100000...0x10ffff => true,
        else => false,
    };
}

/// Lenient UTF-8 decoding: invalid bytes decode as U+FFFD.
pub const Utf8Iterator = struct {
    /// Must outlive the iterator.
    bytes: []const u8,
    index: usize = 0,

    /// Null at the end. A malformed sequence gives U+FFFD and advances one
    /// byte;
    /// a truncated one gives U+FFFD and ends.
    pub fn next(self: *Utf8Iterator) ?u21 {
        if (self.index >= self.bytes.len) return null;
        const first = self.bytes[self.index];
        const length = std.unicode.utf8ByteSequenceLength(first) catch {
            self.index += 1;
            return 0xfffd;
        };
        if (self.index + length > self.bytes.len) {
            self.index = self.bytes.len;
            return 0xfffd;
        }
        const codepoint = std.unicode.utf8Decode(self.bytes[self.index..][0..length]) catch {
            self.index += 1;
            return 0xfffd;
        };
        self.index += length;
        return codepoint;
    }
};

const Reader = struct {
    bytes: []const u8,

    fn slice(self: Reader, offset: usize, length: usize) ![]const u8 {
        if (offset > self.bytes.len or length > self.bytes.len - offset) return error.InvalidFont;
        return self.bytes[offset..][0..length];
    }

    fn u8At(self: Reader, offset: usize) !u8 {
        return (try self.slice(offset, 1))[0];
    }

    fn u16At(self: Reader, offset: usize) !u16 {
        return std.mem.readInt(u16, (try self.slice(offset, 2))[0..2], .big);
    }

    fn i16At(self: Reader, offset: usize) !i16 {
        return std.mem.readInt(i16, (try self.slice(offset, 2))[0..2], .big);
    }

    fn u32At(self: Reader, offset: usize) !u32 {
        return std.mem.readInt(u32, (try self.slice(offset, 4))[0..4], .big);
    }
};

const Tables = struct {
    reader: Reader,
    cmap: usize = 0,
    cmap_format: u16 = 0,
    glyf: usize = 0,
    loca: usize = 0,
    hmtx: usize = 0,
    /// Null when the font has no vertical metrics.
    vmtx: ?usize = null,
    vertical_metric_count: u16 = 0,
    kern: ?usize = null,
    gpos: ?usize = null,
    gsub: ?usize = null,
    gdef: ?usize = null,
    units_per_em: f32 = 1000,
    long_loca: bool = false,
    glyph_count: u32 = 0,
    metric_count: u32 = 0,
    ascent: f32 = 0,
    descent: f32 = 0,
    line_gap: f32 = 0,

    fn findTable(reader: Reader, tag: *const [4]u8) !?usize {
        const count = try reader.u16At(4);
        for (0..count) |index| {
            const record = 12 + index * 16;
            if (std.mem.eql(u8, try reader.slice(record, 4), tag)) return try reader.u32At(record + 8);
        }
        return null;
    }

    fn init(bytes: []const u8) !Tables {
        const reader = Reader{ .bytes = bytes };
        const version = try reader.u32At(0);
        if (version != 0x00010000 and version != 0x74727565) return error.UnsupportedFont; // TrueType outlines only
        var self = Tables{ .reader = reader };
        const head = (try findTable(reader, "head")) orelse return error.InvalidFont;
        const maxp = (try findTable(reader, "maxp")) orelse return error.InvalidFont;
        const hhea = (try findTable(reader, "hhea")) orelse return error.InvalidFont;
        self.hmtx = (try findTable(reader, "hmtx")) orelse return error.InvalidFont;
        self.glyf = (try findTable(reader, "glyf")) orelse return error.UnsupportedFont;
        self.loca = (try findTable(reader, "loca")) orelse return error.InvalidFont;
        self.kern = try findTable(reader, "kern");
        if (try findTable(reader, "vhea")) |vhea| {
            if (try findTable(reader, "vmtx")) |vmtx| {
                self.vertical_metric_count = try reader.u16At(vhea + 34);
                if (self.vertical_metric_count != 0) self.vmtx = vmtx;
            }
        }
        self.gpos = try findTable(reader, "GPOS");
        self.gsub = try findTable(reader, "GSUB");
        self.gdef = try findTable(reader, "GDEF");
        self.units_per_em = @floatFromInt(try reader.u16At(head + 18));
        if (self.units_per_em == 0) return error.InvalidFont;
        self.long_loca = (try reader.i16At(head + 50)) != 0;
        self.glyph_count = try reader.u16At(maxp + 4);
        self.ascent = @floatFromInt(try reader.i16At(hhea + 4));
        self.descent = @floatFromInt(try reader.i16At(hhea + 6));
        self.line_gap = @floatFromInt(try reader.i16At(hhea + 8));
        self.metric_count = try reader.u16At(hhea + 34);
        if (self.metric_count == 0) return error.InvalidFont;

        const cmap = (try findTable(reader, "cmap")) orelse return error.InvalidFont;
        const subtables = try reader.u16At(cmap + 2);
        var best_score: u32 = 0;
        for (0..subtables) |index| {
            const record = cmap + 4 + index * 8;
            const platform = try reader.u16At(record);
            const encoding = try reader.u16At(record + 2);
            const offset = cmap + try reader.u32At(record + 4);
            const format = try reader.u16At(offset);
            const unicode = platform == 0 or (platform == 3 and (encoding == 1 or encoding == 10));
            if (!unicode) continue;
            const score: u32 = if (format == 12) 2 else if (format == 4) 1 else 0;
            if (score > best_score) {
                best_score = score;
                self.cmap = offset;
                self.cmap_format = format;
            }
        }
        if (best_score == 0) return error.UnsupportedFont;
        return self;
    }

    fn glyphIndex(self: *const Tables, codepoint: u21) !u32 {
        if (codepoint >= glyph_codepoints_rtl) return codepoint - glyph_codepoints_rtl;
        if (codepoint >= glyph_codepoints_rtl_mark and codepoint < glyph_codepoints_rtl_mark + 0x10000) return codepoint - glyph_codepoints_rtl_mark;
        if (codepoint >= glyph_codepoints) return codepoint - glyph_codepoints;
        const reader = self.reader;
        const table = self.cmap;
        if (self.cmap_format == 12) {
            const groups = try reader.u32At(table + 12);
            var low: usize = 0;
            var high: usize = groups;
            while (low < high) {
                const mid = (low + high) / 2;
                const group = table + 16 + mid * 12;
                const start = try reader.u32At(group);
                const end = try reader.u32At(group + 4);
                if (codepoint < start) {
                    high = mid;
                } else if (codepoint > end) {
                    low = mid + 1;
                } else return (try reader.u32At(group + 8)) + (codepoint - start);
            }
            return 0;
        }
        if (codepoint > 0xffff) return 0;
        const code: u32 = codepoint;
        const segments = (try reader.u16At(table + 6)) / 2;
        const end_codes = table + 14;
        const start_codes = end_codes + segments * 2 + 2;
        const deltas = start_codes + segments * 2;
        const range_offsets = deltas + segments * 2;
        for (0..segments) |segment| {
            if (code > try reader.u16At(end_codes + segment * 2)) continue;
            const start = try reader.u16At(start_codes + segment * 2);
            if (code < start) return 0;
            const delta = try reader.u16At(deltas + segment * 2);
            const range_offset = try reader.u16At(range_offsets + segment * 2);
            if (range_offset == 0) return (code + delta) & 0xffff;
            const address = range_offsets + segment * 2 + range_offset + (code - start) * 2;
            const value = try reader.u16At(address);
            return if (value == 0) 0 else (@as(u32, value) + delta) & 0xffff;
        }
        return 0;
    }

    /// Vertical advance in font units; 0 when the font has no vertical metrics.
    fn advanceDown(self: *const Tables, glyph_index: u32) !f32 {
        const vmtx = self.vmtx orelse return 0;
        const index: usize = @min(glyph_index, self.vertical_metric_count - 1);
        return @floatFromInt(try self.reader.u16At(vmtx + index * 4));
    }

    fn advance(self: *const Tables, glyph_index: u32) !f32 {
        const index = @min(glyph_index, self.metric_count - 1);
        return @floatFromInt(try self.reader.u16At(self.hmtx + index * 4));
    }

    /// Offset of a glyph inside `glyf`, or null for blank glyphs.
    fn glyphData(self: *const Tables, glyph_index: u32) !?usize {
        if (glyph_index >= self.glyph_count) return null;
        const reader = self.reader;
        const start: usize, const end: usize = if (self.long_loca) .{
            try reader.u32At(self.loca + glyph_index * 4),
            try reader.u32At(self.loca + glyph_index * 4 + 4),
        } else .{
            @as(usize, try reader.u16At(self.loca + glyph_index * 2)) * 2,
            @as(usize, try reader.u16At(self.loca + glyph_index * 2 + 2)) * 2,
        };
        if (end <= start) return null;
        return self.glyf + start;
    }
};

const Segment = struct { a: [2]f32, b: [2]f32 };

/// 2x2 linear transform plus translation, for composite components.
const Affine = struct {
    m: [4]f32 = .{ 1, 0, 0, 1 },
    t: [2]f32 = .{ 0, 0 },

    fn apply(self: Affine, p: [2]f32) [2]f32 {
        return .{
            self.m[0] * p[0] + self.m[2] * p[1] + self.t[0],
            self.m[1] * p[0] + self.m[3] * p[1] + self.t[1],
        };
    }

    fn concat(outer: Affine, inner: Affine) Affine {
        return .{
            .m = .{
                outer.m[0] * inner.m[0] + outer.m[2] * inner.m[1],
                outer.m[1] * inner.m[0] + outer.m[3] * inner.m[1],
                outer.m[0] * inner.m[2] + outer.m[2] * inner.m[3],
                outer.m[1] * inner.m[2] + outer.m[3] * inner.m[3],
            },
            .t = outer.apply(inner.t),
        };
    }
};

const quad_subdivisions = 5;

fn appendQuad(gpa: std.mem.Allocator, segments: *std.ArrayList(Segment), a: [2]f32, control: [2]f32, b: [2]f32) !void {
    var previous = a;
    for (1..quad_subdivisions + 1) |step| {
        const t = @as(f32, @floatFromInt(step)) / quad_subdivisions;
        const u = 1 - t;
        const point = [2]f32{
            u * u * a[0] + 2 * u * t * control[0] + t * t * b[0],
            u * u * a[1] + 2 * u * t * control[1] + t * t * b[1],
        };
        try segments.append(gpa, .{ .a = previous, .b = point });
        previous = point;
    }
}

/// Appends a glyph's outline, in font units, as line segments.
fn appendOutline(
    gpa: std.mem.Allocator,
    tables: *const Tables,
    glyph_index: u32,
    transform: Affine,
    segments: *std.ArrayList(Segment),
    depth: u32,
) !void {
    if (depth > 8) return error.InvalidFont;
    const data = (try tables.glyphData(glyph_index)) orelse return;
    const reader = tables.reader;
    const contour_count = try reader.i16At(data);

    if (contour_count < 0) {
        var cursor = data + 10;
        while (true) {
            const flags = try reader.u16At(cursor);
            const component = try reader.u16At(cursor + 2);
            cursor += 4;
            var local = Affine{};
            if (flags & 0x1 != 0) {
                if (flags & 0x2 != 0) local.t = .{ @floatFromInt(try reader.i16At(cursor)), @floatFromInt(try reader.i16At(cursor + 2)) };
                cursor += 4;
            } else {
                if (flags & 0x2 != 0) {
                    local.t = .{
                        @floatFromInt(@as(i8, @bitCast(try reader.u8At(cursor)))),
                        @floatFromInt(@as(i8, @bitCast(try reader.u8At(cursor + 1)))),
                    };
                }
                cursor += 2;
            }
            const f2dot14 = struct {
                fn read(r: Reader, offset: usize) !f32 {
                    return @as(f32, @floatFromInt(try r.i16At(offset))) / 16384.0;
                }
            }.read;
            if (flags & 0x8 != 0) {
                const s = try f2dot14(reader, cursor);
                local.m = .{ s, 0, 0, s };
                cursor += 2;
            } else if (flags & 0x40 != 0) {
                local.m = .{ try f2dot14(reader, cursor), 0, 0, try f2dot14(reader, cursor + 2) };
                cursor += 4;
            } else if (flags & 0x80 != 0) {
                local.m = .{
                    try f2dot14(reader, cursor),
                    try f2dot14(reader, cursor + 2),
                    try f2dot14(reader, cursor + 4),
                    try f2dot14(reader, cursor + 6),
                };
                cursor += 8;
            }
            try appendOutline(gpa, tables, component, transform.concat(local), segments, depth + 1);
            if (flags & 0x20 == 0) break;
        }
        return;
    }

    const contours: usize = @intCast(contour_count);
    if (contours == 0) return;
    const end_points = data + 10;
    const point_count = @as(usize, try reader.u16At(end_points + (contours - 1) * 2)) + 1;
    const instruction_length = try reader.u16At(end_points + contours * 2);
    var cursor = end_points + contours * 2 + 2 + instruction_length;

    const flags = try gpa.alloc(u8, point_count);
    defer gpa.free(flags);
    const points = try gpa.alloc([2]f32, point_count);
    defer gpa.free(points);
    var index: usize = 0;
    while (index < point_count) {
        const flag = try reader.u8At(cursor);
        cursor += 1;
        var repeat: usize = 1;
        if (flag & 0x8 != 0) {
            repeat += try reader.u8At(cursor);
            cursor += 1;
        }
        if (index + repeat > point_count) return error.InvalidFont;
        @memset(flags[index..][0..repeat], flag);
        index += repeat;
    }
    inline for (.{ 0, 1 }) |axis| {
        const short_bit: u8 = if (axis == 0) 0x2 else 0x4;
        const same_bit: u8 = if (axis == 0) 0x10 else 0x20;
        var value: i32 = 0;
        for (flags, points) |flag, *point| {
            if (flag & short_bit != 0) {
                const delta: i32 = try reader.u8At(cursor);
                cursor += 1;
                value += if (flag & same_bit != 0) delta else -delta;
            } else if (flag & same_bit == 0) {
                value += try reader.i16At(cursor);
                cursor += 2;
            }
            point[axis] = @floatFromInt(value);
        }
    }
    for (points) |*point| point.* = transform.apply(point.*);

    var first: usize = 0;
    for (0..contours) |contour| {
        const last: usize = try reader.u16At(end_points + contour * 2);
        if (last >= point_count or last < first) return error.InvalidFont;
        const count = last - first + 1;
        defer first = last + 1;
        if (count < 2) continue;
        const contour_points = points[first..][0..count];
        const contour_flags = flags[first..][0..count];

        var start_index: usize = 0;
        while (start_index < count and contour_flags[start_index] & 1 == 0) start_index += 1;
        var start: [2]f32 = undefined;
        if (start_index == count) {
            start_index = 0;
            start = midpoint(contour_points[count - 1], contour_points[0]);
        } else {
            start = contour_points[start_index];
        }
        const all_off = start_index == 0 and contour_flags[0] & 1 == 0;

        var pen = start;
        var control: ?[2]f32 = null;
        for (1..count + 1) |step| {
            const point_index = (start_index + (if (all_off) step - 1 else step)) % count;
            const closing = !all_off and step == count;
            const point = if (closing) start else contour_points[point_index];
            const on_curve = closing or contour_flags[point_index] & 1 != 0;
            if (on_curve) {
                if (control) |c| {
                    try appendQuad(gpa, segments, pen, c, point);
                } else {
                    try segments.append(gpa, .{ .a = pen, .b = point });
                }
                pen = point;
                control = null;
            } else {
                if (control) |c| {
                    const implied = midpoint(c, point);
                    try appendQuad(gpa, segments, pen, c, implied);
                    pen = implied;
                }
                control = point;
            }
        }
        if (control) |c| try appendQuad(gpa, segments, pen, c, start);
    }
}

fn midpoint(a: [2]f32, b: [2]f32) [2]f32 {
    return .{ (a[0] + b[0]) * 0.5, (a[1] + b[1]) * 0.5 };
}

/// A segment's channel mask and whether it starts or ends at a corner.
const EdgeInfo = struct {
    channels: u8 = 7,
    corner_at_start: bool = false,
    corner_at_end: bool = false,
};

fn samePoint(a: [2]f32, b: [2]f32) bool {
    return @abs(a[0] - b[0]) < 1e-3 and @abs(a[1] - b[1]) < 1e-3;
}

/// Colors a glyph's outline segments for a multi-channel distance field
/// (Chlumsky, "Shape Decomposition for Multi-channel Distance Fields"). A
/// contour without corners stays in all three channels.
fn colorEdges(outline: []const Segment, info: []EdgeInfo) void {
    const pairs = [3]u8{ 0b101, 0b011, 0b110 };
    var start: usize = 0;
    while (start < outline.len) {
        var end = start + 1;
        while (end < outline.len and samePoint(outline[end].a, outline[end - 1].b)) end += 1;
        const count = end - start;
        var corners: usize = 0;
        var first_corner: usize = 0;
        for (0..count) |index| {
            const here = outline[start + index];
            const before = outline[start + (index + count - 1) % count];
            const d1 = [2]f32{ before.b[0] - before.a[0], before.b[1] - before.a[1] };
            const d2 = [2]f32{ here.b[0] - here.a[0], here.b[1] - here.a[1] };
            const l1 = @sqrt(d1[0] * d1[0] + d1[1] * d1[1]);
            const l2 = @sqrt(d2[0] * d2[0] + d2[1] * d2[1]);
            const corner = l1 > 1e-6 and l2 > 1e-6 and (d1[0] * d2[0] + d1[1] * d2[1]) / (l1 * l2) < 0.7;
            info[start + index] = .{ .corner_at_start = corner };
            if (corner) {
                if (corners == 0) first_corner = index;
                corners += 1;
            }
        }
        for (0..count) |index| info[start + index].corner_at_end = info[start + (index + 1) % count].corner_at_start;
        if (corners == 1) {
            for (0..count) |step| {
                const index = (first_corner + step) % count;
                info[start + index].channels = if (step * 3 < count) pairs[0] else if (step * 3 < count * 2) 7 else pairs[1];
            }
        } else if (corners >= 2) {
            var stretch: usize = 0;
            var color: usize = 0;
            for (0..count) |step| {
                const index = (first_corner + step) % count;
                if (step != 0 and info[start + index].corner_at_start) {
                    stretch += 1;
                    color = (color + 1) % 3;
                    if (stretch == corners - 1 and color == 0) color = if (corners % 3 == 1) 1 else 2;
                }
                info[start + index].channels = pairs[color];
            }
        }
        start = end;
    }
}

fn distanceSquared(p: [2]f32, segment: Segment) f32 {
    const ab = [2]f32{ segment.b[0] - segment.a[0], segment.b[1] - segment.a[1] };
    const ap = [2]f32{ p[0] - segment.a[0], p[1] - segment.a[1] };
    const length_squared = ab[0] * ab[0] + ab[1] * ab[1];
    const t = if (length_squared > 0) std.math.clamp((ap[0] * ab[0] + ap[1] * ab[1]) / length_squared, 0, 1) else 0;
    const dx = ap[0] - ab[0] * t;
    const dy = ap[1] - ab[1] * t;
    return dx * dx + dy * dy;
}

/// Positive inside (non-zero winding), negative outside.
fn signedDistance(p: [2]f32, segments: []const Segment) f32 {
    var best = std.math.inf(f32);
    var winding: i32 = 0;
    for (segments) |segment| {
        best = @min(best, distanceSquared(p, segment));
        const a = segment.a;
        const b = segment.b;
        if ((a[1] <= p[1]) != (b[1] <= p[1])) {
            const x = a[0] + (p[1] - a[1]) / (b[1] - a[1]) * (b[0] - a[0]);
            if (x > p[0]) winding += if (b[1] > a[1]) 1 else -1;
        }
    }
    const distance = @sqrt(best);
    return if (winding != 0) distance else -distance;
}

/// Where the outline crosses a pixel row, and its winding direction there.
const Crossing = struct { x: f32, direction: i32 };

const Cell = struct {
    glyph: usize,
    segment_start: usize,
    segment_count: usize,
    /// Outline bounds in atlas pixels relative to the pen origin, y up.
    min: [2]f32,
    width: u32,
    height: u32,
    x: u32 = 0,
    y: u32 = 0,
};

var next_font_id: std.atomic.Value(u64) = .init(1);

/// Parses a TrueType font and bakes an SDF atlas for `ranges`. `bytes` is
/// copied. Free the result with `Font.deinit`. `error.UnsupportedFont` for
/// CFF outlines, `error.InvalidFont` for damaged files.
pub fn load(gpa: std.mem.Allocator, bytes: []const u8, ranges: []const Range) !Font {
    const tables = try Tables.init(bytes);
    const first = try gpa.create(Baked);
    errdefer gpa.destroy(first);
    first.* = try bake(gpa, &tables, ranges, null);
    errdefer first.deinit(gpa);
    return .{
        .gpa = gpa,
        .ascent = tables.ascent / tables.units_per_em,
        .descent = -tables.descent / tables.units_per_em,
        .line_height = (tables.ascent - tables.descent + tables.line_gap) / tables.units_per_em,
        .current = .init(first),
        .source = try gpa.dupe(u8, bytes),
        .id = next_font_id.fetchAdd(1, .monotonic),
    };
}

/// Bakes the glyphs of `ranges`. `previous` must be a bake of the leading
/// ranges; its glyphs keep their place in the atlas.
fn bake(gpa: std.mem.Allocator, tables: *const Tables, ranges: []const Range, previous: ?*const Baked) !Baked {
    const scale = atlas_em / tables.units_per_em;
    const padding: u32 = @intFromFloat(@ceil(sdf_spread));

    var glyphs: std.ArrayList(Glyph) = .empty;
    errdefer glyphs.deinit(gpa);
    var glyph_indices: std.ArrayList(u32) = .empty;
    defer glyph_indices.deinit(gpa);
    var segments: std.ArrayList(Segment) = .empty;
    defer segments.deinit(gpa);
    var cells: std.ArrayList(Cell) = .empty;
    defer cells.deinit(gpa);

    var first_new: usize = 0;
    if (previous) |old| {
        try glyphs.appendSlice(gpa, old.glyphs);
        for (old.glyphs) |glyph| try glyph_indices.append(gpa, try tables.glyphIndex(glyph.codepoint));
        first_new = old.ranges.len;
    }
    for (ranges[first_new..]) |range| {
        var codepoint = range[0];
        while (codepoint <= range[1]) : (codepoint += 1) {
            if (previous) |old| if (old.find(codepoint) != null) continue;
            const glyph_index = try tables.glyphIndex(codepoint);
            if (glyph_index == 0 and codepoint != ' ') continue;
            const segment_start = segments.items.len;
            try appendOutline(gpa, tables, glyph_index, .{}, &segments, 0);
            const outline = segments.items[segment_start..];
            try glyphs.append(gpa, .{ .codepoint = codepoint, .id = @intCast(glyph_index), .advance = (try tables.advance(glyph_index)) / tables.units_per_em, .advance_down = (try tables.advanceDown(glyph_index)) / tables.units_per_em });
            try glyph_indices.append(gpa, glyph_index);
            if (outline.len == 0) continue;
            var minimum: [2]f32 = @splat(std.math.inf(f32));
            var maximum: [2]f32 = @splat(-std.math.inf(f32));
            for (outline) |*segment| {
                inline for (.{ &segment.a, &segment.b }) |point| {
                    point.* = .{ point[0] * scale, point[1] * scale };
                    inline for (0..2) |axis| {
                        minimum[axis] = @min(minimum[axis], point[axis]);
                        maximum[axis] = @max(maximum[axis], point[axis]);
                    }
                }
            }
            minimum = .{ @floor(minimum[0]), @floor(minimum[1]) };
            try cells.append(gpa, .{
                .glyph = glyphs.items.len - 1,
                .segment_start = segment_start,
                .segment_count = outline.len,
                .min = minimum,
                .width = @as(u32, @intFromFloat(@ceil(maximum[0] - minimum[0]))) + padding * 2,
                .height = @as(u32, @intFromFloat(@ceil(maximum[1] - minimum[1]))) + padding * 2,
            });
        }
    }
    if (glyphs.items.len == 0) return error.EmptyFont;

    const atlas_width: u32 = 1024;
    var pen_x: u32 = if (previous) |old| old.pen[0] else 1;
    var pen_y: u32 = if (previous) |old| old.pen[1] else 1;
    var shelf_height: u32 = if (previous) |old| old.shelf_height else 0;
    for (cells.items) |*cell| {
        if (cell.width + 2 > atlas_width) return error.GlyphTooLarge;
        if (pen_x + cell.width + 1 > atlas_width) {
            pen_x = 1;
            pen_y += shelf_height + 1;
            shelf_height = 0;
        }
        cell.x = pen_x;
        cell.y = pen_y;
        pen_x += cell.width + 1;
        shelf_height = @max(shelf_height, cell.height);
    }
    const atlas_height = std.math.ceilPowerOfTwoAssert(u32, @max(pen_y + shelf_height + 1, 4));
    const atlas = try gpa.alloc(u8, @as(usize, atlas_width) * atlas_height);
    errdefer gpa.free(atlas);
    @memset(atlas, 0);
    const msdf = try gpa.alloc(u8, atlas.len * 3);
    errdefer gpa.free(msdf);
    @memset(msdf, 0);
    if (previous) |old| {
        @memcpy(atlas[0..old.atlas.len], old.atlas);
        @memcpy(msdf[0..old.msdf.len], old.msdf);
        if (old.atlas_height != atlas_height) {
            const shrink = @as(f32, @floatFromInt(old.atlas_height)) / @as(f32, @floatFromInt(atlas_height));
            for (glyphs.items[0..old.glyphs.len]) |*glyph| {
                glyph.uv[1] *= shrink;
                glyph.uv[3] *= shrink;
            }
        }
    }

    var near: std.ArrayList(u32) = .empty;
    defer near.deinit(gpa);
    var crossings: std.ArrayList(Crossing) = .empty;
    var edges: std.ArrayList(EdgeInfo) = .empty;
    defer edges.deinit(gpa);
    defer crossings.deinit(gpa);
    for (cells.items) |cell| {
        const outline = segments.items[cell.segment_start..][0..cell.segment_count];
        try near.ensureTotalCapacity(gpa, outline.len);
        try crossings.ensureTotalCapacity(gpa, outline.len);
        try edges.resize(gpa, outline.len);
        colorEdges(outline, edges.items);
        var inside_left: f32 = 1;
        {
            var longest: f32 = 0;
            for (outline) |segment| {
                const dx = segment.b[0] - segment.a[0];
                const dy = segment.b[1] - segment.a[1];
                const length = @sqrt(dx * dx + dy * dy);
                if (length <= longest) continue;
                longest = length;
                const probe = [2]f32{ (segment.a[0] + segment.b[0]) * 0.5 - dy / length * 0.05, (segment.a[1] + segment.b[1]) * 0.5 + dx / length * 0.05 };
                inside_left = if (signedDistance(probe, outline) > 0) 1 else -1;
            }
        }
        for (0..cell.height) |row| {
            const y = cell.min[1] + @as(f32, @floatFromInt(cell.height - 1 - row)) - @as(f32, @floatFromInt(padding)) + 0.5;
            near.clearRetainingCapacity();
            crossings.clearRetainingCapacity();
            for (outline, 0..) |segment, index| {
                const low = @min(segment.a[1], segment.b[1]);
                const high = @max(segment.a[1], segment.b[1]);
                if (y < low - sdf_spread or y > high + sdf_spread) continue;
                near.appendAssumeCapacity(@intCast(index));
                const a = segment.a;
                const b = segment.b;
                if ((a[1] <= y) != (b[1] <= y)) crossings.appendAssumeCapacity(.{
                    .x = a[0] + (y - a[1]) / (b[1] - a[1]) * (b[0] - a[0]),
                    .direction = if (b[1] > a[1]) 1 else -1,
                });
            }
            for (0..cell.width) |column| {
                const x = cell.min[0] + @as(f32, @floatFromInt(column)) - @as(f32, @floatFromInt(padding)) + 0.5;
                var best: f32 = sdf_spread * sdf_spread;
                for (near.items) |index| {
                    const segment = outline[index];
                    if (x < @min(segment.a[0], segment.b[0]) - sdf_spread or x > @max(segment.a[0], segment.b[0]) + sdf_spread) continue;
                    best = @min(best, distanceSquared(.{ x, y }, segment));
                }
                var winding: i32 = 0;
                for (crossings.items) |crossing| {
                    if (crossing.x > x) winding += crossing.direction;
                }
                const distance = if (winding != 0) @sqrt(best) else -@sqrt(best);
                const value = std.math.clamp(0.5 + distance / (2 * sdf_spread), 0, 1);
                atlas[(cell.y + row) * atlas_width + cell.x + column] = @intFromFloat(@round(value * 255));
                var channel_value: [3]f32 = .{ value, value, value };
                if (@abs(value - 0.5) < 0.45) {
                    var nearest: [3]f32 = @splat(std.math.inf(f32));
                    var across: [3]f32 = @splat(0);
                    var signed: [3]f32 = @splat(0);
                    for (near.items) |index| {
                        const segment = outline[index];
                        if (x < @min(segment.a[0], segment.b[0]) - sdf_spread or x > @max(segment.a[0], segment.b[0]) + sdf_spread) continue;
                        const ab = [2]f32{ segment.b[0] - segment.a[0], segment.b[1] - segment.a[1] };
                        const length = @sqrt(ab[0] * ab[0] + ab[1] * ab[1]);
                        if (length < 1e-6) continue;
                        const ap = [2]f32{ x - segment.a[0], y - segment.a[1] };
                        const t = (ap[0] * ab[0] + ap[1] * ab[1]) / (length * length);
                        const clamped = std.math.clamp(t, 0, 1);
                        const dx = ap[0] - ab[0] * clamped;
                        const dy = ap[1] - ab[1] * clamped;
                        const true_distance = @sqrt(dx * dx + dy * dy);
                        const perpendicular = (ab[0] * ap[1] - ab[1] * ap[0]) / length;
                        const edge = edges.items[index];
                        const beyond = (t < 0 and edge.corner_at_start) or (t > 1 and edge.corner_at_end);
                        const side_distance = if (beyond) perpendicular else if (perpendicular < 0) -true_distance else true_distance;
                        const squareness = @abs(perpendicular) / @max(true_distance, 1e-6);
                        inline for (0..3) |channel| {
                            if (edge.channels & (1 << channel) != 0) {
                                if (true_distance < nearest[channel] - 1e-4 or (true_distance < nearest[channel] + 1e-4 and squareness > across[channel])) {
                                    nearest[channel] = true_distance;
                                    across[channel] = squareness;
                                    signed[channel] = side_distance * inside_left;
                                }
                            }
                        }
                    }
                    inline for (0..3) |channel| {
                        if (nearest[channel] < sdf_spread) channel_value[channel] = std.math.clamp(0.5 + signed[channel] / (2 * sdf_spread), 0, 1);
                    }
                    const median = @max(@min(channel_value[0], channel_value[1]), @min(@max(channel_value[0], channel_value[1]), channel_value[2]));
                    if ((median > 0.5) != (value > 0.5) or @abs(median - value) > 0.2) channel_value = .{ value, value, value };
                }
                const texel = ((cell.y + row) * atlas_width + cell.x + column) * 3;
                inline for (0..3) |channel| msdf[texel + channel] = @intFromFloat(@round(channel_value[channel] * 255));
            }
        }
        const glyph = &glyphs.items[cell.glyph];
        const pad: f32 = @floatFromInt(padding);
        const width: f32 = @floatFromInt(cell.width);
        const height: f32 = @floatFromInt(cell.height);
        glyph.plane = .{
            (cell.min[0] - pad) / atlas_em,
            (cell.min[1] - pad) / atlas_em,
            (cell.min[0] - pad + width) / atlas_em,
            (cell.min[1] - pad + height) / atlas_em,
        };
        glyph.uv = .{
            @as(f32, @floatFromInt(cell.x)) / atlas_width,
            @as(f32, @floatFromInt(cell.y)) / @as(f32, @floatFromInt(atlas_height)),
            (@as(f32, @floatFromInt(cell.x)) + width) / atlas_width,
            (@as(f32, @floatFromInt(cell.y)) + height) / @as(f32, @floatFromInt(atlas_height)),
        };
    }

    var baked = Baked{
        .glyphs = undefined,
        .atlas_width = atlas_width,
        .atlas_height = atlas_height,
        .atlas = atlas,
        .msdf = msdf,
        .pen = .{ pen_x, pen_y },
        .shelf_height = shelf_height,
        .ranges = &.{},
    };
    errdefer baked.kerning.deinit(gpa);
    if (!try loadGposKerning(gpa, tables, glyphs.items, glyph_indices.items, &baked.kerning))
        try loadKerning(gpa, tables, glyphs.items, glyph_indices.items, &baked.kerning);
    errdefer baked.marks.deinit(gpa);
    try loadGposMarks(gpa, tables, glyphs.items, glyph_indices.items, &baked.marks, "mark", 4);
    try loadGposMarks(gpa, tables, glyphs.items, glyph_indices.items, &baked.marks, "mkmk", 6);
    try loadGposMarks(gpa, tables, glyphs.items, glyph_indices.items, &baked.marks, "abvm", 4);
    try loadGposMarks(gpa, tables, glyphs.items, glyph_indices.items, &baked.marks, "blwm", 4);
    try loadGposMarks(gpa, tables, glyphs.items, glyph_indices.items, &baked.marks, "abvm", 6);
    try loadGposMarks(gpa, tables, glyphs.items, glyph_indices.items, &baked.marks, "blwm", 6);
    errdefer baked.ligature_marks.deinit(gpa);
    try loadGposMarks(gpa, tables, glyphs.items, glyph_indices.items, &baked.ligature_marks, "mark", 5);
    errdefer baked.cursive.deinit(gpa);
    try loadGposCursive(gpa, tables, glyphs.items, glyph_indices.items, &baked.cursive);
    baked.ligatures = try bakedLigatures(gpa, tables, glyphs.items, glyph_indices.items);
    errdefer gpa.free(baked.ligatures);
    baked.ranges = try gpa.dupe(Range, ranges);
    errdefer gpa.free(baked.ranges);
    baked.glyphs = try glyphs.toOwnedSlice(gpa);
    std.mem.sort(Glyph, baked.glyphs, {}, struct {
        fn lessThan(_: void, a: Glyph, b: Glyph) bool {
            return a.codepoint < b.codepoint;
        }
    }.lessThan);
    return baked;
}

pub const Ligature = struct {
    /// The first `len` entries are the characters; `result` is the character
    /// the
    /// ligature glyph is baked under.
    sequence: [4]u21 = .{ 0, 0, 0, 0 },
    len: u8 = 0,
    result: u21 = 0,
};

/// Base of the private range naming glyphs with no character of their own:
/// this plus the glyph index.
pub const glyph_codepoints: u21 = 0xf0000;
/// Base of the range of characters that add spacing instead of drawing a
/// glyph. The upper half runs right to left.
pub const spacing_codepoints: u21 = 0xc0000;
const spacing_steps_per_em = 2048;

fn spacingName(ems: f32, rtl: bool) u21 {
    const steps: i32 = @intFromFloat(std.math.clamp(@round(ems * spacing_steps_per_em), -16383, 16383));
    return spacing_codepoints + @as(u21, if (rtl) 0x8000 else 0) + @as(u21, @intCast(steps + 0x4000));
}

/// What a spacing character adds to the pen, in ems; null for any other
/// character.
pub fn spacingOf(codepoint: u21) ?f32 {
    if (codepoint < spacing_codepoints or codepoint >= spacing_codepoints + 0x10000) return null;
    const steps: i32 = @as(i32, @intCast((codepoint - spacing_codepoints) & 0x7fff)) - 0x4000;
    return @as(f32, @floatFromInt(steps)) / spacing_steps_per_em;
}

/// `glyph_codepoints` for right-to-left scripts.
pub const glyph_codepoints_rtl: u21 = 0x100000;
/// `glyph_codepoints` for marks of right-to-left scripts.
pub const glyph_codepoints_rtl_mark: u21 = 0xd0000;

pub const LigatureMatch = struct { consumed: usize, codepoint: u21 };

const RawLigature = struct { glyphs: [4]u16, len: u8, result: u16 };

/// Reads GSUB ligature lookups of the `liga` and `rlig` features, up to four
/// glyphs each.
fn readGsubLigatures(gpa: std.mem.Allocator, tables: *const Tables, out: *std.ArrayList(RawLigature)) !void {
    const gsub = tables.gsub orelse return;
    const reader = tables.reader;
    const feature_list = gsub + (reader.u16At(gsub + 6) catch return);
    const lookup_list = gsub + (reader.u16At(gsub + 8) catch return);
    const lookup_count = reader.u16At(lookup_list) catch return;
    const feature_count = reader.u16At(feature_list) catch return;
    const seen = try gpa.alloc(bool, lookup_count);
    defer gpa.free(seen);
    @memset(seen, false);
    for (0..feature_count) |feature_index| {
        const record = feature_list + 2 + feature_index * 6;
        const tag = reader.slice(record, 4) catch return;
        if (!std.mem.eql(u8, tag, "liga") and !std.mem.eql(u8, tag, "rlig")) continue;
        const feature = feature_list + (reader.u16At(record + 4) catch return);
        const index_count = reader.u16At(feature + 2) catch return;
        for (0..index_count) |slot| {
            const lookup_index = reader.u16At(feature + 4 + slot * 2) catch return;
            if (lookup_index >= lookup_count or seen[lookup_index]) continue;
            seen[lookup_index] = true;
            const lookup = lookup_list + (reader.u16At(lookup_list + 2 + @as(usize, lookup_index) * 2) catch return);
            const lookup_type = reader.u16At(lookup) catch return;
            const subtable_count = reader.u16At(lookup + 4) catch return;
            for (0..subtable_count) |subtable_index| {
                var subtable = lookup + (reader.u16At(lookup + 6 + subtable_index * 2) catch return);
                var kind = lookup_type;
                if (kind == 7) {
                    kind = reader.u16At(subtable + 2) catch return;
                    subtable += reader.u32At(subtable + 4) catch return;
                }
                if (kind != 4) continue;
                ligatureSubtable(gpa, reader, subtable, out) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => {},
                };
            }
        }
    }
}

/// Reads one GSUB ligature substitution subtable.
fn ligatureSubtable(gpa: std.mem.Allocator, reader: Reader, subtable: usize, out: *std.ArrayList(RawLigature)) !void {
    if (try reader.u16At(subtable) != 1) return;
    const coverage = subtable + try reader.u16At(subtable + 2);
    const set_count = try reader.u16At(subtable + 4);
    const coverage_format = try reader.u16At(coverage);
    for (0..set_count) |set_index| {
        const first: u16 = blk: {
            if (coverage_format == 1) {
                if (set_index >= try reader.u16At(coverage + 2)) return;
                break :blk try reader.u16At(coverage + 4 + set_index * 2);
            }
            const range_count = try reader.u16At(coverage + 2);
            for (0..range_count) |range| {
                const entry = coverage + 4 + range * 6;
                const start = try reader.u16At(entry);
                const end = try reader.u16At(entry + 2);
                const start_index = try reader.u16At(entry + 4);
                if (set_index >= start_index and set_index - start_index <= end - start) break :blk start + @as(u16, @intCast(set_index - start_index));
            }
            return;
        };
        const set = subtable + try reader.u16At(subtable + 6 + set_index * 2);
        const ligature_count = try reader.u16At(set);
        for (0..ligature_count) |ligature_index| {
            const ligature = set + try reader.u16At(set + 2 + ligature_index * 2);
            const count = try reader.u16At(ligature + 2);
            if (count < 2 or count > 4) continue;
            var raw = RawLigature{ .glyphs = .{ first, 0, 0, 0 }, .len = @intCast(count), .result = try reader.u16At(ligature) };
            for (1..count) |component| raw.glyphs[component] = try reader.u16At(ligature + 4 + (component - 1) * 2);
            try out.append(gpa, raw);
        }
    }
}

/// Reads GPOS pair adjustments (formats 1 and 2, also through extension
/// lookups) of the `kern` features. Returns whether the font had any.
fn loadGposKerning(
    gpa: std.mem.Allocator,
    tables: *const Tables,
    glyphs: []const Glyph,
    glyph_indices: []const u32,
    kerning: *std.AutoHashMapUnmanaged(u64, f32),
) !bool {
    const gpos = tables.gpos orelse return false;
    const reader = tables.reader;
    const feature_list = gpos + (reader.u16At(gpos + 6) catch return false);
    const lookup_list = gpos + (reader.u16At(gpos + 8) catch return false);
    const lookup_count = reader.u16At(lookup_list) catch return false;
    var found = false;
    const feature_count = reader.u16At(feature_list) catch return false;
    const seen = try gpa.alloc(bool, lookup_count);
    defer gpa.free(seen);
    @memset(seen, false);
    for (0..feature_count) |feature_index| {
        const record = feature_list + 2 + feature_index * 6;
        if (!std.mem.eql(u8, reader.slice(record, 4) catch return found, "kern")) continue;
        const feature = feature_list + (reader.u16At(record + 4) catch return found);
        const index_count = reader.u16At(feature + 2) catch return found;
        for (0..index_count) |slot| {
            const lookup_index = reader.u16At(feature + 4 + slot * 2) catch return found;
            if (lookup_index >= lookup_count or seen[lookup_index]) continue;
            seen[lookup_index] = true;
            const lookup = lookup_list + (reader.u16At(lookup_list + 2 + @as(usize, lookup_index) * 2) catch return found);
            const lookup_type = reader.u16At(lookup) catch return found;
            const subtable_count = reader.u16At(lookup + 4) catch return found;
            for (0..subtable_count) |subtable_index| {
                var subtable = lookup + (reader.u16At(lookup + 6 + subtable_index * 2) catch return found);
                var kind = lookup_type;
                if (kind == 9) {
                    kind = reader.u16At(subtable + 2) catch return found;
                    subtable += reader.u32At(subtable + 4) catch return found;
                }
                if (kind != 2) continue;
                if (pairAdjustments(gpa, tables, subtable, glyphs, glyph_indices, kerning) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => false,
                }) found = true;
            }
        }
    }
    return found;
}

/// Reads GPOS mark anchors for the baked glyphs: the mark's origin relative
/// to the base's, in ems.
fn loadGposMarks(
    gpa: std.mem.Allocator,
    tables: *const Tables,
    glyphs: []const Glyph,
    glyph_indices: []const u32,
    marks: *std.AutoHashMapUnmanaged(u64, [2]f32),
    /// "mark" with lookup type 4 (mark-to-base) or 5 (mark-to-ligature, keyed
    /// by
    /// `ligatureMarkKey`), or "mkmk" with 6 (mark-to-mark).
    tag: *const [4]u8,
    wanted_kind: u16,
) !void {
    const gpos = tables.gpos orelse return;
    const reader = tables.reader;
    const feature_list = gpos + (reader.u16At(gpos + 6) catch return);
    const lookup_list = gpos + (reader.u16At(gpos + 8) catch return);
    const lookup_count = reader.u16At(lookup_list) catch return;
    const feature_count = reader.u16At(feature_list) catch return;
    const seen = try gpa.alloc(bool, lookup_count);
    defer gpa.free(seen);
    @memset(seen, false);
    for (0..feature_count) |feature_index| {
        const record = feature_list + 2 + feature_index * 6;
        if (!std.mem.eql(u8, reader.slice(record, 4) catch return, tag)) continue;
        const feature = feature_list + (reader.u16At(record + 4) catch return);
        const index_count = reader.u16At(feature + 2) catch return;
        for (0..index_count) |slot| {
            const lookup_index = reader.u16At(feature + 4 + slot * 2) catch return;
            if (lookup_index >= lookup_count or seen[lookup_index]) continue;
            seen[lookup_index] = true;
            const lookup = lookup_list + (reader.u16At(lookup_list + 2 + @as(usize, lookup_index) * 2) catch return);
            const lookup_type = reader.u16At(lookup) catch return;
            const subtable_count = reader.u16At(lookup + 4) catch return;
            for (0..subtable_count) |subtable_index| {
                var subtable = lookup + (reader.u16At(lookup + 6 + subtable_index * 2) catch return);
                var kind = lookup_type;
                if (kind == 9) {
                    kind = reader.u16At(subtable + 2) catch return;
                    subtable += reader.u32At(subtable + 4) catch return;
                }
                if (kind != wanted_kind) continue;
                (if (kind == 5)
                    markToLigature(gpa, tables, subtable, glyphs, glyph_indices, marks)
                else
                    markToBase(gpa, tables, subtable, glyphs, glyph_indices, marks)) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => {},
                };
            }
        }
    }
}

/// GPOS cursive attachment, in ems: the next glyph's `entry` is laid on this
/// one's `exit`.
pub const Cursive = struct {
    /// Offsets from the glyph's origin, y up.
    entry: ?[2]f32 = null,
    exit: ?[2]f32 = null,
};

/// Reads cursive anchors of the baked glyphs from the `curs` feature.
fn loadGposCursive(gpa: std.mem.Allocator, tables: *const Tables, glyphs: []const Glyph, glyph_indices: []const u32, cursive: *std.AutoHashMapUnmanaged(u21, Cursive)) !void {
    const gpos = tables.gpos orelse return;
    const reader = tables.reader;
    const feature_list = gpos + (reader.u16At(gpos + 6) catch return);
    const lookup_list = gpos + (reader.u16At(gpos + 8) catch return);
    const lookup_count = reader.u16At(lookup_list) catch return;
    const feature_count = reader.u16At(feature_list) catch return;
    for (0..feature_count) |feature_index| {
        const record = feature_list + 2 + feature_index * 6;
        if (!std.mem.eql(u8, reader.slice(record, 4) catch return, "curs")) continue;
        const feature = feature_list + (reader.u16At(record + 4) catch return);
        const index_count = reader.u16At(feature + 2) catch return;
        for (0..index_count) |slot| {
            const lookup_index = reader.u16At(feature + 4 + slot * 2) catch return;
            if (lookup_index >= lookup_count) continue;
            const lookup = lookup_list + (reader.u16At(lookup_list + 2 + @as(usize, lookup_index) * 2) catch return);
            const lookup_type = reader.u16At(lookup) catch return;
            const subtable_count = reader.u16At(lookup + 4) catch return;
            for (0..subtable_count) |subtable_index| {
                var subtable = lookup + (reader.u16At(lookup + 6 + subtable_index * 2) catch return);
                var kind = lookup_type;
                if (kind == 9) {
                    kind = reader.u16At(subtable + 2) catch return;
                    subtable += reader.u32At(subtable + 4) catch return;
                }
                if (kind != 3 or (reader.u16At(subtable) catch return) != 1) continue;
                const coverage = subtable + (reader.u16At(subtable + 2) catch return);
                const count = reader.u16At(subtable + 4) catch return;
                for (glyphs, glyph_indices) |glyph, index| {
                    const covered = (coverageIndex(reader, coverage, index) catch continue) orelse continue;
                    if (covered >= count or cursive.contains(glyph.codepoint)) continue;
                    var joins = Cursive{};
                    inline for (.{ "entry", "exit" }, 0..) |name, side| {
                        const offset = reader.u16At(subtable + 6 + covered * 4 + side * 2) catch 0;
                        if (offset != 0) {
                            const x = reader.i16At(subtable + offset + 2) catch 0;
                            const y = reader.i16At(subtable + offset + 4) catch 0;
                            @field(joins, name) = .{ @as(f32, @floatFromInt(x)) / tables.units_per_em, @as(f32, @floatFromInt(y)) / tables.units_per_em };
                        }
                    }
                    try cursive.put(gpa, glyph.codepoint, joins);
                }
            }
        }
    }
}

/// Key of `Baked.ligature_marks`. `component` counts from 1; 0 is the last
/// part.
fn ligatureMarkKey(base: u21, mark: u21, component: u8) u64 {
    return @as(u64, base) << 43 | @as(u64, mark) << 22 | component;
}

/// Base of the range of undrawn characters naming the ligature part the next
/// mark belongs to. The second half is for right-to-left text.
pub const component_codepoints: u21 = 0xe1000;

fn componentName(component: u8, rtl: bool) u21 {
    return component_codepoints + @as(u21, if (rtl) 0x100 else 0) + component;
}

/// The 1-based ligature part a component character names (255: the last);
/// null for any other character.
pub fn componentOf(codepoint: u21) ?u8 {
    if (codepoint < component_codepoints or codepoint >= component_codepoints + 0x200) return null;
    return @intCast((codepoint - component_codepoints) & 0xff);
}

/// Reads one GPOS mark-to-ligature subtable.
fn markToLigature(
    gpa: std.mem.Allocator,
    tables: *const Tables,
    subtable: usize,
    glyphs: []const Glyph,
    glyph_indices: []const u32,
    marks: *std.AutoHashMapUnmanaged(u64, [2]f32),
) !void {
    const reader = tables.reader;
    if (try reader.u16At(subtable) != 1) return;
    const mark_coverage = subtable + try reader.u16At(subtable + 2);
    const ligature_coverage = subtable + try reader.u16At(subtable + 4);
    const class_count = try reader.u16At(subtable + 6);
    const mark_array = subtable + try reader.u16At(subtable + 8);
    const ligature_array = subtable + try reader.u16At(subtable + 10);
    const mark_count = try reader.u16At(mark_array);
    const ligature_count = try reader.u16At(ligature_array);
    for (glyphs, glyph_indices) |mark, mark_index| {
        const mark_slot = (try coverageIndex(reader, mark_coverage, mark_index)) orelse continue;
        if (mark_slot >= mark_count) continue;
        const mark_record = mark_array + 2 + mark_slot * 4;
        const class = try reader.u16At(mark_record);
        if (class >= class_count) continue;
        const mark_anchor = mark_array + try reader.u16At(mark_record + 2);
        const mark_x: f32 = @floatFromInt(try reader.i16At(mark_anchor + 2));
        const mark_y: f32 = @floatFromInt(try reader.i16At(mark_anchor + 4));
        for (glyphs, glyph_indices) |base, base_index| {
            const slot = (try coverageIndex(reader, ligature_coverage, base_index)) orelse continue;
            if (slot >= ligature_count) continue;
            const attach = ligature_array + try reader.u16At(ligature_array + 2 + slot * 2);
            const components = @min(try reader.u16At(attach), 255);
            for (0..components) |component| {
                const anchor_offset = try reader.u16At(attach + 2 + (component * class_count + class) * 2);
                if (anchor_offset == 0) continue;
                const anchor = attach + anchor_offset;
                const x: f32 = @floatFromInt(try reader.i16At(anchor + 2));
                const y: f32 = @floatFromInt(try reader.i16At(anchor + 4));
                const offset = [2]f32{ (x - mark_x) / tables.units_per_em, (y - mark_y) / tables.units_per_em };
                const key = ligatureMarkKey(base.codepoint, mark.codepoint, @intCast(component + 1));
                if (!marks.contains(key)) try marks.put(gpa, key, offset);
                const last = ligatureMarkKey(base.codepoint, mark.codepoint, 0);
                if (component + 1 == components and !marks.contains(last)) try marks.put(gpa, last, offset);
            }
        }
    }
}

fn markToBase(
    gpa: std.mem.Allocator,
    tables: *const Tables,
    subtable: usize,
    glyphs: []const Glyph,
    glyph_indices: []const u32,
    marks: *std.AutoHashMapUnmanaged(u64, [2]f32),
) !void {
    const reader = tables.reader;
    if (try reader.u16At(subtable) != 1) return;
    const mark_coverage = subtable + try reader.u16At(subtable + 2);
    const base_coverage = subtable + try reader.u16At(subtable + 4);
    const class_count = try reader.u16At(subtable + 6);
    const mark_array = subtable + try reader.u16At(subtable + 8);
    const base_array = subtable + try reader.u16At(subtable + 10);
    const mark_count = try reader.u16At(mark_array);
    const base_count = try reader.u16At(base_array);
    for (glyphs, glyph_indices) |mark, mark_index| {
        const mark_slot = (try coverageIndex(reader, mark_coverage, mark_index)) orelse continue;
        if (mark_slot >= mark_count) continue;
        const mark_record = mark_array + 2 + mark_slot * 4;
        const class = try reader.u16At(mark_record);
        if (class >= class_count) continue;
        const mark_anchor = mark_array + try reader.u16At(mark_record + 2);
        const mark_x: f32 = @floatFromInt(try reader.i16At(mark_anchor + 2));
        const mark_y: f32 = @floatFromInt(try reader.i16At(mark_anchor + 4));
        for (glyphs, glyph_indices) |base, base_index| {
            const base_slot = (try coverageIndex(reader, base_coverage, base_index)) orelse continue;
            if (base_slot >= base_count) continue;
            const anchor_offset = try reader.u16At(base_array + 2 + (base_slot * class_count + class) * 2);
            if (anchor_offset == 0) continue;
            const base_anchor = base_array + anchor_offset;
            const base_x: f32 = @floatFromInt(try reader.i16At(base_anchor + 2));
            const base_y: f32 = @floatFromInt(try reader.i16At(base_anchor + 4));
            const key = @as(u64, base.codepoint) << 32 | mark.codepoint;
            if (!marks.contains(key)) try marks.put(gpa, key, .{ (base_x - mark_x) / tables.units_per_em, (base_y - mark_y) / tables.units_per_em });
        }
    }
}

/// The font's ligatures whose parts and result are all baked, longest first.
fn bakedLigatures(gpa: std.mem.Allocator, tables: *const Tables, glyphs: []const Glyph, glyph_indices: []const u32) ![]Ligature {
    var raw: std.ArrayList(RawLigature) = .empty;
    defer raw.deinit(gpa);
    try readGsubLigatures(gpa, tables, &raw);
    var found: std.ArrayList(Ligature) = .empty;
    errdefer found.deinit(gpa);
    const Local = struct {
        fn codepointOf(all: []const Glyph, indices: []const u32, glyph: u16) ?u21 {
            var numbered: ?u21 = null;
            for (all, indices) |candidate, index| {
                if (index != glyph) continue;
                if (candidate.codepoint < glyph_codepoints_rtl_mark) return candidate.codepoint;
                numbered = candidate.codepoint;
            }
            return numbered;
        }
    };
    for (raw.items) |ligature| {
        var entry = Ligature{ .len = ligature.len, .result = Local.codepointOf(glyphs, glyph_indices, ligature.result) orelse continue };
        var whole = true;
        for (ligature.glyphs[0..ligature.len], 0..) |glyph, index| {
            entry.sequence[index] = Local.codepointOf(glyphs, glyph_indices, glyph) orelse {
                whole = false;
                break;
            };
        }
        if (whole) try found.append(gpa, entry);
    }
    std.mem.sort(Ligature, found.items, {}, struct {
        fn longer(_: void, a: Ligature, b: Ligature) bool {
            return a.len > b.len;
        }
    }.longer);
    return found.toOwnedSlice(gpa);
}

/// Size in bytes of a GPOS value record of this format.
fn valueSize(format: u16) usize {
    return @as(usize, @popCount(format)) * 2;
}

fn advanceOf(reader: Reader, record: usize, format: u16) !f32 {
    if (format & 0x0004 == 0) return 0;
    return @floatFromInt(try reader.i16At(record + @as(usize, @popCount(format & 0x0003)) * 2));
}

/// Coverage index of a glyph, or null if not covered.
fn coverageIndex(reader: Reader, coverage: usize, glyph: u32) !?usize {
    const count = try reader.u16At(coverage + 2);
    switch (try reader.u16At(coverage)) {
        1 => for (0..count) |index| {
            if (try reader.u16At(coverage + 4 + index * 2) == glyph) return index;
        },
        2 => for (0..count) |index| {
            const range = coverage + 4 + index * 6;
            const first = try reader.u16At(range);
            if (glyph >= first and glyph <= try reader.u16At(range + 2)) return @as(usize, try reader.u16At(range + 4)) + (glyph - first);
        },
        else => {},
    }
    return null;
}

fn classOf(reader: Reader, class_def: usize, glyph: u32) !u16 {
    switch (try reader.u16At(class_def)) {
        1 => {
            const first = try reader.u16At(class_def + 2);
            const count = try reader.u16At(class_def + 4);
            if (glyph >= first and glyph < @as(u32, first) + count) return reader.u16At(class_def + 6 + (glyph - first) * 2);
        },
        2 => {
            const count = try reader.u16At(class_def + 2);
            for (0..count) |index| {
                const range = class_def + 4 + index * 6;
                if (glyph >= try reader.u16At(range) and glyph <= try reader.u16At(range + 2)) return reader.u16At(range + 4);
            }
        },
        else => {},
    }
    return 0;
}

fn pairAdjustments(
    gpa: std.mem.Allocator,
    tables: *const Tables,
    subtable: usize,
    glyphs: []const Glyph,
    glyph_indices: []const u32,
    kerning: *std.AutoHashMapUnmanaged(u64, f32),
) !bool {
    const reader = tables.reader;
    const format = try reader.u16At(subtable);
    const coverage = subtable + try reader.u16At(subtable + 2);
    const format1 = try reader.u16At(subtable + 4);
    const format2 = try reader.u16At(subtable + 6);
    if (format1 & 0x0004 == 0) return false;
    const record_size = valueSize(format1) + valueSize(format2);
    var found = false;
    if (format == 1) {
        const set_count = try reader.u16At(subtable + 8);
        for (glyphs, glyph_indices) |left, left_index| {
            const covered = (try coverageIndex(reader, coverage, left_index)) orelse continue;
            if (covered >= set_count) continue;
            const set = subtable + try reader.u16At(subtable + 10 + covered * 2);
            const pair_count = try reader.u16At(set);
            for (0..pair_count) |pair| {
                const record = set + 2 + pair * (2 + record_size);
                const second = try reader.u16At(record);
                const value = try advanceOf(reader, record + 2, format1);
                if (value == 0) continue;
                for (glyphs, glyph_indices) |right, right_index| {
                    if (right_index != second) continue;
                    const key = @as(u64, left.codepoint) << 32 | right.codepoint;
                    if (!kerning.contains(key)) try kerning.put(gpa, key, value / tables.units_per_em);
                    found = true;
                }
            }
        }
    } else if (format == 2) {
        const class_def1 = subtable + try reader.u16At(subtable + 8);
        const class_def2 = subtable + try reader.u16At(subtable + 10);
        const class1_count = try reader.u16At(subtable + 12);
        const class2_count = try reader.u16At(subtable + 14);
        const right_classes = try gpa.alloc(u16, glyphs.len);
        defer gpa.free(right_classes);
        for (right_classes, glyph_indices) |*class, index| class.* = try classOf(reader, class_def2, index);
        for (glyphs, glyph_indices) |left, left_index| {
            if ((try coverageIndex(reader, coverage, left_index)) == null) continue;
            const class1 = try classOf(reader, class_def1, left_index);
            if (class1 >= class1_count) continue;
            const row = subtable + 16 + @as(usize, class1) * class2_count * record_size;
            for (glyphs, right_classes) |right, class2| {
                if (class2 >= class2_count) continue;
                const value = try advanceOf(reader, row + @as(usize, class2) * record_size, format1);
                if (value == 0) continue;
                const key = @as(u64, left.codepoint) << 32 | right.codepoint;
                if (!kerning.contains(key)) try kerning.put(gpa, key, value / tables.units_per_em);
                found = true;
            }
        }
    }
    return found;
}

/// Reads format 0 `kern` table pairs for the baked glyphs.
fn loadKerning(
    gpa: std.mem.Allocator,
    tables: *const Tables,
    glyphs: []const Glyph,
    glyph_indices: []const u32,
    kerning: *std.AutoHashMapUnmanaged(u64, f32),
) !void {
    const table = tables.kern orelse return;
    const reader = tables.reader;
    if ((reader.u16At(table) catch return) != 0) return;
    const subtables = reader.u16At(table + 2) catch return;
    var by_glyph: std.AutoHashMapUnmanaged(u32, u21) = .empty;
    defer by_glyph.deinit(gpa);
    for (glyphs, glyph_indices) |glyph, index| try by_glyph.put(gpa, index, glyph.codepoint);

    var cursor = table + 4;
    for (0..subtables) |_| {
        const length = reader.u16At(cursor + 2) catch return;
        const coverage = reader.u16At(cursor + 4) catch return;
        if (coverage & 0xff07 == 0x0001) {
            const pairs = reader.u16At(cursor + 6) catch return;
            for (0..pairs) |pair| {
                const record = cursor + 14 + pair * 6;
                const left = by_glyph.get(reader.u16At(record) catch return) orelse continue;
                const right = by_glyph.get(reader.u16At(record + 2) catch return) orelse continue;
                const value: f32 = @floatFromInt(reader.i16At(record + 4) catch return);
                try kerning.put(gpa, @as(u64, left) << 32 | right, value / tables.units_per_em);
            }
        }
        if (length == 0) return;
        cursor += length;
    }
}

test "built-in font parses, bakes and measures" {
    var font = try load(std.testing.allocator, @embedFile("../render/fonts/DejaVuSans.ttf"), default_ranges);
    defer font.deinit();
    try std.testing.expect(font.baked().glyphs.len > 180);
    try std.testing.expect(font.ascent > 0.5 and font.descent > 0.1);

    const a = font.glyph('A');
    try std.testing.expectEqual(@as(u21, 'A'), a.codepoint);
    try std.testing.expect(a.advance > 0.4 and a.advance < 0.9);
    try std.testing.expect(a.plane[3] > 0.6); // capital height
    const stem = font.glyph('I');
    const u: usize = @intFromFloat((stem.uv[0] + stem.uv[2]) * 0.5 * @as(f32, @floatFromInt(font.baked().atlas_width)));
    const v: usize = @intFromFloat((stem.uv[1] + stem.uv[3]) * 0.5 * @as(f32, @floatFromInt(font.baked().atlas_height)));
    try std.testing.expect(font.baked().atlas[v * font.baked().atlas_width + u] > 160);
    const corner_u: usize = @intFromFloat(stem.uv[0] * @as(f32, @floatFromInt(font.baked().atlas_width)));
    const corner_v: usize = @intFromFloat(stem.uv[1] * @as(f32, @floatFromInt(font.baked().atlas_height)));
    try std.testing.expect(font.baked().atlas[corner_v * font.baked().atlas_width + corner_u] < 96);

    try std.testing.expectEqual(@as(u21, '?'), font.glyph(0x4e2d).codepoint);
    const size = font.measure("Hi\nthere", 10);
    try std.testing.expect(size[0] > 15 and size[0] < 40);
    try std.testing.expectApproxEqAbs(font.line_height * 20, size[1], 1e-4);
}

test "utf-8 iteration is lenient" {
    var iterator = Utf8Iterator{ .bytes = "a\xc3\xa9\xff" };
    try std.testing.expectEqual(@as(?u21, 'a'), iterator.next());
    try std.testing.expectEqual(@as(?u21, 0xe9), iterator.next());
    try std.testing.expectEqual(@as(?u21, 0xfffd), iterator.next());
    try std.testing.expectEqual(@as(?u21, null), iterator.next());
}

test "kerning is read from the font's positioning table" {
    var font = try load(std.testing.allocator, @embedFile("../render/fonts/DejaVuSans.ttf"), default_ranges);
    defer font.deinit();
    try std.testing.expect(font.baked().kerning.count() > 100);
    try std.testing.expect(font.kern('A', 'V') < -0.01);
    try std.testing.expect(font.kern('A', 'V') > -0.3);
    try std.testing.expectEqual(@as(f32, 0), font.kern('H', 'H'));
}

test "glyphs added later land where a full bake puts them" {
    const gpa = std.testing.allocator;
    const bytes = @embedFile("../render/fonts/DejaVuSans.ttf");
    var grown = try load(gpa, bytes, &.{.{ 'A', 'Z' }});
    defer grown.deinit();
    const added = [_]u21{ 'a', 'b', 'c', 0x05d0, 0x05d1, '!' };
    const next = (try grown.extend(&added)) orelse return error.NothingAdded;
    grown.adopt(next);
    try std.testing.expect((try grown.extend(&added)) == null);

    var whole = try load(gpa, bytes, &.{ .{ 'A', 'Z' }, .{ 'a', 'a' }, .{ 'b', 'b' }, .{ 'c', 'c' }, .{ 0x05d0, 0x05d0 }, .{ 0x05d1, 0x05d1 }, .{ '!', '!' } });
    defer whole.deinit();
    const a = grown.baked();
    const b = whole.baked();
    try std.testing.expectEqual(b.glyphs.len, a.glyphs.len);
    try std.testing.expectEqual(b.atlas_height, a.atlas_height);
    for (a.glyphs, b.glyphs) |left, right| {
        try std.testing.expectEqual(right.codepoint, left.codepoint);
        try std.testing.expectEqual(right.advance, left.advance);
        try std.testing.expectEqualSlices(f32, &right.plane, &left.plane);
        try std.testing.expectEqualSlices(f32, &right.uv, &left.uv);
    }
    try std.testing.expectEqualSlices(u8, b.atlas, a.atlas);
    try std.testing.expectEqual(b.kerning.count(), a.kerning.count());
    try std.testing.expect(grown.retired.items.len == 1);
    try std.testing.expect(grown.retired.items[0].find('A') != null);
}

test "adding enough glyphs to grow the atlas keeps the earlier ones intact" {
    const gpa = std.testing.allocator;
    const bytes = @embedFile("../render/fonts/DejaVuSans.ttf");
    var font = try load(gpa, bytes, &.{.{ 'A', 'F' }});
    defer font.deinit();
    const small = font.baked();
    const before = small.glyph('C').*;
    const height_before = small.atlas_height;
    var many: [0x250 - 0x21]u21 = undefined;
    for (&many, 0..) |*codepoint, index| codepoint.* = @intCast(0x21 + index);
    const next = (try font.extend(&many)) orelse return error.NothingAdded;
    font.adopt(next);
    const large = font.baked();
    try std.testing.expect(large.atlas_height > height_before);
    const after = large.glyph('C').*;
    const scale = @as(f32, @floatFromInt(height_before)) / @as(f32, @floatFromInt(large.atlas_height));
    try std.testing.expectEqual(before.uv[0], after.uv[0]);
    try std.testing.expectApproxEqAbs(before.uv[1] * scale, after.uv[1], 1e-6);
    try std.testing.expectApproxEqAbs(before.uv[3] * scale, after.uv[3], 1e-6);
    const top: usize = @intFromFloat(@round(after.uv[1] * @as(f32, @floatFromInt(large.atlas_height))));
    const left: usize = @intFromFloat(@round(after.uv[0] * @as(f32, @floatFromInt(large.atlas_width))));
    const width: usize = @intFromFloat(@round((after.uv[2] - after.uv[0]) * @as(f32, @floatFromInt(large.atlas_width))));
    var lit: usize = 0;
    for (large.atlas[top * large.atlas_width + left ..][0..width]) |value| lit += value;
    for (large.atlas[(top + 20) * large.atlas_width + left ..][0..width]) |value| lit += value;
    try std.testing.expect(lit > 0);
}

test "combining marks are placed by the font's anchors" {
    var font = try load(std.testing.allocator, @embedFile("../render/fonts/DejaVuSans.ttf"), &.{ .{ 32, 126 }, .{ 0x300, 0x36f } });
    defer font.deinit();
    const over_e = font.markOffset('e', 0x301) orelse return error.TestExpectedMark;
    const over_capital = font.markOffset('E', 0x301) orelse return error.TestExpectedMark;
    try std.testing.expect(over_capital[1] > over_e[1] + 0.05);
    try std.testing.expectEqual(@as(?[2]f32, null), font.markOffset('e', 'a'));
}

test "a mark on a mark is placed by the font too" {
    var font = try load(std.testing.allocator, @embedFile("../render/fonts/DejaVuSans.ttf"), &.{ .{ 32, 126 }, .{ 0x300, 0x36f } });
    defer font.deinit();
    const stacked = font.markOffset(0x308, 0x301) orelse return error.TestExpectedMark;
    try std.testing.expect(stacked[1] > 0.05);
}

test "the font's own ligatures are read from its substitution table" {
    const gpa = std.testing.allocator;
    const bytes = @embedFile("../render/fonts/DejaVuSans.ttf");
    var named = try load(gpa, bytes, &.{ .{ 32, 126 }, .{ 0xfb00, 0xfb04 } });
    defer named.deinit();
    const ffi = named.ligature(&.{ 'f', 'f', 'i', 'x' }) orelse return error.TestExpectedLigature;
    try std.testing.expectEqual(@as(usize, 3), ffi.consumed);
    try std.testing.expectEqual(@as(u21, 0xfb03), ffi.codepoint);
    try std.testing.expectEqual(@as(?LigatureMatch, null), named.ligature(&.{ 'a', 'b' }));

    var plain = try load(gpa, bytes, &.{.{ 32, 126 }});
    defer plain.deinit();
    try std.testing.expectEqual(@as(?LigatureMatch, null), plain.ligature(&.{ 'f', 'i' }));
    const missing = try plain.missingLigatures(gpa);
    defer gpa.free(missing);
    try std.testing.expect(missing.len >= 3);
    for (missing) |codepoint| try std.testing.expect(codepoint >= glyph_codepoints);
    const next = (try plain.extend(missing)) orelse return error.NothingAdded;
    plain.adopt(next);
    const fi = plain.ligature(&.{ 'f', 'i' }) orelse return error.TestExpectedLigature;
    try std.testing.expectEqual(@as(usize, 2), fi.consumed);
    try std.testing.expect(fi.codepoint >= glyph_codepoints);
    const drawn = plain.glyph(fi.codepoint);
    try std.testing.expect(drawn.plane[2] > drawn.plane[0]);
    try std.testing.expect((try plain.missingLigatures(gpa)).len == 0);
}

fn substitutedForTest(gpa: std.mem.Allocator, text: []const u21, script: opentype.Tag, language: ?opentype.Tag, features: []const opentype.Tag) ![]u16 {
    const tables = try Tables.init(@embedFile("../render/fonts/DejaVuSans.ttf"));
    const layout = try opentype.Layout.init(tables.reader.bytes, tables.gsub.?, tables.gdef);
    var glyphs: std.ArrayList(opentype.Glyph) = .empty;
    defer glyphs.deinit(gpa);
    for (text, 0..) |codepoint, index| try glyphs.append(gpa, .{ .id = @intCast(try tables.glyphIndex(codepoint)), .cluster = @intCast(index) });
    const lookups = try layout.lookups(gpa, script, language, features);
    defer gpa.free(lookups);
    try layout.substitute(gpa, &glyphs, lookups);
    var planned: std.ArrayList(opentype.Glyph) = .empty;
    defer planned.deinit(gpa);
    for (text, 0..) |codepoint, index| try planned.append(gpa, .{ .id = @intCast(try tables.glyphIndex(codepoint)), .cluster = @intCast(index) });
    var plan = try layout.plan(gpa, script, language, features, tables.glyph_count);
    defer plan.deinit(gpa);
    _ = try layout.substitutePlanned(gpa, &planned, plan);
    try std.testing.expectEqual(glyphs.items.len, planned.items.len);
    for (glyphs.items, planned.items) |one, other| try std.testing.expectEqual(one.id, other.id);
    const ids = try gpa.alloc(u16, glyphs.items.len);
    for (ids, glyphs.items) |*id, glyph| id.* = glyph.id;
    return ids;
}

test "the font's substitutions give the glyphs a full shaper gives" {
    const gpa = std.testing.allocator;
    const usual = [_]opentype.Tag{ "ccmp".*, "locl".*, "rlig".*, "liga".*, "calt".*, "clig".* };
    const Case = struct {
        text: []const u21,
        script: opentype.Tag = "latn".*,
        language: ?opentype.Tag = null,
        features: []const opentype.Tag = &usual,
        /// HarfBuzz 13.2 output for the same text.
        glyphs: []const u16,
    };
    const cases = [_]Case{
        .{ .text = &.{ 'f', 'i', ' ', 'f', 'f', 'l' }, .glyphs = &.{ 5042, 3, 5045 } },
        .{ .text = &.{ 'i', 0x30a, ' ', 'j', 0x303 }, .glyphs = &.{ 243, 699, 3, 505, 692 } },
        .{ .text = &.{0x431}, .script = "cyrl".*, .language = "SRB ".*, .glyphs = &.{5040} },
        .{ .text = &.{0x431}, .script = "cyrl".*, .glyphs = &.{966} },
        .{ .text = &.{0x14a}, .language = "NSM ".*, .glyphs = &.{5970} },
        .{ .text = &.{0x14a}, .glyphs = &.{268} },
        .{ .text = &.{'a'}, .features = &.{"salt".*}, .glyphs = &.{531} },
        .{ .text = &.{ 'a', 0xbf, '-' }, .features = &.{"case".*}, .glyphs = &.{ 68, 6214, 16 } },
        .{ .text = &.{0x1c6}, .features = &.{"aalt".*}, .glyphs = &.{392} },
    };
    for (cases) |case| {
        const glyphs = try substitutedForTest(gpa, case.text, case.script, case.language, case.features);
        defer gpa.free(glyphs);
        try std.testing.expectEqualSlices(u16, case.glyphs, glyphs);
    }
}

test "text comes out as the characters of the glyphs the font puts in" {
    const gpa = std.testing.allocator;
    var font = try load(gpa, @embedFile("../render/fonts/DejaVuSans.ttf"), &.{ .{ 32, 126 }, .{ 0x131, 0x131 }, .{ 0x300, 0x30f }, .{ 0x430, 0x431 }, .{ 0xfb01, 0xfb01 } });
    defer font.deinit();
    var out: std.ArrayList(u21) = .empty;
    defer out.deinit(gpa);

    try std.testing.expect(try font.substitute(gpa, &.{ 'f', 'i', 'x' }, .{ .script = "latn".* }, &out));
    try std.testing.expectEqualSlices(u21, &.{ 0xfb01, 'x' }, out.items);
    out.clearRetainingCapacity();
    try std.testing.expect(try font.substitute(gpa, &.{ 'i', 0x30a }, .{ .script = "latn".* }, &out));
    try std.testing.expectEqualSlices(u21, &.{ 0x131, 0x30a }, out.items);
    out.clearRetainingCapacity();

    const serbian = Shaping{ .script = "cyrl".*, .language = "SRB ".* };
    try std.testing.expect(!try font.substitute(gpa, &.{ 0x430, 0x431 }, serbian, &out));
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
    var missing: std.ArrayList(u21) = .empty;
    defer missing.deinit(gpa);
    try font.missingSubstitutes(gpa, &.{ 0x430, 0x431 }, serbian, &missing);
    try std.testing.expectEqualSlices(u21, &.{glyph_codepoints + 5040}, missing.items);
    const next = (try font.extend(missing.items)) orelse return error.NothingAdded;
    font.adopt(next);
    try std.testing.expect(try font.substitute(gpa, &.{ 0x430, 0x431 }, serbian, &out));
    try std.testing.expectEqualSlices(u21, &.{ 0x430, glyph_codepoints + 5040 }, out.items);
    out.clearRetainingCapacity();
    try std.testing.expect(!try font.substitute(gpa, &.{ 0x430, 0x431 }, .{ .script = "cyrl".* }, &out));
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
    out.clearRetainingCapacity();

    missing.clearRetainingCapacity();
    const alternate = Shaping{ .script = "latn".*, .features = &.{"salt".*} };
    try font.missingSubstitutes(gpa, &.{'a'}, alternate, &missing);
    try std.testing.expectEqualSlices(u21, &.{glyph_codepoints + 531}, missing.items);
}

/// System fonts with Devanagari; the repository carries none.
const devanagari_font_paths = [_][]const u8{
    "/nix/store/898jsdqfwknwsli5ajhns19gbi9faz4m-freefont-ttf-20120503/share/fonts/truetype/FreeSerif.ttf",
    "/usr/share/fonts/truetype/freefont/FreeSerif.ttf",
    "/usr/share/fonts/gnu-free/FreeSerif.ttf",
};

test "devanagari comes out as the glyphs a full shaper gives" {
    const gpa = std.testing.allocator;
    const bytes = for (devanagari_font_paths) |path| {
        break std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, gpa, .unlimited) catch continue;
    } else return error.SkipZigTest;
    defer gpa.free(bytes);
    var font = try load(gpa, bytes, &.{.{ 32, 126 }});
    defer font.deinit();
    var with = (try font.substitution(gpa, .{ .script = "dev2".* })) orelse return error.TestExpectedSubstitution;
    defer with.deinit(gpa);
    try std.testing.expect(with.forms.?.reph);
    const Case = struct {
        text: []const u8,
        /// HarfBuzz 13.2 output with FreeSerif (GNU FreeFont 20120503).
        glyphs: []const u16,
    };
    const cases = [_]Case{
        .{ .text = "कि", .glyphs = &.{ 1836, 1794 } },
        .{ .text = "क्ष", .glyphs = &.{10325} },
        .{ .text = "र्क", .glyphs = &.{ 1794, 10002 } },
        .{ .text = "त्र", .glyphs = &.{ 1809, 1850, 1821 } },
        .{ .text = "क्क", .glyphs = &.{ 10328, 1794 } },
        .{ .text = "र्कि", .glyphs = &.{ 1836, 1794, 10002 } },
        .{ .text = "र्का", .glyphs = &.{ 1794, 1835, 10002 } },
        .{ .text = "हिन्दी", .glyphs = &.{ 1836, 1830, 10340, 1811, 1837 } },
        .{ .text = "नमस्ते", .glyphs = &.{ 1813, 1819, 10352, 1809, 1844 } },
        .{ .text = "क्या", .glyphs = &.{ 10328, 1820, 1835 } },
        .{ .text = "प्र", .glyphs = &.{ 1815, 1850, 1821 } },
        .{ .text = "श्री", .glyphs = &.{ 1827, 1850, 1821, 1837 } },
        .{ .text = "कर्म", .glyphs = &.{ 1794, 1819, 10002 } },
        .{ .text = "विद्यार्थी", .glyphs = &.{ 1836, 1826, 10402, 1835, 1810, 1837, 10002 } },
        .{ .text = "क्", .glyphs = &.{ 1794, 1850 } },
        .{ .text = "कृ", .glyphs = &.{ 1794, 1840 } },
        .{ .text = "कं", .glyphs = &.{ 1794, 1775 } },
        .{ .text = "र्के", .glyphs = &.{ 1794, 9991 } },
        .{ .text = "र्कं", .glyphs = &.{ 1794, 10002, 1775 } },
        .{ .text = "र्कों", .glyphs = &.{ 1794, 1848, 10002, 1775 } },
        .{ .text = "र्त्र", .glyphs = &.{ 1809, 1850, 1821, 10002 } },
        .{ .text = "र्क्क", .glyphs = &.{ 10328, 1794, 10002 } },
        .{ .text = "क्कि", .glyphs = &.{ 1836, 10328, 1794 } },
        .{ .text = "त्रि", .glyphs = &.{ 1836, 1809, 1850, 1821 } },
        .{ .text = "क़ि", .glyphs = &.{ 1836, 1861 } },
        .{ .text = "स्त्री", .glyphs = &.{ 10352, 1809, 1850, 1821, 1837 } },
        .{ .text = "अर्क", .glyphs = &.{ 1778, 1794, 10002 } },
        .{ .text = "र्", .glyphs = &.{ 1821, 1850 } },
        .{ .text = "संस्कृत", .glyphs = &.{ 1829, 1775, 10352, 1794, 1840, 1809 } },
        .{ .text = "ज्ञान", .glyphs = &.{ 10326, 1835, 1813 } },
        .{ .text = "श्रद्धा", .glyphs = &.{ 1827, 1850, 1821, 10397, 1835 } },
        .{ .text = "कर्त्ता", .glyphs = &.{ 1794, 10392, 1835, 10002 } },
        .{ .text = "राष्ट्र", .glyphs = &.{ 1821, 1835, 10351, 1804, 1850, 1821 } },
    };
    var failed: usize = 0;
    for (cases) |case| {
        var text: std.ArrayList(u21) = .empty;
        defer text.deinit(gpa);
        var characters = Utf8Iterator{ .bytes = case.text };
        while (characters.next()) |codepoint| try text.append(gpa, codepoint);
        var glyphs: std.ArrayList(opentype.Glyph) = .empty;
        defer glyphs.deinit(gpa);
        _ = try with.run(gpa, text.items, &glyphs);
        var same = glyphs.items.len == case.glyphs.len;
        if (same) for (glyphs.items, case.glyphs) |shaped, expected| {
            if (shaped.id != expected) same = false;
        };
        if (!same) {
            failed += 1;
            std.debug.print("devanagari: {s}: expected {any}, got", .{ case.text, case.glyphs });
            for (glyphs.items) |shaped| std.debug.print(" {d}", .{shaped.id});
            std.debug.print("\n", .{});
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failed);
}

test "arabic comes out as the glyphs a full shaper gives" {
    const gpa = std.testing.allocator;
    var font = try load(gpa, @embedFile("../render/fonts/DejaVuSans.ttf"), &.{.{ 32, 126 }});
    defer font.deinit();
    var with = (try font.substitution(gpa, .{ .script = "arab".* })) orelse return error.TestExpectedSubstitution;
    defer with.deinit(gpa);
    const Case = struct {
        text: []const u8,
        /// HarfBuzz 13.2 output, in logical order.
        glyphs: []const u16,
    };
    const cases = [_]Case{
        .{ .text = "سلام", .glyphs = &.{ 5293, 5366, 1390 } },
        .{ .text = "لا مر", .glyphs = &.{ 5365, 3, 5341, 5288 } },
        .{ .text = "محمد", .glyphs = &.{ 5341, 5278, 5342, 5284 } },
        .{ .text = "كتاب", .glyphs = &.{ 5333, 5266, 5256, 1366 } },
        .{ .text = "اللغة العربية", .glyphs = &.{ 1365, 5337, 5338, 5322, 5262, 3, 1365, 5337, 5318, 5288, 5259, 5358, 5262 } },
        .{ .text = "بِسْمِ", .glyphs = &.{ 5259, 1401, 5294, 1403, 5340, 1401 } },
        .{ .text = "ئة", .glyphs = &.{ 5253, 5262 } },
        .{ .text = "ـبـ", .glyphs = &.{ 1385, 5260, 1385 } },
        .{ .text = "پچژگ", .glyphs = &.{ 5105, 5142, 5156, 1481 } },
        .{ .text = "لله", .glyphs = &.{ 5337, 5338, 5348 } },
        .{ .text = "الله", .glyphs = &.{ 1365, 5337, 5338, 5348 } },
        .{ .text = "فلا", .glyphs = &.{ 5325, 5366 } },
    };
    var failed: usize = 0;
    for (cases) |case| {
        var text: std.ArrayList(u21) = .empty;
        defer text.deinit(gpa);
        var characters = Utf8Iterator{ .bytes = case.text };
        while (characters.next()) |codepoint| try text.append(gpa, codepoint);
        var glyphs: std.ArrayList(opentype.Glyph) = .empty;
        defer glyphs.deinit(gpa);
        _ = try with.run(gpa, text.items, &glyphs);
        var same = glyphs.items.len == case.glyphs.len;
        if (same) for (glyphs.items, case.glyphs) |shaped, expected| {
            if (shaped.id != expected) same = false;
        };
        if (!same) {
            failed += 1;
            std.debug.print("arabic: {s}: expected {any}, got", .{ case.text, case.glyphs });
            for (glyphs.items) |shaped| std.debug.print(" {d}", .{shaped.id});
            std.debug.print("\n", .{});
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failed);
}

test "the sister scripts of devanagari come out as a full shaper gives them" {
    const gpa = std.testing.allocator;
    const bytes = for (devanagari_font_paths) |path| {
        break std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, gpa, .unlimited) catch continue;
    } else return error.SkipZigTest;
    defer gpa.free(bytes);
    var font = try load(gpa, bytes, &.{.{ 32, 126 }});
    defer font.deinit();
    const Case = struct {
        script: opentype.Tag,
        text: []const u8,
        /// HarfBuzz 13.2 output with FreeSerif (GNU FreeFont 20120503).
        glyphs: []const u16,
    };
    const cases = [_]Case{
        .{ .script = "bng2".*, .text = "বাংলা", .glyphs = &.{ 1937, 1949, 1901, 1942, 1949 } },
        .{ .script = "bng2".*, .text = "কি", .glyphs = &.{ 1950, 1915 } },
        .{ .script = "bng2".*, .text = "কে", .glyphs = &.{ 8891, 1915 } },
        .{ .script = "bng2".*, .text = "কো", .glyphs = &.{ 8891, 1915, 1949 } },
        .{ .script = "bng2".*, .text = "কৌ", .glyphs = &.{ 8891, 1915, 1962 } },
        .{ .script = "bng2".*, .text = "র্ক", .glyphs = &.{ 1915, 8893 } },
        .{ .script = "bng2".*, .text = "র্কি", .glyphs = &.{ 1950, 1915, 8893 } },
        .{ .script = "bng2".*, .text = "র্কো", .glyphs = &.{ 8891, 1915, 8893, 1949 } },
        .{ .script = "bng2".*, .text = "ক্ষ", .glyphs = &.{8980} },
        .{ .script = "bng2".*, .text = "ত্র", .glyphs = &.{ 9374, 1941 } },
        .{ .script = "bng2".*, .text = "ব্য", .glyphs = &.{ 9259, 1940 } },
        .{ .script = "bng2".*, .text = "স্ত্রী", .glyphs = &.{ 8925, 9374, 1941, 1951 } },
        .{ .script = "bng2".*, .text = "বিদ্যা", .glyphs = &.{ 1950, 1937, 9376, 1940, 1949 } },
        .{ .script = "bng2".*, .text = "বাংলাদেশ", .glyphs = &.{ 1937, 1949, 1901, 1942, 1949, 1956, 1932, 1943 } },
        .{ .script = "bng2".*, .text = "ভাষা", .glyphs = &.{ 1938, 1949, 1944, 1949 } },
        .{ .script = "bng2".*, .text = "জ্ঞান", .glyphs = &.{ 9011, 1949, 1934 } },
        .{ .script = "gur2".*, .text = "ਪੰਜਾਬੀ", .glyphs = &.{ 2025, 2065, 2012, 2039, 2027, 2041 } },
        .{ .script = "gur2".*, .text = "ਕਿ", .glyphs = &.{ 2040, 2005 } },
        .{ .script = "gur2".*, .text = "ਸ੍ਰੀ", .glyphs = &.{ 2036, 2048, 2031, 2041 } },
        .{ .script = "gur2".*, .text = "ਸਿੰਘ", .glyphs = &.{ 2040, 2036, 2065, 2008 } },
        .{ .script = "gur2".*, .text = "ਗੁਰੂ", .glyphs = &.{ 2007, 2042, 2031, 2043 } },
        .{ .script = "gjr2".*, .text = "ગુજરાતી", .glyphs = &.{ 2090, 2127, 2095, 2114, 2124, 2103, 2126 } },
        .{ .script = "gjr2".*, .text = "કિ", .glyphs = &.{ 10272, 2088 } },
        .{ .script = "gjr2".*, .text = "ર્ક", .glyphs = &.{ 2088, 10266 } },
        .{ .script = "gjr2".*, .text = "ર્કા", .glyphs = &.{ 2088, 2124, 10266 } },
        .{ .script = "gjr2".*, .text = "ક્ષ", .glyphs = &.{10242} },
        .{ .script = "gjr2".*, .text = "શ્રી", .glyphs = &.{ 2118, 2137, 2114, 2126 } },
        .{ .script = "gjr2".*, .text = "ત્ર", .glyphs = &.{ 2103, 2137, 2114 } },
        .{ .script = "ory2".*, .text = "ଓଡ଼ିଆ", .glyphs = &.{ 2168, 2182, 2204, 2207, 2159 } },
        .{ .script = "ory2".*, .text = "କେ", .glyphs = &.{ 2213, 2170 } },
        .{ .script = "ory2".*, .text = "କୋ", .glyphs = &.{ 2213, 2170, 2206 } },
        .{ .script = "ory2".*, .text = "କୈ", .glyphs = &.{ 2213, 2170, 2218 } },
        .{ .script = "ory2".*, .text = "ର୍କ", .glyphs = &.{ 2170, 10170 } },
        .{ .script = "ory2".*, .text = "ର୍କା", .glyphs = &.{ 2170, 10170, 2206 } },
        .{ .script = "ory2".*, .text = "କ୍ଷ", .glyphs = &.{ 2170, 2217, 2201 } },
        .{ .script = "tml2".*, .text = "தமிழ்", .glyphs = &.{ 2266, 2270, 2283, 2276, 2293 } },
        .{ .script = "tml2".*, .text = "கெ", .glyphs = &.{ 2287, 2259 } },
        .{ .script = "tml2".*, .text = "கொ", .glyphs = &.{ 2287, 2259, 2282 } },
        .{ .script = "tml2".*, .text = "கௌ", .glyphs = &.{ 2287, 2259, 2295 } },
        .{ .script = "tml2".*, .text = "க்ஷ", .glyphs = &.{9357} },
        .{ .script = "tml2".*, .text = "ஸ்ரீ", .glyphs = &.{ 2280, 2293, 2272, 2284 } },
        .{ .script = "tml2".*, .text = "வணக்கம்", .glyphs = &.{ 2277, 2265, 2259, 2293, 2259, 2270, 2293 } },
        .{ .script = "mlm2".*, .text = "മലയാളം", .glyphs = &.{ 2358, 2362, 2359, 2372, 2363, 2317 } },
        .{ .script = "mlm2".*, .text = "കെ", .glyphs = &.{ 2379, 2333 } },
        .{ .script = "mlm2".*, .text = "കൊ", .glyphs = &.{ 2379, 2333, 2372 } },
        .{ .script = "mlm2".*, .text = "ക്ക", .glyphs = &.{9436} },
        .{ .script = "mlm2".*, .text = "ന്ത", .glyphs = &.{8393} },
        .{ .script = "mlm2".*, .text = "കൗ", .glyphs = &.{ 2333, 2387 } },
        .{ .script = "mlm2".*, .text = "ക്ഷ", .glyphs = &.{8099} },
    };
    var failed: usize = 0;
    for (cases) |case| {
        var with = (try font.substitution(gpa, .{ .script = case.script })) orelse return error.TestExpectedSubstitution;
        defer with.deinit(gpa);
        var text: std.ArrayList(u21) = .empty;
        defer text.deinit(gpa);
        var characters = Utf8Iterator{ .bytes = case.text };
        while (characters.next()) |codepoint| try text.append(gpa, codepoint);
        var glyphs: std.ArrayList(opentype.Glyph) = .empty;
        defer glyphs.deinit(gpa);
        _ = try with.run(gpa, text.items, &glyphs);
        var same = glyphs.items.len == case.glyphs.len;
        if (same) for (glyphs.items, case.glyphs) |shaped, expected| {
            if (shaped.id != expected) same = false;
        };
        if (!same) {
            failed += 1;
            std.debug.print("indic: {s} {s}: expected {any}, got", .{ case.script, case.text, case.glyphs });
            for (glyphs.items) |shaped| std.debug.print(" {d}", .{shaped.id});
            std.debug.print("\n", .{});
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failed);
}

test "scripts tested with the repository's own fonts come out as a full shaper gives them" {
    const gpa = std.testing.allocator;
    const Case = struct {
        font: []const u8,
        script: opentype.Tag,
        text: []const u8,
        /// HarfBuzz 13.2 output with that font.
        glyphs: []const u16,
    };
    const cases = [_]Case{
        .{ .font = "NotoSansTelugu-Regular.ttf", .script = "tel2".*, .text = "తెలుగు", .glyphs = &.{ 278, 51, 63, 25, 63 } },
        .{ .font = "NotoSansTelugu-Regular.ttf", .script = "tel2".*, .text = "కి", .glyphs = &.{183} },
        .{ .font = "NotoSansTelugu-Regular.ttf", .script = "tel2".*, .text = "కె", .glyphs = &.{263} },
        .{ .font = "NotoSansTelugu-Regular.ttf", .script = "tel2".*, .text = "కై", .glyphs = &.{335} },
        .{ .font = "NotoSansTelugu-Regular.ttf", .script = "tel2".*, .text = "క్క", .glyphs = &.{ 23, 917 } },
        .{ .font = "NotoSansTelugu-Regular.ttf", .script = "tel2".*, .text = "క్ష", .glyphs = &.{110} },
        .{ .font = "NotoSansTelugu-Regular.ttf", .script = "tel2".*, .text = "ర్క", .glyphs = &.{ 49, 917 } },
        .{ .font = "NotoSansTelugu-Regular.ttf", .script = "tel2".*, .text = "స్త్రీ", .glyphs = &.{ 252, 670 } },
        .{ .font = "NotoSansTelugu-Regular.ttf", .script = "tel2".*, .text = "ప్రేమ", .glyphs = &.{ 319, 633, 47 } },
        .{ .font = "NotoSansTelugu-Regular.ttf", .script = "tel2".*, .text = "విద్య", .glyphs = &.{ 213, 40, 932 } },
        .{ .font = "NotoSansTelugu-Regular.ttf", .script = "tel2".*, .text = "కృ", .glyphs = &.{ 23, 65 } },
        .{ .font = "NotoSansTelugu-Regular.ttf", .script = "tel2".*, .text = "కం", .glyphs = &.{ 23, 6 } },
        .{ .font = "NotoSansTelugu-Regular.ttf", .script = "tel2".*, .text = "క్కి", .glyphs = &.{ 183, 917 } },
        .{ .font = "NotoSansTelugu-Regular.ttf", .script = "tel2".*, .text = "క్కు", .glyphs = &.{ 23, 63, 917 } },
        .{ .font = "NotoSansTelugu-Regular.ttf", .script = "tel2".*, .text = "క్కృ", .glyphs = &.{ 23, 917, 584 } },
        .{ .font = "NotoSansTelugu-Regular.ttf", .script = "tel2".*, .text = "నమస్కారం", .glyphs = &.{ 42, 47, 180, 917, 49, 6 } },
        .{ .font = "NotoSansTelugu-Regular.ttf", .script = "tel2".*, .text = "ఆంధ్ర", .glyphs = &.{ 10, 6, 41, 631 } },
        .{ .font = "NotoSansKannada-Regular.ttf", .script = "knd2".*, .text = "ಕನ್ನಡ", .glyphs = &.{ 23, 42, 123, 35 } },
        .{ .font = "NotoSansKannada-Regular.ttf", .script = "knd2".*, .text = "ಕಿ", .glyphs = &.{252} },
        .{ .font = "NotoSansKannada-Regular.ttf", .script = "knd2".*, .text = "ಕೀ", .glyphs = &.{ 252, 77 } },
        .{ .font = "NotoSansKannada-Regular.ttf", .script = "knd2".*, .text = "ಕೊ", .glyphs = &.{ 286, 64 } },
        .{ .font = "NotoSansKannada-Regular.ttf", .script = "knd2".*, .text = "ಕೋ", .glyphs = &.{ 286, 64, 77 } },
        .{ .font = "NotoSansKannada-Regular.ttf", .script = "knd2".*, .text = "ಕೈ", .glyphs = &.{ 286, 78 } },
        .{ .font = "NotoSansKannada-Regular.ttf", .script = "knd2".*, .text = "ಕ್ಕ", .glyphs = &.{ 23, 104 } },
        .{ .font = "NotoSansKannada-Regular.ttf", .script = "knd2".*, .text = "ರ್ಕ", .glyphs = &.{ 23, 99 } },
        .{ .font = "NotoSansKannada-Regular.ttf", .script = "knd2".*, .text = "ರ್ಕಿ", .glyphs = &.{ 252, 99 } },
        .{ .font = "NotoSansKannada-Regular.ttf", .script = "knd2".*, .text = "ಸ್ತ್ರೀ", .glyphs = &.{ 282, 355, 77 } },
        .{ .font = "NotoSansKannada-Regular.ttf", .script = "knd2".*, .text = "ಕ್ಷ", .glyphs = &.{331} },
        .{ .font = "NotoSansKannada-Regular.ttf", .script = "knd2".*, .text = "ಕಂ", .glyphs = &.{ 23, 6 } },
        .{ .font = "NotoSansKannada-Regular.ttf", .script = "knd2".*, .text = "ರ್ಕ್ಕ", .glyphs = &.{ 23, 104, 99 } },
        .{ .font = "NotoSansKannada-Regular.ttf", .script = "knd2".*, .text = "ರ್ಕೋ", .glyphs = &.{ 286, 64, 77, 99 } },
        .{ .font = "NotoSansKannada-Regular.ttf", .script = "knd2".*, .text = "ರ್ಕ್ಕೀ", .glyphs = &.{ 252, 104, 77, 99 } },
        .{ .font = "NotoSansKannada-Regular.ttf", .script = "knd2".*, .text = "ರ್ಕಂ", .glyphs = &.{ 23, 99, 6 } },
        .{ .font = "NotoSansKannada-Regular.ttf", .script = "knd2".*, .text = "ಕ್ರ", .glyphs = &.{ 23, 130 } },
        .{ .font = "NotoSansKannada-Regular.ttf", .script = "knd2".*, .text = "ನಮಸ್ಕಾರ", .glyphs = &.{ 42, 47, 210, 60, 104, 49 } },
        .{ .font = "NotoSansKannada-Regular.ttf", .script = "knd2".*, .text = "ಕರ್ನಾಟಕ", .glyphs = &.{ 23, 197, 60, 99, 33, 23 } },
        .{ .font = "NotoSansSinhala-Regular.ttf", .script = "sinh".*, .text = "ශ්‍රී", .glyphs = &.{ 58, 130, 96 } },
        .{ .font = "NotoSansSinhala-Regular.ttf", .script = "sinh".*, .text = "කි", .glyphs = &.{ 23, 88 } },
        .{ .font = "NotoSansSinhala-Regular.ttf", .script = "sinh".*, .text = "කෙ", .glyphs = &.{ 114, 23 } },
        .{ .font = "NotoSansSinhala-Regular.ttf", .script = "sinh".*, .text = "කො", .glyphs = &.{ 114, 23, 82 } },
        .{ .font = "NotoSansSinhala-Regular.ttf", .script = "sinh".*, .text = "කෝ", .glyphs = &.{ 114, 23, 133 } },
        .{ .font = "NotoSansSinhala-Regular.ttf", .script = "sinh".*, .text = "කෞ", .glyphs = &.{ 114, 23, 120 } },
        .{ .font = "NotoSansSinhala-Regular.ttf", .script = "sinh".*, .text = "ක්‍ර", .glyphs = &.{ 23, 130 } },
        .{ .font = "NotoSansSinhala-Regular.ttf", .script = "sinh".*, .text = "ක්‍ය", .glyphs = &.{ 23, 126 } },
        .{ .font = "NotoSansSinhala-Regular.ttf", .script = "sinh".*, .text = "ර්‍ක", .glyphs = &.{ 23, 124 } },
        .{ .font = "NotoSansSinhala-Regular.ttf", .script = "sinh".*, .text = "සිංහල", .glyphs = &.{ 60, 85, 64, 61, 56 } },
        .{ .font = "NotoSansSinhala-Regular.ttf", .script = "sinh".*, .text = "ර්‍කි", .glyphs = &.{ 23, 124, 88 } },
        .{ .font = "NotoSansSinhala-Regular.ttf", .script = "sinh".*, .text = "ර්‍කො", .glyphs = &.{ 114, 23, 124, 82 } },
        .{ .font = "NotoSansSinhala-Regular.ttf", .script = "sinh".*, .text = "ර්‍කං", .glyphs = &.{ 23, 124, 64 } },
        .{ .font = "NotoSansSinhala-Regular.ttf", .script = "sinh".*, .text = "ක්‍රි", .glyphs = &.{ 23, 130, 88 } },
        .{ .font = "NotoSansSinhala-Regular.ttf", .script = "sinh".*, .text = "ක්‍රෙ", .glyphs = &.{ 114, 23, 130 } },
        .{ .font = "NotoSansSinhala-Regular.ttf", .script = "sinh".*, .text = "ක්‍යො", .glyphs = &.{ 114, 23, 126, 82 } },
        .{ .font = "NotoSansSinhala-Regular.ttf", .script = "sinh".*, .text = "කෛ", .glyphs = &.{ 116, 23 } },
        .{ .font = "NotoSansSinhala-Regular.ttf", .script = "sinh".*, .text = "ක්‍ෂ", .glyphs = &.{67} },
        .{ .font = "NotoSansSinhala-Regular.ttf", .script = "sinh".*, .text = "න්‍ද", .glyphs = &.{76} },
        .{ .font = "NotoSansSinhala-Regular.ttf", .script = "sinh".*, .text = "ර්ක", .glyphs = &.{ 153, 23 } },
        .{ .font = "NotoSansSinhala-Regular.ttf", .script = "sinh".*, .text = "කෘ", .glyphs = &.{ 23, 113 } },
        .{ .font = "NotoSansSinhala-Regular.ttf", .script = "sinh".*, .text = "ද්‍ව", .glyphs = &.{74} },
        .{ .font = "NotoSansSinhala-Regular.ttf", .script = "sinh".*, .text = "ආයුබෝවන්", .glyphs = &.{ 6, 54, 107, 114, 50, 133, 57, 46, 79 } },
        .{ .font = "NotoSansSinhala-Regular.ttf", .script = "sinh".*, .text = "ක්ර", .glyphs = &.{ 23, 79, 55 } },
        .{ .font = "NotoSansKhmer-Regular.ttf", .script = "khmr".*, .text = "ខ្មែរ", .glyphs = &.{ 108, 26, 192, 54 } },
        .{ .font = "NotoSansKhmer-Regular.ttf", .script = "khmr".*, .text = "កា", .glyphs = &.{212} },
        .{ .font = "NotoSansKhmer-Regular.ttf", .script = "khmr".*, .text = "កេ", .glyphs = &.{ 107, 25 } },
        .{ .font = "NotoSansKhmer-Regular.ttf", .script = "khmr".*, .text = "កៃ", .glyphs = &.{ 109, 25 } },
        .{ .font = "NotoSansKhmer-Regular.ttf", .script = "khmr".*, .text = "កោ", .glyphs = &.{ 107, 212 } },
        .{ .font = "NotoSansKhmer-Regular.ttf", .script = "khmr".*, .text = "កៅ", .glyphs = &.{ 107, 213 } },
        .{ .font = "NotoSansKhmer-Regular.ttf", .script = "khmr".*, .text = "កើ", .glyphs = &.{ 107, 25, 85 } },
        .{ .font = "NotoSansKhmer-Regular.ttf", .script = "khmr".*, .text = "កឿ", .glyphs = &.{ 107, 25, 99 } },
        .{ .font = "NotoSansKhmer-Regular.ttf", .script = "khmr".*, .text = "កៀ", .glyphs = &.{ 107, 25, 103 } },
        .{ .font = "NotoSansKhmer-Regular.ttf", .script = "khmr".*, .text = "ក្រ", .glyphs = &.{ 196, 25 } },
        .{ .font = "NotoSansKhmer-Regular.ttf", .script = "khmr".*, .text = "ក្ក", .glyphs = &.{ 25, 159 } },
        .{ .font = "NotoSansKhmer-Regular.ttf", .script = "khmr".*, .text = "ស្ត្រី", .glyphs = &.{ 196, 59, 180, 85 } },
        .{ .font = "NotoSansKhmer-Regular.ttf", .script = "khmr".*, .text = "ក្រុង", .glyphs = &.{ 196, 25, 92, 29 } },
        .{ .font = "NotoSansKhmer-Regular.ttf", .script = "khmr".*, .text = "ភាសា", .glyphs = &.{ 262, 278 } },
        .{ .font = "NotoSansKhmer-Regular.ttf", .script = "khmr".*, .text = "កំ", .glyphs = &.{ 25, 113 } },
        .{ .font = "NotoSansKhmer-Regular.ttf", .script = "khmr".*, .text = "ក៉", .glyphs = &.{ 25, 117 } },
        .{ .font = "NotoSansKhmer-Regular.ttf", .script = "khmr".*, .text = "ព្រះ", .glyphs = &.{ 196, 50, 115 } },
        .{ .font = "NotoSansKhmer-Regular.ttf", .script = "khmr".*, .text = "សួស្តី", .glyphs = &.{ 59, 95, 59, 180, 85 } },
        .{ .font = "NotoSansKhmer-Regular.ttf", .script = "khmr".*, .text = "ក្រេ", .glyphs = &.{ 107, 196, 25 } },
        .{ .font = "NotoSansKhmer-Regular.ttf", .script = "khmr".*, .text = "កម្ពុជា", .glyphs = &.{ 25, 52, 189, 91, 226 } },
        .{ .font = "NotoSansKhmer-Regular.ttf", .script = "khmr".*, .text = "ភ្នំពេញ", .glyphs = &.{ 51, 185, 113, 107, 50, 34 } },
        .{ .font = "NotoSansKhmer-Regular.ttf", .script = "khmr".*, .text = "ប៉ុន្តែ", .glyphs = &.{ 46, 117, 91, 108, 45, 180 } },
        .{ .font = "NotoSansKhmer-Regular.ttf", .script = "khmr".*, .text = "ស៊ី", .glyphs = &.{ 59, 91, 85 } },
        .{ .font = "NotoSansMyanmar-Regular.ttf", .script = "mym2".*, .text = "မြန်မာ", .glyphs = &.{ 47, 29, 24, 381, 29, 368 } },
        .{ .font = "NotoSansMyanmar-Regular.ttf", .script = "mym2".*, .text = "ကေ", .glyphs = &.{ 372, 4 } },
        .{ .font = "NotoSansMyanmar-Regular.ttf", .script = "mym2".*, .text = "ကြ", .glyphs = &.{ 198, 4 } },
        .{ .font = "NotoSansMyanmar-Regular.ttf", .script = "mym2".*, .text = "ကျ", .glyphs = &.{ 4, 382 } },
        .{ .font = "NotoSansMyanmar-Regular.ttf", .script = "mym2".*, .text = "ကြေ", .glyphs = &.{ 372, 198, 4 } },
        .{ .font = "NotoSansMyanmar-Regular.ttf", .script = "mym2".*, .text = "က္က", .glyphs = &.{ 4, 211 } },
        .{ .font = "NotoSansMyanmar-Regular.ttf", .script = "mym2".*, .text = "င်္က", .glyphs = &.{ 4, 189 } },
        .{ .font = "NotoSansMyanmar-Regular.ttf", .script = "mym2".*, .text = "ကို", .glyphs = &.{ 4, 369, 209 } },
        .{ .font = "NotoSansMyanmar-Regular.ttf", .script = "mym2".*, .text = "ကော", .glyphs = &.{ 372, 4, 368 } },
        .{ .font = "NotoSansMyanmar-Regular.ttf", .script = "mym2".*, .text = "ကွ", .glyphs = &.{ 4, 48 } },
        .{ .font = "NotoSansMyanmar-Regular.ttf", .script = "mym2".*, .text = "ကှ", .glyphs = &.{ 4, 384 } },
        .{ .font = "NotoSansMyanmar-Regular.ttf", .script = "mym2".*, .text = "ကျွန်", .glyphs = &.{ 4, 366, 24, 381 } },
        .{ .font = "NotoSansMyanmar-Regular.ttf", .script = "mym2".*, .text = "သင်္ဘော", .glyphs = &.{ 34, 372, 28, 189, 368 } },
        .{ .font = "NotoSansMyanmar-Regular.ttf", .script = "mym2".*, .text = "မင်္ဂလာပါ", .glyphs = &.{ 29, 6, 189, 32, 368, 25, 367 } },
        .{ .font = "NotoSansMyanmar-Regular.ttf", .script = "mym2".*, .text = "ပြည်", .glyphs = &.{ 47, 25, 14, 381 } },
        .{ .font = "NotoSansMyanmar-Regular.ttf", .script = "mym2".*, .text = "ကံ", .glyphs = &.{ 4, 377 } },
        .{ .font = "NotoSansMyanmar-Regular.ttf", .script = "mym2".*, .text = "က့", .glyphs = &.{ 4, 378 } },
        .{ .font = "NotoSansMyanmar-Regular.ttf", .script = "mym2".*, .text = "ဗမာ", .glyphs = &.{ 27, 29, 368 } },
        .{ .font = "NotoSansMyanmar-Regular.ttf", .script = "mym2".*, .text = "ကျေးဇူး", .glyphs = &.{ 372, 4, 382, 379, 11, 360, 379 } },
        .{ .font = "NotoSansMyanmar-Regular.ttf", .script = "mym2".*, .text = "နိုင်ငံ", .glyphs = &.{ 262, 369, 209, 8, 381, 8, 377 } },
        .{ .font = "NotoSansMyanmar-Regular.ttf", .script = "mym2".*, .text = "စက္ကူ", .glyphs = &.{ 9, 4, 211, 361, 610 } },
        .{ .font = "NotoNastaliqUrdu-Regular.ttf", .script = "arab".*, .text = "سلام", .glyphs = &.{ 951, 188, 953, 399, 4, 436 } },
        .{ .font = "NotoNastaliqUrdu-Regular.ttf", .script = "arab".*, .text = "محمد", .glyphs = &.{ 951, 458, 966, 97, 439, 127 } },
        .{ .font = "NotoNastaliqUrdu-Regular.ttf", .script = "arab".*, .text = "اردو", .glyphs = &.{ 3, 143, 126, 551 } },
        .{ .font = "NotoNastaliqUrdu-Regular.ttf", .script = "arab".*, .text = "پاکستان", .glyphs = &.{ 951, 39, 787, 952, 5, 951, 365, 959, 178, 18, 776, 5, 468, 769 } },
        .{ .font = "NotoNastaliqUrdu-Regular.ttf", .script = "arab".*, .text = "کتاب", .glyphs = &.{ 951, 365, 954, 18, 776, 5, 14, 767 } },
        .{ .font = "NotoNastaliqUrdu-Regular.ttf", .script = "arab".*, .text = "ہے", .glyphs = &.{ 948, 507, 949, 960, 596 } },
        .{ .font = "NotoNastaliqUrdu-Regular.ttf", .script = "arab".*, .text = "میں", .glyphs = &.{ 951, 451, 958, 22, 780, 469 } },
        .{ .font = "NotoNastaliqUrdu-Regular.ttf", .script = "arab".*, .text = "اللہ", .glyphs = &.{ 3, 951, 414, 953, 400, 504 } },
        .{ .font = "NotoNastaliqUrdu-Regular.ttf", .script = "arab".*, .text = "بِسْمِ", .glyphs = &.{ 951, 43, 767, 824, 966, 181, 826, 437, 824 } },
        .{ .font = "NotoSerifTibetan-Regular.ttf", .script = "tibt".*, .text = "བོད", .glyphs = &.{ 27, 1341, 22 } },
        .{ .font = "NotoSerifTibetan-Regular.ttf", .script = "tibt".*, .text = "བཀྲ་ཤིས", .glyphs = &.{ 27, 180, 1261, 41, 1328, 43 } },
        .{ .font = "NotoSerifTibetan-Regular.ttf", .script = "tibt".*, .text = "སྐད", .glyphs = &.{ 1088, 22 } },
        .{ .font = "NotoSerifTibetan-Regular.ttf", .script = "tibt".*, .text = "རྒྱལ", .glyphs = &.{ 849, 40 } },
        .{ .font = "NotoSerifTibetan-Regular.ttf", .script = "tibt".*, .text = "བསྒྲུབས", .glyphs = &.{ 27, 1103, 27, 43 } },
        .{ .font = "NotoSerifTibetan-Regular.ttf", .script = "tibt".*, .text = "ཧཱུྃ", .glyphs = &.{ 1180, 1351 } },
        .{ .font = "NotoSansJavanese-Regular.ttf", .script = "java".*, .text = "ꦗꦮ", .glyphs = &.{ 32, 57 } },
        .{ .font = "NotoSansJavanese-Regular.ttf", .script = "java".*, .text = "ꦏꦺ", .glyphs = &.{ 92, 24 } },
        .{ .font = "NotoSansJavanese-Regular.ttf", .script = "java".*, .text = "ꦏꦺꦴ", .glyphs = &.{ 92, 24, 78 } },
        .{ .font = "NotoSansJavanese-Regular.ttf", .script = "java".*, .text = "ꦏꦿ", .glyphs = &.{162} },
        .{ .font = "NotoSansJavanese-Regular.ttf", .script = "java".*, .text = "ꦏ꧀ꦏ", .glyphs = &.{ 24, 257 } },
        .{ .font = "NotoSansJavanese-Regular.ttf", .script = "java".*, .text = "ꦲꦏ꧀ꦱꦫ", .glyphs = &.{ 61, 24, 293, 54 } },
        .{ .font = "NotoSansJavanese-Regular.ttf", .script = "java".*, .text = "ꦏꦶ", .glyphs = &.{ 24, 80 } },
        .{ .font = "NotoSansJavanese-Regular.ttf", .script = "java".*, .text = "ꦱꦸꦒꦼꦁ", .glyphs = &.{ 60, 88, 27, 96 } },
        .{ .font = "NotoSansMongolian-Regular.ttf", .script = "mong".*, .text = "ᠮᠣᠩᠭᠣᠯ", .glyphs = &.{ 1631, 1186, 1261, 1186, 1638 } },
        .{ .font = "NotoSansMongolian-Regular.ttf", .script = "mong".*, .text = "ᠮᠣ", .glyphs = &.{ 1631, 1185 } },
        .{ .font = "NotoSansMongolian-Regular.ttf", .script = "mong".*, .text = "ᠠ", .glyphs = &.{1141} },
        .{ .font = "NotoSansMongolian-Regular.ttf", .script = "mong".*, .text = "ᠪᠢᠴᠢᠭ", .glyphs = &.{ 1284, 1679, 1178, 1520 } },
        .{ .font = "NotoSansMongolian-Regular.ttf", .script = "mong".*, .text = "ᠬᠡᠯᠡ", .glyphs = &.{ 1443, 1641, 1162 } },
    };
    var failed: usize = 0;
    for (cases) |case| {
        var path_buffer: [128]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "examples/assets/fonts/{s}", .{case.font});
        const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, gpa, .unlimited);
        defer gpa.free(bytes);
        const tables = try Tables.init(bytes);
        const layout = try opentype.Layout.init(bytes, tables.gsub.?, tables.gdef);
        var with = (try Font.shapingFor(gpa, tables, layout, .{ .script = case.script })) orelse return error.TestExpectedSubstitution;
        defer with.deinit(gpa);
        var text: std.ArrayList(u21) = .empty;
        defer text.deinit(gpa);
        var characters = Utf8Iterator{ .bytes = case.text };
        while (characters.next()) |codepoint| try text.append(gpa, codepoint);
        var glyphs: std.ArrayList(opentype.Glyph) = .empty;
        defer glyphs.deinit(gpa);
        _ = try with.run(gpa, text.items, &glyphs);
        var same = glyphs.items.len == case.glyphs.len;
        if (same) for (glyphs.items, case.glyphs) |shaped, expected| {
            if (shaped.id != expected) same = false;
        };
        if (!same) {
            failed += 1;
            std.debug.print("shaping: {s} {s}: expected {any}, got", .{ case.script, case.text, case.glyphs });
            for (glyphs.items) |shaped| std.debug.print(" {d}", .{shaped.id});
            std.debug.print("\n", .{});
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failed);
}

test "a cursive script is spaced and stepped as a full shaper does it" {
    const gpa = std.testing.allocator;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "examples/assets/fonts/NotoNastaliqUrdu-Regular.ttf", gpa, .unlimited);
    defer gpa.free(bytes);
    var font = try load(gpa, bytes, &.{.{ 32, 126 }});
    defer font.deinit();
    const Case = struct {
        text: []const u8,
        /// Contextual advance per glyph, in logical order, in font units:
        /// HarfBuzz
        /// 13.2 with and without `kern` and `dist`.
        advances: []const i32,
        /// Height above the baseline of each letter (not mark), left to right,
        /// in
        /// font units, from HarfBuzz.
        rises: []const f32,
    };
    const cases = [_]Case{
        .{ .text = "سلام", .advances = &.{ 0, 0, 0, 0, 0, 0 }, .rises = &.{ 0, 0, 0, 95 } },
        .{ .text = "محمد", .advances = &.{ 0, 0, 0, 0, 0, 0 }, .rises = &.{ 0, 0, 321, 696 } },
        .{ .text = "پاکستان", .advances = &.{ 0, 0, 0, 0, 0, 0, -20, 0, 0, 0, 0, 0, 0, 0 }, .rises = &.{ 0, 0, 0, 145, 361, 0, 0 } },
        .{ .text = "کتاب میں", .advances = &.{ 0, 0, 0, 0, 0, 0, 0, 0, -50, 0, 0, 0, 0, 0, 0 }, .rises = &.{ 0, 335, 304, 0, 0, 0, 0, 145 } },
        .{ .text = "بِسْمِ", .advances = &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0 }, .rises = &.{ 0, 573, 761 } },
    };
    const shaping = Shaping{ .script = "arab".* };
    for (cases) |case| {
        var text: std.ArrayList(u21) = .empty;
        defer text.deinit(gpa);
        var characters = Utf8Iterator{ .bytes = case.text };
        while (characters.next()) |codepoint| try text.append(gpa, codepoint);

        var with = (try font.substitution(gpa, shaping)) orelse return error.TestExpectedSubstitution;
        defer with.deinit(gpa);
        var glyphs: std.ArrayList(opentype.Glyph) = .empty;
        defer glyphs.deinit(gpa);
        _ = try with.run(gpa, text.items, &glyphs);
        try std.testing.expectEqual(case.advances.len, glyphs.items.len);
        for (glyphs.items, case.advances) |shaped, expected| try std.testing.expectEqual(expected, shaped.advance);

        var missing: std.ArrayList(u21) = .empty;
        defer missing.deinit(gpa);
        for (text.items) |codepoint| {
            if (!font.has(codepoint)) try missing.append(gpa, codepoint);
        }
        try font.missingSubstitutes(gpa, text.items, shaping, &missing);
        if (try font.extend(missing.items)) |next| font.adopt(next);
        var drawn: std.ArrayList(u21) = .empty;
        defer drawn.deinit(gpa);
        try std.testing.expect(try font.substituteWith(gpa, text.items, &with, &drawn));
        var rise: f32 = 0;
        var left: ?u21 = null;
        var letter: usize = 0;
        var index = drawn.items.len;
        while (index > 0) {
            index -= 1;
            const codepoint = drawn.items[index];
            if (spacingOf(codepoint) != null or nameKind(codepoint) == .rtl_mark and codepoint >= glyph_codepoints_rtl_mark) continue;
            if (codepoint >= 0x610 and codepoint <= 0x65f) continue;
            if (left) |before| {
                if (font.cursive(before, codepoint)) |join| rise += join[1] else rise = 0;
            }
            left = codepoint;
            try std.testing.expect(letter < case.rises.len);
            try std.testing.expectApproxEqAbs(case.rises[letter] / 1000.0, rise, 0.0015);
            letter += 1;
        }
        try std.testing.expectEqual(case.rises.len, letter);
    }
}

test "marks on a ligature go on the part they were typed after" {
    const gpa = std.testing.allocator;
    var font = try load(gpa, @embedFile("../render/fonts/DejaVuSans.ttf"), &.{ .{ 32, 126 }, .{ 0x600, 0x6ff }, .{ 0xfe70, 0xfeff } });
    defer font.deinit();
    var with = (try font.substitution(gpa, .{ .script = "arab".* })) orelse return error.TestExpectedSubstitution;
    defer with.deinit(gpa);
    const text = [_]u21{ 0x644, 0x64e, 0x627, 0x64e };
    var glyphs: std.ArrayList(opentype.Glyph) = .empty;
    defer glyphs.deinit(gpa);
    _ = try with.run(gpa, &text, &glyphs);
    try std.testing.expectEqual(@as(usize, 3), glyphs.items.len);
    try std.testing.expectEqual(@as(u8, 1), glyphs.items[1].component);
    try std.testing.expectEqual(@as(u8, 0), glyphs.items[2].component);
    var shaped: std.ArrayList(u21) = .empty;
    defer shaped.deinit(gpa);
    try std.testing.expect(try font.substituteWith(gpa, &text, &with, &shaped));
    try std.testing.expectEqual(@as(usize, 5), shaped.items.len);
    try std.testing.expectEqual(@as(?u8, 1), componentOf(shaped.items[1]));
    try std.testing.expectEqual(@as(?u8, 255), componentOf(shaped.items[3]));
    const ligature = shaped.items[0];
    const on_lam = font.markPlacement(ligature, 1, null, .{ 0, 0 }, shaped.items[2]) orelse return error.TestExpectedMark;
    const on_alef = font.markPlacement(ligature, 255, null, .{ 0, 0 }, shaped.items[4]) orelse return error.TestExpectedMark;
    try std.testing.expectApproxEqAbs(@as(f32, 355.0 / 2048.0), on_lam[0], 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 450.0 / 2048.0), on_lam[1], 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, -362.0 / 2048.0), on_alef[0], 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 300.0 / 2048.0), on_alef[1], 1e-3);
}
