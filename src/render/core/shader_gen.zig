//! Shader declarations written from the Zig types they must match, at build
//! time. Imports nothing but `std` and the types.
const std = @import("std");
const frame_constants = @import("frame_constants.zig");

pub const Language = enum { glsl, slang };

/// `frame_constants.glsl`: the flag bits and the `FrameConstants` block.
pub const frame_glsl = header ++ constants(.glsl, "FRAME_", frame_constants.flags) ++ constants(.glsl, "FEATURE_", frame_constants.features) ++
    record(.glsl, "GiCascade", frame_constants.GiCascade) ++
    "\nlayout(buffer_reference, scalar) readonly buffer FrameConstants {\n" ++ fields(.glsl, frame_constants.FrameConstants) ++ "};\n";

/// `frame_constants.slang`: the same, with `FrameConstants` a pointer.
pub const frame_slang = header ++ constants(.slang, "FRAME_", frame_constants.flags) ++ constants(.slang, "FEATURE_", frame_constants.features) ++
    record(.slang, "GiCascade", frame_constants.GiCascade) ++
    "\nstruct FrameConstantsData {\n" ++ fields(.slang, frame_constants.FrameConstants) ++ "};\ntypedef FrameConstantsData* FrameConstants;\n";

const header = "// Generated from src/render/core/frame_constants.zig by the build; edit that file.\n\n";

/// One `uint` constant per declaration of `namespace`, named `prefix` and the
/// declaration's name in capitals.
fn constants(comptime language: Language, comptime prefix: []const u8, comptime namespace: type) []const u8 {
    comptime {
        var text: []const u8 = "";
        for (@typeInfo(namespace).@"struct".decls) |decl| {
            var name: [decl.name.len]u8 = undefined;
            _ = std.ascii.upperString(&name, decl.name);
            const qualifier = if (language == .slang) "static const uint " else "const uint ";
            text = text ++ std.fmt.comptimePrint("{s}{s}{s} = {d}u;\n", .{ qualifier, prefix, name, @field(namespace, decl.name) });
        }
        return text;
    }
}

/// The fields of the extern struct `T` as shader members. A `u64` is an
/// address, typed by `T.references`.
fn fields(comptime language: Language, comptime T: type) []const u8 {
    comptime {
        @setEvalBranchQuota(100_000);
        var text: []const u8 = "";
        for (@typeInfo(T).@"struct".fields) |field| {
            var count: ?usize = null;
            var element = field.type;
            if (@typeInfo(element) == .array and (@typeInfo(@typeInfo(element).array.child) == .array or @typeInfo(@typeInfo(element).array.child) == .@"struct")) {
                count = @typeInfo(element).array.len;
                element = @typeInfo(element).array.child;
            }
            const name = if (element == u64) @field(T.references, field.name) else typeName(language, element);
            text = text ++ "    " ++ name ++ " " ++ field.name ++ (if (count) |n| std.fmt.comptimePrint("[{d}]", .{n}) else "") ++ ";\n";
        }
        return text;
    }
}

/// The extern struct `T` as a shader struct called `name`.
fn record(comptime language: Language, comptime name: []const u8, comptime T: type) []const u8 {
    return "\nstruct " ++ name ++ " {\n" ++ fields(language, T) ++ "};\n";
}

fn typeName(comptime language: Language, comptime T: type) []const u8 {
    const glsl = language == .glsl;
    if (@typeInfo(T) == .@"struct") {
        const full = @typeName(T);
        return full[std.mem.lastIndexOfScalar(u8, full, '.').? + 1 ..];
    }
    return switch (T) {
        f32 => "float",
        u32 => "uint",
        i32 => "int",
        [2]f32 => if (glsl) "vec2" else "float2",
        [3]f32 => if (glsl) "vec3" else "float3",
        [4]f32 => if (glsl) "vec4" else "float4",
        [3]i32 => if (glsl) "ivec3" else "int3",
        [16]f32 => if (glsl) "mat4" else "float4x4",
        else => @compileError("no shader type for " ++ @typeName(T)),
    };
}

test "the generated block has every field once" {
    inline for (@typeInfo(frame_constants.FrameConstants).@"struct".fields) |field| {
        const member = " " ++ field.name ++ ";";
        const array = " " ++ field.name ++ "[";
        try std.testing.expect(std.mem.indexOf(u8, frame_glsl, member) != null or std.mem.indexOf(u8, frame_glsl, array) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, frame_glsl, "const uint FRAME_SHADOWS = 1u;") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame_slang, "    Vertices vertices;") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame_slang, "    float4x4 cascade_view_proj[4];") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame_glsl, "    GiCascade gi_cascades[4];") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame_glsl, "struct GiCascade {\n    vec3 origin;") != null);
}
