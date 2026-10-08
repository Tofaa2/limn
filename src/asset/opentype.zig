//! OpenType layout: applies GSUB substitutions (single, multiple, alternate,
//! ligature, contextual and chained contextual; not reverse chaining) and
//! advance-adjusting GPOS lookups to a glyph run, honouring GDEF classes.
const std = @import("std");

/// Four-character tag, space padded (`"latn"`, `"ROM "`, `"liga"`).
pub const Tag = [4]u8;

pub const Glyph = struct {
    /// Glyph index in the font.
    id: u16,
    /// Index in the shaped text of the first character this glyph stands for.
    cluster: u32 = 0,
    /// A plan stage applies here only if its mask shares a bit with this.
    mask: u32 = std.math.maxInt(u32),
    /// For a mark a ligature was formed across: the 1-based ligature component
    /// it follows. 0 for every other glyph.
    component: u8 = 0,
    /// Advance added by positioning lookups, in font units.
    advance: i32 = 0,
};

/// Maximum nesting of contextual lookups; deeper nesting is cut short.
const max_depth = 6;
/// Glyphs a run may grow to by substitution.
const max_glyphs = 1 << 16;
/// Most glyphs one rule's input may span.
const max_input = 32;

/// Bounds-checked big-endian reads from a font file. `bytes` is borrowed.
pub const Reader = struct {
    bytes: []const u8,

    /// `error.InvalidFont` when `offset` is past the end.
    pub fn u16At(self: Reader, offset: usize) !u16 {
        if (offset > self.bytes.len or self.bytes.len - offset < 2) return error.InvalidFont;
        return std.mem.readInt(u16, self.bytes[offset..][0..2], .big);
    }

    fn i16At(self: Reader, offset: usize) !i16 {
        return @bitCast(try self.u16At(offset));
    }

    fn u32At(self: Reader, offset: usize) !u32 {
        if (offset > self.bytes.len or self.bytes.len - offset < 4) return error.InvalidFont;
        return std.mem.readInt(u32, self.bytes[offset..][0..4], .big);
    }

    fn tagAt(self: Reader, offset: usize) !Tag {
        if (offset > self.bytes.len or self.bytes.len - offset < 4) return error.InvalidFont;
        return self.bytes[offset..][0..4].*;
    }
};

/// How a rule value is compared with a glyph.
const Match = union(enum) {
    /// The value is the glyph id.
    glyph,
    /// The value is the glyph's class in the class definition at this offset.
    class: usize,
    /// The value is the offset, from this base, of a coverage table the glyph
    /// must be in.
    coverage: usize,
};

/// Features applied together, and the glyphs they apply to.
pub const Stage = struct {
    features: []const Tag,
    /// Applied at glyphs whose `Glyph.mask` shares a bit with this.
    mask: u32 = std.math.maxInt(u32),
};

/// Lookups chosen for a script, language and feature set.
pub const Plan = struct {
    /// Lookup list indices, in application order.
    lookups: []u16,
    /// Per lookup, one bit per glyph: set if the lookup can start at that glyph
    /// (all set when unknown).
    starts: []std.DynamicBitSetUnmanaged,
    /// Per lookup, the `Glyph.mask` bits it applies to.
    masks: []u32,

    /// `gpa` must be the allocator the plan was made with.
    pub fn deinit(self: *Plan, gpa: std.mem.Allocator) void {
        for (self.starts) |*set| set.deinit(gpa);
        gpa.free(self.starts);
        gpa.free(self.masks);
        gpa.free(self.lookups);
        self.* = undefined;
    }
};

/// A font's GSUB or GPOS table. Holds offsets into the borrowed file bytes,
/// which must outlive it; owns no memory.
pub const Layout = struct {
    reader: Reader,
    /// True for GPOS, false for GSUB.
    positions: bool = false,
    /// File offsets of the script, feature and lookup lists.
    script_list: usize,
    feature_list: usize,
    lookup_list: usize,
    /// GDEF glyph class definition (base, ligature, mark).
    glyph_classes: ?usize = null,
    /// GDEF mark attachment class definition.
    mark_classes: ?usize = null,
    /// GDEF mark glyph sets.
    mark_sets: ?usize = null,

    /// `table` is the file offset of GSUB, `gdef` that of GDEF if present.
    pub fn init(bytes: []const u8, table: usize, gdef: ?usize) !Layout {
        const reader = Reader{ .bytes = bytes };
        if (try reader.u16At(table) != 1) return error.UnsupportedFont;
        var self = Layout{
            .reader = reader,
            .script_list = table + try reader.u16At(table + 4),
            .feature_list = table + try reader.u16At(table + 6),
            .lookup_list = table + try reader.u16At(table + 8),
        };
        if (gdef) |start| {
            const classes = try reader.u16At(start + 4);
            if (classes != 0) self.glyph_classes = start + classes;
            const marks = try reader.u16At(start + 10);
            if (marks != 0) self.mark_classes = start + marks;
            if (try reader.u16At(start + 2) >= 2) {
                const sets = try reader.u16At(start + 12);
                if (sets != 0) self.mark_sets = start + sets;
            }
        }
        return self;
    }

    /// As `init`, for GPOS. Only advance adjustments are applied: single
    /// adjustments, and contexts with the single and pair adjustments they
    /// call.
    pub fn initPositions(bytes: []const u8, table: usize, gdef: ?usize) !Layout {
        var self = try init(bytes, table, gdef);
        self.positions = true;
        return self;
    }

    /// Lookups of `features` for a script and language, in application order,
    /// each once. Unknown scripts and languages fall back to the defaults.
    /// Owned
    /// by the caller.
    pub fn lookups(self: Layout, gpa: std.mem.Allocator, script: Tag, language: ?Tag, features: []const Tag) ![]u16 {
        var found: std.ArrayList(u16) = .empty;
        errdefer found.deinit(gpa);
        const reader = self.reader;
        const system = (try self.languageSystem(script, language)) orelse return found.toOwnedSlice(gpa);
        const required = try reader.u16At(system + 2);
        const count = try reader.u16At(system + 4);
        const feature_count = try reader.u16At(self.feature_list);
        for (0..@as(usize, count) + 1) |entry| {
            const index = if (entry == count) required else try reader.u16At(system + 6 + entry * 2);
            if (index >= feature_count) continue;
            const record = self.feature_list + 2 + @as(usize, index) * 6;
            const tag = try reader.tagAt(record);
            var wanted = entry == count;
            for (features) |feature| {
                if (std.mem.eql(u8, &feature, &tag)) wanted = true;
            }
            if (!wanted) continue;
            const feature = self.feature_list + try reader.u16At(record + 4);
            const lookup_count = try reader.u16At(feature + 2);
            for (0..lookup_count) |lookup| {
                const value = try reader.u16At(feature + 4 + lookup * 2);
                if (std.mem.indexOfScalar(u16, found.items, value) == null) try found.append(gpa, value);
            }
        }
        std.mem.sort(u16, found.items, {}, std.sort.asc(u16));
        return found.toOwnedSlice(gpa);
    }

    /// As `lookups`, with each lookup's start glyphs precomputed. Owned by the
    /// caller.
    pub fn plan(self: Layout, gpa: std.mem.Allocator, script: Tag, language: ?Tag, features: []const Tag, glyph_count: u32) !Plan {
        return self.planStages(gpa, script, language, &.{.{ .features = features }}, glyph_count);
    }

    /// A plan of stages applied in order, each only at glyphs sharing a bit
    /// with its mask.
    pub fn planStages(self: Layout, gpa: std.mem.Allocator, script: Tag, language: ?Tag, stages: []const Stage, glyph_count: u32) !Plan {
        var indices: std.ArrayList(u16) = .empty;
        defer indices.deinit(gpa);
        var masks: std.ArrayList(u32) = .empty;
        defer masks.deinit(gpa);
        for (stages) |stage| {
            const found = try self.lookups(gpa, script, language, stage.features);
            defer gpa.free(found);
            try indices.appendSlice(gpa, found);
            try masks.appendNTimes(gpa, stage.mask, found.len);
        }
        const starts = try gpa.alloc(std.DynamicBitSetUnmanaged, indices.items.len);
        var made: usize = 0;
        errdefer {
            for (starts[0..made]) |*set| set.deinit(gpa);
            gpa.free(starts);
        }
        for (indices.items, starts) |index, *set| {
            set.* = try std.DynamicBitSetUnmanaged.initEmpty(gpa, glyph_count);
            made += 1;
            self.markStarts(index, set) catch set.setRangeValue(.{ .start = 0, .end = glyph_count }, true);
        }
        const kept_masks = try masks.toOwnedSlice(gpa);
        errdefer gpa.free(kept_masks);
        return .{ .lookups = try indices.toOwnedSlice(gpa), .starts = starts, .masks = kept_masks };
    }

    /// Sets the glyphs a lookup's subtables can start at.
    fn markStarts(self: Layout, index: u16, set: *std.DynamicBitSetUnmanaged) !void {
        const reader = self.reader;
        const lookup = (try self.lookupAt(index)) orelse return;
        const kind = try reader.u16At(lookup);
        for (0..try reader.u16At(lookup + 4)) |entry| {
            var subtable = lookup + try reader.u16At(lookup + 6 + entry * 2);
            var actual = kind;
            const extension: u16 = if (self.positions) 9 else 7;
            if (kind == extension) {
                actual = try reader.u16At(subtable + 2);
                subtable += try reader.u32At(subtable + 4);
            }
            if (self.positions) actual = switch (actual) {
                1 => 1,
                7 => 5,
                8 => 6,
                else => continue,
            };
            const format = try reader.u16At(subtable);
            const coverage: usize = switch (actual) {
                1, 2, 3, 4 => subtable + try reader.u16At(subtable + 2),
                5 => if (format == 3) subtable + try reader.u16At(subtable + 6) else subtable + try reader.u16At(subtable + 2),
                6 => if (format == 3) first: {
                    const input_at = subtable + 4 + @as(usize, try reader.u16At(subtable + 2)) * 2;
                    if (try reader.u16At(input_at) == 0) continue;
                    break :first subtable + try reader.u16At(input_at + 2);
                } else subtable + try reader.u16At(subtable + 2),
                else => continue,
            };
            const count = try reader.u16At(coverage + 2);
            switch (try reader.u16At(coverage)) {
                1 => for (0..count) |glyph| {
                    const id = try reader.u16At(coverage + 4 + glyph * 2);
                    if (id < set.bit_length) set.set(id);
                },
                2 => for (0..count) |range| {
                    const start = try reader.u16At(coverage + 4 + range * 6);
                    const end = try reader.u16At(coverage + 6 + range * 6);
                    var id: usize = start;
                    while (id <= end and id < set.bit_length) : (id += 1) set.set(id);
                },
                else => {},
            }
        }
    }

    /// Applies a plan's lookups to a glyph run. Returns whether anything
    /// changed.
    pub fn substitutePlanned(self: Layout, gpa: std.mem.Allocator, glyphs: *std.ArrayList(Glyph), planned: Plan) !bool {
        var changed = false;
        for (planned.lookups, planned.starts, planned.masks) |index, starts, mask| {
            var lookup: ?usize = null;
            var flag: u32 = 0;
            var at: usize = 0;
            while (at < glyphs.items.len) {
                const id = glyphs.items[at].id;
                if (id >= starts.bit_length or !starts.isSet(id) or glyphs.items[at].mask & mask == 0) {
                    at += 1;
                    continue;
                }
                if (lookup == null) {
                    lookup = (try self.lookupAt(index)) orelse break;
                    flag = try self.flagsOf(lookup.?);
                }
                if (try self.passedOver(flag, id)) {
                    at += 1;
                    continue;
                }
                if (try self.applyAt(gpa, glyphs, lookup.?, at, 0)) |moved| {
                    changed = true;
                    at += moved;
                } else at += 1;
            }
        }
        return changed;
    }

    fn languageSystem(self: Layout, script: Tag, language: ?Tag) !?usize {
        const reader = self.reader;
        const count = try reader.u16At(self.script_list);
        var chosen: ?usize = null;
        var fallback: ?usize = null;
        for (0..count) |index| {
            const record = self.script_list + 2 + index * 6;
            const tag = try reader.tagAt(record);
            const table = self.script_list + try reader.u16At(record + 4);
            if (std.mem.eql(u8, &tag, &script)) chosen = table;
            if (std.mem.eql(u8, &tag, "DFLT")) fallback = table;
        }
        const table = chosen orelse fallback orelse return null;
        if (language) |wanted| {
            const languages = try reader.u16At(table + 2);
            for (0..languages) |index| {
                const record = table + 4 + index * 6;
                if (std.mem.eql(u8, &(try reader.tagAt(record)), &wanted)) return table + try reader.u16At(record + 4);
            }
        }
        const default = try reader.u16At(table);
        return if (default == 0) null else table + default;
    }

    /// Applies lookups, in the order given, to a glyph run.
    pub fn substitute(self: Layout, gpa: std.mem.Allocator, glyphs: *std.ArrayList(Glyph), lookup_indices: []const u16) !void {
        for (lookup_indices) |index| {
            const lookup = (try self.lookupAt(index)) orelse continue;
            const flag = try self.flagsOf(lookup);
            var at: usize = 0;
            while (at < glyphs.items.len) {
                if (try self.passedOver(flag, glyphs.items[at].id)) {
                    at += 1;
                    continue;
                }
                at += (try self.applyAt(gpa, glyphs, lookup, at, 0)) orelse 1;
            }
        }
    }

    /// File offset of lookup `index`, or null when out of range.
    pub fn lookupAt(self: Layout, index: u16) !?usize {
        if (index >= try self.reader.u16At(self.lookup_list)) return null;
        return self.lookup_list + try self.reader.u16At(self.lookup_list + 2 + @as(usize, index) * 2);
    }

    /// A lookup's flags, with its mark filtering set index in the upper 16
    /// bits.
    fn flagsOf(self: Layout, lookup: usize) !u32 {
        const flag: u32 = try self.reader.u16At(lookup + 2);
        if (flag & 0x10 == 0) return flag;
        const count = try self.reader.u16At(lookup + 4);
        return flag | (@as(u32, try self.reader.u16At(lookup + 6 + @as(usize, count) * 2)) << 16);
    }

    pub fn isMark(self: Layout, glyph: u16) bool {
        const classes = self.glyph_classes orelse return false;
        return (self.classOf(classes, glyph) catch 0) == 3;
    }

    /// Whether a lookup with these flags skips the glyph.
    fn passedOver(self: Layout, flag: u32, glyph: u16) !bool {
        if (flag & 0xff1e == 0) return false;
        const classes = self.glyph_classes orelse return false;
        const class = try self.classOf(classes, glyph);
        if (class == 1 and flag & 2 != 0) return true;
        if (class == 2 and flag & 4 != 0) return true;
        if (class != 3) return false;
        if (flag & 8 != 0) return true;
        if (flag & 0x10 != 0) if (self.mark_sets) |sets| {
            const set = flag >> 16;
            if (set < try self.reader.u16At(sets + 2)) {
                const coverage = sets + try self.reader.u32At(sets + 4 + @as(usize, set) * 4);
                if ((try self.coverageIndex(coverage, glyph)) == null) return true;
            }
        };
        const kind = (flag >> 8) & 0xff;
        if (kind == 0) return false;
        const marks = self.mark_classes orelse return false;
        return try self.classOf(marks, glyph) != kind;
    }

    fn next(self: Layout, glyphs: []const Glyph, flag: u32, from: usize) !?usize {
        var at = from + 1;
        while (at < glyphs.len) : (at += 1) {
            if (!try self.passedOver(flag, glyphs[at].id)) return at;
        }
        return null;
    }

    fn previous(self: Layout, glyphs: []const Glyph, flag: u32, from: usize) !?usize {
        var at = from;
        while (at > 0) {
            at -= 1;
            if (!try self.passedOver(flag, glyphs[at].id)) return at;
        }
        return null;
    }

    /// Tries the lookup's subtables at `at`. Null when none applies, else how
    /// many glyphs to advance by.
    fn applyAt(self: Layout, gpa: std.mem.Allocator, glyphs: *std.ArrayList(Glyph), lookup: usize, at: usize, depth: u32) anyerror!?usize {
        const reader = self.reader;
        const kind = try reader.u16At(lookup);
        const flag = try self.flagsOf(lookup);
        const count = try reader.u16At(lookup + 4);
        for (0..count) |index| {
            var subtable = lookup + try reader.u16At(lookup + 6 + index * 2);
            var actual = kind;
            const extension: u16 = if (self.positions) 9 else 7;
            if (kind == extension) {
                actual = try reader.u16At(subtable + 2);
                subtable += try reader.u32At(subtable + 4);
            }
            if (self.positions) {
                const placed = switch (actual) {
                    1 => try self.adjustOne(glyphs, subtable, at),
                    2 => if (depth == 0) null else try self.adjustPair(glyphs, subtable, flag, at),
                    7 => try self.context(gpa, glyphs, subtable, flag, at, depth),
                    8 => try self.chained(gpa, glyphs, subtable, flag, at, depth),
                    else => null,
                };
                if (placed) |by| return by;
                continue;
            }
            const moved = switch (actual) {
                1 => try self.single(glyphs, subtable, at),
                2 => try self.multiple(gpa, glyphs, subtable, at),
                3 => try self.alternate(glyphs, subtable, at),
                4 => try self.ligature(glyphs, subtable, flag, at),
                5 => try self.context(gpa, glyphs, subtable, flag, at, depth),
                6 => try self.chained(gpa, glyphs, subtable, flag, at, depth),
                else => null,
            };
            if (moved) |by| return by;
        }
        return null;
    }

    /// Size in bytes of a GPOS value record of this format.
    fn valueSize(format: u16) usize {
        return @as(usize, @popCount(format & 0xff)) * 2;
    }

    /// The advance a GPOS value record adds.
    fn valueAdvance(self: Layout, record: usize, format: u16) !i32 {
        if (format & 4 == 0) return 0;
        return try self.reader.i16At(record + @as(usize, @popCount(format & 3)) * 2);
    }

    /// GPOS single adjustment.
    fn adjustOne(self: Layout, glyphs: *std.ArrayList(Glyph), subtable: usize, at: usize) !?usize {
        const reader = self.reader;
        const covered = (try self.coverageIndex(subtable + try reader.u16At(subtable + 2), glyphs.items[at].id)) orelse return null;
        const format = try reader.u16At(subtable + 4);
        if (try reader.u16At(subtable) == 1) {
            glyphs.items[at].advance += try self.valueAdvance(subtable + 6, format);
        } else {
            if (covered >= try reader.u16At(subtable + 6)) return null;
            glyphs.items[at].advance += try self.valueAdvance(subtable + 8 + covered * valueSize(format), format);
        }
        return 1;
    }

    /// GPOS pair adjustment.
    fn adjustPair(self: Layout, glyphs: *std.ArrayList(Glyph), subtable: usize, flag: u32, at: usize) !?usize {
        const reader = self.reader;
        const first = glyphs.items[at].id;
        const covered = (try self.coverageIndex(subtable + try reader.u16At(subtable + 2), first)) orelse return null;
        const after = (try self.next(glyphs.items, flag, at)) orelse return null;
        const second = glyphs.items[after].id;
        const format_one = try reader.u16At(subtable + 4);
        const format_two = try reader.u16At(subtable + 6);
        const size_one = valueSize(format_one);
        const size_two = valueSize(format_two);
        if (try reader.u16At(subtable) == 1) {
            if (covered >= try reader.u16At(subtable + 8)) return null;
            const set = subtable + try reader.u16At(subtable + 10 + covered * 2);
            const record_size = 2 + size_one + size_two;
            for (0..try reader.u16At(set)) |index| {
                const record = set + 2 + index * record_size;
                if (try reader.u16At(record) != second) continue;
                glyphs.items[at].advance += try self.valueAdvance(record + 2, format_one);
                glyphs.items[after].advance += try self.valueAdvance(record + 2 + size_one, format_two);
                return 1;
            }
            return null;
        }
        if (try reader.u16At(subtable) != 2) return null;
        const class_one = try self.classOf(subtable + try reader.u16At(subtable + 8), first);
        const class_two = try self.classOf(subtable + try reader.u16At(subtable + 10), second);
        const count_one = try reader.u16At(subtable + 12);
        const count_two = try reader.u16At(subtable + 14);
        if (class_one >= count_one or class_two >= count_two) return null;
        const record = subtable + 16 + (@as(usize, class_one) * count_two + class_two) * (size_one + size_two);
        glyphs.items[at].advance += try self.valueAdvance(record, format_one);
        glyphs.items[after].advance += try self.valueAdvance(record + size_one, format_two);
        return 1;
    }

    fn single(self: Layout, glyphs: *std.ArrayList(Glyph), subtable: usize, at: usize) !?usize {
        const reader = self.reader;
        const glyph = glyphs.items[at].id;
        const covered = (try self.coverageIndex(subtable + try reader.u16At(subtable + 2), glyph)) orelse return null;
        if (try reader.u16At(subtable) == 1) {
            glyphs.items[at].id = glyph +% try reader.u16At(subtable + 4);
        } else {
            if (covered >= try reader.u16At(subtable + 4)) return null;
            glyphs.items[at].id = try reader.u16At(subtable + 6 + covered * 2);
        }
        return 1;
    }

    fn multiple(self: Layout, gpa: std.mem.Allocator, glyphs: *std.ArrayList(Glyph), subtable: usize, at: usize) !?usize {
        const reader = self.reader;
        const covered = (try self.coverageIndex(subtable + try reader.u16At(subtable + 2), glyphs.items[at].id)) orelse return null;
        if (covered >= try reader.u16At(subtable + 4)) return null;
        const sequence = subtable + try reader.u16At(subtable + 6 + covered * 2);
        const count = try reader.u16At(sequence);
        const cluster = glyphs.items[at].cluster;
        const mask = glyphs.items[at].mask;
        if (count == 0) {
            _ = glyphs.orderedRemove(at);
            return 0;
        }
        if (glyphs.items.len + count > max_glyphs) return null;
        glyphs.items[at].id = try reader.u16At(sequence + 2);
        try glyphs.ensureUnusedCapacity(gpa, count - 1);
        for (1..count) |part| glyphs.insertAssumeCapacity(at + part, .{ .id = try reader.u16At(sequence + 2 + part * 2), .cluster = cluster, .mask = mask });
        return count;
    }

    fn alternate(self: Layout, glyphs: *std.ArrayList(Glyph), subtable: usize, at: usize) !?usize {
        const reader = self.reader;
        const covered = (try self.coverageIndex(subtable + try reader.u16At(subtable + 2), glyphs.items[at].id)) orelse return null;
        if (covered >= try reader.u16At(subtable + 4)) return null;
        const set = subtable + try reader.u16At(subtable + 6 + covered * 2);
        if (try reader.u16At(set) == 0) return null;
        glyphs.items[at].id = try reader.u16At(set + 2);
        return 1;
    }

    fn ligature(self: Layout, glyphs: *std.ArrayList(Glyph), subtable: usize, flag: u32, at: usize) !?usize {
        const reader = self.reader;
        const covered = (try self.coverageIndex(subtable + try reader.u16At(subtable + 2), glyphs.items[at].id)) orelse return null;
        if (covered >= try reader.u16At(subtable + 4)) return null;
        const set = subtable + try reader.u16At(subtable + 6 + covered * 2);
        const count = try reader.u16At(set);
        candidates: for (0..count) |index| {
            const entry = set + try reader.u16At(set + 2 + index * 2);
            const parts = try reader.u16At(entry + 2);
            if (parts == 0 or parts > max_input) continue;
            var places: [max_input]usize = undefined;
            places[0] = at;
            for (1..parts) |part| {
                const place = (try self.next(glyphs.items, flag, places[part - 1])) orelse continue :candidates;
                if (glyphs.items[place].id != try reader.u16At(entry + 4 + (part - 1) * 2)) continue :candidates;
                places[part] = place;
            }
            for (1..parts) |part| {
                for (places[part - 1] + 1..places[part]) |between| glyphs.items[between].component = @intCast(part);
            }
            glyphs.items[at].id = try reader.u16At(entry);
            var part = parts;
            while (part > 1) : (part -= 1) _ = glyphs.orderedRemove(places[part - 1]);
            return 1;
        }
        return null;
    }

    fn context(self: Layout, gpa: std.mem.Allocator, glyphs: *std.ArrayList(Glyph), subtable: usize, flag: u32, at: usize, depth: u32) !?usize {
        const reader = self.reader;
        const glyph = glyphs.items[at].id;
        const format = try reader.u16At(subtable);
        if (format == 3) {
            const count = try reader.u16At(subtable + 2);
            const records = try reader.u16At(subtable + 4);
            if (count == 0) return null;
            if ((try self.coverageIndex(subtable + try reader.u16At(subtable + 6), glyph)) == null) return null;
            var places: [max_input]usize = undefined;
            if (!try self.matchInput(glyphs.items, flag, at, subtable + 8, count, .{ .coverage = subtable }, &places)) return null;
            return try self.applyRecords(gpa, glyphs, subtable + 6 + @as(usize, count) * 2, records, &places, count, depth);
        }
        if (format != 1 and format != 2) return null;
        const covered = (try self.coverageIndex(subtable + try reader.u16At(subtable + 2), glyph)) orelse return null;
        const classes = subtable + try reader.u16At(subtable + 4);
        const match: Match = if (format == 1) .glyph else .{ .class = classes };
        const set_index: usize = if (format == 1) covered else try self.classOf(classes, glyph);
        const sets: usize = if (format == 1) subtable + 4 else subtable + 6;
        if (set_index >= try reader.u16At(sets)) return null;
        const set_offset = try reader.u16At(sets + 2 + set_index * 2);
        if (set_offset == 0) return null;
        const set = subtable + set_offset;
        for (0..try reader.u16At(set)) |index| {
            const rule = set + try reader.u16At(set + 2 + index * 2);
            const count = try reader.u16At(rule);
            const records = try reader.u16At(rule + 2);
            if (count == 0) continue;
            var places: [max_input]usize = undefined;
            if (!try self.matchInput(glyphs.items, flag, at, rule + 4, count, match, &places)) continue;
            return try self.applyRecords(gpa, glyphs, rule + 4 + (@as(usize, count) - 1) * 2, records, &places, count, depth);
        }
        return null;
    }

    fn chained(self: Layout, gpa: std.mem.Allocator, glyphs: *std.ArrayList(Glyph), subtable: usize, flag: u32, at: usize, depth: u32) !?usize {
        const reader = self.reader;
        const glyph = glyphs.items[at].id;
        const format = try reader.u16At(subtable);
        if (format == 3) {
            const before = try reader.u16At(subtable + 2);
            const input_at = subtable + 4 + @as(usize, before) * 2;
            const count = try reader.u16At(input_at);
            const after_at = input_at + 2 + @as(usize, count) * 2;
            const after = try reader.u16At(after_at);
            const records_at = after_at + 2 + @as(usize, after) * 2;
            if (count == 0) return null;
            if ((try self.coverageIndex(subtable + try reader.u16At(input_at + 2), glyph)) == null) return null;
            const match = Match{ .coverage = subtable };
            var places: [max_input]usize = undefined;
            if (!try self.matchInput(glyphs.items, flag, at, input_at + 4, count, match, &places)) return null;
            if (!try self.matchBefore(glyphs.items, flag, at, subtable + 4, before, match)) return null;
            if (!try self.matchAfter(glyphs.items, flag, places[count - 1], after_at + 2, after, match)) return null;
            return try self.applyRecords(gpa, glyphs, records_at + 2, try reader.u16At(records_at), &places, count, depth);
        }
        if (format != 1 and format != 2) return null;
        const covered = (try self.coverageIndex(subtable + try reader.u16At(subtable + 2), glyph)) orelse return null;
        const before_match: Match = if (format == 1) .glyph else .{ .class = subtable + try reader.u16At(subtable + 4) };
        const input_classes = subtable + try reader.u16At(subtable + 6);
        const input_match: Match = if (format == 1) .glyph else .{ .class = input_classes };
        const after_match: Match = if (format == 1) .glyph else .{ .class = subtable + try reader.u16At(subtable + 8) };
        const set_index: usize = if (format == 1) covered else try self.classOf(input_classes, glyph);
        const sets: usize = if (format == 1) subtable + 4 else subtable + 10;
        if (set_index >= try reader.u16At(sets)) return null;
        const set_offset = try reader.u16At(sets + 2 + set_index * 2);
        if (set_offset == 0) return null;
        const set = subtable + set_offset;
        for (0..try reader.u16At(set)) |index| {
            const rule = set + try reader.u16At(set + 2 + index * 2);
            const before = try reader.u16At(rule);
            const input_at = rule + 2 + @as(usize, before) * 2;
            const count = try reader.u16At(input_at);
            if (count == 0) continue;
            const after_at = input_at + 2 + (@as(usize, count) - 1) * 2;
            const after = try reader.u16At(after_at);
            const records_at = after_at + 2 + @as(usize, after) * 2;
            var places: [max_input]usize = undefined;
            if (!try self.matchInput(glyphs.items, flag, at, input_at + 2, count, input_match, &places)) continue;
            if (!try self.matchBefore(glyphs.items, flag, at, rule + 2, before, before_match)) continue;
            if (!try self.matchAfter(glyphs.items, flag, places[count - 1], after_at + 2, after, after_match)) continue;
            return try self.applyRecords(gpa, glyphs, records_at + 2, try reader.u16At(records_at), &places, count, depth);
        }
        return null;
    }

    fn matches(self: Layout, match: Match, value: u16, glyph: u16) !bool {
        return switch (match) {
            .glyph => value == glyph,
            .class => |classes| try self.classOf(classes, glyph) == value,
            .coverage => |base| (try self.coverageIndex(base + value, glyph)) != null,
        };
    }

    /// Matches a rule's input glyphs after the first, whose values start at
    /// `values`; writes where each was found to `places`.
    fn matchInput(self: Layout, glyphs: []const Glyph, flag: u32, at: usize, values: usize, count: u16, match: Match, places: *[max_input]usize) !bool {
        if (count > max_input) return false;
        places[0] = at;
        for (1..count) |index| {
            const place = (try self.next(glyphs, flag, places[index - 1])) orelse return false;
            if (!try self.matches(match, try self.reader.u16At(values + (index - 1) * 2), glyphs[place].id)) return false;
            places[index] = place;
        }
        return true;
    }

    /// Matches a rule's backtrack sequence, nearest first.
    fn matchBefore(self: Layout, glyphs: []const Glyph, flag: u32, at: usize, values: usize, count: u16, match: Match) !bool {
        var place = at;
        for (0..count) |index| {
            place = (try self.previous(glyphs, flag, place)) orelse return false;
            if (!try self.matches(match, try self.reader.u16At(values + index * 2), glyphs[place].id)) return false;
        }
        return true;
    }

    /// Matches a rule's lookahead sequence.
    fn matchAfter(self: Layout, glyphs: []const Glyph, flag: u32, last: usize, values: usize, count: u16, match: Match) !bool {
        var place = last;
        for (0..count) |index| {
            place = (try self.next(glyphs, flag, place)) orelse return false;
            if (!try self.matches(match, try self.reader.u16At(values + index * 2), glyphs[place].id)) return false;
        }
        return true;
    }

    /// Applies a matched rule's nested lookups at the places its input was
    /// found.
    fn applyRecords(self: Layout, gpa: std.mem.Allocator, glyphs: *std.ArrayList(Glyph), records: usize, record_count: u16, places: *[max_input]usize, count: u16, depth: u32) !?usize {
        const first = places[0];
        var end = places[count - 1] + 1;
        if (depth < max_depth) for (0..record_count) |index| {
            const sequence = try self.reader.u16At(records + index * 4);
            if (sequence >= count) continue;
            const lookup = (try self.lookupAt(try self.reader.u16At(records + index * 4 + 2))) orelse continue;
            const place = places[sequence];
            if (place >= glyphs.items.len) continue;
            const before = glyphs.items.len;
            _ = try self.applyAt(gpa, glyphs, lookup, place, depth + 1);
            const after = glyphs.items.len;
            for (places[0..count]) |*other| {
                if (other.* > place) other.* = other.* + after -| before;
            }
            end = end + after -| before;
        };
        return @max(end -| first, 1);
    }

    fn coverageIndex(self: Layout, coverage: usize, glyph: u16) !?usize {
        const reader = self.reader;
        const format = try reader.u16At(coverage);
        const count = try reader.u16At(coverage + 2);
        var low: usize = 0;
        var high: usize = count;
        if (format == 1) {
            while (low < high) {
                const middle = (low + high) / 2;
                const value = try reader.u16At(coverage + 4 + middle * 2);
                if (value == glyph) return middle;
                if (value < glyph) low = middle + 1 else high = middle;
            }
        } else if (format == 2) {
            while (low < high) {
                const middle = (low + high) / 2;
                const record = coverage + 4 + middle * 6;
                const start = try reader.u16At(record);
                if (glyph < start) {
                    high = middle;
                } else if (glyph > try reader.u16At(record + 2)) {
                    low = middle + 1;
                } else {
                    return @as(usize, try reader.u16At(record + 4)) + glyph - start;
                }
            }
        }
        return null;
    }

    fn classOf(self: Layout, classes: usize, glyph: u16) !u16 {
        const reader = self.reader;
        const format = try reader.u16At(classes);
        if (format == 1) {
            const start = try reader.u16At(classes + 2);
            const count = try reader.u16At(classes + 4);
            if (glyph < start or glyph - start >= count) return 0;
            return reader.u16At(classes + 6 + @as(usize, glyph - start) * 2);
        }
        if (format != 2) return 0;
        var low: usize = 0;
        var high: usize = try reader.u16At(classes + 2);
        while (low < high) {
            const middle = (low + high) / 2;
            const record = classes + 4 + middle * 6;
            if (glyph < try reader.u16At(record)) {
                high = middle;
            } else if (glyph > try reader.u16At(record + 2)) {
                low = middle + 1;
            } else {
                return reader.u16At(record + 4);
            }
        }
        return 0;
    }
};
