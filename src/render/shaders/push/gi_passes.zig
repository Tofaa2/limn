//! Push constants of the passes in gi_passes.slang. The build writes each
//! struct as `gi_passes.<Name>.slang`, which the shader includes.

pub const TracePush = extern struct {
    frame: u64,
    rays: u64,
    tlas: u64,
    directions: u64,
    buried: u64,
    rays_per_probe: u32,
    probe_count: u32,
    multibounce: u32,
    max_distance: f32,
    probe_stride: u32,
    probe_phase: u32,
    grid: u32,
    skip_buried: u32,
    far_distance: f32,
    turn: u32,

    pub const references = .{ .frame = "FrameConstants", .rays = "float4*", .directions = "float4*", .buried = "uint*" };
};

pub const RelocatePush = extern struct {
    update: UpdatePush,
    previous_offsets: u32,
    pad: [3]u32 = .{ 0, 0, 0 },
};

pub const GatherPush = extern struct {
    frame: u64,
    depth_texture: u32,

    pub const references = .{ .frame = "FrameConstants" };
};

pub const ClampPush = extern struct {
    frame: u64,
    fast_texture: u32,
    scale: f32,
    offset: f32,

    pub const references = .{ .frame = "FrameConstants" };
};

pub const UpdatePush = extern struct {
    frame: u64,
    rays: u64,
    directions: u64,
    rays_per_probe: u32,
    hysteresis: f32,
    max_distance: f32,
    probe_stride: u32,
    probe_phase: u32,
    fast_hysteresis: f32,
    /// Grid cells the volume moved by; probes that wrapped start over.
    shift: [3]i32,
    grid_index: u32,
    far_distance: f32,
    turn: u32,
    /// The direction the first ray points nearest and the last furthest
    /// from, between which the others are ordered.
    axis: [3]f32,
    axis_pad: f32 = 0,

    pub const references = .{ .frame = "FrameConstants", .rays = "float4*", .directions = "float4*" };
};
