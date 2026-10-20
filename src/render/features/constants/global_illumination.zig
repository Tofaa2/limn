//! Irradiance probe constants, `FrameConstants.gi`. The shader struct is generated
//! from it by the build, so it imports nothing but the frame constants.
const frame_constants = @import("../../core/frame_constants.zig");
const invalid_id = frame_constants.invalid_id;

/// Most grids of irradiance probes a scene is lit by at once.
pub const gi_cascade_max = 4;

/// One grid of irradiance probes. 48 bytes.
pub const GiCascade = extern struct {
    /// World position of the first probe.
    origin: [3]f32 = .{ 0, 0, 0 },
    spacing: f32 = 1,
    /// Probes per axis.
    counts: [3]i32 = .{ 2, 2, 2 },
    /// The atlases.
    irradiance: u32 = invalid_id,
    visibility: u32 = invalid_id,
    /// Where the grid's first cell is stored, 10 bits per axis.
    scroll: u32 = 0,
    /// Per-probe offsets off the grid, or `invalid_id`.
    offsets: u32 = invalid_id,
    pad: u32 = 0,
};

pub const GiConstants = extern struct {
    /// The irradiance probe grids (gi.slang), finest first: each is blended
    /// into the next where it ends.
    gi_cascades: [gi_cascade_max]GiCascade = @splat(.{}),
    /// Cascades of `gi_cascades` in use.
    gi_cascade_count: u32 = 0,
    gi_intensity: f32 = 1,
    /// 1 when the probe grids are valid.
    enabled: u32 = 0,
    /// 1 when probes gather light from local lights as well as the sun and sky.
    local_lights: u32 = 0,
    /// Local lights a probe ray samples, 1 to 1023.
    bounce_lights: u32 = 1,
    pad: u32 = 0,
};

comptime {
    @import("std").debug.assert(@sizeOf(GiConstants) % 8 == 0);
}
