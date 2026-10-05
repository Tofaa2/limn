//! Arabic, and Mongolian after it: which of its four forms each letter takes (alone, first,
//! middle or last of a joined group), from the letters either side. A
//! font's lookups for the forms are then applied each to its own letters.
const std = @import("std");

/// Set on every glyph.
pub const mask_all: u32 = 1;
/// A letter joined to neither neighbour; the font's `isol` feature.
pub const mask_isolated: u32 = 2;
/// A letter joined only to the one before it, ending a joined group; the
/// font's `fina` feature.
pub const mask_final: u32 = 4;
/// A letter joined on both sides; the font's `medi` feature.
pub const mask_medial: u32 = 8;
/// A letter joined only to the one after it, beginning a joined group;
/// the font's `init` feature.
pub const mask_initial: u32 = 16;

const Joining = enum {
    /// Joins to nothing.
    none,
    /// Joins to the letter before it only (alef, dal, ra, waw...).
    right,
    /// Joins on both sides.
    dual,
    /// Makes its neighbours join without having forms of its own (the
    /// stretching stroke, the joiner).
    causing,
    /// A mark: letters join across it.
    transparent,
};

fn joiningOf(c: u21) Joining {
    return switch (c) {
        0x0622...0x0625, 0x0627, 0x0629, 0x062f...0x0632, 0x0648, 0x0671...0x0673, 0x0675...0x0677, 0x0688...0x0699, 0x06c0, 0x06c3...0x06cb, 0x06cd, 0x06cf, 0x06d2, 0x06d3, 0x06d5, 0x06ee, 0x06ef, 0x0759...0x075b, 0x076b, 0x076c, 0x0771, 0x0773, 0x0774, 0x0778, 0x0779 => .right,
        0x0620, 0x0626, 0x0628, 0x062a...0x062e, 0x0633...0x063f, 0x0641...0x0647, 0x0649, 0x064a, 0x066e, 0x066f, 0x0678...0x0687, 0x069a...0x06bf, 0x06c1, 0x06c2, 0x06cc, 0x06ce, 0x06d0, 0x06d1, 0x06fa...0x06fc, 0x06ff, 0x0750...0x0758, 0x075c...0x076a, 0x076d...0x0770, 0x0772, 0x0775...0x0777, 0x077a...0x077f, 0x1807, 0x1820...0x1878, 0x1887...0x18a8, 0x18aa => .dual,
        0x0640, 0x200d, 0x180a => .causing,
        0x0610...0x061a, 0x064b...0x065f, 0x0670, 0x06d6...0x06dc, 0x06df...0x06e4, 0x06e7, 0x06e8, 0x06ea...0x06ed, 0x180b...0x180d, 0x180f, 0x1885, 0x1886, 0x18a9 => .transparent,
        else => .none,
    };
}

/// The part each character of `text` plays: `masks` gets one entry a
/// character.
pub fn forms(text: []const u21, masks: []u32) void {
    for (text, masks, 0..) |c, *mask, index| {
        mask.* = mask_all;
        const own = joiningOf(c);
        if (own != .right and own != .dual) continue;
        // The letters either side, past any marks.
        var before: Joining = .none;
        var at = index;
        while (at > 0) {
            at -= 1;
            before = joiningOf(text[at]);
            if (before != .transparent) break;
            before = .none;
        }
        var after: Joining = .none;
        at = index + 1;
        while (at < text.len) : (at += 1) {
            after = joiningOf(text[at]);
            if (after != .transparent) break;
            after = .none;
        }
        const joins_before = before == .dual or before == .causing;
        const joins_after = own == .dual and (after == .dual or after == .right or after == .causing);
        mask.* |= if (joins_before and joins_after) mask_medial else if (joins_before) mask_final else if (joins_after) mask_initial else mask_isolated;
    }
}

test "arabic letters take their forms from their neighbours" {
    // seen, lam, alef, meem: first, middle, last, alone (alef does not
    // join onward).
    var masks: [6]u32 = undefined;
    forms(&.{ 0x633, 0x644, 0x627, 0x645 }, masks[0..4]);
    try std.testing.expectEqualSlices(u32, &.{ mask_all | mask_initial, mask_all | mask_medial, mask_all | mask_final, mask_all | mask_isolated }, masks[0..4]);
    // Letters join across a mark, which has no form itself.
    forms(&.{ 0x628, 0x650, 0x633 }, masks[0..3]);
    try std.testing.expectEqualSlices(u32, &.{ mask_all | mask_initial, mask_all, mask_all | mask_final }, masks[0..3]);
    // A space parts them.
    forms(&.{ 0x628, ' ', 0x628 }, masks[0..3]);
    try std.testing.expectEqualSlices(u32, &.{ mask_all | mask_isolated, mask_all, mask_all | mask_isolated }, masks[0..3]);
}
