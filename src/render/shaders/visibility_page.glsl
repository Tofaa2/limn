#ifndef VISIBILITY_PAGE_GLSL
#define VISIBILITY_PAGE_GLSL

// View of one virtual shadow map page (`VsmPageView` in vsm.glsl), used instead
// of the pass's view when `paged` is set.
layout(buffer_reference, scalar) readonly buffer VisibilityPage {
    mat4 view_proj;
    // Writable part of the target, in NDC.
    vec4 bounds;
};

#endif
