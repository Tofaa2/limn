//! Push constants of the passes in vsm_passes.slang. The build writes each
//! struct as `vsm_passes.<Name>.slang`, which the shader includes.

pub const MarkPush = extern struct {
    frame: u64,
    vsm: u64,
    depth_texture: u32,
    pad: u32 = 0,

    pub const references = .{ .frame = "FrameConstants", .vsm = "VsmData*" };
};

pub const AllocatePush = extern struct {
    frame: u64,
    vsm: u64,
    views: u64,
    first_page_view: u32,
    pad: u32 = 0,

    pub const references = .{ .frame = "FrameConstants", .vsm = "VsmData*", .views = "uint*" };
};

pub const ClearPush = extern struct {
    page_views: u64,

    pub const references = .{ .page_views = "VsmPageView*" };
};
