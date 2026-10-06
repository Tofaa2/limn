// Declarations shared by every shader: the bindless table, GPU scene layout
// and the per-frame constant block. Mirrors src/render/gpu.zig; keep in sync.
#ifndef COMMON_GLSL
#define COMMON_GLSL

#extension GL_EXT_buffer_reference : require
#extension GL_EXT_scalar_block_layout : require
#extension GL_EXT_nonuniform_qualifier : require
#extension GL_EXT_samplerless_texture_functions : require

layout(set = 0, binding = 0) uniform texture2D textures_2d[];
layout(set = 0, binding = 0) uniform utexture2D textures_2d_uint[];
layout(set = 0, binding = 0) uniform textureCube textures_cube[];
layout(set = 0, binding = 0) uniform texture2DArray textures_2d_array[];
layout(set = 0, binding = 1) uniform sampler samplers[];
layout(set = 0, binding = 1) uniform samplerShadow samplers_shadow[];

#define TEX(texture_index, sampler_index) sampler2D(textures_2d[nonuniformEXT(texture_index)], samplers[nonuniformEXT(sampler_index)])
#define TEX_UINT(texture_index, sampler_index) usampler2D(textures_2d_uint[nonuniformEXT(texture_index)], samplers[nonuniformEXT(sampler_index)])
#define TEX_CUBE(texture_index, sampler_index) samplerCube(textures_cube[nonuniformEXT(texture_index)], samplers[nonuniformEXT(sampler_index)])

const float PI = 3.14159265358979;
const uint INVALID_ID = 0xffffffffu;

const uint MATERIAL_ALPHA_TEST = 1u;
const uint MATERIAL_DOUBLE_SIDED = 2u;
const uint INSTANCE_SKINNED = 1u;
const uint INSTANCE_MOVING = 2u;
const uint INSTANCE_NO_DECALS = 4u;
// A stand-in that only rays meet; path tracing passes through it.
const uint INSTANCE_PROXY = 8u;
// Glows evenly and is aimed at by path tracing (see pathtrace.frag).
const uint INSTANCE_AIMED = 16u;

const uint FRAME_SHADOWS = 1u;
const uint FRAME_AMBIENT_OCCLUSION = 2u;
const uint FRAME_ENVIRONMENT = 4u;
const uint FRAME_TEMPORAL = 8u;
const uint FRAME_GI = 16u;
const uint FRAME_SPECULAR_AA = 32u;
const uint FRAME_SSR = 64u;
const uint FRAME_CLOUD_SHADOWS = 128u;
const uint FRAME_GI_LOCAL_LIGHTS = 256u;
const uint FRAME_FLUID_SHADOWS = 512u;
const uint FRAME_COLORED_SHADOWS = 1024u;
// Reflection rays also meet see-through surfaces.
const uint FRAME_REFLECT_TRANSPARENT = 2048u;
// Rays (reflections, probes) pass through smoke and see fire.
const uint FRAME_FLUID_RAYS = 4096u;

// Optional parts of surface shading. Everything is compiled in unless a
// pipeline says otherwise through this constant; the renderer builds the
// shading pass again without the parts a scene does not use, because code
// that never runs still slows the rest down.
layout(constant_id = 0) const uint SHADE_FEATURES = 0xffffffffu;
const uint FEATURE_LOCAL_LIGHTS = 1u;
const uint FEATURE_SIZED_LIGHTS = 2u;
const uint FEATURE_TRACED_LIGHT_SHADOWS = 4u;
const uint FEATURE_FLUID_SHADOWS = 8u;
const uint FEATURE_CLOUD_SHADOWS = 16u;
const uint FEATURE_DECALS = 32u;
const uint FEATURE_TEXTURE_TRANSFORMS = 64u;
const uint FEATURE_COLORED_SHADOWS = 128u;
// Probes moved off the grid (gi.glsl).
const uint FEATURE_GI_RELOCATION = 256u;
// Distance haze (aerialHaze).
const uint FEATURE_AERIAL = 512u;
const uint MATERIAL_BLEND = 4u;

struct Vertex {
    vec3 position;
    // Unit vectors, each a point of the octahedron in two signed 16-bit
    // fractions; read them with vertexNormal and vertexTangent.
    uint normal;
    uint tangent;
    vec2 uv;
    // Multiplies the base color (RGBA8).
    uint color;
    // A second set of texture coordinates.
    vec2 uv1;
};

vec3 unpackDirection(uint packed) {
    vec2 point = unpackSnorm2x16(packed);
    vec3 direction = vec3(point, 1.0 - abs(point.x) - abs(point.y));
    float fold = max(-direction.z, 0.0);
    direction.x += direction.x >= 0.0 ? -fold : fold;
    direction.y += direction.y >= 0.0 ? -fold : fold;
    return normalize(direction);
}

uint packDirection(vec3 direction) {
    vec2 point = direction.xy / max(abs(direction.x) + abs(direction.y) + abs(direction.z), 1e-20);
    if (direction.z < 0.0) point = (1.0 - abs(point.yx)) * vec2(point.x >= 0.0 ? 1.0 : -1.0, point.y >= 0.0 ? 1.0 : -1.0);
    return packSnorm2x16(point);
}

vec3 vertexNormal(Vertex vertex) {
    return unpackDirection(vertex.normal);
}

// The tangent, and in w the side the bitangent is on (1 or -1).
vec4 vertexTangent(Vertex vertex) {
    return vec4(unpackDirection(vertex.tangent), (vertex.tangent & 0x10000u) != 0u ? -1.0 : 1.0);
}

uint packTangent(vec4 tangent) {
    return (packDirection(tangent.xyz) & ~0x10000u) | (tangent.w < 0.0 ? 0x10000u : 0u);
}

struct SkinVertex {
    uvec4 joints;
    vec4 weights;
};

struct Meshlet {
    vec3 center;
    float radius;
    vec3 cone_axis;
    float cone_cutoff;
    uint index_offset;
    uint index_count;
    // Error of this level of detail and of the next coarser one.
    float lod_error;
    float parent_error;
    // With a cluster hierarchy: the bounds (center, radius, in the mesh's
    // space) by whose distance the two errors are judged. A negative
    // radius means the whole mesh's bounds are used instead.
    vec4 self_sphere;
    vec4 parent_sphere;
};

struct Mesh {
    vec3 center;
    float radius;
    uint index_offset;
    uint meshlet_offset;
    uint meshlet_count;
    // Root of the tree over its triangles (see trace.glsl), or INVALID_ID.
    uint bvh;
};

struct Material {
    vec4 base_color;
    vec3 emissive;
    float metallic;
    float roughness;
    float normal_scale;
    float occlusion_strength;
    float alpha_cutoff;
    uint base_color_texture;
    uint normal_texture;
    uint metallic_roughness_texture;
    uint occlusion_texture;
    uint emissive_texture;
    uint sampler_index;
    uint flags;
    uint detail_sampler;
    // 0 for the standard material, else a custom material shader.
    uint shader;
    vec4 params;
    // Texture coordinates are mapped by a 2x2 matrix (rows xy, zw) and an
    // offset before sampling (KHR_texture_transform).
    vec4 uv_transform;
    vec2 uv_offset;
    // A clear, glossy layer over the base surface (car paint, lacquer).
    float clearcoat;
    float clearcoat_roughness;
    // Light passing through the surface, bent by its index of refraction
    // over a nominal thickness.
    float transmission;
    float ior;
    float thickness;
    // Cloth-like glow at grazing angles; black for none.
    vec3 sheen_color;
    float sheen_roughness;
    // Highlights stretched along the surface: strength, and the angle of
    // the grain from the tangent.
    float anisotropy;
    float anisotropy_rotation;
    // Bit per texture (base color, normal, metallic-roughness, occlusion,
    // emissive, coat, coat roughness, coat normal, sheen color, sheen
    // roughness) that uses the second UV set.
    uint uv_sets;
    // How far light spreads under the surface, 0..1.
    float subsurface;
    // Coat strength (red), coat roughness (green), the coat's own normal
    // map, sheen color (RGB) and sheen roughness (alpha).
    uint clearcoat_texture;
    uint clearcoat_roughness_texture;
    uint clearcoat_normal_texture;
    uint sheen_color_texture;
    uint sheen_roughness_texture;
    float clearcoat_normal_scale;
    // Slot in the material buffer of per-texture coordinate transforms, or
    // INVALID_ID when the one above serves every texture.
    uint texture_transforms;
    // How far the wind bends it; see `swayOffset`.
    float sway;
};

struct Instance {
    mat4 transform;
    mat4 previous_transform;
    // World-space bounds, used instead of meshlet bounds for skinned meshes.
    vec4 bounding_sphere;
    uint mesh;
    uint material;
    uint vertex_offset;
    uint previous_vertex_offset;
    uint flags;
    // Multiplies the base color (RGBA8).
    uint tint;
    // First of this instance's per-meshlet bounds (skinned meshes with
    // `Options.skinned_meshlet_bounds`), or INVALID_ID.
    uint bounds_offset;
    // With only the coarse part of its mesh in memory: the error that
    // part is drawn at (see `Mesh.coarse_error` in gltf.zig). 0 otherwise.
    float coarse_error;
    // Free numbers for custom material shaders, per entity or per copy.
    vec4 params;
};

// One entry per (instance, meshlet) pair in the scene. Its index is the
// draw's firstInstance and the upper bits of the visibility ID.
struct MeshletRef {
    uint instance;
    uint meshlet;
};

const uint LIGHT_SPOT = 1u;
const uint LIGHT_DIRECTIONAL = 2u;
const uint LIGHT_RECTANGLE = 4u;
const uint LIGHT_TRACED_SHADOW = 8u;
// The glow of a fire, which smoke does not shadow.
const uint LIGHT_FIRE = 16u;

struct Light {
    vec3 position;
    float range;
    vec3 color;
    // Bit 0: spot light. Bits 8..: index of the first shadow tile plus one,
    // or zero when the light casts no shadow.
    uint flags;
    vec3 direction;
    // Spot cone falloff: saturate(cos_angle * scale + offset) squared.
    float cone_scale;
    float cone_offset;
    // Radius of the glowing sphere the light comes from; 0 is a point.
    float source_radius;
    // Image projected by a spot light, or INVALID_ID.
    uint cookie;
    // Brightness by angle from the axis (a 1D strip), or INVALID_ID.
    uint profile;
    // Length of a tube light along `direction`; 0 for a point or sphere.
    float source_length;
    // Rectangle lights: the panel is source_length wide and this tall.
    float source_height;
    uint light_pad1;
    uint light_pad2;
};

// One face of a local light's shadow in the shared atlas.
struct ShadowTile {
    mat4 view_proj;
    // Atlas placement: uv = tile_uv * rect.xy + rect.zw.
    vec4 rect;
};

const uint CLUSTERS_X = 16u;
const uint CLUSTERS_Y = 9u;
const uint CLUSTERS_Z = 24u;
const uint CLUSTER_CAPACITY = 127u;
const uint CLUSTER_DECAL_WORDS = 8u;

// Lights and decals overlapping one froxel of the view frustum.
struct Cluster {
    uint count;
    uint lights[CLUSTER_CAPACITY];
    // Bit i set: decal i reaches this froxel.
    uint decals[CLUSTER_DECAL_WORDS];
};

layout(buffer_reference, scalar) readonly buffer Vertices { Vertex data[]; };
layout(buffer_reference, scalar) readonly buffer Indices { uint data[]; };
layout(buffer_reference, scalar) readonly buffer Meshlets { Meshlet data[]; };
layout(buffer_reference, scalar) readonly buffer Meshes { Mesh data[]; };
layout(buffer_reference, scalar) readonly buffer Materials { Material data[]; };
// The same buffer seen as 16-byte entries: per-texture coordinate
// transforms live in spare material slots, two entries each (the 2x2
// matrix by rows, then the offset).
layout(buffer_reference, scalar) readonly buffer MaterialWords { vec4 data[]; };
const uint MATERIAL_WORDS = 13u; // 16-byte entries per material slot
layout(buffer_reference, scalar) readonly buffer Instances { Instance data[]; };
layout(buffer_reference, scalar) readonly buffer MeshletRefs { MeshletRef data[]; };
layout(buffer_reference, scalar) readonly buffer Lights { Light data[]; };
layout(buffer_reference, scalar) readonly buffer ShadowTiles { ShadowTile data[]; };

// A box that projects a color or image onto whatever surface is inside it.
struct Decal {
    // World space to the decal's unit cube; it projects along local -Z.
    mat4 world_to_decal;
    vec4 color;
    uint image;
    // Cosine below which surfaces facing away from the projection fade out.
    float angle_fade;
    float emissive;
    // Roughness the decal imposes, or negative to keep the surface's.
    float roughness;
    // Tangent-space normal map laid over the surface, or INVALID_ID.
    uint normal_image;
    float normal_strength;
    uint decal_pad0;
    uint decal_pad1;
    // World-space sphere around the box.
    vec4 bounds;
};
layout(buffer_reference, scalar) readonly buffer Decals { Decal data[]; };

// A local reflection probe: what a box of space mirrors, as a filtered
// cube map taken from its middle. Mirrors `gpu.ReflectionProbe`.
struct ReflectionProbeData {
    vec3 center;
    uint specular;
    // Half the box's size, and the share of it over which the probe fades.
    vec3 extent;
    float fade;
    float intensity;
    // Its diffuse-filtered cube: the light the probe would give a surface.
    uint irradiance;
    vec2 probe_pad;
};
layout(buffer_reference, scalar) readonly buffer ReflectionProbes { ReflectionProbeData data[]; };
layout(buffer_reference, scalar) buffer Clusters { Cluster data[]; };
layout(buffer_reference, scalar) buffer Exposure {
    float exposure;
    float average_luminance;
    // Distance the autofocus has eased to.
    float focus;
    float exposure_pad;
};

// Mirrors `gpu.Clouds`.
struct CloudData {
    // Where the noise has drifted to (wind and scene shifts), in meters,
    // and how many meters one repeat of the noise spans.
    vec3 offset;
    float period;
    vec3 albedo;
    float density;
    float bottom;
    float top;
    float coverage;
    float detail;
    float planet_radius;
    float max_distance;
    float variation;
    float ambient;
    uint noise_texture;
    int steps;
    int light_steps;
    uint history_texture;
    float history_blend;
    float anisotropy;
    uint depth_texture;
    float shadow_strength;
    // Cover of a second, thin layer high above the first; 0 for none.
    float cirrus;
    // How strongly the thickest weather towers up and spreads at the top.
    float anvil;
    vec2 cloud_pad;
    // A lightning flash inside the layer: where, and how bright (w).
    vec4 flash;
};

layout(buffer_reference, scalar) readonly buffer CloudRef { CloudData data; };
const uint FLUID_WALLS_OPEN = 0u;    // fluid leaves through every side
const uint FLUID_WALLS_FLOOR = 1u;   // solid underneath, open elsewhere
const uint FLUID_WALLS_CLOSED = 2u;  // a sealed box

struct FluidSource {
    // Center in the box (0..1 per axis) and radius as a share of its height.
    vec3 position;
    float radius;
    // Cells per second the fluid is driven toward inside the source.
    vec3 velocity;
    // Added per second at the center.
    float smoke;
    float fuel;
    float temperature;
    float pad0;
    float pad1;
};

// A solid shape inside the box, in cells: a sphere (center `a`, `radius`)
// or, with a negative radius, a box from corner `a` to corner `b`.
struct FluidObstacle {
    vec3 a;
    float radius;
    vec3 b;
    float pad;
};

// Mirrors `gpu.Fluid`.
struct FluidData {
    mat4 world_to_box;
    mat4 box_to_world;
    ivec3 size;
    int tiles_x;
    float dt;
    float buoyancy;
    float weight;
    float vorticity;
    // Share of each quantity left after this step's losses.
    float velocity_keep;
    float smoke_keep;
    float heat_keep;
    float fuel_keep;
    float heat;
    float soot;
    uint walls;
    uint source_count;
    vec3 wind;
    float absorption;
    vec3 smoke_color;
    float fire_intensity;
    vec3 fire_color;
    float shadow;
    uint velocity_texture;
    uint solid_texture;
    uint sampler_linear;
    uint sampler_nearest;
    uint scalars_texture;
    float anisotropy;
    float ambient;
    float pad;
    FluidSource sources[8];
    FluidObstacle obstacles[8];
    uint obstacle_count;
    // Nonzero when the solid mask has been drawn this frame.
    uint solid_mask;
};

layout(buffer_reference, scalar) readonly buffer FluidRef { FluidData data; };

// The fluids of the scene being drawn, for the shadows their smoke casts.
layout(buffer_reference, scalar) readonly buffer FluidList {
    uint count;
    uint pad;
    FluidRef fluids[8];
};

layout(buffer_reference, scalar) readonly buffer FrameConstants {
    mat4 view;
    mat4 proj;
    mat4 view_proj;
    mat4 inv_view_proj;
    mat4 view_proj_unjittered;
    mat4 prev_view_proj_unjittered;
    mat4 inv_view;
    mat4 inv_proj;
    mat4 cascade_view_proj[4];
    vec4 cascade_splits;
    vec4 cascade_texel_size;
    vec3 camera_position;
    float near;
    vec3 sun_direction;
    float shadow_softness;
    vec3 sun_radiance;
    float env_intensity;
    vec2 resolution;
    vec2 inv_resolution;
    vec2 jitter;
    vec2 prev_jitter;
    uint frame_index;
    float time;
    float delta_time;
    uint flags;
    uint shadow_map;
    uint shadow_sampler;
    uint env_specular;
    uint env_irradiance;
    uint env_sky;
    uint brdf_lut;
    uint sampler_linear_clamp;
    uint sampler_nearest_clamp;
    float env_specular_mips;
    uint light_count;
    uint sampler_linear_repeat;
    uint decal_count;
    uint local_shadow_map;
    uint local_shadow_sampler;
    // Cluster depth slice = log2(view depth) * scale + bias.
    float cluster_z_scale;
    float cluster_z_bias;
    // Irradiance probe volume (see gi.glsl).
    vec3 gi_origin;
    float gi_spacing;
    ivec3 gi_counts;
    uint gi_irradiance;
    uint gi_visibility;
    float gi_intensity;
    float texture_gradient_scale;
    // Storage offset of the grid's first cell, 10 bits per axis.
    uint gi_scroll;
    // The coarse grid behind the main one; gi2_irradiance is INVALID_ID
    // when there is none.
    vec3 gi2_origin;
    float gi2_spacing;
    ivec3 gi2_counts;
    uint gi2_irradiance;
    uint gi2_visibility;
    uint gi2_scroll;
    // Samples of the sun shadow filter in penumbrae: 4, 8 or 16.
    uint shadow_taps;
    // Depth buffer for contact shadows, or INVALID_ID, and their reach.
    uint contact_depth;
    float contact_length;
    // The scene's acceleration structure (address in two halves), for
    // lights shadowed by a ray; zero for none.
    uint tlas_low;
    uint tlas_high;
    // Haze per world unit over which distant surfaces fade; negative for
    // the simple model (see aerialHaze).
    float aerial;
    // Tint of the sunlight see-through casters let pass, per cascade (rgb)
    // with the nearest such caster's depth (a), or INVALID_ID.
    uint shadow_color;
    // Local reflection probes of the scene.
    uint probe_count;
    // Per-probe offsets of the two probe grids (see GiGrid), or INVALID_ID.
    uint gi_offsets;
    uint gi2_offsets;
    // The middle grid (see gi.glsl); gi3_irradiance is INVALID_ID without.
    vec3 gi3_origin;
    float gi3_spacing;
    ivec3 gi3_counts;
    uint gi3_irradiance;
    uint gi3_visibility;
    uint gi3_scroll;
    uint gi3_offsets;
    uint gi3_pad;
    Vertices vertices;
    Indices indices;
    Meshlets meshlets;
    Meshes meshes;
    Materials materials;
    Instances instances;
    MeshletRefs meshlet_refs;
    Lights lights;
    Clusters clusters;
    ShadowTiles shadow_tiles;
    Exposure exposure;
    Decals decals;
    CloudRef clouds;
    FluidList fluids;
    ReflectionProbes probes;
};

vec2 materialUvDerivative(Material material, vec2 value) {
    return vec2(dot(material.uv_transform.xy, value), dot(material.uv_transform.zw, value));
}

vec2 materialUv(Material material, vec2 uv) {
    return materialUvDerivative(material, uv) + material.uv_offset;
}

// Texture coordinates for texture number `slot` of a material (see
// `Material.uv_sets` for the numbering). `common_uv` is the mesh's coordinate
// already moved by the material's one transform, which is what nearly
// every material uses; `raw` is the coordinate as authored, for materials
// whose textures each have their own. With `offset` false the value is a
// derivative, which takes no offset.
vec2 textureUv(FrameConstants frame, Material material, uint slot, vec2 common_uv, vec2 raw, bool offset) {
    if ((SHADE_FEATURES & FEATURE_TEXTURE_TRANSFORMS) != 0u && material.texture_transforms != INVALID_ID) {
        MaterialWords words = MaterialWords(frame.materials);
        uint at = material.texture_transforms * MATERIAL_WORDS + slot * 2u;
        vec4 matrix = words.data[at];
        vec2 moved = vec2(dot(matrix.xy, raw), dot(matrix.zw, raw));
        return offset ? moved + words.data[at + 1u].xy : moved;
    }
    return common_uv;
}

// Encodes linear Rec.709 color, given in nits, for an HDR10 display:
// Rec.2020 primaries and the PQ (SMPTE ST 2084) curve.
vec3 hdr10Encode(vec3 nits) {
    const mat3 rec709_to_rec2020 = mat3(
        0.6274, 0.0691, 0.0164,
        0.3293, 0.9195, 0.0880,
        0.0433, 0.0114, 0.8956);
    vec3 y = clamp(rec709_to_rec2020 * nits / 10000.0, 0.0, 1.0);
    vec3 p = pow(y, vec3(0.1593017578125));
    return pow((0.8359375 + 18.8515625 * p) / (1.0 + 18.6875 * p), vec3(78.84375));
}

// Reverse-Z with an infinite far plane: depth = near / distance.
float linearDepth(float depth, float near) {
    return near / max(depth, 1e-9);
}

// Wind (`Material.sway`): how far a point of something that stands on
// its origin is carried from where it would stand still. `world` is the
// point, `origin` where its instance stands. The lean grows with the
// square of the height above the origin, so the foot stays planted, and
// comes in gusts that cross the land, so a field moves in waves rather
// than all at once.
vec3 swayOffset(float sway, vec3 origin, vec3 world, float time) {
    float height = max(world.y - origin.y, 0.0);
    float place = dot(origin.xz, vec2(0.11, 0.07));
    float gust = 0.35 + 0.45 * sin(time * 1.3 + place) + 0.2 * sin(time * 2.7 + place * 2.3 + origin.x * 0.9) + 0.08 * sin(time * 6.1 + origin.z * 3.1 + world.y * 2.0);
    return vec3(0.8, 0.0, 0.6) * (sway * height * height * gust);
}

vec3 worldPositionFromDepth(vec2 uv, float depth, mat4 inv_view_proj) {
    vec4 world = inv_view_proj * vec4(uv * 2.0 - 1.0, depth, 1.0);
    return world.xyz / world.w;
}

// Octahedral normal encoding into [0, 1]^2.
vec2 encodeNormal(vec3 n) {
    n /= abs(n.x) + abs(n.y) + abs(n.z);
    vec2 wrapped = (1.0 - abs(n.yx)) * vec2(n.x >= 0.0 ? 1.0 : -1.0, n.y >= 0.0 ? 1.0 : -1.0);
    vec2 encoded = n.z >= 0.0 ? n.xy : wrapped;
    return encoded * 0.5 + 0.5;
}

vec3 decodeNormal(vec2 encoded) {
    vec2 f = encoded * 2.0 - 1.0;
    vec3 n = vec3(f.x, f.y, 1.0 - abs(f.x) - abs(f.y));
    float t = clamp(-n.z, 0.0, 1.0);
    n.x += n.x >= 0.0 ? -t : t;
    n.y += n.y >= 0.0 ? -t : t;
    return normalize(n);
}

float luminance(vec3 color) {
    return dot(color, vec3(0.2126, 0.7152, 0.0722));
}

// How large an error of a cluster looks from the camera levels of detail
// are chosen for: the error, in the mesh's units, as a multiple of the
// allowed number of pixels, judged at the nearest point of `sphere`
// (center and radius in the mesh's space).
float lodProjected(float error, vec4 sphere, mat4 transform, float scale, vec3 lod_camera, float lod_scale, float near) {
    vec3 center = (transform * vec4(sphere.xyz, 1.0)).xyz;
    return error * scale * lod_scale / max(distance(lod_camera, center) - sphere.w * scale, near);
}

// Jorge Jimenez's interleaved gradient noise in space, stepped through time
// by the golden ratio. Each pixel then sees a low-discrepancy sequence, so
// a temporal average of anything driven by it settles far closer to the
// true value than it would with independent noise per frame.
float interleavedGradientNoise(vec2 pixel, uint frame) {
    float spatial = fract(52.9829189 * fract(0.06711056 * pixel.x + 0.00583715 * pixel.y));
    return fract(spatial + float(frame % 64u) * 0.61803399);
}

#endif
