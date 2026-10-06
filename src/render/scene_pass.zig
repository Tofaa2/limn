//! What the passes of one view of a scene hand each other: the state they
//! all read, and the results one leaves for the next. Internal to the
//! renderer; nothing here is part of the library's API.
const rhi = @import("../rhi/rhi.zig");
const math = @import("../math.zig");
const gpu = @import("gpu.zig");
const render = @import("renderer.zig");

const Mat4 = math.Mat4;
const Vec3 = math.Vec3;
const Scene = render.Scene;
const Settings = render.Settings;
const ViewDesc = render.ViewDesc;
const FrameArena = render.FrameArena;
const SceneData = render.SceneData;
const ViewData = render.ViewData;
const ViewState = render.ViewState;
const Cascades = render.Cascades;
const max_local_shadow_views = render.max_local_shadow_views;

/// What `prepareScene` leaves for the views that draw a scene this frame.
pub const SceneFrame = struct {
    instances: u64,
    /// Where this frame's entity records wait in the frame arena to be
    /// copied into the instance buffer.
    staged_buffer: rhi.Buffer,
    staged_instances: u64,
    staged_size: u64,
    joints: u64,
    skinned_vertices: u32,
    any_moving: bool,
    /// Ray-tracing instances for the static geometry, and its bounds.
    tlas_instances: u64,
    tlas_count: u32,
    tlas_hash: u64,
    /// The instances that glow evenly, for path tracing to aim at
    /// (`Glowing` records in the frame arena), and how many.
    glowing: u64,
    glowing_count: u32,
    bounds: [2]Vec3,
};

/// What the passes of one view of a scene share: where they record,
/// the scene as prepared for this frame, the view's targets and
/// settings, and the camera.
pub const ScenePass = struct {
    frame: rhi.Frame,
    cmd: *rhi.CommandEncoder,
    arena: *FrameArena,
    desc: ViewDesc,
    /// `desc.settings`, with what one setting implies for another
    /// filled in.
    settings: Settings,
    scene_handle: Scene,
    scene: *SceneData,
    scene_frame: SceneFrame,
    /// True for the first view to draw the scene this frame, which
    /// also does the work that belongs to the scene.
    fresh_scene: bool,
    view_data: *ViewData,
    view: *ViewState,
    /// Size the scene is rendered at.
    width: u32,
    height: u32,
    /// Size of the area of the target the view fills.
    output_width: u32,
    output_height: u32,
    delta_time: f32,
    /// A debug view is shown: effects that would hide it are left out.
    debugging: bool,
    aspect: f32,
    view_matrix: Mat4,
    proj_unjittered: Mat4,
    view_proj: Mat4,
    view_proj_unjittered: Mat4,
    /// The way the sun's light travels, normalized.
    sun_travel: Vec3,
    /// The scene has meshlets to draw.
    has_geometry: bool,
    occlusion: bool,
    /// The culling records which instances the camera draws.
    mark_seen: bool,
    /// How levels of detail are chosen in the camera's own pass: the
    /// camera's position and the scale they are chosen by.
    lod: [4]f32,
    /// The band over which two levels of detail cross-fade.
    lod_band: f32,
    /// Address of the frame constants; 0 until they have been written.
    frame_address: u64 = 0,
};

/// The sun's shadow cascades for one view of a frame.
pub const SunShadows = struct {
    enabled: bool,
    /// See-through casters tint the light that passes them.
    colored: bool,
    map: rhi.Texture,
    cascades: Cascades,
    /// How many of the cascades are in use.
    count: u32,
    /// The cascades that are redrawn this frame.
    update: [gpu.cascade_count]bool,
};

/// Which cascades `updateCascades` chose to redraw, and how many are in use.
pub const CascadePlan = struct { count: u32, update: [gpu.cascade_count]bool };

/// What is redrawn of the local lights' shadow atlas for one view.
pub const LocalShadows = struct {
    draw: bool,
    /// The atlas holds the same lights in the same tiles as when it
    /// was last drawn, so tiles that did not change are kept.
    same_atlas: bool,
    key: u64,
    tile_dirty: [max_local_shadow_views]bool,
};

/// A frame's reflection probes as the shaders read them.
pub const ProbeList = struct { address: u64, count: u32 };

/// What the first round of culling leaves for the passes after it.
pub const CullState = struct {
    push: CullPush,
    /// Address of the frame's `gpu.CullView` records.
    views: u64,
    /// Cascades that leave out casters whose shadows the camera cannot see.
    receiver_culled: [gpu.cascade_count]bool,
};

/// Push constants of the passes that draw meshlets: the camera's
/// visibility pass and the shadow passes.
pub const DrawPush = extern struct {
    frame: u64,
    /// 1 in a shadow pass whose see-through casters go into the tint
    /// instead of the depth.
    tinted: u32 = 0,
    pad1: u32 = 0,
    view_proj: Mat4,
    /// For cross-fading levels of detail in the camera's own
    /// pass: the camera and scale they are chosen by, the width
    /// of the band, and the near plane.
    lod: [4]f32 = .{ 0, 0, 0, 0 },
    lod_band: f32 = 1,
    lod_near: f32 = 0,
    pad2: [2]u32 = .{ 0, 0 },
};

/// Push constants of the culling pass, for one view at a time.
pub const CullPush = extern struct {
    frame: u64,
    view: u64,
    commands: u64,
    counts: u64,
    visibility: u64,
    ref_count: u32,
    bucket_capacity: u32,
    phase: u32,
    hiz_texture: u32,
    hiz_size: [2]f32,
    skin_bounds: u64,
    seen: u64,
    mark_seen: u32 = 0,
    pad: u32 = 0,
};

/// A view's lights as the shaders read them, and the shadow tiles given to
/// the ones that cast shadows; made by `prepareLights`.
pub const Lighting = struct {
    lights: u64,
    tiles: u64,
    light_count: u32,
    /// Which lights were given shadow tiles, as a hash.
    tiles_key: u64 = 0,
    tile_count: u32,
    tile_view_proj: [max_local_shadow_views]Mat4,
    tile_views: [max_local_shadow_views]gpu.CullView,
};
