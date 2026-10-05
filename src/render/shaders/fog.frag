#version 460
#include "common.glsl"
#include "gi.glsl"
#include "media.glsl"

// Volumetric fog at half resolution: ray-marches from the camera to the
// surface, accumulating sun light (shadowed by the cascades, which is what
// produces light shafts) and ambient sky light. Output is in-scattered
// radiance in rgb and transmittance in a.
layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    uint depth_texture;
    float density;
    float anisotropy;
    float height_falloff;
    float max_distance;
    float ambient;
    int step_count;
} push;

layout(location = 0) in vec2 in_uv;
layout(location = 0) out vec4 out_fog;


void main() {
    FrameConstants frame = push.frame;
    float depth = textureLod(TEX(push.depth_texture, frame.sampler_nearest_clamp), in_uv, 0.0).r;
    vec3 end = worldPositionFromDepth(in_uv, max(depth, 1e-6), frame.inv_view_proj);
    vec3 ray = end - frame.camera_position;
    float ray_length = length(ray);
    vec3 direction = ray / ray_length;
    ray_length = min(ray_length, push.max_distance);

    vec3 sky_ambient = vec3(0.0);
    if ((frame.flags & FRAME_ENVIRONMENT) != 0u) {
        uint s = frame.sampler_linear_clamp;
        sky_ambient = 0.5 * (textureLod(TEX_CUBE(frame.env_irradiance, s), vec3(0.0, 1.0, 0.0), 0.0).rgb +
            textureLod(TEX_CUBE(frame.env_irradiance, s), vec3(0.0, -1.0, 0.0), 0.0).rgb) * frame.env_intensity * push.ambient;
    }
    vec3 sun = frame.sun_radiance * henyeyGreenstein(dot(direction, frame.sun_direction), push.anisotropy);

    float step_length = ray_length / float(push.step_count);
    float jitter = interleavedGradientNoise(gl_FragCoord.xy, frame.frame_index);
    vec3 scattered = vec3(0.0);
    float transmittance = 1.0;
    // Probe ambient is refreshed twice along the ray.
    int ambient_interval = max(push.step_count / 2, 1);
    vec3 ambient = sky_ambient;
    for (int i = 0; i < push.step_count; i++) {
        vec3 position = frame.camera_position + direction * (float(i) + jitter) * step_length;
        float sigma = push.density * exp(-max(position.y, 0.0) * push.height_falloff);
        // Inside the probe volume the fog is lit by local bounce light, not
        // by the open sky; refreshed every few steps to bound the cost.
        if (i % ambient_interval == 0) {
            ambient = sky_ambient;
            if ((frame.flags & FRAME_GI) != 0u) {
                float coverage = giCoverage(frame, position);
                if (coverage > 0.0) ambient = mix(sky_ambient, giAmbient(frame, position) * frame.gi_intensity * push.ambient, coverage);
            }
        }
        vec3 light = sun * sunVisibility(frame, position) + ambient;
        // Analytic integration of in-scattering over the step (Hillaire).
        float step_transmittance = exp(-sigma * step_length);
        scattered += transmittance * light * (1.0 - step_transmittance);
        transmittance *= step_transmittance;
    }
    out_fog = vec4(scattered, transmittance);
}
