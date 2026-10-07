#version 460
#include "common.glsl"
#include "clouds.glsl"

// Composites the clouds over the lit scene.
layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    CloudRef clouds;
    uint cloud_texture;
} push;

layout(location = 0) in vec2 in_uv;
layout(location = 0) out vec4 out_color;

void main() {
    FrameConstants frame = push.frame;
    CloudData clouds = push.clouds.data;
    float depth = texelFetch(TEX(clouds.depth_texture, frame.sampler_nearest_clamp), ivec2(gl_FragCoord.xy), 0).r;
    if (depth > 0.0) {
        vec3 position = worldPositionFromDepth(in_uv, depth, frame.inv_view_proj);
        vec3 direction = normalize(position - frame.camera_position);
        vec2 segment = cloudSegment(clouds, frame.camera_position.y, direction.y);
        if (segment.y <= segment.x || length(position - frame.camera_position) <= segment.x) discard;
    }
    vec4 result = textureLod(TEX(push.cloud_texture, frame.sampler_linear_clamp), in_uv, 0.0);
    // Alpha above 1 marks pixels the march skipped.
    result.a = min(result.a, 1.0);
    // Premultiplied blend: result = rgb + dst * (1 - a).
    out_color = vec4(result.rgb, 1.0 - result.a);
}
