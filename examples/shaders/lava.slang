#define CUSTOM_MATERIAL
#include "shade.slang"

float hash(float3 p) {
    p = frac(p * 0.3183099 + 0.1);
    p *= 17.0;
    return frac(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float noise(float3 p) {
    float3 i = floor(p);
    float3 f = frac(p);
    f = f * f * (3.0 - 2.0 * f);
    return lerp(
        lerp(lerp(hash(i), hash(i + float3(1, 0, 0)), f.x), lerp(hash(i + float3(0, 1, 0)), hash(i + float3(1, 1, 0)), f.x), f.y),
        lerp(lerp(hash(i + float3(0, 0, 1)), hash(i + float3(1, 0, 1)), f.x), lerp(hash(i + float3(0, 1, 1)), hash(i + float3(1, 1, 1)), f.x), f.y),
        f.z);
}

float fbm(float3 p) {
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
    float3 p = context.position * context.params.x;
    float flow = fbm(p + float3(0.0, -context.time * 0.15, 0.0) + fbm(p * 0.5 + context.time * 0.05));
    float heat = smoothstep(0.44, 0.28, flow) * (1.0 - clamp(context.instance_params.x, 0.0, 1.0));
    surface.base_color = lerp(float3(0.05, 0.045, 0.04), float3(0.3, 0.05, 0.01), heat);
    surface.roughness = lerp(0.9, 0.35, heat);
    surface.metallic = 0.0;
    surface.emissive = float3(1.0, 0.28, 0.04) * heat * heat * context.params.y;
    surface.normal = normalize(surface.normal + (flow - 0.5) * 0.6 * context.geometric_normal);
}
