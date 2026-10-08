#ifndef VSM_GLSL
#define VSM_GLSL

const int vsm_pages = 16;
const float vsm_page_texels = 256.0;
const int vsm_atlas_pages = 16;
const uint vsm_pages_per_frame = 8u;

const uint VSM_READY = 1u;
const uint VSM_STALE = 2u;

struct VsmPage {
    uint key;
    uint place;
    uint used;
    uint flags;
};

struct VsmPageView {
    mat4 view_proj;
    vec4 bounds;
};

layout(buffer_reference, scalar) buffer VsmPages { VsmPage data[]; };
layout(buffer_reference, scalar) buffer VsmWords { uint data[]; };
layout(buffer_reference, scalar) buffer VsmPageViews { VsmPageView data[]; };
layout(buffer_reference, scalar) readonly buffer VsmSpheres { vec4 data[]; };

layout(buffer_reference, scalar) readonly buffer Vsm {
    mat4 light_view;
    vec3 camera;
    float base_extent;
    float depth_from;
    float depth_range;
    uint frame;
    uint reset;
    uint levels;
    uint atlas_texture;
    uint mover_count;
    uint all_moved;
    VsmPages pages;
    VsmWords owners;
    VsmWords requested;
    VsmPageViews page_views;
    VsmSpheres movers;
};

float vsmExtent(Vsm vsm, uint level) {
    return vsm.base_extent * exp2(float(level));
}

ivec2 vsmWindow(Vsm vsm, uint level) {
    float page = vsmExtent(vsm, level) / float(vsm_pages);
    return ivec2(floor(vsm.camera.xy / page)) - vsm_pages / 2;
}

uint vsmKey(ivec2 page) {
    return (uint(page.x & 0xffff) << 16) | uint(page.y & 0xffff);
}

uint vsmSlot(uint level, ivec2 page) {
    return level * uint(vsm_pages * vsm_pages) + uint(page.x & (vsm_pages - 1)) + uint(page.y & (vsm_pages - 1)) * uint(vsm_pages);
}

uint vsmLevel(Vsm vsm, vec2 point) {
    vec2 from_camera = abs(point - vsm.camera.xy);
    float reach = max(from_camera.x, from_camera.y);
    for (uint level = 0u; level + 1u < vsm.levels; level++) {
        float extent = vsmExtent(vsm, level);
        if (reach < extent * (0.5 - 1.5 / float(vsm_pages))) return level;
    }
    return vsm.levels - 1u;
}

bool vsmLocate(Vsm vsm, uint level, vec2 point, out ivec2 page, out vec2 within) {
    float size = vsmExtent(vsm, level) / float(vsm_pages);
    vec2 at = point / size;
    page = ivec2(floor(at));
    within = at - vec2(page);
    ivec2 from_window = page - vsmWindow(vsm, level);
    return all(greaterThanEqual(from_window, ivec2(0))) && all(lessThan(from_window, ivec2(vsm_pages)));
}

#endif
