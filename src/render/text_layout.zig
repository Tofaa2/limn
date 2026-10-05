//! Turns one line of text from the order it is typed in into the glyphs
//! that are drawn, left to right:
//!
//!  * Latin f-ligatures (ff, fi, fl, ffi, ffl) where the font has them;
//!  * Arabic letters take their isolated, initial, medial or final shape
//!    from their neighbours, and lam + alef fuse;
//!  * right-to-left runs (Hebrew, Arabic) are reversed in place, with
//!    numbers inside them kept left to right and brackets mirrored.
//!
//! Shapes are chosen through Unicode's precomposed "presentation form"
//! code points rather than the font's own substitution tables, so it works
//! with any font that carries those glyphs (most do) and needs no shaping
//! engine. It does not do the font-specific substitutions and mark
//! positioning a full shaper would, nor scripts that need reordering
//! (Indic, Thai).
const std = @import("std");

/// True if `text` contains anything `shapeLine` would change. Plain text
/// can skip it.
pub fn needsShaping(text: []const u8) bool {
    for (text, 0..) |byte, index| {
        if (byte >= 0xd6) return true; // Hebrew starts at U+0590 (0xD6 0x90)
        if (byte == 'f' and index + 1 < text.len) switch (text[index + 1]) {
            'f', 'i', 'l' => return true,
            else => {},
        };
    }
    return false;
}

/// `control` is an embedding marker: it has a level but takes no part in
/// working out directions.
/// `separator` (plus, minus), `common_separator` (comma, full stop, colon,
/// slash) and `terminator` (percent and currency signs) are what the
/// bidirectional algorithm calls weak types: they become part of a number
/// they touch and are neutral otherwise.
const Class = enum { left, right, arabic, number, arabic_number, neutral, control, separator, common_separator, terminator };

// The explicit direction controls of the Unicode bidirectional algorithm.
const lre = 0x202a;
const rle = 0x202b;
const pdf = 0x202c;
const lro = 0x202d;
const rlo = 0x202e;
const lri = 0x2066;
const rli = 0x2067;
const fsi = 0x2068;
const pdi = 0x2069;
/// Deepest nesting of embeddings and isolates that is honoured.
const max_embedding = 32;

fn isIsolateStart(c: u21) bool {
    return c == lri or c == rli or c == fsi;
}

/// Marks and controls that steer direction and have no glyph.
fn isInvisible(c: u21) bool {
    return switch (c) {
        0x200e, 0x200f, 0x061c, lre...rlo, lri...pdi => true,
        else => false,
    };
}

/// Whether the first strong character of an isolate, whose content
/// `rest` starts with, is a right-to-left one. Nested isolates do not
/// count.
fn firstStrongIsRight(rest: []const u21) bool {
    var nested: u32 = 0;
    for (rest) |c| {
        if (isIsolateStart(c)) {
            nested += 1;
        } else if (c == pdi) {
            if (nested == 0) return false;
            nested -= 1;
        } else if (nested == 0) switch (classOf(c)) {
            .left => return false,
            .right, .arabic => return true,
            else => {},
        };
    }
    return false;
}

fn classOf(c: u21) Class {
    switch (c) {
        '+', '-' => return .separator,
        ',', '.', '/', ':', 0xa0, 0x060c, 0x202f => return .common_separator,
        '#', '$', '%', 0xa2...0xa5, 0xb0, 0xb1, 0x066a, 0x2030...0x2034, 0x20a0...0x20cf => return .terminator,
        else => {},
    }
    return switch (c) {
        // The invisible direction marks: strong characters with no glyph.
        0x200e => .left,
        0x200f => .right,
        '0'...'9' => .number,
        0x0660...0x0669, 0x066b, 0x066c => .arabic_number,
        // The last plane names glyphs of right-to-left scripts that have
        // no character of their own (`font.glyph_codepoints_rtl`).
        // (0xc8000 and up: changes of spacing in right-to-left text,
        // `font.spacing_codepoints`.)
        0x0590...0x05ff, 0xfb1d...0xfb4f, 0x100000...0x10ffff, 0xc8000...0xcffff => .right,
        // (0xe1100 and up: which part of a ligature a mark is on,
        // `font.component_codepoints`.)
        0x0600...0x065f, 0x066d...0x06ff, 0x0750...0x077f, 0xfb50...0xfdff, 0xfe70...0xfeff, 0xd0000...0xdffff, 0xe1100...0xe11ff => .arabic,
        0...0x2f, 0x3a...0x40, 0x5b...0x60, 0x7b...0xbf, 0x2000...0x200d, 0x2010...0x206f => .neutral,
        else => .left,
    };
}

fn mirrored(c: u21) u21 {
    return switch (c) {
        '(' => ')',
        ')' => '(',
        '[' => ']',
        ']' => '[',
        '{' => '}',
        '}' => '{',
        '<' => '>',
        '>' => '<',
        0xab => 0xbb,
        0xbb => 0xab,
        else => c,
    };
}

const Joining = struct {
    /// Isolated presentation form; the final form follows it, and for
    /// letters with four forms the initial and medial ones after that.
    base: u21,
    forms: u3,
};

/// Arabic letters U+0621..U+064A.
const arabic_letters = [_]Joining{
    .{ .base = 0xfe80, .forms = 1 }, .{ .base = 0xfe81, .forms = 2 }, .{ .base = 0xfe83, .forms = 2 }, .{ .base = 0xfe85, .forms = 2 },
    .{ .base = 0xfe87, .forms = 2 }, .{ .base = 0xfe89, .forms = 4 }, .{ .base = 0xfe8d, .forms = 2 }, .{ .base = 0xfe8f, .forms = 4 },
    .{ .base = 0xfe93, .forms = 2 }, .{ .base = 0xfe95, .forms = 4 }, .{ .base = 0xfe99, .forms = 4 }, .{ .base = 0xfe9d, .forms = 4 },
    .{ .base = 0xfea1, .forms = 4 }, .{ .base = 0xfea5, .forms = 4 }, .{ .base = 0xfea9, .forms = 2 }, .{ .base = 0xfeab, .forms = 2 },
    .{ .base = 0xfead, .forms = 2 }, .{ .base = 0xfeaf, .forms = 2 }, .{ .base = 0xfeb1, .forms = 4 }, .{ .base = 0xfeb5, .forms = 4 },
    .{ .base = 0xfeb9, .forms = 4 }, .{ .base = 0xfebd, .forms = 4 }, .{ .base = 0xfec1, .forms = 4 }, .{ .base = 0xfec5, .forms = 4 },
    .{ .base = 0xfec9, .forms = 4 }, .{ .base = 0xfecd, .forms = 4 },
    // U+063B..U+063F are not basic letters; U+0640 is the tatweel.
    .{ .base = 0, .forms = 0 },      .{ .base = 0, .forms = 0 },
    .{ .base = 0, .forms = 0 },      .{ .base = 0, .forms = 0 },      .{ .base = 0, .forms = 0 },      .{ .base = 0x0640, .forms = 0 },
    .{ .base = 0xfed1, .forms = 4 }, .{ .base = 0xfed5, .forms = 4 }, .{ .base = 0xfed9, .forms = 4 }, .{ .base = 0xfedd, .forms = 4 },
    .{ .base = 0xfee1, .forms = 4 }, .{ .base = 0xfee5, .forms = 4 }, .{ .base = 0xfee9, .forms = 4 }, .{ .base = 0xfeed, .forms = 2 },
    .{ .base = 0xfeef, .forms = 2 }, .{ .base = 0xfef1, .forms = 4 },
};

fn joining(c: u21) ?Joining {
    if (c < 0x0621 or c > 0x064a) return null;
    const entry = arabic_letters[c - 0x0621];
    return if (entry.base == 0) null else entry;
}

fn isTatweel(c: u21) bool {
    return c == 0x0640;
}

/// Marks sit on a letter and do not interrupt joining.
fn isArabicMark(c: u21) bool {
    // The last range names mark glyphs that have no character of their
    // own (`font.glyph_codepoints_rtl_mark`).
    return (c >= 0x064b and c <= 0x065f) or c == 0x0670 or (c >= 0xd0000 and c <= 0xdffff);
}

/// Can `c` connect to the letter after it?
fn joinsForward(c: u21) bool {
    if (isTatweel(c)) return true;
    const entry = joining(c) orelse return false;
    return entry.forms == 4;
}

/// Can `c` connect to the letter before it?
fn joinsBackward(c: u21) bool {
    if (isTatweel(c)) return true;
    const entry = joining(c) orelse return false;
    return entry.forms >= 2;
}

fn lamAlef(alef: u21) ?u21 {
    return switch (alef) {
        0x0622 => 0xfef5,
        0x0623 => 0xfef7,
        0x0625 => 0xfef9,
        0x0627 => 0xfefb,
        else => null,
    };
}

/// The script a character belongs to, as OpenType names it. Null for what
/// has none of its own (spaces, digits, punctuation, combining marks) and
/// goes with its neighbours.
pub fn scriptOf(c: u21) ?[4]u8 {
    return switch (c) {
        'A'...'Z', 'a'...'z', 0xaa, 0xba, 0xc0...0xd6, 0xd8...0xf6, 0xf8...0x2af, 0x1e00...0x1eff, 0x2c60...0x2c7f, 0xa720...0xa7ff, 0xfb00...0xfb06 => "latn".*,
        0x370...0x3ff, 0x1f00...0x1fff => "grek".*,
        0x400...0x52f, 0x1c80...0x1c8f, 0x2de0...0x2dff, 0xa640...0xa69f => "cyrl".*,
        0x531...0x58f => "armn".*,
        0x591...0x5f4 => "hebr".*,
        0x600...0x6ff, 0x750...0x77f, 0x8a0...0x8ff, 0xfb50...0xfdff, 0xfe70...0xfeff => "arab".*,
        0x900...0x97f => "dev2".*,
        0x980...0x9ff => "bng2".*,
        0xa00...0xa7f => "gur2".*,
        0xa80...0xaff => "gjr2".*,
        0xb00...0xb7f => "ory2".*,
        0xb80...0xbff => "tml2".*,
        0xc00...0xc7f => "tel2".*,
        0xc80...0xcff => "knd2".*,
        0xd00...0xd7f => "mlm2".*,
        0xd80...0xdff => "sinh".*,
        0xe00...0xe7f => "thai".*,
        0xf00...0xfff => "tibt".*,
        0x1000...0x109f => "mym2".*,
        0x1780...0x17ff => "khmr".*,
        0x10a0...0x10ff => "geor".*,
        0x1800...0x18af => "mong".*,
        0xa980...0xa9df => "java".*,
        else => null,
    };
}

/// Whether a line may change under a font's own substitutions: anything
/// beyond plain ASCII (accents, other scripts), or what `needsShaping`
/// already looks for.
pub fn mayBeSubstituted(text: []const u8) bool {
    for (text) |byte| {
        if (byte >= 0x80) return true;
    }
    return needsShaping(text);
}

/// A ligature found by `Coverage.ligature`: how many characters of the run
/// it stands for, and the code point drawn in their place.
pub const LigatureMatch = struct { consumed: usize, codepoint: u21 };

/// Answers whether a glyph exists for a code point, across the fonts in use.
/// The callbacks are only called during the shaping call the value is
/// passed to, so `context` need only live that long.
pub const Coverage = struct {
    /// Passed back to every callback unchanged.
    context: *const anyopaque,
    /// Whether any font in use has a glyph for `codepoint`.
    has: *const fn (context: *const anyopaque, codepoint: u21) bool,
    /// The font's own ligature at the start of a run of characters, if it
    /// has one: how many characters, and the character drawn instead.
    /// Null leaves only the built-in f-ligatures.
    ligature: ?*const fn (context: *const anyopaque, rest: []const u21) ?LigatureMatch = null,
    /// The fonts' own substitutions for a whole line, in typing order:
    /// appends to `out` the characters to draw. Null leaves the line as
    /// typed.
    substitute: ?*const fn (context: *const anyopaque, gpa: std.mem.Allocator, line: []const u21, out: *std.ArrayList(u21)) anyerror!void = null,

    fn covers(self: Coverage, codepoint: u21) bool {
        return self.has(self.context, codepoint);
    }
};

/// Thai and Lao write one vowel (sara am) as a single character that is
/// drawn as two: a ring above the consonant and a letter after it. The
/// ring belongs under any tone mark typed before the vowel, so it goes in
/// front of those.
fn splitSaraAm(gpa: std.mem.Allocator, out: *std.ArrayList(u21), start: usize) !void {
    var index = start;
    while (index < out.items.len) : (index += 1) {
        const c = out.items[index];
        const lao = c == 0x0eb3;
        if (c != 0x0e33 and !lao) continue;
        const ring: u21 = if (lao) 0x0ecd else 0x0e4d;
        out.items[index] = if (lao) 0x0eb2 else 0x0e32;
        // Back over the tone marks the vowel was typed after.
        var at = index;
        while (at > start) : (at -= 1) {
            const before = out.items[at - 1];
            const tone = if (lao) before >= 0x0ec8 and before <= 0x0ecb else before >= 0x0e48 and before <= 0x0e4b;
            if (!tone) break;
        }
        try out.insert(gpa, at, ring);
        index += 1;
    }
}

/// Decodes `text` (one line, UTF-8) and appends its glyph code points to
/// `out` in the order they are drawn from left to right.
pub fn shapeLine(gpa: std.mem.Allocator, text: []const u8, coverage: Coverage, out: *std.ArrayList(u21)) !void {
    const start = out.items.len;
    var iterator = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (nextLenient(&iterator)) |c| try out.append(gpa, c);
    try splitSaraAm(gpa, out, start);
    if (coverage.substitute) |substitute| {
        var replaced: std.ArrayList(u21) = .empty;
        defer replaced.deinit(gpa);
        try substitute(coverage.context, gpa, out.items[start..], &replaced);
        out.items.len = start;
        try out.appendSlice(gpa, replaced.items);
    }
    const line = out.items[start..];

    // Latin ligatures, in typing order.
    var write: usize = 0;
    var read: usize = 0;
    while (read < line.len) {
        const rest = line[read..];
        const Ligature = struct { sequence: []const u21, glyph: u21 };
        const ligatures = [_]Ligature{
            .{ .sequence = &.{ 'f', 'f', 'i' }, .glyph = 0xfb03 },
            .{ .sequence = &.{ 'f', 'f', 'l' }, .glyph = 0xfb04 },
            .{ .sequence = &.{ 'f', 'f' }, .glyph = 0xfb00 },
            .{ .sequence = &.{ 'f', 'i' }, .glyph = 0xfb01 },
            .{ .sequence = &.{ 'f', 'l' }, .glyph = 0xfb02 },
        };
        var replaced = false;
        // The font's own ligatures first: it knows which it has.
        if (coverage.ligature) |find| if (find(coverage.context, rest)) |match| {
            if (match.consumed >= 2 and match.consumed <= rest.len) {
                line[write] = match.codepoint;
                write += 1;
                read += match.consumed;
                continue;
            }
        };
        if (rest[0] == 'f') for (ligatures) |ligature| {
            if (std.mem.startsWith(u21, rest, ligature.sequence) and coverage.covers(ligature.glyph)) {
                line[write] = ligature.glyph;
                write += 1;
                read += ligature.sequence.len;
                replaced = true;
                break;
            }
        };
        if (!replaced) {
            line[write] = rest[0];
            write += 1;
            read += 1;
        }
    }
    out.items.len = start + write;
    var shaped = out.items[start..];

    // Arabic: pick each letter's form from what it connects to.
    var has_arabic = false;
    for (shaped) |c| if (classOf(c) == .arabic) {
        has_arabic = true;
        break;
    };
    if (has_arabic) {
        write = 0;
        read = 0;
        var previous: u21 = 0; // last letter written, in its original code
        while (read < shaped.len) {
            const c = shaped[read];
            read += 1;
            if (isArabicMark(c)) {
                shaped[write] = c;
                write += 1;
                continue;
            }
            // The next letter, looking past marks.
            var next: u21 = 0;
            var next_index = read;
            while (next_index < shaped.len and isArabicMark(shaped[next_index])) next_index += 1;
            if (next_index < shaped.len) next = shaped[next_index];

            const joins_previous = joinsForward(previous) and joinsBackward(c);
            if (c == 0x0644) if (lamAlef(next)) |ligature| {
                const glyph = ligature + @as(u21, @intFromBool(joins_previous));
                if (coverage.covers(glyph)) {
                    shaped[write] = glyph;
                    write += 1;
                    read = next_index + 1;
                    previous = next; // an alef: nothing joins after it
                    continue;
                }
            };
            var glyph = c;
            if (joining(c)) |entry| {
                const joins_next = entry.forms == 4 and joinsBackward(next);
                const form: u21 = if (joins_previous and joins_next) 3 else if (joins_previous) 1 else if (joins_next) 2 else 0;
                const candidate = entry.base + form;
                if (coverage.covers(candidate)) glyph = candidate;
            }
            shaped[write] = glyph;
            write += 1;
            previous = c;
        }
        out.items.len = start + write;
        shaped = out.items[start..];
    }

    // Direction: find the embedding level of every glyph, then reverse
    // runs from the deepest level outward.
    var any_right = false;
    for (shaped) |c| {
        // A right-to-left control can turn even Latin text around.
        if (c == rle or c == rlo or c == rli) any_right = true;
        switch (classOf(c)) {
            .right, .arabic => any_right = true,
            else => {},
        }
        if (any_right) break;
    }
    if (!any_right) {
        // Nothing to reorder; a stray mark is still not drawn.
        var kept_plain: usize = start;
        for (out.items[start..]) |c| {
            if (isInvisible(c)) continue;
            out.items[kept_plain] = c;
            kept_plain += 1;
        }
        out.items.len = kept_plain;
        return;
    }

    const levels = try gpa.alloc(u8, shaped.len);
    defer gpa.free(levels);
    const classes = try gpa.alloc(Class, shaped.len);
    defer gpa.free(classes);
    // Which run each glyph is resolved with: glyphs directly inside the
    // same embedding or isolate, not separated by a nested embedding.
    const runs = try gpa.alloc(u16, shaped.len);
    defer gpa.free(runs);

    // The line reads in the direction of its first strong character,
    // not counting what is inside isolates.
    var base: u8 = 0;
    {
        var isolates: u32 = 0;
        for (shaped) |c| {
            if (isIsolateStart(c)) {
                isolates += 1;
            } else if (c == pdi) {
                isolates -|= 1;
            } else if (isolates == 0) switch (classOf(c)) {
                .left => break,
                .right, .arabic => {
                    base = 1;
                    break;
                },
                else => {},
            };
        }
    }

    // Embeddings, overrides and isolates: each opens a deeper level until
    // it is closed, and an override also forces a direction on what it
    // holds.
    const Frame = struct { level: u8, override: ?Class, isolate: bool, run: u16 };
    var stack: [max_embedding + 1]Frame = undefined;
    var depth: usize = 0;
    // Openers past the depth limit, so that their closers are ignored too.
    var ignored: u32 = 0;
    var run_count: u16 = 1;
    stack[0] = .{ .level = base, .override = null, .isolate = false, .run = 0 };
    for (shaped, 0..) |c, at| {
        const top = stack[depth];
        levels[at] = top.level;
        runs[at] = top.run;
        switch (c) {
            lre, rle, lro, rlo, lri, rli, fsi => {
                const isolate = isIsolateStart(c);
                // An isolate stands in the text around it as one neutral
                // character; an embedding's own markers take no part.
                classes[at] = if (isolate) .neutral else .control;
                var right = c == rle or c == rlo or c == rli;
                if (c == fsi) right = firstStrongIsRight(shaped[at + 1 ..]);
                const level: u8 = if (right) (top.level + 1) | 1 else (top.level + 2) & ~@as(u8, 1);
                if (depth + 1 < stack.len) {
                    depth += 1;
                    stack[depth] = .{
                        .level = level,
                        .override = if (c == lro) .left else if (c == rlo) .right else null,
                        .isolate = isolate,
                        .run = run_count,
                    };
                    run_count += 1;
                } else ignored += 1;
            },
            pdf => {
                classes[at] = .control;
                if (ignored != 0) {
                    ignored -= 1;
                } else if (depth > 0 and !top.isolate) {
                    depth -= 1;
                    // The text around an embedding resumes as a new run.
                    stack[depth].run = run_count;
                    run_count += 1;
                }
            },
            pdi => {
                if (ignored != 0) {
                    ignored -= 1;
                } else {
                    // Closes the nearest isolate and any embedding left
                    // open inside it.
                    var open = depth;
                    while (open > 0 and !stack[open].isolate) open -= 1;
                    if (open > 0) depth = open - 1;
                }
                levels[at] = stack[depth].level;
                runs[at] = stack[depth].run;
                classes[at] = .neutral;
            },
            else => classes[at] = top.override orelse classOf(c),
        }
    }

    // Within each run: letters set the direction, numbers read left to
    // right even inside right-to-left text, and neutrals between two
    // stretches of the same direction join it; otherwise they follow the
    // run.
    const unresolved = 0xff;
    var members: std.ArrayList(u32) = .empty;
    defer members.deinit(gpa);
    var run: u16 = 0;
    while (run < run_count) : (run += 1) {
        members.clearRetainingCapacity();
        for (runs, classes, 0..) |owner, class, at| {
            if (owner == run and class != .control) try members.append(gpa, @intCast(at));
        }
        if (members.items.len == 0) continue;
        // Signs that go with numbers: a separator between two numbers of
        // one kind joins them, percent and currency signs next to a
        // European number join it, and whatever is left is neutral.
        for (members.items, 0..) |at, index| {
            const class = classes[at];
            if (class != .separator and class != .common_separator) continue;
            if (index == 0 or index + 1 == members.items.len) continue;
            const before = classes[members.items[index - 1]];
            const after = classes[members.items[index + 1]];
            if (before == .number and after == .number) classes[at] = .number;
            if (class == .common_separator and before == .arabic_number and after == .arabic_number) classes[at] = .arabic_number;
        }
        for (members.items, 0..) |at, index| {
            if (classes[at] != .terminator) continue;
            var end = index;
            while (end < members.items.len and classes[members.items[end]] == .terminator) end += 1;
            const number_before = index > 0 and classes[members.items[index - 1]] == .number;
            const number_after = end < members.items.len and classes[members.items[end]] == .number;
            if (number_before or number_after) {
                for (members.items[index..end]) |sign| classes[sign] = .number;
            }
        }
        for (members.items) |at| switch (classes[at]) {
            .separator, .common_separator, .terminator => classes[at] = .neutral,
            else => {},
        };
        const embedding = levels[members.items[0]];
        const odd = embedding % 2 == 1;
        const left_level: u8 = if (odd) embedding + 1 else embedding;
        const right_level: u8 = if (odd) embedding else embedding + 1;
        var strong_right = odd;
        for (members.items) |at| switch (classes[at]) {
            .left => {
                strong_right = false;
                levels[at] = left_level;
            },
            .right, .arabic => {
                strong_right = true;
                levels[at] = right_level;
            },
            .number, .arabic_number => levels[at] = if (odd) embedding + 1 else if (strong_right) embedding + 2 else embedding,
            .neutral => levels[at] = unresolved,
            .control, .separator, .common_separator, .terminator => unreachable,
        };
        var index: usize = 0;
        while (index < members.items.len) {
            if (levels[members.items[index]] != unresolved) {
                index += 1;
                continue;
            }
            var end = index;
            while (end < members.items.len and levels[members.items[end]] == unresolved) end += 1;
            const before: u8 = if (index > 0) levels[members.items[index - 1]] else embedding;
            const after: u8 = if (end < members.items.len) levels[members.items[end]] else embedding;
            const fill: u8 = if (before % 2 != after % 2) embedding else if (before % 2 == 1) right_level else left_level;
            for (members.items[index..end]) |at| levels[at] = fill;
            index = end;
        }
    }

    // The controls have done their work and are not drawn; drop them
    // before reordering.
    {
        var kept: usize = 0;
        for (shaped, levels) |c, level| {
            if (isInvisible(c)) continue;
            shaped[kept] = c;
            levels[kept] = level;
            kept += 1;
        }
        out.items.len = start + kept;
        shaped = out.items[start..];
    }
    var index: usize = 0;
    var highest: u8 = 0;
    for (shaped, levels[0..shaped.len]) |*c, level| {
        highest = @max(highest, level);
        if (level % 2 == 1) c.* = mirrored(c.*);
    }
    var level = highest;
    while (level >= 1) : (level -= 1) {
        index = 0;
        while (index < shaped.len) {
            if (levels[index] < level) {
                index += 1;
                continue;
            }
            var end = index;
            while (end < shaped.len and levels[end] >= level) end += 1;
            std.mem.reverse(u21, shaped[index..end]);
            std.mem.reverse(u8, levels[index..end]);
            index = end;
        }
    }
    // A mark is laid out after its letter whichever way the run reads:
    // reversing a right-to-left run put its marks in front, so each
    // letter's marks go back behind it, in the order they were typed.
    index = 0;
    while (index < shaped.len) {
        if (levels[index] % 2 == 0 or !isCombiningMark(shaped[index])) {
            index += 1;
            continue;
        }
        var end = index;
        while (end < shaped.len and levels[end] % 2 == 1 and isCombiningMark(shaped[end])) end += 1;
        if (end < shaped.len and levels[end] % 2 == 1) {
            std.mem.reverse(u21, shaped[index .. end + 1]);
            end += 1;
        }
        index = end;
    }
}

/// Marks that sit on the letter before them and take no room: the
/// combining diacritics and the points of Hebrew and Arabic.
fn isCombiningMark(c: u21) bool {
    return (c >= 0x0300 and c <= 0x036f) or (c >= 0x0591 and c <= 0x05bd) or c == 0x05bf or c == 0x05c1 or c == 0x05c2 or
        c == 0x05c4 or c == 0x05c5 or c == 0x05c7 or (c >= 0x0610 and c <= 0x061a) or (c >= 0x064b and c <= 0x065f) or
        c == 0x0670 or (c >= 0x06d6 and c <= 0x06dc) or (c >= 0x06df and c <= 0x06e4) or c == 0x06e7 or c == 0x06e8 or
        (c >= 0x06ea and c <= 0x06ed) or (c >= 0xd0000 and c <= 0xdffff) or (c >= 0xe1100 and c <= 0xe11ff);
}

fn nextLenient(iterator: *std.unicode.Utf8Iterator) ?u21 {
    if (iterator.i >= iterator.bytes.len) return null;
    const length = std.unicode.utf8ByteSequenceLength(iterator.bytes[iterator.i]) catch {
        iterator.i += 1;
        return 0xfffd;
    };
    if (iterator.i + length > iterator.bytes.len) {
        iterator.i = iterator.bytes.len;
        return 0xfffd;
    }
    const c = std.unicode.utf8Decode(iterator.bytes[iterator.i..][0..length]) catch {
        iterator.i += 1;
        return 0xfffd;
    };
    iterator.i += length;
    return c;
}

fn everything(_: *const anyopaque, _: u21) bool {
    return true;
}

fn expectShaped(input: []const u8, expected: []const u21) !void {
    var out: std.ArrayList(u21) = .empty;
    defer out.deinit(std.testing.allocator);
    const dummy: u8 = 0;
    try shapeLine(std.testing.allocator, input, .{ .context = &dummy, .has = everything }, &out);
    try std.testing.expectEqualSlices(u21, expected, out.items);
}

test "latin ligatures" {
    try expectShaped("office fluff", &.{ 'o', 0xfb03, 'c', 'e', ' ', 0xfb02, 'u', 0xfb00 });
    try std.testing.expect(needsShaping("fi"));
    try std.testing.expect(!needsShaping("plain text, no f pairs"));
}

test "hebrew runs are reversed inside left-to-right text, numbers are not" {
    // "ab " + alef bet gimel + " cd": the Hebrew word reads right to left.
    try expectShaped("ab \u{05d0}\u{05d1}\u{05d2} cd", &.{ 'a', 'b', ' ', 0x05d2, 0x05d1, 0x05d0, ' ', 'c', 'd' });
    // A right-to-left line: letters reversed, the number kept in order, the
    // brackets mirrored so they still enclose it.
    try expectShaped("\u{05d0}\u{05d1} (12)", &.{ '(', '1', '2', ')', ' ', 0x05d1, 0x05d0 });
}

test "arabic letters take contextual forms and lam-alef fuses" {
    // beh + beh + beh: initial, medial, final; drawn right to left.
    try expectShaped("\u{0628}\u{0628}\u{0628}", &.{ 0xfe90, 0xfe92, 0xfe91 });
    // lam + alef -> the isolated ligature.
    try expectShaped("\u{0644}\u{0627}", &.{0xfefb});
    // alef does not join forward: beh after it starts a new group.
    try expectShaped("\u{0627}\u{0628}", &.{ 0xfe8f, 0xfe8d });
}

test "direction marks steer neutral characters and are not drawn" {
    // Without a mark the exclamation mark sits between a Hebrew word and
    // Latin text and follows the line's direction: it stays after the word.
    try expectShaped("ab \u{05d0}\u{05d1}! cd", &.{ 'a', 'b', ' ', 0x05d1, 0x05d0, '!', ' ', 'c', 'd' });
    // A right-to-left mark after it puts it between two right-to-left
    // characters, so it joins the Hebrew run and ends up on its left.
    try expectShaped("ab \u{05d0}\u{05d1}!\u{200f} cd", &.{ 'a', 'b', ' ', '!', 0x05d1, 0x05d0, ' ', 'c', 'd' });
    // A left-to-right mark alone changes nothing visible.
    try expectShaped("a\u{200e}b", &.{ 'a', 'b' });
}

test "overrides, embeddings and isolates" {
    // An override turns even Latin letters around.
    try expectShaped("a\u{202e}bcd\u{202c}e", &.{ 'a', 'd', 'c', 'b', 'e' });
    // Unisolated, the exclamation mark sits between Hebrew and Latin and
    // follows the line; isolated, it ends the Hebrew phrase.
    try expectShaped("ab \u{05d0}\u{05d1}! cd", &.{ 'a', 'b', ' ', 0x05d1, 0x05d0, '!', ' ', 'c', 'd' });
    try expectShaped("ab \u{2067}\u{05d0}\u{05d1}!\u{2069} cd", &.{ 'a', 'b', ' ', '!', 0x05d1, 0x05d0, ' ', 'c', 'd' });
    // A first-strong isolate takes its direction from what it holds.
    try expectShaped("ab \u{2068}\u{05d0}\u{05d1}!\u{2069} cd", &.{ 'a', 'b', ' ', '!', 0x05d1, 0x05d0, ' ', 'c', 'd' });
    try expectShaped("\u{05d0} \u{2068}ab!\u{2069} \u{05d1}", &.{ 0x05d1, ' ', 'a', 'b', '!', ' ', 0x05d0 });
    // A left-to-right embedding inside right-to-left text keeps a phrase
    // with its punctuation in reading order.
    try expectShaped("\u{05d0} \u{202a}a-b!\u{202c} \u{05d1}", &.{ 0x05d1, ' ', 'a', '-', 'b', '!', ' ', 0x05d0 });
    // Unclosed and unmatched controls are harmless.
    try expectShaped("a\u{202c}b\u{2069}c\u{2067}", &.{ 'a', 'b', 'c' });
}

test "signs next to numbers stay with them in right-to-left text" {
    // A percent sign after a number, and a currency sign before one.
    try expectShaped("\u{05d0}\u{05d1} 100% \u{05d2}", &.{ 0x05d2, ' ', '1', '0', '0', '%', ' ', 0x05d1, 0x05d0 });
    try expectShaped("\u{05d0} $5 \u{05d1}", &.{ 0x05d1, ' ', '$', '5', ' ', 0x05d0 });
    // Separators inside a number keep it in one piece.
    try expectShaped("\u{05d0} 1,234.5 \u{05d1}", &.{ 0x05d1, ' ', '1', ',', '2', '3', '4', '.', '5', ' ', 0x05d0 });
    // A full stop that only follows a number is punctuation of the
    // sentence: it goes where the sentence ends, on the left.
    try expectShaped("\u{05d0} 12.", &.{ '.', '1', '2', ' ', 0x05d0 });
    // In left-to-right text nothing changes.
    try expectShaped("a 50% b", &.{ 'a', ' ', '5', '0', '%', ' ', 'b' });
}

test "marks stay behind their letters in right-to-left runs" {
    // alef with a vowel point, then bet: drawn bet, alef, point.
    try expectShaped("\u{05d0}\u{05b8}\u{05d1}", &.{ 0x05d1, 0x05d0, 0x05b8 });
    // Two marks on one letter keep the order they were typed in.
    try expectShaped("\u{05d1}\u{05d0}\u{05b8}\u{05bc}", &.{ 0x05d0, 0x05b8, 0x05bc, 0x05d1 });
    // Left-to-right text is untouched.
    try expectShaped("e\u{0301}a", &.{ 'e', 0x0301, 'a' });
}

test "sara am is drawn as a ring under the tone mark and a letter" {
    const gpa = std.testing.allocator;
    const Any = struct {
        fn has(_: *const anyopaque, _: u21) bool {
            return true;
        }
    };
    var out: std.ArrayList(u21) = .empty;
    defer out.deinit(gpa);
    // no nu, mai tho, sara am: the ring goes before the tone mark.
    try shapeLine(gpa, "\u{e19}\u{e49}\u{e33}", .{ .context = undefined, .has = Any.has }, &out);
    try std.testing.expectEqualSlices(u21, &.{ 0xe19, 0xe4d, 0xe49, 0xe32 }, out.items);
    out.clearRetainingCapacity();
    // Without a tone mark it simply comes apart.
    try shapeLine(gpa, "\u{e01}\u{e33}", .{ .context = undefined, .has = Any.has }, &out);
    try std.testing.expectEqualSlices(u21, &.{ 0xe01, 0xe4d, 0xe32 }, out.items);
}
