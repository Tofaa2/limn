#version 460
#include "common.glsl"
#include "environment.glsl"
#include "clouds.glsl"

// Fills one sky cube face from an equirectangular panorama or a cube map,
// optionally with the cloud layer on top.
layout(push_constant, scalar) uniform Push {
    uint source_texture;
    uint sampler_index;
    uint face;
    float max_radiance;
    uint from_cube;
    // Sun direction and its radiance at the ground, for the clouds.
    vec3 to_sun;
    vec3 sunlight;
    // Density 0 for none. `depth_texture` holds a linear sampler here.
    CloudData clouds;
} push;

layout(location = 0) in vec2 in_uv;
layout(location = 0) out vec4 out_color;

void main() {
    vec3 direction = cubeDirection(push.face, in_uv);
    vec3 color = push.from_cube != 0u
        ? texture(TEX_CUBE(push.source_texture, push.sampler_index), direction).rgb
        : textureLod(TEX(push.source_texture, push.sampler_index), equirectUv(direction), 0.0).rgb;
    color = min(color, vec3(push.max_radiance));
    if (push.clouds.density > 0.0 && direction.y > 0.0)
        color = cloudsOverSky(push.clouds, direction, normalize(push.to_sun), push.sunlight, color);
    out_color = vec4(color, 1.0);
}
