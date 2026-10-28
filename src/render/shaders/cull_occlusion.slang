#ifndef CULL_OCCLUSION_SLANG
#define CULL_OCCLUSION_SLANG

/// What an occlusion test reads: the view, and the depth pyramid built
/// from it.
struct Occlusion {
    FrameConstants frame;
    CullView view;
    uint hiz_texture;
    float2 hiz_size;
};

bool projectSphere(CullView view, float3 c, float r, float near, float p00, float p11, out float4 aabb) {
    aabb = float4(0.0);
    if (c.z < r + near) return false;
    if (view.far > 0.0) {
        aabb = (float4((c.xy - r) * float2(p00, p11), (c.xy + r) * float2(p00, p11)) + view.lens_shift.xyxy) * 0.5 + 0.5;
        return true;
    }
    float3 cr = c * r;
    float czr2 = c.z * c.z - r * r;
    float vx = sqrt(c.x * c.x + czr2);
    float min_x = (vx * c.x - cr.z) / (vx * c.z + cr.x);
    float max_x = (vx * c.x + cr.z) / (vx * c.z - cr.x);
    float vy = sqrt(c.y * c.y + czr2);
    float min_y = (vy * c.y - cr.z) / (vy * c.z + cr.y);
    float max_y = (vy * c.y + cr.z) / (vy * c.z - cr.y);
    aabb = (float4(min_x * p00, min_y * p11, max_x * p00, max_y * p11) + view.lens_shift.xyxy) * 0.5 + 0.5;
    return true;
}

float farthestDepth(Occlusion occlusion, float2 uv_min, float2 uv_max) {
    float2 size = (uv_max - uv_min) * occlusion.hiz_size;
    float level = ceil(log2(max(max(size.x, size.y), 1.0)));
    uint s = occlusion.frame.sampler_nearest_clamp;
    float a = sampleTextureLod(occlusion.hiz_texture, s, uv_min, level).r;
    float b = sampleTextureLod(occlusion.hiz_texture, s, float2(uv_max.x, uv_min.y), level).r;
    float d = sampleTextureLod(occlusion.hiz_texture, s, float2(uv_min.x, uv_max.y), level).r;
    float e = sampleTextureLod(occlusion.hiz_texture, s, uv_max, level).r;
    return min(min(a, b), min(d, e));
}

bool occluded(Occlusion occlusion, float3 center, float radius) {
    float3 c = mul(occlusion.view.view, float4(center, 1.0)).xyz;
    c.z = -c.z;
    float4 aabb;
    if (!projectSphere(occlusion.view, c, radius, occlusion.view.near, occlusion.view.p00, occlusion.view.p11, aabb)) return false;
    float2 uv_min = clamp(min(aabb.xy, aabb.zw), 0.0, 1.0);
    float2 uv_max = clamp(max(aabb.xy, aabb.zw), 0.0, 1.0);
    float farthest = farthestDepth(occlusion, uv_min, uv_max);
    float nearest = occlusion.view.far > 0.0 ? (occlusion.view.far - c.z + radius) / (occlusion.view.far - occlusion.view.near) : occlusion.view.near / (c.z - radius);
    return nearest < farthest;
}

#endif
