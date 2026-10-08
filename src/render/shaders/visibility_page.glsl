#ifndef VISIBILITY_PAGE_GLSL
#define VISIBILITY_PAGE_GLSL

layout(buffer_reference, scalar) readonly buffer VisibilityPage {
    mat4 view_proj;
    vec4 bounds;
};

#endif
