#version 460
#ifdef RAY_TRACED
#extension GL_EXT_ray_query : require
#endif
#extension GL_EXT_shader_explicit_arithmetic_types_int64 : require
#include "common.glsl"
#include "brdf.glsl"
#include "ffx_reflections.glsl"

layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    uint64_t scene;
    uint64_t scene_instances;
    uint64_t mesh_nodes;
    uint64_t mesh_items;
    uint gathered;
    uint bounces;
    uint samples;
    float clamp_radiance;
    float sun_radius;
    uint light_count;
    uint64_t glowing;
    uint glowing_count;
    uint history_color;
    uint history_guide;
    uint history_soft;
    uint history_gloss;
    uint moved;
    vec3 previous_camera;
    uint reset;
    uint centered;
    uint history_facing;
    uint history_surface;
} push;

#ifdef RAY_TRACED
uint64_t traceScene() { return push.scene; }
#else
#endif
#include "trace.glsl"
#ifndef RAY_TRACED
BvhNodes traceSceneNodes() { return BvhNodes(push.scene); }
BvhInstances traceSceneInstances() { return BvhInstances(push.scene_instances); }
BvhNodes traceMeshNodes() { return BvhNodes(push.mesh_nodes); }
BvhItems traceMeshItems() { return BvhItems(push.mesh_items); }
FrameConstants traceFrame() { return push.frame; }
#endif

struct Glowing {
    uint instance;
    uint triangles;
};
layout(buffer_reference, scalar) readonly buffer GlowingList { Glowing data[]; };

layout(location = 0) out vec4 out_color;
layout(location = 1) out vec4 out_guide;
layout(location = 2) out vec4 out_soft;
layout(location = 3) out vec4 out_facing;
layout(location = 4) out vec4 out_gloss;
layout(location = 5) out vec4 out_gloss_gathered;
layout(location = 6) out vec4 out_surface;

vec3 first_color;
bool first_met;
float first_distance;
bool first_mirrored;
vec3 first_facing;
bool primary_met;
vec3 primary_facing;
float primary_roughness;
float primary_distance;
bool primary_mirror;
float gloss_reach;
bool split_met;

uint random_state;

uint pcg(uint value) {
    uint state = value * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

float random() {
    random_state = pcg(random_state);
    return float(random_state >> 8) / 16777216.0;
}

struct Surface {
    vec3 position;
    vec3 flat_normal;
    vec3 normal;
    vec3 albedo;
    vec3 emissive;
    bool even_glow;
    float metallic;
    float roughness;
    float through;
};

float detailLevel(uint texture_index, uint sampler_index, float spread) {
    vec2 size = vec2(textureSize(TEX(texture_index, sampler_index), 0));
    return max(log2(spread * max(size.x, size.y)) - 1.0, 0.0);
}

Surface surfaceAt(FrameConstants frame, TraceHit hit, vec3 origin, vec3 direction, float footprint) {
    Surface surface;
    Instance instance = frame.instances.data[hit.instance];
    Mesh mesh = frame.meshes.data[instance.mesh];
    Material material = frame.materials.data[instance.material];
    uint base = mesh.index_offset + hit.primitive * 3u;
    Vertex v0 = frame.vertices.data[instance.vertex_offset + frame.indices.data[base]];
    Vertex v1 = frame.vertices.data[instance.vertex_offset + frame.indices.data[base + 1u]];
    Vertex v2 = frame.vertices.data[instance.vertex_offset + frame.indices.data[base + 2u]];
    vec3 lambda = vec3(1.0 - hit.barycentric.x - hit.barycentric.y, hit.barycentric.x, hit.barycentric.y);

    mat3 normal_matrix = transpose(inverse(mat3(instance.transform)));
    surface.flat_normal = normalize(normal_matrix * cross(v1.position - v0.position, v2.position - v0.position));
    if (dot(surface.flat_normal, direction) > 0.0) surface.flat_normal = -surface.flat_normal;
    surface.normal = normalize(normal_matrix * (vertexNormal(v0) * lambda.x + vertexNormal(v1) * lambda.y + vertexNormal(v2) * lambda.z));
    if (dot(surface.normal, surface.flat_normal) < 0.0) surface.normal = -surface.normal;
    surface.position = origin + direction * hit.t;

    vec2 uv = v0.uv * lambda.x + v1.uv * lambda.y + v2.uv * lambda.z;
    vec2 uvb = v0.uv1 * lambda.x + v1.uv1 * lambda.y + v2.uv1 * lambda.z;
    vec3 world_edge_a = mat3(instance.transform) * (v1.position - v0.position);
    vec3 world_edge_b = mat3(instance.transform) * (v2.position - v0.position);
    vec2 uv_edge_a = v1.uv - v0.uv;
    vec2 uv_edge_b = v2.uv - v0.uv;
    float texture_per_world = sqrt(abs(uv_edge_a.x * uv_edge_b.y - uv_edge_a.y * uv_edge_b.x) / max(length(cross(world_edge_a, world_edge_b)), 1e-12));
    float spread = footprint * texture_per_world;
    vec4 base_color = material.base_color;
    if (material.base_color_texture != INVALID_ID)
        base_color *= textureLod(TEX(material.base_color_texture, material.sampler_index), materialUv(material, (material.uv_sets & 1u) != 0u ? uvb : uv), detailLevel(material.base_color_texture, material.sampler_index, spread));
    base_color *= unpackUnorm4x8(v0.color) * lambda.x + unpackUnorm4x8(v1.color) * lambda.y + unpackUnorm4x8(v2.color) * lambda.z;
    base_color.rgb *= unpackUnorm4x8(instance.tint).rgb;
    surface.albedo = base_color.rgb;
    surface.metallic = material.metallic;
    surface.roughness = material.roughness;
    vec4 packed = vec4(1.0);
    if (material.metallic_roughness_texture != INVALID_ID)
        packed = textureLod(TEX(material.metallic_roughness_texture, material.sampler_index), materialUv(material, uv), detailLevel(material.metallic_roughness_texture, material.sampler_index, spread));
    if ((material.flags & MATERIAL_SPECULAR_GLOSSINESS) != 0u) {
        specularGlossiness(material, packed, surface.albedo, surface.roughness, surface.metallic);
    } else {
        surface.metallic *= packed.b;
        surface.roughness *= packed.g;
    }
    surface.roughness = clamp(surface.roughness, 0.03, 1.0);
    surface.emissive = material.emissive;
    surface.even_glow = (instance.flags & INSTANCE_AIMED) != 0u;
    if (material.emissive_texture != INVALID_ID)
        surface.emissive *= textureLod(TEX(material.emissive_texture, material.sampler_index), materialUv(material, uv), detailLevel(material.emissive_texture, material.sampler_index, spread)).rgb;
    surface.through = 0.0;
    if ((material.flags & MATERIAL_ALPHA_TEST) != 0u && base_color.a < material.alpha_cutoff) surface.through = 1.0;
    else if ((material.flags & MATERIAL_BLEND) != 0u) surface.through = clamp(1.0 - base_color.a * (1.0 - material.transmission), 0.0, 1.0);
    if ((instance.flags & INSTANCE_PROXY) != 0u) surface.through = 1.0;
    return surface;
}

const float mirror_roughness = 0.08;

const float glossy_roughness = FFX_GLOSSY_ROUGHNESS;

const float softened_mirror = 0.3;

const float lit_by_itself = 0.5;

const float moving_steady_weight = 1.0 / 3.0;
const float moving_mirror_weight = 0.5;

bool mirrorLike(Surface surface) {
    return surface.roughness <= mirror_roughness;
}

vec3 surfaceResponse(Surface surface, vec3 view, vec3 light) {
    float n_dot_l = dot(surface.normal, light);
    float n_dot_v = max(dot(surface.normal, view), 1e-4);
    if (n_dot_l <= 0.0) return vec3(0.0);
    vec3 half_vector = normalize(view + light);
    float alpha = surface.roughness * surface.roughness;
    vec3 f0 = mix(vec3(0.04), surface.albedo, surface.metallic);
    vec3 fresnel = fresnelSchlick(max(dot(view, half_vector), 0.0), f0);
    vec3 specular = mirrorLike(surface) ? vec3(0.0) : fresnel * distributionGgx(max(dot(surface.normal, half_vector), 0.0), alpha) * visibilitySmithGgx(n_dot_l, n_dot_v, alpha);
    vec3 diffuse = surface.albedo * (1.0 - surface.metallic) * (1.0 - fresnel) / PI;
    return (diffuse + specular) * n_dot_l;
}

vec3 skyLight(FrameConstants frame, vec3 direction, bool with_sun) {
    if ((frame.flags & FRAME_ENVIRONMENT) == 0u) return vec3(0.0);
    if (!with_sun) {
        const float disc_angle = 0.0175;
        float texel_angle = 1.6 / float(textureSize(TEX_CUBE(frame.env_sky, frame.sampler_linear_clamp), 0).x);
        float kept_clear = disc_angle + 2.5 * texel_angle;
        float toward_sun = dot(direction, frame.sun_direction);
        if (toward_sun > cos(kept_clear)) {
            vec3 away = direction - frame.sun_direction * toward_sun;
            float away_length = length(away);
            away = away_length > 1e-6 ? away / away_length : tangentBasis(frame.sun_direction)[0];
            float beside = kept_clear + texel_angle;
            direction = frame.sun_direction * cos(beside) + away * sin(beside);
        }
    }
    return textureLod(TEX_CUBE(frame.env_sky, frame.sampler_linear_clamp), direction, 0.0).rgb * frame.env_intensity;
}

vec3 lampCandidate(FrameConstants frame, Surface surface, vec3 view, uint light_count, out vec3 toward, out float reach) {
    uint pick = min(uint(random() * float(light_count)), light_count - 1u);
    Light light = frame.lights.data[pick];
    float attenuation = 1.0;
    reach = 1e4;
    if ((light.flags & LIGHT_DIRECTIONAL) != 0u) {
        toward = -light.direction;
    } else {
        vec3 target = light.position;
        if (light.source_radius > 0.0) target += (vec3(random(), random(), random()) * 2.0 - 1.0) * light.source_radius * 0.57;
        vec3 to_light = target - surface.position;
        float distance_squared = dot(to_light, to_light);
        float range_squared = light.range * light.range;
        if (distance_squared >= range_squared) return vec3(0.0);
        float window = clamp(1.0 - (distance_squared * distance_squared) / (range_squared * range_squared), 0.0, 1.0);
        attenuation = window * window / max(distance_squared, 0.01);
        reach = sqrt(distance_squared);
        toward = to_light / max(reach, 1e-5);
        if ((light.flags & LIGHT_SPOT) != 0u) {
            float cone = clamp(dot(-toward, light.direction) * light.cone_scale + light.cone_offset, 0.0, 1.0);
            attenuation *= cone * cone;
        }
        if ((light.flags & LIGHT_RECTANGLE) != 0u) attenuation *= clamp(dot(-toward, light.direction), 0.0, 1.0);
        reach -= 0.004;
    }
    if (attenuation <= 1e-5 || dot(surface.flat_normal, toward) <= 0.0) return vec3(0.0);
    return surfaceResponse(surface, view, toward) * light.color * (attenuation * float(light_count));
}

vec3 glowCandidate(FrameConstants frame, Surface surface, vec3 view, out vec3 toward, out float reach) {
    GlowingList list = GlowingList(push.glowing);
    Glowing chosen = list.data[min(uint(random() * float(push.glowing_count)), push.glowing_count - 1u)];
    uint triangle = min(uint(random() * float(chosen.triangles)), chosen.triangles - 1u);
    Instance instance = frame.instances.data[chosen.instance];
    Mesh mesh = frame.meshes.data[instance.mesh];
    uint base = mesh.index_offset + triangle * 3u;
    vec3 p0 = (instance.transform * vec4(frame.vertices.data[instance.vertex_offset + frame.indices.data[base]].position, 1.0)).xyz;
    vec3 p1 = (instance.transform * vec4(frame.vertices.data[instance.vertex_offset + frame.indices.data[base + 1u]].position, 1.0)).xyz;
    vec3 p2 = (instance.transform * vec4(frame.vertices.data[instance.vertex_offset + frame.indices.data[base + 2u]].position, 1.0)).xyz;
    float side = sqrt(random());
    float along = random();
    vec2 weights = vec2(side * (1.0 - along), side * along);
    vec3 point = p0 + (p1 - p0) * weights.x + (p2 - p0) * weights.y;
    vec3 across = cross(p1 - p0, p2 - p0);
    float area = 0.5 * length(across);
    vec3 to_point = point - surface.position;
    float distance_squared = dot(to_point, to_point);
    if (area <= 0.0 || distance_squared <= 1e-8) return vec3(0.0);
    reach = sqrt(distance_squared);
    toward = to_point / reach;
    reach -= 0.004;
    float facing = abs(dot(across, toward)) / (2.0 * area);
    if (facing <= 1e-4 || dot(surface.flat_normal, toward) <= 0.0) return vec3(0.0);
    Material material = frame.materials.data[instance.material];
    float spread = facing * area / max(distance_squared, 0.01);
    return surfaceResponse(surface, view, toward) * material.emissive * (spread * float(chosen.triangles) * float(push.glowing_count));
}

void considerCandidate(vec3 candidate, vec3 toward, float reach, inout vec3 kept, inout vec3 kept_toward, inout float kept_reach, inout float kept_weight, inout float weight_sum) {
    float weight = luminance(candidate);
    if (weight <= 0.0) return;
    weight_sum += weight;
    if (random() * weight_sum < weight) {
        kept = candidate;
        kept_toward = toward;
        kept_reach = reach;
        kept_weight = weight;
    }
}

const uint lamp_candidates = 2u;
const uint glow_candidates = 3u;

vec3 directLight(FrameConstants frame, Surface surface, vec3 view, out vec3 lamps) {
    vec3 total = vec3(0.0);
    lamps = vec3(0.0);
    vec3 start = surface.position + surface.flat_normal * 0.002;
    if (dot(frame.sun_radiance, vec3(1.0)) > 0.0) {
        mat3 basis = tangentBasis(frame.sun_direction);
        float turn = 2.0 * PI * random();
        float reach = push.sun_radius * sqrt(random());
        vec3 toward = normalize(basis * vec3(cos(turn) * reach, sin(turn) * reach, 1.0));
        vec3 response = surfaceResponse(surface, view, toward);
        if (dot(response, vec3(1.0)) > 0.0 && dot(surface.flat_normal, toward) > 0.0 && !traceAny(start, toward, 1e4))
            total += response * frame.sun_radiance;
    }
    uint light_count = min(frame.light_count, push.light_count);
    if (light_count != 0u) {
        vec3 kept = vec3(0.0);
        vec3 kept_toward = vec3(0.0);
        float kept_reach = 0.0;
        float kept_weight = 0.0;
        float weight_sum = 0.0;
        uint candidates = min(light_count, lamp_candidates);
        for (uint index = 0u; index < candidates; index++) {
            vec3 toward;
            float reach;
            vec3 candidate = lampCandidate(frame, surface, view, light_count, toward, reach);
            considerCandidate(candidate, toward, reach, kept, kept_toward, kept_reach, kept_weight, weight_sum);
        }
        if (kept_weight > 0.0 && !traceAny(start, kept_toward, kept_reach))
            lamps += kept * (weight_sum / (float(candidates) * kept_weight));
    }
    if (push.glowing_count != 0u) {
        vec3 kept = vec3(0.0);
        vec3 kept_toward = vec3(0.0);
        float kept_reach = 0.0;
        float kept_weight = 0.0;
        float weight_sum = 0.0;
        for (uint index = 0u; index < glow_candidates; index++) {
            vec3 toward;
            float reach;
            vec3 candidate = glowCandidate(frame, surface, view, toward, reach);
            considerCandidate(candidate, toward, reach, kept, kept_toward, kept_reach, kept_weight, weight_sum);
        }
        if (kept_weight > 0.0 && !traceAny(start, kept_toward, kept_reach))
            lamps += kept * (weight_sum / (float(glow_candidates) * kept_weight));
    }
    return total;
}

vec3 visibleFacet(vec3 view, float alpha, vec2 xi) {
    vec3 stretched = normalize(vec3(alpha * view.xy, view.z));
    float across = dot(stretched.xy, stretched.xy);
    vec3 side = across > 0.0 ? vec3(-stretched.y, stretched.x, 0.0) * inversesqrt(across) : vec3(1.0, 0.0, 0.0);
    vec3 other = cross(stretched, side);
    float radius = sqrt(xi.x);
    float turn = 2.0 * PI * xi.y;
    float a = radius * cos(turn);
    float b = radius * sin(turn);
    float lean = 0.5 * (1.0 + stretched.z);
    b = (1.0 - lean) * sqrt(max(1.0 - a * a, 0.0)) + lean * b;
    vec3 facet = a * side + b * other + sqrt(max(1.0 - a * a - b * b, 0.0)) * stretched;
    return normalize(vec3(alpha * facet.xy, max(facet.z, 1e-6)));
}

float reflectedShare(float n_dot_l, float n_dot_v, float alpha) {
    float a2 = alpha * alpha;
    float seen_out = sqrt(a2 + (1.0 - a2) * n_dot_l * n_dot_l);
    float seen_in = sqrt(a2 + (1.0 - a2) * n_dot_v * n_dot_v);
    return n_dot_l * (n_dot_v + seen_in) / max(n_dot_v * seen_out + n_dot_l * seen_in, 1e-6);
}

vec3 tracePath(FrameConstants frame, vec3 origin, vec3 direction, bool scattering, out vec3 soft, out vec3 indirect, out vec3 gloss) {
    soft = vec3(0.0);
    indirect = vec3(0.0);
    gloss = vec3(0.0);
    bool glossy_first = false;
    bool awaiting_reach = false;
    float travelled = 0.0;
    bool rough_bounce = false;
    bool split = false;
    bool unaimed = true;
    vec3 gathered = vec3(0.0);
    vec3 carried = vec3(1.0);
    float cone_width = 0.0;
    float cone_angle = 2.0 / (abs(frame.proj[1][1]) * frame.resolution.y);
    for (uint bounce = 0u; bounce <= push.bounces; bounce++) {
        TraceHit hit;
        bool met = traceClosest(origin, direction, 1e5, hit);
        if (awaiting_reach) {
            gloss_reach = met ? hit.t : 1000.0;
            awaiting_reach = false;
        }
        if (!met) {
            vec3 sky = carried * skyLight(frame, direction, unaimed);
            if (glossy_first) gloss += sky;
            else if (!rough_bounce) gathered += sky;
            else indirect += sky;
            break;
        }
        cone_width += cone_angle * hit.t;
        Surface surface = surfaceAt(frame, hit, origin, direction, cone_width);
        travelled += hit.t;
        if (rough_bounce) surface.roughness = max(surface.roughness, softened_mirror);
        if (surface.through > 0.0 && random() < surface.through) {
            origin = surface.position + direction * 0.002;
            continue;
        }
        bool glows = luminance(surface.emissive) > lit_by_itself;
        bool pure_mirror = mirrorLike(surface) && surface.metallic > 0.5 && !glows;
        if (!primary_met) {
            primary_met = true;
            primary_facing = surface.normal;
            primary_roughness = surface.roughness;
            primary_distance = travelled;
            primary_mirror = pure_mirror;
        }
        if (!first_met && !pure_mirror) {
            first_met = true;
            first_distance = travelled;
            first_mirrored = bounce > 0u;
            first_color = glows ? vec3(0.0) : max(surface.albedo, vec3(0.03));
            first_facing = surface.normal;
        }
        if (unaimed || !surface.even_glow) {
            if (glossy_first) gloss += carried * surface.emissive;
            else if (!rough_bounce) gathered += carried * surface.emissive;
            else indirect += carried * surface.emissive;
        }
        if (bounce == push.bounces) break;
        vec3 view = -direction;
        vec3 lamps;
        vec3 sun = carried * directLight(frame, surface, view, lamps);
        lamps *= carried;
        if (glossy_first) gloss += sun + lamps;
        else if (rough_bounce) indirect += sun + lamps;
        else {
            gathered += sun;
            soft += lamps;
        }

        vec3 f0 = mix(vec3(0.04), surface.albedo, surface.metallic);
        float n_dot_v = max(dot(surface.normal, view), 1e-4);
        vec3 fresnel_view = fresnelSchlick(n_dot_v, f0);
        vec3 scattered = surface.albedo * (1.0 - surface.metallic);
        float mirror_share = luminance(scattered) > 1e-4 ? clamp(luminance(fresnel_view) / (luminance(fresnel_view) + luminance(scattered)), 0.1, 0.9) : 1.0;
        if (!rough_bounce && !mirrorLike(surface) && surface.roughness < glossy_roughness) mirror_share = max(mirror_share, 0.5);
        bool reflects;
        if (!split && !rough_bounce && !glossy_first && mirrorLike(surface) && mirror_share < 1.0) {
            split = true;
            split_met = true;
            reflects = !scattering;
            mirror_share = reflects ? 1.0 : 0.0;
            if (scattering) {
                gathered = vec3(0.0);
                soft = vec3(0.0);
                indirect = vec3(0.0);
                gloss = vec3(0.0);
            }
        } else {
            reflects = random() < mirror_share;
        }
        mat3 basis = tangentBasis(surface.normal);
        vec3 next;
        if (reflects) {
            float alpha = surface.roughness * surface.roughness;
            vec3 view_local = view * basis;
            vec3 half_vector = basis * visibleFacet(vec3(view_local.xy, max(view_local.z, 1e-3)), alpha, vec2(random(), random()));
            next = reflect(direction, half_vector);
            float n_dot_l = dot(surface.normal, next);
            if (n_dot_l <= 0.0 || dot(surface.flat_normal, next) <= 0.0) break;
            vec3 fresnel = fresnelSchlick(max(dot(view, half_vector), 1e-4), f0);
            carried *= fresnel * reflectedShare(n_dot_l, n_dot_v, alpha) / mirror_share;
            unaimed = mirrorLike(surface);
            if (!rough_bounce && !glossy_first && (unaimed ? mirror_share < 1.0 : surface.roughness < glossy_roughness)) {
                glossy_first = true;
                awaiting_reach = true;
            }
            if (!unaimed) rough_bounce = true;
        } else {
            float turn = 2.0 * PI * random();
            float radius = sqrt(random());
            next = normalize(basis * vec3(cos(turn) * radius, sin(turn) * radius, sqrt(max(1.0 - radius * radius, 0.0))));
            if (dot(surface.flat_normal, next) <= 0.0) break;
            carried *= scattered * (1.0 - fresnel_view) / (1.0 - mirror_share);
            unaimed = false;
            rough_bounce = true;
        }
        cone_angle = max(cone_angle, unaimed ? cone_angle : 0.05 + 0.25 * surface.roughness);
        if (bounce >= 2u) {
            float keep = clamp(max(carried.r, max(carried.g, carried.b)), 0.05, 1.0);
            if (random() > keep) break;
            carried /= keep;
        }
        origin = surface.position + surface.flat_normal * 0.002;
        direction = next;
    }
    return gathered;
}

vec3 historySharp(uint texture_index, uint sampler_index, vec2 uv, vec2 size) {
    vec2 place = uv * size;
    vec2 base = floor(place - 0.5) + 0.5;
    vec2 f = place - base;
    vec2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
    vec2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
    vec2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
    vec2 w3 = f * f * (-0.5 + 0.5 * f);
    vec2 w12 = w1 + w2;
    vec2 near = (base + w2 / w12) / size;
    vec2 before = (base - 1.0) / size;
    vec2 after = (base + 2.0) / size;
    vec3 total = textureLod(TEX(texture_index, sampler_index), vec2(near.x, before.y), 0.0).rgb * (w12.x * w0.y);
    total += textureLod(TEX(texture_index, sampler_index), vec2(before.x, near.y), 0.0).rgb * (w0.x * w12.y);
    total += textureLod(TEX(texture_index, sampler_index), vec2(near.x, near.y), 0.0).rgb * (w12.x * w12.y);
    total += textureLod(TEX(texture_index, sampler_index), vec2(after.x, near.y), 0.0).rgb * (w3.x * w12.y);
    total += textureLod(TEX(texture_index, sampler_index), vec2(near.x, after.y), 0.0).rgb * (w12.x * w3.y);
    float weight = w12.x * w0.y + w0.x * w12.y + w12.x * w12.y + w3.x * w12.y + w12.x * w3.y;
    ivec2 corner = ivec2(base - 0.5);
    ivec2 last = ivec2(size) - 1;
    vec3 a = texelFetch(TEX(texture_index, sampler_index), clamp(corner, ivec2(0), last), 0).rgb;
    vec3 b = texelFetch(TEX(texture_index, sampler_index), clamp(corner + ivec2(1, 0), ivec2(0), last), 0).rgb;
    vec3 c = texelFetch(TEX(texture_index, sampler_index), clamp(corner + ivec2(0, 1), ivec2(0), last), 0).rgb;
    vec3 d = texelFetch(TEX(texture_index, sampler_index), clamp(corner + ivec2(1, 1), ivec2(0), last), 0).rgb;
    return clamp(total / weight, min(min(a, b), min(c, d)), max(max(a, b), max(c, d)));
}

void main() {
    FrameConstants frame = push.frame;
    ivec2 pixel = ivec2(gl_FragCoord.xy);
    random_state = pcg(uint(pixel.x) + pcg(uint(pixel.y) + pcg(push.gathered * 7919u + frame.frame_index)));
    vec3 total = vec3(0.0);
    vec3 total_soft = vec3(0.0);
    vec3 total_gloss = vec3(0.0);
    vec3 guide = vec3(0.0);
    uint samples = max(push.samples, 1u);
    for (uint index = 0u; index < samples; index++) {
        vec2 uv = (vec2(pixel) + (push.centered != 0u ? vec2(0.5) : vec2(random(), random()))) * frame.inv_resolution;
        vec3 through = worldPositionFromDepth(uv, 0.5, frame.inv_view_proj);
        vec3 direction = normalize(through - frame.camera_position);
        first_met = false;
        first_distance = 60000.0;
        first_mirrored = false;
        first_color = vec3(0.0);
        first_facing = vec3(0.0, 1.0, 0.0);
        primary_met = false;
        primary_facing = vec3(0.0, 1.0, 0.0);
        primary_roughness = 1.0;
        primary_distance = 60000.0;
        primary_mirror = false;
        gloss_reach = 0.0;
        vec3 soft;
        vec3 indirect;
        vec3 gloss;
        split_met = false;
        vec3 light = tracePath(frame, frame.camera_position, direction, false, soft, indirect, gloss);
        if (split_met) {
            split_met = false;
            vec3 scattered_soft;
            vec3 scattered_indirect;
            vec3 scattered_gloss;
            vec3 scattered_light = tracePath(frame, frame.camera_position, direction, true, scattered_soft, scattered_indirect, scattered_gloss);
            if (split_met) {
                light += scattered_light;
                soft += scattered_soft;
                indirect += scattered_indirect;
                gloss += scattered_gloss;
            }
        }
        if (any(isnan(light)) || any(isinf(light))) light = vec3(0.0);
        if (any(isnan(soft)) || any(isinf(soft))) soft = vec3(0.0);
        if (any(isnan(indirect)) || any(isinf(indirect))) indirect = vec3(0.0);
        if (any(isnan(gloss)) || any(isinf(gloss))) gloss = vec3(0.0);
        float gloss_brightness = luminance(gloss);
        if (gloss_brightness > push.clamp_radiance) gloss *= push.clamp_radiance / gloss_brightness;
        float brightness = luminance(indirect);
        if (brightness > push.clamp_radiance) indirect *= push.clamp_radiance / brightness;
        total += light;
        total_soft += (soft + indirect) / (dot(first_color, vec3(1.0)) > 0.0 ? first_color : vec3(1.0));
        total_gloss += gloss;
        guide += first_color;
    }
    vec3 light = total / float(samples);
    vec3 grainy = total_soft / float(samples);
    vec3 shown = guide / float(samples);
    float count = 0.0;
    vec3 light_before = vec3(0.0);
    vec4 grainy_before = vec4(0.0);
    vec3 shown_before = vec3(0.0);
    vec4 facing_before = vec4(0.0);
    if (push.reset == 0u) {
        if (push.moved == 0u) {
            vec4 before = texelFetch(TEX(push.history_color, frame.sampler_nearest_clamp), pixel, 0);
            count = before.a;
            light_before = before.rgb;
            grainy_before = texelFetch(TEX(push.history_soft, frame.sampler_nearest_clamp), pixel, 0);
            shown_before = texelFetch(TEX(push.history_guide, frame.sampler_nearest_clamp), pixel, 0).rgb;
            facing_before = texelFetch(TEX(push.history_facing, frame.sampler_nearest_clamp), pixel, 0);
        } else {
            vec2 center = (vec2(pixel) + 0.5) * frame.inv_resolution;
            vec3 toward = normalize(worldPositionFromDepth(center, 0.5, frame.inv_view_proj) - frame.camera_position);
            vec3 point = frame.camera_position + toward * first_distance;
            vec4 clip = frame.prev_view_proj_unjittered * vec4(point, 1.0);
            vec2 was_at = clip.xy / clip.w * 0.5 + 0.5 + frame.prev_jitter;
            if (clip.w > 0.0 && all(greaterThan(was_at, vec2(0.0))) && all(lessThan(was_at, vec2(1.0)))) {
                vec4 guide_before = textureLod(TEX(push.history_guide, frame.sampler_linear_clamp), was_at, 0.0);
                float expected = distance(push.previous_camera, point);
                bool was_mirrored = guide_before.a < 0.0;
                vec3 unlike = abs(guide_before.rgb - shown);
                if (was_mirrored == first_mirrored && abs(abs(guide_before.a) - expected) <= 0.03 * expected + 0.02 && max(unlike.r, max(unlike.g, unlike.b)) < 0.2) {
                    count = textureLod(TEX(push.history_color, frame.sampler_linear_clamp), was_at, 0.0).a;
                    light_before = historySharp(push.history_color, frame.sampler_linear_clamp, was_at, frame.resolution);
                    grainy_before = textureLod(TEX(push.history_soft, frame.sampler_linear_clamp), was_at, 0.0);
                    shown_before = guide_before.rgb;
                    facing_before = textureLod(TEX(push.history_facing, frame.sampler_linear_clamp), was_at, 0.0);
                }
            }
            count = min(count, dot(shown, vec3(1.0)) > 0.0 && !first_mirrored ? 64.0 : 6.0);
        }
    }
    if (any(isnan(light_before)) || any(isinf(light_before)) || any(isnan(grainy_before)) || any(isinf(grainy_before)) || any(isnan(shown_before)) || any(isinf(shown_before)) || any(isnan(facing_before)) || any(isinf(facing_before)) || isnan(count) || isinf(count)) {
        count = 0.0;
        light_before = vec3(0.0);
        grainy_before = vec4(0.0);
        shown_before = vec3(0.0);
        facing_before = vec4(0.0);
    }
    if (any(isnan(shown)) || any(isinf(shown))) shown = vec3(0.0);
    if (isnan(first_distance) || isinf(first_distance)) first_distance = 60000.0;
    count = min(count, 8192.0);
    float weight = 1.0 / (count + 1.0);
    float steady_weight = push.moved != 0u ? max(weight, primary_mirror ? moving_mirror_weight : moving_steady_weight) : weight;
    out_color = vec4(mix(light_before, light, steady_weight), count + 1.0);
    float brightness = min(luminance(grainy), 240.0);
    out_soft = mix(grainy_before, vec4(grainy, brightness * brightness), weight);
    float shown_weight = push.moved != 0u ? max(weight, 0.7) : weight;
    float shown_distance = min(first_distance, 60000.0);
    out_facing = mix(facing_before, vec4(first_facing, first_mirrored ? -shown_distance : shown_distance), shown_weight);
    vec4 surface_now = vec4(unpackSnorm2x16(packDirection(primary_facing)), primary_roughness, min(primary_distance, 60000.0));
    vec4 surface_before = push.reset == 0u && push.moved == 0u ? texelFetch(TEX(push.history_surface, frame.sampler_nearest_clamp), pixel, 0) : surface_now;
    if (any(isnan(surface_before)) || any(isinf(surface_before))) surface_before = surface_now;
    out_surface = mix(surface_before, surface_now, weight);
    vec3 gloss_now = min(total_gloss / float(samples), vec3(60000.0));
    vec4 gloss_before = push.reset == 0u && push.moved == 0u ? texelFetch(TEX(push.history_gloss, frame.sampler_nearest_clamp), pixel, 0) : vec4(0.0);
    if (any(isnan(gloss_before)) || any(isinf(gloss_before))) gloss_before = vec4(0.0);
    out_gloss_gathered = vec4(mix(gloss_before.rgb, gloss_now, 1.0 / (gloss_before.a + 1.0)), min(gloss_before.a + 1.0, 8192.0));
    out_gloss = vec4(out_gloss_gathered.rgb, gloss_reach);
    out_guide = vec4(mix(shown_before, shown, shown_weight), first_mirrored ? -shown_distance : shown_distance);
}
