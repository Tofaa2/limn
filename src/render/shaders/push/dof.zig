//! Push constants of the passes in dof.slang. The build writes each
//! struct as `dof.<Name>.slang`, which the shader includes.

pub const BlurPush = extern struct {
    frame: u64,
    color_texture: u32,
    depth_texture: u32,
    focus_distance: f32,
    strength: f32,
    max_radius: f32,
    tap_count: i32,
    blades: u32,

    pub const references = .{ .frame = "FrameConstants" };
};

pub const CompositePush = extern struct {
    frame: u64,
    color_texture: u32,
    blurred_texture: u32,
    depth_texture: u32,
    focus_distance: f32,
    strength: f32,
    max_radius: f32,

    pub const references = .{ .frame = "FrameConstants" };
};
