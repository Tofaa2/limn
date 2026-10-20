//! Push constants of the passes in cloud_passes.slang. The build writes each
//! struct as `cloud_passes.<Name>.slang`, which the shader includes.

pub const MarchPush = extern struct {
    frame: u64,
    clouds: u64,

    pub const references = .{ .frame = "FrameConstants", .clouds = "CloudRef" };
};

pub const NoisePush = extern struct {
    size: [3]i32,
    tiles_x: i32,
};

pub const CompositePush = extern struct {
    frame: u64,
    clouds: u64,
    cloud_texture: u32 = 0,

    pub const references = .{ .frame = "FrameConstants", .clouds = "CloudRef" };
};
