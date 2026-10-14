#include "common.slang"
#include "visibility_page.slang"
#include "shading.slang"

struct HairPoint {
    float3 position;
    float along;
};

HairPoint hairPoint(float3 position, float along) {
    HairPoint point;
    point.position = position;
    point.along = along;
    return point;
}

/// Push constants of the hair strand passes.
struct HairPush {
    FrameConstants frame;
    HairPoint* points;
    HairPoint* previous_points;
    float4x4 transform;
    float4x4 previous_transform;
    float3 root_color;
    float root_width;
    float3 tip_color;
    float tip_width;
    uint points_per_strand;
    float roughness;
    float spread;
    float pad1;
};

float3 hairCopyOffset(uint strand, uint copy) {
    if (copy == 0u) return float3(0.0);
    uint state = strand * 747796405u + copy * 2891336453u + 1013904223u;
    float3 offset;
    for (int axis = 0; axis < 3; axis++) {
        state = state * 747796405u + 2891336453u;
        uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
        offset[axis] = float((word >> 22u) ^ word) / 2147483647.5 - 1.0;
    }
    return offset;
}

struct Params {
    HairPoint* rest;
    HairPoint* current;
    HairPoint* next;
    uint* density_before;
    uint* density_now;
    float4x4 transform;
    float4x4 world_to_field;
    float3 gravity;
    float damping;
    float3 wind;
    float gustiness;
    float3 field_low;
    float field_cell;
    float3 density_low_before;
    float density_cell_before;
    float3 density_low_now;
    float density_cell_now;
    float time;
    float dt;
    float previous_dt;
    float stiffness;
    float root_stiffness;
    float field_scale;
    float margin;
    float volume;
    uint strand_count;
    uint points_per_strand;
    uint collider_count;
    uint reset;
    uint field_texture;
    uint field_size;
    uint density_size;
    uint pad;
    float4 colliders[6];
};

struct SimPush {
    FrameConstants frame;
    Params* params;
};

[[vk::push_constant]] SimPush sim_push;

static const uint most_points = 64u;

float fieldAt(Params* params, float3 place) {
    float3 cells = (place - params.field_low) / params.field_cell;
    float size = float(params.field_size);
    if (any(cells < 0.5) || any(cells > size - 0.5)) return 1.0e9;
    float layer = cells.z - 0.5;
    float below = floor(layer);
    uint linear = sim_push.frame.sampler_linear_clamp;
    Texture2DArray field = textures_2d_array[NonUniformResourceIndex(params.field_texture)];
    SamplerState sampler = samplers[NonUniformResourceIndex(linear)];
    float a = field.SampleLevel(sampler, float3(cells.xy / size, below), 0.0).r;
    float b = field.SampleLevel(sampler, float3(cells.xy / size, min(below + 1.0, size - 1.0)), 0.0).r;
    return lerp(a, b, layer - below);
}

float3 outsideShape(Params* params, float3 point) {
    if (params.field_texture == INVALID_ID) return point;
    float3 place = mul(params.world_to_field, float4(point, 1.0)).xyz;
    float distance_out = fieldAt(params, place);
    float wanted = params.margin / params.field_scale;
    if (distance_out >= wanted) return point;
    float h = params.field_cell;
    float3 slope = float3(
        fieldAt(params, place + float3(h, 0.0, 0.0)) - fieldAt(params, place - float3(h, 0.0, 0.0)),
        fieldAt(params, place + float3(0.0, h, 0.0)) - fieldAt(params, place - float3(0.0, h, 0.0)),
        fieldAt(params, place + float3(0.0, 0.0, h)) - fieldAt(params, place - float3(0.0, 0.0, h)));
    float steep = length(slope);
    if (steep < 1.0e-6 || steep > 1.0e8) return point;
    float3 way = normalize(mul(slope / steep, (float3x3)params.world_to_field));
    return point + way * (wanted - distance_out) * params.field_scale;
}

uint densityAt(Params* params, int3 cell) {
    int size = int(params.density_size);
    if (any(cell < int3(0)) || any(cell >= int3(size))) return 0u;
    return params.density_before[uint(cell.x + (cell.y + cell.z * size) * size)];
}

float3 awayFromCrowd(Params* params, float3 point) {
    if (params.volume <= 0.0) return float3(0.0);
    int3 cell = int3(floor((point - params.density_low_before) / params.density_cell_before));
    float here = float(densityAt(params, cell));
    float3 slope = float3(
        float(densityAt(params, cell + int3(1, 0, 0))) - float(densityAt(params, cell - int3(1, 0, 0))),
        float(densityAt(params, cell + int3(0, 1, 0))) - float(densityAt(params, cell - int3(0, 1, 0))),
        float(densityAt(params, cell + int3(0, 0, 1))) - float(densityAt(params, cell - int3(0, 0, 1))));
    float3 push_away = -slope / (2.0 * (here + 4.0));
    float size = length(push_away);
    if (size > 1.0) push_away /= size;
    return push_away * params.volume * 0.06 * params.density_cell_before;
}

[shader("compute")]
[numthreads(64, 1, 1)]
void simMain(uint3 id : SV_DispatchThreadID) {
    Params* params = sim_push.params;
    uint strand = id.x;
    if (strand >= params.strand_count) return;
    uint first = strand * params.points_per_strand;
    uint count = min(params.points_per_strand, most_points);
    float3 above = mul(params.transform, float4(params.rest[first].position, 1.0)).xyz;
    float3 combed_above = above;
    params.next[first] = hairPoint(above, 0.0);
    params.current[first] = hairPoint(above, 0.0);
    float3 placed[most_points];
    float3 pulled[most_points];
    placed[0] = above;
    pulled[0] = float3(0.0);
    for (uint index = 1u; index < count; index++) {
        HairPoint combed = params.rest[first + index];
        float3 target = mul(params.transform, float4(combed.position, 1.0)).xyz;
        float reach = distance(target, combed_above);
        float3 point = target;
        if (params.reset == 0u) {
            float3 here = params.current[first + index].position;
            float3 before = params.next[first + index].position;
            float3 travel = (here - before) * (params.dt / max(params.previous_dt, 1.0e-4)) * (1.0 - params.damping);
            float gust = 1.0 + params.gustiness * sin(params.time * 2.3 + dot(here, float3(1.7, 0.6, 1.1)));
            point = here + travel + (params.gravity + params.wind * gust) * params.dt * params.dt;
            point += awayFromCrowd(params, here) * params.dt * 60.0;
            float hold = lerp(params.root_stiffness, params.stiffness, smoothstep(0.0, 0.35, combed.along));
            point = lerp(point, target, 1.0 - pow(1.0 - clamp(hold, 0.0, 1.0), params.dt * 60.0));
        }
        for (uint collider = 0u; collider < params.collider_count; collider++) {
            float4 sphere = params.colliders[collider];
            float3 from = point - sphere.xyz;
            float distance_in = length(from);
            if (distance_in < sphere.w) point = sphere.xyz + from / max(distance_in, 1.0e-6) * sphere.w;
        }
        point = outsideShape(params, point);
        float3 along = point - above;
        float stretched = length(along);
        float3 kept = above + (stretched > 1.0e-6 ? along / stretched : normalize(target - combed_above + float3(0.0, -1.0e-6, 0.0))) * reach;
        kept = outsideShape(params, kept);
        pulled[index] = kept - point;
        placed[index] = kept;
        params.next[first + index] = hairPoint(kept, combed.along);
        int3 cell = int3(floor((kept - params.density_low_now) / params.density_cell_now));
        int size = int(params.density_size);
        if (all(cell >= int3(0)) && all(cell < int3(size)))
            InterlockedAdd(params.density_now[uint(cell.x + (cell.y + cell.z * size) * size)], 1u);
        above = kept;
        combed_above = target;
    }
    const float handed_back = 0.9;
    for (uint index = 1u; index < count; index++) {
        float3 here = placed[index];
        if (params.reset == 0u) here = params.current[first + index].position;
        float3 travel = placed[index] - here;
        if (index + 1u < count) travel -= handed_back * pulled[index + 1u];
        params.current[first + index] = hairPoint(placed[index] - travel, params.rest[first + index].along);
    }
}

[[vk::push_constant]] HairPush strand_push;

struct StrandVaryings {
    [[vk::location(0)]] float3 position;
    [[vk::location(1)]] float3 tangent;
    [[vk::location(2)]] float2 along;
    [[vk::location(3)]] float4 clip;
    [[vk::location(4)]] float4 previous_clip;
    [[vk::location(5)]] nointerpolation float shade;
    float4 screen : SV_Position;
};

float3 strandWorldPoint(uint index) {
    return mul(strand_push.transform, float4(strand_push.points[index].position, 1.0)).xyz;
}

float strandShade(uint strand) {
    strand = strand * 747796405u + 2891336453u;
    uint word = ((strand >> ((strand >> 28u) + 4u)) ^ strand) * 277803737u;
    return lerp(0.62, 1.18, float((word >> 22u) ^ word) / 4294967295.0);
}

/// Each stretch of a strand as a ribbon turned to face the camera, at least
/// a pixel wide.
[shader("vertex")]
StrandVaryings strandMain(uint vertex : SV_VulkanVertexID, uint instance : SV_VulkanInstanceID) {
    FrameConstants frame = strand_push.frame;
    uint stretch = vertex / 6u;
    uint corner = vertex % 6u;
    uint stretches = strand_push.points_per_strand - 1u;
    uint strand = stretch / stretches;
    uint within = stretch % stretches;
    bool far_end = corner == 2u || corner == 3u || corner == 5u;
    float side = corner == 1u || corner == 4u || corner == 5u ? 1.0 : -1.0;
    uint first = strand * strand_push.points_per_strand;
    uint here = first + within + (far_end ? 1u : 0u);
    uint before = max(here, first + 1u) - 1u;
    uint after = min(here + 1u, first + stretches);
    float along = strand_push.points[here].along;
    float3 beside = hairCopyOffset(strand, instance) * strand_push.spread * lerp(0.3, 1.0, along);
    float3 position = strandWorldPoint(here) + beside;
    float3 tangent = normalize(strandWorldPoint(after) - strandWorldPoint(before));
    float3 toward = eyePoint(frame, position) - position;
    float distance_to = max(length(toward), 1e-4);
    float3 across = cross(tangent, toward / distance_to);
    float across_length = length(across);
    across = across_length > 1e-4 ? across / across_length : float3(0.0);

    float width = lerp(strand_push.root_width, strand_push.tip_width, along) * length(matrixColumn(strand_push.transform, 0));
    float pixel = 2.0 * (frame.parallel != 0.0 ? 1.0 : distance_to) / (abs(frame.proj[1][1]) * frame.resolution.y);
    float coverage = clamp(width / pixel, 0.0, 1.0);
    float3 offset = across * side * 0.5 * max(width, pixel);
    float3 previous = mul(strand_push.previous_transform, float4(strand_push.previous_points[here].position, 1.0)).xyz + beside + offset;
    position += offset;

    StrandVaryings result;
    result.position = position;
    result.tangent = tangent;
    result.along = float2(along, coverage);
    result.screen = mul(frame.view_proj, float4(position, 1.0));
    result.clip = mul(frame.view_proj_unjittered, float4(position, 1.0));
    result.previous_clip = mul(frame.prev_view_proj_unjittered, float4(previous, 1.0));
    result.shade = strandShade(strand * 31u + instance);
    return result;
}

struct ShadowPush {
    FrameConstants frame;
    HairPoint* points;
    VisibilityPage page;
    float4x4 view_proj;
    float4x4 transform;
    float3 light;
    float root_width;
    float tip_width;
    float least_width;
    uint points_per_strand;
    uint paged;
    float spread;
    float pad;
};

[[vk::push_constant]] ShadowPush shadow_push;

struct ShadowVaryings {
    float4 position : SV_Position;
    float clip[4] : SV_ClipDistance;
};

float3 shadowWorldPoint(uint index) {
    return mul(shadow_push.transform, float4(shadow_push.points[index].position, 1.0)).xyz;
}

[shader("vertex")]
ShadowVaryings shadowMain(uint vertex : SV_VulkanVertexID, uint instance : SV_VulkanInstanceID) {
    uint stretch = vertex / 6u;
    uint corner = vertex % 6u;
    uint stretches = shadow_push.points_per_strand - 1u;
    uint strand = stretch / stretches;
    uint within = stretch % stretches;
    bool far_end = corner == 2u || corner == 3u || corner == 5u;
    float side = corner == 1u || corner == 4u || corner == 5u ? 1.0 : -1.0;
    uint first = strand * shadow_push.points_per_strand;
    uint here = first + within + (far_end ? 1u : 0u);
    uint before = max(here, first + 1u) - 1u;
    uint after = min(here + 1u, first + stretches);
    float3 position = shadowWorldPoint(here) + hairCopyOffset(strand, instance) * shadow_push.spread * lerp(0.3, 1.0, shadow_push.points[here].along);
    float3 tangent = normalize(shadowWorldPoint(after) - shadowWorldPoint(before));
    float3 across = cross(tangent, shadow_push.light);
    float across_length = length(across);
    across = across_length > 1e-4 ? across / across_length : float3(0.0);
    float width = lerp(shadow_push.root_width, shadow_push.tip_width, shadow_push.points[here].along);
    position += across * side * 0.5 * max(width, shadow_push.least_width);
    ShadowVaryings result;
    result.position = mul(shadow_push.view_proj, float4(position, 1.0));
    float4 inside = float4(1.0);
    if (shadow_push.paged != 0u) {
        result.position = mul(shadow_push.page.data.view_proj, float4(position, 1.0));
        float4 bounds = shadow_push.page.data.bounds;
        inside = float4(result.position.xy - bounds.xy, bounds.zw - result.position.xy);
    }
    result.clip[0] = inside.x;
    result.clip[1] = inside.y;
    result.clip[2] = inside.z;
    result.clip[3] = inside.w;
    return result;
}

[[vk::push_constant]] HairPush shade_push;

struct Output {
    float4 color : SV_Target0;
    float4 motion : SV_Target1;
};

[shader("fragment")]
Output shadeMain(
    [[vk::location(0)]] float3 in_position,
    [[vk::location(1)]] float3 in_tangent,
    [[vk::location(2)]] float2 in_along,
    [[vk::location(3)]] float4 in_clip,
    [[vk::location(4)]] float4 in_previous_clip,
    [[vk::location(5)]] nointerpolation float in_shade,
    float4 fragment : SV_Position) {
    Output result;
    FrameConstants frame = shade_push.frame;
    float3 tangent = normalize(in_tangent);
    float3 view = normalize(eyePoint(frame, in_position) - in_position);
    float3 facing = view - tangent * dot(view, tangent);
    float facing_length = length(facing);
    float3 normal = facing_length > 1e-4 ? facing / facing_length : view;
    float3 color = lerp(shade_push.root_color, shade_push.tip_color, in_along.x) * in_shade;

    Surface surface;
    surface.position = in_position;
    surface.normal = normal;
    surface.view = view;
    surface.diffuse_color = color;
    surface.f0 = float3(0.046);
    surface.roughness = clamp(shade_push.roughness, 0.045, 1.0);
    surface.ao = 1.0;
    surface.bounce = float3(0.0);
    surface.view_depth = -(mul(frame.view, float4(in_position, 1.0))).z;
    surface.clearcoat = 0.0;
    surface.clearcoat_roughness = 0.0;
    surface.coat_normal = normal;
    surface.sheen_color = float3(0.0);
    surface.sheen_roughness = 0.5;
    surface.subsurface = 0.0;
    surface.anisotropy = 0.9;
    surface.grain = tangent;

    float noise = interleavedGradientNoise(fragment.xy, frame.frame_index);
    float3 lit = shadeSurface(frame, surface, fragment.xy, noise, float4(0.0));
    float coverage = in_along.y;
    result.color = float4(lit * coverage, coverage);
    result.motion = float4((in_clip.xy / in_clip.w - in_previous_clip.xy / in_previous_clip.w) * 0.5, 0.0, coverage);
    return result;
}
