//! Push constants of the passes in particles.slang. The build writes each
//! struct as `particles.<Name>.slang`, which the shader includes.

pub const SimPush = extern struct {
    frame: u64,
    emitter: u64,
    particles: u64,
    trail: u64,

    pub const references = .{ .frame = "FrameConstants", .emitter = "EmitterRef", .particles = "Particle*", .trail = "float4*" };
};

pub const SortKeysPush = extern struct {
    frame: u64,
    particles: u64,
    order: u64,
    capacity: u32,
    count: u32,

    pub const references = .{ .frame = "FrameConstants", .particles = "Particle*", .order = "SortEntry*" };
};

pub const SortPush = extern struct {
    order: u64,
    count: u32,
    run: u32,
    stride: u32,

    pub const references = .{ .order = "SortEntry*" };
};

pub const SpriteVertexPush = extern struct {
    frame: u64,
    emitter: u64,
    particles: u64,
    depth_texture: u32,
    push_pad: u32,
    order: u64,

    pub const references = .{ .frame = "FrameConstants", .emitter = "EmitterRef", .particles = "Particle*", .order = "SortEntry*" };
};

pub const SpriteFragmentPush = extern struct {
    frame: u64,
    emitter: u64,
    particles: u64,
    depth_texture: u32,
    push_pad: u32 = 0,
    order: u64,

    pub const references = .{ .frame = "FrameConstants", .emitter = "EmitterRef", .particles = "Particle*", .order = "SortEntry*" };
};

pub const TrailVertexPush = extern struct {
    frame: u64,
    emitter: u64,
    particles: u64,
    depth_texture: u32,
    push_pad: u32 = 0,
    order: u64 = 0,
    trail: u64,

    pub const references = .{ .frame = "FrameConstants", .emitter = "EmitterRef", .particles = "Particle*", .order = "SortEntry*", .trail = "float4*" };
};

pub const MeshVertexPush = extern struct {
    frame: u64,
    emitter: u64,
    particles: u64,
    vertex_offset: u32,
    spin: f32,

    pub const references = .{ .frame = "FrameConstants", .emitter = "EmitterRef", .particles = "Particle*" };
};

pub const MeshFragmentPush = extern struct {
    frame: u64,
    emitter: u64,
    particles: u64,
    vertex_offset: u32,
    spin: f32,

    pub const references = .{ .frame = "FrameConstants", .emitter = "EmitterRef", .particles = "Particle*" };
};
