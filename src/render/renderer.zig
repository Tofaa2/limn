//! The high-level renderer: scenes of glTF models lit by a sun, point lights
//! and an HDR environment, drawn through a GPU-driven visibility-buffer
//! pipeline.
//!
//! Frame outline (see `renderScene`):
//!
//!   skinning and meshlet culling (compute) -> visibility buffer with
//!   two-phase occlusion culling -> sun and local shadow maps -> probe GI
//!   update -> GTAO -> shading -> transparency -> fog -> TAA -> bloom ->
//!   exposure -> tonemap -> draw lists
//!
//! All geometry lives in a handful of global buffers and every view is drawn
//! with two multi-draw-indirect calls, so CPU cost per frame is independent
//! of triangle and meshlet count.
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

const api = @import("api.zig");
const renderer_state = @import("state.zig");
const scene_pass = @import("scene_pass.zig");
const geometry_passes = @import("passes/geometry.zig");
const shadow_passes = @import("passes/shadows.zig");
const shading_passes = @import("passes/shading.zig");
const transparency_passes = @import("passes/transparency.zig");
const volume_passes = @import("passes/volumes.zig");
const path_tracing_pass = @import("passes/path_tracing.zig");
const post_passes = @import("passes/post.zig");
const simulation_passes = @import("passes/simulation.zig");
const particle_passes = @import("passes/particles.zig");
const gi_passes = @import("passes/gi.zig");

pub const Mat4 = math.Mat4;
pub const Vec3 = math.Vec3;
const ScenePass = scene_pass.ScenePass;
pub const SceneFrame = scene_pass.SceneFrame;
const SunShadows = scene_pass.SunShadows;
const CascadePlan = scene_pass.CascadePlan;
const LocalShadows = scene_pass.LocalShadows;
const ProbeList = scene_pass.ProbeList;
const CullState = scene_pass.CullState;
const DrawPush = scene_pass.DrawPush;
const CullPush = scene_pass.CullPush;
const Lighting = scene_pass.Lighting;

pub const ModelTag = api.ModelTag;
pub const EnvironmentTag = api.EnvironmentTag;
pub const SceneTag = api.SceneTag;
pub const EntityTag = api.EntityTag;
pub const ViewTag = api.ViewTag;
pub const EmitterTag = api.EmitterTag;
pub const ReflectionProbeTag = api.ReflectionProbeTag;
pub const FluidTag = api.FluidTag;
pub const WaterTag = api.WaterTag;
pub const LiquidTag = api.LiquidTag;
pub const InstanceGroupTag = api.InstanceGroupTag;
pub const Model = api.Model;
pub const Environment = api.Environment;
pub const Scene = api.Scene;
pub const Entity = api.Entity;
pub const View = api.View;
pub const Emitter = api.Emitter;
pub const ReflectionProbe = api.ReflectionProbe;
pub const Fluid = api.Fluid;
pub const Water = api.Water;
pub const Liquid = api.Liquid;
pub const InstanceGroup = api.InstanceGroup;
pub const Pose = api.Pose;
pub const MeshDesc = api.MeshDesc;
pub const Material = api.Material;
pub const DrawList = api.DrawList;
pub const Image = api.Image;
pub const Font = api.Font;
pub const Options = api.Options;
pub const LiquidSource = api.LiquidSource;
pub const LiquidDesc = api.LiquidDesc;
pub const GeometryStreaming = api.GeometryStreaming;
pub const TextureStreaming = api.TextureStreaming;
const StreamFrustum = renderer_state.StreamFrustum;
const blockFormat = renderer_state.blockFormat;
pub const TextureStream = renderer_state.TextureStream;
pub const TextureCompression = api.TextureCompression;
pub const WaterDesc = api.WaterDesc;
pub const FluidWalls = api.FluidWalls;
pub const FluidSource = api.FluidSource;
pub const FluidObstacle = api.FluidObstacle;
pub const FluidFlipbookDesc = api.FluidFlipbookDesc;
pub const FluidDesc = api.FluidDesc;
pub const CloudDesc = api.CloudDesc;
pub const CloudFlash = api.CloudFlash;
pub const TransparencyMode = api.TransparencyMode;
pub const AerialModel = api.AerialModel;
pub const ShadowLod = api.ShadowLod;
pub const OutputEncoding = api.OutputEncoding;
pub const Profiler = api.Profiler;
const Zone = renderer_state.Zone;
pub const AssetState = api.AssetState;
pub const Camera = api.Camera;
pub const Sun = api.Sun;
pub const LightKind = api.LightKind;
pub const Light = api.Light;
pub const EntityDesc = api.EntityDesc;
pub const AnimationInfo = api.AnimationInfo;
pub const ModelInfo = api.ModelInfo;
pub const EnvironmentInfo = api.EnvironmentInfo;
pub const Settings = api.Settings;
pub const Quality = api.Quality;
pub const DebugView = api.DebugView;
pub const Upscaling = api.Upscaling;
pub const EffectResolution = api.EffectResolution;
pub const EffectScales = renderer_state.EffectScales;
pub const Target = api.Target;
pub const Region = api.Region;
pub const PassStage = api.PassStage;
pub const PassContext = api.PassContext;
pub const Pass = api.Pass;
pub const scene_color_format = api.scene_color_format;
pub const Pick = api.Pick;
pub const MaterialShader = api.MaterialShader;
pub const PickResult = api.PickResult;
pub const DecalDesc = api.DecalDesc;
pub const max_decals = api.max_decals;
pub const SkyDesc = api.SkyDesc;
const sky_sun_strength = api.sky_sun_strength;
pub const skySun = api.skySun;
pub const ParticleBlend = api.ParticleBlend;
pub const max_curve_keys = api.max_curve_keys;
pub const max_trail_points = api.max_trail_points;
pub const ColorCurve = api.ColorCurve;
pub const SizeCurve = api.SizeCurve;
pub const ReflectionProbeDesc = api.ReflectionProbeDesc;
pub const max_reflection_probes = api.max_reflection_probes;
pub const EmitterDesc = api.EmitterDesc;
pub const ViewDesc = api.ViewDesc;
pub const FrameDesc = api.FrameDesc;
pub const PathTracing = api.PathTracing;
pub const Stats = api.Stats;

pub const hdr_format = renderer_state.hdr_format;
const bloom_format = renderer_state.bloom_format;
pub const bloom_levels = renderer_state.bloom_levels;
const ao_depth_mips = renderer_state.ao_depth_mips;
pub const view_count = renderer_state.view_count;
pub const main_late_view = renderer_state.main_late_view;
pub const local_view_base = renderer_state.local_view_base;
pub const max_local_shadow_views = renderer_state.max_local_shadow_views;
const max_movers = renderer_state.max_movers;
pub const local_shadow_tiles_per_side = renderer_state.local_shadow_tiles_per_side;
const cluster_near = renderer_state.cluster_near;
const cluster_far = renderer_state.cluster_far;
const cluster_z_scale = renderer_state.cluster_z_scale;
const env_cube_size = renderer_state.env_cube_size;
const env_specular_size = renderer_state.env_specular_size;
const env_specular_mips = renderer_state.env_specular_mips;
const env_irradiance_size = renderer_state.env_irradiance_size;
const stream_budget_bytes = renderer_state.stream_budget_bytes;
const Range = renderer_state.Range;
const RangeAllocator = renderer_state.RangeAllocator;
const Pool = renderer_state.Pool;
const arena_usage = renderer_state.arena_usage;
pub const FrameArena = renderer_state.FrameArena;
const ModelJob = renderer_state.ModelJob;
const runModelJob = renderer_state.runModelJob;
const ShadeVariant = renderer_state.ShadeVariant;
pub const ShadeVariantJob = renderer_state.ShadeVariantJob;
pub const shadeVariantDesc = renderer_state.shadeVariantDesc;
pub const runShadeVariantJob = renderer_state.runShadeVariantJob;
const EnvironmentJob = renderer_state.EnvironmentJob;
const runEnvironmentJob = renderer_state.runEnvironmentJob;
const loadEnvironmentFile = renderer_state.loadEnvironmentFile;
const brightestCubeDirection = renderer_state.brightestCubeDirection;
pub const ModelMesh = renderer_state.ModelMesh;
pub const MaterialTextures = renderer_state.MaterialTextures;
const ModelEntry = renderer_state.ModelEntry;
const EnvironmentEntry = renderer_state.EnvironmentEntry;
const LayoutEntry = renderer_state.LayoutEntry;
pub const SceneData = renderer_state.SceneData;
const no_skin = renderer_state.no_skin;
const EntityData = renderer_state.EntityData;
pub const TransparentDraw = renderer_state.TransparentDraw;
const BlasJob = renderer_state.BlasJob;
pub const BoundsJob = renderer_state.BoundsJob;
pub const SkinJob = renderer_state.SkinJob;
pub const MadeTextures = renderer_state.MadeTextures;
pub const ViewState = renderer_state.ViewState;
pub const ViewData = renderer_state.ViewData;
const Output = renderer_state.Output;
const Pipelines = renderer_state.Pipelines;
const GiPipelines = renderer_state.GiPipelines;
pub const GiVolume = renderer_state.GiVolume;
pub const gi_irradiance_texels = renderer_state.gi_irradiance_texels;
pub const gi_visibility_texels = renderer_state.gi_visibility_texels;
pub const gi_probe_limit = renderer_state.gi_probe_limit;
const TonemapPipeline = renderer_state.TonemapPipeline;
const PickRequest = renderer_state.PickRequest;
pub const ReflectionTargets = renderer_state.ReflectionTargets;
const CloudTargets = renderer_state.CloudTargets;
pub const cloud_noise_size = renderer_state.cloud_noise_size;
pub const cloud_noise_tiles = renderer_state.cloud_noise_tiles;
const MaterialPipelines = renderer_state.MaterialPipelines;
const uvMatrix = renderer_state.uvMatrix;
const transformSlot = renderer_state.transformSlot;
const uvSetBit = renderer_state.uvSetBit;
pub const packTint = renderer_state.packTint;
pub const max_fluids = renderer_state.max_fluids;
const max_pose_threads = renderer_state.max_pose_threads;
const pose_batch = renderer_state.pose_batch;
const max_liquids = renderer_state.max_liquids;
pub const liquid_cell_slots = renderer_state.liquid_cell_slots;
const LiquidTargets = renderer_state.LiquidTargets;
const LiquidState = renderer_state.LiquidState;
const max_waters = renderer_state.max_waters;
pub const water_quads = renderer_state.water_quads;
const WaterState = renderer_state.WaterState;
const FluidState = renderer_state.FluidState;
const OitTargets = renderer_state.OitTargets;
const PeelTargets = renderer_state.PeelTargets;
const shade_plain_targets = renderer_state.shade_plain_targets;
const shade_reflective_targets = renderer_state.shade_reflective_targets;
const InstanceGroupData = renderer_state.InstanceGroupData;
const InstanceSlot = renderer_state.InstanceSlot;
pub const EmitterData = renderer_state.EmitterData;
const ProbeData = renderer_state.ProbeData;
const PickPending = renderer_state.PickPending;
const SeenTag = renderer_state.SeenTag;
const DrawPipelines = renderer_state.DrawPipelines;
const ImageEntry = renderer_state.ImageEntry;

/// The renderer: owns the device and every model, scene, view, font and
/// image made through it. Create one with `init`, call `render` once per
/// frame and `deinit` at the end.
///
/// Methods lock the renderer themselves (see `lock`), so models can be
/// loaded and scenes edited from other threads while one thread renders.
/// The fields are internal, apart from `device` and `options`.
pub const Renderer = struct {
    gpa: std.mem.Allocator,
    /// Creation-time choices that stay fixed for the renderer's lifetime.
    options: Options,
    io: std.Io,
    /// The underlying device, for custom passes and offscreen targets.
    device: *rhi.Device,

    pipelines: Pipelines,
    tonemap_pipelines: std.ArrayList(TonemapPipeline) = .empty,
    /// Builds of the shading pass for the feature sets seen so far.
    shade_variants: std.ArrayList(ShadeVariant) = .empty,
    /// This frame's animated entities, and scratch space for each thread
    /// that works out their poses.
    posed: std.ArrayList(Entity) = .empty,
    /// Where the round of ray-tracing structure refits has got to.
    refit_cursor: usize = 0,
    /// Loaded models with per-texture coordinate transforms.
    texture_transform_users: u32 = 0,
    pose_scratch: [max_pose_threads]std.ArrayList(animation.Local) = @splat(.empty),
    draw_pipelines: std.ArrayList(DrawPipelines) = .empty,
    /// Guards all renderer and device state; see `lock`.
    mutex: std.Io.Mutex = .init,
    default_font: *Font = undefined,
    fonts: std.ArrayList(*Font) = .empty,
    font_textures: std.ArrayList(rhi.Texture) = .empty,
    images: std.ArrayList(ImageEntry) = .empty,
    sampler_linear_clamp: rhi.Sampler,
    sampler_nearest_clamp: rhi.Sampler,
    sampler_linear_repeat: rhi.Sampler,
    sampler_shadow: rhi.Sampler,
    sampler_local_shadow: rhi.Sampler,
    material_samplers: [36]?rhi.Sampler = @splat(null),

    vertices: Pool,
    skin_vertices: Pool,
    morph_deltas: Pool,
    indices: Pool,
    meshlets: Pool,
    /// Trees over the triangles of meshes, and the triangles their leaves
    /// list, for following rays without the GPU's ray tracing.
    bvh_nodes: Pool,
    bvh_items: Pool,
    /// The box of every mesh that has a tree, by its place among the
    /// mesh records, in the mesh's own space.
    mesh_boxes: std.ArrayList(?[2][3]f32) = .empty,
    meshes: Pool,
    materials: Pool,

    arenas: [rhi.frames_in_flight]FrameArena,
    cull_commands: ?rhi.Buffer = null,
    cull_capacity: u32 = 0,
    cull_counts: rhi.Buffer,
    count_readback: [rhi.frames_in_flight]rhi.Buffer = undefined,
    /// Counts the rounds of texture streaming (see `EntityData.seen_round`).
    seen_round: u64 = 0,
    /// Bound in place of a view's cascades while it draws without shadows.
    shadow_map: rhi.Texture,
    /// Shadow atlas for spot and point lights.
    local_shadow_map: rhi.Texture,
    clusters: rhi.Buffer,
    transparent_order: std.ArrayList(TransparentDraw) = .empty,
    gi_pipelines: ?GiPipelines = null,
    blas_pending: u32 = 0,
    brdf_lut: rhi.Texture,

    models: handle.HandleTable(ModelEntry, ModelTag),
    environments: handle.HandleTable(EnvironmentEntry, EnvironmentTag),
    scenes: handle.HandleTable(SceneData, SceneTag),
    entities: handle.HandleTable(EntityData, EntityTag),
    emitters: handle.HandleTable(EmitterData, EmitterTag),
    probes: handle.HandleTable(ProbeData, ReflectionProbeTag),
    fluids: handle.HandleTable(FluidState, FluidTag),
    waters: handle.HandleTable(WaterState, WaterTag),
    liquids: handle.HandleTable(LiquidState, LiquidTag),
    /// The box liquids stand in as for rays; made with the first liquid.
    liquid_proxy_model: ?Model = null,
    instance_groups: handle.HandleTable(InstanceGroupData, InstanceGroupTag),
    /// Bumped whenever the set of ready models changes.
    asset_generation: u64 = 1,
    loading_count: u32 = 0,

    views: handle.HandleTable(ViewData, ViewTag),
    main_view: View = undefined,
    /// Targets drawn to so far this frame; the first view to touch one
    /// clears it, later ones draw over it.
    frame_targets: [16]rhi.Texture = undefined,
    frame_target_count: u32 = 0,
    /// Scene views recorded so far this frame.
    frame_scene_views: u32 = 0,
    /// Scene whose lights the local shadow atlas currently holds.
    local_shadow_scene: ?Scene = null,
    local_shadow_frame: u64 = std.math.maxInt(u64),
    /// What the atlas was last drawn from; see where it is compared.
    local_shadow_key: u64 = 0,
    /// Whether something moving was in each tile when it was last drawn.
    local_tile_had_mover: [max_local_shadow_views]bool = @splat(false),
    /// Some computed sky is waiting to be rebuilt.
    skies_dirty: bool = false,
    /// Shading pipelines of custom material shaders; slot 0 is the standard
    /// material.
    material_shaders: [32]?MaterialPipelines = @splat(null),
    /// Loaded materials using each slot; unused shaders cost nothing.
    material_shader_users: [32]u32 = @splat(0),
    pick_buffer: rhi.Buffer = undefined,
    pick_readback: [rhi.frames_in_flight]rhi.Buffer = undefined,
    pick_request: ?PickRequest = null,
    pick_pending: [rhi.frames_in_flight]?PickPending = @splat(null),
    pick_result: ?PickResult = null,
    frame_index: u64 = 0,
    time: f32 = 0,
    cloud_noise: ?rhi.Texture = null,
    stats: Stats = .{},

    skin_jobs: std.ArrayList(SkinJob) = .empty,
    /// Morph target weights of this frame's skin jobs, back to back.
    skin_weights: std.ArrayList(f32) = .empty,
    /// Meshes whose meshlet bounds are worked out after skinning.
    bounds_jobs: std.ArrayList(BoundsJob) = .empty,
    /// Acceleration structures of deformed meshes to rebuild once this
    /// frame's skinning has run.
    blas_jobs: std.ArrayList(BlasJob) = .empty,
    scratch_locals: std.ArrayList(animation.Local) = .empty,
    scratch_refs: std.ArrayList(gpu.MeshletRef) = .empty,
    scratch_instances: std.ArrayList(gpu.Instance) = .empty,

    /// Creates the device and the renderer on it, and returns once the
    /// built-in pipelines, the main view and the default font are ready.
    /// The result is allocated with `gpa`, which the renderer keeps for
    /// all its own allocations and which must outlive it; `io` is kept
    /// likewise and runs the background loading jobs. Free with `deinit`.
    ///
    /// Fails when no suitable Vulkan device is found or a GPU resource
    /// cannot be created. A missing optional feature (ray tracing, BC
    /// formats, HDR output) is not an error: what depends on it is left
    /// out.
    pub fn init(gpa: std.mem.Allocator, io: std.Io, options: Options) !*Renderer {
        const device = try rhi.Device.init(gpa, io, .{
            .application_name = options.application_name,
            .validation = options.validation,
            .surface = options.surface,
            .preferred_device = options.preferred_device,
            .pipeline_cache_path = options.pipeline_cache_path,
            .debug_names = options.debug_names,
            .hdr_output = options.hdr_output,
            .ray_tracing = options.ray_tracing,
        });
        errdefer device.deinit();
        gltf.acquireLibraries(io);
        errdefer gltf.releaseLibraries(io);

        const self = try gpa.create(Renderer);
        errdefer gpa.destroy(self);
        const storage = rhi.BufferUsage{ .storage = true, .copy_src = true, .copy_dst = true };
        const geometry = rhi.BufferUsage{ .storage = true, .index = true, .copy_src = true, .copy_dst = true, .acceleration_input = true };
        self.* = .{
            .gpa = gpa,
            .options = options,
            .io = io,
            .device = device,
            .pipelines = try createPipelines(device),
            .sampler_linear_clamp = try device.createSampler(.{ .address_u = .clamp_to_edge, .address_v = .clamp_to_edge, .address_w = .clamp_to_edge }),
            .sampler_nearest_clamp = try device.createSampler(.{
                .min_filter = .nearest,
                .mag_filter = .nearest,
                .mip_filter = .nearest,
                .address_u = .clamp_to_edge,
                .address_v = .clamp_to_edge,
                .address_w = .clamp_to_edge,
            }),
            .sampler_linear_repeat = try device.createSampler(.{ .max_anisotropy = 16 }),
            .sampler_shadow = try device.createSampler(.{
                .address_u = .clamp_to_border,
                .address_v = .clamp_to_border,
                .address_w = .clamp_to_border,
                .mip_filter = .nearest,
                .compare = .less_or_equal,
            }),
            .vertices = try Pool.init(device, "vertices", @sizeOf(gpu.Vertex), 1 << 20, geometry),
            .skin_vertices = try Pool.init(device, "skin vertices", @sizeOf(gpu.SkinVertex), 1 << 16, storage),
            .morph_deltas = try Pool.init(device, "morph deltas", @sizeOf(gltf.MorphDelta), 1 << 14, storage),
            .indices = try Pool.init(device, "indices", @sizeOf(u32), 1 << 22, geometry),
            .meshlets = try Pool.init(device, "meshlets", @sizeOf(gpu.Meshlet), 1 << 16, storage),
            .bvh_nodes = try Pool.init(device, "bvh nodes", @sizeOf(bvh.Node), 1 << 10, storage),
            .bvh_items = try Pool.init(device, "bvh items", @sizeOf(u32), 1 << 10, storage),
            .meshes = try Pool.init(device, "meshes", @sizeOf(gpu.Mesh), 1 << 12, storage),
            .materials = try Pool.init(device, "materials", @sizeOf(gpu.Material), 1 << 12, storage),
            .arenas = undefined,
            .cull_counts = try device.createBuffer(.{ .name = "cull counts", .size = view_count * 2 * @sizeOf(u32), .usage = .{ .storage = true, .indirect = true, .copy_src = true } }),
            .sampler_local_shadow = try device.createSampler(.{
                .address_u = .clamp_to_edge,
                .address_v = .clamp_to_edge,
                .address_w = .clamp_to_edge,
                .mip_filter = .nearest,
                .compare = .greater_or_equal,
            }),
            .local_shadow_map = try device.createTexture(.{
                .name = "local shadow atlas",
                .width = options.local_shadow_resolution,
                .height = options.local_shadow_resolution,
                .format = .depth32_float,
                .usage = .{ .sampled = true, .depth_attachment = true },
            }),
            .clusters = try device.createBuffer(.{ .name = "light clusters", .size = gpu.cluster_count * @sizeOf(gpu.Cluster), .usage = .{ .storage = true } }),
            .shadow_map = try device.createTexture(.{
                .name = "shadow fallback",
                .width = 1,
                .height = 1,
                .format = .depth32_float,
                .usage = .{ .sampled = true, .depth_attachment = true },
                .layers = gpu.cascade_count,
                .kind = .@"2d_array",
            }),
            .brdf_lut = try device.createTexture(.{
                .name = "brdf lut",
                .width = 128,
                .height = 128,
                .format = .rg16_float,
                .usage = .{ .sampled = true, .color_attachment = true },
            }),
            .models = .init(gpa),
            .environments = .init(gpa),
            .scenes = .init(gpa),
            .views = .init(gpa),
            .entities = .init(gpa),
            .emitters = .init(gpa),
            .probes = .init(gpa),
            .fluids = .init(gpa),
            .waters = .init(gpa),
            .liquids = .init(gpa),
            .instance_groups = .init(gpa),
        };
        for (&self.arenas) |*arena| arena.* = try FrameArena.init(device, 4 * 1024 * 1024);
        if (device.ray_tracing) self.gi_pipelines = try createGiPipelines(device);
        for (&self.count_readback) |*buffer| {
            buffer.* = try device.createBuffer(.{ .name = "cull count readback", .size = view_count * 2 * @sizeOf(u32), .usage = .{}, .memory = .gpu_to_cpu });
            @memset(device.mapped(buffer.*), 0);
        }
        self.main_view = try self.insertView();
        self.pick_buffer = try device.createBuffer(.{ .name = "pick", .size = @sizeOf(gpu.Pick), .usage = .{ .storage = true, .copy_src = true } });
        for (&self.pick_readback) |*buffer| {
            buffer.* = try device.createBuffer(.{ .name = "pick readback", .size = @sizeOf(gpu.Pick), .usage = .{}, .memory = .gpu_to_cpu });
            @memset(device.mapped(buffer.*), 0);
        }

        self.default_font = try gpa.create(Font);
        self.default_font.* = try font_module.load(gpa, @embedFile("fonts/DejaVuSans.ttf"), font_module.default_ranges);
        try self.registerFont(self.default_font);
        if (options.asset_cache_max_bytes != 0) if (options.asset_cache_dir) |directory| {
            _ = gltf.trimCache(gpa, self.io, directory, options.asset_cache_max_bytes) catch |err| std.log.warn("asset cache not trimmed: {}", .{err});
        };

        // One-time setup that needs the GPU: the DFG lookup table, and
        // defined contents for the shadow map so it can be sampled even
        // before the first shadow pass.
        var cmd = try device.beginImmediate();
        try cmd.flushUploads();
        try cmd.beginRendering(.{ .color = &.{.{ .texture = self.brdf_lut, .load = .discard }} });
        cmd.bindPipeline(self.pipelines.brdf_lut);
        cmd.drawFullscreen();
        cmd.endRendering();
        cmd.transition(self.brdf_lut, .shader_read);
        for (0..gpu.cascade_count) |cascade| {
            try cmd.beginRendering(.{ .depth = .{ .texture = self.shadow_map, .layer = @intCast(cascade), .clear = 1 } });
            cmd.endRendering();
        }
        cmd.transition(self.shadow_map, .shader_read);
        try cmd.beginRendering(.{ .depth = .{ .texture = self.local_shadow_map, .clear = 0 } });
        cmd.endRendering();
        cmd.transition(self.local_shadow_map, .shader_read);
        try device.endImmediate();
        return self;
    }

    /// Waits for the GPU to finish, then destroys everything the renderer
    /// still holds (scenes, entities, models, environments, fonts, images,
    /// views), the device and the renderer itself. Every handle and font
    /// pointer from it is invalid afterwards. Takes no lock: no other
    /// thread may be using the renderer.
    pub fn deinit(self: *Renderer) void {
        const device = self.device;
        device.waitIdle() catch {};
        while (self.entities.popAny()) |entity| self.freeEntityStorage(entity);
        while (self.scenes.popAny()) |scene_value| {
            var scene = scene_value;
            self.freeScene(&scene);
        }
        while (self.models.popAny()) |model_value| {
            var model = model_value;
            self.freeModel(&model);
        }
        while (self.environments.popAny()) |environment_value| {
            var environment = environment_value;
            self.freeEnvironment(&environment);
        }
        self.entities.deinit();
        while (self.emitters.popAny()) |emitter| {
            device.destroyBuffer(emitter.buffer);
            if (emitter.order) |order| device.destroyBuffer(order);
        }
        self.emitters.deinit();
        self.probes.deinit();
        while (self.fluids.popAny()) |fluid| {
            var state = fluid;
            self.destroyFluidTextures(&state);
        }
        self.fluids.deinit();
        while (self.waters.popAny()) |water| for (water.state) |texture| device.destroyTexture(texture);
        self.waters.deinit();
        for (self.liquids.slots.items) |*slot| if (slot.value) |*state| state.deinit(self.device);
        self.liquids.deinit();
        while (self.instance_groups.popAny()) |group| {
            self.gpa.free(group.transforms);
            self.gpa.free(group.tints);
            self.gpa.free(group.params);
        }
        self.instance_groups.deinit();
        self.scenes.deinit();
        self.models.deinit();
        self.environments.deinit();
        while (self.views.popAny()) |view_value| {
            var view = view_value;
            view.deinit(device);
        }
        self.views.deinit();
        if (self.gi_pipelines) |pipelines| {
            device.destroyPipeline(pipelines.trace);
            device.destroyPipeline(pipelines.irradiance);
            device.destroyPipeline(pipelines.clamp_upper);
            device.destroyPipeline(pipelines.clamp_lower);
            device.destroyPipeline(pipelines.relocate);
            device.destroyPipeline(pipelines.visibility);
        }
        self.dropShadeVariants();
        self.shade_variants.deinit(self.gpa);
        self.posed.deinit(self.gpa);
        for (&self.pose_scratch) |*scratch| scratch.deinit(self.gpa);
        for (self.tonemap_pipelines.items) |entry| device.destroyPipeline(entry.pipeline);
        self.tonemap_pipelines.deinit(self.gpa);
        for (self.draw_pipelines.items) |entry| {
            device.destroyPipeline(entry.flat);
            device.destroyPipeline(entry.depth_tested);
        }
        self.draw_pipelines.deinit(self.gpa);
        for (self.fonts.items, self.font_textures.items) |font, texture| {
            device.destroyTexture(texture);
            font.deinit();
            self.gpa.destroy(font);
        }
        self.fonts.deinit(self.gpa);
        self.font_textures.deinit(self.gpa);
        for (self.images.items) |entry| device.destroyTexture(entry.texture);
        self.images.deinit(self.gpa);
        inline for (@typeInfo(Pipelines).@"struct".fields) |field| {
            const pipeline = @field(self.pipelines, field.name);
            if (@typeInfo(@TypeOf(pipeline)) == .optional) {
                if (pipeline) |made| device.destroyPipeline(made);
            } else device.destroyPipeline(pipeline);
        }
        for (self.material_samplers) |sampler| if (sampler) |value| device.destroySampler(value);
        device.destroySampler(self.sampler_linear_clamp);
        device.destroySampler(self.sampler_nearest_clamp);
        device.destroySampler(self.sampler_linear_repeat);
        device.destroySampler(self.sampler_shadow);
        device.destroySampler(self.sampler_local_shadow);
        device.destroyTexture(self.local_shadow_map);
        device.destroyBuffer(self.clusters);
        self.transparent_order.deinit(self.gpa);
        inline for (.{ "vertices", "skin_vertices", "morph_deltas", "indices", "meshlets", "bvh_nodes", "bvh_items", "meshes", "materials" }) |name| @field(self, name).deinit(self);
        self.mesh_boxes.deinit(self.gpa);
        for (&self.arenas) |*arena| arena.deinit(device);
        device.destroyBuffer(self.cull_counts);
        for (self.count_readback) |buffer| device.destroyBuffer(buffer);
        device.destroyBuffer(self.pick_buffer);
        for (self.material_shaders) |shader| if (shader) |pipelines| {
            device.destroyPipeline(pipelines.plain);
            device.destroyPipeline(pipelines.reflective);
        };
        for (self.pick_readback) |buffer| device.destroyBuffer(buffer);
        if (self.cull_commands) |buffer| device.destroyBuffer(buffer);
        device.destroyTexture(self.shadow_map);
        device.destroyTexture(self.brdf_lut);
        if (self.cloud_noise) |texture| device.destroyTexture(texture);
        self.skin_jobs.deinit(self.gpa);
        self.skin_weights.deinit(self.gpa);
        self.bounds_jobs.deinit(self.gpa);
        self.blas_jobs.deinit(self.gpa);
        self.scratch_locals.deinit(self.gpa);
        self.scratch_refs.deinit(self.gpa);
        self.scratch_instances.deinit(self.gpa);
        var overrides = shader_overrides.valueIterator();
        while (overrides.next()) |code| self.gpa.free(code.*);
        shader_overrides.deinit(self.gpa);
        shader_overrides = .empty;
        const gpa = self.gpa;
        const io = self.io;
        gpa.destroy(self);
        gltf.releaseLibraries(io);
        device.deinit();
    }

    /// Tells the renderer the window's framebuffer is now `width` by
    /// `height` pixels. The swapchain is rebuilt when the next frame
    /// starts, not here, so this is cheap to call on every resize event
    /// and does nothing when the size is unchanged or there is no window.
    /// Safe from any thread.
    pub fn resize(self: *Renderer, width: u32, height: u32) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.device.resize(width, height);
    }

    /// How `Settings.path_tracing` would run on this device; see
    /// `PathTracing`. Fixed for the life of the renderer. Safe from any
    /// thread.
    pub fn pathTracing(self: *const Renderer) PathTracing {
        if (self.device.ray_tracing) return .hardware;
        return if (self.options.path_tracing_fallback) .shader else .unavailable;
    }

    /// Counters from the last frame rendered, with the loading count and
    /// GPU memory use as they are now. Safe from any thread.
    pub fn getStats(self: *Renderer) Stats {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var stats = self.stats;
        stats.models_loading = self.loading_count;
        stats.gpu_memory_bytes = self.device.memoryStats().used_bytes;
        return stats;
    }

    // --------------------------------------------------------------- assets

    fn lodOptions(self: *const Renderer) gltf.LodOptions {
        return .{ .clusters = self.options.cluster_lods, .normal_weight = self.options.lod_normal_weight, .uv_weight = self.options.lod_uv_weight };
    }

    /// Starts loading a glTF model in the background and returns
    /// immediately. Entities may reference the model right away; they appear
    /// once it has streamed in.
    pub fn loadModel(self: *Renderer, path: []const u8) !Model {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const job = try self.gpa.create(ModelJob);
        errdefer self.gpa.destroy(job);
        job.* = .{
            .gpa = self.options.job_allocator orelse std.heap.smp_allocator,
            .io = self.io,
            .path = try self.gpa.dupe(u8, path),
            .options = .{
                .compress_textures = self.options.texture_compression == .bc7 and self.device.bc_textures,
                .normal_maps_bc5 = self.options.normal_maps_bc5,
                .raw_mips = self.options.texture_streaming != null,
                .lods = self.lodOptions(),
                .cache_dir = self.options.asset_cache_dir,
            },
        };
        errdefer self.gpa.free(job.path);
        const model = try self.models.insert(.{ .job = job });
        job.group.concurrent(self.io, runModelJob, .{job}) catch job.group.async(self.io, runModelJob, .{job});
        self.loading_count += 1;
        return model;
    }

    /// Creates a model from geometry in memory (see `MeshDesc`). The model
    /// becomes ready on the next frame or `waitUntilLoaded`.
    pub fn createModel(self: *Renderer, meshes: []const MeshDesc) !Model {
        // Mesh processing needs no renderer state.
        var source = try gltf.fromMeshes(self.options.job_allocator orelse std.heap.smp_allocator, meshes, self.lodOptions());
        errdefer source.deinit();
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const model = try self.models.insert(.{ .source = source });
        self.loading_count += 1;
        return model;
    }

    /// Whether a model is still loading, ready to draw, or failed (see
    /// `modelError`). A handle that names no model reports `.failed`.
    /// Safe from any thread.
    pub fn modelState(self: *Renderer, model: Model) AssetState {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return (self.models.get(model) orelse return .failed).state;
    }

    /// The error a failed load ended with, if any.
    pub fn modelError(self: *Renderer, model: Model) ?anyerror {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return (self.models.get(model) orelse return error.InvalidModel).failure;
    }

    /// Null until the model is ready.
    pub fn modelInfo(self: *Renderer, model: Model) ?ModelInfo {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const entry = self.models.get(model) orelse return null;
        return if (entry.state == .ready) entry.info else null;
    }

    /// How many animation clips a model has; valid `Pose.animation`
    /// indices are below it. 0 until the model is ready.
    pub fn animationCount(self: *Renderer, model: Model) u32 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const entry = self.models.get(model) orelse return 0;
        if (entry.state != .ready) return 0;
        return @intCast(entry.source.?.animations.len);
    }

    /// Name and length in seconds of one of a model's animation clips.
    /// Null until the model is ready, or when `index` is out of range.
    /// The name is not copied: it stays valid until the model is
    /// destroyed.
    pub fn animationInfo(self: *Renderer, model: Model, index: u32) ?AnimationInfo {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const entry = self.models.get(model) orelse return null;
        if (entry.state != .ready or index >= entry.source.?.animations.len) return null;
        const clip = entry.source.?.animations[index];
        return .{ .name = clip.name, .duration = clip.duration };
    }

    /// Index of the node (bone) with this name, for `Pose.Blend.root`.
    /// Null until the model has loaded, or if there is no such node.
    pub fn findNode(self: *Renderer, model: Model, name: []const u8) ?u32 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const entry = self.models.get(model) orelse return null;
        if (entry.state != .ready) return null;
        for (entry.source.?.nodes, 0..) |node, index| {
            if (std.mem.eql(u8, node.name, name)) return @intCast(index);
        }
        return null;
    }

    /// How far an animation carries one node (the root bone, see
    /// `findNode`) between two times, in the model's space. Play the clip
    /// with `Pose.in_place` set to that node and move the entity by this
    /// each frame: the character then travels exactly as far as its feet
    /// do. Times past the clip's length count whole loops.
    pub fn rootMotion(self: *Renderer, model: Model, animation_index: u32, node: u32, from: f32, to: f32) !Vec3 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const entry = self.models.get(model) orelse return error.InvalidModel;
        if (entry.state != .ready) return error.ModelNotReady;
        const source = &entry.source.?;
        if (node >= source.nodes.len) return error.InvalidNode;
        try self.scratch_locals.resize(self.gpa, source.nodes.len * 3);
        const moved = animation.rootMotion(source, self.scratch_locals.items, animation_index, node, from, to, true);
        // From the node's parent space into the model's.
        return if (source.nodes[node].parent) |parent| math.transformDirection(entry.node_world[parent], moved) else moved;
    }

    /// Finds an animation by name, e.g. "Walking", and returns its index
    /// for `Pose.animation`. The match is exact and case-sensitive; the
    /// first clip with the name wins. Null until the model has loaded, or
    /// if there is no such clip.
    pub fn findAnimation(self: *Renderer, model: Model, name: []const u8) ?u32 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const entry = self.models.get(model) orelse return null;
        if (entry.state != .ready) return null;
        for (entry.source.?.animations, 0..) |clip, index| {
            if (std.mem.eql(u8, clip.name, name)) return @intCast(index);
        }
        return null;
    }

    /// Fails with `error.ModelInUse` while any entity still references it.
    pub fn destroyModel(self: *Renderer, model: Model) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const entry = self.models.get(model) orelse return error.InvalidModel;
        if (entry.references != 0) return error.ModelInUse;
        var removed = self.models.remove(model).?;
        if (removed.state == .loading) self.loading_count -= 1;
        self.freeModel(&removed);
        self.asset_generation += 1;
    }

    /// Starts loading an environment for image-based lighting and the sky:
    /// an equirectangular `.hdr` panorama, or a KTX2 cube map of half
    /// floats or BC6H blocks (any size; its mips are used when it is
    /// larger than the sky cube). Radiance is clamped to `max_radiance` so
    /// a sun baked into the picture does not produce fireflies. A BC6H cube
    /// is not decoded here, so its `brightest_direction` stays straight up.
    pub fn loadEnvironment(self: *Renderer, path: []const u8, max_radiance: f32) !Environment {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const job = try self.gpa.create(EnvironmentJob);
        errdefer self.gpa.destroy(job);
        job.* = .{ .gpa = self.options.job_allocator orelse std.heap.smp_allocator, .io = self.io, .path = try self.gpa.dupe(u8, path) };
        errdefer self.gpa.free(job.path);
        const environment = try self.environments.insert(.{ .job = job, .max_radiance = max_radiance });
        job.group.concurrent(self.io, runEnvironmentJob, .{job}) catch job.group.async(self.io, runEnvironmentJob, .{job});
        self.loading_count += 1;
        return environment;
    }

    /// Creates an environment from a computed clear sky. It is ready on
    /// return and is used like one loaded from a file: `setEnvironment`
    /// makes it the scene's backdrop, ambient light and reflections. Pair
    /// it with `skySun(desc)` for matching sunlight.
    pub fn createSky(self: *Renderer, desc: SkyDesc) !Environment {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const environment = try self.environments.insert(.{ .max_radiance = 64, .sky_desc = desc });
        errdefer _ = self.environments.remove(environment);
        const entry = self.environments.get(environment).?;
        errdefer self.freeEnvironment(entry);
        try self.ensureEnvironmentTextures(entry);
        var cmd = try self.device.beginImmediate();
        try self.bakeSky(entry, &cmd, true);
        try self.device.endImmediate();
        entry.state = .ready;
        return environment;
    }

    /// Changes a sky made with `createSky`, for time of day or weather. The
    /// maps are rebuilt during the next frame, which costs about a
    /// millisecond of GPU time; change it as often as the sun visibly moves.
    pub fn setSky(self: *Renderer, environment: Environment, desc: SkyDesc) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const entry = self.environments.get(environment) orelse return;
        if (entry.sky_desc == null) return;
        if (std.meta.eql(entry.sky_desc.?, desc)) return;
        entry.sky_desc = desc;
        entry.sky_dirty = true;
        self.skies_dirty = true;
    }

    /// Draws a computed sky into its cube and filters the lighting from
    /// it: all at once with `whole`, otherwise as many faces as the
    /// description's `rebuild_frames` allows per call, picking up where
    /// the last call stopped.
    fn bakeSky(self: *Renderer, entry: *EnvironmentEntry, cmd: *rhi.CommandEncoder, whole: bool) !void {
        const sky = entry.sky.?;
        cmd.beginScope("sky bake");
        defer cmd.endScope();
        if (entry.bake_step == 0) {
            // A rebuild is drawn from the description as it was when it
            // began; changes made meanwhile start another afterwards.
            entry.bake_desc = entry.sky_desc.?;
            entry.sky_dirty = false;
        }
        const desc = entry.bake_desc;
        // With a cloud layer the cube is drawn twice: with clouds, to
        // derive the lighting from, then clear, as the backdrop the real
        // clouds are drawn over.
        const passes: u32 = if (entry.clouds != null) 2 else 1;
        // One pass can be taken a step at a time: six faces, the diffuse
        // cube, then each roughness level of the reflection cube.
        const stepped = passes == 1;
        const total = if (stepped) 6 + 1 + env_specular_mips else passes * 6;
        const spread = if (whole or entry.clouds != null) 1 else @max(desc.rebuild_frames, 1);
        var budget: u32 = (total + spread - 1) / spread;
        while (entry.bake_step < total and budget > 0) : (budget -= 1) {
            if (stepped and entry.bake_step >= 6) {
                if (entry.bake_step == 6) try self.filterIrradiance(entry, cmd) else try self.filterSpecularMip(entry, cmd, entry.bake_step - 7);
                entry.bake_step += 1;
                continue;
            }
            const pass = entry.bake_step / 6;
            const face = entry.bake_step % 6;
            var clouds = std.mem.zeroes(gpu.Clouds);
            if (pass == 0) if (entry.clouds) |layer| {
                clouds = layer;
                clouds.depth = self.device.samplerIndex(self.sampler_linear_clamp);
            };
            try cmd.beginRendering(.{ .color = &.{.{ .texture = sky, .layer = face, .load = .discard }} });
            cmd.bindPipeline(self.pipelines.env_sky);
            cmd.pushConstants(extern struct { to_sun: [3]f32, face: u32, ground_color: [3]f32, turbidity: f32, intensity: f32, max_radiance: f32, sun_disc: f32, stars: f32, to_moon: [3]f32, moon: f32, ozone: f32, clouds: gpu.Clouds }{
                .to_sun = math.scale(math.normalize(desc.sun_direction), -1),
                .face = @intCast(face),
                .ground_color = desc.ground_color,
                .turbidity = std.math.clamp(desc.turbidity, 1, 10),
                .intensity = desc.intensity,
                .max_radiance = entry.max_radiance,
                .sun_disc = @floatFromInt(@intFromBool(desc.sun_disc)),
                .stars = @max(desc.stars, 0),
                .to_moon = math.scale(math.normalize(desc.moon_direction), -1),
                .moon = @max(desc.moon, 0),
                .ozone = @max(desc.ozone, 0),
                .clouds = clouds,
            });
            cmd.drawFullscreen();
            cmd.endRendering();
            entry.bake_step += 1;
            if (face == 5) {
                cmd.generateMips(sky);
                if (pass == 0 and !stepped) try self.filterEnvironment(entry, cmd);
            }
        }
        if (entry.bake_step >= total) entry.bake_step = 0;
        // More to draw, or a change that came in meanwhile: again next frame.
        if (entry.bake_step != 0 or entry.sky_dirty) self.skies_dirty = true;
    }

    /// Whether an environment is still loading, ready, or failed. A handle
    /// that names no environment reports `.failed`. Safe from any thread.
    pub fn environmentState(self: *Renderer, environment: Environment) AssetState {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return (self.environments.get(environment) orelse return .failed).state;
    }

    /// What was measured while the environment loaded. Null until it is
    /// ready.
    pub fn environmentInfo(self: *Renderer, environment: Environment) ?EnvironmentInfo {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const entry = self.environments.get(environment) orelse return null;
        return if (entry.state == .ready) .{ .brightest_direction = entry.brightest_direction } else null;
    }

    /// Frees an environment and its textures, cancelling the load if it is
    /// still under way. A scene that still has it set (`setEnvironment`)
    /// draws as if it had none. A handle that names nothing is ignored.
    pub fn destroyEnvironment(self: *Renderer, environment: Environment) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var removed = self.environments.remove(environment) orelse return;
        if (removed.state == .loading) self.loading_count -= 1;
        self.freeEnvironment(&removed);
    }

    /// True while any model or environment is still streaming in.
    pub fn isLoading(self: *Renderer) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.loading_count != 0;
    }

    /// Blocks until every pending asset is decoded and on the GPU. Meant for
    /// tools and tests; interactive applications should keep rendering and
    /// let assets stream in.
    pub fn waitUntilLoaded(self: *Renderer) !void {
        while (true) {
            {
                self.mutex.lockUncancelable(self.io);
                defer self.mutex.unlock(self.io);
                if (self.loading_count == 0) return;
                if (self.anyJobFinished()) {
                    var cmd = try self.device.beginImmediate();
                    _ = try self.pumpAssets(&cmd, std.math.maxInt(u64));
                    try cmd.flushUploads();
                    try self.buildPendingBlas(&cmd);
                    try cmd.flushUploads();
                    try self.device.endImmediate();
                    continue;
                }
            }
            try self.io.sleep(std.Io.Duration.fromMilliseconds(1), .awake);
        }
    }

    fn anyJobFinished(self: *Renderer) bool {
        for (self.models.slots.items) |*slot| if (slot.value) |*entry| {
            if (entry.state != .loading) continue;
            if (entry.job == null or entry.job.?.done.load(.acquire)) return true;
        };
        for (self.environments.slots.items) |*slot| if (slot.value) |*entry| {
            if (entry.state == .loading and entry.job.?.done.load(.acquire)) return true;
        };
        return false;
    }

    /// Moves finished decode jobs onto the GPU, spending at most
    /// `budget_bytes` of texture uploads so frames stay responsive.
    fn pumpAssets(self: *Renderer, cmd: *rhi.CommandEncoder, budget_bytes: u64) !bool {
        const zone = Zone.start(self.options.profiler, "stream assets");
        defer zone.stop();
        if (self.loading_count == 0) return false;
        var budget = budget_bytes;
        var progressed = false;
        for (self.models.slots.items) |*slot| if (slot.value) |*entry| {
            if (entry.state != .loading) continue;
            if (entry.job) |job| if (!job.done.load(.acquire)) continue;
            progressed = true;
            const finished = self.finalizeModel(entry, &budget) catch |err| blk: {
                std.log.err("model load failed: {}", .{err});
                self.freeModel(entry);
                const references = entry.references;
                entry.* = .{ .state = .failed, .failure = err, .references = references };
                break :blk true;
            };
            if (finished) {
                self.loading_count -= 1;
                self.asset_generation += 1;
            }
            if (budget == 0) break;
        };
        for (self.environments.slots.items) |*slot| if (slot.value) |*entry| {
            if (entry.state != .loading or entry.job == null or !entry.job.?.done.load(.acquire)) continue;
            progressed = true;
            self.finalizeEnvironment(entry, cmd) catch |err| {
                std.log.err("environment load failed: {}", .{err});
                self.freeEnvironment(entry);
                entry.state = .failed;
                entry.failure = err;
            };
            self.loading_count -= 1;
        };
        return progressed;
    }

    fn finalizeModel(self: *Renderer, entry: *ModelEntry, budget: *u64) !bool {
        const device = self.device;
        const gpa = self.gpa;
        if (entry.job) |job| {
            job.group.await(job.io) catch {};
            const failure = job.failure;
            entry.source = job.model;
            gpa.free(job.path);
            gpa.destroy(job);
            entry.job = null;
            if (failure) |err| return err;
            entry.textures = try gpa.alloc(?rhi.Texture, entry.source.?.images.len);
            @memset(entry.textures, null);
            entry.streams = try gpa.alloc(TextureStream, entry.source.?.images.len);
            @memset(entry.streams, .{});
        }
        const source = &entry.source.?;

        // Textures first, a budgeted few per call.
        while (entry.next_image < source.images.len) : (entry.next_image += 1) {
            if (budget.* == 0) return false;
            const image = source.images[entry.next_image];
            if (image.compressed) |data| {
                // Encoded at load (or read from the cache) with its mips.
                const mips = if (image.mip_levels != 0) image.mip_levels else rhi.TextureDesc.fullMipCount(image.width, image.height);
                const compressed_format = blockFormat(image.block, image.one_channel, image.two_channel, image.srgb);
                if (self.options.texture_streaming) |streaming| {
                    // Start with the small levels; the rest arrive when a
                    // camera gets close enough to need them.
                    var floor: u32 = 0;
                    while (floor + 1 < mips and @max(image.width, image.height) >> @intCast(floor) > streaming.min_size) floor += 1;
                    const stream = &entry.streams[entry.next_image];
                    stream.* = .{ .data = source.takeCompressed(entry.next_image), .width = image.width, .height = image.height, .levels = mips, .srgb = image.srgb, .two_channel = image.two_channel, .one_channel = image.one_channel, .block = image.block, .floor = floor, .resident = floor, .wanted = floor };
                    stream.total = stream.data.len;
                    if (streaming.from_cache and floor > 0 and image.block == .bc7 and image.cache_key != 0) if (self.options.asset_cache_dir) |directory| {
                        // Keep only the small levels here; the cache file
                        // holds the rest for when they are wanted.
                        const extension: []const u8 = if (image.two_channel) "bc5" else if (image.one_channel) "bc4" else "bc7";
                        const path = try std.fmt.allocPrint(self.gpa, "{s}/{x:0>16}.{s}", .{ directory, image.cache_key, extension });
                        const tail_offset = stream.levelOffset(floor);
                        const in_cache = blk: {
                            const file = std.Io.Dir.cwd().openFile(self.io, path, .{}) catch break :blk false;
                            defer file.close(self.io);
                            const stat = file.stat(self.io) catch break :blk false;
                            break :blk stat.size == 12 + stream.total;
                        };
                        if (in_cache) {
                            const tail = try source.arena.child_allocator.dupe(u8, stream.data[tail_offset..]);
                            source.freeCompressed(stream.data);
                            stream.data = tail;
                            stream.tail_offset = tail_offset;
                            stream.path = path;
                        } else self.gpa.free(path);
                    };
                    entry.streamed += 1;
                    entry.textures[entry.next_image] = try self.createStreamTexture(stream, floor);
                    budget.* -|= stream.bytesFrom(floor);
                    continue;
                }
                const texture = try device.createTexture(.{
                    .name = "material texture",
                    .width = image.width,
                    .height = image.height,
                    .format = compressed_format,
                    .usage = .{ .sampled = true, .copy_dst = true },
                    .mip_levels = mips,
                });
                entry.textures[entry.next_image] = texture;
                // Every level through one staging buffer.
                const offset = data.len;
                try device.uploadTextureLevels(texture, 0, 0, data);
                source.releaseImage(entry.next_image);
                budget.* -|= offset;
                continue;
            }
            const pixels = image.pixels();
            if (pixels.len == 0) continue;
            const texture = try device.createTexture(.{
                .name = "material texture",
                .width = image.width,
                .height = image.height,
                .format = if (image.srgb) .rgba8_srgb else .rgba8_unorm,
                .usage = .{ .sampled = true, .copy_dst = true },
                .mip_levels = rhi.TextureDesc.fullMipCount(image.width, image.height),
            });
            entry.textures[entry.next_image] = texture;
            try device.uploadTexture(texture, 0, 0, pixels);
            try device.generateMips(texture);
            source.releaseImage(entry.next_image);
            budget.* -|= pixels.len;
        }

        entry.material_base = try self.materials.alloc(self, @intCast(source.materials.len));
        // Materials whose textures are not all transformed alike get a
        // block of per-texture transforms next to the material records.
        var transform_count: u32 = 0;
        for (source.materials) |material| {
            if (material.hasOwnTransforms()) transform_count += 1;
        }
        if (transform_count != 0) {
            entry.transform_base = try self.materials.alloc(self, transform_count * gpu.texture_transform_slots);
            entry.transform_count = transform_count;
            self.texture_transform_users += 1;
            var slot = entry.transform_base;
            for (source.materials) |material| {
                if (!material.hasOwnTransforms()) continue;
                var block: [gpu.material_texture_count]gpu.TextureTransform = undefined;
                for (material.textureRefs(), &block) |maybe, *out| {
                    const transform = if (maybe) |ref| ref.transform else material.sharedTransform();
                    out.* = .{ .matrix = uvMatrix(transform.scale, transform.rotation), .offset = transform.offset };
                }
                try self.materials.write(device, slot, std.mem.sliceAsBytes(&block));
                slot += gpu.texture_transform_slots;
            }
        }
        const materials = try gpa.alloc(gpu.Material, source.materials.len);
        defer gpa.free(materials);
        for (source.materials, materials, 0..) |material, *out, index| {
            out.* = try self.encodeMaterial(entry, material, index);
            self.material_shader_users[out.shader] += 1;
        }
        try self.materials.write(device, entry.material_base, std.mem.sliceAsBytes(materials));

        entry.mesh_base = try self.meshes.alloc(self, @intCast(source.meshes.len));
        entry.meshes = try gpa.alloc(ModelMesh, source.meshes.len);
        // Zeroed so a failure part-way through frees only what was allocated.
        @memset(entry.meshes, std.mem.zeroes(ModelMesh));
        const mesh_records = try gpa.alloc(gpu.Mesh, source.meshes.len);
        defer gpa.free(mesh_records);
        var triangle_count: u32 = 0;
        var meshlet_count: u32 = 0;
        for (source.meshes, entry.meshes, mesh_records) |mesh, *out, *record| {
            out.* = .{
                .vertex_offset = try self.vertices.alloc(self, @intCast(mesh.vertices.len)),
                .vertex_count = @intCast(mesh.vertices.len),
                .skin_offset = null,
                .index_offset = try self.indices.alloc(self, @intCast(mesh.indices.len)),
                .index_count = @intCast(mesh.indices.len),
                .lod0_index_count = mesh.lod0_index_count,
                .meshlet_offset = try self.meshlets.alloc(self, @intCast(mesh.meshlets.len)),
                .meshlet_count = @intCast(mesh.meshlets.len),
                .material = entry.material_base + mesh.material,
                .blend = source.materials[mesh.material].alpha_mode == .blend or source.materials[mesh.material].transmission > 0,
                .blas = null,
                .coarse_vertex_count = mesh.coarse_vertex_count,
                .coarse_error = mesh.coarse_error,
            };
            try self.vertices.write(device, out.vertex_offset, std.mem.sliceAsBytes(mesh.vertices));
            try self.indices.write(device, out.index_offset, std.mem.sliceAsBytes(mesh.indices));
            try self.meshlets.write(device, out.meshlet_offset, std.mem.sliceAsBytes(mesh.meshlets));
            // Without the GPU's ray tracing, path tracing walks a tree
            // over the mesh's triangles; skinned meshes, whose
            // triangles move, are left out of it.
            if (self.options.path_tracing_fallback and !device.ray_tracing and mesh.skin == null) try self.buildMeshTree(mesh, out, entry.mesh_base + @as(u32, @intCast((@intFromPtr(out) - @intFromPtr(entry.meshes.ptr)) / @sizeOf(ModelMesh))));
            if (mesh.skin) |skin| {
                out.skin_offset = try self.skin_vertices.alloc(self, @intCast(skin.len));
                try self.skin_vertices.write(device, out.skin_offset.?, std.mem.sliceAsBytes(skin));
                if (mesh.morph_targets != 0) {
                    out.morph_offset = try self.morph_deltas.alloc(self, @intCast(mesh.morph_deltas.len));
                    out.morph_targets = mesh.morph_targets;
                    try self.morph_deltas.write(device, out.morph_offset.?, std.mem.sliceAsBytes(mesh.morph_deltas));
                }
            }
            record.* = .{
                .center = mesh.bounds_center,
                .radius = mesh.bounds_radius,
                .index_offset = out.index_offset,
                .meshlet_offset = out.meshlet_offset,
                .meshlet_count = out.meshlet_count,
                .bvh = out.bvh_nodes orelse gpu.invalid_id,
            };
            triangle_count += out.lod0_index_count / 3;
            meshlet_count += out.meshlet_count;
        }
        try self.meshes.write(device, entry.mesh_base, std.mem.sliceAsBytes(mesh_records));

        entry.order = try animation.topologicalOrder(gpa, source.nodes);
        entry.node_world = try gpa.alloc(Mat4, source.nodes.len);
        try self.scratch_locals.resize(gpa, source.nodes.len * 3);
        animation.evaluate(source, entry.order, null, self.scratch_locals.items, entry.node_world);
        {
            // Posing an entity only has to work out the nodes something is
            // drawn at or skinned by, and their ancestors.
            const needed = try gpa.alloc(bool, source.nodes.len);
            defer gpa.free(needed);
            @memset(needed, false);
            for (source.instances) |instance| needed[instance.node] = true;
            for (source.skins) |skin| for (skin.joints) |joint| {
                needed[joint] = true;
            };
            // Children come after their parents, so walking the order
            // backwards reaches every ancestor.
            var remaining = entry.order.len;
            var count: usize = 0;
            while (remaining > 0) {
                remaining -= 1;
                const node = entry.order[remaining];
                if (!needed[node]) continue;
                count += 1;
                if (source.nodes[node].parent) |parent| needed[parent] = true;
            }
            entry.pose_order = try gpa.alloc(u32, count);
            var next: usize = 0;
            for (entry.order) |node| if (needed[node]) {
                entry.pose_order[next] = node;
                next += 1;
            };
            std.log.debug("model: {d} of {d} nodes posed", .{ count, source.nodes.len });
        }

        var minimum: Vec3 = @splat(std.math.inf(f32));
        var maximum: Vec3 = @splat(-std.math.inf(f32));
        var joint_count: u32 = 0;
        for (source.skins) |skin| joint_count += @intCast(skin.joints.len);
        for (source.instances) |instance| {
            const mesh = source.meshes[instance.mesh];
            const world = if (instance.skin != null) math.identity else entry.node_world[instance.node];
            const center = math.transformPoint(world, mesh.bounds_center);
            const radius = mesh.bounds_radius * math.maxScale(world);
            inline for (0..3) |axis| {
                minimum[axis] = @min(minimum[axis], center[axis] - radius);
                maximum[axis] = @max(maximum[axis], center[axis] + radius);
            }
        }
        var morph_meshes: u32 = 0;
        var morph_targets: u32 = 0;
        for (source.meshes) |mesh| {
            if (mesh.morph_targets == 0) continue;
            morph_meshes += 1;
            morph_targets = @max(morph_targets, mesh.morph_targets);
        }
        var texture_count: u32 = 0;
        for (entry.textures) |texture| {
            if (texture != null) texture_count += 1;
        }
        entry.info = .{
            .mesh_count = @intCast(source.meshes.len),
            .triangle_count = triangle_count,
            .meshlet_count = meshlet_count,
            .texture_count = texture_count,
            .joint_count = joint_count,
            .morph_meshes = morph_meshes,
            .morph_targets = morph_targets,
            .bounds_min = minimum,
            .bounds_max = maximum,
            .bounds_center = math.scale(math.add(minimum, maximum), 0.5),
            .bounds_radius = math.length(math.sub(maximum, minimum)) * 0.5,
        };
        if (device.ray_tracing) {
            // Static meshes get a bottom-level structure for ray queries;
            // it is built once their geometry upload has been recorded.
            for (entry.meshes) |*mesh| {
                if (mesh.skin_offset != null) continue;
                mesh.blas = try device.createBlas(geometry_passes.blasDesc(self, mesh.*));
            }
            entry.blas_pending = true;
            self.blas_pending += 1;
        }
        entry.state = .ready;
        return true;
    }

    /// One instance of the scene's tree as the shader reads it
    /// (`BvhInstance` in trace.glsl).
    const TraceInstance = extern struct {
        /// World to the mesh's own space, three rows of each of four
        /// columns.
        to_mesh: [12]f32,
        instance: u32,
        pad: [3]u32 = .{ 0, 0, 0 },
    };

    /// Builds the tree over the scene's instances that path tracing
    /// walks without the GPU's ray tracing, if what it would hold has
    /// changed: every instance whose mesh has a tree of its own.
    /// `entities` are this frame's entity records; instance groups
    /// follow them, as in the instance buffer.
    fn buildSceneTree(self: *Renderer, scene: *SceneData, entities: []const gpu.Instance) !void {
        const gpa = self.gpa;
        const device = self.device;
        const Placed = extern struct { transform: Mat4, mesh: u32, instance: u32 };
        var placed: std.ArrayList(Placed) = .empty;
        defer placed.deinit(gpa);
        for (entities, 0..) |record, index| {
            if (record.flags & (gpu.instance_skinned | gpu.instance_proxy) != 0) continue;
            if (record.mesh >= self.mesh_boxes.items.len or self.mesh_boxes.items[record.mesh] == null) continue;
            try placed.append(gpa, .{ .transform = record.transform, .mesh = record.mesh, .instance = @intCast(index) });
        }
        var record: u32 = @intCast(entities.len);
        for (scene.groups.items) |group_handle| {
            const group = self.instance_groups.get(group_handle) orelse continue;
            if (group.per_copy == 0) continue;
            const model = self.models.get(group.model) orelse continue;
            const source = &model.source.?;
            for (group.transforms) |placement| {
                for (source.instances) |instance| {
                    // Counted in step with the instance records.
                    defer record += 1;
                    const mesh = model.mesh_base + instance.mesh;
                    if (model.meshes[instance.mesh].skin_offset != null) continue;
                    if (mesh >= self.mesh_boxes.items.len or self.mesh_boxes.items[mesh] == null) continue;
                    try placed.append(gpa, .{ .transform = math.mul(placement, model.node_world[instance.node]), .mesh = mesh, .instance = record });
                }
            }
        }
        const hash = std.hash.Wyhash.hash(placed.items.len, std.mem.sliceAsBytes(placed.items)) | 1;
        if (scene.trace_ready and hash == scene.trace_hash) return;

        const lo = try gpa.alloc([3]f32, placed.items.len);
        defer gpa.free(lo);
        const hi = try gpa.alloc([3]f32, placed.items.len);
        defer gpa.free(hi);
        for (placed.items, lo, hi) |item, *low, *high| {
            const box = self.mesh_boxes.items[item.mesh].?;
            low.* = @splat(std.math.inf(f32));
            high.* = @splat(-std.math.inf(f32));
            for (0..8) |corner| {
                const point = math.transformPoint(item.transform, .{
                    box[corner & 1][0],
                    box[(corner >> 1) & 1][1],
                    box[(corner >> 2) & 1][2],
                });
                inline for (0..3) |axis| {
                    low[axis] = @min(low[axis], point[axis]);
                    high[axis] = @max(high[axis], point[axis]);
                }
            }
        }
        var tree = try bvh.build(gpa, lo, hi, 2);
        defer tree.deinit(gpa);
        const records = try gpa.alloc(TraceInstance, @max(placed.items.len, 1));
        defer gpa.free(records);
        records[0] = .{ .to_mesh = @splat(0), .instance = 0 };
        for (tree.order, 0..) |item, place| {
            const m = math.inverse(placed.items[item].transform);
            records[place] = .{
                .to_mesh = .{ m[0], m[1], m[2], m[4], m[5], m[6], m[8], m[9], m[10], m[12], m[13], m[14] },
                .instance = placed.items[item].instance,
            };
        }
        if (scene.trace_nodes == null or scene.trace_nodes_capacity < tree.nodes.len) {
            if (scene.trace_nodes) |old| device.destroyBuffer(old);
            scene.trace_nodes = null;
            scene.trace_nodes_capacity = @intCast(tree.nodes.len + tree.nodes.len / 2);
            scene.trace_nodes = try device.createBuffer(.{ .name = "scene tree", .size = @as(u64, scene.trace_nodes_capacity) * @sizeOf(bvh.Node), .usage = .{ .storage = true, .copy_dst = true } });
        }
        if (scene.trace_instances == null or scene.trace_instances_capacity < records.len) {
            if (scene.trace_instances) |old| device.destroyBuffer(old);
            scene.trace_instances = null;
            scene.trace_instances_capacity = @intCast(records.len + records.len / 2);
            scene.trace_instances = try device.createBuffer(.{ .name = "scene tree instances", .size = @as(u64, scene.trace_instances_capacity) * @sizeOf(TraceInstance), .usage = .{ .storage = true, .copy_dst = true } });
        }
        try device.uploadBuffer(scene.trace_nodes.?, 0, std.mem.sliceAsBytes(tree.nodes));
        try device.uploadBuffer(scene.trace_instances.?, 0, std.mem.sliceAsBytes(records));
        scene.trace_hash = hash;
        scene.trace_ready = true;
    }

    /// Builds the tree over a mesh's full-detail triangles and puts it
    /// in the tree pools; see `Options.path_tracing_fallback`.
    fn buildMeshTree(self: *Renderer, mesh: gltf.Mesh, out: *ModelMesh, record: u32) !void {
        const gpa = self.gpa;
        const triangles = mesh.lod0_index_count / 3;
        if (triangles == 0) return;
        const lo = try gpa.alloc([3]f32, triangles);
        defer gpa.free(lo);
        const hi = try gpa.alloc([3]f32, triangles);
        defer gpa.free(hi);
        for (lo, hi, 0..) |*low, *high, triangle| {
            low.* = @splat(std.math.inf(f32));
            high.* = @splat(-std.math.inf(f32));
            for (mesh.indices[triangle * 3 ..][0..3]) |index| {
                const position = mesh.vertices[index].position;
                inline for (0..3) |axis| {
                    low[axis] = @min(low[axis], position[axis]);
                    high[axis] = @max(high[axis], position[axis]);
                }
            }
        }
        var tree = try bvh.build(gpa, lo, hi, 4);
        defer tree.deinit(gpa);
        const items = try self.bvh_items.alloc(self, triangles);
        errdefer self.bvh_items.free(self, items, triangles);
        const nodes = try self.bvh_nodes.alloc(self, @intCast(tree.nodes.len));
        errdefer self.bvh_nodes.free(self, nodes, @intCast(tree.nodes.len));
        // Leaves name their triangles by place in the pool; children
        // stay relative to the root, which the shader adds.
        for (tree.nodes) |*node| {
            if (node.count != 0) node.first += items;
        }
        try self.bvh_items.write(self.device, items, std.mem.sliceAsBytes(tree.order));
        try self.bvh_nodes.write(self.device, nodes, std.mem.sliceAsBytes(tree.nodes));
        out.bvh_nodes = nodes;
        out.bvh_node_count = @intCast(tree.nodes.len);
        out.bvh_items = items;
        out.bvh_item_count = triangles;
        out.bvh_min = tree.nodes[0].min;
        out.bvh_max = tree.nodes[0].max;
        while (self.mesh_boxes.items.len <= record) try self.mesh_boxes.append(gpa, null);
        self.mesh_boxes.items[record] = .{ tree.nodes[0].min, tree.nodes[0].max };
    }

    // ----------------------------------------------------- geometry streaming

    /// Releases the geometry of models nothing near a camera is drawn
    /// with, and brings back that of models something near one is.
    fn updateGeometryStreaming(self: *Renderer, desc: FrameDesc) !void {
        const streaming = self.options.geometry_streaming orelse return;
        // How near a model has to be found before its nearest copy need not
        // be looked for any further.
        const near_enough = if (streaming.coarse_distance > 0) @min(streaming.distance, streaming.coarse_distance * 0.9) else streaming.distance;
        const zone = Zone.start(self.options.profiler, "geometry streaming");
        defer zone.stop();
        for (self.models.slots.items) |*slot| if (slot.value) |*entry| {
            entry.stream_distance = std.math.inf(f32);
        };
        for (desc.views) |view_desc| {
            const scene = self.scenes.get(view_desc.scene orelse continue) orelse continue;
            const eye = view_desc.camera.position;
            for (scene.entities.items) |item| {
                const entity = self.entities.get(item) orelse continue;
                if (!entity.visible) continue;
                const model = self.models.get(entity.model) orelse continue;
                if (model.state != .ready) continue;
                const center = math.transformPoint(entity.transform, model.info.bounds_center);
                const radius = model.info.bounds_radius * math.maxScale(entity.transform);
                model.stream_distance = @min(model.stream_distance, @max(math.length(math.sub(center, eye)) - radius, 0));
            }
            for (scene.groups.items) |item| {
                const group = self.instance_groups.get(item) orelse continue;
                const model = self.models.get(group.model) orelse continue;
                if (model.state != .ready) continue;
                for (group.transforms) |transform| {
                    // Near is near: no need to find the nearest of them.
                    if (model.stream_distance < near_enough) break;
                    const center = math.transformPoint(transform, model.info.bounds_center);
                    const radius = model.info.bounds_radius * math.maxScale(transform);
                    model.stream_distance = @min(model.stream_distance, @max(math.length(math.sub(center, eye)) - radius, 0));
                }
            }
        }

        var changed = false;
        var budget = streaming.upload_bytes_per_frame;
        var released: u32 = 0;
        var released_bytes: u64 = 0;
        var coarse_models: u32 = 0;
        for (self.models.slots.items) |*slot| if (slot.value) |*entry| {
            if (entry.state != .ready) continue;
            const source = &entry.source.?;
            var bytes: u64 = 0;
            for (entry.meshes) |mesh| bytes += @as(u64, mesh.vertex_count) * @sizeOf(gpu.Vertex) + @as(u64, mesh.index_count) * @sizeOf(u32);
            if (entry.geometry_resident) {
                // Deforming meshes are worked on every frame where they
                // lie; what nothing is drawn with is left alone.
                if (source.skins.len != 0 or entry.geometry_pinned or entry.blas_pending) continue;
                const far = entry.stream_distance != std.math.inf(f32) and entry.stream_distance > streaming.distance * @max(streaming.release_factor, 1);
                if (!far) {
                    // Still wanted: whole, or only its coarse part.
                    const coarse_wanted = streaming.coarse_distance > 0 and entry.stream_distance != std.math.inf(f32) and entry.stream_distance > streaming.coarse_distance;
                    if (coarse_wanted and !entry.geometry_coarse) {
                        if (self.keepCoarse(entry)) changed = true;
                    } else if (entry.geometry_coarse and entry.stream_distance < streaming.coarse_distance * 0.9 and bytes <= budget) {
                        // Back whole: what is there goes, and all of
                        // it is put back from system memory.
                        for (entry.meshes) |*mesh| self.freeMeshGeometry(mesh);
                        entry.geometry_resident = false;
                        entry.geometry_coarse = false;
                        budget -|= bytes;
                        try self.restoreGeometry(entry);
                        changed = true;
                    }
                    if (entry.geometry_coarse) coarse_models += 1;
                    continue;
                }
                for (entry.meshes) |*mesh| {
                    self.freeMeshGeometry(mesh);
                    if (mesh.blas) |blas| self.device.destroyAcceleration(blas);
                    mesh.blas = null;
                }
                entry.geometry_resident = false;
                entry.geometry_coarse = false;
                changed = true;
            } else if (entry.geometry_pinned or entry.stream_distance < streaming.distance) {
                if (bytes > budget and budget != streaming.upload_bytes_per_frame) {
                    released += 1;
                    released_bytes += bytes;
                    continue;
                }
                budget -|= bytes;
                try self.restoreGeometry(entry);
                changed = true;
            }
            if (!entry.geometry_resident) {
                released += 1;
                released_bytes += bytes;
            }
        };
        self.stats.geometry_models_released = released;
        self.stats.geometry_bytes_released = released_bytes;
        self.stats.geometry_models_coarse = coarse_models;
        // What is drawn with them joins or leaves its scene.
        if (changed) for (self.scenes.slots.items) |*slot| if (slot.value) |*scene| {
            scene.layout_dirty = true;
        };
    }

    /// Frees what a mesh holds in the vertex and index pools: all of it,
    /// or the coarse part that is left of it.
    fn freeMeshGeometry(self: *Renderer, mesh: *ModelMesh) void {
        if (mesh.coarse) {
            self.vertices.free(self, mesh.vertex_offset, mesh.coarse_vertex_count);
            self.indices.free(self, mesh.index_offset + mesh.lod0_index_count, mesh.index_count - mesh.lod0_index_count);
            mesh.coarse = false;
        } else {
            self.vertices.free(self, mesh.vertex_offset, mesh.vertex_count);
            self.indices.free(self, mesh.index_offset, mesh.index_count);
        }
    }

    /// Lets go of a model's finest level of detail: the vertices only it
    /// uses and its indices, for every mesh that can be split so. The
    /// rest stays where it is, so nothing that is drawn has to move.
    /// Returns whether anything was freed.
    fn keepCoarse(self: *Renderer, entry: *ModelEntry) bool {
        var any = false;
        for (entry.meshes) |*mesh| {
            // A mesh with a tree for path tracing is walked triangle by
            // triangle of its finest level.
            if (mesh.coarse or mesh.coarse_vertex_count == 0 or mesh.bvh_nodes != null or mesh.skin_offset != null) continue;
            self.vertices.free(self, mesh.vertex_offset + mesh.coarse_vertex_count, mesh.vertex_count - mesh.coarse_vertex_count);
            self.indices.free(self, mesh.index_offset, mesh.lod0_index_count);
            // Rays would look its triangles up among what has gone.
            if (mesh.blas) |blas| self.device.destroyAcceleration(blas);
            mesh.blas = null;
            mesh.coarse = true;
            any = true;
        }
        if (any) entry.geometry_coarse = true;
        return any;
    }

    /// Puts a released model's vertices and indices back in GPU memory,
    /// from the copy kept in system memory.
    fn restoreGeometry(self: *Renderer, entry: *ModelEntry) !void {
        const device = self.device;
        const source = &entry.source.?;
        const records = try self.gpa.alloc(gpu.Mesh, entry.meshes.len);
        defer self.gpa.free(records);
        // Reserved first, so that running out of memory leaves the model
        // released rather than half there.
        var reserved: usize = 0;
        errdefer for (entry.meshes[0..reserved]) |mesh| {
            self.vertices.free(self, mesh.vertex_offset, mesh.vertex_count);
            self.indices.free(self, mesh.index_offset, mesh.index_count);
        };
        for (entry.meshes) |*mesh| {
            const vertex_offset = try self.vertices.alloc(self, mesh.vertex_count);
            mesh.index_offset = self.indices.alloc(self, mesh.index_count) catch |err| {
                self.vertices.free(self, vertex_offset, mesh.vertex_count);
                return err;
            };
            mesh.vertex_offset = vertex_offset;
            reserved += 1;
        }
        for (source.meshes, entry.meshes, records) |mesh, placed, *record| {
            try self.vertices.write(device, placed.vertex_offset, std.mem.sliceAsBytes(mesh.vertices));
            try self.indices.write(device, placed.index_offset, std.mem.sliceAsBytes(mesh.indices));
            record.* = .{
                .center = mesh.bounds_center,
                .radius = mesh.bounds_radius,
                .index_offset = placed.index_offset,
                .meshlet_offset = placed.meshlet_offset,
                .meshlet_count = placed.meshlet_count,
                .bvh = placed.bvh_nodes orelse gpu.invalid_id,
            };
        }
        try self.meshes.write(device, entry.mesh_base, std.mem.sliceAsBytes(records));
        if (device.ray_tracing) {
            for (entry.meshes) |*mesh| {
                if (mesh.skin_offset != null) continue;
                mesh.blas = try device.createBlas(geometry_passes.blasDesc(self, mesh.*));
            }
            entry.blas_pending = true;
            self.blas_pending += 1;
        }
        entry.geometry_resident = true;
    }

    // ------------------------------------------------------ texture streaming

    fn createStreamTexture(self: *Renderer, stream: *const TextureStream, wanted_first: u32) !rhi.Texture {
        const device = self.device;
        var first = wanted_first;
        // Levels that are not in memory come from the cache file, in one
        // read; if that fails the texture makes do with what is here.
        var from_file: []u8 = &.{};
        defer self.gpa.free(from_file);
        const file_start = stream.levelOffset(first);
        if (file_start < stream.tail_offset) {
            if (self.readStreamLevels(stream, file_start, stream.tail_offset - file_start)) |bytes| {
                from_file = bytes;
            } else |err| {
                std.log.warn("texture streaming: could not read {s}: {s}", .{ stream.path, @errorName(err) });
                first = stream.floor;
            }
        }
        const texture = try device.createTexture(.{
            .name = "material texture",
            .width = @max(stream.width >> @intCast(first), 1),
            .height = @max(stream.height >> @intCast(first), 1),
            .format = stream.format(),
            .usage = .{ .sampled = true, .copy_dst = true },
            .mip_levels = stream.levels - first,
        });
        errdefer device.destroyTexture(texture);
        var offset = stream.levelOffset(first);
        for (first..stream.levels) |level| {
            const size = stream.levelSize(@intCast(level));
            const bytes = if (offset < stream.tail_offset) from_file[offset - file_start ..][0..size] else stream.data[offset - stream.tail_offset ..][0..size];
            try device.uploadTexture(texture, @intCast(level - first), 0, bytes);
            offset += size;
        }
        return texture;
    }

    /// Part of a texture's mip chain from its file in the asset cache
    /// (twelve bytes of header, then the chain). Caller frees.
    fn readStreamLevels(self: *Renderer, stream: *const TextureStream, offset: usize, size: usize) ![]u8 {
        const file = try std.Io.Dir.cwd().openFile(self.io, stream.path, .{});
        defer file.close(self.io);
        const bytes = try self.gpa.alloc(u8, size);
        errdefer self.gpa.free(bytes);
        if (try file.readPositionalAll(self.io, bytes, 12 + offset) != size) return error.EndOfStream;
        return bytes;
    }

    /// Lowers the wanted level of each texture a model's meshes use, given
    /// where one copy of the model is and how large a meter at distance one
    /// appears on screen.
    fn wantModelTextures(
        model: *ModelEntry,
        transform: Mat4,
        camera: Camera,
        pixels_at_one_meter: f32,
        bias: f32,
        frustum: ?StreamFrustum,
        /// Per mesh of the model, whether a camera drew it; null to ask for
        /// all of them.
        drawn: ?[]const u32,
    ) void {
        const source = &model.source.?;
        for (source.instances, 0..) |instance, part| {
            if (drawn) |parts| if (parts[part] == 0) continue;
            const mesh = source.meshes[instance.mesh];
            if (mesh.uv_density <= 0) continue;
            const world = if (instance.skin != null) transform else math.mul(transform, model.node_world[instance.node]);
            const scale = @max(math.maxScale(world), 1e-6);
            const center = math.transformPoint(world, mesh.bounds_center);
            const distance = @max(math.length(math.sub(center, camera.position)) - mesh.bounds_radius * scale, camera.near);
            if (frustum) |seen| if (!seen.touches(center, mesh.bounds_radius * scale)) continue;
            const material = source.materials[mesh.material];
            // Fraction of a texture's width that one pixel covers when the
            // surface faces the camera, which is the finest it gets.
            const uv_per_pixel = mesh.uv_density * @max(@abs(material.uv_scale[0]), @abs(material.uv_scale[1])) / scale * distance / pixels_at_one_meter;
            inline for (.{ "base_color_texture", "normal_texture", "metallic_roughness_texture", "occlusion_texture", "emissive_texture" }) |field| {
                if (@field(material, field)) |ref| {
                    const stream = &model.streams[ref.image];
                    if (stream.data.len != 0) {
                        const texels = uv_per_pixel * @as(f32, @floatFromInt(@max(stream.width, stream.height)));
                        const level = @log2(@max(texels, 1e-6)) + bias;
                        const wanted: u32 = if (level <= 0) 0 else @min(@as(u32, @intFromFloat(level)), stream.floor);
                        stream.wanted = @min(stream.wanted, wanted);
                    }
                }
            }
        }
    }

    /// Which of a scene's instances a camera drew a few frames ago, or null
    /// when that is not known: nothing has been read back yet, or the
    /// scene has been laid out anew since.
    fn seenInstances(device: *rhi.Device, scene: *const SceneData, frame: rhi.Frame) ?[]const u32 {
        if (scene.layout_dirty) return null;
        const slot: usize = @intCast(frame.index % rhi.frames_in_flight);
        const tag = scene.seen_tags[slot];
        const buffer = scene.seen_readback[slot] orelse return null;
        if (!tag.valid or tag.layout_version != scene.layout_version) return null;
        return device.mappedSlice(u32, buffer)[0..tag.count];
    }

    /// Decides which mip levels of each streamed texture the frame's views
    /// need, fits that to the budget, and loads or drops levels to match.
    fn updateTextureStreaming(self: *Renderer, frame: rhi.Frame, desc: FrameDesc) !void {
        const streaming = self.options.texture_streaming orelse return;
        const zone = Zone.start(self.options.profiler, "texture streaming");
        defer zone.stop();
        const device = self.device;
        for (self.models.slots.items) |*slot| if (slot.value) |*entry| {
            for (entry.streams) |*stream| stream.wanted = stream.floor;
        };
        for (desc.views) |view_desc| {
            const scene = self.scenes.get(view_desc.scene orelse continue) orelse continue;
            const target = switch (view_desc.target) {
                .backbuffer => frame.backbuffer orelse continue,
                .texture => |texture| texture,
            };
            const height = if (view_desc.region) |region| region.height else device.textureInfo(target).height;
            const camera = view_desc.camera;
            const pixels_at_one_meter = @as(f32, @floatFromInt(height)) * 0.5 / @tan(camera.fov_y * 0.5) *
                std.math.clamp(view_desc.settings.render_scale, 0.25, 1);
            const bias = streaming.mip_bias + view_desc.settings.texture_mip_bias;
            const frustum: ?StreamFrustum = if (streaming.visible_only) blk: {
                const info = device.textureInfo(target);
                const width = if (view_desc.region) |region| region.width else info.width;
                const tan_y = @tan(camera.fov_y * 0.5);
                break :blk .{
                    .view = math.lookTo(camera.position, camera.forward, camera.up),
                    .tan_x = tan_y * @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height)),
                    .tan_y = tan_y,
                };
            } else null;
            // What the cameras drew a few frames ago, when only that is to
            // ask for detail and it is known.
            const seen: ?[]const u32 = if (streaming.skip_occluded) seenInstances(device, scene, frame) else null;
            self.seen_round += 1;
            if (seen != null) for (scene.layout.items, 0..) |placed, index| {
                if (!placed.first_of_entity) continue;
                const entity = self.entities.get(placed.entity) orelse continue;
                entity.seen_round = self.seen_round;
                entity.seen_first = @intCast(index);
            };
            for (scene.entities.items) |item| {
                const entity = self.entities.get(item) orelse continue;
                if (!entity.visible) continue;
                const model = self.models.get(entity.model) orelse continue;
                if (model.state != .ready or model.streamed == 0) continue;
                // Of a model's meshes, only those drawn ask for detail.
                const parts: ?[]const u32 = if (seen) |drawn| blk: {
                    if (entity.seen_round != self.seen_round) continue;
                    const count = model.source.?.instances.len;
                    if (entity.seen_first + count > drawn.len) continue;
                    break :blk drawn[entity.seen_first..][0..count];
                } else null;
                wantModelTextures(model, entity.transform, camera, pixels_at_one_meter, bias, frustum, parts);
            }
            for (scene.groups.items) |item| {
                const group = self.instance_groups.get(item) orelse continue;
                const model = self.models.get(group.model) orelse continue;
                if (model.state != .ready or model.streamed == 0 or group.transforms.len == 0) continue;
                // The copy nearest the camera decides for the whole group
                // (the nearest one drawn, when only those are to count).
                var nearest: ?usize = null;
                var nearest_distance = std.math.inf(f32);
                for (group.transforms, 0..) |transform, index| {
                    if (seen) |drawn| {
                        const first = group.base + @as(u32, @intCast(index)) * group.per_copy;
                        var any = false;
                        for (0..group.per_copy) |part| {
                            if (first + part < drawn.len and drawn[first + part] != 0) any = true;
                        }
                        if (!any) continue;
                    }
                    const delta = math.sub(Vec3{ transform[12], transform[13], transform[14] }, camera.position);
                    const distance = math.dot(delta, delta);
                    if (distance < nearest_distance) {
                        nearest_distance = distance;
                        nearest = index;
                    }
                }
                wantModelTextures(model, group.transforms[nearest orelse continue], camera, pixels_at_one_meter, bias, null, null);
            }
        }

        // Over budget: every texture gives up the same number of levels.
        var extra: u32 = 0;
        var resident_bytes: u64 = 0;
        var count: u32 = 0;
        while (true) : (extra += 1) {
            var wanted_bytes: u64 = 0;
            resident_bytes = 0;
            count = 0;
            for (self.models.slots.items) |*slot| if (slot.value) |*entry| {
                for (entry.streams) |*stream| {
                    if (stream.data.len == 0) continue;
                    wanted_bytes += stream.bytesFrom(@min(stream.wanted + extra, stream.floor));
                    resident_bytes += stream.bytesFrom(stream.resident);
                    count += 1;
                }
            };
            if (streaming.budget_bytes == 0 or wanted_bytes <= streaming.budget_bytes or extra == 16) break;
        }

        // Drop detail first so that loading never overshoots the budget.
        var pending: u32 = 0;
        var upload_left = streaming.upload_bytes_per_frame;
        for ([_]bool{ false, true }) |loading| {
            for (self.models.slots.items) |*slot| if (slot.value) |*entry| {
                if (entry.state != .ready) continue;
                for (entry.streams, 0..) |*stream, index| {
                    if (stream.data.len == 0) continue;
                    const goal = @min(stream.wanted + extra, stream.floor);
                    if (goal == stream.resident) {
                        stream.low_frames = 0;
                        continue;
                    }
                    if (loading != (goal < stream.resident)) continue;
                    const before = stream.bytesFrom(stream.resident);
                    const after = stream.bytesFrom(goal);
                    if (loading) {
                        stream.low_frames = 0;
                        const fits = streaming.budget_bytes == 0 or resident_bytes - before + after <= streaming.budget_bytes;
                        if (upload_left == 0 or !fits) {
                            pending += 1;
                            continue;
                        }
                        upload_left -|= after;
                    } else {
                        stream.low_frames += 1;
                        const over = streaming.budget_bytes != 0 and resident_bytes > streaming.budget_bytes;
                        if (!over and stream.low_frames < streaming.evict_delay_frames) continue;
                        stream.low_frames = 0;
                    }
                    const texture = try self.createStreamTexture(stream, goal);
                    device.destroyTexture(entry.textures[index].?);
                    entry.textures[index] = texture;
                    stream.resident = goal;
                    resident_bytes = resident_bytes - before + after;
                    entry.materials_stale = true;
                }
            };
        }
        // Materials name textures by index, and a reloaded texture has a
        // new one.
        for (self.models.slots.items) |*slot| if (slot.value) |*entry| {
            if (!entry.materials_stale) continue;
            entry.materials_stale = false;
            for (entry.source.?.materials, 0..) |material, index| {
                const encoded = try self.encodeMaterial(entry, material, index);
                try self.materials.write(device, entry.material_base + @as(u32, @intCast(index)), std.mem.asBytes(&encoded));
            }
        };
        self.stats.streamed_textures = count;
        self.stats.streamed_texture_bytes = resident_bytes;
        self.stats.streamed_textures_pending = pending;
    }

    fn textureIndex(self: *Renderer, entry: *ModelEntry, reference: ?gltf.TextureRef) u32 {
        const ref = reference orelse return gpu.invalid_id;
        const texture = entry.textures[ref.image] orelse return gpu.invalid_id;
        return self.device.textureIndex(texture);
    }

    /// Samplers shared by all materials. Color and normal maps get
    /// anisotropic filtering; data maps (roughness, occlusion, emissive)
    /// use plain trilinear, which is markedly cheaper per pixel.
    fn materialSampler(self: *Renderer, data: gltf.SamplerData, anisotropic: bool) !rhi.Sampler {
        const key = @as(usize, @intFromBool(anisotropic)) * 18 + @as(usize, @intFromBool(data.linear)) * 9 +
            @as(usize, @intFromEnum(data.repeat_u)) * 3 + @intFromEnum(data.repeat_v);
        if (self.material_samplers[key]) |sampler| return sampler;
        const filter: rhi.Filter = if (data.linear) .linear else .nearest;
        const sampler = try self.device.createSampler(.{
            .min_filter = .linear,
            .mag_filter = filter,
            .address_u = addressMode(data.repeat_u),
            .address_v = addressMode(data.repeat_v),
            .max_anisotropy = if (anisotropic) self.options.texture_anisotropy else self.options.data_texture_anisotropy,
        });
        self.material_samplers[key] = sampler;
        return sampler;
    }

    fn freeModel(self: *Renderer, entry: *ModelEntry) void {
        const gpa = self.gpa;
        if (entry.job) |job| {
            job.group.cancel(job.io);
            if (job.model) |*model| model.deinit();
            gpa.free(job.path);
            gpa.destroy(job);
            entry.job = null;
        }
        if (entry.source) |*source| for (entry.streams) |stream| {
            if (stream.data.len != 0) source.freeCompressed(stream.data);
            gpa.free(stream.path);
        };
        gpa.free(entry.material_images);
        entry.material_images = &.{};
        gpa.free(entry.streams);
        entry.streams = &.{};
        entry.streamed = 0;
        for (entry.textures) |texture| if (texture) |value| self.device.destroyTexture(value);
        gpa.free(entry.textures);
        entry.textures = &.{};
        for (entry.meshes) |*mesh| {
            if (entry.geometry_resident) self.freeMeshGeometry(mesh);
            self.meshlets.free(self, mesh.meshlet_offset, mesh.meshlet_count);
            if (mesh.bvh_nodes) |offset| {
                self.bvh_nodes.free(self, offset, mesh.bvh_node_count);
                self.bvh_items.free(self, mesh.bvh_items, mesh.bvh_item_count);
            }
            if (mesh.skin_offset) |offset| self.skin_vertices.free(self, offset, mesh.vertex_count);
            if (mesh.morph_offset) |offset| self.morph_deltas.free(self, offset, mesh.vertex_count * mesh.morph_targets);
            if (mesh.blas) |blas| self.device.destroyAcceleration(blas);
        }
        for (0..entry.meshes.len) |index| {
            if (entry.mesh_base + index < self.mesh_boxes.items.len) self.mesh_boxes.items[entry.mesh_base + index] = null;
        }
        if (entry.source) |*source| {
            if (entry.transform_count != 0) {
                self.materials.free(self, entry.transform_base, entry.transform_count * gpu.texture_transform_slots);
                self.texture_transform_users -= 1;
                entry.transform_count = 0;
            }
            if (entry.meshes.len != 0) self.meshes.free(self, entry.mesh_base, @intCast(source.meshes.len));
            if (entry.state == .ready) {
                for (source.materials) |material| self.material_shader_users[if (material.shader < self.material_shaders.len) material.shader else 0] -= 1;
                self.materials.free(self, entry.material_base, @intCast(source.materials.len));
            }
            source.deinit();
            entry.source = null;
        }
        gpa.free(entry.meshes);
        gpa.free(entry.order);
        gpa.free(entry.pose_order);
        gpa.free(entry.node_world);
        entry.meshes = &.{};
        entry.order = &.{};
        entry.pose_order = &.{};
        entry.node_world = &.{};
    }

    fn finalizeEnvironment(self: *Renderer, entry: *EnvironmentEntry, cmd: *rhi.CommandEncoder) !void {
        const device = self.device;
        const job = entry.job.?;
        job.group.await(job.io) catch {};
        defer {
            if (job.image) |*image| image.deinit();
            if (job.cube) |cube| job.gpa.free(cube.data);
            self.gpa.free(job.path);
            self.gpa.destroy(job);
            entry.job = null;
        }
        if (job.failure) |err| return err;

        // The source: a panorama, or a cube map as stored in the file.
        var from_cube = false;
        const source = if (job.cube) |cube| blk: {
            from_cube = true;
            if (cube.format == .bc6h and !device.bc_textures) return error.UnsupportedTextureFormat;
            if (job.cube_brightest) |direction| entry.brightest_direction = direction;
            const format: rhi.Format = if (cube.format == .bc6h) .bc6h_ufloat else .rgba16_float;
            const texture = try device.createTexture(.{
                .name = "environment source",
                .width = cube.width,
                .height = cube.height,
                .format = format,
                .usage = .{ .sampled = true, .copy_dst = true },
                .mip_levels = cube.levels,
                .kind = .cube,
            });
            errdefer device.destroyTexture(texture);
            var offset: usize = 0;
            for (0..cube.levels) |level| {
                const size: usize = @intCast(format.dataSize(@max(cube.width >> @intCast(level), 1), @max(cube.height >> @intCast(level), 1)));
                for (0..6) |face| {
                    try device.uploadTexture(texture, @intCast(level), @intCast(face), cube.data[offset..][0..size]);
                    offset += size;
                }
            }
            break :blk texture;
        } else blk: {
            const image = job.image.?;
            entry.brightest_direction = image.brightest_direction;
            const texture = try device.createTexture(.{
                .name = "equirect",
                .width = image.width,
                .height = image.height,
                .format = .rgba16_float,
                .usage = .{ .sampled = true, .copy_dst = true },
            });
            errdefer device.destroyTexture(texture);
            try device.uploadTexture(texture, 0, 0, image.pixels());
            break :blk texture;
        };
        defer device.destroyTexture(source);
        try cmd.flushUploads();

        try self.ensureEnvironmentTextures(entry);
        const sky = entry.sky.?;

        cmd.beginScope("environment bake");
        for (0..6) |face| try self.drawEnvironmentFace(cmd, entry, sky, source, from_cube, @intCast(face), null);
        cmd.generateMips(sky);

        try self.filterEnvironment(entry, cmd);
        cmd.endScope();
        entry.state = .ready;
    }

    /// One face of a sky cube from a panorama or another cube, with the
    /// cloud layer over it if one is given.
    fn drawEnvironmentFace(self: *Renderer, cmd: *rhi.CommandEncoder, entry: *const EnvironmentEntry, target: rhi.Texture, source: rhi.Texture, from_cube: bool, face: u32, layer: ?gpu.Clouds) !void {
        const device = self.device;
        var clouds = std.mem.zeroes(gpu.Clouds);
        if (layer) |value| {
            clouds = value;
            clouds.depth = device.samplerIndex(self.sampler_linear_clamp);
        }
        try cmd.beginRendering(.{ .color = &.{.{ .texture = target, .layer = face, .load = .discard }} });
        cmd.bindPipeline(self.pipelines.env_cube);
        cmd.pushConstants(extern struct { source: u32, sampler: u32, face: u32, max_radiance: f32, from_cube: u32, to_sun: [3]f32, sunlight: [3]f32, clouds: gpu.Clouds }{
            .source = device.textureIndex(source),
            .sampler = device.samplerIndex(if (from_cube) self.sampler_linear_clamp else self.sampler_linear_repeat),
            .face = face,
            .max_radiance = entry.max_radiance,
            .from_cube = @intFromBool(from_cube),
            .to_sun = entry.cloud_to_sun,
            .sunlight = entry.cloud_sunlight,
            .clouds = clouds,
        });
        cmd.drawFullscreen();
        cmd.endRendering();
    }

    /// A loaded environment under a cloud layer: the lighting cubes are
    /// filtered from the picture with the clouds laid over it, and the
    /// backdrop is then put back as it was, since the real clouds are
    /// drawn over it. Without a layer the lighting goes back to clear.
    fn bakeLoadedClouds(self: *Renderer, entry: *EnvironmentEntry, cmd: *rhi.CommandEncoder) !void {
        entry.sky_dirty = false;
        const sky = entry.sky orelse return;
        cmd.beginScope("environment clouds");
        defer cmd.endScope();
        if (entry.clear == null) {
            // The picture as it was loaded, kept aside from now on.
            if (entry.clouds == null) return;
            const clear = try self.device.createTexture(.{
                .name = "environment clear sky",
                .width = env_cube_size,
                .height = env_cube_size,
                .format = hdr_format,
                .usage = .{ .sampled = true, .color_attachment = true },
                .kind = .cube,
            });
            entry.clear = clear;
            for (0..6) |face| try self.drawEnvironmentFace(cmd, entry, clear, sky, true, @intCast(face), null);
            cmd.transition(clear, .shader_read);
        }
        const clear = entry.clear.?;
        if (entry.clouds) |layer| {
            for (0..6) |face| try self.drawEnvironmentFace(cmd, entry, sky, clear, true, @intCast(face), layer);
            cmd.generateMips(sky);
            try self.filterEnvironment(entry, cmd);
        }
        for (0..6) |face| try self.drawEnvironmentFace(cmd, entry, sky, clear, true, @intCast(face), null);
        cmd.generateMips(sky);
        if (entry.clouds == null) try self.filterEnvironment(entry, cmd);
    }

    /// Creates the three cube maps of an environment if it has none yet.
    fn ensureEnvironmentTextures(self: *Renderer, entry: *EnvironmentEntry) !void {
        if (entry.sky != null) return;
        const device = self.device;
        const cube_usage = rhi.TextureUsage{ .sampled = true, .color_attachment = true };
        const sky = try device.createTexture(.{
            .name = "environment sky",
            .width = env_cube_size,
            .height = env_cube_size,
            .format = hdr_format,
            .usage = cube_usage,
            .mip_levels = rhi.TextureDesc.fullMipCount(env_cube_size, env_cube_size),
            .kind = .cube,
        });
        entry.sky = sky;
        const specular = try device.createTexture(.{
            .name = "environment specular",
            .width = env_specular_size,
            .height = env_specular_size,
            .format = hdr_format,
            .usage = cube_usage,
            .mip_levels = env_specular_mips,
            .kind = .cube,
        });
        entry.specular = specular;
        const irradiance = try device.createTexture(.{
            .name = "environment irradiance",
            .width = env_irradiance_size,
            .height = env_irradiance_size,
            .format = hdr_format,
            .usage = cube_usage,
            .kind = .cube,
        });
        entry.irradiance = irradiance;
    }

    /// Derives diffuse irradiance and roughness-filtered reflections from an
    /// environment's sky cube map.
    fn filterEnvironment(self: *Renderer, entry: *EnvironmentEntry, cmd: *rhi.CommandEncoder) !void {
        try self.filterIrradiance(entry, cmd);
        for (0..env_specular_mips) |mip| try self.filterSpecularMip(entry, cmd, @intCast(mip));
    }

    /// The diffuse lighting cube, from the sky cube.
    fn filterIrradiance(self: *Renderer, entry: *EnvironmentEntry, cmd: *rhi.CommandEncoder) !void {
        const device = self.device;
        const irradiance = entry.irradiance.?;
        for (0..6) |face| {
            try cmd.beginRendering(.{ .color = &.{.{ .texture = irradiance, .layer = @intCast(face), .load = .discard }} });
            cmd.bindPipeline(self.pipelines.env_irradiance);
            cmd.pushConstants(extern struct { source: u32, sampler: u32, face: u32, source_size: f32 }{
                .source = device.textureIndex(entry.sky.?),
                .sampler = device.samplerIndex(self.sampler_linear_clamp),
                .face = @intCast(face),
                .source_size = env_cube_size,
            });
            cmd.drawFullscreen();
            cmd.endRendering();
        }
        cmd.transition(irradiance, .shader_read);
    }

    /// One roughness level of the reflection cube, from the sky cube.
    fn filterSpecularMip(self: *Renderer, entry: *EnvironmentEntry, cmd: *rhi.CommandEncoder, mip: u32) !void {
        const device = self.device;
        const specular = entry.specular.?;
        const roughness = @as(f32, @floatFromInt(mip)) / @as(f32, env_specular_mips - 1);
        for (0..6) |face| {
            try cmd.beginRendering(.{ .color = &.{.{ .texture = specular, .mip = mip, .layer = @intCast(face), .load = .discard }} });
            cmd.bindPipeline(self.pipelines.env_prefilter);
            cmd.pushConstants(extern struct { source: u32, sampler: u32, face: u32, source_size: f32, roughness: f32 }{
                .source = device.textureIndex(entry.sky.?),
                .sampler = device.samplerIndex(self.sampler_linear_clamp),
                .face = @intCast(face),
                .source_size = env_cube_size,
                .roughness = roughness,
            });
            cmd.drawFullscreen();
            cmd.endRendering();
        }
        cmd.transition(specular, .shader_read);
    }

    fn freeEnvironment(self: *Renderer, entry: *EnvironmentEntry) void {
        if (entry.job) |job| {
            job.group.cancel(job.io);
            if (job.image) |*image| image.deinit();
            if (job.cube) |cube| job.gpa.free(cube.data);
            self.gpa.free(job.path);
            self.gpa.destroy(job);
            entry.job = null;
        }
        inline for (.{ "sky", "specular", "irradiance", "clear" }) |name| {
            if (@field(entry, name)) |texture| self.device.destroyTexture(texture);
            @field(entry, name) = null;
        }
    }

    // ------------------------------------------------- locking and 2D assets

    /// Takes the renderer lock. Every public method already locks
    /// internally; hold it yourself only to use `device` directly from a
    /// thread other than the one rendering, or to make several calls atomic.
    /// Not reentrant: do not call renderer methods while holding it.
    pub fn lock(self: *Renderer) void {
        self.mutex.lockUncancelable(self.io);
    }

    /// Releases the lock taken with `lock`, from the same thread.
    pub fn unlock(self: *Renderer) void {
        self.mutex.unlock(self.io);
    }

    /// The built-in font (DejaVu Sans, printable ASCII and Latin-1). Valid
    /// for the lifetime of the renderer.
    pub fn defaultFont(self: *const Renderer) *const Font {
        return self.default_font;
    }

    /// Loads a TrueType font and bakes a distance-field atlas for `ranges`
    /// (see `font.default_ranges`). The font is immutable and may be used
    /// from any thread until `destroyFont`.
    pub fn loadFont(self: *Renderer, path: []const u8, ranges: []const font_module.Range) !*const Font {
        const bytes = try gltf.readFile(self.gpa, self.io, path);
        defer self.gpa.free(bytes);
        return self.loadFontFromMemory(bytes, ranges);
    }

    /// As `loadFont`, from the bytes of a TrueType file already in memory.
    /// `bytes` and `ranges` are not kept: both may be freed once this
    /// returns. Parsing and baking run on the calling thread without the
    /// lock; only the atlas upload takes it. The font belongs to the
    /// renderer: free it with `destroyFont`, or leave it to `deinit`.
    pub fn loadFontFromMemory(self: *Renderer, bytes: []const u8, ranges: []const font_module.Range) !*const Font {
        // Parsing and baking need no renderer state; only the upload does.
        const font = try self.gpa.create(Font);
        errdefer self.gpa.destroy(font);
        font.* = try font_module.load(self.gpa, bytes, ranges);
        errdefer font.deinit();
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.registerFont(font);
        return font;
    }

    fn registerFont(self: *Renderer, font: *Font) !void {
        const device = self.device;
        const texture = try device.createTexture(.{
            .name = "font atlas",
            .width = font.baked().atlas_width,
            .height = font.baked().atlas_height,
            .format = .rgba8_unorm,
            .usage = .{ .sampled = true, .copy_dst = true },
            .mip_levels = 4,
        });
        errdefer device.destroyTexture(texture);
        {
            const texels = try fontTexels(self.gpa, font.baked());
            defer self.gpa.free(texels);
            try device.uploadTexture(texture, 0, 0, texels);
        }
        try device.generateMips(texture);
        font.setTexture(device.textureIndex(texture));
        try self.fonts.append(self.gpa, font);
        errdefer _ = self.fonts.pop();
        try self.font_textures.append(self.gpa, texture);
    }

    /// Adds the font's own ligature glyphs to its atlas: every ligature of
    /// its substitution table (`liga`, `rlig`) whose parts are in the
    /// atlas already. Text drawn afterwards uses them where the letters
    /// meet (fi, ffl and whatever else the font was drawn with). Call it
    /// again after `prepareText` adds letters that have ligatures.
    pub fn prepareLigatures(self: *Renderer, font: *const Font) !void {
        const missing = try font.missingLigatures(self.gpa);
        defer self.gpa.free(missing);
        if (missing.len == 0) return;
        // They are named by characters of a private plane; hand those on
        // as text.
        const text = try self.gpa.alloc(u8, missing.len * 4);
        defer self.gpa.free(text);
        var length: usize = 0;
        for (missing) |codepoint| length += try std.unicode.utf8Encode(codepoint, text[length..]);
        try self.prepareText(font, text[0..length]);
    }

    /// Makes sure `font` can draw every character of `text`, baking any
    /// glyphs the font file has that are not in its atlas yet. Use it for
    /// text whose characters are not known up front (names, chat, other
    /// scripts) instead of loading huge ranges. Call it before drawing
    /// with the font in that frame, and not while another thread is
    /// drawing text with the same font. Costs nothing when there is
    /// nothing new.
    pub fn prepareText(self: *Renderer, font: *const Font, text: []const u8) !void {
        return self.prepareTextWith(font, text, null, &.{});
    }

    /// `prepareText` for text drawn with a language or with font features
    /// asked for by name (`TextOptions.language`, `TextOptions.features`):
    /// also bakes the glyphs those bring in.
    pub fn prepareTextWith(self: *Renderer, font: *const Font, text: []const u8, language: ?[4]u8, features: []const [4]u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const index = for (self.fonts.items, 0..) |candidate, index| {
            if (candidate == font) break index;
        } else return error.UnknownFont;
        const mutable = self.fonts.items[index];
        var missing: std.ArrayList(u21) = .empty;
        defer missing.deinit(self.gpa);
        var iterator = font_module.Utf8Iterator{ .bytes = text };
        while (iterator.next()) |codepoint| {
            // Thai and Lao sara am is drawn as a ring and a letter.
            if (codepoint == 0x0e33 or codepoint == 0x0eb3) {
                const parts: [2]u21 = if (codepoint == 0x0e33) .{ 0x0e4d, 0x0e32 } else .{ 0x0ecd, 0x0eb2 };
                for (parts) |part| {
                    if (!mutable.has(part)) try missing.append(self.gpa, part);
                }
            }
            if (codepoint < 32 or mutable.has(codepoint)) continue;
            try missing.append(self.gpa, codepoint);
            // Arabic letters are drawn through their presentation forms.
            if (codepoint >= 0x0621 and codepoint <= 0x064a) {
                var form: u21 = 0xfe70;
                while (form <= 0xfefc) : (form += 1) {
                    if (!mutable.has(form)) try missing.append(self.gpa, form);
                }
            }
        }
        // The glyphs the font puts in place of what was typed (ligatures,
        // forms that depend on the neighbours or the language, features
        // asked for), script by script.
        {
            var typed: std.ArrayList(u21) = .empty;
            defer typed.deinit(self.gpa);
            var characters = font_module.Utf8Iterator{ .bytes = text };
            while (characters.next()) |codepoint| {
                if (codepoint >= 32) try typed.append(self.gpa, codepoint);
            }
            var start: usize = 0;
            while (start < typed.items.len) {
                var script = text_layout.scriptOf(typed.items[start]);
                var end = start + 1;
                while (end < typed.items.len) : (end += 1) {
                    const own = text_layout.scriptOf(typed.items[end]) orelse continue;
                    if (script) |current| {
                        if (!std.mem.eql(u8, &own, &current)) break;
                    } else script = own;
                }
                const tag = script orelse "DFLT".*;
                try mutable.missingSubstitutes(self.gpa, typed.items[start..end], .{ .script = tag, .language = language, .features = features }, &missing);
                start = end;
            }
        }
        if (missing.items.len == 0) return;
        // The new glyphs go into a bake of their own, which replaces the
        // one in use only once its atlas is on the GPU: threads laying
        // out text meanwhile keep the old bake, glyphs and atlas together.
        const next = (try mutable.extend(missing.items)) orelse return;
        errdefer mutable.discard(next);
        const device = self.device;
        const texture = try device.createTexture(.{
            .name = "font atlas",
            .width = next.atlas_width,
            .height = next.atlas_height,
            .format = .rgba8_unorm,
            .usage = .{ .sampled = true, .copy_dst = true },
            .mip_levels = 4,
        });
        errdefer device.destroyTexture(texture);
        {
            const texels = try fontTexels(self.gpa, next);
            defer self.gpa.free(texels);
            try device.uploadTexture(texture, 0, 0, texels);
        }
        try device.generateMips(texture);
        next.texture_index = device.textureIndex(texture);
        mutable.adopt(next);
        device.destroyTexture(self.font_textures.items[index]);
        self.font_textures.items[index] = texture;
    }

    /// The built-in font cannot be destroyed.
    pub fn destroyFont(self: *Renderer, font: *const Font) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (font == @as(*const Font, self.default_font)) return;
        for (self.fonts.items, 0..) |candidate, index| {
            if (@as(*const Font, candidate) != font) continue;
            self.device.destroyTexture(self.font_textures.items[index]);
            _ = self.fonts.swapRemove(index);
            _ = self.font_textures.swapRemove(index);
            candidate.deinit();
            self.gpa.destroy(candidate);
            return;
        }
    }

    /// As `createImage`, but stored block-compressed (BC7) with a full mip
    /// chain: a quarter of the GPU memory, at the cost of encoding time
    /// here and a slight loss. Falls back to `createImage` on a device
    /// without block compression. Good for large sprites, decals and
    /// backgrounds; not for images that are updated often.
    pub fn createImageCompressed(self: *Renderer, width: u32, height: u32, pixels: []const u8, srgb: bool) !Image {
        if (!self.device.bc_textures) return self.createImage(width, height, pixels, srgb);
        if (pixels.len != @as(usize, width) * height * 4) return error.InvalidTextureData;
        const chain = try texture_codec.encodeBc7Chain(self.gpa, pixels, width, height, srgb);
        defer self.gpa.free(chain);
        return self.createImageFromLevels(.{
            .width = width,
            .height = height,
            .format = .bc7,
            .srgb = srgb,
            .levels = texture_codec.mipCount(width, height),
            .data = chain,
        });
    }

    /// Creates an image for draw lists from tightly packed RGBA8 pixels.
    /// `srgb` should be true for color art, false for data.
    pub fn createImage(self: *Renderer, width: u32, height: u32, pixels: []const u8, srgb: bool) !Image {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const device = self.device;
        const texture = try device.createTexture(.{
            .name = "image",
            .width = width,
            .height = height,
            .format = if (srgb) .rgba8_srgb else .rgba8_unorm,
            .usage = .{ .sampled = true, .copy_dst = true },
            .mip_levels = rhi.TextureDesc.fullMipCount(width, height),
        });
        errdefer device.destroyTexture(texture);
        try device.uploadTexture(texture, 0, 0, pixels);
        try device.generateMips(texture);
        const index = device.textureIndex(texture);
        try self.images.append(self.gpa, .{ .texture = texture, .index = index });
        return .{ .index = index, .width = width, .height = height };
    }

    /// Decodes an image file (PNG, JPEG, ...) to RGBA8. The pixels belong
    /// to `gpa`. For tools and tests; `loadImage` is the way to get an
    /// image onto the screen.
    pub fn readImageFile(self: *Renderer, gpa: std.mem.Allocator, path: []const u8) !png.Image {
        var decoded = try gltf.loadImage(self.gpa, self.io, path);
        defer decoded.deinit();
        return .{ .width = decoded.width, .height = decoded.height, .pixels = try gpa.dupe(u8, decoded.data) };
    }

    /// Decodes a PNG/JPEG/TGA/BMP file into an sRGB image with a full mip
    /// chain, or loads a KTX2 file as it is: its own format, color space
    /// and mips, with no decoding. Reads and decodes on the calling thread
    /// and returns when the image is on the GPU. Destroy it with
    /// `destroyImage`.
    ///
    /// A KTX2 file must hold one flat picture (no cube or array), and a
    /// block-compressed one needs hardware with BC formats; otherwise
    /// `error.UnsupportedTextureFormat`.
    pub fn loadImage(self: *Renderer, path: []const u8) !Image {
        const bytes = try gltf.readFile(self.gpa, self.io, path);
        defer self.gpa.free(bytes);
        if (ktx2.isKtx2(bytes)) {
            const texture = try ktx2.read(self.gpa, bytes);
            defer self.gpa.free(texture.data);
            return self.createImageFromLevels(texture);
        }
        var decoded = try gltf.loadImage(self.gpa, self.io, path);
        defer decoded.deinit();
        return self.createImage(decoded.width, decoded.height, decoded.data, true);
    }

    /// Makes an image from mip levels that are already in a GPU format, as
    /// read from a KTX2 file.
    fn createImageFromLevels(self: *Renderer, source: ktx2.Texture) !Image {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const device = self.device;
        // An image is one flat picture: cube maps are environments, and
        // nothing here draws from an array.
        if (source.faces != 1 or source.layers != 1) return error.UnsupportedTextureFormat;
        if (source.format != .rgba8 and source.format != .rgba16f and !device.bc_textures) return error.UnsupportedTextureFormat;
        const format: rhi.Format = switch (source.format) {
            .bc7 => if (source.srgb) .bc7_srgb else .bc7_unorm,
            .bc1 => if (source.srgb) .bc1_srgb else .bc1_unorm,
            .bc3 => if (source.srgb) .bc3_srgb else .bc3_unorm,
            .bc4 => .bc4_unorm,
            .bc5 => .bc5_unorm,
            .bc6h => .bc6h_ufloat,
            .rgba8 => if (source.srgb) .rgba8_srgb else .rgba8_unorm,
            .rgba16f => .rgba16_float,
        };
        const texture = try device.createTexture(.{
            .name = "image",
            .width = source.width,
            .height = source.height,
            .format = format,
            .usage = .{ .sampled = true, .copy_dst = true },
            .mip_levels = source.levels,
        });
        errdefer device.destroyTexture(texture);
        try device.uploadTextureLevels(texture, 0, 0, source.data);
        const index = device.textureIndex(texture);
        try self.images.append(self.gpa, .{ .texture = texture, .index = index });
        return .{ .index = index, .width = source.width, .height = source.height };
    }

    /// Deletes the oldest files in the asset cache until it takes at most
    /// `max_bytes`, and returns how many bytes that freed. Files are aged
    /// by when they were written, not when they were last read.
    pub fn trimAssetCache(self: *Renderer, max_bytes: u64) !u64 {
        const directory = self.options.asset_cache_dir orelse return 0;
        return gltf.trimCache(self.gpa, self.io, directory, max_bytes);
    }

    /// Compresses an RGBA8 picture to BC7 with a full mip chain and writes
    /// it as a KTX2 file, which `loadImage` and models can then load
    /// without decoding or encoding anything.
    pub fn writeKtx2(self: *Renderer, path: []const u8, width: u32, height: u32, pixels: []const u8, srgb: bool) !void {
        const chain = try texture_codec.encodeBc7Chain(self.gpa, pixels, width, height, srgb);
        defer self.gpa.free(chain);
        const file = try ktx2.write(self.gpa, .{
            .width = width,
            .height = height,
            .format = .bc7,
            .srgb = srgb,
            .levels = texture_codec.mipCount(width, height),
            .data = chain,
        });
        defer self.gpa.free(file);
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = file });
    }

    /// Makes a light profile from brightness values spread evenly from
    /// "along the light's direction" (first) to "straight behind it"
    /// (last). Values are relative; the brightest becomes 1. Destroy it
    /// with `destroyImage`.
    pub fn createLightProfile(self: *Renderer, values: []const f32) !Image {
        if (values.len == 0) return error.EmptyProfile;
        var peak: f32 = 0;
        for (values) |value| peak = @max(peak, value);
        if (peak <= 0) return error.EmptyProfile;
        const width = 256;
        var pixels: [width * 4]u8 = undefined;
        for (0..width) |x| {
            // Linear interpolation between the given values.
            const position = @as(f32, @floatFromInt(x)) / (width - 1) * @as(f32, @floatFromInt(values.len - 1));
            const low: usize = @intFromFloat(@floor(position));
            const high = @min(low + 1, values.len - 1);
            const value = (values[low] + (values[high] - values[low]) * (position - @floor(position))) / peak;
            const level: u8 = @intFromFloat(std.math.clamp(value, 0, 1) * 255 + 0.5);
            pixels[x * 4 ..][0..4].* = .{ level, level, level, 255 };
        }
        return self.createImage(width, 1, &pixels, false);
    }

    /// Loads a measured light distribution in the IES LM-63 format that
    /// lamp manufacturers publish. The result is the fixture's brightness
    /// by angle from its axis, averaged around the axis.
    pub fn loadLightProfile(self: *Renderer, path: []const u8) !Image {
        const bytes = try gltf.readFile(self.gpa, self.io, path);
        defer self.gpa.free(bytes);
        const values = try parseIes(self.gpa, bytes);
        defer self.gpa.free(values);
        return self.createLightProfile(values);
    }

    /// Frees an image made by `createImage`, `loadImage` or one of the
    /// light profile functions. It must no longer be used by a draw list,
    /// light, decal or setting in a frame rendered after this. An image
    /// the renderer does not own (such as a `targetImage`) is ignored.
    pub fn destroyImage(self: *Renderer, image: Image) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.images.items, 0..) |entry, index| {
            if (entry.index != image.index) continue;
            self.device.destroyTexture(entry.texture);
            _ = self.images.swapRemove(index);
            return;
        }
    }

    // ---------------------------------------------------------------- views

    /// Creates the persistent state for one more camera. The renderer has a
    /// built-in main view, so this is only needed when several cameras are
    /// drawn in the same frame (split screen, a camera shown on a surface,
    /// a mirror). Its render targets are allocated on first use and follow
    /// the size it is drawn at.
    pub fn createView(self: *Renderer) !View {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.insertView();
    }

    /// Destroys a view created with `createView`. The main view cannot be
    /// destroyed.
    pub fn destroyView(self: *Renderer, view: View) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (std.meta.eql(view, self.main_view)) return;
        var removed = self.views.remove(view) orelse return;
        removed.deinit(self.device);
    }

    fn insertView(self: *Renderer) !View {
        const device = self.device;
        const exposure = try device.createBuffer(.{ .name = "exposure", .size = @sizeOf(gpu.Exposure), .usage = .{ .storage = true } });
        errdefer device.destroyBuffer(exposure);
        try device.uploadBuffer(exposure, 0, std.mem.asBytes(&gpu.Exposure{ .exposure = 1, .average_luminance = 0, .focus = 0 }));
        return self.views.insert(.{ .exposure = exposure });
    }

    /// Creates a texture that views can draw into (`Target.texture`) and
    /// that draw lists can show (`targetImage`). Destroy it with
    /// `destroyTarget`.
    pub fn createTarget(self: *Renderer, width: u32, height: u32) !rhi.Texture {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const texture = try self.device.createTexture(.{
            .name = "view target",
            .width = width,
            .height = height,
            .format = .rgba8_srgb,
            .usage = .{ .sampled = true, .color_attachment = true, .copy_src = true },
        });
        errdefer self.device.destroyTexture(texture);
        // Defined contents, so it can be shown before anything is drawn.
        var cmd = try self.device.beginImmediate();
        try cmd.beginRendering(.{ .color = &.{.{ .texture = texture, .load = .clear, .clear = .{ 0, 0, 0, 1 } }} });
        cmd.endRendering();
        cmd.transition(texture, .shader_read);
        try self.device.endImmediate();
        return texture;
    }

    /// Destroys a texture made by `createTarget`. Images obtained from it
    /// with `targetImage` must not be drawn afterwards.
    pub fn destroyTarget(self: *Renderer, target: rhi.Texture) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.device.destroyTexture(target);
    }

    /// The picture in a target texture, for drawing with a `DrawList`. A
    /// view listed earlier in the same frame has already drawn into it.
    pub fn targetImage(self: *Renderer, target: rhi.Texture) Image {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const info = self.device.textureInfo(target);
        return .{ .index = self.device.textureIndex(target), .width = info.width, .height = info.height };
    }

    /// Recompiles the renderer's own shaders from their source files with
    /// `glslc` and rebuilds every pipeline, without restarting. A
    /// development tool: it needs the source tree the renderer was built
    /// from and `glslc` on the path. If any shader fails to compile, the
    /// compiler's message is logged, nothing changes, and an error is
    /// returned. Returns the number of shaders compiled.
    pub fn reloadShaders(self: *Renderer) !u32 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const gpa = self.gpa;
        const device = self.device;
        var compiled: std.ArrayList([]u8) = .empty;
        defer {
            for (compiled.items) |code| gpa.free(code);
            compiled.deinit(gpa);
        }
        const include = try std.fmt.allocPrint(gpa, "-I{s}", .{shader_sources.include_dir});
        defer gpa.free(include);
        for (shader_sources.sources, shader_sources.defines, shader_sources.names) |source, define, name| {
            var argv: [8][]const u8 = undefined;
            var count: usize = 0;
            for ([_][]const u8{ "glslc", "--target-env=vulkan1.3", "-O", include }) |arg| {
                argv[count] = arg;
                count += 1;
            }
            const define_arg = try std.fmt.allocPrint(gpa, "-D{s}", .{define});
            defer gpa.free(define_arg);
            if (define.len != 0) {
                argv[count] = define_arg;
                count += 1;
            }
            for ([_][]const u8{ source, "-o", "-" }) |arg| {
                argv[count] = arg;
                count += 1;
            }
            const result = try std.process.run(gpa, self.io, .{ .argv = argv[0..count] });
            defer gpa.free(result.stderr);
            errdefer gpa.free(result.stdout);
            const ok = switch (result.term) {
                .exited => |code| code == 0,
                else => false,
            };
            if (!ok or result.stdout.len == 0 or result.stdout.len % 4 != 0) {
                std.log.err("shader {s} did not compile:\n{s}", .{ name, result.stderr });
                gpa.free(result.stdout);
                return error.ShaderCompileFailed;
            }
            try compiled.append(gpa, result.stdout);
        }

        // Everything compiled: swap the code in and rebuild the pipelines.
        // Variants still compiling read the old code, so they go first.
        self.dropShadeVariants();
        for (shader_sources.names, compiled.items) |name, *code| {
            const previous = try shader_overrides.fetchPut(gpa, name, code.*);
            if (previous) |old| gpa.free(old.value);
            code.* = &.{};
        }
        try device.waitIdle();
        const pipelines = try createPipelines(device);
        inline for (@typeInfo(Pipelines).@"struct".fields) |field| {
            const pipeline = @field(self.pipelines, field.name);
            if (@typeInfo(@TypeOf(pipeline)) == .optional) {
                if (pipeline) |made| device.destroyPipeline(made);
            } else device.destroyPipeline(pipeline);
        }
        self.pipelines = pipelines;
        if (self.gi_pipelines) |old| {
            const rebuilt = try createGiPipelines(device);
            inline for (@typeInfo(GiPipelines).@"struct".fields) |field| device.destroyPipeline(@field(old, field.name));
            self.gi_pipelines = rebuilt;
        }
        // These are built on first use per target format; drop them.
        for (self.tonemap_pipelines.items) |entry| device.destroyPipeline(entry.pipeline);
        self.tonemap_pipelines.clearRetainingCapacity();
        for (self.draw_pipelines.items) |entry| {
            device.destroyPipeline(entry.flat);
            device.destroyPipeline(entry.depth_tested);
        }
        self.draw_pipelines.clearRetainingCapacity();
        return @intCast(shader_sources.names.len);
    }

    // ------------------------------------------------------ material shaders

    /// Registers application surface code. `spirv` is a fragment shader made
    /// of `#define CUSTOM_MATERIAL`, `#include "shade.glsl"` and a
    /// definition of `customMaterial()`; see `examples/shaders/lava.frag`. The
    /// function receives what the standard material computed for the pixel
    /// and may change any of it; lighting, shadows, global illumination and
    /// antialiasing then proceed as for any surface. Assign it to materials
    /// with `Material.shader` or `setMaterialShader`.
    pub fn createMaterialShader(self: *Renderer, spirv: []const u8) !MaterialShader {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.material_shaders[1..], 1..) |*slot, index| {
            if (slot.* != null) continue;
            const plain = try self.device.createGraphicsPipeline(.{
                .name = "custom material",
                .vertex = shaderCode("fullscreen.vert.spv"),
                .fragment = spirv,
                .color_targets = &.{ .{ .format = hdr_format }, .{ .format = .rg16_float } },
                .cull = .none,
            });
            errdefer self.device.destroyPipeline(plain);
            slot.* = .{
                .plain = plain,
                .reflective = try self.device.createGraphicsPipeline(.{
                    .name = "custom material (reflective)",
                    .vertex = shaderCode("fullscreen.vert.spv"),
                    .fragment = spirv,
                    .color_targets = &shade_reflective_targets,
                    .cull = .none,
                }),
            };
            return .{ .slot = @intCast(index) };
        }
        return error.TooManyMaterialShaders;
    }

    /// Materials still referring to the shader fall back to the standard
    /// material.
    pub fn destroyMaterialShader(self: *Renderer, shader: MaterialShader) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (shader.slot == 0 or shader.slot >= self.material_shaders.len) return;
        if (self.material_shaders[shader.slot]) |pipelines| {
            self.device.destroyPipeline(pipelines.plain);
            self.device.destroyPipeline(pipelines.reflective);
        }
        self.material_shaders[shader.slot] = null;
    }

    /// Changes which shader a loaded model's material uses, and its
    /// parameters. `material` indexes the model's materials; null applies to
    /// all of them. `shader` null restores the standard material. The model
    /// must have finished loading.
    pub fn setMaterialShader(self: *Renderer, model: Model, material: ?u32, shader: ?MaterialShader, params: [4]f32) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const entry = self.models.get(model) orelse return error.InvalidModel;
        if (entry.state != .ready) return error.ModelNotReady;
        const materials = entry.source.?.materials;
        if (material) |index| if (index >= materials.len) return error.InvalidMaterial;
        for (materials, 0..) |*item, index| {
            if (material) |only| if (only != index) continue;
            self.material_shader_users[if (item.shader < self.material_shaders.len) item.shader else 0] -= 1;
            item.shader = if (shader) |value| value.slot else 0;
            item.params = params;
            const encoded = try self.encodeMaterial(entry, item.*, index);
            self.material_shader_users[encoded.shader] += 1;
            try self.materials.write(self.device, entry.material_base + @as(u32, @intCast(index)), std.mem.asBytes(&encoded));
        }
    }

    /// Gives a material of a model images made with `createImage`,
    /// `createImageCompressed` or `loadImage` as its textures: the way to
    /// texture a model built from meshes in memory, and to swap a loaded
    /// model's textures. `material` indexes the model's materials (for
    /// `createModel`, one per mesh); null applies to all of them. Create
    /// color images as sRGB and data images (normal, roughness, occlusion)
    /// as linear. The images must outlive the model's use of them.
    pub fn setMaterialTextures(self: *Renderer, model: Model, material: ?u32, textures: MaterialTextures) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const entry = self.models.get(model) orelse return error.InvalidModel;
        const source = entry.source orelse return error.ModelNotReady;
        const count = source.materials.len;
        if (material) |index| if (index >= count) return error.InvalidMaterial;
        if (entry.material_images.len == 0) {
            entry.material_images = try self.gpa.alloc(MaterialTextures, count);
            @memset(entry.material_images, .{});
        }
        for (entry.material_images, 0..) |*images, index| {
            if (material) |only| if (only != index) continue;
            images.* = textures;
        }
        // A model still on its way to the GPU picks them up when it gets
        // there.
        if (entry.state != .ready) return;
        for (source.materials, 0..) |item, index| {
            if (material) |only| if (only != index) continue;
            const encoded = try self.encodeMaterial(entry, item, index);
            try self.materials.write(self.device, entry.material_base + @as(u32, @intCast(index)), std.mem.asBytes(&encoded));
        }
    }

    fn encodeMaterial(self: *Renderer, entry: *ModelEntry, material: gltf.Material, index: usize) !gpu.Material {
        const device = self.device;
        const sampler_source = material.base_color_texture orelse material.normal_texture orelse
            material.metallic_roughness_texture orelse material.emissive_texture orelse material.occlusion_texture;
        var flags: u32 = 0;
        if (material.alpha_mode == .mask) flags |= gpu.material_alpha_test;
        if (material.alpha_mode == .blend or material.transmission > 0) flags |= gpu.material_blend;
        if (material.double_sided) flags |= gpu.material_double_sided;
        var encoded: gpu.Material = .{
            .base_color = material.base_color,
            .emissive = material.emissive,
            .metallic = material.metallic,
            .roughness = material.roughness,
            .normal_scale = material.normal_scale,
            .occlusion_strength = material.occlusion_strength,
            .alpha_cutoff = material.alpha_cutoff,
            .base_color_texture = self.textureIndex(entry, material.base_color_texture),
            .normal_texture = self.textureIndex(entry, material.normal_texture),
            .metallic_roughness_texture = self.textureIndex(entry, material.metallic_roughness_texture),
            .occlusion_texture = self.textureIndex(entry, material.occlusion_texture),
            .emissive_texture = self.textureIndex(entry, material.emissive_texture),
            .clearcoat_texture = self.textureIndex(entry, material.clearcoat_texture),
            .clearcoat_roughness_texture = self.textureIndex(entry, material.clearcoat_roughness_texture),
            .clearcoat_normal_texture = self.textureIndex(entry, material.clearcoat_normal_texture),
            .clearcoat_normal_scale = material.clearcoat_normal_scale,
            .sheen_color_texture = self.textureIndex(entry, material.sheen_color_texture),
            .sheen_roughness_texture = self.textureIndex(entry, material.sheen_roughness_texture),
            .uv_sets = uvSetBit(material.base_color_texture, 0) | uvSetBit(material.normal_texture, 1) | uvSetBit(material.metallic_roughness_texture, 2) | uvSetBit(material.occlusion_texture, 3) | uvSetBit(material.emissive_texture, 4) | uvSetBit(material.clearcoat_texture, 5) | uvSetBit(material.clearcoat_roughness_texture, 6) | uvSetBit(material.clearcoat_normal_texture, 7) | uvSetBit(material.sheen_color_texture, 8) | uvSetBit(material.sheen_roughness_texture, 9),
            .sampler_index = device.samplerIndex(try self.materialSampler(if (sampler_source) |ref| ref.sampler else .{}, true)),
            .detail_sampler = device.samplerIndex(try self.materialSampler(if (sampler_source) |ref| ref.sampler else .{}, false)),
            .flags = flags,
            .shader = if (material.shader < self.material_shaders.len) material.shader else 0,
            .params = material.params,
            // Scale, then rotate, then offset, as glTF defines it.
            .uv_transform = uvMatrix(material.uv_scale, material.uv_rotation),
            .texture_transforms = transformSlot(entry, index),
            .sway = material.sway,
            .uv_offset = material.uv_offset,
            .clearcoat = std.math.clamp(material.clearcoat, 0, 1),
            .clearcoat_roughness = std.math.clamp(material.clearcoat_roughness, 0, 1),
            .transmission = std.math.clamp(material.transmission, 0, 1),
            .ior = @max(material.ior, 1),
            .thickness = @max(material.thickness, 0),
            .sheen_color = material.sheen_color,
            .sheen_roughness = std.math.clamp(material.sheen_roughness, 0.07, 1),
            .anisotropy = std.math.clamp(material.anisotropy, 0, 1),
            .anisotropy_rotation = material.anisotropy_rotation,
            .subsurface = std.math.clamp(material.subsurface, 0, 1),
        };
        // Application images take the place of the model's own textures.
        if (index < entry.material_images.len) {
            const images = entry.material_images[index];
            inline for (.{
                .{ "base_color", "base_color_texture" },
                .{ "normal", "normal_texture" },
                .{ "metallic_roughness", "metallic_roughness_texture" },
                .{ "occlusion", "occlusion_texture" },
                .{ "emissive", "emissive_texture" },
                .{ "clearcoat", "clearcoat_texture" },
                .{ "clearcoat_roughness", "clearcoat_roughness_texture" },
                .{ "clearcoat_normal", "clearcoat_normal_texture" },
                .{ "sheen_color", "sheen_color_texture" },
                .{ "sheen_roughness", "sheen_roughness_texture" },
            }) |pair| {
                if (@field(images, pair[0])) |image| @field(encoded, pair[1]) = image.index;
            }
        }
        return encoded;
    }

    /// Gives the scene a layer of volumetric clouds, or takes it away with
    /// null. They are lit by the scene's sun and environment, drift with
    /// the wind, and are drawn by every view of the scene that has
    /// `Settings.clouds` on.
    pub fn setClouds(self: *Renderer, scene: Scene, clouds: ?CloudDesc) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const data = self.scenes.get(scene) orelse return error.InvalidScene;
        data.clouds = clouds;
    }

    /// The lightning flash in a scene's cloud layer right now, if any:
    /// where it is and how bright, for a light of the application's own
    /// (`setLights`) so that the ground flickers with the cloud.
    pub fn cloudFlash(self: *Renderer, scene: Scene) ?CloudFlash {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const data = self.scenes.get(scene) orelse return null;
        if (data.flash_brightness <= 0) return null;
        return .{
            .position = .{
                @floatCast(data.flash_position[0] - data.origin[0]),
                @floatCast(data.flash_position[1] - data.origin[1]),
                @floatCast(data.flash_position[2] - data.origin[2]),
            },
            .brightness = data.flash_brightness,
        };
    }

    /// Replaces the scene's decals. They apply to opaque surfaces, before
    /// lighting, so they are lit and shadowed like the surface itself.
    pub fn setDecals(self: *Renderer, scene: Scene, decals: []const DecalDesc) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const data = self.scenes.get(scene) orelse return error.InvalidScene;
        if (decals.len > max_decals) return error.TooManyDecals;
        data.decals.clearRetainingCapacity();
        try data.decals.appendSlice(self.gpa, decals);
    }

    // ------------------------------------------------------------ instances

    /// Places many copies of a model at once: foliage, rocks, debris,
    /// buildings, crowds of static props. The copies are stored on the GPU
    /// and cost no CPU time per frame however many there are; they are
    /// culled, shadowed, lit and picked like entities. They do not animate
    /// (a skinned model is shown in its rest pose), blended meshes in the
    /// model are skipped. They block and bounce probe light while the scene
    /// holds no more than `Options.gi_instance_limit` of them.
    pub fn createInstances(self: *Renderer, scene: Scene, model: Model, transforms: []const Mat4) !InstanceGroup {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const scene_data = self.scenes.get(scene) orelse return error.InvalidScene;
        const entry = self.models.get(model) orelse return error.InvalidModel;
        const copy = try self.gpa.dupe(Mat4, transforms);
        errdefer self.gpa.free(copy);
        const group = try self.instance_groups.insert(.{ .scene = scene, .model = model, .transforms = copy });
        errdefer _ = self.instance_groups.remove(group);
        try scene_data.groups.append(self.gpa, group);
        entry.references += 1;
        scene_data.layout_dirty = true;
        return group;
    }

    /// Replaces the transforms of a group; the count may change.
    pub fn setInstances(self: *Renderer, group: InstanceGroup, transforms: []const Mat4) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const data = self.instance_groups.get(group) orelse return error.InvalidInstanceGroup;
        const scene = self.scenes.get(data.scene) orelse return error.InvalidScene;
        if (transforms.len == data.transforms.len) {
            @memcpy(data.transforms, transforms);
            // Same shape: only the records need rewriting.
            scene.static_version += 1;
            return;
        }
        const copy = try self.gpa.dupe(Mat4, transforms);
        self.gpa.free(data.transforms);
        data.transforms = copy;
        scene.layout_dirty = true;
    }

    /// Gives each copy in a group its own color, multiplied with the
    /// model's base color: one per transform, in the same order. An empty
    /// slice removes them. They must be set again after `setInstances`
    /// changes the number of copies.
    pub fn setInstanceColors(self: *Renderer, group: InstanceGroup, colors: []const [3]f32) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const data = self.instance_groups.get(group) orelse return error.InvalidInstanceGroup;
        const scene = self.scenes.get(data.scene) orelse return error.InvalidScene;
        if (colors.len != 0 and colors.len != data.transforms.len) return error.ColorCountMismatch;
        const tints = try self.gpa.alloc(u32, colors.len);
        for (tints, colors) |*tint, color| tint.* = packTint(color);
        self.gpa.free(data.tints);
        data.tints = tints;
        scene.static_version += 1;
    }

    /// Gives each copy in a group four numbers of its own for custom
    /// material shaders (`MaterialContext.instance_params`): one set per
    /// transform, in the same order. An empty slice removes them. They
    /// must be set again after `setInstances` changes the number of
    /// copies.
    pub fn setInstanceParams(self: *Renderer, group: InstanceGroup, params: []const [4]f32) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const data = self.instance_groups.get(group) orelse return error.InvalidInstanceGroup;
        const scene = self.scenes.get(data.scene) orelse return error.InvalidScene;
        if (params.len != 0 and params.len != data.transforms.len) return error.ParamCountMismatch;
        const copy = try self.gpa.dupe([4]f32, params);
        self.gpa.free(data.params);
        data.params = copy;
        scene.static_version += 1;
    }

    /// Makes every copy of a group take the pose of `entity`, which must
    /// be a visible entity of the same model in the same scene: a crowd
    /// that moves as one, deformed once however many copies there are.
    /// Null, or an entity that is not being posed, leaves the copies in
    /// the model's rest pose. The copies do not take part in ray tracing.
    pub fn setInstancesPose(self: *Renderer, group: InstanceGroup, entity: ?Entity) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const data = self.instance_groups.get(group) orelse return;
        const scene = self.scenes.get(data.scene) orelse return;
        data.driver = entity;
        scene.static_version += 1;
    }

    /// Removes an instance group and all its copies from its scene and
    /// releases its hold on the model. A stale handle is ignored.
    pub fn destroyInstances(self: *Renderer, group: InstanceGroup) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const removed = self.instance_groups.remove(group) orelse return;
        self.gpa.free(removed.transforms);
        self.gpa.free(removed.tints);
        self.gpa.free(removed.params);
        if (self.models.get(removed.model)) |model| model.references -= 1;
        const scene = self.scenes.get(removed.scene) orelse return;
        for (scene.groups.items, 0..) |item, index| if (std.meta.eql(item, group)) {
            _ = scene.groups.orderedRemove(index);
            break;
        };
        scene.layout_dirty = true;
    }

    // ---------------------------------------------------------------- water

    /// Adds a sheet of simulated water to a scene: ripples spread across
    /// it, bounce off its edges and die down. It mirrors the scene (by ray
    /// where ray tracing is available, else the sky), shows what is under
    /// it bent by the waves, and takes on its own color with depth.
    pub fn createWater(self: *Renderer, scene: Scene, desc: WaterDesc) !Water {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const data = self.scenes.get(scene) orelse return error.InvalidScene;
        if (data.waters.items.len == max_waters) return error.TooManyWaters;
        var state = WaterState{ .scene = scene, .desc = desc };
        if (desc.splashes > 0) state.splash = try self.createEmitterLocked(scene, simulation_passes.splashDesc(desc));
        errdefer if (state.splash) |emitter| self.destroyEmitterLocked(emitter);
        try self.createWaterTextures(&state);
        errdefer for (state.state) |texture| self.device.destroyTexture(texture);
        const water = try self.waters.insert(state);
        errdefer _ = self.waters.remove(water);
        try data.waters.append(self.gpa, water);
        return water;
    }

    /// Replaces a water surface's description. Changing the resolution
    /// flattens it; anything else applies to the moving surface.
    pub fn setWater(self: *Renderer, water: Water, desc: WaterDesc) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const state = self.waters.get(water) orelse return error.InvalidWater;
        const resized = !std.mem.eql(u32, &desc.resolution, &state.desc.resolution);
        if (desc.splashes > 0 and state.splash == null) state.splash = try self.createEmitterLocked(state.scene, simulation_passes.splashDesc(desc));
        if (desc.splashes <= 0) if (state.splash) |emitter| {
            self.destroyEmitterLocked(emitter);
            state.splash = null;
        };
        state.desc = desc;
        if (resized) {
            for (state.state) |texture| self.device.destroyTexture(texture);
            try self.createWaterTextures(state);
        }
    }

    /// Dents the water at a point in the world, as something falling in or
    /// moving through it would: `radius` and `depth` in world units. Up to
    /// 16 per frame take effect; further ones are dropped.
    pub fn addRipple(self: *Renderer, water: Water, position: Vec3, radius: f32, depth: f32) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const state = self.waters.get(water) orelse return;
        if (state.ripple_count == state.ripples.len) return;
        const t = state.desc.transform;
        const local = math.transformPoint(math.inverse(t), position);
        const width = @max(math.length(.{ t[0], t[1], t[2] }), 1e-6);
        const up = @max(math.length(.{ t[4], t[5], t[6] }), 1e-6);
        state.ripples[state.ripple_count] = .{
            .position = .{ local[0] + 0.5, local[2] + 0.5 },
            .radius = radius / width,
            .depth = depth / up,
        };
        state.ripple_count += 1;
        // As deep a dent as this is something falling in: it splashes.
        const strength = depth * 12 * radius;
        if (strength > state.hit_strength) {
            state.hit_strength = strength;
            state.hit_at = math.transformPoint(t, .{ local[0], 0, local[2] });
            state.hit_radius = radius;
        }
    }

    /// Removes a water sheet from its scene and frees its simulation
    /// textures, along with the splash emitter it made for itself, if
    /// any. A stale handle is ignored.
    pub fn destroyWater(self: *Renderer, water: Water) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const removed = self.waters.remove(water) orelse return;
        if (removed.splash) |emitter| self.destroyEmitterLocked(emitter);
        for (removed.state) |texture| self.device.destroyTexture(texture);
        const scene = self.scenes.get(removed.scene) orelse return;
        for (scene.waters.items, 0..) |item, index| if (std.meta.eql(item, water)) {
            _ = scene.waters.orderedRemove(index);
            break;
        };
    }

    // ------------------------------------------------------------- liquid

    /// Adds a volume of liquid to a scene.
    pub fn createLiquid(self: *Renderer, scene: Scene, desc: LiquidDesc) !Liquid {
        const liquid = try self.createLiquidAlone(scene, desc);
        // The stand-in is a nicety: a liquid without one is only missing
        // from ray-traced reflections.
        self.attachLiquidProxy(scene, liquid, desc) catch |err| std.log.debug("liquid: no stand-in for rays: {s}", .{@errorName(err)});
        return liquid;
    }

    /// Gives a liquid the box that rays meet in its place: see-through,
    /// in the liquid's color, resized each frame to how much liquid
    /// there is.
    fn attachLiquidProxy(self: *Renderer, scene: Scene, liquid: Liquid, desc: LiquidDesc) !void {
        if (!self.device.ray_tracing) return;
        const model = self.liquid_proxy_model orelse made: {
            const positions = [8][3]f32{ .{ -0.5, -0.5, -0.5 }, .{ 0.5, -0.5, -0.5 }, .{ 0.5, 0.5, -0.5 }, .{ -0.5, 0.5, -0.5 }, .{ -0.5, -0.5, 0.5 }, .{ 0.5, -0.5, 0.5 }, .{ 0.5, 0.5, 0.5 }, .{ -0.5, 0.5, 0.5 } };
            const indices = [36]u32{ 0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7, 0, 1, 5, 0, 5, 4, 3, 6, 2, 3, 7, 6, 0, 4, 7, 0, 7, 3, 1, 2, 6, 1, 6, 5 };
            const created = try self.createModel(&.{.{ .positions = &positions, .indices = &indices, .material = .{ .base_color = .{ 1, 1, 1, 0.7 }, .metallic = 0, .roughness = 0.05, .alpha_mode = .blend, .double_sided = true } }});
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            // Another thread may have made one meanwhile; one is kept.
            if (self.liquid_proxy_model == null) self.liquid_proxy_model = created;
            break :made self.liquid_proxy_model.?;
        };
        // Hidden until it is marked as for rays only, so that no frame
        // draws it.
        const entity = try self.spawn(scene, .{ .model = model, .transform = desc.transform, .visible = false, .tint = desc.color });
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const data = self.entities.get(entity) orelse return;
        data.rays_only = true;
        data.visible = true;
        if (self.liquids.get(liquid)) |state| state.proxy = entity;
        if (self.scenes.get(scene)) |scene_data| scene_data.layout_dirty = true;
    }

    fn createLiquidAlone(self: *Renderer, scene: Scene, desc: LiquidDesc) !Liquid {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const data = self.scenes.get(scene) orelse return error.InvalidScene;
        if (data.liquids.items.len == max_liquids) return error.TooManyLiquids;
        const device = self.device;
        const radius = std.math.clamp(desc.particle_radius, 0.002, 10);
        const reach = radius * 4;
        const box = simulation_passes.liquidBox(desc.transform);
        var grid: [3]i32 = undefined;
        var cell_count: u64 = 1;
        inline for (0..3) |axis| {
            grid[axis] = @intFromFloat(@max(@ceil(box.extent[axis] / reach), 1));
            cell_count *= @intCast(grid[axis]);
        }
        // A box this much larger than its grain would need a grid that
        // does not fit: ask for coarser particles.
        if (cell_count > 2 * 1024 * 1024) return error.LiquidTooFine;
        const capacity = std.math.clamp(desc.capacity, 64, 1 << 20);
        var block: [3]u32 = undefined;
        inline for (0..3) |axis| block[axis] = @intFromFloat(@max(@floor(std.math.clamp(desc.fill[axis], 0, 1) * box.extent[axis] / (radius * 2) - 1), 0));
        const particles = try device.createBuffer(.{ .name = "liquid particles", .size = @as(u64, capacity) * @sizeOf(gpu.LiquidParticle), .usage = .{ .storage = true } });
        errdefer device.destroyBuffer(particles);
        const counts = try device.createBuffer(.{ .name = "liquid grid counts", .size = cell_count * @sizeOf(u32), .usage = .{ .storage = true } });
        errdefer device.destroyBuffer(counts);
        const cells = try device.createBuffer(.{ .name = "liquid grid", .size = cell_count * liquid_cell_slots * @sizeOf(u32), .usage = .{ .storage = true } });
        errdefer device.destroyBuffer(cells);
        const params_buffer = try device.createBuffer(.{ .name = "liquid steps", .size = 8 * @sizeOf(gpu.Liquid), .usage = .{ .storage = true } });
        errdefer device.destroyBuffer(params_buffer);
        var state = LiquidState{
            .scene = scene,
            .desc = desc,
            .capacity = capacity,
            .particles = particles,
            .counts = counts,
            .cells = cells,
            .params_buffer = params_buffer,
            .cell_count = @intCast(cell_count),
            .grid = grid,
            .block = block,
        };
        state.desc.particle_radius = radius;
        state.setSources(desc.sources);
        const liquid = try self.liquids.insert(state);
        errdefer _ = self.liquids.remove(liquid);
        try data.liquids.append(self.gpa, liquid);
        return liquid;
    }

    /// Replaces a liquid's description. The box's size, the particle
    /// radius, the capacity and the starting block stay as they were
    /// when it was created; the rest applies to the liquid as it is.
    pub fn setLiquid(self: *Renderer, liquid: Liquid, desc: LiquidDesc) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const state = self.liquids.get(liquid) orelse return error.InvalidLiquid;
        const radius = state.desc.particle_radius;
        state.desc = desc;
        state.desc.particle_radius = radius;
        state.setSources(desc.sources);
    }

    /// How many particles of a liquid are in use.
    pub fn liquidParticles(self: *Renderer, liquid: Liquid) u32 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const state = self.liquids.get(liquid) orelse return 0;
        return state.live;
    }

    /// Removes a liquid from its scene and frees its particle buffers. A
    /// stale handle is ignored.
    pub fn destroyLiquid(self: *Renderer, liquid: Liquid) void {
        // The stand-in goes once the lock below has been let go.
        var proxy: ?Entity = null;
        defer if (proxy) |entity| self.despawn(entity);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var removed = self.liquids.remove(liquid) orelse return;
        proxy = removed.proxy;
        removed.deinit(self.device);
        const scene = self.scenes.get(removed.scene) orelse return;
        for (scene.liquids.items, 0..) |item, index| if (std.meta.eql(item, liquid)) {
            _ = scene.liquids.orderedRemove(index);
            break;
        };
    }

    fn createWaterTextures(self: *Renderer, state: *WaterState) !void {
        inline for (0..2) |axis| state.size[axis] = std.math.clamp(state.desc.resolution[axis], 16, 1024);
        var made: usize = 0;
        errdefer for (state.state[0..made]) |texture| self.device.destroyTexture(texture);
        for (&state.state) |*texture| {
            texture.* = try self.device.createTexture(.{
                .name = "water",
                .width = state.size[0],
                .height = state.size[1],
                .format = .rg16_float,
                .usage = .{ .sampled = true, .color_attachment = true },
            });
            made += 1;
        }
        state.cleared = false;
        state.current = 0;
    }

    // --------------------------------------------------------------- fluids

    /// Adds a box of simulated smoke and fire to a scene. The simulation
    /// runs on the GPU once per frame and every view of the scene draws
    /// the result, lit by the sun, the sky and the probes.
    pub fn createFluid(self: *Renderer, scene: Scene, desc: FluidDesc) !Fluid {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const data = self.scenes.get(scene) orelse return error.InvalidScene;
        if (data.fluids.items.len == max_fluids) return error.TooManyFluids;
        if (desc.sources.len > gpu.max_fluid_sources) return error.TooManyFluidSources;
        if (desc.obstacles.len > gpu.max_fluid_obstacles) return error.TooManyFluidObstacles;
        var state = FluidState{ .scene = scene, .desc = desc };
        state.setSources(desc.sources);
        try self.createFluidTextures(&state);
        errdefer self.destroyFluidTextures(&state);
        const fluid = try self.fluids.insert(state);
        errdefer _ = self.fluids.remove(fluid);
        try data.fluids.append(self.gpa, fluid);
        return fluid;
    }

    /// Replaces a fluid's description. Changing the resolution starts the
    /// simulation over; anything else takes effect on the running one.
    pub fn setFluid(self: *Renderer, fluid: Fluid, desc: FluidDesc) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const state = self.fluids.get(fluid) orelse return error.InvalidFluid;
        if (desc.sources.len > gpu.max_fluid_sources) return error.TooManyFluidSources;
        if (desc.obstacles.len > gpu.max_fluid_obstacles) return error.TooManyFluidObstacles;
        const resized = !std.mem.eql(u32, &desc.resolution, &state.desc.resolution);
        state.desc = desc;
        state.setSources(desc.sources);
        if (resized) {
            self.destroyFluidTextures(state);
            try self.createFluidTextures(state);
        }
    }

    /// Empties a fluid: no smoke, no heat, no motion.
    pub fn resetFluid(self: *Renderer, fluid: Fluid) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.fluids.get(fluid)) |state| state.cleared = false;
    }

    /// A picture of the fluid seen along its depth, redrawn every frame the
    /// fluid's scene is rendered: smoke as coverage, fire as glow. Draw it
    /// with a draw list for 2D smoke and fire. It is `resolution` pixels
    /// in size and lasts as long as the fluid.
    pub fn fluidImage(self: *Renderer, fluid: Fluid) !Image {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const state = self.fluids.get(fluid) orelse return error.InvalidFluid;
        if (state.picture == null) {
            state.picture = try self.device.createTexture(.{
                .name = "fluid picture",
                .width = state.size[0],
                .height = state.size[1],
                .format = hdr_format,
                .usage = .{ .sampled = true, .color_attachment = true, .copy_src = true },
            });
            state.picture_drawn = false;
        }
        return .{ .index = self.device.textureIndex(state.picture.?), .width = state.size[0], .height = state.size[1] };
    }

    /// Saves the fluid's picture (see `fluidImage`) as a PNG with alpha:
    /// one frame of a sprite animation baked from the simulation. Call it
    /// between frames; it waits for the GPU. `fluidImage` must have been
    /// asked for and at least one frame rendered since.
    pub fn saveFluidImage(self: *Renderer, fluid: Fluid, path: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const state = self.fluids.get(fluid) orelse return error.InvalidFluid;
        const picture = state.picture orelse return error.NoFluidImage;
        try self.saveHdrPicture(picture, state.size[0], state.size[1], path);
    }

    /// Starts recording the fluid's picture (as `fluidImage` shows it)
    /// into a sheet of `columns` x `rows` frames, one every `interval`
    /// simulation steps, filled left to right, top row first. The sheet is
    /// returned at once and fills in as the frames go by: give it to an
    /// emitter (`EmitterDesc.image` with `sheet`) or a draw list, or write
    /// it out with `saveFluidFlipbook` once `fluidFlipbookFrames` says it
    /// is full. It lasts as long as the fluid keeps its resolution;
    /// calling this again starts over, and with a different size replaces
    /// the sheet.
    pub fn recordFluidFlipbook(self: *Renderer, fluid: Fluid, desc: FluidFlipbookDesc) !Image {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const state = self.fluids.get(fluid) orelse return error.InvalidFluid;
        if (desc.columns == 0 or desc.rows == 0) return error.InvalidFlipbook;
        const frame = desc.frame_size orelse [2]u32{ state.size[0], state.size[1] };
        const width = frame[0] * desc.columns;
        const height = frame[1] * desc.rows;
        if (frame[0] == 0 or frame[1] == 0 or width > 16384 or height > 16384) return error.InvalidFlipbook;
        const old = state.flipbook_desc;
        if (state.flipbook == null or old.columns != desc.columns or old.rows != desc.rows or !std.meta.eql(state.flipbook_frame, frame)) {
            const sheet = try self.device.createTexture(.{
                .name = "fluid flipbook",
                .width = width,
                .height = height,
                .format = hdr_format,
                .usage = .{ .sampled = true, .color_attachment = true, .copy_src = true },
            });
            if (state.flipbook) |texture| self.device.destroyTexture(texture);
            state.flipbook = sheet;
        }
        state.flipbook_desc = desc;
        state.flipbook_frame = frame;
        state.flipbook_recorded = 0;
        state.flipbook_wait = 0;
        return .{ .index = self.device.textureIndex(state.flipbook.?), .width = width, .height = height };
    }

    /// How many frames of the fluid's flipbook have been recorded so far;
    /// `columns * rows` when it is full.
    pub fn fluidFlipbookFrames(self: *Renderer, fluid: Fluid) u32 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const state = self.fluids.get(fluid) orelse return 0;
        return state.flipbook_recorded;
    }

    /// Saves the fluid's flipbook as a PNG with alpha, as far as it has
    /// been recorded. Call it between frames; it waits for the GPU.
    pub fn saveFluidFlipbook(self: *Renderer, fluid: Fluid, path: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const state = self.fluids.get(fluid) orelse return error.InvalidFluid;
        const sheet = state.flipbook orelse return error.NoFluidImage;
        if (state.flipbook_recorded == 0) return error.NoFluidImage;
        try self.saveHdrPicture(sheet, state.flipbook_frame[0] * state.flipbook_desc.columns, state.flipbook_frame[1] * state.flipbook_desc.rows, path);
    }

    /// Writes a half-float, linear, straight-alpha texture as an 8-bit
    /// sRGB PNG.
    fn saveHdrPicture(self: *Renderer, texture: rhi.Texture, width: u32, height: u32, path: []const u8) !void {
        const raw = try self.device.readTexture(self.gpa, texture);
        defer self.gpa.free(raw);
        const count = @as(usize, width) * height;
        const pixels = try self.gpa.alloc(u8, count * 4);
        defer self.gpa.free(pixels);
        for (0..count) |index| {
            inline for (0..4) |channel| {
                const half: f16 = @bitCast(std.mem.readInt(u16, raw[index * 8 + channel * 2 ..][0..2], .little));
                const value = std.math.clamp(@as(f32, half), 0, 1);
                const encoded = if (channel == 3) value else if (value <= 0.0031308) value * 12.92 else 1.055 * std.math.pow(f32, value, 1.0 / 2.4) - 0.055;
                pixels[index * 4 + channel] = @intFromFloat(encoded * 255 + 0.5);
            }
        }
        try png.write(self.gpa, self.io, path, .{ .width = width, .height = height, .pixels = pixels });
    }

    /// Removes a fluid from its scene and frees its simulation textures. A
    /// stale handle is ignored.
    pub fn destroyFluid(self: *Renderer, fluid: Fluid) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var removed = self.fluids.remove(fluid) orelse return;
        self.destroyFluidTextures(&removed);
        const scene = self.scenes.get(removed.scene) orelse return;
        for (scene.fluids.items, 0..) |item, index| if (std.meta.eql(item, fluid)) {
            _ = scene.fluids.orderedRemove(index);
            break;
        };
    }

    fn createFluidTextures(self: *Renderer, state: *FluidState) !void {
        const device = self.device;
        inline for (0..3) |axis| state.size[axis] = std.math.clamp(state.desc.resolution[axis], if (axis == 2) 1 else 8, 256);
        // The slices are laid out as a roughly square sheet.
        state.tiles_x = @intFromFloat(@ceil(@sqrt(@as(f32, @floatFromInt(state.size[2])))));
        const tiles_y = (state.size[2] + state.tiles_x - 1) / state.tiles_x;
        const width = state.size[0] * state.tiles_x;
        const height = state.size[1] * tiles_y;
        const usage = rhi.TextureUsage{ .sampled = true, .color_attachment = true };
        var made: usize = 0;
        const textures = state.textures();
        errdefer for (textures[0..made]) |texture| device.destroyTexture(texture.*);
        for (textures, 0..) |texture, index| {
            texture.* = try device.createTexture(.{
                .name = "fluid",
                .width = width,
                .height = height,
                // Pressure and divergence: a number and the solid flag.
                .format = if (index == 8) .r8_unorm else if (index >= 4 and index < 7) .rg16_float else .rgba16_float,
                .usage = usage,
            });
            made += 1;
        }
        state.cleared = false;
        state.current = 0;
    }

    fn destroyFluidTextures(self: *Renderer, state: *FluidState) void {
        for (state.textures()) |texture| self.device.destroyTexture(texture.*);
        if (state.picture) |texture| self.device.destroyTexture(texture);
        if (state.flipbook) |texture| self.device.destroyTexture(texture);
        state.flipbook = null;
        state.picture = null;
    }

    // ------------------------------------------------------------ particles

    /// Adds a particle emitter to a scene. Particles are simulated and
    /// drawn entirely on the GPU; the cost on the CPU does not depend on
    /// how many there are.
    pub fn createEmitter(self: *Renderer, scene: Scene, desc: EmitterDesc) !Emitter {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.createEmitterLocked(scene, desc);
    }

    /// `createEmitter` for a caller that holds the renderer's lock.
    fn createEmitterLocked(self: *Renderer, scene: Scene, desc: EmitterDesc) !Emitter {
        const data = self.scenes.get(scene) orelse return error.InvalidScene;
        const capacity = std.math.clamp(desc.capacity, 1, 1 << 20);
        const buffer = try self.device.createBuffer(.{
            .name = "particles",
            .size = @as(u64, capacity) * @sizeOf(gpu.Particle),
            .usage = .{ .storage = true },
        });
        errdefer self.device.destroyBuffer(buffer);
        // All zero: age equals lifetime, so every particle starts dead.
        const zeros = try self.gpa.alloc(u8, capacity * @sizeOf(gpu.Particle));
        defer self.gpa.free(zeros);
        @memset(zeros, 0);
        try self.device.uploadBuffer(buffer, 0, zeros);
        // The sort works on a power of two; the slots past the capacity
        // hold entries that sort last and draw nothing.
        const order_count = std.math.ceilPowerOfTwo(u32, capacity) catch capacity;
        const order: ?rhi.Buffer = if (desc.sorted) try self.device.createBuffer(.{
            .name = "particle order",
            .size = @as(u64, order_count) * 8,
            .usage = .{ .storage = true, .copy_src = true },
        }) else null;
        errdefer if (order) |value| self.device.destroyBuffer(value);
        // Remembered positions for trails; newborns fill theirs in.
        const trail_points = @min(desc.trail, max_trail_points);
        const trail: ?rhi.Buffer = if (trail_points != 0) try self.device.createBuffer(.{
            .name = "particle trails",
            .size = @as(u64, capacity) * trail_points * 16,
            .usage = .{ .storage = true },
        }) else null;
        errdefer if (trail) |value| self.device.destroyBuffer(value);
        const emitter = try self.emitters.insert(.{ .scene = scene, .desc = desc, .buffer = buffer, .capacity = capacity, .order = order, .order_count = order_count, .trail = trail, .trail_points = trail_points });
        errdefer _ = self.emitters.remove(emitter);
        try data.emitters.append(self.gpa, emitter);
        return emitter;
    }

    /// For tests: the sort keys of a sorted emitter in drawing order, as
    /// left by the last view that drew it. Smaller is farther; dead slots
    /// are large and come last. Waits for the GPU. Caller frees.
    pub fn emitterSortKeys(self: *Renderer, gpa: std.mem.Allocator, emitter: Emitter) ![]f32 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const data = self.emitters.get(emitter) orelse return error.InvalidEmitter;
        const order = data.order orelse return error.EmitterNotSorted;
        const bytes = try self.device.readBuffer(gpa, order, @as(u64, data.order_count) * 8);
        defer gpa.free(bytes);
        const keys = try gpa.alloc(f32, data.order_count);
        for (keys, 0..) |*key, index| key.* = @bitCast(std.mem.readInt(u32, bytes[index * 8 ..][0..4], .little));
        return keys;
    }

    /// Replaces an emitter's description; `capacity` is ignored.
    pub fn setEmitter(self: *Renderer, emitter: Emitter, desc: EmitterDesc) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.emitters.get(emitter)) |data| data.desc = desc;
    }

    /// Adds a local reflection probe to a scene. Its six pictures are
    /// taken at the end of the next frames that draw anything (one
    /// picture a frame, so six frames a probe, each costing a small view
    /// of the scene), without
    /// screen-space reflections or other probes' help on the first take;
    /// call `updateReflectionProbe` after the scene or its lighting
    /// changes, or again to pick up light bounced between mirrors.
    pub fn createReflectionProbe(self: *Renderer, scene: Scene, desc: ReflectionProbeDesc) !ReflectionProbe {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const data = self.scenes.get(scene) orelse return error.InvalidScene;
        if (data.probes.items.len >= max_reflection_probes) return error.TooManyReflectionProbes;
        const size = std.math.clamp(desc.resolution, 16, 1024);
        const target = try self.device.createTexture(.{
            .name = "reflection probe view",
            .width = size,
            .height = size,
            .format = .rgba8_srgb,
            .usage = .{ .sampled = true, .color_attachment = true },
        });
        errdefer self.device.destroyTexture(target);
        const view = try self.insertView();
        errdefer if (self.views.remove(view)) |removed_view| {
            var removed = removed_view;
            removed.deinit(self.device);
        };
        const probe = try self.probes.insert(.{ .scene = scene, .desc = desc, .target = target, .view = view, .cubes = .{ .max_radiance = desc.max_radiance } });
        errdefer _ = self.probes.remove(probe);
        try data.probes.append(self.gpa, probe);
        return probe;
    }

    /// Changes where a probe is and what it covers. A new position takes
    /// effect with the next `updateReflectionProbe`.
    pub fn setReflectionProbe(self: *Renderer, probe: ReflectionProbe, desc: ReflectionProbeDesc) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const data = self.probes.get(probe) orelse return;
        const resolution = data.desc.resolution;
        data.desc = desc;
        data.desc.resolution = resolution;
        data.cubes.max_radiance = desc.max_radiance;
    }

    /// Asks for a probe's pictures to be taken again.
    pub fn updateReflectionProbe(self: *Renderer, probe: ReflectionProbe) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.probes.get(probe)) |data| data.dirty = true;
    }

    /// Removes a reflection probe from its scene and frees its pictures
    /// and the view they were taken with. A stale handle is ignored.
    pub fn destroyReflectionProbe(self: *Renderer, probe: ReflectionProbe) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var removed = self.probes.remove(probe) orelse return;
        self.freeProbe(&removed);
        const scene = self.scenes.get(removed.scene) orelse return;
        for (scene.probes.items, 0..) |item, index| if (std.meta.eql(item, probe)) {
            _ = scene.probes.swapRemove(index);
            break;
        };
    }

    fn freeProbe(self: *Renderer, probe: *ProbeData) void {
        self.freeEnvironment(&probe.cubes);
        self.device.destroyTexture(probe.target);
        if (self.views.remove(probe.view)) |removed_view| {
            var removed = removed_view;
            removed.deinit(self.device);
        }
    }

    /// Takes the six pictures of the first probe that is waiting for
    /// them, and filters them into its reflection cube.
    fn captureProbes(self: *Renderer, frame: rhi.Frame, delta_time: f32, arena: *FrameArena) !void {
        for (self.probes.slots.items) |*slot| if (slot.value) |*probe| {
            if (!probe.dirty and probe.face == 0) continue;
            // Bounced light takes some frames to settle after a scene
            // appears; a picture taken before then is lit by the sun alone.
            if (!probe.captured and probe.face == 0 and probe.waited < probe.desc.settle_frames) {
                probe.waited += 1;
                continue;
            }
            const scene = self.scenes.get(probe.scene) orelse continue;
            // Wait for something to mirror.
            if (scene.layout.items.len == 0 and scene.static_count == 0) continue;
            // One picture a frame: a view can be drawn once per frame, and
            // six at once would be a spike.
            if (probe.face == 0) probe.dirty = false;
            probe.capturing = true;
            defer probe.capturing = false;
            const cmd = frame.cmd;
            const device = self.device;
            try self.ensureEnvironmentTextures(&probe.cubes);
            // Each face's camera: where it looks and which way is up.
            const faces = [6][2]Vec3{
                .{ .{ 1, 0, 0 }, .{ 0, 1, 0 } },  .{ .{ -1, 0, 0 }, .{ 0, 1, 0 } },
                .{ .{ 0, 1, 0 }, .{ 0, 0, -1 } }, .{ .{ 0, -1, 0 }, .{ 0, 0, 1 } },
                .{ .{ 0, 0, 1 }, .{ 0, 1, 0 } },  .{ .{ 0, 0, -1 }, .{ 0, 1, 0 } },
            };
            {
                const face = probe.face;
                const axes = faces[face];
                try self.renderView(frame, .{
                    .view = probe.view,
                    .scene = probe.scene,
                    .camera = .{ .position = probe.desc.position, .forward = axes[0], .up = axes[1], .fov_y = std.math.pi * 0.5, .near = 0.05 },
                    .target = .{ .texture = probe.target },
                    // The plain lit scene: nothing that depends on the
                    // frames before, on the screen, or on the lens.
                    .settings = .{
                        .temporal_antialiasing = false,
                        .screen_space_reflections = false,
                        .occlusion_culling = false,
                        .automatic_exposure = false,
                        .gi_follow_camera = false,
                        .ao_temporal_filter = false,
                        .cloud_temporal_filter = false,
                        .shadow_cascade_stagger = false,
                        .light_shadow_filter = false,
                        .bloom = 0,
                        .sharpen = 0,
                    },
                }, delta_time, arena);
                const state = &(self.views.get(probe.view).?.state orelse return);
                cmd.transition(state.hdr, .shader_read);
                const forward = axes[0];
                const right = math.normalize(math.cross(forward, axes[1]));
                const up = math.cross(right, forward);
                try cmd.beginRendering(.{ .color = &.{.{ .texture = probe.cubes.sky.?, .layer = @intCast(face), .load = .discard }} });
                cmd.bindPipeline(self.pipelines.probe_face);
                cmd.pushConstants(extern struct { source: u32, sampler: u32, face: u32, max_radiance: f32, right: [3]f32, up: [3]f32, forward: [3]f32 }{
                    .source = device.textureIndex(state.hdr),
                    .sampler = device.samplerIndex(self.sampler_linear_clamp),
                    .face = @intCast(face),
                    .max_radiance = probe.desc.max_radiance,
                    .right = right,
                    .up = up,
                    .forward = forward,
                });
                cmd.drawFullscreen();
                cmd.endRendering();
            }
            probe.face += 1;
            if (probe.face < 6) return;
            probe.face = 0;
            cmd.generateMips(probe.cubes.sky.?);
            try self.filterEnvironment(&probe.cubes, cmd);
            probe.cubes.state = .ready;
            probe.captured = true;
            return;
        };
    }

    /// Removes an emitter from its scene and frees its particle buffers;
    /// particles still alive vanish at once. A stale handle is ignored.
    pub fn destroyEmitter(self: *Renderer, emitter: Emitter) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.destroyEmitterLocked(emitter);
    }

    /// `destroyEmitter` for a caller that holds the renderer's lock.
    fn destroyEmitterLocked(self: *Renderer, emitter: Emitter) void {
        const removed = self.emitters.remove(emitter) orelse return;
        self.device.destroyBuffer(removed.buffer);
        if (removed.order) |order| self.device.destroyBuffer(order);
        if (removed.trail) |trail| self.device.destroyBuffer(trail);
        const scene = self.scenes.get(removed.scene) orelse return;
        for (scene.emitters.items, 0..) |item, index| if (std.meta.eql(item, emitter)) {
            _ = scene.emitters.swapRemove(index);
            break;
        };
    }

    /// Waits for every shading variant being compiled and frees them all.
    /// Called before the shader code they are built from goes away.
    fn dropShadeVariants(self: *Renderer) void {
        for (self.shade_variants.items) |*variant| {
            if (variant.job) |job| {
                job.group.cancel(job.io);
                if (job.compiled) |compiled| self.device.discardPipeline(compiled);
                self.gpa.destroy(job);
            }
            if (variant.pipeline) |pipeline| self.device.destroyPipeline(pipeline);
        }
        self.shade_variants.clearRetainingCapacity();
    }

    /// Blocks until the shading variants being compiled in the background
    /// are done, so that the next frame uses them. For tools, tests and
    /// benchmarks that measure a handful of frames; an application just
    /// keeps rendering.
    pub fn waitForShaderVariants(self: *Renderer) !void {
        while (true) {
            {
                self.mutex.lockUncancelable(self.io);
                defer self.mutex.unlock(self.io);
                var pending = false;
                for (self.shade_variants.items) |variant| {
                    if (variant.job) |job| if (!job.done.load(.acquire)) {
                        pending = true;
                    };
                }
                if (!pending) return;
            }
            try self.io.sleep(std.Io.Duration.fromMilliseconds(1), .awake);
        }
    }

    fn noteMover(self: *Renderer, scene: *SceneData, sphere: [4]f32) void {
        if (scene.movers.items.len >= max_movers) {
            scene.movers_overflow = true;
            return;
        }
        scene.movers.append(self.gpa, sphere) catch {
            scene.movers_overflow = true;
        };
    }

    /// Works out the node matrices of every animated entity of a scene for
    /// this frame, on several threads when there are enough of them.
    fn evaluatePoses(self: *Renderer, scene: *SceneData) !void {
        const zone = Zone.start(self.options.profiler, "poses");
        defer zone.stop();
        self.posed.clearRetainingCapacity();
        var most_nodes: usize = 0;
        for (scene.layout.items) |entry| {
            if (!entry.first_of_entity) continue;
            const entity = self.entities.get(entry.entity).?;
            if (entity.node_world.len == 0) continue;
            try self.posed.append(self.gpa, entry.entity);
            most_nodes = @max(most_nodes, entity.node_world.len);
        }
        const count = self.posed.items.len;
        if (count == 0) return;
        const allowed: usize = switch (self.options.pose_threads) {
            0 => @min(std.Thread.getCpuCount() catch 1, max_pose_threads),
            else => |asked| @min(asked, max_pose_threads),
        };
        const threads = std.math.clamp(count / pose_batch, 1, allowed);
        // The threads only read and write memory set aside here: nothing
        // is allocated off this thread.
        for (self.pose_scratch[0..threads]) |*scratch| try scratch.resize(self.gpa, most_nodes * 3);
        if (threads == 1) return self.poseEntities(self.posed.items, self.pose_scratch[0].items);
        var group: std.Io.Group = .init;
        const share = (count + threads - 1) / threads;
        for (1..threads) |index| {
            const batch = self.posed.items[@min(index * share, count)..@min((index + 1) * share, count)];
            // If no thread is to be had, the work is done here instead.
            group.concurrent(self.io, poseEntities, .{ self, batch, self.pose_scratch[index].items }) catch
                self.poseEntities(batch, self.pose_scratch[index].items);
        }
        self.poseEntities(self.posed.items[0..@min(share, count)], self.pose_scratch[0].items);
        group.await(self.io) catch {};
    }

    /// Runs on any thread. Entities are only read, apart from each one's
    /// own node matrices, and no two batches share an entity.
    fn poseEntities(self: *Renderer, entities: []const Entity, scratch: []animation.Local) void {
        for (entities) |handle_value| {
            const entity = self.entities.get(handle_value).?;
            const model = self.models.get(entity.model).?;
            std.mem.swap([]Mat4, &entity.node_world, &entity.previous_node_world);
            animation.evaluate(&model.source.?, model.pose_order, entity.pose, scratch, entity.node_world);
            if (entity.history_frames == 0) @memcpy(entity.previous_node_world, entity.node_world);
        }
    }

    // -------------------------------------------------------------- picking

    /// Asks which entity is under `pixel` of a view (null for the main
    /// view), in that view's own pixel coordinates. The answer is read from
    /// the frame the GPU renders next and arrives through `takePick` a few
    /// frames later, so nothing waits on the GPU. A new request replaces
    /// one that has not been picked up by a frame yet. Blended (transparent)
    /// surfaces are not pickable.
    pub fn requestPick(self: *Renderer, view: ?View, pixel: [2]u32) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.pick_request = .{ .view = view orelse self.main_view, .pixel = pixel };
    }

    /// Returns the answer to a `requestPick` once, when it is ready.
    pub fn takePick(self: *Renderer) ?PickResult {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        defer self.pick_result = null;
        return self.pick_result;
    }

    /// Collects the answer the GPU wrote for a pick issued in this frame
    /// slot's previous use.
    fn resolvePick(self: *Renderer, slot: usize) void {
        const pending = self.pick_pending[slot] orelse return;
        self.pick_pending[slot] = null;
        const raw = self.device.mappedSlice(gpu.Pick, self.pick_readback[slot])[0];
        var result = PickResult{ .pixel = pending.pixel, .hit = null };
        defer self.pick_result = result;
        if (raw.instance == gpu.invalid_id) return;
        const scene = self.scenes.get(pending.scene) orelse return;
        if (scene.layout_version != pending.layout_version) return;
        if (raw.instance >= scene.layout.items.len) {
            // Past the entities: a copy in one of the instance groups.
            for (scene.groups.items) |group_handle| {
                const group = self.instance_groups.get(group_handle) orelse continue;
                if (group.per_copy == 0 or raw.instance < group.base) continue;
                const offset = raw.instance - group.base;
                if (offset >= group.transforms.len * group.per_copy) continue;
                result.hit = .{
                    .entity = .invalid,
                    .instances = group_handle,
                    .copy = offset / group.per_copy,
                    .mesh_instance = offset % group.per_copy,
                    .position = raw.position,
                    .distance = pending.near / @max(raw.depth, 1e-9),
                };
                return;
            }
            return;
        }
        const entry = scene.layout.items[raw.instance];
        result.hit = .{
            .entity = entry.entity,
            .mesh_instance = entry.model_instance,
            .position = raw.position,
            .distance = pending.near / @max(raw.depth, 1e-9),
        };
    }

    // --------------------------------------------------------------- scenes

    /// Creates an empty scene: no entities or lights, the sun off, no
    /// environment. Scenes are independent of one another and of views;
    /// a view draws one by naming it in `ViewDesc.scene`. Free it with
    /// `destroyScene`.
    pub fn createScene(self: *Renderer) !Scene {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.scenes.insert(.{});
    }

    /// Destroys the scene and every entity in it.
    pub fn destroyScene(self: *Renderer, scene: Scene) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var removed = self.scenes.remove(scene) orelse return;
        for (removed.entities.items) |entity| {
            const data = self.entities.remove(entity) orelse continue;
            if (self.models.get(data.model)) |model| model.references -= 1;
            self.freeEntityStorage(data);
        }
        self.freeScene(&removed);
    }

    fn freeScene(self: *Renderer, scene: *SceneData) void {
        scene.entities.deinit(self.gpa);
        scene.lights.deinit(self.gpa);
        for (scene.emitters.items) |emitter| if (self.emitters.remove(emitter)) |removed| {
            self.device.destroyBuffer(removed.buffer);
            if (removed.order) |order| self.device.destroyBuffer(order);
            if (removed.trail) |trail| self.device.destroyBuffer(trail);
        };
        scene.emitters.deinit(self.gpa);
        for (scene.probes.items) |probe| if (self.probes.remove(probe)) |removed_probe| {
            var removed = removed_probe;
            self.freeProbe(&removed);
        };
        scene.probes.deinit(self.gpa);
        for (scene.fluids.items) |fluid| if (self.fluids.remove(fluid)) |removed| {
            var state = removed;
            self.destroyFluidTextures(&state);
        };
        scene.fluids.deinit(self.gpa);
        for (scene.waters.items) |water| if (self.waters.remove(water)) |removed| {
            for (removed.state) |texture| self.device.destroyTexture(texture);
        };
        scene.waters.deinit(self.gpa);
        for (scene.liquids.items) |liquid| if (self.liquids.remove(liquid)) |removed_liquid| {
            var removed = removed_liquid;
            removed.deinit(self.device);
        };
        scene.liquids.deinit(self.gpa);
        if (scene.trace_nodes) |buffer| self.device.destroyBuffer(buffer);
        if (scene.trace_instances) |buffer| self.device.destroyBuffer(buffer);
        scene.decals.deinit(self.gpa);
        scene.movers.deinit(self.gpa);
        for (scene.groups.items) |group| if (self.instance_groups.remove(group)) |removed| {
            self.gpa.free(removed.transforms);
            self.gpa.free(removed.tints);
            self.gpa.free(removed.params);
            if (self.models.get(removed.model)) |model| model.references -= 1;
        };
        scene.groups.deinit(self.gpa);
        scene.static_tlas.deinit(self.gpa);
        for (scene.instance_slots) |slot| if (slot.buffer) |buffer| self.device.destroyBuffer(buffer);
        scene.transparent.deinit(self.gpa);
        scene.static_transparent.deinit(self.gpa);
        scene.layout.deinit(self.gpa);
        if (scene.refs) |buffer| self.device.destroyBuffer(buffer);
        if (scene.seen) |buffer| self.device.destroyBuffer(buffer);
        for (scene.seen_readback) |readback| if (readback) |buffer| self.device.destroyBuffer(buffer);
        if (scene.skin_bounds) |buffer| self.device.destroyBuffer(buffer);
        if (scene.tlas) |tlas| self.device.destroyAcceleration(tlas);
        if (scene.gi) |volume| volume.deinit(self.device);
        if (scene.gi_coarse) |volume| volume.deinit(self.device);
        if (scene.gi_middle) |volume| volume.deinit(self.device);
    }

    /// Replaces the scene's sun, taking effect from the next frame. An
    /// `intensity` of 0 turns it, and its shadows, off. A stale scene
    /// handle is ignored.
    pub fn setSun(self: *Renderer, scene: Scene, sun: Sun) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.scenes.get(scene)) |data| data.sun = sun;
    }

    /// Sets the HDR environment used for the sky and image-based lighting.
    pub fn setEnvironment(self: *Renderer, scene: Scene, environment: ?Environment, intensity: f32) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.scenes.get(scene)) |data| {
            data.environment = environment;
            data.environment_intensity = intensity;
        }
    }

    /// Replaces the scene's point and spot lights.
    pub fn setLights(self: *Renderer, scene: Scene, lights: []const Light) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const data = self.scenes.get(scene) orelse return error.InvalidScene;
        data.lights.clearRetainingCapacity();
        try data.lights.appendSlice(self.gpa, lights);
        data.lights_version += 1;
    }

    /// Adds an entity to a scene: one placement of `desc.model`. The model
    /// need not have finished loading; the entity is drawn from the frame
    /// it becomes ready. The entity holds a reference to the model (see
    /// `destroyModel`) until `despawn` or `destroyScene`.
    ///
    /// Fails with `error.InvalidScene` or `error.InvalidModel` for a
    /// stale handle. Safe from any thread.
    pub fn spawn(self: *Renderer, scene: Scene, desc: EntityDesc) !Entity {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const scene_data = self.scenes.get(scene) orelse return error.InvalidScene;
        const model = self.models.get(desc.model) orelse return error.InvalidModel;
        const entity = try self.entities.insert(.{
            .scene = scene,
            .model = desc.model,
            .transform = desc.transform,
            .previous_transform = desc.transform,
            .visible = desc.visible,
            .tint = packTint(desc.tint),
            .params = desc.params,
            .receive_decals = desc.receive_decals,
        });
        errdefer _ = self.entities.remove(entity);
        try scene_data.entities.append(self.gpa, entity);
        model.references += 1;
        scene_data.layout_dirty = true;
        return entity;
    }

    /// Removes an entity from its scene, frees its skinning storage and
    /// releases its reference to the model. The handle is stale
    /// afterwards; a stale handle is ignored.
    pub fn despawn(self: *Renderer, entity: Entity) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const data = self.entities.remove(entity) orelse return;
        if (self.scenes.get(data.scene)) |scene| {
            for (scene.entities.items, 0..) |candidate, index| if (@as(u32, @bitCast(candidate)) == @as(u32, @bitCast(entity))) {
                _ = scene.entities.orderedRemove(index);
                break;
            };
            scene.layout_dirty = true;
        }
        if (self.models.get(data.model)) |model| model.references -= 1;
        self.freeEntityStorage(data);
    }

    fn freeEntityStorage(self: *Renderer, entity: EntityData) void {
        if (self.models.get(entity.model)) |model| {
            if (model.source) |source| for (entity.skin_offsets, 0..) |offset, index| {
                if (offset == no_skin) continue;
                self.vertices.free(self, offset, model.meshes[source.instances[index].mesh].vertex_count * 2);
            };
        }
        self.gpa.free(entity.skin_offsets);
        for (entity.skin_blas) |blas| if (blas) |value| self.device.destroyAcceleration(value);
        self.gpa.free(entity.skin_blas);
        self.gpa.free(entity.bounds_offsets);
        self.gpa.free(entity.node_world);
        self.gpa.free(entity.previous_node_world);
    }

    /// Moves an entity: `transform` places the model's space in the world.
    /// The difference from last frame's transform counts as motion, for
    /// motion vectors, temporal antialiasing and motion blur; use
    /// `teleport` for a jump that should not. A stale handle is ignored.
    pub fn setTransform(self: *Renderer, entity: Entity, transform: Mat4) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.entities.get(entity)) |data| data.transform = transform;
    }

    /// Like `setTransform`, but also resets motion history so the move is
    /// not smeared by temporal antialiasing.
    pub fn teleport(self: *Renderer, entity: Entity, transform: Mat4) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.entities.get(entity)) |data| {
            data.transform = transform;
            data.previous_transform = transform;
        }
    }

    /// Changes the color an entity's materials are multiplied by.
    pub fn setTint(self: *Renderer, entity: Entity, tint: [3]f32) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.entities.get(entity)) |data| data.tint = packTint(tint);
    }

    /// Sets the numbers an entity hands to custom material shaders
    /// (`MaterialContext.instance_params`).
    pub fn setParams(self: *Renderer, entity: Entity, params: [4]f32) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.entities.get(entity)) |data| data.params = params;
    }

    /// Sets the weights of an entity's morph targets (blend shapes: facial
    /// expressions, muscle bulges) by hand, on every mesh of it that has
    /// any; up to 64, in the order the model lists them. Null hands them
    /// back to the animation. Only skinned meshes morph.
    pub fn setMorphWeights(self: *Renderer, entity: Entity, weights: ?[]const f32) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const data = self.entities.get(entity) orelse return;
        if (weights) |values| {
            var stored: [gltf.max_morph_targets]f32 = @splat(0);
            for (values[0..@min(values.len, stored.len)], 0..) |value, index| stored[index] = value;
            data.morph_weights = stored;
        } else data.morph_weights = null;
    }

    /// Shows or hides an entity without removing it. A hidden entity is
    /// left out of the scene's instance list, so it is not drawn and casts
    /// no shadows; showing it again starts its motion history afresh. A
    /// change rebuilds that list on the next frame, as `spawn` and
    /// `despawn` do; setting the value it already has costs nothing.
    pub fn setVisible(self: *Renderer, entity: Entity, visible: bool) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const data = self.entities.get(entity) orelse return;
        if (data.visible == visible) return;
        data.visible = visible;
        data.history_frames = 0;
        if (self.scenes.get(data.scene)) |scene| scene.layout_dirty = true;
    }

    /// Sets the animation pose. Null returns the model to its rest pose.
    pub fn setPose(self: *Renderer, entity: Entity, pose: ?Pose) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.entities.get(entity)) |data| data.pose = pose;
    }

    /// Allocates per-entity animation state the first time its model is seen
    /// ready.
    fn resolveEntity(self: *Renderer, entity: *EntityData, model: *ModelEntry) !void {
        if (entity.resolved) return;
        const source = &model.source.?;
        const gpa = self.gpa;
        if (source.skins.len != 0 or source.animations.len != 0) {
            entity.node_world = try gpa.dupe(Mat4, model.node_world);
            entity.previous_node_world = try gpa.dupe(Mat4, model.node_world);
        }
        entity.skin_offsets = try gpa.alloc(u32, source.instances.len);
        @memset(entity.skin_offsets, no_skin);
        entity.skin_blas = try gpa.alloc(?rhi.AccelerationStructure, source.instances.len);
        @memset(entity.skin_blas, null);
        entity.bounds_offsets = try gpa.alloc(u32, source.instances.len);
        @memset(entity.bounds_offsets, gpu.invalid_id);
        for (source.instances, entity.skin_offsets) |instance, *offset| {
            const mesh = model.meshes[instance.mesh];
            if (instance.skin == null or mesh.skin_offset == null) continue;
            offset.* = try self.vertices.alloc(self, mesh.vertex_count * 2);
        }
        entity.history_frames = 0;
        entity.resolved = true;
    }

    /// The entity whose pose a group's copies take, if it is being posed
    /// this frame: visible, of the group's model and in its scene.
    fn groupDriver(self: *Renderer, group: *const InstanceGroupData, model_instances: usize) ?*EntityData {
        const entity = self.entities.get(group.driver orelse return null) orelse return null;
        if (!entity.visible or !entity.resolved) return null;
        if (!std.meta.eql(entity.model, group.model) or !std.meta.eql(entity.scene, group.scene)) return null;
        if (entity.skin_offsets.len != model_instances) return null;
        return entity;
    }

    fn rebuildLayout(self: *Renderer, scene: *SceneData) !void {
        const zone = Zone.start(self.options.profiler, "rebuild layout");
        defer zone.stop();
        const gpa = self.gpa;
        scene.layout.clearRetainingCapacity();
        self.scratch_refs.clearRetainingCapacity();
        scene.joint_count = 0;
        scene.triangle_count = 0;
        for (scene.entities.items) |entity_handle| {
            const entity = self.entities.get(entity_handle) orelse continue;
            if (!entity.visible) continue;
            const model = self.models.get(entity.model) orelse continue;
            if (model.state != .ready or !model.geometry_resident) continue;
            try self.resolveEntity(entity, model);
            const source = &model.source.?;
            for (source.instances, 0..) |instance, index| {
                const mesh = model.meshes[instance.mesh];
                const instance_index: u32 = @intCast(scene.layout.items.len);
                try scene.layout.append(gpa, .{ .entity = entity_handle, .model_instance = @intCast(index), .first_of_entity = index == 0 });
                scene.triangle_count += mesh.lod0_index_count / 3;
                if (entity.skin_offsets[index] != no_skin) scene.joint_count += @intCast(source.skins[instance.skin.?].joints.len);
                // Blended meshes get references too: the culling pass keeps
                // them out of the camera's visibility buffer (they are drawn
                // by the transparent pass) but lets them cast shadows.
                // What only rays meet has no meshlets to draw.
                if (entity.rays_only) continue;
                try self.scratch_refs.ensureUnusedCapacity(gpa, mesh.meshlet_count);
                for (0..mesh.meshlet_count) |meshlet| self.scratch_refs.appendAssumeCapacity(.{
                    .instance = instance_index,
                    .meshlet = mesh.meshlet_offset + @as(u32, @intCast(meshlet)),
                });
            }
        }
        // Instance groups follow the entities in the instance numbering.
        scene.static_count = 0;
        for (scene.groups.items) |group_handle| {
            const group = self.instance_groups.get(group_handle) orelse continue;
            group.base = @as(u32, @intCast(scene.layout.items.len)) + scene.static_count;
            group.per_copy = 0;
            const model = self.models.get(group.model) orelse continue;
            if (model.state != .ready or !model.geometry_resident) continue;
            const source = &model.source.?;
            group.per_copy = @intCast(source.instances.len);
            for (0..group.transforms.len) |copy| {
                var slot: u32 = 0;
                for (source.instances) |instance| {
                    const mesh = model.meshes[instance.mesh];
                    const instance_index = group.base + @as(u32, @intCast(copy)) * group.per_copy + slot;
                    slot += 1;
                    // Blended meshes get references too, as for entities:
                    // kept out of the camera's visibility buffer, drawn by
                    // the transparent pass, and able to cast shadows.
                    scene.triangle_count += mesh.lod0_index_count / 3;
                    try self.scratch_refs.ensureUnusedCapacity(gpa, mesh.meshlet_count);
                    for (0..mesh.meshlet_count) |meshlet| self.scratch_refs.appendAssumeCapacity(.{
                        .instance = instance_index,
                        .meshlet = mesh.meshlet_offset + @as(u32, @intCast(meshlet)),
                    });
                }
            }
            scene.static_count += @as(u32, @intCast(group.transforms.len)) * group.per_copy;
        }
        scene.static_version += 1;
        const count: u32 = @intCast(self.scratch_refs.items.len);
        if (count > scene.refs_capacity) {
            if (scene.refs) |buffer| self.device.destroyBuffer(buffer);
            scene.refs_capacity = @max(count + count / 2, 4096);
            scene.refs = try self.device.createBuffer(.{
                .name = "meshlet refs",
                .size = @as(u64, scene.refs_capacity) * @sizeOf(gpu.MeshletRef),
                .usage = .{ .storage = true },
            });
        }
        if (count != 0) try self.device.uploadBuffer(scene.refs.?, 0, std.mem.sliceAsBytes(self.scratch_refs.items));
        scene.ref_count = count;
        scene.layout_dirty = false;
        scene.layout_version += 1;
        scene.layout_generation = self.asset_generation;
    }

    /// An instance whose material glows the same all over (`Glowing` in
    /// pathtrace.frag): which instance, and how many triangles its
    /// full-detail level has to pick a point among.
    const Glowing = extern struct { instance: u32, triangles: u32 };
    /// Most glowing instances path tracing aims at; any more are found
    /// by chance only, as all were before.
    const max_glowing = 1024;

    /// Writes this frame's instance records and joint matrices and queues
    /// the skinning jobs.
    fn prepareScene(self: *Renderer, scene: *SceneData, arena: *FrameArena, slot: usize) !SceneFrame {
        const zone = Zone.start(self.options.profiler, "prepare scene");
        defer zone.stop();
        const device = self.device;
        if (scene.layout_dirty or scene.layout_generation != self.asset_generation) try self.rebuildLayout(scene);
        // Instance records live in GPU memory, which shaders read far
        // faster than memory the CPU can also see. Entities are written to
        // the frame arena and copied across every frame; instance groups
        // are uploaded only when they change.
        const entity_count = scene.layout.items.len;
        const total = entity_count + scene.static_count;
        const records = &scene.instance_slots[0];
        _ = slot;
        if (records.buffer == null or records.capacity < total) {
            if (records.buffer) |old| device.destroyBuffer(old);
            records.buffer = null;
            records.capacity = @intCast(@max(total + total / 2, 64));
            records.buffer = try device.createBuffer(.{
                .name = "instances",
                .size = @as(u64, records.capacity) * @sizeOf(gpu.Instance),
                .usage = .{ .storage = true, .copy_dst = true },
            });
            records.static_version = std.math.maxInt(u64);
        }
        const staged = try arena.alloc(device, gpu.Instance, entity_count);
        const instance_records = staged.items;
        const group_rays = device.ray_tracing and scene.static_count != 0 and scene.static_count <= self.options.gi_instance_limit;
        const tlas_instances = try arena.alloc(device, rhi.AccelerationInstance, scene.layout.items.len + (if (group_rays) scene.static_count else 0));
        var tlas_count: u32 = 0;
        var tlas_hasher = std.hash.Wyhash.init(0);
        var bounds = [2]Vec3{ @splat(std.math.inf(f32)), @splat(-std.math.inf(f32)) };
        const joints = try arena.alloc(device, Mat4, scene.joint_count);
        self.skin_jobs.clearRetainingCapacity();
        self.skin_weights.clearRetainingCapacity();
        self.bounds_jobs.clearRetainingCapacity();
        var bounds_cursor: u32 = 0;
        self.blas_jobs.clearRetainingCapacity();
        const parity: u32 = @intCast(self.frame_index & 1);
        var joint_cursor: u32 = 0;
        var shared_skin_entity: u32 = std.math.maxInt(u32);
        var shared_skin: u32 = 0;
        var shared_joints: u32 = 0;
        var shared_center: Vec3 = .{ 0, 0, 0 };
        var shared_radius: f32 = 0;
        var skinned_vertices: u32 = 0;
        // Whether anything in the scene is in a different place than last
        // frame, which is what forces shadow maps to be redrawn.
        var any_moving = false;

        try self.evaluatePoses(scene);
        scene.movers.clearRetainingCapacity();
        scene.movers_overflow = false;
        scene.transparent.clearRetainingCapacity();
        scene.transmissive = false;

        const glowing = try arena.alloc(device, Glowing, max_glowing);
        var glowing_count: u32 = 0;
        for (scene.layout.items, instance_records, 0..) |entry, *out, instance_index| {
            const entity = self.entities.get(entry.entity).?;
            const model = self.models.get(entity.model).?;
            const source = &model.source.?;
            const node_world = if (entity.node_world.len != 0) entity.node_world else model.node_world;
            const previous_node_world = if (entity.node_world.len != 0) entity.previous_node_world else model.node_world;
            const instance = source.instances[entry.model_instance];
            const mesh = model.meshes[instance.mesh];
            const skin_base = entity.skin_offsets[entry.model_instance];
            // Blended meshes are drawn by the forward pass; remember where
            // they ended up once this instance's transform is known.
            var aimed = false;
            {
                // Path tracing aims at what glows evenly; a glow painted
                // by a texture is left to chance, which finds its bright
                // parts where aiming at any triangle would not.
                const glow = source.materials[source.meshes[instance.mesh].material];
                if (glow.emissive_texture == null and (glow.emissive[0] > 0 or glow.emissive[1] > 0 or glow.emissive[2] > 0) and mesh.lod0_index_count >= 3 and !mesh.coarse and glowing_count < max_glowing) {
                    glowing.items[glowing_count] = .{ .instance = @intCast(instance_index), .triangles = mesh.lod0_index_count / 3 };
                    glowing_count += 1;
                    aimed = true;
                }
            }
            defer if (mesh.blend and !entity.rays_only) {
                if (source.materials[source.meshes[instance.mesh].material].transmission > 0) scene.transmissive = true;
                scene.transparent.append(self.gpa, .{
                    .instance = @intCast(instance_index),
                    .first_index = mesh.index_offset,
                    .index_count = mesh.lod0_index_count,
                    .center = math.transformPoint(out.transform, source.meshes[instance.mesh].bounds_center),
                    .transmissive = source.materials[source.meshes[instance.mesh].material].transmission > 0,
                }) catch {};
            };

            if (skin_base == no_skin) {
                const transform = math.mul(entity.transform, node_world[instance.node]);
                const previous_transform = math.mul(entity.previous_transform, previous_node_world[instance.node]);
                if (!std.mem.eql(f32, &transform, &previous_transform)) {
                    any_moving = true;
                    const bounds_of = source.meshes[instance.mesh];
                    const moved_center = math.transformPoint(transform, bounds_of.bounds_center);
                    self.noteMover(scene, .{ moved_center[0], moved_center[1], moved_center[2], bounds_of.bounds_radius * math.maxScale(transform) });
                }
                out.* = .{
                    .transform = transform,
                    .previous_transform = previous_transform,
                    .bounding_sphere = .{ 0, 0, 0, 0 },
                    .mesh = model.mesh_base + instance.mesh,
                    .material = mesh.material,
                    .vertex_offset = mesh.vertex_offset,
                    .previous_vertex_offset = mesh.vertex_offset,
                    .coarse_error = if (mesh.coarse) mesh.coarse_error else 0,
                    // Lets the resolve pass skip previous-frame fetches.
                    .flags = (if (std.mem.eql(f32, &transform, &previous_transform)) 0 else gpu.instance_moving) | (if (entity.receive_decals) 0 else gpu.instance_no_decals) | (if (entity.rays_only) gpu.instance_proxy else 0) | (if (aimed) gpu.instance_aimed else 0),
                    .tint = entity.tint,
                    .params = entity.params,
                };
                if (mesh.blas != null) {
                    const center = math.transformPoint(transform, source.meshes[instance.mesh].bounds_center);
                    const radius = source.meshes[instance.mesh].bounds_radius * math.maxScale(transform);
                    inline for (0..3) |axis| {
                        bounds[0][axis] = @min(bounds[0][axis], center[axis] - radius);
                        bounds[1][axis] = @max(bounds[1][axis], center[axis] + radius);
                    }
                    const tlas_instance = rhi.AccelerationInstance{
                        // Row-major 3x4 from a column-major 4x4.
                        .transform = .{
                            transform[0], transform[4], transform[8],  transform[12],
                            transform[1], transform[5], transform[9],  transform[13],
                            transform[2], transform[6], transform[10], transform[14],
                        },
                        // See-through meshes are in the structure for rays
                        // that draw a picture only; probes and shadows
                        // look for the first of the two mask bits.
                        .custom_index_and_mask = (@as(u32, @intCast(instance_index)) & 0x00ff_ffff) | (if (mesh.blend) @as(u32, 0x0200_0000) else 0xff00_0000),
                        // Disable facing-based culling: probes need hits from both sides.
                        .offset_and_flags = 0x0100_0000,
                        .blas = device.accelerationAddress(mesh.blas.?),
                    };
                    // Hash the local copy: the arena is write-combined memory
                    // and must never be read back.
                    tlas_hasher.update(std.mem.asBytes(&tlas_instance));
                    tlas_instances.items[tlas_count] = tlas_instance;
                    tlas_count += 1;
                }
                continue;
            }

            // Skinned: joint matrices are in model space, so the mesh node's
            // own transform drops out and only the entity transform remains.
            const skin = source.skins[instance.skin.?];
            // The meshes of one entity that share a skin share its joint
            // matrices and the bounds worked out from them.
            if (shared_skin_entity != entry.entity.index or shared_skin != instance.skin.?) {
                shared_skin_entity = entry.entity.index;
                shared_skin = instance.skin.?;
                shared_joints = joint_cursor;
                var minimum: Vec3 = @splat(std.math.inf(f32));
                var model_minimum: Vec3 = @splat(std.math.inf(f32));
                var model_maximum: Vec3 = @splat(-std.math.inf(f32));
                var maximum: Vec3 = @splat(-std.math.inf(f32));
                for (skin.joints, skin.inverse_bind, 0..) |joint, inverse_bind, index| {
                    joints.items[joint_cursor + index] = math.mul(node_world[joint], inverse_bind);
                    const position = math.transformPoint(entity.transform, node_world[joint][12..15].*);
                    inline for (0..3) |axis| {
                        model_minimum[axis] = @min(model_minimum[axis], node_world[joint][12 + axis]);
                        model_maximum[axis] = @max(model_maximum[axis], node_world[joint][12 + axis]);
                    }
                    inline for (0..3) |axis| {
                        minimum[axis] = @min(minimum[axis], position[axis]);
                        maximum[axis] = @max(maximum[axis], position[axis]);
                    }
                }
                joint_cursor += @intCast(skin.joints.len);
                shared_center = math.scale(math.add(minimum, maximum), 0.5);
                shared_radius = math.length(math.sub(maximum, minimum)) * 0.5;
                const model_center = math.scale(math.add(model_minimum, model_maximum), 0.5);
                entity.skin_bounds = .{ model_center[0], model_center[1], model_center[2], math.length(math.sub(model_maximum, model_minimum)) * 0.5 + model.info.bounds_radius * 0.25 };
            }
            const center = shared_center;
            const padding = model.info.bounds_radius * 0.25 * math.maxScale(entity.transform);
            self.noteMover(scene, .{ center[0], center[1], center[2], shared_radius + padding });
            const current = skin_base + parity * mesh.vertex_count;
            // Meshlet bounds of the deformed mesh, taken after skinning.
            const own_bounds = self.options.skinned_meshlet_bounds and mesh.meshlet_count != 0;
            const previous = skin_base + (1 - parity) * mesh.vertex_count;
            any_moving = true;
            out.* = .{
                .transform = entity.transform,
                .previous_transform = entity.previous_transform,
                .bounding_sphere = .{ center[0], center[1], center[2], shared_radius + padding },
                .mesh = model.mesh_base + instance.mesh,
                .material = mesh.material,
                .vertex_offset = current,
                .previous_vertex_offset = if (entity.history_frames != 0) previous else current,
                .flags = gpu.instance_skinned | gpu.instance_moving,
                .bounds_offset = if (own_bounds) bounds_cursor else gpu.invalid_id,
            };
            // Morph targets: the weights the clip gives this node, else the
            // mesh's own, unless the entity was given weights by hand.
            var morph_weights = source.meshes[instance.mesh].morph_weights;
            if (mesh.morph_targets != 0) {
                if (entity.pose) |pose| animation.poseWeights(source, pose, instance.node, morph_weights[0..mesh.morph_targets]);
                if (entity.morph_weights) |override| morph_weights = override;
            }
            entity.bounds_offsets[entry.model_instance] = gpu.invalid_id;
            if (own_bounds) {
                entity.bounds_offsets[entry.model_instance] = bounds_cursor;
                try self.bounds_jobs.append(self.gpa, .{ .vertex_offset = current, .meshlet_offset = mesh.meshlet_offset, .meshlet_count = mesh.meshlet_count, .bounds_offset = bounds_cursor });
                bounds_cursor += mesh.meshlet_count;
            }
            const weights_offset: u32 = @intCast(self.skin_weights.items.len);
            try self.skin_weights.appendSlice(self.gpa, morph_weights[0..mesh.morph_targets]);
            try self.skin_jobs.append(self.gpa, .{
                .source_offset = mesh.vertex_offset,
                .destination_offset = current,
                .skin_offset = mesh.skin_offset.?,
                .joint_offset = shared_joints,
                .vertex_count = mesh.vertex_count,
                .morph_offset = mesh.morph_offset orelse 0,
                .target_count = mesh.morph_targets,
                .weights_offset = weights_offset,
            });
            if (self.options.gi_dynamic_geometry and device.ray_tracing and !mesh.blend) {
                // The deformed vertices are in world space up to the
                // entity's transform, like the instance record says.
                var dynamic_desc = geometry_passes.blasDesc(self, mesh);
                dynamic_desc.vertex_offset = @as(u64, current) * @sizeOf(gpu.Vertex);
                dynamic_desc.dynamic = true;
                const slot_blas = &entity.skin_blas[entry.model_instance];
                if (slot_blas.* == null) slot_blas.* = try device.createBlas(dynamic_desc);
                try self.blas_jobs.append(self.gpa, .{ .blas = slot_blas.*.?, .vertex_offset = current, .mesh = mesh });
                const t = entity.transform;
                const tlas_instance = rhi.AccelerationInstance{
                    .transform = .{ t[0], t[4], t[8], t[12], t[1], t[5], t[9], t[13], t[2], t[6], t[10], t[14] },
                    .custom_index_and_mask = (@as(u32, @intCast(instance_index)) & 0x00ff_ffff) | 0xff00_0000,
                    .offset_and_flags = 0x0100_0000,
                    .blas = device.accelerationAddress(slot_blas.*.?),
                };
                tlas_hasher.update(std.mem.asBytes(&tlas_instance));
                // The shape changes even when the record does not.
                tlas_hasher.update(std.mem.asBytes(&self.frame_index));
                tlas_instances.items[tlas_count] = tlas_instance;
                tlas_count += 1;
            }
            skinned_vertices += mesh.vertex_count;
        }

        if (bounds_cursor > scene.skin_bounds_capacity) {
            if (scene.skin_bounds) |buffer| device.destroyBuffer(buffer);
            scene.skin_bounds = null;
            scene.skin_bounds_capacity = bounds_cursor + bounds_cursor / 2;
            scene.skin_bounds = try device.createBuffer(.{
                .name = "skinned meshlet bounds",
                .size = @as(u64, scene.skin_bounds_capacity) * 16,
                .usage = .{ .storage = true },
            });
        }

        // Groups that follow an entity's pose are rewritten every frame:
        // the deformed vertices they point at swap places each frame.
        var driven = false;
        for (scene.groups.items) |group_handle| {
            const group = self.instance_groups.get(group_handle) orelse continue;
            if (group.driver != null) driven = true;
        }
        if (driven or records.static_version != scene.static_version or records.entity_count != entity_count) {
            self.scratch_instances.clearRetainingCapacity();
            scene.static_transparent.clearRetainingCapacity();
            scene.static_transmissive = false;
            try self.scratch_instances.ensureTotalCapacity(self.gpa, scene.static_count);
            for (scene.groups.items) |group_handle| {
                const group = self.instance_groups.get(group_handle) orelse continue;
                if (group.per_copy == 0) continue;
                const model = self.models.get(group.model) orelse continue;
                const source = &model.source.?;
                // The entity whose pose the copies take, if it is being
                // posed this frame.
                const driver = self.groupDriver(group, source.instances.len);
                for (group.transforms, 0..) |placement, copy_index| {
                    const tint: u32 = if (group.tints.len == group.transforms.len) group.tints[copy_index] else 0xffffffff;
                    const params: [4]f32 = if (group.params.len == group.transforms.len) group.params[copy_index] else .{ 0, 0, 0, 0 };
                    var noted = false;
                    for (source.instances, 0..) |instance, model_instance| {
                        const mesh = model.meshes[instance.mesh];
                        var record = gpu.Instance{
                            .transform = math.mul(placement, model.node_world[instance.node]),
                            .previous_transform = undefined,
                            .bounding_sphere = .{ 0, 0, 0, 0 },
                            .mesh = model.mesh_base + instance.mesh,
                            .material = mesh.material,
                            .vertex_offset = mesh.vertex_offset,
                            .previous_vertex_offset = mesh.vertex_offset,
                            .coarse_error = if (mesh.coarse) mesh.coarse_error else 0,
                            .flags = 0,
                            .tint = tint,
                            .params = params,
                        };
                        var center = math.transformPoint(record.transform, source.meshes[instance.mesh].bounds_center);
                        const skin_base = if (driver) |entity| entity.skin_offsets[model_instance] else no_skin;
                        if (skin_base != no_skin) {
                            // Deformed vertices are in model space: only the
                            // copy's own placement applies.
                            const entity = driver.?;
                            const current = skin_base + parity * mesh.vertex_count;
                            center = math.transformPoint(placement, entity.skin_bounds[0..3].*);
                            const radius = entity.skin_bounds[3] * math.maxScale(placement);
                            record.transform = placement;
                            record.bounding_sphere = .{ center[0], center[1], center[2], radius };
                            record.vertex_offset = current;
                            record.previous_vertex_offset = if (entity.history_frames != 0) skin_base + (1 - parity) * mesh.vertex_count else current;
                            record.flags = gpu.instance_skinned | gpu.instance_moving;
                            // The bounds are in model space too, so the
                            // copies share the entity's.
                            record.bounds_offset = entity.bounds_offsets[model_instance];
                            any_moving = true;
                            if (!noted) self.noteMover(scene, record.bounding_sphere);
                            noted = true;
                        }
                        record.previous_transform = record.transform;
                        if (mesh.blend) {
                            // Drawn by the forward pass, back to front.
                            if (source.materials[source.meshes[instance.mesh].material].transmission > 0) scene.static_transmissive = true;
                            try scene.static_transparent.append(self.gpa, .{
                                .instance = @intCast(entity_count + self.scratch_instances.items.len),
                                .first_index = mesh.index_offset,
                                .index_count = mesh.lod0_index_count,
                                .center = center,
                                .transmissive = source.materials[source.meshes[instance.mesh].material].transmission > 0,
                            });
                        }
                        self.scratch_instances.appendAssumeCapacity(record);
                    }
                }
            }
            if (self.scratch_instances.items.len != 0) try device.uploadBuffer(
                records.buffer.?,
                @as(u64, entity_count) * @sizeOf(gpu.Instance),
                std.mem.sliceAsBytes(self.scratch_instances.items),
            );
            records.static_version = scene.static_version;
            records.entity_count = entity_count;
        }
        if (scene.static_transmissive) scene.transmissive = true;
        try scene.transparent.appendSlice(self.gpa, scene.static_transparent.items);
        // Instance groups in the ray-tracing structure: their entries are
        // worked out once per change of the groups and copied in each
        // frame. Past the limit they are left out, as before.
        if (group_rays) {
            if (driven or scene.static_tlas_version != scene.static_version or scene.static_tlas_base != entity_count) {
                scene.static_tlas.clearRetainingCapacity();
                var record: u32 = @intCast(entity_count);
                for (scene.groups.items) |group_handle| {
                    const group = self.instance_groups.get(group_handle) orelse continue;
                    if (group.per_copy == 0) continue;
                    const model = self.models.get(group.model) orelse continue;
                    const source = &model.source.?;
                    const driver = self.groupDriver(group, source.instances.len);
                    for (group.transforms) |placement| {
                        for (source.instances, 0..) |instance, model_instance| {
                            const mesh = model.meshes[instance.mesh];
                            // Counted in step with the instance records above.
                            defer record += 1;
                            if (mesh.blend) continue;
                            // A copy that follows an entity's pose shares
                            // that entity's deformed structure, which is in
                            // model space.
                            const posed: ?rhi.AccelerationStructure = if (driver) |entity| (if (entity.skin_offsets[model_instance] != no_skin and model_instance < entity.skin_blas.len) entity.skin_blas[model_instance] else null) else null;
                            const blas = posed orelse mesh.blas orelse continue;
                            const t = if (posed != null) placement else math.mul(placement, model.node_world[instance.node]);
                            try scene.static_tlas.append(self.gpa, .{
                                .transform = .{ t[0], t[4], t[8], t[12], t[1], t[5], t[9], t[13], t[2], t[6], t[10], t[14] },
                                .custom_index_and_mask = (record & 0x00ff_ffff) | 0xff00_0000,
                                .offset_and_flags = 0x0100_0000,
                                .blas = device.accelerationAddress(blas),
                            });
                        }
                    }
                }
                scene.static_tlas_version = scene.static_version;
                scene.static_tlas_base = entity_count;
            }
            @memcpy(tlas_instances.items[tlas_count..][0..scene.static_tlas.items.len], scene.static_tlas.items);
            tlas_count += @intCast(scene.static_tlas.items.len);
            tlas_hasher.update(std.mem.asBytes(&scene.static_version));
            // Posed copies change shape even when nothing else does.
            if (driven) tlas_hasher.update(std.mem.asBytes(&self.frame_index));
        }

        // Everything drawn this frame becomes next frame's history.
        for (scene.layout.items) |entry| {
            if (!entry.first_of_entity) continue;
            const entity = self.entities.get(entry.entity).?;
            // How far it travelled this frame, for the water it moves through.
            entity.travelled = math.length(math.sub(entity.transform[12..15].*, entity.previous_transform[12..15].*));
            entity.previous_transform = entity.transform;
            entity.history_frames +|= 1;
        }
        // Without the GPU's ray tracing, path tracing walks a tree over
        // the scene's instances, kept up while a view asks for it.
        if (scene.trace_wanted and !device.ray_tracing and self.options.path_tracing_fallback) {
            scene.trace_wanted = false;
            try self.buildSceneTree(scene, instance_records);
        }
        return .{
            .instances = device.bufferAddress(records.buffer.?),
            .staged_buffer = staged.buffer,
            .staged_instances = staged.offset,
            .staged_size = @as(u64, entity_count) * @sizeOf(gpu.Instance),
            .joints = joints.address,
            .skinned_vertices = skinned_vertices,
            .any_moving = any_moving,
            .tlas_instances = tlas_instances.address,
            .tlas_count = tlas_count,
            .tlas_hash = tlas_hasher.final() +% tlas_count,
            .glowing = glowing.address,
            .glowing_count = glowing_count,
            .bounds = bounds,
        };
    }

    // ---------------------------------------------------------------- frame

    /// Renders one frame. Returns false when the frame was skipped because
    /// the window has no drawable surface right now.
    ///
    /// Call from one thread at a time. Other threads may keep using the
    /// renderer meanwhile: the lock is held only while the frame is being
    /// recorded, not while waiting for the GPU or the display.
    pub fn render(self: *Renderer, desc: FrameDesc) !bool {
        const device = self.device;
        var failure: ?anyerror = null;
        try device.waitForFrame();
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (!try device.prepareSurface()) return false;
        }
        if (!try device.acquireImage()) return false;
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            const cpu_start = std.Io.Clock.Timestamp.now(self.io, .awake);
            const frame = try device.startFrame();
            self.renderFrame(frame, desc) catch |err| {
                // What was recorded before the failure has already changed
                // what the renderer knows about GPU state (uploads, texture
                // states, acceleration structures), so the partial frame
                // is still submitted; only the picture is lost.
                failure = err;
                device.closeFailedFrame();
                for (self.frame_targets[0..self.frame_target_count]) |target| {
                    const is_backbuffer = if (frame.backbuffer) |backbuffer| std.meta.eql(backbuffer, target) else false;
                    if (!is_backbuffer) frame.cmd.transition(target, .shader_read);
                }
                if (frame.backbuffer) |backbuffer| if (!self.targetWritten(backbuffer)) {
                    if (frame.cmd.beginRendering(.{ .color = &.{.{ .texture = backbuffer, .load = .clear, .clear = .{ 0, 0, 0, 1 } }} })) |_|
                        frame.cmd.endRendering()
                    else |_| {}
                };
            };
            try device.submitFrame();
            self.stats.cpu_ms = @as(f32, @floatFromInt(cpu_start.untilNow(self.io).raw.nanoseconds)) / 1e6;
            self.frame_index += 1;
            self.time += desc.delta_time;
        }
        try device.presentFrame();
        if (failure) |err| return err;
        return true;
    }

    fn renderFrame(self: *Renderer, frame: rhi.Frame, desc: FrameDesc) !void {
        const frame_zone = Zone.start(self.options.profiler, "render frame");
        defer frame_zone.stop();
        const cmd = frame.cmd;
        const arena = &self.arenas[@intCast(frame.index % rhi.frames_in_flight)];
        self.stats.draw_list_triangles = 0;
        self.stats.path_traced_frames = 0;
        self.stats.views = @intCast(desc.views.len);
        arena.reset(self.device);
        self.frame_target_count = 0;
        self.frame_scene_views = 0;
        self.resolvePick(@intCast(frame.index % rhi.frames_in_flight));

        cmd.beginScope("streaming");
        _ = try self.pumpAssets(cmd, stream_budget_bytes);
        try self.updateTextureStreaming(frame, desc);
        try self.updateGeometryStreaming(desc);
        if (self.skies_dirty) {
            self.skies_dirty = false;
            for (self.environments.slots.items) |*slot| if (slot.value) |*entry| {
                if (entry.sky_desc == null) {
                    if (entry.sky_dirty) try self.bakeLoadedClouds(entry, cmd);
                } else if (entry.sky_dirty or entry.bake_step != 0) try self.bakeSky(entry, cmd, false);
            };
        }
        try cmd.flushUploads();
        // Gaps left in the geometry pools are closed a mesh at a time,
        // which may move a pool to a smaller buffer: that move is
        // flushed here too, before anything reads the pool.
        if (try self.compactGeometry(cmd)) try cmd.flushUploads();
        try self.buildPendingBlas(cmd);
        cmd.endScope();

        for (desc.views) |view_desc| try self.renderView(frame, view_desc, desc.delta_time, arena);
        // Reflection probes are photographed after the frame's own views,
        // so they disturb nothing those rely on, and serve from the next.
        try self.captureProbes(frame, desc.delta_time, arena);
        // A frame with no view for the window still has to present something.
        if (frame.backbuffer) |backbuffer| if (!self.targetWritten(backbuffer)) {
            try cmd.beginRendering(.{ .color = &.{.{ .texture = backbuffer, .load = .clear, .clear = .{ 0, 0, 0, 1 } }} });
            cmd.endRendering();
        };
    }

    /// The quality level this renderer's GPU can be expected to hold; see
    /// `Quality.recommended`. Safe from any thread.
    pub fn recommendedQuality(self: *const Renderer) Quality {
        return Quality.recommended(self.device.adapterInfo());
    }

    /// True when the window surface is HDR10 (`Options.hdr_output` was set
    /// and the display supports it).
    pub fn hdrActive(self: *Renderer) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.device.hdr_active;
    }

    fn targetWritten(self: *const Renderer, target: rhi.Texture) bool {
        for (self.frame_targets[0..self.frame_target_count]) |written| if (std.meta.eql(written, target)) return true;
        return false;
    }

    fn renderView(self: *Renderer, frame: rhi.Frame, desc: ViewDesc, delta_time: f32, arena: *FrameArena) !void {
        const view_zone = Zone.start(self.options.profiler, "render view");
        defer view_zone.stop();
        const device = self.device;
        const cmd = frame.cmd;
        const target = switch (desc.target) {
            .backbuffer => frame.backbuffer orelse return error.NoSurface,
            .texture => |texture| texture,
        };
        const info = device.textureInfo(target);
        const region = desc.region orelse Region{ .x = 0, .y = 0, .width = info.width, .height = info.height };
        if (region.width == 0 or region.height == 0 or
            @as(u64, region.x) + region.width > info.width or @as(u64, region.y) + region.height > info.height)
            return error.InvalidRegion;
        const whole = region.width == info.width and region.height == info.height;
        const written = self.targetWritten(target);
        if (!written) {
            if (self.frame_target_count == self.frame_targets.len) return error.TooManyTargets;
            self.frame_targets[self.frame_target_count] = target;
            self.frame_target_count += 1;
        }
        const load: rhi.LoadOp = if (written) .load else .clear;

        if (desc.scene) |scene_handle| {
            const scene = self.scenes.get(scene_handle) orelse return error.InvalidScene;
            const view = self.views.get(desc.view orelse self.main_view) orelse return error.InvalidView;
            if (view.last_frame == self.frame_index) return error.ViewUsedTwice;
            // A view that covers its target tone-maps straight into it. One
            // that covers a part goes through a texture of its own size, so
            // its passes never deal with offsets.
            var color = target;
            if (!whole) {
                if (view.output) |texture| {
                    const current = device.textureInfo(texture);
                    if (current.width != region.width or current.height != region.height or view.output_format != info.format) {
                        device.destroyTexture(texture);
                        view.output = null;
                    }
                }
                if (view.output == null) {
                    view.output = try device.createTexture(.{
                        .name = "view output",
                        .width = region.width,
                        .height = region.height,
                        .format = info.format,
                        .usage = .{ .sampled = true, .color_attachment = true },
                    });
                    view.output_format = info.format;
                }
                color = view.output.?;
            }
            // The scene may be rendered at a fraction (or a multiple) of
            // the size it is shown at.
            const render_scale = std.math.clamp(desc.settings.render_scale, 0.25, 2);
            const internal_width: u32 = @max(@as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(region.width)) * render_scale))), 1);
            const internal_height: u32 = @max(@as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(region.height)) * render_scale))), 1);
            const frame_address = try self.renderScene(frame, desc, scene_handle, scene, view, color, info.format, internal_width, internal_height, region.width, region.height, delta_time, arena);
            try self.renderDrawLists(cmd, desc, .{
                .texture = color,
                .format = info.format,
                .region = .{ .x = 0, .y = 0, .width = region.width, .height = region.height },
                .load = .load,
                .clear = desc.clear_color,
                .depth = view.state.?.depth,
            }, arena);
            if (!whole) {
                cmd.beginScope("view composite");
                cmd.transition(color, .shader_read);
                try cmd.beginRendering(.{ .color = &.{.{ .texture = target, .load = load, .clear = desc.clear_color }} });
                cmd.setViewport(region.x, region.y, region.width, region.height);
                cmd.bindPipeline(try post_passes.tonemapPipeline(self, info.format));
                cmd.pushConstants(post_passes.TonemapPush{
                    .frame = frame_address,
                    .color = device.textureIndex(color),
                    .bloom = gpu.invalid_id,
                    .bloom_strength = 0,
                    // Already encoded for this format; copy as is.
                    .encode_srgb = 0,
                    .sharpen = 0,
                    .bloom_scale = 0,
                    .passthrough = 1,
                    .origin = .{ @intCast(region.x), @intCast(region.y) },
                });
                cmd.drawFullscreen();
                cmd.endRendering();
                cmd.endScope();
            }
        } else {
            try self.renderDrawLists(cmd, desc, .{
                .texture = target,
                .format = info.format,
                .region = region,
                .load = load,
                .clear = desc.clear_color,
            }, arena);
        }
        if (desc.target == .texture) cmd.transition(target, .shader_read);
    }

    /// Draws the 2D/3D draw lists over the finished scene (or over a cleared
    /// target when there is no scene).
    fn renderDrawLists(self: *Renderer, cmd: *rhi.CommandEncoder, desc: ViewDesc, output: Output, arena: *FrameArena) !void {
        const zone = Zone.start(self.options.profiler, "draw lists");
        defer zone.stop();
        const device = self.device;
        const region = output.region;
        var any_world = false;
        var any_screen = false;
        for (desc.draw_lists) |list| {
            any_world = any_world or list.world.indices.items.len != 0;
            any_screen = any_screen or list.screen.indices.items.len != 0;
        }
        var load = output.load;
        if (!any_world and !any_screen) {
            if (load != .clear) return;
            try cmd.beginRendering(.{ .color = &.{.{ .texture = output.texture, .load = .clear, .clear = output.clear }} });
            cmd.endRendering();
            return;
        }

        cmd.beginScope("draw lists");
        defer cmd.endScope();
        const pipelines = try self.drawPipelines(output.format);
        const width: f32 = @floatFromInt(region.width);
        const height: f32 = @floatFromInt(region.height);
        const Push = extern struct {
            vertices: u64,
            indices: u64,
            transform: Mat4,
            camera_right: Vec3,
            encode_srgb: u32,
            camera_up: Vec3,
            sdf_spread: f32,
            viewport: [2]f32,
            sampler_linear: u32,
            sampler_nearest: u32,
            /// Scene depth to test against, or `invalid_id`; and where
            /// the view starts in the target.
            depth_texture: u32,
            /// HDR10 targets: brightness of white in nits.
            hdr_paper_white: f32,
            origin: [2]f32,
            /// 1 to read text from the three-channel field, which keeps
            /// the corners of glyphs sharp at large sizes.
            sharp_text: u32,
            pad: u32 = 0,
        };
        var push = Push{
            .vertices = 0,
            .indices = 0,
            .transform = math.identity,
            .camera_right = .{ 1, 0, 0 },
            .encode_srgb = post_passes.outputEncoding(self, desc, output.format),
            .camera_up = .{ 0, 1, 0 },
            .sdf_spread = font_module.sdf_spread,
            .viewport = .{ width, height },
            .sampler_linear = device.samplerIndex(self.sampler_linear_clamp),
            .sampler_nearest = device.samplerIndex(self.sampler_nearest_clamp),
            .depth_texture = gpu.invalid_id,
            .hdr_paper_white = @max(desc.settings.hdr_paper_white, 1),
            .origin = .{ @floatFromInt(region.x), @floatFromInt(region.y) },
            .sharp_text = @intFromBool(desc.settings.sharp_text),
        };

        if (any_world) {
            const view_matrix = math.lookTo(desc.camera.position, desc.camera.forward, desc.camera.up);
            const inv_view = math.inverse(view_matrix);
            push.transform = math.mul(math.perspective(desc.camera.fov_y, width / height, desc.camera.near), view_matrix);
            push.camera_right = inv_view[0..3].*;
            push.camera_up = inv_view[4..7].*;
            // World-space items are depth-tested against the scene.
            try cmd.beginRendering(.{ .color = &.{.{ .texture = output.texture, .load = load, .clear = output.clear }} });
            cmd.setViewport(region.x, region.y, region.width, region.height);
            load = .load;
            // World-space items are tested against the scene's depth in
            // the shader, so the scene may be at another resolution.
            push.depth_texture = if (output.depth) |texture| device.textureIndex(texture) else gpu.invalid_id;
            cmd.bindPipeline(pipelines.flat);
            for (desc.draw_lists) |list| try self.drawBatch(cmd, arena, &list.world, &push, region);
            cmd.endRendering();
        }
        if (any_screen) {
            push.transform = .{
                2 / width, 0,          0, 0,
                0,         2 / height, 0, 0,
                0,         0,          1, 0,
                -1,        -1,         0, 1,
            };
            // Screen-space items are never hidden by the scene.
            push.depth_texture = gpu.invalid_id;
            push.camera_right = .{ 0, 0, 0 };
            push.camera_up = .{ 0, 0, 0 };
            try cmd.beginRendering(.{ .color = &.{.{ .texture = output.texture, .load = load, .clear = output.clear }} });
            cmd.setViewport(region.x, region.y, region.width, region.height);
            cmd.bindPipeline(pipelines.flat);
            for (desc.draw_lists) |list| try self.drawBatch(cmd, arena, &list.screen, &push, region);
            cmd.endRendering();
        }
    }

    fn drawBatch(self: *Renderer, cmd: *rhi.CommandEncoder, arena: *FrameArena, batch: *const draw_list.Batch, push: anytype, region: Region) !void {
        if (batch.indices.items.len == 0) return;
        const vertices = try arena.alloc(self.device, draw_list.Vertex, batch.vertices.items.len);
        const indices = try arena.alloc(self.device, u32, batch.indices.items.len);
        @memcpy(vertices.items, batch.vertices.items);
        @memcpy(indices.items, batch.indices.items);
        push.vertices = vertices.address;
        push.indices = indices.address;
        cmd.pushConstants(push.*);
        self.stats.draw_list_triangles += @intCast(batch.indices.items.len / 3);
        const total: u32 = @intCast(batch.indices.items.len);
        if (batch.clips.items.len == 0) {
            cmd.draw(total, 1, 0, 0);
            return;
        }
        // One draw per stretch of indices that shares a clip rectangle.
        defer cmd.setScissor(region.x, region.y, region.width, region.height);
        var first: u32 = 0;
        var clip: ?draw_list.Rect = null;
        for (batch.clips.items, 0..) |range, index| {
            if (range.first_index > first) {
                self.applyClip(cmd, clip, region);
                cmd.draw(range.first_index - first, 1, first, 0);
            }
            first = range.first_index;
            clip = range.rect;
            if (index + 1 == batch.clips.items.len and total > first) {
                self.applyClip(cmd, clip, region);
                cmd.draw(total - first, 1, first, 0);
            }
        }
    }

    fn applyClip(self: *Renderer, cmd: *rhi.CommandEncoder, clip: ?draw_list.Rect, region: Region) void {
        _ = self;
        const rect = clip orelse return cmd.setScissor(region.x, region.y, region.width, region.height);
        // Clip rectangles are in the view's pixels; the scissor is in the
        // target's, and may not leave the view's region.
        const x0 = std.math.clamp(rect.x, 0, @as(f32, @floatFromInt(region.width)));
        const y0 = std.math.clamp(rect.y, 0, @as(f32, @floatFromInt(region.height)));
        const x1 = std.math.clamp(rect.x + rect.width, x0, @as(f32, @floatFromInt(region.width)));
        const y1 = std.math.clamp(rect.y + rect.height, y0, @as(f32, @floatFromInt(region.height)));
        cmd.setScissor(
            region.x + @as(u32, @intFromFloat(@floor(x0))),
            region.y + @as(u32, @intFromFloat(@floor(y0))),
            @intFromFloat(@ceil(x1) - @floor(x0)),
            @intFromFloat(@ceil(y1) - @floor(y0)),
        );
    }

    fn drawPipelines(self: *Renderer, format: rhi.Format) !DrawPipelines {
        for (self.draw_pipelines.items) |entry| if (entry.format == format) return entry;
        const entry = DrawPipelines{
            .format = format,
            .flat = try self.device.createGraphicsPipeline(.{
                .name = "draw list",
                .vertex = shaderCode("draw.vert.spv"),
                .fragment = shaderCode("draw.frag.spv"),
                .color_targets = &.{.{ .format = format, .blend = .alpha }},
                .cull = .none,
            }),
            .depth_tested = try self.device.createGraphicsPipeline(.{
                .name = "draw list (world)",
                .vertex = shaderCode("draw.vert.spv"),
                .fragment = shaderCode("draw.frag.spv"),
                .color_targets = &.{.{ .format = format, .blend = .alpha }},
                .depth = .{ .write = false, .compare = .greater_or_equal },
                .cull = .none,
            }),
        };
        try self.draw_pipelines.append(self.gpa, entry);
        return entry;
    }

    /// Draws `scene` through `view` into `target` and returns the address
    /// of the frame constants it used.
    fn renderScene(
        self: *Renderer,
        frame: rhi.Frame,
        desc: ViewDesc,
        scene_handle: Scene,
        scene: *SceneData,
        view_data: *ViewData,
        target: rhi.Texture,
        target_format: rhi.Format,
        width: u32,
        height: u32,
        /// Size of the area of the target this view fills; differs from
        /// `width` x `height` when a render scale is set.
        output_width: u32,
        output_height: u32,
        delta_time: f32,
        arena: *FrameArena,
    ) !u64 {
        const device = self.device;
        const cmd = frame.cmd;
        var settings = desc.settings;
        // Path tracing on the GPU's ray tracing uses the structure that
        // bounce light keeps up to date.
        if (settings.path_tracing and device.ray_tracing) settings.global_illumination = true;
        const first_view = self.frame_scene_views == 0;
        self.frame_scene_views += 1;

        // Work that belongs to the scene, not the camera, happens for the
        // first view that shows the scene this frame.
        cmd.beginScope("scene update");
        const fresh_scene = scene.prepared_frame != self.frame_index;
        if (fresh_scene) {
            scene.prepared = try self.prepareScene(scene, arena, @intCast(frame.index % rhi.frames_in_flight));
            scene.prepared_frame = self.frame_index;
        }
        const scene_frame = scene.prepared;
        try cmd.flushUploads();
        try self.buildPendingBlas(cmd);
        cmd.endScope();

        const scales = EffectScales{
            .ao = settings.ao_resolution,
            .fog = settings.fog_resolution,
            .gi = settings.gi_resolution,
            .reflections = if (settings.screen_space_reflections) settings.reflection_resolution else null,
            .clouds = if (scene.clouds != null and settings.clouds) settings.cloud_resolution else null,
            .fluid = if (scene.fluids.items.len != 0 and settings.fluids) settings.fluid_resolution else null,
            .lens = settings.dof_aperture > 0 or settings.motion_blur > 0,
            .dof = if (settings.dof_aperture > 0 and settings.dof_resolution != .full) settings.dof_resolution else null,
            .oit = settings.transparency == .weighted,
            .peel = settings.transparency == .peeled,
            .refraction = scene.transmissive or scene.waters.items.len != 0 or scene.liquids.items.len != 0,
            .liquid = scene.liquids.items.len != 0,
            .output_width = output_width,
            .output_height = output_height,
            .temporal_upscale = settings.upscaling == .temporal and settings.temporal_antialiasing and settings.debug_view == .none and (output_width > width or output_height > height),
        };
        if (view_data.state == null or view_data.state.?.width != width or view_data.state.?.height != height or
            !std.meta.eql(view_data.state.?.scales, scales))
        {
            if (view_data.state) |*old| old.deinit(device);
            view_data.state = null;
            view_data.state = try ViewState.init(device, width, height, scales);
            view_data.exposure_reset = true;
        }
        const view = &view_data.state.?;
        // History from a frame this view sat out no longer lines up.
        if (view_data.last_frame +% 1 != self.frame_index) {
            view.history_valid = false;
            view.ao_history_valid = false;
            if (view.reflections) |*targets| targets.history_valid = false;
            if (view.clouds) |*targets| targets.history_valid = false;
        }

        // ------------------------------------------------------ frame data
        const aspect = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));
        const view_matrix = math.lookTo(desc.camera.position, desc.camera.forward, desc.camera.up);
        const proj_unjittered = math.perspective(desc.camera.fov_y, aspect, desc.camera.near);
        var jitter: [2]f32 = .{ 0, 0 };
        var proj = proj_unjittered;
        const debugging = settings.debug_view != .none;
        if (settings.temporal_antialiasing and !debugging) {
            // Eight positions cover a pixel; when the picture is being built
            // at a larger size, proportionally more are needed to cover
            // each of the output's pixels.
            const upscale_area = @as(f32, @floatFromInt(output_width)) * @as(f32, @floatFromInt(output_height)) / (@as(f32, @floatFromInt(width)) * @as(f32, @floatFromInt(height)));
            const jitter_count: u64 = if (settings.upscaling == .temporal and upscale_area > 1) @intFromFloat(@min(@ceil(8 * upscale_area), 64)) else 8;
            const sample: u32 = @intCast(view_data.frames % jitter_count + 1);
            const offset = [2]f32{ halton(sample, 2) - 0.5, halton(sample, 3) - 0.5 };
            jitter = .{ offset[0] / @as(f32, @floatFromInt(width)), offset[1] / @as(f32, @floatFromInt(height)) };
            // NDC shift of +2*jitter; clip.w is -view.z, hence the sign.
            proj[8] = -2 * jitter[0];
            proj[9] = -2 * jitter[1];
        }
        const view_proj = math.mul(proj, view_matrix);
        const view_proj_unjittered = math.mul(proj_unjittered, view_matrix);
        {
            // The scene was shifted since this view last drew it: express
            // last frame's camera in the new coordinates.
            var since: Vec3 = undefined;
            inline for (0..3) |axis| since[axis] = @floatCast(view_data.scene_origin[axis] - scene.origin[axis]);
            if (since[0] != 0 or since[1] != 0 or since[2] != 0)
                view_data.previous_view_proj = math.mul(view_data.previous_view_proj, math.translation(math.scale(since, -1)));
            view_data.scene_origin = scene.origin;
        }
        if (!view.history_valid) view_data.previous_view_proj = view_proj_unjittered;

        const sun_travel = math.normalize(scene.sun.direction);
        const sun_enabled = scene.sun.intensity > 0 and math.dot(sun_travel, sun_travel) > 0.5;
        const shadows_enabled = settings.shadows and sun_enabled and scene.ref_count != 0;
        const has_geometry = scene.ref_count != 0;
        // Which instances the cameras draw, for texture streaming that
        // skips what is hidden.
        const instance_total: u32 = @as(u32, @intCast(scene.layout.items.len)) + scene.static_count;
        const mark_seen = has_geometry and instance_total != 0 and
            (if (self.options.texture_streaming) |streaming| streaming.skip_occluded else false);
        // How levels of detail are chosen in the camera's own pass, and
        // the band over which two of them cross-fade.
        const lod_scale: f32 = if (settings.lod_error_pixels > 0)
            @abs(proj_unjittered[5]) * @as(f32, @floatFromInt(height)) * 0.5 / settings.lod_error_pixels
        else
            0;
        var pass = ScenePass{
            .frame = frame,
            .cmd = cmd,
            .arena = arena,
            .desc = desc,
            .settings = settings,
            .scene_handle = scene_handle,
            .scene = scene,
            .scene_frame = scene_frame,
            .fresh_scene = fresh_scene,
            .view_data = view_data,
            .view = view,
            .width = width,
            .height = height,
            .output_width = output_width,
            .output_height = output_height,
            .delta_time = delta_time,
            .debugging = debugging,
            .aspect = aspect,
            .view_matrix = view_matrix,
            .proj_unjittered = proj_unjittered,
            .view_proj = view_proj,
            .view_proj_unjittered = view_proj_unjittered,
            .sun_travel = sun_travel,
            .has_geometry = has_geometry,
            .occlusion = settings.occlusion_culling and has_geometry,
            .mark_seen = mark_seen,
            .lod = .{ desc.camera.position[0], desc.camera.position[1], desc.camera.position[2], lod_scale },
            .lod_band = if (lod_scale > 0) 1 + std.math.clamp(settings.lod_cross_fade, 0, 1) else 1,
        };
        const colored_shadows = shadows_enabled and settings.colored_shadows and settings.transparent_shadows;
        if (colored_shadows and view_data.shadow_color == null) {
            view_data.shadow_color = try device.createTexture(.{
                .name = "shadow tint",
                .width = @max(self.options.shadow_resolution / 2, 1),
                .height = @max(self.options.shadow_resolution / 2, 1),
                .format = .rgba8_unorm,
                .usage = .{ .sampled = true, .color_attachment = true },
                .layers = gpu.cascade_count,
                .kind = .@"2d_array",
            });
        }
        // Switching it on or off changes what the cascades hold.
        if (view_data.shadows_colored != colored_shadows) {
            view_data.shadows_colored = colored_shadows;
            view_data.cascade_cache.valid = false;
        }
        const cascade_plan = shadow_passes.updateCascades(self, &pass, shadows_enabled);
        const cascades = view_data.cascade_cache.cascades;
        // Each view keeps its own cascades: they follow its camera and are
        // reused between its frames.
        if (shadows_enabled and view_data.shadow_map == null) {
            view_data.shadow_map = try device.createTexture(.{
                .name = "shadow cascades",
                .width = self.options.shadow_resolution,
                .height = self.options.shadow_resolution,
                .format = .depth32_float,
                .usage = .{ .sampled = true, .depth_attachment = true },
                .layers = gpu.cascade_count,
                .kind = .@"2d_array",
            });
        }
        const shadow_map = if (shadows_enabled) view_data.shadow_map.? else self.shadow_map;
        const sun_shadows = SunShadows{
            .enabled = shadows_enabled,
            .colored = colored_shadows,
            .map = shadow_map,
            .cascades = cascades,
            .count = cascade_plan.count,
            .update = cascade_plan.update,
        };

        const environment: ?*EnvironmentEntry = blk: {
            const entry = self.environments.get(scene.environment orelse break :blk null) orelse break :blk null;
            break :blk if (entry.state == .ready) entry else null;
        };

        const gi = try gi_passes.prepareGi(self, scene, scene_frame, settings, desc.camera.position);
        const gi_coarse: ?*const GiVolume = if (gi != null) (if (scene.gi_coarse) |*volume| volume else null) else null;
        const gi_middle: ?*const GiVolume = if (gi_coarse != null) (if (scene.gi_middle) |*volume| volume else null) else null;
        // Lights with a length cast shadows a point's shadow map cannot
        // show; where rays are to be had they are shadowed by rays instead.
        const traced_shadows = settings.ray_traced_light_shadows and gi != null and device.ray_tracing and scene.tlas != null;
        const lighting = try self.prepareLights(scene, arena, settings.shadows, desc.camera.position, traced_shadows);
        const local_shadows = shadow_passes.planLocalShadows(self, &pass, &lighting);
        // The cloud layer is described before the frame constants are
        // written, because shading needs it for the shadows it casts.
        const cloud_address = try volume_passes.prepareClouds(self, &pass);
        var flags: u32 = 0;
        if (shadows_enabled) flags |= gpu.frame_shadows;
        if (settings.ambient_occlusion) flags |= gpu.frame_ambient_occlusion;
        if (environment != null) flags |= gpu.frame_environment;
        if (gi != null) flags |= gpu.frame_gi;
        if (settings.temporal_antialiasing and !debugging) flags |= gpu.frame_temporal;
        if (settings.specular_antialiasing) flags |= gpu.frame_specular_aa;
        if (settings.screen_space_reflections and !debugging) flags |= gpu.frame_ssr;
        if (settings.gi_local_lights) flags |= gpu.frame_gi_local_lights;
        // Rays per pixel toward a light with a size, in four bits of the flags.
        flags |= std.math.clamp(settings.light_shadow_rays, 1, 15) << 16;
        // How many local lights bounce, in ten more.
        flags |= std.math.clamp(settings.gi_bounce_lights, 1, 1023) << 20;
        const probes = try shading_passes.reflectionProbeList(self, &pass);
        // Filled in once the fluids have been stepped, further down.
        const fluid_list = try arena.alloc(device, gpu.FluidList, 1);
        fluid_list.items[0] = .{};
        if (settings.fluid_shadows and scene.fluids.items.len != 0) flags |= gpu.frame_fluid_shadows;
        if (colored_shadows) flags |= gpu.frame_colored_shadows;
        if (settings.reflect_transparent) flags |= gpu.frame_reflect_transparent;
        if (settings.fluid_rays and scene.fluids.items.len != 0) flags |= gpu.frame_fluid_rays;
        if (cloud_address != 0 and scene.clouds.?.shadow > 0) flags |= gpu.frame_cloud_shadows;

        const decals_address = try shading_passes.writeDecals(self, &pass);
        const constants = try arena.alloc(device, gpu.FrameConstants, 1);
        const shadow_tlas: u64 = if (traced_shadows) device.accelerationAddress(scene.tlas.?) else 0;
        constants.items[0] = .{
            .view = view_matrix,
            .proj = proj,
            .view_proj = view_proj,
            .inv_view_proj = math.inverse(view_proj),
            .view_proj_unjittered = view_proj_unjittered,
            .prev_view_proj_unjittered = view_data.previous_view_proj,
            .inv_view = math.inverse(view_matrix),
            .inv_proj = math.inverse(proj),
            .cascade_view_proj = cascades.view_proj,
            .cascade_splits = cascades.splits,
            .cascade_texel_size = cascades.texel_size,
            .camera_position = desc.camera.position,
            .near = desc.camera.near,
            .sun_direction = math.scale(sun_travel, -1),
            .shadow_softness = settings.shadow_softness,
            .sun_radiance = if (sun_enabled) math.scale(scene.sun.color, scene.sun.intensity) else .{ 0, 0, 0 },
            .env_intensity = scene.environment_intensity,
            .resolution = .{ @floatFromInt(width), @floatFromInt(height) },
            .inv_resolution = .{ 1.0 / @as(f32, @floatFromInt(width)), 1.0 / @as(f32, @floatFromInt(height)) },
            .jitter = jitter,
            .prev_jitter = view_data.previous_jitter,
            .frame_index = @truncate(self.frame_index),
            .time = self.time,
            .delta_time = delta_time,
            .flags = flags,
            .shadow_map = device.textureIndex(shadow_map),
            .shadow_sampler = device.samplerIndex(self.sampler_shadow),
            .env_specular = if (environment) |entry| device.textureIndex(entry.specular.?) else gpu.invalid_id,
            .env_irradiance = if (environment) |entry| device.textureIndex(entry.irradiance.?) else gpu.invalid_id,
            .env_sky = if (environment) |entry| device.textureIndex(entry.sky.?) else gpu.invalid_id,
            .brdf_lut = device.textureIndex(self.brdf_lut),
            .sampler_linear_clamp = device.samplerIndex(self.sampler_linear_clamp),
            .sampler_nearest_clamp = device.samplerIndex(self.sampler_nearest_clamp),
            .env_specular_mips = env_specular_mips,
            .light_count = lighting.light_count,
            .sampler_linear_repeat = device.samplerIndex(self.sampler_linear_repeat),
            .local_shadow_map = device.textureIndex(self.local_shadow_map),
            .local_shadow_sampler = device.samplerIndex(self.sampler_local_shadow),
            .cluster_z_scale = cluster_z_scale,
            .cluster_z_bias = -@log2(cluster_near) * cluster_z_scale,
            .gi_origin = if (gi) |volume| volume.origin else .{ 0, 0, 0 },
            .gi_spacing = if (gi) |volume| volume.spacing else 1,
            .gi_counts = if (gi) |volume| .{ @intCast(volume.counts[0]), @intCast(volume.counts[1]), @intCast(volume.counts[2]) } else .{ 2, 2, 2 },
            .gi_irradiance = if (gi) |volume| device.textureIndex(volume.irradiance) else gpu.invalid_id,
            .gi_visibility = if (gi) |volume| device.textureIndex(volume.visibility) else gpu.invalid_id,
            .gi_intensity = settings.gi_intensity,
            .gi_scroll = if (gi) |volume| giScroll(volume) else 0,
            .gi_offsets = if (gi) |volume| (if (settings.gi_probe_relocation and volume.offsets_valid) device.textureIndex(volume.offsets[volume.offset_turn]) else gpu.invalid_id) else gpu.invalid_id,
            .gi2_origin = if (gi_coarse) |volume| volume.origin else .{ 0, 0, 0 },
            .gi2_spacing = if (gi_coarse) |volume| volume.spacing else 1,
            .gi2_counts = if (gi_coarse) |volume| .{ @intCast(volume.counts[0]), @intCast(volume.counts[1]), @intCast(volume.counts[2]) } else .{ 2, 2, 2 },
            .gi2_irradiance = if (gi_coarse) |volume| device.textureIndex(volume.irradiance) else gpu.invalid_id,
            .gi2_visibility = if (gi_coarse) |volume| device.textureIndex(volume.visibility) else gpu.invalid_id,
            .gi2_scroll = if (gi_coarse) |volume| giScroll(volume) else 0,
            .gi3_origin = if (gi_middle) |volume| volume.origin else .{ 0, 0, 0 },
            .gi3_spacing = if (gi_middle) |volume| volume.spacing else 1,
            .gi3_counts = if (gi_middle) |volume| .{ @intCast(volume.counts[0]), @intCast(volume.counts[1]), @intCast(volume.counts[2]) } else .{ 2, 2, 2 },
            .gi3_irradiance = if (gi_middle) |volume| device.textureIndex(volume.irradiance) else gpu.invalid_id,
            .gi3_visibility = if (gi_middle) |volume| device.textureIndex(volume.visibility) else gpu.invalid_id,
            .gi3_scroll = if (gi_middle) |volume| giScroll(volume) else 0,
            .gi3_offsets = if (gi_middle) |volume| (if (settings.gi_probe_relocation and volume.offsets_valid) device.textureIndex(volume.offsets[volume.offset_turn]) else gpu.invalid_id) else gpu.invalid_id,
            .gi2_offsets = if (gi_coarse) |volume| (if (settings.gi_probe_relocation and volume.offsets_valid) device.textureIndex(volume.offsets[volume.offset_turn]) else gpu.invalid_id) else gpu.invalid_id,
            .shadow_taps = settings.shadow_samples,
            // Also what the soft shadow filter compares neighbours by.
            .contact_depth = if (!debugging) device.textureIndex(view.depth) else gpu.invalid_id,
            .contact_length = @max(settings.contact_shadows, 0),
            .tlas_low = @truncate(shadow_tlas),
            .tlas_high = @truncate(shadow_tlas >> 32),
            // Negative asks the shaders for the simple model.
            .aerial = if (settings.aerial_model == .sky) -@max(settings.aerial_perspective, 0) else @max(settings.aerial_perspective, 0),
            .shadow_color = if (colored_shadows) device.textureIndex(view_data.shadow_color.?) else gpu.invalid_id,
            .texture_gradient_scale = if (settings.temporal_antialiasing and !debugging) std.math.pow(f32, 2, std.math.clamp(settings.texture_mip_bias, -2, 2)) else 1,
            .vertices = device.bufferAddress(self.vertices.buffer),
            .indices = device.bufferAddress(self.indices.buffer),
            .meshlets = device.bufferAddress(self.meshlets.buffer),
            .meshes = device.bufferAddress(self.meshes.buffer),
            .materials = device.bufferAddress(self.materials.buffer),
            .instances = scene_frame.instances,
            .meshlet_refs = if (scene.refs) |buffer| device.bufferAddress(buffer) else 0,
            .lights = lighting.lights,
            .clusters = device.bufferAddress(self.clusters),
            .shadow_tiles = lighting.tiles,
            .decal_count = @intCast(scene.decals.items.len),
            .decals = decals_address,
            .clouds = cloud_address,
            .fluids = fluid_list.address,
            .probes = probes.address,
            .probe_count = probes.count,
            .exposure = device.bufferAddress(view_data.exposure),
        };
        const frame_address = constants.address;
        pass.frame_address = frame_address;

        // ----------------------------------------------- skinning and culling
        // Draw counts from two frames ago, for statistics.
        const count_readback = self.count_readback[@intCast(frame.index % rhi.frames_in_flight)];
        if (first_view) {
            const counted = device.mappedSlice(u32, count_readback);
            self.stats.meshlets_drawn = counted[0] + counted[1] + counted[main_late_view * 2] + counted[main_late_view * 2 + 1];
            self.stats.shadow_meshlets_drawn = 0;
            for (1..1 + gpu.cascade_count) |index| self.stats.shadow_meshlets_drawn += counted[index * 2] + counted[index * 2 + 1];
        }

        try geometry_passes.resetCullBuffers(self, &pass, instance_total);
        if (fresh_scene) try simulation_passes.simulateFluids(self, cmd, scene, arena, delta_time);
        if (fresh_scene) try simulation_passes.simulateWater(self, cmd, scene, arena, delta_time);
        if (fresh_scene) try simulation_passes.simulateLiquids(self, cmd, scene, arena, delta_time);
        // Built here and stored once: the arena must not be read back.
        fluid_list.items[0] = volume_passes.shadowingFluids(self, &pass);
        // Each view has its own light records, so the fires' light is
        // worked out per view, after the fluids have been stepped.
        volume_passes.lightFluids(self, &pass, &lighting);
        // Particles may be carried by a fluid, so they come second. They
        // collide with the depth this view drew last frame.
        if (fresh_scene) try particle_passes.simulateParticles(self, cmd, scene, arena, frame_address, delta_time, if (view.history_valid) device.textureIndex(view.depth) else null);
        if (has_geometry) {
            const zone = Zone.start(self.options.profiler, "deformed geometry");
            defer zone.stop();
            try geometry_passes.skinScene(self, &pass);
        }
        const culling = try geometry_passes.cullScene(self, &pass, &sun_shadows, &lighting, local_shadows.draw);

        try geometry_passes.drawSceneVisibility(self, &pass, &sun_shadows, &culling);
        if (first_view) cmd.copyBuffer(self.cull_counts, count_readback, 0, 0, view_count * 2 * @sizeOf(u32));
        if (mark_seen) {
            // Every view of the scene adds to it; the last copy has all.
            const slot: usize = @intCast(frame.index % rhi.frames_in_flight);
            cmd.copyBuffer(scene.seen.?, scene.seen_readback[slot].?, 0, 0, @as(u64, instance_total) * @sizeOf(u32));
            scene.seen_tags[slot] = .{ .layout_version = scene.layout_version, .count = instance_total, .valid = true };
        }

        if (shadows_enabled) try shadow_passes.drawSunShadows(self, &pass, &sun_shadows);

        if (lighting.light_count != 0 or scene.decals.items.len != 0) {
            cmd.beginScope("light clusters");
            cmd.bindPipeline(self.pipelines.cluster);
            cmd.pushConstants(extern struct { frame: u64, z_near: f32, z_ratio: f32 }{
                .frame = frame_address,
                .z_near = cluster_near,
                .z_ratio = std.math.pow(f32, cluster_far / cluster_near, 1.0 / @as(f32, gpu.clusters_z)),
            });
            cmd.dispatch((gpu.cluster_count + 63) / 64, 1, 1);
            cmd.sync(.compute_to_all);
            cmd.endScope();
        }
        if (local_shadows.draw) try shadow_passes.drawLocalShadows(self, &pass, &lighting, &local_shadows);

        // The passes below sample depth and the visibility buffer.
        cmd.transition(view.visibility, .shader_read);
        cmd.transition(view.depth, .shader_read);

        geometry_passes.recordPick(self, &pass);
        try shading_passes.ambientOcclusion(self, &pass);

        if (gi) |volume| if (scene.gi_updated_frame != self.frame_index) {
            try gi_passes.updateGi(self, cmd, scene, volume, scene_frame, frame_address, settings, 0);
            // The coarse grid can be refreshed less often than the fine one.
            if (scene.gi_coarse) |*coarse| {
                if (coarse.frames < 64 or self.frame_index % @max(settings.gi_coarse_interval, 1) == 0)
                    try gi_passes.updateGi(self, cmd, scene, coarse, scene_frame, frame_address, settings, 1);
            }
            if (scene.gi_middle) |*middle| try gi_passes.updateGi(self, cmd, scene, middle, scene_frame, frame_address, settings, 2);
            scene.gi_updated_frame = self.frame_index;
        };

        // Optional reduced-resolution probe gather, upsampled by shading.
        var gathered_gi: ?rhi.Texture = null;
        if (gi != null) if (view.gi_gather) |texture| {
            cmd.beginScope("gi gather");
            try cmd.beginRendering(.{ .color = &.{.{ .texture = texture, .load = .discard }} });
            cmd.bindPipeline(self.pipelines.gi_gather);
            cmd.pushConstants(extern struct { frame: u64, depth: u32, pad: u32 = 0 }{
                .frame = frame_address,
                .depth = device.textureIndex(view.depth),
            });
            cmd.drawFullscreen();
            cmd.endRendering();
            cmd.transition(texture, .shader_read);
            cmd.endScope();
            gathered_gi = texture;
        };

        const reflections = try shading_passes.shadeScene(self, &pass, &lighting, flags, shadow_tlas, colored_shadows, gathered_gi);
        if (cloud_address != 0 and !debugging) try volume_passes.drawClouds(self, &pass, cloud_address);
        if (reflections) |targets| try shading_passes.drawReflections(self, &pass, targets, gi != null);
        try self.runPasses(&pass, .after_opaque, view.hdr, hdr_format, width, height);

        try transparency_passes.drawLiquids(self, &pass);
        try transparency_passes.drawWater(self, &pass);
        try transparency_passes.drawTransparency(self, &pass);
        try volume_passes.drawFluids(self, &pass);
        if (settings.fog_density > 0 and !debugging) try volume_passes.drawFog(self, &pass);
        if (!debugging) try particle_passes.drawParticles(self, cmd, scene, view, frame_address, desc.camera.position);
        try self.runPasses(&pass, .after_transparency, view.hdr, hdr_format, width, height);

        const path_traced = try path_tracing_pass.pathTrace(self, &pass);
        var resolved = try post_passes.resolveTemporal(self, &pass, path_traced);
        resolved = try post_passes.lensEffects(self, &pass, resolved);
        const bloom_count = try post_passes.bloomAndExposure(self, &pass, resolved);
        try post_passes.tonemapScene(self, &pass, resolved, bloom_count, target, target_format);
        try self.runPasses(&pass, .after_tonemap, target, target_format, output_width, output_height);

        view_data.previous_view_proj = view_proj_unjittered;
        view_data.previous_jitter = jitter;
        view_data.frames += 1;
        view_data.last_frame = self.frame_index;
        if (first_view) {
            self.stats.instances = instance_total;
            self.stats.meshlets = scene.ref_count;
            self.stats.triangles = scene.triangle_count;
            self.stats.skinned_vertices = scene_frame.skinned_vertices;
        }
        return frame_address;
    }

    /// Runs the application's passes for `stage`, which draw into `color`.
    fn runPasses(self: *Renderer, p: *const ScenePass, stage: PassStage, color: rhi.Texture, color_format: rhi.Format, width: u32, height: u32) !void {
        const cmd = p.cmd;
        var ran = false;
        for (p.desc.passes) |pass| {
            if (pass.stage != stage) continue;
            cmd.beginScope("custom pass");
            defer cmd.endScope();
            try pass.run(pass.context, .{
                .cmd = cmd,
                .device = self.device,
                .stage = stage,
                .frame = p.frame_address,
                .color = color,
                .color_format = color_format,
                .depth = p.view.depth,
                .motion = p.view.motion,
                .width = width,
                .height = height,
            });
            ran = true;
        }
        if (!ran) return;
        // Whatever the pass attached goes back to being readable.
        if (stage != .after_tonemap) cmd.transition(color, .shader_read);
        cmd.transition(p.view.depth, .shader_read);
        cmd.transition(p.view.motion, .shader_read);
    }

    /// Converts the scene's lights to GPU records and assigns shadow atlas
    /// tiles to the ones that cast shadows.
    fn prepareLights(self: *Renderer, scene: *SceneData, arena: *FrameArena, shadows: bool, camera_position: Vec3, traced_shadows: bool) !Lighting {
        const device = self.device;
        var fluid_lights: usize = 0;
        for (scene.fluids.items) |item| {
            if (self.fluids.get(item)) |state| fluid_lights += @intFromBool(state.desc.light > 0);
        }
        const lights = try arena.alloc(device, gpu.Light, scene.lights.items.len + fluid_lights);
        const tiles = try arena.alloc(device, gpu.ShadowTile, max_local_shadow_views);
        var result = Lighting{
            .lights = lights.address,
            .tiles = tiles.address,
            .light_count = @intCast(scene.lights.items.len + fluid_lights),
            .tile_count = 0,
            .tile_view_proj = undefined,
            .tile_views = undefined,
        };
        const tiles_per_side = std.math.clamp(self.options.local_shadow_tiles_per_side, 1, local_shadow_tiles_per_side);
        const tile_scale = 1.0 / @as(f32, @floatFromInt(tiles_per_side));
        const axes = [6]Vec3{ .{ 1, 0, 0 }, .{ -1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, -1, 0 }, .{ 0, 0, 1 }, .{ 0, 0, -1 } };
        // Shadow tiles go to the lights that matter most to this camera:
        // bright, far-reaching and near. The rest are lit without shadows.
        const granted = try self.gpa.alloc(bool, scene.lights.items.len);
        defer self.gpa.free(granted);
        @memset(granted, false);
        if (shadows) {
            const Candidate = struct { index: u32, score: f32 };
            const candidates = try self.gpa.alloc(Candidate, scene.lights.items.len);
            defer self.gpa.free(candidates);
            var candidate_count: usize = 0;
            for (scene.lights.items, 0..) |light, index| {
                if (!light.cast_shadows or light.kind == .directional or light.kind == .rectangle) continue;
                // A tube: rays aim along its length, a shadow map sees a point.
                if (traced_shadows and light.kind != .spot and light.source_length > 0) continue;
                const away = math.sub(light.position, camera_position);
                candidates[candidate_count] = .{ .index = @intCast(index), .score = light.intensity * @max(light.color[0], @max(light.color[1], light.color[2])) * light.range / (math.dot(away, away) + 1) };
                candidate_count += 1;
            }
            std.mem.sort(Candidate, candidates[0..candidate_count], {}, struct {
                fn higher(_: void, a: Candidate, b: Candidate) bool {
                    return a.score > b.score;
                }
            }.higher);
            var tiles_left: u32 = tiles_per_side * tiles_per_side;
            for (candidates[0..candidate_count]) |candidate| {
                const needed: u32 = if (scene.lights.items[candidate.index].kind == .spot) 1 else 6;
                if (needed > tiles_left) continue;
                tiles_left -= needed;
                granted[candidate.index] = true;
            }
        }
        result.tiles_key = std.hash.Wyhash.hash(tiles_per_side, std.mem.sliceAsBytes(granted));
        for (scene.lights.items, lights.items[0..scene.lights.items.len], granted) |light, *out, has_tiles| {
            const direction = math.normalize(light.direction);
            const cos_outer = @cos(light.outer_angle);
            const cos_inner = @max(@cos(@min(light.inner_angle, light.outer_angle)), cos_outer + 1e-4);
            const cone_scale = 1.0 / (cos_inner - cos_outer);
            out.* = .{
                .position = light.position,
                .range = light.range,
                .color = math.scale(light.color, light.intensity),
                .flags = switch (light.kind) {
                    .point => 0,
                    .spot => gpu.light_spot,
                    .directional => gpu.light_directional,
                    .rectangle => gpu.light_rectangle,
                },
                .source_radius = @max(light.source_radius, 0),
                .source_length = if (light.kind == .point or light.kind == .rectangle) @max(light.source_length, 0) else 0,
                .source_height = if (light.kind == .rectangle) @max(light.source_height, 0) else 0,
                .cookie = if (light.cookie) |image| image.index else gpu.invalid_id,
                .profile = if (light.profile) |image| image.index else gpu.invalid_id,
                .direction = direction,
                .cone_scale = cone_scale,
                .cone_offset = -cos_outer * cone_scale,
            };
            const faces: u32 = if (light.kind == .spot) 1 else 6;
            if (!has_tiles) {
                // No shadow map for this one: a ray does it where it can.
                if (shadows and light.cast_shadows) out.flags |= gpu.light_traced_shadow;
                continue;
            }
            out.flags |= (result.tile_count + 1) << 8;
            for (0..faces) |face| {
                const forward = if (light.kind == .spot) direction else axes[face];
                const up: Vec3 = if (@abs(forward[1]) > 0.99) .{ 0, 0, 1 } else .{ 0, 1, 0 };
                // Point faces are slightly wider than 90 degrees so filter
                // taps near an edge still land inside the tile.
                const fov: f32 = if (light.kind == .spot) @min(light.outer_angle * 2 + 0.05, 3.0) else 1.62;
                const view_proj = math.mul(math.perspective(fov, 1, 0.05), math.lookTo(light.position, forward, up));
                const index = result.tile_count;
                var cull = cullView(view_proj, light.position, .perspective);
                // Nothing beyond the light's range can cast a visible shadow.
                cull.planes[5] = .{ -forward[0], -forward[1], -forward[2], math.dot(forward, light.position) + light.range };
                cull.plane_count = 6;
                result.tile_views[index] = cull;
                result.tile_view_proj[index] = view_proj;
                tiles.items[index] = .{
                    .view_proj = view_proj,
                    .rect = .{
                        tile_scale,
                        tile_scale,
                        @as(f32, @floatFromInt(index % tiles_per_side)) * tile_scale,
                        @as(f32, @floatFromInt(index / tiles_per_side)) * tile_scale,
                    },
                };
                result.tile_count += 1;
            }
        }
        // Fires light the scene: one light record per fluid that asks for
        // it. Its color and center are written on the GPU from the fluid
        // itself (fluid_light.comp); everything else is set here.
        var fluid_slot: usize = scene.lights.items.len;
        for (scene.fluids.items) |item| {
            const state = self.fluids.get(item) orelse continue;
            if (state.desc.light <= 0) continue;
            const t = state.desc.transform;
            const height = math.length(.{ t[4], t[5], t[6] });
            lights.items[fluid_slot] = .{
                .position = .{ t[12], t[13], t[14] },
                .range = if (state.desc.light_range > 0) state.desc.light_range else height * 3,
                .color = .{ 0, 0, 0 },
                // Shadowed by rays where that is available.
                .flags = gpu.light_fire | (if (shadows) gpu.light_traced_shadow else 0),
                .source_radius = height * @max(state.desc.light_size, 0),
            };
            fluid_slot += 1;
        }
        return result;
    }

    /// Builds acceleration structures for models that just finished loading.
    /// Must run after their geometry uploads have been recorded.
    /// Closes gaps in the vertex and index pools: when a quarter or more
    /// of what a pool spans lies free between meshes, the mesh nearest
    /// its end is copied into the first gap that holds it, one mesh a
    /// pool each frame. The end then draws back and the pool can move to
    /// a smaller buffer (see `Pool.trim`). Returns whether anything was
    /// moved.
    fn compactGeometry(self: *Renderer, cmd: *rhi.CommandEncoder) !bool {
        var moved = false;
        inline for (.{ "vertices", "indices" }) |name| {
            const pool: *Pool = &@field(self, name);
            const vertices = comptime std.mem.eql(u8, name, "vertices");
            var free_inside: u64 = 0;
            for (pool.ranges.free_ranges.items) |range| free_inside += range.count;
            // Small pools and small gaps are not worth a copy.
            if (free_inside * 4 >= pool.ranges.top and @as(u64, pool.ranges.top) * pool.stride >= 1 << 20) find: {
                // The mesh that ends the pool.
                var last_entry: ?*ModelEntry = null;
                var last_mesh: usize = 0;
                var last_end: u32 = 0;
                for (self.models.slots.items) |*slot| if (slot.value) |*entry| {
                    if (entry.state != .ready or !entry.geometry_resident or entry.geometry_coarse) continue;
                    for (entry.meshes, 0..) |mesh, index| {
                        const end = if (vertices) mesh.vertex_offset + mesh.vertex_count else mesh.index_offset + mesh.index_count;
                        if (end > last_end) {
                            last_end = end;
                            last_entry = entry;
                            last_mesh = index;
                        }
                    }
                };
                const entry = last_entry orelse break :find;
                // Something else ends the pool (a posed copy of a skinned
                // mesh), or its structure is still to be built from where
                // it lies.
                if (last_end != pool.ranges.top or entry.blas_pending) break :find;
                const mesh = &entry.meshes[last_mesh];
                const count = if (vertices) mesh.vertex_count else mesh.index_count;
                const old = if (vertices) mesh.vertex_offset else mesh.index_offset;
                if (count == 0 or @as(u64, count) * pool.stride > 16 << 20) break :find;
                const new = pool.ranges.alloc(count) orelse break :find;
                // Only into a gap wholly before it: a copy within one
                // buffer may not overlap itself.
                if (new + count > old) {
                    pool.ranges.free(self.gpa, new, count);
                    break :find;
                }
                cmd.sync(.all_to_transfer);
                cmd.copyBuffer(pool.buffer, pool.buffer, @as(u64, old) * pool.stride, @as(u64, new) * pool.stride, @as(u64, count) * pool.stride);
                cmd.sync(.transfer_to_all);
                if (vertices) mesh.vertex_offset = new else mesh.index_offset = new;
                if (!vertices) {
                    // The mesh's record names where its indices start.
                    const source_mesh = entry.source.?.meshes[last_mesh];
                    const record = gpu.Mesh{
                        .center = source_mesh.bounds_center,
                        .radius = source_mesh.bounds_radius,
                        .index_offset = mesh.index_offset,
                        .meshlet_offset = mesh.meshlet_offset,
                        .meshlet_count = mesh.meshlet_count,
                        .bvh = mesh.bvh_nodes orelse gpu.invalid_id,
                    };
                    try self.meshes.write(self.device, entry.mesh_base + @as(u32, @intCast(last_mesh)), std.mem.asBytes(&record));
                }
                // Instance groups keep their records between frames, and
                // those name where the vertices are.
                if (vertices) for (self.scenes.slots.items) |*slot| if (slot.value) |*scene| {
                    scene.static_version += 1;
                };
                self.stats.geometry_bytes_compacted += @as(u64, count) * pool.stride;
                pool.free(self, old, count);
                moved = true;
            }
        }
        return moved;
    }

    fn buildPendingBlas(self: *Renderer, cmd: *rhi.CommandEncoder) !void {
        if (self.blas_pending == 0) return;
        self.blas_pending = 0;
        for (self.models.slots.items) |*slot| if (slot.value) |*entry| {
            if (!entry.blas_pending) continue;
            entry.blas_pending = false;
            for (entry.meshes) |mesh| if (mesh.blas) |blas| try cmd.buildBlas(blas, geometry_passes.blasDesc(self, mesh));
        };
    }

    /// Pins the irradiance probe volume to a world-space box. Pass null to
    /// Moves everything in a scene by `offset` without it counting as
    /// motion: entities, instance groups, lights, decals, emitters and
    /// their particles, the probe volume and each view's history all move
    /// together, so the picture does not change.
    ///
    /// This is how to keep precision in a large world. Positions are 32-bit
    /// floats, which hold about a millimetre a few kilometres from zero and
    /// far less beyond. Keep the application's own positions in 64 bits,
    /// hand the renderer positions relative to a point near the camera, and
    /// when the camera strays from that point, shift the scene back and
    /// from then on hand in positions relative to the new point. The
    /// camera, draw lists and settings given in world units (fog height)
    /// are the caller's to shift.
    pub fn shiftScene(self: *Renderer, scene: Scene, offset: Vec3) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const data = self.scenes.get(scene) orelse return error.InvalidScene;
        inline for (0..3) |axis| data.origin[axis] -= offset[axis];
        for (data.entities.items) |item| {
            const entity = self.entities.get(item) orelse continue;
            inline for (0..3) |axis| {
                entity.transform[12 + axis] += offset[axis];
                entity.previous_transform[12 + axis] += offset[axis];
            }
        }
        for (data.groups.items) |item| {
            const group = self.instance_groups.get(item) orelse continue;
            for (group.transforms) |*transform| {
                inline for (0..3) |axis| transform[12 + axis] += offset[axis];
            }
        }
        data.static_version += 1;
        for (data.lights.items) |*light| light.position = math.add(light.position, offset);
        data.lights_version += 1;
        for (data.decals.items) |*decal| {
            inline for (0..3) |axis| decal.transform[12 + axis] += offset[axis];
        }
        for (data.emitters.items) |item| {
            const emitter = self.emitters.get(item) orelse continue;
            emitter.desc.position = math.add(emitter.desc.position, offset);
            emitter.shift = math.add(emitter.shift, offset);
        }
        for (data.fluids.items) |item| {
            const fluid = self.fluids.get(item) orelse continue;
            inline for (0..3) |axis| fluid.desc.transform[12 + axis] += offset[axis];
        }
        for (data.waters.items) |item| {
            const water = self.waters.get(item) orelse continue;
            inline for (0..3) |axis| water.desc.transform[12 + axis] += offset[axis];
        }
        if (data.gi_bounds) |*bounds| {
            bounds[0] = math.add(bounds[0], offset);
            bounds[1] = math.add(bounds[1], offset);
        }
        // Probe grids keep their probes: their cells are counted from the
        // scene's origin, which moved the other way.
        inline for (.{ &data.gi, &data.gi_coarse, &data.gi_middle }) |slot| {
            if (slot.*) |*volume| volume.origin = math.add(volume.origin, offset);
        }
    }

    /// Where the scene's zero sits in the application's world: minus the
    /// sum of every `shiftScene` so far.
    pub fn sceneOrigin(self: *Renderer, scene: Scene) [3]f64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return if (self.scenes.get(scene)) |data| data.origin else .{ 0, 0, 0 };
    }

    /// derive it from the scene's static geometry (the default).
    pub fn setGiVolume(self: *Renderer, scene: Scene, bounds: ?[2]Vec3) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.scenes.get(scene)) |data| data.gi_bounds = bounds;
    }
};

fn addressMode(mode: gltf.SamplerData.AddressMode) rhi.AddressMode {
    return switch (mode) {
        .repeat => .repeat,
        .mirrored_repeat => .mirrored_repeat,
        .clamp_to_edge => .clamp_to_edge,
    };
}

fn halton(index: u32, base: u32) f32 {
    var result: f32 = 0;
    var fraction: f32 = 1;
    var i = index;
    while (i > 0) : (i /= base) {
        fraction /= @floatFromInt(base);
        result += fraction * @as(f32, @floatFromInt(i % base));
    }
    return result;
}

fn createPipelines(device: *rhi.Device) !Pipelines {
    const Local = struct {
        fn pass(d: *rhi.Device, name: [:0]const u8, fragment: []const u8, targets: []const rhi.ColorTarget) !rhi.Pipeline {
            return d.createGraphicsPipeline(.{
                .name = name,
                .vertex = shaderCode("fullscreen.vert.spv"),
                .fragment = fragment,
                .color_targets = targets,
                .cull = .none,
            });
        }
    };
    // Local lights use reverse-Z perspective, so the bias pushes toward 0.
    const local_shadow_depth = rhi.DepthState{
        .compare = .greater_or_equal,
        .bias = .{ .constant = -1.5, .slope = -2.0 },
    };
    const shadow_depth = rhi.DepthState{
        .compare = .less_or_equal,
        .bias = .{ .constant = 1.5, .slope = 2.0 },
        .clamp = true,
    };
    return .{
        .skin = try device.createComputePipeline(.{ .name = "skin", .shader = shaderCode("skin.comp.spv") }),
        .skin_bounds = try device.createComputePipeline(.{ .name = "skin bounds", .shader = shaderCode("skin_bounds.comp.spv") }),
        .cull = try device.createComputePipeline(.{ .name = "cull", .shader = shaderCode("cull.comp.spv") }),
        .cluster = try device.createComputePipeline(.{ .name = "light clusters", .shader = shaderCode("cluster.comp.spv") }),
        .local_shadow = try device.createGraphicsPipeline(.{
            .name = "local shadow",
            .vertex = shaderCode("visibility.vert.spv"),
            .depth = local_shadow_depth,
            .cull = .back,
        }),
        .local_shadow_masked = try device.createGraphicsPipeline(.{
            .name = "local shadow masked",
            .vertex = shaderCode("visibility.vert.spv"),
            .fragment = shaderCode("shadow_masked.frag.spv"),
            .depth = local_shadow_depth,
            .cull = .none,
        }),
        .forward = try device.createGraphicsPipeline(.{
            .name = "forward transparent",
            .vertex = shaderCode("forward.vert.spv"),
            .fragment = shaderCode("forward.frag.spv"),
            .color_targets = &.{ .{ .format = hdr_format, .blend = .premultiplied }, .{ .format = .rg16_float, .blend = .alpha } },
            .depth = .{ .write = false, .compare = .greater_or_equal },
            .cull = .none,
        }),
        // The other two transparency modes compile the large forward shader
        // again each; they are made when a view first asks for them.
        .forward_weighted = null,
        .oit_composite = try Local.pass(device, "transparency composite", shaderCode("oit_composite.frag.spv"), &.{.{ .format = hdr_format, .blend = .alpha }}),
        .forward_peel = null,
        .peel_under = try Local.pass(device, "peel under", shaderCode("copy.frag.spv"), &.{.{ .format = hdr_format, .blend = .under }}),
        .peel_composite = try Local.pass(device, "peel composite", shaderCode("copy.frag.spv"), &.{.{ .format = hdr_format, .blend = .premultiplied }}),
        .copy = try Local.pass(device, "copy", shaderCode("copy.frag.spv"), &.{.{ .format = hdr_format }}),
        .upscale = try Local.pass(device, "upscale", shaderCode("upscale.frag.spv"), &.{.{ .format = hdr_format }}),
        .hiz = try Local.pass(device, "depth pyramid", shaderCode("hiz.frag.spv"), &.{.{ .format = .r32_float }}),
        .visibility = try device.createGraphicsPipeline(.{
            .name = "visibility",
            .vertex = shaderCode("visibility.vert.spv"),
            .fragment = shaderCode("visibility.frag.spv"),
            .color_targets = &.{.{ .format = .r32_uint }},
            .depth = .{},
            .cull = .back,
        }),
        .visibility_masked = try device.createGraphicsPipeline(.{
            .name = "visibility masked",
            .vertex = shaderCode("visibility.vert.spv"),
            .fragment = shaderCode("visibility_masked.frag.spv"),
            .color_targets = &.{.{ .format = .r32_uint }},
            .depth = .{},
            .cull = .none,
        }),
        .shadow = try device.createGraphicsPipeline(.{
            .name = "shadow",
            .vertex = shaderCode("visibility.vert.spv"),
            .depth = shadow_depth,
            .cull = .back,
        }),
        .shadow_masked = try device.createGraphicsPipeline(.{
            .name = "shadow masked",
            .vertex = shaderCode("visibility.vert.spv"),
            .fragment = shaderCode("shadow_masked.frag.spv"),
            .depth = shadow_depth,
            .cull = .none,
        }),
        // See-through casters into a cascade's tint: no depth, every one
        // of them counts.
        .shadow_color = try device.createGraphicsPipeline(.{
            .name = "shadow tint",
            .vertex = shaderCode("visibility.vert.spv"),
            .fragment = shaderCode("shadow_color.frag.spv"),
            .color_targets = &.{.{ .format = .rgba8_unorm, .blend = .tint }},
            .cull = .none,
        }),
        .gtao = try Local.pass(device, "gtao", shaderCode("gtao.frag.spv"), &.{ .{ .format = .rg16_float }, .{ .format = .rgba16_float } }),
        .gtao_bounce_denoise = try Local.pass(device, "gtao bounce denoise", shaderCode("gtao_bounce_denoise.frag.spv"), &.{ .{ .format = .r16_float }, .{ .format = .rgba16_float } }),
        .ao_depth = try Local.pass(device, "ao depth", shaderCode("ao_depth.frag.spv"), &.{.{ .format = .r16_float }}),
        .gi_gather = try Local.pass(device, "gi gather", shaderCode("gi_gather.frag.spv"), &.{.{ .format = hdr_format }}),
        .gtao_denoise = try Local.pass(device, "gtao denoise", shaderCode("gtao_denoise.frag.spv"), &.{.{ .format = .r16_float }}),
        .shade = null,
        .shade_reflective = try Local.pass(device, "shading (reflective)", if (device.ray_tracing) shaderCode("shade_rt.frag.spv") else shaderCode("shade.frag.spv"), &shade_reflective_targets),
        .ssr = try Local.pass(device, "reflections", shaderCode("ssr.frag.spv"), &.{.{ .format = hdr_format }}),
        .ssr_traced = try Local.pass(device, "reflections (ray traced)", if (device.ray_tracing) shaderCode("ssr_rt.frag.spv") else shaderCode("ssr.frag.spv"), &.{.{ .format = hdr_format }}),
        .ssr_composite = try Local.pass(device, "reflection composite", shaderCode("ssr_composite.frag.spv"), &.{.{ .format = hdr_format, .blend = .additive }}),
        .cloud_noise = try Local.pass(device, "cloud noise", shaderCode("cloud_noise.frag.spv"), &.{.{ .format = .rgba8_unorm }}),
        .cloud = try Local.pass(device, "clouds", shaderCode("cloud.frag.spv"), &.{.{ .format = hdr_format }}),
        .cloud_composite = try Local.pass(device, "cloud composite", shaderCode("cloud_composite.frag.spv"), &.{.{ .format = hdr_format, .blend = .premultiplied }}),
        .fluid_advect = try Local.pass(device, "fluid advect", shaderCode("fluid_advect.frag.spv"), &.{ .{ .format = .rgba16_float }, .{ .format = .rgba16_float } }),
        .fluid_curl = try Local.pass(device, "fluid curl", shaderCode("fluid_curl.frag.spv"), &.{.{ .format = .rgba16_float }}),
        .fluid_force = try Local.pass(device, "fluid forces", shaderCode("fluid_force.frag.spv"), &.{.{ .format = .rgba16_float }}),
        .fluid_divergence = try Local.pass(device, "fluid divergence", shaderCode("fluid_divergence.frag.spv"), &.{.{ .format = .rg16_float }}),
        .fluid_pressure = try Local.pass(device, "fluid pressure", shaderCode("fluid_pressure.frag.spv"), &.{.{ .format = .rg16_float }}),
        .fluid_project = try Local.pass(device, "fluid projection", shaderCode("fluid_project.frag.spv"), &.{.{ .format = .rgba16_float }}),
        .fluid_present = try Local.pass(device, "fluid picture", shaderCode("fluid_present.frag.spv"), &.{.{ .format = hdr_format }}),
        .water_sim = try Local.pass(device, "water simulation", shaderCode("water_sim.frag.spv"), &.{.{ .format = .rg16_float }}),
        .water = try device.createGraphicsPipeline(.{
            .name = "water",
            .vertex = shaderCode("water.vert.spv"),
            .fragment = if (device.ray_tracing) shaderCode("water_rt.frag.spv") else shaderCode("water.frag.spv"),
            .color_targets = &.{.{ .format = hdr_format }},
            .cull = .none,
        }),
        .underwater = try Local.pass(device, "underwater", shaderCode("underwater.frag.spv"), &.{.{ .format = hdr_format }}),
        .liquid_sim = try device.createComputePipeline(.{ .name = "liquid simulation", .shader = shaderCode("liquid_sim.comp.spv") }),
        // Each frame writes the average so far beside the last frame's,
        // which it reads; see pathtrace.frag.
        .path_trace = try Local.pass(device, "path tracing", if (device.ray_tracing) shaderCode("pathtrace_rt.frag.spv") else shaderCode("pathtrace.frag.spv"), &.{ .{ .format = .rgba32_float }, .{ .format = .rgba16_float } }),
        .path_denoise = try Local.pass(device, "path tracing denoise", shaderCode("pathtrace_denoise.frag.spv"), &.{.{ .format = .rgba16_float }}),
        .path_denoise_final = try Local.pass(device, "path tracing denoise (last)", shaderCode("pathtrace_denoise.frag.spv"), &.{.{ .format = hdr_format }}),
        .liquid_surface = try device.createGraphicsPipeline(.{
            .name = "liquid surface depth",
            .vertex = shaderCode("fullscreen.vert.spv"),
            .fragment = shaderCode("liquid_surface.frag.spv"),
            .color_targets = &.{.{ .format = .rg16_float }},
            .depth = .{ .write = true, .compare = .greater },
            .cull = .none,
        }),
        .liquid_shadow = try device.createGraphicsPipeline(.{
            .name = "liquid shadow",
            .vertex = shaderCode("liquid_shadow.vert.spv"),
            .fragment = shaderCode("liquid_shadow.frag.spv"),
            .depth = shadow_depth,
            .cull = .none,
        }),
        .liquid_depth = try device.createGraphicsPipeline(.{
            .name = "liquid depth",
            .vertex = shaderCode("liquid.vert.spv"),
            .fragment = shaderCode("liquid_depth.frag.spv"),
            .depth = .{ .write = true, .compare = .greater },
            .cull = .none,
        }),
        .liquid_thickness = try device.createGraphicsPipeline(.{
            .name = "liquid thickness",
            .vertex = shaderCode("liquid.vert.spv"),
            .fragment = shaderCode("liquid_thickness.frag.spv"),
            .color_targets = &.{.{ .format = .r16_float, .blend = .additive }},
            .cull = .none,
        }),
        .liquid_blur = try Local.pass(device, "liquid smoothing", shaderCode("liquid_blur.frag.spv"), &.{.{ .format = .r32_float }}),
        .liquid = try Local.pass(device, "liquid", shaderCode("liquid.frag.spv"), &.{.{ .format = hdr_format, .blend = .alpha }}),
        // The same surface again, into the depth buffer only.
        .water_depth = try device.createGraphicsPipeline(.{
            .name = "water depth",
            .vertex = shaderCode("water.vert.spv"),
            .depth = .{ .write = true, .compare = .greater },
            .cull = .none,
        }),
        .fluid_solid = try Local.pass(device, "fluid obstacles", shaderCode("fluid_solid.frag.spv"), &.{.{ .format = .r8_unorm }}),
        .fluid_solid_traced = try Local.pass(device, "fluid obstacles (scene)", if (device.ray_tracing) shaderCode("fluid_solid_rt.frag.spv") else shaderCode("fluid_solid.frag.spv"), &.{.{ .format = .r8_unorm }}),
        .fluid_carry = try Local.pass(device, "fluid carry", shaderCode("fluid_carry.frag.spv"), &.{ .{ .format = .rgba16_float }, .{ .format = .rgba16_float } }),
        .fluid = try Local.pass(device, "fluids", shaderCode("fluid.frag.spv"), &.{ .{ .format = hdr_format }, .{ .format = .rgba16_float } }),
        .fluid_motion = try Local.pass(device, "fluid motion", shaderCode("fluid_motion.frag.spv"), &.{.{ .format = .rg16_float, .blend = .alpha }}),
        .dof = try Local.pass(device, "depth of field", shaderCode("dof.frag.spv"), &.{.{ .format = hdr_format }}),
        .dof_composite = try Local.pass(device, "depth of field (join)", shaderCode("dof_composite.frag.spv"), &.{.{ .format = hdr_format }}),
        .motion_blur = try Local.pass(device, "motion blur", shaderCode("motion_blur.frag.spv"), &.{.{ .format = hdr_format }}),
        .fog = try Local.pass(device, "fog", shaderCode("fog.frag.spv"), &.{.{ .format = hdr_format }}),
        .fog_composite = try Local.pass(device, "fog composite", shaderCode("fog_composite.frag.spv"), &.{.{ .format = hdr_format, .blend = .premultiplied }}),
        .taa = try Local.pass(device, "taa", shaderCode("taa.frag.spv"), &.{.{ .format = hdr_format }}),
        .bloom_down = try Local.pass(device, "bloom down", shaderCode("bloom_down.frag.spv"), &.{.{ .format = bloom_format }}),
        .bloom_up = try Local.pass(device, "bloom up", shaderCode("bloom_up.frag.spv"), &.{.{ .format = bloom_format, .blend = .additive }}),
        .exposure = try device.createComputePipeline(.{ .name = "exposure", .shader = shaderCode("exposure.comp.spv") }),
        .pick = try device.createComputePipeline(.{ .name = "pick", .shader = shaderCode("pick.comp.spv") }),
        .particle_sim = try device.createComputePipeline(.{ .name = "particle simulation", .shader = shaderCode("particle_sim.comp.spv") }),
        .fluid_light = try device.createComputePipeline(.{ .name = "fluid light", .shader = shaderCode("fluid_light.comp.spv") }),
        .particle_sort_keys = try device.createComputePipeline(.{ .name = "particle sort keys", .shader = shaderCode("particle_sort_keys.comp.spv") }),
        .particle_sort = try device.createComputePipeline(.{ .name = "particle sort", .shader = shaderCode("particle_sort.comp.spv") }),
        .particles = try device.createGraphicsPipeline(.{
            .name = "particles",
            .vertex = shaderCode("particle.vert.spv"),
            .fragment = shaderCode("particle.frag.spv"),
            .color_targets = &.{ .{ .format = hdr_format, .blend = .premultiplied }, .{ .format = .rg16_float, .blend = .alpha } },
            .cull = .none,
        }),
        .particle_trails = try device.createGraphicsPipeline(.{
            .name = "particle trails",
            .vertex = shaderCode("particle_trail.vert.spv"),
            .fragment = shaderCode("particle.frag.spv"),
            .color_targets = &.{ .{ .format = hdr_format, .blend = .premultiplied }, .{ .format = .rg16_float, .blend = .alpha } },
            .cull = .none,
        }),
        .particle_mesh = try device.createGraphicsPipeline(.{
            .name = "mesh particles",
            .vertex = shaderCode("particle_mesh.vert.spv"),
            .fragment = shaderCode("particle_mesh.frag.spv"),
            .color_targets = &.{ .{ .format = hdr_format, .blend = .premultiplied }, .{ .format = .rg16_float, .blend = .alpha } },
            .depth = .{ .write = true, .compare = .greater_or_equal },
            .cull = .none,
        }),
        .probe_face = try Local.pass(device, "probe face", shaderCode("probe_face.frag.spv"), &.{.{ .format = hdr_format }}),
        .env_cube = try Local.pass(device, "env cube", shaderCode("env_cube.frag.spv"), &.{.{ .format = hdr_format }}),
        .env_sky = try Local.pass(device, "env sky", shaderCode("env_sky.frag.spv"), &.{.{ .format = hdr_format }}),
        .env_irradiance = try Local.pass(device, "env irradiance", shaderCode("env_irradiance.frag.spv"), &.{.{ .format = hdr_format }}),
        .env_prefilter = try Local.pass(device, "env prefilter", shaderCode("env_prefilter.frag.spv"), &.{.{ .format = hdr_format }}),
        .brdf_lut = try Local.pass(device, "brdf lut", shaderCode("brdf_lut.frag.spv"), &.{.{ .format = .rg16_float }}),
    };
}

const CullKind = enum { perspective, shadow };

/// Extracts world-space culling planes (normals pointing inward).
pub fn cullView(view_proj: Mat4, camera_position: Vec3, kind: CullKind) gpu.CullView {
    const row = struct {
        fn get(m: Mat4, index: usize) [4]f32 {
            return .{ m[index], m[4 + index], m[8 + index], m[12 + index] };
        }
    }.get;
    const r0 = row(view_proj, 0);
    const r1 = row(view_proj, 1);
    const r2 = row(view_proj, 2);
    const r3 = row(view_proj, 3);
    var result = gpu.CullView{
        .planes = undefined,
        .camera_position = camera_position,
        .plane_count = 5,
        .cone_culling = @intFromBool(kind == .perspective),
    };
    result.planes[0] = normalizePlane(addPlanes(r3, r0, 1));
    result.planes[1] = normalizePlane(addPlanes(r3, r0, -1));
    result.planes[2] = normalizePlane(addPlanes(r3, r1, 1));
    result.planes[3] = normalizePlane(addPlanes(r3, r1, -1));
    // Reverse-Z perspective: near is w - z >= 0 and there is no far plane.
    // Shadow views use forward Z and keep only the far plane (same
    // expression), so casters between the light and the slice stay in.
    result.planes[4] = normalizePlane(addPlanes(r3, r2, -1));
    result.planes[5] = .{ 0, 0, 0, 1 };
    return result;
}

fn addPlanes(a: [4]f32, b: [4]f32, sign: f32) [4]f32 {
    return .{ a[0] + sign * b[0], a[1] + sign * b[1], a[2] + sign * b[2], a[3] + sign * b[3] };
}

fn normalizePlane(plane: [4]f32) [4]f32 {
    const length = @sqrt(plane[0] * plane[0] + plane[1] * plane[1] + plane[2] * plane[2]);
    if (length < 1e-20) return .{ 0, 0, 0, 1 };
    return .{ plane[0] / length, plane[1] / length, plane[2] / length, plane[3] / length };
}

/// The sun cascades as last rendered, which is what shading must sample.
pub const CascadeCache = struct {
    valid: bool = false,
    /// Scene the cached maps were rendered from.
    scene: Scene = .invalid,
    count: u32 = 0,
    sun: Vec3 = .{ 0, 0, 0 },
    shadow_distance: f32 = 0,
    near: f32 = 0,
    cascades: Cascades = std.mem.zeroes(Cascades),
};

/// Extra radius given to cascades that are reused across frames, so camera
/// motion between refreshes stays inside the rendered area.
const cascade_margin = [gpu.cascade_count]f32{ 1.0, 1.05, 1.08, 1.12 };

/// The sun's shadow cascades: the matrix of each, where it ends along the
/// view and the area it covers.
pub const Cascades = struct {
    /// World-space bounding sphere each map covers (`radii` includes the
    /// reuse margin, `tight_radii` does not).
    centers: [gpu.cascade_count]Vec3,
    radii: [gpu.cascade_count]f32,
    tight_radii: [gpu.cascade_count]f32,
    view_proj: [gpu.cascade_count]Mat4,
    splits: [4]f32,
    texel_size: [4]f32,
};

/// Fits each cascade to a bounding sphere of its frustum slice and snaps it
/// to shadow-map texels, so the shadow does not shimmer as the camera moves
/// or rotates.
pub fn computeCascades(camera: Camera, view_matrix: Mat4, aspect: f32, sun_travel: Vec3, shadow_distance: f32, shadow_resolution: u32, count: u32) Cascades {
    const active: usize = std.math.clamp(count, 1, gpu.cascade_count);
    var result: Cascades = undefined;
    const inv_view = math.inverse(view_matrix);
    const near = camera.near;
    const far = @max(shadow_distance, near * 2);
    const tan_half = @tan(camera.fov_y * 0.5);
    const light_view = math.lookTo(.{ 0, 0, 0 }, sun_travel, .{ 0, 1, 0 });
    const blend = 0.85;
    var slice_near = near;
    for (0..gpu.cascade_count) |cascade| {
        if (cascade >= active) {
            // Unused cascades repeat the last one, so nothing selects them.
            inline for (.{ "view_proj", "splits", "texel_size", "centers", "radii", "tight_radii" }) |field| {
                @field(result, field)[cascade] = @field(result, field)[cascade - 1];
            }
            continue;
        }
        const fraction = @as(f32, @floatFromInt(cascade + 1)) / @as(f32, @floatFromInt(active));
        const logarithmic = near * std.math.pow(f32, far / near, fraction);
        const uniform = near + (far - near) * fraction;
        const slice_far = blend * logarithmic + (1 - blend) * uniform;

        var corners: [8]Vec3 = undefined;
        var center: Vec3 = .{ 0, 0, 0 };
        for ([_]f32{ slice_near, slice_far }, 0..) |distance, plane| {
            const half_height = distance * tan_half;
            const half_width = half_height * aspect;
            for ([_][2]f32{ .{ -1, -1 }, .{ 1, -1 }, .{ -1, 1 }, .{ 1, 1 } }, 0..) |corner, index| {
                const world = math.transformPoint(inv_view, .{ corner[0] * half_width, corner[1] * half_height, -distance });
                corners[plane * 4 + index] = world;
                center = math.add(center, math.scale(world, 1.0 / 8.0));
            }
        }
        var radius: f32 = 0;
        for (corners) |corner| radius = @max(radius, math.length(math.sub(corner, center)));
        result.centers[cascade] = center;
        result.tight_radii[cascade] = radius;
        radius = @ceil(radius * cascade_margin[cascade] * 16) / 16;
        result.radii[cascade] = radius;

        const texel = 2 * radius / @as(f32, @floatFromInt(shadow_resolution));
        var light_center = math.transformPoint(light_view, center);
        light_center[0] = @floor(light_center[0] / texel) * texel;
        light_center[1] = @floor(light_center[1] / texel) * texel;
        // Depth range reaches far back toward the light; casters in front of
        // the near plane are kept by depth clamping.
        const caster_distance = 500;
        const depth_center = -light_center[2];
        const projection = math.orthographic(
            light_center[0] - radius,
            light_center[0] + radius,
            light_center[1] - radius,
            light_center[1] + radius,
            depth_center - radius - caster_distance,
            depth_center + radius,
        );
        result.view_proj[cascade] = math.mul(projection, light_view);
        result.splits[cascade] = slice_far;
        result.texel_size[cascade] = texel;
        slice_near = slice_far;
    }
    return result;
}

test "range allocator reuses and coalesces freed ranges" {
    const gpa = std.testing.allocator;
    var ranges = RangeAllocator{ .capacity = 100 };
    defer ranges.free_ranges.deinit(gpa);
    const a = ranges.alloc(10).?;
    const b = ranges.alloc(20).?;
    const c = ranges.alloc(30).?;
    try std.testing.expectEqual(@as(u32, 0), a);
    try std.testing.expectEqual(@as(u32, 10), b);
    try std.testing.expectEqual(@as(u32, 30), c);
    ranges.free(gpa, a, 10);
    ranges.free(gpa, b, 20);
    try std.testing.expectEqual(@as(usize, 1), ranges.free_ranges.items.len);
    try std.testing.expectEqual(@as(u32, 0), ranges.alloc(25).?);
    ranges.free(gpa, c, 30);
    ranges.free(gpa, 0, 25);
    try std.testing.expectEqual(@as(u32, 0), ranges.top);
    try std.testing.expectEqual(@as(usize, 0), ranges.free_ranges.items.len);
    try std.testing.expect(ranges.alloc(101) == null);
}

test "culling planes keep points inside the frustum" {
    const view = math.lookAt(.{ 0, 0, 5 }, .{ 0, 0, 0 }, .{ 0, 1, 0 });
    const cull = cullView(math.mul(math.perspective(1.0, 1.0, 0.1), view), .{ 0, 0, 5 }, .perspective);
    const inside = [3]f32{ 0, 0, 0 };
    const behind = [3]f32{ 0, 0, 10 };
    for (cull.planes[0..cull.plane_count]) |plane|
        try std.testing.expect(plane[0] * inside[0] + plane[1] * inside[1] + plane[2] * inside[2] + plane[3] > 0);
    var rejected = false;
    for (cull.planes[0..cull.plane_count]) |plane| {
        if (plane[0] * behind[0] + plane[1] * behind[1] + plane[2] * behind[2] + plane[3] < 0) rejected = true;
    }
    try std.testing.expect(rejected);
}

test "halton sequence stays in the unit interval" {
    for (1..17) |index| {
        const value = halton(@intCast(index), 2);
        try std.testing.expect(value > 0 and value < 1);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), halton(1, 2), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 / 3.0), halton(1, 3), 1e-6);
}

/// Storage offset of the volume's first cell: probes are stored by world
/// cell modulo the grid size.
fn giScroll(volume: *const GiVolume) u32 {
    var packed_scroll: u32 = 0;
    inline for (0..3) |axis| {
        const wrapped: u32 = @intCast(@mod(volume.cell[axis], @as(i32, @intCast(volume.counts[axis]))));
        packed_scroll |= wrapped << (10 * axis);
    }
    return packed_scroll;
}

fn createGiPipelines(device: *rhi.Device) !GiPipelines {
    return .{
        .trace = try device.createComputePipeline(.{ .name = "gi trace", .shader = shaderCode("gi_trace.comp.spv") }),
        .irradiance = try device.createGraphicsPipeline(.{
            .name = "gi irradiance",
            .vertex = shaderCode("fullscreen.vert.spv"),
            .fragment = shaderCode("gi_irradiance.frag.spv"),
            // The steady atlas and the fast one, each with its own rate.
            .color_targets = &.{ .{ .format = hdr_format, .blend = .alpha }, .{ .format = hdr_format, .blend = .alpha } },
            .cull = .none,
        }),
        .clamp_upper = try device.createGraphicsPipeline(.{
            .name = "gi clamp upper",
            .vertex = shaderCode("fullscreen.vert.spv"),
            .fragment = shaderCode("gi_clamp.frag.spv"),
            .color_targets = &.{.{ .format = hdr_format, .blend = .minimum }},
            .cull = .none,
        }),
        .relocate = try device.createGraphicsPipeline(.{
            .name = "gi relocate",
            .vertex = shaderCode("fullscreen.vert.spv"),
            .fragment = shaderCode("gi_relocate.frag.spv"),
            .color_targets = &.{.{ .format = .rgba16_float }},
            .cull = .none,
        }),
        .clamp_lower = try device.createGraphicsPipeline(.{
            .name = "gi clamp lower",
            .vertex = shaderCode("fullscreen.vert.spv"),
            .fragment = shaderCode("gi_clamp.frag.spv"),
            .color_targets = &.{.{ .format = hdr_format, .blend = .maximum }},
            .cull = .none,
        }),
        .visibility = try device.createGraphicsPipeline(.{
            .name = "gi visibility",
            .vertex = shaderCode("fullscreen.vert.spv"),
            .fragment = shaderCode("gi_visibility.frag.spv"),
            .color_targets = &.{.{ .format = .rg16_float, .blend = .alpha }},
            .cull = .none,
        }),
    };
}

/// Shaders that `reloadShaders` has compiled, by name.
var shader_overrides: std.StringHashMapUnmanaged([]u8) = .empty;

/// Shader code by name: what `reloadShaders` last compiled, or else what
/// was built into the program.
pub fn shaderCode(comptime name: []const u8) []const u8 {
    if (shader_overrides.get(name)) |code| return code;
    return @embedFile(name);
}

/// Reads an IES LM-63 photometric file and returns brightness at 181
/// angles, 0 to 180 degrees from the fixture's axis.
fn parseIes(gpa: std.mem.Allocator, bytes: []const u8) ![]f32 {
    // Everything after the TILT line is whitespace-separated numbers.
    const tilt = std.mem.indexOf(u8, bytes, "TILT=") orelse return error.InvalidIes;
    const after_tilt = std.mem.indexOfScalarPos(u8, bytes, tilt, '\n') orelse return error.InvalidIes;
    var numbers: std.ArrayList(f32) = .empty;
    defer numbers.deinit(gpa);
    var tokens = std.mem.tokenizeAny(u8, bytes[after_tilt..], " \t\r\n,");
    while (tokens.next()) |token| try numbers.append(gpa, std.fmt.parseFloat(f32, token) catch return error.InvalidIes);
    // lamps, lumens, multiplier, vertical count, horizontal count, type,
    // units, width, length, height, ballast, future use, watts.
    if (numbers.items.len < 13) return error.InvalidIes;
    const multiplier = numbers.items[2];
    const vertical: usize = @intFromFloat(numbers.items[3]);
    const horizontal: usize = @intFromFloat(numbers.items[4]);
    if (vertical < 2 or horizontal < 1) return error.InvalidIes;
    if (numbers.items.len < 13 + vertical + horizontal + vertical * horizontal) return error.InvalidIes;
    const angles = numbers.items[13..][0..vertical];
    const candela = numbers.items[13 + vertical + horizontal ..][0 .. vertical * horizontal];

    const result = try gpa.alloc(f32, 181);
    errdefer gpa.free(result);
    for (result, 0..) |*out, degree| {
        const angle: f32 = @floatFromInt(degree);
        // Outside the measured range the fixture emits nothing.
        if (angle < angles[0] or angle > angles[vertical - 1]) {
            out.* = 0;
            continue;
        }
        var upper: usize = 1;
        while (upper < vertical - 1 and angles[upper] < angle) upper += 1;
        const span = angles[upper] - angles[upper - 1];
        const t = if (span > 0) (angle - angles[upper - 1]) / span else 0;
        var sum: f32 = 0;
        for (0..horizontal) |plane| {
            const low = candela[plane * vertical + upper - 1];
            const high = candela[plane * vertical + upper];
            sum += low + (high - low) * t;
        }
        out.* = sum / @as(f32, @floatFromInt(horizontal)) * multiplier;
    }
    return result;
}

test "an IES file becomes brightness by angle" {
    const file =
        \\IESNA:LM-63-2002
        \\[TEST] made up
        \\TILT=NONE
        \\1 1000 2 3 1 1 2 0 0 0
        \\1 1 100
        \\0 45 90
        \\0
        \\100 50 0
    ;
    const values = try parseIes(std.testing.allocator, file);
    defer std.testing.allocator.free(values);
    try std.testing.expectEqual(@as(usize, 181), values.len);
    try std.testing.expectApproxEqAbs(@as(f32, 200), values[0], 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 100), values[45], 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 150), values[22], 4);
    try std.testing.expectApproxEqAbs(@as(f32, 0), values[90], 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 0), values[120], 1e-3);
}

/// A font atlas as the GPU gets it: the three-channel field in red, green
/// and blue, the plain one in alpha. Caller frees.
fn fontTexels(gpa: std.mem.Allocator, baked: *const font_module.Baked) ![]u8 {
    const texels = try gpa.alloc(u8, baked.atlas.len * 4);
    for (baked.atlas, 0..) |distance, index| {
        const channels: [3]u8 = if (baked.msdf.len == baked.atlas.len * 3) baked.msdf[index * 3 ..][0..3].* else .{ distance, distance, distance };
        texels[index * 4 ..][0..4].* = .{ channels[0], channels[1], channels[2], distance };
    }
    return texels;
}
