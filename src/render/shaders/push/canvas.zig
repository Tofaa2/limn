//! Push constants of the passes in canvas.slang. The build writes each
//! struct as `canvas.<Name>.slang`, which the shader includes.

pub const Push = extern struct {
    vertices: u64,
    indices: u64,
    transform: [16]f32,
    camera_right: [3]f32,
    encode_srgb: u32,
    camera_up: [3]f32,
    sdf_spread: f32,
    viewport: [2]f32,
    sampler_linear: u32,
    sampler_nearest: u32,
    /// Scene depth to test against, or `invalid_id`.
    depth_texture: u32,
    /// HDR10 targets: brightness of white in nits.
    hdr_paper_white: f32,
    origin: [2]f32,
    /// 1 to read text from the three-channel field.
    sharp_text: u32,
    /// Seconds since the renderer started, for custom shaders.
    time: f32,
    /// `Quad` records; the draw unfolds them when `unfold` is set.
    quads: u64 = 0,
    unfold: u32 = 0,
    /// 1 to draw only where the scene's depth shows no surface.
    under: u32 = 0,

    pub const references = .{ .vertices = "DrawVertex*", .indices = "uint*", .quads = "DrawQuad*" };
};
