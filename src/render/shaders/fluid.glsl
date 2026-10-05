// Grid fluids: smoke and fire simulated on a volume stored as a sheet of
// slices (see volume.glsl). Velocities are in cells per second.
#ifndef FLUID_GLSL
#define FLUID_GLSL
#include "volume.glsl"


ivec2 fluidPixel(FluidRef fluid, ivec3 cell) {
    int tiles_x = fluid.data.tiles_x;
    return ivec2(cell.z % tiles_x, cell.z / tiles_x) * fluid.data.size.xy + cell.xy;
}

// The cell a pixel of the sheet is; z is past the end on unused tiles.
ivec3 fluidCell(FluidRef fluid, ivec2 pixel) {
    return volumeCell(pixel, fluid.data.size, fluid.data.tiles_x);
}

bool fluidInside(FluidRef fluid, ivec3 cell) {
    return all(greaterThanEqual(cell, ivec3(0))) && all(lessThan(cell, fluid.data.size));
}

// Outside the grid on a side the fluid cannot pass through.
bool fluidWall(FluidRef fluid, ivec3 cell) {
    uint walls = fluid.data.walls;
    if (walls == FLUID_WALLS_CLOSED) return true;
    return walls == FLUID_WALLS_FLOOR && cell.y < 0;
}

// Whether a cell of the grid is inside an obstacle, from the mask drawn
// by fluid_solid.frag. The solver's passes ask this once per cell and
// hand the answer on in the textures they write (velocity.w, the second
// channel of divergence and pressure), so neighbours cost nothing extra.
bool fluidObstacle(FluidRef fluid, ivec3 cell) {
    if (fluid.data.solid_mask == 0u) return false;
    return texelFetch(TEX(fluid.data.solid_texture, fluid.data.sampler_nearest), fluidPixel(fluid, cell), 0).r > 0.5;
}

// Value at a cell; outside the grid, the nearest cell inside.
vec4 fluidFetch(FluidRef fluid, uint texture_index, ivec3 cell) {
    cell = clamp(cell, ivec3(0), fluid.data.size - 1);
    return texelFetch(TEX(texture_index, fluid.data.sampler_nearest), fluidPixel(fluid, cell), 0);
}

// Value at a position in cells (cell centers are at +0.5).
vec4 fluidSample(FluidRef fluid, uint texture_index, vec3 position) {
    ivec3 size = fluid.data.size;
    return sampleVolume(texture_index, fluid.data.sampler_linear, position / vec3(size), size, fluid.data.tiles_x);
}

// Velocity at a neighbour of the cell whose velocity is `center`, as the
// solver should see it. Against a wall or an obstacle it is the cell's
// own flow mirrored, so that halfway between the two nothing crosses; an
// open side continues what is next to it.
vec3 fluidVelocity(FluidRef fluid, uint texture_index, ivec3 cell, ivec3 from, vec3 center) {
    vec3 mirrored = center * vec3(1 - 2 * abs(cell - from));
    if (!fluidInside(fluid, cell)) return fluidWall(fluid, cell) ? mirrored : center;
    vec4 velocity = texelFetch(TEX(texture_index, fluid.data.sampler_nearest), fluidPixel(fluid, cell), 0);
    return velocity.w > 0.5 ? mirrored : velocity.xyz;
}

// Pressure at a neighbour of a cell whose pressure is `center`, and
// whether that neighbour is solid: walls and obstacles push back as hard
// as they are pushed, open sides are at rest.
float fluidPressure(FluidRef fluid, uint texture_index, ivec3 cell, float center, out bool solid) {
    if (!fluidInside(fluid, cell)) {
        solid = fluidWall(fluid, cell);
        return solid ? center : 0.0;
    }
    vec2 pressure = texelFetch(TEX(texture_index, fluid.data.sampler_nearest), fluidPixel(fluid, cell), 0).rg;
    solid = pressure.g > 0.5;
    return solid ? center : pressure.r;
}

// The glow of burning gas by temperature: dull red, orange, then white.
vec3 fireGlow(float temperature) {
    float t = max(temperature, 0.0);
    vec3 color = vec3(smoothstep(0.02, 0.45, t), smoothstep(0.25, 1.1, t) * 0.75, smoothstep(0.7, 1.9, t) * 0.55);
    return color * (0.25 + t) * (0.25 + t);
}


// How much light gets through the scene's smoke from a point `reach` away
// in `direction`: a short march through each fluid box the ray crosses.
float fluidShadowToward(FrameConstants frame, vec3 position, vec3 direction, float reach) {
    if ((SHADE_FEATURES & FEATURE_FLUID_SHADOWS) == 0u || (frame.flags & FRAME_FLUID_SHADOWS) == 0u) return 1.0;
    float through = 1.0;
    uint count = frame.fluids.count;
    for (uint i = 0u; i < count; i++) {
        FluidRef fluid = frame.fluids.fluids[i];
        mat4 world_to_box = fluid.data.world_to_box;
        vec3 origin = (world_to_box * vec4(position, 1.0)).xyz;
        vec3 along = (world_to_box * vec4(direction, 0.0)).xyz;
        vec3 inverse = 1.0 / mix(along, vec3(1e-8), lessThan(abs(along), vec3(1e-8)));
        vec3 a = (vec3(0.0) - origin) * inverse;
        vec3 b = (vec3(1.0) - origin) * inverse;
        vec3 low = min(a, b);
        vec3 high = max(a, b);
        float t0 = max(max(low.x, max(low.y, low.z)), 0.0);
        float t1 = min(min(high.x, min(high.y, high.z)), reach);
        if (t1 <= t0) continue;
        const int steps = 8;
        float step_length = (t1 - t0) / float(steps);
        float smoke = 0.0;
        for (int s = 0; s < steps; s++) {
            vec3 uvw = origin + along * (t0 + (float(s) + 0.5) * step_length);
            smoke += sampleVolume(fluid.data.scalars_texture, fluid.data.sampler_linear, uvw, fluid.data.size, fluid.data.tiles_x).x;
        }
        through *= exp(-smoke * step_length * fluid.data.absorption * fluid.data.shadow);
    }
    return through;
}

// What the scene's smoke and fire do to a ray from `position` going
// `reach` in `direction`: the share of what lies beyond that gets
// through, and in `added` the light they send back along it (smoke lit by
// `ambient`, and the glow of flames). A short march through each box.
float fluidAlong(FrameConstants frame, vec3 position, vec3 direction, float reach, vec3 ambient, out vec3 added) {
    added = vec3(0.0);
    float through = 1.0;
    uint count = frame.fluids.count;
    for (uint i = 0u; i < count; i++) {
        FluidRef fluid = frame.fluids.fluids[i];
        mat4 world_to_box = fluid.data.world_to_box;
        vec3 origin = (world_to_box * vec4(position, 1.0)).xyz;
        vec3 along = (world_to_box * vec4(direction, 0.0)).xyz;
        vec3 inverse = 1.0 / mix(along, vec3(1e-8), lessThan(abs(along), vec3(1e-8)));
        vec3 a = (vec3(0.0) - origin) * inverse;
        vec3 b = (vec3(1.0) - origin) * inverse;
        vec3 low = min(a, b);
        vec3 high = max(a, b);
        float t0 = max(max(low.x, max(low.y, low.z)), 0.0);
        float t1 = min(min(high.x, min(high.y, high.z)), reach);
        if (t1 <= t0) continue;
        const int steps = 10;
        float step_length = (t1 - t0) / float(steps);
        for (int s = 0; s < steps; s++) {
            vec3 uvw = origin + along * (t0 + (float(s) + 0.5) * step_length);
            vec4 value = sampleVolume(fluid.data.scalars_texture, fluid.data.sampler_linear, uvw, fluid.data.size, fluid.data.tiles_x);
            float step_through = exp(-value.x * fluid.data.absorption * step_length);
            added += through * (fluid.data.smoke_color * ambient * (1.0 - step_through) + fluid.data.fire_color * fluid.data.fire_intensity * fireGlow(value.y) * step_length);
            through *= step_through;
        }
    }
    return through;
}

// How much sun gets through the scene's smoke to a point.
float fluidShadow(FrameConstants frame, vec3 position) {
    return fluidShadowToward(frame, position, frame.sun_direction, 1e30);
}

#endif
