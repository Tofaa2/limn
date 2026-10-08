#ifndef CULL_VIEW_GLSL
#define CULL_VIEW_GLSL

layout(buffer_reference, scalar) readonly buffer CullView {
    vec4 planes[6];
    vec3 camera_position;
    uint plane_count;
    uint cone_culling;
    float p00;
    float p11;
    float near;
    mat4 view;
    vec3 lod_camera;
    float lod_scale;
    uint blended_casters;
    float lod_band;
    float min_radius;
    uint receiver_culling;
    mat4 receiver_view;
    vec4 receiver_planes[6];
    vec3 light_travel;
    float receiver_margin;
    float receiver_p00;
    float receiver_p11;
    float receiver_near;
    float receiver_pad;
    vec2 lens_shift;
    vec2 view_pad;
};

const uint PHASE_SINGLE = 0u;
const uint PHASE_EARLY = 1u;
const uint PHASE_LATE = 2u;

layout(buffer_reference, scalar) buffer CullDispatch {
    uint x;
    uint y;
    uint z;
    uint count;
};

layout(buffer_reference, scalar) buffer InstanceVisibility { uint data[]; };

#endif
