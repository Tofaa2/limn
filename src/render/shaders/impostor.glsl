#ifndef IMPOSTOR_GLSL
#define IMPOSTOR_GLSL

// Impostors: a model captured from many directions into an octahedral atlas,
// impostor_frames tiles a side, and drawn as a card when far away.
const float impostor_frames = 8.0;

// Octahedral mapping: direction to unit square.
vec2 impostorFold(vec3 direction) {
    direction /= abs(direction.x) + abs(direction.y) + abs(direction.z);
    if (direction.z < 0.0) direction.xy = (1.0 - abs(direction.yx)) * vec2(direction.x >= 0.0 ? 1.0 : -1.0, direction.y >= 0.0 ? 1.0 : -1.0);
    return direction.xy * 0.5 + 0.5;
}

// Unit square to direction.
vec3 impostorUnfold(vec2 place) {
    vec2 e = place * 2.0 - 1.0;
    vec3 direction = vec3(e, 1.0 - abs(e.x) - abs(e.y));
    if (direction.z < 0.0) direction.xy = (1.0 - abs(direction.yx)) * vec2(direction.x >= 0.0 ? 1.0 : -1.0, direction.y >= 0.0 ? 1.0 : -1.0);
    return normalize(direction);
}

// Capture camera basis in model space; the camera looks along -toward. Must
// match the renderer's `impostorBasis`.
void impostorBasis(vec3 toward, out vec3 right, out vec3 up) {
    vec3 hint = abs(toward.y) < 0.999 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
    right = normalize(cross(hint, toward));
    up = cross(toward, right);
}

// Must match `gpu.Impostor`.
struct Impostor {
    // Model-space bounding sphere.
    vec3 center;
    float radius;
    uint color_texture;
    uint normal_texture;
    // Screen size in pixels below which the impostor is drawn.
    float pixels;
    float pad;
};

layout(buffer_reference, scalar) readonly buffer Impostors { Impostor data[]; };

#endif
