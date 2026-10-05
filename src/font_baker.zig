//! Root of the module that parses fonts and bakes their glyphs into
//! distance fields. Baking runs over every texel of every glyph against
//! every curve of its outline, so like the texture codec this module is
//! always built optimized, whatever the application is built with.
/// The font code itself: `font.Font`, its glyph atlas baking and the
/// shaping queries text drawing uses. Other modules reach it as
/// `@import("font_baker").font`.
pub const font = @import("asset/font.zig");

test {
    _ = font;
}
