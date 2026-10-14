#include "water.slang"
#include "common.slang"
#include "shading.slang"

struct SimPush {
    WaterRef water;
};

[[vk::push_constant]] SimPush sim_push;

float2 state(int2 cell, int2 size) {
    cell = clamp(cell, int2(0), size - 1);
    return fetchTexel(sim_push.water.state_texture, cell).rg;
}

[shader("fragment")]
float4 simMain(float4 fragment : SV_Position) : SV_Target {
    WaterRef water = sim_push.water;
    int2 size = water.size;
    int2 cell = int2(fragment.xy);
    float2 here = state(cell, size);
    float around = state(cell + int2(1, 0), size).r + state(cell - int2(1, 0), size).r +
        state(cell + int2(0, 1), size).r + state(cell - int2(0, 1), size).r;
    float dt = min(water.dt, 0.65 / max(water.speed, 1e-6));
    float courant = water.speed * dt;
    float velocity = (here.g + courant * courant * (around - 4.0 * here.r) / max(dt, 1e-5)) * water.keep;
    float height = here.r + velocity * dt;
    height *= exp(-dt * 0.02);
    float2 uv = (float2(cell) + 0.5) / float2(size);
    for (uint i = 0u; i < water.ripple_count; i++) {
        WaterRipple ripple = water.ripples[i];
        float2 offset = (uv - ripple.position) / max(ripple.radius, 1e-4);
        float away = dot(offset, offset);
        height -= ripple.depth * (1.0 - 2.0 * away) * exp(-away * 2.0);
    }
    return float4(height, velocity, 0.0, 0.0);
}

struct SurfacePush {
    FrameConstants frame;
    WaterRef water;
    uint depth_texture;
    uint scene_texture;
    uint quads;
};

[[vk::push_constant]] SurfacePush surface_push;

struct Varyings {
    [[vk::location(0)]] float2 uv;
    [[vk::location(1)]] float3 position;
    float4 screen : SV_Position;
};

static const float2 corners[6] = { float2(0, 0), float2(1, 0), float2(1, 1), float2(0, 0), float2(1, 1), float2(0, 1) };

[shader("vertex")]
Varyings surfaceMain(uint vertex : SV_VulkanVertexID) {
    uint quad = vertex / 6u;
    float2 corner = corners[vertex % 6u];
    float2 uv = (float2(quad % surface_push.quads, quad / surface_push.quads) + corner) / float(surface_push.quads);
    float3 world = waterPoint(surface_push.water, uv, surface_push.frame.time);
    Varyings result;
    result.uv = uv;
    result.position = world;
    result.screen = mul(surface_push.frame.view_proj, float4(world, 1.0));
    return result;
}

struct ShadePush {
    FrameConstants frame;
    WaterRef water;
    uint depth_texture;
    uint scene_texture;
    uint quads;
};

[[vk::push_constant]] ShadePush shade_push;

struct ShadeOutput {
    float4 color : SV_Target0;
};

[shader("fragment")]
ShadeOutput shadeMain(
    [[vk::location(0)]] float2 in_uv,
    [[vk::location(1)]] float3 in_position,
    float4 fragment : SV_Position) {
    ShadeOutput result;
    FrameConstants frame = shade_push.frame;
    WaterRef water = shade_push.water;
    uint nearest = frame.sampler_nearest_clamp;
    uint linear = frame.sampler_linear_clamp;
    float2 screen_uv = fragment.xy * frame.inv_resolution;
    float scene_depth = fetchTexel(shade_push.depth_texture, int2(fragment.xy)).r;
    float surface_distance = clipDepth(frame, mul(frame.view_proj, float4(in_position, 1.0)));
    float scene_distance = scene_depth > 0.0 ? linearDepth(scene_depth, frame.depth_terms) : 1e9;
    if (scene_distance < surface_distance) discard;
    if (water.mask != 0xffffffffu && sampleTextureLod(water.mask, nearest, in_uv, 0.0).r < 0.5) discard;

    float2 texel = 1.0 / float2(water.size);
    float3 right = waterPoint(water, in_uv + float2(texel.x, 0.0), frame.time) - waterPoint(water, in_uv - float2(texel.x, 0.0), frame.time);
    float3 ahead = waterPoint(water, in_uv + float2(0.0, texel.y), frame.time) - waterPoint(water, in_uv - float2(0.0, texel.y), frame.time);
    float3 normal = normalize(cross(ahead, right));
    {
        float pixel = (frame.parallel != 0.0 ? 1.0 : surface_distance) * 2.0 / (abs(frame.proj[1][1]) * frame.resolution.y);
        float3 to_eye = normalize(eyePoint(frame, in_position) - in_position);
        float footprint = pixel / max(abs(dot(normal, to_eye)), 0.08);
        float2 ripple = waterDetailSlope(water.detail, in_position.xz, frame.time, footprint);
        float3 axis_x = normalize(matrixColumn(water.transform, 0));
        float3 axis_z = normalize(matrixColumn(water.transform, 2));
        normal = normalize(normal - axis_x * ripple.x - axis_z * ripple.y);
    }
    float3 view = normalize(eyePoint(frame, in_position) - in_position);
    if (dot(normal, view) < 0.0) normal = -normal;
    float n_dot_v = clamp(dot(normal, view), 0.0, 1.0);
    float fresnel = 0.02 + 0.98 * pow(1.0 - n_dot_v, 5.0);

    float3 flat_normal = normalize(matrixColumn(water.transform, 1));
    float2 bend = (mul(frame.view, float4(normal - flat_normal, 0.0))).xy * water.refraction / max(surface_distance, 0.5);
    float2 below_uv = clamp(screen_uv + bend, float2(0.001), float2(0.999));
    float below_depth = sampleTextureLod(shade_push.depth_texture, nearest, below_uv, 0.0).r;
    float below_distance = below_depth > 0.0 ? linearDepth(below_depth, frame.depth_terms) : 1e9;
    if (below_distance < surface_distance) {
        below_uv = screen_uv;
        below_distance = scene_distance;
    }
    float3 below = sampleTextureLod(shade_push.scene_texture, linear, below_uv, 0.0).rgb;
    if (water.caustics > 0.0 && below_distance < 1e8) {
        float below_raw = sampleTextureLod(shade_push.depth_texture, nearest, below_uv, 0.0).r;
        float3 below_point = worldPositionFromDepth(below_uv, below_raw, frame.inv_view_proj);
        below *= lerp(1.0, waterCaustic(water, below_point, frame.sun_direction, frame.time), sunShadow(frame, below_point, flat_normal, 1.0, below_distance, 0.5));
    }
    float looked_through = min(below_distance - surface_distance, 1e4) / max(n_dot_v, 0.2);
    float3 tint = water.color / max(max(water.color.r, water.color.g), max(water.color.b, 1.0e-4));
    float3 clear = exp(-looked_through * water.murk * (float3(1.25) - tint));
    float3 ambient = float3(0.0);
    if ((frame.flags & FRAME_ENVIRONMENT) != 0u)
        ambient = sampleCubeLod(frame.env_irradiance, linear, float3(0.0, 1.0, 0.0), 0.0).rgb * frame.env_intensity;
    float sun_shadow = sunShadow(frame, in_position, normal, 1.0, surface_distance, 0.5);
    float3 body = water.color * (ambient + frame.sun_radiance * max(frame.sun_direction.y, 0.0) * sun_shadow * 0.3);
    float3 under = lerp(body, below, clear);

    float3 mirror = reflect(-view, normal);
    if (dot(mirror, flat_normal) < 0.02) mirror = normalize(mirror + flat_normal * (0.02 - dot(mirror, flat_normal)));
    float3 reflected = float3(0.0);
    bool found = false;
#ifdef RAY_TRACED
    if ((frame.tlas_low | frame.tlas_high) != 0u) {
        uint64_t tlas = uint64_t(frame.tlas_low) | (uint64_t(frame.tlas_high) << 32);
        Tracer tracer;
        tracer.frame = frame;
        tracer.scene = tlas;
        LitRay seen = tracePicture(tracer, in_position + flat_normal * 0.02, mirror, 200.0, 1.0 + water.roughness * 8.0);
        found = seen.met != RAY_MISS;
        if (found) reflected = throughFluids(frame, in_position, mirror, seen.distance, seen.radiance);
    }
#endif
    if (!found && (frame.flags & FRAME_ENVIRONMENT) != 0u)
        reflected = sampleCubeLod(frame.env_specular, linear, mirror, water.roughness * (frame.env_specular_mips - 1.0)).rgb * frame.env_intensity;

    if (dot(flat_normal, view) < 0.0) {
        const float water_index = 1.33;
        float leaves = 1.0 - water_index * water_index * (1.0 - n_dot_v * n_dot_v);
        float out_cosine = sqrt(max(leaves, 0.0));
        float base = 1.0 - out_cosine;
        fresnel = leaves > 0.0 ? 0.02 + 0.98 * base * base * base * base * base : 1.0;
        reflected = body;
        under = below;
    }
    float3 color = lerp(under, reflected, fresnel);
    if (water.foam > 0.0) {
        float thickness = max(scene_distance - surface_distance, 0.0);
        float churn = abs(sampleTextureLod(water.state_texture, linear, in_uv, 0.0).g) * length(matrixColumn(water.transform, 1));
        float foam = (1.0 - smoothstep(0.0, 0.18, thickness)) + smoothstep(0.25, 1.2, churn);
        float grain = 0.0;
        float share = 0.65;
        float2 at = in_position.xz * 7.0 + frame.time * 0.15;
        for (int octave = 0; octave < 2; octave++) {
            float2 corner = floor(at);
            float2 within = at - corner;
            within = within * within * (3.0 - 2.0 * within);
            float a = frac(sin(dot(corner, float2(127.1, 311.7))) * 43758.5453);
            float b = frac(sin(dot(corner + float2(1.0, 0.0), float2(127.1, 311.7))) * 43758.5453);
            float c = frac(sin(dot(corner + float2(0.0, 1.0), float2(127.1, 311.7))) * 43758.5453);
            float d = frac(sin(dot(corner + float2(1.0, 1.0), float2(127.1, 311.7))) * 43758.5453);
            grain += share * lerp(lerp(a, b, within.x), lerp(c, d, within.x), within.y);
            at = at * 2.7 + 13.1;
            share = 0.35;
        }
        foam = clamp(foam * (0.55 + 0.9 * grain) * water.foam, 0.0, 1.0);
        float3 froth = float3(0.9) * (ambient + frame.sun_radiance * max(frame.sun_direction.y, 0.0) * sun_shadow / PI);
        color = lerp(color, froth, foam);
    }
    color += directLight(normal, view, frame.sun_direction, frame.sun_radiance * sun_shadow, float3(0.0), float3(0.02), max(water.roughness, 0.04));
    result.color = float4(color, 1.0);
    return result;
}

struct UnderwaterPush {
    FrameConstants frame;
    WaterRef water;
    uint depth_texture;
    uint scene_texture;
};

[[vk::push_constant]] UnderwaterPush underwater_push;

struct UnderwaterOutput {
    float4 color : SV_Target0;
};

[shader("fragment")]
UnderwaterOutput underwaterMain(
    [[vk::location(0)]] float2 in_uv,
    float4 fragment : SV_Position) {
    UnderwaterOutput result;
    FrameConstants frame = underwater_push.frame;
    WaterRef water = underwater_push.water;
    uint nearest = frame.sampler_nearest_clamp;
    float2 screen_uv = fragment.xy * frame.inv_resolution;
    float3 scene = fetchTexel(underwater_push.scene_texture, int2(fragment.xy)).rgb;
    float depth = fetchTexel(underwater_push.depth_texture, int2(fragment.xy)).r;
    float3 world = worldPositionFromDepth(screen_uv, max(depth, 1e-7), frame.inv_view_proj);
    float3 direction = normalize(world - eyePoint(frame, world));
    float reach = depth > 0.0 ? distance(world, eyePoint(frame, world)) : 1e5;

    float3 up = normalize(matrixColumn(water.transform, 1));
    float below = dot(matrixColumn(water.transform, 3) - frame.camera_position, up);
    float rise = dot(direction, up);
    float to_surface = rise > 1e-5 ? below / rise : 1e9;
    bool in_water = reach < to_surface;
    float through = min(reach, to_surface);

    if (in_water) scene *= lerp(1.0, waterCaustic(water, world, frame.sun_direction, frame.time), sunShadow(frame, world, up, 1.0, reach, 0.5));
    float3 ambient = float3(0.0);
    if ((frame.flags & FRAME_ENVIRONMENT) != 0u)
        ambient = sampleCubeLod(frame.env_irradiance, frame.sampler_linear_clamp, float3(0.0, 1.0, 0.0), 0.0).rgb * frame.env_intensity;
    float3 body = water.color * (ambient + frame.sun_radiance * max(frame.sun_direction.y, 0.0) * 0.3);
    result.color = float4(lerp(body, scene, exp(-through * water.murk)), 1.0);
    return result;
}
