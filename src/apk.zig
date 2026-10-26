//! Packs a native Android application into an installable APK without the
//! Android SDK: a binary manifest for a `NativeActivity`, the library, the
//! assets, and an APK Signature Scheme v2 block signed with a debug key.
//!
//!   apk <out.apk> <package> <label> <libmain.so> [<archive path> <file>]...
//!
//! The library goes in as `lib/arm64-v8a/libmain.so` (or x86_64 when
//! `<libmain.so>` is given as `x86_64:<path>`). Every other pair is stored
//! under its archive path, and `assets/limn_files.txt` lists the ones under
//! `assets/` so the application can unpack them.
const std = @import("std");

const Ecdsa = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const Sha256 = std.crypto.hash.sha2.Sha256;

/// The debug key every build signs with: derived from a fixed seed, so an
/// installed application can be updated by any later build, from any
/// machine. Not for release.
pub fn debugKey() !Ecdsa.KeyPair {
    var seed: [Ecdsa.KeyPair.seed_length]u8 = undefined;
    Sha256.hash("limn android debug key", seed[0..32], .{});
    return Ecdsa.KeyPair.generateDeterministic(seed);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    var arguments = try init.minimal.args.iterateAllocator(gpa);
    _ = arguments.skip();
    const out_path = arguments.next() orelse return error.MissingArgument;
    const package = arguments.next() orelse return error.MissingArgument;
    const label = arguments.next() orelse return error.MissingArgument;
    const library = arguments.next() orelse return error.MissingArgument;
    var entries: std.ArrayList(Entry) = .empty;
    const abi, const library_path = if (std.mem.startsWith(u8, library, "x86_64:")) .{ "x86_64", library["x86_64:".len..] } else .{ "arm64-v8a", library };
    const cwd = std.Io.Dir.cwd();
    try entries.append(gpa, .{ .name = try std.fmt.allocPrint(gpa, "lib/{s}/libmain.so", .{abi}), .data = try cwd.readFileAlloc(init.io, library_path, gpa, .unlimited), .alignment = 4096 });
    var listing: std.Io.Writer.Allocating = .init(gpa);
    while (arguments.next()) |name| {
        const path = arguments.next() orelse return error.MissingArgument;
        try entries.append(gpa, .{ .name = name, .data = try cwd.readFileAlloc(init.io, path, gpa, .unlimited) });
        if (std.mem.startsWith(u8, name, "assets/")) try listing.writer.print("{s}\n", .{name["assets/".len..]});
    }
    try entries.append(gpa, .{ .name = "assets/limn_files.txt", .data = listing.written() });
    try entries.insert(gpa, 0, .{ .name = "AndroidManifest.xml", .data = try manifest(gpa, package, label) });
    const apk = try pack(gpa, entries.items, try debugKey());
    try cwd.writeFile(init.io, .{ .sub_path = out_path, .data = apk });
}

pub const Entry = struct {
    name: []const u8,
    data: []const u8,
    /// Where the data must start in the file; native libraries are page
    /// aligned so they can be mapped straight from the archive.
    alignment: u32 = 4,
};

/// The binary XML manifest of a debuggable `NativeActivity` that loads
/// `libmain.so`, for Android 10 (API 29) and later.
pub fn manifest(gpa: std.mem.Allocator, package: []const u8, label: []const u8) ![]u8 {
    var xml: Xml = .{ .gpa = gpa };
    const android = "http://schemas.android.com/apk/res/android";
    try xml.startNamespace("android", android);
    try xml.start("manifest", &.{
        .{ .name = "versionCode", .android = true, .value = .{ .int = 1 } },
        .{ .name = "versionName", .android = true, .value = .{ .string = "1.0" } },
        .{ .name = "package", .value = .{ .string = package } },
    });
    try xml.start("uses-sdk", &.{
        .{ .name = "minSdkVersion", .android = true, .value = .{ .int = 29 } },
        .{ .name = "targetSdkVersion", .android = true, .value = .{ .int = 34 } },
    });
    try xml.end("uses-sdk");
    try xml.start("application", &.{
        .{ .name = "label", .android = true, .value = .{ .string = label } },
        .{ .name = "hasCode", .android = true, .value = .{ .boolean = false } },
        .{ .name = "debuggable", .android = true, .value = .{ .boolean = true } },
    });
    try xml.start("activity", &.{
        .{ .name = "label", .android = true, .value = .{ .string = label } },
        .{ .name = "name", .android = true, .value = .{ .string = "android.app.NativeActivity" } },
        .{ .name = "exported", .android = true, .value = .{ .boolean = true } },
        .{ .name = "screenOrientation", .android = true, .value = .{ .int = 6 } },
        .{ .name = "configChanges", .android = true, .value = .{ .hex = 0x1fb0 } },
    });
    try xml.start("meta-data", &.{
        .{ .name = "name", .android = true, .value = .{ .string = "android.app.lib_name" } },
        .{ .name = "value", .android = true, .value = .{ .string = "main" } },
    });
    try xml.end("meta-data");
    try xml.start("intent-filter", &.{});
    try xml.start("action", &.{.{ .name = "name", .android = true, .value = .{ .string = "android.intent.action.MAIN" } }});
    try xml.end("action");
    try xml.start("category", &.{.{ .name = "name", .android = true, .value = .{ .string = "android.intent.category.LAUNCHER" } }});
    try xml.end("category");
    try xml.end("intent-filter");
    try xml.end("activity");
    try xml.end("application");
    try xml.end("manifest");
    try xml.endNamespace("android", android);
    return xml.finish();
}

/// Resource ids of the `android:` attributes the manifest uses; the
/// platform finds attributes by these, not by name.
const attribute_ids = [_]struct { []const u8, u32 }{
    .{ "label", 0x01010001 },
    .{ "name", 0x01010003 },
    .{ "hasCode", 0x0101000c },
    .{ "debuggable", 0x0101000f },
    .{ "exported", 0x01010010 },
    .{ "screenOrientation", 0x0101001e },
    .{ "configChanges", 0x0101001f },
    .{ "value", 0x01010024 },
    .{ "minSdkVersion", 0x0101020c },
    .{ "versionCode", 0x0101021b },
    .{ "versionName", 0x0101021c },
    .{ "targetSdkVersion", 0x01010270 },
};

const Attribute = struct {
    name: []const u8,
    android: bool = false,
    value: union(enum) { string: []const u8, int: u32, hex: u32, boolean: bool },
};

/// Android's compiled XML: one string pool, a map from the first strings
/// to resource ids, then a flat stream of namespace and element chunks.
const Xml = struct {
    gpa: std.mem.Allocator,
    strings: std.ArrayList([]const u8) = .empty,
    body: std.ArrayList(u8) = .empty,

    fn string(self: *Xml, text: []const u8) !u32 {
        for (self.strings.items, 0..) |existing, index| {
            if (std.mem.eql(u8, existing, text)) return @intCast(index);
        }
        try self.strings.append(self.gpa, text);
        return @intCast(self.strings.items.len - 1);
    }

    fn word(self: *Xml, value: u32) !void {
        try self.body.appendSlice(self.gpa, std.mem.asBytes(&std.mem.nativeToLittle(u32, value)));
    }

    fn half(self: *Xml, value: u16) !void {
        try self.body.appendSlice(self.gpa, std.mem.asBytes(&std.mem.nativeToLittle(u16, value)));
    }

    fn chunk(self: *Xml, kind: u16, header: u16, size: u32) !void {
        try self.half(kind);
        try self.half(header);
        try self.word(size);
        try self.word(1);
        try self.word(0xffffffff);
    }

    fn startNamespace(self: *Xml, prefix: []const u8, uri: []const u8) !void {
        for (attribute_ids) |entry| _ = try self.string(entry[0]);
        try self.chunk(0x0100, 16, 24);
        try self.word(try self.string(prefix));
        try self.word(try self.string(uri));
    }

    fn endNamespace(self: *Xml, prefix: []const u8, uri: []const u8) !void {
        try self.chunk(0x0101, 16, 24);
        try self.word(try self.string(prefix));
        try self.word(try self.string(uri));
    }

    fn start(self: *Xml, name: []const u8, attributes: []const Attribute) !void {
        var sorted: [8]Attribute = undefined;
        @memcpy(sorted[0..attributes.len], attributes);
        std.mem.sort(Attribute, sorted[0..attributes.len], {}, struct {
            fn before(_: void, a: Attribute, b: Attribute) bool {
                return attributeId(a) < attributeId(b);
            }
        }.before);
        try self.chunk(0x0102, 16, 36 + 20 * @as(u32, @intCast(attributes.len)));
        try self.word(0xffffffff);
        try self.word(try self.string(name));
        try self.half(20);
        try self.half(20);
        try self.half(@intCast(attributes.len));
        try self.half(0);
        try self.half(0);
        try self.half(0);
        for (sorted[0..attributes.len]) |attribute| {
            try self.word(if (attribute.android) try self.string("http://schemas.android.com/apk/res/android") else 0xffffffff);
            try self.word(try self.string(attribute.name));
            const raw: u32 = switch (attribute.value) {
                .string => |text| try self.string(text),
                else => 0xffffffff,
            };
            try self.word(raw);
            try self.half(8);
            try self.body.append(self.gpa, 0);
            const kind: u8, const data: u32 = switch (attribute.value) {
                .string => .{ 0x03, raw },
                .int => |value| .{ 0x10, value },
                .hex => |value| .{ 0x11, value },
                .boolean => |value| .{ 0x12, if (value) 0xffffffff else 0 },
            };
            try self.body.append(self.gpa, kind);
            try self.word(data);
        }
    }

    fn attributeId(attribute: Attribute) u32 {
        if (!attribute.android) return std.math.maxInt(u32);
        for (attribute_ids) |entry| {
            if (std.mem.eql(u8, entry[0], attribute.name)) return entry[1];
        }
        unreachable;
    }

    fn end(self: *Xml, name: []const u8) !void {
        try self.chunk(0x0103, 16, 24);
        try self.word(0xffffffff);
        try self.word(try self.string(name));
    }

    fn finish(self: *Xml) ![]u8 {
        var pool: std.ArrayList(u8) = .empty;
        var offsets: std.ArrayList(u8) = .empty;
        var data: std.ArrayList(u8) = .empty;
        for (self.strings.items) |text| {
            try offsets.appendSlice(self.gpa, std.mem.asBytes(&std.mem.nativeToLittle(u32, @intCast(data.items.len))));
            const length: u16 = @intCast(try std.unicode.calcUtf16LeLen(text));
            try data.appendSlice(self.gpa, std.mem.asBytes(&std.mem.nativeToLittle(u16, length)));
            const wide = try std.unicode.utf8ToUtf16LeAlloc(self.gpa, text);
            try data.appendSlice(self.gpa, std.mem.sliceAsBytes(wide));
            try data.appendSlice(self.gpa, &.{ 0, 0 });
        }
        while (data.items.len % 4 != 0) try data.append(self.gpa, 0);
        const pool_size: u32 = @intCast(28 + offsets.items.len + data.items.len);
        const header = [_]u32{ @as(u32, 0x0001) | (28 << 16), pool_size, @intCast(self.strings.items.len), 0, 0, @intCast(28 + offsets.items.len), 0 };
        for (header) |value| try pool.appendSlice(self.gpa, std.mem.asBytes(&std.mem.nativeToLittle(u32, value)));
        try pool.appendSlice(self.gpa, offsets.items);
        try pool.appendSlice(self.gpa, data.items);
        var map: std.ArrayList(u8) = .empty;
        const map_header = [_]u32{ @as(u32, 0x0180) | (8 << 16), 8 + 4 * attribute_ids.len };
        for (map_header) |value| try map.appendSlice(self.gpa, std.mem.asBytes(&std.mem.nativeToLittle(u32, value)));
        for (attribute_ids) |entry| try map.appendSlice(self.gpa, std.mem.asBytes(&std.mem.nativeToLittle(u32, entry[1])));
        var file: std.ArrayList(u8) = .empty;
        const total: u32 = @intCast(8 + pool.items.len + map.items.len + self.body.items.len);
        for ([_]u32{ @as(u32, 0x0003) | (8 << 16), total }) |value| try file.appendSlice(self.gpa, std.mem.asBytes(&std.mem.nativeToLittle(u32, value)));
        try file.appendSlice(self.gpa, pool.items);
        try file.appendSlice(self.gpa, map.items);
        try file.appendSlice(self.gpa, self.body.items);
        return file.toOwnedSlice(self.gpa);
    }
};

/// A stored (uncompressed) zip of `entries` with a v2 signing block before
/// its central directory.
pub fn pack(gpa: std.mem.Allocator, entries: []const Entry, key: Ecdsa.KeyPair) ![]u8 {
    var contents: std.ArrayList(u8) = .empty;
    var directory: std.ArrayList(u8) = .empty;
    for (entries) |entry| {
        const offset: u32 = @intCast(contents.items.len);
        const crc = std.hash.Crc32.hash(entry.data);
        const unpadded = offset + 30 + entry.name.len;
        const padding = std.mem.alignForward(usize, unpadded, entry.alignment) - unpadded;
        const size: u32 = @intCast(entry.data.len);
        try appendLittle(gpa, &contents, .{ @as(u32, 0x04034b50), @as(u16, 10), @as(u16, 0), @as(u16, 0), @as(u16, 0), @as(u16, 0x21), crc, size, size, @as(u16, @intCast(entry.name.len)), @as(u16, @intCast(padding)) });
        try contents.appendSlice(gpa, entry.name);
        try contents.appendNTimes(gpa, 0, padding);
        try contents.appendSlice(gpa, entry.data);
        try appendLittle(gpa, &directory, .{ @as(u32, 0x02014b50), @as(u16, 10), @as(u16, 10), @as(u16, 0), @as(u16, 0), @as(u16, 0), @as(u16, 0x21), crc, size, size, @as(u16, @intCast(entry.name.len)), @as(u16, 0), @as(u16, 0), @as(u16, 0), @as(u16, 0), @as(u32, 0), offset });
        try directory.appendSlice(gpa, entry.name);
    }
    var end: std.ArrayList(u8) = .empty;
    try appendLittle(gpa, &end, .{ @as(u32, 0x06054b50), @as(u16, 0), @as(u16, 0), @as(u16, @intCast(entries.len)), @as(u16, @intCast(entries.len)), @as(u32, @intCast(directory.items.len)), @as(u32, @intCast(contents.items.len)), @as(u16, 0) });
    const block = try signingBlock(gpa, contents.items, directory.items, end.items, key);
    std.mem.writeInt(u32, end.items[16..20], @intCast(contents.items.len + block.len), .little);
    var apk: std.ArrayList(u8) = .empty;
    try apk.appendSlice(gpa, contents.items);
    try apk.appendSlice(gpa, block);
    try apk.appendSlice(gpa, directory.items);
    try apk.appendSlice(gpa, end.items);
    return apk.toOwnedSlice(gpa);
}

fn appendLittle(gpa: std.mem.Allocator, list: *std.ArrayList(u8), values: anytype) !void {
    inline for (values) |value| try list.appendSlice(gpa, std.mem.asBytes(&std.mem.nativeToLittle(@TypeOf(value), value)));
}

/// ECDSA with SHA-256, in the v2 scheme's numbering.
const ecdsa_sha256 = 0x0201;
const v2_block_id = 0x7109871a;

/// The v2 digest: SHA-256 over 1 MiB chunks of the entries, the central
/// directory and the end record, whose directory offset must already point
/// where the signing block will start.
pub fn digest(gpa: std.mem.Allocator, sections: []const []const u8) ![32]u8 {
    var chunk_digests: std.ArrayList(u8) = .empty;
    defer chunk_digests.deinit(gpa);
    var count: u32 = 0;
    for (sections) |section| {
        var at: usize = 0;
        while (at < section.len) : (at += 1 << 20) {
            const piece = section[at..@min(at + (1 << 20), section.len)];
            var hash = Sha256.init(.{});
            hash.update(&.{0xa5});
            hash.update(std.mem.asBytes(&std.mem.nativeToLittle(u32, @intCast(piece.len))));
            hash.update(piece);
            try chunk_digests.appendSlice(gpa, &hash.finalResult());
            count += 1;
        }
    }
    var top = Sha256.init(.{});
    top.update(&.{0x5a});
    top.update(std.mem.asBytes(&std.mem.nativeToLittle(u32, count)));
    top.update(chunk_digests.items);
    return top.finalResult();
}

fn signingBlock(gpa: std.mem.Allocator, contents: []const u8, directory: []const u8, end: []const u8, key: Ecdsa.KeyPair) ![]u8 {
    const moved_end = try gpa.dupe(u8, end);
    defer gpa.free(moved_end);
    std.mem.writeInt(u32, moved_end[16..20], @intCast(contents.len), .little);
    const apk_digest = try digest(gpa, &.{ contents, directory, moved_end });
    const public_key = try subjectPublicKey(gpa, key.public_key);
    const certificate = try selfSigned(gpa, key, public_key);

    var signed: Bytes = .{ .gpa = gpa };
    var digests: Bytes = .{ .gpa = gpa };
    var one_digest: Bytes = .{ .gpa = gpa };
    try one_digest.int(u32, ecdsa_sha256);
    try one_digest.prefixed(&apk_digest);
    try digests.prefixed(one_digest.list.items);
    try signed.prefixed(digests.list.items);
    var certificates: Bytes = .{ .gpa = gpa };
    try certificates.prefixed(certificate);
    try signed.prefixed(certificates.list.items);
    try signed.prefixed(&.{});

    var signature_der: [Ecdsa.Signature.der_encoded_length_max]u8 = undefined;
    const signature = (try key.sign(signed.list.items, null)).toDer(&signature_der);
    var one_signature: Bytes = .{ .gpa = gpa };
    try one_signature.int(u32, ecdsa_sha256);
    try one_signature.prefixed(signature);
    var signatures: Bytes = .{ .gpa = gpa };
    try signatures.prefixed(one_signature.list.items);

    var signer: Bytes = .{ .gpa = gpa };
    try signer.prefixed(signed.list.items);
    try signer.prefixed(signatures.list.items);
    try signer.prefixed(public_key);
    var signers: Bytes = .{ .gpa = gpa };
    try signers.prefixed(signer.list.items);
    var value: Bytes = .{ .gpa = gpa };
    try value.prefixed(signers.list.items);

    var block: Bytes = .{ .gpa = gpa };
    const pair_length = 4 + value.list.items.len;
    const block_size: u64 = 8 + pair_length + 8 + 16;
    try block.int(u64, block_size);
    try block.int(u64, pair_length);
    try block.int(u32, v2_block_id);
    try block.list.appendSlice(gpa, value.list.items);
    try block.int(u64, block_size);
    try block.list.appendSlice(gpa, "APK Sig Block 42");
    return block.list.toOwnedSlice(gpa);
}

/// Little-endian, length-prefixed byte sequences, as the v2 block nests them.
const Bytes = struct {
    gpa: std.mem.Allocator,
    list: std.ArrayList(u8) = .empty,

    fn int(self: *Bytes, comptime T: type, value: T) !void {
        try self.list.appendSlice(self.gpa, std.mem.asBytes(&std.mem.nativeToLittle(T, value)));
    }

    fn prefixed(self: *Bytes, data: []const u8) !void {
        try self.int(u32, @intCast(data.len));
        try self.list.appendSlice(self.gpa, data);
    }
};

/// DER, for the two structures the signature carries.
fn der(gpa: std.mem.Allocator, tag: u8, parts: []const []const u8) ![]u8 {
    var length: usize = 0;
    for (parts) |part| length += part.len;
    var out: std.ArrayList(u8) = .empty;
    try out.append(gpa, tag);
    if (length < 0x80) {
        try out.append(gpa, @intCast(length));
    } else if (length < 0x100) {
        try out.appendSlice(gpa, &.{ 0x81, @intCast(length) });
    } else {
        try out.appendSlice(gpa, &.{ 0x82, @intCast(length >> 8), @truncate(length) });
    }
    for (parts) |part| try out.appendSlice(gpa, part);
    return out.toOwnedSlice(gpa);
}

const ec_public_key_oid = [_]u8{ 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01 };
const prime256v1_oid = [_]u8{ 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07 };
const ecdsa_with_sha256_oid = [_]u8{ 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02 };
const common_name_oid = [_]u8{ 0x06, 0x03, 0x55, 0x04, 0x03 };

/// The key as an X.509 SubjectPublicKeyInfo.
fn subjectPublicKey(gpa: std.mem.Allocator, key: Ecdsa.PublicKey) ![]u8 {
    const point = key.toUncompressedSec1();
    const algorithm = try der(gpa, 0x30, &.{ &ec_public_key_oid, &prime256v1_oid });
    const bits = try der(gpa, 0x03, &.{ &.{0}, &point });
    return der(gpa, 0x30, &.{ algorithm, bits });
}

/// A self-signed X.509 certificate for "limn debug", valid until 2050.
fn selfSigned(gpa: std.mem.Allocator, key: Ecdsa.KeyPair, public_key: []const u8) ![]u8 {
    const algorithm = try der(gpa, 0x30, &.{&ecdsa_with_sha256_oid});
    const name = try der(gpa, 0x30, &.{try der(gpa, 0x31, &.{try der(gpa, 0x30, &.{ &common_name_oid, try der(gpa, 0x0c, &.{"limn debug"}) })})});
    const validity = try der(gpa, 0x30, &.{ try der(gpa, 0x17, &.{"260101000000Z"}), try der(gpa, 0x18, &.{"20500101000000Z"}) });
    const version = try der(gpa, 0xa0, &.{&.{ 0x02, 0x01, 0x02 }});
    const serial = [_]u8{ 0x02, 0x01, 0x01 };
    const to_sign = try der(gpa, 0x30, &.{ version, &serial, algorithm, name, validity, name, public_key });
    var signature_der: [Ecdsa.Signature.der_encoded_length_max]u8 = undefined;
    const signature = (try key.sign(to_sign, null)).toDer(&signature_der);
    return der(gpa, 0x30, &.{ to_sign, algorithm, try der(gpa, 0x03, &.{ &.{0}, signature }) });
}

test "a packed APK carries a v2 signature over its own bytes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const key = try debugKey();
    const entries = [_]Entry{
        .{ .name = "AndroidManifest.xml", .data = try manifest(gpa, "org.limn.test", "limn test") },
        .{ .name = "lib/arm64-v8a/libmain.so", .data = "\x7fELF library", .alignment = 4096 },
        .{ .name = "assets/limn_files.txt", .data = "" },
    };
    const apk = try pack(gpa, &entries, key);

    const end = apk[apk.len - 22 ..];
    try std.testing.expectEqual(@as(u32, 0x06054b50), std.mem.readInt(u32, end[0..4], .little));
    const directory_offset = std.mem.readInt(u32, end[16..20], .little);
    const directory_size = std.mem.readInt(u32, end[12..16], .little);
    try std.testing.expectEqualStrings("APK Sig Block 42", apk[directory_offset - 16 .. directory_offset]);
    const block_size = std.mem.readInt(u64, apk[directory_offset - 24 ..][0..8], .little);
    const block_start = directory_offset - 8 - block_size;
    try std.testing.expectEqual(block_size, std.mem.readInt(u64, apk[block_start..][0..8], .little));

    var at = block_start + 8;
    const pair_length = std.mem.readInt(u64, apk[at..][0..8], .little);
    try std.testing.expectEqual(@as(u32, v2_block_id), std.mem.readInt(u32, apk[at + 8 ..][0..4], .little));
    at += 12;
    const value = apk[at .. at + pair_length - 4];
    const signer = lengthPrefixed(lengthPrefixed(value, 0).body, 0).body;
    const signed = lengthPrefixed(signer, 0);
    const signatures = lengthPrefixed(signer, signed.next);
    const public_key = lengthPrefixed(signer, signatures.next).body;
    const signature = lengthPrefixed(lengthPrefixed(signatures.body, 0).body, 4).body;
    const point = public_key[public_key.len - 65 ..];
    try (try Ecdsa.Signature.fromDer(signature)).verify(signed.body, try Ecdsa.PublicKey.fromSec1(point));

    const moved_end = try gpa.dupe(u8, end);
    std.mem.writeInt(u32, moved_end[16..20], @intCast(block_start), .little);
    const expected = try digest(gpa, &.{ apk[0..block_start], apk[directory_offset .. directory_offset + directory_size], moved_end });
    const recorded = lengthPrefixed(lengthPrefixed(lengthPrefixed(signed.body, 0).body, 0).body, 4).body;
    try std.testing.expectEqualSlices(u8, &expected, recorded);
    try std.testing.expectEqual(@as(usize, 0), (std.mem.indexOf(u8, apk, "\x7fELF library").?) % 4096);
}

fn lengthPrefixed(data: []const u8, at: usize) struct { body: []const u8, next: usize } {
    const length = std.mem.readInt(u32, data[at..][0..4], .little);
    return .{ .body = data[at + 4 .. at + 4 + length], .next = at + 4 + length };
}
