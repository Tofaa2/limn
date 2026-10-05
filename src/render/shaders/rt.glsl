// Ray queries against the scene's acceleration structure, with a simple
// shading of what a ray hits: emission, sun light (shadowed by a second
// ray) and probe light. Shared by the probe tracer and the reflection
// pass. The includer enables GL_EXT_ray_query and 64-bit integers.
#ifndef RT_GLSL
#define RT_GLSL
#include "gi.glsl"
#include "fluid.glsl"

const int RT_MISS = 0;
const int RT_HIT = 1;
// Which instances a ray can meet: solid ones only, or see-through ones
// as well (only rays that draw a picture want those).
const uint RT_SOLID = 0x01u;
const uint RT_ALL = 0x03u;
// The ray ran into the back of a single-sided surface.
const int RT_BACK = 2;

bool rtOccluded(uint64_t tlas, vec3 origin, vec3 direction, float max_distance) {
    rayQueryEXT query;
    rayQueryInitializeEXT(query, accelerationStructureEXT(tlas), gl_RayFlagsOpaqueEXT | gl_RayFlagsTerminateOnFirstHitEXT, RT_SOLID, origin, 0.0, direction, max_distance);
    while (rayQueryProceedEXT(query)) {}
    return rayQueryGetIntersectionTypeEXT(query, true) != gl_RayQueryCommittedIntersectionNoneEXT;
}

// Follows one ray. Returns what kind of thing it met, the light coming
// back along it in `radiance` (nothing on a miss) and how far it went in
// `distance_hit`. `lod` picks how blurry the hit's textures are read.
int rtTraceMasked(FrameConstants frame, uint64_t tlas, vec3 origin, vec3 direction, float max_distance, float lod, bool probe_light, uint mask, out vec3 radiance, out float distance_hit, out float opacity) {
    opacity = 1.0;
    radiance = vec3(0.0);
    distance_hit = max_distance;
    rayQueryEXT query;
    rayQueryInitializeEXT(query, accelerationStructureEXT(tlas), gl_RayFlagsOpaqueEXT, mask, origin, 0.0, direction, max_distance);
    while (rayQueryProceedEXT(query)) {}
    if (rayQueryGetIntersectionTypeEXT(query, true) == gl_RayQueryCommittedIntersectionNoneEXT) return RT_MISS;

    float t = rayQueryGetIntersectionTEXT(query, true);
    distance_hit = t;
    uint instance_index = uint(rayQueryGetIntersectionInstanceCustomIndexEXT(query, true));
    uint primitive = uint(rayQueryGetIntersectionPrimitiveIndexEXT(query, true));
    vec2 barycentric = rayQueryGetIntersectionBarycentricsEXT(query, true);
    vec3 lambda = vec3(1.0 - barycentric.x - barycentric.y, barycentric.x, barycentric.y);

    Instance instance = frame.instances.data[instance_index];
    Mesh mesh = frame.meshes.data[instance.mesh];
    Material material = frame.materials.data[instance.material];
    uint base = mesh.index_offset + primitive * 3u;
    Vertex v0 = frame.vertices.data[instance.vertex_offset + frame.indices.data[base]];
    Vertex v1 = frame.vertices.data[instance.vertex_offset + frame.indices.data[base + 1u]];
    Vertex v2 = frame.vertices.data[instance.vertex_offset + frame.indices.data[base + 2u]];

    mat3 normal_matrix = transpose(inverse(mat3(instance.transform)));
    vec3 geometric_normal = normalize(normal_matrix * cross(v1.position - v0.position, v2.position - v0.position));
    bool back_face = dot(geometric_normal, direction) > 0.0;
    if (back_face && (material.flags & MATERIAL_DOUBLE_SIDED) == 0u) return RT_BACK;
    vec3 normal = normalize(normal_matrix * (v0.normal * lambda.x + v1.normal * lambda.y + v2.normal * lambda.z));
    if (dot(normal, direction) > 0.0) normal = -normal;
    vec2 uv = v0.uv * lambda.x + v1.uv * lambda.y + v2.uv * lambda.z;
    vec2 uvb = v0.uv1 * lambda.x + v1.uv1 * lambda.y + v2.uv1 * lambda.z;

    vec4 base_color = material.base_color;
    if (material.base_color_texture != INVALID_ID)
        base_color *= textureLod(TEX(material.base_color_texture, material.sampler_index), materialUv(material, (material.uv_sets & 1u) != 0u ? uvb : uv), lod);
    // Metalness usually lives in a texture with the factor left at 1.
    float metallic = material.metallic;
    if (material.metallic_roughness_texture != INVALID_ID)
        metallic *= textureLod(TEX(material.metallic_roughness_texture, material.sampler_index), materialUv(material, uv), lod).b;
    // Metals have no diffuse term; let them bounce a little light anyway,
    // since their specular reflection is not traced.
    base_color *= unpackUnorm4x8(v0.color) * lambda.x + unpackUnorm4x8(v1.color) * lambda.y + unpackUnorm4x8(v2.color) * lambda.z;
    base_color.rgb *= unpackUnorm4x8(instance.tint).rgb;
    // How much of what is behind a see-through surface it hides.
    if ((material.flags & MATERIAL_BLEND) != 0u) opacity = clamp(base_color.a * (1.0 - material.transmission * 0.85), 0.0, 1.0);
    vec3 albedo = base_color.rgb * (1.0 - 0.7 * metallic);
    vec3 emissive = material.emissive;
    if (material.emissive_texture != INVALID_ID)
        emissive *= textureLod(TEX(material.emissive_texture, material.sampler_index), uv, lod).rgb;

    vec3 position = origin + direction * t;
    radiance = emissive;
    float n_dot_l = dot(normal, frame.sun_direction);
    if (n_dot_l > 0.0 && dot(frame.sun_radiance, vec3(1.0)) > 0.0) {
        if (!rtOccluded(tlas, position + normal * 0.02, frame.sun_direction, 1e4))
            radiance += albedo / PI * frame.sun_radiance * n_dot_l;
    }
    // Local lights, each tested with a ray of its own. Point-like: the
    // size and shape of the source do not matter for a bounce.
    if ((frame.flags & FRAME_GI_LOCAL_LIGHTS) != 0u) {
        // How many of the scene's lights bounce is a setting, carried in
        // ten bits of the flags.
        uint light_count = min(frame.light_count, max((frame.flags >> 20) & 1023u, 1u));
        for (uint i = 0u; i < light_count; i++) {
            Light light = frame.lights.data[i];
            vec3 to_light = light.position - position;
            vec3 l;
            float attenuation = 1.0;
            float reach = 1e4;
            vec3 tint = vec3(1.0);
            if ((light.flags & LIGHT_DIRECTIONAL) != 0u) {
                l = -light.direction;
            } else {
                float distance_squared = dot(to_light, to_light);
                float range_squared = light.range * light.range;
                if (distance_squared > range_squared) continue;
                float window = clamp(1.0 - (distance_squared * distance_squared) / (range_squared * range_squared), 0.0, 1.0);
                attenuation = window * window / max(distance_squared, 0.01);
                reach = sqrt(distance_squared);
                l = to_light / max(reach, 1e-5);
                if ((light.flags & LIGHT_SPOT) != 0u) {
                    float cos_angle = dot(-l, light.direction);
                    float cone = clamp(cos_angle * light.cone_scale + light.cone_offset, 0.0, 1.0);
                    attenuation *= cone * cone;
                    if (light.cookie != INVALID_ID && attenuation > 0.0) {
                        // The projected image colors the bounce as it does
                        // the surface (see localLights in shading.glsl).
                        vec3 axis = light.direction;
                        vec3 side = normalize(abs(axis.y) < 0.99 ? cross(axis, vec3(0.0, 1.0, 0.0)) : cross(axis, vec3(1.0, 0.0, 0.0)));
                        vec3 up = cross(side, axis);
                        float cos_outer = -light.cone_offset / max(light.cone_scale, 1e-5);
                        float tan_outer = sqrt(max(1.0 - cos_outer * cos_outer, 0.0)) / max(cos_outer, 1e-3);
                        vec2 slide = vec2(dot(-l, side), dot(-l, up)) / max(cos_angle, 1e-3) / max(tan_outer, 1e-3);
                        tint = textureLod(TEX(light.cookie, frame.sampler_linear_clamp), slide * 0.5 + 0.5, 0.0).rgb;
                    }
                }
                // Brightness by angle from the light's axis.
                if (light.profile != INVALID_ID)
                    attenuation *= textureLod(TEX(light.profile, frame.sampler_linear_clamp), vec2(acos(clamp(dot(-l, light.direction), -1.0, 1.0)) / PI, 0.5), 0.0).r;
                if ((light.flags & LIGHT_RECTANGLE) != 0u) attenuation *= clamp(dot(-l, light.direction), 0.0, 1.0);
            }
            float facing = dot(normal, l);
            if (facing <= 0.0 || attenuation <= 1e-5) continue;
            if (rtOccluded(tlas, position + normal * 0.02, l, reach - 0.04)) continue;
            radiance += albedo / PI * light.color * tint * (attenuation * facing);
        }
    }
    if (probe_light && giCoverage(frame, position) > 0.0)
        radiance += albedo * giIrradiance(frame, position, normal, -direction);
    return RT_HIT;
}

// Follows one ray past solid things only, as probes and shadows see the
// scene.
int rtTrace(FrameConstants frame, uint64_t tlas, vec3 origin, vec3 direction, float max_distance, float lod, bool probe_light, out vec3 radiance, out float distance_hit) {
    float opacity;
    return rtTraceMasked(frame, tlas, origin, direction, max_distance, lod, probe_light, RT_SOLID, radiance, distance_hit, opacity);
}

// Follows one ray for a picture (a reflection): a see-through surface in
// its way is shaded and laid over what a second ray finds behind it, the
// sky if nothing. One such layer; further see-through surfaces behind
// the first are passed through unseen.
int rtTracePicture(FrameConstants frame, uint64_t tlas, vec3 origin, vec3 direction, float max_distance, float lod, out vec3 radiance, out float distance_hit) {
    if ((frame.flags & FRAME_REFLECT_TRANSPARENT) == 0u) return rtTrace(frame, tlas, origin, direction, max_distance, lod, true, radiance, distance_hit);
    float opacity;
    int met = rtTraceMasked(frame, tlas, origin, direction, max_distance, lod, true, RT_ALL, radiance, distance_hit, opacity);
    if (met != RT_HIT || opacity >= 0.999) return met;
    vec3 behind = vec3(0.0);
    float distance_behind;
    float unused;
    int beyond = rtTraceMasked(frame, tlas, origin + direction * (distance_hit + 0.01), direction, max(max_distance - distance_hit, 0.02), lod, true, RT_SOLID, behind, distance_behind, unused);
    if (beyond == RT_MISS && (frame.flags & FRAME_ENVIRONMENT) != 0u)
        behind = textureLod(TEX_CUBE(frame.env_specular, frame.sampler_linear_clamp), direction, lod * 0.5).rgb * frame.env_intensity;
    radiance = radiance * opacity + behind * (1.0 - opacity);
    return RT_HIT;
}

// Lays the scene's smoke and fire over what a ray brought back from
// `distance_seen` away (see `fluidAlong`). Probes use it too, so smoke
// dims the light that crosses it and flames show up in what bounces.
vec3 rtThroughFluids(FrameConstants frame, vec3 origin, vec3 direction, float distance_seen, vec3 radiance) {
    if ((frame.flags & FRAME_FLUID_RAYS) == 0u || frame.fluids.count == 0u) return radiance;
    vec3 ambient = vec3(0.0);
    if ((frame.flags & FRAME_ENVIRONMENT) != 0u)
        ambient = textureLod(TEX_CUBE(frame.env_irradiance, frame.sampler_linear_clamp), vec3(0.0, 1.0, 0.0), 0.0).rgb * frame.env_intensity * 0.5;
    vec3 added;
    float through = fluidAlong(frame, origin, direction, distance_seen, ambient, added);
    return radiance * through + added;
}

#endif
