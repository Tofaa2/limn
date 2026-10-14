#ifndef CULL_VIEW_SLANG
#define CULL_VIEW_SLANG

struct CullViewData {
    float4 planes[6];
    float3 camera_position;
    uint plane_count;
    uint cone_culling;
    float p00;
    float p11;
    float near;
    float4x4 view;
    float3 lod_camera;
    float lod_scale;
    uint blended_casters;
    float lod_band;
    float min_radius;
    uint receiver_culling;
    float4x4 receiver_view;
    float4 receiver_planes[6];
    float3 light_travel;
    float receiver_margin;
    float receiver_p00;
    float receiver_p11;
    float receiver_near;
    float receiver_pad;
    float2 lens_shift;
    float far;
    float view_pad;
};

typedef CullViewData* CullView;

static const uint PHASE_SINGLE = 0u;
static const uint PHASE_EARLY = 1u;
static const uint PHASE_LATE = 2u;

struct CullDispatchData {
    uint x;
    uint y;
    uint z;
    uint count;
};

typedef CullDispatchData* CullDispatch;

#endif
