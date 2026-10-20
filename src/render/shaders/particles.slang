#include "fluid.slang"
#include "common.slang"
#include "shading.slang"

struct Particle {
    float3 position;
    float age;
    float3 velocity;
    float lifetime;
};

static const uint EMITTER_ADDITIVE = 1u;
static const uint EMITTER_LIT = 2u;
static const uint EMITTER_FLUID = 4u;
static const uint EMITTER_COLLIDE = 8u;
static const uint EMITTER_SORTED = 16u;

struct SortEntry {
    float key;
    uint index;
};

struct EmitterData {
    float3 position;
    float radius;
    float3 direction;
    float spread;
    float3 gravity;
    float drag;
    float4 color_start;
    float4 color_end;
    float2 lifetime;
    float2 speed;
    float2 size;
    uint spawn_start;
    uint spawn_count;
    uint capacity;
    uint flags;
    uint image;
    float softness;
    uint seed;
    uint pad;
    float3 shift;
    float trail_fraction;
    float follow;
    float bounce;
    uint collision_depth;
    float stretch;
    uint2 sheet;
    uint2 pad2;
    FluidRef fluid;
    float4 color_mid;
    float size_mid;
    float mid;
    uint keys;
    uint trail_record;
    float4 curve_colors[8];
    float curve_sizes[8];
    uint2 curve_counts;
    uint trail_count;
    uint trail_head;
};

struct EmitterRef { EmitterData* data; };

#include "particles.SimPush.slang"

[[vk::push_constant]] SimPush sim_push;

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

[shader("compute")]
[numthreads(64, 1, 1)]
void simMain(uint3 id : SV_DispatchThreadID) {
    EmitterData* emitter = sim_push.emitter.data;
    uint index = id.x;
    if (index >= emitter.capacity) return;
    float dt = sim_push.frame.delta_time;
    Particle particle = loadAligned<16>(sim_push.particles + index);

    uint slot = (index + emitter.capacity - emitter.spawn_start) % emitter.capacity;
    if (slot < emitter.spawn_count) {
        uint state = hash(index * 0x9e3779b9u + emitter.seed);
        float cos_limit = cos(emitter.spread);
        float cos_theta = lerp(1.0, cos_limit, random(state));
        float sin_theta = sqrt(max(1.0 - cos_theta * cos_theta, 0.0));
        float phi = 2.0 * PI * random(state);
        float3 axis = normalize(emitter.direction);
        float3 side = normalize(abs(axis.y) < 0.99 ? cross(axis, float3(0.0, 1.0, 0.0)) : cross(axis, float3(1.0, 0.0, 0.0)));
        float3 other = cross(axis, side);
        float3 direction = axis * cos_theta + (side * cos(phi) + other * sin(phi)) * sin_theta;
        float offset_x = random(state);
        float offset_y = random(state);
        float offset_z = random(state);
        float3 offset = float3(offset_x, offset_y, offset_z) * 2.0 - 1.0;
        offset *= emitter.radius * pow(random(state), 1.0 / 3.0) / max(length(offset), 1e-4);
        particle.velocity = direction * lerp(emitter.speed.x, emitter.speed.y, random(state));
        particle.lifetime = lerp(emitter.lifetime.x, emitter.lifetime.y, random(state));
        particle.age = dt * random(state);
        particle.position = emitter.position + offset + particle.velocity * particle.age;
        for (uint point = 0u; point < emitter.trail_count; point++)
            sim_push.trail[index * emitter.trail_count + point] = float4(particle.position, 0.0);
    } else if (particle.age < particle.lifetime) {
        if (emitter.trail_count != 0u) {
            if (any(emitter.shift != float3(0.0))) {
                for (uint point = 0u; point < emitter.trail_count; point++)
                    sim_push.trail[index * emitter.trail_count + point].xyz += emitter.shift;
            }
            if (emitter.trail_record != 0u)
                sim_push.trail[index * emitter.trail_count + emitter.trail_head] = float4(particle.position + emitter.shift, 0.0);
        }
        particle.velocity += emitter.gravity * dt;
        particle.velocity *= exp(-emitter.drag * dt);
        if ((emitter.flags & EMITTER_FLUID) != 0u) {
            FluidRef fluid = emitter.fluid;
            float3 uvw = mul(fluid.data.world_to_box, float4(particle.position, 1.0)).xyz;
            if (all(uvw > 0.0) && all(uvw < 1.0)) {
                int3 size = fluid.data.size;
                float3 cells = sampleVolume(fluid.data.velocity_texture, fluid.data.sampler_linear, uvw, size, fluid.data.tiles_x).xyz;
                float3 flow = mul(fluid.data.box_to_world, float4(cells / float3(size), 0.0)).xyz;
                particle.velocity = lerp(flow, particle.velocity, exp(-emitter.follow * dt));
            }
        }
        float3 next = particle.position + emitter.shift + particle.velocity * dt;
        if ((emitter.flags & EMITTER_COLLIDE) != 0u) {
            FrameConstants frame = sim_push.frame;
            uint nearest = frame.sampler_nearest_clamp;
            uint depth_texture = emitter.collision_depth;
            float4 clip = mul(frame.prev_view_proj_unjittered, float4(next, 1.0));
            float2 uv = clip.xy / clip.w * 0.5 + 0.5;
            float along = clipDepth(frame, clip);
            if (along > frame.near && all(uv > 0.0) && all(uv < 1.0)) {
                float depth = sampleTextureLod(depth_texture, nearest, uv, 0.0).r;
                float surface = linearDepth(depth, frame.depth_terms);
                float behind = along - surface;
                if (depth > 0.0 && behind > 0.0 && behind < 0.5 + length(particle.velocity) * dt * 2.0) {
                    float2 texel = 1.0 / textureSize(depth_texture);
                    float3 here = worldPositionFromDepth(uv, depth, frame.inv_view_proj);
                    float3 across = worldPositionFromDepth(uv + float2(texel.x, 0.0), sampleTextureLod(depth_texture, nearest, uv + float2(texel.x, 0.0), 0.0).r, frame.inv_view_proj);
                    float3 down = worldPositionFromDepth(uv + float2(0.0, texel.y), sampleTextureLod(depth_texture, nearest, uv + float2(0.0, texel.y), 0.0).r, frame.inv_view_proj);
                    float3 normal = normalize(cross(across - here, down - here));
                    if (dot(normal, eyePoint(frame, here) - here) < 0.0) normal = -normal;
                    if (dot(particle.velocity, normal) < 0.0)
                        particle.velocity = reflect(particle.velocity, normal) * emitter.bounce;
                    next = here + normal * 0.01 + particle.velocity * dt;
                }
            }
        }
        particle.position = next;
        particle.age += dt;
    }
    sim_push.particles[index] = particle;
}

#include "particles.SortKeysPush.slang"

[[vk::push_constant]] SortKeysPush sort_keys_push;

[shader("compute")]
[numthreads(64, 1, 1)]
void sortKeysMain(uint3 id : SV_DispatchThreadID) {
    uint index = id.x;
    if (index >= sort_keys_push.count) return;
    SortEntry entry = { 1e30, 0xffffffffu };
    if (index < sort_keys_push.capacity) {
        Particle particle = loadAligned<16>(sort_keys_push.particles + index);
        if (particle.age < particle.lifetime) {
            float3 away = particle.position - eyePoint(sort_keys_push.frame, particle.position);
            entry.key = -dot(away, away);
            entry.index = index;
        }
    }
    sort_keys_push.order[index] = entry;
}

#include "particles.SortPush.slang"

[[vk::push_constant]] SortPush sort_push;

[shader("compute")]
[numthreads(64, 1, 1)]
void sortMain(uint3 id : SV_DispatchThreadID) {
    uint index = id.x;
    uint partner = index ^ sort_push.stride;
    if (partner <= index || partner >= sort_push.count) return;
    SortEntry a = loadAligned<8>(sort_push.order + index);
    SortEntry b = loadAligned<8>(sort_push.order + partner);
    bool ascending = (index & sort_push.run) == 0u;
    if ((a.key > b.key) == ascending) {
        sort_push.order[index] = b;
        sort_push.order[partner] = a;
    }
}

#include "particles.SpriteVertexPush.slang"

[[vk::push_constant]] SpriteVertexPush sprite_vertex_push;

struct SpriteVertexVaryings {
    [[vk::location(0)]] float4 color;
    [[vk::location(1)]] float2 uv;
    [[vk::location(2)]] float view_depth;
    [[vk::location(3)]] float4 clip;
    [[vk::location(4)]] float4 previous_clip;
    float4 screen : SV_Position;
};

[shader("vertex")]
SpriteVertexVaryings spriteVertexMain(uint vertex : SV_VulkanVertexID) {
    SpriteVertexVaryings result;
    FrameConstants frame = sprite_vertex_push.frame;
    EmitterData* emitter = sprite_vertex_push.emitter.data;
    uint slot = vertex / 6u;
    bool listed = true;
    if ((emitter.flags & EMITTER_SORTED) != 0u) {
        slot = sprite_vertex_push.order[slot].index;
        listed = slot != 0xffffffffu;
        if (!listed) slot = 0u;
    }
    Particle particle = loadAligned<16>(sprite_vertex_push.particles + slot);
    if (!listed || particle.age >= particle.lifetime) {
        result.screen = float4(0.0, 0.0, 2.0, 1.0);
        result.color = float4(0.0);
        result.uv = float2(0.0);
        result.view_depth = 0.0;
        result.clip = float4(0.0, 0.0, 0.0, 1.0);
        result.previous_clip = float4(0.0, 0.0, 0.0, 1.0);
        return result;
    }
    const float2 corners[6] = { float2(-1, -1), float2(1, -1), float2(1, 1), float2(-1, -1), float2(1, 1), float2(-1, 1) };
    float2 corner = corners[vertex % 6u];
    float t = particle.age / particle.lifetime;
    float size = lerp(emitter.size.x, emitter.size.y, t);
    if ((emitter.keys & 2u) != 0u)
        size = t < emitter.mid ? lerp(emitter.size.x, emitter.size_mid, t / emitter.mid) : lerp(emitter.size_mid, emitter.size.y, (t - emitter.mid) / (1.0 - emitter.mid));
    if (emitter.curve_counts.y >= 2u) {
        float at = t * float(emitter.curve_counts.y - 1u);
        uint key = min(uint(at), emitter.curve_counts.y - 2u);
        size = lerp(emitter.curve_sizes[key], emitter.curve_sizes[key + 1u], at - float(key));
    }
    float3 right = matrixColumn(frame.inv_view, 0);
    float3 up = matrixColumn(frame.inv_view, 1);
    float2 half_size = float2(size * 0.5);
    if (emitter.stretch > 0.0) {
        float3 toward = normalize(particle.position - eyePoint(frame, particle.position));
        float3 along = particle.velocity - toward * dot(particle.velocity, toward);
        float speed = length(along);
        if (speed > 1e-4) {
            up = along / speed;
            right = normalize(cross(up, toward));
            half_size.y += emitter.stretch * speed * 0.5;
        }
    }
    float3 world = particle.position + right * corner.x * half_size.x + up * corner.y * half_size.y;

    float4 color = lerp(emitter.color_start, emitter.color_end, t);
    if ((emitter.keys & 1u) != 0u)
        color = t < emitter.mid ? lerp(emitter.color_start, emitter.color_mid, t / emitter.mid) : lerp(emitter.color_mid, emitter.color_end, (t - emitter.mid) / (1.0 - emitter.mid));
    if (emitter.curve_counts.x >= 2u) {
        float at = t * float(emitter.curve_counts.x - 1u);
        uint key = min(uint(at), emitter.curve_counts.x - 2u);
        color = lerp(emitter.curve_colors[key], emitter.curve_colors[key + 1u], at - float(key));
    }
    color.a *= smoothstep(0.0, 0.08, t);
    float view_depth = -(mul(frame.view, float4(particle.position, 1.0))).z;
    if ((emitter.flags & EMITTER_LIT) != 0u) {
        float3 light = float3(0.0);
        if (frame.gi.enabled != 0u) {
            light += giAmbient(frame, particle.position) * frame.gi.gi_intensity;
        } else if (frame.environment != 0u) {
            light += sampleCubeLod(frame.env_irradiance, frame.sampler_linear_clamp, float3(0.0, 1.0, 0.0), 0.0).rgb * frame.env_intensity;
        }
        float shadow = sunShadow(frame, particle.position, frame.sun_direction, 1.0, view_depth, 0.5);
        light += frame.sun_radiance * shadow * (0.5 / PI);
        color.rgb *= light;
    }
    result.color = color;
    result.uv = corner * 0.5 + 0.5;
    if (emitter.image != INVALID_ID) {
        uint frames = max(emitter.sheet.x * emitter.sheet.y, 1u);
        uint shown = min(uint(t * float(frames)), frames - 1u);
        float2 cell = float2(shown % max(emitter.sheet.x, 1u), shown / max(emitter.sheet.x, 1u));
        result.uv = (cell + result.uv) / float2(max(emitter.sheet, uint2(1u)));
    }
    result.view_depth = -(mul(frame.view, float4(world, 1.0))).z;
    result.screen = mul(frame.view_proj, float4(world, 1.0));
    result.clip = mul(frame.view_proj_unjittered, float4(world, 1.0));
    result.previous_clip = mul(frame.prev_view_proj_unjittered, float4(world - particle.velocity * frame.delta_time, 1.0));
    return result;
}

#include "particles.SpriteFragmentPush.slang"

[[vk::push_constant]] SpriteFragmentPush sprite_fragment_push;

struct SpriteFragmentOutput {
    float4 color : SV_Target0;
    float4 motion : SV_Target1;
};

[shader("fragment")]
SpriteFragmentOutput spriteFragmentMain(
    [[vk::location(0)]] float4 in_color,
    [[vk::location(1)]] float2 in_uv,
    [[vk::location(2)]] float in_view_depth,
    [[vk::location(3)]] float4 in_clip,
    [[vk::location(4)]] float4 in_previous_clip,
    float4 fragment : SV_Position) {
    FrameConstants frame = sprite_fragment_push.frame;
    EmitterData* emitter = sprite_fragment_push.emitter.data;
    float4 color = in_color;
    if (emitter.image != INVALID_ID) {
        color *= sampleTexture(emitter.image, frame.sampler_linear_clamp, in_uv);
    } else {
        float2 centered = in_uv * 2.0 - 1.0;
        float falloff = clamp(1.0 - dot(centered, centered), 0.0, 1.0);
        color.a *= falloff * falloff;
    }
    float scene = linearDepth(fetchTexel(sprite_fragment_push.depth_texture, int2(fragment.xy)).r, frame.depth_terms);
    float fade = emitter.softness > 0.0 ? clamp((scene - in_view_depth) / emitter.softness, 0.0, 1.0) : float(scene > in_view_depth);
    color.a *= fade;
    if (color.a <= 0.0) discard;
    SpriteFragmentOutput result;
    result.color = float4(color.rgb * color.a, (emitter.flags & EMITTER_ADDITIVE) != 0u ? 0.0 : color.a);
    result.motion = float4((in_clip.xy / in_clip.w - in_previous_clip.xy / in_previous_clip.w) * 0.5, 0.0, color.a);
    return result;
}

#include "particles.TrailVertexPush.slang"

[[vk::push_constant]] TrailVertexPush trail_vertex_push;

float3 ribbonPoint(EmitterData* emitter, uint slot, float3 head, uint k) {
    if (k == 0u) return head;
    uint count = emitter.trail_count;
    uint index = (emitter.trail_head + count - (k - 1u)) % count;
    float3 point = trail_vertex_push.trail[slot * count + index].xyz;
    if (k == count && count > 1u) {
        uint newer = (emitter.trail_head + count - (k - 2u)) % count;
        point = lerp(point, trail_vertex_push.trail[slot * count + newer].xyz, emitter.trail_fraction);
    }
    return point;
}

struct TrailVertexVaryings {
    [[vk::location(0)]] float4 color;
    [[vk::location(1)]] float2 uv;
    [[vk::location(2)]] float view_depth;
    [[vk::location(3)]] float4 clip;
    [[vk::location(4)]] float4 previous_clip;
    float4 screen : SV_Position;
};

[shader("vertex")]
TrailVertexVaryings trailVertexMain(uint vertex : SV_VulkanVertexID) {
    TrailVertexVaryings result;
    FrameConstants frame = trail_vertex_push.frame;
    EmitterData* emitter = trail_vertex_push.emitter.data;
    uint count = max(emitter.trail_count, 1u);
    uint slot = vertex / (6u * count);
    uint segment = (vertex / 6u) % count;
    Particle particle = loadAligned<16>(trail_vertex_push.particles + slot);
    if (particle.age >= particle.lifetime) {
        result.screen = float4(0.0, 0.0, 2.0, 1.0);
        result.color = float4(0.0);
        result.uv = float2(0.0);
        result.view_depth = 0.0;
        result.clip = float4(0.0, 0.0, 0.0, 1.0);
        result.previous_clip = float4(0.0, 0.0, 0.0, 1.0);
        return result;
    }
    const float2 corners[6] = { float2(-1, 0), float2(1, 0), float2(1, 1), float2(-1, 0), float2(1, 1), float2(-1, 1) };
    float2 corner = corners[vertex % 6u];
    uint k = segment + uint(corner.y);
    float along = float(k) / float(count);

    float3 center = ribbonPoint(emitter, slot, particle.position, k);
    float3 ahead = ribbonPoint(emitter, slot, particle.position, k > 0u ? k - 1u : 0u);
    float3 behind = ribbonPoint(emitter, slot, particle.position, min(k + 1u, count));
    float3 direction = ahead - behind;
    if (dot(direction, direction) < 1e-10) direction = particle.velocity;
    float3 toward = normalize(center - eyePoint(frame, center));
    float3 across = cross(direction, toward);
    float across_length = length(across);
    across = across_length > 1e-6 ? across / across_length : matrixColumn(frame.inv_view, 0);

    float t = particle.age / particle.lifetime;
    float size = lerp(emitter.size.x, emitter.size.y, t);
    if ((emitter.keys & 2u) != 0u)
        size = t < emitter.mid ? lerp(emitter.size.x, emitter.size_mid, t / emitter.mid) : lerp(emitter.size_mid, emitter.size.y, (t - emitter.mid) / (1.0 - emitter.mid));
    if (emitter.curve_counts.y >= 2u) {
        float at = t * float(emitter.curve_counts.y - 1u);
        uint key = min(uint(at), emitter.curve_counts.y - 2u);
        size = lerp(emitter.curve_sizes[key], emitter.curve_sizes[key + 1u], at - float(key));
    }
    float taper = 1.0 - along;
    float3 world = center + across * corner.x * size * 0.5 * taper;

    float4 color = lerp(emitter.color_start, emitter.color_end, t);
    if ((emitter.keys & 1u) != 0u)
        color = t < emitter.mid ? lerp(emitter.color_start, emitter.color_mid, t / emitter.mid) : lerp(emitter.color_mid, emitter.color_end, (t - emitter.mid) / (1.0 - emitter.mid));
    if (emitter.curve_counts.x >= 2u) {
        float at = t * float(emitter.curve_counts.x - 1u);
        uint key = min(uint(at), emitter.curve_counts.x - 2u);
        color = lerp(emitter.curve_colors[key], emitter.curve_colors[key + 1u], at - float(key));
    }
    color.a *= taper;
    float view_depth = -(mul(frame.view, float4(particle.position, 1.0))).z;
    if ((emitter.flags & EMITTER_LIT) != 0u) {
        float3 light = float3(0.0);
        if (frame.gi.enabled != 0u) {
            light += giAmbient(frame, particle.position) * frame.gi.gi_intensity;
        } else if (frame.environment != 0u) {
            light += sampleCubeLod(frame.env_irradiance, frame.sampler_linear_clamp, float3(0.0, 1.0, 0.0), 0.0).rgb * frame.env_intensity;
        }
        float shadow = sunShadow(frame, particle.position, frame.sun_direction, 1.0, view_depth, 0.5);
        light += frame.sun_radiance * shadow * (0.5 / PI);
        color.rgb *= light;
    }
    result.color = color;
    result.uv = float2(corner.x * 0.5 + 0.5, emitter.image != INVALID_ID ? along : 0.5);
    result.view_depth = -(mul(frame.view, float4(world, 1.0))).z;
    result.screen = mul(frame.view_proj, float4(world, 1.0));
    result.clip = mul(frame.view_proj_unjittered, float4(world, 1.0));
    result.previous_clip = mul(frame.prev_view_proj_unjittered, float4(world - (k == 0u ? particle.velocity * frame.delta_time : float3(0.0)), 1.0));
    return result;
}

#include "particles.MeshVertexPush.slang"

[[vk::push_constant]] MeshVertexPush mesh_vertex_push;

uint hashSlot(uint value) {
    value ^= value >> 16;
    value *= 0x7feb352du;
    value ^= value >> 15;
    value *= 0x846ca68bu;
    value ^= value >> 16;
    return value;
}

float3 turn(float3 v, float3 axis, float angle) {
    float s = sin(angle);
    float c = cos(angle);
    return v * c + cross(axis, v) * s + axis * dot(axis, v) * (1.0 - c);
}

struct MeshVertexVaryings {
    [[vk::location(0)]] float4 color;
    [[vk::location(1)]] float2 uv;
    [[vk::location(2)]] float4 clip;
    [[vk::location(3)]] float4 previous_clip;
    float4 screen : SV_Position;
};

[shader("vertex")]
MeshVertexVaryings meshVertexMain(uint vertex_index : SV_VulkanVertexID, uint instance : SV_VulkanInstanceID) {
    MeshVertexVaryings result;
    FrameConstants frame = mesh_vertex_push.frame;
    EmitterData* emitter = mesh_vertex_push.emitter.data;
    uint slot = instance;
    Particle particle = loadAligned<16>(mesh_vertex_push.particles + slot);
    if (particle.age >= particle.lifetime) {
        result.screen = float4(0.0, 0.0, 2.0, 1.0);
        result.color = float4(0.0);
        result.uv = float2(0.0);
        result.clip = float4(0.0, 0.0, 0.0, 1.0);
        result.previous_clip = float4(0.0, 0.0, 0.0, 1.0);
        return result;
    }
    Vertex vertex = frame.vertices.data[mesh_vertex_push.vertex_offset + vertex_index];
    float t = particle.age / particle.lifetime;
    float size = lerp(emitter.size.x, emitter.size.y, t);
    if ((emitter.keys & 2u) != 0u)
        size = t < emitter.mid ? lerp(emitter.size.x, emitter.size_mid, t / emitter.mid) : lerp(emitter.size_mid, emitter.size.y, (t - emitter.mid) / (1.0 - emitter.mid));
    if (emitter.curve_counts.y >= 2u) {
        float at = t * float(emitter.curve_counts.y - 1u);
        uint key = min(uint(at), emitter.curve_counts.y - 2u);
        size = lerp(emitter.curve_sizes[key], emitter.curve_sizes[key + 1u], at - float(key));
    }

    uint h = hashSlot(slot + 1u);
    float3 axis = normalize(float3(h & 1023u, (h >> 10) & 1023u, (h >> 20) & 1023u) / 511.5 - 1.0 + float3(1e-3, 0.0, 0.0));
    float pace = 0.5 + float(hashSlot(h) & 1023u) / 1023.0;
    float phase = float(hashSlot(h + 7u) & 1023u) / 1023.0 * 6.2831853;
    float angle = phase + mesh_vertex_push.spin * pace * particle.age;
    float previous_angle = phase + mesh_vertex_push.spin * pace * max(particle.age - frame.delta_time, 0.0);

    float3 world = particle.position + turn(vertex.position, axis, angle) * size;
    float3 normal = turn(vertexNormal(vertex), axis, angle);

    float4 color = lerp(emitter.color_start, emitter.color_end, t);
    if ((emitter.keys & 1u) != 0u)
        color = t < emitter.mid ? lerp(emitter.color_start, emitter.color_mid, t / emitter.mid) : lerp(emitter.color_mid, emitter.color_end, (t - emitter.mid) / (1.0 - emitter.mid));
    if (emitter.curve_counts.x >= 2u) {
        float at = t * float(emitter.curve_counts.x - 1u);
        uint key = min(uint(at), emitter.curve_counts.x - 2u);
        color = lerp(emitter.curve_colors[key], emitter.curve_colors[key + 1u], at - float(key));
    }
    color *= unpackUnorm(vertex.color);
    if ((emitter.flags & EMITTER_LIT) != 0u) {
        float3 light = float3(0.0);
        if (frame.gi.enabled != 0u) {
            light += giAmbient(frame, particle.position) * frame.gi.gi_intensity;
        } else if (frame.environment != 0u) {
            light += sampleCubeLod(frame.env_irradiance, frame.sampler_linear_clamp, normal, 0.0).rgb * frame.env_intensity;
        }
        float view_depth = -(mul(frame.view, float4(particle.position, 1.0))).z;
        float shadow = sunShadow(frame, particle.position, frame.sun_direction, 1.0, view_depth, 0.5);
        light += frame.sun_radiance * shadow * max(dot(normal, frame.sun_direction), 0.0) / PI;
        color.rgb *= light;
    }
    result.color = color;
    result.uv = vertex.uv;
    result.screen = mul(frame.view_proj, float4(world, 1.0));
    result.clip = mul(frame.view_proj_unjittered, float4(world, 1.0));
    float3 previous = particle.position - particle.velocity * frame.delta_time + turn(vertex.position, axis, previous_angle) * size;
    result.previous_clip = mul(frame.prev_view_proj_unjittered, float4(previous, 1.0));
    return result;
}

#include "particles.MeshFragmentPush.slang"

[[vk::push_constant]] MeshFragmentPush mesh_fragment_push;

struct MeshFragmentOutput {
    float4 color : SV_Target0;
    float4 motion : SV_Target1;
};

[shader("fragment")]
MeshFragmentOutput meshFragmentMain(
    [[vk::location(0)]] float4 in_color,
    [[vk::location(1)]] float2 in_uv,
    [[vk::location(2)]] float4 in_clip,
    [[vk::location(3)]] float4 in_previous_clip) {
    FrameConstants frame = mesh_fragment_push.frame;
    EmitterData* emitter = mesh_fragment_push.emitter.data;
    float4 color = in_color;
    if (emitter.image != INVALID_ID) color *= sampleTexture(emitter.image, frame.sampler_linear_repeat, in_uv);
    if (color.a <= 0.0) discard;
    MeshFragmentOutput result;
    result.color = float4(color.rgb * color.a, (emitter.flags & EMITTER_ADDITIVE) != 0u ? 0.0 : color.a);
    result.motion = float4((in_clip.xy / in_clip.w - in_previous_clip.xy / in_previous_clip.w) * 0.5, 0.0, color.a);
    return result;
}
