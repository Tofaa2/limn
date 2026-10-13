#ifndef RAY_LIGHT_SLANG
#define RAY_LIGHT_SLANG
#include "surface.slang"
#include "gi.slang"
#include "fluid.slang"

static const int RAY_MISS = 0;
static const int RAY_HIT = 1;
static const int RAY_BACK = 2;

/// What a ray brings back: the light leaving the surface it met toward the
/// ray's origin, lit by the sun, the nearest lights and the probes or sky.
struct LitRay {
    int met;
    float3 radiance;
    float distance;
    float opacity;
};

bool rayOccluded(Tracer tracer, float3 origin, float3 direction, float reach) {
    return tracer.any(origin, direction, reach, RAY_SOLID, Cutouts.cut);
}

/// Light of one of the frame's lamps on a surface before shadowing, with the
/// direction and distance a shadow ray toward it takes. False where the lamp
/// does not reach.
bool lampOnHit(FrameConstants frame, Light light, float3 position, float3 normal, out float3 toward, out float reach, out float3 arriving) {
    toward = float3(0.0);
    reach = 1e4;
    arriving = float3(0.0);
    float attenuation = 1.0;
    float3 tint = float3(1.0);
    if ((light.flags & LIGHT_DIRECTIONAL) != 0u) {
        toward = -light.direction;
    } else {
        float3 to_light = light.position - position;
        float distance_squared = dot(to_light, to_light);
        float range_squared = light.range * light.range;
        if (distance_squared > range_squared || dot(normal, to_light) <= 0.0) return false;
        float window = clamp(1.0 - (distance_squared * distance_squared) / (range_squared * range_squared), 0.0, 1.0);
        attenuation = window * window / max(distance_squared, 0.01);
        reach = sqrt(distance_squared);
        toward = to_light / max(reach, 1e-5);
        if ((light.flags & LIGHT_SPOT) != 0u) {
            float cos_angle = dot(-toward, light.direction);
            float cone = clamp(cos_angle * light.cone_scale + light.cone_offset, 0.0, 1.0);
            attenuation *= cone * cone;
            if (light.cookie != INVALID_ID && attenuation > 0.0) {
                float3 axis = light.direction;
                float3 side = normalize(abs(axis.y) < 0.99 ? cross(axis, float3(0.0, 1.0, 0.0)) : cross(axis, float3(1.0, 0.0, 0.0)));
                float3 up = cross(side, axis);
                float cos_outer = -light.cone_offset / max(light.cone_scale, 1e-5);
                float tan_outer = sqrt(max(1.0 - cos_outer * cos_outer, 0.0)) / max(cos_outer, 1e-3);
                float2 slide = float2(dot(-toward, side), dot(-toward, up)) / max(cos_angle, 1e-3) / max(tan_outer, 1e-3);
                tint = sampleTextureLod(light.cookie, frame.sampler_linear_clamp, slide * 0.5 + 0.5, 0.0).rgb;
            }
        }
        if (light.profile != INVALID_ID)
            attenuation *= sampleTextureLod(light.profile, frame.sampler_linear_clamp, float2(acos(clamp(dot(-toward, light.direction), -1.0, 1.0)) / PI, 0.5), 0.0).r;
        if ((light.flags & LIGHT_RECTANGLE) != 0u) attenuation *= clamp(dot(-toward, light.direction), 0.0, 1.0);
    }
    float facing = dot(normal, toward);
    if (facing <= 0.0 || attenuation <= 1e-5) return false;
    arriving = light.color * tint * (attenuation * facing);
    return true;
}

float3 lightsOnHit(Tracer tracer, float3 position, float3 normal, float3 albedo) {
    FrameConstants frame = tracer.frame;
    float3 radiance = float3(0.0);
    uint light_count = min(frame.light_count, max((frame.flags >> 20) & 1023u, 1u));
    for (uint i = 0u; i < light_count; i++) {
        float3 toward;
        float reach;
        float3 arriving;
        if (lampOnHit(frame, frame.lights.data[i], position, normal, toward, reach, arriving)) {
            if (!rayOccluded(tracer, position + normal * 0.02, toward, reach - 0.04)) radiance += albedo / PI * arriving;
        }
    }
    return radiance;
}

LitRay traceLit(Tracer tracer, float3 origin, float3 direction, float reach, float lod, bool probe_light, uint mask) {
    FrameConstants frame = tracer.frame;
    LitRay result;
    result.met = RAY_MISS;
    result.radiance = float3(0.0);
    result.distance = reach;
    result.opacity = 1.0;
    TraceHit hit;
    if (!tracer.closest(origin, direction, reach, mask, Cutouts.cut, hit)) return result;
    result.distance = hit.t;

    HitGeometry geometry = geometryAt(frame, hit, origin, direction);
    if (geometry.back_face && (geometry.material.flags & MATERIAL_DOUBLE_SIDED) == 0u) {
        result.met = RAY_BACK;
        return result;
    }
    HitSurface surface = surfaceOf(geometry, SurfaceDetail.fixed(lod));
    result.met = RAY_HIT;
    if ((surface.material_flags & MATERIAL_BLEND) != 0u) result.opacity = clamp(surface.base_color.a * (1.0 - surface.transmission * 0.85), 0.0, 1.0);
    float3 albedo = surface.base_color.rgb * (1.0 - 0.7 * surface.metallic);
    float3 normal = surface.normal;
    float3 position = surface.position;

    float3 radiance = surface.emissive;
    float n_dot_l = dot(normal, frame.sun_direction);
    if (n_dot_l > 0.0 && dot(frame.sun_radiance, float3(1.0)) > 0.0) {
        if (!rayOccluded(tracer, position + normal * 0.02, frame.sun_direction, 1e4))
            radiance += albedo / PI * frame.sun_radiance * n_dot_l;
    }
    if ((frame.flags & FRAME_GI_LOCAL_LIGHTS) != 0u) radiance += lightsOnHit(tracer, position, normal, albedo);
    if ((frame.flags & FRAME_GI) == 0u) {
        radiance += albedo * ((frame.flags & FRAME_ENVIRONMENT) != 0u
            ? sampleCubeLod(frame.env_irradiance, frame.sampler_linear_clamp, normal, 0.0).rgb * frame.env_intensity
            : float3(0.03));
    } else if (probe_light && giCoverage(frame, position) > 0.0) {
        radiance += albedo * giIrradiance(frame, position, normal, -direction);
    }
    result.radiance = radiance;
    return result;
}

/// As `traceLit` for a picture of the scene: see-through surfaces show what
/// is behind them where the frame asks reflections to include them.
LitRay tracePicture(Tracer tracer, float3 origin, float3 direction, float reach, float lod) {
    FrameConstants frame = tracer.frame;
    if ((frame.flags & FRAME_REFLECT_TRANSPARENT) == 0u) return traceLit(tracer, origin, direction, reach, lod, true, RAY_SOLID);
    LitRay front = traceLit(tracer, origin, direction, reach, lod, true, RAY_ALL);
    if (front.met != RAY_HIT || front.opacity >= 0.999) return front;
    LitRay beyond = traceLit(tracer, origin + direction * (front.distance + 0.01), direction, max(reach - front.distance, 0.02), lod, true, RAY_SOLID);
    float3 behind = beyond.radiance;
    if (beyond.met == RAY_MISS && (frame.flags & FRAME_ENVIRONMENT) != 0u)
        behind = sampleCubeLod(frame.env_specular, frame.sampler_linear_clamp, direction, lod * 0.5).rgb * frame.env_intensity;
    front.radiance = front.radiance * front.opacity + behind * (1.0 - front.opacity);
    return front;
}

float3 throughFluids(FrameConstants frame, float3 origin, float3 direction, float distance_seen, float3 radiance) {
    if ((frame.flags & FRAME_FLUID_RAYS) == 0u || frame.fluids.count == 0u) return radiance;
    float3 ambient = float3(0.0);
    if ((frame.flags & FRAME_ENVIRONMENT) != 0u)
        ambient = sampleCubeLod(frame.env_irradiance, frame.sampler_linear_clamp, float3(0.0, 1.0, 0.0), 0.0).rgb * frame.env_intensity * 0.5;
    float3 added;
    float through = fluidAlong(frame, origin, direction, distance_seen, ambient, added);
    return radiance * through + added;
}

#endif
