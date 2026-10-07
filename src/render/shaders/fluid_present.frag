#version 460
#include "common.glsl"
#include "fluid.glsl"

// Projects a fluid along its depth into a 2D image: smoke as coverage, fire as
// emission.
layout(push_constant, scalar) uniform Push {
    FluidRef fluid;
} push;

layout(location = 0) in vec2 in_uv;
layout(location = 0) out vec4 out_color;

void main() {
    FluidRef fluid = push.fluid;
    ivec3 size = fluid.data.size;
    uint scalars = fluid.data.scalars_texture;
    vec2 uv = vec2(in_uv.x, 1.0 - in_uv.y);
    float depth = length(fluid.data.box_to_world[2].xyz) / float(size.z);
    vec3 fire = fluid.data.fire_color * fluid.data.fire_intensity;
    vec3 color = vec3(0.0);
    float transmittance = 1.0;
    for (int z = 0; z < size.z; z++) {
        vec4 value = textureLod(TEX(scalars, fluid.data.sampler_linear), volumeTileUv(uv * vec2(size.xy), z, size, fluid.data.tiles_x), 0.0);
        float step_transmittance = exp(-value.x * fluid.data.absorption * depth);
        color += transmittance * (fluid.data.smoke_color * (1.0 - step_transmittance) + fire * fireGlow(value.y) * depth);
        transmittance *= step_transmittance;
    }
    // Straight alpha; emission counts as coverage.
    float alpha = clamp(max(1.0 - transmittance, luminance(color)), 0.0, 1.0);
    out_color = vec4(color / max(alpha, 1e-4), alpha);
}
