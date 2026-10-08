#ifndef PARTICLES_GLSL
#define PARTICLES_GLSL
#include "fluid.glsl"

struct Particle {
    vec3 position;
    float age;
    vec3 velocity;
    float lifetime;
};

const uint EMITTER_ADDITIVE = 1u;
const uint EMITTER_LIT = 2u;
const uint EMITTER_FLUID = 4u;
const uint EMITTER_COLLIDE = 8u;
const uint EMITTER_SORTED = 16u;

struct SortEntry {
    float key;
    uint index;
};

struct EmitterData {
    vec3 position;
    float radius;
    vec3 direction;
    float spread;
    vec3 gravity;
    float drag;
    vec4 color_start;
    vec4 color_end;
    vec2 lifetime;
    vec2 speed;
    vec2 size;
    uint spawn_start;
    uint spawn_count;
    uint capacity;
    uint flags;
    uint image;
    float softness;
    uint seed;
    uint pad;
    vec3 shift;
    float trail_fraction;
    float follow;
    float bounce;
    uint collision_depth;
    float stretch;
    uvec2 sheet;
    uvec2 pad2;
    FluidRef fluid;
    vec4 color_mid;
    float size_mid;
    float mid;
    uint keys;
    uint trail_record;
    vec4 curve_colors[8];
    float curve_sizes[8];
    uvec2 curve_counts;
    uint trail_count;
    uint trail_head;
};

layout(buffer_reference, scalar) buffer Particles { Particle data[]; };
layout(buffer_reference, scalar) buffer ParticleOrder { SortEntry data[]; };
layout(buffer_reference, scalar) buffer TrailPoints { vec4 data[]; };
layout(buffer_reference, scalar) readonly buffer EmitterRef { EmitterData data; };

#endif
