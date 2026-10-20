//! Push constants of the passes in water_passes.slang. The build writes each
//! struct as `water_passes.<Name>.slang`, which the shader includes.

pub const SimPush = extern struct {
    water: u64,

    pub const references = .{ .water = "WaterRef" };
};

pub const SurfacePush = extern struct {
    frame: u64,
    water: u64,
    depth_texture: u32,
    scene_texture: u32,
    quads: u32,

    pub const references = .{ .frame = "FrameConstants", .water = "WaterRef" };
};

pub const ShadePush = extern struct {
    frame: u64,
    water: u64,
    depth_texture: u32,
    scene_texture: u32,
    quads: u32,

    pub const references = .{ .frame = "FrameConstants", .water = "WaterRef" };
};

pub const UnderwaterPush = extern struct {
    frame: u64,
    water: u64,
    depth_texture: u32,
    scene_texture: u32,

    pub const references = .{ .frame = "FrameConstants", .water = "WaterRef" };
};
