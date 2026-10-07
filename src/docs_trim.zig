//! Trims the source archive of `zig build docs` to the named modules.
//!
//!   docs_trim sources.tar trimmed.tar renderer texture_codec
const std = @import("std");

const block = 512;

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    var arguments = try init.minimal.args.iterateAllocator(gpa);
    _ = arguments.next();
    const source_path = arguments.next() orelse return error.MissingArgument;
    const target_path = arguments.next() orelse return error.MissingArgument;
    var kept: std.ArrayList([]const u8) = .empty;
    while (arguments.next()) |name| try kept.append(gpa, name);

    const source = try std.Io.Dir.cwd().readFileAlloc(init.io, source_path, gpa, .unlimited);
    var trimmed: std.ArrayList(u8) = .empty;
    var offset: usize = 0;
    while (offset + block <= source.len) {
        const header = source[offset..][0..block];
        const name = std.mem.sliceTo(header[0..100], 0);
        if (name.len == 0) break;
        const size = try std.fmt.parseInt(usize, std.mem.trim(u8, header[124..136], " \x00"), 8);
        const length = block + std.mem.alignForward(usize, size, block);
        if (offset + length > source.len) return error.TruncatedArchive;
        const module = name[0 .. std.mem.indexOfScalar(u8, name, '/') orelse name.len];
        for (kept.items) |wanted| {
            if (!std.mem.eql(u8, module, wanted)) continue;
            try trimmed.appendSlice(gpa, source[offset..][0..length]);
            break;
        }
        offset += length;
    }
    try trimmed.appendNTimes(gpa, 0, block * 2);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = target_path, .data = trimmed.items });
}
