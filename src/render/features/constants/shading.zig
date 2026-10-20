//! Surface shading constants, `FrameConstants.shading`. The shader struct is generated
//! from it by the build, so it imports nothing but the frame constants.
const frame_constants = @import("../../core/frame_constants.zig");
const invalid_id = frame_constants.invalid_id;

pub const ShadingConstants = extern struct {
    /// Addresses of the `Decal` and `ReflectionProbe` arrays; 0 for none.
    decals: u64 = 0,
    probes: u64 = 0,
    decal_count: u32 = 0,
    probe_count: u32 = 0,
    /// Haze per world unit; 0 for none.
    aerial: f32 = 0,
    /// 1 when roughness is raised where normals vary within a pixel.
    specular_aa: u32 = 0,

    pub const references = .{ .decals = "Decals", .probes = "ReflectionProbes" };
};

comptime {
    @import("std").debug.assert(@sizeOf(ShadingConstants) % 8 == 0);
}
