#version 460
#ifdef RAY_TRACED
#extension GL_EXT_ray_query : require
#extension GL_EXT_shader_explicit_arithmetic_types_int64 : require
#endif
#include "common.glsl"
#include "fluid.glsl"

// Marks solid cells: inside an obstacle or, optionally, crossed by scene
// geometry.
layout(push_constant, scalar) uniform Push {
    FluidRef fluid;
#ifdef RAY_TRACED
    // TLAS address, or zero to ignore the scene.
    uint64_t tlas;
#endif
} push;

layout(location = 0) in vec2 in_uv;
layout(location = 0) out vec4 out_solid;

void main() {
    FluidRef fluid = push.fluid;
    ivec3 cell = fluidCell(fluid, ivec2(gl_FragCoord.xy));
    vec3 center = vec3(cell) + 0.5;
    float solid = 0.0;
    for (uint i = 0u; i < fluid.data.obstacle_count; i++) {
        FluidObstacle obstacle = fluid.data.obstacles[i];
        if (obstacle.radius >= 0.0) {
            vec3 offset = center - obstacle.a;
            if (fluid.data.size.z == 1) offset.z = 0.0;
            if (dot(offset, offset) < obstacle.radius * obstacle.radius) solid = 1.0;
        } else if (all(greaterThanEqual(center, obstacle.a)) && all(lessThanEqual(center, obstacle.b))) {
            solid = 1.0;
        }
    }
#ifdef RAY_TRACED
    if (solid == 0.0 && push.tlas != 0ul && cell.z < fluid.data.size.z) {
        // Six short rays from the cell center to its faces.
        mat4 box_to_world = fluid.data.box_to_world;
        vec3 origin = (box_to_world * vec4(center / vec3(fluid.data.size), 1.0)).xyz;
        for (int axis = 0; axis < 3 && solid == 0.0; axis++) {
            vec3 half_cell = box_to_world[axis].xyz * (0.5 / float(fluid.data.size[axis]));
            float reach = length(half_cell);
            if (reach < 1e-6) continue;
            vec3 direction = half_cell / reach;
            for (int side = 0; side < 2; side++) {
                rayQueryEXT query;
                rayQueryInitializeEXT(query, accelerationStructureEXT(push.tlas), gl_RayFlagsOpaqueEXT | gl_RayFlagsTerminateOnFirstHitEXT, 0x01, origin, 0.0, side == 0 ? direction : -direction, reach);
                while (rayQueryProceedEXT(query)) {}
                if (rayQueryGetIntersectionTypeEXT(query, true) != gl_RayQueryCommittedIntersectionNoneEXT) solid = 1.0;
            }
        }
    }
#endif
    out_solid = vec4(solid);
}
