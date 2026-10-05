//! Small linear-algebra kit shared by the renderer and applications.
//!
//! Conventions: right-handed world, +Y up, cameras look down -Z in view space.
//! Matrices are column-major (`m[column * 4 + row]`) and multiply column
//! vectors, so `mul(a, b)` applies `b` first. Quaternions are `{x, y, z, w}`.
const std = @import("std");

/// 2D vector or point, `{x, y}`.
pub const Vec2 = [2]f32;
/// 3D vector or point, `{x, y, z}`. The vector functions below (`add`,
/// `dot`, `cross`, ...) all take this type.
pub const Vec3 = [3]f32;
/// Homogeneous vector `{x, y, z, w}`: w is 1 for points, 0 for directions.
pub const Vec4 = [4]f32;
/// Rotation quaternion `{x, y, z, w}` with the scalar part last. Functions
/// that take one expect unit length unless they say otherwise.
pub const Quat = [4]f32;
/// 4x4 matrix stored column by column: element (row, column) is
/// `m[column * 4 + row]`, and the translation of an affine transform is
/// `m[12..15]`. The layout matches GLSL's `mat4`.
pub const Mat4 = [16]f32;

/// The matrix that leaves every vector unchanged.
pub const identity: Mat4 = .{
    1, 0, 0, 0,
    0, 1, 0, 0,
    0, 0, 1, 0,
    0, 0, 0, 1,
};
/// The quaternion of no rotation.
pub const quat_identity: Quat = .{ 0, 0, 0, 1 };

/// Component-wise sum `a + b`.
pub fn add(a: Vec3, b: Vec3) Vec3 {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2] };
}

/// Component-wise difference `a - b`: the vector from `b` to `a`.
pub fn sub(a: Vec3, b: Vec3) Vec3 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}

/// Multiplies every component of `a` by `s`.
pub fn scale(a: Vec3, s: f32) Vec3 {
    return .{ a[0] * s, a[1] * s, a[2] * s };
}

/// Dot product: `|a| * |b| * cos` of the angle between them.
pub fn dot(a: Vec3, b: Vec3) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

/// Right-handed cross product: perpendicular to both, so that
/// `cross(+X, +Y)` is `+Z`. Not normalized.
pub fn cross(a: Vec3, b: Vec3) Vec3 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}

/// Euclidean length of `a`.
pub fn length(a: Vec3) f32 {
    return @sqrt(dot(a, a));
}

/// `a` scaled to unit length. A vector too short to have a direction
/// (length at most 1e-20) gives zero rather than NaN.
pub fn normalize(a: Vec3) Vec3 {
    const len = length(a);
    return if (len > 1e-20) scale(a, 1.0 / len) else .{ 0, 0, 0 };
}

/// Linear blend from `a` (t = 0) to `b` (t = 1). `t` is not clamped, so
/// values outside 0..1 extrapolate.
pub fn lerp(a: Vec3, b: Vec3, t: f32) Vec3 {
    return .{ a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t };
}

/// Matrix product `a * b`. With column vectors the result applies `b`
/// first and then `a`, so a model matrix is built as
/// `mul(translation, mul(rotation, scale))`.
pub fn mul(a: Mat4, b: Mat4) Mat4 {
    var result: Mat4 = undefined;
    inline for (0..4) |column| {
        inline for (0..4) |row| {
            result[column * 4 + row] =
                a[0 * 4 + row] * b[column * 4 + 0] +
                a[1 * 4 + row] * b[column * 4 + 1] +
                a[2 * 4 + row] * b[column * 4 + 2] +
                a[3 * 4 + row] * b[column * 4 + 3];
        }
    }
    return result;
}

/// Matrix that moves points by `v`. Directions (w = 0) are unaffected.
pub fn translation(v: Vec3) Mat4 {
    var result = identity;
    result[12] = v[0];
    result[13] = v[1];
    result[14] = v[2];
    return result;
}

/// Matrix that scales about the origin by `v[0]`, `v[1]` and `v[2]` along
/// X, Y and Z.
pub fn scaling(v: Vec3) Mat4 {
    var result = identity;
    result[0] = v[0];
    result[5] = v[1];
    result[10] = v[2];
    return result;
}

/// Matrix that scales about the origin by `s` along every axis.
pub fn uniformScaling(s: f32) Mat4 {
    return scaling(.{ s, s, s });
}

/// Rotation about +X by `angle` radians, counter-clockwise when looking
/// down the axis toward the origin (right-hand rule: +Y turns toward +Z).
pub fn rotationX(angle: f32) Mat4 {
    const s = @sin(angle);
    const c = @cos(angle);
    return .{ 1, 0, 0, 0, 0, c, s, 0, 0, -s, c, 0, 0, 0, 0, 1 };
}

/// Counter-clockwise rotation about +Y when viewed from above.
pub fn rotationY(angle: f32) Mat4 {
    const s = @sin(angle);
    const c = @cos(angle);
    return .{ c, 0, -s, 0, 0, 1, 0, 0, s, 0, c, 0, 0, 0, 0, 1 };
}

/// Rotation about +Z by `angle` radians, counter-clockwise when looking
/// down the axis toward the origin (right-hand rule: +X turns toward +Y).
pub fn rotationZ(angle: f32) Mat4 {
    const s = @sin(angle);
    const c = @cos(angle);
    return .{ c, s, 0, 0, -s, c, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
}

/// Rotation matrix of the quaternion `q`, which must be unit length (see
/// `quatNormalize`); anything else adds scale and shear.
pub fn fromQuat(q: Quat) Mat4 {
    const x = q[0];
    const y = q[1];
    const z = q[2];
    const w = q[3];
    return .{
        1 - 2 * (y * y + z * z), 2 * (x * y + z * w),     2 * (x * z - y * w),     0,
        2 * (x * y - z * w),     1 - 2 * (x * x + z * z), 2 * (y * z + x * w),     0,
        2 * (x * z + y * w),     2 * (y * z - x * w),     1 - 2 * (x * x + y * y), 0,
        0,                       0,                       0,                       1,
    };
}

/// Translation * rotation * scale.
pub fn compose(t: Vec3, r: Quat, s: Vec3) Mat4 {
    var result = fromQuat(r);
    inline for (0..3) |row| {
        result[0 + row] *= s[0];
        result[4 + row] *= s[1];
        result[8 + row] *= s[2];
    }
    result[12] = t[0];
    result[13] = t[1];
    result[14] = t[2];
    return result;
}

/// Applies an affine `m` to the point `p` (w = 1): rotation, scale and
/// translation. The bottom row is ignored and there is no perspective
/// divide, so use `transformVec4` for projection matrices.
pub fn transformPoint(m: Mat4, p: Vec3) Vec3 {
    return .{
        m[0] * p[0] + m[4] * p[1] + m[8] * p[2] + m[12],
        m[1] * p[0] + m[5] * p[1] + m[9] * p[2] + m[13],
        m[2] * p[0] + m[6] * p[1] + m[10] * p[2] + m[14],
    };
}

/// Applies the upper 3x3 of `m` to the direction `d` (w = 0), leaving the
/// translation out. The result is not renormalized, and under non-uniform
/// scale this is not the right transform for surface normals.
pub fn transformDirection(m: Mat4, d: Vec3) Vec3 {
    return .{
        m[0] * d[0] + m[4] * d[1] + m[8] * d[2],
        m[1] * d[0] + m[5] * d[1] + m[9] * d[2],
        m[2] * d[0] + m[6] * d[1] + m[10] * d[2],
    };
}

/// Full product `m * v` of a matrix and a homogeneous column vector. For
/// a projection the result is in clip space; divide by its w yourself.
pub fn transformVec4(m: Mat4, v: Vec4) Vec4 {
    var result: Vec4 = undefined;
    inline for (0..4) |row| {
        result[row] = m[row] * v[0] + m[4 + row] * v[1] + m[8 + row] * v[2] + m[12 + row] * v[3];
    }
    return result;
}

/// Largest axis scale of the upper 3x3, used to scale bounding spheres.
pub fn maxScale(m: Mat4) f32 {
    const x = length(.{ m[0], m[1], m[2] });
    const y = length(.{ m[4], m[5], m[6] });
    const z = length(.{ m[8], m[9], m[10] });
    return @max(x, @max(y, z));
}

/// View matrix for a camera at `eye` looking at `target`.
pub fn lookAt(eye: Vec3, target: Vec3, up: Vec3) Mat4 {
    return lookTo(eye, sub(target, eye), up);
}

/// View matrix (world to view space) for a camera at `eye` looking along
/// `direction`: right-handed, with the view direction on -Z, right on +X
/// and up on +Y. `direction` and `up` need not be unit length nor
/// perpendicular; `up` only picks the roll. When the two are parallel
/// world +Z stands in for `up`.
pub fn lookTo(eye: Vec3, direction: Vec3, up: Vec3) Mat4 {
    const f = normalize(direction);
    var r = cross(f, up);
    if (dot(r, r) < 1e-10) r = cross(f, .{ 0, 0, 1 });
    r = normalize(r);
    const u = cross(r, f);
    return .{
        r[0],         u[0],         -f[0],       0,
        r[1],         u[1],         -f[1],       0,
        r[2],         u[2],         -f[2],       0,
        -dot(r, eye), -dot(u, eye), dot(f, eye), 1,
    };
}

/// Reverse-Z perspective with an infinite far plane. Depth is 1 at `near`
/// and approaches 0 at infinity; Y is flipped for Vulkan clip space.
pub fn perspective(fov_y: f32, aspect: f32, near: f32) Mat4 {
    const f = 1.0 / @tan(fov_y * 0.5);
    return .{
        f / aspect, 0,  0,    0,
        0,          -f, 0,    0,
        0,          0,  0,    -1,
        0,          0,  near, 0,
    };
}

/// Orthographic projection mapping view-space z in [-near, -far] to depth
/// [0, 1], Y flipped for Vulkan clip space.
pub fn orthographic(left: f32, right: f32, bottom: f32, top: f32, near: f32, far: f32) Mat4 {
    return .{
        2 / (right - left),               0,                               0,                    0,
        0,                                -2 / (top - bottom),             0,                    0,
        0,                                0,                               -1 / (far - near),    0,
        -(right + left) / (right - left), (top + bottom) / (top - bottom), -near / (far - near), 1,
    };
}

/// Swaps rows and columns. For a pure rotation this is also its inverse.
pub fn transpose(m: Mat4) Mat4 {
    var result: Mat4 = undefined;
    inline for (0..4) |column| {
        inline for (0..4) |row| result[column * 4 + row] = m[row * 4 + column];
    }
    return result;
}

/// General 4x4 inverse. Returns identity for singular matrices.
pub fn inverse(m: Mat4) Mat4 {
    var inv: Mat4 = undefined;
    inv[0] = m[5] * m[10] * m[15] - m[5] * m[11] * m[14] - m[9] * m[6] * m[15] + m[9] * m[7] * m[14] + m[13] * m[6] * m[11] - m[13] * m[7] * m[10];
    inv[4] = -m[4] * m[10] * m[15] + m[4] * m[11] * m[14] + m[8] * m[6] * m[15] - m[8] * m[7] * m[14] - m[12] * m[6] * m[11] + m[12] * m[7] * m[10];
    inv[8] = m[4] * m[9] * m[15] - m[4] * m[11] * m[13] - m[8] * m[5] * m[15] + m[8] * m[7] * m[13] + m[12] * m[5] * m[11] - m[12] * m[7] * m[9];
    inv[12] = -m[4] * m[9] * m[14] + m[4] * m[10] * m[13] + m[8] * m[5] * m[14] - m[8] * m[6] * m[13] - m[12] * m[5] * m[10] + m[12] * m[6] * m[9];
    inv[1] = -m[1] * m[10] * m[15] + m[1] * m[11] * m[14] + m[9] * m[2] * m[15] - m[9] * m[3] * m[14] - m[13] * m[2] * m[11] + m[13] * m[3] * m[10];
    inv[5] = m[0] * m[10] * m[15] - m[0] * m[11] * m[14] - m[8] * m[2] * m[15] + m[8] * m[3] * m[14] + m[12] * m[2] * m[11] - m[12] * m[3] * m[10];
    inv[9] = -m[0] * m[9] * m[15] + m[0] * m[11] * m[13] + m[8] * m[1] * m[15] - m[8] * m[3] * m[13] - m[12] * m[1] * m[11] + m[12] * m[3] * m[9];
    inv[13] = m[0] * m[9] * m[14] - m[0] * m[10] * m[13] - m[8] * m[1] * m[14] + m[8] * m[2] * m[13] + m[12] * m[1] * m[10] - m[12] * m[2] * m[9];
    inv[2] = m[1] * m[6] * m[15] - m[1] * m[7] * m[14] - m[5] * m[2] * m[15] + m[5] * m[3] * m[14] + m[13] * m[2] * m[7] - m[13] * m[3] * m[6];
    inv[6] = -m[0] * m[6] * m[15] + m[0] * m[7] * m[14] + m[4] * m[2] * m[15] - m[4] * m[3] * m[14] - m[12] * m[2] * m[7] + m[12] * m[3] * m[6];
    inv[10] = m[0] * m[5] * m[15] - m[0] * m[7] * m[13] - m[4] * m[1] * m[15] + m[4] * m[3] * m[13] + m[12] * m[1] * m[7] - m[12] * m[3] * m[5];
    inv[14] = -m[0] * m[5] * m[14] + m[0] * m[6] * m[13] + m[4] * m[1] * m[14] - m[4] * m[2] * m[13] - m[12] * m[1] * m[6] + m[12] * m[2] * m[5];
    inv[3] = -m[1] * m[6] * m[11] + m[1] * m[7] * m[10] + m[5] * m[2] * m[11] - m[5] * m[3] * m[10] - m[9] * m[2] * m[7] + m[9] * m[3] * m[6];
    inv[7] = m[0] * m[6] * m[11] - m[0] * m[7] * m[10] - m[4] * m[2] * m[11] + m[4] * m[3] * m[10] + m[8] * m[2] * m[7] - m[8] * m[3] * m[6];
    inv[11] = -m[0] * m[5] * m[11] + m[0] * m[7] * m[9] + m[4] * m[1] * m[11] - m[4] * m[3] * m[9] - m[8] * m[1] * m[7] + m[8] * m[3] * m[5];
    inv[15] = m[0] * m[5] * m[10] - m[0] * m[6] * m[9] - m[4] * m[1] * m[10] + m[4] * m[2] * m[9] + m[8] * m[1] * m[6] - m[8] * m[2] * m[5];
    const det = m[0] * inv[0] + m[1] * inv[4] + m[2] * inv[8] + m[3] * inv[12];
    if (@abs(det) < 1e-30) return identity;
    const inv_det = 1.0 / det;
    for (&inv) |*value| value.* *= inv_det;
    return inv;
}

/// Unit quaternion for a rotation of `angle` radians about `axis`,
/// counter-clockwise when looking down the axis toward the origin
/// (right-hand rule). `axis` is normalized here; a zero axis gives the
/// vector part zero.
pub fn quatFromAxisAngle(axis: Vec3, angle: f32) Quat {
    const n = normalize(axis);
    const s = @sin(angle * 0.5);
    return .{ n[0] * s, n[1] * s, n[2] * s, @cos(angle * 0.5) };
}

/// Hamilton product: the rotation `b` followed by `a`. Components are
/// (x, y, z, w).
pub fn quatMul(a: Quat, b: Quat) Quat {
    return .{
        a[3] * b[0] + a[0] * b[3] + a[1] * b[2] - a[2] * b[1],
        a[3] * b[1] - a[0] * b[2] + a[1] * b[3] + a[2] * b[0],
        a[3] * b[2] + a[0] * b[1] - a[1] * b[0] + a[2] * b[3],
        a[3] * b[3] - a[0] * b[0] - a[1] * b[1] - a[2] * b[2],
    };
}

/// `q` scaled to unit length, which is what `fromQuat` and `slerp` expect.
/// A quaternion too short to normalize (length under 1e-20) gives
/// `quat_identity`.
pub fn quatNormalize(q: Quat) Quat {
    const len = @sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]);
    if (len < 1e-20) return quat_identity;
    return .{ q[0] / len, q[1] / len, q[2] / len, q[3] / len };
}

/// Shortest-path spherical interpolation.
pub fn slerp(a: Quat, b_in: Quat, t: f32) Quat {
    var b = b_in;
    var cos_theta = a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3];
    if (cos_theta < 0) {
        b = .{ -b[0], -b[1], -b[2], -b[3] };
        cos_theta = -cos_theta;
    }
    if (cos_theta > 0.9995) {
        return quatNormalize(.{
            a[0] + (b[0] - a[0]) * t,
            a[1] + (b[1] - a[1]) * t,
            a[2] + (b[2] - a[2]) * t,
            a[3] + (b[3] - a[3]) * t,
        });
    }
    const theta = std.math.acos(cos_theta);
    const sin_theta = @sin(theta);
    const wa = @sin((1 - t) * theta) / sin_theta;
    const wb = @sin(t * theta) / sin_theta;
    return .{
        a[0] * wa + b[0] * wb,
        a[1] * wa + b[1] * wb,
        a[2] * wa + b[2] * wb,
        a[3] * wa + b[3] * wb,
    };
}

test "inverse round-trips an affine transform" {
    const m = mul(translation(.{ 1, 2, 3 }), mul(rotationY(0.7), scaling(.{ 2, 3, 4 })));
    const product = mul(m, inverse(m));
    for (product, identity) |actual, expected| try std.testing.expectApproxEqAbs(expected, actual, 1e-5);
}

test "reverse-Z perspective maps near to 1 and infinity to 0" {
    const p = perspective(1.0, 1.5, 0.1);
    const near = transformVec4(p, .{ 0, 0, -0.1, 1 });
    try std.testing.expectApproxEqAbs(@as(f32, 1), near[2] / near[3], 1e-6);
    const far = transformVec4(p, .{ 0, 0, -1e6, 1 });
    try std.testing.expect(far[2] / far[3] < 1e-6);
}

test "lookAt places the target on the -Z axis" {
    const view = lookAt(.{ 0, 0, 5 }, .{ 0, 0, 0 }, .{ 0, 1, 0 });
    const p = transformPoint(view, .{ 0, 0, 0 });
    try std.testing.expectApproxEqAbs(@as(f32, -5), p[2], 1e-6);
}
