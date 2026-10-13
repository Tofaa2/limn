#ifndef COMMON_SLANG
#define COMMON_SLANG

[[vk::binding(0, 0)]] Texture2D textures_2d[];
[[vk::binding(0, 0)]] Texture2D<uint4> textures_2d_uint[];
[[vk::binding(0, 0)]] TextureCube textures_cube[];
[[vk::binding(0, 0)]] Texture2DArray textures_2d_array[];
[[vk::binding(1, 0)]] SamplerState samplers[];
[[vk::binding(0, 0)]] Texture3D textures_3d[];
#ifdef STORAGE_IMAGES
[[vk::binding(2, 0)]] [[vk::image_format("unknown")]] RWTexture2D<float4> storage_2d[];
[[vk::binding(3, 0)]] [[vk::image_format("unknown")]] RWTexture3D<float4> storage_3d[];
#endif
[[vk::binding(1, 0)]] SamplerComparisonState samplers_shadow[];

static const float PI = 3.14159265358979;
static const uint INVALID_ID = 0xffffffffu;

static const uint MATERIAL_ALPHA_TEST = 1u;
static const uint MATERIAL_DOUBLE_SIDED = 2u;
static const uint MATERIAL_BLEND = 4u;
static const uint MATERIAL_SPECULAR_GLOSSINESS = 8u;
static const uint MATERIAL_SWAY_WEIGHTS = 16u;
static const uint INSTANCE_SKINNED = 1u;
static const uint INSTANCE_MOVING = 2u;
static const uint INSTANCE_NO_DECALS = 4u;
static const uint INSTANCE_PROXY = 8u;
static const uint INSTANCE_AIMED = 16u;
static const uint INSTANCE_PREVIOUS = 32u;

[[vk::constant_id(0)]] const uint SHADE_FEATURES = 0xffffffffu;

float4 sampleTexture(uint texture, uint sampler, float2 uv) {
    return textures_2d[NonUniformResourceIndex(texture)].Sample(samplers[NonUniformResourceIndex(sampler)], uv);
}

float4 sampleTextureLod(uint texture, uint sampler, float2 uv, float lod) {
    return textures_2d[NonUniformResourceIndex(texture)].SampleLevel(samplers[NonUniformResourceIndex(sampler)], uv, lod);
}

float4 sampleCubeLod(uint texture, uint sampler, float3 direction, float lod) {
    return textures_cube[NonUniformResourceIndex(texture)].SampleLevel(samplers[NonUniformResourceIndex(sampler)], direction, lod);
}

float4 fetchTexel(uint texture, int2 pixel) {
    return textures_2d[NonUniformResourceIndex(texture)].Load(int3(pixel, 0));
}

float2 cubeSize(uint texture) {
    uint width;
    uint height;
    textures_cube[NonUniformResourceIndex(texture)].GetDimensions(width, height);
    return float2(width, height);
}

float2 textureSize(uint texture) {
    uint width;
    uint height;
    textures_2d[NonUniformResourceIndex(texture)].GetDimensions(width, height);
    return float2(width, height);
}

float4 unpackUnorm(uint packed) {
    return float4(float(packed & 0xffu), float((packed >> 8) & 0xffu), float((packed >> 16) & 0xffu), float(packed >> 24)) / 255.0;
}

float2 unpackSnormPair(uint packed) {
    int2 words = int2(int(packed << 16) >> 16, int(packed) >> 16);
    return max(float2(words) / 32767.0, float2(-1.0));
}

uint packSnormPair(float2 value) {
    int2 words = int2(round(clamp(value, -1.0, 1.0) * 32767.0));
    return (uint(words.x) & 0xffffu) | (uint(words.y) << 16);
}

struct Vertex {
    float3 position;
    uint normal;
    uint tangent;
    float2 uv;
    uint color;
    float2 uv1;
};

float3 unpackDirection(uint packed) {
    float2 point = unpackSnormPair(packed);
    float3 direction = float3(point, 1.0 - abs(point.x) - abs(point.y));
    float fold = max(-direction.z, 0.0);
    direction.x += direction.x >= 0.0 ? -fold : fold;
    direction.y += direction.y >= 0.0 ? -fold : fold;
    return normalize(direction);
}

uint packDirection(float3 direction) {
    float2 point = direction.xy / max(abs(direction.x) + abs(direction.y) + abs(direction.z), 1e-20);
    if (direction.z < 0.0) point = (1.0 - abs(point.yx)) * float2(point.x >= 0.0 ? 1.0 : -1.0, point.y >= 0.0 ? 1.0 : -1.0);
    return packSnormPair(point);
}

float3 vertexNormal(Vertex vertex) {
    return unpackDirection(vertex.normal);
}

float4 vertexTangent(Vertex vertex) {
    return float4(unpackDirection(vertex.tangent), (vertex.tangent & 0x10000u) != 0u ? -1.0 : 1.0);
}

struct Mesh {
    float3 center;
    float radius;
    uint index_offset;
    uint meshlet_offset;
    uint meshlet_count;
    uint bvh;
};

struct Material {
    float4 base_color;
    float3 emissive;
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
    float4 params;
    float4 uv_transform;
    float2 uv_offset;
    float clearcoat;
    float clearcoat_roughness;
    float transmission;
    float ior;
    float thickness;
    float3 sheen_color;
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

void specularGlossiness(Material material, float4 packed, inout float3 color, out float roughness, out float metallic) {
    const float dielectric = 0.04;
    float3 specular = material.params.rgb * packed.rgb;
    roughness = 1.0 - material.roughness * packed.a;
    float specular_strength = max(specular.r, max(specular.g, specular.b));
    float diffuse_strength = sqrt(dot(color * color, float3(0.299, 0.587, 0.114)));
    float specular_brightness = sqrt(dot(specular * specular, float3(0.299, 0.587, 0.114)));
    metallic = 0.0;
    if (specular_brightness > dielectric) {
        float b = diffuse_strength * (1.0 - specular_strength) / (1.0 - dielectric) + specular_brightness - 2.0 * dielectric;
        float c = dielectric - specular_brightness;
        metallic = clamp((-b + sqrt(max(b * b - 4.0 * dielectric * c, 0.0))) / (2.0 * dielectric), 0.0, 1.0);
    }
    float3 from_diffuse = color * ((1.0 - specular_strength) / (1.0 - dielectric) / max(1.0 - metallic, 1e-4));
    float3 from_specular = (specular - dielectric * (1.0 - metallic)) / max(metallic, 1e-4);
    color = clamp(lerp(from_diffuse, from_specular, metallic * metallic), 0.0, 1.0);
}

struct Instance {
    float3x4 transform;
    float4 bounding_sphere;
    uint mesh;
    uint material;
    uint vertex_offset;
    uint previous_vertex_offset;
    uint flags;
    uint tint;
    uint bounds_offset;
    float coarse_error;
    uint lightmap;
    float4 params;
};

static const uint LIGHT_SPOT = 1u;
static const uint LIGHT_DIRECTIONAL = 2u;
static const uint LIGHT_RECTANGLE = 4u;
static const uint LIGHT_TRACED_SHADOW = 8u;
static const uint LIGHT_FIRE = 16u;

struct Light {
    float3 position;
    float range;
    float3 color;
    uint flags;
    float3 direction;
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

static const uint FLUID_WALLS_OPEN = 0u;
static const uint FLUID_WALLS_FLOOR = 1u;
static const uint FLUID_WALLS_CLOSED = 2u;

struct FluidSource {
    float3 position;
    float radius;
    float3 velocity;
    float smoke;
    float fuel;
    float temperature;
    float pad0;
    float pad1;
};

struct FluidObstacle {
    float3 a;
    float radius;
    float3 b;
    float pad;
};

struct FluidData {
    float4x4 world_to_box;
    float4x4 box_to_world;
    int3 size;
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
    float3 wind;
    float absorption;
    float3 smoke_color;
    float fire_intensity;
    float3 fire_color;
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

struct FluidRef { FluidData* data; };

struct FluidListData {
    uint count;
    uint pad;
    FluidRef fluids[8];
};

struct CloudData {
    float3 offset;
    float period;
    float3 albedo;
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
    float2 cloud_pad;
    float4 flash;
};

struct Vertices { Vertex* data; };
struct Indices { uint* data; };
struct Meshlets { uint64_t address; };
struct Meshes { Mesh* data; };
struct Materials { Material* data; };
struct Instances { Instance* data; };
struct PreviousTransforms { uint64_t address; };
struct Vsm { uint64_t address; };
struct MeshletRefs { uint64_t address; };
struct Lights { Light* data; };
struct Clusters { uint64_t address; };
struct ShadowTiles { uint64_t address; };
struct Exposure { uint64_t address; };
struct Decals { uint64_t address; };
struct CloudRef { CloudData* data; };
typedef FluidListData* FluidList;
struct ReflectionProbes { uint64_t address; };

#include "frame_constants.slang"

float2 materialUvDerivative(Material material, float2 value) {
    return float2(dot(material.uv_transform.xy, value), dot(material.uv_transform.zw, value));
}

float2 materialUv(Material material, float2 uv) {
    return materialUvDerivative(material, uv) + material.uv_offset;
}

float3x3 normalMatrix(float3x4 transform) {
    float3x3 linear = (float3x3)transform;
    float3 a = cross(linear[1], linear[2]);
    float3 b = cross(linear[2], linear[0]);
    float3 c = cross(linear[0], linear[1]);
    return float3x3(a, b, c) / dot(linear[0], a);
}

float3 matrixColumn(float4x4 m, int column) {
    return float3(m[0][column], m[1][column], m[2][column]);
}

/// The point of the lens that sees `position`: the camera, or in a parallel
/// view the point straight behind `position`.
float3 eyePoint(FrameConstants frame, float3 position) {
    if (frame.parallel == 0.0) return frame.camera_position;
    return position - frame.eye_axis * dot(position - frame.camera_position, frame.eye_axis);
}

/// Distance along the view of a depth, by `FrameConstants.depth_terms`.
float linearDepth(float depth, float4 terms) {
    return (terms.y + terms.x * depth) / max(terms.z * depth + terms.w, 1e-9);
}

/// Distance along the view of a point in clip space.
float clipDepth(FrameConstants frame, float4 clip) {
    return frame.parallel != 0.0 ? linearDepth(clip.z, frame.depth_terms) : clip.w;
}

/// The depth of a point `distance` along the view; `linearDepth` undone.
float depthAt(float distance, float4 terms) {
    return (terms.y - terms.w * distance) / (terms.z * distance - terms.x);
}

float3 worldPositionFromDepth(float2 uv, float depth, float4x4 inv_view_proj) {
    float4 world = mul(inv_view_proj, float4(uv * 2.0 - 1.0, depth, 1.0));
    return world.xyz / world.w;
}

float2 encodeNormal(float3 n) {
    n /= abs(n.x) + abs(n.y) + abs(n.z);
    float2 wrapped = (1.0 - abs(n.yx)) * float2(n.x >= 0.0 ? 1.0 : -1.0, n.y >= 0.0 ? 1.0 : -1.0);
    float2 encoded = n.z >= 0.0 ? n.xy : wrapped;
    return encoded * 0.5 + 0.5;
}

float3 decodeNormal(float2 encoded) {
    float2 f = encoded * 2.0 - 1.0;
    float3 n = float3(f.x, f.y, 1.0 - abs(f.x) - abs(f.y));
    float t = clamp(-n.z, 0.0, 1.0);
    n.x += n.x >= 0.0 ? -t : t;
    n.y += n.y >= 0.0 ? -t : t;
    return normalize(n);
}

float luminance(float3 color) {
    return dot(color, float3(0.2126, 0.7152, 0.0722));
}

float interleavedGradientNoise(float2 pixel, uint frame) {
    float spatial = frac(52.9829189 * frac(0.06711056 * pixel.x + 0.00583715 * pixel.y));
    return frac(spatial + float(frame % 64u) * 0.61803399);
}

float3 srgbToLinear(float3 c) {
    return lerp(c / 12.92, pow((c + 0.055) / 1.055, float3(2.4)), step(float3(0.04045), c));
}

float3 linearToSrgb(float3 c) {
    return lerp(c * 12.92, 1.055 * pow(c, float3(1.0 / 2.4)) - 0.055, step(float3(0.0031308), c));
}

float3 hdr10Encode(float3 nits) {
    float3 rec2020 = float3(
        dot(float3(0.6274, 0.3293, 0.0433), nits),
        dot(float3(0.0691, 0.9195, 0.0114), nits),
        dot(float3(0.0164, 0.0880, 0.8956), nits));
    float3 y = clamp(rec2020 / 10000.0, 0.0, 1.0);
    float3 p = pow(y, float3(0.1593017578125));
    return pow((0.8359375 + 18.8515625 * p) / (1.0 + 18.6875 * p), float3(78.84375));
}

#endif
