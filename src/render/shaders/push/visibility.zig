//! Push constants of the passes in visibility.slang. The build writes each
//! struct as `visibility.<Name>.slang`, which the shader includes.

pub const VisibilityPush = extern struct {
    frame: u64,

    pub const references = .{ .frame = "FrameConstants" };
};

/// Push constants of the meshlet passes: camera visibility and shadows.
pub const GeometryPush = extern struct {
    frame: u64,
    /// 1 in a shadow pass whose translucent casters go into the tint pass.
    tinted: u32 = 0,
    /// Nonzero when `page` supplies the view.
    paged: u32 = 0,
    view_proj: [16]f32,
    /// LOD cross-fade, main camera pass only: LOD camera (xyz), error-to-pixels
    /// scale (w), band width (1 for none) and near plane.
    lod: [4]f32 = .{ 0, 0, 0, 0 },
    lod_band: f32 = 1,
    lod_near: f32 = 0,
    /// Meshlet references written by cull.slang, and their count.
    list: u64 = 0,
    count: u64 = 0,
    /// A page of the sun's virtual shadow map (`VisibilityPage` in
    /// visibility_page.slang).
    page: u64 = 0,

    pub const references = .{ .frame = "FrameConstants", .list = "uint*", .count = "uint*", .page = "VisibilityPage" };
};
