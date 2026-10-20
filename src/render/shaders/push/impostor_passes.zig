//! Push constants of the passes in impostor_passes.slang. The build writes each
//! struct as `impostor_passes.<Name>.slang`, which the shader includes.

pub const DrawPush = extern struct {
    frame: u64,
    impostors: u64,
    instances: u64,
    list: u64,
    entity_instances: u32,

    pub const references = .{ .frame = "FrameConstants", .impostors = "Impostor*", .instances = "StaticCull*", .list = "uint*" };
};

pub const ShadePush = extern struct {
    frame: u64,
    impostors: u64,
    instances: u64,
    list: u64,
    entity_instances: u32,

    pub const references = .{ .frame = "FrameConstants", .impostors = "Impostor*", .instances = "StaticCull*", .list = "uint*" };
};

pub const BakePush = extern struct {
    frame: u64,
    node: [16]f32,
    center: [3]f32,
    radius: f32,
    right: [3]f32,
    vertex_offset: u32,
    up: [3]f32,
    material: u32,
    toward: [3]f32,
    pad: f32 = 0,

    pub const references = .{ .frame = "FrameConstants" };
};
