//! Push constants of the passes in pathtrace.slang. The build writes each
//! struct as `pathtrace.<Name>.slang`, which the shader includes.

pub const Push = extern struct {
    frame: u64,
    scene: u64,
    scene_instances: u64,
    mesh_nodes: u64,
    mesh_items: u64,
    gathered: u32,
    bounces: u32,
    samples: u32,
    clamp_radiance: f32,
    sun_radius: f32,
    light_count: u32,
    glowing: u64,
    glowing_count: u32,
    moved: u32,
    previous_camera: [3]f32,
    centered: u32,
    history_facing: u32,
    history_reservoir: u32,
    reusable: u32,
    motion: u32,
    depth: u32,
    probes: u32,
    reconstructed: u32,
    pad: u32 = 0,
    /// Compute only: the storage images the fields of `Output` and then
    /// of `Guides` go to, in order.
    targets: u64,

    pub const references = .{ .frame = "FrameConstants", .scene = "SceneTree", .scene_instances = "SceneInstances", .mesh_nodes = "SceneTree", .mesh_items = "MeshItems", .glowing = "Glowing*", .targets = "uint*" };
};
