#ifndef SHADING_SLANG
#define SHADING_SLANG

#include "brdf.slang"
#include "vsm.slang"
#include "gi.slang"
#include "clouds.slang"
#include "fluid.slang"
#ifdef RAY_TRACED
#include "ray_light.slang"
#endif

struct Surface {
    float3 position;
    float3 normal;
    float3 view;
    float3 diffuse_color;
    float3 f0;
    float roughness;
    float ao;
    float3 bounce;
    float view_depth;
    float clearcoat;
    float clearcoat_roughness;
    float3 coat_normal;
    float3 sheen_color;
    float sheen_roughness;
    /// Stretch of the highlights along `grain`, 0..1; below 0 the surface is
    /// a hair fibre running along `grain`.
    float anisotropy;
    float3 grain;
    float subsurface;
    /// Specular gain giving back the energy single-scattering GGX loses on
    /// rough surfaces is `1 + f0 * energy`; set by `shadeSurface`.
    float energy;
};

#include "shadowing.slang"
#include "lobes.slang"
#include "local_lights.slang"
#include "ambient.slang"

/// Light leaving `surface`. Diffuse light is linear in `diffuse_color`, so a
/// caller can scale it apart from reflections by scaling `diffuse_color`.
float3 shadeSurface(FrameConstants frame, Surface surface, float2 pixel, float noise, float4 gathered_gi) {
    float2 dfg = brdfTable(frame, surface);
    surface.energy = 1.0 / max(dfg.x + dfg.y, 1e-4) - 1.0;
    float3 color = float3(0.0);
    float3 l = frame.sun_direction;
    float n_dot_l = clamp(dot(surface.normal, l), 0.0, 1.0);
    if (n_dot_l > 0.0 && dot(frame.sun_radiance, float3(1.0)) > 0.0) {
        float shadow = sunShadow(frame, surface.position, surface.normal, n_dot_l, surface.view_depth, noise);
        if (shadow > 0.0) shadow *= contactShadow(frame, surface.position, noise);
        if (shadow > 0.0)
            color += surfaceLight(surface, l, frame.sun_radiance * sunTint(frame, surface.position, surface.view_depth)) * shadow;
    }
    if (surface.subsurface > 0.0 && dot(frame.sun_radiance, float3(1.0)) > 0.0) {
        float wrap = clamp((dot(surface.normal, l) + surface.subsurface) / (1.0 + surface.subsurface), 0.0, 1.0);
        float through = pow(clamp(dot(surface.view, -l), 0.0, 1.0), 4.0) * surface.subsurface;
        float lit_behind = sunShadow(frame, surface.position + surface.normal * (0.1 + 0.5 * surface.subsurface), l, 1.0, surface.view_depth, noise);
        float softened = frame.shading.screen_subsurface != 0u ? 0.0 : max(wrap * wrap - n_dot_l, 0.0) * 0.7;
        color += surface.diffuse_color * frame.sun_radiance * ((softened + through * 0.25) / PI) * lit_behind;
    }
    color += localLights(frame, surface, pixel, noise);
    color += ambientLight(frame, surface, gathered_gi, dfg);
    return color;
}

#endif
