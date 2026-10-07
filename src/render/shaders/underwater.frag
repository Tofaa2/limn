#version 460
#include "common.glsl"
#include "shading.glsl"
#include "water.glsl"

// Underwater view: absorption by distance through the water, and caustics on
// submerged surfaces.
layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    WaterRef water;
    uint depth_texture;
    uint scene_texture;
} push;

layout(location = 0) in vec2 in_uv;
layout(location = 0) out vec4 out_color;

void main() {
    FrameConstants frame = push.frame;
    WaterRef water = push.water;
    uint nearest = frame.sampler_nearest_clamp;
    vec2 screen_uv = gl_FragCoord.xy * frame.inv_resolution;
    vec3 scene = texelFetch(TEX(push.scene_texture, nearest), ivec2(gl_FragCoord.xy), 0).rgb;
    float depth = texelFetch(TEX(push.depth_texture, nearest), ivec2(gl_FragCoord.xy), 0).r;
    vec3 world = worldPositionFromDepth(screen_uv, max(depth, 1e-7), frame.inv_view_proj);
    vec3 direction = normalize(world - frame.camera_position);
    float reach = depth > 0.0 ? distance(world, frame.camera_position) : 1e5;

    vec3 up = normalize(water.data.transform[1].xyz);
    float below = dot(water.data.transform[3].xyz - frame.camera_position, up);
    float rise = dot(direction, up);
    float to_surface = rise > 1e-5 ? below / rise : 1e9;
    bool in_water = reach < to_surface;
    float through = min(reach, to_surface);

    if (in_water) scene *= mix(1.0, waterCaustic(water, world, frame.sun_direction, frame.time), sunShadow(frame, world, up, 1.0, reach, 0.5));
    vec3 ambient = vec3(0.0);
    if ((frame.flags & FRAME_ENVIRONMENT) != 0u)
        ambient = textureLod(TEX_CUBE(frame.env_irradiance, frame.sampler_linear_clamp), vec3(0.0, 1.0, 0.0), 0.0).rgb * frame.env_intensity;
    vec3 body = water.data.color * (ambient + frame.sun_radiance * max(frame.sun_direction.y, 0.0) * 0.3);
    out_color = vec4(mix(body, scene, exp(-through * water.data.murk)), 1.0);
}
