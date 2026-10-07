#version 460
#include "common.glsl"
#include "gi.glsl"
#include "media.glsl"
#include "fluid.glsl"

// Ray-marches the scene's fluid volumes. Smoke scatters sun, local and ambient
// light; hot gas emits. Output: radiance in rgb, transmittance in a.
const uint MAX_FLUIDS = 8u;

// Maximum local lights per fluid.
const uint MAX_FLUID_LAMPS = 16u;

layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    uint depth_texture;
    uint count;
    int steps;
    int light_steps;
    // 1 to output motion vectors.
    uint motion;
    uint motion_pad;
    FluidRef fluids[MAX_FLUIDS];
} push;

layout(location = 0) in vec2 in_uv;
layout(location = 0) out vec4 out_fluid;
// Screen motion of the fluid (xy) and its coverage (a).
layout(location = 1) out vec4 out_motion;

void main() {
    FrameConstants frame = push.frame;
    float depth = textureLod(TEX(push.depth_texture, frame.sampler_nearest_clamp), in_uv, 0.0).r;
    vec3 camera = frame.camera_position;
    vec3 end = worldPositionFromDepth(in_uv, max(depth, 1e-6), frame.inv_view_proj);
    float scene_distance = depth > 0.0 ? length(end - camera) : 1e30;
    vec3 direction = normalize(end - camera);

    // Ray span in each box, sorted near to far.
    float enter[MAX_FLUIDS];
    float leave[MAX_FLUIDS];
    uint order[MAX_FLUIDS];
    // Initialised: helper invocations may read it past their own box count.
    for (uint i = 0u; i < MAX_FLUIDS; i++) order[i] = 0u;
    uint hits = 0u;
    for (uint i = 0u; i < push.count; i++) {
        mat4 world_to_box = push.fluids[i].data.world_to_box;
        vec3 origin = (world_to_box * vec4(camera, 1.0)).xyz;
        vec3 along = (world_to_box * vec4(direction, 0.0)).xyz;
        vec3 inverse = 1.0 / mix(along, vec3(1e-8), lessThan(abs(along), vec3(1e-8)));
        vec3 a = (vec3(0.0) - origin) * inverse;
        vec3 b = (vec3(1.0) - origin) * inverse;
        vec3 low = min(a, b);
        vec3 high = max(a, b);
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
    out_fluid = vec4(0.0, 0.0, 0.0, 1.0);
    out_motion = vec4(0.0);
    if (hits == 0u) return;

    float jitter = interleavedGradientNoise(gl_FragCoord.xy, frame.frame_index);
    vec3 sky_ambient = vec3(0.0);
    vec3 moving_position = vec3(0.0);
    vec3 moving_velocity = vec3(0.0);
    float moving_weight = 0.0;
    if ((frame.flags & FRAME_ENVIRONMENT) != 0u) {
        uint s = frame.sampler_linear_clamp;
        sky_ambient = 0.5 * (textureLod(TEX_CUBE(frame.env_irradiance, s), vec3(0.0, 1.0, 0.0), 0.0).rgb +
            textureLod(TEX_CUBE(frame.env_irradiance, s), vec3(0.0, -1.0, 0.0), 0.0).rgb) * frame.env_intensity;
    }
    vec3 scattered = vec3(0.0);
    float transmittance = 1.0;
    for (uint hit = 0u; hit < hits && transmittance > 0.01; hit++) {
        FluidRef fluid = push.fluids[order[hit]];
        mat4 world_to_box = fluid.data.world_to_box;
        ivec3 size = fluid.data.size;
        int tiles_x = fluid.data.tiles_x;
        uint scalars = fluid.data.scalars_texture;
        uint linear = fluid.data.sampler_linear;
        float absorption = fluid.data.absorption;
        vec3 smoke_color = fluid.data.smoke_color;
        vec3 fire = fluid.data.fire_color * fluid.data.fire_intensity;
        int steps = push.steps;
        int light_steps = push.light_steps;
        float self_shadow = fluid.data.shadow;

        // Ambient is sampled once, at the box center.
        vec3 middle = (fluid.data.box_to_world * vec4(0.5, 0.5, 0.5, 1.0)).xyz;
        vec3 ambient = sky_ambient;
        if ((frame.flags & FRAME_GI) != 0u) {
            float coverage = giCoverage(frame, middle);
            if (coverage > 0.0) ambient = mix(sky_ambient, giAmbient(frame, middle) * frame.gi_intensity, coverage);
        }
        ambient *= fluid.data.ambient;
        vec3 sun = frame.sun_radiance * henyeyGreenstein(dot(direction, frame.sun_direction), fluid.data.anisotropy);
        // Sun march covers about half the box height.
        float light_reach = 0.5 * length(fluid.data.box_to_world[1].xyz);
        float light_step = light_reach / float(max(light_steps, 1));
        vec3 sun_in_box = (world_to_box * vec4(frame.sun_direction * light_step, 0.0)).xyz;

        uint near_lights[MAX_FLUID_LAMPS];
        uint near_count = 0u;
        float box_radius = 0.5 * length(fluid.data.box_to_world[0].xyz + fluid.data.box_to_world[1].xyz + fluid.data.box_to_world[2].xyz);
        for (uint i = 0u; i < frame.light_count && near_count < MAX_FLUID_LAMPS; i++) {
            Light light = frame.lights.data[i];
            if ((light.flags & LIGHT_DIRECTIONAL) != 0u) continue;
            if (distance(light.position, middle) < light.range + box_radius) near_lights[near_count++] = i;
        }
        float t0 = enter[order[hit]];
        float step_length = (leave[order[hit]] - t0) / float(steps);
        for (int i = 0; i < steps; i++) {
            vec3 position = camera + direction * (t0 + (float(i) + jitter) * step_length);
            vec3 uvw = (world_to_box * vec4(position, 1.0)).xyz;
            vec4 value = sampleVolume(scalars, linear, uvw, size, tiles_x);
            float sigma = value.x * absorption;
            vec3 glow = fire * fireGlow(value.y);
            if (sigma < 1e-4 && dot(glow, vec3(1.0)) < 1e-4) continue;

            vec3 light = ambient;
            if (sigma > 1e-4 && dot(sun, vec3(1.0)) > 1e-5) {
                float optical_depth = 0.0;
                if (self_shadow > 0.0) {
                    for (int j = 1; j <= light_steps; j++) {
                        vec3 toward = uvw + sun_in_box * (float(j) - 0.5);
                        if (any(lessThan(toward, vec3(0.0))) || any(greaterThan(toward, vec3(1.0)))) break;
                        optical_depth += sampleVolume(scalars, linear, toward, size, tiles_x).x * absorption * light_step;
                    }
                }
                light += sun * exp(-optical_depth * self_shadow) * cascadeVisibility(frame, position) * cloudShadow(frame, position);
            }
            for (uint i = 0u; i < near_count && sigma > 1e-4; i++) {
                Light lamp = frame.lights.data[near_lights[i]];
                vec3 to_lamp = lamp.position - position;
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
                    vec3 lamp_in_box = (world_to_box * vec4(to_lamp / lamp_distance * lamp_step, 0.0)).xyz;
                    float optical_depth = 0.0;
                    for (int j = 1; j <= light_steps; j++) {
                        vec3 toward = uvw + lamp_in_box * (float(j) - 0.5);
                        if (any(lessThan(toward, vec3(0.0))) || any(greaterThan(toward, vec3(1.0)))) break;
                        optical_depth += sampleVolume(scalars, linear, toward, size, tiles_x).x * absorption * lamp_step;
                    }
                    attenuation *= exp(-optical_depth * self_shadow);
                }
                light += lamp.color * attenuation / (4.0 * PI);
            }
            float step_transmittance = exp(-sigma * step_length);
            if (push.motion != 0u) {
                float shows = transmittance * max(1.0 - step_transmittance, min(dot(glow, vec3(0.33)) * step_length, 1.0));
                vec3 cells = sampleVolume(fluid.data.velocity_texture, linear, uvw, size, tiles_x).xyz;
                moving_position += position * shows;
                moving_velocity += (fluid.data.box_to_world * vec4(cells / vec3(size), 0.0)).xyz * shows;
                moving_weight += shows;
            }
            scattered += transmittance * (light * smoke_color * (1.0 - step_transmittance) + glow * step_length);
            transmittance *= step_transmittance;
            if (transmittance < 0.01) break;
        }
    }
    out_fluid = vec4(scattered, transmittance);
    out_motion = vec4(0.0);
    if (moving_weight > 1e-4) {
        vec3 at = moving_position / moving_weight;
        vec3 before = at - moving_velocity / moving_weight * frame.delta_time;
        vec4 clip = frame.view_proj_unjittered * vec4(at, 1.0);
        vec4 previous_clip = frame.prev_view_proj_unjittered * vec4(before, 1.0);
        out_motion = vec4((clip.xy / clip.w - previous_clip.xy / previous_clip.w) * 0.5, 0.0, clamp(moving_weight, 0.0, 1.0));
    }
}
