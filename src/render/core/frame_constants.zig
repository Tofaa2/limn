//! The constants every shader of a view reads, and the flag bits that go with
//! them. The shader declarations are generated from this file by the build
//! (`frame_constants.slang`), so it imports nothing but `std`.
const std = @import("std");

pub const invalid_id: u32 = 0xffff_ffff;
/// Cascades of the sun's shadow map.
pub const cascade_count = 4;

/// `SHADE_FEATURES` bits; `FEATURE_*` in shaders. A shading pipeline built
/// without one leaves that code out.
pub const features = struct {
    pub const local_lights: u32 = 1;
    pub const sized_lights: u32 = 2;
    /// Local lights shadowed by a ray (`light_traced_shadow`).
    pub const traced_light_shadows: u32 = 4;
    pub const fluid_shadows: u32 = 8;
    pub const cloud_shadows: u32 = 16;
    pub const decals: u32 = 32;
    /// The value `SHADE_FEATURES` has when a pipeline does not set it.
    pub const all: u32 = 0xffffffff;
    /// Per-texture coordinate transforms (`Material.texture_transforms`).
    pub const texture_transforms: u32 = 64;
    pub const colored_shadows: u32 = 128;
    /// Irradiance probes moved off the grid (gi.slang).
    pub const gi_relocation: u32 = 256;
    /// Distance haze (`FrameConstants.shading.aerial`).
    pub const aerial: u32 = 512;
    /// Rectangle lights, by linearly transformed cosines.
    pub const rect_lights: u32 = 1024;
    /// Coats, sheen, grain and thin films (`Internal.lobe_users`).
    pub const material_lobes: u32 = 2048;
};

pub const shadows = @import("../features/constants/shadows.zig");
pub const lights = @import("../features/constants/lights.zig");
pub const global_illumination = @import("../features/constants/global_illumination.zig");
pub const shading = @import("../features/constants/shading.zig");
pub const reflections = @import("../features/constants/reflections.zig");
pub const ambient_occlusion = @import("../features/constants/ambient_occlusion.zig");
pub const clouds = @import("../features/constants/clouds.zig");
pub const fluids = @import("../features/constants/fluids.zig");
pub const GiCascade = global_illumination.GiCascade;
pub const gi_cascade_max = global_illumination.gi_cascade_max;

/// The constants every shader of a view reads: the view's own, then one block
/// per feature that has any. Shaders receive its address in their push
/// constants. Matrices are column-major.
pub const FrameConstants = extern struct {
    /// World to view, jittered view to clip, and their product.
    view: [16]f32,
    proj: [16]f32,
    view_proj: [16]f32,
    inv_view_proj: [16]f32,
    /// World to clip without jitter, this frame and last, for motion vectors.
    view_proj_unjittered: [16]f32,
    prev_view_proj_unjittered: [16]f32,
    inv_view: [16]f32,
    inv_proj: [16]f32,
    camera_position: [3]f32,
    near: f32,
    sun_direction: [3]f32,
    sun_radiance: [3]f32,
    env_intensity: f32,
    /// Render target size in pixels, and its reciprocal.
    resolution: [2]f32,
    inv_resolution: [2]f32,
    /// Sub-pixel offset of the projection this frame and last frame.
    jitter: [2]f32,
    prev_jitter: [2]f32,
    frame_index: u32,
    /// Seconds: the running clock, and the length of this frame.
    time: f32,
    delta_time: f32,
    /// 1 when `env_specular`, `env_irradiance` and `env_sky` are bound.
    environment: u32 = 0,
    /// 1 when temporal antialiasing is on: per-pixel noise varies with
    /// `frame_index`.
    temporal: u32 = 0,
    /// Filtered reflection cube, diffuse cube and sky.
    env_specular: u32,
    env_irradiance: u32,
    env_sky: u32,
    brdf_lut: u32,
    sampler_linear_clamp: u32,
    sampler_nearest_clamp: u32,
    /// Mip levels of `env_specular`.
    env_specular_mips: f32,
    sampler_linear_repeat: u32,
    /// Scale applied to texture coordinate derivatives (2^mip bias).
    texture_gradient_scale: f32 = 1,
    /// Distance along the view of a depth d is (y + x d) / (z d + w).
    depth_terms: [4]f32 = .{ 0, 0.1, 1, 0 },
    /// Unit direction the camera looks along.
    eye_axis: [3]f32 = .{ 0, 0, -1 },
    /// 1 when the camera is orthographic: every pixel looks along
    /// `eye_axis` from its own point of the lens. 0 otherwise.
    parallel: f32 = 0,
    /// GPU addresses: arrays of `Vertex`, `u32` indices, `Meshlet`, `Mesh`,
    /// `Material`, `Instance`, `MeshletRef`, then one `Exposure`. The buffers
    /// must outlive the frame's GPU work.
    vertices: u64,
    indices: u64,
    meshlets: u64,
    meshes: u64,
    materials: u64,
    instances: u64,
    /// Last frame's `Instance.transform` of the instances flagged
    /// `instance_previous`, at their own index.
    previous_transforms: u64,
    meshlet_refs: u64,
    exposure: u64,
    /// One block per feature with constants of its own, each filled in by
    /// that feature (see `features/constants/`).
    ambient_occlusion: ambient_occlusion.AmbientOcclusionConstants = .{},
    shadows: shadows.ShadowConstants = .{},
    lights: lights.LightConstants = .{},
    gi: global_illumination.GiConstants = .{},
    shading: shading.ShadingConstants = .{},
    reflections: reflections.ReflectionConstants = .{},
    clouds: clouds.CloudConstants = .{},
    fluids: fluids.FluidConstants = .{},

    /// The shader type behind each address.
    pub const references = .{
        .vertices = "Vertices",
        .indices = "Indices",
        .meshlets = "Meshlets",
        .meshes = "Meshes",
        .materials = "Materials",
        .instances = "Instances",
        .previous_transforms = "PreviousTransforms",
        .meshlet_refs = "MeshletRefs",
        .exposure = "Exposure",
    };
};

comptime {
    std.debug.assert(@sizeOf(FrameConstants) % 8 == 0);
}
