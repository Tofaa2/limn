// A volume of liquid: particles in a box, moved by position-based
// dynamics (Macklin and Müller, "Position Based Fluids") and drawn as one
// surface. Shared by the simulation and the passes that draw it.
#ifndef LIQUID_GLSL
#define LIQUID_GLSL

// Positions are in the box's own space: its corner at the origin, its
// axes along the box, in world units.
struct LiquidParticle {
    vec3 position;
    float lambda;
    // Where the step is trying to put it, in two copies that take turns:
    // each round of the solver reads one and writes the other.
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
    // Particles in one layer across the jet.
    float layer;
};

struct LiquidData {
    mat4 from_box;
    vec3 extent;
    // Reach of a particle's influence, and the size of a grid cell.
    float h;
    ivec3 cells;
    uint slots;
    // Particles alive before this step and after it; those between are
    // born in it.
    uint live_before;
    uint live;
    // The first `block_count` particles start as a block, this many
    // along x and z.
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
    // Share of its speed a particle keeps from one step to the next.
    float keep;
    // The particles each source gives birth to in this step.
    uvec4 source_start;
    uvec4 source_end;
    // How strongly neighbours share their speed.
    float viscosity;
    // Steepness of the fine ripples the surface is shaded with.
    float detail;
    float pad_b;
    float pad_c;
    // How far each source's newest layer has travelled from its mouth.
    vec4 source_lead;
    LiquidSource sources[4];
    // Things in the liquid's way: center and radius.
    vec4 spheres[16];
};

layout(buffer_reference, scalar) readonly buffer LiquidRef { LiquidData data; };

#endif
