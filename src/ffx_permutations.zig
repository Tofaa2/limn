//! Writes the `<pass>_permutations.h` header the FidelityFX SDK looks a
//! pass's shaders up in (the format of AMD's Windows-only `FidelityFX_SC`).
//!
//!   ffx_permutations <directory to write to> <pass name> <option,option,...>
//!       <first.spv> <second.spv> ...
//!
//! Option i is bit i of a permutation's number; files are in number order.
const std = @import("std");

/// Binding kinds, in the SDK's order.
const Kind = enum { constant_buffer, sampled_texture, storage_texture, read_buffer, written_buffer, sampler, acceleration_structure };

const kind_names = [_][]const u8{ "CBV", "TextureSRV", "TextureUAV", "BufferSRV", "BufferUAV", "Sampler", "RTAccelerationStructure" };
const member_names = [_][]const u8{ "constantBuffer", "srvTexture", "uavTexture", "srvBuffer", "uavBuffer", "sampler", "rtAccelerationStructure" };
const count_names = [_][]const u8{ "numConstantBuffers", "numSRVTextures", "numUAVTextures", "numSRVBuffers", "numUAVBuffers", "numSamplers", "numRTAccelerationStructures" };

const Resource = struct {
    kind: Kind,
    name: []const u8,
    binding: u32,
    set: u32,
    count: u32,

    fn before(_: void, a: Resource, b: Resource) bool {
        return if (a.set != b.set) a.set < b.set else a.binding < b.binding;
    }
};

const Type = union(enum) {
    none,
    pointer: u32,
    array: struct { element: u32, length: u32 },
    image: bool,
    sampled_image,
    sampler,
    structure,
    acceleration_structure,
};

const Decorations = struct {
    binding: ?u32 = null,
    set: ?u32 = null,
    block: bool = false,
    buffer_block: bool = false,
    read_only: bool = false,
    name: []const u8 = "",
};

/// Every bound variable of a SPIR-V module: name, binding and kind.
fn reflect(gpa: std.mem.Allocator, bytes: []const u8) ![]Resource {
    if (bytes.len < 20 or bytes.len % 4 != 0) return error.InvalidSpirv;
    const words = try gpa.alloc(u32, bytes.len / 4);
    for (words, 0..) |*word, index| word.* = std.mem.readInt(u32, bytes[index * 4 ..][0..4], .little);
    if (words[0] != 0x07230203) return error.InvalidSpirv;
    const bound = words[3];
    const types = try gpa.alloc(Type, bound);
    @memset(types, .none);
    const decorations = try gpa.alloc(Decorations, bound);
    @memset(decorations, .{});
    const constants = try gpa.alloc(u32, bound);
    @memset(constants, 1);
    const Variable = struct { id: u32, pointer: u32, storage: u32 };
    var variables: std.ArrayList(Variable) = .empty;

    var at: usize = 5;
    while (at < words.len) {
        const length = words[at] >> 16;
        const opcode = words[at] & 0xffff;
        if (length == 0 or at + length > words.len) return error.InvalidSpirv;
        const operands = words[at + 1 .. at + length];
        switch (opcode) {
            // OpName
            5 => decorations[operands[0]].name = std.mem.sliceTo(std.mem.sliceAsBytes(operands[1..]), 0),
            // OpDecorate
            71 => switch (operands[1]) {
                2 => decorations[operands[0]].block = true,
                3 => decorations[operands[0]].buffer_block = true,
                24 => decorations[operands[0]].read_only = true,
                33 => decorations[operands[0]].binding = operands[2],
                34 => decorations[operands[0]].set = operands[2],
                else => {},
            },
            // OpMemberDecorate; one read-only member marks the whole block.
            72 => if (operands[2] == 24) {
                decorations[operands[0]].read_only = true;
            },
            25 => types[operands[0]] = .{ .image = operands[6] == 2 },
            26 => types[operands[0]] = .sampler,
            27 => types[operands[0]] = .sampled_image,
            28 => types[operands[0]] = .{ .array = .{ .element = operands[1], .length = operands[2] } },
            29 => types[operands[0]] = .{ .array = .{ .element = operands[1], .length = 0 } },
            30 => types[operands[0]] = .structure,
            32 => types[operands[0]] = .{ .pointer = operands[2] },
            5341 => types[operands[0]] = .acceleration_structure,
            // OpConstant
            43 => constants[operands[1]] = operands[2],
            // OpVariable
            59 => try variables.append(gpa, .{ .id = operands[1], .pointer = operands[0], .storage = operands[2] }),
            else => {},
        }
        at += length;
    }

    var resources: std.ArrayList(Resource) = .empty;
    for (variables.items) |variable| {
        const decoration = decorations[variable.id];
        const binding = decoration.binding orelse continue;
        var pointee = switch (types[variable.pointer]) {
            .pointer => |target| target,
            else => continue,
        };
        var count: u32 = 1;
        while (true) switch (types[pointee]) {
            .array => |array| {
                count *= if (array.length == 0) 1 else constants[array.length];
                pointee = array.element;
            },
            else => break,
        };
        const kind: Kind = switch (types[pointee]) {
            .image => |storage| if (storage) .storage_texture else .sampled_texture,
            .sampler => .sampler,
            .acceleration_structure => .acceleration_structure,
            // 12 is StorageBuffer; older SPIR-V marks a Uniform as BufferBlock.
            .structure => if (variable.storage == 12 or decorations[pointee].buffer_block)
                (if (decorations[pointee].read_only or decoration.read_only) Kind.read_buffer else Kind.written_buffer)
            else
                .constant_buffer,
            else => return error.UnsupportedResource,
        };
        try resources.append(gpa, .{
            .kind = kind,
            .name = if (decoration.name.len != 0) decoration.name else decorations[pointee].name,
            .binding = binding,
            .set = decoration.set orelse 0,
            .count = count,
        });
    }
    std.mem.sort(Resource, resources.items, {}, Resource.before);
    return resources.items;
}

/// The module without its source text and line instructions. Names stay:
/// `reflect` reads them.
fn withoutSource(gpa: std.mem.Allocator, bytes: []const u8) ![]u8 {
    if (bytes.len < 20 or bytes.len % 4 != 0) return error.InvalidSpirv;
    var kept: std.ArrayList(u8) = .empty;
    try kept.appendSlice(gpa, bytes[0..20]);
    var at: usize = 20;
    while (at < bytes.len) {
        const first = std.mem.readInt(u32, bytes[at..][0..4], .little);
        const length = (first >> 16) * 4;
        if (length == 0 or at + length > bytes.len) return error.InvalidSpirv;
        switch (first & 0xffff) {
            // OpSourceContinued, OpSource, OpSourceExtension, OpString,
            // OpLine, OpNoLine, OpModuleProcessed.
            2, 3, 4, 7, 8, 317, 330 => {},
            else => try kept.appendSlice(gpa, bytes[at..][0..length]),
        }
        at += length;
    }
    return kept.items;
}

const Unique = struct {
    digest: [16]u8,
    bytes: []const u8,
    resources: []const Resource,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    var arguments = try init.minimal.args.iterateAllocator(gpa);
    _ = arguments.next();
    const directory = arguments.next() orelse return error.MissingArgument;
    const pass = arguments.next() orelse return error.MissingArgument;
    const option_list = arguments.next() orelse return error.MissingArgument;
    var options: std.ArrayList([]const u8) = .empty;
    var option_names = std.mem.tokenizeScalar(u8, option_list, ',');
    while (option_names.next()) |name| try options.append(gpa, name);

    var unique: std.ArrayList(Unique) = .empty;
    var indirection: std.ArrayList(usize) = .empty;
    while (arguments.next()) |path| {
        const bytes = try withoutSource(gpa, try std.Io.Dir.cwd().readFileAlloc(init.io, path, gpa, .unlimited));
        var digest: [16]u8 = undefined;
        _ = try std.fmt.bufPrint(&digest, "{x:0>16}", .{std.hash.Wyhash.hash(0, bytes)});
        const found = for (unique.items, 0..) |known, index| {
            if (std.mem.eql(u8, &known.digest, &digest) and std.mem.eql(u8, known.bytes, bytes)) break index;
        } else added: {
            try unique.append(gpa, .{ .digest = digest, .bytes = bytes, .resources = try reflect(gpa, bytes) });
            break :added unique.items.len - 1;
        };
        try indirection.append(gpa, found);
    }
    if (indirection.items.len != @as(usize, 1) << @intCast(options.items.len)) return error.WrongNumberOfShaders;

    var text: std.Io.Writer.Allocating = .init(gpa);
    const out = &text.writer;
    try out.print("// {s}_permutations.h.\n// Made by src/ffx_permutations.zig in the place of FidelityFX-SC.\n\n#ifndef LIMN_{s}_PERMUTATIONS_H\n#define LIMN_{s}_PERMUTATIONS_H\n\n#include <stdint.h>\n\n", .{ pass, pass, pass });
    for (unique.items) |shader| {
        inline for (@typeInfo(Kind).@"enum".fields, kind_names) |field, kind_name| {
            const kind: Kind = @enumFromInt(field.value);
            var any = false;
            for (shader.resources) |resource| any = any or resource.kind == kind;
            if (any) {
                const Column = enum { names, bindings, counts, sets };
                inline for (.{ Column.names, Column.bindings, Column.counts, Column.sets }, .{ "Names", "Bindings", "Counts", "Sets" }) |column, column_name| {
                    try out.print("static const {s} g_{s}_{s}_{s}Resource{s}[] = {{ ", .{ if (column == .names) "char*" else "uint32_t", pass, shader.digest, kind_name, column_name });
                    for (shader.resources) |resource| {
                        if (resource.kind != kind) continue;
                        switch (column) {
                            .names => try out.print(" \"{s}\",", .{resource.name}),
                            .bindings => try out.print(" {d},", .{resource.binding}),
                            .counts => try out.print(" {d},", .{resource.count}),
                            .sets => try out.print(" {d},", .{resource.set}),
                        }
                    }
                    try out.writeAll(" };\n");
                }
                try out.writeAll("\n");
            }
        }
        try out.print("static const uint32_t g_{s}_{s}_size = {d};\n\nstatic const unsigned char g_{s}_{s}_data[] = {{\n", .{ pass, shader.digest, shader.bytes.len, pass, shader.digest });
        for (shader.bytes, 0..) |byte, index| {
            try out.print("0x{x:0>2}{s}", .{ byte, if (index + 1 == shader.bytes.len) "" else if ((index + 1) % 16 == 0) ",\n" else "," });
        }
        try out.writeAll("\n};\n\n");
    }

    try out.print("typedef union {s}_PermutationKey {{\n    struct {{\n", .{pass});
    for (options.items) |option| try out.print("        uint32_t {s} : 1;\n", .{option});
    try out.print("    }};\n    uint32_t index;\n}} {s}_PermutationKey;\n\n", .{pass});

    try out.print("typedef struct {s}_PermutationInfo {{\n    const uint32_t       blobSize;\n    const unsigned char* blobData;\n\n", .{pass});
    for (member_names, count_names, 0..) |member, count_name, index| {
        try out.print("\n    const uint32_t  {s};\n    const char**    {s}Names;\n    const uint32_t* {s}Bindings;\n    const uint32_t* {s}Counts;\n    const uint32_t* {s}{s};\n", .{
            count_name, member, member, member, member, if (index == 0 or index == member_names.len) "Spaces" else "Spaces",
        });
    }
    try out.print("\n}} {s}_PermutationInfo;\n\n", .{pass});

    try out.print("static const uint32_t g_{s}_IndirectionTable[] = {{\n", .{pass});
    for (indirection.items) |index| try out.print("    {d},\n", .{index});
    try out.writeAll("};\n\n");

    try out.print("static const {s}_PermutationInfo g_{s}_PermutationInfo[] = {{\n", .{ pass, pass });
    for (unique.items) |shader| {
        try out.print("    {{ g_{s}_{s}_size, g_{s}_{s}_data, ", .{ pass, shader.digest, pass, shader.digest });
        inline for (@typeInfo(Kind).@"enum".fields, kind_names) |field, kind_name| {
            const kind: Kind = @enumFromInt(field.value);
            var count: usize = 0;
            for (shader.resources) |resource| count += @intFromBool(resource.kind == kind);
            if (count == 0) {
                try out.writeAll("0, 0, 0, 0, 0, ");
            } else {
                try out.print("{d}, (const char**)g_{s}_{s}_{s}ResourceNames, g_{s}_{s}_{s}ResourceBindings, g_{s}_{s}_{s}ResourceCounts, g_{s}_{s}_{s}ResourceSets, ", .{
                    count, pass, shader.digest, kind_name, pass, shader.digest, kind_name, pass, shader.digest, kind_name, pass, shader.digest, kind_name,
                });
            }
        }
        try out.writeAll("},\n");
    }
    try out.writeAll("};\n\n#endif\n");

    var folder = try std.Io.Dir.cwd().openDir(init.io, directory, .{});
    defer folder.close(init.io);
    try folder.writeFile(init.io, .{ .sub_path = try std.fmt.allocPrint(gpa, "{s}_permutations.h", .{pass}), .data = text.written() });
    // Variants this build does not make alias the plain one.
    for ([_][]const u8{ "wave64", "16bit", "wave64_16bit" }) |kind| {
        const alias = try std.fmt.allocPrint(gpa,
            \\// {s}_{s}_permutations.h.
            \\// Made by src/ffx_permutations.zig: this kind is not built, the plain one stands for it.
            \\
            \\#include "{s}_permutations.h"
            \\#define g_{s}_{s}_IndirectionTable g_{s}_IndirectionTable
            \\#define g_{s}_{s}_PermutationInfo g_{s}_PermutationInfo
            \\
        , .{ pass, kind, pass, pass, kind, pass, pass, kind, pass });
        try folder.writeFile(init.io, .{ .sub_path = try std.fmt.allocPrint(gpa, "{s}_{s}_permutations.h", .{ pass, kind }), .data = alias });
    }
}
