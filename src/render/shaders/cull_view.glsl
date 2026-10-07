#ifndef CULL_VIEW_GLSL
#define CULL_VIEW_GLSL

// One culling view: the camera or a shadow map (`gpu.CullView`). Shared by
// cull_instances.comp and cull.comp.
layout(buffer_reference, scalar) readonly buffer CullView {
    vec4 planes[6];
    vec3 camera_position;
    uint plane_count;
    // Valid only for perspective views.
    uint cone_culling;
    float p00;
    float p11;
    float near;
    mat4 view;
    vec3 lod_camera;
    float lod_scale;
    // Shadow views also draw blended surfaces.
    uint blended_casters;
    // LOD cross-fade: both levels draw while the coarser error is between 1 and
    // this many pixels. 1 or less disables it.
    float lod_band;
    // Shadow views: world-space radius below which meshlets are dropped; 0
    // keeps all.
    float min_radius;
    // Shadow views: 0 off, 1 test casters against the receiver planes, 2 also
    // against the depth pyramid.
    uint receiver_culling;
    // View matrix of the camera the shadows are for.
    mat4 receiver_view;
    // Part of the camera frustum this map shadows.
    vec4 receiver_planes[6];
    // Unit direction of light travel.
    vec3 light_travel;
    // Shadow filter reach to the side of a caster.
    float receiver_margin;
    float receiver_p00;
    float receiver_p11;
    float receiver_near;
    float receiver_pad;
    // Lens shift in half-viewport units.
    vec2 lens_shift;
    vec2 view_pad;
};

const uint PHASE_SINGLE = 0u;
const uint PHASE_EARLY = 1u;
const uint PHASE_LATE = 2u;

// Dispatch arguments for a view's meshlet culling: `x` work groups, `count`
// listed meshlets. cull_instances.comp adds to both.
layout(buffer_reference, scalar) buffer CullDispatch {
    uint x;
    uint y;
    uint z;
    uint count;
};

// Per instance-group instance and view. Bit 0: visible last frame; bit 1:
// visible the frame before.
layout(buffer_reference, scalar) buffer InstanceVisibility { uint data[]; };

#endif
