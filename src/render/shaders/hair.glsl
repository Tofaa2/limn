#ifndef HAIR_GLSL
#define HAIR_GLSL

// Strand point: position in hair space and distance along the strand, 0 at the
// root to 1 at the tip.
struct HairPoint {
    vec3 position;
    float along;
};

layout(buffer_reference, scalar) readonly buffer HairPoints { HairPoint data[]; };

// Push constants of the hair pass (`HairPush` in passes/hair.zig).
#define HAIR_PUSH \
    FrameConstants frame; \
    HairPoints points; \
    HairPoints previous_points; \
    mat4 transform; \
    mat4 previous_transform; \
    vec3 root_color; \
    float root_width; \
    vec3 tip_color; \
    float tip_width; \
    uint points_per_strand; \
    float roughness; \
    float spread; \
    float pad1;

// Offset of strand copy `copy` (0 = the strand itself), as a fraction of the
// spread.
vec3 hairCopyOffset(uint strand, uint copy) {
    if (copy == 0u) return vec3(0.0);
    uint state = strand * 747796405u + copy * 2891336453u + 1013904223u;
    vec3 offset;
    for (int axis = 0; axis < 3; axis++) {
        state = state * 747796405u + 2891336453u;
        uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
        offset[axis] = float((word >> 22u) ^ word) / 2147483647.5 - 1.0;
    }
    return offset;
}

#endif
