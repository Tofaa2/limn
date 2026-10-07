#version 460
#include "common.glsl"
#include "fluid.glsl"

// Forward advection guess for the MacCormack correction in fluid_advect.frag.
layout(push_constant, scalar) uniform Push {
    FluidRef fluid;
    uint velocity_texture;
    uint scalars_texture;
} push;

layout(location = 0) in vec2 in_uv;
layout(location = 0) out vec4 out_scalars;
layout(location = 1) out vec4 out_velocity;

void main() {
    FluidRef fluid = push.fluid;
    ivec3 size = fluid.data.size;
    ivec3 cell = fluidCell(fluid, ivec2(gl_FragCoord.xy));
    out_scalars = vec4(0.0);
    out_velocity = vec4(0.0);
    if (cell.z >= size.z) return;
    vec3 position = vec3(cell) + 0.5;
    vec3 source = position - fluidFetch(fluid, push.velocity_texture, cell).xyz * fluid.data.dt;
    if (size.z == 1) source.z = 0.5;
    out_scalars = fluidSample(fluid, push.scalars_texture, source);
    out_velocity = fluidSample(fluid, push.velocity_texture, source);
}
