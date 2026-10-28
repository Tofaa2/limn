//! Push constants of the passes in ocean.slang. The build writes each
//! struct as `ocean.<Name>.slang`, which the shader includes.

pub const Push = extern struct {
    /// Rows transformed by the first pass, `ocean_cells` squared complex
    /// values, and the heights the second pass writes.
    rows: u64,
    heights: u64,
    time: f32,
    /// Side of the tile in world units, and the height scale.
    period: f32,
    scale: f32,
    wind_speed: f32,
    wind_direction: [2]f32,

    pub const references = .{ .rows = "float2*", .heights = "float*" };
};
