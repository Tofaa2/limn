#include "vsm.slang"
#include "cull_view.slang"

struct MarkPush {
    FrameConstants frame;
    VsmData* vsm;
    uint depth_texture;
    uint pad;
};

[[vk::push_constant]] MarkPush mark_push;

[shader("compute")]
[numthreads(8, 8, 1)]
void markMain(uint3 id : SV_DispatchThreadID) {
    FrameConstants frame = mark_push.frame;
    VsmData* vsm = mark_push.vsm;
    int2 pixel = int2(id.xy);
    if (any(pixel >= int2(frame.resolution))) return;
    float depth = fetchTexel(mark_push.depth_texture, pixel).r;
    if (depth <= 0.0) return;
    float2 uv = (float2(pixel) + 0.5) / frame.resolution;
    float3 position = worldPositionFromDepth(uv, depth, frame.inv_view_proj);
    float2 point = mul(vsm.light_view, float4(position, 1.0)).xy;
    uint level = vsmLevel(vsm, point);
    int2 page;
    float2 within;
    if (!vsmLocate(vsm, level, point, page, within)) return;
    vsm.requested[vsmSlot(level, page)] = vsm.frame;
}

struct AllocatePush {
    FrameConstants frame;
    VsmData* vsm;
    uint* views;
    uint first_page_view;
    uint pad;
};

[[vk::push_constant]] AllocatePush allocate_push;

static const uint cull_view_words = 108u;
static const uint cull_view_plane_count = 27u;
static const uint cull_view_cone_culling = 28u;
static const uint cull_view_blended_casters = 52u;
static const uint cull_view_lod_band = 53u;
static const uint cull_view_min_radius = 54u;
static const uint cull_view_receiver_culling = 55u;

uint pageCullView(uint which) {
    uint first = (allocate_push.first_page_view + which) * cull_view_words;
    for (uint word = 0u; word < cull_view_words; word++) allocate_push.views[first + word] = allocate_push.views[word];
    allocate_push.views[first + cull_view_cone_culling] = 0u;
    allocate_push.views[first + cull_view_blended_casters] = 0u;
    allocate_push.views[first + cull_view_lod_band] = asuint(1.0);
    allocate_push.views[first + cull_view_min_radius] = asuint(0.0);
    allocate_push.views[first + cull_view_receiver_culling] = 0u;
    return first;
}

void setPlane(uint first, uint plane, float4 value) {
    for (uint part = 0u; part < 4u; part++) allocate_push.views[first + plane * 4u + part] = asuint(value[part]);
}

bool moved(VsmData* vsm, uint level, int2 page) {
    if (vsm.all_moved != 0u) return true;
    float size = vsmExtent(vsm, level) / float(vsm_pages);
    float2 low = float2(page) * size;
    for (uint index = 0u; index < vsm.mover_count; index++) {
        float4 sphere = vsm.movers[index];
        float2 middle = mul(vsm.light_view, float4(sphere.xyz, 1.0)).xy;
        float2 nearest = clamp(middle, low, low + size);
        if (distance(nearest, middle) <= sphere.w) return true;
    }
    return false;
}

void drawPage(VsmData* vsm, uint which, uint level, int2 page, uint place) {
    float size = vsmExtent(vsm, level) / float(vsm_pages);
    float2 low = float2(page) * size;
    int2 in_atlas = int2(int(place) % vsm_atlas_pages, int(place) / vsm_atlas_pages);
    float across = 2.0 / float(vsm_atlas_pages);
    float2 corner = float2(in_atlas) * across - 1.0;
    float4x4 fit = float4x4(
        across / size, 0.0, 0.0, corner.x - low.x * across / size,
        0.0, across / size, 0.0, corner.y - low.y * across / size,
        0.0, 0.0, 1.0 / vsm.depth_range, -vsm.depth_from / vsm.depth_range,
        0.0, 0.0, 0.0, 1.0);
    float4x4 light_view = vsm.light_view;
    VsmPageView view;
    view.view_proj = mul(fit, light_view);
    view.bounds = float4(corner, corner + across);
    vsm.page_views[which] = view;

    float3 right = float3(light_view[0][0], light_view[0][1], light_view[0][2]);
    float3 up = float3(light_view[1][0], light_view[1][1], light_view[1][2]);
    float2 offset = float2(light_view[0][3], light_view[1][3]);
    uint cull = pageCullView(which);
    setPlane(cull, 0u, float4(right, offset.x - low.x));
    setPlane(cull, 1u, float4(-right, low.x + size - offset.x));
    setPlane(cull, 2u, float4(up, offset.y - low.y));
    setPlane(cull, 3u, float4(-up, low.y + size - offset.y));
    allocate_push.views[cull + cull_view_plane_count] = 4u;
}

int2 slotPage(VsmData* vsm, uint slot, uint per_level) {
    uint level = slot / per_level;
    int2 window = vsmWindow(vsm, level);
    int2 wrapped = int2(int(slot % per_level) % vsm_pages, int(slot % per_level) / vsm_pages);
    return window + ((wrapped - window) & (vsm_pages - 1));
}

[shader("compute")]
[numthreads(1, 1, 1)]
void allocateMain() {
    VsmData* vsm = allocate_push.vsm;
    uint per_level = uint(vsm_pages * vsm_pages);
    uint total = vsm.levels * per_level;
    uint places = uint(vsm_atlas_pages * vsm_atlas_pages);

    for (uint slot = 0u; slot < total; slot++) {
        uint level = slot / per_level;
        int2 page = slotPage(vsm, slot, per_level);
        VsmPage entry = vsm.pages[slot];
        uint key = vsmKey(page);
        if (vsm.reset != 0u || entry.key != key) {
            if (entry.place != 0u) vsm.owners[entry.place - 1u] = 0u;
            entry.key = key;
            entry.place = 0u;
            entry.used = 0u;
            entry.flags = 0u;
        }
        if (vsm.requested[slot] == vsm.frame) entry.used = vsm.frame;
        if (entry.place != 0u && (entry.flags & VSM_READY) != 0u && moved(vsm, level, page)) entry.flags = VSM_STALE;
        vsm.pages[slot] = entry;
    }

    uint drawn = 0u;
    uint search = 0u;
    for (uint slot = 0u; slot < total * 2u; slot++) {
        bool stale_round = slot < total;
        VsmPage entry = vsm.pages[slot % total];
        if (entry.used != vsm.frame || ((entry.flags & VSM_STALE) != 0u) != stale_round) continue;
        uint level = (slot % total) / per_level;
        int2 page = slotPage(vsm, slot % total, per_level);
        if (entry.place == 0u) {
            uint found = places;
            for (uint tried = 0u; tried < places && found == places; tried++) {
                uint place = (search + tried) % places;
                if (vsm.owners[place] == 0u) found = place;
            }
            if (found == places) {
                uint oldest = vsm.frame;
                for (uint place = 0u; place < places; place++) {
                    uint used = vsm.pages[vsm.owners[place] - 1u].used;
                    if (used < oldest) {
                        oldest = used;
                        found = place;
                    }
                }
                if (found == places) continue;
                uint evicted = vsm.owners[found] - 1u;
                vsm.pages[evicted].place = 0u;
                vsm.pages[evicted].flags = 0u;
            }
            search = found + 1u;
            vsm.owners[found] = slot % total + 1u;
            entry.place = found + 1u;
            entry.flags = 0u;
        }
        if ((entry.flags & VSM_READY) == 0u && drawn < vsm_pages_per_frame) {
            drawPage(vsm, drawn, level, page, entry.place - 1u);
            entry.flags = VSM_READY;
            drawn++;
        }
        vsm.pages[slot % total] = entry;
    }

    for (uint which = drawn; which < vsm_pages_per_frame; which++) {
        VsmPageView view;
        view.view_proj = float4x4(0.0);
        view.bounds = float4(0.0);
        vsm.page_views[which] = view;
        uint cull = pageCullView(which);
        setPlane(cull, 0u, float4(0.0, 0.0, 0.0, -1.0e30));
        allocate_push.views[cull + cull_view_plane_count] = 1u;
    }
}

struct ClearPush {
    VsmPageView* page_views;
};

[[vk::push_constant]] ClearPush clear_push;

[shader("vertex")]
float4 clearMain(uint vertex : SV_VulkanVertexID, uint instance : SV_VulkanInstanceID) : SV_Position {
    float4 bounds = clear_push.page_views[instance].bounds;
    float2 corner = float2(vertex == 1u || vertex == 4u || vertex == 5u ? bounds.z : bounds.x, vertex == 2u || vertex == 3u || vertex == 5u ? bounds.w : bounds.y);
    return float4(corner, 1.0, 1.0);
}
