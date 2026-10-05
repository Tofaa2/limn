//! Cuts the archive of sources that `zig build docs` shows down to the
//! modules named on the command line. The compiler puts every module the
//! library was built with into it, the standard library and the generated
//! Vulkan bindings included: twenty megabytes for a browser to fetch and
//! index, against the one or two that are this library's own.
//!
//!   docs_trim sources.tar trimmed.tar renderer texture_codec
const std = @import("std");

const block = 512;

/// Copies the entries of the kept modules from the first archive to the second.
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
        // Two empty blocks end an archive.
        if (name.len == 0) break;
        const size = try std.fmt.parseInt(usize, std.mem.trim(u8, header[124..136], " \x00"), 8);
        const length = block + std.mem.alignForward(usize, size, block);
        if (offset + length > source.len) return error.TruncatedArchive;
        // An entry is named `module/path/in/the/module.zig`.
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
