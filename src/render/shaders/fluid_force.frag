#version 460
#include "common.glsl"
#include "fluid.glsl"

// Forces on the flow: hot gas rises, smoke weighs it down, wind pushes,
// and small swirls that the grid would smear away are put back (vorticity
// confinement, Fedkiw et al. 2001).
layout(push_constant, scalar) uniform Push {
    FluidRef fluid;
    uint velocity_texture;
    uint scalars_texture;
    uint curl_texture;
} push;

layout(location = 0) in vec2 in_uv;
layout(location = 0) out vec4 out_velocity;

void main() {
    FluidRef fluid = push.fluid;
    ivec3 size = fluid.data.size;
    ivec3 cell = fluidCell(fluid, ivec2(gl_FragCoord.xy));
    out_velocity = vec4(0.0);
    if (cell.z >= size.z) return;
    float dt = fluid.data.dt;
    vec4 current = fluidFetch(fluid, push.velocity_texture, cell);
    if (current.w > 0.5) {
        out_velocity = vec4(0.0, 0.0, 0.0, 1.0);
        return;
    }
    vec3 velocity = current.xyz;
    vec4 scalars = fluidFetch(fluid, push.scalars_texture, cell);

    float cells = float(size.y);
    velocity.y += (fluid.data.buoyancy * scalars.y - fluid.data.weight * scalars.x) * cells * dt;
    velocity += fluid.data.wind * cells * dt;

    if (fluid.data.vorticity > 0.0) {
        uint c = push.curl_texture;
        vec4 curl = fluidFetch(fluid, c, cell);
        vec3 gradient = 0.5 * vec3(
            fluidFetch(fluid, c, cell + ivec3(1, 0, 0)).w - fluidFetch(fluid, c, cell - ivec3(1, 0, 0)).w,
            fluidFetch(fluid, c, cell + ivec3(0, 1, 0)).w - fluidFetch(fluid, c, cell - ivec3(0, 1, 0)).w,
            fluidFetch(fluid, c, cell + ivec3(0, 0, 1)).w - fluidFetch(fluid, c, cell - ivec3(0, 0, 1)).w);
        float steepness = length(gradient);
        if (steepness > 1e-5) velocity += fluid.data.vorticity * cross(gradient / steepness, curl.xyz) * dt;
    }
    if (size.z == 1) velocity.z = 0.0;
    out_velocity = vec4(velocity, 0.0);
}
