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
const features = @import("core/features.zig");

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
/// `Renderer.models.load`. Handles are 32-bit copyable values; calls given a
/// stale handle do nothing or return an error.
pub const Model = handle.Handle(ModelTag);
/// A sky and its image-based lighting; see `Renderer.environments.load`.
pub const Environment = handle.Handle(EnvironmentTag);
/// A world of entities, lights and effects; see `Renderer.scenes.create`.
pub const Scene = handle.Handle(SceneTag);
/// One placement of a model in a scene; see `Renderer.entities.spawn`.
pub const Entity = handle.Handle(EntityTag);
/// Per-camera state that persists between frames.
pub const View = handle.Handle(ViewTag);
/// A particle emitter in a scene.
pub const Emitter = handle.Handle(EmitterTag);
/// A local reflection probe in a scene.
pub const ReflectionProbe = handle.Handle(ReflectionProbeTag);
/// A box of simulated smoke and fire in a scene; see `Renderer.fluids.create`.
pub const Fluid = handle.Handle(FluidTag);
/// A shape that hair is kept out of; see `Renderer.hairs.createCollisionField`.
pub const CollisionField = handle.Handle(CollisionFieldTag);
/// Strands of hair, fur or grass in a scene; see `Renderer.hairs.create`.
pub const Hair = handle.Handle(HairTag);
/// A sheet of simulated water in a scene; see `Renderer.waters.create`.
pub const Water = handle.Handle(WaterTag);
/// A volume of particle-simulated liquid; see `Renderer.liquids.create`.
pub const Liquid = handle.Handle(LiquidTag);
/// Many copies of one model; see `Renderer.instances.create`.
pub const InstanceGroup = handle.Handle(InstanceGroupTag);
/// Animation clips an entity plays; see `Renderer.entities.setPose`.
pub const Pose = animation.Pose;
/// Application-supplied geometry for `Renderer.models.create`.
pub const MeshDesc = gltf.MeshDesc;
/// Surface description of a mesh.
pub const Material = gltf.Material;
/// 2D shapes, images and text drawn over a view.
pub const DrawList = draw_list.DrawList;
/// A texture for draw lists, lights and settings; see `Renderer.images.create`.
pub const Image = draw_list.Image;
/// A font baked into a distance-field atlas; see `Renderer.fonts.load`.
pub const Font = font_module.Font;

/// Ray tracing and what is built for it; see `Options.ray_tracing.hardware`.
pub const RayTracingOptions = struct {
    /// Use hardware ray tracing where available. False disables ray-traced
    /// effects; path tracing then runs in a shader.
    hardware: bool = true,
    /// Build a BVH per model at load so `Settings.path_tracing` works without
    /// hardware ray tracing. No effect where the GPU traces rays.
    software_path_tracing: bool = false,
    /// Maximum probes along X, Y and Z in one light probe grid.
    max_probes: [3]u32 = .{ 32, 12, 32 },
    /// Include skinned and morphed meshes in the ray-tracing structure, at one
    /// structure build per such mesh per frame.
    dynamic_geometry: bool = true,
    /// How many of those structures are updated per frame, in turn; 0 for all.
    /// New ones are always built at once.
    dynamic_refits: u32 = 0,
    /// Instance groups join the ray-tracing structure while the scene holds at
    /// most this many group instances; 0 never.
    instance_limit: u32 = 65536,
};

/// Shadow map sizes; see `Options.shadows`.
pub const ShadowOptions = struct {
    /// Size of each of the four sun shadow cascades, in texels per side.
    resolution: u32 = 2048,
    /// Size per side of the spot and point light shadow atlas, in texels.
    local_resolution: u32 = 2048,
    /// Tiles per side of the local-light shadow atlas, 1..4. A spot light uses
    /// one tile, a point light six.
    local_tiles_per_side: u32 = 4,
};

/// How textures are stored and sampled; see `Options.textures`.
pub const TextureOptions = struct {
    /// Anisotropic filtering for color and normal maps (1 disables).
    anisotropy: f32 = 8,
    /// Anisotropic filtering for roughness/metalness, occlusion and emissive.
    data_anisotropy: f32 = 1,
    /// GPU storage of material textures. `.bc7` takes a quarter of the memory
    /// of `.none`; falls back to `.none` without BC format support.
    compression: TextureCompression = .bc7,
    /// With compression on, store normal maps as BC5; false uses BC7.
    normal_maps_bc5: bool = true,
    /// Null keeps every texture fully loaded.
    streaming: ?TextureStreaming = null,
};

/// How meshes are built and drawn; see `Options.geometry`.
pub const GeometryOptions = struct {
    /// Draw meshlets with mesh shaders where available instead of indirect
    /// draws. Off by default: indirect draws share vertices between
    /// triangles and are the faster of the two.
    mesh_shaders: bool = false,
    /// Compute per-meshlet bounds of skinned and morphed meshes on the GPU each
    /// frame, so they are culled per meshlet instead of per mesh.
    skinned_meshlet_bounds: bool = false,
    /// Build coarser levels of detail for models. False loads them faster and
    /// draws every mesh at full detail, which suits geometry made of flat
    /// textured faces that does not simplify.
    lods: bool = true,
    /// Build cluster-hierarchy LODs, chosen per meshlet. Meshes under about
    /// 8000 triangles and skinned meshes keep whole-mesh LODs.
    cluster_lods: bool = true,
    /// Weight of normal deviation when LODs are built; 0 uses shape alone. See
    /// `gltf.LodOptions.normal_weight`.
    lod_normal_weight: f32 = gltf.default_lod_normal_weight,
    /// Weight of UV deviation when LODs are built: 1 counts a UV shift as a
    /// shape error of the same distance, 0 ignores it.
    lod_uv_weight: f32 = gltf.default_lod_uv_weight,
    /// Keep a model's geometry on the GPU only while something drawn with it is
    /// near a camera. Null keeps all geometry loaded.
    streaming: ?GeometryStreaming = null,
};

/// What is kept on disk between runs; see `Options.cache`.
pub const CacheOptions = struct {
    /// File for the driver's pipeline cache. Null keeps none.
    pipelines: ?[]const u8 = null,
    /// Directory for processed assets; null caches nothing.
    assets: ?[]const u8 = null,
    /// Size the asset cache is trimmed to at startup, oldest files first; 0
    /// never trims. See `trimAssetCache`.
    assets_max_bytes: u64 = 0,
};

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
    cache: CacheOptions = .{},
    /// Name GPU objects and label passes; needs `VK_EXT_debug_utils`.
    debug_names: bool = false,
    /// Ask for an HDR10 surface; see `Renderer.hdrActive` for the result.
    hdr_output: bool = false,
    ray_tracing: RayTracingOptions = .{},
    geometry: GeometryOptions = .{},
    /// CPU profiler hooks.
    profiler: ?Profiler = null,
    shadows: ShadowOptions = .{},
    textures: TextureOptions = .{},
    /// Allocator for worker-thread asset decoding and the resulting models;
    /// must be thread-safe. Null uses a general-purpose one.
    job_allocator: ?std.mem.Allocator = null,
    /// Compile a shading-pass variant per set of features a view uses, on a
    /// worker thread. False always uses the full pass.
    shader_variants: bool = true,
    /// Threads for animation poses and instance records, including the render
    /// thread: 0 picks automatically (at most 8), 1 uses no other thread.
    worker_threads: u32 = 0,
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

/// A box of particle-simulated liquid; see `Renderer.liquids.create`. Costs far
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

/// See `Options.geometry.streaming`.
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
    /// `Options.cache.assets` and compressed textures.
    from_cache: bool = false,
};

/// See `Options.textures.compression`. `.none` is RGBA8.
pub const TextureCompression = enum { none, bc7 };
/// See `Renderer.entities.bakeLightmap`.
pub const LightmapDesc = struct {
    /// Texels per side.
    resolution: u32 = 256,
    /// Frames the bake is spread over, and rays per texel per frame.
    frames: u32 = 256,
    rays: u32 = 16,
    /// Maximum ray length, in world units.
    reach: f32 = 200,
};

/// See `Renderer.instances.setImpostor`.
pub const ImpostorDesc = struct {
    /// Copies smaller than this many pixels across are drawn as impostor cards.
    pixels: f32 = 24,
    /// Pixels per side of each of the 64 captured directions.
    resolution: u32 = 64,
};

/// Strands of hair, fur or grass; see `Renderer.hairs.create`. Each strand is a
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

/// Strand dynamics; see `HairDesc.simulation` and `Renderer.hairs.setSimulation`.
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
    /// Collision shape from `Renderer.hairs.createCollisionField`; `field_transform`
    /// places it in the world.
    field: ?CollisionField = null,
    field_transform: Mat4 = math.identity,
    /// Distance strands are kept from the field, in world units.
    margin: f32 = 0.002,
    /// Strand-to-strand repulsion; 0 for none.
    volume: f32 = 0.4,
};

/// A sheet of simulated water; see `Renderer.waters.create`.
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
    /// Stretched over the sheet; where its red channel is below one half no
    /// water is drawn. Null draws the whole sheet. Not applied to `write_depth`.
    mask: ?Image = null,
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

/// Frames recorded from a running fluid; see `Renderer.fluids.recordFlipbook`.
pub const FluidFlipbookDesc = struct {
    columns: u32 = 8,
    rows: u32 = 8,
    /// Simulation steps from one frame to the next, at least 1.
    interval: u32 = 2,
    /// Size of one frame in pixels; null uses the fluid's resolution.
    frame_size: ?[2]u32 = null,
};

/// A box of simulated smoke and fire; see `Renderer.fluids.create`.
pub const FluidDesc = struct {
    /// Cells along each axis, 8..256. A depth of 1 makes the fluid 2D.
    resolution: [3]u32 = .{ 64, 96, 64 },
    /// Places the box: a unit cube centered on the origin, +Y up.
    transform: Mat4 = math.identity,
    /// Up to 8.
    sources: []const FluidSource = &.{},
    /// Up to 8.
    obstacles: []const FluidObstacle = &.{},
    /// Treat scene geometry inside the box as solid. Needs ray tracing;
    /// six short rays per cell per frame.
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
    /// ray-traced shadows (see `Settings.shadows.light_rays`).
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

/// A layer of volumetric clouds; see `Renderer.scenes.setClouds`.
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
    /// light only the cloud; see `Renderer.scenes.cloudFlash`.
    lightning: f32 = 0,
    lightning_brightness: f32 = 40,
    /// Radius of the planet the layer wraps around.
    planet_radius: f32 = 6_360_000,
};

/// A lightning flash in a cloud layer; see `Renderer.scenes.cloudFlash`.
pub const CloudFlash = struct { position: Vec3, brightness: f32 };

/// See `Settings.transparency.mode`.
pub const TransparencyMode = enum {
    /// Whole meshes, back to front.
    sorted,
    /// Weighted blended: one pass, approximate layering.
    weighted,
    /// Depth peeling: exact for the nearest `Settings.transparency.layers`
    /// surfaces, one pass per layer.
    peeled,
};

/// Haze model of aerial perspective; see `Settings.shading.aerial_model`.
pub const AerialModel = enum { atmosphere, sky };

/// LOD used for local light shadows; see `Settings.shadows.lod`.
pub const ShadowLod = enum { camera, light };

/// See `Settings.output.encoding`.
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
    /// The load failed (see `Renderer.models.loadError`) or the handle is invalid.
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
    /// Null is a perspective camera with `fov_y`. Set for a parallel one, as
    /// in isometric and 2.5D views.
    orthographic: ?Orthographic = null,

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

/// A parallel projection; see `Camera.orthographic`.
pub const Orthographic = struct {
    /// World units the picture spans from top to bottom.
    height: f32 = 10,
    /// Far plane distance, in world units. Nothing beyond it is drawn.
    far: f32 = 1000,
};

/// The scene's one shadow-casting directional light; see `Renderer.scenes.setSun`.
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
    /// Radius of the emitting sphere; 0 is an ideal point. For a directional
    /// light, the tangent of the angle its disc spans from the center: the
    /// sun's is about 0.005. Path tracing lets light out through anything
    /// inside the sphere, so a lamp may sit within the model of its fitting.
    source_radius: f32 = 0,
    /// Point lights only: makes the source a tube this long along `direction`,
    /// `source_radius` thick. Shadows are still cast from the center.
    source_length: f32 = 0,
    /// Rectangle lights only: panel height (`source_length` is its width).
    source_height: f32 = 0,
    /// Spot lights only: an image projected by the light.
    cookie: ?Image = null,
    /// Brightness by angle from `direction`: a strip image, left edge along the
    /// axis, right edge straight behind. See `Renderer.images.loadLightProfile`.
    profile: ?Image = null,
};

/// What `Renderer.entities.spawn` makes an entity from. Everything but the model can be
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

/// One animation clip of a model; see `Renderer.models.animationInfo`.
pub const AnimationInfo = struct {
    /// Owned by the model; valid until it is destroyed.
    name: []const u8,
    /// In seconds.
    duration: f32,
};

/// See `Renderer.models.info`.
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

/// See `Renderer.environments.info`.
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

/// `Settings.ambient_occlusion`.
pub const AmbientOcclusion = @import("features/ambient_occlusion.zig").Settings;
/// `Settings.canvas`.
pub const Canvas = @import("features/canvas.zig").Settings;

/// `Settings.geometry`.
pub const Geometry = @import("features/geometry.zig").Settings;
/// `Settings.shading`.
pub const Shading = @import("features/shading.zig").Settings;
/// `Settings.shadows`.
pub const Shadows = @import("features/shadows.zig").Settings;
/// `Settings.reflections`.
pub const Reflections = @import("features/reflections.zig").Settings;
/// `Settings.global_illumination`.
pub const GlobalIllumination = @import("features/global_illumination.zig").Settings;
/// `Settings.path_tracing`.
pub const PathTracing = @import("features/path_tracing.zig").Settings;
/// `Settings.path_tracing.nrd`.
pub const NrdSettings = @import("features/path_tracing.zig").Nrd;
/// `Settings.transparency.mode`.
pub const Transparency = @import("features/transparency.zig").Settings;
/// `Settings.fog`.
pub const Fog = @import("features/fog.zig").Settings;
/// `Settings.clouds`.
pub const Clouds = @import("features/clouds.zig").Settings;
/// `Settings.fluids`.
pub const Fluids = @import("features/fluids.zig").Settings;
/// `Settings.post`.
pub const Post = @import("features/post.zig").Settings;
/// `Settings.resolution`.
pub const Resolution = @import("features/resolution.zig").Settings;
/// `Settings.output`.
pub const Output = @import("features/output.zig").Settings;
/// `Settings.post.depth_of_field`.
pub const DepthOfField = @import("features/post.zig").DepthOfField;
/// `Settings.post.motion_blur`.
pub const MotionBlur = @import("features/post.zig").MotionBlur;

/// The settings of a feature that can be switched off, or its defaults while
/// it is off.
pub fn filled(setting: anytype) @typeInfo(@TypeOf(setting)).optional.child {
    return setting orelse .{};
}

/// Per-view quality and look (`ViewDesc.settings`); may change every frame.
/// Distances are in world units.
pub const Settings = struct {
    /// The settings of a quality level; only cost-related fields differ.
    pub fn preset(quality: Quality) Settings {
        var settings = Settings{};
        features.preset(&settings, quality);
        return settings;
    }

    /// Which of a scene's geometry a view draws, and at what detail.
    geometry: Geometry = .{},
    /// How lit surfaces are shaded.
    shading: Shading = .{},
    /// Shadows of the sun and of local lights. Null for none.
    shadows: ?Shadows = .{},
    /// Screen-space ambient occlusion (GTAO); null for none.
    ambient_occlusion: ?AmbientOcclusion = .{},
    /// Reflections traced on screen and, where the GPU traces rays, through the scene. Null for none.
    reflections: ?Reflections = .{},
    /// Bounce light from grids of probes that trace the scene. Null for none.
    global_illumination: ?GlobalIllumination = .{ .probes = .{} },
    /// Path tracing in place of rasterized lighting. Null for none.
    path_tracing: ?PathTracing = null,
    /// How see-through surfaces are drawn.
    transparency: Transparency = .{},
    /// Height fog lit by the sun and local lights. Null for none.
    fog: ?Fog = null,
    /// Volumetric clouds of a scene that has them. Null for none.
    clouds: ?Clouds = .{},
    /// Smoke and fire of a scene's fluids. Null for none.
    fluids: ?Fluids = .{},
    /// Lens effects, bloom, exposure and color grading.
    post: Post = .{},
    /// The size a view is rendered at and how it is antialiased and brought to the size of its target.
    resolution: Resolution = .{},
    /// How a view's picture is encoded for its target.
    output: Output = .{},
    /// How draw lists are drawn.
    canvas: Canvas = .{},
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

/// See `Settings.resolution.upscaler`.
pub const Upscaler = enum { spatial, temporal, fsr, fsr2, fsr3, dlss };

/// See `Settings.path_tracing.denoiser`.
pub const Denoiser = enum {
    builtin,
    /// DLSS Ray Reconstruction; needs `Upscaler.dlss`.
    ray_reconstruction,
    /// NVIDIA Real-time Denoisers (ReLAX) for bounced light and
    /// reflections; needs the NRD SDK (`zig build nrd-sdk`).
    nrd,
};

/// How a path picks the lamp to light a surface with. `.ris` draws a few
/// candidates and keeps one by its contribution, reusing last frame's and
/// the neighbours' choices.
pub const DirectSampling = enum { ris };

/// See `Settings.resolution.frame_generation`.
pub const FrameGeneration = enum { fsr3 };

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
    /// GPU address of this view's `FrameConstants` (see `shaders/common.glsl`);
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

/// See `Renderer.images.create`.
pub const ImageDesc = struct {
    width: u32,
    height: u32,
    /// Tightly packed RGBA8, top row first.
    pixels: []const u8,
    /// True for color, false for data.
    srgb: bool = true,
    /// Most mips made; 0 is the full chain. An atlas wants no more than its
    /// smallest cell can be halved.
    mip_levels: u32 = 0,
};

/// See `Renderer.environments.load`.
pub const EnvironmentOptions = struct {
    /// Radiance is clamped to this, which keeps a small sun from sparkling.
    max_radiance: f32 = 64,
};

/// See `Renderer.scenes.setEnvironment`.
pub const SceneEnvironment = struct {
    /// Null for none.
    environment: ?Environment,
    /// Multiplies its radiance.
    intensity: f32 = 1,
};

/// See `Renderer.materials.setShader`.
pub const ShaderAssignment = struct {
    /// Index of the material; null for every material of the model.
    material: ?u32 = null,
    /// Null restores the standard shader.
    shader: ?MaterialShader = null,
    params: [4]f32 = .{ 0, 0, 0, 0 },
};

/// See `Renderer.materials.createShader`.
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

/// A procedural clear sky; see `Renderer.environments.createSky`.
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
/// `Renderer.scenes.setSun`.
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
/// `Renderer.probes.create`.
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

/// A source of particles; see `Renderer.emitters.create`.
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

/// When in a view's frame a draw list is drawn; see `DrawLayer`.
pub const DrawStage = enum {
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

/// How path tracing follows rays on this device; see `Capabilities`.
pub const PathTracingSupport = enum {
    /// Hardware ray tracing.
    hardware,
    /// A shader walking CPU-built trees; needs `Options.ray_tracing.software_path_tracing`.
    shader,
    /// `Settings.path_tracing` has no effect.
    unavailable,
};

/// Whether something can run here and, if not, what is in the way.
pub const Support = enum {
    available,
    /// The GPU, its driver or the display cannot do it.
    no_device_support,
    /// Left out of this build (`-Dfidelityfx`, `zig build dlss-sdk`).
    not_built,
    /// Not asked for in `Options`.
    off,
};

/// What this renderer can do on this device; see `Renderer.capabilities`.
/// A view that asks for more gets the nearest thing and says so in
/// `Stats.downgraded`.
pub const Capabilities = struct {
    /// Probe lighting, traced reflections and traced light shadows.
    ray_tracing: Support,
    path_tracing: PathTracingSupport,
    mesh_shaders: Support,
    variable_rate_shading: Support,
    /// `Upscaler.fsr2`, `Upscaler.fsr3` and `FrameGeneration.fsr3`.
    fidelityfx: Support,
    /// `Upscaler.dlss`.
    dlss: Support,
    /// `Denoiser.ray_reconstruction`.
    dlss_ray_reconstruction: Support,
    /// The window surface is HDR10.
    hdr_output: Support,

    pub fn upscaler(self: Capabilities, technique: Upscaler) Support {
        return switch (technique) {
            .spatial, .temporal, .fsr => .available,
            .fsr2, .fsr3 => self.fidelityfx,
            .dlss => self.dlss,
        };
    }
};

/// Why a view did not get what its settings asked for.
pub const DowngradeReason = enum {
    /// The GPU cannot trace rays.
    no_ray_tracing,
    /// `Settings.resolution.temporal_antialiasing` is off.
    needs_temporal_antialiasing,
    /// The GPU or its driver lacks what the feature needs.
    unsupported,
    /// The library the feature comes from is not there or would not start.
    unavailable,
};

/// A setting of a view that was asked for and replaced; see
/// `Stats.downgraded`.
pub const Downgrade = struct {
    /// The setting, as it is spelled in `Settings`.
    feature: []const u8,
    requested: []const u8,
    used: []const u8,
    reason: DowngradeReason,
};

pub const max_downgrades = 16;

/// Counters describing the last frame; see `Renderer.getStats`.
pub const Stats = struct {
    /// What the views of the last frame asked for and did not get.
    pub fn downgraded(self: *const Stats) []const Downgrade {
        return self.downgrades[0..self.downgrade_count];
    }

    downgrades: [max_downgrades]Downgrade = undefined,
    downgrade_count: u32 = 0,

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
    /// Built-in pipelines built so far.
    pipelines: u32 = 0,
    /// Textures under `Options.textures.streaming`, the GPU memory they
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
