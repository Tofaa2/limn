#include "common.slang"

/// A ball of the blob, and where it was a frame ago.
struct Orb {
    float3 position;
    float radius;
    float3 previous;
    float pad;
};

struct MovePush {
    Orb* orbs;
    uint count;
    float time;
};

[[vk::push_constant]] MovePush move_push;

/// Moves the balls: work of the application's own, on the GPU, that the
/// drawing pass then reads.
[shader("compute")]
[numthreads(64, 1, 1)]
void moveMain(uint3 id : SV_DispatchThreadID) {
    if (id.x >= move_push.count) return;
    float phase = float(id.x) * 1.7;
    float t = move_push.time;
    move_push.orbs[id.x].previous = move_push.orbs[id.x].position;
    move_push.orbs[id.x].position = float3(sin(t * 0.9 + phase) * 1.1, 1.4 + sin(t * 1.3 + phase * 2.1) * 0.45, cos(t * 0.7 + phase * 1.3) * 1.1);
    move_push.orbs[id.x].radius = 0.32 + 0.1 * sin(phase);
}

struct Fullscreen {
    [[vk::location(0)]] float2 uv;
    float4 position : SV_Position;
};

[shader("vertex")]
Fullscreen fullscreenMain(uint vertex : SV_VulkanVertexID) {
    Fullscreen result;
    result.uv = float2((vertex << 1) & 2, vertex & 2);
    result.position = float4(result.uv * 2.0 - 1.0, 0.0, 1.0);
    return result;
}

struct OrbsPush {
    FrameConstants frame;
    Orb* orbs;
    uint count;
    uint pad;
};

[[vk::push_constant]] OrbsPush orbs_push;

/// Distance to the blob, the balls melted together, and the nearest ball.
float blob(float3 p, out uint nearest) {
    float merged = 1e9;
    float closest = 1e9;
    nearest = 0u;
    for (uint i = 0u; i < orbs_push.count; i++) {
        Orb orb = orbs_push.orbs[i];
        float d = length(p - orb.position) - orb.radius;
        if (d < closest) {
            closest = d;
            nearest = i;
        }
        float h = clamp(0.5 + 0.5 * (d - merged) / 0.3, 0.0, 1.0);
        merged = lerp(d, merged, h) - 0.3 * h * (1.0 - h);
    }
    return merged;
}

struct OrbsOutput {
    float4 color : SV_Target0;
    float4 motion : SV_Target1;
    float depth : SV_Depth;
};

/// Geometry of the application's own in the lit scene: a blob found by
/// marching rays, lit by the scene's sun and sky, hidden behind the scene by
/// the depth test, with motion vectors so antialiasing keeps it sharp.
[shader("fragment")]
OrbsOutput orbsMain(float4 fragment : SV_Position) {
    FrameConstants frame = orbs_push.frame;
    float2 uv = fragment.xy * frame.inv_resolution;
    float3 origin = frame.camera_position;
    float3 way = normalize(worldPositionFromDepth(uv, 0.5, frame.inv_view_proj) - origin);
    float t = 0.05;
    uint nearest = 0u;
    bool hit = false;
    for (int step = 0; step < 96 && t < 40.0; step++) {
        float d = blob(origin + way * t, nearest);
        if (d < 0.0015 * t) {
            hit = true;
            break;
        }
        t += d;
    }
    if (!hit) discard;
    float3 p = origin + way * t;
    uint ignored;
    const float e = 0.002;
    float3 normal = normalize(float3(
        blob(p + float3(e, 0, 0), ignored) - blob(p - float3(e, 0, 0), ignored),
        blob(p + float3(0, e, 0), ignored) - blob(p - float3(0, e, 0), ignored),
        blob(p + float3(0, 0, e), ignored) - blob(p - float3(0, 0, e), ignored)));

    float3 tint = 0.5 + 0.5 * cos(float(nearest) * 1.3 + float3(0.0, 2.1, 4.2));
    float3 sky = frame.environment != 0u ? sampleCubeLod(frame.env_irradiance, frame.sampler_linear_clamp, normal, 0.0).rgb * frame.env_intensity : float3(0.03);
    float3 view = -way;
    float3 halfway = normalize(view + frame.sun_direction);
    float lit = max(dot(normal, frame.sun_direction), 0.0);
    float shine = pow(max(dot(normal, halfway), 0.0), 64.0) * 0.6;
    float rim = pow(1.0 - max(dot(normal, view), 0.0), 4.0);

    OrbsOutput result;
    result.color = float4(tint * (sky + frame.sun_radiance * lit / PI) + frame.sun_radiance * shine * lit / PI + sky * rim, 1.0);
    float4 clip = mul(frame.view_proj, float4(p, 1.0));
    result.depth = clip.z / clip.w;
    Orb orb = orbs_push.orbs[nearest];
    float3 before = p - (orb.position - orb.previous);
    float4 now = mul(frame.view_proj_unjittered, float4(p, 1.0));
    float4 then = mul(frame.prev_view_proj_unjittered, float4(before, 1.0));
    result.motion = float4((now.xy / now.w - then.xy / then.w) * 0.5, 0.0, 1.0);
    return result;
}

struct CopyPush {
    uint source_texture;
    float exposure;
};

[[vk::push_constant]] CopyPush copy_push;

[shader("fragment")]
float4 copyMain(float4 fragment : SV_Position) : SV_Target {
    return fetchTexel(copy_push.source_texture, int2(fragment.xy));
}

/// A tone curve of the application's own (Hable's filmic curve), standing in
/// for the renderer's with `Settings.post.tone_curve` off.
[shader("fragment")]
float4 curveMain(float4 fragment : SV_Position) : SV_Target {
    float3 x = fetchTexel(copy_push.source_texture, int2(fragment.xy)).rgb * copy_push.exposure;
    const float a = 0.15, b = 0.5, c = 0.1, d = 0.2, e = 0.02, f = 0.3, white = 11.2;
    float3 curve = ((x * (a * x + c * b) + d * e) / (x * (a * x + b) + d * f)) - e / f;
    float top = ((white * (a * white + c * b) + d * e) / (white * (a * white + b) + d * f)) - e / f;
    return float4(curve / top, 1.0);
}

struct OutlinePush {
    FrameConstants frame;
    uint depth_texture;
    float strength;
};

[[vk::push_constant]] OutlinePush outline_push;

/// Ink lines where the scene's depth jumps, drawn over the finished picture.
[shader("fragment")]
float4 outlineMain(float4 fragment : SV_Position) : SV_Target {
    FrameConstants frame = outline_push.frame;
    int2 size = int2(textureSize(outline_push.depth_texture));
    int2 pixel = clamp(int2(fragment.xy * float2(size) * frame.inv_resolution), int2(1), size - 2);
    float center = fetchTexel(outline_push.depth_texture, pixel).r;
    float here = center > 0.0 ? linearDepth(center, frame.depth_terms) : 1e4;
    float around = 0.0;
    for (int i = 0; i < 4; i++) {
        int2 offset = int2(i == 0 ? 1 : (i == 1 ? -1 : 0), i == 2 ? 1 : (i == 3 ? -1 : 0));
        float raw = fetchTexel(outline_push.depth_texture, pixel + offset).r;
        around += raw > 0.0 ? linearDepth(raw, frame.depth_terms) : 1e4;
    }
    float jump = abs(around - 4.0 * here) / max(here, 0.1);
    float ink = smoothstep(0.08, 0.25, jump) * outline_push.strength;
    return float4(0.015, 0.012, 0.02, ink);
}

struct ShadowPush {
    float4x4 to_world;
    Orb* orbs;
    uint count;
    uint pad;
};

[[vk::push_constant]] ShadowPush shadow_push;

/// The blob as a caster in a sun shadow cascade: marched along the
/// cascade's parallel rays, writing the depth where they enter it.
[shader("fragment")]
float shadowMain([[vk::location(0)]] float2 uv) : SV_Depth {
    float2 ndc = uv * 2.0 - 1.0;
    float4 near_point = mul(shadow_push.to_world, float4(ndc, 0.0, 1.0));
    float4 far_point = mul(shadow_push.to_world, float4(ndc, 1.0, 1.0));
    float3 from = near_point.xyz / near_point.w;
    float3 to = far_point.xyz / far_point.w;
    float reach = length(to - from);
    float3 way = (to - from) / reach;
    float t = 0.0;
    for (int step = 0; step < 128 && t < reach; step++) {
        float merged = 1e9;
        for (uint i = 0u; i < shadow_push.count; i++) {
            Orb orb = shadow_push.orbs[i];
            float d = length(from + way * t - orb.position) - orb.radius;
            float h = clamp(0.5 + 0.5 * (d - merged) / 0.3, 0.0, 1.0);
            merged = lerp(d, merged, h) - 0.3 * h * (1.0 - h);
        }
        if (merged < 0.002) return t / reach;
        t += max(merged, 0.01);
    }
    discard;
    return 1.0;
}

struct LightShadowPush {
    float4x4 view_proj;
    float4x4 to_world;
    Orb* orbs;
    uint count;
    uint pad;
};

[[vk::push_constant]] LightShadowPush light_shadow_push;

/// The blob as a caster in a spot or point light's tile of the shadow atlas:
/// marched along rays from the light, writing the reversed depth of the
/// point where they enter it.
[shader("fragment")]
float lightShadowMain([[vk::location(0)]] float2 uv) : SV_Depth {
    float2 ndc = uv * 2.0 - 1.0;
    float4 near_point = mul(light_shadow_push.to_world, float4(ndc, 1.0, 1.0));
    float4 further = mul(light_shadow_push.to_world, float4(ndc, 0.5, 1.0));
    float3 from = near_point.xyz / near_point.w;
    float3 way = normalize(further.xyz / further.w - from);
    float t = 0.0;
    for (int step = 0; step < 128 && t < 30.0; step++) {
        float merged = 1e9;
        for (uint i = 0u; i < light_shadow_push.count; i++) {
            Orb orb = light_shadow_push.orbs[i];
            float d = length(from + way * t - orb.position) - orb.radius;
            float h = clamp(0.5 + 0.5 * (d - merged) / 0.3, 0.0, 1.0);
            merged = lerp(d, merged, h) - 0.3 * h * (1.0 - h);
        }
        if (merged < 0.002) {
            float4 clip = mul(light_shadow_push.view_proj, float4(from + way * t, 1.0));
            return clip.z / clip.w;
        }
        t += max(merged, 0.01);
    }
    discard;
    return 0.0;
}
