#ifndef IMPOSTOR_GLSL
#define IMPOSTOR_GLSL

const float impostor_frames = 8.0;

vec2 impostorFold(vec3 direction) {
    direction /= abs(direction.x) + abs(direction.y) + abs(direction.z);
    if (direction.z < 0.0) direction.xy = (1.0 - abs(direction.yx)) * vec2(direction.x >= 0.0 ? 1.0 : -1.0, direction.y >= 0.0 ? 1.0 : -1.0);
    return direction.xy * 0.5 + 0.5;
}

vec3 impostorUnfold(vec2 place) {
    vec2 e = place * 2.0 - 1.0;
    vec3 direction = vec3(e, 1.0 - abs(e.x) - abs(e.y));
    if (direction.z < 0.0) direction.xy = (1.0 - abs(direction.yx)) * vec2(direction.x >= 0.0 ? 1.0 : -1.0, direction.y >= 0.0 ? 1.0 : -1.0);
    return normalize(direction);
}

void impostorBasis(vec3 toward, out vec3 right, out vec3 up) {
    vec3 hint = abs(toward.y) < 0.999 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
    right = normalize(cross(hint, toward));
    up = cross(toward, right);
}

struct Impostor {
    vec3 center;
    float radius;
    uint color_texture;
    uint normal_texture;
    float pixels;
    float pad;
};

layout(buffer_reference, scalar) readonly buffer Impostors { Impostor data[]; };

#endif
