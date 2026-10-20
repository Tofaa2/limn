//! Local light constants, `FrameConstants.lights`. The shader struct is generated
//! from it by the build, so it imports nothing but the frame constants.
const frame_constants = @import("../../core/frame_constants.zig");
const invalid_id = frame_constants.invalid_id;

pub const LightConstants = extern struct {
    /// Arrays of `Light`, `Cluster` and `ShadowTile`.
    lights: u64 = 0,
    clusters: u64 = 0,
    shadow_tiles: u64 = 0,
    light_count: u32 = 0,
    /// Cluster depth slice = log2(view depth) * scale + bias.
    cluster_z_scale: f32 = 0,
    cluster_z_bias: f32 = 0,
    pad: u32 = 0,

    pub const references = .{ .lights = "Lights", .clusters = "Clusters", .shadow_tiles = "ShadowTiles" };
};

comptime {
    @import("std").debug.assert(@sizeOf(LightConstants) % 8 == 0);
}
