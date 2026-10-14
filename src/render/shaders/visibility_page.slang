#ifndef VISIBILITY_PAGE_SLANG
#define VISIBILITY_PAGE_SLANG

struct VisibilityPageData {
    float4x4 view_proj;
    float4 bounds;
};

struct VisibilityPage { VisibilityPageData* data; };

#endif
