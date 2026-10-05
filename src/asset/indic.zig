//! The scripts of India that share one plan (Devanagari, Bengali,
//! Gurmukhi, Gujarati, Oriya, Tamil, Malayalam): the order their letters
//! are drawn in, which is not the order they are typed in, and the part
//! each plays in its syllable, which decides what a font may do with it.
//!
//! A syllable is a run of consonants joined by the sign that silences
//! their vowel (halant), then vowel signs and other marks. One consonant
//! is its base; those before it take half forms, those after it (when
//! the font has such forms for them) sit below or behind it. A vowel
//! sign drawn to the left is put first, and one drawn in two parts is
//! taken apart, the left part first. In some of the scripts a syllable
//! beginning with ra and a halant draws that ra as a hook over the
//! syllable (reph).
//!
//! The Unicode blocks of these scripts are laid out alike, so a letter's
//! kind is read from its place in its block, with a few exceptions each.
const std = @import("std");

/// Set on every glyph.
pub const mask_all: u32 = 1;
/// The ra and halant that become a reph.
pub const mask_reph: u32 = 2;
/// Consonants before the base, with their halants: half forms.
pub const mask_half: u32 = 4;
/// What follows the base consonant: forms below and behind it.
pub const mask_post: u32 = 8;
/// The first syllable of a word: forms some letters take only there.
pub const mask_initial: u32 = 16;

/// A character to draw, the character of the text it came from, and its
/// part.
pub const Placed = struct { index: u32, codepoint: u21, mask: u32 };

/// What the order depends on in the font.
pub const Forms = struct {
    script: *const Script,
    /// It turns ra and halant into a reph.
    reph: bool = false,
    /// The consonants (by place in the block) it has a form for below or
    /// behind a base.
    below: std.StaticBitSet(128) = .initEmpty(),
};

/// What sets one of these scripts apart from the others: where its
/// Unicode block is and which of its letters are of which kind. Letters
/// are given by their place in the block (code point minus `block`).
pub const Script = struct {
    /// How OpenType names the script, in its newer and older plan.
    tag: [4]u8,
    old_tag: [4]u8,
    /// Where its Unicode block starts.
    block: u21,
    /// Consonants outside the usual stretch of the block.
    consonants: []const u8 = &.{},
    /// Vowel signs drawn to the left of their consonant.
    left: []const u8,
    /// Signs drawn to the left of everything else on the left.
    far_left: []const u8 = &.{},
    /// Vowel signs set straight after the base consonant, ahead of the
    /// consonants written under it.
    early: []const u8 = &.{},
    /// Vowel signs drawn in parts: the sign and its parts in order (0
    /// for none). Each part goes where a sign of its own kind would.
    split: []const [4]u8 = &.{},
    /// Marks that close a syllable, besides the usual three.
    modifiers: []const u8 = &.{},
    /// Where the kinds of letter sit in the block; most of these scripts
    /// share the places given here.
    consonant_range: [2]u8 = .{ 0x15, 0x39 },
    vowel_range: [2]u8 = .{ 0x04, 0x14 },
    /// Independent vowels outside that stretch.
    vowels: []const u8 = &.{ 0x60, 0x61, 0x72, 0x73, 0x74, 0x75, 0x76, 0x77 },
    matra_range: [2]u8 = .{ 0x3e, 0x4c },
    /// Vowel signs outside that stretch.
    matras: []const u8 = &.{ 0x3a, 0x3b, 0x4f, 0x55, 0x56, 0x57, 0x62, 0x63 },
    /// Places of the halant, the nukta and ra.
    halant_place: u8 = 0x4d,
    /// 0xff where the script has no nukta.
    nukta_place: u8 = 0x3c,
    ra_place: u8 = 0x30,
    /// The joiner between consonants is part of how the script is
    /// written: it is kept for the font to see, and a reph forms only
    /// with it. Elsewhere a joiner there asks for no reph.
    joiners: bool = false,
    /// Signs that belong to a consonant as a nukta does, by place.
    nuktas: []const u8 = &.{},
    /// The first consonant of a syllable is its base, whatever follows.
    first_base: bool = false,
    /// A subjoined ra is drawn to the left of the base.
    left_ra: bool = false,
    /// The reph is written with a sign between its consonant and the
    /// halant (the nukta's place), and needs no form of the font's own
    /// to be moved: Myanmar's kinzi.
    kinzi: bool = false,
    /// Where a reph goes, in the scripts that have one.
    reph: enum { none, after_base, after_vowel_signs } = .none,

    /// The script's halant, the sign that silences a consonant's vowel, as a
    /// code point.
    pub fn halant(self: Script) u21 {
        return self.block + self.halant_place;
    }

    /// The script's letter ra, as a code point.
    pub fn ra(self: Script) u21 {
        return self.block + self.ra_place;
    }
};

/// The scripts handled: Devanagari, Bengali, Gurmukhi, Gujarati, Oriya,
/// Tamil, Malayalam, Telugu, Kannada, Sinhala, Khmer and Myanmar. See
/// `scriptOf`.
pub const scripts = [_]Script{
    .{ .tag = "dev2".*, .old_tag = "deva".*, .block = 0x900, .consonants = &.{ 0x58, 0x59, 0x5a, 0x5b, 0x5c, 0x5d, 0x5e, 0x5f, 0x78, 0x79, 0x7a, 0x7b, 0x7c, 0x7d, 0x7e, 0x7f }, .left = &.{ 0x3f, 0x4e }, .reph = .after_vowel_signs },
    .{ .tag = "bng2".*, .old_tag = "beng".*, .block = 0x980, .consonants = &.{ 0x5c, 0x5d, 0x5f, 0x70, 0x71 }, .left = &.{ 0x3f, 0x47, 0x48 }, .split = &.{ .{ 0x4b, 0x47, 0x3e, 0 }, .{ 0x4c, 0x47, 0x57, 0 } }, .reph = .after_base },
    .{ .tag = "gur2".*, .old_tag = "guru".*, .block = 0xa00, .consonants = &.{ 0x59, 0x5a, 0x5b, 0x5c, 0x5e }, .left = &.{0x3f}, .modifiers = &.{ 0x70, 0x71 } },
    .{ .tag = "gjr2".*, .old_tag = "gujr".*, .block = 0xa80, .left = &.{0x3f}, .reph = .after_vowel_signs },
    .{ .tag = "ory2".*, .old_tag = "orya".*, .block = 0xb00, .consonants = &.{ 0x5c, 0x5d, 0x5f, 0x71 }, .left = &.{0x47}, .split = &.{ .{ 0x48, 0x47, 0x56, 0 }, .{ 0x4b, 0x47, 0x3e, 0 }, .{ 0x4c, 0x47, 0x57, 0 } }, .reph = .after_base },
    .{ .tag = "tml2".*, .old_tag = "taml".*, .block = 0xb80, .left = &.{ 0x46, 0x47, 0x48 }, .split = &.{ .{ 0x4a, 0x46, 0x3e, 0 }, .{ 0x4b, 0x47, 0x3e, 0 }, .{ 0x4c, 0x46, 0x57, 0 } } },
    .{ .tag = "mlm2".*, .old_tag = "mlym".*, .block = 0xd00, .consonants = &.{0x3a}, .left = &.{ 0x46, 0x47, 0x48 }, .split = &.{ .{ 0x4a, 0x46, 0x3e, 0 }, .{ 0x4b, 0x47, 0x3e, 0 }, .{ 0x4c, 0x46, 0x57, 0 } } },
    .{ .tag = "tel2".*, .old_tag = "telu".*, .block = 0xc00, .consonants = &.{ 0x58, 0x59, 0x5a }, .left = &.{}, .early = &.{ 0x3e, 0x3f, 0x40, 0x41, 0x42, 0x46, 0x47, 0x4a, 0x4b, 0x4c, 0x55, 0x56 }, .split = &.{.{ 0x48, 0x46, 0x56, 0 }} },
    .{ .tag = "knd2".*, .old_tag = "knda".*, .block = 0xc80, .consonants = &.{0x5e}, .left = &.{}, .early = &.{ 0x3e, 0x3f, 0x41, 0x42, 0x46, 0x4c }, .split = &.{ .{ 0x40, 0x3f, 0x55, 0 }, .{ 0x47, 0x46, 0x55, 0 }, .{ 0x48, 0x46, 0x56, 0 }, .{ 0x4a, 0x46, 0x42, 0 }, .{ 0x4b, 0x46, 0x42, 0x55 } }, .reph = .after_vowel_signs },
    .{ .tag = "sinh".*, .old_tag = "sinh".*, .block = 0xd80, .consonant_range = .{ 0x1a, 0x46 }, .vowel_range = .{ 0x05, 0x16 }, .vowels = &.{}, .matra_range = .{ 0x4f, 0x5f }, .matras = &.{ 0x72, 0x73 }, .halant_place = 0x4a, .nukta_place = 0xff, .ra_place = 0x3b, .left = &.{ 0x59, 0x5b }, .split = &.{ .{ 0x5a, 0x59, 0x4a, 0 }, .{ 0x5c, 0x59, 0x4f, 0 }, .{ 0x5d, 0x59, 0x4f, 0x4a }, .{ 0x5e, 0x59, 0x5f, 0 } }, .reph = .after_base, .joiners = true },
    .{ .tag = "khmr".*, .old_tag = "khmr".*, .block = 0x1780, .consonant_range = .{ 0x00, 0x22 }, .vowel_range = .{ 0x23, 0x33 }, .vowels = &.{}, .matra_range = .{ 0x36, 0x45 }, .matras = &.{}, .halant_place = 0x52, .nukta_place = 0xff, .nuktas = &.{ 0x49, 0x4a }, .ra_place = 0x1a, .left = &.{ 0x41, 0x42, 0x43 }, .split = &.{ .{ 0x3e, 0x41, 0x3e, 0 }, .{ 0x3f, 0x41, 0x3f, 0 }, .{ 0x40, 0x41, 0x40, 0 }, .{ 0x44, 0x41, 0x44, 0 }, .{ 0x45, 0x41, 0x45, 0 } }, .modifiers = &.{ 0x46, 0x47, 0x48, 0x4b, 0x4c, 0x4d, 0x4e, 0x4f, 0x50, 0x51, 0x5d }, .first_base = true, .left_ra = true },
    .{ .tag = "mym2".*, .old_tag = "mymr".*, .block = 0x1000, .consonant_range = .{ 0x00, 0x20 }, .consonants = &.{ 0x3f, 0x50, 0x51, 0x5a, 0x5b, 0x5c, 0x5d }, .vowel_range = .{ 0x21, 0x2a }, .vowels = &.{ 0x52, 0x53, 0x54, 0x55 }, .matra_range = .{ 0x2b, 0x32 }, .matras = &.{ 0x3b, 0x3d, 0x3e, 0x56, 0x57, 0x58, 0x59, 0x5e, 0x5f, 0x60, 0x62, 0x71, 0x72, 0x73, 0x74 }, .halant_place = 0x39, .nukta_place = 0x3a, .ra_place = 0x04, .far_left = &.{0x31}, .left = &.{0x3c}, .modifiers = &.{ 0x36, 0x37, 0x38 }, .first_base = true, .reph = .after_base, .kinzi = true },
    .{ .tag = "java".*, .old_tag = "java".*, .block = 0xa980, .consonant_range = .{ 0x0f, 0x32 }, .vowel_range = .{ 0x04, 0x0e }, .vowels = &.{}, .matra_range = .{ 0x34, 0x3f }, .matras = &.{}, .halant_place = 0x40, .nukta_place = 0x33, .ra_place = 0x2b, .left = &.{ 0x3a, 0x3b }, .modifiers = &.{0x00}, .first_base = true },
};

/// The script of that name, if it is one of these.
pub fn scriptOf(tag: [4]u8) ?*const Script {
    for (&scripts) |*script| {
        if (std.mem.eql(u8, &script.tag, &tag)) return script;
    }
    return null;
}

const Kind = enum { consonant, vowel, nukta, halant, matra, left_matra, split_matra, modifier, joiner, other };

fn kindOf(script: *const Script, c: u21) Kind {
    // They steer how consonants join and are not drawn.
    if (c == 0x200c or c == 0x200d) return .joiner;
    if (c < script.block or c >= script.block + 0x80) return .other;
    const place: u8 = @intCast(c - script.block);
    if (std.mem.indexOfScalar(u8, script.consonants, place) != null) return .consonant;
    if (std.mem.indexOfScalar(u8, script.left, place) != null or std.mem.indexOfScalar(u8, script.far_left, place) != null) return .left_matra;
    if (std.mem.indexOfScalar(u8, script.modifiers, place) != null) return .modifier;
    for (script.split) |entry| {
        if (entry[0] == place) return .split_matra;
    }
    if (place >= script.consonant_range[0] and place <= script.consonant_range[1]) return .consonant;
    if (place >= script.vowel_range[0] and place <= script.vowel_range[1]) return .vowel;
    if (std.mem.indexOfScalar(u8, script.vowels, place) != null) return .vowel;
    if (place == script.nukta_place or std.mem.indexOfScalar(u8, script.nuktas, place) != null) return .nukta;
    if (place == script.halant_place) return .halant;
    if (place >= script.matra_range[0] and place <= script.matra_range[1]) return .matra;
    if (std.mem.indexOfScalar(u8, script.matras, place) != null) return .matra;
    return switch (place) {
        0x00...0x03, 0x51...0x54 => .modifier,
        else => .other,
    };
}

/// More consonants than this in one syllable and the rest start another.
const max_consonants = 12;

/// Appends the characters of `text` in the order they are drawn.
pub fn reorder(gpa: std.mem.Allocator, text: []const u21, forms: Forms, out: *std.ArrayList(Placed)) !void {
    // A vowel sign drawn in parts takes up to three places.
    try out.ensureUnusedCapacity(gpa, text.len * 3);
    const script = forms.script;
    var at: usize = 0;
    while (at < text.len) {
        switch (kindOf(script, text[at])) {
            .consonant => {
                // A word starts where no letter of the script comes before.
                const first = at == 0 or kindOf(script, text[at - 1]) == .other;
                const from = out.items.len;
                at = syllable(text, at, forms, out);
                if (first) for (out.items[from..]) |*item| {
                    item.mask |= mask_initial;
                };
            },
            .joiner => at += 1,
            .vowel => {
                put(out, text, at, mask_all);
                at += 1;
                while (at < text.len) : (at += 1) switch (kindOf(script, text[at])) {
                    .nukta, .matra, .left_matra, .split_matra, .modifier => put(out, text, at, mask_all),
                    else => break,
                };
            },
            else => {
                put(out, text, at, mask_all);
                at += 1;
            },
        }
    }
}

fn put(out: *std.ArrayList(Placed), text: []const u21, index: usize, mask: u32) void {
    out.appendAssumeCapacity(.{ .index = @intCast(index), .codepoint = text[index], .mask = mask });
}

/// Where a vowel sign, or a part of one, is set in its syllable.
const SignPlace = enum { far_left, left, early, late };

/// Puts down the vowel signs of a syllable that belong in one place,
/// taking apart those written as one character and drawn as several.
fn putSigns(out: *std.ArrayList(Placed), text: []const u21, script: *const Script, from: usize, to: usize, wanted: SignPlace) void {
    for (from..to) |index| {
        const sign: u8 = @intCast(text[index] - script.block);
        var parts = [3]u8{ sign, 0, 0 };
        for (script.split) |entry| {
            if (entry[0] == sign) parts = entry[1..4].*;
        }
        for (parts) |part| {
            if (part == 0) continue;
            const place: SignPlace = if (std.mem.indexOfScalar(u8, script.far_left, part) != null)
                .far_left
            else if (std.mem.indexOfScalar(u8, script.left, part) != null)
                .left
            else if (std.mem.indexOfScalar(u8, script.early, part) != null)
                .early
            else
                .late;
            if (place == wanted) out.appendAssumeCapacity(.{ .index = @intCast(index), .codepoint = script.block + part, .mask = mask_all });
        }
    }
}

/// One consonant with what belongs to it: `end` is past its nukta and
/// halant, if it has them, and past a joiner the script keeps.
const Consonant = struct {
    start: usize,
    end: usize,
    halant: bool,
    nukta: bool,
    joined: bool,

    /// Where the consonant's own letters end and its halant begins.
    fn bare(self: Consonant, script: *const Script) usize {
        return self.end - @intFromBool(self.halant) - @intFromBool(self.joined and script.joiners);
    }
};

/// Puts down a consonant after the base together with the halant that
/// ties it on, which belongs to the consonant before it.
fn putJoined(out: *std.ArrayList(Placed), text: []const u21, script: *const Script, before: Consonant, consonant: Consonant) void {
    for (before.bare(script)..before.end) |index| put(out, text, index, mask_all | mask_post);
    for (consonant.start..consonant.bare(script)) |index| put(out, text, index, mask_all | mask_post);
}

/// Lays out the syllable that starts with the consonant at `start`;
/// returns where the next one starts.
fn syllable(text: []const u21, start: usize, forms: Forms, out: *std.ArrayList(Placed)) usize {
    const script = forms.script;
    const from = out.items.len;
    var consonants: [max_consonants]Consonant = undefined;
    var count: usize = 0;
    var at = start;
    while (count < max_consonants) {
        var end = at + 1;
        var nukta = false;
        while (end < text.len and kindOf(script, text[end]) == .nukta) {
            nukta = true;
            end += 1;
        }
        var halant = false;
        var joined = false;
        var next = end;
        if (end < text.len and kindOf(script, text[end]) == .halant) {
            halant = true;
            end += 1;
            next = end;
            // A joiner after the halant: in most of these scripts it asks
            // for the half form, which a following consonant gets anyway,
            // and is dropped; where the script is written with joiners
            // it stays, for the font to make its conjuncts with. (A
            // non-joiner asks for the halant to show, and ends the
            // syllable.)
            if (next < text.len and text[next] == 0x200d) {
                joined = true;
                next += 1;
                if (script.joiners) end = next;
            }
        }
        consonants[count] = .{ .start = at, .end = end, .halant = halant, .nukta = nukta, .joined = joined };
        count += 1;
        at = next;
        if (!halant or at >= text.len or kindOf(script, text[at]) != .consonant) break;
    }
    const marks = at;
    while (at < text.len) : (at += 1) switch (kindOf(script, text[at])) {
        .matra, .left_matra, .split_matra => {},
        else => break,
    };
    const modifiers = at;
    while (at < text.len and kindOf(script, text[at]) == .modifier) at += 1;

    const reph = forms.reph and script.reph != .none and count >= 2 and text[consonants[0].start] == script.ra() and
        consonants[0].halant and consonants[0].nukta == script.kinzi and consonants[0].joined == script.joiners;
    const first: usize = @intFromBool(reph);
    // The base: the last consonant that the font does not draw below or
    // behind another, or simply the first where the script stacks every
    // later one under it.
    var base = count - 1;
    if (script.first_base) base = first;
    while (base > first and forms.below.isSet(text[consonants[base].start] - script.block)) base -= 1;

    // What is drawn on the left: whole vowel signs, and the left parts
    // of those in several.
    putSigns(out, text, script, marks, modifiers, .far_left);
    putSigns(out, text, script, marks, modifiers, .left);
    // A consonant after the base is written with the halant that ties it
    // on, which is typed before it. Where the script draws a subjoined
    // ra to the left of the base, that pair goes first.
    if (script.left_ra) for (base + 1..count) |index| {
        if (text[consonants[index].start] == script.ra()) putJoined(out, text, script, consonants[index - 1], consonants[index]);
    };
    for (consonants[first..base]) |consonant| {
        for (consonant.start..consonant.end) |index| put(out, text, index, mask_all | mask_half);
    }
    // The base, bare; its halant, if any, belongs to what follows.
    for (consonants[base].start..consonants[base].bare(script)) |index| put(out, text, index, mask_all);
    putSigns(out, text, script, marks, modifiers, .early);
    for (base + 1..count) |index| {
        if (script.left_ra and text[consonants[index].start] == script.ra()) continue;
        putJoined(out, text, script, consonants[index - 1], consonants[index]);
    }
    // A halant with no consonant after it shows as itself.
    const last = consonants[count - 1];
    for (last.bare(script)..last.end) |index| put(out, text, index, mask_all | mask_post);
    if (reph and script.reph == .after_base) {
        for (consonants[0].start..consonants[0].end) |index| put(out, text, index, mask_all | mask_reph);
    }
    putSigns(out, text, script, marks, modifiers, .late);
    if (reph and script.reph == .after_vowel_signs) {
        for (consonants[0].start..consonants[0].end) |index| put(out, text, index, mask_all | mask_reph);
    }
    for (modifiers..at) |index| put(out, text, index, mask_all);
    // Where the base is simply the first consonant, everything else in
    // the syllable counts as coming after it: the font's forms for what
    // follows a base are open to all of it.
    if (script.first_base) for (out.items[from..]) |*item| {
        if (item.index != consonants[base].start) item.mask |= mask_post;
    };
    return at;
}

fn orderOf(gpa: std.mem.Allocator, text: []const u21, forms: Forms) ![]u21 {
    var placed: std.ArrayList(Placed) = .empty;
    defer placed.deinit(gpa);
    try reorder(gpa, text, forms, &placed);
    const order = try gpa.alloc(u21, placed.items.len);
    for (order, placed.items) |*c, item| c.* = item.codepoint;
    return order;
}

test "indic scripts are put in the order they are drawn" {
    const gpa = std.testing.allocator;
    const Case = struct { script: [4]u8 = "dev2".*, typed: []const u21, drawn: []const u21 };
    const cases = [_]Case{
        // The vowel sign i is drawn before its consonant, and before the
        // half forms that lead up to it.
        .{ .typed = &.{ 0x915, 0x93f }, .drawn = &.{ 0x93f, 0x915 } },
        .{ .typed = &.{ 0x915, 0x94d, 0x915, 0x93f }, .drawn = &.{ 0x93f, 0x915, 0x94d, 0x915 } },
        // Ra and halant at the start go to the end, before an anusvara.
        .{ .typed = &.{ 0x930, 0x94d, 0x915 }, .drawn = &.{ 0x915, 0x930, 0x94d } },
        .{ .typed = &.{ 0x930, 0x94d, 0x915, 0x94b, 0x902 }, .drawn = &.{ 0x915, 0x94b, 0x930, 0x94d, 0x902 } },
        // On their own they stay.
        .{ .typed = &.{ 0x930, 0x94d }, .drawn = &.{ 0x930, 0x94d } },
        // A vowel is a syllable of its own; a joiner is not drawn.
        .{ .typed = &.{ 0x905, 0x930, 0x94d, 0x915 }, .drawn = &.{ 0x905, 0x915, 0x930, 0x94d } },
        .{ .typed = &.{ 0x915, 0x94d, 0x200d, 0x915 }, .drawn = &.{ 0x915, 0x94d, 0x915 } },
        // Other text passes through.
        .{ .typed = &.{ 'a', ' ', 0x915, 0x93f, ' ', 0x915 }, .drawn = &.{ 'a', ' ', 0x93f, 0x915, ' ', 0x915 } },
        // Bengali: o is drawn as e before the consonant and aa after it,
        // and the reph sits between the consonant and the aa.
        .{ .script = "bng2".*, .typed = &.{ 0x995, 0x9cb }, .drawn = &.{ 0x9c7, 0x995, 0x9be } },
        .{ .script = "bng2".*, .typed = &.{ 0x9b0, 0x9cd, 0x995, 0x9cb }, .drawn = &.{ 0x9c7, 0x995, 0x9b0, 0x9cd, 0x9be } },
        // Tamil has no reph: ra stays where it was typed.
        .{ .script = "tml2".*, .typed = &.{ 0xbb0, 0xbcd, 0xb95, 0xbca }, .drawn = &.{ 0xbc6, 0xbb0, 0xbcd, 0xb95, 0xbbe } },
        // Oriya writes its i after the consonant, and e before it.
        .{ .script = "ory2".*, .typed = &.{ 0xb15, 0xb3f }, .drawn = &.{ 0xb15, 0xb3f } },
        .{ .script = "ory2".*, .typed = &.{ 0xb15, 0xb47 }, .drawn = &.{ 0xb47, 0xb15 } },
    };
    for (cases) |case| {
        const order = try orderOf(gpa, case.typed, .{ .script = scriptOf(case.script).?, .reph = true });
        defer gpa.free(order);
        try std.testing.expectEqualSlices(u21, case.drawn, order);
    }
    // Without a reph in the font, ra stays where it was typed.
    const order = try orderOf(gpa, &.{ 0x930, 0x94d, 0x915 }, .{ .script = scriptOf("dev2".*).? });
    defer gpa.free(order);
    try std.testing.expectEqualSlices(u21, &.{ 0x930, 0x94d, 0x915 }, order);
}
