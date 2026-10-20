//! Views, frames and application passes.
const rhi = @import("../../rhi/rhi.zig");
const render = @import("../renderer.zig");

const Mat4 = render.Mat4;
const Vec3 = render.Vec3;

const api = @import("../api.zig");
const Camera = api.Camera;
const DrawList = api.DrawList;
const Entity = api.Entity;
const InstanceGroup = api.InstanceGroup;
const Options = api.Options;
const Scene = api.Scene;
const Settings = api.Settings;
const Stats = api.Stats;
const Transparency = api.Transparency;
const View = api.View;

/// Where a view's picture goes; see `ViewDesc.target`.
pub const Target = union(enum) {
    /// The window surface passed in `Options.surface`.
    backbuffer,
    /// Any color texture created with `.color_attachment` usage.
    texture: rhi.Texture,
};

/// A rectangle of a target, in pixels from the top-left corner.
pub const Region = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

/// Points in a view's frame where a `Pass` can run.
pub const PassStage = enum {
    /// Opaque surfaces are lit. `color` is the HDR scene color, `depth` the
    /// scene depth.
    after_opaque,
    /// Transparency and fog are in; still HDR, before antialiasing, bloom and
    /// exposure.
    after_transparency,
    /// Antialiased and at output size; still HDR, before lens effects, bloom
    /// and exposure.
    after_resolve,
    /// Tone-mapped: `color` is the view's output in display colors. Draw lists
    /// come after.
    after_tonemap,
};

/// What a `Pass` is given. Textures are in the shader-read state;
/// `cmd.beginRendering` moves them to attachments and the renderer restores
/// them afterwards.
pub const PassContext = struct {
    cmd: *rhi.CommandEncoder,
    device: *rhi.Device,
    stage: PassStage,
    /// GPU address of this view's `FrameConstants` (see `shaders/common.slang`);
    /// 0 on a view without a scene that draws nothing before tone mapping.
    frame: u64,
    color: rhi.Texture,
    color_format: rhi.Format,
    /// Reverse-Z scene depth (near plane at 1, far at 0). Null on a view
    /// without a scene.
    depth: ?rhi.Texture,
    /// Screen-space motion vectors; write them for geometry that moves.
    /// Null on a view without a scene.
    motion: ?rhi.Texture,
    /// The visibility buffer (instance and triangle of each pixel), when a
    /// pass of this stage reads `.visibility`.
    visibility: ?rhi.Texture = null,
    /// Ambient occlusion, when a pass of this stage reads
    /// `.ambient_occlusion` and the view has it.
    ambient_occlusion: ?rhi.Texture = null,
    width: u32,
    height: u32,
    camera: Camera,
    /// World to view, view to clip with this frame's jitter, and both.
    view: Mat4,
    projection: Mat4,
    view_projection: Mat4,
    /// The view's settings as it got them; see `Stats.downgraded`.
    settings: *const Settings,
};

/// Application code run at a `PassStage`, while the frame is recorded with the
/// renderer locked: it must not call back into the `Renderer`. On a view
/// without a scene the stages before tone mapping run together, after the
/// draw lists of `DrawStage.scene`.
/// A texture of the view a `Pass` can read.
pub const PassRead = enum { depth, motion, visibility, ambient_occlusion };

pub const Pass = struct {
    stage: PassStage,
    /// What the pass samples besides `PassContext.color`: the passes that
    /// make them run first, and they are readable when it runs.
    reads: []const PassRead = &.{},
    context: ?*anyopaque = null,
    run: *const fn (context: ?*anyopaque, pass: PassContext) anyerror!void,
};

/// Format of `PassContext.color` before tone mapping.
pub const scene_color_format: rhi.Format = .rgba16_float;

/// What was found under a pixel.
pub const Pick = struct {
    /// The entity hit, or `.invalid` when it was a copy in an instance group.
    entity: Entity,
    /// The instance group and which of its copies was hit, if it was one.
    instances: ?InstanceGroup = null,
    copy: u32 = 0,
    /// Index of the hit mesh instance within the entity's model.
    mesh_instance: u32,
    /// World-space point on the surface.
    position: Vec3,
    /// Distance from the camera plane.
    distance: f32,
};

/// When in a view's frame a draw list is drawn; see `DrawLayer`.
pub const DrawStage = enum {
    /// Under the scene: into the HDR picture where no surface is, after the
    /// sky and before transparent surfaces, lit and graded like the scene.
    /// In a view without a scene, drawn before the lists drawn as a scene.
    under,
    /// Into the picture before lens effects, bloom, exposure and tone
    /// mapping, so it is lit and graded like a scene. A view without a
    /// scene gets those effects when any of its lists is drawn here, and
    /// needs a `View` of its own.
    scene,
    /// Over the finished picture, in the colors given.
    overlay,
};

/// A draw list and when it is drawn; see `ViewDesc.draw_lists`.
pub const DrawLayer = struct {
    list: *const DrawList,
    stage: DrawStage = .overlay,
};

/// One camera's picture: what to draw, from where, and where it goes.
pub const ViewDesc = struct {
    /// Persistent view state to use; null is the built-in main view. Every
    /// camera drawn in the same frame needs its own `View`.
    view: ?View = null,
    /// Null for a purely 2D view.
    scene: ?Scene = null,
    /// Drawn in order within each stage. The lists must not be modified
    /// until `render` returns.
    draw_lists: []const DrawLayer = &.{},
    /// Background without a scene, linear RGBA. Only the first view drawn to a
    /// target in a frame clears it.
    clear_color: [4]f32 = .{ 0, 0, 0, 1 },
    camera: Camera = .{},
    target: Target = .backbuffer,
    /// Part of the target to draw into; null covers it all.
    region: ?Region = null,
    passes: []const Pass = &.{},
    settings: Settings = .{},
};

/// Everything `Renderer.render` draws in one frame.
pub const FrameDesc = struct {
    /// Drawn in order. A view may draw into a texture a later view shows (see
    /// `Renderer.views.targetImage`).
    views: []const ViewDesc,
    /// Seconds since the previous frame.
    delta_time: f32 = 1.0 / 60.0,
};
