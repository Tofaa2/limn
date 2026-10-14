#include "common.slang"

struct Push {
    FrameConstants frame;
    uint surface;
    uint diffuse;
    uint specular;
    uint albedo;
    uint depth;
    uint pad;
};

[[vk::push_constant]] Push push;

/// View depth given to what the rays missed, beyond any the denoiser treats
/// as a surface.
static const float sky_depth = -1e6;

/// The tracer's signals as NRD reads them.
struct Output {
    /// World normal of the first surface, and its roughness.
    float4 normal_roughness : SV_Target0;
    /// Where it is along the view's Z axis.
    float view_depth : SV_Target1;
    /// Bounced light over the surface's color, and how far the bounce went.
    float4 diffuse : SV_Target2;
    /// Reflected light, and how far the reflection reached.
    float4 specular : SV_Target3;
};

[shader("fragment")]
Output fragmentMain(float4 position : SV_Position) {
    FrameConstants frame = push.frame;
    int2 pixel = int2(position.xy);
    float4 surface = fetchTexel(push.surface, pixel);
    float3 folded = float3(surface.xy, 1.0 - abs(surface.x) - abs(surface.y));
    float fold = max(-folded.z, 0.0);
    folded.x += folded.x >= 0.0 ? -fold : fold;
    folded.y += folded.y >= 0.0 ? -fold : fold;
    float3 normal = normalize(folded);

    Output result;
    result.normal_roughness = float4(normal / max(abs(normal.x), max(abs(normal.y), abs(normal.z))), surface.z);
    float depth = fetchTexel(push.depth, pixel).r;
    float3 world = worldPositionFromDepth(position.xy * frame.inv_resolution, depth, frame.inv_view_proj);
    result.view_depth = depth > 0.0 ? mul(frame.view, float4(world, 1.0)).z : sky_depth;
    float4 bounced = fetchTexel(push.diffuse, pixel);
    result.diffuse = float4(clamp(bounced.rgb, 0.0, 60000.0), clamp(bounced.a, 0.0, 60000.0));
    float reach = fetchTexel(push.albedo, pixel).a;
    result.specular = float4(clamp(fetchTexel(push.specular, pixel).rgb, 0.0, 60000.0), clamp(reach, 0.0, 60000.0));
    return result;
}
