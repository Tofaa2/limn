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

/// The camera's projection for a picture of `aspect`, without jitter.
pub fn cameraProjection(camera: Camera, aspect: f32) Mat4 {
    const shift = [2]f32{ camera.lens_shift[0] / aspect, camera.lens_shift[1] };
    if (camera.orthographic) |parallel| {
        const half_height = @max(parallel.height, 1e-6) * 0.5;
        const half_width = half_height * aspect;
        var result = math.orthographic(-half_width, half_width, -half_height, half_height, farPlane(camera), camera.near);
        result[12] += shift[0];
        result[13] += shift[1];
        return result;
    }
    var result = math.perspective(camera.fov_y, aspect, camera.near);
    result[8] = -shift[0];
    result[9] = -shift[1];
    return result;
}

/// `matrix` drawing `offset` further off its axis, in half picture sizes.
pub fn shifted(matrix: Mat4, camera: Camera, offset: [2]f32) Mat4 {
    var result = matrix;
    if (camera.orthographic != null) {
        result[12] += offset[0];
        result[13] += offset[1];
    } else {
        result[8] -= offset[0];
        result[9] -= offset[1];
    }
    return result;
}

/// How far off its axis `matrix` draws, in half picture sizes.
pub fn lensShift(matrix: Mat4, camera: Camera) [2]f32 {
    return if (camera.orthographic != null) .{ matrix[12], matrix[13] } else .{ -matrix[8], -matrix[9] };
}

fn farPlane(camera: Camera) f32 {
    return @max(camera.orthographic.?.far, camera.near * 2);
}

/// `FrameConstants.depth_terms` of the camera.
pub fn depthTerms(camera: Camera) [4]f32 {
    if (camera.orthographic == null) return .{ 0, camera.near, 1, 0 };
    const far = farPlane(camera);
    return .{ camera.near - far, far, 0, 1 };
}

/// Distance along the view of what a pixel of `depth` shows.
pub fn viewDepth(terms: [4]f32, depth: f32) f32 {
    return (terms[1] + terms[0] * depth) / @max(terms[2] * depth + terms[3], 1e-9);
}

/// Distance at which a perspective camera stands in for a parallel one
/// where only the direction and the ratio of size to distance matter.
pub const parallel_distance = 1e7;

pub const Vantage = struct { position: Vec3, scale: f32 };

/// Where levels of detail and facing are judged from, and the factor that
/// makes sizes over the distance from there come out in the picture's scale.
pub fn vantage(camera: Camera) Vantage {
    if (camera.orthographic == null) return .{ .position = camera.position, .scale = 1 };
    const back = math.scale(math.normalize(camera.forward), -parallel_distance);
    return .{ .position = math.add(camera.position, back), .scale = parallel_distance };
}

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
    orthographic: ?api.Orthographic = null,
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
            const half_height = if (camera.orthographic) |parallel| parallel.height * 0.5 else distance * tan_half;
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

test "orthographic depth runs from 1 at the near plane to 0 at the far one" {
    const camera = Camera{ .position = .{ 0, 0, 0 }, .forward = .{ 0, 0, -1 }, .near = 2, .orthographic = .{ .height = 10, .far = 50 } };
    const matrix = cameraProjection(camera, 2);
    const terms = depthTerms(camera);
    for ([_]f32{ 2, 14, 50 }) |distance| {
        const clip = math.transformVec4(matrix, .{ 10, 5, -distance, 1 });
        try std.testing.expectApproxEqAbs(@as(f32, 1), clip[0], 1e-5);
        try std.testing.expectApproxEqAbs(@as(f32, -1), clip[1], 1e-5);
        try std.testing.expectApproxEqAbs(distance, viewDepth(terms, clip[2] / clip[3]), 1e-3);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 7), viewDepth(depthTerms(.{ .near = 0.5 }), 0.5 / 7.0), 1e-4);
}
