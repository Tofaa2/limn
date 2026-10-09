//! Fonts and the glyphs prepared for them. Internal to the renderer.
const std = @import("std");
const rhi = @import("../../rhi/rhi.zig");
const gltf = @import("../../asset/gltf.zig");
const text_layout = @import("../text_layout.zig");
const api = @import("../api.zig");
const render = @import("../renderer.zig");

const Renderer = render.Renderer;
const font_module = @import("font_baker").font;
const Font = api.Font;

/// Distance-field fonts for draw lists.
pub const Fonts = struct {
    default_font: *Font = undefined,
    list: std.ArrayList(*Font) = .empty,
    textures: std.ArrayList(rhi.Texture) = .empty,

    fn renderer(fonts: *Fonts) *Renderer {
        return @alignCast(@fieldParentPtr("fonts", fonts));
    }

    /// The built-in font (DejaVu Sans, printable ASCII and Latin-1).
    pub fn default(fonts: *const Fonts) *const Font {
        return fonts.default_font;
    }

    /// Loads a TrueType font and bakes a distance-field atlas for `ranges`.
    /// The font is immutable and usable from any thread until `fonts.destroy`.
    pub fn load(fonts: *Fonts, path: []const u8, ranges: []const font_module.Range) !*const Font {
        const self = fonts.renderer();
        const bytes = try gltf.readFile(self.gpa, self.io, path);
        defer self.gpa.free(bytes);
        return self.fonts.loadFromMemory(bytes, ranges);
    }

    /// As `fonts.load`, from bytes in memory. `bytes` and `ranges` are not kept.
    pub fn loadFromMemory(fonts: *Fonts, bytes: []const u8, ranges: []const font_module.Range) !*const Font {
        const self = fonts.renderer();
        const font = try self.gpa.create(Font);
        errdefer self.gpa.destroy(font);
        font.* = try font_module.load(self.gpa, bytes, ranges);
        errdefer font.deinit();
        self.lock();
        defer self.unlock();
        try registerFont(self, font);
        return font;
    }

    /// Adds to the atlas every `liga`/`rlig` ligature whose parts are already
    /// in it. Call again after `prepareText` adds letters.
    pub fn prepareLigatures(fonts: *Fonts, font: *const Font) !void {
        const self = fonts.renderer();
        const missing = try font.missingLigatures(self.gpa);
        defer self.gpa.free(missing);
        if (missing.len == 0) return;
        const text = try self.gpa.alloc(u8, missing.len * 4);
        defer self.gpa.free(text);
        var length: usize = 0;
        for (missing) |codepoint| length += try std.unicode.utf8Encode(codepoint, text[length..]);
        try self.fonts.prepareText(font, text[0..length]);
    }

    /// Bakes any glyphs of `text` the font has that are not in its atlas yet.
    /// Call before drawing with the font that frame, and not while another
    /// thread draws text with it.
    pub fn prepareText(fonts: *Fonts, font: *const Font, text: []const u8) !void {
        const self = fonts.renderer();
        return self.fonts.prepareTextWith(font, text, null, &.{});
    }

    /// `prepareText` that also bakes glyphs brought in by `language` and
    /// `features`.
    pub fn prepareTextWith(fonts: *Fonts, font: *const Font, text: []const u8, language: ?[4]u8, features: []const [4]u8) !void {
        const self = fonts.renderer();
        self.lock();
        defer self.unlock();
        const index = for (self.fonts.list.items, 0..) |candidate, index| {
            if (candidate == font) break index;
        } else return error.UnknownFont;
        const mutable = self.fonts.list.items[index];
        var missing: std.ArrayList(u21) = .empty;
        defer missing.deinit(self.gpa);
        var iterator = font_module.Utf8Iterator{ .bytes = text };
        while (iterator.next()) |codepoint| {
            if (codepoint == 0x0e33 or codepoint == 0x0eb3) {
                const parts: [2]u21 = if (codepoint == 0x0e33) .{ 0x0e4d, 0x0e32 } else .{ 0x0ecd, 0x0eb2 };
                for (parts) |part| {
                    if (!mutable.has(part)) try missing.append(self.gpa, part);
                }
            }
            if (codepoint < 32 or mutable.has(codepoint)) continue;
            try missing.append(self.gpa, codepoint);
            if (codepoint >= 0x0621 and codepoint <= 0x064a) {
                var form: u21 = 0xfe70;
                while (form <= 0xfefc) : (form += 1) {
                    if (!mutable.has(form)) try missing.append(self.gpa, form);
                }
            }
        }
        {
            var typed: std.ArrayList(u21) = .empty;
            defer typed.deinit(self.gpa);
            var characters = font_module.Utf8Iterator{ .bytes = text };
            while (characters.next()) |codepoint| {
                if (codepoint >= 32) try typed.append(self.gpa, codepoint);
            }
            var start: usize = 0;
            while (start < typed.items.len) {
                var script = text_layout.scriptOf(typed.items[start]);
                var end = start + 1;
                while (end < typed.items.len) : (end += 1) {
                    const own = text_layout.scriptOf(typed.items[end]) orelse continue;
                    if (script) |current| {
                        if (!std.mem.eql(u8, &own, &current)) break;
                    } else script = own;
                }
                const tag = script orelse "DFLT".*;
                try mutable.missingSubstitutes(self.gpa, typed.items[start..end], .{ .script = tag, .language = language, .features = features }, &missing);
                start = end;
            }
        }
        if (missing.items.len == 0) return;
        const next = (try mutable.extend(missing.items)) orelse return;
        errdefer mutable.discard(next);
        const device = self.device;
        const texture = try device.createTexture(.{
            .name = "font atlas",
            .width = next.atlas_width,
            .height = next.atlas_height,
            .format = .rgba8_unorm,
            .usage = .{ .sampled = true, .copy_dst = true },
            .mip_levels = 4,
        });
        errdefer device.destroyTexture(texture);
        {
            const texels = try fontTexels(self.gpa, next);
            defer self.gpa.free(texels);
            try device.uploadTexture(texture, 0, 0, texels);
        }
        try device.generateMips(texture);
        next.texture_index = device.textureIndex(texture);
        mutable.adopt(next);
        device.destroyTexture(self.fonts.textures.items[index]);
        self.fonts.textures.items[index] = texture;
    }

    /// The built-in font cannot be destroyed.
    pub fn destroy(fonts: *Fonts, font: *const Font) void {
        const self = fonts.renderer();
        self.lock();
        defer self.unlock();
        if (font == @as(*const Font, self.fonts.default_font)) return;
        for (self.fonts.list.items, 0..) |candidate, index| {
            if (@as(*const Font, candidate) != font) continue;
            self.device.destroyTexture(self.fonts.textures.items[index]);
            _ = self.fonts.list.swapRemove(index);
            _ = self.fonts.textures.swapRemove(index);
            candidate.deinit();
            self.gpa.destroy(candidate);
            return;
        }
    }
};

pub fn registerFont(self: *Renderer, font: *Font) !void {
    const device = self.device;
    const texture = try device.createTexture(.{
        .name = "font atlas",
        .width = font.baked().atlas_width,
        .height = font.baked().atlas_height,
        .format = .rgba8_unorm,
        .usage = .{ .sampled = true, .copy_dst = true },
        .mip_levels = 4,
    });
    errdefer device.destroyTexture(texture);
    {
        const texels = try fontTexels(self.gpa, font.baked());
        defer self.gpa.free(texels);
        try device.uploadTexture(texture, 0, 0, texels);
    }
    try device.generateMips(texture);
    font.setTexture(device.textureIndex(texture));
    try self.fonts.list.append(self.gpa, font);
    errdefer _ = self.fonts.list.pop();
    try self.fonts.textures.append(self.gpa, texture);
}

/// A font atlas as the GPU gets it: the three-channel field in red, green
/// and blue, the plain one in alpha. Caller frees.
fn fontTexels(gpa: std.mem.Allocator, baked: *const font_module.Baked) ![]u8 {
    const texels = try gpa.alloc(u8, baked.atlas.len * 4);
    for (baked.atlas, 0..) |distance, index| {
        const channels: [3]u8 = if (baked.msdf.len == baked.atlas.len * 3) baked.msdf[index * 3 ..][0..3].* else .{ distance, distance, distance };
        texels[index * 4 ..][0..4].* = .{ channels[0], channels[1], channels[2], distance };
    }
    return texels;
}
