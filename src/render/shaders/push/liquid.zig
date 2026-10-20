//! Push constants of the passes in liquid.slang. The build writes each
//! struct as `liquid.<Name>.slang`, which the shader includes.

pub const SimPush = extern struct {
    liquid: u64,
    particles: u64,
    counts: u64,
    cells: u64,
    mode: u32,
    flip: u32,

    pub const references = .{ .liquid = "LiquidData*", .particles = "LiquidParticle*", .counts = "uint*", .cells = "uint*" };
};

pub const SpherePush = extern struct {
    frame: u64,
    liquid: u64,
    particles: u64,
    depth_texture: u32,
    swell: f32,

    pub const references = .{ .frame = "FrameConstants", .liquid = "LiquidData*", .particles = "LiquidParticle*" };
};

pub const ShadowPush = extern struct {
    frame: u64,
    liquid: u64,
    particles: u64,
    view_proj: [16]f32,
    swell: f32,
    strength: f32,

    pub const references = .{ .frame = "FrameConstants", .liquid = "LiquidData*", .particles = "LiquidParticle*" };
};

pub const SurfacePush = extern struct {
    frame: u64,
    distance_texture: u32,

    pub const references = .{ .frame = "FrameConstants" };
};

pub const BlurPush = extern struct {
    frame: u64,
    source_texture: u32,
    raw: u32,
    direction: [2]f32,
    width: f32,
    edge: f32,

    pub const references = .{ .frame = "FrameConstants" };
};

pub const ShadePush = extern struct {
    frame: u64,
    liquid: u64,
    distance_texture: u32,
    thickness_texture: u32,
    scene_texture: u32,
    depth_texture: u32,

    pub const references = .{ .frame = "FrameConstants", .liquid = "LiquidData*" };
};
