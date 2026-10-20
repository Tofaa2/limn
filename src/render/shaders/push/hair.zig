//! Push constants of the passes in hair.slang. The build writes each
//! struct as `hair.<Name>.slang`, which the shader includes.

/// Push constants of the hair strand passes.
pub const HairPush = extern struct {
    frame: u64,
    points: u64,
    previous_points: u64,
    transform: [16]f32,
    previous_transform: [16]f32,
    root_color: [3]f32,
    root_width: f32,
    tip_color: [3]f32,
    tip_width: f32,
    points_per_strand: u32,
    roughness: f32,
    spread: f32,
    pad1: f32 = 0,

    pub const references = .{ .frame = "FrameConstants", .points = "HairPoint*", .previous_points = "HairPoint*" };
};

pub const SimPush = extern struct {
    frame: u64,
    params: u64,

    pub const references = .{ .frame = "FrameConstants", .params = "Params*" };
};

pub const ShadowPush = extern struct {
    frame: u64,
    points: u64,
    page: u64,
    view_proj: [16]f32,
    transform: [16]f32,
    light: [3]f32,
    root_width: f32,
    tip_width: f32,
    least_width: f32,
    points_per_strand: u32,
    paged: u32,
    spread: f32,
    pad: f32 = 0,

    pub const references = .{ .frame = "FrameConstants", .points = "HairPoint*", .page = "VisibilityPage" };
};
