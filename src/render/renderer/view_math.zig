//! Culling planes, shadow cascades and sample sequences of a view. Internal to the renderer.
const std = @import("std");
const math = @import("../../math.zig");
const gpu = @import("../gpu.zig");
const api = @import("../api.zig");
const renderer_state = @import("../state.zig");

const Mat4 = math.Mat4;
const Vec3 = math.Vec3;
const Scene = api.Scene;
const Camera = api.Camera;
const GiVolume = renderer_state.GiVolume;

pub fn halton(index: u32, base: u32) f32 {
    var result: f32 = 0;
    var fraction: f32 = 1;
    var i = index;
    while (i > 0) : (i /= base) {
        fraction /= @floatFromInt(base);
        result += fraction * @as(f32, @floatFromInt(i % base));
    }
    return result;
}

const CullKind = enum { perspective, shadow };

/// Extracts world-space culling planes (normals pointing inward).
pub fn cullView(view_proj: Mat4, camera_position: Vec3, kind: CullKind) gpu.CullView {
    const row = struct {
        fn get(m: Mat4, index: usize) [4]f32 {
            return .{ m[index], m[4 + index], m[8 + index], m[12 + index] };
        }
    }.get;
    const r0 = row(view_proj, 0);
    const r1 = row(view_proj, 1);
    const r2 = row(view_proj, 2);
    const r3 = row(view_proj, 3);
    var result = gpu.CullView{
        .planes = undefined,
        .camera_position = camera_position,
        .plane_count = 5,
        .cone_culling = @intFromBool(kind == .perspective),
    };
    result.planes[0] = normalizePlane(addPlanes(r3, r0, 1));
    result.planes[1] = normalizePlane(addPlanes(r3, r0, -1));
    result.planes[2] = normalizePlane(addPlanes(r3, r1, 1));
    result.planes[3] = normalizePlane(addPlanes(r3, r1, -1));
    result.planes[4] = normalizePlane(addPlanes(r3, r2, -1));
    result.planes[5] = .{ 0, 0, 0, 1 };
    return result;
}

fn addPlanes(a: [4]f32, b: [4]f32, sign: f32) [4]f32 {
    return .{ a[0] + sign * b[0], a[1] + sign * b[1], a[2] + sign * b[2], a[3] + sign * b[3] };
}

fn normalizePlane(plane: [4]f32) [4]f32 {
    const length = @sqrt(plane[0] * plane[0] + plane[1] * plane[1] + plane[2] * plane[2]);
    if (length < 1e-20) return .{ 0, 0, 0, 1 };
    return .{ plane[0] / length, plane[1] / length, plane[2] / length, plane[3] / length };
}

/// The sun cascades as last rendered, which is what shading must sample.
pub const CascadeCache = struct {
    valid: bool = false,
    /// Scene the cached maps were rendered from.
    scene: Scene = .invalid,
    count: u32 = 0,
    sun: Vec3 = .{ 0, 0, 0 },
    shadow_distance: f32 = 0,
    near: f32 = 0,
    cascades: Cascades = std.mem.zeroes(Cascades),
};

/// Extra radius given to cascades that are reused across frames, so camera
/// motion between refreshes stays inside the rendered area.
const cascade_margin = [gpu.cascade_count]f32{ 1.0, 1.05, 1.08, 1.12 };

/// The sun's shadow cascades: matrices, split distances and coverage.
pub const Cascades = struct {
    /// World-space bounding sphere each map covers (`radii` includes the
    /// reuse margin, `tight_radii` does not).
    centers: [gpu.cascade_count]Vec3,
    radii: [gpu.cascade_count]f32,
    tight_radii: [gpu.cascade_count]f32,
    view_proj: [gpu.cascade_count]Mat4,
    splits: [4]f32,
    texel_size: [4]f32,
};

/// Fits each cascade to a bounding sphere of its frustum slice, snapped to
/// shadow-map texels.
pub fn computeCascades(camera: Camera, view_matrix: Mat4, aspect: f32, sun_travel: Vec3, shadow_distance: f32, shadow_resolution: u32, count: u32) Cascades {
    const active: usize = std.math.clamp(count, 1, gpu.cascade_count);
    var result: Cascades = undefined;
    const inv_view = math.inverse(view_matrix);
    const near = camera.near;
    const far = @max(shadow_distance, near * 2);
    const tan_half = @tan(camera.fov_y * 0.5);
    const light_view = math.lookTo(.{ 0, 0, 0 }, sun_travel, .{ 0, 1, 0 });
    const blend = 0.85;
    var slice_near = near;
    for (0..gpu.cascade_count) |cascade| {
        if (cascade >= active) {
            inline for (.{ "view_proj", "splits", "texel_size", "centers", "radii", "tight_radii" }) |field| {
                @field(result, field)[cascade] = @field(result, field)[cascade - 1];
            }
            continue;
        }
        const fraction = @as(f32, @floatFromInt(cascade + 1)) / @as(f32, @floatFromInt(active));
        const logarithmic = near * std.math.pow(f32, far / near, fraction);
        const uniform = near + (far - near) * fraction;
        const slice_far = blend * logarithmic + (1 - blend) * uniform;

        var corners: [8]Vec3 = undefined;
        var center: Vec3 = .{ 0, 0, 0 };
        for ([_]f32{ slice_near, slice_far }, 0..) |distance, plane| {
            const half_height = distance * tan_half;
            const half_width = half_height * aspect;
            for ([_][2]f32{ .{ -1, -1 }, .{ 1, -1 }, .{ -1, 1 }, .{ 1, 1 } }, 0..) |corner, index| {
                const world = math.transformPoint(inv_view, .{ corner[0] * half_width, corner[1] * half_height, -distance });
                corners[plane * 4 + index] = world;
                center = math.add(center, math.scale(world, 1.0 / 8.0));
            }
        }
        var radius: f32 = 0;
        for (corners) |corner| radius = @max(radius, math.length(math.sub(corner, center)));
        result.centers[cascade] = center;
        result.tight_radii[cascade] = radius;
        radius = @ceil(radius * cascade_margin[cascade] * 16) / 16;
        result.radii[cascade] = radius;

        const texel = 2 * radius / @as(f32, @floatFromInt(shadow_resolution));
        var light_center = math.transformPoint(light_view, center);
        light_center[0] = @floor(light_center[0] / texel) * texel;
        light_center[1] = @floor(light_center[1] / texel) * texel;
        const caster_distance = 500;
        const depth_center = -light_center[2];
        const projection = math.orthographic(
            light_center[0] - radius,
            light_center[0] + radius,
            light_center[1] - radius,
            light_center[1] + radius,
            depth_center - radius - caster_distance,
            depth_center + radius,
        );
        result.view_proj[cascade] = math.mul(projection, light_view);
        result.splits[cascade] = slice_far;
        result.texel_size[cascade] = texel;
        slice_near = slice_far;
    }
    return result;
}

test "culling planes keep points inside the frustum" {
    const view = math.lookAt(.{ 0, 0, 5 }, .{ 0, 0, 0 }, .{ 0, 1, 0 });
    const cull = cullView(math.mul(math.perspective(1.0, 1.0, 0.1), view), .{ 0, 0, 5 }, .perspective);
    const inside = [3]f32{ 0, 0, 0 };
    const behind = [3]f32{ 0, 0, 10 };
    for (cull.planes[0..cull.plane_count]) |plane|
        try std.testing.expect(plane[0] * inside[0] + plane[1] * inside[1] + plane[2] * inside[2] + plane[3] > 0);
    var rejected = false;
    for (cull.planes[0..cull.plane_count]) |plane| {
        if (plane[0] * behind[0] + plane[1] * behind[1] + plane[2] * behind[2] + plane[3] < 0) rejected = true;
    }
    try std.testing.expect(rejected);
}

test "halton sequence stays in the unit interval" {
    for (1..17) |index| {
        const value = halton(@intCast(index), 2);
        try std.testing.expect(value > 0 and value < 1);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), halton(1, 2), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 / 3.0), halton(1, 3), 1e-6);
}

/// Storage offset of the volume's first cell: probes are stored by world
/// cell modulo the grid size.
pub fn giScroll(volume: *const GiVolume) u32 {
    var packed_scroll: u32 = 0;
    inline for (0..3) |axis| {
        const wrapped: u32 = @intCast(@mod(volume.cell[axis], @as(i32, @intCast(volume.counts[axis]))));
        packed_scroll |= wrapped << (10 * axis);
    }
    return packed_scroll;
}
