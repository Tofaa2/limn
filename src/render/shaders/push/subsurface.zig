//! Push constants of the passes in subsurface.slang. The build writes each
//! struct as `subsurface.<Name>.slang`, which the shader includes.

pub const BlurPush = extern struct {
    frame: u64,
    /// Diffuse light of subsurface pixels, strength in alpha; and for the
    /// second pass, the light before either pass blurred it.
    source: u32,
    original: u32,
    depth: u32,
    /// 1 for the second pass, which gives the change to add to the picture.
    last: u32,
    direction: [2]f32,
    /// World units light travels under the skin at strength 1.
    radius: f32,
    pad: f32 = 0,

    pub const references = .{ .frame = "FrameConstants" };
};
