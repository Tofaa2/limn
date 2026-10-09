#version 460
#include "common.glsl"
#include "gi.glsl"

layout(buffer_reference, scalar) readonly buffer Rays { vec4 data[]; };
layout(buffer_reference, scalar) readonly buffer Directions { vec4 data[]; };

layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    Rays rays;
    Directions directions;
    uint rays_per_probe;
    float hysteresis;
    float max_distance;
    uint probe_stride;
    uint probe_phase;
    float fast_hysteresis;
    ivec3 shift;
    uint grid_index;
    float far_distance;
    uint turn;
    uint previous_offsets;
} push;

layout(location = 0) out vec4 out_offset;


void main() {
    FrameConstants frame = push.frame;
    ivec2 pixel = ivec2(gl_FragCoord.xy);
    GiGrid grid = giGrid(frame, push.grid_index);
    ivec3 counts = grid.counts;
    ivec3 storage = ivec3(pixel.x % counts.x, pixel.y, pixel.x / counts.x);
    int probe = storage.x + storage.y * counts.x + storage.z * counts.x * counts.y;
    vec3 grid_position = giProbeGridPosition(grid, giGridCoord(grid, storage));
    float mark = giProbeMark(grid, grid_position);

    vec4 before = texelFetch(TEX(push.previous_offsets, frame.sampler_nearest_clamp), pixel, 0);
    float apart = abs(before.w - mark);
    vec3 offset = min(apart, 1.0 - apart) < 0.004 ? before.xyz : vec3(0.0);
    out_offset = vec4(offset, mark);
    if (uint(probe) % push.probe_stride != push.probe_phase) return;

    float count = float(push.rays_per_probe);
    float backs = 0.0;
    float nearest_back = 1e30;
    vec3 nearest_back_way = vec3(0.0);
    float nearest_front = 1e30;
    vec3 nearest_front_way = vec3(0.0);
    float farthest_front = 0.0;
    vec3 farthest_front_way = vec3(0.0);
    for (uint ray = 0u; ray < push.rays_per_probe; ray++) {
        float met = push.rays.data[uint(probe) * push.rays_per_probe + ray].w;
        vec3 way = push.directions.data[ray].xyz;
        if (met < 0.0) {
            backs += 1.0;
            float distance_met = -met * 5.0;
            if (distance_met < nearest_back) {
                nearest_back = distance_met;
                nearest_back_way = way;
            }
        } else {
            if (met < nearest_front) {
                nearest_front = met;
                nearest_front_way = way;
            }
            if (met > farthest_front) {
                farthest_front = met;
                farthest_front_way = way;
            }
        }
    }

    float room = grid.spacing * 0.2;
    vec3 moved = offset;
    if (backs / count > 0.25 && nearest_back < 1e29) {
        moved = offset + nearest_back_way * (nearest_back + room * 0.5);
    } else if (nearest_front < room) {
        if (dot(nearest_front_way, farthest_front_way) <= 0.0)
            moved = offset + farthest_front_way * min(farthest_front, room);
    } else if (dot(offset, offset) > 1e-8) {
        float back = min(nearest_front - room, length(offset));
        moved = offset - normalize(offset) * back;
    }
    if (all(lessThan(abs(moved), vec3(grid.spacing * 0.45)))) offset = moved;
    out_offset = vec4(offset, mark);
}
