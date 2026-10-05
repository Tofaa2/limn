#version 460
#include "common.glsl"
#include "fluid.glsl"

// Last step: subtracts the pressure gradient, leaving a flow that neither
// piles up nor thins out anywhere, and stops it at walls and obstacles.
layout(push_constant, scalar) uniform Push {
    FluidRef fluid;
    uint velocity_texture;
    uint pressure_texture;
} push;

layout(location = 0) in vec2 in_uv;
layout(location = 0) out vec4 out_velocity;

void main() {
    FluidRef fluid = push.fluid;
    ivec3 size = fluid.data.size;
    ivec3 cell = fluidCell(fluid, ivec2(gl_FragCoord.xy));
    out_velocity = vec4(0.0);
    if (cell.z >= size.z) return;
    vec4 current = fluidFetch(fluid, push.velocity_texture, cell);
    if (current.w > 0.5) {
        out_velocity = vec4(0.0, 0.0, 0.0, 1.0);
        return;
    }
    uint p = push.pressure_texture;
    float center = fluidFetch(fluid, p, cell).r;
    bool solid_right, solid_left, solid_up, solid_down, solid_front, solid_back;
    float right = fluidPressure(fluid, p, cell + ivec3(1, 0, 0), center, solid_right);
    float left = fluidPressure(fluid, p, cell - ivec3(1, 0, 0), center, solid_left);
    float up = fluidPressure(fluid, p, cell + ivec3(0, 1, 0), center, solid_up);
    float down = fluidPressure(fluid, p, cell - ivec3(0, 1, 0), center, solid_down);
    vec3 velocity = current.xyz;
    velocity.xy -= 0.5 * vec2(right - left, up - down);
    // Nothing moves into a wall.
    if (solid_left) velocity.x = max(velocity.x, 0.0);
    if (solid_right) velocity.x = min(velocity.x, 0.0);
    if (solid_down) velocity.y = max(velocity.y, 0.0);
    if (solid_up) velocity.y = min(velocity.y, 0.0);
    if (size.z == 1) {
        velocity.z = 0.0;
    } else {
        float front = fluidPressure(fluid, p, cell + ivec3(0, 0, 1), center, solid_front);
        float back = fluidPressure(fluid, p, cell - ivec3(0, 0, 1), center, solid_back);
        velocity.z -= 0.5 * (front - back);
        if (solid_back) velocity.z = max(velocity.z, 0.0);
        if (solid_front) velocity.z = min(velocity.z, 0.0);
    }
    out_velocity = vec4(velocity, 0.0);
}
