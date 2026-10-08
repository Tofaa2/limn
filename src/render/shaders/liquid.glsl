#ifndef LIQUID_GLSL
#define LIQUID_GLSL

struct LiquidParticle {
    vec3 position;
    float lambda;
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
    float layer;
};

struct LiquidData {
    mat4 from_box;
    vec3 extent;
    float h;
    ivec3 cells;
    uint slots;
    uint live_before;
    uint live;
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
    float keep;
    uvec4 source_start;
    uvec4 source_end;
    float viscosity;
    float detail;
    float pad_b;
    float pad_c;
    vec4 source_lead;
    LiquidSource sources[4];
    vec4 spheres[16];
};

layout(buffer_reference, scalar) readonly buffer LiquidRef { LiquidData data; };

#endif
