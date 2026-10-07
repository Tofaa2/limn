#ifndef VSM_GLSL
#define VSM_GLSL

// Virtual shadow maps for the sun: nested clipmap levels around the camera,
// each twice as wide as the last, cut into pages. Only pages something on
// screen falls in are allocated, in one shared atlas, and pages are redrawn
// only when something in them moves.
//
//   vsm_mark.comp      marks the pages visible surfaces fall in
//   vsm_allocate.comp  allocates them and picks which to draw
//   visibility.vert    (and .mesh) draw a page
//   shading.glsl       samples the shadow

// Pages per level side, texels per page side, pages per atlas side.
const int vsm_pages = 16;
const float vsm_page_texels = 256.0;
const int vsm_atlas_pages = 16;
// Maximum pages drawn per frame.
const uint vsm_pages_per_frame = 8u;

const uint VSM_READY = 1u;
// Drawn before but invalidated; redrawn ahead of never-drawn pages.
const uint VSM_STALE = 2u;

// Page table entry: key (see vsmKey), atlas slot + 1 (0 for none), frame last
// requested, and state.
struct VsmPage {
    uint key;
    uint place;
    uint used;
    uint flags;
};

// Draw view of a page: light view-projection mapped to its atlas slot, and its
// atlas rectangle in NDC (min, max).
struct VsmPageView {
    mat4 view_proj;
    vec4 bounds;
};

layout(buffer_reference, scalar) buffer VsmPages { VsmPage data[]; };
layout(buffer_reference, scalar) buffer VsmWords { uint data[]; };
layout(buffer_reference, scalar) buffer VsmPageViews { VsmPageView data[]; };
layout(buffer_reference, scalar) readonly buffer VsmSpheres { vec4 data[]; };

// Must match `gpu.VsmParams`.
layout(buffer_reference, scalar) readonly buffer Vsm {
    // World to light space: x, y across the light, z along it.
    mat4 light_view;
    // Camera in light space, and extent of the finest level.
    vec3 camera;
    float base_extent;
    // Depth range along the light.
    float depth_from;
    float depth_range;
    uint frame;
    // Nonzero to invalidate every page.
    uint reset;
    uint levels;
    uint atlas_texture;
    uint mover_count;
    // Nonzero when `movers` overflowed: every page is redrawn.
    uint all_moved;
    VsmPages pages;
    // Per atlas slot: owning page + 1.
    VsmWords owners;
    // Per page: frame last requested.
    VsmWords requested;
    VsmPageViews page_views;
    VsmSpheres movers;
};

float vsmExtent(Vsm vsm, uint level) {
    return vsm.base_extent * exp2(float(level));
}

// First page of a level's window, which snaps to whole pages.
ivec2 vsmWindow(Vsm vsm, uint level) {
    float page = vsmExtent(vsm, level) / float(vsm_pages);
    return ivec2(floor(vsm.camera.xy / page)) - vsm_pages / 2;
}

uint vsmKey(ivec2 page) {
    return (uint(page.x & 0xffff) << 16) | uint(page.y & 0xffff);
}

// Page table slot; pages wrap within their level (toroidal addressing).
uint vsmSlot(uint level, ivec2 page) {
    return level * uint(vsm_pages * vsm_pages) + uint(page.x & (vsm_pages - 1)) + uint(page.y & (vsm_pages - 1)) * uint(vsm_pages);
}

// Finest level whose window contains a light-space point with margin.
uint vsmLevel(Vsm vsm, vec2 point) {
    vec2 from_camera = abs(point - vsm.camera.xy);
    float reach = max(from_camera.x, from_camera.y);
    for (uint level = 0u; level + 1u < vsm.levels; level++) {
        float extent = vsmExtent(vsm, level);
        if (reach < extent * (0.5 - 1.5 / float(vsm_pages))) return level;
    }
    return vsm.levels - 1u;
}

// Page of `level` containing a point and the position in it (0..1). False
// outside the window.
bool vsmLocate(Vsm vsm, uint level, vec2 point, out ivec2 page, out vec2 within) {
    float size = vsmExtent(vsm, level) / float(vsm_pages);
    vec2 at = point / size;
    page = ivec2(floor(at));
    within = at - vec2(page);
    ivec2 from_window = page - vsmWindow(vsm, level);
    return all(greaterThanEqual(from_window, ivec2(0))) && all(lessThan(from_window, ivec2(vsm_pages)));
}

#endif
