//! Push constants of the passes in hiz.slang. The build writes each
//! struct as `hiz.<Name>.slang`, which the shader includes.

pub const RasterPush = extern struct {
    source_texture: u32,
    sampler_index: u32,
    first: u32,
    source_lod: i32,
    texel: [2]f32,
};

pub const ComputePush = extern struct {
    source_texture: u32,
    sampler_index: u32,
    first: u32,
    source_lod: i32,
    target: u32,
    pad: u32 = 0,
    size: [2]i32,
};
