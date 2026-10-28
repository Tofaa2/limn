#ifndef AMBIENT_SLANG
#define AMBIENT_SLANG

float3 environmentReflection(FrameConstants frame, float3 view, float3 normal, float roughness) {
    float3 r = reflect(-view, normal);
    r = normalize(lerp(r, normal, roughness * roughness * roughness));
    return sampleCubeLod(frame.env_specular, frame.sampler_linear_clamp, r, roughness * (frame.env_specular_mips - 1.0)).rgb * frame.env_intensity;
}

void aerialHaze(FrameConstants frame, float3 view, float distance_seen, out float3 through, out float3 air) {
    if (frame.shading.aerial < 0.0) {
        through = float3(exp(distance_seen * frame.shading.aerial));
        air = sampleCubeLod(frame.env_specular, frame.sampler_linear_clamp, -view, frame.env_specular_mips * 0.6).rgb * frame.env_intensity;
        return;
    }
    float3 by_air = frame.shading.aerial * 0.6 * float3(0.43, 1.0, 2.45);
    float by_haze = frame.shading.aerial * 0.4;
    float3 lost = by_air + by_haze;
    through = exp(-lost * distance_seen);
    float mu = dot(-view, frame.sun_direction);
    float phase_air = 3.0 / (16.0 * PI) * (1.0 + mu * mu);
    const float g = 0.76;
    float phase_haze = 3.0 / (8.0 * PI) * ((1.0 - g * g) * (1.0 + mu * mu)) / ((2.0 + g * g) * pow(1.0 + g * g - 2.0 * g * mu, 1.5));
    float3 sky = sampleCubeLod(frame.env_irradiance, frame.sampler_linear_clamp, float3(0.0, 1.0, 0.0), 0.0).rgb * frame.env_intensity;
    air = (frame.sun_radiance * (by_air * phase_air + by_haze * phase_haze) + sky * 0.5 * lost) / lost;
}

float reflectionReach(FrameConstants frame, float3 position, float3 normal, float3 irradiance, float sky_visibility) {
    if (frame.shading.probe_count == 0u) return sky_visibility;
    float reach = 0.0;
    float covered = 0.0;
    for (uint i = 0u; i < frame.shading.probe_count && covered < 0.999; i++) {
        ReflectionProbeData probe = frame.shading.probes.data[i];
        float3 inside = 1.0 - abs(position - probe.center) / probe.extent;
        float weight = clamp(min(inside.x, min(inside.y, inside.z)) / max(probe.fade, 1e-3), 0.0, 1.0) * (1.0 - covered);
        if (weight <= 0.0) continue;
        float3 seen = sampleCubeLod(probe.irradiance, frame.sampler_linear_clamp, normal, 0.0).rgb * probe.intensity;
        reach += clamp(luminance(irradiance) / max(luminance(seen), 1e-4), 0.0, 1.0) * weight;
        covered += weight;
    }
    return reach + sky_visibility * (1.0 - covered);
}

float3 ambientReflection(FrameConstants frame, float3 position, float3 view, float3 normal, float roughness, float reach) {
    float3 sky = float3(0.0);
    if (frame.environment != 0u) sky = environmentReflection(frame, view, normal, roughness);
    if (frame.shading.probe_count == 0u) return sky * reach;
    float3 r = reflect(-view, normal);
    r = normalize(lerp(r, normal, roughness * roughness * roughness));
    float3 safe = select(abs(r) < float3(1e-5), float3(1e-5), r);
    float3 local = float3(0.0);
    float covered = 0.0;
    for (uint i = 0u; i < frame.shading.probe_count && covered < 0.999; i++) {
        ReflectionProbeData probe = frame.shading.probes.data[i];
        float3 offset = position - probe.center;
        float3 inside = 1.0 - abs(offset) / probe.extent;
        float weight = clamp(min(inside.x, min(inside.y, inside.z)) / max(probe.fade, 1e-3), 0.0, 1.0) * (1.0 - covered);
        if (weight <= 0.0) continue;
        float3 exits = max((probe.extent - offset) / safe, (-probe.extent - offset) / safe);
        float3 lookup = offset + safe * min(exits.x, min(exits.y, exits.z));
        local += sampleCubeLod(probe.specular, frame.sampler_linear_clamp, lookup, roughness * (frame.env_specular_mips - 1.0)).rgb * (probe.intensity * weight);
        covered += weight;
    }
    return local * lerp(1.0, reach, clamp(roughness * 3.0, 0.0, 1.0)) + sky * ((1.0 - covered) * reach);
}

#ifdef DEFER_REFLECTIONS
static float4 deferred_reflection = float4(0.0);
#endif

/// `dfg` is `brdfTable` at the surface.
float3 ambientLight(FrameConstants frame, Surface surface, float4 gathered, float2 dfg) {
    bool has_environment = frame.environment != 0u;
    bool has_gi = frame.gi.enabled != 0u;
    uint s = frame.sampler_linear_clamp;
    float n_dot_v = max(dot(surface.normal, surface.view), 1e-4);

    float3 sky_irradiance = float3(0.03);
    if (has_environment) sky_irradiance = sampleCubeLod(frame.env_irradiance, s, surface.normal, 0.0).rgb * frame.env_intensity;
    float3 irradiance = sky_irradiance;
    float sky_visibility = 1.0;
    if (has_gi) {
        float coverage = giCoverage(frame, surface.position);
        if (coverage > 0.0) {
            float3 probes = gathered.rgb;
            if (gathered.a <= 0.0) probes = giIrradiance(frame, surface.position, surface.normal, surface.view) * frame.gi.gi_intensity;
            irradiance = lerp(sky_irradiance, probes, coverage);
            float ratio = luminance(probes) / max(luminance(sky_irradiance), 1e-4);
            sky_visibility = lerp(1.0, clamp(ratio, 0.0, 1.0), coverage);
        }
    }

    float3 specular_weight = surface.f0 * dfg.x + dfg.y;
    float3 color = irradiance * surface.diffuse_color * (1.0 - specular_weight) * multiBounceAo(surface.ao, surface.diffuse_color);
    color += surface.bounce * surface.diffuse_color * (1.0 - specular_weight);
    float3 energy_compensation = 1.0 + surface.f0 * (1.0 / max(dfg.x + dfg.y, 1e-4) - 1.0);
    float3 reflection_weight = specular_weight * energy_compensation * specularOcclusion(n_dot_v, surface.ao, surface.roughness);
    float sheen_strength = max(surface.sheen_color.r, max(surface.sheen_color.g, surface.sheen_color.b));
    if (sheen_strength > 0.0) {
        float sheen_share = sheenAlbedo(n_dot_v, surface.sheen_roughness);
        color *= 1.0 - sheen_strength * sheen_share;
        reflection_weight *= 1.0 - sheen_strength * sheen_share;
        color += irradiance * surface.sheen_color * sheen_share * surface.ao * specular_kept;
    }
    sky_visibility = reflectionReach(frame, surface.position, surface.normal, irradiance, sky_visibility);
    bool add_environment = has_environment;
#ifdef DEFER_REFLECTIONS
    deferred_reflection = float4(reflection_weight, sky_visibility);
    if (frame.reflections.enabled != 0u) add_environment = false;
#endif
    float3 mirror_normal = surface.normal;
    if (surface.anisotropy > 0.0) {
        float3 across_grain = cross(surface.normal, surface.grain);
        float3 bent = cross(cross(across_grain, surface.view), across_grain);
        mirror_normal = normalize(lerp(surface.normal, bent, surface.anisotropy * clamp(5.0 * surface.roughness, 0.0, 1.0)));
    }
    if (add_environment) color += ambientReflection(frame, surface.position, surface.view, mirror_normal, surface.roughness, sky_visibility) * reflection_weight * specular_kept;
    if (surface.clearcoat > 0.0) {
        float coat_n_dot_v = clamp(dot(surface.coat_normal, surface.view), 0.0, 1.0);
        float coat_fresnel = (0.04 + 0.96 * pow(1.0 - coat_n_dot_v, 5.0)) * surface.clearcoat;
        color *= 1.0 - coat_fresnel;
        if (has_environment) {
            float3 r = reflect(-surface.view, surface.coat_normal);
            float3 radiance = sampleCubeLod(frame.env_specular, s, r, surface.clearcoat_roughness * (frame.env_specular_mips - 1.0)).rgb * frame.env_intensity;
            color += radiance * coat_fresnel * specularOcclusion(coat_n_dot_v, surface.ao, surface.clearcoat_roughness) * sky_visibility * specular_kept;
        }
    }
    return color;
}

/// Scale and bias of the split-sum specular integral at the surface.
float2 brdfTable(FrameConstants frame, Surface surface) {
    float n_dot_v = max(dot(surface.normal, surface.view), 1e-4);
    return sampleTextureLod(frame.brdf_lut, frame.sampler_linear_clamp, float2(n_dot_v, surface.roughness), 0.0).rg;
}

#endif
