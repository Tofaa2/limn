#ifndef SHADING_SLANG
#define SHADING_SLANG

#include "brdf.slang"
#include "vsm.slang"
#include "gi.slang"
#include "clouds.slang"
#include "fluid.slang"
#ifdef RAY_TRACED
#include "ray_light.slang"
#endif

struct Surface {
    float3 position;
    float3 normal;
    float3 view;
    float3 diffuse_color;
    float3 f0;
    float roughness;
    float ao;
    float3 bounce;
    float view_depth;
    float clearcoat;
    float clearcoat_roughness;
    float3 coat_normal;
    float3 sheen_color;
    float sheen_roughness;
    /// Stretch of the highlights along `grain`, 0..1; below 0 the surface is
    /// a hair fibre running along `grain`.
    float anisotropy;
    float3 grain;
    float subsurface;
};

static const float2 vogel_disk[16] = { float2(0.1768, 0.0000), float2(-0.2257, 0.2068), float2(0.0345, -0.3938), float2(0.2845, 0.3703), float2(-0.5265, -0.0696), float2(0.4594, -0.3632), float2(-0.1158, 0.6272), float2(-0.4117, -0.5510), float2(0.7123, 0.1728), float2(-0.6434, 0.4302), float2(0.2334, -0.7767), float2(0.4298, 0.7324), float2(-0.8291, -0.2950), float2(0.8183, -0.4133), float2(-0.3632, 0.8715), float2(-0.3838, -0.9010) };

float sampleCascade(FrameConstants frame, uint cascade, float3 world_position, float3 normal, float n_dot_l, float rotation) {
    float texel = frame.shadows.cascade_texel_size[cascade];
    float3 biased = world_position + normal * texel * (1.5 + 2.5 * (1.0 - n_dot_l));
    float4 clip = mul(frame.shadows.cascade_view_proj[cascade], float4(biased, 1.0));
    float3 coord = float3(clip.xy * 0.5 + 0.5, clip.z);
    if (coord.z >= 1.0) return 1.0;
    float c = cos(rotation);
    float s = sin(rotation);
    float2x2 rotate = float2x2(c, s, -s, c);
    float radius = frame.shadows.shadow_softness / (texel * float(textureArraySize(frame.shadows.shadow_map).x));
    #define SHADOW_TAP(index) textures_2d_array[NonUniformResourceIndex(frame.shadows.shadow_map)].SampleCmpLevelZero( \
        samplers_shadow[NonUniformResourceIndex(frame.shadows.shadow_sampler)], \
        float3(coord.xy + mul(vogel_disk[index], rotate) * radius, float(cascade)), coord.z)
    float lit = SHADOW_TAP(3) + SHADOW_TAP(7) + SHADOW_TAP(11) + SHADOW_TAP(15);
    if (lit <= 0.0 || lit >= 4.0) return lit * 0.25;
    if (frame.shadows.shadow_taps <= 4u) return lit * 0.25;
    int stride = frame.shadows.shadow_taps >= 16u ? 1 : 2;
    float taps = 4.0;
    for (int i = 0; i < 16; i += stride) {
        if ((i & 3) == 3) continue;
        lit += SHADOW_TAP(i);
        taps += 1.0;
    }
    #undef SHADOW_TAP
    return lit / taps;
}

float cascadeShadow(FrameConstants frame, float3 world_position, float3 normal, float n_dot_l, float view_depth, float noise) {
    if (frame.shadows.enabled == 0u) return 1.0;
    uint cascade = 0u;
    for (uint i = 0u; i < 3u; i++) {
        if (view_depth > frame.shadows.cascade_splits[i]) cascade = i + 1u;
    }
    if (view_depth > frame.shadows.cascade_splits[3]) return 1.0;
    float rotation = noise * 2.0 * PI;
    float lit = sampleCascade(frame, cascade, world_position, normal, n_dot_l, rotation);
    float split = frame.shadows.cascade_splits[cascade];
    float band = split * 0.1;
    float blend = clamp((view_depth - (split - band)) / band, 0.0, 1.0);
    if (blend > 0.0) {
        float next = 1.0;
        if (cascade < 3u) next = sampleCascade(frame, cascade + 1u, world_position, normal, n_dot_l, rotation);
        lit = lerp(lit, next, blend);
    }
    return lit;
}

float virtualShadow(FrameConstants frame, float3 world_position, float3 normal, float n_dot_l) {
    VsmData* vsm = frame.shadows.vsm.data;
    float2 unmoved = (mul(vsm.light_view, float4(world_position, 1.0))).xy;
    for (uint level = vsmLevel(vsm, unmoved); level < vsm.levels; level++) {
        float texel = vsmExtent(vsm, level) / (float(vsm_pages) * vsm_page_texels);
        float3 at = (mul(vsm.light_view, float4(world_position + normal * texel * (1.5 + 2.5 * (1.0 - n_dot_l)), 1.0))).xyz;
        int2 page;
        float2 within;
        if (!vsmLocate(vsm, level, at.xy, page, within)) continue;
        VsmPage entry = vsm.pages[vsmSlot(level, page)];
        if (entry.key != vsmKey(page) || entry.place == 0u || (entry.flags & VSM_READY) == 0u) continue;
        float2 corner = float2(float((entry.place - 1u) % uint(vsm_atlas_pages)), float((entry.place - 1u) / uint(vsm_atlas_pages)));
        float depth = (at.z - vsm.depth_from) / vsm.depth_range;
        float lit = 0.0;
        for (int tap = 0; tap < 4; tap++) {
            float2 offset = float2((tap & 1) == 0 ? -0.5 : 0.5, (tap & 2) == 0 ? -0.5 : 0.5) / vsm_page_texels;
            float2 inside = clamp(within + offset, float2(1.0 / vsm_page_texels), float2(1.0 - 1.0 / vsm_page_texels));
            lit += textures_2d[NonUniformResourceIndex(vsm.atlas_texture)].SampleCmpLevelZero(samplers_shadow[NonUniformResourceIndex(frame.shadows.shadow_sampler)], (corner + inside) / float(vsm_atlas_pages), depth);
        }
        return lit * 0.25;
    }
    return -1.0;
}

float sunShadow(FrameConstants frame, float3 world_position, float3 normal, float n_dot_l, float view_depth, float noise) {
    float past_geometry = -1.0;
    if (frame.shadows.virtual_maps != 0u) past_geometry = virtualShadow(frame, world_position, normal, n_dot_l);
    if (past_geometry < 0.0) past_geometry = cascadeShadow(frame, world_position, normal, n_dot_l, view_depth, noise);
    return past_geometry * cloudShadow(frame, world_position) * fluidShadow(frame, world_position);
}

float3 sunTint(FrameConstants frame, float3 world_position, float view_depth) {
    if ((SHADE_FEATURES & FEATURE_COLORED_SHADOWS) == 0u || frame.shadows.colored == 0u) return float3(1.0);
    uint cascade = 0u;
    for (uint i = 0u; i < 3u; i++) {
        if (view_depth > frame.shadows.cascade_splits[i]) cascade = i + 1u;
    }
    if (view_depth > frame.shadows.cascade_splits[3]) return float3(1.0);
    float4 clip = mul(frame.shadows.cascade_view_proj[cascade], float4(world_position, 1.0));
    float2 uv = clip.xy * 0.5 + 0.5;
    if (any((uv < float2(0.0))) || any((uv > float2(1.0)))) return float3(1.0);
    Texture2DArray shadow_color = textures_2d_array[NonUniformResourceIndex(frame.shadows.shadow_color)];
    SamplerState linear = samplers[NonUniformResourceIndex(frame.sampler_linear_clamp)];
    float4 tint = shadow_color.SampleLevel(linear, float3(uv, float(cascade)), 0.0);
    float4 depths = shadow_color.GatherAlpha(linear, float3(uv, float(cascade)));
    float nearest_caster = min(min(depths.x, depths.y), min(depths.z, depths.w));
    return clip.z > nearest_caster + 0.01 ? tint.rgb : float3(1.0);
}

float contactShadow(FrameConstants frame, float3 position, float noise) {
#ifdef CONTACT_SHADOWS
    if (frame.shadows.contact_depth == INVALID_ID || frame.shadows.contact_length <= 0.0) return 1.0;
    const int steps = 12;
    float3 stride = frame.sun_direction * (frame.shadows.contact_length / float(steps));
    float3 point = position + stride * noise;
    for (int i = 0; i < steps; i++) {
        point += stride;
        float4 clip = mul(frame.view_proj, float4(point, 1.0));
        float along = clipDepth(frame, clip);
        if (along <= frame.near) break;
        float2 uv = clip.xy / clip.w * 0.5 + 0.5;
        if (any((uv < float2(0.0))) || any((uv > float2(1.0)))) break;
        float scene = linearDepth(sampleTextureLod(frame.shadows.contact_depth, frame.sampler_nearest_clamp, uv, 0.0).r, frame.depth_terms);
        float behind = along - scene;
        if (behind > 0.01 * along + 0.005 && behind < frame.shadows.contact_length) return 0.0;
    }
#endif
    return 1.0;
}

float3 directLight(float3 n, float3 v, float3 l, float3 radiance, float3 diffuse_color, float3 f0, float roughness) {
    float n_dot_l = clamp(dot(n, l), 0.0, 1.0);
    if (n_dot_l <= 0.0) return float3(0.0);
    float3 h = normalize(v + l);
    float n_dot_v = max(dot(n, v), 1e-4);
    float n_dot_h = clamp(dot(n, h), 0.0, 1.0);
    float alpha = roughness * roughness;
    float3 fresnel = fresnelSchlick(clamp(dot(v, h), 0.0, 1.0), f0);
    float3 specular = fresnel * (distributionGgx(n_dot_h, alpha) * visibilitySmithGgx(n_dot_l, n_dot_v, alpha));
    float3 diffuse = diffuse_color * (1.0 - fresnel) / PI;
    return (diffuse + specular) * radiance * n_dot_l;
}

float3 grainLight(Surface surface, float3 l, float3 radiance) {
    float3 n = surface.normal;
    float3 v = surface.view;
    float n_dot_l = clamp(dot(n, l), 0.0, 1.0);
    if (n_dot_l <= 0.0) return float3(0.0);
    float3 h = normalize(v + l);
    float n_dot_v = max(dot(n, v), 1e-4);
    float3 t = surface.grain;
    float3 b = cross(n, t);
    float across = max(surface.roughness * surface.roughness, 0.002);
    float along = lerp(across, 1.0, surface.anisotropy * surface.anisotropy);
    float3 scaled = float3(dot(t, h) / along, dot(b, h) / across, dot(n, h));
    float distribution = 1.0 / (PI * along * across * dot(scaled, scaled) * dot(scaled, scaled));
    float visibility = 0.5 / max(n_dot_l * length(float3(along * dot(t, v), across * dot(b, v), n_dot_v)) +
        n_dot_v * length(float3(along * dot(t, l), across * dot(b, l), n_dot_l)), 1e-5);
    float3 fresnel = fresnelSchlick(clamp(dot(v, h), 0.0, 1.0), surface.f0);
    float3 diffuse = surface.diffuse_color * (1.0 - fresnel) / PI;
    return (diffuse + fresnel * min(distribution * visibility, 1e4)) * radiance * n_dot_l;
}

/// Fresnel reflectance of a hair's cuticle, of index 1.55.
float hairFresnel(float cos_theta) {
    const float f0 = 0.0465;
    return f0 + (1.0 - f0) * pow(1.0 - clamp(cos_theta, 0.0, 1.0), 5.0);
}

float hairLobe(float width, float angle) {
    width = max(width, 1e-3);
    return exp(-0.5 * angle * angle / (width * width)) / (sqrt(2.0 * PI) * width);
}

/// Light a hair fibre along `tangent` sends toward `view` from `l`, after
/// Marschner: a white reflection off the cuticle shifted toward the tip,
/// light through the fibre coloured by `color` toward a light behind, and a
/// coloured reflection from inside it shifted toward the root. The lobes are
/// Karis's fits.
float3 hairFibre(float3 tangent, float3 view, float3 l, float3 color, float roughness) {
    float sin_l = clamp(dot(tangent, l), -1.0, 1.0);
    float sin_v = clamp(dot(tangent, view), -1.0, 1.0);
    float cos_d = max(cos(0.5 * abs(asin(sin_v) - asin(sin_l))), 1e-3);
    float3 across_l = l - sin_l * tangent;
    float3 across_v = view - sin_v * tangent;
    float cos_phi = dot(across_l, across_v) * rsqrt(dot(across_l, across_l) * dot(across_v, across_v) + 1e-4);
    float cos_half_phi = sqrt(clamp(0.5 + 0.5 * cos_phi, 0.0, 1.0));
    float width = max(roughness * roughness, 0.002);
    const float shift = 0.035;
    float3 result = float3(0.0);

    float tilt_sin = sin(-2.0 * shift);
    float tilt_cos = cos(-2.0 * shift);
    float tilt = 2.0 * tilt_sin * (tilt_cos * cos_half_phi * sqrt(max(1.0 - sin_v * sin_v, 0.0)) + tilt_sin * sin_v);
    float reflected = hairLobe(width * sqrt(2.0) * cos_half_phi, sin_l + sin_v - tilt) * 0.25 * cos_half_phi;
    result += reflected * hairFresnel(sqrt(clamp(0.5 + 0.5 * dot(view, l), 0.0, 1.0)));

    float bent = 1.0 / (1.19 / cos_d + 0.36 * cos_d);
    float offset = cos_half_phi * (1.0 + bent * (0.6 - 0.8 * cos_phi));
    float entering = hairFresnel(cos_d * sqrt(clamp(1.0 - offset * offset, 0.0, 1.0)));
    float3 passed = pow(color, 0.5 * sqrt(clamp(1.0 - offset * offset * bent * bent, 0.0, 1.0)) / cos_d);
    result += hairLobe(width * 0.5, sin_l + sin_v - shift) * exp(-3.65 * cos_phi - 3.98) * (1.0 - entering) * (1.0 - entering) * passed;

    float inner = hairFresnel(cos_d * 0.5);
    result += hairLobe(width * 2.0, sin_l + sin_v - 4.0 * shift) * exp(17.0 * cos_phi - 16.78) * (1.0 - inner) * (1.0 - inner) * inner * pow(color, 0.8 / cos_d);
    return max(result, float3(0.0));
}

/// Light scattered back and forth among neighbouring fibres, which gives hair
/// its body and the glow of fair hair; `through` is what is left of it after
/// crossing other fibres on the way in.
float3 hairScatter(float3 tangent, float3 view, float3 l, float3 color, float3 through) {
    float across = 1.0 - abs(dot(tangent, l));
    float3 facing = view - tangent * dot(view, tangent);
    facing *= rsqrt(max(dot(facing, facing), 1e-8));
    float wrapped = clamp((dot(facing, l) + 1.0) * 0.25, 0.0, 1.0);
    return color * through * (lerp(wrapped, across, 0.33) / PI);
}

float3 surfaceLight(Surface surface, float3 l, float3 radiance) {
    if (surface.anisotropy < 0.0) return (hairFibre(surface.grain, surface.view, l, surface.diffuse_color, surface.roughness) + hairScatter(surface.grain, surface.view, l, surface.diffuse_color, float3(1.0))) * radiance;
    float3 base;
    if (surface.anisotropy > 0.0) base = grainLight(surface, l, radiance);
    else base = directLight(surface.normal, surface.view, l, radiance, surface.diffuse_color, surface.f0, surface.roughness);
    float sheen_strength = max(surface.sheen_color.r, max(surface.sheen_color.g, surface.sheen_color.b));
    if (surface.clearcoat <= 0.0 && sheen_strength <= 0.0) return base;
    float n_dot_l = clamp(dot(surface.normal, l), 0.0, 1.0);
    if (n_dot_l <= 0.0) return base;
    float3 h = normalize(surface.view + l);
    float n_dot_v = max(dot(surface.normal, surface.view), 1e-4);
    if (sheen_strength > 0.0) {
        float inverse_alpha = 1.0 / max(surface.sheen_roughness * surface.sheen_roughness, 0.005);
        float n_dot_h = clamp(dot(surface.normal, h), 0.0, 1.0);
        float sin_squared = 1.0 - n_dot_h * n_dot_h;
        float distribution = (2.0 + inverse_alpha) * pow(sin_squared, 0.5 * inverse_alpha) / (2.0 * PI);
        float visibility = 1.0 / (4.0 * (n_dot_l + n_dot_v - n_dot_l * n_dot_v));
        base = base * (1.0 - 0.3 * sheen_strength) + surface.sheen_color * radiance * (distribution * visibility * n_dot_l);
    }
    if (surface.clearcoat <= 0.0) return base;
    float coat_n_dot_l = clamp(dot(surface.coat_normal, l), 0.0, 1.0);
    float coat_fresnel = fresnelSchlick(clamp(dot(surface.view, h), 0.0, 1.0), float3(0.04)).x * surface.clearcoat;
    float alpha = max(surface.clearcoat_roughness * surface.clearcoat_roughness, 0.002);
    float coat = distributionGgx(clamp(dot(surface.coat_normal, h), 0.0, 1.0), alpha) * visibilitySmithGgx(coat_n_dot_l, max(dot(surface.coat_normal, surface.view), 1e-4), alpha) * coat_fresnel;
    return base * (1.0 - coat_fresnel) + radiance * (coat_n_dot_l * coat);
}

float3 multiBounceAo(float ao, float3 albedo) {
    float3 a = 2.0404 * albedo - 0.3324;
    float3 b = -4.7951 * albedo + 0.6417;
    float3 c = 2.7552 * albedo + 0.6903;
    return max(float3(ao), ((ao * a + b) * ao + c) * ao);
}

float specularOcclusion(float n_dot_v, float ao, float roughness) {
    return clamp(pow(n_dot_v + ao, exp2(-16.0 * roughness - 1.0)) - 1.0 + ao, 0.0, 1.0);
}

uint clusterIndex(FrameConstants frame, float2 pixel, float view_depth) {
    uint2 tile = min(uint2(pixel * frame.inv_resolution * float2(CLUSTERS_X, CLUSTERS_Y)), uint2(CLUSTERS_X - 1u, CLUSTERS_Y - 1u));
    float slice = log2(max(view_depth, 1e-4)) * frame.lights.cluster_z_scale + frame.lights.cluster_z_bias;
    uint z = uint(clamp(slice, 0.0, float(CLUSTERS_Z - 1u)));
    return tile.x + tile.y * CLUSTERS_X + z * CLUSTERS_X * CLUSTERS_Y;
}

#define DECAL_LOOP_BEGIN(position, pixel) \
    uint decal_cluster = clusterIndex(frame, pixel, -(mul(frame.view, float4(position, 1.0))).z); \
    for (uint decal_word = 0u; decal_word < ((SHADE_FEATURES & FEATURE_DECALS) == 0u || (instance.flags & INSTANCE_NO_DECALS) != 0u ? 0u : (frame.shading.decal_count + 31u) >> 5u); decal_word++) \
    for (uint decal_bits = frame.lights.clusters.data[decal_cluster].decals[decal_word]; decal_bits != 0u; decal_bits &= decal_bits - 1u) { \
        uint i = decal_word * 32u + uint(firstbitlow(decal_bits));

#ifdef RAY_TRACED
bool rtOccluded(FrameConstants frame, uint64_t tlas, float3 origin, float3 direction, float reach) {
    Tracer tracer;
    tracer.frame = frame;
    tracer.scene = tlas;
    return rayOccluded(tracer, origin, direction, reach);
}
#endif

float tracedShadow(FrameConstants frame, Light light, float3 position, float3 normal, float3 l, float reach, float noise) {
#ifdef RAY_TRACED
    if ((SHADE_FEATURES & FEATURE_TRACED_LIGHT_SHADOWS) == 0u || (light.flags & LIGHT_TRACED_SHADOW) == 0u || (frame.shadows.tlas_low | frame.shadows.tlas_high) == 0u) return 1.0;
    uint64_t tlas = uint64_t(frame.shadows.tlas_low) | (uint64_t(frame.shadows.tlas_high) << 32);
    float3 origin = position + normal * 0.03;
    if ((light.flags & LIGHT_DIRECTIONAL) != 0u && light.source_radius > 0.0) {
        uint rays = max(frame.shadows.light_rays, 1u);
        float3 side = normalize(cross(abs(l.y) < 0.99 ? float3(0.0, 1.0, 0.0) : float3(1.0, 0.0, 0.0), l));
        float3 up = cross(l, side);
        float lit = 0.0;
        for (uint ray = 0u; ray < rays; ray++) {
            float angle = frac(noise + float(ray) * 0.61803399) * 6.2831853;
            float reach_out = light.source_radius * sqrt(frac(noise * 7.31 + 0.37 + float(ray) * 0.75487767));
            lit += rtOccluded(frame, tlas, origin, normalize(l + (side * cos(angle) + up * sin(angle)) * reach_out), reach) ? 0.0 : 1.0;
        }
        return lit / float(rays);
    }
    if ((light.flags & LIGHT_DIRECTIONAL) == 0u && (light.source_radius > 0.0 || light.source_length > 0.0)) {
        uint rays = max(frame.shadows.light_rays, 1u);
        float base = noise;
        float lit = 0.0;
        for (uint ray = 0u; ray < rays; ray++) {
            float2 pick = frac(float2(base + float(ray) * 0.61803399, base * 7.31 + 0.37 + float(ray) * 0.75487767)) - 0.5;
            float3 target = light.position;
            if ((light.flags & LIGHT_RECTANGLE) != 0u) {
                float3 facing = light.direction;
                float3 right = normalize(cross(abs(facing.y) < 0.99 ? float3(0.0, 1.0, 0.0) : float3(1.0, 0.0, 0.0), facing));
                target += right * (pick.x * light.source_length) + cross(facing, right) * (pick.y * light.source_height);
            } else {
                if ((light.flags & LIGHT_SPOT) == 0u) target += light.direction * (pick.x * light.source_length);
                float angle = pick.y * 6.2831853;
                target += float3(cos(angle), sin(angle * 1.7), sin(angle)) * (light.source_radius * frac(base * 3.17 + 0.11 + float(ray) * 0.37));
            }
            float3 toward = target - origin;
            float distance_there = length(toward);
            lit += rtOccluded(frame, tlas, origin, toward / max(distance_there, 1e-5), distance_there - 0.06) ? 0.0 : 1.0;
        }
        return lit / float(rays);
    }
    return rtOccluded(frame, tlas, origin, l, reach) ? 0.0 : 1.0;
#else
    return 1.0;
#endif
}

static const float LOCAL_SHADOW_MAX_KERNEL = 14.0;

float localShadow(FrameConstants frame, Light light, float3 world_position, float3 normal, float3 to_light, float distance_to_light, float noise) {
    uint first = light.flags >> 8;
    if (first == 0u) return 1.0;
    uint tile_index = first - 1u;
    if ((light.flags & LIGHT_SPOT) == 0u) {
        float3 d = -to_light;
        float3 a = abs(d);
        if (a.x >= a.y && a.x >= a.z) tile_index += d.x > 0.0 ? 0u : 1u;
        else if (a.y >= a.z) tile_index += d.y > 0.0 ? 2u : 3u;
        else tile_index += d.z > 0.0 ? 4u : 5u;
    }
    ShadowTile tile = frame.lights.shadow_tiles.data[tile_index];
    float2 atlas_size = textureSize(frame.shadows.local_shadow_map);
    float texel_world = distance_to_light * 2.0 / (tile.rect.x * atlas_size.x);
    float3 biased = world_position + normal * texel_world * 2.0 + to_light * texel_world;
    float4 clip = mul(tile.view_proj, float4(biased, 1.0));
    if (clip.w <= 0.0) return 1.0;
    float3 ndc = clip.xyz / clip.w;
    float2 tile_uv = ndc.xy * 0.5 + 0.5;
    if (any((tile_uv < float2(0.0))) || any((tile_uv > float2(1.0)))) return 1.0;
    float2 texel = 1.0 / atlas_size;
    float2 low = tile.rect.zw + texel;
    float2 high = tile.rect.zw + tile.rect.xy - texel;
    float c = cos(noise * 2.0 * PI);
    float s = sin(noise * 2.0 * PI);
    float2x2 rotate = float2x2(c, s, -s, c);
    float kernel = 2.5;
    if ((SHADE_FEATURES & FEATURE_SIZED_LIGHTS) != 0u && light.source_radius > 0.0) {
        float texels_per_world = tile.rect.x * atlas_size.x * 0.5 / distance_to_light;
        float search = clamp(light.source_radius * texels_per_world, 2.5, LOCAL_SHADOW_MAX_KERNEL);
        float blockers = 0.0;
        float blocker_z = 0.0;
        for (int i = 0; i < 16; i += 2) {
            float2 at = clamp(tile_uv * tile.rect.xy + tile.rect.zw + mul(vogel_disk[i], rotate) * texel * search, low, high);
            float z = sampleTextureLod(frame.shadows.local_shadow_map, frame.sampler_nearest_clamp, at, 0.0).r;
            if (z > ndc.z) {
                blockers += 1.0;
                blocker_z += z;
            }
        }
        if (blockers == 0.0) return 1.0;
        float ratio = (blocker_z / blockers) / ndc.z;
        kernel = clamp(light.source_radius * (ratio - 1.0) * texels_per_world, 2.5, LOCAL_SHADOW_MAX_KERNEL);
        if (kernel > 2.5) {
            biased = world_position + normal * texel_world * (0.8 * kernel) + to_light * texel_world * (0.4 * kernel);
            clip = mul(tile.view_proj, float4(biased, 1.0));
            ndc = clip.xyz / clip.w;
            tile_uv = ndc.xy * 0.5 + 0.5;
        }
    }
    #define LOCAL_SHADOW_TAP(index) textures_2d[NonUniformResourceIndex(frame.shadows.local_shadow_map)].SampleCmpLevelZero( \
        samplers_shadow[NonUniformResourceIndex(frame.shadows.local_shadow_sampler)], \
        clamp(tile_uv * tile.rect.xy + tile.rect.zw + mul(vogel_disk[index], rotate) * texel * kernel, low, high), ndc.z)
    float lit = LOCAL_SHADOW_TAP(3) + LOCAL_SHADOW_TAP(7) + LOCAL_SHADOW_TAP(11) + LOCAL_SHADOW_TAP(15);
    if (lit <= 0.0 || lit >= 4.0) return lit * 0.25;
    for (int i = 0; i < 16; i += 2) lit += LOCAL_SHADOW_TAP(i);
    #undef LOCAL_SHADOW_TAP
    return lit / 12.0;
}

float3 sphereLight(Surface surface, float3 to_light, float distance_to_light, float radius, float3 radiance, float3 tube_center, float3 tube_axis, float tube_length) {
    float3 l = to_light / max(distance_to_light, 1e-5);
    if ((radius <= 0.0 && tube_length == 0.0) || surface.anisotropy < 0.0) return surfaceLight(surface, l, radiance);
    float3 mirror = reflect(-surface.view, surface.normal);
    float3 center = to_light;
    float line_normalization = 1.0;
    if (tube_length > 0.0) {
        float3 a = tube_center - tube_axis * (0.5 * tube_length);
        float3 ab = tube_axis * tube_length;
        float along = dot(mirror, ab);
        float t = clamp((dot(mirror, a) * along - dot(a, ab)) / max(dot(ab, ab) - along * along, 1e-5), 0.0, 1.0);
        center = a + ab * t;
        float alpha_line = surface.roughness * surface.roughness;
        line_normalization = alpha_line / clamp(alpha_line + tube_length / (2.0 * distance_to_light), 1e-4, 1.0);
    }
    if (tube_length < 0.0) {
        center = tube_center;
        float alpha_panel = surface.roughness * surface.roughness;
        line_normalization = alpha_panel / clamp(alpha_panel - tube_length / (2.0 * distance_to_light), 1e-4, 1.0);
    }
    float3 center_to_ray = dot(center, mirror) * mirror - center;
    float3 closest = center + center_to_ray * clamp(radius / max(length(center_to_ray), 1e-5), 0.0, 1.0);
    float3 specular_l = normalize(closest);
    float alpha = surface.roughness * surface.roughness;
    float widened = clamp(alpha + radius / (2.0 * distance_to_light), 0.0, 1.0);
    float normalization = (alpha / max(widened, 1e-4)) * (alpha / max(widened, 1e-4)) * line_normalization;
    Surface diffuse_only = surface;
    diffuse_only.f0 = float3(0.0);
    diffuse_only.clearcoat = 0.0;
    Surface specular_only = surface;
    specular_only.diffuse_color = float3(0.0);
    return surfaceLight(diffuse_only, l, radiance) + surfaceLight(specular_only, specular_l, radiance) * normalization;
}

static uint soft_history_texture = INVALID_ID;
static float2 soft_history_uv = float2(0.0);
static uint soft_history_depth_texture = INVALID_ID;
static float soft_history_depth = 0.0;
static float soft_history_slack = 0.0;

float softShadowHistory(FrameConstants frame) {
    if (soft_history_texture == INVALID_ID) return -1.0;
    float2 previous_uv = soft_history_uv;
    if (any((previous_uv < float2(0.0))) || any((previous_uv > float2(1.0)))) return -1.0;
    int2 history_size = int2(textureSize(soft_history_texture));
    int2 at = int2(previous_uv * float2(history_size));
    int2 last = history_size - 1;
    float expected = soft_history_depth_texture != INVALID_ID ? soft_history_depth : 0.0;
    int2 depth_size = int2(1);
    if (soft_history_depth_texture != INVALID_ID) depth_size = int2(textureSize(soft_history_depth_texture));
    float2 scale = float2(depth_size) / float2(history_size);
    int2 depth_last = depth_size - 1;
    const int2 offsets[5] = { int2(0, 0), int2(1, 0), int2(-1, 0), int2(0, 1), int2(0, -1) };
    float total = 0.0;
    float weight = 0.0;
    for (int i = 0; i < 5; i++) {
        float value = fetchTexel(soft_history_texture, clamp(at + offsets[i], int2(0), last)).a;
        if (value > 1.0) continue;
        if (expected > 0.0) {
            float there = linearDepth(fetchTexel(soft_history_depth_texture, clamp(int2((float2(at + offsets[i]) + 0.5) * scale), int2(0), depth_last)).r, frame.depth_terms);
            if (abs(there - expected) > soft_history_slack) continue;
        }
        float tap = i == 0 ? 2.0 : 1.0;
        total += value * tap;
        weight += tap;
    }
    return weight > 0.0 ? total / weight : -1.0;
}
static float soft_shadow_visibility = 2.0;

float3 localLights(FrameConstants frame, Surface surface, float2 pixel, float noise) {
    if ((SHADE_FEATURES & FEATURE_LOCAL_LIGHTS) == 0u || frame.lights.light_count == 0u) return float3(0.0);
    float3 color = float3(0.0);
    float3 soft_light = float3(0.0);
    float soft_weight = 0.0;
    float soft_lit = 0.0;
    uint cluster = clusterIndex(frame, pixel, surface.view_depth);
    uint count = frame.lights.clusters.data[cluster].count;
    for (uint i = 0u; i < count; i++) {
        Light light = frame.lights.lights.data[frame.lights.clusters.data[cluster].lights[i]];
        if ((light.flags & LIGHT_DIRECTIONAL) != 0u) {
            float3 l = -light.direction;
            if (dot(surface.normal, l) > 0.0) {
                float3 lit = surfaceLight(surface, l, light.color);
                float traced = tracedShadow(frame, light, surface.position, surface.normal, l, 1e4, noise);
                if ((light.flags & LIGHT_TRACED_SHADOW) != 0u && light.source_radius > 0.0) {
                    float brightness = dot(lit, float3(0.2126, 0.7152, 0.0722));
                    soft_light += lit;
                    soft_weight += brightness;
                    soft_lit += brightness * traced;
                } else {
                    color += lit * traced;
                }
            }
            continue;
        }
        float3 to_light = light.position - surface.position;
        float tube_length = (light.flags & (LIGHT_SPOT | LIGHT_RECTANGLE)) == 0u ? light.source_length : 0.0;
        float3 tube_center = to_light;
        if (tube_length > 0.0) to_light += light.direction * clamp(dot(-to_light, light.direction), -0.5 * tube_length, 0.5 * tube_length);
        bool panel = (light.flags & LIGHT_RECTANGLE) != 0u;
        if (panel) {
            float3 facing = light.direction;
            float3 right = normalize(cross(abs(facing.y) < 0.99 ? float3(0.0, 1.0, 0.0) : float3(1.0, 0.0, 0.0), facing));
            float3 up = cross(facing, right);
            float3 from_light = -to_light;
            if (dot(from_light, facing) <= 0.0) continue;
            float2 half_size = 0.5 * float2(light.source_length, light.source_height);
            float2 nearest = clamp(float2(dot(from_light, right), dot(from_light, up)), -half_size, half_size);
            float2 mirrored = nearest;
            float3 mirror = reflect(-surface.view, surface.normal);
            float toward = dot(mirror, facing);
            if (toward < -1e-4) {
                float3 met = from_light + mirror * (-dot(from_light, facing) / toward);
                mirrored = clamp(float2(dot(met, right), dot(met, up)), -half_size, half_size);
            }
            tube_center = to_light + right * mirrored.x + up * mirrored.y;
            to_light += right * nearest.x + up * nearest.y;
            tube_length = -max(light.source_length, light.source_height);
        }
        float distance_squared = dot(to_light, to_light);
        float range_squared = light.range * light.range;
        if (distance_squared > range_squared) continue;
        float window = clamp(1.0 - (distance_squared * distance_squared) / (range_squared * range_squared), 0.0, 1.0);
        float attenuation = window * window / max(distance_squared, max(light.source_radius * light.source_radius, 1e-4));
        float distance_to_light = sqrt(distance_squared);
        if (panel) attenuation *= clamp(dot(-to_light, light.direction) / max(distance_to_light, 1e-5), 0.0, 1.0);
        float3 l = to_light / max(distance_to_light, 1e-5);
        float3 radiance = light.color;
        if ((light.flags & LIGHT_SPOT) != 0u) {
            float cos_angle = dot(-l, light.direction);
            float cone = clamp(cos_angle * light.cone_scale + light.cone_offset, 0.0, 1.0);
            attenuation *= cone * cone;
            if (light.cookie != INVALID_ID && attenuation > 0.0) {
                float3 axis = light.direction;
                float3 side = normalize(abs(axis.y) < 0.99 ? cross(axis, float3(0.0, 1.0, 0.0)) : cross(axis, float3(1.0, 0.0, 0.0)));
                float3 up = cross(side, axis);
                float cos_outer = -light.cone_offset / max(light.cone_scale, 1e-5);
                float tan_outer = sqrt(max(1.0 - cos_outer * cos_outer, 0.0)) / max(cos_outer, 1e-3);
                float2 slide = float2(dot(-l, side), dot(-l, up)) / max(cos_angle, 1e-3) / max(tan_outer, 1e-3);
                radiance *= sampleTextureLod(light.cookie, frame.sampler_linear_clamp, slide * 0.5 + 0.5, 0.0).rgb;
            }
        }
        if (light.profile != INVALID_ID) {
            float angle = acos(clamp(dot(-l, light.direction), -1.0, 1.0)) / PI;
            attenuation *= sampleTextureLod(light.profile, frame.sampler_linear_clamp, float2(angle, 0.5), 0.0).r;
        }
        if (attenuation <= 0.0 || dot(surface.normal, l) <= -light.source_radius / max(distance_to_light, 1e-4)) continue;
        attenuation *= localShadow(frame, light, surface.position, surface.normal, l, distance_to_light, noise);
        bool soft = (light.flags & LIGHT_TRACED_SHADOW) != 0u && (light.source_radius > 0.0 || light.source_length > 0.0);
        float traced = 1.0;
        if (attenuation > 0.0) traced = tracedShadow(frame, light, surface.position, surface.normal, l, distance_to_light - 0.06, noise);
        if (!soft) attenuation *= traced;
        if (attenuation > 0.0 && (light.flags & LIGHT_FIRE) == 0u) attenuation *= fluidShadowToward(frame, surface.position, l, distance_to_light);
        if (attenuation <= 0.0) continue;
        float3 lit = sphereLight(surface, to_light, distance_to_light, light.source_radius, radiance * attenuation, tube_center, light.direction, tube_length);
        if (soft) {
            float brightness = dot(lit, float3(0.2126, 0.7152, 0.0722));
            soft_light += lit;
            soft_weight += brightness;
            soft_lit += brightness * traced;
        } else {
            color += lit;
        }
    }
    if (soft_weight > 0.0) {
        float now = soft_lit / soft_weight;
        float before = softShadowHistory(frame);
        soft_shadow_visibility = before >= 0.0 ? lerp(before, now, 0.12) : now;
        color += soft_light * soft_shadow_visibility;
    }
    return color;
}

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

float3 ambientLight(FrameConstants frame, Surface surface, float4 gathered) {
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

    float2 dfg = sampleTextureLod(frame.brdf_lut, s, float2(n_dot_v, surface.roughness), 0.0).rg;
    float3 specular_weight = surface.f0 * dfg.x + dfg.y;
    float3 color = irradiance * surface.diffuse_color * (1.0 - specular_weight) * multiBounceAo(surface.ao, surface.diffuse_color);
    color += surface.bounce * surface.diffuse_color * (1.0 - specular_weight);
    color += irradiance * surface.sheen_color * (0.08 + 0.92 * pow(1.0 - n_dot_v, 3.0)) * surface.ao;
    float3 energy_compensation = 1.0 + surface.f0 * (1.0 / max(dfg.x + dfg.y, 1e-4) - 1.0);
    float3 reflection_weight = specular_weight * energy_compensation * specularOcclusion(n_dot_v, surface.ao, surface.roughness);
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
    if (add_environment) color += ambientReflection(frame, surface.position, surface.view, mirror_normal, surface.roughness, sky_visibility) * reflection_weight;
    if (surface.clearcoat > 0.0) {
        float coat_n_dot_v = clamp(dot(surface.coat_normal, surface.view), 0.0, 1.0);
        float coat_fresnel = (0.04 + 0.96 * pow(1.0 - coat_n_dot_v, 5.0)) * surface.clearcoat;
        color *= 1.0 - coat_fresnel;
        if (has_environment) {
            float3 r = reflect(-surface.view, surface.coat_normal);
            float3 radiance = sampleCubeLod(frame.env_specular, s, r, surface.clearcoat_roughness * (frame.env_specular_mips - 1.0)).rgb * frame.env_intensity;
            color += radiance * coat_fresnel * specularOcclusion(coat_n_dot_v, surface.ao, surface.clearcoat_roughness) * sky_visibility;
        }
    }
    return color;
}

float3 shadeSurface(FrameConstants frame, Surface surface, float2 pixel, float noise, float4 gathered_gi) {
    float3 color = float3(0.0);
    float3 l = frame.sun_direction;
    float n_dot_l = clamp(dot(surface.normal, l), 0.0, 1.0);
    if (n_dot_l > 0.0 && dot(frame.sun_radiance, float3(1.0)) > 0.0) {
        float shadow = sunShadow(frame, surface.position, surface.normal, n_dot_l, surface.view_depth, noise);
        if (shadow > 0.0) shadow *= contactShadow(frame, surface.position, noise);
        if (shadow > 0.0)
            color += surfaceLight(surface, l, frame.sun_radiance * sunTint(frame, surface.position, surface.view_depth)) * shadow;
    }
    if (surface.subsurface > 0.0 && dot(frame.sun_radiance, float3(1.0)) > 0.0) {
        float wrap = clamp((dot(surface.normal, l) + surface.subsurface) / (1.0 + surface.subsurface), 0.0, 1.0);
        float through = pow(clamp(dot(surface.view, -l), 0.0, 1.0), 4.0) * surface.subsurface;
        float lit_behind = sunShadow(frame, surface.position + surface.normal * (0.1 + 0.5 * surface.subsurface), l, 1.0, surface.view_depth, noise);
        color += surface.diffuse_color * frame.sun_radiance * ((max(wrap * wrap - n_dot_l, 0.0) * 0.7 + through * 0.25) / PI) * lit_behind;
    }
    color += localLights(frame, surface, pixel, noise);
    color += ambientLight(frame, surface, gathered_gi);
    return color;
}

#endif
