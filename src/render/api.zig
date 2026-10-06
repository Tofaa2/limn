//! What an application gives the renderer and gets back from it: handles,
//! options, the descriptions things are made from, per-view settings and
//! statistics. `root.zig` re-exports the parts that are the library's API.
const std = @import("std");
const rhi = @import("../rhi/rhi.zig");
const math = @import("../math.zig");
const gltf = @import("../asset/gltf.zig");
const ktx2 = @import("../asset/ktx2.zig");
const texture_codec = @import("texture_codec");
const shader_sources = @import("shader_sources");
const png = @import("../png.zig");
const gpu = @import("gpu.zig");
const animation = @import("animation.zig");
const bvh = @import("bvh.zig");
const handle = @import("../handle.zig");
const draw_list = @import("draw_list.zig");
const font_module = @import("font_baker").font;
const text_layout = @import("text_layout.zig");
const render = @import("renderer.zig");

const Mat4 = render.Mat4;
const Vec3 = render.Vec3;
const bloom_levels = render.bloom_levels;
const local_shadow_tiles_per_side = render.local_shadow_tiles_per_side;

/// Marker type that makes `Model` a distinct handle type.
pub const ModelTag = opaque {};
/// Marker type that makes `Environment` a distinct handle type.
pub const EnvironmentTag = opaque {};
/// Marker type that makes `Scene` a distinct handle type.
pub const SceneTag = opaque {};
/// Marker type that makes `Entity` a distinct handle type.
pub const EntityTag = opaque {};
/// Marker type that makes `View` a distinct handle type.
pub const ViewTag = opaque {};
/// Marker type that makes `Emitter` a distinct handle type.
pub const EmitterTag = opaque {};
/// Marker type that makes `ReflectionProbe` a distinct handle type.
pub const ReflectionProbeTag = opaque {};
/// Marker type that makes `Fluid` a distinct handle type.
pub const FluidTag = opaque {};
/// Marker type that makes `Water` a distinct handle type.
pub const WaterTag = opaque {};
/// Marker type that makes `Liquid` a distinct handle type.
pub const LiquidTag = opaque {};
/// Marker type that makes `InstanceGroup` a distinct handle type.
pub const InstanceGroupTag = opaque {};
/// Geometry, materials and animations shared by any number of entities;
/// see `Renderer.loadModel` and `Renderer.createModel`. Like every handle
/// here it is a 32-bit value, free to copy, that stops resolving once the
/// thing it names is destroyed: calls given a stale handle do nothing or
/// return an error instead of touching whatever reused the slot.
pub const Model = handle.Handle(ModelTag);
/// A sky and the image-based lighting made from it; see
/// `Renderer.loadEnvironment` and `Renderer.setEnvironment`.
pub const Environment = handle.Handle(EnvironmentTag);
/// A world of entities, lights and effects that views draw; see
/// `Renderer.createScene`.
pub const Scene = handle.Handle(SceneTag);
/// One placement of a model in a scene; see `Renderer.spawn`.
pub const Entity = handle.Handle(EntityTag);
/// Per-camera state that persists between frames.
pub const View = handle.Handle(ViewTag);
/// A particle emitter in a scene.
pub const Emitter = handle.Handle(EmitterTag);
/// A local reflection probe in a scene.
pub const ReflectionProbe = handle.Handle(ReflectionProbeTag);
/// A box of simulated smoke and fire in a scene; see `Renderer.createFluid`.
pub const Fluid = handle.Handle(FluidTag);
/// A sheet of simulated water in a scene; see `Renderer.createWater`.
pub const Water = handle.Handle(WaterTag);
/// A body of particle-simulated liquid in a scene; see
/// `Renderer.createLiquid`.
pub const Liquid = handle.Handle(LiquidTag);
/// Many copies of one model; see `Renderer.createInstances`.
pub const InstanceGroup = handle.Handle(InstanceGroupTag);
/// Which animation clips an entity plays and how far into them it is; see
/// `Renderer.setPose`.
pub const Pose = animation.Pose;
/// Application-supplied geometry for `Renderer.createModel`.
pub const MeshDesc = gltf.MeshDesc;
/// Surface description of a mesh, as imported from glTF or given in a
/// `MeshDesc`.
pub const Material = gltf.Material;
/// Collects 2D shapes, images and text for a view to draw over its picture.
pub const DrawList = draw_list.DrawList;
/// A texture that draw lists, lights and settings can refer to; see
/// `Renderer.createImage` and `Renderer.loadImage`.
pub const Image = draw_list.Image;
/// A font baked into a distance-field atlas; see `Renderer.loadFont`.
pub const Font = font_module.Font;

/// Choices made when the renderer is created (`Renderer.init`). They stay
/// fixed for its lifetime; what can change from frame to frame is in
/// `Settings`.
pub const Options = struct {
    /// Name reported to the Vulkan driver.
    application_name: [:0]const u8 = "limn",
    /// Vulkan validation layers, including synchronization validation.
    /// Meant for development; requires the Khronos layers to be installed.
    validation: bool = false,
    /// Window to present to. Null renders offscreen only.
    surface: ?rhi.Surface = null,
    /// Part of the name of the GPU to prefer on a machine with several.
    preferred_device: ?[]const u8 = null,
    /// File the driver's pipeline cache is kept in between runs, so later
    /// starts compile fewer shaders. Null keeps none.
    pipeline_cache_path: ?[]const u8 = null,
    /// Name GPU objects and label passes for debuggers such as RenderDoc,
    /// without turning validation on. Where the driver has no
    /// `VK_EXT_debug_utils`, this does nothing.
    debug_names: bool = false,
    /// Ask for an HDR10 window surface. If the display or driver has none,
    /// the window stays SDR; `Renderer.hdrActive` tells which it is.
    hdr_output: bool = false,
    /// Use the GPU's ray tracing where it has it. False does without
    /// even there: no ray-traced reflections, shadows or bounce light,
    /// and path tracing follows its rays in an ordinary shader. Meant
    /// for comparing the two and for testing the second.
    ray_tracing: bool = true,
    /// Path tracing on a GPU without ray tracing: build for every model as
    /// it loads what `Settings.path_tracing` needs to follow rays in a
    /// shader (a tree over its triangles). Off by default, since it costs
    /// loading time and a few bytes a triangle whether or not anything
    /// is ever path traced; without it path tracing does nothing on such
    /// a GPU. Has no effect where the GPU traces rays itself.
    path_tracing_fallback: bool = false,
    /// Called around the renderer's CPU work, for a profiler such as
    /// Tracy; see `Profiler`.
    profiler: ?Profiler = null,
    /// Size of each of the four sun shadow cascades, in texels per side.
    shadow_resolution: u32 = 2048,
    /// Size of the atlas shared by spot and point light shadows; it holds
    /// 16 tiles, so each tile is a quarter of this per side.
    local_shadow_resolution: u32 = 2048,
    /// Anisotropic filtering for color and normal maps (1 disables).
    texture_anisotropy: f32 = 8,
    /// Anisotropic filtering for roughness/metalness, occlusion and
    /// emissive maps. 1 is noticeably cheaper per pixel.
    data_texture_anisotropy: f32 = 1,
    /// Most probes along X, Y and Z in one light probe grid. More covers a
    /// scene at a finer spacing; cost and memory grow with the product.
    gi_max_probes: [3]u32 = .{ 24, 12, 24 },
    /// The local-light shadow atlas is divided into this many tiles per
    /// side, 1..4: 4 gives 16 tiles (a spot light uses one, a point light
    /// six), 2 gives four tiles of four times the resolution each.
    local_shadow_tiles_per_side: u32 = 4,
    /// How material textures are stored on the GPU. `.bc7` uses a quarter of
    /// the memory of `.none` and filters faster, at a small loss of detail
    /// in blocks that mix unrelated colors; `.none` keeps every texel
    /// exact. Falls back to `.none` on hardware without BC formats.
    texture_compression: TextureCompression = .bc7,
    /// With compression on, store normal maps as BC5: two channels at far
    /// higher precision than BC7 gives them, the third rebuilt when
    /// shading. False keeps them in BC7 like every other texture.
    normal_maps_bc5: bool = true,
    /// Directory for processed assets (compressed textures), so later runs
    /// skip decoding and encoding. Null processes everything on each load.
    asset_cache_dir: ?[]const u8 = null,
    /// Size the asset cache is trimmed to when the renderer starts, oldest
    /// files first; 0 never deletes anything. See `trimAssetCache`.
    asset_cache_max_bytes: u64 = 0,
    /// Allocator for work done on worker threads: decoding models and
    /// environments, and the models that result. It must be safe to use
    /// from several threads at once. Null uses a general-purpose one.
    job_allocator: ?std.mem.Allocator = null,
    /// Build the shading pass again for each set of optional features a
    /// view uses (local lights, sized lamps, traced light shadows, smoke
    /// and cloud shadows, decals), leaving the rest out: code that never
    /// runs still slows a shader down. Each build is compiled on a worker
    /// thread while the full pass stands in, so nothing stalls; false
    /// always uses the full pass.
    shader_variants: bool = true,
    /// Work out the bounds of every meshlet of skinned and morphed meshes
    /// on the GPU each frame, after they are deformed, so that animated
    /// characters are culled piece by piece (frustum, occlusion, shadow
    /// views) instead of as one sphere each. Costs a pass over their
    /// triangles; worth it for large or many characters that are often
    /// partly hidden.
    skinned_meshlet_bounds: bool = false,
    /// Build levels of detail as a hierarchy of clusters (after Nanite):
    /// every meshlet-sized piece of a mesh picks its own level by its own
    /// distance, and neighbouring pieces of different levels still meet
    /// exactly. A large mesh the camera stands inside, which whole-mesh
    /// levels can never coarsen, is then coarse far away and fine close
    /// by. Meshes of fewer than about eight thousand triangles, which gain
    /// nothing from it, and skinned meshes keep whole-mesh levels.
    cluster_lods: bool = true,
    /// How much a change of normals counts when levels of detail are
    /// built: higher keeps shading closer to the full mesh at the price
    /// of levels that switch later; 0 looks at shape alone. See
    /// `gltf.LodOptions.normal_weight`.
    lod_normal_weight: f32 = gltf.default_lod_normal_weight,
    /// How much texture sliding over the surface counts when levels of
    /// detail are built: 1 treats a texture moved by some distance as a
    /// shape error of that distance, 0 ignores it.
    lod_uv_weight: f32 = gltf.default_lod_uv_weight,
    /// Threads that animated entities' poses are worked out on, counting
    /// the one that renders: 0 picks by the machine (at most 8), 1 never
    /// uses another thread. More than one is only used for scenes with
    /// enough animated entities to be worth it.
    pose_threads: u32 = 0,
    /// Put skinned and morphed meshes into the ray-tracing structure, so
    /// animated characters block and bounce probe light and show in
    /// ray-traced reflections. Costs one structure build per such mesh per
    /// frame. False leaves them out, as static-only GI.
    gi_dynamic_geometry: bool = true,
    /// How many of those structures are brought up to date each frame; 0
    /// for all of them. With a limit they take turns, so in a crowd each
    /// character's shape as rays see it lags its pose by a few frames,
    /// for a fraction of the cost. New ones are always built at once.
    gi_dynamic_refits: u32 = 0,
    /// Instance groups join the ray-tracing structure (blocking and
    /// bouncing probe light, showing in ray-traced reflections) while a
    /// scene holds at most this many group instances; larger scenes leave
    /// them out. 0 always leaves them out.
    gi_instance_limit: u32 = 65536,
    /// Loads texture detail by distance instead of all at once. Null keeps
    /// every texture fully loaded.
    texture_streaming: ?TextureStreaming = null,
    /// Keeps a model's geometry on the GPU only while something drawn
    /// with it is near a camera: its room in the vertex and index pools is
    /// handed to other models and its ray-tracing structures are freed.
    /// Null keeps every loaded
    /// model's geometry there.
    geometry_streaming: ?GeometryStreaming = null,
};

/// Where liquid pours into a `LiquidDesc` volume.
pub const LiquidSource = struct {
    /// Mouth of the jet, in the world.
    position: Vec3,
    /// Direction and speed of the jet.
    velocity: Vec3 = .{ 0, -1, 0 },
    radius: f32 = 0.12,
    /// Particles a second; 0 fills the jet solid at its speed. Either
    /// way they leave in whole layers across the jet.
    rate: f32 = 0,
};

/// A volume of liquid (`Renderer.createLiquid`): particles held in a box
/// that pour, slosh, splash and break as waves, drawn as one surface.
/// Unlike `WaterDesc`, which is a sheet whose height is simulated, this
/// is liquid that can come apart; it costs far more for the same area and
/// suits a tank, a fountain or a spill rather than a lake.
pub const LiquidDesc = struct {
    /// Places the box the liquid is held in: the unit cube centered on the
    /// origin, scaled to the box's size, turned and moved into place. Its
    /// faces are the liquid's only walls.
    transform: Mat4,
    /// Most particles there can be; fixed when the liquid is created.
    /// Pouring stops when they are all in use.
    capacity: u32 = 30000,
    /// Half the distance between neighbouring particles at rest: the
    /// grain of the liquid. Smaller is finer and needs more particles for
    /// the same amount (eight times as many at half the radius). Fixed
    /// when the liquid is created.
    particle_radius: f32 = 0.04,
    /// The liquid there is at the start: a block in the box's low corner,
    /// this share of the box along each of its axes. Zeros start empty.
    fill: [3]f32 = .{ 0, 0, 0 },
    /// Up to four jets pouring in.
    sources: []const LiquidSource = &.{},
    gravity: Vec3 = .{ 0, -9.8, 0 },
    /// The color it takes on with depth, and how quickly: 0 is clear.
    color: [3]f32 = .{ 0.1, 0.38, 0.5 },
    murk: f32 = 3,
    /// How much of the sun's light it stops: 0 casts no shadow, 1 a
    /// solid one. Costs drawing the particles once more into each
    /// shadow cascade that is refreshed.
    shadow: f32 = 0.5,
    /// Count as a surface for what is drawn after it: fog stops at the
    /// liquid, particles are hidden behind it, antialiasing follows it as
    /// the camera moves, and depth of field and
    /// motion blur focus and blur it by its own distance rather than by
    /// that of what shows through.
    write_depth: bool = true,
    /// How far the slope of the surface shifts what is seen through it.
    refraction: f32 = 0.3,
    /// Steps of simulation a frame, and rounds of pushing particles
    /// apart in each. More of either holds the liquid's volume better
    /// (it squashes less under its own weight) at that many times the
    /// cost.
    substeps: u32 = 2,
    iterations: u32 = 3,
    /// Share of its speed the liquid loses a second: thick liquids high.
    damping: f32 = 0.05,
    /// How much neighbouring liquid shares its speed, 0 to 1: higher
    /// moves more as one body and settles sooner; 0 is a swarm of
    /// particles each going its own way.
    viscosity: f32 = 0.08,
    /// Fine ripples the open surface is shaded with (see
    /// `WaterDesc.ripple_detail`); 0 for none.
    ripple_detail: f32 = 0.4,
    /// Entities push the liquid aside, by the bounding spheres of their
    /// models (the nearest sixteen that reach into the box).
    obstacles: bool = true,
    /// 0 stands still.
    time_scale: f32 = 1,
};

/// Geometry by distance (`Options.geometry_streaming`).
pub const GeometryStreaming = struct {
    /// A model's vertices and indices are on the GPU while anything
    /// drawn with it is within this distance of a camera (measured to
    /// the nearest point of its bounds). Set it past the farthest you
    /// can see, or things will be missing from the picture: what is
    /// drawn with a released model is left out of its scene altogether,
    /// shadows, reflections and bounced light included.
    distance: f32 = 200,
    /// A model is released only beyond `distance` times this, so one
    /// near the edge does not come and go.
    release_factor: f32 = 1.25,
    /// Most bytes of geometry brought back in one frame; the rest waits
    /// for the next. A model larger than this still loads, alone.
    upload_bytes_per_frame: u64 = 16 * 1024 * 1024,
    /// Beyond this distance a model keeps only its coarser levels of
    /// detail in GPU memory: the vertices those use, and the indices
    /// of every level but the finest. It is still drawn, at the detail
    /// it would mostly be drawn at from there anyway, and brought back
    /// whole when a camera comes within nine tenths of this. While it
    /// is so it takes no part in ray tracing. 0 never does this; a
    /// value at or past `distance` does nothing.
    coarse_distance: f32 = 0,
};

/// Keeps only as much of each model texture in GPU memory as the cameras
/// can make use of. Applies to compressed textures (`texture_compression`
/// or KTX2 files); the full mip chains stay in system memory.
pub const TextureStreaming = struct {
    /// GPU memory the streamed textures may take. When what the views want
    /// exceeds it, every texture drops the same number of top levels.
    /// 0 means no limit.
    budget_bytes: u64 = 0,
    /// Levels this small or smaller always stay loaded.
    min_size: u32 = 64,
    /// Texture data uploaded per frame at most (one texture always goes
    /// through, however large).
    upload_bytes_per_frame: u64 = 16 * 1024 * 1024,
    /// Added to the level each texture wants: positive keeps less detail,
    /// negative more.
    mip_bias: f32 = 0,
    /// Frames a texture must go on wanting less detail before detail is
    /// dropped, unless the budget forces it sooner.
    evict_delay_frames: u32 = 120,
    /// Ask for detail only on what is inside a camera's view. Saves the
    /// memory of what is behind the camera; turning around then shows
    /// blurry textures until they load.
    visible_only: bool = false,
    /// Ask for detail only on what a camera actually drew: what is hidden
    /// behind other things asks for none, as if it were out of view. What
    /// was drawn is read back from the GPU a few frames late, so something
    /// coming out from behind cover shows blurry textures until they load.
    skip_occluded: bool = false,
    /// Keep only each texture's small, always-loaded levels in system
    /// memory and read the larger ones from the asset cache file when a
    /// camera wants them. Frees the memory of the full mip chains; the
    /// reads happen on the rendering thread, a few megabytes at a time.
    /// Needs `Options.asset_cache_dir` and compressed textures; a texture
    /// whose cache file is missing stays in memory as before.
    from_cache: bool = false,
};

/// How material textures are stored on the GPU; see
/// `Options.texture_compression`. `.none` keeps them as plain RGBA8,
/// `.bc7` block-compresses them to a quarter of that.
pub const TextureCompression = enum { none, bc7 };
/// A sheet of simulated water; see `createWater`.
pub const WaterDesc = struct {
    /// Cells of the simulation along each side, 16..1024.
    resolution: [2]u32 = .{ 256, 256 },
    /// Places the surface in the world: a unit square in the XZ plane
    /// centered on the origin, +Y up. The Y scale is the unit of height.
    transform: Mat4 = math.identity,
    /// How fast ripples travel, in world units per second (limited by the
    /// resolution: a wave cannot cross more than about two thirds of a
    /// cell per step).
    wave_speed: f32 = 3,
    /// Share of the motion lost per second; higher calms the water sooner.
    damping: f32 = 0.5,
    /// Raindrops per second landing at random places; 0 for none.
    rain: f32 = 0,
    /// Entities moving through the surface disturb it: how strongly (1 is
    /// a plausible wake), 0 for not at all. An entity counts by the
    /// bounding sphere of its model.
    object_ripples: f32 = 1,
    /// Spray thrown up where an entity moves through the surface: how
    /// much (1 is a plausible splash for something dropped in), 0 for
    /// none. The drops are particles of an emitter the water keeps for
    /// itself, lit and shadowed like any others; they take the water's
    /// color. It goes by the same bounding spheres as `object_ripples`,
    /// which must be on, and throws from one place a frame: the
    /// strongest.
    splashes: f32 = 0,
    /// A steady swell laid over the ripples: its height and wave length in
    /// world units. 0 leaves still water flat.
    swell: f32 = 0,
    swell_length: f32 = 6,
    /// Speed of the simulation; 0 freezes it.
    time_scale: f32 = 1,
    /// Color the water takes on with depth, and how quickly (per world
    /// unit looked through).
    color: Vec3 = .{ 0.02, 0.1, 0.12 },
    murk: f32 = 0.5,
    /// Blur of what the surface mirrors.
    roughness: f32 = 0.04,
    /// How strongly the slope of the surface shifts what is seen under it.
    refraction: f32 = 1.2,
    /// White froth at shallow edges (walls, things standing in the water)
    /// and where the surface is churning, 0..1; 0 for none.
    foam: f32 = 0.6,
    /// Patterns of light on what lies under the water, cast by the waves
    /// above (so still water has none), 0..1; 0 for none. They show
    /// through the surface and from below it, in sunlight.
    caustics: f32 = 0.6,
    /// Fine wind ripples laid over the surface for the light only: they
    /// tilt what is mirrored and seen through, and scatter the sun into
    /// glitter, without moving the surface. 0 is glass-still; 1 a
    /// breezy pond.
    ripple_detail: f32 = 0.5,
    /// When the camera is under the surface: tint the view by how much
    /// water it looks through, as the surface does from above.
    underwater: bool = true,
    /// Count as a surface for what is drawn after it: fog stops at the
    /// water, particles fade into it and are hidden below it, and
    /// transparent things under it are covered. False leaves the water
    /// out of the depth those passes see, so they treat it as not there.
    write_depth: bool = true,
};

/// What happens at the sides of a fluid's box.
pub const FluidWalls = enum(u32) {
    /// The fluid leaves through every side.
    open,
    /// Solid underneath, open elsewhere: a fire on the ground.
    floor,
    /// A sealed box: smoke fills it.
    closed,
};

/// A place inside a fluid's box where smoke, heat or fuel enters.
pub const FluidSource = struct {
    /// Center, as a share of the box along each axis (0..1).
    position: Vec3 = .{ 0.5, 0.08, 0.5 },
    /// Radius as a share of the box's height.
    radius: f32 = 0.07,
    /// Where the fluid is pushed inside the source, in box heights per second.
    velocity: Vec3 = .{ 0, 0.5, 0 },
    /// Smoke, fuel and heat added per second at the center. Fuel burns
    /// where it is hot, giving heat and smoke of its own.
    smoke: f32 = 0,
    fuel: f32 = 0,
    temperature: f32 = 0,
};

/// Something solid inside a fluid's box that the flow goes around. In the
/// box's own coordinates: 0..1 along each axis.
pub const FluidObstacle = union(enum) {
    /// `radius` is a share of the box's height.
    sphere: struct { center: Vec3, radius: f32 },
    box: struct { min: Vec3, max: Vec3 },
};

/// A sheet of frames recorded from a running fluid (`recordFluidFlipbook`).
pub const FluidFlipbookDesc = struct {
    columns: u32 = 8,
    rows: u32 = 8,
    /// Simulation steps from one frame to the next, at least 1.
    interval: u32 = 2,
    /// Size of one frame in pixels; null uses the fluid's resolution.
    frame_size: ?[2]u32 = null,
};

/// A box of simulated smoke and fire; see `createFluid`.
pub const FluidDesc = struct {
    /// Cells along each axis, 8..256. A depth of 1 makes the fluid 2D.
    resolution: [3]u32 = .{ 64, 96, 64 },
    /// Places the box in the world: a unit cube centered on the origin,
    /// with +Y up for the fluid.
    transform: Mat4 = math.identity,
    /// Up to 8.
    sources: []const FluidSource = &.{},
    /// Up to 8. The flow does not see the scene's geometry; describe what
    /// stands in its way here.
    obstacles: []const FluidObstacle = &.{},
    /// Treat the scene's own geometry inside the box as solid too: each
    /// frame the cells a surface passes through are found with short
    /// rays. Needs ray tracing and a view of the scene with global
    /// illumination on; costs six short rays per cell per frame.
    scene_obstacles: bool = false,
    walls: FluidWalls = .floor,
    /// How hard heat lifts the gas and smoke weighs it down, in box
    /// heights per second squared per unit of each.
    buoyancy: f32 = 1.6,
    weight: f32 = 0.1,
    /// Strength of the swirls put back into the flow (vorticity
    /// confinement). 0 gives a smooth, lazy flow.
    vorticity: f32 = 12,
    /// A steady push on all of the fluid, in box heights per second squared.
    wind: Vec3 = .{ 0, 0, 0 },
    /// Share lost per second: motion dying down, smoke thinning, gas
    /// cooling, fuel burning.
    velocity_loss: f32 = 0.25,
    smoke_loss: f32 = 0.45,
    cooling: f32 = 1.4,
    burn_rate: f32 = 5,
    /// Heat and smoke given off per unit of fuel burned.
    heat: f32 = 3,
    soot: f32 = 0.6,
    /// Correct the error of carrying smoke and heat along the flow
    /// (MacCormack advection): wisps stay sharp instead of blurring out.
    /// One more pass and a dozen more lookups per cell.
    sharp_advection: bool = true,
    /// The same correction for the flow itself: swirls keep their energy
    /// instead of dying down, so the fluid stays livelier with less
    /// `vorticity`. Needs `sharp_advection`; a dozen more lookups.
    sharp_velocity: bool = false,
    /// Jacobi iterations of the pressure solve per step, 1..200. More
    /// keeps the flow from compressing in large or fast fluids.
    pressure_iterations: u32 = 24,
    /// Speed of the simulation; 0 freezes it.
    time_scale: f32 = 1,

    /// Color the smoke scatters, and how much light a unit of smoke takes
    /// out per world unit.
    smoke_color: Vec3 = .{ 0.55, 0.55, 0.58 },
    absorption: f32 = 8,
    /// Tint and brightness of the glow of hot gas.
    fire_color: Vec3 = .{ 1, 1, 1 },
    fire_intensity: f32 = 6,
    /// How strongly the fire lights the scene around it: a light is kept
    /// at the middle of the glow, as bright and as colored as the flames
    /// are at that moment, flickering with them. 0 gives off no light.
    light: f32 = 1,
    /// How far that light reaches; 0 picks three times the box's height.
    light_range: f32 = 0,
    /// Width of that light as a share of the box's height. 0 casts sharp
    /// shadows from the middle of the flame; more (a flame is about 0.08)
    /// softens them where ray-traced light shadows are on, at the price
    /// of grain wherever only a sliver of the flame is in sight, which
    /// `Settings.light_shadow_rays` reduces.
    light_size: f32 = 0,
    /// How much of the flames' height the light takes: 1 makes it a
    /// standing line as tall as the glow, so a tall fire lights what is
    /// beside it evenly; 0 is a single point at the middle of the glow.
    /// A tall light casts soft shadows where they are ray traced.
    light_tall: f32 = 1,
    /// How strongly the smoke shadows itself from the sun, 0..1.
    shadow: f32 = 1,
    /// How much light keeps its direction through the smoke: higher gives
    /// a brighter rim toward the sun.
    anisotropy: f32 = 0.35,
    /// How much ambient light the smoke picks up.
    ambient: f32 = 1,
};

/// A layer of volumetric clouds over a scene; see `setClouds`.
pub const CloudDesc = struct {
    /// Share of the sky the clouds fill, 0..1.
    coverage: f32 = 0.5,
    /// How much coverage varies from place to place: 0 is an even field,
    /// higher gathers the clouds into banks with clear sky between.
    variation: f32 = 0.6,
    /// Light lost per meter inside a cloud. Higher is darker and
    /// harder-edged.
    density: f32 = 0.012,
    /// Altitude of the cloud base and how tall the layer is, in world units
    /// above y = 0.
    bottom: f32 = 1500,
    thickness: f32 = 1400,
    /// Size of the cloud shapes; 1 gives clouds a few kilometres across.
    scale: f32 = 1,
    /// How strongly small-scale noise eats into the edges, 0..1.
    detail: f32 = 0.35,
    /// World units per second the clouds drift.
    wind: Vec3 = .{ 12, 0, 5 },
    /// Tint of the scattered light.
    color: Vec3 = .{ 1, 1, 1 },
    /// How much sky light the clouds pick up, relative to the environment.
    ambient: f32 = 1,
    /// How strongly light keeps its direction passing through: higher
    /// gives a brighter rim toward the sun.
    anisotropy: f32 = 0.6,
    /// How dark the shadow under a cloud is, 0..1; 0 casts none. The
    /// shadows fall on everything the sun lights, fog included.
    shadow: f32 = 0.8,
    /// Seconds between rebuilds of the sky's lighting with the clouds in
    /// it, so that ambient light dims under overcast and sky reflections
    /// show clouds. A loaded environment's clouds are lit by the scene's
    /// sun. 0 leaves the
    /// lighting as a clear sky. Each rebuild costs a sky bake.
    environment_interval: f32 = 4,
    /// Cover of a second layer far above the first: thin streaks of ice
    /// cloud, 0..1; 0 for none. It casts no shadow.
    cirrus: f32 = 0,
    /// Storm cells, 0..1: where the weather is heaviest (see `variation`)
    /// the cloud stands solid to the top of the layer and spreads out
    /// there, like the anvil of a thunderstorm. Wants a thick layer.
    anvil: f32 = 0,
    /// Lightning: flashes per minute, at random places in the layer
    /// within a few kilometres of the camera, each lighting the cloud
    /// around it for a moment; and how bright they are. The scene is not
    /// lit by them unless the application adds a light where
    /// `Renderer.cloudFlash` says one is.
    lightning: f32 = 0,
    lightning_brightness: f32 = 40,
    /// Radius of the planet the layer wraps around; decides how the
    /// clouds sink toward the horizon.
    planet_radius: f32 = 6_360_000,
};

/// A lightning flash in a cloud layer; see `Renderer.cloudFlash`.
pub const CloudFlash = struct { position: Vec3, brightness: f32 };

/// How overlapping transparent surfaces are combined; see
/// `Settings.transparency`.
pub const TransparencyMode = enum {
    /// Whole meshes, drawn farthest first.
    sorted,
    /// Order-independent by weighting: any number of layers in one pass,
    /// but an average rather than true layering.
    weighted,
    /// Depth peeling: exact per pixel for the nearest
    /// `Settings.transparency_layers` surfaces, at one pass over the
    /// transparent geometry per layer.
    peeled,
};

/// What the haze of aerial perspective is made of; see
/// `Settings.aerial_model`. `.atmosphere` is air lit by sun and sky, `.sky`
/// a plain fade to the sky behind.
pub const AerialModel = enum { atmosphere, sky };

/// Which level of detail a local light's shadow is drawn from: the one the
/// camera sees, or the one that suits the light's distance. See
/// `Settings.shadow_lod`.
pub const ShadowLod = enum { camera, light };

/// How a view's final picture is encoded; see `Settings.output_encoding`.
/// `.auto` follows the target, `.srgb` and `.hdr10` force one.
pub const OutputEncoding = enum { auto, srgb, hdr10 };

/// Hooks for an external CPU profiler. `begin` is called with a static
/// zone name when the renderer starts a piece of work and returns whatever
/// the profiler needs to close the zone; `end` receives it back. With
/// Tracy: `begin` calls `___tracy_emit_zone_begin_alloc` and returns the
/// context, `end` calls `___tracy_emit_zone_end`.
pub const Profiler = struct {
    /// Passed back to `begin` and `end` unchanged.
    context: ?*anyopaque = null,
    begin: *const fn (context: ?*anyopaque, name: [:0]const u8) u64,
    end: *const fn (context: ?*anyopaque, zone: u64) void,
};

/// Where a model or environment is on its way from a file to the GPU.
pub const AssetState = enum {
    /// Still being decoded or uploaded; entities that use it are not drawn
    /// yet.
    loading,
    ready,
    /// The load ended in an error (see `Renderer.modelError`), or the
    /// handle names nothing.
    failed,
};

/// Where a view is seen from. The projection is a perspective one with no
/// far plane; its aspect ratio follows the size the view is drawn at.
pub const Camera = struct {
    /// Position of the eye, in world units.
    position: Vec3 = .{ 0, 0, 3 },
    /// Direction the camera looks along; need not be normalized.
    forward: Vec3 = .{ 0, 0, -1 },
    /// Roughly which way is up in the picture; need not be perpendicular
    /// to `forward`. Where the two are parallel, +Z is used instead.
    up: Vec3 = .{ 0, 1, 0 },
    /// Vertical field of view in radians.
    fov_y: f32 = std.math.degreesToRadians(60.0),
    /// Distance to the near plane, in world units; nothing closer is drawn.
    near: f32 = 0.1,

    /// A camera at `position` looking toward `target`, with every other
    /// field at its default. The two points must differ.
    pub fn lookAt(position: Vec3, target: Vec3) Camera {
        return .{ .position = position, .forward = math.sub(target, position) };
    }
};

/// The scene's one shadow-casting directional light; see `Renderer.setSun`.
pub const Sun = struct {
    /// Direction the light travels (from the sun toward the scene).
    direction: Vec3 = .{ -0.4, -1.0, -0.3 },
    /// Linear color of the light; `intensity` scales it.
    color: Vec3 = .{ 1.0, 0.96, 0.9 },
    /// Radiometric scale in the same units as the environment map. 0, the
    /// default, turns the sun off.
    intensity: f32 = 0,
};

/// The shape of a `Light`.
pub const LightKind = enum {
    /// Shines in every direction from `position`.
    point,
    /// A cone from `position` along `direction`, between `inner_angle`
    /// and `outer_angle`.
    spot,
    /// Parallel light from infinitely far away, like the sun but without
    /// shadows: a moon beside the sun, a fill light, sky bounce. `position`
    /// and `range` are ignored.
    directional,
    /// A glowing panel (a window, a screen, a ceiling light): a rectangle
    /// centered on `position`, `source_length` wide and `source_height`
    /// tall, shining along `direction`. Its shadows are ray traced.
    rectangle,
};

/// A point or spot light. Lights are culled into view-space clusters, so
/// cost scales with lights per cluster rather than total light count.
pub const Light = struct {
    kind: LightKind = .point,
    /// Where the light is, in world units.
    position: Vec3,
    /// Direction a spot light points; ignored for point lights.
    direction: Vec3 = .{ 0, -1, 0 },
    /// Linear color of the light; `intensity` scales it.
    color: Vec3 = .{ 1, 1, 1 },
    intensity: f32 = 1,
    /// Distance at which the light's contribution reaches zero.
    range: f32 = 5,
    /// Spot cone half-angles in radians: full brightness inside `inner`,
    /// none outside `outer`.
    inner_angle: f32 = 0.35,
    outer_angle: f32 = 0.6,
    /// Shadows use one atlas tile for a spot light and six for a point
    /// light; at most 16 tiles are available per frame, assigned in order.
    cast_shadows: bool = false,
    /// Radius of the glowing sphere the light comes from. 0 is an ideal
    /// point; larger sources give wider, softer highlights (a bulb, a
    /// paper lantern) and stop getting brighter once a surface touches
    /// them.
    source_radius: f32 = 0,
    /// Point lights only: makes the source a tube this long, centered on
    /// `position` and lying along `direction` (a fluorescent strip, a
    /// neon sign). `source_radius` is then the tube's thickness. Shadows
    /// are still cast from the center.
    source_length: f32 = 0,
    /// Rectangle lights only: the panel's height (`source_length` is its
    /// width).
    source_height: f32 = 0,
    /// Spot lights only: an image projected like a slide (a window frame,
    /// a stained glass pattern, a flashlight's rings).
    cookie: ?Image = null,
    /// Brightness by angle from `direction`: a strip image whose left edge
    /// is the brightness along the axis and whose right edge is straight
    /// behind it. See `Renderer.loadLightProfile` for measured IES data.
    profile: ?Image = null,
};

/// What `Renderer.spawn` makes an entity from. Everything but the model
/// can be changed afterwards (`setTransform`, `setVisible`, `setTint`,
/// `setParams`).
pub const EntityDesc = struct {
    /// The model to draw. It may still be loading; the entity appears
    /// once it is ready.
    model: Model,
    /// Places the model's space in the world.
    transform: Mat4 = math.identity,
    /// False keeps the entity in the scene without drawing it.
    visible: bool = true,
    /// Multiplies the base color of every material on the entity.
    tint: [3]f32 = .{ 1, 1, 1 },
    /// Free numbers handed to custom material shaders as
    /// `MaterialContext.instance_params`.
    params: [4]f32 = .{ 0, 0, 0, 0 },
    /// False keeps the scene's decals off this entity (a character
    /// walking over a painted floor).
    receive_decals: bool = true,
};

/// One animation clip of a model; see `Renderer.animationInfo`.
pub const AnimationInfo = struct {
    /// The clip's name in the file. The bytes belong to the model and are
    /// valid until it is destroyed.
    name: []const u8,
    /// Length of the clip in seconds.
    duration: f32,
};

/// Size and extent of a loaded model; see `Renderer.modelInfo`.
pub const ModelInfo = struct {
    mesh_count: u32,
    triangle_count: u32,
    meshlet_count: u32,
    texture_count: u32,
    /// Joints of all the model's skins together; 0 for a rigid model.
    joint_count: u32,
    /// Meshes that have morph targets, and the most any one has.
    morph_meshes: u32 = 0,
    morph_targets: u32 = 0,
    /// Axis-aligned bounds of the rest pose, in model space.
    bounds_min: Vec3,
    bounds_max: Vec3,
    /// Bounding sphere of the rest pose, in model space.
    bounds_center: Vec3,
    bounds_radius: f32,
};

/// What is known about a loaded environment; see
/// `Renderer.environmentInfo`.
pub const EnvironmentInfo = struct {
    /// Direction toward the brightest part of the panorama, usually the sun.
    /// Negate it to get a matching `Sun.direction`.
    brightest_direction: Vec3,
};

/// How much of a frame the effects may take: a starting point for
/// `Settings` (see `Settings.preset`) that an application adjusts from.
pub const Quality = enum {
    /// For integrated and software GPUs. No bounce light or reflections,
    /// coarser shadows and volumes, and the scene drawn at three quarters
    /// of the output size and upscaled.
    low,
    /// For graphics cards without ray tracing. Reflections at half
    /// resolution; no bounce light, which needs ray tracing to follow
    /// what moves.
    medium,
    /// Everything on, with reflections at half resolution.
    high,
    /// Everything on at full resolution: what `Settings` is by default.
    ultra,

    /// The level a GPU can be expected to hold a steady frame rate at.
    /// A guess from what kind of GPU it is, not a measurement of it:
    /// offer the user the choice as well.
    pub fn recommended(adapter: rhi.AdapterInfo) Quality {
        const ultra_memory_bytes = 10 << 30;
        return switch (adapter.kind) {
            .integrated, .software, .other => .low,
            .discrete, .virtual => if (!adapter.ray_tracing)
                .medium
            else if (adapter.memory_bytes >= ultra_memory_bytes)
                .ultra
            else
                .high,
        };
    }
};

/// Quality and look of one view (`ViewDesc.settings`). Unlike `Options`
/// these may differ between views and change from frame to frame.
/// Distances are in world units.
pub const Settings = struct {
    /// The settings of a quality level. Only what costs time differs
    /// between levels; the look (exposure, bloom, fog, grading, lens)
    /// is left at its defaults for the application to set.
    pub fn preset(quality: Quality) Settings {
        return switch (quality) {
            .ultra => .{},
            .high => .{ .reflection_resolution = .half },
            .medium => .{
                .global_illumination = false,
                .ao_bounce = 0,
                .reflection_resolution = .half,
                .shadow_samples = 8,
                .light_shadow_rays = 2,
                .cloud_steps = 32,
                .fluid_steps = 32,
            },
            .low => .{
                .render_scale = 0.75,
                .global_illumination = false,
                .ao_bounce = 0,
                .ao_slices = 1,
                .screen_space_reflections = false,
                .shadow_cascades = 3,
                .shadow_samples = 4,
                .light_shadow_rays = 1,
                .cloud_resolution = .quarter,
                .cloud_steps = 24,
                .fluid_resolution = .quarter,
                .fluid_steps = 24,
                .fog_steps = 8,
                .dof_resolution = .half,
                .motion_blur_samples = 6,
            },
        };
    }

    /// Sun and local light shadows. False draws no shadow maps at all.
    shadows: bool = true,
    /// Distance from the camera covered by the shadow cascades.
    shadow_distance: f32 = 60,
    /// Penumbra radius in world units.
    shadow_softness: f32 = 0.035,
    /// Shadow maps the sun's shadow distance is split over, 1..4. Fewer
    /// cost less to render and blur more at range.
    shadow_cascades: u32 = 4,
    /// Leave out of each sun shadow cascade whatever is smaller than this
    /// many of its texels across: a caster that small leaves a shadow of
    /// a texel or two that the filter blurs to nothing, but still costs a
    /// draw. With very many small things (debris, grass, a field of
    /// blocks) it removes most of the far cascades' work. 0 draws
    /// everything; a value around 2 is rarely visible. It goes by the
    /// size of a whole mesh, so large things keep their shadows.
    shadow_small_feature_texels: f32 = 0,
    /// Leave out of a sun shadow cascade every caster whose shadow cannot
    /// fall on anything the camera sees: its bounds, swept along the
    /// light, miss the part of the view the cascade shadows, or lie
    /// behind what is drawn there (the air in front of surfaces counts as
    /// seen, so fog and see-through surfaces keep their shadows). Nothing
    /// in the picture changes. It applies to cascades drawn afresh every
    /// frame: all of them without `shadow_cascade_stagger`, only the
    /// nearest with it, since a map kept for several frames must also
    /// hold what the camera comes to see in the meantime.
    shadow_receiver_culling: bool = true,
    /// Reach, in world units, of small screen-space shadows added to the
    /// sun's (where feet meet the floor, under ledges); 0.2 to 0.5 is
    /// typical. 0 turns them off. Opaque surfaces only, and only what is
    /// on screen casts them.
    contact_shadows: f32 = 0,
    /// Lights that cast shadows but have no shadow map (extra directional
    /// lights, panels, lamps past the shadow tile budget) are shadowed by
    /// a ray each in the opaque pass. Needs ray tracing and
    /// `global_illumination`. One ray per light per pixel; lights with a
    /// size get a soft edge once temporal antialiasing has averaged it.
    ray_traced_light_shadows: bool = true,
    /// Rays per pixel toward each ray-shadowed light that has a size
    /// (sphere, tube, panel), 1..15. More gives a smoother penumbra.
    light_shadow_rays: u32 = 4,
    /// Carry how much of each soft-shadowed light reaches a surface from
    /// frame to frame, so that the few rays per pixel add up instead of
    /// showing as grain. The shadows of moving things trail by a few
    /// frames. Needs temporal antialiasing; off takes each frame's rays
    /// as they come.
    light_shadow_filter: bool = true,
    /// Samples of the sun shadow filter where a shadow's edge falls: 4, 8
    /// or 16. Fewer are cheaper and grainier.
    shadow_samples: u32 = 16,
    /// Darken creases and corners where little ambient light reaches,
    /// from what is on screen (GTAO).
    ambient_occlusion: bool = true,
    /// World-space radius searched for occluders.
    ao_radius: f32 = 1.2,
    /// Blend each frame's ambient occlusion with the previous frames',
    /// reprojected. Removes the grain and flicker of the sampling pattern;
    /// occlusion then takes a few frames to follow fast-moving objects.
    ao_temporal_filter: bool = true,
    /// Light from what occludes: where ambient occlusion finds a nearby
    /// surface in the way of the sky, that surface's own light (as it
    /// was lit last frame) arrives in the sky's place, so a red wall
    /// tints the floor at its foot and a lit floor brightens the
    /// underside of what stands on it. This is the indirect light too
    /// fine for the probes of `global_illumination`. A strength, 0 for
    /// none; costs one texture fetch per occlusion sample and a filter
    /// pass. Needs `ambient_occlusion` and `temporal_antialiasing`.
    ao_bounce: f32 = 1,
    /// Exponent applied to the occlusion term; higher is darker.
    ao_intensity: f32 = 1.3,
    /// Skip geometry hidden behind what was visible last frame, using a
    /// depth pyramid. Never drops visible geometry.
    occlusion_culling: bool = true,
    /// Resolution the scene is rendered at, as a fraction of the size it is
    /// shown at: 0.5 renders a quarter of the pixels and upscales, above 1
    /// supersamples. Draw lists and text are always drawn at full size.
    render_scale: f32 = 1,
    /// How a picture rendered below the output size (`render_scale` under
    /// 1) is brought up to it. `.temporal` lets temporal antialiasing
    /// build the full-size picture out of several frames' samples, which
    /// recovers detail a single frame does not have; `.spatial` stretches
    /// each frame by itself. Temporal needs `temporal_antialiasing`.
    upscaling: Upscaling = .temporal,
    /// Meshes switch to a coarser level of detail once the detail lost
    /// would be smaller than this many pixels on screen. Higher draws
    /// fewer triangles and may show the switch; 0 always draws full detail.
    lod_error_pixels: f32 = 1,
    /// Cross-fade between levels of detail instead of switching: over
    /// this share of the switching distance (0.25 is a good width) both
    /// levels are drawn, each on a dithered share of the pixels that
    /// temporal antialiasing blends. 0 switches at once, which can pop.
    /// Costs drawing two levels of whatever is inside the band.
    lod_cross_fade: f32 = 0,
    /// Which level of detail a local light's shadow is drawn from.
    /// `.camera`: the one the camera sees, so a thing and its shadow
    /// always agree. `.light`: the one that suits the shadow tile, by
    /// distance from the light, which draws far less when a light is far
    /// from what the camera is close to, at the risk of a coarse shadow
    /// on a finely drawn thing. The sun's cascades always follow the
    /// camera.
    shadow_lod: ShadowLod = .camera,
    /// How overlapping transparent surfaces are combined. `.sorted` draws
    /// each mesh back to front, exact for surfaces that do not intersect.
    /// `.weighted` needs no order and never pops when two meshes swap
    /// places, but blends by a weighted average rather than true layering.
    transparency: TransparencyMode = .sorted,
    /// Layers of the `.peeled` mode, 1..16: how many transparent surfaces
    /// behind one another are resolved at each pixel.
    transparency_layers: u32 = 4,
    /// Transparent surfaces cast shadows as dark as they are opaque.
    transparent_shadows: bool = true,
    /// A surface that bends light shows the see-through surfaces behind
    /// it as well, not only the solid scene: the picture is copied again
    /// before each such surface is drawn, which is what it costs. Only
    /// with `.sorted` transparency.
    layered_refraction: bool = false,
    /// See-through surfaces tint the sunlight that passes through them
    /// (stained glass on a floor) instead of only dimming it. Costs a
    /// second, half-size picture per shadow cascade and a pass over the
    /// see-through casters. Sun shadows only; needs `transparent_shadows`.
    colored_shadows: bool = false,
    /// Glossy surfaces mirror what is on screen around them (floors show
    /// the walls, puddles the lamps) instead of only the sky. What is off
    /// screen or hidden cannot be mirrored and falls back to the sky.
    screen_space_reflections: bool = true,
    /// Resolution the reflection rays are traced at. Half traces a quarter
    /// of the rays and joins them back up with regard to depth; mirrors
    /// lose a little sharpness, rough reflections lose nothing visible.
    reflection_resolution: EffectResolution = .full,
    /// Surfaces rougher than this reflect only the sky.
    reflection_max_roughness: f32 = 0.5,
    /// Samples along each reflection ray, 4..256.
    reflection_steps: u32 = 32,
    /// How far a reflection ray travels, in world units.
    reflection_distance: f32 = 30,
    /// How thick surfaces are assumed to be when a ray passes behind them.
    reflection_thickness: f32 = 0.3,
    /// Average reflections over frames. Removes sparkle at thin objects and
    /// screen edges; reflections of moving things trail slightly.
    reflection_temporal_filter: bool = true,
    /// Where the screen has no answer for a reflection (off screen, behind
    /// something), trace a real ray and shade what it hits with sun and
    /// probe light. Needs ray tracing and `global_illumination`. What is
    /// hit shows no highlights of its own, and animated or transparent
    /// things are not hit.
    reflection_ray_tracing: bool = true,
    /// Ray-traced reflections (and water's) show see-through surfaces
    /// too: the nearest one along the ray, laid over what a second ray
    /// finds behind it. Costs that second ray where one is hit.
    reflect_transparent: bool = true,
    /// Samples of the blur that makes reflections softer the rougher the
    /// surface is, 0..32. 0 leaves them sharp at any roughness.
    reflection_blur_samples: u32 = 8,
    /// Draw the scene's fluids (`createFluid`). They are simulated either way.
    fluids: bool = true,
    /// Resolution of the pass that draws them.
    fluid_resolution: EffectResolution = .half,
    /// Samples along each ray through a fluid's box, 4..256, and toward
    /// the sun from each of them, 1..32.
    fluid_steps: u32 = 48,
    fluid_light_steps: u32 = 6,
    /// Smoke shadows what the sun lights behind it (surfaces, fog, other
    /// smoke): a short march through each fluid the sun's ray crosses.
    fluid_shadows: bool = true,
    /// Smoke and flame write motion vectors, so that antialiasing over
    /// frames follows them as they drift instead of smearing them over
    /// what is behind. Costs a look at the flow at every step of the march.
    fluid_motion_vectors: bool = true,
    /// Rays pass through smoke and see fire: ray-traced reflections show
    /// them, and the probes' rays are dimmed by smoke and pick up the
    /// flames. A short march through each fluid box per ray.
    fluid_rays: bool = true,
    /// Draw the scene's cloud layer, if it has one (`setClouds`).
    clouds: bool = true,
    /// Resolution of the cloud pass.
    cloud_resolution: EffectResolution = .half,
    /// Samples along each cloud ray, 8..256, and toward the sun from each
    /// of them, 1..16.
    cloud_steps: u32 = 48,
    cloud_light_steps: u32 = 6,
    /// How far clouds are drawn, in world units; they fade out before it.
    cloud_distance: f32 = 60_000,
    /// Average clouds over frames, which fills in between the samples.
    /// Without it they are grainy unless `cloud_steps` is raised a lot.
    cloud_temporal_filter: bool = true,
    /// Diffuse global illumination from ray-traced irradiance probes.
    /// Ignored (sky light is used instead) on hardware without ray queries.
    global_illumination: bool = true,
    /// Distance between probes; grows automatically for large scenes.
    gi_probe_spacing: f32 = 1.5,
    /// Rays traced per probe per frame, 16..256.
    gi_rays: u32 = 64,
    /// Multiplies the indirect light the probes give; 1 is unchanged.
    gi_intensity: f32 = 1,
    /// Resolution at which probe irradiance is evaluated. `.full` looks the
    /// probes up per pixel with the normal-mapped normal. Lower settings
    /// gather with geometric normals and upsample, which is cheaper but
    /// drops normal-map detail from indirect light.
    gi_resolution: EffectResolution = .full,
    /// Each probe is re-traced once every this many frames (1..16). Higher
    /// values cost less and react to lighting changes more slowly.
    gi_update_interval: u32 = 4,
    /// How much of a probe's previous value survives each frame, 0..1.
    /// Higher is steadier and slower to follow small lighting changes:
    /// 0.995 settles in about four seconds at 60 fps and 0.99 in two, with
    /// bounce light that drifts half as much again; 0.9 takes a sixth of
    /// a second but flickers visibly at low ray counts. Large changes do
    /// not wait for it: see `gi_change_tolerance`.
    gi_hysteresis: f32 = 0.995,
    /// What to do in a scene too large for the probe grid at
    /// `gi_probe_spacing`. True keeps that spacing in a grid that moves
    /// with the camera and adds a coarse grid over the whole scene behind
    /// it; false uses only the coarse one. Following costs the second
    /// grid's update (about 0.1 ms in the Sponza test).
    gi_follow_camera: bool = true,
    /// How much wider than `gi_probe_spacing` the probes would have to be
    /// spread to cover the scene before the following grid is used.
    gi_follow_threshold: f32 = 1.25,
    /// Frames between updates of the coarse grid behind a following one,
    /// once it has settled. 1 updates it every frame; higher saves that
    /// cost on the frames between and makes distant bounce light slower
    /// to follow changes.
    gi_coarse_interval: u32 = 1,
    /// For very large worlds: when the coarse grid's probes end up more
    /// than this many times as far apart as the main grid's, a third
    /// grid goes between them, following the camera at a spacing halfway
    /// (geometrically) between the two. 0 never adds one.
    gi_middle_ratio: f32 = 6,
    /// Local lights (up to the first 32) light what probe and reflection
    /// rays hit, each tested with a shadow ray: lamps then bounce off
    /// walls, and lamp-lit surfaces show in ray-traced reflections. Costs
    /// a ray per light in range per hit.
    gi_local_lights: bool = true,
    /// Most local lights whose light bounces: the first this many of the
    /// scene's list, up to 1023. Every ray that hits something looks at
    /// each of them and sends a shadow ray to those in range, so the cost
    /// grows with it; lights past the count still light surfaces directly.
    gi_bounce_lights: u32 = 32,
    /// Probes that sit inside geometry (most of their rays meet the backs
    /// of surfaces) are traced only every eighth turn: nothing is lit by
    /// them, so their rays are wasted. A probe uncovered by something
    /// moving away takes up to eight updates to notice.
    gi_skip_buried_probes: bool = false,
    /// Move probes out of walls and off surfaces they sit too close to,
    /// each within its own cell, from what their rays meet. A probe in a
    /// wall is dark and one against a surface sees little of the room;
    /// moved, both light their surroundings properly. Costs a small pass
    /// per probe update and eight texture fetches per shaded pixel.
    gi_probe_relocation: bool = false,
    /// How far a probe's fast estimate may differ from its steady value
    /// before the steady value is pulled along, as a fraction (0.25 = 25%).
    /// This is what lets `gi_hysteresis` be high without making light
    /// changes lag: noise stays inside the band and is averaged away, a
    /// door opening or a light switching on leaves it and shows within a
    /// few frames. 0 turns the mechanism off.
    gi_change_tolerance: f32 = 0.3,
    /// Resolution of the ambient occlusion pass; upsampled with depth
    /// weights. Lower is cheaper and softer.
    ao_resolution: EffectResolution = .half,
    /// Resolution of the volumetric fog pass.
    fog_resolution: EffectResolution = .half,
    /// Samples along each fog ray, 4..128.
    fog_steps: u32 = 12,
    /// Directions searched for occluders per pixel, 1..8.
    ao_slices: u32 = 2,
    /// Samples per direction, 1..32.
    ao_steps: u32 = 5,
    /// Refresh the far sun cascades every 2nd, 4th and 8th frame instead of
    /// every frame. Turn off if far shadows of moving objects must not lag.
    shadow_cascade_stagger: bool = true,
    /// Antialias by jittering the camera and blending each frame with the
    /// reprojected ones before it (TAA). Several other settings rely on it
    /// to average their noise away.
    temporal_antialiasing: bool = true,
    /// Mip bias for material textures while temporal antialiasing is on.
    /// Negative values pick sharper mips, which the accumulation resolves
    /// into extra detail at the cost of more shimmer on very fine patterns;
    /// 0 is the unbiased, most stable choice.
    texture_mip_bias: f32 = -0.25,
    /// Widen highlights where normals vary faster than pixels can show
    /// (distant normal-mapped metal, fabric weave), which otherwise sparkle.
    specular_antialiasing: bool = true,
    /// Fraction of the image replaced by its blurred self; 0 disables bloom.
    bloom: f32 = 0.04,
    /// How many halvings the bloom blur goes through, 1..6. More spreads
    /// the glow wider.
    bloom_levels: u32 = 6,
    /// Adapt exposure to the picture's average brightness over time, as
    /// an eye or a camera does. False uses `exposure_compensation` alone.
    automatic_exposure: bool = true,
    /// Stops added on top of automatic exposure, or the absolute exposure
    /// (as 2^EV) when automatic exposure is off.
    exposure_compensation: f32 = 0,
    /// Extinction of the volumetric fog per world unit; 0 disables it.
    fog_density: f32 = 0,
    /// How quickly the fog thins with height.
    fog_height_falloff: f32 = 0.08,
    /// Forward-scattering bias, 0 isotropic .. 1 all toward the viewer.
    fog_anisotropy: f32 = 0.6,
    /// Aerial perspective: haze per world unit that distant opaque
    /// surfaces fade into the sky by (0.0005 turns hills a kilometre away
    /// pale). 0 for none. Needs an environment.
    aerial_perspective: f32 = 0,
    /// What the haze is made of. `.atmosphere`: air, which scatters blue
    /// more than red (far things turn blue), glows around the sun and is
    /// lit by sun and sky. `.sky`: one grey haze that fades things to the
    /// sky seen behind them, which matches any backdrop exactly.
    aerial_model: AerialModel = .atmosphere,
    /// Strength of the post-TAA sharpening filter, 0..1.
    sharpen: f32 = 0.35,
    /// Read text from a three-channel distance field, in which the
    /// corners of letters stay sharp however large the text is drawn.
    /// False reads the plain field, which rounds corners off at large
    /// sizes but cannot show the rare speck the three channels can.
    sharp_text: bool = true,
    /// Darkening toward the corners of the picture, 0..1.
    vignette: f32 = 0,
    /// Film grain strength, 0..1.
    film_grain: f32 = 0,
    /// 0 is black and white, 1 unchanged, above 1 more vivid.
    saturation: f32 = 1,
    /// Contrast around middle grey; 1 unchanged.
    contrast: f32 = 1,
    /// White balance: negative cooler (bluer), positive warmer, -1..1.
    temperature: f32 = 0,
    /// Multiplies the picture before tone mapping, like a lens filter.
    color_filter: [3]f32 = .{ 1, 1, 1 },
    /// A color lookup table applied to the finished picture, as graded in
    /// an image editor: a strip of N slices, each N by N, N squared wide
    /// and N tall (16 or 32 are usual), in sRGB. Load it with
    /// `createImage(..., false)` so it is not converted.
    color_lut: ?Image = null,
    /// How much of the table's result to use, 0..1.
    color_lut_strength: f32 = 1,
    /// Red/blue fringing toward the corners, 0..1.
    chromatic_aberration: f32 = 0,
    /// Lens flare: faint mirrored copies of, and a ring around, things far
    /// brighter than white (the sun, lamps). 0 is none, 1 is plain to see.
    lens_flare: f32 = 0,
    /// How the final picture is encoded. `.auto` matches the target: sRGB
    /// for ordinary targets, HDR10 for the window when `Options.hdr_output`
    /// got an HDR surface. The others force one, for rendering to a
    /// texture meant for something else.
    output_encoding: OutputEncoding = .auto,
    /// HDR10 only: how bright white (a page, the UI) is, in nits.
    hdr_paper_white: f32 = 200,
    /// HDR10 only: the brightest the display can show, in nits. Highlights
    /// roll off toward it instead of clipping.
    hdr_peak: f32 = 1000,
    /// Depth of field: how wide the lens is open. 0 keeps everything
    /// sharp; 1 blurs distant things by about 24 pixels at 1080p when
    /// focused close.
    dof_aperture: f32 = 0,
    /// Distance from the camera that is in perfect focus.
    dof_focus_distance: f32 = 10,
    /// Focus on whatever is at the middle of the picture instead, easing
    /// to it over a moment (`dof_autofocus_speed`).
    dof_autofocus: bool = false,
    /// How quickly the autofocus follows, per second; higher refocuses
    /// faster.
    dof_autofocus_speed: f32 = 4,
    /// Largest blur radius, in pixels at 1080p.
    dof_max_blur: f32 = 16,
    /// Samples gathered per pixel, 4..128.
    dof_samples: u32 = 32,
    /// Resolution the blur is gathered at. Half or quarter costs a fraction
    /// and is joined back onto the sharp picture by how far each pixel is
    /// out of focus; fine detail inside the blur is softer still.
    dof_resolution: EffectResolution = .full,
    /// Blades of the aperture: out-of-focus highlights become polygons
    /// with this many sides (5 to 9 are what lenses have). 0 keeps them
    /// round.
    dof_blades: u32 = 0,
    /// Motion blur: the fraction of a frame the shutter stays open. 0 is
    /// off, 0.5 is the film look.
    motion_blur: f32 = 0,
    /// Samples along each pixel's path, 2..64.
    motion_blur_samples: u32 = 10,
    /// Let fast things smear over what is next to them, past their own
    /// outline, as a real shutter does. Off blurs each pixel only by its
    /// own motion, which leaves moving things with hard edges; it costs
    /// one more lookup per sample.
    motion_blur_spread: bool = true,
    /// Draw the scene by path tracing instead: every pixel follows a ray
    /// from surface to surface and gathers the light of the sun, the
    /// lamps, the sky and what glows. One frame is noisy; frames are
    /// averaged for as long as the camera, the scene and the lights
    /// stand still, and start over when one of them moves. A reference
    /// to compare the usual picture with, and a way to make a still.
    /// Uses the GPU's ray tracing where there is some and a shader
    /// that walks a tree built on the CPU where there is not (far
    /// slower, and only with `Options.path_tracing_fallback`);
    /// `Renderer.pathTracing` says which
    /// and how many frames have been gathered. Not traced: skinned
    /// meshes without ray tracing, water, liquids, smoke, clouds,
    /// particles and decals, and refraction through glass.
    path_tracing: bool = false,
    /// Surfaces a path may bounce off before it ends, 1..16. 1 is
    /// direct light only.
    path_tracing_bounces: u32 = 4,
    /// Paths followed for each pixel every frame, 1..64.
    path_tracing_samples: u32 = 1,
    /// Most light a path may bring back by way of a rough bounce, in the
    /// scene's units before exposure; what is seen directly or in a mirror
    /// is not limited. Lower hides the sparkle of rare bright paths sooner
    /// and loses a little of their light.
    path_tracing_clamp: f32 = 12,
    /// Clear the grain of a path-traced picture that has not gathered
    /// many frames yet, by averaging the light of neighbouring pixels
    /// on the same surface. Textures, edges, mirrors and what glows
    /// are left alone, and the averaging narrows as frames are
    /// gathered, so a finished picture is as it was traced. False
    /// shows the picture exactly as gathered. Two passes over the
    /// picture.
    path_tracing_denoise: bool = true,
    /// Show one input of the shading instead of the lit picture.
    debug_view: DebugView = .none,
};

/// What `Settings.debug_view` shows in place of the lit picture. The
/// values match the switch in `shaders/shade.glsl`.
pub const DebugView = enum(u32) {
    /// The normal, lit picture.
    none,
    /// Base color of the material, without lighting.
    albedo,
    /// Shading normal, mapped from -1..1 to 0..1 per axis.
    normal,
    roughness,
    metallic,
    ambient_occlusion,
    /// How much of the sun reaches each point: white lit, black shadowed.
    shadow,
    /// Which sun shadow cascade covers each point: red, green, blue,
    /// yellow from nearest to farthest, grey beyond the last.
    cascades,
    /// Screen-space motion vectors, magnified, in red and green.
    motion,
    /// Distance from the camera as repeating bands of color.
    depth,
    /// A random color per meshlet.
    meshlets,
    /// A random color per triangle.
    triangles,
};

/// How a picture rendered below the output size is brought up to it; see
/// `Settings.upscaling`.
pub const Upscaling = enum { spatial, temporal };

/// Fraction of the output resolution an effect is computed at. Reduced
/// rates are brought back to full resolution with a depth-aware upsample.
pub const EffectResolution = enum {
    full,
    /// Half the width and height: a quarter of the pixels.
    half,
    /// A quarter of the width and height: a sixteenth of the pixels.
    quarter,
};

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

/// Points in a view's frame where application code can record its own GPU
/// work.
pub const PassStage = enum {
    /// Opaque surfaces are lit. `color` is the HDR scene color and `depth`
    /// the scene depth; draw your own opaque geometry or decals here.
    after_opaque,
    /// Transparency and fog are in. Still HDR, before antialiasing, bloom
    /// and exposure, so effects drawn here are antialiased with the scene.
    after_transparency,
    /// The picture is tone-mapped. `color` is the view's output in display
    /// colors; draw lists come after this.
    after_tonemap,
};

/// What a custom pass gets to work with. Textures are in the shader-read
/// state unless noted; `cmd.beginRendering` moves them to attachments and
/// the renderer restores them afterwards.
pub const PassContext = struct {
    cmd: *rhi.CommandEncoder,
    device: *rhi.Device,
    stage: PassStage,
    /// Address of this view's `FrameConstants` (see `shaders/common.glsl`):
    /// camera matrices, jitter, time, the scene buffers and lighting.
    frame: u64,
    color: rhi.Texture,
    color_format: rhi.Format,
    /// Reverse-Z scene depth (near plane at 1, far at 0).
    depth: rhi.Texture,
    /// Screen-space motion vectors; write them for geometry that moves.
    motion: rhi.Texture,
    width: u32,
    height: u32,
};

/// Application code run at a `PassStage` of a view. It is called while the
/// frame is being recorded, with the renderer locked: record commands and
/// use `device`, but do not call back into the `Renderer`.
pub const Pass = struct {
    stage: PassStage,
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
    /// Which of the entity's model's mesh instances was hit.
    mesh_instance: u32,
    /// World-space point on the surface.
    position: Vec3,
    /// Distance from the camera plane.
    distance: f32,
};

/// Application surface code; see `Renderer.createMaterialShader`.
pub const MaterialShader = struct {
    /// Value for `Material.shader`.
    slot: u32,
};

/// The answer to a `Renderer.requestPick`, returned by `Renderer.takePick`.
pub const PickResult = struct {
    /// The pixel that was asked about.
    pixel: [2]u32,
    /// Null when nothing opaque is there, or the scene's contents changed
    /// before the answer came back.
    hit: ?Pick,
};

/// A box that projects a color or an image onto the opaque surfaces inside
/// it: bullet marks, blood, paint, road markings, blob shadows.
pub const DecalDesc = struct {
    /// Places a unit cube (-0.5..0.5) in the world. The image is projected
    /// along the cube's local -Z, so +Z should point away from the surface;
    /// X and Y are the image's width and height, Z how deep it reaches.
    transform: Mat4,
    /// Linear color and opacity, multiplied with the image if there is one.
    color: [4]f32 = .{ 1, 1, 1, 1 },
    image: ?Image = null,
    /// A normal map laid over the surface inside the box (cracks, bullet
    /// holes, tyre tracks), and how strongly it bends the surface.
    normal_image: ?Image = null,
    normal_strength: f32 = 1,
    /// Roughness to give the covered surface (wet paint, dry dust); null
    /// keeps what the surface has.
    roughness: ?f32 = null,
    /// How much the decal glows with its own color.
    emissive: f32 = 0,
    /// Surfaces facing away from the projection by more than this cosine
    /// are left alone, so a decal on a floor does not smear up a wall.
    angle_fade: f32 = 0.2,
};

/// Most decals a scene can hold. They are sorted into the same view-space
/// clusters as lights, so a pixel only tests the ones near it.
pub const max_decals = gpu.cluster_decal_words * 32;

/// A clear sky computed from the sun's position instead of loaded from a
/// photograph. See `Renderer.createSky`.
pub const SkyDesc = struct {
    /// Direction the sun's light travels, as in `Sun.direction`.
    sun_direction: Vec3 = .{ -0.4, -1.0, -0.3 },
    /// Haze: 1 is very clear air, 10 a hazy day with a pale sky and a wide
    /// glow around the sun.
    turbidity: f32 = 2.5,
    /// Ozone in the air, 1 for the Earth's. It absorbs orange and green
    /// light high up, which is what keeps the sky overhead blue at dusk;
    /// 0 leaves it out (a greener, yellower twilight).
    ozone: f32 = 1,
    /// Frames a change to the sky is spread over: 1 redraws it all in the
    /// frame it changes; more draws a part per frame, so a sky that
    /// changes all the time (a moving sun) costs a fraction per frame and
    /// follows a few frames behind. While it is under way the faces of
    /// the sky are from two different moments. Ignored (taken as 1) while
    /// a cloud layer is baked into the lighting.
    rebuild_frames: u32 = 1,
    /// Overall brightness of the sky.
    intensity: f32 = 1,
    /// Color of the ground below the horizon, as seen in reflections and
    /// bouncing light up into the scene.
    ground_color: [3]f32 = .{ 0.25, 0.23, 0.2 },
    /// Draw the sun's disc into the sky, so it shows and reflects.
    sun_disc: bool = true,
    /// Brightness of the stars, which show once the sun is down. 0 leaves
    /// the night sky empty.
    stars: f32 = 0,
    /// A moon: the direction its light travels (as for the sun) and how
    /// bright its disc is drawn; 0 for no moon. It gives no light by
    /// itself: pair it with a directional light for moonlight.
    moon_direction: Vec3 = .{ 0.3, -0.6, 0.5 },
    moon: f32 = 0,
};

/// Brightness of the sun above the atmosphere; matches env_sky.frag.
pub const sky_sun_strength = 8.0;

/// The sun that goes with a sky: its direction, and the color and strength
/// left after the light has crossed the atmosphere (white at noon, weak and
/// red near the horizon, nothing below it). Pass it to `Renderer.setSun`.
pub fn skySun(desc: SkyDesc) Sun {
    const to_sun = math.normalize(math.scale(desc.sun_direction, -1));
    if (to_sun[1] <= -0.02) return .{ .direction = desc.sun_direction, .intensity = 0 };
    // The same integral as the shader's light march, from the ground up.
    const planet = 6360e3;
    const top = 6420e3;
    const origin_height = planet + 200.0;
    const b = origin_height * @max(to_sun[1], 0.0);
    const exit = -b + @sqrt(@max(b * b - (origin_height * origin_height - top * top), 0));
    var rayleigh: f32 = 0;
    var mie: f32 = 0;
    var ozone: f32 = 0;
    const steps = 32;
    const step_length = exit / steps;
    for (0..steps) |index| {
        const t = step_length * (@as(f32, @floatFromInt(index)) + 0.5);
        const height = @sqrt(origin_height * origin_height + t * t + 2 * origin_height * t * @max(to_sun[1], 0.0)) - planet;
        rayleigh += @exp(-height / 8000.0) * step_length;
        mie += @exp(-height / 1200.0) * step_length;
        ozone += @max(1 - @abs(height - 25e3) / 15e3, 0) * step_length;
    }
    const beta = [3]f32{ 5.8e-6, 13.5e-6, 33.1e-6 };
    const absorbed = [3]f32{ 0.650e-6, 1.881e-6, 0.085e-6 };
    var color: Vec3 = undefined;
    inline for (0..3) |c| color[c] = @exp(-(beta[c] * rayleigh + 4e-6 * desc.turbidity * 1.1 * mie + absorbed[c] * @max(desc.ozone, 0) * ozone));
    const strongest = @max(color[0], @max(color[1], color[2]));
    if (strongest < 1e-6) return .{ .direction = desc.sun_direction, .intensity = 0 };
    // Fade out over the last degree as the disc sinks below the horizon.
    const above = std.math.clamp((to_sun[1] + 0.02) / 0.04, 0, 1);
    return .{
        .direction = desc.sun_direction,
        .color = math.scale(color, 1 / strongest),
        .intensity = sky_sun_strength * strongest * desc.intensity * above,
    };
}

/// How an emitter's particles are laid over the picture.
pub const ParticleBlend = enum {
    /// Covers what is behind it in proportion to its opacity (smoke, dust).
    alpha,
    /// Adds light without hiding anything (fire, sparks, magic).
    additive,
};

/// Most keys a particle curve can have.
pub const max_curve_keys = gpu.emitter_curve_keys;

/// Most remembered points a particle's trail can have.
pub const max_trail_points = 32;

/// Colors (linear, with opacity) at evenly spaced moments of a particle's
/// life. Fewer than two keys means no curve.
pub const ColorCurve = struct {
    keys: [max_curve_keys][4]f32 = @splat(.{ 1, 1, 1, 1 }),
    count: u32 = 0,

    /// Keys past `max_curve_keys` are dropped.
    pub fn init(keys: []const [4]f32) ColorCurve {
        var curve = ColorCurve{ .count = @intCast(@min(keys.len, max_curve_keys)) };
        @memcpy(curve.keys[0..curve.count], keys[0..curve.count]);
        return curve;
    }
};

/// Diameters at evenly spaced moments of a particle's life.
pub const SizeCurve = struct {
    keys: [max_curve_keys]f32 = @splat(0),
    count: u32 = 0,

    /// Copies `keys` into a curve. Keys past `max_curve_keys` are dropped.
    pub fn init(keys: []const f32) SizeCurve {
        var curve = SizeCurve{ .count = @intCast(@min(keys.len, max_curve_keys)) };
        @memcpy(curve.keys[0..curve.count], keys[0..curve.count]);
        return curve;
    }
};

/// A local reflection probe: a picture of the surroundings taken from one
/// place, which surfaces inside the probe's box mirror where neither the
/// screen nor a ray gives them a reflection (indoors, that is otherwise
/// the sky dimmed by how little of it is visible). See
/// `Renderer.createReflectionProbe`.
pub const ReflectionProbeDesc = struct {
    /// Where the picture is taken from, and the middle of the box.
    position: Vec3,
    /// Half the size of the box of space the probe answers for. Mirror
    /// rays are followed to the box's walls, so a box that matches the
    /// room gives reflections that sit where the walls are.
    extent: Vec3 = .{ 5, 3, 5 },
    /// Share of the box, inward from its faces, over which the probe
    /// fades into whatever lies outside it.
    fade: f32 = 0.15,
    intensity: f32 = 1,
    /// Pixels along each side of the six pictures taken, 16..1024.
    resolution: u32 = 256,
    /// Frames to let the scene's bounced light settle before the first
    /// pictures are taken.
    settle_frames: u32 = 40,
    /// Brightest value kept, so one hot highlight does not sparkle
    /// across every rough surface.
    max_radiance: f32 = 32,
};

/// Most reflection probes a scene can hold.
pub const max_reflection_probes = 16;

/// A source of particles in a scene. Everything except `capacity` can be
/// changed at any time with `Renderer.setEmitter`.
pub const EmitterDesc = struct {
    position: Vec3 = .{ 0, 0, 0 },
    /// Particles are born inside a sphere of this radius.
    radius: f32 = 0.1,
    /// Most particles alive at once; fixed when the emitter is created. If
    /// `rate` times the lifetime exceeds it, the oldest are replaced early.
    capacity: u32 = 1024,
    /// Births per second. 0 stops emitting; living particles finish.
    rate: f32 = 100,
    /// Seconds a particle lives, chosen between these two.
    lifetime: [2]f32 = .{ 1, 2 },
    /// Axis of the cone particles are launched into.
    direction: Vec3 = .{ 0, 1, 0 },
    /// Half-angle of that cone in radians; pi launches in every direction.
    spread: f32 = 0.4,
    /// Launch speed, chosen between these two.
    speed: [2]f32 = .{ 1, 2 },
    /// Constant acceleration. Negative Y falls, positive rises like smoke.
    gravity: Vec3 = .{ 0, 0, 0 },
    /// How quickly particles lose speed, per second.
    drag: f32 = 0.5,
    /// Diameter in world units at birth and at death.
    size: [2]f32 = .{ 0.05, 0.2 },
    /// Linear color and opacity at birth and at death. Values above 1 glow
    /// and feed bloom.
    color_start: [4]f32 = .{ 1, 1, 1, 1 },
    color_end: [4]f32 = .{ 1, 1, 1, 0 },
    blend: ParticleBlend = .alpha,
    /// Lit by the sun (with shadows) and the surroundings; turn off for
    /// particles that are themselves a light source.
    lit: bool = true,
    /// Distance over which a particle fades out as it nears a surface; 0
    /// gives a hard edge.
    softness: f32 = 0.3,
    /// Draw the particles farthest first, sorted on the GPU for every
    /// view. Alpha-blended particles that overlap (smoke, dust) need it
    /// to layer correctly; additive ones do not. Fixed when the emitter
    /// is created, like `capacity`.
    sorted: bool = false,
    /// Seconds of simulation to run before the emitter is first shown, so
    /// it starts full (smoke already risen, snow already falling) instead
    /// of empty. Costs that many frames of simulation on its first frame.
    prewarm: f32 = 0,
    /// A third color and size partway through a particle's life, at `mid`
    /// (0..1). Null goes straight from start to end.
    color_mid: ?[4]f32 = null,
    size_mid: ?f32 = null,
    mid: f32 = 0.5,
    /// Free-form color and size over a particle's life: 2 to
    /// `max_curve_keys` keys spaced evenly from birth to death, which
    /// replace the start, mid and end values above. See `ColorCurve.init`.
    color_curve: ColorCurve = .{},
    size_curve: SizeCurve = .{},
    /// Draw each particle as a copy of this model's first mesh instead of
    /// a flat sprite (debris, leaves, shards): the model's unit is `size`
    /// across, colored by the particle's color (times the mesh's vertex
    /// colors and `image`, laid out by the mesh's texture coordinates),
    /// matte when `lit`. The copies hide each other and are hidden by the
    /// scene exactly, so they need no sorting; `softness` and `stretch`
    /// do not apply. Nothing is drawn until the model has loaded.
    mesh: ?Model = null,
    /// Radians per second a mesh particle tumbles, about an axis of its
    /// own and at up to half again or half this pace.
    spin: f32 = 0,
    /// Draw a ribbon behind each particle through the places it has been:
    /// this many remembered points per particle (up to `max_trail_points`;
    /// 0 for none), reaching `trail_seconds` back. The ribbon is as wide
    /// as the particle at its head and narrows and fades to nothing at
    /// its tail; with an `image`, the image runs once along it. The point
    /// count is fixed when the emitter is created, like `capacity`.
    trail: u32 = 0,
    trail_seconds: f32 = 0.4,
    /// A fluid whose flow carries the particles while they are inside its
    /// box (embers in a fire, dust in smoke), and how quickly they take
    /// on its velocity, per second.
    fluid: ?Fluid = null,
    fluid_follow: f32 = 6,
    /// Bounce off the surfaces the first view of the scene saw last frame,
    /// keeping this share of their speed. Only what is on screen can be
    /// hit.
    collide: bool = false,
    bounce: f32 = 0.4,
    /// Draw each particle as a streak along its motion, this many seconds
    /// of travel long (sparks, rain). 0 draws it round.
    stretch: f32 = 0,
    /// Columns and rows of frames in `image`; they play once over the
    /// particle's life.
    sheet: [2]u32 = .{ 1, 1 },
    /// Sprite to draw; null draws a soft round blob.
    image: ?Image = null,
};

/// One camera's picture: what to draw, from where, and where it goes.
pub const ViewDesc = struct {
    /// Which persistent view state to use (temporal history, exposure,
    /// shadow cascades, occlusion results). Null is the renderer's built-in
    /// main view. Every camera that is drawn in the same frame needs its
    /// own `View`; see `Renderer.createView`.
    view: ?View = null,
    /// The 3D scene to draw, or null for a purely 2D view.
    scene: ?Scene = null,
    /// Shapes, images and text drawn over the scene, in order. The lists
    /// must not be modified until `render` returns.
    draw_lists: []const *const DrawList = &.{},
    /// Background when there is no scene. Linear RGBA. Only the first view
    /// drawn to a target in a frame clears it; later ones draw over it.
    clear_color: [4]f32 = .{ 0, 0, 0, 1 },
    /// Where the scene is seen from; unused without a scene.
    camera: Camera = .{},
    /// Where the picture goes: the window or a texture.
    target: Target = .backbuffer,
    /// Part of the target to draw into, for split screen and insets. Null
    /// covers the whole target.
    region: ?Region = null,
    /// Application passes run at fixed points of this view's frame.
    passes: []const Pass = &.{},
    settings: Settings = .{},
};

/// Everything `Renderer.render` draws in one frame.
pub const FrameDesc = struct {
    /// Drawn in order. A view may draw into a texture that a later view
    /// shows (see `Renderer.targetImage`), or over an earlier view.
    views: []const ViewDesc,
    /// Seconds since the previous frame; drives exposure adaptation.
    delta_time: f32 = 1.0 / 60.0,
};

/// How path tracing follows its rays on a device; see
/// `Renderer.pathTracing`.
pub const PathTracing = enum {
    /// By the GPU's own ray tracing.
    hardware,
    /// By an ordinary shader walking trees built on the CPU: the GPU has
    /// no ray tracing (or `Options.ray_tracing` is off) and
    /// `Options.path_tracing_fallback` is on.
    shader,
    /// Not at all: the GPU has no ray tracing and the fallback was not
    /// asked for. `Settings.path_tracing` then leaves the usual picture.
    unavailable,
};

/// Counters describing the last frame; see `Renderer.getStats`.
pub const Stats = struct {
    /// Views drawn in the last frame. The scene numbers below describe the
    /// first one that showed a scene.
    views: u32 = 0,
    /// Particle slots drawn (alive or not) in the first scene view.
    particles: u32 = 0,
    /// Mesh instances in the scene: one per mesh of every entity and of
    /// every copy in an instance group.
    instances: u32 = 0,
    /// Meshlet instances in the scene.
    meshlets: u32 = 0,
    /// Meshlets that survived culling in the main view / shadow cascades
    /// (measured two frames ago).
    meshlets_drawn: u32 = 0,
    shadow_meshlets_drawn: u32 = 0,
    /// Triangles in the scene at full detail, visible entities and
    /// instance copies together, before culling and level of detail.
    triangles: u64 = 0,
    /// Vertices deformed by skinning or morphing this frame.
    skinned_vertices: u32 = 0,
    /// Models and environments still loading.
    models_loading: u32 = 0,
    /// GPU memory the device has allocated, in bytes.
    gpu_memory_bytes: u64 = 0,
    /// Textures under `Options.texture_streaming`, the GPU memory they
    /// take now, and how many are waiting to load more detail.
    streamed_textures: u32 = 0,
    streamed_texture_bytes: u64 = 0,
    streamed_textures_pending: u32 = 0,
    /// With geometry streaming: the models whose geometry is out of GPU
    /// memory just now, and how many bytes of vertices and indices that
    /// is.
    geometry_models_released: u32 = 0,
    geometry_bytes_released: u64 = 0,
    /// Bytes of vertices and indices moved toward the start of their
    /// pools since the renderer started, to close gaps that freed models
    /// left and let the pools shrink.
    geometry_bytes_compacted: u64 = 0,
    /// Models of which only the coarser levels of detail are in GPU
    /// memory (`GeometryStreaming.coarse_distance`).
    geometry_models_coarse: u32 = 0,
    /// Triangles drawn from draw lists, over all views.
    draw_list_triangles: u32 = 0,
    /// Frames gathered into the path-traced picture of the view drawn
    /// last, 0 when none was path traced; and whether its rays were
    /// followed by the GPU's ray tracing or by a shader.
    path_traced_frames: u32 = 0,
    path_tracing_hardware: bool = false,
    /// CPU time spent building and submitting the last frame, excluding
    /// waits on the GPU and the display.
    cpu_ms: f32 = 0,
    /// Irradiance probes updated this frame; 0 when GI is inactive.
    gi_probes: u32 = 0,
};

test "a quality level is recommended by the kind of GPU" {
    const gibibyte = 1 << 30;
    try std.testing.expectEqual(Quality.low, Quality.recommended(.{ .kind = .integrated, .vendor_id = 0x8086, .memory_bytes = 16 * gibibyte, .ray_tracing = true }));
    try std.testing.expectEqual(Quality.low, Quality.recommended(.{ .kind = .software, .vendor_id = 0, .memory_bytes = 0, .ray_tracing = false }));
    try std.testing.expectEqual(Quality.medium, Quality.recommended(.{ .kind = .discrete, .vendor_id = 0x1002, .memory_bytes = 8 * gibibyte, .ray_tracing = false }));
    try std.testing.expectEqual(Quality.high, Quality.recommended(.{ .kind = .discrete, .vendor_id = 0x10de, .memory_bytes = 8 * gibibyte, .ray_tracing = true }));
    try std.testing.expectEqual(Quality.ultra, Quality.recommended(.{ .kind = .discrete, .vendor_id = 0x10de, .memory_bytes = 16 * gibibyte, .ray_tracing = true }));
}

test "the ultra preset is the default settings" {
    try std.testing.expectEqualDeep(Settings{}, Settings.preset(.ultra));
}
