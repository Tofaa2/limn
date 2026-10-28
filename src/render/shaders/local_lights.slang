#ifndef LOCAL_LIGHTS_SLANG
#define LOCAL_LIGHTS_SLANG

uint clusterIndex(FrameConstants frame, float2 pixel, float view_depth) {
    uint2 tile = min(uint2(pixel * frame.inv_resolution * float2(CLUSTERS_X, CLUSTERS_Y)), uint2(CLUSTERS_X - 1u, CLUSTERS_Y - 1u));
    float slice = log2(max(view_depth, 1e-4)) * frame.lights.cluster_z_scale + frame.lights.cluster_z_bias;
    uint z = uint(clamp(slice, 0.0, float(CLUSTERS_Z - 1u)));
    return tile.x + tile.y * CLUSTERS_X + z * CLUSTERS_X * CLUSTERS_Y;
}

#define DECAL_LOOP_BEGIN(position, pixel) \
    Cluster decal_cell = frame.lights.clusters.data[clusterIndex(frame, pixel, -(mul(frame.view, float4(position, 1.0))).z)]; \
    uint decal_end = (SHADE_FEATURES & FEATURE_DECALS) == 0u || (instance.flags & INSTANCE_NO_DECALS) != 0u || frame.shading.decal_count == 0u ? 0u : decal_cell.decal_count; \
    for (uint decal_at = 0u; decal_at < decal_end; decal_at++) { \
        uint i = frame.lights.light_indices[decal_cell.decal_offset + decal_at];

/// One edge's share of the vector form factor of a polygon on the unit
/// sphere (Heitz et al. 2016, fitted arc length).
float3 ltcEdge(float3 from, float3 to) {
    float x = dot(from, to);
    float y = abs(x);
    float a = 0.8543985 + (0.4965155 + 0.0145206 * y) * y;
    float b = 3.4175940 + (4.1616724 + y) * y;
    float v = a / b;
    float theta_over_sine = x > 0.0 ? v : 0.5 * rsqrt(max(1.0 - x * x, 1e-7)) - v;
    return cross(from, to) * theta_over_sine;
}

/// What rectangle lights take of a surface, the same for every panel: the
/// inverse transform and Fresnel terms from the table, and the surface's
/// frame with `across` toward the eye.
struct LtcSurface {
    float4 inverse;
    float4 scale;
    float3 across;
    float3 along;
};

LtcSurface ltcSurface(FrameConstants frame, Surface surface) {
    LtcSurface ltc = {};
    float n_dot_v = clamp(dot(surface.normal, surface.view), 1e-4, 1.0);
    float2 uv = float2(surface.roughness, sqrt(1.0 - n_dot_v)) * (63.0 / 64.0) + 0.5 / 64.0;
    ltc.inverse = sampleTextureLod(frame.lights.ltc_table, frame.sampler_linear_clamp, float2(uv.x, uv.y * 0.5), 0.0);
    ltc.scale = sampleTextureLod(frame.lights.ltc_table, frame.sampler_linear_clamp, float2(uv.x, 0.5 + uv.y * 0.5), 0.0);
    float3 across = surface.view - surface.normal * dot(surface.view, surface.normal);
    ltc.across = dot(across, across) > 1e-8 ? normalize(across) : tangentBasis(surface.normal).side;
    ltc.along = -cross(surface.normal, ltc.across);
    return ltc;
}

/// The cosine-weighted share of the sphere the panel covers, as seen from
/// the surface (x, diffuse) and through the transform for its roughness (y,
/// specular). The corners are walked one at a time, so that little is live.
float2 ltcCoverage(float3 center, float3 half_right, float3 half_up, LtcSurface ltc, float3 normal) {
    float4 m = ltc.inverse;
    float3 plain_form = float3(0.0);
    float3 turned_form = float3(0.0);
    float3 first_plain = float3(0.0);
    float3 first_turned = float3(0.0);
    float3 last_plain = float3(0.0);
    float3 last_turned = float3(0.0);
    [unroll]
    for (int i = 0; i < 4; i++) {
        float3 corner = center + half_right * (i == 0 || i == 3 ? 1.0 : -1.0) + half_up * (i < 2 ? 1.0 : -1.0);
        float3 local = float3(dot(ltc.across, corner), dot(ltc.along, corner), dot(normal, corner));
        float3 plain = normalize(local);
        float3 turned = normalize(float3(m.x * local.x + m.z * local.z, local.y, m.y * local.x + m.w * local.z));
        if (i == 0) {
            first_plain = plain;
            first_turned = turned;
        } else {
            plain_form += ltcEdge(last_plain, plain);
            turned_form += ltcEdge(last_turned, turned);
        }
        last_plain = plain;
        last_turned = turned;
    }
    plain_form += ltcEdge(last_plain, first_plain);
    turned_form += ltcEdge(last_turned, first_turned);
    float plain_size = length(plain_form);
    float turned_size = length(turned_form);
    return float2(max((plain_size * plain_size + plain_form.z) / (plain_size + 1.0), 0.0), max((turned_size * turned_size + turned_form.z) / (turned_size + 1.0), 0.0));
}

/// A rectangle light by linearly transformed cosines, where it looks large
/// enough for the nearest-point estimate to go wrong, on surfaces with
/// neither coat, sheen nor grain. `center` is the panel's middle relative to
/// the surface, `half_right` and `half_up` half its sides, and `radiance`
/// what the panel gives off per unit of area.
float3 rectangleLight(LtcSurface ltc, Surface surface, float3 center, float3 half_right, float3 half_up, float3 radiance) {
    float2 coverage = ltcCoverage(center, half_right, half_up, ltc, surface.normal);
    float3 fresnel = surface.f0 * ltc.scale.x + (1.0 - surface.f0) * ltc.scale.y;
    return radiance * (surface.diffuse_color * coverage.x + fresnel * (coverage.y * (1.0 + surface.f0 * surface.energy) * specular_kept));
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
    return surfaceLight(diffuse_only, l, radiance) + surfaceLight(specular_only, specular_l, radiance) * (normalization * specular_kept);
}

static uint soft_history_texture = INVALID_ID;
static float2 soft_history_uv = float2(0.0);
static uint soft_history_depth_texture = INVALID_ID;
static float soft_history_depth = 0.0;
static float soft_history_slack = 0.0;
/// How far the pixel moved since the history was made, in pixels.
static float soft_history_speed = 0.0;

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

/// What the local lights add up to while a pixel goes through its cluster:
/// light left as it is, and light whose traced soft shadow is filtered.
struct LightSums {
    float3 color;
    float3 soft_light;
    float3 soft_shadowed;
    float soft_weight;
    float soft_lit;
};

void addLit(inout LightSums sums, float3 lit, float traced, bool soft) {
    if (soft) {
        float brightness = dot(lit, float3(0.2126, 0.7152, 0.0722));
        sums.soft_light += lit;
        sums.soft_shadowed += lit * traced;
        sums.soft_weight += brightness;
        sums.soft_lit += brightness * traced;
    } else {
        sums.color += lit;
    }
}

/// Adds one listed light to `sums`. Called with `panels` false for every
/// light but rectangles and then true for those alone, so that the code of
/// each kind is in a loop of its own and the busy loop keeps few registers.
void addLocalLight(FrameConstants frame, Surface surface, Light light, float noise, bool panels, inout LightSums sums) {
    bool panel = (SHADE_FEATURES & FEATURE_RECT_LIGHTS) != 0u && (light.flags & LIGHT_RECTANGLE) != 0u;
    if (panel != panels) return;
    if (!panels && (light.flags & LIGHT_DIRECTIONAL) != 0u) {
        float3 l = -light.direction;
        if (dot(surface.normal, l) > 0.0) {
            float3 lit = surfaceLight(surface, l, light.color);
            float traced = tracedShadow(frame, light, surface.position, surface.normal, l, 1e4, noise);
            bool soft = (SHADE_FEATURES & FEATURE_TRACED_LIGHT_SHADOWS) != 0u && (light.flags & LIGHT_TRACED_SHADOW) != 0u && light.source_radius > 0.0;
            addLit(sums, soft ? lit : lit * traced, traced, soft);
        }
        return;
    }
    float3 to_light = light.position - surface.position;
    float tube_length = (light.flags & (LIGHT_SPOT | LIGHT_RECTANGLE)) == 0u ? light.source_length : 0.0;
    float3 tube_center = to_light;
    if (!panels && tube_length > 0.0) to_light += light.direction * clamp(dot(-to_light, light.direction), -0.5 * tube_length, 0.5 * tube_length);
    float3 panel_right = float3(0.0);
    float3 panel_up = float3(0.0);
    if (panels) {
        float3 facing = light.direction;
        float3 right = normalize(cross(abs(facing.y) < 0.99 ? float3(0.0, 1.0, 0.0) : float3(1.0, 0.0, 0.0), facing));
        float3 up = cross(facing, right);
        panel_right = right * (0.5 * light.source_length);
        panel_up = up * (0.5 * light.source_height);
        float3 from_light = -to_light;
        if (dot(from_light, facing) <= 0.0) return;
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
    if (distance_squared > range_squared) return;
    float window = clamp(1.0 - (distance_squared * distance_squared) / (range_squared * range_squared), 0.0, 1.0);
    float attenuation = window * window / max(distance_squared, max(light.source_radius * light.source_radius, 1e-4));
    float distance_to_light = sqrt(distance_squared);
    if (panels) attenuation *= clamp(dot(-to_light, light.direction) / max(distance_to_light, 1e-5), 0.0, 1.0);
    float falloff = attenuation;
    float3 l = to_light / max(distance_to_light, 1e-5);
    float3 radiance = light.color;
    if (!panels && (light.flags & LIGHT_SPOT) != 0u) {
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
    if (attenuation <= 0.0 || dot(surface.normal, l) <= -light.source_radius / max(distance_to_light, 1e-4)) return;
    attenuation *= localShadow(frame, light, surface.position, surface.normal, l, distance_to_light, noise);
    bool soft = (SHADE_FEATURES & FEATURE_TRACED_LIGHT_SHADOWS) != 0u && (light.flags & LIGHT_TRACED_SHADOW) != 0u && (light.source_radius > 0.0 || light.source_length > 0.0);
    float traced = 1.0;
    if (attenuation > 0.0) traced = tracedShadow(frame, light, surface.position, surface.normal, l, distance_to_light - 0.06, noise);
    if (!soft) attenuation *= traced;
    if (attenuation > 0.0 && (light.flags & LIGHT_FIRE) == 0u) attenuation *= fluidShadowToward(frame, surface.position, l, distance_to_light);
    if (attenuation <= 0.0) return;
    float3 lit;
    if (panels && frame.lights.ltc_table != INVALID_ID && max(light.source_length, light.source_height) > 0.25 * distance_to_light && surface.clearcoat <= 0.0 && surface.anisotropy == 0.0 && all(surface.sheen_color <= 0.0)) {
        LtcSurface ltc = ltcSurface(frame, surface);
        float area = max(light.source_length * light.source_height, 1e-4);
        lit = rectangleLight(ltc, surface, light.position - surface.position, panel_right, panel_up, radiance * (window * window * attenuation / max(falloff, 1e-20) / area));
    } else {
        lit = sphereLight(surface, to_light, distance_to_light, light.source_radius, radiance * attenuation, tube_center, light.direction, tube_length);
    }
    addLit(sums, lit, traced, soft);
}

float3 localLights(FrameConstants frame, Surface surface, float2 pixel, float noise) {
    if ((SHADE_FEATURES & FEATURE_LOCAL_LIGHTS) == 0u || frame.lights.light_count == 0u) return float3(0.0);
    LightSums sums = {};
    uint cluster = clusterIndex(frame, pixel, surface.view_depth);
    uint count = frame.lights.clusters.data[cluster].count;
    uint listed = frame.lights.clusters.data[cluster].offset;
    for (uint i = 0u; i < count; i++) {
        Light light = frame.lights.lights.data[frame.lights.light_indices[listed + i]];
        addLocalLight(frame, surface, light, noise, false, sums);
    }
    if ((SHADE_FEATURES & FEATURE_RECT_LIGHTS) != 0u) for (uint i = 0u; i < count; i++) {
        uint index = frame.lights.light_indices[listed + i];
        if ((frame.lights.lights.data[index].flags & LIGHT_RECTANGLE) == 0u) continue;
        Light light = frame.lights.lights.data[index];
        addLocalLight(frame, surface, light, noise, true, sums);
    }
    float3 color = sums.color;
    if (sums.soft_weight > 0.0) {
        float now = sums.soft_lit / sums.soft_weight;
        float before = softShadowHistory(frame);
        float fresh = lerp(0.12, 1.0, clamp(soft_history_speed * 0.5, 0.0, 1.0));
        soft_shadow_visibility = before >= 0.0 ? lerp(before, now, fresh) : now;
        float3 apart = sums.soft_shadowed * (soft_shadow_visibility / max(now, 1e-4));
        color += lerp(sums.soft_light * soft_shadow_visibility, apart, smoothstep(0.0, 0.1, now));
    }
    return color;
}

#endif
