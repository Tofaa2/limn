//! Push constants of the passes in lightmap.slang. The build writes each
//! struct as `lightmap.<Name>.slang`, which the shader includes.

pub const BakePush = extern struct {
    frame: u64,
    tlas: u64,
    transform: [16]f32,
    vertex_offset: u32,
    gathered_texture: u32,
    rounds: u32,
    rays: u32,
    reach: f32,

    pub const references = .{ .frame = "FrameConstants" };
};

pub const DilatePush = extern struct {
    frame: u64,
    source_texture: u32,

    pub const references = .{ .frame = "FrameConstants" };
};
