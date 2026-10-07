//! Root of the font module: parsing and distance-field glyph baking. Always
//! built optimized.
pub const font = @import("asset/font.zig");

test {
    _ = font;
}
