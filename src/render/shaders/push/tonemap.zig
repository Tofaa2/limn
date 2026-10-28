//! Push constants of the passes in tonemap.slang. The build writes each
//! struct as `tonemap.<Name>.slang`, which the shader includes.

/// Push constants of tonemap.slang.
pub const Push = extern struct {
    frame: u64,
    color_texture: u32,
    bloom_texture: u32,
    bloom_strength: f32,
    encode_srgb: u32,
    sharpen: f32,
    bloom_scale: f32,
    passthrough: u32,
    /// Top-left corner of the area being written, in target pixels.
    origin: [2]i32 = .{ 0, 0 },
    vignette: f32 = 0,
    grain: f32 = 0,
    saturation: f32 = 1,
    contrast: f32 = 1,
    color_filter: [3]f32 = .{ 1, 1, 1 },
    aberration: f32 = 0,
    hdr_paper_white: f32 = 200,
    hdr_peak: f32 = 1000,
    lut_texture: u32 = 0xffff_ffff,
    lut_strength: f32 = 1,
    flare: f32 = 0,
    /// 0 skips the tone curve: colors are only exposed, graded and encoded.
    curve: u32 = 1,

    pub const references = .{ .frame = "FrameConstants" };
};
