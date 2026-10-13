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
layout(set = 0, binding = 0) uniform texture3D textures_3d[];
#ifdef STORAGE_IMAGES
#extension GL_EXT_shader_image_load_formatted : require
layout(set = 0, binding = 2) uniform image2D storage_2d[];
layout(set = 0, binding = 3) uniform image3D storage_3d[];
#define STORAGE(index) storage_2d[index]
#define STORAGE_3D(index) storage_3d[index]
#endif
layout(set = 0, binding = 1) uniform samplerShadow samplers_shadow[];

#define TEX(texture_index, sampler_index) sampler2D(textures_2d[nonuniformEXT(texture_index)], samplers[nonuniformEXT(sampler_index)])
#define TEX_UINT(texture_index, sampler_index) usampler2D(textures_2d_uint[nonuniformEXT(texture_index)], samplers[nonuniformEXT(sampler_index)])
#define TEX_3D(texture_index, sampler_index) sampler3D(textures_3d[nonuniformEXT(texture_index)], samplers[nonuniformEXT(sampler_index)])
#define TEX_CUBE(texture_index, sampler_index) samplerCube(textures_cube[nonuniformEXT(texture_index)], samplers[nonuniformEXT(sampler_index)])

const float PI = 3.14159265358979;
const uint INVALID_ID = 0xffffffffu;

const uint MATERIAL_ALPHA_TEST = 1u;
const uint MATERIAL_DOUBLE_SIDED = 2u;
const uint INSTANCE_SKINNED = 1u;
const uint INSTANCE_MOVING = 2u;
const uint INSTANCE_NO_DECALS = 4u;
const uint INSTANCE_PROXY = 8u;
const uint INSTANCE_AIMED = 16u;
const uint INSTANCE_PREVIOUS = 32u;

layout(constant_id = 0) const uint SHADE_FEATURES = 0xffffffffu;
const uint MATERIAL_BLEND = 4u;
const uint MATERIAL_SPECULAR_GLOSSINESS = 8u;
const uint MATERIAL_SWAY_WEIGHTS = 16u;

struct Vertex {
    vec3 position;
    uint normal;
    uint tangent;
    vec2 uv;
    uint color;
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
    float lod_error;
    float parent_error;
    vec4 self_sphere;
    vec4 parent_sphere;
};

struct Mesh {
    vec3 center;
    float radius;
    uint index_offset;
    uint meshlet_offset;
    uint meshlet_count;
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
    uint shader;
    vec4 params;
    vec4 uv_transform;
    vec2 uv_offset;
    float clearcoat;
    float clearcoat_roughness;
    float transmission;
    float ior;
    float thickness;
    vec3 sheen_color;
    float sheen_roughness;
    float anisotropy;
    float anisotropy_rotation;
    uint uv_sets;
    float subsurface;
    uint clearcoat_texture;
    uint clearcoat_roughness_texture;
    uint clearcoat_normal_texture;
    uint sheen_color_texture;
    uint sheen_roughness_texture;
    float clearcoat_normal_scale;
    uint texture_transforms;
    float sway;
};

void specularGlossiness(Material material, vec4 packed, inout vec3 color, out float roughness, out float metallic) {
    const float dielectric = 0.04;
    vec3 specular = material.params.rgb * packed.rgb;
    roughness = 1.0 - material.roughness * packed.a;
    float specular_strength = max(specular.r, max(specular.g, specular.b));
    float diffuse_strength = sqrt(dot(color * color, vec3(0.299, 0.587, 0.114)));
    float specular_brightness = sqrt(dot(specular * specular, vec3(0.299, 0.587, 0.114)));
    metallic = 0.0;
    if (specular_brightness > dielectric) {
        float b = diffuse_strength * (1.0 - specular_strength) / (1.0 - dielectric) + specular_brightness - 2.0 * dielectric;
        float c = dielectric - specular_brightness;
        metallic = clamp((-b + sqrt(max(b * b - 4.0 * dielectric * c, 0.0))) / (2.0 * dielectric), 0.0, 1.0);
    }
    vec3 from_diffuse = color * ((1.0 - specular_strength) / (1.0 - dielectric) / max(1.0 - metallic, 1e-4));
    vec3 from_specular = (specular - dielectric * (1.0 - metallic)) / max(metallic, 1e-4);
    color = clamp(mix(from_diffuse, from_specular, metallic * metallic), 0.0, 1.0);
}

struct Instance {
    mat4x3 transform;
    vec4 bounding_sphere;
    uint mesh;
    uint material;
    uint vertex_offset;
    uint previous_vertex_offset;
    uint flags;
    uint tint;
    uint bounds_offset;
    float coarse_error;
    uint lightmap;
    vec4 params;
};

struct MeshletRef {
    uint instance;
    uint meshlet;
};

const uint LIGHT_SPOT = 1u;
const uint LIGHT_DIRECTIONAL = 2u;
const uint LIGHT_RECTANGLE = 4u;
const uint LIGHT_TRACED_SHADOW = 8u;
const uint LIGHT_FIRE = 16u;

struct Light {
    vec3 position;
    float range;
    vec3 color;
    uint flags;
    vec3 direction;
    float cone_scale;
    float cone_offset;
    float source_radius;
    uint cookie;
    uint profile;
    float source_length;
    float source_height;
    uint light_pad1;
    uint light_pad2;
};

struct ShadowTile {
    mat4 view_proj;
    vec4 rect;
};

const uint CLUSTERS_X = 16u;
const uint CLUSTERS_Y = 9u;
const uint CLUSTERS_Z = 24u;
const uint CLUSTER_CAPACITY = 127u;
const uint CLUSTER_DECAL_WORDS = 8u;

struct Cluster {
    uint count;
    uint lights[CLUSTER_CAPACITY];
    uint decals[CLUSTER_DECAL_WORDS];
};

layout(buffer_reference, scalar) readonly buffer Vertices { Vertex data[]; };
layout(buffer_reference, scalar) readonly buffer Indices { uint data[]; };
layout(buffer_reference, scalar) readonly buffer Meshlets { Meshlet data[]; };
layout(buffer_reference, scalar) readonly buffer Meshes { Mesh data[]; };
layout(buffer_reference, scalar) readonly buffer Materials { Material data[]; };
layout(buffer_reference, scalar) readonly buffer MaterialWords { vec4 data[]; };
const uint MATERIAL_WORDS = 13u;
layout(buffer_reference, scalar) readonly buffer Instances { Instance data[]; };
layout(buffer_reference, scalar) readonly buffer PreviousTransforms { mat4x3 data[]; };
layout(buffer_reference, scalar) readonly buffer MeshletRefs { MeshletRef data[]; };
layout(buffer_reference, scalar) readonly buffer Lights { Light data[]; };
layout(buffer_reference, scalar) readonly buffer ShadowTiles { ShadowTile data[]; };

struct Decal {
    mat4 world_to_decal;
    vec4 color;
    uint image;
    float angle_fade;
    float emissive;
    float roughness;
    uint normal_image;
    float normal_strength;
    uint decal_pad0;
    uint decal_pad1;
    vec4 bounds;
};
layout(buffer_reference, scalar) readonly buffer Decals { Decal data[]; };

struct ReflectionProbeData {
    vec3 center;
    uint specular;
    vec3 extent;
    float fade;
    float intensity;
    uint irradiance;
    vec2 probe_pad;
};
layout(buffer_reference, scalar) readonly buffer ReflectionProbes { ReflectionProbeData data[]; };
layout(buffer_reference, scalar) buffer Clusters { Cluster data[]; };
layout(buffer_reference, scalar) buffer Exposure {
    float exposure;
    float average_luminance;
    float focus;
    float exposure_pad;
};

struct CloudData {
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
    float cirrus;
    float anvil;
    vec2 cloud_pad;
    vec4 flash;
};

layout(buffer_reference, scalar) readonly buffer CloudRef { CloudData data; };
const uint FLUID_WALLS_OPEN = 0u;
const uint FLUID_WALLS_FLOOR = 1u;
const uint FLUID_WALLS_CLOSED = 2u;

struct FluidSource {
    vec3 position;
    float radius;
    vec3 velocity;
    float smoke;
    float fuel;
    float temperature;
    float pad0;
    float pad1;
};

struct FluidObstacle {
    vec3 a;
    float radius;
    vec3 b;
    float pad;
};

struct FluidData {
    mat4 world_to_box;
    mat4 box_to_world;
    ivec3 size;
    int tiles_x;
    float dt;
    float buoyancy;
    float weight;
    float vorticity;
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
    uint solid_mask;
};

layout(buffer_reference, scalar) readonly buffer FluidRef { FluidData data; };

layout(buffer_reference, scalar) readonly buffer FluidList {
    uint count;
    uint pad;
    FluidRef fluids[8];
};

layout(buffer_reference) buffer Vsm;

#include "frame_constants.glsl"

mat4x3 previousTransform(FrameConstants frame, Instance instance, uint index) {
    if ((instance.flags & INSTANCE_PREVIOUS) != 0u) return frame.previous_transforms.data[index];
    return instance.transform;
}

vec2 materialUvDerivative(Material material, vec2 value) {
    return vec2(dot(material.uv_transform.xy, value), dot(material.uv_transform.zw, value));
}

vec2 materialUv(Material material, vec2 uv) {
    return materialUvDerivative(material, uv) + material.uv_offset;
}

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

vec3 hdr10Encode(vec3 nits) {
    const mat3 rec709_to_rec2020 = mat3(
        0.6274, 0.0691, 0.0164,
        0.3293, 0.9195, 0.0880,
        0.0433, 0.0114, 0.8956);
    vec3 y = clamp(rec709_to_rec2020 * nits / 10000.0, 0.0, 1.0);
    vec3 p = pow(y, vec3(0.1593017578125));
    return pow((0.8359375 + 18.8515625 * p) / (1.0 + 18.6875 * p), vec3(78.84375));
}

/// The point of the lens that sees `position`: the camera, or in a parallel
/// view the point straight behind `position`.
vec3 eyePoint(FrameConstants frame, vec3 position) {
    if (frame.parallel == 0.0) return frame.camera_position;
    return position - frame.eye_axis * dot(position - frame.camera_position, frame.eye_axis);
}

/// Distance along the view of a depth, by `FrameConstants.depth_terms`.
float linearDepth(float depth, vec4 terms) {
    return (terms.y + terms.x * depth) / max(terms.z * depth + terms.w, 1e-9);
}

/// Distance along the view of a point in clip space.
float clipDepth(FrameConstants frame, vec4 clip) {
    return frame.parallel != 0.0 ? linearDepth(clip.z, frame.depth_terms) : clip.w;
}

/// The depth of a point `distance` along the view; `linearDepth` undone.
float depthAt(float distance, vec4 terms) {
    return (terms.y - terms.w * distance) / (terms.z * distance - terms.x);
}

vec3 swayOffset(float sway, uint flags, vec3 origin, vec3 world, vec2 weights, float time) {
    if ((flags & MATERIAL_SWAY_WEIGHTS) != 0u) {
        if (weights == vec2(0.0)) return vec3(0.0);
        float place = dot(world.xz, vec2(0.37, 0.23));
        float gust = 0.35 + 0.45 * sin(time * 1.3 + place) + 0.2 * sin(time * 2.7 + place * 2.3);
        vec3 flutter = vec3(
            sin(time * 2.3 + world.x * 1.9 + world.y * 1.3),
            0.5 * sin(time * 1.9 + world.z * 2.3 + world.x * 0.7),
            sin(time * 2.9 + world.z * 1.7 + world.y * 1.1));
        return sway * (vec3(0.8, 0.0, 0.6) * (weights.x * gust) + flutter * weights.y);
    }
    float height = max(world.y - origin.y, 0.0);
    float place = dot(origin.xz, vec2(0.11, 0.07));
    float gust = 0.35 + 0.45 * sin(time * 1.3 + place) + 0.2 * sin(time * 2.7 + place * 2.3 + origin.x * 0.9) + 0.08 * sin(time * 6.1 + origin.z * 3.1 + world.y * 2.0);
    return vec3(0.8, 0.0, 0.6) * (sway * height * height * gust);
}

vec3 worldPositionFromDepth(vec2 uv, float depth, mat4 inv_view_proj) {
    vec4 world = inv_view_proj * vec4(uv * 2.0 - 1.0, depth, 1.0);
    return world.xyz / world.w;
}

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

float lodProjected(float error, vec4 sphere, mat4x3 transform, float scale, vec3 lod_camera, float lod_scale, float near) {
    vec3 center = transform * vec4(sphere.xyz, 1.0);
    return error * scale * lod_scale / max(distance(lod_camera, center) - sphere.w * scale, near);
}

float interleavedGradientNoise(vec2 pixel, uint frame) {
    float spatial = fract(52.9829189 * fract(0.06711056 * pixel.x + 0.00583715 * pixel.y));
    return fract(spatial + float(frame % 64u) * 0.61803399);
}

#endif
