//! Skeletal animation sampling: turns a clip and a time into node world
//! matrices. Pure CPU math over the imported glTF node hierarchy.
const std = @import("std");
const math = @import("../math.zig");
const gltf = @import("../asset/gltf.zig");

/// What an animated entity looks like at one moment: a base clip and a
/// time, with optional clips blended on top. A plain value; the
/// application advances `time` itself and hands the pose over each frame
/// (`Renderer.setPose`).
pub const Pose = struct {
    /// Index into the model's animation list (`Renderer.findAnimation`).
    /// An index past the end of the list gives the rest pose.
    animation: u32,
    /// Seconds into the clip.
    time: f32,
    /// True wraps `time` around the clip's length; false holds the first
    /// frame before 0 and the last frame past the end.
    loop: bool = true,
    /// Optional second clip cross-faded on top, for transitions.
    blend: ?Blend = null,
    /// Further clips applied in order on top of that: each one moves the
    /// result so far toward (or, when additive, beyond) its own clip. With
    /// `root` set, only one part of the body is affected, e.g. a wave or
    /// an aim pose on the arms while the legs keep walking.
    layers: [max_layers]?Blend = @splat(null),
    /// Root motion: hold this node's travel along the ground (x and z)
    /// at its rest value, so the character animates on the spot and the
    /// application moves the entity instead, by `Renderer.rootMotion`.
    in_place: ?u32 = null,

    /// Most clips `layers` can hold.
    pub const max_layers = 4;

    /// One clip laid over the pose built so far.
    pub const Blend = struct {
        /// Index into the model's animation list.
        animation: u32,
        /// Seconds into this clip, independent of the base clip's time.
        time: f32,
        /// 0 leaves the pose as it is, 1 applies this clip entirely.
        weight: f32,
        /// Limit the effect to this node and everything below it (see
        /// `Renderer.findNode`). Null affects the whole skeleton.
        root: ?u32 = null,
        /// Add this clip's motion relative to its own first frame on top
        /// of the pose, instead of replacing the pose with it. For leans,
        /// recoil and breathing layered over any base animation.
        additive: bool = false,
        /// Whether this clip's time wraps; null follows `Pose.loop`.
        loop: ?bool = null,
    };
};

/// One node's transform relative to its parent, as sampled from a clip.
/// Scratch space for `evaluate` and `rootMotion` is a slice of these.
pub const Local = struct {
    translation: [3]f32,
    /// Unit quaternion, (x, y, z, w).
    rotation: [4]f32,
    scale: [3]f32,
};

/// Node indices ordered so that parents always precede their children.
pub fn topologicalOrder(gpa: std.mem.Allocator, nodes: []const gltf.Node) ![]u32 {
    const order = try gpa.alloc(u32, nodes.len);
    errdefer gpa.free(order);
    const placed = try gpa.alloc(bool, nodes.len);
    defer gpa.free(placed);
    @memset(placed, false);
    var count: usize = 0;
    // Each sweep places every node whose parent is already placed; a tree of
    // depth d needs d sweeps. Malformed cycles are broken by the guard.
    var sweeps: usize = 0;
    while (count < nodes.len and sweeps <= nodes.len) : (sweeps += 1) {
        for (nodes, 0..) |node, index| {
            if (placed[index]) continue;
            if (node.parent) |parent| if (parent < nodes.len and !placed[parent]) continue;
            placed[index] = true;
            order[count] = @intCast(index);
            count += 1;
        }
    }
    for (placed, 0..) |done, index| if (!done) {
        order[count] = @intCast(index);
        count += 1;
    };
    return order;
}

fn sampleClip(model: *const gltf.Model, locals: []Local, clip_index: u32, time_in: f32, loop: bool) void {
    for (model.nodes, locals) |node, *local| local.* = .{
        .translation = node.translation,
        .rotation = node.rotation,
        .scale = node.scale,
    };
    if (clip_index >= model.animations.len) return;
    const clip = model.animations[clip_index];
    const time = if (clip.duration <= 0)
        0
    else if (loop)
        @mod(time_in, clip.duration)
    else
        std.math.clamp(time_in, 0, clip.duration);
    for (clip.channels) |channel| {
        if (channel.node >= locals.len or channel.path == .weights) continue;
        const components: usize = if (channel.path == .rotation) 4 else 3;
        // Binary search for the keyframe at or before `time`.
        var low: usize = 0;
        var high: usize = channel.times.len;
        while (low + 1 < high) {
            const mid = (low + high) / 2;
            if (channel.times[mid] <= time) low = mid else high = mid;
        }
        const next = @min(low + 1, channel.times.len - 1);
        const span = channel.times[next] - channel.times[low];
        const t: f32 = if (channel.step or span <= 0) 0 else std.math.clamp((time - channel.times[low]) / span, 0, 1);
        var value: [4]f32 = undefined;
        if (channel.cubic) {
            // Hermite spline through the keys with the stored tangents.
            const stride = components * 3;
            const from = channel.values[low * stride ..][0..stride];
            const to = channel.values[next * stride ..][0..stride];
            const t2 = t * t;
            const t3 = t2 * t;
            for (0..components) |c| {
                const p0 = from[components + c];
                const m0 = from[components * 2 + c] * span;
                const p1 = to[components + c];
                const m1 = to[c] * span;
                value[c] = (2 * t3 - 3 * t2 + 1) * p0 + (t3 - 2 * t2 + t) * m0 + (-2 * t3 + 3 * t2) * p1 + (t3 - t2) * m1;
            }
            if (channel.path == .rotation) value = math.quatNormalize(value);
        } else {
            const a = channel.values[low * components ..][0..components];
            const b = channel.values[next * components ..][0..components];
            if (channel.path == .rotation) {
                value = math.slerp(a[0..4].*, b[0..4].*, t);
            } else {
                value[0..3].* = math.lerp(a[0..3].*, b[0..3].*, t);
            }
        }
        const local = &locals[channel.node];
        switch (channel.path) {
            .translation => local.translation = value[0..3].*,
            .scale => local.scale = value[0..3].*,
            .rotation => local.rotation = value,
            .weights => unreachable,
        }
    }
}

fn isBelow(nodes: []const gltf.Node, node: usize, root: u32) bool {
    var current: ?u32 = @intCast(node);
    var guard: usize = 0;
    while (current) |index| : (guard += 1) {
        if (index == root) return true;
        if (index >= nodes.len or guard > nodes.len) return false;
        current = nodes[index].parent;
    }
    return false;
}

/// q * inverse(r) for unit quaternions (x, y, z, w).
fn quatDifference(q: [4]f32, r: [4]f32) [4]f32 {
    return math.quatMul(q, .{ -r[0], -r[1], -r[2], r[3] });
}

/// Applies one layer to `locals`. `other` and `reference` are scratch.
fn applyLayer(model: *const gltf.Model, locals: []Local, other: []Local, reference: []Local, layer: Pose.Blend, loop: bool) void {
    const weight = std.math.clamp(layer.weight, 0, 1);
    if (weight <= 0) return;
    sampleClip(model, other, layer.animation, layer.time, layer.loop orelse loop);
    if (layer.additive) sampleClip(model, reference, layer.animation, 0, false);
    for (locals, other, reference, 0..) |*a, b, base, index| {
        if (layer.root) |root| if (!isBelow(model.nodes, index, root)) continue;
        if (layer.additive) {
            // The clip's change since its first frame, scaled by weight.
            a.translation = math.add(a.translation, math.scale(math.sub(b.translation, base.translation), weight));
            inline for (0..3) |c| a.scale[c] *= 1 + (b.scale[c] / (if (base.scale[c] != 0) base.scale[c] else 1) - 1) * weight;
            const delta = math.slerp(.{ 0, 0, 0, 1 }, quatDifference(b.rotation, base.rotation), weight);
            a.rotation = math.quatNormalize(math.quatMul(delta, a.rotation));
        } else {
            a.translation = math.lerp(a.translation, b.translation, weight);
            a.scale = math.lerp(a.scale, b.scale, weight);
            a.rotation = math.slerp(a.rotation, b.rotation, weight);
        }
    }
}

/// Fills `world` with a model-space matrix per node. `scratch` must hold
/// `3 * nodes.len` entries. A null pose yields the file's rest pose.
pub fn evaluate(
    model: *const gltf.Model,
    order: []const u32,
    pose: ?Pose,
    scratch: []Local,
    world: [][16]f32,
) void {
    const count = model.nodes.len;
    const locals = scratch[0..count];
    sampleClip(model, locals, if (pose) |p| p.animation else std.math.maxInt(u32), if (pose) |p| p.time else 0, if (pose) |p| p.loop else true);
    if (pose) |p| {
        const other = scratch[count .. count * 2];
        const reference = scratch[count * 2 .. count * 3];
        if (p.blend) |blend| applyLayer(model, locals, other, reference, blend, p.loop);
        for (p.layers) |layer| if (layer) |value| applyLayer(model, locals, other, reference, value, p.loop);
    }
    if (pose) |p| if (p.in_place) |node| if (node < count) {
        locals[node].translation[0] = model.nodes[node].translation[0];
        locals[node].translation[2] = model.nodes[node].translation[2];
    };
    for (order) |index| {
        const node = model.nodes[index];
        const local = if (node.matrix) |matrix|
            matrix
        else
            math.compose(locals[index].translation, locals[index].rotation, locals[index].scale);
        world[index] = if (node.parent) |parent| math.mul(world[parent], local) else local;
    }
}

/// Morph target weights a clip gives one node at a time; `weights` is left
/// as it is when the clip does not animate them. Returns whether it did.
pub fn sampleWeights(model: *const gltf.Model, clip_index: u32, node: u32, time_in: f32, loop: bool, weights: []f32) bool {
    if (clip_index >= model.animations.len) return false;
    const clip = model.animations[clip_index];
    const time = if (clip.duration <= 0) 0 else if (loop) @mod(time_in, clip.duration) else std.math.clamp(time_in, 0, clip.duration);
    for (clip.channels) |channel| {
        if (channel.path != .weights or channel.node != node or channel.width == 0) continue;
        var low: usize = 0;
        var high: usize = channel.times.len;
        while (low + 1 < high) {
            const mid = (low + high) / 2;
            if (channel.times[mid] <= time) low = mid else high = mid;
        }
        const next = @min(low + 1, channel.times.len - 1);
        const span = channel.times[next] - channel.times[low];
        const t: f32 = if (channel.step or span <= 0) 0 else std.math.clamp((time - channel.times[low]) / span, 0, 1);
        // Cubic keys hold in-tangent, value, out-tangent; the value is
        // used and the keys joined by straight lines.
        const stride: usize = channel.width * @as(usize, if (channel.cubic) 3 else 1);
        const skip: usize = if (channel.cubic) channel.width else 0;
        for (weights[0..@min(weights.len, channel.width)], 0..) |*weight, target| {
            const a = channel.values[low * stride + skip + target];
            const b = channel.values[next * stride + skip + target];
            weight.* = a + (b - a) * t;
        }
        return true;
    }
    return false;
}

/// Morph target weights a whole pose gives one node: the base clip's, then
/// the cross-fade and every layer on top, each by its own weight, mask and
/// mode, as `evaluate` does for the skeleton. `weights` comes in holding
/// the mesh's own weights, which a clip that does not animate them leaves.
pub fn poseWeights(model: *const gltf.Model, pose: Pose, node: u32, weights: []f32) void {
    _ = sampleWeights(model, pose.animation, node, pose.time, pose.loop, weights);
    if (pose.blend) |blend| applyWeightLayer(model, node, weights, blend, pose.loop);
    for (pose.layers) |layer| if (layer) |value| applyWeightLayer(model, node, weights, value, pose.loop);
}

fn applyWeightLayer(model: *const gltf.Model, node: u32, weights: []f32, layer: Pose.Blend, loop: bool) void {
    const amount = std.math.clamp(layer.weight, 0, 1);
    if (amount <= 0) return;
    if (layer.root) |root| if (!isBelow(model.nodes, node, root)) return;
    var other_storage: [gltf.max_morph_targets]f32 = undefined;
    const count = @min(weights.len, other_storage.len);
    const other = other_storage[0..count];
    @memcpy(other, weights[0..count]);
    // A layer whose clip leaves the weights alone has nothing to say.
    if (!sampleWeights(model, layer.animation, node, layer.time, layer.loop orelse loop, other)) return;
    if (layer.additive) {
        // The clip's change since its first frame, scaled by weight.
        var base_storage: [gltf.max_morph_targets]f32 = undefined;
        const base = base_storage[0..count];
        @memcpy(base, other);
        _ = sampleWeights(model, layer.animation, node, 0, false, base);
        for (weights[0..count], other, base) |*weight, value, start| weight.* += (value - start) * amount;
    } else {
        for (weights[0..count], other) |*weight, value| weight.* += (value - weight.*) * amount;
    }
}

/// How far a clip moves one node between two times, in the node's parent
/// space. Across the end of a looping clip it adds the stretch to the end
/// and the stretch from the start. `scratch` holds one `Local` per node.
pub fn rootMotion(model: *const gltf.Model, scratch: []Local, clip_index: u32, node: u32, from: f32, to: f32, loop: bool) [3]f32 {
    if (clip_index >= model.animations.len or node >= model.nodes.len) return .{ 0, 0, 0 };
    const duration = model.animations[clip_index].duration;
    const Sampler = struct {
        fn at(m: *const gltf.Model, locals: []Local, clip: u32, index: u32, time: f32) [3]f32 {
            // Clamped, so the clip's last key can be told from its first.
            sampleClip(m, locals, clip, time, false);
            return locals[index].translation;
        }
    };
    const locals = scratch[0..model.nodes.len];
    if (!loop or duration <= 0) return math.sub(Sampler.at(model, locals, clip_index, node, to), Sampler.at(model, locals, clip_index, node, from));
    const start = @mod(from, duration);
    const end = @mod(to, duration);
    // Whole turns of the clip in between each add its full travel.
    const turns = @floor(to / duration) - @floor(from / duration);
    const whole = math.sub(Sampler.at(model, locals, clip_index, node, duration), Sampler.at(model, locals, clip_index, node, 0));
    const partial = math.sub(Sampler.at(model, locals, clip_index, node, end), Sampler.at(model, locals, clip_index, node, start));
    return math.add(partial, math.scale(whole, turns));
}

test "root motion adds up across the end of a looping clip" {
    var nodes = [_]gltf.Node{.{}};
    var times = [_]f32{ 0, 1 };
    // Walks 2 units along x every second.
    var values = [_]f32{ 0, 0, 0, 2, 0, 0 };
    var channels = [_]gltf.Channel{.{ .node = 0, .path = .translation, .step = false, .times = &times, .values = &values }};
    var animations = [_]gltf.Animation{.{ .name = "walk", .duration = 1, .channels = &channels }};
    const model = gltf.Model{ .arena = undefined, .nodes = &nodes, .animations = &animations };
    var scratch: [3]Local = undefined;
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), rootMotion(&model, &scratch, 0, 0, 0.25, 0.5, true)[0], 1e-5);
    // From 0.75 to 1.25 crosses the loop point: still half a second of travel.
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), rootMotion(&model, &scratch, 0, 0, 0.75, 1.25, true)[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), rootMotion(&model, &scratch, 0, 0, 0, 2.5, true)[0], 1e-5);
    // Held in place, the node stays at its rest position while posed.
    var world: [1][16]f32 = undefined;
    evaluate(&model, &.{0}, .{ .animation = 0, .time = 0.5, .in_place = 0 }, &scratch, &world);
    try std.testing.expectApproxEqAbs(@as(f32, 0), world[0][12], 1e-6);
}

test "topological order places parents before children" {
    const nodes = [_]gltf.Node{
        .{ .parent = 2 },
        .{ .parent = 0 },
        .{ .parent = null },
        .{ .parent = 1 },
    };
    const order = try topologicalOrder(std.testing.allocator, &nodes);
    defer std.testing.allocator.free(order);
    var position: [nodes.len]usize = undefined;
    for (order, 0..) |node, index| position[node] = index;
    for (nodes, 0..) |node, index| {
        if (node.parent) |parent| try std.testing.expect(position[parent] < position[index]);
    }
}

test "pose sampling interpolates keys and composes the hierarchy" {
    var times = [_]f32{ 0, 1 };
    var values = [_]f32{ 0, 0, 0, 2, 0, 0 };
    var channels = [_]gltf.Channel{.{ .node = 0, .path = .translation, .step = false, .times = &times, .values = &values }};
    var animations = [_]gltf.Animation{.{ .name = "slide", .duration = 1, .channels = &channels }};
    var nodes = [_]gltf.Node{ .{}, .{ .parent = 0, .translation = .{ 0, 1, 0 } } };
    const model = gltf.Model{ .arena = .init(std.testing.allocator), .nodes = &nodes, .animations = &animations };
    const order = [_]u32{ 0, 1 };
    var scratch: [6]Local = undefined;
    var world: [2][16]f32 = undefined;

    evaluate(&model, &order, .{ .animation = 0, .time = 0.5 }, &scratch, &world);
    try std.testing.expectApproxEqAbs(@as(f32, 1), world[0][12], 1e-6);
    // The child inherits the animated parent translation plus its own offset.
    try std.testing.expectApproxEqAbs(@as(f32, 1), world[1][12], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1), world[1][13], 1e-6);

    evaluate(&model, &order, null, &scratch, &world);
    try std.testing.expectApproxEqAbs(@as(f32, 0), world[0][12], 1e-6);
}

test "cubic spline keys pass through their values and follow their tangents" {
    // One node whose x translation goes 0 -> 1 over a second, leaving the
    // first key at speed 2 and arriving at the second at speed 0.
    var nodes = [_]gltf.Node{.{}};
    var times = [_]f32{ 0, 1 };
    var values = [_]f32{ 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0 };
    var channels = [_]gltf.Channel{.{ .node = 0, .path = .translation, .step = false, .cubic = true, .times = &times, .values = &values }};
    var animations = [_]gltf.Animation{.{ .name = "move", .duration = 1, .channels = &channels }};
    const model = gltf.Model{ .arena = undefined, .nodes = &nodes, .animations = &animations };
    var scratch: [3]Local = undefined;
    var world: [1][16]f32 = undefined;
    const order = [_]u32{0};
    evaluate(&model, &order, .{ .animation = 0, .time = 0, .loop = false }, &scratch, &world);
    try std.testing.expectApproxEqAbs(@as(f32, 0), world[0][12], 1e-5);
    evaluate(&model, &order, .{ .animation = 0, .time = 1, .loop = false }, &scratch, &world);
    try std.testing.expectApproxEqAbs(@as(f32, 1), world[0][12], 1e-5);
    // Hermite at t = 0.5: 0.5 * p1 + 0.125 * m0 = 0.5 + 0.25.
    evaluate(&model, &order, .{ .animation = 0, .time = 0.5, .loop = false }, &scratch, &world);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), world[0][12], 1e-5);
}

test "layers can be masked to a subtree and added on top" {
    // root -> spine -> arm, and a leg under the root.
    var nodes = [_]gltf.Node{ .{}, .{ .parent = 0 }, .{ .parent = 1 }, .{ .parent = 0 } };
    var times = [_]f32{ 0, 1 };
    // "raise": moves every node up by 1 over a second.
    var raise_values = [_]f32{ 0, 0, 0, 0, 1, 0 };
    var raise_channels: [4]gltf.Channel = undefined;
    for (&raise_channels, 0..) |*channel, node| channel.* = .{ .node = @intCast(node), .path = .translation, .step = false, .times = &times, .values = &raise_values };
    var animations = [_]gltf.Animation{
        .{ .name = "rest", .duration = 1, .channels = &.{} },
        .{ .name = "raise", .duration = 1, .channels = &raise_channels },
    };
    const model = gltf.Model{ .arena = undefined, .nodes = &nodes, .animations = &animations };
    var scratch: [12]Local = undefined;
    var world: [4][16]f32 = undefined;
    const order = [_]u32{ 0, 1, 2, 3 };

    // Masked to the spine: the spine and arm move, the root and leg do not.
    var pose = Pose{ .animation = 0, .time = 0, .loop = false };
    pose.layers[0] = .{ .animation = 1, .time = 1, .weight = 1, .root = 1 };
    evaluate(&model, &order, pose, &scratch, &world);
    try std.testing.expectApproxEqAbs(@as(f32, 0), world[0][13], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1), world[1][13], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 2), world[2][13], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0), world[3][13], 1e-5);

    // Additive at half weight on top of the clip itself at its end:
    // 1 from the base plus half of (1 - 0) for the root.
    pose = .{ .animation = 1, .time = 1, .loop = false };
    pose.layers[0] = .{ .animation = 1, .time = 1, .weight = 0.5, .additive = true };
    evaluate(&model, &order, pose, &scratch, &world);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), world[0][13], 1e-5);
}

test "morph weights follow the base clip, the cross-fade and the layers" {
    // A head under a root, with two targets. "talk" opens the first from
    // 0 to 1 over a second; "blink" closes the second from 0.2 to 1.
    var nodes = [_]gltf.Node{ .{}, .{ .parent = 0 } };
    var times = [_]f32{ 0, 1 };
    var talk_values = [_]f32{ 0, 0, 1, 0 };
    var blink_values = [_]f32{ 0, 0.2, 0, 1 };
    var talk_channels = [_]gltf.Channel{.{ .node = 1, .path = .weights, .step = false, .width = 2, .times = &times, .values = &talk_values }};
    var blink_channels = [_]gltf.Channel{.{ .node = 1, .path = .weights, .step = false, .width = 2, .times = &times, .values = &blink_values }};
    var animations = [_]gltf.Animation{
        .{ .name = "talk", .duration = 1, .channels = &talk_channels },
        .{ .name = "blink", .duration = 1, .channels = &blink_channels },
        .{ .name = "still", .duration = 1, .channels = &.{} },
    };
    const model = gltf.Model{ .arena = undefined, .nodes = &nodes, .animations = &animations };

    // The base clip alone.
    var weights = [_]f32{ 0.3, 0.3 };
    poseWeights(&model, .{ .animation = 0, .time = 0.5, .loop = false }, 1, &weights);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), weights[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0), weights[1], 1e-6);

    // A layer at half weight moves halfway toward its clip.
    var pose = Pose{ .animation = 0, .time = 0.5, .loop = false };
    pose.layers[0] = .{ .animation = 1, .time = 1, .weight = 0.5 };
    weights = .{ 0.3, 0.3 };
    poseWeights(&model, pose, 1, &weights);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), weights[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), weights[1], 1e-6);

    // Additive: only the clip's change since its first frame is added.
    pose.layers[0] = .{ .animation = 1, .time = 1, .weight = 1, .additive = true };
    weights = .{ 0.3, 0.3 };
    poseWeights(&model, pose, 1, &weights);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), weights[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), weights[1], 1e-6);

    // Masked to a subtree the node is not in, and a clip without weight
    // keys: both leave the result alone.
    pose.layers[0] = .{ .animation = 1, .time = 1, .weight = 1, .root = 0 };
    pose.layers[1] = .{ .animation = 2, .time = 0.5, .weight = 1 };
    weights = .{ 0.3, 0.3 };
    poseWeights(&model, pose, 0, &weights);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), weights[0], 1e-6);
    poseWeights(&model, .{ .animation = 2, .time = 0.5, .layers = .{ .{ .animation = 1, .time = 1, .weight = 1, .root = 1 }, null, null, null } }, 0, &weights);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), weights[1], 1e-6);
}
