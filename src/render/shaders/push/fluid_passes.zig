//! Push constants of the passes in fluid_passes.slang. The build writes each
//! struct as `fluid_passes.<Name>.slang`, which the shader includes.

pub const AdvectPush = extern struct {
    fluid: u64,
    velocity_texture: u32 = 0,
    scalars_texture: u32 = 0,
    carried_texture: u32 = 0,
    carried_velocity_texture: u32 = 0,

    pub const references = .{ .fluid = "FluidRef" };
};

pub const CarryPush = extern struct {
    fluid: u64,
    velocity_texture: u32 = 0,
    scalars_texture: u32 = 0,

    pub const references = .{ .fluid = "FluidRef" };
};

pub const CurlPush = extern struct {
    fluid: u64,
    velocity_texture: u32 = 0,

    pub const references = .{ .fluid = "FluidRef" };
};

pub const DivergencePush = extern struct {
    fluid: u64,
    velocity_texture: u32 = 0,

    pub const references = .{ .fluid = "FluidRef" };
};

pub const ForcePush = extern struct {
    fluid: u64,
    velocity_texture: u32 = 0,
    scalars_texture: u32 = 0,
    curl_texture: u32 = 0,

    pub const references = .{ .fluid = "FluidRef" };
};

pub const PressurePush = extern struct {
    fluid: u64,
    pressure_texture: u32 = 0,
    divergence_texture: u32 = 0,

    pub const references = .{ .fluid = "FluidRef" };
};

pub const ProjectPush = extern struct {
    fluid: u64,
    velocity_texture: u32 = 0,
    pressure_texture: u32 = 0,

    pub const references = .{ .fluid = "FluidRef" };
};

pub const SolidPush = extern struct {
    fluid: u64,
    /// The scene's acceleration structure, as two halves so that shaders
    /// that do not trace need no 64-bit integers.
    tlas_low: u32,
    tlas_high: u32,

    pub const references = .{ .fluid = "FluidRef" };
};

pub const LightPush = extern struct {
    fluid: u64,
    lights: u64,
    index: u32,
    scale: f32,
    tall: f32,

    pub const references = .{ .fluid = "FluidRef", .lights = "Light*" };
};

pub const PresentPush = extern struct {
    fluid: u64,

    pub const references = .{ .fluid = "FluidRef" };
};

pub const MotionPush = extern struct {
    frame: u64,
    source_texture: u32,

    pub const references = .{ .frame = "FrameConstants" };
};

pub const VolumePush = extern struct {
    frame: u64,
    depth_texture: u32,
    count: u32,
    steps: i32,
    light_steps: i32,
    motion: u32,
    motion_pad: u32,
    fluids: [8]u64,

    pub const references = .{ .frame = "FrameConstants", .fluids = "FluidRef" };
};
