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
pub const CollisionField = api.CollisionField;
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
pub const Dlss = api.Dlss;
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
pub const packTint = renderer_state.packTint;
pub const max_fluids = renderer_state.max_fluids;
const max_worker_threads = renderer_state.max_worker_threads;
const EntityEdit = renderer_state.EntityEdit;
const EntityMark = renderer_state.EntityMark;
pub const liquid_cell_slots = renderer_state.liquid_cell_slots;
pub const max_hair_colliders = renderer_state.max_hair_colliders;
pub const hair_density_size = renderer_state.hair_density_size;
pub const CollisionFieldState = renderer_state.CollisionFieldState;
pub const water_quads = renderer_state.water_quads;
pub const EmitterData = renderer_state.EmitterData;
const PickPending = renderer_state.PickPending;
const DrawPipelines = renderer_state.DrawPipelines;

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
/// (see `lock`), so other threads may load and edit while one renders; the
/// entity setters do not wait for a frame that is being recorded.
///
/// A handle whose object was destroyed is never an error to set or destroy:
/// setters and `destroy` do nothing, and queries answer null, 0 or `.failed`.
/// Only making something from one fails, with `error.InvalidScene` and the
/// like.
///
/// Everything about one kind of object is under its field: `models`, `scenes`,
/// `entities` and so on. Those, `device` and `options` are the public fields.
pub const Renderer = struct {
    gpa: std.mem.Allocator,
    /// Fixed for the renderer's lifetime.
    options: Options,
    io: std.Io,
    /// For custom passes and offscreen targets.
    device: *rhi.Device,

    models: models_module.Models,
    materials: materials_module.Materials,
    environments: environments_module.Environments,
    scenes: scenes_module.Scenes,
    entities: scenes_module.Entities,
    instances: instances_module.Instances,
    emitters: emitters_module.Emitters,
    probes: probes_module.Probes,
    fluids: fluid_module.Fluids,
    waters: water_module.Waters,
    liquids: liquid_module.Liquids,
    hairs: hair_module.Hairs,
    views: views_module.Views,
    fonts: fonts_module.Fonts = .{},
    images: images_module.Images = .{},
    shaders: pipelines_module.Shaders = .{},

    pipelines: Pipelines,
    tonemap_pipelines: std.ArrayList(TonemapPipeline) = .empty,
    /// Shading pass builds, one per feature set seen.
    shade_variants: std.ArrayList(ShadeVariant) = .empty,
    /// This frame's animated entities.
    /// Progress through the round of acceleration structure refits.
    refit_cursor: usize = 0,
    /// Count of loaded models with per-texture UV transforms.
    texture_transform_users: u32 = 0,
    pose_scratch: [max_worker_threads]std.ArrayList(animation.Local) = @splat(.empty),
    prepare_chunks: std.ArrayList(renderer_state.PrepareChunk) = .empty,
    draw_pipelines: std.ArrayList(DrawPipelines) = .empty,
    /// Guards all renderer and device state; see `lock`.
    mutex: std.Io.Mutex = .init,
    /// Each entity's transform by slot, now and as of the last prepared
    /// frame, and its bookkeeping. Apart from `EntityData` so that moving
    /// many entities touches little memory.
    entity_transforms: std.array_list.Aligned(Mat4, .@"64") = .empty,
    entity_previous: std.array_list.Aligned(Mat4, .@"64") = .empty,
    entity_marks: std.ArrayList(EntityMark) = .empty,
    /// Entity edits made while the lock was taken, and the ones being made;
    /// see `queueEdit`.
    pending: std.ArrayList(EntityEdit) = .empty,
    applying: std.ArrayList(EntityEdit) = .empty,
    pending_mutex: std.Io.Mutex = .init,
    pending_any: std.atomic.Value(bool) = .init(false),
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

    /// Ray-tracing stand-in box for liquids; made with the first liquid.
    liquid_proxy_model: ?Model = null,
    /// Bumped whenever the set of ready models changes.
    asset_generation: u64 = 1,
    loading_count: u32 = 0,

    main_view: View = undefined,
    /// Targets drawn to this frame; the first view to touch one clears it.
    frame_targets: [16]rhi.Texture = undefined,
    frame_target_count: u32 = 0,
    /// Scene views recorded so far this frame.
    frame_scene_views: u32 = 0,
    /// The upscaler of the view this frame generates frames from, and whether
    /// its history was reset.
    /// What DLSS offers on this device.
    dlss: @import("dlss.zig").Library = .{},
    generating: ?@import("ffx.zig").Upscaler = null,
    generating_reset: bool = false,
    generating_failed: bool = false,
    /// Scene whose lights the local shadow atlas currently holds.
    local_shadow_scene: ?Scene = null,
    local_shadow_frame: u64 = std.math.maxInt(u64),
    /// Key of what the atlas was last drawn from.
    local_shadow_key: u64 = 0,
    /// Whether each tile held a mover when last drawn.
    local_tile_had_mover: [max_local_shadow_views]bool = @splat(false),
    /// A computed sky is waiting to be rebuilt.
    skies_dirty: bool = false,
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
    scratch_settling: std.ArrayList([2]u32) = .empty,
    scratch_moved: std.ArrayList([2]u32) = .empty,
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
            .nvidia_ngx = @import("dlss.zig").available,
        });
        errdefer device.deinit();
        gltf.acquireLibraries(io);
        errdefer gltf.releaseLibraries(io);

        const self = try gpa.create(Renderer);
        errdefer gpa.destroy(self);
        pipelines_module.acquireOverrides();
        errdefer pipelines_module.releaseOverrides();
        const storage = rhi.BufferUsage{ .storage = true, .copy_src = true, .copy_dst = true };
        const geometry = rhi.BufferUsage{ .storage = true, .index = true, .copy_src = true, .copy_dst = true, .acceleration_input = true };
        self.* = .{
            .gpa = gpa,
            .options = options,
            .io = io,
            .device = device,
            .dlss = @import("dlss.zig").Library.start(device),
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
            .materials = .{ .pool = try Pool.init(device, "materials", @sizeOf(gpu.Material), 1 << 12, storage) },
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
            .models = .{ .table = .init(gpa) },
            .environments = .{ .table = .init(gpa) },
            .scenes = .{ .table = .init(gpa) },
            .views = .{ .table = .init(gpa) },
            .entities = .{ .table = .init(gpa) },
            .emitters = .{ .table = .init(gpa) },
            .probes = .{ .table = .init(gpa) },
            .fluids = .{ .table = .init(gpa) },
            .waters = .{ .table = .init(gpa) },
            .hairs = .{ .table = .init(gpa), .fields = .init(gpa) },
            .liquids = .{ .table = .init(gpa) },
            .instances = .{ .table = .init(gpa) },
        };
        for (&self.arenas) |*arena| arena.* = try FrameArena.init(device, 4 * 1024 * 1024);
        if (device.ray_tracing) self.gi_pipelines = try createGiPipelines(device);
        for (&self.count_readback) |*buffer| {
            buffer.* = try device.createBuffer(.{ .name = "cull count readback", .size = (view_count * 2 + 1) * @sizeOf(u32), .usage = .{}, .memory = .gpu_to_cpu });
            @memset(device.mapped(buffer.*), 0);
        }
        self.main_view = try insertView(self);
        errdefer self.views.table.deinit();
        self.pick_buffer = try device.createBuffer(.{ .name = "pick", .size = @sizeOf(gpu.Pick), .usage = .{ .storage = true, .copy_src = true } });
        for (&self.pick_readback) |*buffer| {
            buffer.* = try device.createBuffer(.{ .name = "pick readback", .size = @sizeOf(gpu.Pick), .usage = .{}, .memory = .gpu_to_cpu });
            @memset(device.mapped(buffer.*), 0);
        }

        self.fonts.default_font = try gpa.create(Font);
        errdefer gpa.destroy(self.fonts.default_font);
        self.fonts.default_font.* = try font_module.load(gpa, @embedFile("fonts/DejaVuSans.ttf"), font_module.default_ranges);
        errdefer self.fonts.default_font.deinit();
        try registerFont(self, self.fonts.default_font);
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
        self.pending.deinit(self.gpa);
        self.applying.deinit(self.gpa);
        self.entity_transforms.deinit(self.gpa);
        self.entity_previous.deinit(self.gpa);
        self.entity_marks.deinit(self.gpa);
        while (self.entities.table.popAny()) |entity| freeEntityStorage(self, entity);
        while (self.scenes.table.popAny()) |scene_value| {
            var scene = scene_value;
            freeScene(self, &scene);
        }
        while (self.models.table.popAny()) |model_value| {
            var model = model_value;
            freeModel(self, &model);
        }
        while (self.environments.table.popAny()) |environment_value| {
            var environment = environment_value;
            freeEnvironment(self, &environment);
        }
        self.entities.table.deinit();
        while (self.emitters.table.popAny()) |emitter| {
            device.destroyBuffer(emitter.buffer);
            if (emitter.order) |order| device.destroyBuffer(order);
        }
        self.emitters.table.deinit();
        self.probes.table.deinit();
        while (self.fluids.table.popAny()) |fluid| {
            var state = fluid;
            destroyFluidTextures(self, &state);
        }
        self.fluids.table.deinit();
        while (self.waters.table.popAny()) |water| for (water.state) |texture| device.destroyTexture(texture);
        self.waters.table.deinit();
        while (self.hairs.table.popAny()) |hair| freeHair(self, hair);
        self.hairs.table.deinit();
        while (self.hairs.fields.popAny()) |field| device.destroyTexture(field.texture);
        self.hairs.fields.deinit();
        for (self.liquids.table.slots.items) |*slot| if (slot.value) |*state| state.deinit(self.device);
        self.liquids.table.deinit();
        while (self.instances.table.popAny()) |group| {
            self.gpa.free(group.transforms);
            self.gpa.free(group.tints);
            self.gpa.free(group.params);
        }
        self.instances.table.deinit();
        self.scenes.table.deinit();
        self.models.table.deinit();
        self.environments.table.deinit();
        while (self.views.table.popAny()) |view_value| {
            var view = view_value;
            view.deinit(device);
        }
        self.views.table.deinit();
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
        for (&self.pose_scratch) |*scratch| scratch.deinit(self.gpa);
        self.prepare_chunks.deinit(self.gpa);
        for (self.tonemap_pipelines.items) |entry| device.destroyPipeline(entry.pipeline);
        self.tonemap_pipelines.deinit(self.gpa);
        for (self.draw_pipelines.items) |entry| {
            device.destroyPipeline(entry.flat);
            device.destroyPipeline(entry.depth_tested);
        }
        self.draw_pipelines.deinit(self.gpa);
        for (self.fonts.list.items, self.fonts.textures.items) |font, texture| {
            device.destroyTexture(texture);
            font.deinit();
            self.gpa.destroy(font);
        }
        self.fonts.list.deinit(self.gpa);
        self.fonts.textures.deinit(self.gpa);
        for (self.images.list.items) |entry| device.destroyTexture(entry.texture);
        self.images.list.deinit(self.gpa);
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
        inline for (.{ "vertices", "skin_vertices", "morph_deltas", "indices", "meshlets", "bvh_nodes", "bvh_items", "meshes" }) |name| @field(self, name).deinit(self);
        self.materials.pool.deinit(self);
        self.mesh_boxes.deinit(self.gpa);
        for (&self.arenas) |*arena| arena.deinit(device);
        device.destroyBuffer(self.cull_counts);
        device.destroyBuffer(self.cull_dispatch);
        device.destroyBuffer(self.impostor_draw);
        self.scratch_impostors.deinit(self.gpa);
        device.destroyBuffer(self.cull_mesh_draws);
        for (self.count_readback) |buffer| device.destroyBuffer(buffer);
        device.destroyBuffer(self.pick_buffer);
        for (self.materials.shaders) |shader| if (shader) |pipelines| {
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
        self.scratch_settling.deinit(self.gpa);
        self.scratch_moved.deinit(self.gpa);
        self.scratch_instances.deinit(self.gpa);
        self.scratch_static_cull.deinit(self.gpa);
        self.dlss.stop(device);
        pipelines_module.releaseOverrides();
        const gpa = self.gpa;
        const io = self.io;
        gpa.destroy(self);
        gltf.releaseLibraries(io);
        device.deinit();
    }

    /// Records the new framebuffer size in pixels; the swapchain is rebuilt
    /// at the next frame. Safe from any thread.
    pub fn resize(self: *Renderer, width: u32, height: u32) void {
        self.lock();
        defer self.unlock();
        self.device.resize(width, height);
    }

    /// How `Settings.path_tracing` would run on this device. Safe from any
    /// thread.
    pub fn pathTracing(self: *const Renderer) PathTracing {
        if (self.device.ray_tracing) return .hardware;
        return if (self.options.path_tracing_fallback) .shader else .unavailable;
    }

    /// What `Upscaling.dlss` would do on this device: nothing without
    /// the DLSS SDK built in, an NVIDIA GPU and a driver that runs it. Safe from any thread.
    pub fn dlssSupport(self: *const Renderer) Dlss {
        return .{ .super_resolution = self.dlss.super_resolution, .ray_reconstruction = self.dlss.ray_reconstruction };
    }

    /// Last frame's counters, with current loading count and GPU memory use.
    /// Safe from any thread.
    pub fn getStats(self: *Renderer) Stats {
        self.lock();
        defer self.unlock();
        var stats = self.stats;
        stats.models_loading = self.loading_count;
        stats.gpu_memory_bytes = self.device.memoryStats().used_bytes;
        return stats;
    }

    /// True while any model or environment is still streaming in.
    pub fn isLoading(self: *Renderer) bool {
        self.lock();
        defer self.unlock();
        return self.loading_count != 0;
    }

    /// Blocks until every pending asset is on the GPU. For tools and tests.
    pub fn waitUntilLoaded(self: *Renderer) !void {
        while (true) {
            {
                self.lock();
                defer self.unlock();
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
        for (self.models.table.slots.items) |*slot| if (slot.value) |*entry| {
            if (entry.state != .loading) continue;
            if (entry.job == null or entry.job.?.done.load(.acquire)) return true;
        };
        for (self.environments.table.slots.items) |*slot| if (slot.value) |*entry| {
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
        for (self.models.table.slots.items) |*slot| if (slot.value) |*entry| {
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
        for (self.environments.table.slots.items) |*slot| if (slot.value) |*entry| {
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

    /// Deletes the oldest-written asset cache files until at most `max_bytes`
    /// remain; returns the bytes freed.
    pub fn trimAssetCache(self: *Renderer, max_bytes: u64) !u64 {
        const directory = self.options.asset_cache_dir orelse return 0;
        return gltf.trimCache(self.gpa, self.io, directory, max_bytes);
    }

    /// Takes the renderer lock. Public methods lock internally; hold it only
    /// to use `device` from a non-rendering thread. Not reentrant: call no
    /// renderer methods while holding it.
    pub fn lock(self: *Renderer) void {
        self.mutex.lockUncancelable(self.io);
        if (self.pending_any.load(.acquire)) self.applyPending();
    }

    /// Must be called from the thread that took the lock.
    pub fn unlock(self: *Renderer) void {
        self.mutex.unlock(self.io);
    }

    /// Takes the lock if nothing holds it. The entity setters use it so as
    /// not to wait for a frame that is being recorded; see `queueEdit`.
    pub fn tryLock(self: *Renderer) bool {
        if (!self.mutex.tryLock()) return false;
        if (self.pending_any.load(.acquire)) self.applyPending();
        return true;
    }

    /// Leaves an entity edit to be made, in order, before anything else next
    /// uses the lock, so that the caller does not wait for a frame.
    pub fn queueEdit(self: *Renderer, entity: Entity, change: EntityEdit.Change) void {
        self.queueEdits(&.{.{ .entity = entity, .change = change }});
    }

    /// `queueEdit` for several edits under one lock of the queue.
    pub fn queueEdits(self: *Renderer, edits: []const EntityEdit) void {
        const queued = queued: {
            self.pending_mutex.lockUncancelable(self.io);
            defer self.pending_mutex.unlock(self.io);
            self.pending.appendSlice(self.gpa, edits) catch break :queued false;
            self.pending_any.store(true, .release);
            break :queued true;
        };
        if (queued) return;
        self.lock();
        defer self.unlock();
        for (edits) |edit| applyEdit(self, edit);
    }

    fn applyPending(self: *Renderer) void {
        {
            self.pending_mutex.lockUncancelable(self.io);
            defer self.pending_mutex.unlock(self.io);
            std.mem.swap(std.ArrayList(EntityEdit), &self.pending, &self.applying);
            self.pending_any.store(false, .release);
        }
        for (self.applying.items) |edit| applyEdit(self, edit);
        self.applying.clearRetainingCapacity();
    }

    fn applyEdit(self: *Renderer, edit: EntityEdit) void {
        switch (edit.change) {
            .transform => |transform| self.moveEntity(edit.entity, transform, false),
            .teleport => |transform| self.moveEntity(edit.entity, transform, true),
            .tint => |tint| if (self.entities.table.get(edit.entity)) |data| {
                if (data.tint == tint) return;
                data.tint = tint;
                self.restyleEntity(edit.entity);
            },
            .params => |params| if (self.entities.table.get(edit.entity)) |data| {
                if (std.mem.eql(f32, &data.params, &params)) return;
                data.params = params;
                self.restyleEntity(edit.entity);
            },
            .pose => |pose| if (self.entities.table.get(edit.entity)) |data| {
                data.pose = pose;
            },
        }
    }

    /// The bookkeeping of a live entity. Needs the lock, as do the calls below.
    pub fn markOf(self: *Renderer, entity: Entity) ?*EntityMark {
        if (entity.index >= self.entity_marks.items.len) return null;
        const mark = &self.entity_marks.items[entity.index];
        return if (mark.handle == @as(u64, @bitCast(entity))) mark else null;
    }

    /// An entity's transform; the identity for a stale handle.
    pub fn transformOf(self: *Renderer, entity: Entity) Mat4 {
        return if (self.markOf(entity) != null) self.entity_transforms.items[entity.index] else math.identity;
    }

    /// Gives an entity a transform. A teleport is not motion.
    pub fn moveEntity(self: *Renderer, entity: Entity, transform: Mat4, teleport: bool) void {
        const mark = self.markOf(entity) orelse return;
        const slot = &self.entity_transforms.items[entity.index];
        if (teleport) {
            self.entity_previous.items[entity.index] = transform;
        } else if (std.mem.eql(f32, slot, &transform)) return;
        slot.* = transform;
        self.noteEdited(entity.index, mark, if (teleport) EntityMark.teleported else EntityMark.moved);
    }

    /// Has an entity's instance records written again.
    pub fn restyleEntity(self: *Renderer, entity: Entity) void {
        const mark = self.markOf(entity) orelse return;
        self.noteEdited(entity.index, mark, EntityMark.restyled);
    }

    fn noteEdited(self: *Renderer, index: u32, mark: *EntityMark, change: u32) void {
        const wanted = change | EntityMark.listed;
        if (mark.bits & wanted == wanted) return;
        const scene = self.scenes.table.get(mark.scene) orelse return;
        const whole = EntityMark.restyled | EntityMark.teleported;
        if (change & whole != 0 and mark.bits & whole == 0) scene.restyled_entries += mark.layout_count;
        mark.bits |= change;
        if (mark.bits & EntityMark.listed != 0) return;
        scene.edited.append(self.gpa, index) catch {
            scene.records_valid = false;
            return;
        };
        scene.edited_entries += mark.layout_count;
        mark.bits |= EntityMark.listed;
    }

    /// Starts the bookkeeping of a new entity.
    pub fn markEntity(self: *Renderer, entity: Entity, scene: Scene, transform: Mat4) !void {
        const needed = @as(usize, entity.index) + 1;
        if (self.entity_marks.items.len < needed) {
            try self.entity_transforms.ensureTotalCapacity(self.gpa, needed);
            try self.entity_previous.ensureTotalCapacity(self.gpa, needed);
            try self.entity_marks.ensureTotalCapacity(self.gpa, needed);
            @memset(self.entity_transforms.addManyAsSliceAssumeCapacity(needed - self.entity_transforms.items.len), math.identity);
            @memset(self.entity_previous.addManyAsSliceAssumeCapacity(needed - self.entity_previous.items.len), math.identity);
            @memset(self.entity_marks.addManyAsSliceAssumeCapacity(needed - self.entity_marks.items.len), .{});
        }
        self.entity_transforms.items[entity.index] = transform;
        self.entity_previous.items[entity.index] = transform;
        self.entity_marks.items[entity.index] = .{ .handle = @bitCast(entity), .scene = scene };
    }

    /// Asks which entity is under `pixel` (in the view's pixels; null is the
    /// main view). The answer arrives through `takePick` a few frames later.
    /// A new request replaces an unserved one. Blended surfaces do not pick.
    pub fn requestPick(self: *Renderer, view: ?View, pixel: [2]u32) void {
        self.lock();
        defer self.unlock();
        self.pick_request = .{ .view = view orelse self.main_view, .pixel = pixel };
    }

    /// Returns the answer to a `requestPick` once, when it is ready.
    pub fn takePick(self: *Renderer) ?PickResult {
        self.lock();
        defer self.unlock();
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
        const scene = self.scenes.table.get(pending.scene) orelse return;
        if (scene.layout_version != pending.layout_version) return;
        if (raw.instance >= scene.layout.items.len) {
            for (scene.groups.items) |group_handle| {
                const group = self.instances.table.get(group_handle) orelse continue;
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

    /// Renders one frame; false when skipped because the window has no
    /// drawable surface. Call from one thread at a time; the lock is held
    /// only while recording, not while waiting for the GPU or display.
    pub fn render(self: *Renderer, desc: FrameDesc) !bool {
        const device = self.device;
        var failure: ?anyerror = null;
        try device.waitForFrame();
        {
            self.lock();
            defer self.unlock();
            if (!try device.prepareSurface()) return false;
        }
        if (!try device.acquireImage()) return false;
        {
            self.lock();
            defer self.unlock();
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
        return upscaler.generate(self.device, cmd, shown, output, self.generating_reset) catch {
            if (!self.generating_failed) std.log.warn("FidelityFX frame generation failed; frames are shown without it", .{});
            self.generating_failed = true;
            return false;
        };
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
            for (self.environments.table.slots.items) |*slot| if (slot.value) |*entry| {
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
        self.lock();
        defer self.unlock();
        return self.device.hdr_active;
    }
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
