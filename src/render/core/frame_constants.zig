//! The constants every shader of a view reads, and the flag bits that go with
//! them. The shader declarations are generated from this file by the build
//! (`frame_constants.glsl`, `frame_constants.slang`), so it imports nothing
//! but `std`.
const std = @import("std");

pub const invalid_id: u32 = 0xffff_ffff;
/// Cascades of the sun's shadow map.
pub const cascade_count = 4;

/// `FrameConstants.flags` bits; `FRAME_*` in shaders.
pub const flags = struct {
    /// The sun's cascaded shadow map is valid.
    pub const shadows: u32 = 1;
    pub const ambient_occlusion: u32 = 2;
    /// `env_specular`, `env_irradiance` and `env_sky` are bound.
    pub const environment: u32 = 4;
    /// Temporal antialiasing is on: per-pixel noise varies with `frame_index`.
    pub const temporal: u32 = 8;
    /// The irradiance probe grids (`gi_*`) are valid.
    pub const gi: u32 = 16;
    /// Roughness is raised where normals vary within a pixel.
    pub const specular_aa: u32 = 32;
    pub const ssr: u32 = 64;
    /// The cloud layer at `clouds` shadows the sun.
    pub const cloud_shadows: u32 = 128;
    /// Probes gather light from local lights as well as the sun and sky.
    pub const gi_local_lights: u32 = 256;
    /// Smoke of the fluids at `fluids` shadows the sun.
    pub const fluid_shadows: u32 = 512;
    /// See-through casters tint sunlight; `shadow_color` is valid.
    pub const colored_shadows: u32 = 1024;
    /// Reflection rays also meet see-through surfaces.
    pub const reflect_transparent: u32 = 2048;
    /// Rays (reflections, probes) pass through smoke and see fire.
    pub const fluid_rays: u32 = 4096;
    /// The sun's shadows are read from `FrameConstants.vsm` where it has them.
    pub const vsm: u32 = 8192;
};

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
    /// Irradiance probes moved off the grid (gi.glsl).
    pub const gi_relocation: u32 = 256;
    /// Distance haze (`FrameConstants.aerial`).
    pub const aerial: u32 = 512;
};

/// Shaders receive its address in their push constants. The addresses must
/// start at offset 1136. Matrices are column-major.
/// Most grids of irradiance probes a scene is lit by at once.
pub const gi_cascade_max = 4;

/// One grid of irradiance probes. 48 bytes.
pub const GiCascade = extern struct {
    /// World position of the first probe.
    origin: [3]f32 = .{ 0, 0, 0 },
    spacing: f32 = 1,
    /// Probes per axis.
    counts: [3]i32 = .{ 2, 2, 2 },
    /// The atlases.
    irradiance: u32 = invalid_id,
    visibility: u32 = invalid_id,
    /// Where the grid's first cell is stored, 10 bits per axis.
    scroll: u32 = 0,
    /// Per-probe offsets off the grid, or `invalid_id`.
    offsets: u32 = invalid_id,
    pad: u32 = 0,
};

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
    cascade_view_proj: [cascade_count][16]f32,
    /// View depth at which each cascade ends.
    cascade_splits: [4]f32,
    /// World size of one shadow map texel in each cascade.
    cascade_texel_size: [4]f32,
    camera_position: [3]f32,
    near: f32,
    sun_direction: [3]f32,
    /// Width of the sun shadow's penumbra, in world units.
    shadow_softness: f32 = 0,
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
    flags: u32,
    /// The sun's cascades (a 2D array texture) and its comparison sampler.
    /// Texture and sampler fields here index the bindless tables.
    shadow_map: u32,
    shadow_sampler: u32,
    /// Filtered reflection cube, diffuse cube and sky.
    env_specular: u32,
    env_irradiance: u32,
    env_sky: u32,
    brdf_lut: u32,
    sampler_linear_clamp: u32,
    sampler_nearest_clamp: u32,
    /// Mip levels of `env_specular`.
    env_specular_mips: f32,
    light_count: u32,
    sampler_linear_repeat: u32,
    decal_count: u32 = 0,
    /// The local lights' shadow atlas and its comparison sampler.
    local_shadow_map: u32,
    local_shadow_sampler: u32,
    /// Cluster depth slice = log2(view depth) * scale + bias.
    cluster_z_scale: f32,
    cluster_z_bias: f32,
    /// Cascades of `gi_cascades` in use, finest first.
    gi_cascade_count: u32 = 0,
    gi_intensity: f32 = 1,
    /// Scale applied to texture coordinate derivatives (2^mip bias).
    texture_gradient_scale: f32 = 1,
    /// Sun shadow filter samples: 4, 8 or 16.
    shadow_taps: u32 = 16,
    /// Contact shadow depth buffer, or `invalid_id`, and reach in world units.
    contact_depth: u32 = invalid_id,
    contact_length: f32 = 0,
    /// Address of the scene's TLAS, in two halves; 0 for none.
    tlas_low: u32 = 0,
    tlas_high: u32 = 0,
    /// Haze per world unit; 0 for none.
    aerial: f32 = 0,
    /// Tint of sunlight passed by see-through casters, per cascade (rgb) with
    /// the nearest such caster's depth (a); or `invalid_id`.
    shadow_color: u32 = invalid_id,
    probe_count: u32 = 0,
    /// The irradiance probe grids (gi.glsl), finest first: each is blended
    /// into the next where it ends.
    gi_cascades: [gi_cascade_max]GiCascade = @splat(.{}),
    gi_pad: u32 = 0,
    /// Distance along the view of a depth d is (y + x d) / (z d + w).
    depth_terms: [4]f32 = .{ 0, 0.1, 1, 0 },
    /// Unit direction the camera looks along.
    eye_axis: [3]f32 = .{ 0, 0, -1 },
    /// 1 when the camera is orthographic: every pixel looks along
    /// `eye_axis` from its own point of the lens. 0 otherwise.
    parallel: f32 = 0,
    /// GPU addresses from here on: arrays of `Vertex`, `u32` indices,
    /// `Meshlet`, `Mesh`, `Material`, `Instance`, `MeshletRef`, `Light`,
    /// `Cluster`, `ShadowTile`, then one `Exposure`. The buffers must outlive
    /// the frame's GPU work.
    vertices: u64,
    indices: u64,
    meshlets: u64,
    meshes: u64,
    materials: u64,
    instances: u64,
    /// Last frame's `Instance.transform` of the instances flagged
    /// `instance_previous`, at their own index.
    previous_transforms: u64,
    /// A `VsmParams`, in frames whose flags have `frame_vsm`.
    vsm: u64,
    meshlet_refs: u64,
    lights: u64,
    clusters: u64,
    shadow_tiles: u64,
    exposure: u64,
    /// Addresses of the `Decal` array, `Clouds` record, `FluidList` and
    /// `ReflectionProbe` array; 0 when the scene has none.
    decals: u64 = 0,
    clouds: u64 = 0,
    fluids: u64 = 0,
    probes: u64 = 0,

    /// The shader type behind each address.
    pub const references = .{
        .vertices = "Vertices",
        .indices = "Indices",
        .meshlets = "Meshlets",
        .meshes = "Meshes",
        .materials = "Materials",
        .instances = "Instances",
        .previous_transforms = "PreviousTransforms",
        .vsm = "Vsm",
        .meshlet_refs = "MeshletRefs",
        .lights = "Lights",
        .clusters = "Clusters",
        .shadow_tiles = "ShadowTiles",
        .exposure = "Exposure",
        .decals = "Decals",
        .clouds = "CloudRef",
        .fluids = "FluidList",
        .probes = "ReflectionProbes",
    };
};

comptime {
    std.debug.assert(@offsetOf(FrameConstants, "vertices") == 1232);
    std.debug.assert(@sizeOf(FrameConstants) == 1232 + 17 * 8);
}
