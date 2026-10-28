#include "common.slang"
#include "shading.slang"
#include "water.slang"

struct LiquidParticle {
    float3 position;
    float lambda;
    float3 guess_a;
    float pad0;
    float3 guess_b;
    float pad1;
    float3 velocity;
    float foam;
};

struct LiquidSource {
    float3 position;
    float radius;
    float3 velocity;
    float layer;
};

struct LiquidData {
    float4x4 from_box;
    float3 extent;
    float h;
    int3 cells;
    uint slots;
    uint live_before;
    uint live;
    uint block_count;
    uint block_nx;
    uint block_nz;
    float spacing;
    float dt;
    float rest_density;
    float3 gravity;
    float radius;
    float3 block_origin;
    uint seed;
    float3 color;
    float murk;
    uint source_count;
    uint sphere_count;
    float refraction;
    float keep;
    uint4 source_start;
    uint4 source_end;
    float viscosity;
    float detail;
    float scatter;
    float fill;
    float foam;
    float foam_kept;
    float swell;
    float frame_dt;
    float4 source_lead;
    LiquidSource sources[4];
    float4 spheres[16];
};

/// Corners of the two triangles drawn for each particle.
static const float2 liquid_corners[6] = { float2(-1.0, -1.0), float2(1.0, -1.0), float2(1.0, 1.0), float2(-1.0, -1.0), float2(1.0, 1.0), float2(-1.0, 1.0) };

#include "liquid.SimPush.slang"

[[vk::push_constant]] SimPush sim_push;

static const float PI_ = 3.14159265;

uint hash(uint value) {
    value ^= value >> 16;
    value *= 0x7feb352du;
    value ^= value >> 15;
    value *= 0x846ca68bu;
    value ^= value >> 16;
    return value;
}

float random(inout uint state) {
    state = hash(state);
    return float(state >> 8) / 16777216.0;
}

int3 cellOf(float3 position) {
    return clamp(int3(position / sim_push.liquid.h), int3(0), sim_push.liquid.cells - 1);
}

uint cellIndex(int3 cell) {
    return uint(cell.x + sim_push.liquid.cells.x * (cell.y + sim_push.liquid.cells.y * cell.z));
}

/// A particle's position, or one of its two guesses, read whole: each sits
/// on its own 16 bytes.
float3 positionOf(uint index) {
    return loadAligned<16>(&sim_push.particles[index].position);
}

float3 guessOf(uint index, bool first) {
    LiquidParticle* particle = sim_push.particles + index;
    float3 guess;
    if (first) guess = loadAligned<16>(&particle.guess_a);
    else guess = loadAligned<16>(&particle.guess_b);
    return guess;
}

float3 contained(float3 position) {
    LiquidData* liquid = sim_push.liquid;
    for (uint i = 0u; i < liquid.sphere_count; i++) {
        float3 away = position - liquid.spheres[i].xyz;
        float reach = liquid.spheres[i].w + liquid.radius;
        float distance_squared = dot(away, away);
        if (distance_squared < reach * reach && distance_squared > 1.0e-12) position = liquid.spheres[i].xyz + away * (reach / sqrt(distance_squared));
    }
    return clamp(position, float3(liquid.radius), liquid.extent - float3(liquid.radius));
}

/// One Jacobi rotation of the symmetric `a` that zeroes its (p, q) entry,
/// gathered into the eigenvectors `v`, one per column.
void jacobiRotate(inout float3x3 a, inout float3x3 v, int p, int q) {
    if (abs(a[p][q]) < 1.0e-20) return;
    float theta = (a[q][q] - a[p][p]) / (2.0 * a[p][q]);
    float t = (theta >= 0.0 ? 1.0 : -1.0) / (abs(theta) + sqrt(theta * theta + 1.0));
    float c = rsqrt(t * t + 1.0);
    float s = t * c;
    for (int k = 0; k < 3; k++) {
        float kp = a[k][p];
        float kq = a[k][q];
        a[k][p] = c * kp - s * kq;
        a[k][q] = s * kp + c * kq;
    }
    for (int k = 0; k < 3; k++) {
        float pk = a[p][k];
        float qk = a[q][k];
        a[p][k] = c * pk - s * qk;
        a[q][k] = s * pk + c * qk;
    }
    for (int k = 0; k < 3; k++) {
        float kp = v[k][p];
        float kq = v[k][q];
        v[k][p] = c * kp - s * kq;
        v[k][q] = s * kp + c * kq;
    }
}

/// The shape a particle is drawn as, after Yu and Turk: stretched along the
/// spread of its neighbours, so the surface reads as sheets rather than
/// beads, and centred a little toward them; a particle nearly alone is a
/// small drop. Also whitens liquid that is churned (neighbours rushing past
/// each other) or flung apart, and lets that foam fade.
void shapeParticle(uint index) {
    LiquidData* liquid = sim_push.liquid;
    float3 own = positionOf(index);
    float3 own_velocity = sim_push.particles[index].velocity;
    int3 home = cellOf(own);
    float inverse_h = 1.0 / liquid.h;
    float total = 0.0;
    float3 first = float3(0.0);
    float3x3 second = float3x3(0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0);
    float near = 0.0;
    float churn = 0.0;
    int3 grid = liquid.cells;
    for (int z = -1; z <= 1; z++) for (int y = -1; y <= 1; y++) for (int x = -1; x <= 1; x++) {
        int3 cell = home + int3(x, y, z);
        if (any(cell < int3(0)) || any(cell >= grid)) continue;
        uint base = uint(cell.x + grid.x * (cell.y + grid.y * cell.z));
        uint count = min(sim_push.counts[base], liquid.slots);
        for (uint slot = 0u; slot < count; slot++) {
            uint other = sim_push.cells[base * liquid.slots + slot];
            float3 apart = positionOf(other) - own;
            float q = length(apart) * inverse_h;
            if (q >= 1.0) continue;
            float w = 1.0 - q * q * q;
            total += w;
            first += apart * w;
            second += float3x3(apart * apart.x, apart * apart.y, apart * apart.z) * w;
            if (other == index) continue;
            near += 1.0;
            float3 rushing = sim_push.particles[other].velocity - own_velocity;
            float speed = length(rushing);
            if (speed > 1.0e-4) churn += speed * (1.0 - dot(rushing / speed, -apart / max(length(apart), 1.0e-6))) * (1.0 - q);
        }
    }
    float3 middle = first / max(total, 1.0e-6);
    float3x3 spread = second / max(total, 1.0e-6) - float3x3(middle * middle.x, middle * middle.y, middle * middle.z);
    float3x3 axes = float3x3(1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0);
    for (int sweep = 0; sweep < 5; sweep++) {
        jacobiRotate(spread, axes, 0, 1);
        jacobiRotate(spread, axes, 0, 2);
        jacobiRotate(spread, axes, 1, 2);
    }
    float3 stretch = sqrt(max(float3(spread[0][0], spread[1][1], spread[2][2]), float3(1.0e-12)));
    float widest = max(stretch.x, max(stretch.y, stretch.z));
    stretch = max(stretch, float3(widest * 0.25));
    stretch /= pow(stretch.x * stretch.y * stretch.z, 1.0 / 3.0);
    float crowd = smoothstep(4.0, 12.0, near);
    float3 radii = liquid.radius * lerp(float3(0.7), liquid.swell * stretch, crowd);
    float3 center = own + middle * 0.5 * crowd;

    float speed = length(own_velocity);
    float flung = (1.0 - crowd) * smoothstep(15.0, 40.0, speed / liquid.radius);
    float surface = 1.0 - smoothstep(18.0, 28.0, near);
    float churned = surface * smoothstep(80.0, 320.0, churn / liquid.radius);
    float foam = max(sim_push.particles[index].foam * liquid.foam_kept, max(churned, flung) * liquid.foam);
    sim_push.particles[index].foam = foam;

    float4* shape = sim_push.shapes + index * 4u;
    shape[0] = float4(center, foam);
    shape[1] = float4(axes[0][0], axes[1][0], axes[2][0], 0.0) * radii.x;
    shape[2] = float4(axes[0][1], axes[1][1], axes[2][1], 0.0) * radii.y;
    shape[3] = float4(axes[0][2], axes[1][2], axes[2][2], 0.0) * radii.z;
}

[shader("compute")]
[numthreads(64, 1, 1)]
void simMain(uint3 id : SV_DispatchThreadID) {
    LiquidData* liquid = sim_push.liquid;
    uint index = id.x;
    if (sim_push.mode == 6u) {
        if (index >= uint(liquid.cells.x * liquid.cells.y * liquid.cells.z)) return;
        uint count = min(sim_push.counts[index], liquid.slots);
        uint base = index * liquid.slots;
        for (uint i = 1u; i < count; i++) {
            uint value = sim_push.cells[base + i];
            uint j = i;
            while (j > 0u && sim_push.cells[base + j - 1u] > value) {
                sim_push.cells[base + j] = sim_push.cells[base + j - 1u];
                j--;
            }
            sim_push.cells[base + j] = value;
        }
        return;
    }
    if (index >= liquid.live) return;
    if (sim_push.mode == 7u) {
        shapeParticle(index);
        return;
    }

    if (sim_push.mode == 0u) {
        LiquidParticle particle = sim_push.particles[index];
        if (index >= liquid.live_before) {
            uint state = hash(index * 0x9e3779b9u + liquid.seed);
            particle.velocity = float3(0.0);
            particle.foam = 0.0;
            if (index < liquid.block_count) {
                uint column = index % liquid.block_nx;
                uint row = (index / liquid.block_nx) % liquid.block_nz;
                uint layer = index / (liquid.block_nx * liquid.block_nz);
                float jitter_x = random(state);
                float jitter_y = random(state);
                float jitter_z = random(state);
                float3 jitter = (float3(jitter_x, jitter_y, jitter_z) - 0.5) * 0.05;
                particle.position = liquid.block_origin + (float3(column, layer, row) + 0.5 + jitter) * liquid.spacing;
            } else {
                LiquidSource source = liquid.sources[0];
                uint which = 0u;
                for (uint i = 1u; i < liquid.source_count; i++) {
                    if (index >= liquid.source_start[i] && index < liquid.source_end[i]) {
                        source = liquid.sources[i];
                        which = i;
                    }
                }
                float3 along = normalize(source.velocity + float3(0.0, -1.0e-4, 0.0));
                float3 side = normalize(cross(along, abs(along.y) < 0.9 ? float3(0.0, 1.0, 0.0) : float3(1.0, 0.0, 0.0)));
                float3 other = cross(along, side);
                uint per_layer = max(uint(source.layer), 1u);
                uint born = index - liquid.source_start[which];
                uint layer = born / per_layer;
                uint place = born % per_layer;
                float angle = float(place) * 2.39996323 + float(layer + liquid.seed % 64u) * 0.7;
                float reach = sqrt((float(place) + 0.5) / float(per_layer)) * max(source.radius - liquid.radius, 0.0);
                particle.position = source.position + (side * cos(angle) + other * sin(angle)) * reach + along * (liquid.source_lead[which] + float(layer) * liquid.spacing);
                particle.velocity = source.velocity;
            }
            particle.position = contained(particle.position);
        }
        particle.velocity += liquid.gravity * liquid.dt;
        uint shake = hash(index * 0x85ebca6bu + liquid.seed);
        float nudge_x = random(shake);
        float nudge_y = random(shake);
        float nudge_z = random(shake);
        float3 nudge = (float3(nudge_x, nudge_y, nudge_z) - 0.5) * liquid.h * 0.004;
        particle.guess_a = contained(particle.position + particle.velocity * liquid.dt + nudge);
        particle.guess_b = particle.guess_a;
        particle.lambda = 0.0;
        sim_push.particles[index] = particle;
        return;
    }

    if (sim_push.mode == 1u) {
        uint cell = cellIndex(cellOf(sim_push.particles[index].guess_a));
        uint slot;
        InterlockedAdd(sim_push.counts[cell], 1u, slot);
        if (slot < liquid.slots) sim_push.cells[cell * liquid.slots + slot] = index;
        return;
    }

    if (sim_push.mode == 5u) {
        sim_push.particles[index].position = guessOf(index, sim_push.flip == 0u);
        return;
    }

    float3 own = guessOf(index, sim_push.flip == 0u);
    float own_lambda = sim_push.particles[index].lambda;
    float3 own_position = positionOf(index);
    int3 home = cellOf(own);
    float density = 0.0;
    float3 gradient_sum = float3(0.0);
    float gradient_squares = 0.0;
    float3 correction = float3(0.0);
    float3 own_velocity = (own - own_position) / liquid.dt;
    float3 drift = float3(0.0);
    float inverse_h = 1.0 / liquid.h;
    float inverse_dt = 1.0 / liquid.dt;
    float inverse_rest = 1.0 / liquid.rest_density;
    uint slots = liquid.slots;
    int3 grid = liquid.cells;
    uint mode = sim_push.mode;
    bool first = sim_push.flip == 0u;
    for (int z = -1; z <= 1; z++) for (int y = -1; y <= 1; y++) for (int x = -1; x <= 1; x++) {
        int3 cell = home + int3(x, y, z);
        if (any(cell < int3(0)) || any(cell >= grid)) continue;
        uint base = uint(cell.x + grid.x * (cell.y + grid.y * cell.z));
        uint count = min(sim_push.counts[base], slots);
        for (uint slot = 0u; slot < count; slot++) {
            uint other = sim_push.cells[base * slots + slot];
            float3 there = guessOf(other, first);
            float3 apart = (own - there) * inverse_h;
            float q2 = dot(apart, apart);
            if (q2 >= 1.0) continue;
            float q = sqrt(q2);
            float w = 1.0 - q2;
            float weight = (315.0 / (64.0 * PI_)) * w * w * w;
            float3 slope = q > 1.0e-5 ? apart * (-(45.0 / PI_) * (1.0 - q) * (1.0 - q) / q) : float3(0.0);
            if (mode == 2u) {
                density += weight;
                if (other != index) {
                    float3 share = slope * inverse_rest;
                    gradient_sum += share;
                    gradient_squares += dot(share, share);
                }
            } else if (mode == 3u) {
                if (other != index) correction += (own_lambda + sim_push.particles[other].lambda) * slope;
            } else if (other != index) {
                drift += ((there - positionOf(other)) * inverse_dt - own_velocity) * weight;
            }
        }
    }
    for (int axis = 0; axis < 3; axis++) for (int side = 0; side < 2; side++) {
        float gap = (side == 0 ? own[axis] : liquid.extent[axis] - own[axis]) / liquid.h;
        if (gap >= 1.0) continue;
        float near = 1.0 - max(gap, 0.0);
        float3 inward = float3(0.0);
        inward[axis] = side == 0 ? 1.0 : -1.0;
        float3 share = -inward * near;
        if (sim_push.mode == 2u) {
            density += 0.5 * liquid.rest_density * near * near;
            gradient_sum += share;
        } else if (sim_push.mode == 3u) {
            correction += own_lambda * share * liquid.rest_density;
        }
    }
    if (sim_push.mode == 2u) {
        float crowding = max(density / liquid.rest_density - 1.0, 0.0);
        sim_push.particles[index].lambda = -crowding / (gradient_squares + dot(gradient_sum, gradient_sum) + 0.05);
    } else if (sim_push.mode == 3u) {
        float3 moved = contained(own + correction / liquid.rest_density * liquid.h);
        if (sim_push.flip == 0u) sim_push.particles[index].guess_b = moved;
        else sim_push.particles[index].guess_a = moved;
    } else {
        float3 velocity = own_velocity + drift * (liquid.viscosity / liquid.rest_density);
        float speed = length(velocity);
        float limit = liquid.h / liquid.dt;
        if (speed > limit) velocity *= limit / speed;
        sim_push.particles[index].velocity = velocity * liquid.keep;
    }
}

#include "liquid.SpherePush.slang"

[[vk::push_constant]] SpherePush sphere_push;

struct SphereVaryings {
    [[vk::location(0)]] float3 at;
    [[vk::location(1)]] nointerpolation float4 center;
    [[vk::location(2)]] nointerpolation float3 across_a;
    [[vk::location(3)]] nointerpolation float3 across_b;
    [[vk::location(4)]] nointerpolation float3 across_c;
    float4 position : SV_Position;
};

/// One camera-facing square per particle, wide enough for the ellipsoid it
/// is drawn as, carrying that ellipsoid in view space: its centre and foam,
/// and the rows that take a point into the space where it is a unit ball.
[shader("vertex")]
SphereVaryings sphereVertexMain(uint vertex : SV_VulkanVertexID) {
    FrameConstants frame = sphere_push.frame;
    LiquidData* liquid = sphere_push.liquid;
    uint slot = vertex / 6u;
    SphereVaryings result;
    if (slot >= liquid.live) {
        result.position = float4(0.0, 0.0, 2.0, 1.0);
        result.at = float3(0.0);
        result.center = float4(0.0);
        result.across_a = float3(0.0);
        result.across_b = float3(0.0);
        result.across_c = float3(0.0);
        return result;
    }
    float4* shape = sphere_push.shapes + slot * 4u;
    float4 middle = shape[0];
    float3x3 to_view = mul((float3x3)frame.view, (float3x3)liquid.from_box);
    float3 a = mul(to_view, shape[1].xyz);
    float3 b = mul(to_view, shape[2].xyz);
    float3 c = mul(to_view, shape[3].xyz);
    float3 center = mul(frame.view, float4(mul(liquid.from_box, float4(middle.xyz, 1.0)).xyz, 1.0)).xyz;
    float reach = sqrt(max(dot(a, a), max(dot(b, b), dot(c, c))));
    float2 corner = liquid_corners[vertex % 6u];
    result.at = center + float3(corner * reach, 0.0);
    result.center = float4(center, middle.w);
    result.across_a = a / max(dot(a, a), 1.0e-12);
    result.across_b = b / max(dot(b, b), 1.0e-12);
    result.across_c = c / max(dot(c, c), 1.0e-12);
    result.position = mul(frame.proj, float4(result.at, 1.0));
    return result;
}

/// Where the ray through a pixel enters and leaves a particle's ellipsoid,
/// as distances along the ray from `origin`; none when it misses.
bool ellipsoidSpan(SphereVaryings input, out float3 origin, out float3 way, out float2 span) {
    if (sphere_push.frame.parallel != 0.0) {
        way = float3(0.0, 0.0, -1.0);
        origin = float3(input.at.xy, input.center.z + 1.0e4);
    } else {
        way = normalize(input.at);
        origin = float3(0.0);
    }
    float3 from = origin - input.center.xyz;
    float3 o = float3(dot(input.across_a, from), dot(input.across_b, from), dot(input.across_c, from));
    float3 d = float3(dot(input.across_a, way), dot(input.across_b, way), dot(input.across_c, way));
    float a = dot(d, d);
    float b = dot(o, d);
    float c = dot(o, o) - 1.0;
    float discriminant = b * b - a * c;
    span = float2(0.0);
    if (discriminant <= 0.0 || a <= 0.0) return false;
    float root = sqrt(discriminant);
    span = float2(-b - root, -b + root) / a;
    return true;
}

/// The nearest point of each ellipsoid in front of the scene, as depth.
[shader("fragment")]
float sphereDepthMain(SphereVaryings input) : SV_Depth {
    float3 origin;
    float3 way;
    float2 span;
    if (!ellipsoidSpan(input, origin, way, span)) discard;
    float4 clip = mul(sphere_push.frame.proj, float4(origin + way * span.x, 1.0));
    float depth = clip.z / clip.w;
    float scene = fetchTexel(sphere_push.depth_texture, int2(input.position.xy)).r;
    if (depth < scene) discard;
    return depth;
}

/// How much liquid each ellipsoid puts in front of the scene, and how much
/// of it is foam, summed by blending. `fill` turns the overlapping shapes'
/// depth into the liquid's.
[shader("fragment")]
float2 sphereThicknessMain(SphereVaryings input) : SV_Target {
    float3 origin;
    float3 way;
    float2 span;
    if (!ellipsoidSpan(input, origin, way, span)) discard;
    float4 clip = mul(sphere_push.frame.proj, float4(input.center.xyz, 1.0));
    float scene = fetchTexel(sphere_push.depth_texture, int2(input.position.xy)).r;
    if (clip.z / clip.w < scene) discard;
    float through = (span.y - span.x) * sphere_push.liquid.fill;
    return float2(through, through * input.center.w);
}

#include "liquid.ShadowPush.slang"

[[vk::push_constant]] ShadowPush shadow_push;

struct ShadowVaryings {
    [[vk::location(0)]] float2 corner;
    [[vk::location(1)]] nointerpolation uint slot;
    float4 position : SV_Position;
};

[shader("vertex")]
ShadowVaryings shadowVertexMain(uint vertex : SV_VulkanVertexID) {
    LiquidData* liquid = shadow_push.liquid;
    uint slot = vertex / 6u;
    ShadowVaryings result;
    result.corner = liquid_corners[vertex % 6u];
    result.slot = slot;
    if (slot >= liquid.live) {
        result.position = float4(0.0, 0.0, 2.0, 1.0);
        return result;
    }
    float3 world = mul(liquid.from_box, float4(shadow_push.particles[slot].position, 1.0)).xyz;
    float3 across = normalize(float3(shadow_push.view_proj[0][0], shadow_push.view_proj[0][1], shadow_push.view_proj[0][2]));
    float3 up = normalize(float3(shadow_push.view_proj[1][0], shadow_push.view_proj[1][1], shadow_push.view_proj[1][2]));
    float radius = liquid.radius * shadow_push.swell;
    result.position = mul(shadow_push.view_proj, float4(world + (across * result.corner.x + up * result.corner.y) * radius, 1.0));
    return result;
}

static const float screen[16] = { 0.0, 8.0, 2.0, 10.0, 12.0, 4.0, 14.0, 6.0, 3.0, 11.0, 1.0, 9.0, 15.0, 7.0, 13.0, 5.0 };

[shader("fragment")]
void shadowFragmentMain(ShadowVaryings input) {
    if (dot(input.corner, input.corner) > 1.0) discard;
    int2 texel = int2(input.position.xy) & 3;
    if ((screen[texel.y * 4 + texel.x] + 0.5) / 16.0 > shadow_push.strength) discard;
}

#include "liquid.SurfacePush.slang"

[[vk::push_constant]] SurfacePush surface_push;

struct SurfaceOutput {
    float4 motion : SV_Target0;
    float depth : SV_Depth;
};

[shader("fragment")]
SurfaceOutput surfaceMain(float4 fragment : SV_Position) {
    FrameConstants frame = surface_push.frame;
    float here = fetchTexel(surface_push.distance_texture, int2(fragment.xy)).r;
    if (here <= 0.0) discard;
    SurfaceOutput result;
    result.depth = depthAt(here, frame.depth_terms);
    float3 position = worldPositionFromDepth(fragment.xy * frame.inv_resolution, result.depth, frame.inv_view_proj);
    float4 clip = mul(frame.view_proj_unjittered, float4(position, 1.0));
    float4 previous = mul(frame.prev_view_proj_unjittered, float4(position, 1.0));
    result.motion = float4((clip.xy / clip.w - previous.xy / previous.w) * 0.5, 0.0, 1.0);
    return result;
}

#include "liquid.BlurPush.slang"

[[vk::push_constant]] BlurPush blur_push;

float distanceAt(int2 pixel) {
    float value = fetchTexel(blur_push.source_texture, pixel).r;
    if (blur_push.raw == 0u) return value;
    return value > 0.0 ? linearDepth(value, blur_push.frame.depth_terms) : 0.0;
}

[shader("fragment")]
float blurMain(float4 fragment : SV_Position) : SV_Target {
    FrameConstants frame = blur_push.frame;
    int2 pixel = int2(fragment.xy);
    float center = distanceAt(pixel);
    if (center <= 0.0) return 0.0;
    float pixels = clamp(blur_push.width * abs(frame.proj[1][1]) * frame.resolution.y * 0.5 / (frame.parallel != 0.0 ? 1.0 : center), 1.0, 28.0);
    int reach = int(ceil(pixels));
    float sum = center;
    float weight = 1.0;
    for (int i = 1; i <= reach; i++) {
        float along = float(i) / pixels;
        float falloff = exp(-2.5 * along * along);
        for (int side = -1; side <= 1; side += 2) {
            float value = distanceAt(pixel + int2(blur_push.direction) * (i * side));
            if (value <= 0.0) continue;
            float jump = (value - center) / blur_push.edge;
            float w = falloff * exp(-jump * jump);
            sum += value * w;
            weight += w;
        }
    }
    return sum / weight;
}

#include "liquid.ShadePush.slang"

[[vk::push_constant]] ShadePush shade_push;

float3 pointAt(int2 pixel, float distance_here) {
    float2 uv = (float2(pixel) + 0.5) * shade_push.frame.inv_resolution;
    return worldPositionFromDepth(uv, depthAt(distance_here, shade_push.frame.depth_terms), shade_push.frame.inv_view_proj);
}

struct ShadeOutput {
    float4 color : SV_Target0;
};

/// What the screen shows along a reflected ray, and how far to trust it:
/// none where the ray leaves the screen or passes behind what it shows.
float4 screenReflection(FrameConstants frame, float3 origin, float3 direction, float reach, float jitter) {
    const int steps = 24;
    float previous_t = 0.0;
    float hit_t = -1.0;
    float2 hit_uv = float2(0.0);
    for (int i = 1; i <= steps; i++) {
        float fraction = (float(i) - 1.0 + jitter) / float(steps);
        float t = reach * fraction * fraction;
        float4 clip = mul(frame.view_proj, float4(origin + direction * t, 1.0));
        float along = clipDepth(frame, clip);
        if (along <= frame.near) break;
        float2 uv = clip.xy / clip.w * 0.5 + 0.5;
        if (any(uv < 0.0) || any(uv > 1.0)) break;
        float depth = sampleTextureLod(shade_push.depth_texture, frame.sampler_nearest_clamp, uv, 0.0).r;
        float behind = along - (depth > 0.0 ? linearDepth(depth, frame.depth_terms) : 1.0e30);
        if (behind > 0.0 && behind < (t - previous_t) + reach * 0.02) {
            hit_t = t;
            hit_uv = uv;
            break;
        }
        previous_t = t;
    }
    if (hit_t < 0.0) return float4(0.0);
    float2 border = min(hit_uv, 1.0 - hit_uv);
    float trust = smoothstep(0.0, 0.08, min(border.x, border.y)) * (1.0 - smoothstep(0.7, 1.0, hit_t / reach));
    return float4(sampleTextureLod(shade_push.scene_texture, frame.sampler_linear_clamp, hit_uv, 0.0).rgb, trust);
}

/// The liquid's surface: the scene and sky it reflects, by Fresnel; under
/// that, what lies behind, bent and dimmed by what the liquid absorbs and
/// scatters on the way through, with the light it scatters toward the eye;
/// and white foam where it is churned.
[shader("fragment")]
ShadeOutput shadeMain(
    float4 fragment : SV_Position) {
    ShadeOutput result;
    FrameConstants frame = shade_push.frame;
    LiquidData* liquid = shade_push.liquid;
    uint nearest = frame.sampler_nearest_clamp;
    uint linear = frame.sampler_linear_clamp;
    int2 pixel = int2(fragment.xy);
    float here = fetchTexel(shade_push.distance_texture, pixel).r;
    if (here <= 0.0) discard;
    float2 uv = fragment.xy * frame.inv_resolution;
    float2 depth_and_foam = sampleTextureLod(shade_push.thickness_texture, linear, uv, 0.0).rg;
    float thickness = depth_and_foam.x;
    float foam = clamp(depth_and_foam.y / max(thickness, 1.0e-6), 0.0, 1.0);

    float3 position = pointAt(pixel, here);
    float left = fetchTexel(shade_push.distance_texture, pixel + int2(-1, 0)).r;
    float right = fetchTexel(shade_push.distance_texture, pixel + int2(1, 0)).r;
    float up = fetchTexel(shade_push.distance_texture, pixel + int2(0, -1)).r;
    float down = fetchTexel(shade_push.distance_texture, pixel + int2(0, 1)).r;
    bool use_left = right <= 0.0 || (left > 0.0 && abs(left - here) < abs(right - here));
    bool use_up = down <= 0.0 || (up > 0.0 && abs(up - here) < abs(down - here));
    float3 along_x = use_left ? position - pointAt(pixel + int2(-1, 0), left > 0.0 ? left : here) : pointAt(pixel + int2(1, 0), right > 0.0 ? right : here) - position;
    float3 along_y = use_up ? position - pointAt(pixel + int2(0, -1), up > 0.0 ? up : here) : pointAt(pixel + int2(0, 1), down > 0.0 ? down : here) - position;
    float3 normal = normalize(cross(along_x, along_y));
    float3 view = normalize(eyePoint(frame, position) - position);
    if (dot(normal, view) < 0.0) normal = -normal;
    {
        float pixel_size = (frame.parallel != 0.0 ? 1.0 : here) * 2.0 / (abs(frame.proj[1][1]) * frame.resolution.y);
        float2 ripple = waterDetailSlope(liquid.detail, position.xz, frame.time, pixel_size / max(abs(dot(normal, view)), 0.08)) * max(normal.y, 0.0);
        normal = normalize(normal - float3(ripple.x, 0.0, ripple.y));
    }
    float n_dot_v = clamp(dot(normal, view), 0.0, 1.0);
    float fresnel = 0.02 + 0.98 * pow(1.0 - n_dot_v, 5.0);
    float noise = interleavedGradientNoise(fragment.xy, frame.frame_index);

    float2 bend = (mul(frame.view, float4(normal, 0.0))).xy * float2(1.0, -1.0) * liquid.refraction * min(thickness * 2.0, 1.0) / max(here, 0.5);
    float2 behind_uv = clamp(uv - bend, float2(0.001), float2(0.999));
    float behind_depth = sampleTextureLod(shade_push.depth_texture, nearest, behind_uv, 0.0).r;
    if (behind_depth > 0.0 && linearDepth(behind_depth, frame.depth_terms) < here) behind_uv = uv;
    float3 behind = sampleTextureLod(shade_push.scene_texture, linear, behind_uv, 0.0).rgb;

    float3 sky_light = float3(0.0);
    if (frame.environment != 0u) sky_light = sampleCubeLod(frame.env_irradiance, linear, float3(0.0, 1.0, 0.0), 0.0).rgb * frame.env_intensity;
    float sun_shadow = sunShadow(frame, position, normal, 1.0, here, noise);
    float3 sunlight = frame.sun_radiance * sun_shadow;

    float3 absorbed = liquid.murk * (float3(1.0) - liquid.color);
    float3 extinction = absorbed + liquid.scatter;
    float3 through = exp(-extinction * thickness);
    float3 lit_inside = (sky_light + sunlight * 0.25 / PI) * exp(-absorbed * thickness * 0.5);
    float3 scattered = lit_inside * (liquid.scatter / max(extinction, float3(1.0e-6))) * (float3(1.0) - through);
    float3 under = behind * through + scattered;

    float3 mirror = reflect(-view, normal);
    float3 reflected = ambientReflection(frame, position, view, normal, 0.03, 1.0);
    float4 seen = screenReflection(frame, position + normal * liquid.radius * 0.5, mirror, max(here, 1.0) * 2.0, noise);
    reflected = lerp(reflected, seen.rgb, seen.a);
    float3 halfway = normalize(view + frame.sun_direction);
    float n_dot_h = clamp(dot(normal, halfway), 0.0, 1.0);
    const float alpha = 0.03 * 0.03;
    float glint = alpha / (PI * pow(n_dot_h * n_dot_h * (alpha - 1.0) + 1.0, 2.0)) / (4.0 * max(n_dot_v, 0.05));
    float3 color = lerp(under, reflected, fresnel) + sunlight * glint * fresnel;

    float3 foam_lit = (sampleCubeLod(frame.env_irradiance, linear, normal, 0.0).rgb * frame.env_intensity * float(frame.environment != 0u) + sunlight * (dot(normal, frame.sun_direction) * 0.5 + 0.5) / PI) * 0.9;
    color = lerp(color, foam_lit, foam);
    result.color = float4(color, 1.0);
    return result;
}
