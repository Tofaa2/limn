//! Marks what a SPIR-V module only reads through buffer addresses as
//! `NonWritable`, as glslang does for `readonly` buffer references. Slang has
//! no way to say it, and without it drivers load through the slower writable
//! path: the probe tracer took 15% longer.
//!
//! Every struct a physical storage buffer pointer points to gets the
//! decoration on all its members, unless some store or atomic in the module
//! reaches memory through a pointer of that type, or the struct sits inside
//! one that does. Instructions it does not know count as writes to every
//! pointer they name.
//!
//!   spirv_readonly in.spv out.spv
const std = @import("std");

const physical_storage_buffer = 5349;
const non_writable = 24;

const Op = enum(u16) {
    function_parameter = 55,
    function_call = 57,
    variable = 59,
    load = 61,
    store = 62,
    copy_memory = 63,
    copy_memory_sized = 64,
    access_chain = 65,
    in_bounds_access_chain = 66,
    ptr_access_chain = 67,
    in_bounds_ptr_access_chain = 70,
    decorate = 71,
    member_decorate = 72,
    copy_object = 83,
    convert_u_to_ptr = 120,
    convert_ptr_to_u = 117,
    bitcast = 124,
    select = 169,
    atomic_load = 227,
    atomic_store = 228,
    phi = 245,
    type_array = 28,
    type_runtime_array = 29,
    type_struct = 30,
    type_pointer = 32,
    type_forward_pointer = 39,
    ptr_equal = 401,
    ptr_not_equal = 402,
    ptr_diff = 403,
    _,
};

/// The module with the decorations added, owned by the caller; `words` when
/// it is not a SPIR-V module.
pub fn markReadOnly(gpa: std.mem.Allocator, words: []const u32) ![]u32 {
    if (words.len < 5 or words[0] != 0x07230203) return gpa.dupe(u32, words);

    var pointee: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer pointee.deinit(gpa);
    var members: std.AutoHashMapUnmanaged(u32, []const u32) = .empty;
    defer members.deinit(gpa);
    var elements: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer elements.deinit(gpa);
    var value_type: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer value_type.deinit(gpa);
    var derived: std.AutoHashMapUnmanaged(u32, []const u32) = .empty;
    defer derived.deinit(gpa);
    var decorated: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer decorated.deinit(gpa);
    var phi_lists: std.ArrayList([]u32) = .empty;
    defer {
        for (phi_lists.items) |list| gpa.free(list);
        phi_lists.deinit(gpa);
    }
    var written_pointers: std.ArrayList(u32) = .empty;
    defer written_pointers.deinit(gpa);
    var other_uses: std.ArrayList(u32) = .empty;
    defer other_uses.deinit(gpa);
    var annotations_end: usize = 0;
    var first_type: usize = 0;

    var at: usize = 5;
    while (at < words.len) {
        const count: usize = words[at] >> 16;
        if (count == 0 or at + count > words.len) return gpa.dupe(u32, words);
        const op: Op = @enumFromInt(@as(u16, @truncate(words[at])));
        const operands = words[at + 1 .. at + count];
        switch (op) {
            .type_pointer => {
                if (first_type == 0) first_type = at;
                if (operands[1] == physical_storage_buffer) try pointee.put(gpa, operands[0], operands[2]);
            },
            .type_struct => {
                if (first_type == 0) first_type = at;
                try members.put(gpa, operands[0], operands[1..]);
            },
            .type_array, .type_runtime_array => {
                if (first_type == 0) first_type = at;
                try elements.put(gpa, operands[0], operands[1]);
            },
            .type_forward_pointer => if (first_type == 0) {
                first_type = at;
            },
            .decorate => annotations_end = at + count,
            .member_decorate => {
                annotations_end = at + count;
                if (operands[2] == non_writable) try decorated.put(gpa, (@as(u64, operands[0]) << 32) | operands[1], {});
            },
            .access_chain, .in_bounds_access_chain, .ptr_access_chain, .in_bounds_ptr_access_chain, .copy_object, .bitcast => {
                try value_type.put(gpa, operands[1], operands[0]);
                try derived.put(gpa, operands[1], operands[2..3]);
            },
            .select => {
                try value_type.put(gpa, operands[1], operands[0]);
                try derived.put(gpa, operands[1], operands[3..5]);
            },
            .phi => {
                try value_type.put(gpa, operands[1], operands[0]);
                const incoming = try gpa.alloc(u32, (operands.len - 2) / 2);
                try phi_lists.append(gpa, incoming);
                for (incoming, 0..) |*value, pair| value.* = operands[2 + pair * 2];
                try derived.put(gpa, operands[1], incoming);
            },
            .load, .function_parameter, .function_call, .variable, .convert_u_to_ptr, .atomic_load => {
                try value_type.put(gpa, operands[1], operands[0]);
                if (op == .function_call) try other_uses.appendSlice(gpa, operands[3..]);
            },
            .store, .copy_memory, .copy_memory_sized, .atomic_store => try written_pointers.append(gpa, operands[0]),
            .convert_ptr_to_u, .ptr_equal, .ptr_not_equal, .ptr_diff => {},
            else => if (first_type != 0 and !isDeclaration(op)) try other_uses.appendSlice(gpa, operands),
        }
        at += count;
    }

    var written: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer written.deinit(gpa);
    var visited: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer visited.deinit(gpa);
    for (other_uses.items) |id| {
        const kind = value_type.get(id) orelse continue;
        if (pointee.contains(kind)) try written_pointers.append(gpa, id);
    }
    for (written_pointers.items) |pointer| try markRoots(gpa, pointer, &derived, &value_type, &pointee, &members, &elements, &visited, &written);

    var added: std.ArrayList(u32) = .empty;
    defer added.deinit(gpa);
    var targets = pointee.valueIterator();
    while (targets.next()) |target| {
        if (written.contains(target.*)) continue;
        const fields = members.get(target.*) orelse continue;
        for (0..fields.len) |member| {
            const key = (@as(u64, target.*) << 32) | member;
            if (decorated.contains(key)) continue;
            try decorated.put(gpa, key, {});
            try added.appendSlice(gpa, &.{ (4 << 16) | @as(u32, @intFromEnum(Op.member_decorate)), target.*, @intCast(member), non_writable });
        }
    }
    const insert = if (annotations_end != 0) annotations_end else first_type;
    if (added.items.len == 0 or insert == 0) return gpa.dupe(u32, words);
    const result = try gpa.alloc(u32, words.len + added.items.len);
    @memcpy(result[0..insert], words[0..insert]);
    @memcpy(result[insert..][0..added.items.len], added.items);
    @memcpy(result[insert + added.items.len ..], words[insert..]);
    return result;
}

fn isDeclaration(op: Op) bool {
    const code = @intFromEnum(op);
    return (code >= 19 and code <= 39) or (code >= 41 and code <= 52) or code == 71 or code == 72 or code == 74 or code == 75 or code == 332 or code == 5632 or code == 5633;
}

fn markRoots(
    gpa: std.mem.Allocator,
    pointer: u32,
    derived: *const std.AutoHashMapUnmanaged(u32, []const u32),
    value_type: *const std.AutoHashMapUnmanaged(u32, u32),
    pointee: *const std.AutoHashMapUnmanaged(u32, u32),
    members: *const std.AutoHashMapUnmanaged(u32, []const u32),
    elements: *const std.AutoHashMapUnmanaged(u32, u32),
    visited: *std.AutoHashMapUnmanaged(u32, void),
    written: *std.AutoHashMapUnmanaged(u32, void),
) !void {
    if ((try visited.getOrPut(gpa, pointer)).found_existing) return;
    if (derived.get(pointer)) |sources| {
        for (sources) |source| try markRoots(gpa, source, derived, value_type, pointee, members, elements, visited, written);
        return;
    }
    const kind = value_type.get(pointer) orelse return;
    const target = pointee.get(kind) orelse return;
    try markContents(gpa, target, members, elements, written);
}

fn markContents(gpa: std.mem.Allocator, kind: u32, members: *const std.AutoHashMapUnmanaged(u32, []const u32), elements: *const std.AutoHashMapUnmanaged(u32, u32), written: *std.AutoHashMapUnmanaged(u32, void)) !void {
    if ((try written.getOrPut(gpa, kind)).found_existing) return;
    if (elements.get(kind)) |element| try markContents(gpa, element, members, elements, written);
    if (members.get(kind)) |fields| for (fields) |field| try markContents(gpa, field, members, elements, written);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    var arguments = try init.minimal.args.iterateAllocator(gpa);
    _ = arguments.next();
    const source_path = arguments.next() orelse return error.MissingArgument;
    const target_path = arguments.next() orelse return error.MissingArgument;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, source_path, gpa, .unlimited);
    if (bytes.len % 4 != 0) return error.NotSpirv;
    const words = try gpa.alloc(u32, bytes.len / 4);
    @memcpy(std.mem.sliceAsBytes(words), bytes);
    const marked = try markReadOnly(gpa, words);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = target_path, .data = std.mem.sliceAsBytes(marked) });
}

fn instruction(comptime op: Op, comptime operands: []const u32) [1 + operands.len]u32 {
    return [1]u32{(@as(u32, operands.len + 1) << 16) | @intFromEnum(op)} ++ operands[0..operands.len].*;
}

test "structs only read through a pointer become NonWritable, written ones stay" {
    const header = [_]u32{ 0x07230203, 0x00010500, 0, 100, 0 };
    const read_struct = 10;
    const written_struct = 11;
    const float = 12;
    const read_pointer = 13;
    const written_pointer = 14;
    const module = header ++
        instruction(.decorate, &.{ read_struct, 2 }) ++
        [_]u32{ (3 << 16) | 22, float, 32 } ++
        instruction(.type_struct, &.{ read_struct, float, float }) ++
        instruction(.type_struct, &.{ written_struct, float }) ++
        instruction(.type_pointer, &.{ read_pointer, physical_storage_buffer, read_struct }) ++
        instruction(.type_pointer, &.{ written_pointer, physical_storage_buffer, written_struct }) ++
        instruction(.function_parameter, &.{ read_pointer, 20 }) ++
        instruction(.function_parameter, &.{ written_pointer, 21 }) ++
        instruction(.access_chain, &.{ 15, 22, 21, 30 }) ++
        instruction(.store, &.{ 22, 31 });
    const marked = try markReadOnly(std.testing.allocator, &module);
    defer std.testing.allocator.free(marked);
    try std.testing.expectEqual(module.len + 8, marked.len);
    var decorations: [2]u32 = undefined;
    var found: usize = 0;
    var at: usize = 5;
    while (at < marked.len) : (at += marked[at] >> 16) {
        if ((marked[at] & 0xffff) != @intFromEnum(Op.member_decorate)) continue;
        try std.testing.expectEqual(@as(u32, read_struct), marked[at + 1]);
        try std.testing.expectEqual(@as(u32, non_writable), marked[at + 3]);
        decorations[found] = marked[at + 2];
        found += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), found);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1 }, &decorations);
}
