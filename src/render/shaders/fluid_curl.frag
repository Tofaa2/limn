#version 460
#include "common.glsl"
#include "fluid.glsl"

// Curl of the velocity field.
layout(push_constant, scalar) uniform Push {
    FluidRef fluid;
    uint velocity_texture;
} push;

layout(location = 0) in vec2 in_uv;
layout(location = 0) out vec4 out_curl;

void main() {
    FluidRef fluid = push.fluid;
    ivec3 cell = fluidCell(fluid, ivec2(gl_FragCoord.xy));
    out_curl = vec4(0.0);
    if (cell.z >= fluid.data.size.z) return;
    uint v = push.velocity_texture;
    vec4 center = fluidFetch(fluid, v, cell);
    if (center.w > 0.5) return;
    vec3 right = fluidVelocity(fluid, v, cell + ivec3(1, 0, 0), cell, center.xyz);
    vec3 left = fluidVelocity(fluid, v, cell - ivec3(1, 0, 0), cell, center.xyz);
    vec3 up = fluidVelocity(fluid, v, cell + ivec3(0, 1, 0), cell, center.xyz);
    vec3 down = fluidVelocity(fluid, v, cell - ivec3(0, 1, 0), cell, center.xyz);
    vec3 front = fluidVelocity(fluid, v, cell + ivec3(0, 0, 1), cell, center.xyz);
    vec3 back = fluidVelocity(fluid, v, cell - ivec3(0, 0, 1), cell, center.xyz);
    vec3 curl = 0.5 * vec3(
        (up.z - down.z) - (front.y - back.y),
        (front.x - back.x) - (right.z - left.z),
        (right.y - left.y) - (up.x - down.x));
    out_curl = vec4(curl, length(curl));
}
