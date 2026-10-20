//! Push constants of the passes in hair.slang. The build writes each
//! struct as `hair.<Name>.slang`, which the shader includes.

/// How a hair is drawn: its colours, widths and grooming, and the grid of
/// light inside it.
pub const HairLook = extern struct {
    /// Per grid cell: fibres the sunlight crosses to reach it, how far it
    /// travels through them, and the share of open sky round it.
    light: u64,
    root_color: [3]f32,
    root_width: f32,
    tip_color: [3]f32,
    tip_width: f32,
    grid_low: [3]f32,
    grid_cell: f32,
    roughness: f32,
    variation: f32,
    spread: f32,
    clump: f32,
    curl: f32,
    curl_turns: f32,
    frizz: f32,
    points_per_strand: u32,
    grid_size: u32,
    pad0: u32 = 0,
    pad1: u32 = 0,
    pad2: u32 = 0,

    pub const references = .{ .light = "float4*" };
};

/// Push constants of the hair strand passes.
pub const HairPush = extern struct {
    frame: u64,
    points: u64,
    previous_points: u64,
    look: u64,
    transform: [16]f32,
    previous_transform: [16]f32,

    pub const references = .{ .frame = "FrameConstants", .points = "HairPoint*", .previous_points = "HairPoint*", .look = "HairLook*" };
};

pub const SimPush = extern struct {
    frame: u64,
    params: u64,

    pub const references = .{ .frame = "FrameConstants", .params = "Params*" };
};

pub const ShadowPush = extern struct {
    frame: u64,
    points: u64,
    page: u64,
    look: u64,
    view_proj: [16]f32,
    transform: [16]f32,
    light: [3]f32,
    least_width: f32,
    paged: u32,
    pad0: u32 = 0,
    pad1: u32 = 0,
    pad2: u32 = 0,

    pub const references = .{ .frame = "FrameConstants", .points = "HairPoint*", .page = "VisibilityPage", .look = "HairLook*" };
};

/// Counts the points of a hair into the cells of its grid.
pub const CountPush = extern struct {
    points: u64,
    counts: u64,
    transform: [16]f32,
    grid_low: [3]f32,
    grid_cell: f32,
    point_count: u32,
    grid_size: u32,
    pad0: u32 = 0,
    pad1: u32 = 0,

    pub const references = .{ .points = "HairPoint*", .counts = "uint*" };
};

/// Works out how much light reaches each cell of a hair's grid.
pub const LightPush = extern struct {
    counts: u64,
    light: u64,
    to_sun: [3]f32,
    /// Fibres crossed per point counted in a cell, per world unit travelled.
    fibre: f32,
    grid_cell: f32,
    grid_size: u32,
    pad0: u32 = 0,
    pad1: u32 = 0,

    pub const references = .{ .counts = "uint*", .light = "float4*" };
};
