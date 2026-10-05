#version 460
#define CUSTOM_MATERIAL
#include "shade.glsl"

// Example custom material: animated molten rock. The material's `params.x` scales the
// pattern, `params.y` the glow, and each entity's own `params.x` cools it
// (0 molten, 1 solid). Everything else (lighting, shadows, global
// illumination, antialiasing) is the renderer's.
float hash(vec3 p) {
    p = fract(p * 0.3183099 + 0.1);
    p *= 17.0;
    return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float noise(vec3 p) {
    vec3 i = floor(p);
    vec3 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(
        mix(mix(hash(i), hash(i + vec3(1, 0, 0)), f.x), mix(hash(i + vec3(0, 1, 0)), hash(i + vec3(1, 1, 0)), f.x), f.y),
        mix(mix(hash(i + vec3(0, 0, 1)), hash(i + vec3(1, 0, 1)), f.x), mix(hash(i + vec3(0, 1, 1)), hash(i + vec3(1, 1, 1)), f.x), f.y),
        f.z);
}

float fbm(vec3 p) {
    float total = 0.0;
    float amplitude = 0.5;
    for (int i = 0; i < 4; i++) {
        total += noise(p) * amplitude;
        p = p * 2.03 + 7.1;
        amplitude *= 0.5;
    }
    return total;
}

void customMaterial(inout MaterialSurface surface, MaterialContext context, FrameConstants frame) {
    vec3 p = context.position * context.params.x;
    float flow = fbm(p + vec3(0.0, -context.time * 0.15, 0.0) + fbm(p * 0.5 + context.time * 0.05));
    // Cracks glow where the pattern is low; crust elsewhere.
    float heat = smoothstep(0.44, 0.28, flow) * (1.0 - clamp(context.instance_params.x, 0.0, 1.0));
    surface.base_color = mix(vec3(0.05, 0.045, 0.04), vec3(0.3, 0.05, 0.01), heat);
    surface.roughness = mix(0.9, 0.35, heat);
    surface.metallic = 0.0;
    surface.emissive = vec3(1.0, 0.28, 0.04) * heat * heat * context.params.y;
    surface.normal = normalize(surface.normal + (flow - 0.5) * 0.6 * context.geometric_normal);
}
