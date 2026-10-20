//! Push constants of the passes in resolution.slang. The build writes each
//! struct as `resolution.<Name>.slang`, which the shader includes.

pub const UpscalePush = extern struct {
    frame: u64,
    source_texture: u32,

    pub const references = .{ .frame = "FrameConstants" };
};

pub const EasuPush = extern struct {
    frame: u64,
    source_texture: u32,
    pad: u32 = 0,
    con0: [4]u32,
    con1: [4]u32,
    con2: [4]u32,
    con3: [4]u32,

    pub const references = .{ .frame = "FrameConstants" };
};

pub const RcasPush = extern struct {
    frame: u64,
    source_texture: u32,
    pad: u32 = 0,
    con: [4]u32,

    pub const references = .{ .frame = "FrameConstants" };
};
