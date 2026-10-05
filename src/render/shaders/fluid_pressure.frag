#version 460
#include "common.glsl"
#include "fluid.glsl"

// One Jacobi iteration toward the pressure that cancels the divergence.
// The second channel carries on whether the cell is solid.
layout(push_constant, scalar) uniform Push {
    FluidRef fluid;
    uint pressure_texture;
    uint divergence_texture;
} push;

layout(location = 0) in vec2 in_uv;
layout(location = 0) out vec4 out_pressure;

void main() {
    FluidRef fluid = push.fluid;
    ivec3 cell = fluidCell(fluid, ivec2(gl_FragCoord.xy));
    out_pressure = vec4(0.0);
    if (cell.z >= fluid.data.size.z) return;
    vec2 divergence = fluidFetch(fluid, push.divergence_texture, cell).rg;
    if (divergence.g > 0.5) {
        out_pressure = vec4(0.0, 1.0, 0.0, 0.0);
        return;
    }
    uint p = push.pressure_texture;
    float center = fluidFetch(fluid, p, cell).r;
    bool solid;
    float total = fluidPressure(fluid, p, cell + ivec3(1, 0, 0), center, solid) + fluidPressure(fluid, p, cell - ivec3(1, 0, 0), center, solid) +
        fluidPressure(fluid, p, cell + ivec3(0, 1, 0), center, solid) + fluidPressure(fluid, p, cell - ivec3(0, 1, 0), center, solid);
    float neighbours = 4.0;
    if (fluid.data.size.z > 1) {
        total += fluidPressure(fluid, p, cell + ivec3(0, 0, 1), center, solid) + fluidPressure(fluid, p, cell - ivec3(0, 0, 1), center, solid);
        neighbours = 6.0;
    }
    out_pressure = vec4((total - divergence.r) / neighbours, 0.0, 0.0, 0.0);
}
