#version 460
#include "common.glsl"
#include "gi.glsl"

// Evaluates probe irradiance at reduced resolution, for scenes where the
// per-pixel probe lookup is too expensive. Uses the geometric normal
// reconstructed from depth, so normal-map detail does not affect the
// result; the shading pass upsamples it with depth weights.
layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    uint depth_texture;
} push;

layout(location = 0) in vec2 in_uv;
// rgb: irradiance, a: linear view depth of this sample.
layout(location = 0) out vec4 out_gi;

vec3 worldAt(FrameConstants frame, vec2 uv, out float depth) {
    depth = textureLod(TEX(push.depth_texture, frame.sampler_nearest_clamp), uv, 0.0).r;
    return worldPositionFromDepth(uv, max(depth, 1e-7), frame.inv_view_proj);
}

void main() {
    FrameConstants frame = push.frame;
    float depth;
    // A reduced-resolution pixel centre falls on the boundary between
    // full-resolution texels; snap to one texel centre so the position and
    // its neighbours are sampled unambiguously.
    vec2 uv = (floor(in_uv * frame.resolution) + 0.5) * frame.inv_resolution;
    vec3 position = worldAt(frame, uv, depth);
    if (depth == 0.0) {
        out_gi = vec4(0.0, 0.0, 0.0, 1e9);
        return;
    }
    // For each axis use the neighbour closer in depth so the normal does not
    // straddle a silhouette.
    float dl, dr, du, dd;
    vec3 left = worldAt(frame, uv - vec2(frame.inv_resolution.x, 0.0), dl);
    vec3 right = worldAt(frame, uv + vec2(frame.inv_resolution.x, 0.0), dr);
    vec3 up = worldAt(frame, uv - vec2(0.0, frame.inv_resolution.y), du);
    vec3 down = worldAt(frame, uv + vec2(0.0, frame.inv_resolution.y), dd);
    vec3 dx = abs(dl - depth) < abs(dr - depth) ? position - left : right - position;
    vec3 dy = abs(du - depth) < abs(dd - depth) ? position - up : down - position;
    vec3 view = normalize(frame.camera_position - position);
    vec3 normal = normalize(cross(dx, dy));
    if (dot(normal, view) < 0.0) normal = -normal;

    out_gi = vec4(giIrradiance(frame, position, normal, view) * frame.gi_intensity, linearDepth(depth, frame.near));
}
