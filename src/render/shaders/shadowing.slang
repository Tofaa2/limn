#ifndef SHADOWING_SLANG
#define SHADOWING_SLANG

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

/// The page `virtualTap` looked up last, so taps in it skip the page table.
static uint vsm_seen_level = 0xffffffffu;
static int2 vsm_seen_page = int2(0);
static float2 vsm_seen_corner = float2(-1.0);

/// One comparison tap of the virtual shadow map at `point` of `level`, from
/// whichever page holds it; -1 where that page is not drawn.
float virtualTap(FrameConstants frame, VsmData* vsm, uint level, float2 point, float depth) {
    int2 page;
    float2 within;
    if (!vsmLocate(vsm, level, point, page, within)) return -1.0;
    if (level != vsm_seen_level || any(page != vsm_seen_page)) {
        VsmPage entry = vsm.pages[vsmSlot(level, page)];
        bool drawn = entry.key == vsmKey(page) && entry.place != 0u && (entry.flags & VSM_READY) != 0u;
        vsm_seen_level = level;
        vsm_seen_page = page;
        vsm_seen_corner = drawn ? float2(float((entry.place - 1u) % uint(vsm_atlas_pages)), float((entry.place - 1u) / uint(vsm_atlas_pages))) : float2(-1.0);
    }
    if (vsm_seen_corner.x < 0.0) return -1.0;
    float2 corner = vsm_seen_corner;
    float2 inside = clamp(within, float2(0.5 / vsm_page_texels), float2(1.0 - 0.5 / vsm_page_texels));
    return textures_2d[NonUniformResourceIndex(vsm.atlas_texture)].SampleCmpLevelZero(samplers_shadow[NonUniformResourceIndex(frame.shadows.shadow_sampler)], (corner + inside) / float(vsm_atlas_pages), depth);
}

/// Taps spread over `Settings.shadows.softness`, crossing page edges; -1
/// where the page under the point is not drawn.
float virtualShadow(FrameConstants frame, float3 world_position, float3 normal, float n_dot_l, float noise) {
    VsmData* vsm = frame.shadows.vsm.data;
    float2 unmoved = (mul(vsm.light_view, float4(world_position, 1.0))).xy;
    for (uint level = vsmLevel(vsm, unmoved); level < vsm.levels; level++) {
        float texel = vsmExtent(vsm, level) / (float(vsm_pages) * vsm_page_texels);
        float3 at = (mul(vsm.light_view, float4(world_position + normal * texel * (1.5 + 2.5 * (1.0 - n_dot_l)), 1.0))).xyz;
        float depth = (at.z - vsm.depth_from) / vsm.depth_range;
        float middle = virtualTap(frame, vsm, level, at.xy, depth);
        if (middle < 0.0) continue;
        float radius = max(frame.shadows.shadow_softness, texel);
        float rotation = noise * 2.0 * PI;
        float c = cos(rotation);
        float s = sin(rotation);
        float2x2 rotate = float2x2(c, s, -s, c);
        uint wanted = clamp(frame.shadows.shadow_taps, 4u, 16u);
        int stride = wanted >= 16u ? 1 : (wanted >= 8u ? 2 : 4);
        float lit = middle;
        float taps = 1.0;
        for (int i = 3; i < 16; i += 4) {
            float tap = virtualTap(frame, vsm, level, at.xy + mul(vogel_disk[i], rotate) * radius, depth);
            if (tap < 0.0) continue;
            lit += tap;
            taps += 1.0;
        }
        if (lit <= 0.0 || lit >= taps || stride == 4) return lit / taps;
        for (int i = 0; i < 16; i += stride) {
            if ((i & 3) == 3) continue;
            float tap = virtualTap(frame, vsm, level, at.xy + mul(vogel_disk[i], rotate) * radius, depth);
            if (tap < 0.0) continue;
            lit += tap;
            taps += 1.0;
        }
        return lit / taps;
    }
    return -1.0;
}

float sunShadow(FrameConstants frame, float3 world_position, float3 normal, float n_dot_l, float view_depth, float noise) {
    float past_geometry = -1.0;
    if (frame.shadows.virtual_maps != 0u) past_geometry = virtualShadow(frame, world_position, normal, n_dot_l, noise);
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
        float3 across = normalize(cross(abs(l.y) < 0.99 ? float3(0.0, 1.0, 0.0) : float3(1.0, 0.0, 0.0), l));
        float3 across_up = cross(l, across);
        for (uint ray = 0u; ray < rays; ray++) {
            float2 pick = frac(float2(base + float(ray) * 0.61803399, base * 7.31 + 0.37 + float(ray) * 0.75487767)) - 0.5;
            float3 target = light.position;
            if ((light.flags & LIGHT_RECTANGLE) != 0u) {
                float3 facing = light.direction;
                float3 right = normalize(cross(abs(facing.y) < 0.99 ? float3(0.0, 1.0, 0.0) : float3(1.0, 0.0, 0.0), facing));
                target += right * (pick.x * light.source_length) + cross(facing, right) * (pick.y * light.source_height);
            } else {
                if ((light.flags & LIGHT_SPOT) == 0u) target += light.direction * (pick.x * light.source_length);
                float angle = (pick.y + 0.5) * 6.2831853;
                float out_from_center = light.source_radius * sqrt(frac(base * 3.17 + 0.11 + float(ray) * 0.56984029));
                target += (across * cos(angle) + across_up * sin(angle)) * out_from_center;
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

#endif
