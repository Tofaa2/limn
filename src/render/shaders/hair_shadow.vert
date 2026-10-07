#version 460
#include "common.glsl"
#include "hair.glsl"
#include "visibility_page.glsl"

// Hair in a shadow map: light-facing ribbons with a minimum width, since
// strands are far narrower than a shadow texel.
layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    HairPoints points;
    // Virtual shadow map page to draw into, when `paged`.
    VisibilityPage page;
    mat4 view_proj;
    mat4 transform;
    // Direction of light travel.
    vec3 light;
    float root_width;
    float tip_width;
    // Minimum strand width in world units.
    float least_width;
    uint points_per_strand;
    uint paged;
    float spread;
    float pad;
} push;

vec3 worldPoint(uint index) {
    return (push.transform * vec4(push.points.data[index].position, 1.0)).xyz;
}

void main() {
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
    vec3 position = worldPoint(here) + hairCopyOffset(strand, uint(gl_InstanceIndex)) * push.spread * mix(0.3, 1.0, push.points.data[here].along);
    vec3 tangent = normalize(worldPoint(after) - worldPoint(before));
    vec3 across = cross(tangent, push.light);
    float across_length = length(across);
    across = across_length > 1e-4 ? across / across_length : vec3(0.0);
    float width = mix(push.root_width, push.tip_width, push.points.data[here].along);
    position += across * side * 0.5 * max(width, push.least_width);
    gl_Position = push.view_proj * vec4(position, 1.0);
    vec4 inside = vec4(1.0);
    if (push.paged != 0u) {
        gl_Position = push.page.view_proj * vec4(position, 1.0);
        vec4 bounds = push.page.bounds;
        inside = vec4(gl_Position.xy - bounds.xy, bounds.zw - gl_Position.xy);
    }
    gl_ClipDistance[0] = inside.x;
    gl_ClipDistance[1] = inside.y;
    gl_ClipDistance[2] = inside.z;
    gl_ClipDistance[3] = inside.w;
}
