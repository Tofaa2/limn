//! Cameras, lights, entities and what loaded assets report.
const std = @import("std");
const math = @import("../../math.zig");
const animation = @import("../animation.zig");
const handle = @import("../../handle.zig");
const render = @import("../renderer.zig");
const view_math = @import("../renderer/view_math.zig");

const Mat4 = render.Mat4;
const Vec3 = render.Vec3;

const api = @import("../api.zig");
const Image = api.Image;
const Model = api.Model;
const Scene = api.Scene;
const Entity = api.Entity;
const Pose = api.Pose;
const Shadows = api.Shadows;
const View = api.View;

/// Load state of a model or environment.
pub const AssetState = enum {
    /// Entities that use it are not drawn yet.
    loading,
    ready,
    /// The load failed (see `Renderer.models.loadError`) or the handle is invalid.
    failed,
};

/// Where a view is seen from. Perspective with no far plane; the aspect ratio
/// follows the view's size.
pub const Camera = struct {
    position: Vec3 = .{ 0, 0, 3 },
    /// Need not be normalized.
    forward: Vec3 = .{ 0, 0, -1 },
    /// Need not be perpendicular to `forward`; if parallel, +Z is used.
    up: Vec3 = .{ 0, 1, 0 },
    /// Vertical field of view in radians.
    fov_y: f32 = std.math.degreesToRadians(60.0),
    /// Near plane distance, in world units.
    near: f32 = 0.1,
    /// Shifts the picture off the camera's axis, right and down, in halves of
    /// the picture's height. See `stereo`.
    lens_shift: [2]f32 = .{ 0, 0 },
    /// Null is a perspective camera with `fov_y`. Set for a parallel one, as
    /// in isometric and 2.5D views.
    orthographic: ?Orthographic = null,

    /// A camera at `position` looking toward `target`, which must differ.
    pub fn lookAt(position: Vec3, target: Vec3) Camera {
        return .{ .position = position, .forward = math.sub(target, position) };
    }

    /// Whether the camera can be drawn from: finite numbers, a direction to
    /// look in, a field of view between 0 and pi, a near plane in front and,
    /// when orthographic, a height and a far plane beyond the near one. A
    /// view whose camera is not fails with `error.InvalidCamera`.
    pub fn valid(self: Camera) bool {
        const numbers = self.position ++ self.forward ++ self.up ++ self.lens_shift ++ [2]f32{ self.fov_y, self.near };
        for (numbers) |number| if (!std.math.isFinite(number)) return false;
        if (math.dot(self.forward, self.forward) < 1e-20 or math.dot(self.up, self.up) < 1e-20) return false;
        if (!(self.near > 0)) return false;
        if (self.orthographic) |parallel| {
            if (!std.math.isFinite(parallel.height) or !std.math.isFinite(parallel.far)) return false;
            return parallel.height > 0 and parallel.far > self.near;
        }
        return self.fov_y > 0 and self.fov_y < std.math.pi;
    }

    /// World space to clip space for a picture `size` pixels wide and high,
    /// as views draw with it, without antialiasing jitter.
    pub fn viewProjection(self: Camera, size: [2]f32) Mat4 {
        const projection = view_math.cameraProjection(self, size[0] / @max(size[1], 1e-6));
        return math.mul(projection, math.lookTo(self.position, self.forward, self.up));
    }

    /// Where `point` is drawn in a picture `size` pixels wide and high, in
    /// pixels from its top-left corner, and how far in front of the camera
    /// it is along the view; null when it is not in front. Points off the
    /// picture are still projected.
    pub fn project(self: Camera, point: Vec3, size: [2]f32) ?Projected {
        const clip = math.transformVec4(self.viewProjection(size), .{ point[0], point[1], point[2], 1 });
        const view = math.transformPoint(math.lookTo(self.position, self.forward, self.up), point);
        if (!(-view[2] > 0) or !(clip[3] > 0)) return null;
        return .{
            .pixel = .{ (clip[0] / clip[3] * 0.5 + 0.5) * size[0], (clip[1] / clip[3] * 0.5 + 0.5) * size[1] },
            .depth = -view[2],
        };
    }

    /// The ray through `pixel` (from the top-left corner, in pixels) of a
    /// picture `size` pixels wide and high. It starts on the near plane, so
    /// nothing nearer than the camera draws is hit.
    pub fn ray(self: Camera, pixel: [2]f32, size: [2]f32) Ray {
        const inverse = math.inverse(self.viewProjection(size));
        const ndc = [2]f32{ pixel[0] / size[0] * 2 - 1, pixel[1] / size[1] * 2 - 1 };
        const unproject = struct {
            fn at(matrix: Mat4, x: f32, y: f32, depth: f32) Vec3 {
                const point = math.transformVec4(matrix, .{ x, y, depth, 1 });
                return .{ point[0] / point[3], point[1] / point[3], point[2] / point[3] };
            }
        };
        const near = unproject.at(inverse, ndc[0], ndc[1], 1);
        const far = unproject.at(inverse, ndc[0], ndc[1], 0.5);
        return .{ .origin = near, .direction = math.normalize(math.sub(far, near)) };
    }

    /// Left and right eye cameras `eye_separation` apart in world units,
    /// converging at distance `convergence`. Draw each as its own view with its
    /// own `View` handle.
    pub fn stereo(self: Camera, eye_separation: f32, convergence: f32) [2]Camera {
        const forward = math.normalize(self.forward);
        var right = math.cross(forward, self.up);
        if (math.length(right) < 1e-6) right = math.cross(forward, .{ 0, 0, 1 });
        right = math.normalize(right);
        const half = eye_separation * 0.5;
        const shift = half / (@max(convergence, 1e-3) * @tan(self.fov_y * 0.5));
        var left_eye = self;
        left_eye.position = math.sub(self.position, math.scale(right, half));
        left_eye.lens_shift[0] = self.lens_shift[0] + shift;
        var right_eye = self;
        right_eye.position = math.add(self.position, math.scale(right, half));
        right_eye.lens_shift[0] = self.lens_shift[0] - shift;
        return .{ left_eye, right_eye };
    }
};

/// A point as `Camera.project` finds it in the picture.
pub const Projected = struct {
    /// Pixels from the picture's top-left corner.
    pixel: [2]f32,
    /// World units in front of the camera, along the view.
    depth: f32,
};

/// A half-line from `origin` along `direction`, which is unit length.
pub const Ray = struct {
    origin: Vec3,
    direction: Vec3,

    /// The point `distance` along the ray.
    pub fn at(self: Ray, distance: f32) Vec3 {
        return math.add(self.origin, math.scale(self.direction, distance));
    }
};

test "a camera's ray lands where it projects" {
    const size = [2]f32{ 640, 360 };
    for ([_]Camera{
        Camera.lookAt(.{ 1, 2, 3 }, .{ 0, 0, 0 }),
        .{ .position = .{ -2, 1, 4 }, .forward = .{ 0.3, -0.2, -1 }, .lens_shift = .{ 0.2, -0.1 } },
        .{ .position = .{ 0, 5, 5 }, .forward = .{ 0, -1, -1 }, .orthographic = .{ .height = 8 } },
    }) |camera| {
        for ([_][2]f32{ .{ 320, 180 }, .{ 10, 20 }, .{ 600, 350 } }) |pixel| {
            const ray = camera.ray(pixel, size);
            const projected = camera.project(ray.at(7), size) orelse return error.TestBehindCamera;
            try std.testing.expectApproxEqAbs(pixel[0], projected.pixel[0], 1e-2);
            try std.testing.expectApproxEqAbs(pixel[1], projected.pixel[1], 1e-2);
        }
        try std.testing.expect(camera.project(math.sub(camera.position, camera.forward), size) == null);
    }
    const centered = Camera.lookAt(.{ 0, 0, 5 }, .{ 0, 0, 0 }).project(.{ 0, 1, 0 }, size).?;
    try std.testing.expectApproxEqAbs(@as(f32, 320), centered.pixel[0], 1e-3);
    try std.testing.expect(centered.pixel[1] < 180);
    try std.testing.expectApproxEqAbs(@as(f32, 5), centered.depth, 1e-4);
}

/// A parallel projection; see `Camera.orthographic`.
pub const Orthographic = struct {
    /// World units the picture spans from top to bottom.
    height: f32 = 10,
    /// Far plane distance, in world units. Nothing beyond it is drawn.
    far: f32 = 1000,
};

/// The scene's one shadow-casting directional light; see `Renderer.scenes.setSun`.
pub const SunDesc = struct {
    /// Direction the light travels.
    direction: Vec3 = .{ -0.4, -1.0, -0.3 },
    /// Linear color; `intensity` scales it.
    color: Vec3 = .{ 1.0, 0.96, 0.9 },
    /// In the units of the environment map; 0 turns the sun off. `skySun`
    /// gives a sun matching a sky.
    intensity: f32,
};

pub const LightKind = enum {
    point,
    /// A cone along `direction`, between `inner_angle` and `outer_angle`.
    spot,
    /// Parallel light, like the sun but without shadow maps. `position` and
    /// `range` are ignored.
    directional,
    /// A `source_length` by `source_height` rectangle centered on `position`,
    /// shining along `direction`. Its shadows are ray traced.
    rectangle,
};

/// A point, spot, directional or rectangle light.
pub const LightDesc = struct {
    kind: LightKind = .point,
    position: Vec3,
    /// Ignored for point lights.
    direction: Vec3 = .{ 0, -1, 0 },
    /// Linear color; `intensity` scales it.
    color: Vec3 = .{ 1, 1, 1 },
    intensity: f32 = 1,
    /// Distance, in world units, at which the light's contribution reaches zero.
    range: f32 = 5,
    /// Spot cone half-angles in radians: full brightness inside `inner_angle`,
    /// none outside `outer_angle`.
    inner_angle: f32 = 0.35,
    outer_angle: f32 = 0.6,
    /// Uses one atlas tile for a spot light and six for a point light; at most
    /// 16 tiles per frame, assigned in order.
    cast_shadows: bool = false,
    /// Radius of the emitting sphere; 0 is an ideal point. For a directional
    /// light, the tangent of the angle its disc spans from the center: the
    /// sun's is about 0.005. Path tracing lets light out through anything
    /// inside the sphere, so a lamp may sit within the model of its fitting.
    source_radius: f32 = 0,
    /// Point lights only: makes the source a tube this long along `direction`,
    /// `source_radius` thick. Shadows are still cast from the center.
    source_length: f32 = 0,
    /// Rectangle lights only: panel height (`source_length` is its width).
    source_height: f32 = 0,
    /// Spot lights only: an image projected by the light.
    cookie: ?Image = null,
    /// Brightness by angle from `direction`: a strip image, left edge along the
    /// axis, right edge straight behind. See `Renderer.images.loadLightProfile`.
    profile: ?Image = null,
};

/// What `Renderer.entities.create` makes an entity from. Everything but the model can be
/// changed afterwards.
pub const EntityDesc = struct {
    /// May still be loading; the entity appears once it is ready.
    model: Model,
    /// Model space to world.
    transform: Mat4 = math.identity,
    visible: bool = true,
    /// Multiplies the base color of every material.
    tint: [3]f32 = .{ 1, 1, 1 },
    /// Passed to custom material shaders as `MaterialContext.instance_params`.
    params: [4]f32 = .{ 0, 0, 0, 0 },
    /// False keeps the scene's decals off this entity.
    receive_decals: bool = true,
};

/// An entity as it stands; see `Renderer.entities.info`.
pub const EntityInfo = struct {
    scene: Scene,
    model: Model,
    /// As last set: relative to `parent` when there is one.
    transform: Mat4,
    /// Model space to world, after the parents' transforms.
    world_transform: Mat4,
    parent: ?Entity,
    visible: bool,
    /// As stored, to 1/255.
    tint: [3]f32,
    params: [4]f32,
    receive_decals: bool,
    pose: ?Pose,
};

/// One animation clip of a model; see `Renderer.models.animationInfo`.
pub const AnimationInfo = struct {
    /// Owned by the model; valid until it is destroyed.
    name: []const u8,
    /// In seconds.
    duration: f32,
};

/// See `Renderer.models.info`.
pub const ModelInfo = struct {
    mesh_count: u32,
    triangle_count: u32,
    meshlet_count: u32,
    texture_count: u32,
    /// Joints of all the model's skins together; 0 for a rigid model.
    joint_count: u32,
    /// Meshes that have morph targets, and the most any one has.
    morph_meshes: u32 = 0,
    morph_targets: u32 = 0,
    /// Axis-aligned bounds of the rest pose, in model space.
    bounds_min: Vec3,
    bounds_max: Vec3,
    /// Bounding sphere of the rest pose, in model space.
    bounds_center: Vec3,
    bounds_radius: f32,
};

/// See `Renderer.environments.info`.
pub const EnvironmentInfo = struct {
    /// Direction toward the brightest part of the panorama, usually the sun.
    /// Negate it to get a matching `SunDesc.direction`.
    brightest_direction: Vec3,
};
