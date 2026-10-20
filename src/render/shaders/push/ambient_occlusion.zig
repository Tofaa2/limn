//! Push constants of the passes in ambient_occlusion.slang. The build writes each
//! struct as `ambient_occlusion.<Name>.slang`, which the shader includes.

pub const DepthPush = extern struct {
    source_texture: u32,
    sampler_index: u32,
    first: u32,
    source_lod: i32,
    terms: [4]f32,
};

pub const GtaoPush = extern struct {
    frame: u64,
    depth_texture: u32,
    color_texture: u32,
    radius: f32,
    intensity: f32,
    slice_count: i32,
    step_count: i32,

    pub const references = .{ .frame = "FrameConstants" };
};

pub const DenoisePush = extern struct {
    frame: u64,
    ao_texture: u32,
    depth_texture: u32,
    history_texture: u32,
    history_blend: f32,
    bounce_texture: u32,
    bounce_history_texture: u32,

    pub const references = .{ .frame = "FrameConstants" };
};
