#include "ray_light.slang"

struct Push {
    FrameConstants frame;
    float4* rays;
    uint64_t tlas;
    float4* directions;
    uint rays_per_probe;
    uint probe_count;
    uint multibounce;
    float max_distance;
    uint probe_stride;
    uint probe_phase;
    uint grid;
    uint skip_buried;
    float far_distance;
    uint turn;
};

[[vk::push_constant]] Push push;

[shader("compute")]
[numthreads(64, 1, 1)]
void computeMain(uint3 id : SV_DispatchThreadID) {
    uint index = id.x;
    uint probe = (index / push.rays_per_probe) * push.probe_stride + push.probe_phase;
    if (probe >= push.probe_count) return;
    FrameConstants frame = push.frame;
    uint ray = index % push.rays_per_probe;
    uint slot = probe * push.rays_per_probe + ray;
    if (push.skip_buried != 0u && (frame.frame_index / max(push.probe_stride, 1u) + probe) % 8u != 0u) {
        uint backs = 0u;
        uint spread = max(push.rays_per_probe / 8u, 1u);
        for (uint k = 0u; k < 8u; k++) backs += uint(push.rays[probe * push.rays_per_probe + min(k * spread, push.rays_per_probe - 1u)].w < 0.0);
        if (backs >= 6u) return;
    }
    GiGrid grid = giGrid(frame, push.grid);
    float3 origin = giProbePosition(grid, giGridCoord(grid, giProbeCoord(int(probe), grid.counts)));
    if (!giProbeDue(frame, origin, probe, push.turn, push.far_distance)) return;
    float3 direction = push.directions[ray].xyz;

    Tracer tracer;
    tracer.frame = frame;
    tracer.scene = push.tlas;
    LitRay seen = traceLit(tracer, origin, direction, push.max_distance, 3.0, push.multibounce != 0u, RAY_SOLID);
    if (seen.met == RAY_MISS) {
        float3 sky = float3(0.0);
        if ((frame.flags & FRAME_ENVIRONMENT) != 0u)
            sky = sampleCubeLod(frame.env_specular, frame.sampler_linear_clamp, direction, 2.0).rgb * frame.env_intensity;
        push.rays[slot] = float4(throughFluids(frame, origin, direction, push.max_distance, sky), push.max_distance);
    } else if (seen.met == RAY_BACK) {
        push.rays[slot] = float4(0.0, 0.0, 0.0, -0.2 * seen.distance);
    } else {
        push.rays[slot] = float4(throughFluids(frame, origin, direction, seen.distance, seen.radiance), seen.distance);
    }
}
