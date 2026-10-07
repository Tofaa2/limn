// Shared by the particle simulation and drawing shaders.
#ifndef PARTICLES_GLSL
#define PARTICLES_GLSL
#include "fluid.glsl"

struct Particle {
    vec3 position;
    // Seconds since spawn; alive while age < lifetime.
    float age;
    vec3 velocity;
    float lifetime;
};

const uint EMITTER_ADDITIVE = 1u;
const uint EMITTER_LIT = 2u;
const uint EMITTER_FLUID = 4u;
const uint EMITTER_COLLIDE = 8u;
const uint EMITTER_SORTED = 16u;

// Draw order: slot indices, farthest first.
struct SortEntry {
    float key;
    uint index;
};

// Must match `gpu.Emitter`.
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
    // Particles [spawn_start, spawn_start + spawn_count) spawn this frame.
    uint spawn_start;
    uint spawn_count;
    uint capacity;
    uint flags;
    uint image;
    float softness;
    uint seed;
    uint pad;
    // Scene origin shift since the last step.
    vec3 shift;
    // Fraction the oldest trail point has slid toward the next.
    float trail_fraction;
    // Rate at which particles take on the fluid's velocity.
    float follow;
    // Fraction of speed kept on a bounce.
    float bounce;
    uint collision_depth;
    // Seconds of travel a particle is stretched over.
    float stretch;
    // Sprite sheet columns and rows.
    uvec2 sheet;
    uvec2 pad2;
    FluidRef fluid;
    // Optional middle color key, at `mid`.
    vec4 color_mid;
    float size_mid;
    float mid;
    uint keys;
    // 1 in a step that records trail points.
    uint trail_record;
    // Evenly spaced keys over the lifetime; 2 or more replace start, mid and
    // end. `curve_counts`: color keys, size keys.
    vec4 curve_colors[8];
    float curve_sizes[8];
    uvec2 curve_counts;
    // Trail points per particle and index of the newest.
    uint trail_count;
    uint trail_head;
};

layout(buffer_reference, scalar) buffer Particles { Particle data[]; };
layout(buffer_reference, scalar) buffer ParticleOrder { SortEntry data[]; };
// `trail_count` positions per particle slot.
layout(buffer_reference, scalar) buffer TrailPoints { vec4 data[]; };
layout(buffer_reference, scalar) readonly buffer EmitterRef { EmitterData data; };

#endif
