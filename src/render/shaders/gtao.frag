#version 460
#include "common.glsl"

// Ground-truth ambient occlusion (Jimenez et al. 2016): screen-space horizon
// search with a cosine-weighted analytic integral per slice.
layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    uint depth_texture;
    // Last frame's lit color for bounce gathering, or INVALID_ID.
    uint color_texture;
    float radius;
    float intensity;
    // Slices per pixel and steps per side.
    int slice_count;
    int step_count;
} push;

layout(location = 0) in vec2 in_uv;
// r: occlusion, g: linear view depth.
layout(location = 0) out vec2 out_ao;
// Bounce light from the occluders.
layout(location = 1) out vec4 out_bounce;


const float sky_depth = 50000.0;

// View-space position from the linear depth pyramid.
vec3 viewPosition(FrameConstants frame, vec2 uv, float mip) {
    float z = textureLod(TEX(push.depth_texture, frame.sampler_nearest_clamp), uv, mip).r;
    vec2 ndc = uv * 2.0 - 1.0;
    // Account for lens shift.
    ndc += vec2(frame.proj[2][0], frame.proj[2][1]);
    return vec3(ndc.x / frame.proj[0][0], ndc.y / frame.proj[1][1], -1.0) * z;
}

void main() {
    FrameConstants frame = push.frame;
    vec3 position = viewPosition(frame, in_uv, 0.0);
    if (-position.z > sky_depth) {
        out_ao = vec2(1.0, -position.z);
        out_bounce = vec4(0.0);
        return;
    }
    // Normal from depth: per axis, use the neighbour closer in depth.
    vec2 texel = 1.0 / vec2(textureSize(TEX(push.depth_texture, frame.sampler_nearest_clamp), 0));
    vec3 left = viewPosition(frame, in_uv - vec2(texel.x, 0.0), 0.0);
    vec3 right = viewPosition(frame, in_uv + vec2(texel.x, 0.0), 0.0);
    vec3 up = viewPosition(frame, in_uv - vec2(0.0, texel.y), 0.0);
    vec3 down = viewPosition(frame, in_uv + vec2(0.0, texel.y), 0.0);
    vec3 dx = abs(left.z - position.z) < abs(right.z - position.z) ? position - left : right - position;
    vec3 dy = abs(up.z - position.z) < abs(down.z - position.z) ? position - up : down - position;
    vec3 normal = normalize(cross(dx, dy));
    if (dot(normal, position) > 0.0) normal = -normal;
    vec3 view = normalize(-position);

    float projected = push.radius * 0.5 * abs(frame.proj[1][1]) / -position.z;
    vec2 radius_uv = vec2(projected * frame.resolution.y / frame.resolution.x, projected);
    radius_uv = min(radius_uv, vec2(0.15));
    float pixel_radius = radius_uv.y * float(textureSize(TEX(push.depth_texture, frame.sampler_nearest_clamp), 0).y);
    if (pixel_radius < 1.5) {
        out_ao = vec2(1.0, -position.z);
        out_bounce = vec4(0.0);
        return;
    }

    float noise_direction = interleavedGradientNoise(gl_FragCoord.xy, frame.frame_index);
    float noise_offset = fract(noise_direction * 7.31 + 0.37);
    float falloff_end = push.radius * push.radius;
    float visibility = 0.0;
    vec3 bounce = vec3(0.0);
    bool gather = push.color_texture != INVALID_ID;

    for (int slice = 0; slice < push.slice_count; slice++) {
        float phi = (float(slice) + noise_direction) * PI / float(push.slice_count);
        vec2 omega = vec2(cos(phi), sin(phi));
        // Screen +y is view -y.
        vec3 direction = vec3(omega.x, -omega.y, 0.0);
        vec3 ortho_direction = direction - dot(direction, view) * view;
        vec3 axis = normalize(cross(direction, view));
        vec3 projected_normal = normal - axis * dot(normal, axis);
        float projected_length = length(projected_normal);
        float sign_n = sign(dot(ortho_direction, projected_normal));
        float cos_n = clamp(dot(projected_normal, view) / max(projected_length, 1e-5), 0.0, 1.0);
        float n = sign_n * acos(cos_n);

        float horizon_cos[2] = float[](-1.0, -1.0);
        for (int side = 0; side < 2; side++) {
            float direction_sign = side == 0 ? 1.0 : -1.0;
            for (int tap_index = 0; tap_index < push.step_count; tap_index++) {
                float t = (float(tap_index) + noise_offset) / float(push.step_count);
                float reach = t * t + 0.5 / pixel_radius;
                vec2 sample_uv = in_uv + direction_sign * omega * radius_uv * reach;
                // Farther samples read coarser mips.
                float mip = clamp(log2(reach * pixel_radius) - 2.5, 0.0, 4.0);
                vec3 delta = viewPosition(frame, sample_uv, floor(mip)) - position;
                float distance_squared = dot(delta, delta);
                float cos_horizon = dot(delta, view) * inversesqrt(max(distance_squared, 1e-8));
                // Distance falloff against haloing around thin objects.
                float falloff = clamp(distance_squared / falloff_end * 2.0 - 1.0, 0.0, 1.0);
                float candidate = mix(cos_horizon, -1.0, falloff);
                if (candidate > horizon_cos[side]) {
                    if (gather) {
                        float facing = max(dot(normal, delta) * inversesqrt(max(distance_squared, 1e-8)), 0.0);
                        float slice_width = candidate - max(horizon_cos[side], -0.2);
                        if (slice_width > 0.0) bounce += textureLod(TEX(push.color_texture, frame.sampler_linear_clamp), sample_uv, 0.0).rgb * (facing * slice_width);
                    }
                    horizon_cos[side] = candidate;
                }
            }
        }
        // Clamp horizons to the hemisphere around the projected normal.
        float h0 = n + clamp(-acos(horizon_cos[1]) - n, -PI * 0.5, PI * 0.5);
        float h1 = n + clamp(acos(horizon_cos[0]) - n, -PI * 0.5, PI * 0.5);
        float arc0 = (cos_n + 2.0 * h0 * sin(n) - cos(2.0 * h0 - n)) * 0.25;
        float arc1 = (cos_n + 2.0 * h1 * sin(n) - cos(2.0 * h1 - n)) * 0.25;
        visibility += projected_length * (arc0 + arc1);
    }
    visibility /= float(push.slice_count);
    out_ao = vec2(pow(clamp(visibility, 0.0, 1.0), push.intensity), -position.z);
    out_bounce = vec4(min(bounce / float(push.slice_count * 2), vec3(64.0)), 1.0);
}
