//! State and results shared between the passes of one view of a scene.
//! Internal to the renderer.
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
    /// See `gpu.FrameConstants.previous_transforms`.
    previous_transforms: u64,
    /// This frame's entity records in the frame arena, to be copied into the
    /// instance buffer.
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
    /// Address and count of the `Glowing` records in the frame arena, for
    /// path tracing to sample.
    glowing: u64,
    glowing_count: u32,
    bounds: [2]Vec3,
};

/// State shared by the passes of one view of a scene.
pub const ScenePass = struct {
    frame: rhi.Frame,
    cmd: *rhi.CommandEncoder,
    arena: *FrameArena,
    desc: ViewDesc,
    /// `desc.settings` with implied settings filled in.
    settings: Settings,
    scene_handle: Scene,
    scene: *SceneData,
    scene_frame: SceneFrame,
    /// True for the first view to draw the scene this frame, which also does
    /// the per-scene work.
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
    /// This frame's subpixel jitter, as a fraction of the picture.
    jitter: [2]f32 = .{ 0, 0 },
    view_proj: Mat4,
    view_proj_unjittered: Mat4,
    /// Direction the sun's light travels, normalized.
    sun_travel: Vec3,
    /// The scene has meshlets to draw.
    has_geometry: bool,
    occlusion: bool,
    /// Culling records which instances the camera draws.
    mark_seen: bool,
    /// Camera position (xyz) and LOD selection scale (w) for the camera pass.
    lod: [4]f32,
    /// Width of the LOD cross-fade band.
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
    /// Cascades in use.
    count: u32,
    /// Cascades redrawn this frame.
    update: [gpu.cascade_count]bool,
};

/// Result of `updateCascades`.
pub const CascadePlan = struct { count: u32, update: [gpu.cascade_count]bool };

/// What is redrawn of the local lights' shadow atlas for one view.
pub const LocalShadows = struct {
    draw: bool,
    /// The atlas holds the same lights in the same tiles as when last drawn,
    /// so unchanged tiles are kept.
    same_atlas: bool,
    key: u64,
    tile_dirty: [max_local_shadow_views]bool,
};

/// A frame's reflection probes as the shaders read them.
pub const ProbeList = struct { address: u64, count: u32 };

/// What the first round of culling leaves for later passes.
pub const CullState = struct {
    push: CullPush,
    /// Address of the frame's `gpu.CullView` records.
    views: u64,
    /// Cascades that leave out casters whose shadows the camera cannot see.
    receiver_culled: [gpu.cascade_count]bool,
};

/// Push constants of the meshlet passes: camera visibility and shadows.
pub const DrawPush = extern struct {
    frame: u64,
    /// 1 in a shadow pass whose see-through casters go into the tint
    /// instead of the depth.
    tinted: u32 = 0,
    /// Nonzero when `page` replaces `view_proj`.
    paged: u32 = 0,
    view_proj: Mat4,
    /// LOD cross-fade in the camera pass: camera and selection scale, band
    /// width, and near plane.
    lod: [4]f32 = .{ 0, 0, 0, 0 },
    lod_band: f32 = 1,
    lod_near: f32 = 0,
    /// With mesh shaders: the meshlet list for this draw and the address of
    /// its length.
    list: u64 = 0,
    count: u64 = 0,
    /// A page of the sun's virtual shadow map (`VisibilityPage` in
    /// visibility_page.glsl).
    page: u64 = 0,
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
    entity_refs: u32 = 0,
    candidates: u64 = 0,
    dispatch: u64 = 0,
    instance_visibility: u64 = 0,
    entity_instances: u32 = 0,
    masked_capacity: u32 = 0,
    seen_total: u32 = 0,
    mesh_lists: u32 = 0,
    mesh_draws: u64 = 0,
    lists: u64 = 0,
};

/// Push constants of cull_instances.comp.
pub const InstanceCullPush = extern struct {
    frame: u64,
    view: u64,
    instances: u64,
    candidates: u64,
    dispatch: u64,
    visibility: u64,
    instance_count: u32,
    phase: u32,
    hiz_texture: u32,
    entity_refs: u32,
    hiz_size: [2]f32,
    impostors: u64 = 0,
    impostor_list: u64 = 0,
    impostor_draw: u64 = 0,
    /// Nonzero for the camera's view, where small copies become impostors.
    impostor_view: u32 = 0,
    pad: u32 = 0,
};

/// A view's lights as the shaders read them and the shadow tiles assigned
/// to them; made by `prepareLights`.
pub const Lighting = struct {
    lights: u64,
    tiles: u64,
    light_count: u32,
    /// Hash of which lights were given shadow tiles.
    tiles_key: u64 = 0,
    tile_count: u32,
    tile_view_proj: [max_local_shadow_views]Mat4,
    tile_views: [max_local_shadow_views]gpu.CullView,
};
