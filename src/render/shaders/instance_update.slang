#include "common.slang"

static const uint MOVE_MOVED = 1u;
static const uint MOVE_KEEP = 2u;

struct Move {
    uint instance;
    uint tlas_slot;
    uint flags;
    uint move_pad;
    float3x4 transform;
};

struct Rewrite {
    uint instance;
    uint tlas_slot;
    uint rewrite_pad0;
    uint rewrite_pad1;
    float3x4 previous;
    Instance record;
};

struct TlasInstance {
    float4x3 transform;
    uint custom_index_and_mask;
    uint offset_and_flags;
    uint blas_low;
    uint blas_high;
};

#ifdef REWRITE
typedef Rewrite* Updates;
#else
typedef Move* Updates;
#endif

#include "instance_update.Push.slang"

[[vk::push_constant]] Push push;

[shader("compute")]
[numthreads(64, 1, 1)]
void computeMain(uint3 id : SV_DispatchThreadID) {
    uint index = id.x;
    if (index >= push.count) return;
#ifdef REWRITE
    Rewrite change = push.updates[index];
    float3x4 transform = change.record.transform;
    push.previous[change.instance] = change.previous;
    push.records[change.instance] = change.record;
#else
    Move change = push.updates[index];
    if (change.instance == INVALID_ID) return;
    float3x4 transform = change.transform;
    push.previous[change.instance] = (change.flags & MOVE_KEEP) != 0u ? push.records[change.instance].transform : transform;
    uint flags = push.records[change.instance].flags & ~(INSTANCE_MOVING | INSTANCE_PREVIOUS);
    if ((change.flags & MOVE_MOVED) != 0u) flags |= INSTANCE_MOVING | INSTANCE_PREVIOUS;
    push.records[change.instance].transform = transform;
    push.records[change.instance].flags = flags;
#endif
    if (change.tlas_slot != INVALID_ID) push.tlas[change.tlas_slot].transform = transpose(transform);
}
