#version 460
#include "common.glsl"
#include "fluid.glsl"

// Velocity divergence per cell. The second channel flags solid cells.
layout(push_constant, scalar) uniform Push {
    FluidRef fluid;
    uint velocity_texture;
} push;

layout(location = 0) in vec2 in_uv;
layout(location = 0) out vec4 out_divergence;

void main() {
    FluidRef fluid = push.fluid;
    ivec3 cell = fluidCell(fluid, ivec2(gl_FragCoord.xy));
    out_divergence = vec4(0.0);
    if (cell.z >= fluid.data.size.z) return;
    uint v = push.velocity_texture;
    vec4 center = fluidFetch(fluid, v, cell);
    if (center.w > 0.5) {
        out_divergence = vec4(0.0, 1.0, 0.0, 0.0);
        return;
    }
    vec3 c = center.xyz;
    float divergence = fluidVelocity(fluid, v, cell + ivec3(1, 0, 0), cell, c).x - fluidVelocity(fluid, v, cell - ivec3(1, 0, 0), cell, c).x +
        fluidVelocity(fluid, v, cell + ivec3(0, 1, 0), cell, c).y - fluidVelocity(fluid, v, cell - ivec3(0, 1, 0), cell, c).y;
    if (fluid.data.size.z > 1)
        divergence += fluidVelocity(fluid, v, cell + ivec3(0, 0, 1), cell, c).z - fluidVelocity(fluid, v, cell - ivec3(0, 0, 1), cell, c).z;
    out_divergence = vec4(0.5 * divergence, 0.0, 0.0, 0.0);
}
