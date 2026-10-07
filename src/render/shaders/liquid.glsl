// Liquid: particles in a box, simulated with Position Based Fluids (Macklin and
// Müller) and drawn as one surface.
#ifndef LIQUID_GLSL
#define LIQUID_GLSL

// Positions are in box space: corner at the origin, world units.
struct LiquidParticle {
    vec3 position;
    float lambda;
    // Predicted position, double-buffered: each solver iteration reads one and
    // writes the other.
    vec3 guess_a;
    float pad0;
    vec3 guess_b;
    float pad1;
    vec3 velocity;
    float pad2;
};

layout(buffer_reference, scalar) buffer LiquidParticles { LiquidParticle data[]; };
layout(buffer_reference, scalar) buffer LiquidCells { uint data[]; };

struct LiquidSource {
    vec3 position;
    float radius;
    vec3 velocity;
    // Particles per layer across the jet.
    float layer;
};

struct LiquidData {
    mat4 from_box;
    vec3 extent;
    // Smoothing radius and grid cell size.
    float h;
    ivec3 cells;
    uint slots;
    // Live particles before and after this step; those between are spawned in
    // it.
    uint live_before;
    uint live;
    // The first `block_count` particles start as a block, this many along x and
    // z.
    uint block_count;
    uint block_nx;
    uint block_nz;
    float spacing;
    float dt;
    float rest_density;
    vec3 gravity;
    float radius;
    vec3 block_origin;
    uint seed;
    vec3 color;
    float murk;
    uint source_count;
    uint sphere_count;
    float refraction;
    // Fraction of velocity kept per step.
    float keep;
    // Particle range each source spawns this step.
    uvec4 source_start;
    uvec4 source_end;
    // XSPH viscosity.
    float viscosity;
    // Steepness of the detail ripples.
    float detail;
    float pad_b;
    float pad_c;
    // Distance each source's newest layer has travelled.
    vec4 source_lead;
    LiquidSource sources[4];
    // Sphere obstacles: center and radius.
    vec4 spheres[16];
};

layout(buffer_reference, scalar) readonly buffer LiquidRef { LiquidData data; };

#endif
