//! Public types of the renderer: handles, options, descriptions, per-view
//! settings and statistics. `root.zig` re-exports the API subset.
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

pub const ModelTag = opaque {};
pub const EnvironmentTag = opaque {};
pub const SceneTag = opaque {};
pub const EntityTag = opaque {};
pub const ViewTag = opaque {};
pub const EmitterTag = opaque {};
pub const ReflectionProbeTag = opaque {};
pub const FluidTag = opaque {};
pub const WaterTag = opaque {};
pub const HairTag = opaque {};
pub const CollisionFieldTag = opaque {};
pub const LiquidTag = opaque {};
pub const InstanceGroupTag = opaque {};
/// Geometry, materials and animations shared by entities; see
/// `Renderer.loadModel`. Handles are 32-bit copyable values; calls given a
/// stale handle do nothing or return an error.
pub const Model = handle.Handle(ModelTag);
/// A sky and its image-based lighting; see `Renderer.loadEnvironment`.
pub const Environment = handle.Handle(EnvironmentTag);
/// A world of entities, lights and effects; see `Renderer.createScene`.
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
/// A shape that hair is kept out of; see `Renderer.createCollisionField`.
pub const CollisionField = handle.Handle(CollisionFieldTag);
/// Strands of hair, fur or grass in a scene; see `Renderer.createHair`.
pub const Hair = handle.Handle(HairTag);
/// A sheet of simulated water in a scene; see `Renderer.createWater`.
pub const Water = handle.Handle(WaterTag);
/// A volume of particle-simulated liquid; see `Renderer.createLiquid`.
pub const Liquid = handle.Handle(LiquidTag);
/// Many copies of one model; see `Renderer.createInstances`.
pub const InstanceGroup = handle.Handle(InstanceGroupTag);
/// Animation clips an entity plays; see `Renderer.setPose`.
pub const Pose = animation.Pose;
/// Application-supplied geometry for `Renderer.createModel`.
pub const MeshDesc = gltf.MeshDesc;
/// Surface description of a mesh.
pub const Material = gltf.Material;
/// 2D shapes, images and text drawn over a view.
pub const DrawList = draw_list.DrawList;
/// A texture for draw lists, lights and settings; see `Renderer.createImage`.
pub const Image = draw_list.Image;
/// A font baked into a distance-field atlas; see `Renderer.loadFont`.
pub const Font = font_module.Font;

/// Creation-time options for `Renderer.init`; fixed for its lifetime.
pub const Options = struct {
    /// Name reported to the Vulkan driver.
    application_name: [:0]const u8 = "limn",
    /// Vulkan validation, including synchronization; needs the Khronos layers.
    validation: bool = false,
    /// Window to present to. Null renders offscreen only.
    surface: ?rhi.Surface = null,
    /// Substring of the name of the GPU to prefer.
    preferred_device: ?[]const u8 = null,
    /// File for the driver's pipeline cache. Null keeps none.
    pipeline_cache_path: ?[]const u8 = null,
    /// Name GPU objects and label passes; needs `VK_EXT_debug_utils`.
    debug_names: bool = false,
    /// Ask for an HDR10 surface; see `Renderer.hdrActive` for the result.
    hdr_output: bool = false,
    /// Use hardware ray tracing where available. False disables ray-traced
    /// effects; path tracing then runs in a shader.
    ray_tracing: bool = true,
    /// Draw meshlets with mesh shaders where available, else indirect draws.
    mesh_shaders: bool = true,
    /// Build a BVH per model at load so `Settings.path_tracing` works without
    /// hardware ray tracing. No effect where the GPU traces rays.
    path_tracing_fallback: bool = false,
    /// CPU profiler hooks.
    profiler: ?Profiler = null,
    /// Size of each of the four sun shadow cascades, in texels per side.
    shadow_resolution: u32 = 2048,
    /// Size per side of the spot and point light shadow atlas, in texels.
    local_shadow_resolution: u32 = 2048,
    /// Anisotropic filtering for color and normal maps (1 disables).
    texture_anisotropy: f32 = 8,
    /// Anisotropic filtering for roughness/metalness, occlusion and emissive.
    data_texture_anisotropy: f32 = 1,
    /// Maximum probes along X, Y and Z in one light probe grid.
    gi_max_probes: [3]u32 = .{ 24, 12, 24 },
    /// Tiles per side of the local-light shadow atlas, 1..4. A spot light uses
    /// one tile, a point light six.
    local_shadow_tiles_per_side: u32 = 4,
    /// GPU storage of material textures. `.bc7` takes a quarter of the memory
    /// of `.none`; falls back to `.none` without BC format support.
    texture_compression: TextureCompression = .bc7,
    /// With compression on, store normal maps as BC5; false uses BC7.
    normal_maps_bc5: bool = true,
    /// Directory for processed assets; null caches nothing.
    asset_cache_dir: ?[]const u8 = null,
    /// Size the asset cache is trimmed to at startup, oldest files first; 0
    /// never trims. See `trimAssetCache`.
    asset_cache_max_bytes: u64 = 0,
    /// Allocator for worker-thread asset decoding and the resulting models;
    /// must be thread-safe. Null uses a general-purpose one.
    job_allocator: ?std.mem.Allocator = null,
    /// Compile a shading-pass variant per set of features a view uses, on a
    /// worker thread. False always uses the full pass.
    shader_variants: bool = true,
    /// Compute per-meshlet bounds of skinned and morphed meshes on the GPU each
    /// frame, so they are culled per meshlet instead of per mesh.
    skinned_meshlet_bounds: bool = false,
    /// Build cluster-hierarchy LODs, chosen per meshlet. Meshes under about
    /// 8000 triangles and skinned meshes keep whole-mesh LODs.
    cluster_lods: bool = true,
    /// Weight of normal deviation when LODs are built; 0 uses shape alone. See
    /// `gltf.LodOptions.normal_weight`.
    lod_normal_weight: f32 = gltf.default_lod_normal_weight,
    /// Weight of UV deviation when LODs are built: 1 counts a UV shift as a
    /// shape error of the same distance, 0 ignores it.
    lod_uv_weight: f32 = gltf.default_lod_uv_weight,
    /// Threads for animation poses, including the render thread: 0 picks
    /// automatically (at most 8), 1 uses no other thread.
    pose_threads: u32 = 0,
    /// Include skinned and morphed meshes in the ray-tracing structure, at one
    /// structure build per such mesh per frame.
    gi_dynamic_geometry: bool = true,
    /// How many of those structures are updated per frame, in turn; 0 for all.
    /// New ones are always built at once.
    gi_dynamic_refits: u32 = 0,
    /// Instance groups join the ray-tracing structure while the scene holds at
    /// most this many group instances; 0 never.
    gi_instance_limit: u32 = 65536,
    /// Null keeps every texture fully loaded.
    texture_streaming: ?TextureStreaming = null,
    /// Keep a model's geometry on the GPU only while something drawn with it is
    /// near a camera. Null keeps all geometry loaded.
    geometry_streaming: ?GeometryStreaming = null,
};

/// Where liquid pours into a `LiquidDesc` volume.
pub const LiquidSource = struct {
    /// Mouth of the jet, in world space.
    position: Vec3,
    /// Direction and speed of the jet.
    velocity: Vec3 = .{ 0, -1, 0 },
    radius: f32 = 0.12,
    /// Particles per second; 0 fills the jet solid at its speed.
    rate: f32 = 0,
};

/// A box of particle-simulated liquid; see `Renderer.createLiquid`. Costs far
/// more than a `WaterDesc` sheet of the same area.
pub const LiquidDesc = struct {
    /// Places the containing box: the unit cube centered on the origin. Its
    /// faces are the liquid's only walls.
    transform: Mat4,
    /// Maximum particles; fixed at creation.
    capacity: u32 = 30000,
    /// Half the rest distance between particles; fixed at creation.
    particle_radius: f32 = 0.04,
    /// Initial fill from the box's low corner, as a share of each axis.
    fill: [3]f32 = .{ 0, 0, 0 },
    /// Up to four jets pouring in.
    sources: []const LiquidSource = &.{},
    gravity: Vec3 = .{ 0, -9.8, 0 },
    /// Color taken on with depth, and how quickly; `murk` 0 is clear.
    color: [3]f32 = .{ 0.1, 0.38, 0.5 },
    murk: f32 = 3,
    /// Sun shadow opacity, 0..1; above 0 costs a draw per refreshed cascade.
    shadow: f32 = 0.5,
    /// Write depth, so fog, particles, antialiasing, depth of field and motion
    /// blur treat the liquid as a surface.
    write_depth: bool = true,
    /// How far the slope of the surface shifts what is seen through it.
    refraction: f32 = 0.3,
    /// Simulation steps per frame, and solver iterations per step.
    substeps: u32 = 2,
    iterations: u32 = 3,
    /// Share of its speed lost per second.
    damping: f32 = 0.05,
    /// How much neighbouring particles share velocity, 0..1.
    viscosity: f32 = 0.08,
    /// Fine shading ripples (see `WaterDesc.ripple_detail`); 0 for none.
    ripple_detail: f32 = 0.4,
    /// Entities displace the liquid by their models' bounding spheres (the
    /// nearest 16 that reach into the box).
    obstacles: bool = true,
    /// Simulation speed; 0 freezes it.
    time_scale: f32 = 1,
};

/// See `Options.geometry_streaming`.
pub const GeometryStreaming = struct {
    /// Geometry is loaded while anything drawn with it is within this distance
    /// of a camera. Whatever uses a released model is left out of the scene,
    /// including shadows, reflections and bounce light.
    distance: f32 = 200,
    /// A model is released only beyond `distance` times this.
    release_factor: f32 = 1.25,
    /// Maximum bytes reloaded per frame; a larger model still loads, alone.
    upload_bytes_per_frame: u64 = 16 * 1024 * 1024,
    /// Beyond this distance a model keeps only its coarser LODs on the GPU and
    /// takes no part in ray tracing; restored within 0.9 of it. 0 disables; at
    /// or past `distance` has no effect.
    coarse_distance: f32 = 0,
};

/// Keeps only the texture mips cameras can use in GPU memory. Applies to
/// compressed textures; full mip chains stay in system memory.
pub const TextureStreaming = struct {
    /// GPU memory budget; when exceeded, every texture drops the same number of
    /// top mips. 0 means no limit.
    budget_bytes: u64 = 0,
    /// Mips this size or smaller always stay loaded.
    min_size: u32 = 64,
    /// Maximum bytes uploaded per frame; one texture always goes through.
    upload_bytes_per_frame: u64 = 16 * 1024 * 1024,
    /// Added to the mip each texture wants: positive keeps less detail.
    mip_bias: f32 = 0,
    /// Frames a texture must want less detail before mips are dropped, unless
    /// the budget forces it sooner.
    evict_delay_frames: u32 = 120,
    /// Request detail only for what is inside a camera's view.
    visible_only: bool = false,
    /// Request detail only for what a camera drew, known a few frames late.
    skip_occluded: bool = false,
    /// Keep only the always-loaded mips in system memory and read the rest from
    /// the asset cache on demand, on the rendering thread. Needs
    /// `Options.asset_cache_dir` and compressed textures.
    from_cache: bool = false,
};

/// See `Options.texture_compression`. `.none` is RGBA8.
pub const TextureCompression = enum { none, bc7 };
/// See `Renderer.bakeLightmap`.
pub const LightmapDesc = struct {
    /// Texels per side.
    resolution: u32 = 256,
    /// Frames the bake is spread over, and rays per texel per frame.
    frames: u32 = 256,
    rays: u32 = 16,
    /// Maximum ray length, in world units.
    reach: f32 = 200,
};

/// See `Renderer.setInstancesImpostor`.
pub const ImpostorDesc = struct {
    /// Copies smaller than this many pixels across are drawn as impostor cards.
    pixels: f32 = 24,
    /// Pixels per side of each of the 64 captured directions.
    resolution: u32 = 64,
};

/// Strands of hair, fur or grass; see `Renderer.createHair`. Each strand is a
/// row of points drawn as a camera-facing ribbon. Strands cast no shadows.
pub const HairDesc = struct {
    /// All strands' points, each root to tip, in hair space. Copied.
    points: []const [3]f32,
    /// Points per strand; at least 2.
    points_per_strand: u32,
    /// Hair space to world.
    transform: Mat4 = math.identity,
    /// Width at the root, in hair-space units.
    width: f32 = 0.002,
    /// Tip width as a share of `width`.
    taper: f32 = 0.3,
    root_color: [3]f32 = .{ 0.10, 0.06, 0.03 },
    tip_color: [3]f32 = .{ 0.30, 0.20, 0.11 },
    /// Highlight roughness, as for a material.
    roughness: f32 = 0.35,
    /// Draws each strand this many times, offset sideways.
    copies: u32 = 1,
    /// Maximum sideways offset of the copies, in hair-space units; less toward
    /// the root.
    spread: f32 = 0,
    /// Null leaves the strands static.
    simulation: ?HairSimulation = null,
};

/// Strand dynamics; see `HairDesc.simulation` and `Renderer.setHairSimulation`.
/// Roots stay fixed; strands keep their length and are pulled toward their
/// given shape. At most 64 points per strand. World units and seconds.
pub const HairSimulation = struct {
    gravity: Vec3 = .{ 0, -9.8, 0 },
    /// Average wind acceleration, added to gravity.
    wind: Vec3 = .{ 0, 0, 0 },
    /// Gust variation: 0 is steady, 1 drops to nothing between gusts.
    gustiness: f32 = 0.6,
    /// Pull toward the given shape: share of the way restored per 1/60 s; 0
    /// hangs free, 1 is rigid. `root_stiffness` applies at the root and gives
    /// way to `stiffness` over the first third of the strand.
    stiffness: f32 = 0.006,
    root_stiffness: f32 = 0.35,
    /// Share of its speed a strand loses each step.
    damping: f32 = 0.04,
    /// Collision spheres: center and radius, in world space. At most 6; copied.
    colliders: []const [4]f32 = &.{},
    /// Collision shape from `Renderer.createCollisionField`; `field_transform`
    /// places it in the world.
    field: ?CollisionField = null,
    field_transform: Mat4 = math.identity,
    /// Distance strands are kept from the field, in world units.
    margin: f32 = 0.002,
    /// Strand-to-strand repulsion; 0 for none.
    volume: f32 = 0.4,
};

/// A sheet of simulated water; see `Renderer.createWater`.
pub const WaterDesc = struct {
    /// Cells of the simulation along each side, 16..1024.
    resolution: [2]u32 = .{ 256, 256 },
    /// Places the surface in the world: a unit square in the XZ plane
    /// centered on the origin, +Y up. The Y scale is the unit of height.
    transform: Mat4 = math.identity,
    /// Ripple speed in world units per second; at most about 2/3 cell per step.
    wave_speed: f32 = 3,
    /// Share of the motion lost per second.
    damping: f32 = 0.5,
    /// Raindrops per second landing at random places; 0 for none.
    rain: f32 = 0,
    /// Strength of ripples from entities moving through the surface, by their
    /// models' bounding spheres; 0 for none.
    object_ripples: f32 = 1,
    /// Spray where an entity moves through the surface; 0 for none. Needs
    /// `object_ripples`. One splash location per frame.
    splashes: f32 = 0,
    /// Swell height and wave length, in world units; 0 for none.
    swell: f32 = 0,
    swell_length: f32 = 6,
    /// Speed of the simulation; 0 freezes it.
    time_scale: f32 = 1,
    /// Color taken on with depth, and how quickly per world unit.
    color: Vec3 = .{ 0.02, 0.1, 0.12 },
    murk: f32 = 0.5,
    /// Roughness of reflections.
    roughness: f32 = 0.04,
    /// Refraction strength.
    refraction: f32 = 1.2,
    /// Foam at shallow edges and churning water, 0..1.
    foam: f32 = 0.6,
    /// Caustics under the water in sunlight, 0..1.
    caustics: f32 = 0.6,
    /// Fine shading-only ripples: 0 is glass-still, 1 a breezy pond.
    ripple_detail: f32 = 0.5,
    /// Tint the view by water depth when the camera is under the surface.
    underwater: bool = true,
    /// Write depth, so fog, particles and transparents treat it as a surface.
    write_depth: bool = true,
};

/// What happens at the sides of a fluid's box.
pub const FluidWalls = enum(u32) {
    open,
    /// Solid underneath, open elsewhere.
    floor,
    /// Sealed on every side.
    closed,
};

/// A place inside a fluid's box where smoke, heat or fuel enters.
pub const FluidSource = struct {
    /// Center, in box coordinates 0..1.
    position: Vec3 = .{ 0.5, 0.08, 0.5 },
    /// Radius as a share of the box's height.
    radius: f32 = 0.07,
    /// Velocity imposed inside the source, in box heights per second.
    velocity: Vec3 = .{ 0, 0.5, 0 },
    /// Amounts added per second at the center. Fuel burns where it is hot,
    /// giving heat and smoke.
    smoke: f32 = 0,
    fuel: f32 = 0,
    temperature: f32 = 0,
};

/// A solid inside a fluid's box, in box coordinates 0..1.
pub const FluidObstacle = union(enum) {
    /// `radius` is a share of the box's height.
    sphere: struct { center: Vec3, radius: f32 },
    box: struct { min: Vec3, max: Vec3 },
};

/// Frames recorded from a running fluid; see `Renderer.recordFluidFlipbook`.
pub const FluidFlipbookDesc = struct {
    columns: u32 = 8,
    rows: u32 = 8,
    /// Simulation steps from one frame to the next, at least 1.
    interval: u32 = 2,
    /// Size of one frame in pixels; null uses the fluid's resolution.
    frame_size: ?[2]u32 = null,
};

/// A box of simulated smoke and fire; see `Renderer.createFluid`.
pub const FluidDesc = struct {
    /// Cells along each axis, 8..256. A depth of 1 makes the fluid 2D.
    resolution: [3]u32 = .{ 64, 96, 64 },
    /// Places the box: a unit cube centered on the origin, +Y up.
    transform: Mat4 = math.identity,
    /// Up to 8.
    sources: []const FluidSource = &.{},
    /// Up to 8.
    obstacles: []const FluidObstacle = &.{},
    /// Treat scene geometry inside the box as solid. Needs ray tracing and a
    /// view with global illumination; six short rays per cell per frame.
    scene_obstacles: bool = false,
    walls: FluidWalls = .floor,
    /// Lift per unit of heat and sink per unit of smoke, in box heights per
    /// second squared.
    buoyancy: f32 = 1.6,
    weight: f32 = 0.1,
    /// Vorticity confinement strength; 0 for none.
    vorticity: f32 = 12,
    /// Constant acceleration, in box heights per second squared.
    wind: Vec3 = .{ 0, 0, 0 },
    /// Shares lost per second: velocity, smoke, heat, fuel.
    velocity_loss: f32 = 0.25,
    smoke_loss: f32 = 0.45,
    cooling: f32 = 1.4,
    burn_rate: f32 = 5,
    /// Heat and smoke given off per unit of fuel burned.
    heat: f32 = 3,
    soot: f32 = 0.6,
    /// MacCormack advection of smoke and heat: sharper, at one more pass.
    sharp_advection: bool = true,
    /// MacCormack advection of velocity too. Needs `sharp_advection`.
    sharp_velocity: bool = false,
    /// Jacobi pressure iterations per step, 1..200.
    pressure_iterations: u32 = 24,
    /// Speed of the simulation; 0 freezes it.
    time_scale: f32 = 1,

    /// Scattering color, and extinction per unit of smoke per world unit.
    smoke_color: Vec3 = .{ 0.55, 0.55, 0.58 },
    absorption: f32 = 8,
    /// Tint and brightness of the glow of hot gas.
    fire_color: Vec3 = .{ 1, 1, 1 },
    fire_intensity: f32 = 6,
    /// Strength of the light the fire casts on the scene; 0 for none.
    light: f32 = 1,
    /// How far that light reaches; 0 picks three times the box's height.
    light_range: f32 = 0,
    /// Size of that light as a share of the box's height; above 0 softens its
    /// ray-traced shadows (see `Settings.light_shadow_rays`).
    light_size: f32 = 0,
    /// Height of that light: 1 is a line as tall as the glow, 0 a point.
    light_tall: f32 = 1,
    /// Self-shadowing from the sun, 0..1.
    shadow: f32 = 1,
    /// Forward-scattering anisotropy.
    anisotropy: f32 = 0.35,
    /// Ambient light multiplier.
    ambient: f32 = 1,
};

/// A layer of volumetric clouds; see `Renderer.setClouds`.
pub const CloudDesc = struct {
    /// Share of the sky the clouds fill, 0..1.
    coverage: f32 = 0.5,
    /// Variation of coverage: 0 is even, higher gathers the clouds into banks.
    variation: f32 = 0.6,
    /// Extinction per meter inside a cloud.
    density: f32 = 0.012,
    /// Cloud base altitude and layer height, in world units above y = 0.
    bottom: f32 = 1500,
    thickness: f32 = 1400,
    /// Size of the cloud shapes; 1 gives clouds a few kilometres across.
    scale: f32 = 1,
    /// Edge erosion by detail noise, 0..1.
    detail: f32 = 0.35,
    /// Drift, in world units per second.
    wind: Vec3 = .{ 12, 0, 5 },
    /// Tint of the scattered light.
    color: Vec3 = .{ 1, 1, 1 },
    /// Sky light multiplier.
    ambient: f32 = 1,
    /// Forward-scattering anisotropy.
    anisotropy: f32 = 0.6,
    /// Darkness of cloud shadows, 0..1; 0 casts none.
    shadow: f32 = 0.8,
    /// Seconds between rebuilds of the sky's lighting with the clouds in it; 0
    /// never rebuilds. Each rebuild costs a sky bake.
    environment_interval: f32 = 4,
    /// Coverage of a high cirrus layer, 0..1. Casts no shadow.
    cirrus: f32 = 0,
    /// Storm cells, 0..1: anvil-topped towers where coverage is heaviest.
    anvil: f32 = 0,
    /// Lightning flashes per minute near the camera, and their brightness. They
    /// light only the cloud; see `Renderer.cloudFlash`.
    lightning: f32 = 0,
    lightning_brightness: f32 = 40,
    /// Radius of the planet the layer wraps around.
    planet_radius: f32 = 6_360_000,
};

/// A lightning flash in a cloud layer; see `Renderer.cloudFlash`.
pub const CloudFlash = struct { position: Vec3, brightness: f32 };

/// See `Settings.transparency`.
pub const TransparencyMode = enum {
    /// Whole meshes, back to front.
    sorted,
    /// Weighted blended: one pass, approximate layering.
    weighted,
    /// Depth peeling: exact for the nearest `Settings.transparency_layers`
    /// surfaces, one pass per layer.
    peeled,
};

/// Haze model of aerial perspective; see `Settings.aerial_model`.
pub const AerialModel = enum { atmosphere, sky };

/// LOD used for local light shadows; see `Settings.shadow_lod`.
pub const ShadowLod = enum { camera, light };

/// See `Settings.output_encoding`.
pub const OutputEncoding = enum { auto, srgb, hdr10 };

/// Hooks for an external CPU profiler such as Tracy. `begin` gets a static zone
/// name and returns a value that `end` receives back.
pub const Profiler = struct {
    /// Passed back to `begin` and `end` unchanged.
    context: ?*anyopaque = null,
    begin: *const fn (context: ?*anyopaque, name: [:0]const u8) u64,
    end: *const fn (context: ?*anyopaque, zone: u64) void,
};

/// Load state of a model or environment.
pub const AssetState = enum {
    /// Entities that use it are not drawn yet.
    loading,
    ready,
    /// The load failed (see `Renderer.modelError`) or the handle is invalid.
    failed,
};

/// Where a view is seen from. Perspective with no far plane; the aspect ratio
/// follows the view's size.
pub const Camera = struct {
    position: Vec3 = .{ 0, 0, 3 },
    /// Need not be normalized.
    forward: Vec3 = .{ 0, 0, -1 },
    /// Need not be perpendicular to `forward`; if parallel, +Z is used.
    up: Vec3 = .{ 0, 1, 0 },
    /// Vertical field of view in radians.
    fov_y: f32 = std.math.degreesToRadians(60.0),
    /// Near plane distance, in world units.
    near: f32 = 0.1,
    /// Shifts the picture off the camera's axis, right and down, in halves of
    /// the picture's height. See `stereo`.
    lens_shift: [2]f32 = .{ 0, 0 },

    /// A camera at `position` looking toward `target`, which must differ.
    pub fn lookAt(position: Vec3, target: Vec3) Camera {
        return .{ .position = position, .forward = math.sub(target, position) };
    }

    /// Left and right eye cameras `eye_separation` apart in world units,
    /// converging at distance `convergence`. Draw each as its own view with its
    /// own `View` handle.
    pub fn stereo(self: Camera, eye_separation: f32, convergence: f32) [2]Camera {
        const forward = math.normalize(self.forward);
        var right = math.cross(forward, self.up);
        if (math.length(right) < 1e-6) right = math.cross(forward, .{ 0, 0, 1 });
        right = math.normalize(right);
        const half = eye_separation * 0.5;
        const shift = half / (@max(convergence, 1e-3) * @tan(self.fov_y * 0.5));
        var left_eye = self;
        left_eye.position = math.sub(self.position, math.scale(right, half));
        left_eye.lens_shift[0] = self.lens_shift[0] + shift;
        var right_eye = self;
        right_eye.position = math.add(self.position, math.scale(right, half));
        right_eye.lens_shift[0] = self.lens_shift[0] - shift;
        return .{ left_eye, right_eye };
    }
};

/// The scene's one shadow-casting directional light; see `Renderer.setSun`.
pub const Sun = struct {
    /// Direction the light travels.
    direction: Vec3 = .{ -0.4, -1.0, -0.3 },
    /// Linear color; `intensity` scales it.
    color: Vec3 = .{ 1.0, 0.96, 0.9 },
    /// In the units of the environment map. 0 turns the sun off.
    intensity: f32 = 0,
};

pub const LightKind = enum {
    point,
    /// A cone along `direction`, between `inner_angle` and `outer_angle`.
    spot,
    /// Parallel light, like the sun but without shadow maps. `position` and
    /// `range` are ignored.
    directional,
    /// A `source_length` by `source_height` rectangle centered on `position`,
    /// shining along `direction`. Its shadows are ray traced.
    rectangle,
};

/// A point, spot, directional or rectangle light.
pub const Light = struct {
    kind: LightKind = .point,
    position: Vec3,
    /// Ignored for point lights.
    direction: Vec3 = .{ 0, -1, 0 },
    /// Linear color; `intensity` scales it.
    color: Vec3 = .{ 1, 1, 1 },
    intensity: f32 = 1,
    /// Distance at which the light's contribution reaches zero.
    range: f32 = 5,
    /// Spot cone half-angles in radians: full brightness inside `inner_angle`,
    /// none outside `outer_angle`.
    inner_angle: f32 = 0.35,
    outer_angle: f32 = 0.6,
    /// Uses one atlas tile for a spot light and six for a point light; at most
    /// 16 tiles per frame, assigned in order.
    cast_shadows: bool = false,
    /// Radius of the emitting sphere; 0 is an ideal point.
    source_radius: f32 = 0,
    /// Point lights only: makes the source a tube this long along `direction`,
    /// `source_radius` thick. Shadows are still cast from the center.
    source_length: f32 = 0,
    /// Rectangle lights only: panel height (`source_length` is its width).
    source_height: f32 = 0,
    /// Spot lights only: an image projected by the light.
    cookie: ?Image = null,
    /// Brightness by angle from `direction`: a strip image, left edge along the
    /// axis, right edge straight behind. See `Renderer.loadLightProfile`.
    profile: ?Image = null,
};

/// What `Renderer.spawn` makes an entity from. Everything but the model can be
/// changed afterwards.
pub const EntityDesc = struct {
    /// May still be loading; the entity appears once it is ready.
    model: Model,
    /// Model space to world.
    transform: Mat4 = math.identity,
    visible: bool = true,
    /// Multiplies the base color of every material.
    tint: [3]f32 = .{ 1, 1, 1 },
    /// Passed to custom material shaders as `MaterialContext.instance_params`.
    params: [4]f32 = .{ 0, 0, 0, 0 },
    /// False keeps the scene's decals off this entity.
    receive_decals: bool = true,
};

/// One animation clip of a model; see `Renderer.animationInfo`.
pub const AnimationInfo = struct {
    /// Owned by the model; valid until it is destroyed.
    name: []const u8,
    /// In seconds.
    duration: f32,
};

/// See `Renderer.modelInfo`.
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

/// See `Renderer.environmentInfo`.
pub const EnvironmentInfo = struct {
    /// Direction toward the brightest part of the panorama, usually the sun.
    /// Negate it to get a matching `Sun.direction`.
    brightest_direction: Vec3,
};

/// Effect quality level to start `Settings` from; see `Settings.preset`.
pub const Quality = enum {
    /// For integrated and software GPUs: no bounce light or reflections, scene
    /// rendered at 0.75 scale.
    low,
    /// For discrete GPUs without ray tracing: half-resolution reflections, no
    /// bounce light.
    medium,
    /// Everything on, with reflections at half resolution.
    high,
    /// Everything on at full resolution: the `Settings` defaults.
    ultra,

    /// A guess from the adapter's kind, ray tracing support and memory.
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

/// Per-view quality and look (`ViewDesc.settings`); may change every frame.
/// Distances are in world units.
pub const Settings = struct {
    /// The settings of a quality level; only cost-related fields differ.
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

    /// Sun and local light shadows.
    shadows: bool = true,
    /// Distance from the camera covered by the shadow cascades.
    shadow_distance: f32 = 60,
    /// Penumbra radius in world units.
    shadow_softness: f32 = 0.035,
    /// Number of sun shadow cascades, 1..4.
    shadow_cascades: u32 = 4,
    /// Leave out of each sun cascade meshes smaller than this many of its
    /// texels across. 0 draws everything; around 2 is rarely visible.
    shadow_small_feature_texels: f32 = 0,
    /// Cull sun shadow casters whose shadow cannot reach anything the camera
    /// sees. Applies to cascades redrawn every frame: all without
    /// `shadow_cascade_stagger`, only the nearest with it.
    shadow_receiver_culling: bool = true,
    /// Reach of screen-space contact shadows for the sun, in world units; 0.2
    /// to 0.5 is typical, 0 is off. Opaque surfaces only.
    contact_shadows: f32 = 0,
    /// Ray trace the shadows of shadow-casting lights that have no shadow map
    /// (directional, rectangle, lights past the tile budget). Needs ray tracing
    /// and `global_illumination`.
    ray_traced_light_shadows: bool = true,
    /// Rays per pixel toward each ray-shadowed light that has a size, 1..15.
    light_shadow_rays: u32 = 4,
    /// Accumulate soft light shadows over frames; moving shadows trail by a few
    /// frames. Needs `temporal_antialiasing`.
    light_shadow_filter: bool = true,
    /// Sun shadow filter samples: 4, 8 or 16.
    shadow_samples: u32 = 16,
    /// Screen-space ambient occlusion (GTAO).
    ambient_occlusion: bool = true,
    /// World-space radius searched for occluders.
    ao_radius: f32 = 1.2,
    /// Blend occlusion over frames; it then lags fast motion slightly.
    ao_temporal_filter: bool = true,
    /// Strength of bounce light from nearby occluders; 0 for none. Needs
    /// `ambient_occlusion` and `temporal_antialiasing`.
    ao_bounce: f32 = 1,
    /// Exponent applied to the occlusion term; higher is darker.
    ao_intensity: f32 = 1.3,
    /// Cull geometry hidden behind what was visible last frame. Never drops
    /// visible geometry.
    occlusion_culling: bool = true,
    /// Use a virtual shadow map for the sun: four nested 4096-texel levels out
    /// to `shadow_distance`, drawn page by page on demand and cached. Cascades
    /// are used where pages are not yet drawn.
    virtual_shadow_maps: bool = false,
    /// Shade once per 2x2 pixels where last frame's picture was flat and
    /// smooth. Needs GPU shading-rate support and `temporal_antialiasing`.
    variable_rate_shading: bool = false,
    /// Relative color variation a 16-pixel tile may have and still be shaded
    /// coarsely.
    variable_rate_contrast: f32 = 0.06,
    /// Scene resolution as a fraction of the output size; above 1 supersamples.
    /// Draw lists are always drawn at full size.
    render_scale: f32 = 1,
    /// Scaling of a picture rendered below output size. `.temporal`, `.fsr2`
    /// and `.fsr3` need `temporal_antialiasing`; `.fsr2` and `.fsr3` also need
    /// storage images and `-Dfidelityfx`, else fall back to `.temporal`. `.fsr`
    /// is FSR 1, sharpened by `sharpen`.
    upscaling: Upscaling = .temporal,
    /// FSR 3 frame generation: shows a generated picture between every two
    /// rendered. Needs `.fsr3` upscaling on a view that fills the backbuffer;
    /// presentation is then vsynced. Draw lists are interpolated with the scene.
    frame_generation: bool = false,
    /// Screen-space error in pixels at which meshes switch to a coarser LOD; 0
    /// always draws full detail.
    lod_error_pixels: f32 = 1,
    /// Cross-fade LODs by dithering over this share of the switching distance
    /// (0.25 is typical); 0 switches at once.
    lod_cross_fade: f32 = 0,
    /// LOD used for local light shadows: `.camera` matches what the camera
    /// sees, `.light` picks by distance from the light. Sun cascades always
    /// follow the camera.
    shadow_lod: ShadowLod = .camera,
    /// How overlapping transparent surfaces are combined.
    transparency: TransparencyMode = .sorted,
    /// Layers of the `.peeled` mode, 1..16.
    transparency_layers: u32 = 4,
    /// Transparent surfaces cast shadows as dark as they are opaque.
    transparent_shadows: bool = true,
    /// Refractive surfaces also show the transparent surfaces behind them, at
    /// one scene-color copy per such surface. `.sorted` transparency only.
    layered_refraction: bool = false,
    /// Transparent surfaces tint the sunlight passing through them. Sun shadows
    /// only; needs `transparent_shadows`.
    colored_shadows: bool = false,
    /// Screen-space reflections; what is not on screen falls back to the sky.
    screen_space_reflections: bool = true,
    /// Resolution the reflection rays are traced at.
    reflection_resolution: EffectResolution = .full,
    /// Surfaces rougher than this reflect only the sky.
    reflection_max_roughness: f32 = 0.5,
    /// Samples along each reflection ray, 4..256.
    reflection_steps: u32 = 32,
    /// How far a reflection ray travels, in world units.
    reflection_distance: f32 = 30,
    /// Assumed thickness of surfaces a ray passes behind.
    reflection_thickness: f32 = 0.3,
    /// Average reflections over frames; moving reflections trail slightly.
    reflection_temporal_filter: bool = true,
    /// Trace a ray where the screen has no reflection. Needs ray tracing and
    /// `global_illumination`. Hits are shaded with sun and probe light, without
    /// highlights. Animated meshes are hit only with
    /// `Options.gi_dynamic_geometry`, transparent ones with `reflect_transparent`.
    reflection_ray_tracing: bool = true,
    /// Ray-traced reflections show the nearest transparent surface along the
    /// ray, at a second ray where one is hit.
    reflect_transparent: bool = true,
    /// Roughness blur samples, 0..32; 0 leaves reflections sharp.
    reflection_blur_samples: u32 = 8,
    /// Draw the scene's fluids; they are simulated either way.
    fluids: bool = true,
    fluid_resolution: EffectResolution = .half,
    /// Samples along each ray through a fluid, 4..256, and toward the sun from
    /// each, 1..32.
    fluid_steps: u32 = 48,
    fluid_light_steps: u32 = 6,
    /// Smoke shadows what the sun lights behind it.
    fluid_shadows: bool = true,
    /// Fluids write motion vectors, so temporal antialiasing follows them.
    fluid_motion_vectors: bool = true,
    /// Ray-traced reflections and probe rays see smoke and fire.
    fluid_rays: bool = true,
    /// Draw the scene's cloud layer.
    clouds: bool = true,
    cloud_resolution: EffectResolution = .half,
    /// Samples along each cloud ray, 8..256, and toward the sun from each,
    /// 1..16.
    cloud_steps: u32 = 48,
    cloud_light_steps: u32 = 6,
    /// How far clouds are drawn, in world units; they fade out before it.
    cloud_distance: f32 = 60_000,
    /// Average clouds over frames; without it they are grainy.
    cloud_temporal_filter: bool = true,
    /// Diffuse global illumination from ray-traced irradiance probes. Without
    /// ray queries, sky light is used instead.
    global_illumination: bool = true,
    /// Distance between probes; grows automatically for large scenes.
    gi_probe_spacing: f32 = 1.5,
    /// Rays traced per probe per frame, 16..256.
    gi_rays: u32 = 64,
    /// Multiplies the probes' indirect light.
    gi_intensity: f32 = 1,
    /// Resolution probe irradiance is evaluated at. Below `.full` it uses
    /// geometric normals, losing normal-map detail in indirect light.
    gi_resolution: EffectResolution = .full,
    /// Each probe is re-traced once every this many frames, 1..16.
    gi_update_interval: u32 = 4,
    /// Share of a probe's previous value kept each frame, 0..1. Large changes
    /// bypass it; see `gi_change_tolerance`.
    gi_hysteresis: f32 = 0.995,
    /// In a scene too large for the grid at `gi_probe_spacing`: true keeps that
    /// spacing in a grid that follows the camera, plus a coarse grid over the
    /// whole scene; false uses only the coarse grid.
    gi_follow_camera: bool = true,
    /// How much wider than `gi_probe_spacing` the spacing must get to cover the
    /// scene before the following grid is used.
    gi_follow_threshold: f32 = 1.25,
    /// Frames between updates of the coarse grid behind a following one.
    gi_coarse_interval: u32 = 1,
    /// When the coarse grid's spacing exceeds this multiple of the main grid's,
    /// a third following grid at the geometric mean spacing is added. 0 never
    /// adds one.
    gi_middle_ratio: f32 = 6,
    /// Local lights light what probe and reflection rays hit, at a shadow ray
    /// per light in range per hit.
    gi_local_lights: bool = true,
    /// Local lights whose light bounces: the first this many of the scene's
    /// list, up to 1023.
    gi_bounce_lights: u32 = 32,
    /// Trace probes that sit inside geometry only every eighth turn.
    gi_skip_buried_probes: bool = false,
    /// Move probes out of walls and away from nearby surfaces, within their
    /// cells. Costs a pass per probe update and eight texture fetches per
    /// shaded pixel.
    gi_probe_relocation: bool = false,
    /// Relative difference between a probe's fast and steady estimates (0.25 =
    /// 25%) beyond which the steady one follows at once. 0 turns it off.
    gi_change_tolerance: f32 = 0.3,
    /// Resolution of the ambient occlusion pass.
    ao_resolution: EffectResolution = .half,
    fog_resolution: EffectResolution = .half,
    /// Samples along each fog ray, 4..128.
    fog_steps: u32 = 12,
    /// Ambient occlusion directions per pixel, 1..8.
    ao_slices: u32 = 2,
    /// Ambient occlusion samples per direction, 1..32.
    ao_steps: u32 = 5,
    /// Refresh the far sun cascades every 2nd, 4th and 8th frame. A cascade
    /// with a moving caster is still redrawn every frame.
    shadow_cascade_stagger: bool = true,
    /// Temporal antialiasing (TAA). Several other settings rely on it to
    /// average out their noise.
    temporal_antialiasing: bool = true,
    /// Mip bias for material textures under TAA; negative is sharper.
    texture_mip_bias: f32 = -0.25,
    /// Widen highlights where normals vary faster than pixels can show.
    specular_antialiasing: bool = true,
    /// Fraction of the image replaced by its blurred self; 0 disables bloom.
    bloom: f32 = 0.04,
    /// Bloom blur levels, 1..6; more spreads the glow wider.
    bloom_levels: u32 = 6,
    /// Adapt exposure to the picture's average brightness. False uses
    /// `exposure_compensation` alone.
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
    /// Haze per world unit fading distant opaque surfaces into the sky (0.0005
    /// shows at a kilometre); 0 for none. Needs an environment.
    aerial_perspective: f32 = 0,
    /// `.atmosphere` is air lit by sun and sky, scattering blue more than red;
    /// `.sky` fades to the sky behind.
    aerial_model: AerialModel = .atmosphere,
    /// Strength of the post-TAA sharpening filter, 0..1.
    sharpen: f32 = 0.35,
    /// Draw text from a three-channel distance field, which keeps corners sharp
    /// at large sizes. False uses the single-channel field.
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
    /// Color lookup table applied to the finished picture: a strip of N slices,
    /// N*N wide and N tall, in sRGB. Load it with `createImage(..., false)`.
    color_lut: ?Image = null,
    /// Blend of the table's result, 0..1.
    color_lut_strength: f32 = 1,
    /// Red/blue fringing toward the corners, 0..1.
    chromatic_aberration: f32 = 0,
    /// Lens flare strength; 0 is none.
    lens_flare: f32 = 0,
    /// `.auto` is sRGB, or HDR10 for the window when `Options.hdr_output` got
    /// an HDR surface.
    output_encoding: OutputEncoding = .auto,
    /// HDR10 only: brightness of white, in nits.
    hdr_paper_white: f32 = 200,
    /// HDR10 only: peak brightness of the display, in nits.
    hdr_peak: f32 = 1000,
    /// Depth of field aperture. 0 is off; 1 blurs distant things by about 24
    /// pixels at 1080p when focused close.
    dof_aperture: f32 = 0,
    /// Distance in perfect focus.
    dof_focus_distance: f32 = 10,
    /// Focus on what is at the middle of the picture instead.
    dof_autofocus: bool = false,
    /// Autofocus rate, per second.
    dof_autofocus_speed: f32 = 4,
    /// Largest blur radius, in pixels at 1080p.
    dof_max_blur: f32 = 16,
    /// Depth of field samples per pixel, 4..128.
    dof_samples: u32 = 32,
    /// Resolution the blur is gathered at.
    dof_resolution: EffectResolution = .full,
    /// Aperture blades: bokeh gets this many sides; 0 is round.
    dof_blades: u32 = 0,
    /// Motion blur: fraction of a frame the shutter stays open; 0 is off.
    motion_blur: f32 = 0,
    /// Samples along each pixel's path, 2..64.
    motion_blur_samples: u32 = 10,
    /// Let moving things smear past their own outline.
    motion_blur_spread: bool = true,
    /// Path trace the view, accumulating frames while camera, scene and lights
    /// are still. Uses hardware ray tracing, or a shader with
    /// `Options.path_tracing_fallback`; see `Renderer.pathTracing`. Not traced:
    /// skinned meshes without ray tracing, water, liquids, smoke, clouds,
    /// particles, decals and refraction.
    path_tracing: bool = false,
    /// Maximum bounces per path, 1..16; 1 is direct light only.
    path_tracing_bounces: u32 = 4,
    /// Paths per pixel per frame, 1..64.
    path_tracing_samples: u32 = 1,
    /// Most light a path may return through a rough bounce, before exposure;
    /// directly seen and mirrored light is not limited.
    path_tracing_clamp: f32 = 12,
    /// Denoise by averaging lamp and indirect light over neighbouring pixels of
    /// the same surface, while a pixel still varies between frames.
    path_tracing_denoise: bool = true,
    /// Show one input of the shading instead of the lit picture.
    debug_view: DebugView = .none,
};

/// See `Settings.debug_view`. Values match the switch in `shaders/shade.glsl`.
pub const DebugView = enum(u32) {
    none,
    /// Material base color, unlit.
    albedo,
    /// Shading normal, mapped from -1..1 to 0..1 per axis.
    normal,
    roughness,
    metallic,
    ambient_occlusion,
    /// Sun visibility: white lit, black shadowed.
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

/// See `Settings.upscaling`.
pub const Upscaling = enum { spatial, temporal, fsr, fsr2, fsr3 };

/// Fraction of the output resolution an effect is computed at; upsampled
/// depth-aware.
pub const EffectResolution = enum {
    full,
    /// Half the width and height.
    half,
    /// A quarter of the width and height.
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

/// Points in a view's frame where a `Pass` can run.
pub const PassStage = enum {
    /// Opaque surfaces are lit. `color` is the HDR scene color, `depth` the
    /// scene depth.
    after_opaque,
    /// Transparency and fog are in; still HDR, before antialiasing, bloom and
    /// exposure.
    after_transparency,
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
    /// GPU address of this view's `FrameConstants` (see `shaders/common.glsl`).
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

/// Application code run at a `PassStage`, while the frame is recorded with the
/// renderer locked: it must not call back into the `Renderer`.
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
    /// Index of the hit mesh instance within the entity's model.
    mesh_instance: u32,
    /// World-space point on the surface.
    position: Vec3,
    /// Distance from the camera plane.
    distance: f32,
};

/// See `Renderer.createMaterialShader`.
pub const MaterialShader = struct {
    /// Value for `Material.shader`.
    slot: u32,
};

/// The answer to a `Renderer.requestPick`, returned by `Renderer.takePick`.
pub const PickResult = struct {
    pixel: [2]u32,
    /// Null when nothing opaque is there, or the scene's contents changed
    /// before the answer came back.
    hit: ?Pick,
};

/// A box that projects a color or image onto the opaque surfaces inside it.
pub const DecalDesc = struct {
    /// Places a unit cube (-0.5..0.5) in the world. The image is projected
    /// along the cube's local -Z, so +Z should point away from the surface;
    /// X and Y are the image's width and height, Z how deep it reaches.
    transform: Mat4,
    /// Linear color and opacity, multiplied with the image if there is one.
    color: [4]f32 = .{ 1, 1, 1, 1 },
    image: ?Image = null,
    /// Normal map applied inside the box, and its strength.
    normal_image: ?Image = null,
    normal_strength: f32 = 1,
    /// Roughness given to the covered surface; null keeps the surface's own.
    roughness: ?f32 = null,
    /// Emission, in the decal's color.
    emissive: f32 = 0,
    /// Surfaces facing away from the projection by more than this cosine are
    /// left alone.
    angle_fade: f32 = 0.2,
};

/// Most decals a scene can hold.
pub const max_decals = gpu.cluster_decal_words * 32;

/// A procedural clear sky; see `Renderer.createSky`.
pub const SkyDesc = struct {
    /// Direction the sun's light travels, as in `Sun.direction`.
    sun_direction: Vec3 = .{ -0.4, -1.0, -0.3 },
    /// Haze: 1 is very clear air, 10 a hazy day.
    turbidity: f32 = 2.5,
    /// Ozone, 1 for the Earth's; 0 leaves it out.
    ozone: f32 = 1,
    /// Frames a change to the sky is spread over; above 1 the sky lags and
    /// briefly mixes two moments. Taken as 1 while a cloud layer is baked into
    /// the lighting.
    rebuild_frames: u32 = 1,
    /// Overall brightness of the sky.
    intensity: f32 = 1,
    /// Color of the ground below the horizon.
    ground_color: [3]f32 = .{ 0.25, 0.23, 0.2 },
    /// Draw the sun's disc into the sky.
    sun_disc: bool = true,
    /// Brightness of the stars, shown once the sun is down.
    stars: f32 = 0,
    /// Direction the moon's light travels and the brightness of its disc; 0 for
    /// no moon. It gives no light: pair it with a directional light.
    moon_direction: Vec3 = .{ 0.3, -0.6, 0.5 },
    moon: f32 = 0,
};

/// Brightness of the sun above the atmosphere; matches env_sky.frag.
pub const sky_sun_strength = 8.0;

/// The `Sun` matching a sky: its direction, and its color and intensity after
/// crossing the atmosphere (zero below the horizon). Pass it to
/// `Renderer.setSun`.
pub fn skySun(desc: SkyDesc) Sun {
    const to_sun = math.normalize(math.scale(desc.sun_direction, -1));
    if (to_sun[1] <= -0.02) return .{ .direction = desc.sun_direction, .intensity = 0 };
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
    const above = std.math.clamp((to_sun[1] + 0.02) / 0.04, 0, 1);
    return .{
        .direction = desc.sun_direction,
        .color = math.scale(color, 1 / strongest),
        .intensity = sky_sun_strength * strongest * desc.intensity * above,
    };
}

/// How an emitter's particles are laid over the picture.
pub const ParticleBlend = enum {
    /// Covers what is behind it in proportion to its opacity.
    alpha,
    /// Adds light without hiding anything.
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

    /// Keys past `max_curve_keys` are dropped.
    pub fn init(keys: []const f32) SizeCurve {
        var curve = SizeCurve{ .count = @intCast(@min(keys.len, max_curve_keys)) };
        @memcpy(curve.keys[0..curve.count], keys[0..curve.count]);
        return curve;
    }
};

/// A local reflection capture, used by surfaces inside its box where neither
/// the screen nor a ray gives a reflection. See
/// `Renderer.createReflectionProbe`.
pub const ReflectionProbeDesc = struct {
    /// Capture point and center of the box.
    position: Vec3,
    /// Half the size of the box. Reflections are projected onto its walls, so
    /// match it to the room.
    extent: Vec3 = .{ 5, 3, 5 },
    /// Share of the box, inward from its faces, over which the probe fades out.
    fade: f32 = 0.15,
    intensity: f32 = 1,
    /// Pixels per side of each of the six faces, 16..1024.
    resolution: u32 = 256,
    /// Frames to let bounce light settle before capturing.
    settle_frames: u32 = 40,
    /// Brightest value kept.
    max_radiance: f32 = 32,
};

/// Most reflection probes a scene can hold.
pub const max_reflection_probes = 16;

/// A source of particles; see `Renderer.createEmitter`.
pub const EmitterDesc = struct {
    position: Vec3 = .{ 0, 0, 0 },
    /// Particles are born inside a sphere of this radius.
    radius: f32 = 0.1,
    /// Most particles alive at once; fixed at creation. If `rate` times the
    /// lifetime exceeds it, the oldest are replaced early.
    capacity: u32 = 1024,
    /// Births per second.
    rate: f32 = 100,
    /// Seconds a particle lives, chosen between these two.
    lifetime: [2]f32 = .{ 1, 2 },
    /// Axis of the cone particles are launched into.
    direction: Vec3 = .{ 0, 1, 0 },
    /// Half-angle of that cone in radians; pi launches in every direction.
    spread: f32 = 0.4,
    /// Launch speed, chosen between these two.
    speed: [2]f32 = .{ 1, 2 },
    /// Constant acceleration.
    gravity: Vec3 = .{ 0, 0, 0 },
    /// How quickly particles lose speed, per second.
    drag: f32 = 0.5,
    /// Diameter in world units at birth and at death.
    size: [2]f32 = .{ 0.05, 0.2 },
    /// Linear color and opacity at birth and at death.
    color_start: [4]f32 = .{ 1, 1, 1, 1 },
    color_end: [4]f32 = .{ 1, 1, 1, 0 },
    blend: ParticleBlend = .alpha,
    /// Lit by the sun (with shadows) and the surroundings.
    lit: bool = true,
    /// Distance over which a particle fades out as it nears a surface; 0
    /// gives a hard edge.
    softness: f32 = 0.3,
    /// Sort particles farthest first on the GPU for every view, as overlapping
    /// alpha-blended particles need. Fixed at creation.
    sorted: bool = false,
    /// Seconds of simulation run before the emitter is first shown.
    prewarm: f32 = 0,
    /// A third color and size partway through a particle's life, at `mid`
    /// (0..1). Null goes straight from start to end.
    color_mid: ?[4]f32 = null,
    size_mid: ?f32 = null,
    mid: f32 = 0.5,
    /// Color and size over life: 2 to `max_curve_keys` evenly spaced keys,
    /// replacing the start, mid and end values.
    color_curve: ColorCurve = .{},
    size_curve: SizeCurve = .{},
    /// Draw each particle as this model's first mesh instead of a sprite,
    /// `size` across and tinted by the particle color and `image`. `softness`
    /// and `stretch` do not apply.
    mesh: ?Model = null,
    /// Tumble rate of a mesh particle, in radians per second.
    spin: f32 = 0,
    /// Ribbon trail: remembered points per particle (up to `max_trail_points`,
    /// 0 for none), reaching `trail_seconds` back. The point count is fixed at
    /// creation.
    trail: u32 = 0,
    trail_seconds: f32 = 0.4,
    /// A fluid whose flow carries the particles inside its box, and how quickly
    /// they take on its velocity, per second.
    fluid: ?Fluid = null,
    fluid_follow: f32 = 6,
    /// Bounce off the surfaces the scene's first view saw last frame, keeping
    /// `bounce` of their speed.
    collide: bool = false,
    bounce: f32 = 0.4,
    /// Stretch along motion by this many seconds of travel; 0 draws it round.
    stretch: f32 = 0,
    /// Columns and rows of frames in `image`; they play once over the
    /// particle's life.
    sheet: [2]u32 = .{ 1, 1 },
    /// Sprite to draw; null draws a soft round blob.
    image: ?Image = null,
};

/// One camera's picture: what to draw, from where, and where it goes.
pub const ViewDesc = struct {
    /// Persistent view state to use; null is the built-in main view. Every
    /// camera drawn in the same frame needs its own `View`.
    view: ?View = null,
    /// Null for a purely 2D view.
    scene: ?Scene = null,
    /// Drawn over the scene, in order. Must not be modified until `render`
    /// returns.
    draw_lists: []const *const DrawList = &.{},
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
    /// `Renderer.targetImage`).
    views: []const ViewDesc,
    /// Seconds since the previous frame.
    delta_time: f32 = 1.0 / 60.0,
};

/// How path tracing follows rays on this device; see `Renderer.pathTracing`.
pub const PathTracing = enum {
    /// Hardware ray tracing.
    hardware,
    /// A shader walking CPU-built trees; needs `Options.path_tracing_fallback`.
    shader,
    /// `Settings.path_tracing` has no effect.
    unavailable,
};

/// Counters describing the last frame; see `Renderer.getStats`.
pub const Stats = struct {
    /// Views drawn. Scene numbers below describe the first view with a scene.
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
    /// Mesh instances with any meshlet drawn (measured two frames ago).
    instances_drawn: u32 = 0,
    /// Triangles in the scene at full detail, before culling and LOD.
    triangles: u64 = 0,
    /// Vertices deformed by skinning or morphing this frame.
    skinned_vertices: u32 = 0,
    /// Models and environments still loading.
    models_loading: u32 = 0,
    /// GPU memory allocated by the device, in bytes.
    gpu_memory_bytes: u64 = 0,
    /// Textures under `Options.texture_streaming`, the GPU memory they
    /// take now, and how many are waiting to load more detail.
    streamed_textures: u32 = 0,
    streamed_texture_bytes: u64 = 0,
    streamed_textures_pending: u32 = 0,
    /// Models whose geometry is currently released, and its size in bytes.
    geometry_models_released: u32 = 0,
    geometry_bytes_released: u64 = 0,
    /// Bytes of geometry moved to compact the pools since startup.
    geometry_bytes_compacted: u64 = 0,
    /// Models of which only the coarser levels of detail are in GPU
    /// memory (`GeometryStreaming.coarse_distance`).
    geometry_models_coarse: u32 = 0,
    /// Triangles drawn from draw lists, over all views.
    draw_list_triangles: u32 = 0,
    /// Indirect draws for scene geometry, camera and shadow maps together.
    indirect_draws: u32 = 0,
    /// Frames accumulated in the last path-traced view (0 when none), and
    /// whether it used hardware ray tracing.
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
