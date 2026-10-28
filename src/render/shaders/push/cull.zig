//! Push constants of the passes in cull.slang. The build writes each
//! struct as `cull.<Name>.slang`, which the shader includes.

/// Push constants of the culling pass, for one view at a time.
pub const MeshletPush = extern struct {
    frame: u64,
    view: u64,
    commands: u64,
    counts: u64,
    visibility: u64,
    ref_count: u32,
    bucket_capacity: u32,
    phase: u32,
    hiz_texture: u32,
    hiz_size: [2]f32,
    skin_bounds: u64,
    seen: u64,
    mark_seen: u32 = 0,
    masked_capacity: u32 = 0,
    candidates: u64 = 0,
    dispatch: u64 = 0,
    /// Per instance record, whether its instance was visible last frame.
    instance_visibility: u64 = 0,
    seen_total: u32 = 0,
    mesh_lists: u32 = 0,
    mesh_draws: u64 = 0,
    lists: u64 = 0,
    /// With `ordered`, the bucket each visible reference is marked for
    /// instead of being listed: 1 opaque, 2 masked.
    marks: u64 = 0,
    ordered: u32 = 0,
    push_pad: u32 = 0,

    pub const references = .{ .frame = "FrameConstants", .view = "CullView", .commands = "DrawCommand*", .counts = "uint*", .visibility = "uint*", .skin_bounds = "float4*", .seen = "uint*", .candidates = "uint*", .dispatch = "CullDispatch", .instance_visibility = "uint*", .mesh_draws = "MeshDraw*", .lists = "uint*", .marks = "uint*" };
};

/// Push constants of the passes that list marked references in reference
/// order: counted per block of `order_block`, the counts turned into
/// offsets, then written.
pub const OrderPush = extern struct {
    frame: u64,
    marks: u64,
    blocks: u64,
    commands: u64,
    lists: u64,
    counts: u64,
    mesh_draws: u64,
    ref_count: u32,
    bucket_capacity: u32,
    masked_capacity: u32,
    mesh_lists: u32,

    pub const references = .{ .frame = "FrameConstants", .marks = "uint*", .blocks = "uint*", .commands = "DrawCommand*", .lists = "uint*", .counts = "uint*", .mesh_draws = "MeshDraw*" };
};

/// References each workgroup of the ordering passes covers.
pub const order_block = 1024;

/// Push constants of the instance pass in cull.slang.
pub const InstancePush = extern struct {
    frame: u64,
    view: u64,
    instances: u64,
    candidates: u64,
    dispatch: u64,
    visibility: u64,
    instance_count: u32,
    phase: u32,
    hiz_texture: u32,
    /// Entity slots, culled before the `instance_count` instance groups'
    /// instances; `visibility` and the dispatch cover both.
    entity_count: u32,
    hiz_size: [2]f32,
    impostors: u64 = 0,
    impostor_list: u64 = 0,
    impostor_draw: u64 = 0,
    entity_cull: u64 = 0,
    /// Nonzero for the camera's view, where small copies become impostors.
    impostor_view: u32 = 0,
    push_pad: u32 = 0,

    pub const references = .{ .frame = "FrameConstants", .view = "CullView", .instances = "StaticCull*", .candidates = "uint*", .dispatch = "CullDispatch", .visibility = "uint*", .impostors = "Impostor*", .impostor_list = "uint*", .impostor_draw = "ImpostorDraw*", .entity_cull = "uint2*" };
};
