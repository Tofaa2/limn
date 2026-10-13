#ifdef RAY_TRACED
#include "trace.slang"
#endif
#include "fluid.slang"

struct Push {
    FluidRef fluid;
#ifdef RAY_TRACED
    uint64_t tlas;
#endif
};

[[vk::push_constant]] Push push;

[shader("fragment")]
float4 fragmentMain(float4 fragment : SV_Position) : SV_Target {
    FluidRef fluid = push.fluid;
    int3 cell = fluidCell(fluid, int2(fragment.xy));
    float3 center = float3(cell) + 0.5;
    float solid = 0.0;
    for (uint i = 0u; i < fluid.data.obstacle_count; i++) {
        FluidObstacle obstacle = fluid.data.obstacles[i];
        if (obstacle.radius >= 0.0) {
            float3 offset = center - obstacle.a;
            if (fluid.data.size.z == 1) offset.z = 0.0;
            if (dot(offset, offset) < obstacle.radius * obstacle.radius) solid = 1.0;
        } else if (all(center >= obstacle.a) && all(center <= obstacle.b)) {
            solid = 1.0;
        }
    }
#ifdef RAY_TRACED
    if (solid == 0.0 && push.tlas != 0 && cell.z < fluid.data.size.z) {
        float4x4 box_to_world = fluid.data.box_to_world;
        float3 origin = mul(box_to_world, float4(center / float3(fluid.data.size), 1.0)).xyz;
        Tracer tracer;
        tracer.frame = (FrameConstants)nullptr;
        tracer.scene = push.tlas;
        for (int axis = 0; axis < 3 && solid == 0.0; axis++) {
            float3 half_cell = matrixColumn(box_to_world, axis) * (0.5 / float(fluid.data.size[axis]));
            float reach = length(half_cell);
            if (reach < 1e-6) continue;
            float3 direction = half_cell / reach;
            for (int side = 0; side < 2; side++) {
                if (tracer.any(origin, side == 0 ? direction : -direction, reach, RAY_SOLID, Cutouts.whole)) solid = 1.0;
            }
        }
    }
#endif
    return float4(solid);
}
