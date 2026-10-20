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
    float pad2;
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
    float pad_b;
    float pad_c;
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

    if (sim_push.mode == 0u) {
        LiquidParticle particle = sim_push.particles[index];
        if (index >= liquid.live_before) {
            uint state = hash(index * 0x9e3779b9u + liquid.seed);
            particle.velocity = float3(0.0);
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
    [[vk::location(0)]] float2 corner;
    [[vk::location(1)]] float4 sphere;
    float4 position : SV_Position;
};

/// One camera-facing square per particle, carrying the sphere it stands for
/// in view space.
[shader("vertex")]
SphereVaryings sphereVertexMain(uint vertex : SV_VulkanVertexID) {
    FrameConstants frame = sphere_push.frame;
    LiquidData* liquid = sphere_push.liquid;
    uint slot = vertex / 6u;
    SphereVaryings result;
    result.corner = liquid_corners[vertex % 6u];
    if (slot >= liquid.live) {
        result.position = float4(0.0, 0.0, 2.0, 1.0);
        result.sphere = float4(0.0);
        return result;
    }
    float3 world = mul(liquid.from_box, float4(sphere_push.particles[slot].position, 1.0)).xyz;
    float3 center = mul(frame.view, float4(world, 1.0)).xyz;
    float radius = liquid.radius * sphere_push.swell;
    result.sphere = float4(center, radius);
    result.position = mul(frame.proj, float4(center + float3(result.corner * radius, 0.0), 1.0));
    return result;
}

/// The nearest point of each sphere in front of the scene, as depth.
[shader("fragment")]
float sphereDepthMain(SphereVaryings input) : SV_Depth {
    float off_center = dot(input.corner, input.corner);
    if (off_center > 1.0) discard;
    float3 surface = input.sphere.xyz + float3(input.corner, sqrt(1.0 - off_center)) * input.sphere.w;
    float4 clip = mul(sphere_push.frame.proj, float4(surface, 1.0));
    float depth = clip.z / clip.w;
    float scene = fetchTexel(sphere_push.depth_texture, int2(input.position.xy)).r;
    if (depth < scene) discard;
    return depth;
}

/// How much liquid each sphere puts in front of the scene, summed by blending.
[shader("fragment")]
float sphereThicknessMain(SphereVaryings input) : SV_Target {
    float off_center = dot(input.corner, input.corner);
    if (off_center > 1.0) discard;
    float4 clip = mul(sphere_push.frame.proj, float4(input.sphere.xyz, 1.0));
    float scene = fetchTexel(sphere_push.depth_texture, int2(input.position.xy)).r;
    if (clip.z / clip.w < scene) discard;
    return 2.0 * input.sphere.w * sqrt(1.0 - off_center) * 0.24;
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
    float thickness = sampleTextureLod(shade_push.thickness_texture, linear, uv, 0.0).r;

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

    float2 bend = (mul(frame.view, float4(normal, 0.0))).xy * float2(1.0, -1.0) * liquid.refraction * min(thickness * 2.0, 1.0) / max(here, 0.5);
    float2 behind_uv = clamp(uv - bend, float2(0.001), float2(0.999));
    float behind_depth = sampleTextureLod(shade_push.depth_texture, nearest, behind_uv, 0.0).r;
    if (behind_depth > 0.0 && linearDepth(behind_depth, frame.depth_terms) < here) behind_uv = uv;
    float3 behind = sampleTextureLod(shade_push.scene_texture, linear, behind_uv, 0.0).rgb;

    float3 clear = exp(-liquid.murk * thickness * (float3(1.0) - liquid.color));
    float3 ambient = float3(0.0);
    if (frame.environment != 0u)
        ambient = sampleCubeLod(frame.env_irradiance, linear, normal, 0.0).rgb * frame.env_intensity;
    float sun_shadow = sunShadow(frame, position, normal, 1.0, here, 0.5);
    float sun_facing = clamp(dot(normal, frame.sun_direction), 0.0, 1.0);
    float3 lit = ambient + frame.sun_radiance * sun_facing * sun_shadow;
    float3 under = behind * clear + liquid.color * lit * 0.12 * (1.0 - exp(-liquid.murk * thickness * 0.5));

    float3 mirror = reflect(-view, normal);
    float3 reflected = float3(0.0);
    if (frame.environment != 0u)
        reflected = sampleCubeLod(frame.env_specular, linear, mirror, 0.04 * (frame.env_specular_mips - 1.0)).rgb * frame.env_intensity;
    float3 halfway = normalize(view + frame.sun_direction);
    float glint = pow(clamp(dot(normal, halfway), 0.0, 1.0), 220.0) * sun_shadow;
    float3 color = lerp(under, reflected, fresnel) + frame.sun_radiance * glint * 1.5;

    float drop = 1.0 - smoothstep(liquid.radius * 0.15, liquid.radius * 0.9, thickness);
    color = lerp(color, lit * 0.5 + reflected * 0.3, drop * 0.35);
    result.color = float4(color, 1.0);
    return result;
}
