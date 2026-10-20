//! Push constants of the passes in environment.slang. The build writes each
//! struct as `environment.<Name>.slang`, which the shader includes.
const clouds = @import("../../features/constants/clouds.zig");

pub const CubePush = extern struct {
    source_texture: u32,
    sampler_index: u32,
    face: u32,
    max_radiance: f32,
    from_cube: u32,
    to_sun: [3]f32,
    sunlight: [3]f32,
    clouds: clouds.Clouds,

    pub const references = .{ .clouds = "CloudData" };
};

pub const IrradiancePush = extern struct {
    source_texture: u32,
    sampler_index: u32,
    face: u32,
    source_size: f32,
};

pub const PrefilterPush = extern struct {
    source_texture: u32,
    sampler_index: u32,
    face: u32,
    source_size: f32,
    roughness: f32,
};

pub const SkyPush = extern struct {
    to_sun: [3]f32,
    face: u32,
    ground_color: [3]f32,
    turbidity: f32,
    intensity: f32,
    max_radiance: f32,
    sun_disc: f32,
    stars: f32,
    to_moon: [3]f32,
    moon: f32,
    ozone: f32,
    clouds: clouds.Clouds,

    pub const references = .{ .clouds = "CloudData" };
};

pub const ProbeFacePush = extern struct {
    source_texture: u32,
    sampler_index: u32,
    face: u32,
    max_radiance: f32,
    right: [3]f32,
    up: [3]f32,
    forward: [3]f32,
};
