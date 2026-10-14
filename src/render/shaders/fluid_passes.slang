#include "fluid.slang"
#include "trace.slang"
#include "common.slang"
#include "gi.slang"
#include "media.slang"

struct AdvectPush {
    FluidRef fluid;
    uint velocity_texture;
    uint scalars_texture;
    uint carried_texture;
    uint carried_velocity_texture;
};

[[vk::push_constant]] AdvectPush advect_push;

struct AdvectOutput {
    float4 velocity : SV_Target0;
    float4 scalars : SV_Target1;
};

[shader("fragment")]
AdvectOutput advectMain(float4 fragment : SV_Position) {
    FluidRef fluid = advect_push.fluid;
    int3 size = fluid.data.size;
    int3 cell = fluidCell(fluid, int2(fragment.xy));
    AdvectOutput result;
    result.velocity = float4(0.0);
    result.scalars = float4(0.0);
    if (cell.z >= size.z) return result;
    if (fluidObstacle(fluid, cell)) {
        result.velocity = float4(0.0, 0.0, 0.0, 1.0);
        return result;
    }
    float dt = fluid.data.dt;
    float3 position = float3(cell) + 0.5;
    float3 velocity_here = fluidFetch(fluid, advect_push.velocity_texture, cell).xyz;
    float3 velocity = velocity_here;
    float3 source = position - velocity * dt;
    if (size.z == 1) source.z = 0.5;

    velocity = fluidSample(fluid, advect_push.velocity_texture, source).xyz;
    float4 scalars = fluidSample(fluid, advect_push.scalars_texture, source);
    if (advect_push.carried_texture != INVALID_ID) {
        float4 guess = fluidFetch(fluid, advect_push.carried_texture, cell);
        float3 ahead = position + velocity_here * dt;
        if (size.z == 1) ahead.z = 0.5;
        float4 returned = fluidSample(fluid, advect_push.carried_texture, ahead);
        float4 corrected = guess + 0.5 * (fluidFetch(fluid, advect_push.scalars_texture, cell) - returned);
        int3 base = int3(floor(source - 0.5));
        float4 low = float4(1e30);
        float4 high = float4(-1e30);
        for (int i = 0; i < (size.z == 1 ? 4 : 8); i++) {
            float4 corner = fluidFetch(fluid, advect_push.scalars_texture, base + int3(i & 1, (i >> 1) & 1, (i >> 2) & 1));
            low = min(low, corner);
            high = max(high, corner);
        }
        scalars = clamp(corrected, low, high);
        if (advect_push.carried_velocity_texture != INVALID_ID) {
            float3 guess_velocity = fluidFetch(fluid, advect_push.carried_velocity_texture, cell).xyz;
            float3 returned_velocity = fluidSample(fluid, advect_push.carried_velocity_texture, ahead).xyz;
            float3 corrected_velocity = guess_velocity + 0.5 * (velocity_here - returned_velocity);
            float3 slowest = float3(1e30);
            float3 fastest = float3(-1e30);
            float solid = 0.0;
            for (int i = 0; i < (size.z == 1 ? 4 : 8); i++) {
                float4 corner = fluidFetch(fluid, advect_push.velocity_texture, base + int3(i & 1, (i >> 1) & 1, (i >> 2) & 1));
                slowest = min(slowest, corner.xyz);
                fastest = max(fastest, corner.xyz);
                solid = max(solid, corner.w);
            }
            if (solid == 0.0) velocity = clamp(corrected_velocity, slowest, fastest);
        }
    }
    int3 from = int3(floor(source));
    if (!fluidInside(fluid, from) && !fluidWall(fluid, from)) {
        scalars = float4(0.0);
        velocity = float3(0.0);
    }

    float burning = scalars.z * (1.0 - fluid.data.fuel_keep) * smoothstep(0.05, 0.3, scalars.y);
    scalars.z -= burning;
    scalars.y += burning * fluid.data.heat;
    scalars.x += burning * fluid.data.soot;

    velocity *= fluid.data.velocity_keep;
    scalars.x *= fluid.data.smoke_keep;
    scalars.y *= fluid.data.heat_keep;

    for (uint i = 0u; i < fluid.data.source_count; i++) {
        FluidSource emitter = fluid.data.sources[i];
        float3 offset = position - emitter.position * float3(size);
        if (size.z == 1) offset.z = 0.0;
        float reach = max(emitter.radius * float(size.y), 0.5);
        float amount = clamp(1.0 - length(offset) / reach, 0.0, 1.0);
        if (amount <= 0.0) continue;
        amount = amount * amount * (3.0 - 2.0 * amount);
        scalars.x += emitter.smoke * amount * dt;
        scalars.y += emitter.temperature * amount * dt;
        scalars.z += emitter.fuel * amount * dt;
        velocity = lerp(velocity, emitter.velocity, amount * min(dt * 10.0, 1.0));
    }
    result.velocity = float4(velocity, 0.0);
    result.scalars = max(scalars, float4(0.0));
    return result;
}

struct CarryPush {
    FluidRef fluid;
    uint velocity_texture;
    uint scalars_texture;
};

[[vk::push_constant]] CarryPush carry_push;

struct CarryOutput {
    float4 scalars : SV_Target0;
    float4 velocity : SV_Target1;
};

[shader("fragment")]
CarryOutput carryMain(float4 fragment : SV_Position) {
    FluidRef fluid = carry_push.fluid;
    int3 size = fluid.data.size;
    int3 cell = fluidCell(fluid, int2(fragment.xy));
    CarryOutput result;
    result.scalars = float4(0.0);
    result.velocity = float4(0.0);
    if (cell.z >= size.z) return result;
    float3 position = float3(cell) + 0.5;
    float3 source = position - fluidFetch(fluid, carry_push.velocity_texture, cell).xyz * fluid.data.dt;
    if (size.z == 1) source.z = 0.5;
    result.scalars = fluidSample(fluid, carry_push.scalars_texture, source);
    result.velocity = fluidSample(fluid, carry_push.velocity_texture, source);
    return result;
}

struct CurlPush {
    FluidRef fluid;
    uint velocity_texture;
};

[[vk::push_constant]] CurlPush curl_push;

[shader("fragment")]
float4 curlMain(float4 fragment : SV_Position) : SV_Target {
    FluidRef fluid = curl_push.fluid;
    int3 cell = fluidCell(fluid, int2(fragment.xy));
    if (cell.z >= fluid.data.size.z) return float4(0.0);
    uint v = curl_push.velocity_texture;
    float4 center = fluidFetch(fluid, v, cell);
    if (center.w > 0.5) return float4(0.0);
    float3 right = fluidVelocity(fluid, v, cell + int3(1, 0, 0), cell, center.xyz);
    float3 left = fluidVelocity(fluid, v, cell - int3(1, 0, 0), cell, center.xyz);
    float3 up = fluidVelocity(fluid, v, cell + int3(0, 1, 0), cell, center.xyz);
    float3 down = fluidVelocity(fluid, v, cell - int3(0, 1, 0), cell, center.xyz);
    float3 front = fluidVelocity(fluid, v, cell + int3(0, 0, 1), cell, center.xyz);
    float3 back = fluidVelocity(fluid, v, cell - int3(0, 0, 1), cell, center.xyz);
    float3 curl = 0.5 * float3(
        (up.z - down.z) - (front.y - back.y),
        (front.x - back.x) - (right.z - left.z),
        (right.y - left.y) - (up.x - down.x));
    return float4(curl, length(curl));
}

struct DivergencePush {
    FluidRef fluid;
    uint velocity_texture;
};

[[vk::push_constant]] DivergencePush divergence_push;

[shader("fragment")]
float4 divergenceMain(float4 fragment : SV_Position) : SV_Target {
    FluidRef fluid = divergence_push.fluid;
    int3 cell = fluidCell(fluid, int2(fragment.xy));
    if (cell.z >= fluid.data.size.z) return float4(0.0);
    uint v = divergence_push.velocity_texture;
    float4 center = fluidFetch(fluid, v, cell);
    if (center.w > 0.5) return float4(0.0, 1.0, 0.0, 0.0);
    float3 c = center.xyz;
    float divergence = fluidVelocity(fluid, v, cell + int3(1, 0, 0), cell, c).x - fluidVelocity(fluid, v, cell - int3(1, 0, 0), cell, c).x +
        fluidVelocity(fluid, v, cell + int3(0, 1, 0), cell, c).y - fluidVelocity(fluid, v, cell - int3(0, 1, 0), cell, c).y;
    if (fluid.data.size.z > 1)
        divergence += fluidVelocity(fluid, v, cell + int3(0, 0, 1), cell, c).z - fluidVelocity(fluid, v, cell - int3(0, 0, 1), cell, c).z;
    return float4(0.5 * divergence, 0.0, 0.0, 0.0);
}

struct ForcePush {
    FluidRef fluid;
    uint velocity_texture;
    uint scalars_texture;
    uint curl_texture;
};

[[vk::push_constant]] ForcePush force_push;

[shader("fragment")]
float4 forceMain(float4 fragment : SV_Position) : SV_Target {
    FluidRef fluid = force_push.fluid;
    int3 size = fluid.data.size;
    int3 cell = fluidCell(fluid, int2(fragment.xy));
    if (cell.z >= size.z) return float4(0.0);
    float dt = fluid.data.dt;
    float4 current = fluidFetch(fluid, force_push.velocity_texture, cell);
    if (current.w > 0.5) return float4(0.0, 0.0, 0.0, 1.0);
    float3 velocity = current.xyz;
    float4 scalars = fluidFetch(fluid, force_push.scalars_texture, cell);

    float cells = float(size.y);
    velocity.y += (fluid.data.buoyancy * scalars.y - fluid.data.weight * scalars.x) * cells * dt;
    velocity += fluid.data.wind * cells * dt;

    if (fluid.data.vorticity > 0.0) {
        uint c = force_push.curl_texture;
        float4 curl = fluidFetch(fluid, c, cell);
        float3 gradient = 0.5 * float3(
            fluidFetch(fluid, c, cell + int3(1, 0, 0)).w - fluidFetch(fluid, c, cell - int3(1, 0, 0)).w,
            fluidFetch(fluid, c, cell + int3(0, 1, 0)).w - fluidFetch(fluid, c, cell - int3(0, 1, 0)).w,
            fluidFetch(fluid, c, cell + int3(0, 0, 1)).w - fluidFetch(fluid, c, cell - int3(0, 0, 1)).w);
        float steepness = length(gradient);
        if (steepness > 1e-5) velocity += fluid.data.vorticity * cross(gradient / steepness, curl.xyz) * dt;
    }
    if (size.z == 1) velocity.z = 0.0;
    return float4(velocity, 0.0);
}

struct PressurePush {
    FluidRef fluid;
    uint pressure_texture;
    uint divergence_texture;
};

[[vk::push_constant]] PressurePush pressure_push;

[shader("fragment")]
float4 pressureMain(float4 fragment : SV_Position) : SV_Target {
    FluidRef fluid = pressure_push.fluid;
    int3 cell = fluidCell(fluid, int2(fragment.xy));
    if (cell.z >= fluid.data.size.z) return float4(0.0);
    float2 divergence = fluidFetch(fluid, pressure_push.divergence_texture, cell).rg;
    if (divergence.g > 0.5) return float4(0.0, 1.0, 0.0, 0.0);
    uint p = pressure_push.pressure_texture;
    float center = fluidFetch(fluid, p, cell).r;
    bool solid;
    float total = fluidPressure(fluid, p, cell + int3(1, 0, 0), center, solid) + fluidPressure(fluid, p, cell - int3(1, 0, 0), center, solid) +
        fluidPressure(fluid, p, cell + int3(0, 1, 0), center, solid) + fluidPressure(fluid, p, cell - int3(0, 1, 0), center, solid);
    float neighbours = 4.0;
    if (fluid.data.size.z > 1) {
        total += fluidPressure(fluid, p, cell + int3(0, 0, 1), center, solid) + fluidPressure(fluid, p, cell - int3(0, 0, 1), center, solid);
        neighbours = 6.0;
    }
    return float4((total - divergence.r) / neighbours, 0.0, 0.0, 0.0);
}

struct ProjectPush {
    FluidRef fluid;
    uint velocity_texture;
    uint pressure_texture;
};

[[vk::push_constant]] ProjectPush project_push;

[shader("fragment")]
float4 projectMain(float4 fragment : SV_Position) : SV_Target {
    FluidRef fluid = project_push.fluid;
    int3 size = fluid.data.size;
    int3 cell = fluidCell(fluid, int2(fragment.xy));
    if (cell.z >= size.z) return float4(0.0);
    float4 current = fluidFetch(fluid, project_push.velocity_texture, cell);
    if (current.w > 0.5) return float4(0.0, 0.0, 0.0, 1.0);
    uint p = project_push.pressure_texture;
    float center = fluidFetch(fluid, p, cell).r;
    bool solid_right, solid_left, solid_up, solid_down, solid_front, solid_back;
    float right = fluidPressure(fluid, p, cell + int3(1, 0, 0), center, solid_right);
    float left = fluidPressure(fluid, p, cell - int3(1, 0, 0), center, solid_left);
    float up = fluidPressure(fluid, p, cell + int3(0, 1, 0), center, solid_up);
    float down = fluidPressure(fluid, p, cell - int3(0, 1, 0), center, solid_down);
    float3 velocity = current.xyz;
    velocity.xy -= 0.5 * float2(right - left, up - down);
    if (solid_left) velocity.x = max(velocity.x, 0.0);
    if (solid_right) velocity.x = min(velocity.x, 0.0);
    if (solid_down) velocity.y = max(velocity.y, 0.0);
    if (solid_up) velocity.y = min(velocity.y, 0.0);
    if (size.z == 1) {
        velocity.z = 0.0;
    } else {
        float front = fluidPressure(fluid, p, cell + int3(0, 0, 1), center, solid_front);
        float back = fluidPressure(fluid, p, cell - int3(0, 0, 1), center, solid_back);
        velocity.z -= 0.5 * (front - back);
        if (solid_back) velocity.z = max(velocity.z, 0.0);
        if (solid_front) velocity.z = min(velocity.z, 0.0);
    }
    return float4(velocity, 0.0);
}

#ifdef RAY_TRACED
#endif

struct SolidPush {
    FluidRef fluid;
#ifdef RAY_TRACED
    uint64_t tlas;
#endif
};

[[vk::push_constant]] SolidPush solid_push;

[shader("fragment")]
float4 solidMain(float4 fragment : SV_Position) : SV_Target {
    FluidRef fluid = solid_push.fluid;
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
    if (solid == 0.0 && solid_push.tlas != 0 && cell.z < fluid.data.size.z) {
        float4x4 box_to_world = fluid.data.box_to_world;
        float3 origin = mul(box_to_world, float4(center / float3(fluid.data.size), 1.0)).xyz;
        Tracer tracer;
        tracer.frame = (FrameConstants)nullptr;
        tracer.scene = solid_push.tlas;
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

struct LightPush {
    FluidRef fluid;
    Light* lights;
    uint index;
    float scale;
    float tall;
};

[[vk::push_constant]] LightPush light_push;

[shader("compute")]
[numthreads(1, 1, 1)]
void lightMain() {
    FluidRef fluid = light_push.fluid;
    int3 size = fluid.data.size;
    const int3 samples = int3(10, 14, size.z == 1 ? 1 : 10);
    float3 total = float3(0.0);
    float3 center = float3(0.0);
    float weight = 0.0;
    float height_sum = 0.0;
    float height_squared = 0.0;
    for (int z = 0; z < samples.z; z++)
    for (int y = 0; y < samples.y; y++)
    for (int x = 0; x < samples.x; x++) {
        float3 uvw = (float3(x, y, z) + 0.5) / float3(samples);
        float temperature = sampleVolume(fluid.data.scalars_texture, fluid.data.sampler_linear, uvw, size, fluid.data.tiles_x).y;
        float3 glow = fireGlow(temperature);
        float brightness = dot(glow, float3(0.3, 0.5, 0.2));
        total += glow;
        center += uvw * brightness;
        weight += brightness;
        height_sum += uvw.y * brightness;
        height_squared += uvw.y * uvw.y * brightness;
    }
    float4x4 box_to_world = fluid.data.box_to_world;
    float volume = abs(determinant((float3x3)box_to_world));
    float3 mean_glow = total / float(samples.x * samples.y * samples.z);
    float3 where = weight > 1e-6 ? center / weight : float3(0.5);
    Light* light = light_push.lights + light_push.index;
    light.position = mul(box_to_world, float4(where, 1.0)).xyz;
    float mean_height = weight > 1e-6 ? height_sum / weight : 0.5;
    float spread = weight > 1e-6 ? sqrt(max(height_squared / weight - mean_height * mean_height, 0.0)) : 0.0;
    float3 up = matrixColumn(box_to_world, 1);
    light.direction = normalize(up);
    light.source_length = 4.0 * spread * length(up) * light_push.tall;
    light.color = mean_glow * fluid.data.fire_color * (fluid.data.fire_intensity * volume * light_push.scale);
}

struct PresentPush {
    FluidRef fluid;
};

[[vk::push_constant]] PresentPush present_push;

[shader("fragment")]
float4 presentMain([[vk::location(0)]] float2 in_uv) : SV_Target {
    FluidRef fluid = present_push.fluid;
    int3 size = fluid.data.size;
    uint scalars = fluid.data.scalars_texture;
    float2 uv = float2(in_uv.x, 1.0 - in_uv.y);
    float depth = length(matrixColumn(fluid.data.box_to_world, 2)) / float(size.z);
    float3 fire = fluid.data.fire_color * fluid.data.fire_intensity;
    float3 color = float3(0.0);
    float transmittance = 1.0;
    for (int z = 0; z < size.z; z++) {
        float4 value = sampleTextureLod(scalars, fluid.data.sampler_linear, volumeTileUv(uv * float2(size.xy), z, size, fluid.data.tiles_x), 0.0);
        float step_transmittance = exp(-value.x * fluid.data.absorption * depth);
        color += transmittance * (fluid.data.smoke_color * (1.0 - step_transmittance) + fire * fireGlow(value.y) * depth);
        transmittance *= step_transmittance;
    }
    float alpha = clamp(max(1.0 - transmittance, luminance(color)), 0.0, 1.0);
    return float4(color / max(alpha, 1e-4), alpha);
}

struct MotionPush {
    FrameConstants frame;
    uint source_texture;
};

[[vk::push_constant]] MotionPush motion_push;

[shader("fragment")]
float4 motionMain([[vk::location(0)]] float2 in_uv) : SV_Target {
    return sampleTextureLod(motion_push.source_texture, motion_push.frame.sampler_linear_clamp, in_uv, 0.0);
}

static const uint MAX_FLUIDS = 8u;

static const uint MAX_FLUID_LAMPS = 16u;

struct VolumePush {
    FrameConstants frame;
    uint depth_texture;
    uint count;
    int steps;
    int light_steps;
    uint motion;
    uint motion_pad;
    FluidRef fluids[MAX_FLUIDS];
};

[[vk::push_constant]] VolumePush volume_push;

struct VolumeOutput {
    float4 fluid : SV_Target0;
    float4 motion : SV_Target1;
};

[shader("fragment")]
VolumeOutput volumeMain([[vk::location(0)]] float2 in_uv, float4 fragment : SV_Position) {
    FrameConstants frame = volume_push.frame;
    float depth = sampleTextureLod(volume_push.depth_texture, frame.sampler_nearest_clamp, in_uv, 0.0).r;
    float3 end = worldPositionFromDepth(in_uv, max(depth, 1e-6), frame.inv_view_proj);
    float3 camera = eyePoint(frame, end);
    float scene_distance = depth > 0.0 ? length(end - camera) : 1e30;
    float3 direction = normalize(end - camera);

    float enter[MAX_FLUIDS];
    float leave[MAX_FLUIDS];
    uint order[MAX_FLUIDS];
    for (uint i = 0u; i < MAX_FLUIDS; i++) order[i] = 0u;
    uint hits = 0u;
    for (uint i = 0u; i < volume_push.count; i++) {
        float4x4 world_to_box = volume_push.fluids[i].data.world_to_box;
        float3 origin = mul(world_to_box, float4(camera, 1.0)).xyz;
        float3 along = mul(world_to_box, float4(direction, 0.0)).xyz;
        float3 inverse_along = 1.0 / select(abs(along) < float3(1e-8), float3(1e-8), along);
        float3 a = (float3(0.0) - origin) * inverse_along;
        float3 b = (float3(1.0) - origin) * inverse_along;
        float3 low = min(a, b);
        float3 high = max(a, b);
        float t0 = max(max(low.x, max(low.y, low.z)), 0.0);
        float t1 = min(min(high.x, min(high.y, high.z)), scene_distance);
        if (t1 <= t0) continue;
        uint slot = hits++;
        while (slot > 0u && enter[order[slot - 1u]] > t0) {
            order[slot] = order[slot - 1u];
            slot--;
        }
        order[slot] = i;
        enter[i] = t0;
        leave[i] = t1;
    }
    VolumeOutput result;
    result.fluid = float4(0.0, 0.0, 0.0, 1.0);
    result.motion = float4(0.0);
    if (hits == 0u) return result;

    float jitter = interleavedGradientNoise(fragment.xy, frame.frame_index);
    float3 sky_ambient = float3(0.0);
    float3 moving_position = float3(0.0);
    float3 moving_velocity = float3(0.0);
    float moving_weight = 0.0;
    if ((frame.flags & FRAME_ENVIRONMENT) != 0u) {
        uint s = frame.sampler_linear_clamp;
        sky_ambient = 0.5 * (sampleCubeLod(frame.env_irradiance, s, float3(0.0, 1.0, 0.0), 0.0).rgb +
            sampleCubeLod(frame.env_irradiance, s, float3(0.0, -1.0, 0.0), 0.0).rgb) * frame.env_intensity;
    }
    float3 scattered = float3(0.0);
    float transmittance = 1.0;
    for (uint hit = 0u; hit < hits && transmittance > 0.01; hit++) {
        FluidRef fluid = volume_push.fluids[order[hit]];
        float4x4 world_to_box = fluid.data.world_to_box;
        float4x4 box_to_world = fluid.data.box_to_world;
        int3 size = fluid.data.size;
        int tiles_x = fluid.data.tiles_x;
        uint scalars = fluid.data.scalars_texture;
        uint linear = fluid.data.sampler_linear;
        float absorption = fluid.data.absorption;
        float3 smoke_color = fluid.data.smoke_color;
        float3 fire = fluid.data.fire_color * fluid.data.fire_intensity;
        int steps = volume_push.steps;
        int light_steps = volume_push.light_steps;
        float self_shadow = fluid.data.shadow;

        float3 middle = mul(box_to_world, float4(0.5, 0.5, 0.5, 1.0)).xyz;
        float3 ambient = sky_ambient;
        if ((frame.flags & FRAME_GI) != 0u) {
            float coverage = giCoverage(frame, middle);
            if (coverage > 0.0) ambient = lerp(sky_ambient, giAmbient(frame, middle) * frame.gi_intensity, coverage);
        }
        ambient *= fluid.data.ambient;
        float3 sun = frame.sun_radiance * henyeyGreenstein(dot(direction, frame.sun_direction), fluid.data.anisotropy);
        float light_reach = 0.5 * length(matrixColumn(box_to_world, 1));
        float light_step = light_reach / float(max(light_steps, 1));
        float3 sun_in_box = mul(world_to_box, float4(frame.sun_direction * light_step, 0.0)).xyz;

        uint near_lights[MAX_FLUID_LAMPS];
        uint near_count = 0u;
        float box_radius = 0.5 * length(matrixColumn(box_to_world, 0) + matrixColumn(box_to_world, 1) + matrixColumn(box_to_world, 2));
        for (uint i = 0u; i < frame.light_count && near_count < MAX_FLUID_LAMPS; i++) {
            Light light = frame.lights.data[i];
            if ((light.flags & LIGHT_DIRECTIONAL) != 0u) continue;
            if (distance(light.position, middle) < light.range + box_radius) near_lights[near_count++] = i;
        }
        float t0 = enter[order[hit]];
        float step_length = (leave[order[hit]] - t0) / float(steps);
        for (int i = 0; i < steps; i++) {
            float3 position = camera + direction * (t0 + (float(i) + jitter) * step_length);
            float3 uvw = mul(world_to_box, float4(position, 1.0)).xyz;
            float4 value = sampleVolume(scalars, linear, uvw, size, tiles_x);
            float sigma = value.x * absorption;
            float3 glow = fire * fireGlow(value.y);
            if (sigma < 1e-4 && dot(glow, float3(1.0)) < 1e-4) continue;

            float3 light = ambient;
            if (sigma > 1e-4 && dot(sun, float3(1.0)) > 1e-5) {
                float optical_depth = 0.0;
                if (self_shadow > 0.0) {
                    for (int j = 1; j <= light_steps; j++) {
                        float3 toward = uvw + sun_in_box * (float(j) - 0.5);
                        if (any(toward < 0.0) || any(toward > 1.0)) break;
                        optical_depth += sampleVolume(scalars, linear, toward, size, tiles_x).x * absorption * light_step;
                    }
                }
                light += sun * exp(-optical_depth * self_shadow) * cascadeVisibility(frame, position) * cloudShadow(frame, position);
            }
            for (uint k = 0u; k < near_count && sigma > 1e-4; k++) {
                Light lamp = frame.lights.data[near_lights[k]];
                float3 to_lamp = lamp.position - position;
                float distance_squared = dot(to_lamp, to_lamp);
                float range_squared = lamp.range * lamp.range;
                if (distance_squared > range_squared) continue;
                float window = clamp(1.0 - (distance_squared * distance_squared) / (range_squared * range_squared), 0.0, 1.0);
                float attenuation = window * window / max(distance_squared, max(lamp.source_radius * lamp.source_radius, 0.05));
                if ((lamp.flags & LIGHT_SPOT) != 0u) {
                    float cone = clamp(dot(-normalize(to_lamp), lamp.direction) * lamp.cone_scale + lamp.cone_offset, 0.0, 1.0);
                    attenuation *= cone * cone;
                }
                if (attenuation <= 1e-5) continue;
                float lamp_distance = sqrt(distance_squared);
                attenuation *= lampVisibility(frame, lamp, position, to_lamp);
                if (self_shadow > 0.0 && attenuation > 1e-5 && (lamp.flags & LIGHT_FIRE) == 0u) {
                    float lamp_step = min(lamp_distance, light_reach) / float(max(light_steps, 1));
                    float3 lamp_in_box = mul(world_to_box, float4(to_lamp / lamp_distance * lamp_step, 0.0)).xyz;
                    float optical_depth = 0.0;
                    for (int j = 1; j <= light_steps; j++) {
                        float3 toward = uvw + lamp_in_box * (float(j) - 0.5);
                        if (any(toward < 0.0) || any(toward > 1.0)) break;
                        optical_depth += sampleVolume(scalars, linear, toward, size, tiles_x).x * absorption * lamp_step;
                    }
                    attenuation *= exp(-optical_depth * self_shadow);
                }
                light += lamp.color * attenuation / (4.0 * PI);
            }
            float step_transmittance = exp(-sigma * step_length);
            if (volume_push.motion != 0u) {
                float shows = transmittance * max(1.0 - step_transmittance, min(dot(glow, float3(0.33)) * step_length, 1.0));
                float3 cells = sampleVolume(fluid.data.velocity_texture, linear, uvw, size, tiles_x).xyz;
                moving_position += position * shows;
                moving_velocity += mul(box_to_world, float4(cells / float3(size), 0.0)).xyz * shows;
                moving_weight += shows;
            }
            scattered += transmittance * (light * smoke_color * (1.0 - step_transmittance) + glow * step_length);
            transmittance *= step_transmittance;
            if (transmittance < 0.01) break;
        }
    }
    result.fluid = float4(scattered, transmittance);
    if (moving_weight > 1e-4) {
        float3 at = moving_position / moving_weight;
        float3 before = at - moving_velocity / moving_weight * frame.delta_time;
        float4 clip = mul(frame.view_proj_unjittered, float4(at, 1.0));
        float4 previous_clip = mul(frame.prev_view_proj_unjittered, float4(before, 1.0));
        result.motion = float4((clip.xy / clip.w - previous_clip.xy / previous_clip.w) * 0.5, 0.0, clamp(moving_weight, 0.0, 1.0));
    }
    return result;
}
