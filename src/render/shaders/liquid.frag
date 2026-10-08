#version 460
#include "common.glsl"
#include "shading.glsl"
#include "liquid.glsl"
#include "water.glsl"

layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    LiquidRef liquid;
    uint distance_texture;
    uint thickness_texture;
    uint scene_texture;
    uint depth_texture;
} push;

layout(location = 0) out vec4 out_color;

vec3 pointAt(ivec2 pixel, float distance_here) {
    vec2 uv = (vec2(pixel) + 0.5) * push.frame.inv_resolution;
    return worldPositionFromDepth(uv, push.frame.near / distance_here, push.frame.inv_view_proj);
}

void main() {
    FrameConstants frame = push.frame;
    LiquidData liquid = push.liquid.data;
    uint nearest = frame.sampler_nearest_clamp;
    uint linear = frame.sampler_linear_clamp;
    ivec2 pixel = ivec2(gl_FragCoord.xy);
    float here = texelFetch(TEX(push.distance_texture, nearest), pixel, 0).r;
    if (here <= 0.0) discard;
    vec2 uv = gl_FragCoord.xy * frame.inv_resolution;
    float thickness = textureLod(TEX(push.thickness_texture, linear), uv, 0.0).r;

    vec3 position = pointAt(pixel, here);
    float left = texelFetch(TEX(push.distance_texture, nearest), pixel + ivec2(-1, 0), 0).r;
    float right = texelFetch(TEX(push.distance_texture, nearest), pixel + ivec2(1, 0), 0).r;
    float up = texelFetch(TEX(push.distance_texture, nearest), pixel + ivec2(0, -1), 0).r;
    float down = texelFetch(TEX(push.distance_texture, nearest), pixel + ivec2(0, 1), 0).r;
    bool use_left = right <= 0.0 || (left > 0.0 && abs(left - here) < abs(right - here));
    bool use_up = down <= 0.0 || (up > 0.0 && abs(up - here) < abs(down - here));
    vec3 along_x = use_left ? position - pointAt(pixel + ivec2(-1, 0), left > 0.0 ? left : here) : pointAt(pixel + ivec2(1, 0), right > 0.0 ? right : here) - position;
    vec3 along_y = use_up ? position - pointAt(pixel + ivec2(0, -1), up > 0.0 ? up : here) : pointAt(pixel + ivec2(0, 1), down > 0.0 ? down : here) - position;
    vec3 normal = normalize(cross(along_x, along_y));
    vec3 view = normalize(frame.camera_position - position);
    if (dot(normal, view) < 0.0) normal = -normal;
    {
        float pixel = here * 2.0 / (abs(frame.proj[1][1]) * frame.resolution.y);
        vec2 ripple = waterDetailSlope(liquid.detail, position.xz, frame.time, pixel / max(abs(dot(normal, view)), 0.08)) * max(normal.y, 0.0);
        normal = normalize(normal - vec3(ripple.x, 0.0, ripple.y));
    }
    float n_dot_v = clamp(dot(normal, view), 0.0, 1.0);
    float fresnel = 0.02 + 0.98 * pow(1.0 - n_dot_v, 5.0);

    vec2 bend = (frame.view * vec4(normal, 0.0)).xy * vec2(1.0, -1.0) * liquid.refraction * min(thickness * 2.0, 1.0) / max(here, 0.5);
    vec2 behind_uv = clamp(uv - bend, vec2(0.001), vec2(0.999));
    float behind_depth = textureLod(TEX(push.depth_texture, nearest), behind_uv, 0.0).r;
    if (behind_depth > 0.0 && linearDepth(behind_depth, frame.near) < here) behind_uv = uv;
    vec3 behind = textureLod(TEX(push.scene_texture, linear), behind_uv, 0.0).rgb;

    vec3 clear = exp(-liquid.murk * thickness * (vec3(1.0) - liquid.color));
    vec3 ambient = vec3(0.0);
    if ((frame.flags & FRAME_ENVIRONMENT) != 0u)
        ambient = textureLod(TEX_CUBE(frame.env_irradiance, linear), normal, 0.0).rgb * frame.env_intensity;
    float sun_shadow = sunShadow(frame, position, normal, 1.0, here, 0.5);
    float sun_facing = clamp(dot(normal, frame.sun_direction), 0.0, 1.0);
    vec3 lit = ambient + frame.sun_radiance * sun_facing * sun_shadow;
    vec3 under = behind * clear + liquid.color * lit * 0.12 * (1.0 - exp(-liquid.murk * thickness * 0.5));

    vec3 mirror = reflect(-view, normal);
    vec3 reflected = vec3(0.0);
    if ((frame.flags & FRAME_ENVIRONMENT) != 0u)
        reflected = textureLod(TEX_CUBE(frame.env_specular, linear), mirror, 0.04 * (frame.env_specular_mips - 1.0)).rgb * frame.env_intensity;
    vec3 halfway = normalize(view + frame.sun_direction);
    float glint = pow(clamp(dot(normal, halfway), 0.0, 1.0), 220.0) * sun_shadow;
    vec3 color = mix(under, reflected, fresnel) + frame.sun_radiance * glint * 1.5;

    float drop = 1.0 - smoothstep(liquid.radius * 0.15, liquid.radius * 0.9, thickness);
    color = mix(color, lit * 0.5 + reflected * 0.3, drop * 0.35);
    out_color = vec4(color, 1.0);
}
