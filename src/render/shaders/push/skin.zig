//! Push constants of the passes in skin.slang. The build writes each
//! struct as `skin.<Name>.slang`, which the shader includes.

pub const SkinPush = extern struct {
    vertices: u64,
    skin: u64,
    joints: u64,
    morph: u64,
    jobs: u64,
    group_jobs: u64,
    weights: u64,
    group_count: u32,

    pub const references = .{ .vertices = "Vertex*", .skin = "SkinVertex*", .joints = "float4x4*", .morph = "MorphDelta*", .jobs = "SkinJob*", .group_jobs = "uint*", .weights = "float*" };
};

pub const BoundsPush = extern struct {
    vertices: u64,
    indices: u64,
    meshlets: u64,
    bounds: u64,
    jobs: u64,
    group_jobs: u64,
    group_count: u32,

    pub const references = .{ .vertices = "Vertices", .indices = "Indices", .meshlets = "Meshlets", .bounds = "float4*", .jobs = "BoundsJob*", .group_jobs = "uint*" };
};
