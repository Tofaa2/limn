// Surface shading shared by the deferred lighting pass and the forward
// (transparent) pass: sun with cascaded shadows, clustered local lights with
// atlas shadows, and ambient light from probes or the environment.
#ifndef SHADING_GLSL
#define SHADING_GLSL

#include "brdf.glsl"
#include "gi.glsl"
#include "clouds.glsl"
#include "fluid.glsl"
#ifdef RAY_TRACED
#include "rt.glsl"
#endif

struct Surface {
    vec3 position;
    vec3 normal;
    vec3 view;          // toward the camera
    vec3 diffuse_color;
    vec3 f0;
    float roughness;
    float ao;
    // Light from the surfaces close by that block the sky (see gtao.frag).
    vec3 bounce;
    float view_depth;   // distance along the view axis
    // Strength and roughness of a clear layer on top; 0 for none.
    float clearcoat;
    float clearcoat_roughness;
    // The coat's own normal: the smooth surface or its own map, not the
    // base's normal map.
    vec3 coat_normal;
    // Color and roughness of a cloth-like sheen; black for none.
    vec3 sheen_color;
    float sheen_roughness;
    // Strength of stretched highlights and the direction they stretch
    // along, in the surface; 0 for none.
    float anisotropy;
    vec3 grain;
    // How far light spreads under the surface, 0..1.
    float subsurface;
};

const vec2 vogel_disk[16] = vec2[](
    vec2(0.1768, 0.0000), vec2(-0.2257, 0.2068), vec2(0.0345, -0.3938), vec2(0.2845, 0.3703),
    vec2(-0.5265, -0.0696), vec2(0.4594, -0.3632), vec2(-0.1158, 0.6272), vec2(-0.4117, -0.5510),
    vec2(0.7123, 0.1728), vec2(-0.6434, 0.4302), vec2(0.2334, -0.7767), vec2(0.4298, 0.7324),
    vec2(-0.8291, -0.2950), vec2(0.8183, -0.4133), vec2(-0.3632, 0.8715), vec2(-0.3838, -0.9010));

float sampleCascade(FrameConstants frame, uint cascade, vec3 world_position, vec3 normal, float n_dot_l, float rotation) {
    // Offset along the normal by a couple of texels to hide acne on
    // surfaces at grazing angles to the light.
    float texel = frame.cascade_texel_size[cascade];
    vec3 biased = world_position + normal * texel * (1.5 + 2.5 * (1.0 - n_dot_l));
    vec4 clip = frame.cascade_view_proj[cascade] * vec4(biased, 1.0);
    vec3 coord = vec3(clip.xy * 0.5 + 0.5, clip.z);
    if (coord.z >= 1.0) return 1.0;
    float c = cos(rotation);
    float s = sin(rotation);
    mat2 rotate = mat2(c, s, -s, c);
    // Constant world-space penumbra across cascades.
    float radius = frame.shadow_softness / (texel * float(textureSize(textures_2d_array[nonuniformEXT(frame.shadow_map)], 0).x));
    #define SHADOW_TAP(index) texture( \
        sampler2DArrayShadow(textures_2d_array[nonuniformEXT(frame.shadow_map)], samplers_shadow[nonuniformEXT(frame.shadow_sampler)]), \
        vec4(coord.xy + rotate * vogel_disk[index] * radius, float(cascade), coord.z))
    // Four taps spread over the kernel decide whether this pixel is in a
    // penumbra at all; fully lit and fully shadowed pixels stop here.
    float lit = SHADOW_TAP(3) + SHADOW_TAP(7) + SHADOW_TAP(11) + SHADOW_TAP(15);
    if (lit <= 0.0 || lit >= 4.0) return lit * 0.25;
    // The four test taps always count; the rest are added by quality.
    if (frame.shadow_taps <= 4u) return lit * 0.25;
    int stride = frame.shadow_taps >= 16u ? 1 : 2;
    float taps = 4.0;
    for (int i = 0; i < 16; i += stride) {
        if ((i & 3) == 3) continue;
        lit += SHADOW_TAP(i);
        taps += 1.0;
    }
    #undef SHADOW_TAP
    return lit / taps;
}

float cascadeShadow(FrameConstants frame, vec3 world_position, vec3 normal, float n_dot_l, float view_depth, float noise) {
    if ((frame.flags & FRAME_SHADOWS) == 0u) return 1.0;
    uint cascade = 0u;
    for (uint i = 0u; i < 3u; i++) {
        if (view_depth > frame.cascade_splits[i]) cascade = i + 1u;
    }
    if (view_depth > frame.cascade_splits[3]) return 1.0;
    float rotation = noise * 2.0 * PI;
    float lit = sampleCascade(frame, cascade, world_position, normal, n_dot_l, rotation);
    // Dither across the last 10% of each cascade to hide the seam.
    float split = frame.cascade_splits[cascade];
    float band = split * 0.1;
    float blend = clamp((view_depth - (split - band)) / band, 0.0, 1.0);
    if (blend > 0.0) {
        float next = cascade < 3u ? sampleCascade(frame, cascade + 1u, world_position, normal, n_dot_l, rotation) : 1.0;
        lit = mix(lit, next, blend);
    }
    return lit;
}

// Sun reaching a point: past the scene's geometry and the clouds.
float sunShadow(FrameConstants frame, vec3 world_position, vec3 normal, float n_dot_l, float view_depth, float noise) {
    return cascadeShadow(frame, world_position, normal, n_dot_l, view_depth, noise) * cloudShadow(frame, world_position) * fluidShadow(frame, world_position);
}

// The color see-through casters leave the sunlight with at a point: the
// product of what each lets pass, for points behind the nearest of them.
vec3 sunTint(FrameConstants frame, vec3 world_position, float view_depth) {
    if ((SHADE_FEATURES & FEATURE_COLORED_SHADOWS) == 0u || (frame.flags & FRAME_COLORED_SHADOWS) == 0u) return vec3(1.0);
    uint cascade = 0u;
    for (uint i = 0u; i < 3u; i++) {
        if (view_depth > frame.cascade_splits[i]) cascade = i + 1u;
    }
    if (view_depth > frame.cascade_splits[3]) return vec3(1.0);
    vec4 clip = frame.cascade_view_proj[cascade] * vec4(world_position, 1.0);
    vec2 uv = clip.xy * 0.5 + 0.5;
    if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) return vec3(1.0);
    vec4 tint = textureLod(sampler2DArray(textures_2d_array[nonuniformEXT(frame.shadow_color)], samplers[nonuniformEXT(frame.sampler_linear_clamp)]), vec3(uv, float(cascade)), 0.0);
    // Alpha is the depth of the nearest such caster, coarsely: what is in
    // front of it, or just behind, is not tinted. The nearest of the four
    // texels around is used: filtered across the edge of a caster the
    // depth would be meaningless, and the edge is already soft in rgb.
    vec4 depths = textureGather(sampler2DArray(textures_2d_array[nonuniformEXT(frame.shadow_color)], samplers[nonuniformEXT(frame.sampler_linear_clamp)]), vec3(uv, float(cascade)), 3);
    float nearest_caster = min(min(depths.x, depths.y), min(depths.z, depths.w));
    // front of it, or just behind, is not tinted.
    return clip.z > nearest_caster + 0.01 ? tint.rgb : vec3(1.0);
}

// Small shadows the cascades are too coarse for (where a foot meets the
// floor, under a ledge): a short walk toward the sun through the depth
// buffer. Only what is on screen can cast them.
float contactShadow(FrameConstants frame, vec3 position, float noise) {
#ifdef CONTACT_SHADOWS
    if (frame.contact_depth == INVALID_ID || frame.contact_length <= 0.0) return 1.0;
    const int steps = 12;
    vec3 stride = frame.sun_direction * (frame.contact_length / float(steps));
    vec3 point = position + stride * noise;
    for (int i = 0; i < steps; i++) {
        point += stride;
        vec4 clip = frame.view_proj * vec4(point, 1.0);
        if (clip.w <= frame.near) break;
        vec2 uv = clip.xy / clip.w * 0.5 + 0.5;
        if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) break;
        float scene = linearDepth(textureLod(TEX(frame.contact_depth, frame.sampler_nearest_clamp), uv, 0.0).r, frame.near);
        float behind = clip.w - scene;
        // Hidden behind something thin enough to be a real blocker, not
        // merely passing behind a wall far in front.
        if (behind > 0.01 * clip.w + 0.005 && behind < frame.contact_length) return 0.0;
    }
#endif
    return 1.0;
}

vec3 directLight(vec3 n, vec3 v, vec3 l, vec3 radiance, vec3 diffuse_color, vec3 f0, float roughness) {
    float n_dot_l = clamp(dot(n, l), 0.0, 1.0);
    if (n_dot_l <= 0.0) return vec3(0.0);
    vec3 h = normalize(v + l);
    float n_dot_v = max(dot(n, v), 1e-4);
    float n_dot_h = clamp(dot(n, h), 0.0, 1.0);
    float alpha = roughness * roughness;
    vec3 fresnel = fresnelSchlick(clamp(dot(v, h), 0.0, 1.0), f0);
    vec3 specular = fresnel * (distributionGgx(n_dot_h, alpha) * visibilitySmithGgx(n_dot_l, n_dot_v, alpha));
    vec3 diffuse = diffuse_color * (1.0 - fresnel) / PI;
    return (diffuse + specular) * radiance * n_dot_l;
}

// Light from one direction on a surface, including its clear coat: the
// coat reflects a little at its own (usually low) roughness and lets the
// rest through to the base.
// Direct light with highlights stretched along the surface's grain
// (anisotropic GGX, as in KHR_materials_anisotropy).
vec3 grainLight(Surface surface, vec3 l, vec3 radiance) {
    vec3 n = surface.normal;
    vec3 v = surface.view;
    float n_dot_l = clamp(dot(n, l), 0.0, 1.0);
    if (n_dot_l <= 0.0) return vec3(0.0);
    vec3 h = normalize(v + l);
    float n_dot_v = max(dot(n, v), 1e-4);
    vec3 t = surface.grain;
    vec3 b = cross(n, t);
    float across = max(surface.roughness * surface.roughness, 0.002);
    float along = mix(across, 1.0, surface.anisotropy * surface.anisotropy);
    vec3 scaled = vec3(dot(t, h) / along, dot(b, h) / across, dot(n, h));
    float distribution = 1.0 / (PI * along * across * dot(scaled, scaled) * dot(scaled, scaled));
    float visibility = 0.5 / max(n_dot_l * length(vec3(along * dot(t, v), across * dot(b, v), n_dot_v)) +
        n_dot_v * length(vec3(along * dot(t, l), across * dot(b, l), n_dot_l)), 1e-5);
    vec3 fresnel = fresnelSchlick(clamp(dot(v, h), 0.0, 1.0), surface.f0);
    vec3 diffuse = surface.diffuse_color * (1.0 - fresnel) / PI;
    return (diffuse + fresnel * min(distribution * visibility, 1e4)) * radiance * n_dot_l;
}

vec3 surfaceLight(Surface surface, vec3 l, vec3 radiance) {
    vec3 base = surface.anisotropy > 0.0
        ? grainLight(surface, l, radiance)
        : directLight(surface.normal, surface.view, l, radiance, surface.diffuse_color, surface.f0, surface.roughness);
    float sheen_strength = max(surface.sheen_color.r, max(surface.sheen_color.g, surface.sheen_color.b));
    if (surface.clearcoat <= 0.0 && sheen_strength <= 0.0) return base;
    float n_dot_l = clamp(dot(surface.normal, l), 0.0, 1.0);
    if (n_dot_l <= 0.0) return base;
    vec3 h = normalize(surface.view + l);
    float n_dot_v = max(dot(surface.normal, surface.view), 1e-4);
    if (sheen_strength > 0.0) {
        // Fibres standing off the surface catch light at grazing angles
        // (the "Charlie" distribution of Estevez and Kulla, with Neubelt's
        // visibility term).
        float inverse_alpha = 1.0 / max(surface.sheen_roughness * surface.sheen_roughness, 0.005);
        float n_dot_h = clamp(dot(surface.normal, h), 0.0, 1.0);
        float sin_squared = 1.0 - n_dot_h * n_dot_h;
        float distribution = (2.0 + inverse_alpha) * pow(sin_squared, 0.5 * inverse_alpha) / (2.0 * PI);
        float visibility = 1.0 / (4.0 * (n_dot_l + n_dot_v - n_dot_l * n_dot_v));
        // What the fibres scatter does not reach the surface under them.
        base = base * (1.0 - 0.3 * sheen_strength) + surface.sheen_color * radiance * (distribution * visibility * n_dot_l);
    }
    if (surface.clearcoat <= 0.0) return base;
    float coat_n_dot_l = clamp(dot(surface.coat_normal, l), 0.0, 1.0);
    float coat_fresnel = fresnelSchlick(clamp(dot(surface.view, h), 0.0, 1.0), vec3(0.04)).x * surface.clearcoat;
    float alpha = max(surface.clearcoat_roughness * surface.clearcoat_roughness, 0.002);
    float coat = distributionGgx(clamp(dot(surface.coat_normal, h), 0.0, 1.0), alpha) * visibilitySmithGgx(coat_n_dot_l, max(dot(surface.coat_normal, surface.view), 1e-4), alpha) * coat_fresnel;
    return base * (1.0 - coat_fresnel) + radiance * (coat_n_dot_l * coat);
}

// Jimenez et al.: approximate interreflections inside occluded creases so
// that AO does not over-darken bright albedos.
vec3 multiBounceAo(float ao, vec3 albedo) {
    vec3 a = 2.0404 * albedo - 0.3324;
    vec3 b = -4.7951 * albedo + 0.6417;
    vec3 c = 2.7552 * albedo + 0.6903;
    return max(vec3(ao), ((ao * a + b) * ao + c) * ao);
}

float specularOcclusion(float n_dot_v, float ao, float roughness) {
    return clamp(pow(n_dot_v + ao, exp2(-16.0 * roughness - 1.0)) - 1.0 + ao, 0.0, 1.0);
}

// Index of the froxel containing a pixel at a given view depth.
uint clusterIndex(FrameConstants frame, vec2 pixel, float view_depth) {
    uvec2 tile = min(uvec2(pixel * frame.inv_resolution * vec2(CLUSTERS_X, CLUSTERS_Y)), uvec2(CLUSTERS_X - 1u, CLUSTERS_Y - 1u));
    float slice = log2(max(view_depth, 1e-4)) * frame.cluster_z_scale + frame.cluster_z_bias;
    uint z = uint(clamp(slice, 0.0, float(CLUSTERS_Z - 1u)));
    return tile.x + tile.y * CLUSTERS_X + z * CLUSTERS_X * CLUSTERS_Y;
}

// Opens a loop over the decals that reach the cluster `position` is in, in
// index order, with `i` the decal's index. Expects `frame` and `instance`.
#define DECAL_LOOP_BEGIN(position) \
    uint decal_cluster = clusterIndex(frame, gl_FragCoord.xy, -(frame.view * vec4(position, 1.0)).z); \
    for (uint decal_word = 0u; decal_word < ((SHADE_FEATURES & FEATURE_DECALS) == 0u || (instance.flags & INSTANCE_NO_DECALS) != 0u ? 0u : (frame.decal_count + 31u) >> 5u); decal_word++) \
    for (uint decal_bits = frame.clusters.data[decal_cluster].decals[decal_word]; decal_bits != 0u; decal_bits &= decal_bits - 1u) { \
        uint i = decal_word * 32u + uint(findLSB(decal_bits));

// Shadow of a local light from the tile atlas (reverse-Z perspective).
// Shadow of a light that has no shadow map (a second sun, a panel, a
// tube, or a lamp past the shadow tile budget): one ray toward it.
float tracedShadow(FrameConstants frame, Light light, vec3 position, vec3 normal, vec3 l, float reach, float noise) {
#ifdef RAY_TRACED
    if ((SHADE_FEATURES & FEATURE_TRACED_LIGHT_SHADOWS) == 0u || (light.flags & LIGHT_TRACED_SHADOW) == 0u || (frame.tlas_low | frame.tlas_high) == 0u) return 1.0;
    uint64_t tlas = uint64_t(frame.tlas_low) | (uint64_t(frame.tlas_high) << 32);
    vec3 origin = position + normal * 0.03;
    if ((light.flags & LIGHT_DIRECTIONAL) == 0u && (light.source_radius > 0.0 || light.source_length > 0.0)) {
        // A light with a size: several rays to different points of it,
        // averaged, the points changing every frame so that temporal
        // antialiasing fills in between them. One ray per frame flickers
        // visibly; a pattern fixed in time leaves a visible dither. Several
        // rays that change is the combination that does neither.
        uint rays = max((frame.flags >> 16) & 15u, 1u);
        float base = noise;
        float lit = 0.0;
        for (uint ray = 0u; ray < rays; ray++) {
            vec2 pick = fract(vec2(base + float(ray) * 0.61803399, base * 7.31 + 0.37 + float(ray) * 0.75487767)) - 0.5;
            vec3 target = light.position;
            if ((light.flags & LIGHT_RECTANGLE) != 0u) {
                vec3 facing = light.direction;
                vec3 right = normalize(cross(abs(facing.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0), facing));
                target += right * (pick.x * light.source_length) + cross(facing, right) * (pick.y * light.source_height);
            } else {
                if ((light.flags & LIGHT_SPOT) == 0u) target += light.direction * (pick.x * light.source_length);
                // A point inside the sphere, roughly.
                float angle = pick.y * 6.2831853;
                target += vec3(cos(angle), sin(angle * 1.7), sin(angle)) * (light.source_radius * fract(base * 3.17 + 0.11 + float(ray) * 0.37));
            }
            vec3 toward = target - origin;
            float distance_there = length(toward);
            lit += rtOccluded(tlas, origin, toward / max(distance_there, 1e-5), distance_there - 0.06) ? 0.0 : 1.0;
        }
        return lit / float(rays);
    }
    return rtOccluded(tlas, origin, l, reach) ? 0.0 : 1.0;
#else
    return 1.0;
#endif
}

// Widest shadow filter, in shadow map texels, for a light with a size.
const float LOCAL_SHADOW_MAX_KERNEL = 14.0;

float localShadow(FrameConstants frame, Light light, vec3 world_position, vec3 normal, vec3 to_light, float distance_to_light, float noise) {
    uint first = light.flags >> 8;
    if (first == 0u) return 1.0;
    uint tile_index = first - 1u;
    if ((light.flags & LIGHT_SPOT) == 0u) {
        // Point light: six tiles in +X, -X, +Y, -Y, +Z, -Z order.
        vec3 d = -to_light;
        vec3 a = abs(d);
        if (a.x >= a.y && a.x >= a.z) tile_index += d.x > 0.0 ? 0u : 1u;
        else if (a.y >= a.z) tile_index += d.y > 0.0 ? 2u : 3u;
        else tile_index += d.z > 0.0 ? 4u : 5u;
    }
    ShadowTile tile = frame.shadow_tiles.data[tile_index];
    vec2 atlas_size = vec2(textureSize(textures_2d[nonuniformEXT(frame.local_shadow_map)], 0));
    // World size of one shadow texel at this distance sets the bias.
    float texel_world = distance_to_light * 2.0 / (tile.rect.x * atlas_size.x);
    vec3 biased = world_position + normal * texel_world * 2.0 + to_light * texel_world;
    vec4 clip = tile.view_proj * vec4(biased, 1.0);
    if (clip.w <= 0.0) return 1.0;
    vec3 ndc = clip.xyz / clip.w;
    vec2 tile_uv = ndc.xy * 0.5 + 0.5;
    if (any(lessThan(tile_uv, vec2(0.0))) || any(greaterThan(tile_uv, vec2(1.0)))) return 1.0;
    vec2 texel = 1.0 / atlas_size;
    vec2 low = tile.rect.zw + texel;
    vec2 high = tile.rect.zw + tile.rect.xy - texel;
    float c = cos(noise * 2.0 * PI);
    float s = sin(noise * 2.0 * PI);
    mat2 rotate = mat2(c, s, -s, c);
    // A light with a size casts shadows that widen with the distance
    // between what blocks it and what the shadow falls on: find how far
    // the blockers around this point are and size the filter to match.
    float kernel = 2.5;
    if ((SHADE_FEATURES & FEATURE_SIZED_LIGHTS) != 0u && light.source_radius > 0.0) {
        float texels_per_world = tile.rect.x * atlas_size.x * 0.5 / distance_to_light;
        float search = clamp(light.source_radius * texels_per_world, 2.5, LOCAL_SHADOW_MAX_KERNEL);
        float blockers = 0.0;
        float blocker_z = 0.0;
        for (int i = 0; i < 16; i += 2) {
            vec2 at = clamp(tile_uv * tile.rect.xy + tile.rect.zw + rotate * vogel_disk[i] * texel * search, low, high);
            float z = textureLod(TEX(frame.local_shadow_map, frame.sampler_nearest_clamp), at, 0.0).r;
            if (z > ndc.z) {
                blockers += 1.0;
                blocker_z += z;
            }
        }
        if (blockers == 0.0) return 1.0;
        // These tiles store near / distance, so the ratio of the two
        // stored values is the receiver's distance over the blockers'.
        float ratio = (blocker_z / blockers) / ndc.z;
        kernel = clamp(light.source_radius * (ratio - 1.0) * texels_per_world, 2.5, LOCAL_SHADOW_MAX_KERNEL);
        if (kernel > 2.5) {
            // A wider filter needs the point pushed further off the surface.
            biased = world_position + normal * texel_world * (0.8 * kernel) + to_light * texel_world * (0.4 * kernel);
            clip = tile.view_proj * vec4(biased, 1.0);
            ndc = clip.xyz / clip.w;
            tile_uv = ndc.xy * 0.5 + 0.5;
        }
    }
    #define LOCAL_SHADOW_TAP(index) texture( \
        sampler2DShadow(textures_2d[nonuniformEXT(frame.local_shadow_map)], samplers_shadow[nonuniformEXT(frame.local_shadow_sampler)]), \
        vec3(clamp(tile_uv * tile.rect.xy + tile.rect.zw + rotate * vogel_disk[index] * texel * kernel, low, high), ndc.z))
    // Four taps spread over the kernel settle pixels that are fully lit
    // or fully shadowed; penumbra pixels take eight more, which is what
    // keeps shadow edges from crawling.
    float lit = LOCAL_SHADOW_TAP(3) + LOCAL_SHADOW_TAP(7) + LOCAL_SHADOW_TAP(11) + LOCAL_SHADOW_TAP(15);
    if (lit <= 0.0 || lit >= 4.0) return lit * 0.25;
    for (int i = 0; i < 16; i += 2) lit += LOCAL_SHADOW_TAP(i);
    #undef LOCAL_SHADOW_TAP
    return lit / 12.0;
}

// Light from a sphere of the given radius instead of a point: the
// highlight is as wide as the sphere looks from the surface (Karis 2013,
// "representative point"), with the energy spread accordingly.
vec3 sphereLight(Surface surface, vec3 to_light, float distance_to_light, float radius, vec3 radiance, vec3 tube_center, vec3 tube_axis, float tube_length) {
    vec3 l = to_light / max(distance_to_light, 1e-5);
    if (radius <= 0.0 && tube_length == 0.0) return surfaceLight(surface, l, radiance);
    // The point of the sphere closest to the mirror direction stands in
    // for the whole light when computing the highlight.
    vec3 mirror = reflect(-surface.view, surface.normal);
    vec3 center = to_light;
    float line_normalization = 1.0;
    if (tube_length > 0.0) {
        // A tube: first the point of its axis nearest the mirror ray
        // (Karis, "Real Shading in Unreal Engine 4"), then the sphere
        // around that point as before.
        vec3 a = tube_center - tube_axis * (0.5 * tube_length);
        vec3 ab = tube_axis * tube_length;
        float along = dot(mirror, ab);
        float t = clamp((dot(mirror, a) * along - dot(a, ab)) / max(dot(ab, ab) - along * along, 1e-5), 0.0, 1.0);
        center = a + ab * t;
        float alpha_line = surface.roughness * surface.roughness;
        line_normalization = alpha_line / clamp(alpha_line + tube_length / (2.0 * distance_to_light), 1e-4, 1.0);
    }
    if (tube_length < 0.0) {
        // A panel: the caller found the point of it nearest the mirror
        // ray; its size widens the highlight.
        center = tube_center;
        float alpha_panel = surface.roughness * surface.roughness;
        line_normalization = alpha_panel / clamp(alpha_panel - tube_length / (2.0 * distance_to_light), 1e-4, 1.0);
    }
    vec3 center_to_ray = dot(center, mirror) * mirror - center;
    vec3 closest = center + center_to_ray * clamp(radius / max(length(center_to_ray), 1e-5), 0.0, 1.0);
    vec3 specular_l = normalize(closest);
    float alpha = surface.roughness * surface.roughness;
    float widened = clamp(alpha + radius / (2.0 * distance_to_light), 0.0, 1.0);
    float normalization = (alpha / max(widened, 1e-4)) * (alpha / max(widened, 1e-4)) * line_normalization;
    // Diffuse from the center, specular from the representative point.
    Surface diffuse_only = surface;
    diffuse_only.f0 = vec3(0.0);
    diffuse_only.clearcoat = 0.0;
    Surface specular_only = surface;
    specular_only.diffuse_color = vec3(0.0);
    return surfaceLight(diffuse_only, l, radiance) + surfaceLight(specular_only, specular_l, radiance) * normalization;
}

// Soft ray-traced shadows are a few rays per pixel, which is grainy where
// little of a light is in sight. The opaque pass therefore carries how much
// of the soft lights reached each point from frame to frame: it sets
// `soft_shadow_history` to last frame's value (negative for none) before
// shading and stores `soft_shadow_visibility` afterwards.
float soft_shadow_history = -1.0;
// 2 where no soft-shadowed light reaches: nothing to carry.
float soft_shadow_visibility = 2.0;

vec3 localLights(FrameConstants frame, Surface surface, vec2 pixel, float noise) {
    if ((SHADE_FEATURES & FEATURE_LOCAL_LIGHTS) == 0u || frame.light_count == 0u) return vec3(0.0);
    vec3 color = vec3(0.0);
    // Light from sources with soft traced shadows, before shadowing, and
    // how much of it (by brightness) this frame's rays let through.
    vec3 soft_light = vec3(0.0);
    float soft_weight = 0.0;
    float soft_lit = 0.0;
    uint cluster = clusterIndex(frame, pixel, surface.view_depth);
    uint count = frame.clusters.data[cluster].count;
    for (uint i = 0u; i < count; i++) {
        Light light = frame.lights.data[frame.clusters.data[cluster].lights[i]];
        if ((light.flags & LIGHT_DIRECTIONAL) != 0u) {
            // A second sun: the same light everywhere, no falloff.
            vec3 l = -light.direction;
            if (dot(surface.normal, l) > 0.0) color += surfaceLight(surface, l, light.color) * tracedShadow(frame, light, surface.position, surface.normal, l, 1e4, noise);
            continue;
        }
        vec3 to_light = light.position - surface.position;
        // A tube: brightness falls off from, and diffuse light comes from,
        // the point of its axis nearest the surface.
        float tube_length = (light.flags & (LIGHT_SPOT | LIGHT_RECTANGLE)) == 0u ? light.source_length : 0.0;
        vec3 tube_center = to_light;
        if (tube_length > 0.0) to_light += light.direction * clamp(dot(-to_light, light.direction), -0.5 * tube_length, 0.5 * tube_length);
        bool panel = (light.flags & LIGHT_RECTANGLE) != 0u;
        if (panel) {
            // A glowing rectangle facing along its direction. Diffuse
            // light and falloff come from its nearest point, the
            // highlight from where the mirror ray meets it.
            vec3 facing = light.direction;
            vec3 right = normalize(cross(abs(facing.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0), facing));
            vec3 up = cross(facing, right);
            vec3 from_light = -to_light;
            if (dot(from_light, facing) <= 0.0) continue;
            vec2 half_size = 0.5 * vec2(light.source_length, light.source_height);
            vec2 nearest = clamp(vec2(dot(from_light, right), dot(from_light, up)), -half_size, half_size);
            vec2 mirrored = nearest;
            vec3 mirror = reflect(-surface.view, surface.normal);
            float toward = dot(mirror, facing);
            if (toward < -1e-4) {
                vec3 met = from_light + mirror * (-dot(from_light, facing) / toward);
                mirrored = clamp(vec2(dot(met, right), dot(met, up)), -half_size, half_size);
            }
            tube_center = to_light + right * mirrored.x + up * mirrored.y;
            to_light += right * nearest.x + up * nearest.y;
            tube_length = -max(light.source_length, light.source_height);
        }
        float distance_squared = dot(to_light, to_light);
        float range_squared = light.range * light.range;
        if (distance_squared > range_squared) continue;
        // glTF inverse-square falloff, windowed so it reaches zero at range.
        float window = clamp(1.0 - (distance_squared * distance_squared) / (range_squared * range_squared), 0.0, 1.0);
        // A source with a size cannot get brighter than its own surface.
        float attenuation = window * window / max(distance_squared, max(light.source_radius * light.source_radius, 1e-4));
        float distance_to_light = sqrt(distance_squared);
        // A panel shines most straight ahead and not at all sideways.
        if (panel) attenuation *= clamp(dot(-to_light, light.direction) / max(distance_to_light, 1e-5), 0.0, 1.0);
        vec3 l = to_light / max(distance_to_light, 1e-5);
        vec3 radiance = light.color;
        if ((light.flags & LIGHT_SPOT) != 0u) {
            float cos_angle = dot(-l, light.direction);
            float cone = clamp(cos_angle * light.cone_scale + light.cone_offset, 0.0, 1.0);
            attenuation *= cone * cone;
            if (light.cookie != INVALID_ID && attenuation > 0.0) {
                // Project the image like a slide: the cone's edge maps to
                // the image's inscribed circle.
                vec3 axis = light.direction;
                vec3 side = normalize(abs(axis.y) < 0.99 ? cross(axis, vec3(0.0, 1.0, 0.0)) : cross(axis, vec3(1.0, 0.0, 0.0)));
                vec3 up = cross(side, axis);
                float cos_outer = -light.cone_offset / max(light.cone_scale, 1e-5);
                float tan_outer = sqrt(max(1.0 - cos_outer * cos_outer, 0.0)) / max(cos_outer, 1e-3);
                vec2 slide = vec2(dot(-l, side), dot(-l, up)) / max(cos_angle, 1e-3) / max(tan_outer, 1e-3);
                radiance *= textureLod(TEX(light.cookie, frame.sampler_linear_clamp), slide * 0.5 + 0.5, 0.0).rgb;
            }
        }
        if (light.profile != INVALID_ID) {
            // Measured or authored brightness by angle from the light's
            // axis: 0 along it, 1 straight back.
            float angle = acos(clamp(dot(-l, light.direction), -1.0, 1.0)) / PI;
            attenuation *= textureLod(TEX(light.profile, frame.sampler_linear_clamp), vec2(angle, 0.5), 0.0).r;
        }
        if (attenuation <= 0.0 || dot(surface.normal, l) <= -light.source_radius / max(distance_to_light, 1e-4)) continue;
        attenuation *= localShadow(frame, light, surface.position, surface.normal, l, distance_to_light, noise);
        bool soft = (light.flags & LIGHT_TRACED_SHADOW) != 0u && (light.source_radius > 0.0 || light.source_length > 0.0);
        float traced = attenuation > 0.0 ? tracedShadow(frame, light, surface.position, surface.normal, l, distance_to_light - 0.06, noise) : 1.0;
        if (!soft) attenuation *= traced;
        if (attenuation > 0.0 && (light.flags & LIGHT_FIRE) == 0u) attenuation *= fluidShadowToward(frame, surface.position, l, distance_to_light);
        if (attenuation <= 0.0) continue;
        vec3 lit = sphereLight(surface, to_light, distance_to_light, light.source_radius, radiance * attenuation, tube_center, light.direction, tube_length);
        if (soft) {
            float brightness = dot(lit, vec3(0.2126, 0.7152, 0.0722));
            soft_light += lit;
            soft_weight += brightness;
            soft_lit += brightness * traced;
        } else {
            color += lit;
        }
    }
    if (soft_weight > 0.0) {
        float now = soft_lit / soft_weight;
        soft_shadow_visibility = soft_shadow_history >= 0.0 ? mix(soft_shadow_history, now, 0.12) : now;
        color += soft_light * soft_shadow_visibility;
    }
    return color;
}

// Diffuse and specular ambient light.
// `gathered` is probe irradiance already evaluated for this pixel at reduced
// What the sky shows in the mirror direction of a surface, blurred by its
// roughness.
vec3 environmentReflection(FrameConstants frame, vec3 view, vec3 normal, float roughness) {
    vec3 r = reflect(-view, normal);
    // Rough surfaces reflect closer to the normal than the mirror direction.
    r = normalize(mix(r, normal, roughness * roughness * roughness));
    return textureLod(TEX_CUBE(frame.env_specular, frame.sampler_linear_clamp), r, roughness * (frame.env_specular_mips - 1.0)).rgb * frame.env_intensity;
}

// Aerial perspective: what the air between the eye and a surface does to
// its light. `through` is the share that arrives and `air` the light the
// air itself sends toward the eye where it is thick enough to hide the
// surface, so that the result is `lit * through + air * (1 - through)`.
// `view` points from the surface to the eye. A negative `frame.aerial`
// asks for the simple model: one haze for all colors, fading to the sky
// seen behind the surface. Otherwise the air is treated as air: blue is
// scattered more than red (far things turn blue, and what shines through
// turns warm), haze glows around the sun, and the light scattered in is
// the sun's and the sky's.
void aerialHaze(FrameConstants frame, vec3 view, float distance_seen, out vec3 through, out vec3 air) {
    if (frame.aerial < 0.0) {
        through = vec3(exp(distance_seen * frame.aerial));
        air = textureLod(TEX_CUBE(frame.env_specular, frame.sampler_linear_clamp), -view, frame.env_specular_mips * 0.6).rgb * frame.env_intensity;
        return;
    }
    // Clear air and haze, in the proportions of a slightly hazy day; the
    // setting scales both.
    vec3 by_air = frame.aerial * 0.6 * vec3(0.43, 1.0, 2.45);
    float by_haze = frame.aerial * 0.4;
    vec3 lost = by_air + by_haze;
    through = exp(-lost * distance_seen);
    float mu = dot(-view, frame.sun_direction);
    float phase_air = 3.0 / (16.0 * PI) * (1.0 + mu * mu);
    const float g = 0.76;
    float phase_haze = 3.0 / (8.0 * PI) * ((1.0 - g * g) * (1.0 + mu * mu)) / ((2.0 + g * g) * pow(1.0 + g * g - 2.0 * g * mu, 1.5));
    vec3 sky = textureLod(TEX_CUBE(frame.env_irradiance, frame.sampler_linear_clamp), vec3(0.0, 1.0, 0.0), 0.0).rgb * frame.env_intensity;
    air = (frame.sun_radiance * (by_air * phase_air + by_haze * phase_haze) + sky * 0.5 * lost) / lost;
}

// How much of what the sky or a reflection probe shows really reaches a
// surface: the light arriving there, set against the light the sky or the
// probe would give it unobstructed. It keeps a probe that saw a sunlit
// wall from lighting up a corner the wall's light never gets to.
// `sky_visibility` is that share for the sky.
float reflectionReach(FrameConstants frame, vec3 position, vec3 normal, vec3 irradiance, float sky_visibility) {
    if (frame.probe_count == 0u) return sky_visibility;
    float reach = 0.0;
    float covered = 0.0;
    for (uint i = 0u; i < frame.probe_count && covered < 0.999; i++) {
        ReflectionProbeData probe = frame.probes.data[i];
        vec3 inside = 1.0 - abs(position - probe.center) / probe.extent;
        float weight = clamp(min(inside.x, min(inside.y, inside.z)) / max(probe.fade, 1e-3), 0.0, 1.0) * (1.0 - covered);
        if (weight <= 0.0) continue;
        vec3 seen = textureLod(TEX_CUBE(probe.irradiance, frame.sampler_linear_clamp), normal, 0.0).rgb * probe.intensity;
        reach += clamp(luminance(irradiance) / max(luminance(seen), 1e-4), 0.0, 1.0) * weight;
        covered += weight;
    }
    return reach + sky_visibility * (1.0 - covered);
}

// What a surface mirrors when nothing traced answers for it: inside the
// box of a local reflection probe, the picture taken from the probe's
// place, looked up where the mirror ray leaves the box; elsewhere, and
// where probes fade out, the sky. `reach` is the share of it that gets to
// the surface (see `reflectionReach`).
vec3 ambientReflection(FrameConstants frame, vec3 position, vec3 view, vec3 normal, float roughness, float reach) {
    vec3 sky = vec3(0.0);
    if ((frame.flags & FRAME_ENVIRONMENT) != 0u) sky = environmentReflection(frame, view, normal, roughness);
    if (frame.probe_count == 0u) return sky * reach;
    vec3 r = reflect(-view, normal);
    r = normalize(mix(r, normal, roughness * roughness * roughness));
    // Never exactly along an axis, so the divisions below stay finite.
    vec3 safe = mix(r, vec3(1e-5), lessThan(abs(r), vec3(1e-5)));
    vec3 local = vec3(0.0);
    float covered = 0.0;
    for (uint i = 0u; i < frame.probe_count && covered < 0.999; i++) {
        ReflectionProbeData probe = frame.probes.data[i];
        vec3 offset = position - probe.center;
        vec3 inside = 1.0 - abs(offset) / probe.extent;
        float weight = clamp(min(inside.x, min(inside.y, inside.z)) / max(probe.fade, 1e-3), 0.0, 1.0) * (1.0 - covered);
        if (weight <= 0.0) continue;
        vec3 exits = max((probe.extent - offset) / safe, (-probe.extent - offset) / safe);
        vec3 lookup = offset + safe * min(exits.x, min(exits.y, exits.z));
        local += textureLod(TEX_CUBE(probe.specular, frame.sampler_linear_clamp), lookup, roughness * (frame.env_specular_mips - 1.0)).rgb * (probe.intensity * weight);
        covered += weight;
    }
    // A polished surface shows the probe's picture as it is; the rougher
    // it is, the more of that picture it gathers from places whose light
    // may not get to it, and the more the reach counts.
    return local * mix(1.0, reach, clamp(roughness * 3.0, 0.0, 1.0)) + sky * ((1.0 - covered) * reach);
}


#ifdef DEFER_REFLECTIONS
// rgb: how strongly the surface mirrors its surroundings; a: how much of
// the sky reaches it. Written by ambientLight for the reflection pass.
vec4 deferred_reflection = vec4(0.0);
#endif

// resolution (alpha > 0), or zero to evaluate the probes here.
vec3 ambientLight(FrameConstants frame, Surface surface, vec4 gathered) {
    bool has_environment = (frame.flags & FRAME_ENVIRONMENT) != 0u;
    bool has_gi = (frame.flags & FRAME_GI) != 0u;
    uint s = frame.sampler_linear_clamp;
    float n_dot_v = max(dot(surface.normal, surface.view), 1e-4);

    vec3 sky_irradiance = has_environment
        ? textureLod(TEX_CUBE(frame.env_irradiance, s), surface.normal, 0.0).rgb * frame.env_intensity
        : vec3(0.03);
    vec3 irradiance = sky_irradiance;
    // Fraction of the unoccluded sky that actually reaches this point,
    // estimated from the probes; also applied to sky reflections so they do
    // not leak into interiors.
    float sky_visibility = 1.0;
    if (has_gi) {
        float coverage = giCoverage(frame, surface.position);
        if (coverage > 0.0) {
            vec3 probes = gathered.a > 0.0
                ? gathered.rgb
                : giIrradiance(frame, surface.position, surface.normal, surface.view) * frame.gi_intensity;
            irradiance = mix(sky_irradiance, probes, coverage);
            float ratio = luminance(probes) / max(luminance(sky_irradiance), 1e-4);
            sky_visibility = mix(1.0, clamp(ratio, 0.0, 1.0), coverage);
        }
    }

    vec2 dfg = textureLod(TEX(frame.brdf_lut, s), vec2(n_dot_v, surface.roughness), 0.0).rg;
    vec3 specular_weight = surface.f0 * dfg.x + dfg.y;
    vec3 color = irradiance * surface.diffuse_color * (1.0 - specular_weight) * multiBounceAo(surface.ao, surface.diffuse_color);
    // Where close surfaces block the sky, their own light arrives instead.
    color += surface.bounce * surface.diffuse_color * (1.0 - specular_weight);
    // Sheen under ambient light: brightest toward the silhouette. An
    // approximation; there is no pre-integrated table for it.
    color += irradiance * surface.sheen_color * (0.08 + 0.92 * pow(1.0 - n_dot_v, 3.0)) * surface.ao;
    vec3 energy_compensation = 1.0 + surface.f0 * (1.0 / max(dfg.x + dfg.y, 1e-4) - 1.0);
    vec3 reflection_weight = specular_weight * energy_compensation * specularOcclusion(n_dot_v, surface.ao, surface.roughness);
    // From here on: the share of the sky's or a probe's light that reaches.
    sky_visibility = reflectionReach(frame, surface.position, surface.normal, irradiance, sky_visibility);
    bool add_environment = has_environment;
#ifdef DEFER_REFLECTIONS
    // The reflection pass adds what this surface mirrors (from the screen
    // where it can, from the sky otherwise); it needs the weight for that.
    deferred_reflection = vec4(reflection_weight, sky_visibility);
    if ((frame.flags & FRAME_SSR) != 0u) add_environment = false;
#endif
    vec3 mirror_normal = surface.normal;
    if (surface.anisotropy > 0.0) {
        // The surroundings are smeared across the grain; bending the
        // normal toward the view around the grain imitates that.
        vec3 across_grain = cross(surface.normal, surface.grain);
        vec3 bent = cross(cross(across_grain, surface.view), across_grain);
        mirror_normal = normalize(mix(surface.normal, bent, surface.anisotropy * clamp(5.0 * surface.roughness, 0.0, 1.0)));
    }
    if (add_environment) color += ambientReflection(frame, surface.position, surface.view, mirror_normal, surface.roughness, sky_visibility) * reflection_weight;
    if (surface.clearcoat > 0.0) {
        // The coat mirrors the surroundings sharply and dims what is under it.
        float coat_n_dot_v = clamp(dot(surface.coat_normal, surface.view), 0.0, 1.0);
        float coat_fresnel = (0.04 + 0.96 * pow(1.0 - coat_n_dot_v, 5.0)) * surface.clearcoat;
        color *= 1.0 - coat_fresnel;
        if (has_environment) {
            vec3 r = reflect(-surface.view, surface.coat_normal);
            vec3 radiance = textureLod(TEX_CUBE(frame.env_specular, s), r, surface.clearcoat_roughness * (frame.env_specular_mips - 1.0)).rgb * frame.env_intensity;
            color += radiance * coat_fresnel * specularOcclusion(coat_n_dot_v, surface.ao, surface.clearcoat_roughness) * sky_visibility;
        }
    }
    return color;
}

vec3 shadeSurface(FrameConstants frame, Surface surface, vec2 pixel, float noise, vec4 gathered_gi) {
    vec3 color = vec3(0.0);
    vec3 l = frame.sun_direction;
    float n_dot_l = clamp(dot(surface.normal, l), 0.0, 1.0);
    if (n_dot_l > 0.0 && dot(frame.sun_radiance, vec3(1.0)) > 0.0) {
        float shadow = sunShadow(frame, surface.position, surface.normal, n_dot_l, surface.view_depth, noise);
        if (shadow > 0.0) shadow *= contactShadow(frame, surface.position, noise);
        if (shadow > 0.0)
            color += surfaceLight(surface, l, frame.sun_radiance * sunTint(frame, surface.position, surface.view_depth)) * shadow;
    }
    if (surface.subsurface > 0.0 && dot(frame.sun_radiance, vec3(1.0)) > 0.0) {
        // Light that enters, spreads and leaves again: the lit side reaches
        // a little past the shadow line, and thin parts seen against the
        // sun glow. The shadow is looked up a little way out from the
        // surface, which clears the object's own shadow near the shadow line
        // while other things still shade it. The wrap falls off fast, so
        // where the object's shadow does take over there is little left.
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
