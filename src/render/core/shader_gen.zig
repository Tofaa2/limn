//! Shader declarations written from the Zig types they must match, at build
//! time. Imports nothing but `std` and the types.
const std = @import("std");
const frame_constants = @import("frame_constants.zig");
const push = @import("../shaders/push/all.zig");

/// `frame_constants.slang`: the flag bits, and the `FrameConstants` block as a
/// pointer.
pub const frame_slang = header ++ constants("FEATURE_", frame_constants.features) ++
    record("GiCascade", frame_constants.GiCascade) ++ blocks() ++
    "\nstruct FrameConstantsData {\n" ++ fields(frame_constants.FrameConstants) ++ "};\ntypedef FrameConstantsData* FrameConstants;\n";

/// A generated shader header: its file name and text.
pub const File = struct { name: []const u8, text: []const u8 };

/// One header per push constant struct of `shaders/push`, named
/// `<shader file>.<struct>.slang`.
pub const push_files: []const File = blk: {
    @setEvalBranchQuota(1_000_000);
    var list: []const File = &.{};
    for (push.files) |entry| {
        const stem = entry[0];
        const module = entry[1];
        for (@typeInfo(module).@"struct".decls) |decl| {
            const T = @field(module, decl.name);
            if (@TypeOf(T) != type or @typeInfo(T) != .@"struct" or @typeInfo(T).@"struct".layout != .@"extern") continue;
            list = list ++ [_]File{.{ .name = stem ++ "." ++ decl.name ++ ".slang", .text = push_header ++ record(decl.name, T) }};
        }
    }
    break :blk list;
};

const push_header = "// Generated from src/render/shaders/push by the build; edit that file.\n";

const header = "// Generated from src/render/core/frame_constants.zig by the build; edit that file.\n\n";

/// One `uint` constant per declaration of `namespace`, named `prefix` and the
/// declaration's name in capitals.
fn constants(comptime prefix: []const u8, comptime namespace: type) []const u8 {
    comptime {
        var text: []const u8 = "";
        for (@typeInfo(namespace).@"struct".decls) |decl| {
            var name: [decl.name.len]u8 = undefined;
            _ = std.ascii.upperString(&name, decl.name);
            text = text ++ std.fmt.comptimePrint("static const uint {s}{s} = {d}u;\n", .{ prefix, name, @field(namespace, decl.name) });
        }
        return text;
    }
}

/// The fields of the extern struct `T` as shader members. A `u64` is an
/// address, typed by `T.references`.
fn fields(comptime T: type) []const u8 {
    comptime {
        @setEvalBranchQuota(100_000);
        var text: []const u8 = "";
        for (@typeInfo(T).@"struct".fields) |field| {
            var count: ?usize = null;
            var element = field.type;
            if (@typeInfo(element) == .array) {
                const child = @typeInfo(element).array.child;
                if (@typeInfo(child) == .array or @typeInfo(child) == .@"struct" or child == u64) {
                    count = @typeInfo(element).array.len;
                    element = child;
                }
            }
            const name = if (@hasDecl(T, "references") and @hasField(@TypeOf(T.references), field.name)) @field(T.references, field.name) else typeName(element);
            text = text ++ "    " ++ name ++ " " ++ field.name ++ (if (count) |n| std.fmt.comptimePrint("[{d}]", .{n}) else "") ++ ";\n";
        }
        return text;
    }
}

/// The struct of each feature block of `FrameConstants`, named after its type.
fn blocks() []const u8 {
    comptime {
        var text: []const u8 = "";
        for (@typeInfo(frame_constants.FrameConstants).@"struct".fields) |field| {
            if (@typeInfo(field.type) != .@"struct") continue;
            text = text ++ record(typeName(field.type), field.type);
        }
        return text;
    }
}

/// The extern struct `T` as a shader struct called `name`.
fn record(comptime name: []const u8, comptime T: type) []const u8 {
    return "\nstruct " ++ name ++ " {\n" ++ fields(T) ++ "};\n";
}

fn typeName(comptime T: type) []const u8 {
    if (@typeInfo(T) == .@"enum") return typeName(@typeInfo(T).@"enum".tag_type);
    if (@typeInfo(T) == .@"struct") {
        const full = @typeName(T);
        return full[std.mem.lastIndexOfScalar(u8, full, '.').? + 1 ..];
    }
    return switch (T) {
        f32 => "float",
        u32 => "uint",
        i32 => "int",
        u64 => "uint64_t",
        [2]u32 => "uint2",
        [3]u32 => "uint3",
        [4]u32 => "uint4",
        [2]i32 => "int2",
        [4]i32 => "int4",
        [2]f32 => "float2",
        [3]f32 => "float3",
        [4]f32 => "float4",
        [3]i32 => "int3",
        [16]f32 => "float4x4",
        else => @compileError("no shader type for " ++ @typeName(T)),
    };
}

test "the generated block has every field once" {
    inline for (@typeInfo(frame_constants.FrameConstants).@"struct".fields) |field| {
        const member = " " ++ field.name ++ ";";
        const array = " " ++ field.name ++ "[";
        try std.testing.expect(std.mem.indexOf(u8, frame_slang, member) != null or std.mem.indexOf(u8, frame_slang, array) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, frame_slang, "    ShadowConstants shadows;") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame_slang, "    Vertices vertices;") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame_slang, "    float4x4 cascade_view_proj[4];") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame_slang, "    GiCascade gi_cascades[4];") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame_slang, "    Lights lights;") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame_slang, "struct GiCascade {\n    float3 origin;") != null);
}
