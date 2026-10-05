#version 460
#include "common.glsl"

layout(push_constant, scalar) uniform Push {
    uvec2 vertices;
    uvec2 indices;
    mat4 transform;
    vec3 camera_right;
    uint encode_srgb;
    vec3 camera_up;
    float sdf_spread;
    vec2 viewport;
    uint sampler_linear;
    uint sampler_nearest;
    // Scene depth for world-space items, or INVALID_ID; and the view'"'"'s
    // corner in the target.
    uint depth_texture;
    // HDR10 targets: brightness of white in nits.
    float hdr_paper_white;
    vec2 origin;
    // 1 to read text from the three-channel field (sharp corners).
    uint sharp_text;
} push;

layout(location = 0) in vec2 in_uv;
layout(location = 1) in vec4 in_color;
layout(location = 2) flat in uint in_texture_mode;
layout(location = 3) flat in vec2 in_extra;

layout(location = 0) out vec4 out_color;

vec3 linearToSrgb(vec3 c) {
    return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), c));
}

void main() {
    if (push.depth_texture != INVALID_ID) {
        // Hidden behind the scene? (Reverse depth: nearer is larger.)
        vec2 uv = (gl_FragCoord.xy - push.origin) / push.viewport;
        float scene = textureLod(TEX(push.depth_texture, push.sampler_nearest), uv, 0.0).r;
        if (gl_FragCoord.z < scene) discard;
    }
    uint mode = in_texture_mode >> 24;
    uint texture_index = in_texture_mode & 0x00ffffffu;
    vec4 color = in_color;
    switch (mode) {
    case 1u:
        color *= texture(TEX(texture_index, push.sampler_linear), in_uv);
        break;
    case 6u:
        color *= texture(TEX(texture_index, push.sampler_nearest), in_uv);
        break;
    case 2u: {
        // Signed distance field text: scale the stored distance to screen
        // pixels using how fast the atlas coordinate changes per pixel.
        // The atlas holds the distance in alpha, and in red, green and
        // blue a field per channel whose median keeps corners sharp.
        vec4 field = texture(TEX(texture_index, push.sampler_linear), in_uv);
        float distance = (push.sharp_text != 0u ? max(min(field.r, field.g), min(max(field.r, field.g), field.b)) : field.a) - 0.5;
        vec2 atlas_size = vec2(textureSize(textures_2d[nonuniformEXT(texture_index)], 0));
        vec2 texels_per_pixel = fwidth(in_uv) * atlas_size;
        float pixels_per_unit = 2.0 * push.sdf_spread / max(0.5 * (texels_per_pixel.x + texels_per_pixel.y), 1e-6);
        color.a *= clamp(distance * max(pixels_per_unit, 1.0) + 0.5, 0.0, 1.0);
        break;
    }
    case 3u: {
        float radius = length(in_uv);
        color.a *= clamp((1.0 - radius) / max(fwidth(radius), 1e-6) + 0.5, 0.0, 1.0);
        break;
    }
    case 4u: {
        vec2 edge = (1.0 - abs(in_uv)) / max(fwidth(in_uv), vec2(1e-6));
        color.a *= clamp(min(edge.x, edge.y), 0.0, 1.0);
        break;
    }
    case 7u: {
        // Rounded rectangle: signed distance to the outline, in the
        // shape's own units, turned into coverage by how fast it changes
        // across a pixel.
        float radius = float(texture_index & 0xfffu) * 0.25;
        float stroke = float((texture_index >> 12) & 0xfffu) * 0.25;
        vec2 q = abs(in_uv) - in_extra + radius;
        float distance = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
        // An outline is the band between the edge and `stroke` inside it.
        if (stroke > 0.0) distance = max(distance, -(distance + stroke));
        color.a *= clamp(0.5 - distance / max(fwidth(distance), 1e-6), 0.0, 1.0);
        break;
    }
    default:
        break;
    }
    if (color.a <= 0.0) discard;
    if (push.encode_srgb == 1u) color.rgb = linearToSrgb(color.rgb);
    if (push.encode_srgb == 2u) color.rgb = hdr10Encode(color.rgb * push.hdr_paper_white);
    out_color = color;
}
