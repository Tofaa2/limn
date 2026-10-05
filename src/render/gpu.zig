//! CPU mirrors of the structures in shaders/common.glsl. GLSL uses scalar
//! block layout, which matches `extern struct` as long as every field is
//! naturally aligned; the size assertions below catch drift.
const std = @import("std");
const gltf = @import("../asset/gltf.zig");

/// One mesh vertex as shaders read it (`Vertex` in common.glsl); the same
/// record the glTF loader produces.
pub const Vertex = gltf.Vertex;
/// Joint indices and weights of one skinned vertex (`SkinVertex` in
/// common.glsl), read by `skin.comp`.
pub const SkinVertex = gltf.SkinVertex;
/// One cluster of triangles with its culling bounds and level-of-detail
/// errors (`Meshlet` in common.glsl).
pub const Meshlet = gltf.Meshlet;

/// "None" for texture, buffer slot and record indices (`INVALID_ID` in
/// common.glsl).
pub const invalid_id: u32 = 0xffff_ffff;

/// Bits of `Material.flags` (`MATERIAL_*` in common.glsl). Alpha test:
/// texels whose alpha is under `Material.alpha_cutoff` are discarded.
pub const material_alpha_test: u32 = 1;
/// `Material.flags`: both faces are drawn; back faces are not culled.
pub const material_double_sided: u32 = 2;
/// Bits of `Instance.flags` (`INSTANCE_*` in common.glsl). Skinned: the
/// vertices were deformed this frame, so the instance is culled by
/// `Instance.bounding_sphere` (or its per-meshlet bounds) rather than by
/// the mesh's own bounds.
pub const instance_skinned: u32 = 1;
/// `Instance.flags`: the instance moved or deformed since the last frame,
/// so shading reads its previous transform and vertices for motion
/// vectors. Instances without it skip those fetches.
pub const instance_moving: u32 = 2;
/// `Instance.flags`: decals are not projected onto this instance.
pub const instance_no_decals: u32 = 4;
/// `Instance.flags`: only rays meet this instance (a stand-in, such as a
/// liquid's box); path tracing passes through it.
pub const instance_proxy: u32 = 8;
/// `Instance.flags`: the instance glows evenly and is in the list path
/// tracing aims at, so a path that runs into it does not count its glow
/// again.
pub const instance_aimed: u32 = 16;

/// Bits of `FrameConstants.flags` (`FRAME_*` in common.glsl), saying
/// which effects are on this frame. Shadows: the sun's cascaded shadow
/// map is valid and sampled.
pub const frame_shadows: u32 = 1;
/// `FrameConstants.flags`: ambient occlusion is computed and applied.
pub const frame_ambient_occlusion: u32 = 2;
/// `FrameConstants.flags`: an environment map is bound (`env_specular`,
/// `env_irradiance`, `env_sky`) and lights the scene.
pub const frame_environment: u32 = 4;
/// `FrameConstants.flags`: temporal antialiasing is on, so per-pixel
/// noise changes with `frame_index` for it to average out.
pub const frame_temporal: u32 = 8;
/// `FrameConstants.flags`: the irradiance probe grids (`gi_*`) are valid
/// and provide indirect light.
pub const frame_gi: u32 = 16;
/// `FrameConstants.flags`: roughness is raised where normals vary within
/// a pixel, to steady specular highlights.
pub const frame_specular_aa: u32 = 32;
/// `FrameConstants.flags`: screen-space reflections are on.
pub const frame_ssr: u32 = 64;
/// `FrameConstants.flags`: the cloud layer at `clouds` shadows the sun.
pub const frame_cloud_shadows: u32 = 128;
/// `FrameConstants.flags`: probes gather light from local lights as well
/// as from the sun and sky.
pub const frame_gi_local_lights: u32 = 256;
/// `FrameConstants.flags`: smoke of the fluids at `fluids` shadows the
/// sun.
pub const frame_fluid_shadows: u32 = 512;
/// `FrameConstants.flags`: see-through shadow casters tint the sunlight
/// they let pass; `shadow_color` is valid.
pub const frame_colored_shadows: u32 = 1024;
/// `FrameConstants.flags`: reflection rays also meet see-through
/// surfaces.
pub const frame_reflect_transparent: u32 = 2048;
/// `FrameConstants.flags`: rays (reflections, probes) pass through smoke
/// and see fire.
pub const frame_fluid_rays: u32 = 4096;
/// `Material.flags`: the surface is blended (alpha blend or transmission)
/// and drawn in the transparent pass rather than the opaque one.
pub const material_blend: u32 = 4;

/// Cascades of the sun's shadow map; the length of the cascade arrays in
/// `FrameConstants`, which shaders hard-code as 4.
pub const cascade_count = 4;

/// One mesh in the scene's mesh buffer (`Mesh` in common.glsl): where its
/// indices and meshlets are in the shared buffers. 32 bytes.
pub const Mesh = extern struct {
    /// Bounding sphere in the mesh's own space.
    center: [3]f32,
    radius: f32,
    /// First of the mesh's indices in the shared index buffer; meshlet
    /// index offsets are relative to it.
    index_offset: u32,
    /// The mesh's run of records in the shared meshlet buffer.
    meshlet_offset: u32,
    meshlet_count: u32,
    /// Where the tree over its triangles starts in the tree pool, for
    /// following rays in a shader; `invalid_id` when it has none.
    bvh: u32 = invalid_id,
};

/// A surface's shading parameters (`Material` in common.glsl), one slot
/// of the material buffer. The factors and textures follow glTF's
/// metallic-roughness model and its extensions. Texture fields index the
/// bindless texture table, `invalid_id` for none.
///
/// 208 bytes, asserted below. The size must stay a multiple of 16 because
/// shaders also read the buffer as 16-byte entries (`MATERIAL_WORDS` in
/// common.glsl is the size in those entries).
pub const Material = extern struct {
    /// Linear RGB and opacity, multiplied with the base color texture.
    base_color: [4]f32,
    emissive: [3]f32,
    metallic: f32,
    roughness: f32,
    normal_scale: f32,
    occlusion_strength: f32,
    /// Alpha below which a texel is discarded (`material_alpha_test`).
    alpha_cutoff: f32,
    base_color_texture: u32 = invalid_id,
    normal_texture: u32 = invalid_id,
    metallic_roughness_texture: u32 = invalid_id,
    occlusion_texture: u32 = invalid_id,
    emissive_texture: u32 = invalid_id,
    /// Index of the material's sampler in the bindless sampler table.
    sampler_index: u32,
    /// `material_*` bits.
    flags: u32,
    /// Non-anisotropic sampler for data textures.
    detail_sampler: u32,
    /// 0 for the standard material, else a custom material shader slot.
    shader: u32 = 0,
    /// Free numbers for a custom material shader.
    params: [4]f32 = .{ 0, 0, 0, 0 },
    /// Texture coordinates are mapped by this 2x2 matrix (by rows) and
    /// `uv_offset` before sampling (KHR_texture_transform).
    uv_transform: [4]f32 = .{ 1, 0, 0, 1 },
    uv_offset: [2]f32 = .{ 0, 0 },
    /// A clear, glossy layer over the base surface (car paint, lacquer).
    clearcoat: f32 = 0,
    clearcoat_roughness: f32 = 0,
    /// Light passing through the surface, bent by its index of refraction
    /// over a nominal thickness.
    transmission: f32 = 0,
    ior: f32 = 1.5,
    thickness: f32 = 0.1,
    /// Cloth-like glow at grazing angles; black for none.
    sheen_color: [3]f32 = .{ 0, 0, 0 },
    sheen_roughness: f32 = 0.5,
    /// Highlights stretched along the surface: strength, and the angle of
    /// the grain from the tangent.
    anisotropy: f32 = 0,
    anisotropy_rotation: f32 = 0,
    /// Bit per texture (base color, normal, metallic-roughness, occlusion,
    /// emissive, coat, coat roughness, coat normal, sheen color, sheen
    /// roughness, from bit 0) that is mapped with the second UV set.
    uv_sets: u32 = 0,
    /// How far light spreads under the surface, 0..1.
    subsurface: f32 = 0,
    /// Coat strength (red), coat roughness (green), the coat's own normal
    /// map, sheen color (RGB) and sheen roughness (alpha).
    clearcoat_texture: u32 = invalid_id,
    clearcoat_roughness_texture: u32 = invalid_id,
    clearcoat_normal_texture: u32 = invalid_id,
    sheen_color_texture: u32 = invalid_id,
    sheen_roughness_texture: u32 = invalid_id,
    clearcoat_normal_scale: f32 = 1,
    /// Slot in the material buffer where this material's per-texture
    /// coordinate transforms start (`texture_transform_slots` slots of
    /// them), or `invalid_id` when one transform serves every texture.
    texture_transforms: u32 = invalid_id,
    /// How far the wind bends what is drawn with it (`gltf.Material.sway`).
    sway: f32 = 0,
};

/// One drawn copy of a mesh (`Instance` in common.glsl): its placement,
/// which mesh and material it uses and where its vertices are. Rebuilt
/// each frame. 192 bytes, asserted below.
pub const Instance = extern struct {
    /// Model-to-world matrix, column-major, this frame and last frame
    /// (for motion vectors).
    transform: [16]f32,
    previous_transform: [16]f32,
    /// World-space bounds (center, radius), used instead of meshlet bounds
    /// for skinned meshes.
    bounding_sphere: [4]f32,
    /// Indices into the mesh and material buffers.
    mesh: u32,
    material: u32,
    /// First of the instance's vertices in the shared vertex buffer, this
    /// frame and last frame; they differ for skinned meshes, whose
    /// deformed vertices are written anew each frame.
    vertex_offset: u32,
    previous_vertex_offset: u32,
    /// `instance_*` bits.
    flags: u32,
    /// Multiplies the material's base color: RGBA8, red in the low byte.
    tint: u32 = 0xffffffff,
    /// First of this instance's per-meshlet bounds, for deformed meshes
    /// whose bounds are worked out each frame; else `invalid_id`.
    bounds_offset: u32 = invalid_id,
    /// With only the coarse part of its mesh in memory: the error that
    /// part is drawn at (`gltf.Mesh.coarse_error`). 0 otherwise.
    coarse_error: f32 = 0,
    /// Free numbers for custom material shaders, per entity or per copy.
    params: [4]f32 = .{ 0, 0, 0, 0 },
};

/// One (instance, meshlet) pair of the scene (`MeshletRef` in
/// common.glsl). Culling works through the list of these; an entry's
/// index is its draw's `first_instance` and the upper bits of the
/// visibility buffer's ID.
pub const MeshletRef = extern struct {
    /// Index into the instance buffer.
    instance: u32,
    /// Index into the shared meshlet buffer.
    meshlet: u32,
};

/// Bits of `Light.flags` (`LIGHT_*` in common.glsl); a light with none of
/// the shape bits is a point light. Spot: light is confined to a cone
/// about `Light.direction`.
pub const light_spot: u32 = 1;
/// `Light.flags`: parallel light along `Light.direction`, with no
/// position or falloff.
pub const light_directional: u32 = 2;
/// `Light.flags`: a glowing panel `Light.source_length` wide and
/// `Light.source_height` tall.
pub const light_rectangle: u32 = 4;
/// Shadowed by a ray instead of a shadow tile.
pub const light_traced_shadow: u32 = 8;
/// The glow of a fire: smoke does not shadow it (it comes from all over
/// the flame, not from the one point the record gives).
pub const light_fire: u32 = 16;

/// A local light (`Light` in common.glsl), one entry of the buffer at
/// `FrameConstants.lights`. 80 bytes, asserted below.
pub const Light = extern struct {
    /// World position, and the distance in world units beyond which the
    /// light gives nothing.
    position: [3]f32,
    range: f32,
    /// Linear RGB color and strength of the light.
    color: [3]f32,
    /// The `light_*` bits in the low byte. Bits 8..: first shadow tile
    /// index + 1, or 0 for none.
    flags: u32 = 0,
    direction: [3]f32 = .{ 0, -1, 0 },
    /// Spot cone falloff: saturate(cos_angle * scale + offset) squared.
    /// The defaults give no falloff.
    cone_scale: f32 = 0,
    cone_offset: f32 = 1,
    /// Radius of the glowing sphere the light comes from; 0 is a point.
    source_radius: f32 = 0,
    /// Image projected by a spot light, or `invalid_id`.
    cookie: u32 = invalid_id,
    /// Brightness by angle from the axis (a 1D strip), or `invalid_id`.
    profile: u32 = invalid_id,
    /// Length of a tube light along `direction`; 0 for a point or sphere.
    source_length: f32 = 0,
    /// Rectangle lights: the panel is `source_length` wide and this tall.
    source_height: f32 = 0,
    pad: [2]u32 = .{ 0, 0 },
};

/// One face of a local light's shadow in the shared shadow atlas
/// (`ShadowTile` in common.glsl). 80 bytes, asserted below.
pub const ShadowTile = extern struct {
    /// World space to the tile's clip space.
    view_proj: [16]f32,
    /// uv = tile_uv * rect[0..2] + rect[2..4].
    rect: [4]f32,
};

/// The view frustum is cut into this many froxels across, down and in
/// depth for light and decal lookup (`CLUSTERS_X`, `_Y`, `_Z` in
/// common.glsl). Depth slices are spaced logarithmically; see
/// `FrameConstants.cluster_z_scale`.
pub const clusters_x = 16;
/// Froxels down the screen; see `clusters_x`.
pub const clusters_y = 9;
/// Froxel slices in depth; see `clusters_x`.
pub const clusters_z = 24;
/// Records in the buffer at `FrameConstants.clusters`.
pub const cluster_count = clusters_x * clusters_y * clusters_z;
/// Most lights one cluster can list (`CLUSTER_CAPACITY` in common.glsl);
/// further lights reaching it are left out. Chosen so that the count and
/// the list together fill 128 words.
pub const cluster_capacity = 127;
/// One bit per decal a cluster can hold, 32 to a word.
pub const cluster_decal_words = 8;

/// The lights and decals overlapping one froxel of the view frustum
/// (`Cluster` in common.glsl), filled by `cluster.comp` each frame. 544
/// bytes, asserted below.
pub const Cluster = extern struct {
    /// How many entries of `lights` are in use.
    count: u32,
    /// Indices into the light buffer.
    lights: [cluster_capacity]u32,
    /// Bit i set: decal i reaches this cluster.
    decals: [cluster_decal_words]u32,
};

/// One indexed indirect draw, written by `cull.comp` for each visible
/// meshlet. The fields and their order are those of Vulkan's
/// `VkDrawIndexedIndirectCommand` (20 bytes, asserted below) and must not
/// change.
pub const DrawCommand = extern struct {
    index_count: u32,
    instance_count: u32,
    first_index: u32,
    vertex_offset: i32,
    /// Index of the draw's `MeshletRef`.
    first_instance: u32,
};

/// What one culling pass tests meshlets against (`CullView` in
/// `cull.comp`): the camera's view or one shadow map's. 416 bytes,
/// asserted below.
pub const CullView = extern struct {
    /// Frustum planes in world space; the first `plane_count` are tested.
    planes: [6][4]f32,
    camera_position: [3]f32,
    plane_count: u32,
    /// Nonzero to cull meshlets that face wholly away from
    /// `camera_position`. Only valid for perspective views.
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
    /// Nonzero in shadow views, which also draw blended surfaces; the
    /// camera view leaves those to the transparent pass.
    blended_casters: u32 = 0,
    /// Shaders address these records by pointer and assume 16-byte
    /// alignment, so the size must stay a multiple of 16.
    /// Both of two levels of detail are drawn while the coarser one's
    /// error is between 1 and this many pixels' worth; 1 for no band.
    lod_band: f32 = 1,
    /// Shadow views: bounds smaller than this are not drawn. 0 for none.
    min_radius: f32 = 0,
    /// Shadow views: 0, or how casters are tested against what the camera
    /// sees (1: the part of its view the map shadows, 2: and the depth
    /// pyramid).
    receiver_culling: u32 = 0,
    /// The camera the shadows are for: its view matrix.
    receiver_view: [16]f32 = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 },
    /// The part of that camera's view this map shadows.
    receiver_planes: [6][4]f32 = @splat(.{ 0, 0, 0, 1 }),
    /// Unit direction the light travels in.
    light_travel: [3]f32 = .{ 0, -1, 0 },
    /// How far to the side of a caster its shadow is still read (the
    /// filter's reach).
    receiver_margin: f32 = 0,
    /// Projection terms of the receiver camera, as `p00`, `p11`, `near`.
    receiver_p00: f32 = 1,
    receiver_p11: f32 = 1,
    receiver_near: f32 = 0.1,
    receiver_pad: f32 = 0,
};

/// The camera's automatic exposure state (the `Exposure` block in
/// common.glsl): a small buffer `exposure.comp` updates each frame and
/// the other passes read through `FrameConstants.exposure`. 16 bytes.
pub const Exposure = extern struct {
    /// Factor scene radiance is multiplied by before tone mapping.
    exposure: f32,
    /// The scene's average luminance as the meter has eased to it.
    average_luminance: f32,
    /// Distance the autofocus has settled on.
    focus: f32 = 10,
    pad: f32 = 0,
};

/// Everything a shader needs to know about the frame (`FrameConstants`
/// in common.glsl): camera matrices, sun and environment, indices of the
/// shared textures and samplers in the bindless tables, and the GPU
/// addresses of the scene's buffers. Written by the renderer each frame;
/// shaders receive its address in their push constants.
///
/// The layout is scalar, so it must match the GLSL block field for
/// field. The addresses are 8-byte aligned and must start at offset
/// 1136; the assertions below check that and the total size. Matrices
/// are column-major, as in `math.zig`.
pub const FrameConstants = extern struct {
    /// World to view space, view to clip space (with this frame's
    /// `jitter`), and their product.
    view: [16]f32,
    proj: [16]f32,
    view_proj: [16]f32,
    inv_view_proj: [16]f32,
    /// World to clip space without the temporal jitter, this frame and
    /// last frame, for motion vectors.
    view_proj_unjittered: [16]f32,
    prev_view_proj_unjittered: [16]f32,
    inv_view: [16]f32,
    inv_proj: [16]f32,
    /// World to each sun shadow cascade's clip space.
    cascade_view_proj: [cascade_count][16]f32,
    /// View depth at which each cascade ends; past the last there is no
    /// sun shadow.
    cascade_splits: [4]f32,
    /// World size of one shadow map texel in each cascade.
    cascade_texel_size: [4]f32,
    camera_position: [3]f32,
    /// Distance of the near plane, in world units.
    near: f32,
    /// Unit vector pointing toward the sun.
    sun_direction: [3]f32,
    /// Width of the sun shadow's penumbra, in world units.
    shadow_softness: f32,
    sun_radiance: [3]f32,
    /// Multiplies the light of the environment map.
    env_intensity: f32,
    /// Size of the render target in pixels, and its reciprocal.
    resolution: [2]f32,
    inv_resolution: [2]f32,
    /// Sub-pixel offset of the projection this frame and last frame.
    jitter: [2]f32,
    prev_jitter: [2]f32,
    frame_index: u32,
    /// Seconds: the running clock, and the length of this frame.
    time: f32,
    delta_time: f32,
    /// `frame_*` bits.
    flags: u32,
    /// The sun's cascades (a 2D array texture) and its comparison
    /// sampler. Like every texture and sampler field here, an index into
    /// the bindless tables.
    shadow_map: u32,
    shadow_sampler: u32,
    /// The environment: filtered reflection cube, diffuse cube and sky.
    env_specular: u32,
    env_irradiance: u32,
    env_sky: u32,
    brdf_lut: u32,
    sampler_linear_clamp: u32,
    sampler_nearest_clamp: u32,
    /// Number of mip levels of `env_specular`; rougher reflections read
    /// higher ones.
    env_specular_mips: f32,
    /// Entries in `lights`.
    light_count: u32,
    sampler_linear_repeat: u32,
    /// Entries in `decals`.
    decal_count: u32 = 0,
    /// The atlas of local lights' shadows (see `ShadowTile`) and its
    /// comparison sampler.
    local_shadow_map: u32,
    local_shadow_sampler: u32,
    /// Cluster depth slice = log2(view depth) * scale + bias.
    cluster_z_scale: f32,
    cluster_z_bias: f32,
    /// The main irradiance probe grid (see gi.glsl): world position of
    /// its first probe, distance between probes, probes per axis, and
    /// its irradiance and visibility atlases.
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
    /// The coarse grid behind the main one; `gi2_irradiance` is
    /// `invalid_id` when there is none.
    gi2_origin: [3]f32 = .{ 0, 0, 0 },
    gi2_spacing: f32 = 1,
    gi2_counts: [3]i32 = .{ 2, 2, 2 },
    gi2_irradiance: u32 = invalid_id,
    gi2_visibility: u32 = invalid_id,
    gi2_scroll: u32 = 0,
    /// Samples of the sun shadow filter in penumbrae: 4, 8 or 16.
    shadow_taps: u32 = 16,
    /// Depth buffer for contact shadows, or `invalid_id`, and how far
    /// they reach in world units.
    contact_depth: u32 = invalid_id,
    contact_length: f32 = 0,
    /// Address of the scene's acceleration structure for ray-traced light
    /// shadows, in two halves; zero for none.
    tlas_low: u32 = 0,
    tlas_high: u32 = 0,
    /// Haze per world unit that distant surfaces fade into; 0 for none.
    aerial: f32 = 0,
    /// Tint of the sunlight that see-through casters let pass, per
    /// cascade (rgb) with the nearest such caster's depth (a); or
    /// `invalid_id`.
    shadow_color: u32 = invalid_id,
    /// Local reflection probes of the scene, listed at `probes`.
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
    /// GPU addresses of the scene's buffers from here on, each an array
    /// of the record named after it (`Vertex`, `u32` indices, `Meshlet`,
    /// `Mesh`, `Material`, `Instance`, `MeshletRef`, `Light`, `Cluster`,
    /// `ShadowTile`), then one `Exposure`. The buffers must outlive the
    /// frame's GPU work.
    vertices: u64,
    indices: u64,
    meshlets: u64,
    meshes: u64,
    materials: u64,
    instances: u64,
    meshlet_refs: u64,
    lights: u64,
    clusters: u64,
    shadow_tiles: u64,
    exposure: u64,
    /// Addresses of the `Decal` array, the `Clouds` record, the
    /// `FluidList` and the `ReflectionProbe` array; 0 when the scene has
    /// none.
    decals: u64 = 0,
    clouds: u64 = 0,
    fluids: u64 = 0,
    probes: u64 = 0,
};

comptime {
    std.debug.assert(@sizeOf(Mesh) == 32);
    std.debug.assert(@sizeOf(Material) == 208);
    std.debug.assert(@sizeOf(Instance) == 192);
    std.debug.assert(@sizeOf(Light) == 80);
    std.debug.assert(@sizeOf(ShadowTile) == 80);
    std.debug.assert(@sizeOf(Cluster) == 544);
    std.debug.assert(@sizeOf(DrawCommand) == 20);
    std.debug.assert(@sizeOf(CullView) == 416 and @sizeOf(CullView) % 16 == 0);
    std.debug.assert(@offsetOf(FrameConstants, "vertices") == 1136);
    std.debug.assert(@sizeOf(FrameConstants) == 1136 + 15 * 8);
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

/// Bits of `Emitter.flags` (`EMITTER_*` in particles.glsl). Additive:
/// particles add their light to what is behind them instead of covering
/// it.
pub const emitter_additive: u32 = 1;
/// `Emitter.flags`: particles are lit by the scene's lighting rather
/// than drawn at their own color.
pub const emitter_lit: u32 = 2;
/// `Emitter.flags`: particles are carried by the fluid at
/// `Emitter.fluid`.
pub const emitter_fluid: u32 = 4;
/// `Emitter.flags`: particles bounce off the scene, found through the
/// depth buffer at `Emitter.collision_depth`.
pub const emitter_collide: u32 = 8;
/// `Emitter.flags`: particles are drawn in sorted order, farthest first.
pub const emitter_sorted: u32 = 16;

/// One simulated particle (`Particle` in particles.glsl).
pub const Particle = extern struct {
    position: [3]f32,
    /// Seconds since birth; a particle is alive while age < lifetime.
    age: f32,
    velocity: [3]f32,
    lifetime: f32,
};

/// Length of the color and size curves in `Emitter` (the GLSL arrays in
/// `EmitterData` are declared with the same 8).
pub const emitter_curve_keys = 8;

/// Per-frame emitter parameters (`EmitterData` in particles.glsl), read
/// by the particle simulation and drawing shaders. 400 bytes, asserted
/// below; `fluid` is a GPU address and sits at an 8-byte boundary.
/// Where a field is two numbers they are a range each particle draws
/// from at birth.
pub const Emitter = extern struct {
    /// Particles are born within `radius` of `position`, heading along
    /// `direction` within `spread`.
    position: [3]f32,
    radius: f32,
    direction: [3]f32,
    spread: f32,
    gravity: [3]f32,
    drag: f32,
    /// Color at birth and at death; see also `color_mid` and the curves.
    color_start: [4]f32,
    color_end: [4]f32,
    /// Seconds.
    lifetime: [2]f32,
    speed: [2]f32,
    size: [2]f32,
    /// Particles [spawn_start, spawn_start + spawn_count) are born this
    /// frame.
    spawn_start: u32,
    spawn_count: u32,
    /// Particle slots the emitter owns.
    capacity: u32,
    /// `emitter_*` bits.
    flags: u32,
    /// Bindless index of the particles' image.
    image: u32,
    softness: f32,
    seed: u32,
    pad: u32 = 0,
    /// Added to every live particle this frame; see `shiftScene`.
    shift: [3]f32 = .{ 0, 0, 0 },
    /// How far the oldest trail point has slid toward the next one.
    trail_fraction: f32 = 0,
    /// How quickly particles take on the fluid's velocity, per second.
    follow: f32 = 0,
    /// Share of its speed a particle keeps when it bounces off the scene.
    bounce: f32 = 0,
    /// Last frame's depth buffer to collide with, or `invalid_id`.
    collision_depth: u32 = invalid_id,
    /// Seconds of travel a particle is drawn stretched over.
    stretch: f32 = 0,
    /// Columns and rows of the sprite sheet; played once over the
    /// lifetime.
    sheet: [2]u32 = .{ 1, 1 },
    pad2: [2]u32 = .{ 0, 0 },
    /// The fluid that carries the particles (`emitter_fluid` set), else 0.
    fluid: u64 = 0,
    /// An optional third key partway through life, at `mid` (0..1 of the
    /// lifetime).
    color_mid: [4]f32 = .{ 0, 0, 0, 0 },
    size_mid: f32 = 0,
    mid: f32 = 0.5,
    /// Bit 0: `color_mid` is used. Bit 1: `size_mid` is.
    keys: u32 = 0,
    /// 1 in a step that remembers the particles' positions for trails.
    trail_record: u32 = 0,
    /// Evenly spaced keys over a particle's life; a count of 2 or more
    /// replaces start, mid and end.
    curve_colors: [emitter_curve_keys][4]f32 = @splat(.{ 1, 1, 1, 1 }),
    curve_sizes: [emitter_curve_keys]f32 = @splat(0),
    /// Keys in the color curve and in the size curve.
    curve_counts: [2]u32 = .{ 0, 0 },
    /// Remembered positions per particle, and the newest one's place.
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
    /// A lightning flash inside the layer: where, and how bright.
    flash: [4]f32 = .{ 0, 0, 0, 0 },
};

/// Length of `Fluid.sources`; the GLSL `FluidData` declares the same 8.
pub const max_fluid_sources = 8;
/// Length of `Fluid.obstacles`; the GLSL `FluidData` declares the same 8.
pub const max_fluid_obstacles = 8;

/// `FluidObstacle` in fluid.glsl. A solid shape inside the box, in
/// cells: a sphere (center `a`, `radius`) or, with a negative radius, a
/// box from corner `a` to corner `b`.
pub const FluidObstacle = extern struct {
    a: [3]f32 = .{ 0, 0, 0 },
    radius: f32 = 0,
    b: [3]f32 = .{ 0, 0, 0 },
    pad: f32 = 0,
};

/// `FluidSource` in fluid.glsl.
pub const FluidSource = extern struct {
    /// Center in the box (0..1 per axis) and radius as a share of its
    /// height.
    position: [3]f32 = .{ 0, 0, 0 },
    radius: f32 = 0,
    /// Cells per second the fluid is driven toward inside the source.
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
    /// Share of each quantity left after this step's losses.
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

/// Length of `Water.ripples`; the GLSL `WaterData` declares the same 16.
pub const max_water_ripples = 16;

/// `WaterRipple` in water.glsl: a dent pressed into the surface this
/// step.
pub const WaterRipple = extern struct {
    /// Where on the surface (0..1 across it), how wide (same units) and
    /// how deep the dent is, in the surface's height units.
    position: [2]f32 = .{ 0, 0 },
    radius: f32 = 0,
    depth: f32 = 0,
};

/// `WaterData` in water.glsl: one simulated water surface and one step
/// of it. Its size is asserted below.
pub const Water = extern struct {
    /// Places the unit square (x and z in -0.5..0.5, y up) in the world.
    transform: [16]f32,
    /// Cells of the simulation grid.
    size: [2]i32,
    /// Texture holding height (r) and its rate of change (g).
    state: u32,
    sampler_linear: u32,
    /// Seconds this step advances.
    dt: f32,
    /// Wave speed in cells per second, and the share of motion kept per
    /// step.
    speed: f32,
    keep: f32,
    /// Entries of `ripples` in use.
    ripple_count: u32,
    color: [3]f32,
    /// Per world unit of water looked through: how quickly it takes on
    /// its color.
    murk: f32,
    roughness: f32,
    refraction: f32,
    /// Wind-driven swell laid over the simulated ripples: height and
    /// length.
    swell: f32,
    swell_length: f32,
    /// Strength of the foam at shallow edges and where the surface churns.
    foam: f32 = 0,
    /// Strength of the light pattern the waves cast on what is under them.
    caustics: f32 = 0,
    /// Steepness of the fine wind ripples that the light is shaded by.
    detail: f32 = 0,
    water_pad: f32 = 0,
    ripples: [max_water_ripples]WaterRipple,
};

comptime {
    std.debug.assert(@sizeOf(Water) == 144 + max_water_ripples * 16);
}

/// Optional parts of surface shading, as `SHADE_FEATURES` in common.glsl
/// names them. A shading pipeline built without one leaves that code out.
pub const feature_local_lights: u32 = 1;
/// `SHADE_FEATURES`: lights with a size (sphere, tube and rectangle
/// sources) rather than points only.
pub const feature_sized_lights: u32 = 2;
/// `SHADE_FEATURES`: local lights shadowed by a ray
/// (`light_traced_shadow`).
pub const feature_traced_light_shadows: u32 = 4;
/// `SHADE_FEATURES`: shadows cast by the smoke of fluids.
pub const feature_fluid_shadows: u32 = 8;
/// `SHADE_FEATURES`: shadows cast by the cloud layer.
pub const feature_cloud_shadows: u32 = 16;
/// `SHADE_FEATURES`: decals projected onto surfaces.
pub const feature_decals: u32 = 32;
/// Every feature compiled in; the value `SHADE_FEATURES` has when a
/// pipeline does not set it.
pub const feature_all: u32 = 0xffffffff;
/// `SHADE_FEATURES`: per-texture coordinate transforms
/// (`Material.texture_transforms`).
pub const feature_texture_transforms: u32 = 64;

/// Textures a material can have, in the order shaders number them.
pub const material_texture_count = 10;
/// One coordinate transform: a 2x2 matrix (rows) and an offset.
pub const TextureTransform = extern struct {
    matrix: [4]f32 = .{ 1, 0, 0, 1 },
    offset: [2]f32 = .{ 0, 0 },
    pad: [2]f32 = .{ 0, 0 },
};
/// Material buffer slots a block of per-texture transforms takes.
pub const texture_transform_slots = (material_texture_count * @sizeOf(TextureTransform) + @sizeOf(Material) - 1) / @sizeOf(Material);

comptime {
    // Shaders reach a transform block through the material buffer as an
    // array of 16-byte entries, so a slot must be a whole number of them.
    std.debug.assert(@sizeOf(Material) % 16 == 0);
    std.debug.assert(@sizeOf(TextureTransform) == 32);
}
/// `SHADE_FEATURES`: sunlight tinted by see-through shadow casters.
pub const feature_colored_shadows: u32 = 128;
/// `SHADE_FEATURES`: irradiance probes moved off the grid (gi.glsl).
pub const feature_gi_relocation: u32 = 256;
/// `SHADE_FEATURES`: distance haze (`FrameConstants.aerial`).
pub const feature_aerial: u32 = 512;

/// `ReflectionProbeData` in common.glsl.
pub const ReflectionProbe = extern struct {
    center: [3]f32,
    /// The probe's filtered reflection cube.
    specular: u32,
    extent: [3]f32,
    fade: f32,
    intensity: f32,
    /// The probe's diffuse-filtered cube.
    irradiance: u32,
    pad: [2]f32 = .{ 0, 0 },
};

comptime {
    std.debug.assert(@sizeOf(ReflectionProbe) == 48);
}

/// One particle of a liquid (`LiquidParticle` in liquid.glsl). Positions
/// are in the box's own space: its corner at the origin, its axes along
/// the box, in world units. 64 bytes, asserted below.
pub const LiquidParticle = extern struct {
    position: [3]f32,
    lambda: f32,
    /// Where the step is trying to put it, in two copies that take
    /// turns: each round of the solver reads one and writes the other.
    guess_a: [3]f32,
    pad0: f32 = 0,
    guess_b: [3]f32,
    pad1: f32 = 0,
    velocity: [3]f32,
    pad2: f32 = 0,
};

/// A jet that pours particles into a liquid (`LiquidSource` in
/// liquid.glsl): a round mouth at `position` with the given `radius`,
/// in the liquid's box space, releasing particles at `velocity`. 32
/// bytes; `Liquid` holds up to four.
pub const LiquidSource = extern struct {
    position: [3]f32 = .{ 0, 0, 0 },
    radius: f32 = 0,
    velocity: [3]f32 = .{ 0, 0, 0 },
    /// Particles in one layer across the jet.
    layer: f32 = 1,
};

/// A liquid and one step of it (`LiquidData` in liquid.glsl). 640 bytes
/// and a multiple of 16, both asserted below.
pub const Liquid = extern struct {
    /// Box space (see `LiquidParticle`) to world space.
    from_box: [16]f32,
    /// Size of the box in world units.
    extent: [3]f32,
    /// Reach of a particle's influence, and the size of a grid cell.
    h: f32,
    /// Grid cells along each axis of the box.
    cells: [3]i32,
    /// Particle slots allocated.
    slots: u32,
    /// Particles alive before this step and after it; those between are
    /// born in it.
    live_before: u32,
    live: u32,
    /// The first `block_count` particles start as a block, `block_nx`
    /// by `block_nz` along x and z.
    block_count: u32,
    block_nx: u32,
    block_nz: u32,
    spacing: f32,
    /// Seconds this step advances.
    dt: f32,
    rest_density: f32,
    gravity: [3]f32,
    radius: f32,
    block_origin: [3]f32,
    seed: u32,
    color: [3]f32,
    murk: f32,
    /// Entries of `sources` and of `spheres` in use.
    source_count: u32,
    sphere_count: u32,
    refraction: f32,
    /// Share of its speed a particle keeps from one step to the next.
    keep: f32,
    /// The particles each source gives birth to in this step.
    source_start: [4]u32 = @splat(0),
    source_end: [4]u32 = @splat(0),
    /// How strongly neighbours share their speed.
    viscosity: f32 = 0,
    /// Steepness of the fine ripples the surface is shaded with.
    detail: f32 = 0,
    pad: [2]f32 = .{ 0, 0 },
    /// How far each source's newest layer has travelled from its mouth.
    source_lead: [4]f32 = @splat(0),
    sources: [4]LiquidSource = @splat(.{}),
    /// Things in the liquid's way: center and radius.
    spheres: [16][4]f32 = @splat(.{ 0, 0, 0, 0 }),
};

comptime {
    std.debug.assert(@sizeOf(LiquidParticle) == 64);
    std.debug.assert(@sizeOf(Liquid) == 640 and @sizeOf(Liquid) % 16 == 0);
}
