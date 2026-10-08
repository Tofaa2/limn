//! High-level renderer: glTF scenes lit by a sun, local lights and an HDR
//! environment, drawn through a GPU-driven visibility-buffer pipeline.
//! Frame outline: see `renderScene` in `renderer/view_render.zig`.
const std = @import("std");
const rhi = @import("../rhi/rhi.zig");
const math = @import("../math.zig");
const gltf = @import("../asset/gltf.zig");
const gpu = @import("gpu.zig");
const animation = @import("animation.zig");
const bvh = @import("bvh.zig");
const handle = @import("../handle.zig");
const font_module = @import("font_baker").font;
const models_module = @import("renderer/models.zig");
const streaming_module = @import("renderer/streaming.zig");
const materials_module = @import("renderer/materials.zig");
const environments_module = @import("renderer/environments.zig");
const fonts_module = @import("renderer/fonts.zig");
const images_module = @import("renderer/images.zig");
const pipelines_module = @import("renderer/pipelines.zig");
const instances_module = @import("renderer/instances.zig");
const water_module = @import("renderer/water.zig");
const hair_module = @import("renderer/hair.zig");
const liquid_module = @import("renderer/liquid.zig");
const fluid_module = @import("renderer/fluid.zig");
const emitters_module = @import("renderer/emitters.zig");
const probes_module = @import("renderer/probes.zig");
const scenes_module = @import("renderer/scenes.zig");
const scene_update_module = @import("renderer/scene_update.zig");
const views_module = @import("renderer/views.zig");
const view_render_module = @import("renderer/view_render.zig");
const view_math_module = @import("renderer/view_math.zig");

const api = @import("api.zig");
const renderer_state = @import("state.zig");
const scene_pass = @import("scene_pass.zig");

pub const Mat4 = math.Mat4;
pub const Vec3 = math.Vec3;
pub const SceneFrame = scene_pass.SceneFrame;

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
pub const Hair = api.Hair;
pub const HairDesc = api.HairDesc;
pub const HairSimulation = api.HairSimulation;
pub const ImpostorDesc = api.ImpostorDesc;
pub const LightmapDesc = api.LightmapDesc;
const HairTag = api.HairTag;
pub const CollisionField = api.CollisionField;
const CollisionFieldTag = api.CollisionFieldTag;
const HairState = renderer_state.HairState;
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
pub const bloom_levels = renderer_state.bloom_levels;
pub const view_count = renderer_state.view_count;
pub const main_late_view = renderer_state.main_late_view;
pub const local_view_base = renderer_state.local_view_base;
pub const vsm_view_base = renderer_state.vsm_view_base;
pub const max_local_shadow_views = renderer_state.max_local_shadow_views;
pub const local_shadow_tiles_per_side = renderer_state.local_shadow_tiles_per_side;
const stream_budget_bytes = renderer_state.stream_budget_bytes;
const RangeAllocator = renderer_state.RangeAllocator;
const Pool = renderer_state.Pool;
pub const FrameArena = renderer_state.FrameArena;
const ShadeVariant = renderer_state.ShadeVariant;
pub const ShadeVariantJob = renderer_state.ShadeVariantJob;
pub const shadeVariantDesc = renderer_state.shadeVariantDesc;
pub const runShadeVariantJob = renderer_state.runShadeVariantJob;
pub const ModelMesh = renderer_state.ModelMesh;
pub const MaterialTextures = renderer_state.MaterialTextures;
const ModelEntry = renderer_state.ModelEntry;
const EnvironmentEntry = renderer_state.EnvironmentEntry;
pub const SceneData = renderer_state.SceneData;
const EntityData = renderer_state.EntityData;
pub const TransparentDraw = renderer_state.TransparentDraw;
const BlasJob = renderer_state.BlasJob;
pub const BoundsJob = renderer_state.BoundsJob;
pub const SkinJob = renderer_state.SkinJob;
pub const MadeTextures = renderer_state.MadeTextures;
pub const ViewState = renderer_state.ViewState;
pub const ViewData = renderer_state.ViewData;
const Pipelines = renderer_state.Pipelines;
const GiPipelines = renderer_state.GiPipelines;
pub const GiVolume = renderer_state.GiVolume;
pub const gi_irradiance_texels = renderer_state.gi_irradiance_texels;
pub const gi_visibility_texels = renderer_state.gi_visibility_texels;
pub const gi_probe_limit = renderer_state.gi_probe_limit;
const TonemapPipeline = renderer_state.TonemapPipeline;
const PickRequest = renderer_state.PickRequest;
pub const ReflectionTargets = renderer_state.ReflectionTargets;
pub const cloud_noise_size = renderer_state.cloud_noise_size;
pub const cloud_noise_tiles = renderer_state.cloud_noise_tiles;
const MaterialPipelines = renderer_state.MaterialPipelines;
pub const packTint = renderer_state.packTint;
pub const max_fluids = renderer_state.max_fluids;
const max_pose_threads = renderer_state.max_pose_threads;
pub const liquid_cell_slots = renderer_state.liquid_cell_slots;
const LiquidState = renderer_state.LiquidState;
pub const max_hair_colliders = renderer_state.max_hair_colliders;
pub const hair_density_size = renderer_state.hair_density_size;
pub const CollisionFieldState = renderer_state.CollisionFieldState;
pub const water_quads = renderer_state.water_quads;
const WaterState = renderer_state.WaterState;
const FluidState = renderer_state.FluidState;
const InstanceGroupData = renderer_state.InstanceGroupData;
pub const EmitterData = renderer_state.EmitterData;
const ProbeData = renderer_state.ProbeData;
const PickPending = renderer_state.PickPending;
const DrawPipelines = renderer_state.DrawPipelines;
const ImageEntry = renderer_state.ImageEntry;

const bakeLoadedClouds = environments_module.bakeLoadedClouds;
const bakeSky = environments_module.bakeSky;
const buildPendingBlas = scene_update_module.buildPendingBlas;
const captureProbes = probes_module.captureProbes;
const compactGeometry = scene_update_module.compactGeometry;
const createGiPipelines = pipelines_module.createGiPipelines;
const createPipelines = pipelines_module.createPipelines;
const destroyFluidTextures = fluid_module.destroyFluidTextures;
const dropShadeVariants = pipelines_module.dropShadeVariants;
const finalizeEnvironment = environments_module.finalizeEnvironment;
const finalizeModel = models_module.finalizeModel;
const freeEntityStorage = scenes_module.freeEntityStorage;
const freeEnvironment = environments_module.freeEnvironment;
const freeHair = hair_module.freeHair;
const freeModel = models_module.freeModel;
const freeScene = scenes_module.freeScene;
const insertView = views_module.insertView;
const registerFont = fonts_module.registerFont;
const renderView = view_render_module.renderView;
const targetWritten = views_module.targetWritten;
const updateGeometryStreaming = streaming_module.updateGeometryStreaming;
const updateTextureStreaming = streaming_module.updateTextureStreaming;

/// Owns the device and everything made through it. Methods lock internally
/// (see `lock`), so other threads may load and edit while one renders.
/// Only `device` and `options` are public fields.
pub const Renderer = struct {
    gpa: std.mem.Allocator,
    /// Fixed for the renderer's lifetime.
    options: Options,
    io: std.Io,
    /// For custom passes and offscreen targets.
    device: *rhi.Device,

    pipelines: Pipelines,
    tonemap_pipelines: std.ArrayList(TonemapPipeline) = .empty,
    /// Shading pass builds, one per feature set seen.
    shade_variants: std.ArrayList(ShadeVariant) = .empty,
    /// This frame's animated entities.
    posed: std.ArrayList(Entity) = .empty,
    /// Progress through the round of acceleration structure refits.
    refit_cursor: usize = 0,
    /// Count of loaded models with per-texture UV transforms.
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
    /// Per-mesh triangle BVHs for the path tracing fallback.
    bvh_nodes: Pool,
    bvh_items: Pool,
    /// Mesh-space box of each mesh with a BVH, by mesh record index.
    mesh_boxes: std.ArrayList(?[2][3]f32) = .empty,
    meshes: Pool,
    materials: Pool,

    arenas: [rhi.frames_in_flight]FrameArena,
    cull_commands: ?rhi.Buffer = null,
    cull_capacity: u32 = 0,
    /// Views `cull_commands` has room for.
    cull_views: u32 = 0,
    /// Draws each view's second list (masked, two-sided, LOD-fading) has
    /// room for; the first has `cull_capacity`.
    cull_masked_capacity: u32 = 0,
    cull_counts: rhi.Buffer,
    /// One `gpu.CullDispatch` per view of a frame.
    cull_dispatch: rhi.Buffer,
    /// The `gpu.DrawIndirect` that draws a view's impostors.
    impostor_draw: rhi.Buffer,
    scratch_impostors: std.ArrayList(gpu.Impostor) = .empty,
    /// Two `gpu.MeshDraw`s per view, one per meshlet list; mesh shaders only.
    cull_mesh_draws: rhi.Buffer,
    count_readback: [rhi.frames_in_flight]rhi.Buffer = undefined,
    /// Texture streaming round counter (see `EntityData.seen_round`).
    seen_round: u64 = 0,
    /// Bound in place of cascades for views drawn without shadows.
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
    hairs: handle.HandleTable(HairState, HairTag),
    collision_fields: handle.HandleTable(CollisionFieldState, CollisionFieldTag),
    liquids: handle.HandleTable(LiquidState, LiquidTag),
    /// Ray-tracing stand-in box for liquids; made with the first liquid.
    liquid_proxy_model: ?Model = null,
    instance_groups: handle.HandleTable(InstanceGroupData, InstanceGroupTag),
    /// Bumped whenever the set of ready models changes.
    asset_generation: u64 = 1,
    loading_count: u32 = 0,

    views: handle.HandleTable(ViewData, ViewTag),
    main_view: View = undefined,
    /// Targets drawn to this frame; the first view to touch one clears it.
    frame_targets: [16]rhi.Texture = undefined,
    frame_target_count: u32 = 0,
    /// Scene views recorded so far this frame.
    frame_scene_views: u32 = 0,
    /// The upscaler of the view this frame generates frames from, and whether
    /// its history was reset.
    generating: ?@import("ffx.zig").Upscaler = null,
    generating_reset: bool = false,
    /// Scene whose lights the local shadow atlas currently holds.
    local_shadow_scene: ?Scene = null,
    local_shadow_frame: u64 = std.math.maxInt(u64),
    /// Key of what the atlas was last drawn from.
    local_shadow_key: u64 = 0,
    /// Whether each tile held a mover when last drawn.
    local_tile_had_mover: [max_local_shadow_views]bool = @splat(false),
    /// A computed sky is waiting to be rebuilt.
    skies_dirty: bool = false,
    /// Pipelines of custom material shaders; slot 0 is the standard material.
    material_shaders: [32]?MaterialPipelines = @splat(null),
    /// Loaded materials using each slot.
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
    /// Deformed-mesh acceleration structures to rebuild after skinning.
    blas_jobs: std.ArrayList(BlasJob) = .empty,
    scratch_locals: std.ArrayList(animation.Local) = .empty,
    scratch_refs: std.ArrayList(gpu.MeshletRef) = .empty,
    scratch_instances: std.ArrayList(gpu.Instance) = .empty,
    scratch_static_cull: std.ArrayList(gpu.StaticCull) = .empty,

    /// Creates the device and renderer. `gpa` and `io` are kept and must
    /// outlive it. Missing optional features (ray tracing, BC, HDR output)
    /// are not errors. Free with `deinit`.
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
            .mesh_shaders = options.mesh_shaders,
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
            .cull_mesh_draws = try device.createBuffer(.{ .name = "cull mesh draws", .size = view_count * 2 * @sizeOf(gpu.MeshDraw), .usage = .{ .storage = true, .indirect = true, .copy_dst = true } }),
            .impostor_draw = try device.createBuffer(.{ .name = "impostor draw", .size = @sizeOf(gpu.DrawIndirect), .usage = .{ .storage = true, .indirect = true, .copy_dst = true } }),
            .cull_dispatch = try device.createBuffer(.{ .name = "cull dispatch", .size = view_count * @sizeOf(gpu.CullDispatch), .usage = .{ .storage = true, .indirect = true, .copy_dst = true } }),
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
            .hairs = .init(gpa),
            .collision_fields = .init(gpa),
            .liquids = .init(gpa),
            .instance_groups = .init(gpa),
        };
        for (&self.arenas) |*arena| arena.* = try FrameArena.init(device, 4 * 1024 * 1024);
        if (device.ray_tracing) self.gi_pipelines = try createGiPipelines(device);
        for (&self.count_readback) |*buffer| {
            buffer.* = try device.createBuffer(.{ .name = "cull count readback", .size = (view_count * 2 + 1) * @sizeOf(u32), .usage = .{}, .memory = .gpu_to_cpu });
            @memset(device.mapped(buffer.*), 0);
        }
        self.main_view = try insertView(self);
        self.pick_buffer = try device.createBuffer(.{ .name = "pick", .size = @sizeOf(gpu.Pick), .usage = .{ .storage = true, .copy_src = true } });
        for (&self.pick_readback) |*buffer| {
            buffer.* = try device.createBuffer(.{ .name = "pick readback", .size = @sizeOf(gpu.Pick), .usage = .{}, .memory = .gpu_to_cpu });
            @memset(device.mapped(buffer.*), 0);
        }

        self.default_font = try gpa.create(Font);
        self.default_font.* = try font_module.load(gpa, @embedFile("fonts/DejaVuSans.ttf"), font_module.default_ranges);
        try registerFont(self, self.default_font);
        if (options.asset_cache_max_bytes != 0) if (options.asset_cache_dir) |directory| {
            _ = gltf.trimCache(gpa, self.io, directory, options.asset_cache_max_bytes) catch |err| std.log.warn("asset cache not trimmed: {}", .{err});
        };

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

    /// Waits for the GPU, then destroys everything, including the device and
    /// the renderer. Takes no lock: no other thread may be using it.
    pub fn deinit(self: *Renderer) void {
        const device = self.device;
        device.waitIdle() catch {};
        while (self.entities.popAny()) |entity| freeEntityStorage(self, entity);
        while (self.scenes.popAny()) |scene_value| {
            var scene = scene_value;
            freeScene(self, &scene);
        }
        while (self.models.popAny()) |model_value| {
            var model = model_value;
            freeModel(self, &model);
        }
        while (self.environments.popAny()) |environment_value| {
            var environment = environment_value;
            freeEnvironment(self, &environment);
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
            destroyFluidTextures(self, &state);
        }
        self.fluids.deinit();
        while (self.waters.popAny()) |water| for (water.state) |texture| device.destroyTexture(texture);
        self.waters.deinit();
        while (self.hairs.popAny()) |hair| freeHair(self, hair);
        self.hairs.deinit();
        while (self.collision_fields.popAny()) |field| device.destroyTexture(field.texture);
        self.collision_fields.deinit();
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
        dropShadeVariants(self);
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
        device.destroyBuffer(self.cull_dispatch);
        device.destroyBuffer(self.impostor_draw);
        self.scratch_impostors.deinit(self.gpa);
        device.destroyBuffer(self.cull_mesh_draws);
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
        self.scratch_static_cull.deinit(self.gpa);
        var overrides = pipelines_module.shader_overrides.valueIterator();
        while (overrides.next()) |code| self.gpa.free(code.*);
        pipelines_module.shader_overrides.deinit(self.gpa);
        pipelines_module.shader_overrides = .empty;
        const gpa = self.gpa;
        const io = self.io;
        gpa.destroy(self);
        gltf.releaseLibraries(io);
        device.deinit();
    }

    /// Records the new framebuffer size in pixels; the swapchain is rebuilt
    /// at the next frame. Safe from any thread.
    pub fn resize(self: *Renderer, width: u32, height: u32) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.device.resize(width, height);
    }

    /// How `Settings.path_tracing` would run on this device. Safe from any
    /// thread.
    pub fn pathTracing(self: *const Renderer) PathTracing {
        if (self.device.ray_tracing) return .hardware;
        return if (self.options.path_tracing_fallback) .shader else .unavailable;
    }

    /// Last frame's counters, with current loading count and GPU memory use.
    /// Safe from any thread.
    pub fn getStats(self: *Renderer) Stats {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var stats = self.stats;
        stats.models_loading = self.loading_count;
        stats.gpu_memory_bytes = self.device.memoryStats().used_bytes;
        return stats;
    }

    pub const loadModel = models_module.loadModel;
    pub const createModel = models_module.createModel;
    pub const modelState = models_module.modelState;
    pub const modelError = models_module.modelError;
    pub const modelInfo = models_module.modelInfo;
    pub const animationCount = models_module.animationCount;
    pub const animationInfo = models_module.animationInfo;
    pub const findNode = models_module.findNode;
    pub const rootMotion = models_module.rootMotion;
    pub const findAnimation = models_module.findAnimation;
    pub const destroyModel = models_module.destroyModel;
    pub const loadEnvironment = environments_module.loadEnvironment;
    pub const createSky = environments_module.createSky;
    pub const setSky = environments_module.setSky;
    pub const environmentState = environments_module.environmentState;
    pub const environmentInfo = environments_module.environmentInfo;
    pub const destroyEnvironment = environments_module.destroyEnvironment;

    /// True while any model or environment is still streaming in.
    pub fn isLoading(self: *Renderer) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.loading_count != 0;
    }

    /// Blocks until every pending asset is on the GPU. For tools and tests.
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
                    try buildPendingBlas(self, &cmd, null);
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
    /// `budget_bytes` on texture uploads.
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
            const finished = finalizeModel(self, entry, &budget) catch |err| blk: {
                std.log.err("model load failed: {}", .{err});
                freeModel(self, entry);
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
            finalizeEnvironment(self, entry, cmd) catch |err| {
                std.log.err("environment load failed: {}", .{err});
                freeEnvironment(self, entry);
                entry.state = .failed;
                entry.failure = err;
            };
            self.loading_count -= 1;
        };
        return progressed;
    }

    /// Takes the renderer lock. Public methods lock internally; hold it only
    /// to use `device` from a non-rendering thread. Not reentrant: call no
    /// renderer methods while holding it.
    pub fn lock(self: *Renderer) void {
        self.mutex.lockUncancelable(self.io);
    }

    /// Must be called from the thread that took the lock.
    pub fn unlock(self: *Renderer) void {
        self.mutex.unlock(self.io);
    }

    pub const defaultFont = fonts_module.defaultFont;
    pub const loadFont = fonts_module.loadFont;
    pub const loadFontFromMemory = fonts_module.loadFontFromMemory;
    pub const prepareLigatures = fonts_module.prepareLigatures;
    pub const prepareText = fonts_module.prepareText;
    pub const prepareTextWith = fonts_module.prepareTextWith;
    pub const destroyFont = fonts_module.destroyFont;
    pub const createImageCompressed = images_module.createImageCompressed;
    pub const createImage = images_module.createImage;
    pub const readImageFile = images_module.readImageFile;
    pub const loadImage = images_module.loadImage;
    pub const trimAssetCache = images_module.trimAssetCache;
    pub const writeKtx2 = images_module.writeKtx2;
    pub const createLightProfile = images_module.createLightProfile;
    pub const loadLightProfile = images_module.loadLightProfile;
    pub const destroyImage = images_module.destroyImage;
    pub const createView = views_module.createView;
    pub const destroyView = views_module.destroyView;
    pub const createTarget = views_module.createTarget;
    pub const destroyTarget = views_module.destroyTarget;
    pub const targetImage = views_module.targetImage;
    pub const reloadShaders = pipelines_module.reloadShaders;
    pub const createMaterialShader = materials_module.createMaterialShader;
    pub const destroyMaterialShader = materials_module.destroyMaterialShader;
    pub const setMaterialShader = materials_module.setMaterialShader;
    pub const setMaterialTextures = materials_module.setMaterialTextures;
    pub const setClouds = scenes_module.setClouds;
    pub const cloudFlash = scenes_module.cloudFlash;
    pub const setDecals = scenes_module.setDecals;
    pub const createInstances = instances_module.createInstances;
    pub const setInstances = instances_module.setInstances;
    pub const setInstanceColors = instances_module.setInstanceColors;
    pub const setInstanceParams = instances_module.setInstanceParams;
    pub const setInstancesImpostor = instances_module.setInstancesImpostor;
    pub const setInstancesPose = instances_module.setInstancesPose;
    pub const destroyInstances = instances_module.destroyInstances;
    pub const createWater = water_module.createWater;
    pub const setWater = water_module.setWater;
    pub const addRipple = water_module.addRipple;
    pub const destroyWater = water_module.destroyWater;
    pub const createHair = hair_module.createHair;
    pub const createCollisionField = hair_module.createCollisionField;
    pub const destroyCollisionField = hair_module.destroyCollisionField;
    pub const setHairSimulation = hair_module.setHairSimulation;
    pub const setHairTransform = hair_module.setHairTransform;
    pub const destroyHair = hair_module.destroyHair;
    pub const createLiquid = liquid_module.createLiquid;
    pub const setLiquid = liquid_module.setLiquid;
    pub const liquidParticles = liquid_module.liquidParticles;
    pub const destroyLiquid = liquid_module.destroyLiquid;
    pub const createFluid = fluid_module.createFluid;
    pub const setFluid = fluid_module.setFluid;
    pub const resetFluid = fluid_module.resetFluid;
    pub const fluidImage = fluid_module.fluidImage;
    pub const saveFluidImage = fluid_module.saveFluidImage;
    pub const recordFluidFlipbook = fluid_module.recordFluidFlipbook;
    pub const fluidFlipbookFrames = fluid_module.fluidFlipbookFrames;
    pub const saveFluidFlipbook = fluid_module.saveFluidFlipbook;
    pub const destroyFluid = fluid_module.destroyFluid;
    pub const createEmitter = emitters_module.createEmitter;
    pub const emitterSortKeys = emitters_module.emitterSortKeys;
    pub const setEmitter = emitters_module.setEmitter;
    pub const createReflectionProbe = probes_module.createReflectionProbe;
    pub const setReflectionProbe = probes_module.setReflectionProbe;
    pub const updateReflectionProbe = probes_module.updateReflectionProbe;
    pub const destroyReflectionProbe = probes_module.destroyReflectionProbe;
    pub const destroyEmitter = emitters_module.destroyEmitter;
    pub const waitForShaderVariants = pipelines_module.waitForShaderVariants;

    /// Asks which entity is under `pixel` (in the view's pixels; null is the
    /// main view). The answer arrives through `takePick` a few frames later.
    /// A new request replaces an unserved one. Blended surfaces do not pick.
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

    /// Collects the pick the GPU wrote in this frame slot's previous use.
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

    pub const createScene = scenes_module.createScene;
    pub const destroyScene = scenes_module.destroyScene;
    pub const setSun = scenes_module.setSun;
    pub const setEnvironment = scenes_module.setEnvironment;
    pub const setLights = scenes_module.setLights;
    pub const spawn = scenes_module.spawn;
    pub const despawn = scenes_module.despawn;
    pub const setTransform = scenes_module.setTransform;
    pub const teleport = scenes_module.teleport;
    pub const setTint = scenes_module.setTint;
    pub const setParams = scenes_module.setParams;
    pub const setMorphWeights = scenes_module.setMorphWeights;
    pub const bakeLightmap = scenes_module.bakeLightmap;
    pub const lightmapProgress = scenes_module.lightmapProgress;
    pub const setVisible = scenes_module.setVisible;
    pub const setPose = scenes_module.setPose;

    /// Renders one frame; false when skipped because the window has no
    /// drawable surface. Call from one thread at a time; the lock is held
    /// only while recording, not while waiting for the GPU or display.
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
                failure = err;
                device.closeFailedFrame();
                for (self.frame_targets[0..self.frame_target_count]) |target| {
                    const is_backbuffer = if (frame.backbuffer) |backbuffer| std.meta.eql(backbuffer, target) else false;
                    if (!is_backbuffer) frame.cmd.transition(target, .shader_read);
                }
                if (frame.backbuffer) |backbuffer| if (!targetWritten(self, backbuffer)) {
                    if (frame.cmd.beginRendering(.{ .color = &.{.{ .texture = backbuffer, .load = .clear, .clear = .{ 0, 0, 0, 1 } }} })) |_|
                        frame.cmd.endRendering()
                    else |_| {}
                };
            };
            self.stats.indirect_draws = frame.cmd.indirect_draws;
            device.setFrameGenerator(if (self.generating != null and failure == null) .{ .context = self, .generate = generateFrame } else null);
            try device.submitFrame();
            self.stats.cpu_ms = @as(f32, @floatFromInt(cpu_start.untilNow(self.io).raw.nanoseconds)) / 1e6;
            self.frame_index += 1;
            self.time += desc.delta_time;
        }
        try device.presentFrame();
        if (failure) |err| return err;
        return true;
    }

    fn generateFrame(context: *anyopaque, cmd: *rhi.CommandEncoder, shown: rhi.Texture, output: rhi.Texture) bool {
        const self: *Renderer = @ptrCast(@alignCast(context));
        const upscaler = self.generating orelse return false;
        return upscaler.generate(self.device, cmd, shown, output, self.generating_reset);
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
        self.generating = null;
        self.resolvePick(@intCast(frame.index % rhi.frames_in_flight));

        cmd.beginScope("streaming");
        _ = try self.pumpAssets(cmd, stream_budget_bytes);
        try updateTextureStreaming(self, frame, desc);
        try updateGeometryStreaming(self, desc);
        if (self.skies_dirty) {
            self.skies_dirty = false;
            for (self.environments.slots.items) |*slot| if (slot.value) |*entry| {
                if (entry.sky_desc == null) {
                    if (entry.sky_dirty) try bakeLoadedClouds(self, entry, cmd);
                } else if (entry.sky_dirty or entry.bake_step != 0) try bakeSky(self, entry, cmd, false);
            };
        }
        try cmd.flushUploads();
        if (try compactGeometry(self, cmd)) try cmd.flushUploads();
        try buildPendingBlas(self, cmd, frame.index);
        cmd.endScope();

        for (desc.views) |view_desc| try renderView(self, frame, view_desc, desc.delta_time, arena);
        try captureProbes(self, frame, desc.delta_time, arena);
        if (frame.backbuffer) |backbuffer| if (!targetWritten(self, backbuffer)) {
            try cmd.beginRendering(.{ .color = &.{.{ .texture = backbuffer, .load = .clear, .clear = .{ 0, 0, 0, 1 } }} });
            cmd.endRendering();
        };
    }

    /// See `Quality.recommended`. Safe from any thread.
    pub fn recommendedQuality(self: *const Renderer) Quality {
        return Quality.recommended(self.device.adapterInfo());
    }

    /// True when the window surface is HDR10.
    pub fn hdrActive(self: *Renderer) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.device.hdr_active;
    }

    pub const shiftScene = scenes_module.shiftScene;
    pub const sceneOrigin = scenes_module.sceneOrigin;
    pub const setGiVolume = scenes_module.setGiVolume;
};

pub const cullView = view_math_module.cullView;
pub const CascadeCache = view_math_module.CascadeCache;
pub const Cascades = view_math_module.Cascades;
pub const computeCascades = view_math_module.computeCascades;

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

pub const shaderCode = pipelines_module.shaderCode;
