//! Push constants of the passes in fog.slang. The build writes each
//! struct as `fog.<Name>.slang`, which the shader includes.

pub const FogPush = extern struct {
    frame: u64,
    depth_texture: u32,
    density: f32,
    anisotropy: f32,
    height_falloff: f32,
    max_distance: f32,
    ambient: f32,
    step_count: i32,

    pub const references = .{ .frame = "FrameConstants" };
};

pub const CompositePush = extern struct {
    frame: u64,
    fog_texture: u32,
    depth_texture: u32,

    pub const references = .{ .frame = "FrameConstants" };
};
