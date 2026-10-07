#version 460
#include "common.glsl"
#include "fluid.glsl"

// Solver step 1: semi-Lagrangian advection of velocity, smoke, heat and fuel,
// then combustion, dissipation and sources.
layout(push_constant, scalar) uniform Push {
    FluidRef fluid;
    uint velocity_texture;
    uint scalars_texture;
    // Forward guess from fluid_carry.frag, or INVALID_ID for no correction.
    uint carried_texture;
    // Same for velocity.
    uint carried_velocity_texture;
} push;

layout(location = 0) in vec2 in_uv;
layout(location = 0) out vec4 out_velocity;
// x smoke, y temperature, z fuel.
layout(location = 1) out vec4 out_scalars;

void main() {
    FluidRef fluid = push.fluid;
    ivec3 size = fluid.data.size;
    ivec3 cell = fluidCell(fluid, ivec2(gl_FragCoord.xy));
    out_velocity = vec4(0.0);
    out_scalars = vec4(0.0);
    if (cell.z >= size.z) return;
    // Obstacle cells are cleared; velocity.w flags them for later passes.
    if (fluidObstacle(fluid, cell)) {
        out_velocity = vec4(0.0, 0.0, 0.0, 1.0);
        return;
    }
    float dt = fluid.data.dt;
    vec3 position = vec3(cell) + 0.5;
    vec3 velocity_here = fluidFetch(fluid, push.velocity_texture, cell).xyz;
    vec3 velocity = velocity_here;
    vec3 source = position - velocity * dt;
    if (size.z == 1) source.z = 0.5;

    velocity = fluidSample(fluid, push.velocity_texture, source).xyz;
    vec4 scalars = fluidSample(fluid, push.scalars_texture, source);
    if (push.carried_texture != INVALID_ID) {
        // MacCormack correction, clamped to the upstream neighbourhood.
        vec4 guess = fluidFetch(fluid, push.carried_texture, cell);
        vec3 ahead = position + velocity_here * dt;
        if (size.z == 1) ahead.z = 0.5;
        vec4 returned = fluidSample(fluid, push.carried_texture, ahead);
        vec4 corrected = guess + 0.5 * (fluidFetch(fluid, push.scalars_texture, cell) - returned);
        ivec3 base = ivec3(floor(source - 0.5));
        vec4 low = vec4(1e30);
        vec4 high = vec4(-1e30);
        for (int i = 0; i < (size.z == 1 ? 4 : 8); i++) {
            vec4 corner = fluidFetch(fluid, push.scalars_texture, base + ivec3(i & 1, (i >> 1) & 1, (i >> 2) & 1));
            low = min(low, corner);
            high = max(high, corner);
        }
        scalars = clamp(corrected, low, high);
        if (push.carried_velocity_texture != INVALID_ID) {
            // Same for velocity, except next to obstacles.
            vec3 guess_velocity = fluidFetch(fluid, push.carried_velocity_texture, cell).xyz;
            vec3 returned_velocity = fluidSample(fluid, push.carried_velocity_texture, ahead).xyz;
            vec3 corrected_velocity = guess_velocity + 0.5 * (velocity_here - returned_velocity);
            vec3 slowest = vec3(1e30);
            vec3 fastest = vec3(-1e30);
            float solid = 0.0;
            for (int i = 0; i < (size.z == 1 ? 4 : 8); i++) {
                vec4 corner = fluidFetch(fluid, push.velocity_texture, base + ivec3(i & 1, (i >> 1) & 1, (i >> 2) & 1));
                slowest = min(slowest, corner.xyz);
                fastest = max(fastest, corner.xyz);
                solid = max(solid, corner.w);
            }
            if (solid == 0.0) velocity = clamp(corrected_velocity, slowest, fastest);
        }
    }
    // Inflow through open sides is clear, still air.
    ivec3 from = ivec3(floor(source));
    if (!fluidInside(fluid, from) && !fluidWall(fluid, from)) {
        scalars = vec4(0.0);
        velocity = vec3(0.0);
    }

    float burning = scalars.z * (1.0 - fluid.data.fuel_keep) * smoothstep(0.05, 0.3, scalars.y);
    scalars.z -= burning;
    scalars.y += burning * fluid.data.heat;
    scalars.x += burning * fluid.data.soot;

    velocity *= fluid.data.velocity_keep;
    scalars.x *= fluid.data.smoke_keep;
    scalars.y *= fluid.data.heat_keep;

    for (uint i = 0u; i < fluid.data.source_count; i++) {
        FluidSource emitter = fluid.data.sources[i];
        vec3 offset = position - emitter.position * vec3(size);
        if (size.z == 1) offset.z = 0.0;
        float reach = max(emitter.radius * float(size.y), 0.5);
        float amount = clamp(1.0 - length(offset) / reach, 0.0, 1.0);
        if (amount <= 0.0) continue;
        amount = amount * amount * (3.0 - 2.0 * amount);
        scalars.x += emitter.smoke * amount * dt;
        scalars.y += emitter.temperature * amount * dt;
        scalars.z += emitter.fuel * amount * dt;
        velocity = mix(velocity, emitter.velocity, amount * min(dt * 10.0, 1.0));
    }
    out_velocity = vec4(velocity, 0.0);
    out_scalars = max(scalars, vec4(0.0));
}
