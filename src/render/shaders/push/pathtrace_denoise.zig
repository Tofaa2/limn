//! Push constants of the passes in pathtrace_denoise.slang. The build writes each
//! struct as `pathtrace_denoise.<Name>.slang`, which the shader includes.

pub const GatherPush = extern struct {
    frame: u64,
    color: u32,
    guide: u32,
    soft: u32,
    facing: u32,
    lamp: u32,
    gloss: u32,
    surface: u32,
    history_color: u32,
    history_guide: u32,
    history_soft: u32,
    history_facing: u32,
    history_lamp: u32,
    history_gloss: u32,
    history_surface: u32,
    motion: u32,
    depth: u32,
    moved: u32,
    reset: u32,
    history_limit: f32,
    lamp_limit: f32,
    previous_camera: [3]f32,
    pad: f32 = 0,

    pub const references = .{ .frame = "FrameConstants" };
};

/// Which step of the denoiser a pass is.
pub const DenoiseMode = enum(u32) { first = 0, last = 1, none = 2, between = 3 };

/// Push constants of pathtrace_denoise.slang.
pub const DenoisePush = extern struct {
    frame: u64,
    color_texture: u32,
    guide_texture: u32,
    step_size: i32,
    gathered: u32,
    mode: DenoiseMode,
    steady_texture: u32,
    facing_texture: u32,
    gloss_texture: u32,
    gloss_gathered_texture: u32,
    lamp_texture: u32,

    pub const references = .{ .frame = "FrameConstants" };
};

pub const NrdPackPush = extern struct {
    frame: u64,
    surface: u32,
    diffuse: u32,
    specular: u32,
    albedo: u32,
    depth: u32,
    pad: u32 = 0,

    pub const references = .{ .frame = "FrameConstants" };
};

pub const NrdComposePush = extern struct {
    frame: u64,
    steady_texture: u32,
    albedo_texture: u32,
    lamp_texture: u32,
    diffuse_texture: u32,
    specular_texture: u32,
    depth_texture: u32,

    pub const references = .{ .frame = "FrameConstants" };
};
