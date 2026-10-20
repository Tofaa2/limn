//! Push constants of the passes in ssr.slang. The build writes each
//! struct as `ssr.<Name>.slang`, which the shader includes.

pub const TracePush = extern struct {
    frame: u64,
    depth_texture: u32,
    color_texture: u32,
    reflection_texture: u32,
    surface_texture: u32,
    max_roughness: f32,
    thickness: f32,
    max_distance: f32,
    step_count: i32,
    history_texture: u32,
    history_blend: f32,
    tlas: u64,

    pub const references = .{ .frame = "FrameConstants" };
};

pub const CompositePush = extern struct {
    frame: u64,
    depth_texture: u32,
    reflection_texture: u32,
    surface_texture: u32,
    traced_texture: u32,
    max_roughness: f32,
    blur_taps: i32,
    reduced: u32,

    pub const references = .{ .frame = "FrameConstants" };
};
