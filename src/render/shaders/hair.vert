#version 460
#include "common.glsl"
#include "hair.glsl"

layout(push_constant, scalar) uniform Push {
    HAIR_PUSH
} push;

layout(location = 0) out vec3 out_position;
layout(location = 1) out vec3 out_tangent;
layout(location = 2) out vec2 out_along;
layout(location = 3) out vec4 out_clip;
layout(location = 4) out vec4 out_previous_clip;
layout(location = 5) flat out float out_shade;

vec3 worldPoint(uint index) {
    return (push.transform * vec4(push.points.data[index].position, 1.0)).xyz;
}

float strandShade(uint strand) {
    strand = strand * 747796405u + 2891336453u;
    uint word = ((strand >> ((strand >> 28u) + 4u)) ^ strand) * 277803737u;
    return mix(0.62, 1.18, float((word >> 22u) ^ word) / 4294967295.0);
}

void main() {
    FrameConstants frame = push.frame;
    uint stretch = uint(gl_VertexIndex) / 6u;
    uint corner = uint(gl_VertexIndex) % 6u;
    uint stretches = push.points_per_strand - 1u;
    uint strand = stretch / stretches;
    uint within = stretch % stretches;
    bool far_end = corner == 2u || corner == 3u || corner == 5u;
    float side = corner == 1u || corner == 4u || corner == 5u ? 1.0 : -1.0;
    uint first = strand * push.points_per_strand;
    uint here = first + within + (far_end ? 1u : 0u);
    uint before = max(here, first + 1u) - 1u;
    uint after = min(here + 1u, first + stretches);
    float along = push.points.data[here].along;
    vec3 beside = hairCopyOffset(strand, uint(gl_InstanceIndex)) * push.spread * mix(0.3, 1.0, along);
    vec3 position = worldPoint(here) + beside;
    vec3 tangent = normalize(worldPoint(after) - worldPoint(before));
    vec3 toward = frame.camera_position - position;
    float distance_to = max(length(toward), 1e-4);
    vec3 across = cross(tangent, toward / distance_to);
    float across_length = length(across);
    across = across_length > 1e-4 ? across / across_length : vec3(0.0);

    float width = mix(push.root_width, push.tip_width, along) * length(push.transform[0].xyz);
    float pixel = 2.0 * distance_to / (abs(frame.proj[1][1]) * frame.resolution.y);
    float coverage = clamp(width / pixel, 0.0, 1.0);
    vec3 offset = across * side * 0.5 * max(width, pixel);
    vec3 previous = (push.previous_transform * vec4(push.previous_points.data[here].position, 1.0)).xyz + beside + offset;
    position += offset;

    out_position = position;
    out_tangent = tangent;
    out_along = vec2(along, coverage);
    gl_Position = frame.view_proj * vec4(position, 1.0);
    out_clip = frame.view_proj_unjittered * vec4(position, 1.0);
    out_previous_clip = frame.prev_view_proj_unjittered * vec4(previous, 1.0);
    out_shade = strandShade(strand * 31u + uint(gl_InstanceIndex));
}
