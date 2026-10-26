//! A tile of open sea from Tessendorf's wave spectrum: a fresh spectrum each
//! frame, turned into heights by a discrete Fourier transform over the rows,
//! then over the columns.
#include "common.slang"

#include "ocean.Push.slang"

[[vk::push_constant]] Push push;

static const uint ocean_cells = 128u;
static const float gravity = 9.81;

groupshared float2 line[ocean_cells];

float2 multiply(float2 a, float2 b) {
    return float2(a.x * b.x - a.y * b.y, a.x * b.y + a.y * b.x);
}

uint mixBits(uint value) {
    value ^= value >> 16u;
    value *= 0x7feb352du;
    value ^= value >> 15u;
    value *= 0x846ca68bu;
    return value ^ (value >> 16u);
}

/// Two independent standard normal numbers for wave `n`, the same every frame.
float2 gaussianPair(int2 n) {
    uint seed = mixBits(uint(n.x + 1024) * 2654435761u ^ uint(n.y + 1024) * 40503u);
    float u = (float(mixBits(seed) >> 8u) + 0.5) / 16777216.0;
    float v = float(mixBits(seed + 1u) >> 8u) / 16777216.0;
    float radius = sqrt(-2.0 * log(u));
    return radius * float2(cos(2.0 * PI * v), sin(2.0 * PI * v));
}

/// Phillips spectrum: energy of waves of wave vector `k` under the wind.
float phillips(float2 k) {
    float k2 = dot(k, k);
    if (k2 < 1e-8) return 0.0;
    float reach = push.wind_speed * push.wind_speed / gravity;
    float along = dot(k / sqrt(k2), push.wind_direction);
    float small = reach * 0.001;
    return exp(-1.0 / (k2 * reach * reach)) / (k2 * k2) * along * along * exp(-k2 * small * small);
}

float2 startingWave(int2 n) {
    float2 k = float2(n) * (2.0 * PI / push.period);
    return gaussianPair(n) * sqrt(phillips(k) * 0.5);
}

/// The wave of index `n` (centered on 0) at `push.time`.
float2 wave(int2 n) {
    float2 k = float2(n) * (2.0 * PI / push.period);
    float omega = sqrt(gravity * length(k));
    float2 turn = float2(cos(omega * push.time), sin(omega * push.time));
    float2 back = startingWave(-n);
    return multiply(startingWave(n), turn) + multiply(float2(back.x, -back.y), float2(turn.x, -turn.y));
}

/// One output of the inverse transform of `line` at `place`.
float2 transformed(uint place) {
    float2 sum = float2(0.0);
    for (uint j = 0u; j < ocean_cells; j++) {
        float angle = 2.0 * PI * (float(j) - float(ocean_cells / 2u)) * float(place) / float(ocean_cells);
        sum += multiply(line[j], float2(cos(angle), sin(angle)));
    }
    return sum;
}

[shader("compute")]
[numthreads(128, 1, 1)]
void rowsMain(uint3 group : SV_GroupID, uint3 thread : SV_GroupThreadID) {
    uint row = group.x;
    uint column = thread.x;
    line[column] = wave(int2(int(column) - int(ocean_cells / 2u), int(row) - int(ocean_cells / 2u)));
    GroupMemoryBarrierWithGroupSync();
    push.rows[row * ocean_cells + column] = transformed(column);
}

[shader("compute")]
[numthreads(128, 1, 1)]
void columnsMain(uint3 group : SV_GroupID, uint3 thread : SV_GroupThreadID) {
    uint column = group.x;
    uint row = thread.x;
    line[row] = push.rows[row * ocean_cells + column];
    GroupMemoryBarrierWithGroupSync();
    push.heights[row * ocean_cells + column] = transformed(row).x * push.scale;
}
