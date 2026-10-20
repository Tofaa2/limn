//! Push constants of the passes in ffx_reflections.slang. The build writes each
//! struct as `ffx_reflections.<Name>.slang`, which the shader includes.

pub const ReprojectPush = extern struct {
    frame: u64,
    radiance_texture: u32,
    surface_texture: u32,
    surface_history_texture: u32,
    motion_texture: u32,
    history_texture: u32,
    samples_history_texture: u32,
    reach_texture: u32,

    pub const references = .{ .frame = "FrameConstants" };
};

pub const PrefilterPush = extern struct {
    frame: u64,
    radiance_texture: u32,
    reprojected_texture: u32,
    surface_texture: u32,
    average_texture: u32,

    pub const references = .{ .frame = "FrameConstants" };
};

pub const ResolvePush = extern struct {
    frame: u64,
    prefiltered_texture: u32,
    reprojected_texture: u32,
    samples_texture: u32,
    surface_texture: u32,
    average_texture: u32,
    history_clip_weight: f32,

    pub const references = .{ .frame = "FrameConstants" };
};

pub const AveragePush = extern struct {
    frame: u64,
    radiance_texture: u32,
    reprojected_texture: u32,
    samples_texture: u32,

    pub const references = .{ .frame = "FrameConstants" };
};
