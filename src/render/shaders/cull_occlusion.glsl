#ifndef CULL_OCCLUSION_GLSL
#define CULL_OCCLUSION_GLSL

bool projectSphere(vec3 c, float r, float near, float p00, float p11, out vec4 aabb) {
    if (c.z < r + near) return false;
    vec3 cr = c * r;
    float czr2 = c.z * c.z - r * r;
    float vx = sqrt(c.x * c.x + czr2);
    float min_x = (vx * c.x - cr.z) / (vx * c.z + cr.x);
    float max_x = (vx * c.x + cr.z) / (vx * c.z - cr.x);
    float vy = sqrt(c.y * c.y + czr2);
    float min_y = (vy * c.y - cr.z) / (vy * c.z + cr.y);
    float max_y = (vy * c.y + cr.z) / (vy * c.z - cr.y);
    aabb = (vec4(min_x * p00, min_y * p11, max_x * p00, max_y * p11) + push.view.lens_shift.xyxy) * 0.5 + 0.5;
    return true;
}

float farthestDepth(vec2 uv_min, vec2 uv_max) {
    vec2 size = (uv_max - uv_min) * push.hiz_size;
    float level = ceil(log2(max(max(size.x, size.y), 1.0)));
    uint s = push.frame.sampler_nearest_clamp;
    float a = textureLod(TEX(push.hiz_texture, s), uv_min, level).r;
    float b = textureLod(TEX(push.hiz_texture, s), vec2(uv_max.x, uv_min.y), level).r;
    float d = textureLod(TEX(push.hiz_texture, s), vec2(uv_min.x, uv_max.y), level).r;
    float e = textureLod(TEX(push.hiz_texture, s), uv_max, level).r;
    return min(min(a, b), min(d, e));
}

bool occluded(vec3 center, float radius) {
    vec3 c = (push.view.view * vec4(center, 1.0)).xyz;
    c.z = -c.z;
    vec4 aabb;
    if (!projectSphere(c, radius, push.view.near, push.view.p00, push.view.p11, aabb)) return false;
    vec2 uv_min = clamp(min(aabb.xy, aabb.zw), 0.0, 1.0);
    vec2 uv_max = clamp(max(aabb.xy, aabb.zw), 0.0, 1.0);
    float farthest = farthestDepth(uv_min, uv_max);
    float nearest = push.view.near / (c.z - radius);
    return nearest < farthest;
}

#endif
