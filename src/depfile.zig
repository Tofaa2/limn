//! Runs a shader compiler, then rewrites the depfile it wrote into one Zig's
//! build cache reads on every host. slangc and glslang escape `\` and `:` the
//! way make does, and the cache takes those names as they are, so no Windows
//! path survives them.
//!
//!   depfile <compiler> <arguments...>
//!
//! The depfile is the argument after `-depfile` or `--depfile`.
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    var arguments = try init.minimal.args.iterateAllocator(gpa);
    _ = arguments.next();
    var argv: std.ArrayList([]const u8) = .empty;
    while (arguments.next()) |argument| try argv.append(gpa, argument);
    if (argv.items.len == 0) return error.MissingArgument;
    var child = try std.process.spawn(init.io, .{ .argv = argv.items });
    switch (try child.wait(init.io)) {
        .exited => |code| if (code != 0) std.process.exit(code),
        else => std.process.exit(1),
    }
    const path = for (argv.items[0 .. argv.items.len - 1], argv.items[1..]) |flag, value| {
        if (std.mem.eql(u8, flag, "-depfile") or std.mem.eql(u8, flag, "--depfile")) break value;
    } else return;
    const escaped = try std.Io.Dir.cwd().readFileAlloc(init.io, path, gpa, .unlimited);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = try quoted(gpa, escaped) });
}

/// One rule naming every prerequisite in quotes with its escapes undone,
/// since the cache takes a quoted name exactly as written.
fn quoted(gpa: std.mem.Allocator, escaped: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(gpa, "deps:");
    var in_target = true;
    var in_name = false;
    var index: usize = 0;
    while (index < escaped.len) : (index += 1) {
        var char = escaped[index];
        switch (char) {
            ' ', '\t', '\r', '\n' => {
                if (in_name) try out.append(gpa, '"');
                in_name = false;
                if (char == '\n') in_target = true;
                continue;
            },
            ':' => if (in_target and !(index + 1 < escaped.len and (escaped[index + 1] == '\\' or escaped[index + 1] == '/'))) {
                in_target = false;
                continue;
            },
            '\\' => if (index + 1 < escaped.len) switch (escaped[index + 1]) {
                ' ', ':', '#', '[', ']', '\\' => {
                    index += 1;
                    char = escaped[index];
                },
                '\r', '\n' => {
                    index += 1;
                    if (escaped[index] == '\r' and index + 1 < escaped.len and escaped[index + 1] == '\n') index += 1;
                    if (in_name) try out.append(gpa, '"');
                    in_name = false;
                    continue;
                },
                else => {},
            },
            '$' => if (index + 1 < escaped.len and escaped[index + 1] == '$') {
                index += 1;
            },
            else => {},
        }
        if (in_target) continue;
        if (!in_name) try out.appendSlice(gpa, " \"");
        in_name = true;
        try out.append(gpa, char);
    }
    if (in_name) try out.append(gpa, '"');
    try out.append(gpa, '\n');
    return out.toOwnedSlice(gpa);
}

fn expectPrerequisites(escaped: []const u8, expected: []const []const u8) !void {
    const gpa = std.testing.allocator;
    const rewritten = try quoted(gpa, escaped);
    defer gpa.free(rewritten);
    var tokens: std.Build.Cache.DepTokenizer = .{ .bytes = rewritten };
    var found: usize = 0;
    while (tokens.next()) |token| switch (token) {
        .target => {},
        .prereq => |name| {
            try std.testing.expect(found < expected.len);
            try std.testing.expectEqualStrings(expected[found], name);
            found += 1;
        },
        else => return error.UnexpectedToken,
    };
    try std.testing.expectEqual(expected.len, found);
}

test "slangc's Windows depfile reads back as plain paths" {
    try expectPrerequisites(".\\\\w.spv: D\\:\\\\a\\\\limn\\\\t.slang D\\:\\\\a\\\\limn\\\\inc\\\\helper.slang\n", &.{ "D:\\a\\limn\\t.slang", "D:\\a\\limn\\inc\\helper.slang" });
}

test "glslang's escapes, spaces and continued lines are undone" {
    try expectPrerequisites("out.spv: /home/a\\ b/x.glsl \\\r\n /i/\\[1\\]\\#.h $$HOME/y.h\r\n", &.{ "/home/a b/x.glsl", "/i/[1]#.h", "$HOME/y.h" });
}

test "a depfile without escapes keeps its names" {
    try expectPrerequisites("./x.spv: /tmp/dep/t.slang /tmp/dep/inc/helper.slang\n", &.{ "/tmp/dep/t.slang", "/tmp/dep/inc/helper.slang" });
}

test "an unescaped Windows rule keeps its drive letters" {
    try expectPrerequisites("D:\\o.spv: D:\\a\\b.glsl\r\n", &.{"D:\\a\\b.glsl"});
}
