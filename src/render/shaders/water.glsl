// Water surfaces: a height field simulated on a grid (ripples that spread,
// reflect off the edges and die down), drawn as a displaced sheet that
// mirrors and refracts.
#ifndef WATER_GLSL
#define WATER_GLSL

struct WaterRipple {
    // Where on the surface (0..1 across it), how wide (same units) and how
    // deep the dent is, in the surface's height units.
    vec2 position;
    float radius;
    float depth;
};

// Mirrors `gpu.Water`.
struct WaterData {
    // Places the unit square (x and z in -0.5..0.5, y up) in the world.
    mat4 transform;
    ivec2 size;
    // Texture holding height (r) and its rate of change (g).
    uint state_texture;
    uint sampler_linear;
    float dt;
    // Wave speed in cells per second, and the share of motion kept per step.
    float speed;
    float keep;
    uint ripple_count;
    vec3 color;
    // Per world unit of water looked through: how quickly it takes on its color.
    float murk;
    float roughness;
    float refraction;
    // Wind-driven swell laid over the simulated ripples: height and length.
    float swell;
    float swell_length;
    // Strength of the foam at shallow edges and where the surface churns.
    float foam;
    // Strength of the light pattern the waves cast on what is under them.
    float caustics;
    // Steepness of the fine wind ripples that the light is shaded by.
    float detail;
    float water_pad;
    WaterRipple ripples[16];
};

layout(buffer_reference, scalar) readonly buffer WaterRef { WaterData data; };

// Height of the swell at a point of the surface (world x and z) and time.
float waterSwell(WaterRef water, vec2 at, float time) {
    float amplitude = water.data.swell;
    if (amplitude <= 0.0) return 0.0;
    float k = 6.2831853 / max(water.data.swell_length, 1e-3);
    return amplitude * (
        0.5 * sin(dot(at, vec2(0.8, 0.6)) * k + time * 1.3) +
        0.3 * sin(dot(at, vec2(-0.5, 0.86)) * k * 1.7 + time * 1.9) +
        0.2 * sin(dot(at, vec2(0.2, -0.98)) * k * 2.9 + time * 2.7));
}

// Fine wind ripples: too small to move the surface, they tilt what the
// light meets, which is what makes water glitter and its reflections
// shiver. Returns the slope they add along world x and z at a point.
// `footprint` is the size of a pixel on the surface there: ripples
// finer than a few pixels are left out, so that they do not sparkle as
// noise in the distance.
vec2 waterDetailSlope(float strength, vec2 at, float time, float footprint) {
    if (strength <= 0.0) return vec2(0.0);
    vec2 slope = vec2(0.0);
    float wave_length = 1.1;
    float angle = 0.4;
    for (int i = 0; i < 9; i++) {
        vec2 along = vec2(cos(angle), sin(angle));
        vec2 across = vec2(-along.y, along.x);
        float k = 6.2831853 / wave_length;
        // Each train of ripples wanders a little, crests bending and
        // bunching, so that the trains never line up into a weave.
        float wander = sin(dot(at, across) * k * 0.23 + float(i) * 2.1 + time * 0.31) * 1.3 +
            sin(dot(at, along) * k * 0.11 + float(i) * 0.7) * 1.9;
        // Short waves travel slower, as on real water.
        float phase = dot(at, along) * k + time * sqrt(9.81 * k) + wander + float(i) * 1.7;
        float seen = clamp(wave_length / max(footprint, 1.0e-5) * 0.25 - 0.5, 0.0, 1.0);
        slope += along * (cos(phase) * strength * 0.05 * seen);
        wave_length *= 0.71;
        angle += 2.39996 + float(i) * 0.37;
    }
    return slope;
}

// World position of the surface at `uv` (0..1 across it).
vec3 waterPoint(WaterRef water, vec2 uv, float time) {
    float height = textureLod(TEX(water.data.state_texture, water.data.sampler_linear), uv, 0.0).r;
    vec3 flat_point = (water.data.transform * vec4(uv.x - 0.5, 0.0, uv.y - 0.5, 1.0)).xyz;
    vec3 up = water.data.transform[1].xyz;
    float up_length = max(length(up), 1e-6);
    return flat_point + up * height + (up / up_length) * waterSwell(water, flat_point.xz, time);
}

// Height of the surface above its resting plane at `uv`, in world units.
float waterHeight(WaterRef water, vec2 uv, float time) {
    float height = textureLod(TEX(water.data.state_texture, water.data.sampler_linear), uv, 0.0).r;
    vec3 flat_point = (water.data.transform * vec4(uv.x - 0.5, 0.0, uv.y - 0.5, 1.0)).xyz;
    return height * length(water.data.transform[1].xyz) + waterSwell(water, flat_point.xz, time);
}

// How far below the resting surface a world point is, and where on the
// surface (0..1 across it) the sun's light toward it came through.
// Negative depth: the point is above the water.
float waterDepthBelow(WaterRef water, vec3 world, vec3 to_sun, out vec2 entry_uv) {
    mat4 to_local = inverse(water.data.transform);
    vec3 local = (to_local * vec4(world, 1.0)).xyz;
    vec3 sun_local = (to_local * vec4(to_sun, 0.0)).xyz;
    float rise = max(sun_local.y, 1e-4);
    entry_uv = local.xz + sun_local.xz * (-local.y / rise) + 0.5;
    return -local.y * length(water.data.transform[1].xyz);
}

// Caustics: how much brighter or darker sunlight is at a point under the
// water than it would be under a flat surface. Crests of the waves above
// gather the light and troughs spread it; the pattern sharpens with depth
// and is lost in murk. 1 where there is none.
float waterCaustic(WaterRef water, vec3 world, vec3 to_sun, float time) {
    if (water.data.caustics <= 0.0 || to_sun.y <= 0.0) return 1.0;
    vec2 uv;
    float depth = waterDepthBelow(water, world, to_sun, uv);
    if (depth <= 0.0 || any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) return 1.0;
    vec2 texel = 1.0 / vec2(water.data.size);
    // Curvature of the surface, per world unit.
    vec2 cell = vec2(length(water.data.transform[0].xyz), length(water.data.transform[2].xyz)) * texel;
    float here = waterHeight(water, uv, time);
    float along_x = waterHeight(water, uv + vec2(texel.x, 0.0), time) + waterHeight(water, uv - vec2(texel.x, 0.0), time) - 2.0 * here;
    float along_z = waterHeight(water, uv + vec2(0.0, texel.y), time) + waterHeight(water, uv - vec2(0.0, texel.y), time) - 2.0 * here;
    float curvature = along_x / (cell.x * cell.x) + along_z / (cell.y * cell.y);
    // A thin lens: light through a crest (curved downward) converges.
    float gain = clamp(1.0 - curvature * min(depth, 4.0), 0.2, 5.0);
    return mix(1.0, gain, water.data.caustics * exp(-depth * water.data.murk * 0.5));
}

#endif
