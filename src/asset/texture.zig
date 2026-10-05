//! Texture processing for baked assets: CPU mip chains and BC7 block
//! compression. Built optimized even in debug builds (see build.zig), since
//! it runs over every texel of every texture.
//!
//! The encoder emits BC7 mode 6 (one endpoint pair per 4x4 block, 7-bit
//! RGBA endpoints with a shared low bit, 4-bit indices), which is exact
//! enough for smooth and noisy single-gradient blocks and handles alpha,
//! and for opaque blocks that mix two unrelated hues mode 1 (two groups of
//! texels with an endpoint pair each, 3-bit indices).
const std = @import("std");

/// Bump when the encoder output changes, so cached files are rebuilt.
pub const version: u32 = 2;

/// Squared error over a block above which the two-group mode is tried.
const two_group_threshold: f32 = 16 * 3 * 4;

const Vec = @Vector(4, f32);
const weights = [16]u8{ 0, 4, 9, 13, 17, 21, 26, 30, 34, 38, 43, 47, 51, 55, 60, 64 };

/// Levels in a full mip chain: from `width` x `height` down to 1x1, each
/// half the one before.
pub fn mipCount(width: u32, height: u32) u32 {
    return std.math.log2_int(u32, @max(width, height, 1)) + 1;
}

/// Bytes one BC7 mip level occupies.
pub fn levelSize(width: u32, height: u32) usize {
    return @as(usize, (width + 3) / 4) * ((height + 3) / 4) * 16;
}

/// Bytes one mip level occupies in a given block format.
pub fn levelSizeOf(codec: Codec, width: u32, height: u32) usize {
    return @as(usize, (width + 3) / 4) * ((height + 3) / 4) * @as(usize, if (codec == .bc4) 8 else 16);
}

/// Bytes of a full mip chain in a given block format.
pub fn chainSizeOf(codec: Codec, width: u32, height: u32) usize {
    return if (codec == .bc4) chainSize(width, height) / 2 else chainSize(width, height);
}

/// Bytes of a full BC7 mip chain.
pub fn chainSize(width: u32, height: u32) usize {
    var total: usize = 0;
    var w = width;
    var h = height;
    while (true) {
        total += levelSize(w, h);
        if (w == 1 and h == 1) break;
        w = @max(w / 2, 1);
        h = @max(h / 2, 1);
    }
    return total;
}

/// Builds every mip of an RGBA8 image and encodes each as BC7. The result
/// holds the levels back to back, largest first. `srgb` makes the mips
/// average light rather than encoded values.
pub fn encodeBc7Chain(gpa: std.mem.Allocator, pixels: []const u8, width: u32, height: u32, srgb: bool) ![]u8 {
    return encodeChain(gpa, pixels, width, height, srgb, .bc7);
}

/// Block formats the encoder writes.
pub const Codec = enum {
    /// Four channels; one mode (6) of the format.
    bc7,
    /// Red and green only, each with its own 8-step ramp per block: far
    /// more exact for those two, which is what normal maps need (the
    /// third component is rebuilt from the other two when shading).
    bc5,
    /// Red only, 8 bytes per block: for textures that hold one number
    /// per texel, such as a separate occlusion map.
    bc4,
};

/// As `encodeBc7Chain`, in either block format.
pub fn encodeChain(gpa: std.mem.Allocator, pixels: []const u8, width: u32, height: u32, srgb: bool, codec: Codec) ![]u8 {
    std.debug.assert(pixels.len == @as(usize, width) * height * 4);
    const output = try gpa.alloc(u8, chainSizeOf(codec, width, height));
    errdefer gpa.free(output);
    // Scratch for the two most recent levels.
    const scratch = try gpa.alloc(u8, @as(usize, @max(width / 2, 1)) * @max(height / 2, 1) * 4 * 2);
    defer gpa.free(scratch);
    const half = scratch.len / 2;

    var level: []const u8 = pixels;
    var w = width;
    var h = height;
    var cursor: usize = 0;
    var flip = false;
    while (true) {
        const size = levelSizeOf(codec, w, h);
        encodeLevel(level, w, h, output[cursor..][0..size], codec);
        cursor += size;
        if (w == 1 and h == 1) break;
        const next_w = @max(w / 2, 1);
        const next_h = @max(h / 2, 1);
        const next = (if (flip) scratch[half..] else scratch[0..half])[0 .. @as(usize, next_w) * next_h * 4];
        downsample(level, w, h, next, next_w, next_h, srgb);
        level = next;
        w = next_w;
        h = next_h;
        flip = !flip;
    }
    return output;
}

/// Builds every mip of an RGBA8 image and leaves them uncompressed: the
/// levels back to back, largest first, four bytes a texel. For textures
/// that are streamed without being compressed.
pub fn rawChain(gpa: std.mem.Allocator, pixels: []const u8, width: u32, height: u32, srgb: bool) ![]u8 {
    std.debug.assert(pixels.len == @as(usize, width) * height * 4);
    var total: usize = 0;
    {
        var w = width;
        var h = height;
        while (true) {
            total += @as(usize, w) * h * 4;
            if (w == 1 and h == 1) break;
            w = @max(w / 2, 1);
            h = @max(h / 2, 1);
        }
    }
    const output = try gpa.alloc(u8, total);
    errdefer gpa.free(output);
    @memcpy(output[0..pixels.len], pixels);
    var cursor: usize = 0;
    var w = width;
    var h = height;
    while (!(w == 1 and h == 1)) {
        const size = @as(usize, w) * h * 4;
        const next_w = @max(w / 2, 1);
        const next_h = @max(h / 2, 1);
        const next_size = @as(usize, next_w) * next_h * 4;
        // Each level is made from the one before it, already in place.
        downsample(output[cursor..][0..size], w, h, output[cursor + size ..][0..next_size], next_w, next_h, srgb);
        cursor += size;
        w = next_w;
        h = next_h;
    }
    return output;
}

fn downsample(source: []const u8, width: u32, height: u32, out: []u8, out_width: u32, out_height: u32, srgb: bool) void {
    for (0..out_height) |y| {
        const y0 = @min(y * 2, height - 1);
        const y1 = @min(y * 2 + 1, height - 1);
        for (0..out_width) |x| {
            const x0 = @min(x * 2, width - 1);
            const x1 = @min(x * 2 + 1, width - 1);
            const taps = [4]usize{ (y0 * width + x0) * 4, (y0 * width + x1) * 4, (y1 * width + x0) * 4, (y1 * width + x1) * 4 };
            const target = out[(y * out_width + x) * 4 ..][0..4];
            inline for (0..4) |channel| {
                if (srgb and channel < 3) {
                    var sum: f32 = 0;
                    for (taps) |tap| sum += srgb_to_linear[source[tap + channel]];
                    target[channel] = linearToSrgb(sum * 0.25);
                } else {
                    var sum: u32 = 2;
                    for (taps) |tap| sum += source[tap + channel];
                    target[channel] = @intCast(sum / 4);
                }
            }
        }
    }
}

const srgb_to_linear: [256]f32 = blk: {
    @setEvalBranchQuota(100_000);
    var table: [256]f32 = undefined;
    for (&table, 0..) |*entry, index| {
        const c = @as(f32, @floatFromInt(index)) / 255.0;
        entry.* = if (c <= 0.04045) c / 12.92 else std.math.pow(f32, (c + 0.055) / 1.055, 2.4);
    }
    break :blk table;
};

fn linearToSrgb(value: f32) u8 {
    const c = std.math.clamp(value, 0, 1);
    const encoded = if (c <= 0.0031308) c * 12.92 else 1.055 * std.math.pow(f32, c, 1.0 / 2.4) - 0.055;
    return @intFromFloat(encoded * 255.0 + 0.5);
}

fn encodeLevel(pixels: []const u8, width: u32, height: u32, out: []u8, codec: Codec) void {
    const blocks_x = (width + 3) / 4;
    const blocks_y = (height + 3) / 4;
    for (0..blocks_y) |by| {
        for (0..blocks_x) |bx| {
            var block: [16][4]u8 = undefined;
            for (0..4) |y| {
                const sy = @min(by * 4 + y, height - 1);
                for (0..4) |x| {
                    const sx = @min(bx * 4 + x, width - 1);
                    block[y * 4 + x] = pixels[(sy * width + sx) * 4 ..][0..4].*;
                }
            }
            if (codec == .bc4) {
                var red: [16]u8 = undefined;
                for (block, &red) |texel, *r| r.* = texel[0];
                out[(by * blocks_x + bx) * 8 ..][0..8].* = encodeBc4(&red);
                continue;
            }
            out[(by * blocks_x + bx) * 16 ..][0..16].* = switch (codec) {
                .bc7 => encodeBlock(&block),
                .bc5 => encodeBc5Block(&block),
                .bc4 => unreachable,
            };
        }
    }
}

const Endpoint = struct {
    /// 7-bit channel values.
    q: [4]u8,
    p: u1,

    fn value(self: Endpoint) Vec {
        var result: Vec = undefined;
        inline for (0..4) |c| result[c] = @floatFromInt(@as(u32, self.q[c]) * 2 + self.p);
        return result;
    }
};

fn quantize(endpoint: Vec, force_p: ?u1) Endpoint {
    var best: Endpoint = undefined;
    var best_error = std.math.inf(f32);
    for ([2]u1{ 0, 1 }) |p| {
        if (force_p) |forced| if (forced != p) continue;
        var candidate = Endpoint{ .q = undefined, .p = p };
        var err: f32 = 0;
        inline for (0..4) |c| {
            const q = std.math.clamp(@round((endpoint[c] - @as(f32, @floatFromInt(p))) * 0.5), 0, 127);
            candidate.q[c] = @intFromFloat(q);
            const delta = q * 2 + @as(f32, @floatFromInt(p)) - endpoint[c];
            err += delta * delta;
        }
        if (err < best_error) {
            best_error = err;
            best = candidate;
        }
    }
    return best;
}

fn dot(a: Vec, b: Vec) f32 {
    return @reduce(.Add, a * b);
}

fn assignIndices(colors: *const [16]Vec, e0: Vec, e1: Vec, indices: *[16]u8) void {
    const direction = e1 - e0;
    const length_squared = dot(direction, direction);
    for (colors, indices) |color, *index| {
        const t = if (length_squared > 1e-6) dot(color - e0, direction) / length_squared else 0;
        index.* = @intFromFloat(std.math.clamp(@round(t * 15), 0, 15));
    }
}

/// The 64 ways BC7 splits a block into two groups of texels: bit i set
/// puts texel i (row by row) in the second group.
pub const partitions = [64]u16{
    0xCCCC, 0x8888, 0xEEEE, 0xECC8, 0xC880, 0xFEEC, 0xFEC8, 0xEC80,
    0xC800, 0xFFEC, 0xFE80, 0xE800, 0xFFE8, 0xFF00, 0xFFF0, 0xF000,
    0xF710, 0x008E, 0x7100, 0x08CE, 0x008C, 0x7310, 0x3100, 0x8CCE,
    0x088C, 0x3110, 0x6666, 0x366C, 0x17E8, 0x0FF0, 0x718E, 0x399C,
    0xAAAA, 0xF0F0, 0x5A5A, 0x33CC, 0x3C3C, 0x55AA, 0x9696, 0xA55A,
    0x73CE, 0x13C8, 0x324C, 0x3BDC, 0x6996, 0xC33C, 0x9966, 0x0660,
    0x0272, 0x04E4, 0x4E40, 0x2720, 0xC936, 0x936C, 0x39C6, 0x639C,
    0x9336, 0x9CC6, 0x817E, 0xE718, 0xCCF0, 0x0FCC, 0x7744, 0xEE22,
};

/// For each split, the texel of the second group whose index is stored
/// one bit short (the first group's is always texel 0).
const second_anchor = [64]u8{
    15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
    15, 2,  8,  2,  2,  8,  8,  15, 2,  8,  2,  2,  8,  8,  2,  2,
    15, 15, 6,  8,  2,  8,  15, 15, 2,  8,  2,  2,  2,  15, 15, 6,
    6,  2,  6,  8,  15, 15, 2,  2,  15, 15, 15, 15, 15, 2,  2,  15,
};

/// Weights of the eight steps between two end points with 3-bit indices.
const weights3 = [8]u8{ 0, 9, 18, 27, 37, 46, 55, 64 };

/// A mode 1 end point: six bits a channel plus a low bit the group's two
/// end points share, widened to eight bits the way the format does.
fn widen6(q: u8, p: u1) f32 {
    const seven: u32 = @as(u32, q) << 1 | p;
    return @floatFromInt(seven << 1 | seven >> 6);
}

const TwoGroups = struct { bits: u128, failure: f32 };

/// Encodes an opaque block as BC7 mode 1 with the given split: each of
/// the two groups gets its own pair of end colors (6 bits a channel and a
/// shared low bit) and 3-bit indices. Returns the block and its squared
/// error over the color channels.
fn encodeTwoGroups(colors: *const [16]Vec, partition: u8) TwoGroups {
    const mask = partitions[partition];
    var q: [2][2][3]u8 = undefined;
    var p: [2]u1 = undefined;
    var indices: [16]u8 = undefined;
    var failure: f32 = 0;
    for (0..2) |group| {
        // The group's colors, their middle, and their longest axis.
        var mean: Vec = @splat(0);
        var count: f32 = 0;
        var minimum: Vec = @splat(255);
        var maximum: Vec = @splat(0);
        for (colors, 0..) |color, texel| {
            if ((mask >> @intCast(texel)) & 1 != group) continue;
            mean += color;
            count += 1;
            minimum = @min(minimum, color);
            maximum = @max(maximum, color);
        }
        mean /= @splat(@max(count, 1));
        var covariance: [3]Vec = @splat(@splat(0));
        for (colors, 0..) |color, texel| {
            if ((mask >> @intCast(texel)) & 1 != group) continue;
            const d = color - mean;
            inline for (0..3) |c| covariance[c] += d * @as(Vec, @splat(d[c]));
        }
        var axis = maximum - minimum;
        axis[3] = 0;
        for (0..4) |_| {
            var next: Vec = @splat(0);
            inline for (0..3) |c| next += covariance[c] * @as(Vec, @splat(axis[c]));
            next[3] = 0;
            const length = @sqrt(dot(next, next));
            if (length < 1e-6) break;
            axis = next / @as(Vec, @splat(length));
        }
        const axis_length = @sqrt(dot(axis, axis));
        if (axis_length > 1e-6) axis /= @splat(axis_length);
        var low: f32 = std.math.inf(f32);
        var high: f32 = -std.math.inf(f32);
        for (colors, 0..) |color, texel| {
            if ((mask >> @intCast(texel)) & 1 != group) continue;
            const t = dot(color - mean, axis);
            low = @min(low, t);
            high = @max(high, t);
        }
        if (count == 0) {
            low = 0;
            high = 0;
        }
        const ends = [2]Vec{ mean + axis * @as(Vec, @splat(low)), mean + axis * @as(Vec, @splat(high)) };
        // The shared low bit that leaves both ends closest.
        var best_error = std.math.inf(f32);
        for ([2]u1{ 0, 1 }) |low_bit| {
            var candidate: [2][3]u8 = undefined;
            var err: f32 = 0;
            for (ends, &candidate) |end, *out| inline for (0..3) |c| {
                const target = std.math.clamp(end[c], 0, 255);
                // Seven bits with the low one fixed, then the nearest six.
                const seven = std.math.clamp(@round((target / 255.0 * 127.0 - @as(f32, @floatFromInt(low_bit))) * 0.5), 0, 63);
                out[c] = @intFromFloat(seven);
                const delta = widen6(out[c], low_bit) - target;
                err += delta * delta;
            };
            if (err < best_error) {
                best_error = err;
                q[group] = candidate;
                p[group] = low_bit;
            }
        }
        var a: Vec = @splat(255);
        var b: Vec = @splat(255);
        inline for (0..3) |c| {
            a[c] = widen6(q[group][0][c], p[group]);
            b[c] = widen6(q[group][1][c], p[group]);
        }
        const direction = b - a;
        const length_squared = dot(direction, direction);
        for (colors, 0..) |color, texel| {
            if ((mask >> @intCast(texel)) & 1 != group) continue;
            // The nearest of the eight steps.
            var best_index: u8 = 0;
            var best_distance = std.math.inf(f32);
            const guess: i32 = if (length_squared > 1e-6) @intFromFloat(std.math.clamp(@round(dot(color - a, direction) / length_squared * 7), 0, 7)) else 0;
            var candidate_index: i32 = @max(guess - 1, 0);
            while (candidate_index <= @min(guess + 1, 7)) : (candidate_index += 1) {
                const w: f32 = @floatFromInt(weights3[@intCast(candidate_index)]);
                var delta = @floor((a * @as(Vec, @splat(64 - w)) + b * @as(Vec, @splat(w)) + @as(Vec, @splat(32))) / @as(Vec, @splat(64))) - color;
                delta[3] = 0;
                const distance = dot(delta, delta);
                if (distance < best_distance) {
                    best_distance = distance;
                    best_index = @intCast(candidate_index);
                }
            }
            indices[texel] = best_index;
            failure += best_distance;
        }
        // The group's anchor index is stored without its top bit.
        const anchor: usize = if (group == 0) 0 else second_anchor[partition];
        if (indices[anchor] >= 4) {
            std.mem.swap([3]u8, &q[group][0], &q[group][1]);
            for (&indices, 0..) |*index, texel| {
                if ((mask >> @intCast(texel)) & 1 == group) index.* = 7 - index.*;
            }
        }
    }
    var bits: u128 = 0b10 | @as(u128, partition) << 2;
    var position: u7 = 8;
    inline for (0..3) |c| {
        for (0..2) |group| for (0..2) |end| {
            bits |= @as(u128, q[group][end][c]) << position;
            position += 6;
        };
    }
    bits |= @as(u128, p[0]) << position;
    position += 1;
    bits |= @as(u128, p[1]) << position;
    position += 1;
    for (indices, 0..) |index, texel| {
        const width: u7 = if (texel == 0 or texel == second_anchor[partition]) 2 else 3;
        bits |= @as(u128, index) << position;
        position +%= width;
    }
    return .{ .bits = bits, .failure = failure };
}

/// Encodes sixteen RGBA8 texels (row by row) as one BC7 mode 6 block.
pub fn encodeBlock(block: *const [16][4]u8) [16]u8 {
    var colors: [16]Vec = undefined;
    var mean: Vec = @splat(0);
    var minimum: Vec = @splat(255);
    var maximum: Vec = @splat(0);
    var opaque_block = true;
    for (block, &colors) |texel, *color| {
        inline for (0..4) |c| color[c] = @floatFromInt(texel[c]);
        mean += color.*;
        minimum = @min(minimum, color.*);
        maximum = @max(maximum, color.*);
        opaque_block = opaque_block and texel[3] == 255;
    }
    mean /= @splat(16);
    // Opaque textures must stay exactly opaque: alpha 255 needs the low bit.
    const force_p: ?u1 = if (opaque_block) 1 else null;

    // Principal axis of the block's colors by power iteration, started
    // from the bounding box diagonal.
    var covariance: [4]Vec = @splat(@splat(0));
    for (colors) |color| {
        const d = color - mean;
        inline for (0..4) |c| covariance[c] += d * @as(Vec, @splat(d[c]));
    }
    var axis = maximum - minimum;
    for (0..4) |_| {
        var next: Vec = @splat(0);
        inline for (0..4) |c| next += covariance[c] * @as(Vec, @splat(axis[c]));
        const length = @sqrt(dot(next, next));
        if (length < 1e-6) break;
        axis = next / @as(Vec, @splat(length));
    }
    const axis_length = @sqrt(dot(axis, axis));
    if (axis_length > 1e-6) axis /= @splat(axis_length);

    var low: f32 = std.math.inf(f32);
    var high: f32 = -std.math.inf(f32);
    for (colors) |color| {
        const t = dot(color - mean, axis);
        low = @min(low, t);
        high = @max(high, t);
    }
    const zero: Vec = @splat(0);
    const full: Vec = @splat(255);
    var e0 = quantize(std.math.clamp(mean + axis * @as(Vec, @splat(low)), zero, full), force_p);
    var e1 = quantize(std.math.clamp(mean + axis * @as(Vec, @splat(high)), zero, full), force_p);
    var indices: [16]u8 = undefined;
    assignIndices(&colors, e0.value(), e1.value(), &indices);

    // One least-squares pass: the best endpoints for the chosen indices.
    {
        var a: f32 = 0;
        var b: f32 = 0;
        var c: f32 = 0;
        var rhs0: Vec = @splat(0);
        var rhs1: Vec = @splat(0);
        for (colors, indices) |color, index| {
            const w = @as(f32, @floatFromInt(weights[index])) / 64.0;
            a += (1 - w) * (1 - w);
            b += w * (1 - w);
            c += w * w;
            rhs0 += color * @as(Vec, @splat(1 - w));
            rhs1 += color * @as(Vec, @splat(w));
        }
        const determinant = a * c - b * b;
        if (@abs(determinant) > 1e-4) {
            const inverse: Vec = @splat(1.0 / determinant);
            const refined0 = (rhs0 * @as(Vec, @splat(c)) - rhs1 * @as(Vec, @splat(b))) * inverse;
            const refined1 = (rhs1 * @as(Vec, @splat(a)) - rhs0 * @as(Vec, @splat(b))) * inverse;
            const r0 = quantize(std.math.clamp(refined0, zero, full), force_p);
            const r1 = quantize(std.math.clamp(refined1, zero, full), force_p);
            var refined_indices: [16]u8 = undefined;
            assignIndices(&colors, r0.value(), r1.value(), &refined_indices);
            if (blockError(&colors, r0, r1, &refined_indices) < blockError(&colors, e0, e1, &indices)) {
                e0 = r0;
                e1 = r1;
                indices = refined_indices;
            }
        }
    }

    // The first index stores only three bits; its top bit must be zero.
    if (indices[0] >= 8) {
        std.mem.swap(Endpoint, &e0, &e1);
        for (&indices) |*index| index.* = 15 - index.*;
    }

    var bits: u128 = 1 << 6;
    var position: u7 = 7;
    inline for (0..4) |c| {
        bits |= @as(u128, e0.q[c]) << position;
        position += 7;
        bits |= @as(u128, e1.q[c]) << position;
        position += 7;
    }
    bits |= @as(u128, e0.p) << position;
    position += 1;
    bits |= @as(u128, e1.p) << position;
    position += 1;
    bits |= @as(u128, indices[0]) << position;
    position += 3;
    for (indices[1..]) |index| {
        bits |= @as(u128, index) << position;
        position +%= 4;
    }
    // A block of two unrelated colors (an edge between two surfaces) fits
    // a single line through color space badly. When it does, try giving
    // each side of the block its own pair of end colors (mode 1): the
    // split is guessed from which end of the line each texel fell toward,
    // and the three closest of the format's 64 splits are tried.
    if (opaque_block) {
        const single_failure = blockError(&colors, e0, e1, &indices);
        if (single_failure > two_group_threshold) {
            var sides: u16 = 0;
            for (indices, 0..) |index, texel| {
                if (index >= 8) sides |= @as(u16, 1) << @intCast(texel);
            }
            var best_bits = bits;
            var best_failure = single_failure;
            var tried: [3]u8 = .{ 255, 255, 255 };
            for (&tried) |*slot| {
                var closest: u8 = 255;
                var closest_distance: u32 = 99;
                for (partitions, 0..) |partition, index| {
                    if (index == tried[0] or index == tried[1] or index == tried[2]) continue;
                    const differing = @popCount(partition ^ sides);
                    const distance = @min(differing, 16 - differing);
                    if (distance < closest_distance) {
                        closest_distance = distance;
                        closest = @intCast(index);
                    }
                }
                slot.* = closest;
                const candidate = encodeTwoGroups(&colors, closest);
                if (candidate.failure < best_failure) {
                    best_failure = candidate.failure;
                    best_bits = candidate.bits;
                }
            }
            bits = best_bits;
        }
    }
    return @bitCast(std.mem.nativeToLittle(u128, bits));
}

fn interpolate(e0: Vec, e1: Vec, index: u8) Vec {
    const w: f32 = @floatFromInt(weights[index]);
    return @floor((e0 * @as(Vec, @splat(64 - w)) + e1 * @as(Vec, @splat(w)) + @as(Vec, @splat(32))) / @as(Vec, @splat(64)));
}

fn blockError(colors: *const [16]Vec, e0: Endpoint, e1: Endpoint, indices: *const [16]u8) f32 {
    var total: f32 = 0;
    const a = e0.value();
    const b = e1.value();
    for (colors, indices) |color, index| {
        const delta = interpolate(a, b, index) - color;
        total += dot(delta, delta);
    }
    return total;
}

/// Decodes a block of either mode the encoder writes. Only used to check
/// the encoder.
pub fn decodeBlock(data: [16]u8) [16][4]u8 {
    const bits = std.mem.littleToNative(u128, @bitCast(data));
    if (bits & 0b11 == 0b10) return decodeTwoGroups(bits);
    std.debug.assert(bits & 0x7f == 1 << 6);
    var position: u7 = 7;
    var e0 = Endpoint{ .q = undefined, .p = 0 };
    var e1 = Endpoint{ .q = undefined, .p = 0 };
    inline for (0..4) |c| {
        e0.q[c] = @intCast((bits >> position) & 0x7f);
        position += 7;
        e1.q[c] = @intCast((bits >> position) & 0x7f);
        position += 7;
    }
    e0.p = @intCast((bits >> position) & 1);
    position += 1;
    e1.p = @intCast((bits >> position) & 1);
    position += 1;
    var result: [16][4]u8 = undefined;
    for (&result, 0..) |*texel, pixel| {
        const width: u7 = if (pixel == 0) 3 else 4;
        const index: u8 = @intCast((bits >> position) & ((@as(u128, 1) << width) - 1));
        position +%= width;
        const color = interpolate(e0.value(), e1.value(), index);
        inline for (0..4) |c| texel[c] = @intFromFloat(color[c]);
    }
    return result;
}

fn decodeTwoGroups(bits: u128) [16][4]u8 {
    const partition: u8 = @intCast((bits >> 2) & 0x3f);
    const mask = partitions[partition];
    var position: u7 = 8;
    var q: [2][2][3]u8 = undefined;
    inline for (0..3) |c| {
        for (0..2) |group| for (0..2) |end| {
            q[group][end][c] = @intCast((bits >> position) & 0x3f);
            position += 6;
        };
    }
    var p: [2]u1 = undefined;
    for (&p) |*bit| {
        bit.* = @intCast((bits >> position) & 1);
        position += 1;
    }
    var result: [16][4]u8 = undefined;
    for (&result, 0..) |*texel, pixel| {
        const width: u7 = if (pixel == 0 or pixel == second_anchor[partition]) 2 else 3;
        const index: u8 = @intCast((bits >> position) & ((@as(u128, 1) << width) - 1));
        position +%= width;
        const group: usize = (mask >> @intCast(pixel)) & 1;
        const w: f32 = @floatFromInt(weights3[index]);
        inline for (0..3) |c| {
            const a = widen6(q[group][0][c], p[group]);
            const b = widen6(q[group][1][c], p[group]);
            texel[c] = @intFromFloat(@floor((a * (64 - w) + b * w + 32) / 64));
        }
        texel[3] = 255;
    }
    return result;
}

test "a block of two colors is kept by giving each its own end points" {
    // Left half red to dark red, right half blue to cyan: no one line
    // through color space fits both.
    var block: [16][4]u8 = undefined;
    for (&block, 0..) |*texel, index| {
        const row: u8 = @intCast(index / 4);
        texel.* = if (index % 4 < 2) .{ 250 - row * 40, 20, 10, 255 } else .{ 10, 60 + row * 50, 240, 255 };
    }
    const encoded = encodeBlock(&block);
    // It chose the two-group mode.
    try std.testing.expectEqual(@as(u8, 0b10), encoded[0] & 0b11);
    const decoded = decodeBlock(encoded);
    for (decoded, block) |got, expected| {
        inline for (0..3) |c| try std.testing.expect(@abs(@as(i32, got[c]) - @as(i32, expected[c])) <= 13);
        try std.testing.expectEqual(@as(u8, 255), got[3]);
    }
}

test "flat opaque blocks survive exactly enough" {
    var block: [16][4]u8 = @splat(.{ 200, 100, 51, 255 });
    const decoded = decodeBlock(encodeBlock(&block));
    for (decoded) |texel| {
        try std.testing.expectEqual(@as(u8, 255), texel[3]);
        inline for (0..3) |c| try std.testing.expect(@abs(@as(i32, texel[c]) - @as(i32, block[0][c])) <= 1);
    }
    block[5] = .{ 0, 0, 0, 255 };
    try std.testing.expectEqual(@as(u8, 255), decodeBlock(encodeBlock(&block))[5][3]);
}

test "gradients with alpha decode within a few levels" {
    var block: [16][4]u8 = undefined;
    for (&block, 0..) |*texel, index| {
        const t: u8 = @intCast(index * 15);
        texel.* = .{ t, 255 - t, 40 + t / 2, 30 + t / 2 };
    }
    const decoded = decodeBlock(encodeBlock(&block));
    for (decoded, block) |got, expected| {
        inline for (0..4) |c| try std.testing.expect(@abs(@as(i32, got[c]) - @as(i32, expected[c])) <= 6);
    }
}

test "chain sizes" {
    try std.testing.expectEqual(@as(u32, 11), mipCount(1024, 512));
    try std.testing.expectEqual(@as(usize, 16), levelSize(1, 1));
    try std.testing.expectEqual(@as(usize, 16 * 4 + 16 + 16 + 16), chainSize(8, 8));
    const pixels: [8 * 8 * 4]u8 = @splat(128);
    const chain = try encodeBc7Chain(std.testing.allocator, &pixels, 8, 8, true);
    defer std.testing.allocator.free(chain);
    try std.testing.expectEqual(chainSize(8, 8), chain.len);
}

/// One channel of sixteen texels as a BC4 block: two end values and a
/// 3-bit choice among the eight steps between them per texel.
fn encodeBc4(values: *const [16]u8) [8]u8 {
    var low: u8 = 255;
    var high: u8 = 0;
    for (values) |value| {
        low = @min(low, value);
        high = @max(high, value);
    }
    var out: [8]u8 = @splat(0);
    out[0] = high;
    out[1] = low;
    // Equal ends would select the six-step mode; all indices stay 0.
    if (high == low) return out;
    var bits: u64 = 0;
    const range: f32 = @floatFromInt(high - low);
    for (values, 0..) |value, texel| {
        const step: u32 = @intFromFloat(@as(f32, @floatFromInt(high - value)) / range * 7 + 0.5);
        // Index 0 is the high end, 1 the low end, 2..7 the steps between.
        const index: u64 = if (step == 0) 0 else if (step == 7) 1 else step + 1;
        bits |= index << @intCast(texel * 3);
    }
    inline for (0..6) |byte| out[2 + byte] = @truncate(bits >> (byte * 8));
    return out;
}

fn decodeBc4(block: [8]u8) [16]u8 {
    var palette: [8]u8 = undefined;
    palette[0] = block[0];
    palette[1] = block[1];
    const high: u32 = block[0];
    const low: u32 = block[1];
    if (high > low) {
        inline for (1..7) |step| palette[step + 1] = @intCast(((7 - step) * high + step * low + 3) / 7);
    } else {
        inline for (1..5) |step| palette[step + 1] = @intCast(((5 - step) * high + step * low + 2) / 5);
        palette[6] = 0;
        palette[7] = 255;
    }
    var bits: u64 = 0;
    inline for (0..6) |byte| bits |= @as(u64, block[2 + byte]) << (byte * 8);
    var out: [16]u8 = undefined;
    for (&out, 0..) |*value, texel| value.* = palette[@intCast((bits >> @intCast(texel * 3)) & 7)];
    return out;
}

/// Red and green of sixteen texels as a BC5 block.
pub fn encodeBc5Block(block: *const [16][4]u8) [16]u8 {
    var red: [16]u8 = undefined;
    var green: [16]u8 = undefined;
    for (block, &red, &green) |texel, *r, *g| {
        r.* = texel[0];
        g.* = texel[1];
    }
    var out: [16]u8 = undefined;
    out[0..8].* = encodeBc4(&red);
    out[8..16].* = encodeBc4(&green);
    return out;
}

test "a BC5 block keeps red and green within half a step" {
    var block: [16][4]u8 = undefined;
    for (&block, 0..) |*texel, index| texel.* = .{ @intCast(40 + index * 9), @intCast(200 - index * 5), 0, 255 };
    const encoded = encodeBc5Block(&block);
    const red = decodeBc4(encoded[0..8].*);
    const green = decodeBc4(encoded[8..16].*);
    for (block, red, green) |texel, r, g| {
        // Eight steps across a range of 135 and of 75.
        try std.testing.expect(@abs(@as(i32, texel[0]) - r) <= 10);
        try std.testing.expect(@abs(@as(i32, texel[1]) - g) <= 6);
    }
    // A flat block is exact.
    const flat: [16][4]u8 = @splat(.{ 128, 128, 255, 255 });
    const flat_encoded = encodeBc5Block(&flat);
    for (decodeBc4(flat_encoded[0..8].*)) |value| try std.testing.expectEqual(@as(u8, 128), value);
}
