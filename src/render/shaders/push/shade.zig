//! Push constants of the passes in shade.slang. The build writes each
//! struct as `shade.<Name>.slang`, which the shader includes.

pub const Push = extern struct {
    frame: u64,
    visibility_texture: u32,
    ao_texture: u32,
    debug_view: u32,
    gi_texture: u32,
    material_shader: u32,
    shadow_history: u32,
    bounce_texture: u32,
    bounce_strength: f32,
    shadow_depth: u32 = 0xffff_ffff,

    pub const references = .{ .frame = "FrameConstants" };
};
