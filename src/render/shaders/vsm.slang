#ifndef VSM_SLANG
#define VSM_SLANG
#include "common.slang"

static const int vsm_pages = 16;
static const float vsm_page_texels = 256.0;
static const int vsm_atlas_pages = 16;
static const uint vsm_pages_per_frame = 8u;

static const uint VSM_READY = 1u;
static const uint VSM_STALE = 2u;

float vsmExtent(VsmData* vsm, uint level) {
    return vsm.base_extent * exp2(float(level));
}

int2 vsmWindow(VsmData* vsm, uint level) {
    float page = vsmExtent(vsm, level) / float(vsm_pages);
    return int2(floor(vsm.camera.xy / page)) - vsm_pages / 2;
}

uint vsmKey(int2 page) {
    return (uint(page.x & 0xffff) << 16) | uint(page.y & 0xffff);
}

uint vsmSlot(uint level, int2 page) {
    return level * uint(vsm_pages * vsm_pages) + uint(page.x & (vsm_pages - 1)) + uint(page.y & (vsm_pages - 1)) * uint(vsm_pages);
}

uint vsmLevel(VsmData* vsm, float2 point) {
    float2 from_camera = abs(point - vsm.camera.xy);
    float reach = max(from_camera.x, from_camera.y);
    for (uint level = 0u; level + 1u < vsm.levels; level++) {
        float extent = vsmExtent(vsm, level);
        if (reach < extent * (0.5 - 1.5 / float(vsm_pages))) return level;
    }
    return vsm.levels - 1u;
}

bool vsmLocate(VsmData* vsm, uint level, float2 point, out int2 page, out float2 within) {
    float size = vsmExtent(vsm, level) / float(vsm_pages);
    float2 at = point / size;
    page = int2(floor(at));
    within = at - float2(page);
    int2 from_window = page - vsmWindow(vsm, level);
    return all(from_window >= int2(0)) && all(from_window < int2(vsm_pages));
}

#endif
