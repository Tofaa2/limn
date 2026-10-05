// Shared by the particle simulation and drawing shaders.
#ifndef PARTICLES_GLSL
#define PARTICLES_GLSL
#include "fluid.glsl"

struct Particle {
    vec3 position;
    // Seconds since birth; a particle is alive while age < lifetime.
    float age;
    vec3 velocity;
    float lifetime;
};

const uint EMITTER_ADDITIVE = 1u;
const uint EMITTER_LIT = 2u;
const uint EMITTER_FLUID = 4u;
const uint EMITTER_COLLIDE = 8u;
const uint EMITTER_SORTED = 16u;

// Drawing order of an emitter's particles: slot indices, farthest first.
struct SortEntry {
    float key;
    uint index;
};

// Mirrors `gpu.Emitter`.
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
    // Particles [spawn_start, spawn_start + spawn_count) are born this frame.
    uint spawn_start;
    uint spawn_count;
    uint capacity;
    uint flags;
    uint image;
    float softness;
    uint seed;
    uint pad;
    // The scene moved by this much since the last simulation step.
    vec3 shift;
    // How far the oldest trail point has slid toward the next one.
    float trail_fraction;
    // How quickly particles take on the carrying fluid's velocity.
    float follow;
    // Share of its speed a particle keeps when it bounces off the scene.
    float bounce;
    uint collision_depth;
    // Seconds of travel a particle is drawn stretched over.
    float stretch;
    // Columns and rows of the sprite sheet; played once over the lifetime.
    uvec2 sheet;
    uvec2 pad2;
    FluidRef fluid;
    // An optional third key partway through life, at `mid`.
    vec4 color_mid;
    float size_mid;
    float mid;
    uint keys;
    // 1 in a step that remembers the particles' positions for trails.
    uint trail_record;
    // Evenly spaced keys over a particle's life; a count of 2 or more
    // replaces start, mid and end. `curve_counts`: color keys, size keys.
    vec4 curve_colors[8];
    float curve_sizes[8];
    uvec2 curve_counts;
    // Remembered positions per particle, and the newest one's place.
    uint trail_count;
    uint trail_head;
};

layout(buffer_reference, scalar) buffer Particles { Particle data[]; };
layout(buffer_reference, scalar) buffer ParticleOrder { SortEntry data[]; };
// `trail_count` remembered positions for every particle slot.
layout(buffer_reference, scalar) buffer TrailPoints { vec4 data[]; };
layout(buffer_reference, scalar) readonly buffer EmitterRef { EmitterData data; };

#endif
