#version 460
#ifdef RAY_TRACED
#extension GL_EXT_ray_query : require
#extension GL_EXT_shader_explicit_arithmetic_types_int64 : require
#endif
#include "common.glsl"
#include "shading.glsl"
#include "water.glsl"

// Shades the water surface: refracted, absorbed scene below; reflections
// (traced or sky) by Fresnel; sun specular.
layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    WaterRef water;
    uint depth_texture;
    uint scene_texture;
    uint quads;
} push;

layout(location = 0) in vec2 in_uv;
layout(location = 1) in vec3 in_position;
layout(location = 0) out vec4 out_color;

void main() {
    FrameConstants frame = push.frame;
    WaterRef water = push.water;
    uint nearest = frame.sampler_nearest_clamp;
    uint linear = frame.sampler_linear_clamp;
    vec2 screen_uv = gl_FragCoord.xy * frame.inv_resolution;
    float scene_depth = texelFetch(TEX(push.depth_texture, nearest), ivec2(gl_FragCoord.xy), 0).r;
    float surface_distance = (frame.view_proj * vec4(in_position, 1.0)).w;
    float scene_distance = scene_depth > 0.0 ? linearDepth(scene_depth, frame.near) : 1e9;
    if (scene_distance < surface_distance) discard;

    vec2 texel = 1.0 / vec2(water.data.size);
    vec3 right = waterPoint(water, in_uv + vec2(texel.x, 0.0), frame.time) - waterPoint(water, in_uv - vec2(texel.x, 0.0), frame.time);
    vec3 ahead = waterPoint(water, in_uv + vec2(0.0, texel.y), frame.time) - waterPoint(water, in_uv - vec2(0.0, texel.y), frame.time);
    vec3 normal = normalize(cross(ahead, right));
    {
        float pixel = surface_distance * 2.0 / (abs(frame.proj[1][1]) * frame.resolution.y);
        vec3 to_eye = normalize(frame.camera_position - in_position);
        float footprint = pixel / max(abs(dot(normal, to_eye)), 0.08);
        vec2 ripple = waterDetailSlope(water.data.detail, in_position.xz, frame.time, footprint);
        vec3 axis_x = normalize(water.data.transform[0].xyz);
        vec3 axis_z = normalize(water.data.transform[2].xyz);
        normal = normalize(normal - axis_x * ripple.x - axis_z * ripple.y);
    }
    vec3 view = normalize(frame.camera_position - in_position);
    if (dot(normal, view) < 0.0) normal = -normal;
    float n_dot_v = clamp(dot(normal, view), 0.0, 1.0);
    float fresnel = 0.02 + 0.98 * pow(1.0 - n_dot_v, 5.0);

    vec3 flat_normal = normalize(water.data.transform[1].xyz);
    vec2 bend = (frame.view * vec4(normal - flat_normal, 0.0)).xy * water.data.refraction / max(surface_distance, 0.5);
    vec2 below_uv = clamp(screen_uv + bend, vec2(0.001), vec2(0.999));
    float below_depth = textureLod(TEX(push.depth_texture, nearest), below_uv, 0.0).r;
    float below_distance = below_depth > 0.0 ? linearDepth(below_depth, frame.near) : 1e9;
    // Never sample something in front of the water.
    if (below_distance < surface_distance) {
        below_uv = screen_uv;
        below_distance = scene_distance;
    }
    vec3 below = textureLod(TEX(push.scene_texture, linear), below_uv, 0.0).rgb;
    if (water.data.caustics > 0.0 && below_distance < 1e8) {
        float below_raw = textureLod(TEX(push.depth_texture, nearest), below_uv, 0.0).r;
        vec3 below_point = worldPositionFromDepth(below_uv, below_raw, frame.inv_view_proj);
        below *= mix(1.0, waterCaustic(water, below_point, frame.sun_direction, frame.time), sunShadow(frame, below_point, flat_normal, 1.0, below_distance, 0.5));
    }
    float looked_through = min(below_distance - surface_distance, 1e4) / max(n_dot_v, 0.2);
    vec3 tint = water.data.color / max(max(water.data.color.r, water.data.color.g), max(water.data.color.b, 1.0e-4));
    vec3 clear = exp(-looked_through * water.data.murk * (vec3(1.25) - tint));
    vec3 ambient = vec3(0.0);
    if ((frame.flags & FRAME_ENVIRONMENT) != 0u)
        ambient = textureLod(TEX_CUBE(frame.env_irradiance, linear), vec3(0.0, 1.0, 0.0), 0.0).rgb * frame.env_intensity;
    float sun_shadow = sunShadow(frame, in_position, normal, 1.0, surface_distance, 0.5);
    vec3 body = water.data.color * (ambient + frame.sun_radiance * max(frame.sun_direction.y, 0.0) * sun_shadow * 0.3);
    vec3 under = mix(body, below, clear);

    vec3 mirror = reflect(-view, normal);
    if (dot(mirror, flat_normal) < 0.02) mirror = normalize(mirror + flat_normal * (0.02 - dot(mirror, flat_normal)));
    vec3 reflected = vec3(0.0);
    bool found = false;
#ifdef RAY_TRACED
    if ((frame.tlas_low | frame.tlas_high) != 0u) {
        uint64_t tlas = uint64_t(frame.tlas_low) | (uint64_t(frame.tlas_high) << 32);
        float distance_hit;
        found = rtTracePicture(frame, tlas, in_position + flat_normal * 0.02, mirror, 200.0, 1.0 + water.data.roughness * 8.0, reflected, distance_hit) != RT_MISS;
        if (found) reflected = rtThroughFluids(frame, in_position, mirror, distance_hit, reflected);
    }
#endif
    if (!found && (frame.flags & FRAME_ENVIRONMENT) != 0u)
        reflected = textureLod(TEX_CUBE(frame.env_specular, linear), mirror, water.data.roughness * (frame.env_specular_mips - 1.0)).rgb * frame.env_intensity;

    // From below: total internal reflection past the critical angle.
    if (dot(flat_normal, view) < 0.0) {
        const float water_index = 1.33;
        float leaves = 1.0 - water_index * water_index * (1.0 - n_dot_v * n_dot_v);
        float out_cosine = sqrt(max(leaves, 0.0));
        float base = 1.0 - out_cosine;
        fresnel = leaves > 0.0 ? 0.02 + 0.98 * base * base * base * base * base : 1.0;
        reflected = body;
        under = below;
    }
    vec3 color = mix(under, reflected, fresnel);
    if (water.data.foam > 0.0) {
        float thickness = max(scene_distance - surface_distance, 0.0);
        float churn = abs(textureLod(TEX(water.data.state_texture, linear), in_uv, 0.0).g) * length(water.data.transform[1].xyz);
        float foam = (1.0 - smoothstep(0.0, 0.18, thickness)) + smoothstep(0.25, 1.2, churn);
        float grain = 0.0;
        float share = 0.65;
        vec2 at = in_position.xz * 7.0 + frame.time * 0.15;
        for (int octave = 0; octave < 2; octave++) {
            vec2 corner = floor(at);
            vec2 within = at - corner;
            within = within * within * (3.0 - 2.0 * within);
            float a = fract(sin(dot(corner, vec2(127.1, 311.7))) * 43758.5453);
            float b = fract(sin(dot(corner + vec2(1.0, 0.0), vec2(127.1, 311.7))) * 43758.5453);
            float c = fract(sin(dot(corner + vec2(0.0, 1.0), vec2(127.1, 311.7))) * 43758.5453);
            float d = fract(sin(dot(corner + vec2(1.0, 1.0), vec2(127.1, 311.7))) * 43758.5453);
            grain += share * mix(mix(a, b, within.x), mix(c, d, within.x), within.y);
            at = at * 2.7 + 13.1;
            share = 0.35;
        }
        foam = clamp(foam * (0.55 + 0.9 * grain) * water.data.foam, 0.0, 1.0);
        vec3 froth = vec3(0.9) * (ambient + frame.sun_radiance * max(frame.sun_direction.y, 0.0) * sun_shadow / PI);
        color = mix(color, froth, foam);
    }
    color += directLight(normal, view, frame.sun_direction, frame.sun_radiance * sun_shadow, vec3(0.0), vec3(0.02), max(water.data.roughness, 0.04));
    out_color = vec4(color, 1.0);
}
