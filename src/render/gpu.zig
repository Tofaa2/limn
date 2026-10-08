//! CPU mirrors of the structures in shaders/common.glsl. GLSL scalar block
//! layout matches `extern struct` when every field is naturally aligned.
const std = @import("std");
const gltf = @import("../asset/gltf.zig");

/// `Vertex` in common.glsl.
pub const Vertex = gltf.Vertex;
/// `SkinVertex` in common.glsl, read by `skin.comp`.
pub const SkinVertex = gltf.SkinVertex;
/// `Meshlet` in common.glsl.
pub const Meshlet = gltf.Meshlet;

/// `INVALID_ID` in common.glsl: no texture, slot or record.
pub const invalid_id: u32 = 0xffff_ffff;

/// `Material.flags` bits (`MATERIAL_*` in common.glsl). Texels with alpha
/// under `Material.alpha_cutoff` are discarded.
pub const material_alpha_test: u32 = 1;
/// Back faces are not culled.
pub const material_double_sided: u32 = 2;
/// `Instance.flags` bits (`INSTANCE_*` in common.glsl). Deformed this
/// frame: culled by `Instance.bounding_sphere` or its per-meshlet bounds.
pub const instance_skinned: u32 = 1;
/// Moved or deformed since last frame: shading reads its previous
/// transform and vertices for motion vectors.
pub const instance_moving: u32 = 2;
pub const instance_no_decals: u32 = 4;
/// Only rays meet this instance; path tracing passes through it.
pub const instance_proxy: u32 = 8;
/// In the list of emitters path tracing samples, so a path that hits it
/// does not count its glow again.
pub const instance_aimed: u32 = 16;
/// Last frame's transform is in `FrameConstants.previous_transforms`.
pub const instance_previous: u32 = 32;

/// Top three rows of a matrix, column by column (`mat4x3` in shaders).
pub fn affine(m: [16]f32) [12]f32 {
    return .{ m[0], m[1], m[2], m[4], m[5], m[6], m[8], m[9], m[10], m[12], m[13], m[14] };
}

/// Inverse of `affine`.
pub fn expand(m: [12]f32) [16]f32 {
    return .{ m[0], m[1], m[2], 0, m[3], m[4], m[5], 0, m[6], m[7], m[8], 0, m[9], m[10], m[11], 1 };
}

/// `FrameConstants.flags` bits (`FRAME_*` in common.glsl). The sun's
/// cascaded shadow map is valid.
pub const frame_shadows: u32 = 1;
pub const frame_ambient_occlusion: u32 = 2;
/// `env_specular`, `env_irradiance` and `env_sky` are bound.
pub const frame_environment: u32 = 4;
/// Temporal antialiasing is on: per-pixel noise varies with `frame_index`.
pub const frame_temporal: u32 = 8;
/// The irradiance probe grids (`gi_*`) are valid.
pub const frame_gi: u32 = 16;
/// Roughness is raised where normals vary within a pixel.
pub const frame_specular_aa: u32 = 32;
pub const frame_ssr: u32 = 64;
/// The cloud layer at `clouds` shadows the sun.
pub const frame_cloud_shadows: u32 = 128;
/// Probes gather light from local lights as well as the sun and sky.
pub const frame_gi_local_lights: u32 = 256;
/// Smoke of the fluids at `fluids` shadows the sun.
pub const frame_fluid_shadows: u32 = 512;
/// See-through casters tint sunlight; `shadow_color` is valid.
pub const frame_colored_shadows: u32 = 1024;
/// Reflection rays also meet see-through surfaces.
pub const frame_reflect_transparent: u32 = 2048;
/// Rays (reflections, probes) pass through smoke and see fire.
pub const frame_fluid_rays: u32 = 4096;
/// The sun's shadows are read from `FrameConstants.vsm` where it has them.
pub const frame_vsm: u32 = 8192;

/// The sun's virtual shadow map (vsm.glsl): levels, pages per level side,
/// texels per page side, pages per atlas side, and most pages drawn in a
/// frame.
pub const vsm_levels = 4;
pub const vsm_pages = 16;
pub const vsm_page_texels = 256;
pub const vsm_atlas_pages = 16;
pub const vsm_pages_per_frame = 8;

/// `VsmPage` in vsm.glsl.
pub const VsmPage = extern struct { key: u32, place: u32, used: u32, flags: u32 };
/// `VsmPageView` in vsm.glsl.
pub const VsmPageView = extern struct { view_proj: [16]f32, bounds: [4]f32 };
/// `Vsm` in vsm.glsl.
pub const VsmParams = extern struct {
    light_view: [16]f32,
    camera: [3]f32,
    base_extent: f32,
    depth_from: f32,
    depth_range: f32,
    frame: u32,
    reset: u32,
    levels: u32,
    atlas_texture: u32,
    mover_count: u32,
    all_moved: u32,
    pages: u64,
    owners: u64,
    requested: u64,
    page_views: u64,
    movers: u64,
};
/// `Material.flags`: alpha blend or transmission; transparent pass.
pub const material_blend: u32 = 4;
/// `Material.roughness` is a glossiness factor, `params` the specular factor,
/// and the metallic-roughness texture holds specular and glossiness.
pub const material_specular_glossiness: u32 = 8;

/// Cascades of the sun's shadow map. Shaders hard-code 4.
pub const cascade_count = 4;

/// `Mesh` in common.glsl. 32 bytes.
pub const Mesh = extern struct {
    center: [3]f32,
    radius: f32,
    /// First index in the shared index buffer; base of meshlet offsets.
    index_offset: u32,
    meshlet_offset: u32,
    meshlet_count: u32,
    /// Start of its triangle tree in the tree pool, or `invalid_id`.
    bvh: u32 = invalid_id,
};

/// `Material` in common.glsl, one slot of the material buffer. Texture
/// fields index the bindless texture table, `invalid_id` for none.
/// 208 bytes. The size must stay a multiple of 16: shaders also read the
/// buffer as 16-byte entries (`MATERIAL_WORDS` in common.glsl).
pub const Material = extern struct {
    /// Linear RGB and opacity, multiplied with the base color texture.
    base_color: [4]f32,
    emissive: [3]f32,
    metallic: f32,
    roughness: f32,
    normal_scale: f32,
    occlusion_strength: f32,
    /// Used with `material_alpha_test`.
    alpha_cutoff: f32,
    base_color_texture: u32 = invalid_id,
    normal_texture: u32 = invalid_id,
    metallic_roughness_texture: u32 = invalid_id,
    occlusion_texture: u32 = invalid_id,
    emissive_texture: u32 = invalid_id,
    sampler_index: u32,
    flags: u32,
    /// Non-anisotropic sampler for data textures.
    detail_sampler: u32,
    /// 0 for the standard material, else a custom material shader slot.
    shader: u32 = 0,
    params: [4]f32 = .{ 0, 0, 0, 0 },
    /// 2x2 matrix (by rows) applied with `uv_offset` before sampling
    /// (KHR_texture_transform).
    uv_transform: [4]f32 = .{ 1, 0, 0, 1 },
    uv_offset: [2]f32 = .{ 0, 0 },
    clearcoat: f32 = 0,
    clearcoat_roughness: f32 = 0,
    transmission: f32 = 0,
    ior: f32 = 1.5,
    thickness: f32 = 0.1,
    /// Black for none.
    sheen_color: [3]f32 = .{ 0, 0, 0 },
    sheen_roughness: f32 = 0.5,
    /// Strength, and the angle of the grain from the tangent.
    anisotropy: f32 = 0,
    anisotropy_rotation: f32 = 0,
    /// Bit per texture mapped with the second UV set, from bit 0: base color,
    /// normal, metallic-roughness, occlusion, emissive, coat, coat roughness,
    /// coat normal, sheen color, sheen roughness.
    uv_sets: u32 = 0,
    /// 0..1.
    subsurface: f32 = 0,
    /// Coat strength (red), coat roughness (green), the coat's own normal
    /// map, sheen color (RGB) and sheen roughness (alpha).
    clearcoat_texture: u32 = invalid_id,
    clearcoat_roughness_texture: u32 = invalid_id,
    clearcoat_normal_texture: u32 = invalid_id,
    sheen_color_texture: u32 = invalid_id,
    sheen_roughness_texture: u32 = invalid_id,
    clearcoat_normal_scale: f32 = 1,
    /// First material buffer slot of this material's per-texture transforms
    /// (`texture_transform_slots` slots), or `invalid_id` when one transform
    /// serves every texture.
    texture_transforms: u32 = invalid_id,
    /// See `gltf.Material.sway`.
    sway: f32 = 0,
};

/// `Instance` in common.glsl: one drawn copy of a mesh. Rebuilt each
/// frame. 116 bytes.
pub const Instance = extern struct {
    /// Model-to-world matrix as `affine` packs it.
    transform: [12]f32,
    /// World-space center and radius; replaces meshlet bounds when skinned.
    bounding_sphere: [4]f32,
    mesh: u32,
    material: u32,
    /// First vertex in the shared vertex buffer, this frame and last frame.
    vertex_offset: u32,
    previous_vertex_offset: u32,
    flags: u32,
    /// Multiplies the material's base color: RGBA8, red in the low byte.
    tint: u32 = 0xffffffff,
    /// First per-meshlet bounds record for deformed meshes, else `invalid_id`.
    bounds_offset: u32 = invalid_id,
    /// Error the coarse part is drawn at when only it is in memory
    /// (`gltf.Mesh.coarse_error`); 0 otherwise.
    coarse_error: f32 = 0,
    /// Baked lightmap, read with the second UV set, or `invalid_id`.
    lightmap: u32 = invalid_id,
    params: [4]f32 = .{ 0, 0, 0, 0 },
};

/// `StaticCull` in cull_instances.comp: an instance's world-space
/// bounding sphere and where its `MeshletRef`s are.
pub const StaticCull = extern struct {
    sphere: [4]f32,
    first_ref: u32,
    ref_count: u32,
    /// Index + 1 of the `Impostor` drawn when small enough, or 0.
    impostor: u32 = 0,
    pad: u32 = 0,
};

/// `Impostor` in impostor.glsl.
pub const Impostor = extern struct {
    center: [3]f32,
    radius: f32,
    color_texture: u32,
    normal_texture: u32,
    pixels: f32,
    pad: f32 = 0,
};

/// `ImpostorDraw` in cull_instances.comp.
pub const DrawIndirect = extern struct {
    vertex_count: u32,
    instance_count: u32 = 0,
    first_vertex: u32 = 0,
    first_instance: u32 = 0,
};

/// `MeshDraw` in cull.comp: task shader group counts for one meshlet list.
pub const MeshDraw = extern struct {
    x: u32 = 0,
    y: u32 = 1,
    z: u32 = 1,
    pad: u32 = 0,
};

/// `CullDispatch` in cull_view.glsl.
pub const CullDispatch = extern struct {
    x: u32,
    y: u32 = 1,
    z: u32 = 1,
    count: u32 = 0,
};

/// `MeshletRef` in common.glsl. An entry's index is its draw's
/// `first_instance` and the upper bits of the visibility buffer's ID.
pub const MeshletRef = extern struct {
    instance: u32,
    meshlet: u32,
};

/// `Light.flags` bits (`LIGHT_*` in common.glsl); no shape bit is a point
/// light. Light is confined to a cone about `Light.direction`.
pub const light_spot: u32 = 1;
/// Parallel light along `Light.direction`; no position or falloff.
pub const light_directional: u32 = 2;
/// A panel `Light.source_length` wide and `Light.source_height` tall.
pub const light_rectangle: u32 = 4;
pub const light_traced_shadow: u32 = 8;
/// The glow of a fire: smoke does not shadow it.
pub const light_fire: u32 = 16;

/// `Light` in common.glsl. 80 bytes.
pub const Light = extern struct {
    /// World position, and the distance beyond which the light gives nothing.
    position: [3]f32,
    range: f32,
    /// Linear RGB, scaled by intensity.
    color: [3]f32,
    /// `light_*` bits in the low byte. Bits 8..: first shadow tile index + 1,
    /// or 0 for none.
    flags: u32 = 0,
    direction: [3]f32 = .{ 0, -1, 0 },
    /// Spot cone falloff: saturate(cos_angle * scale + offset) squared.
    /// The defaults give no falloff.
    cone_scale: f32 = 0,
    cone_offset: f32 = 1,
    /// Radius of the emitting sphere; 0 is a point.
    source_radius: f32 = 0,
    /// Image projected by a spot light, or `invalid_id`.
    cookie: u32 = invalid_id,
    /// Brightness by angle from the axis (a 1D strip), or `invalid_id`.
    profile: u32 = invalid_id,
    /// Length of a tube light along `direction`; 0 for a point or sphere.
    source_length: f32 = 0,
    /// Height of a rectangle light; its width is `source_length`.
    source_height: f32 = 0,
    pad: [2]u32 = .{ 0, 0 },
};

/// `ShadowTile` in common.glsl: one atlas face of a light. 80 bytes.
pub const ShadowTile = extern struct {
    view_proj: [16]f32,
    /// uv = tile_uv * rect[0..2] + rect[2..4].
    rect: [4]f32,
};

/// Froxel grid for light and decal lookup (`CLUSTERS_X`, `_Y`, `_Z` in
/// common.glsl). Depth slices are logarithmic; see
/// `FrameConstants.cluster_z_scale`.
pub const clusters_x = 16;
pub const clusters_y = 9;
pub const clusters_z = 24;
/// Records in the buffer at `FrameConstants.clusters`.
pub const cluster_count = clusters_x * clusters_y * clusters_z;
/// Most lights one cluster lists (`CLUSTER_CAPACITY` in common.glsl); the
/// rest are dropped. Count plus list fill 128 words.
pub const cluster_capacity = 127;
/// One bit per decal a cluster can hold, 32 to a word.
pub const cluster_decal_words = 8;

/// `Cluster` in common.glsl, filled by `cluster.comp`. 544 bytes.
pub const Cluster = extern struct {
    count: u32,
    lights: [cluster_capacity]u32,
    /// Bit i set: decal i reaches this cluster.
    decals: [cluster_decal_words]u32,
};

/// Written by `cull.comp` per visible meshlet. Layout is Vulkan's
/// `VkDrawIndexedIndirectCommand` (20 bytes) and must not change.
pub const DrawCommand = extern struct {
    index_count: u32,
    instance_count: u32,
    first_index: u32,
    vertex_offset: i32,
    /// Index of the draw's `MeshletRef`.
    first_instance: u32,
};

/// `CullView` in `cull.comp`: the camera's view or one shadow map's. 432
/// bytes; shaders assume 16-byte alignment, so the size must stay a
/// multiple of 16.
pub const CullView = extern struct {
    /// Frustum planes in world space; the first `plane_count` are tested.
    planes: [6][4]f32,
    camera_position: [3]f32,
    plane_count: u32,
    /// Nonzero to cull meshlets facing wholly away from `camera_position`.
    /// Only valid for perspective views.
    cone_culling: u32,
    /// Projection terms and view matrix, used by the occlusion test.
    p00: f32 = 1,
    p11: f32 = 1,
    near: f32 = 0.1,
    view: [16]f32 = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 },
    /// Camera that levels of detail are chosen for, and pixels per world
    /// unit at distance 1 divided by the allowed error (0 = full detail).
    lod_camera: [3]f32 = .{ 0, 0, 0 },
    lod_scale: f32 = 0,
    /// Nonzero in shadow views, which also draw blended surfaces.
    blended_casters: u32 = 0,
    /// Both of two levels of detail are drawn while the coarser one's error
    /// is between 1 and this many pixels; 1 for no band.
    lod_band: f32 = 1,
    /// Shadow views: bounds smaller than this are not drawn. 0 for none.
    min_radius: f32 = 0,
    /// Shadow views: 0 for none, 1 tests casters against the part of the
    /// camera's view the map shadows, 2 also against the depth pyramid.
    receiver_culling: u32 = 0,
    /// View matrix of the camera the shadows are for.
    receiver_view: [16]f32 = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 },
    /// The part of that camera's view this map shadows.
    receiver_planes: [6][4]f32 = @splat(.{ 0, 0, 0, 1 }),
    light_travel: [3]f32 = .{ 0, -1, 0 },
    /// The shadow filter's sideways reach.
    receiver_margin: f32 = 0,
    /// Projection terms of the receiver camera, as `p00`, `p11`, `near`.
    receiver_p00: f32 = 1,
    receiver_p11: f32 = 1,
    receiver_near: f32 = 0.1,
    receiver_pad: f32 = 0,
    /// Off-axis shift in half picture sizes (`Camera.lens_shift`).
    lens_shift: [2]f32 = .{ 0, 0 },
    pad: [2]f32 = .{ 0, 0 },
};

/// The `Exposure` block in common.glsl, updated by `exposure.comp`. 16 bytes.
pub const Exposure = extern struct {
    /// Multiplies scene radiance before tone mapping.
    exposure: f32,
    /// Smoothed average scene luminance.
    average_luminance: f32,
    focus: f32 = 10,
    pad: f32 = 0,
};

/// `FrameConstants` in common.glsl; shaders receive its address in their
/// push constants. Must match the GLSL block field for field. The
/// addresses must start at offset 1136. Matrices are column-major.
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
    shadow_softness: f32,
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
    /// Main irradiance probe grid (gi.glsl): world position of its first
    /// probe, probe spacing, probes per axis, and its atlases.
    gi_origin: [3]f32 = .{ 0, 0, 0 },
    gi_spacing: f32 = 1,
    gi_counts: [3]i32 = .{ 2, 2, 2 },
    gi_irradiance: u32 = invalid_id,
    gi_visibility: u32 = invalid_id,
    gi_intensity: f32 = 1,
    /// Scale applied to texture coordinate derivatives (2^mip bias).
    texture_gradient_scale: f32 = 1,
    /// Where the probe grid's first cell is stored, 10 bits per axis.
    gi_scroll: u32 = 0,
    /// The coarse grid; `gi2_irradiance` is `invalid_id` when there is none.
    gi2_origin: [3]f32 = .{ 0, 0, 0 },
    gi2_spacing: f32 = 1,
    gi2_counts: [3]i32 = .{ 2, 2, 2 },
    gi2_irradiance: u32 = invalid_id,
    gi2_visibility: u32 = invalid_id,
    gi2_scroll: u32 = 0,
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
    /// Per-probe offsets of the two probe grids, or `invalid_id`.
    gi_offsets: u32 = invalid_id,
    gi2_offsets: u32 = invalid_id,
    /// The middle probe grid, between the main and the coarse one.
    gi3_origin: [3]f32 = .{ 0, 0, 0 },
    gi3_spacing: f32 = 1,
    gi3_counts: [3]i32 = .{ 2, 2, 2 },
    gi3_irradiance: u32 = invalid_id,
    gi3_visibility: u32 = invalid_id,
    gi3_scroll: u32 = 0,
    gi3_offsets: u32 = invalid_id,
    gi3_pad: u32 = 0,
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
};

comptime {
    std.debug.assert(@sizeOf(Mesh) == 32);
    std.debug.assert(@sizeOf(Material) == 208);
    std.debug.assert(@sizeOf(Instance) == 116);
    std.debug.assert(@sizeOf(Light) == 80);
    std.debug.assert(@sizeOf(ShadowTile) == 80);
    std.debug.assert(@sizeOf(Cluster) == 544);
    std.debug.assert(@sizeOf(DrawCommand) == 20);
    std.debug.assert(@sizeOf(CullView) == 432 and @sizeOf(CullView) % 16 == 0);
    std.debug.assert(@offsetOf(FrameConstants, "vertices") == 1136);
    std.debug.assert(@sizeOf(FrameConstants) == 1136 + 17 * 8);
}

/// Written by `pick.comp`.
pub const Pick = extern struct {
    instance: u32,
    triangle: u32,
    depth: f32,
    pad: u32 = 0,
    position: [3]f32,
    pad1: u32 = 0,
};

/// `Emitter.flags` bits (`EMITTER_*` in particles.glsl). Additive blend.
pub const emitter_additive: u32 = 1;
pub const emitter_lit: u32 = 2;
/// Carried by the fluid at `Emitter.fluid`.
pub const emitter_fluid: u32 = 4;
/// Collides with the depth buffer at `Emitter.collision_depth`.
pub const emitter_collide: u32 = 8;
pub const emitter_sorted: u32 = 16;

/// `Particle` in particles.glsl.
pub const Particle = extern struct {
    position: [3]f32,
    /// Seconds since birth; alive while age < lifetime.
    age: f32,
    velocity: [3]f32,
    lifetime: f32,
};

/// Curve length in `Emitter`; `EmitterData` in GLSL declares the same 8.
pub const emitter_curve_keys = 8;

/// `EmitterData` in particles.glsl. 400 bytes; `fluid` is a GPU address
/// at an 8-byte boundary. Two-number fields are a range each particle
/// draws from at birth.
pub const Emitter = extern struct {
    /// Particles are born within `radius` of `position`, heading along
    /// `direction` within `spread`.
    position: [3]f32,
    radius: f32,
    direction: [3]f32,
    spread: f32,
    gravity: [3]f32,
    drag: f32,
    /// Color at birth and at death.
    color_start: [4]f32,
    color_end: [4]f32,
    /// Seconds.
    lifetime: [2]f32,
    speed: [2]f32,
    size: [2]f32,
    /// Particles [spawn_start, spawn_start + spawn_count) spawn this frame.
    spawn_start: u32,
    spawn_count: u32,
    capacity: u32,
    flags: u32,
    image: u32,
    softness: f32,
    seed: u32,
    pad: u32 = 0,
    /// Added to every live particle this frame; see `shiftScene`.
    shift: [3]f32 = .{ 0, 0, 0 },
    /// How far the oldest trail point has slid toward the next one.
    trail_fraction: f32 = 0,
    /// Rate particles take on the fluid's velocity, per second.
    follow: f32 = 0,
    /// Fraction of speed kept on a bounce.
    bounce: f32 = 0,
    /// Last frame's depth buffer to collide with, or `invalid_id`.
    collision_depth: u32 = invalid_id,
    /// Seconds of travel a particle is drawn stretched over.
    stretch: f32 = 0,
    /// Columns and rows of the sprite sheet; played once over the lifetime.
    sheet: [2]u32 = .{ 1, 1 },
    pad2: [2]u32 = .{ 0, 0 },
    /// Address of the carrying fluid (`emitter_fluid` set), else 0.
    fluid: u64 = 0,
    /// Optional third key at `mid` (0..1 of the lifetime).
    color_mid: [4]f32 = .{ 0, 0, 0, 0 },
    size_mid: f32 = 0,
    mid: f32 = 0.5,
    /// Bit 0: `color_mid` is used. Bit 1: `size_mid` is.
    keys: u32 = 0,
    /// 1 in a step that records positions for trails.
    trail_record: u32 = 0,
    /// Evenly spaced keys over a particle's life; a count of 2 or more
    /// replaces start, mid and end.
    curve_colors: [emitter_curve_keys][4]f32 = @splat(.{ 1, 1, 1, 1 }),
    curve_sizes: [emitter_curve_keys]f32 = @splat(0),
    /// Keys in the color curve and in the size curve.
    curve_counts: [2]u32 = .{ 0, 0 },
    /// Remembered positions per particle, and the newest one's index.
    trail_count: u32 = 0,
    trail_head: u32 = 0,
};

comptime {
    std.debug.assert(@sizeOf(Particle) == 32);
    std.debug.assert(@sizeOf(Emitter) == 400);
}

/// `Decal` in common.glsl.
pub const Decal = extern struct {
    world_to_decal: [16]f32,
    color: [4]f32,
    image: u32,
    angle_fade: f32,
    emissive: f32,
    roughness: f32,
    normal_image: u32 = invalid_id,
    normal_strength: f32 = 1,
    pad: [2]u32 = .{ 0, 0 },
    /// World-space sphere around the box, for sorting into clusters.
    bounds: [4]f32,
};

comptime {
    std.debug.assert(@sizeOf(Decal) == 128);
}

/// `CloudData` in clouds.glsl.
pub const Clouds = extern struct {
    offset: [3]f32,
    period: f32,
    albedo: [3]f32,
    density: f32,
    bottom: f32,
    top: f32,
    coverage: f32,
    detail: f32,
    planet_radius: f32,
    max_distance: f32,
    variation: f32,
    ambient: f32,
    noise: u32,
    steps: i32,
    light_steps: i32,
    history: u32,
    history_blend: f32,
    anisotropy: f32,
    depth: u32,
    shadow_strength: f32 = 0,
    cirrus: f32 = 0,
    anvil: f32 = 0,
    cloud_pad: [2]f32 = .{ 0, 0 },
    /// A lightning flash inside the layer: position and brightness.
    flash: [4]f32 = .{ 0, 0, 0, 0 },
};

/// Length of `Fluid.sources`; `FluidData` in GLSL declares the same 8.
pub const max_fluid_sources = 8;
/// Length of `Fluid.obstacles`; `FluidData` in GLSL declares the same 8.
pub const max_fluid_obstacles = 8;

/// `FluidObstacle` in fluid.glsl, in cells: a sphere (center `a`,
/// `radius`) or, with a negative radius, a box from corner `a` to `b`.
pub const FluidObstacle = extern struct {
    a: [3]f32 = .{ 0, 0, 0 },
    radius: f32 = 0,
    b: [3]f32 = .{ 0, 0, 0 },
    pad: f32 = 0,
};

/// `FluidSource` in fluid.glsl.
pub const FluidSource = extern struct {
    /// Center (0..1 per axis) and radius as a fraction of the box's height.
    position: [3]f32 = .{ 0, 0, 0 },
    radius: f32 = 0,
    /// Target velocity inside the source, in cells per second.
    velocity: [3]f32 = .{ 0, 0, 0 },
    /// Smoke, fuel and temperature added per second at the center.
    smoke: f32 = 0,
    fuel: f32 = 0,
    temperature: f32 = 0,
    pad0: f32 = 0,
    pad1: f32 = 0,
};

/// `FluidData` in fluid.glsl.
pub const Fluid = extern struct {
    world_to_box: [16]f32,
    box_to_world: [16]f32,
    size: [3]i32,
    tiles_x: i32,
    dt: f32,
    buoyancy: f32,
    weight: f32,
    vorticity: f32,
    /// Fraction of each quantity kept per step.
    velocity_keep: f32,
    smoke_keep: f32,
    heat_keep: f32,
    fuel_keep: f32,
    heat: f32,
    soot: f32,
    walls: u32,
    source_count: u32,
    wind: [3]f32,
    absorption: f32,
    smoke_color: [3]f32,
    fire_intensity: f32,
    fire_color: [3]f32,
    shadow: f32,
    velocity: u32 = 0,
    solid: u32 = 0,
    sampler_linear: u32,
    sampler_nearest: u32,
    scalars: u32,
    anisotropy: f32,
    ambient: f32,
    pad: f32 = 0,
    sources: [max_fluid_sources]FluidSource,
    obstacles: [max_fluid_obstacles]FluidObstacle,
    obstacle_count: u32,
    /// Nonzero when the solid mask has been drawn this frame.
    solid_mask: u32 = 0,
};

comptime {
    std.debug.assert(@sizeOf(FluidSource) == 48);
    std.debug.assert(@sizeOf(Fluid) == 272 + max_fluid_sources * 48 + max_fluid_obstacles * 32 + 8);
}

/// `FluidList` in common.glsl.
pub const FluidList = extern struct {
    count: u32 = 0,
    pad: u32 = 0,
    fluids: [8]u64 = @splat(0),
};

/// Length of `Water.ripples`; `WaterData` in GLSL declares the same 16.
pub const max_water_ripples = 16;

/// `WaterRipple` in water.glsl: a dent pressed into the surface this step.
pub const WaterRipple = extern struct {
    /// Position and width in 0..1 across the surface; depth in the surface's
    /// height units.
    position: [2]f32 = .{ 0, 0 },
    radius: f32 = 0,
    depth: f32 = 0,
};

/// `WaterData` in water.glsl: one water surface and one step of it.
pub const Water = extern struct {
    /// Places the unit square (x and z in -0.5..0.5, y up) in the world.
    transform: [16]f32,
    size: [2]i32,
    /// Texture holding height (r) and its rate of change (g).
    state: u32,
    sampler_linear: u32,
    dt: f32,
    /// Wave speed in cells per second, and motion kept per step.
    speed: f32,
    keep: f32,
    ripple_count: u32,
    color: [3]f32,
    /// Rate the water takes on its color, per world unit looked through.
    murk: f32,
    roughness: f32,
    refraction: f32,
    /// Height and length of the wind-driven swell.
    swell: f32,
    swell_length: f32,
    /// Strength of foam at shallow edges and churn.
    foam: f32 = 0,
    /// Strength of the caustics cast below the surface.
    caustics: f32 = 0,
    /// Steepness of the fine wind ripples used for shading.
    detail: f32 = 0,
    water_pad: f32 = 0,
    ripples: [max_water_ripples]WaterRipple,
};

comptime {
    std.debug.assert(@sizeOf(Water) == 144 + max_water_ripples * 16);
}

/// `SHADE_FEATURES` bits in common.glsl. A shading pipeline built without
/// one leaves that code out.
pub const feature_local_lights: u32 = 1;
pub const feature_sized_lights: u32 = 2;
/// Local lights shadowed by a ray (`light_traced_shadow`).
pub const feature_traced_light_shadows: u32 = 4;
pub const feature_fluid_shadows: u32 = 8;
pub const feature_cloud_shadows: u32 = 16;
pub const feature_decals: u32 = 32;
/// The value `SHADE_FEATURES` has when a pipeline does not set it.
pub const feature_all: u32 = 0xffffffff;
/// Per-texture coordinate transforms (`Material.texture_transforms`).
pub const feature_texture_transforms: u32 = 64;

/// Textures a material can have, in the order shaders number them.
pub const material_texture_count = 10;
/// A 2x2 matrix (rows) and an offset.
pub const TextureTransform = extern struct {
    matrix: [4]f32 = .{ 1, 0, 0, 1 },
    offset: [2]f32 = .{ 0, 0 },
    pad: [2]f32 = .{ 0, 0 },
};
/// Material buffer slots a block of per-texture transforms takes.
pub const texture_transform_slots = (material_texture_count * @sizeOf(TextureTransform) + @sizeOf(Material) - 1) / @sizeOf(Material);

comptime {
    std.debug.assert(@sizeOf(Material) % 16 == 0);
    std.debug.assert(@sizeOf(TextureTransform) == 32);
}
pub const feature_colored_shadows: u32 = 128;
/// Irradiance probes moved off the grid (gi.glsl).
pub const feature_gi_relocation: u32 = 256;
/// Distance haze (`FrameConstants.aerial`).
pub const feature_aerial: u32 = 512;

/// `ReflectionProbeData` in common.glsl.
pub const ReflectionProbe = extern struct {
    center: [3]f32,
    specular: u32,
    extent: [3]f32,
    fade: f32,
    intensity: f32,
    irradiance: u32,
    pad: [2]f32 = .{ 0, 0 },
};

comptime {
    std.debug.assert(@sizeOf(ReflectionProbe) == 48);
}

/// `LiquidParticle` in liquid.glsl. Positions are in box space: corner at
/// the origin, axes along the box, in world units. 64 bytes.
pub const LiquidParticle = extern struct {
    position: [3]f32,
    lambda: f32,
    /// Predicted position, in two copies the solver ping-pongs between.
    guess_a: [3]f32,
    pad0: f32 = 0,
    guess_b: [3]f32,
    pad1: f32 = 0,
    velocity: [3]f32,
    pad2: f32 = 0,
};

/// `LiquidSource` in liquid.glsl: a round mouth at `position` with
/// `radius`, in box space, releasing particles at `velocity`. 32 bytes.
pub const LiquidSource = extern struct {
    position: [3]f32 = .{ 0, 0, 0 },
    radius: f32 = 0,
    velocity: [3]f32 = .{ 0, 0, 0 },
    /// Particles in one layer across the jet.
    layer: f32 = 1,
};

/// `LiquidData` in liquid.glsl. 640 bytes; must be a multiple of 16.
pub const Liquid = extern struct {
    /// Box space (see `LiquidParticle`) to world space.
    from_box: [16]f32,
    extent: [3]f32,
    /// Particle influence radius, and the grid cell size.
    h: f32,
    cells: [3]i32,
    slots: u32,
    /// Particles alive before and after this step; the rest spawn in it.
    live_before: u32,
    live: u32,
    /// The first `block_count` particles start as a block, `block_nx` by
    /// `block_nz` along x and z.
    block_count: u32,
    block_nx: u32,
    block_nz: u32,
    spacing: f32,
    dt: f32,
    rest_density: f32,
    gravity: [3]f32,
    radius: f32,
    block_origin: [3]f32,
    seed: u32,
    color: [3]f32,
    murk: f32,
    source_count: u32,
    sphere_count: u32,
    refraction: f32,
    /// Fraction of speed kept per step.
    keep: f32,
    /// Range of particles each source spawns in this step.
    source_start: [4]u32 = @splat(0),
    source_end: [4]u32 = @splat(0),
    viscosity: f32 = 0,
    /// Steepness of the fine ripples used for shading.
    detail: f32 = 0,
    pad: [2]f32 = .{ 0, 0 },
    /// Distance each source's newest layer has travelled from its mouth.
    source_lead: [4]f32 = @splat(0),
    sources: [4]LiquidSource = @splat(.{}),
    /// Obstacles: center and radius.
    spheres: [16][4]f32 = @splat(.{ 0, 0, 0, 0 }),
};

comptime {
    std.debug.assert(@sizeOf(LiquidParticle) == 64);
    std.debug.assert(@sizeOf(Liquid) == 640 and @sizeOf(Liquid) % 16 == 0);
}
