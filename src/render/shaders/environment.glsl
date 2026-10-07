// Helpers for baking image-based lighting.
#ifndef ENVIRONMENT_GLSL
#define ENVIRONMENT_GLSL

// Direction through a cube face at `uv` in [0, 1]^2, Vulkan face order.
vec3 cubeDirection(uint face, vec2 uv) {
    vec2 p = uv * 2.0 - 1.0;
    vec3 direction;
    switch (face) {
    case 0u: direction = vec3(1.0, -p.y, -p.x); break;
    case 1u: direction = vec3(-1.0, -p.y, p.x); break;
    case 2u: direction = vec3(p.x, 1.0, p.y); break;
    case 3u: direction = vec3(p.x, -1.0, -p.y); break;
    case 4u: direction = vec3(p.x, -p.y, 1.0); break;
    default: direction = vec3(-p.x, -p.y, -1.0); break;
    }
    return normalize(direction);
}

// Must match `equirectDirection` in src/asset/gltf.zig.
vec2 equirectUv(vec3 direction) {
    return vec2(atan(direction.z, direction.x) / (2.0 * PI) + 0.5, acos(clamp(direction.y, -1.0, 1.0)) / PI);
}

#endif
