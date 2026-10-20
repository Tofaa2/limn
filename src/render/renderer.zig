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
const ray_scene = @import("scene/ray_scene.zig");
const placed_module = @import("renderer/placed.zig");
const view_math_module = @import("renderer/view_math.zig");

const api = @import("api.zig");
pub const max_curve_keys = api.max_curve_keys;
pub const EffectResolution = api.EffectResolution;
pub const Settings = api.Settings;
pub const ViewDesc = api.ViewDesc;
pub const Region = api.Region;
pub const CloudDesc = api.CloudDesc;
pub const DecalDesc = api.DecalDesc;
pub const InstanceGroup = api.InstanceGroup;
pub const Liquid = api.Liquid;
pub const Hair = api.Hair;
pub const Water = api.Water;
pub const Fluid = api.Fluid;
pub const AssetState = api.AssetState;
pub const Capabilities = api.Capabilities;
pub const Emitter = api.Emitter;
pub const EmitterDesc = api.EmitterDesc;
pub const Entity = api.Entity;
pub const Environment = api.Environment;
pub const FluidDesc = api.FluidDesc;
pub const FluidFlipbookDesc = api.FluidFlipbookDesc;
pub const FluidObstacle = api.FluidObstacle;
pub const FluidSource = api.FluidSource;
pub const Font = api.Font;
pub const FrameDesc = api.FrameDesc;
pub const HairDesc = api.HairDesc;
pub const HairSimulation = api.HairSimulation;
pub const Image = api.Image;
pub const Light = api.Light;
pub const LiquidDesc = api.LiquidDesc;
pub const LiquidSource = api.LiquidSource;
pub const Model = api.Model;
pub const ModelInfo = api.ModelInfo;
pub const Options = api.Options;
pub const PathTracingSupport = api.PathTracingSupport;
pub const PickResult = api.PickResult;
pub const Pose = api.Pose;
pub const Profiler = api.Profiler;
pub const Quality = api.Quality;
pub const ReflectionProbe = api.ReflectionProbe;
pub const ReflectionProbeDesc = api.ReflectionProbeDesc;
pub const Scene = api.Scene;
pub const SkyDesc = api.SkyDesc;
pub const Stats = api.Stats;
pub const Sun = api.Sun;
pub const View = api.View;
pub const WaterDesc = api.WaterDesc;
pub const scene_color_format = api.scene_color_format;
const renderer_state = @import("state.zig");
const scene_pass = @import("scene_pass.zig");
const features = @import("core/features.zig");
const canvas_feature = @import("features/canvas.zig");
const targets = @import("core/targets.zig");

pub const Mat4 = math.Mat4;
pub const Vec3 = math.Vec3;
pub const SceneFrame = scene_pass.SceneFrame;

pub const TextureStream = renderer_state.TextureStream;
const Zone = renderer_state.Zone;

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
pub const shadeVariantDesc = renderer_state.shadeVariantDesc;
pub const ModelMesh = renderer_state.ModelMesh;
pub const SceneData = renderer_state.SceneData;
const EntityData = renderer_state.EntityData;
pub const TransparentDraw = renderer_state.TransparentDraw;
const BlasJob = renderer_state.BlasJob;
pub const BoundsJob = renderer_state.BoundsJob;
pub const SkinJob = renderer_state.SkinJob;
pub const MadeTextures = renderer_state.MadeTextures;
pub const ViewState = renderer_state.ViewState;
pub const ViewData = renderer_state.ViewData;
const Pipelines = pipelines_module.Pipelines;
pub const GiVolume = renderer_state.GiVolume;
pub const gi_irradiance_texels = renderer_state.gi_irradiance_texels;
pub const gi_visibility_texels = renderer_state.gi_visibility_texels;
pub const gi_probe_limit = renderer_state.gi_probe_limit;
const PickRequest = renderer_state.PickRequest;
pub const ReflectionTargets = renderer_state.ReflectionTargets;
pub const cloud_noise_size = renderer_state.cloud_noise_size;
pub const cloud_noise_tiles = renderer_state.cloud_noise_tiles;
pub const cloud_weather_size = renderer_state.cloud_weather_size;
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

const bakeLoadedClouds = environments_module.bakeLoadedClouds;
const bakeSky = environments_module.bakeSky;
const buildPendingBlas = ray_scene.buildPendingBlas;
const captureProbes = probes_module.captureProbes;
const compactGeometry = scene_update_module.compactGeometry;
const destroyFluidTextures = fluid_module.destroyFluidTextures;
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
/// The kinds of object kept in a handle table, freed in this order when the
/// renderer is destroyed. Each namespace has `table` and `free`. A freed
/// scene forgets its lights and decals, so `scenes` goes before them.
const stores = .{ "entities", "scenes", "lights", "decals", "models", "environments", "emitters", "probes", "fluids", "waters", "hairs", "liquids", "instances", "views" };

/// Removes `handle` from the table of `kind` and from its scene's list
/// `list`, then frees what it held. Under the renderer's lock.
pub fn destroyObject(self: *Renderer, comptime kind: []const u8, comptime list: []const u8, handle: anytype) void {
    const store = &@field(self, kind);
    var removed = store.table.remove(handle) orelse return;
    @TypeOf(store.*).free(self, &removed);
    const scene = self.scenes.table.get(removed.scene) orelse return;
    const items = &@field(scene, list);
    for (items.items, 0..) |item, index| if (std.meta.eql(item, handle)) {
        _ = items.orderedRemove(index);
        break;
    };
}

/// What a renderer keeps besides its namespaces, options and device; not part
/// of the API.
pub const Internal = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    pipelines: Pipelines,
    /// Shading pass builds, one per feature set seen.
    shade_variants: std.ArrayList(ShadeVariant) = .empty,
    /// This frame's animated entities.
    /// Count of loaded models with per-texture UV transforms.
    texture_transform_users: u32 = 0,
    pose_scratch: [max_worker_threads]std.ArrayList(animation.Local) = @splat(.empty),
    prepare_chunks: std.ArrayList(renderer_state.PrepareChunk) = .empty,
    /// Short-lived render targets, lent to the passes of every view.
    target_pool: targets.Pool = .{},
    /// What the views of this frame asked for and did not get.
    downgrades: features.Downgrades = .{},
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
    /// BLASes and the software BVHs of meshes.
    rays: ray_scene.Structures,
    meshes: Pool,
    arenas: [rhi.frames_in_flight]FrameArena,
    cull_commands: ?rhi.Buffer = null,
    cull_capacity: u32 = 0,
    /// Views `cull_commands` has room for.
    cull_views: u32 = 0,
    /// Draws each view's second list (masked, two-sided, LOD-fading) has
    /// room for; the first has `cull_capacity`.
    cull_masked_capacity: u32 = 0,
    /// The buffers and textures only scenes use have been made; see
    /// `ensureSceneResources`.
    scene_ready: bool = false,
    cull_counts: rhi.Buffer = undefined,
    /// One `gpu.CullDispatch` per view of a frame.
    cull_dispatch: rhi.Buffer = undefined,
    /// The `gpu.DrawIndirect` that draws a view's impostors.
    impostor_draw: rhi.Buffer = undefined,
    scratch_impostors: std.ArrayList(gpu.Impostor) = .empty,
    /// Two `gpu.MeshDraw`s per view, one per meshlet list; mesh shaders only.
    cull_mesh_draws: rhi.Buffer = undefined,
    count_readback: [rhi.frames_in_flight]rhi.Buffer = undefined,
    /// Texture streaming round counter (see `EntityData.seen_round`).
    seen_round: u64 = 0,
    /// Bound in place of cascades for views drawn without shadows.
    shadow_map: rhi.Texture = undefined,
    /// Shadow atlas for spot and point lights.
    local_shadow_map: rhi.Texture = undefined,
    clusters: rhi.Buffer = undefined,
    transparent_order: std.ArrayList(TransparentDraw) = .empty,
    /// Frame in which a geometry pool last moved to a new buffer.
    geometry_replaced: ?u64 = null,
    /// Frames a view asked for path tracing and was drawn without it.
    path_trace_misses: u32 = 0,
    brdf_lut: rhi.Texture = undefined,
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
    generating: ?@import("techniques/upscaling.zig").Generator = null,
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
    cloud_weather: ?rhi.Texture = null,
    stats: Stats = .{},
    skin_jobs: std.ArrayList(SkinJob) = .empty,
    /// Morph target weights of this frame's skin jobs, back to back.
    skin_weights: std.ArrayList(f32) = .empty,
    /// Meshes whose meshlet bounds are worked out after skinning.
    bounds_jobs: std.ArrayList(BoundsJob) = .empty,
    scratch_locals: std.ArrayList(animation.Local) = .empty,
    scratch_refs: std.ArrayList(gpu.MeshletRef) = .empty,
    scratch_settling: std.ArrayList([2]u32) = .empty,
    scratch_moved: std.ArrayList([2]u32) = .empty,
    scratch_instances: std.ArrayList(gpu.Instance) = .empty,
    scratch_static_cull: std.ArrayList(gpu.StaticCull) = .empty,
};

pub const Renderer = struct {
    /// Fixed for the renderer's lifetime.
    options: Options,
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
    /// Single lights of scenes, by handle.
    lights: placed_module.Lights,
    /// Single decals of scenes, by handle.
    decals: placed_module.Decals,
    fluids: fluid_module.Fluids,
    waters: water_module.Waters,
    liquids: liquid_module.Liquids,
    hairs: hair_module.Hairs,
    views: views_module.Views,
    fonts: fonts_module.Fonts = .{},
    images: images_module.Images = .{},
    shaders: pipelines_module.Shaders = .{},
    /// Custom draw list shaders.
    canvas: canvas_feature.Canvas = .{},
    /// Everything else the renderer keeps; not part of the API.
    internal: Internal,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, options: Options) !*Renderer {
        const device = try rhi.Device.init(gpa, io, .{
            .application_name = options.application_name,
            .validation = options.validation,
            .surface = options.surface,
            .preferred_device = options.preferred_device,
            .pipeline_cache_path = options.cache.pipelines,
            .debug_names = options.debug_names,
            .hdr_output = options.hdr_output,
            .ray_tracing = options.ray_tracing.hardware,
            .mesh_shaders = options.geometry.mesh_shaders,
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
            .options = options,
            .device = device,
            .materials = .{ .pool = .init("materials", @sizeOf(gpu.Material), 1 << 12, storage) },
            .models = .{ .table = .init(gpa) },
            .environments = .{ .table = .init(gpa) },
            .scenes = .{ .table = .init(gpa) },
            .views = .{ .table = .init(gpa) },
            .entities = .{ .table = .init(gpa) },
            .emitters = .{ .table = .init(gpa) },
            .probes = .{ .table = .init(gpa) },
            .lights = .{ .table = .init(gpa) },
            .decals = .{ .table = .init(gpa) },
            .fluids = .{ .table = .init(gpa) },
            .waters = .{ .table = .init(gpa) },
            .hairs = .{ .table = .init(gpa), .fields = .init(gpa) },
            .liquids = .{ .table = .init(gpa) },
            .instances = .{ .table = .init(gpa) },
            .internal = .{
                .gpa = gpa,
                .io = io,
                .dlss = @import("dlss.zig").Library.start(device),
                .pipelines = .init(gpa, device, io),
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
                .vertices = .init("vertices", @sizeOf(gpu.Vertex), 1 << 20, geometry),
                .skin_vertices = .init("skin vertices", @sizeOf(gpu.SkinVertex), 1 << 16, storage),
                .morph_deltas = .init("morph deltas", @sizeOf(gltf.MorphDelta), 1 << 14, storage),
                .indices = .init("indices", @sizeOf(u32), 1 << 22, geometry),
                .meshlets = .init("meshlets", @sizeOf(gpu.Meshlet), 1 << 16, storage),
                .rays = .init(storage),
                .meshes = .init("meshes", @sizeOf(gpu.Mesh), 1 << 12, storage),
                .arenas = undefined,
                .sampler_local_shadow = try device.createSampler(.{
                    .address_u = .clamp_to_edge,
                    .address_v = .clamp_to_edge,
                    .address_w = .clamp_to_edge,
                    .mip_filter = .nearest,
                    .compare = .greater_or_equal,
                }),
            },
        };
        for (&self.internal.arenas) |*arena| arena.* = try FrameArena.init(device, 4 * 1024 * 1024);
        self.internal.main_view = try insertView(self);
        errdefer self.views.table.deinit();

        self.fonts.default_font = try gpa.create(Font);
        errdefer gpa.destroy(self.fonts.default_font);
        self.fonts.default_font.* = try font_module.load(gpa, @embedFile("fonts/DejaVuSans.ttf"), font_module.default_ranges);
        errdefer self.fonts.default_font.deinit();
        try registerFont(self, self.fonts.default_font);
        if (options.cache.assets_max_bytes != 0) if (options.cache.assets) |directory| {
            _ = gltf.trimCache(gpa, self.internal.io, directory, options.cache.assets_max_bytes) catch |err| std.log.warn("asset cache not trimmed: {}", .{err});
        };

        var cmd = try device.beginImmediate();
        try cmd.flushUploads();
        try device.endImmediate(&cmd);
        return self;
    }

    /// Makes what only scenes use, the first time a scene is drawn: the
    /// geometry pools, culling and picking buffers, shadow maps, light
    /// clusters and the BRDF table. A renderer that draws no scene has none.
    pub fn ensureSceneResources(self: *Renderer, cmd: *rhi.CommandEncoder) !void {
        if (self.internal.scene_ready) return;
        const device = self.device;
        inline for (.{ "vertices", "skin_vertices", "morph_deltas", "indices", "meshlets", "meshes" }) |name| try @field(self.internal, name).ensure(device);
        try self.internal.rays.ensure(device);
        try self.materials.pool.ensure(device);

        var made: std.ArrayList(rhi.Buffer) = .empty;
        defer made.deinit(self.internal.gpa);
        errdefer for (made.items) |buffer| device.destroyBuffer(buffer);
        try made.ensureTotalCapacity(self.internal.gpa, 6 + 2 * rhi.frames_in_flight);
        const Local = struct {
            fn buffer(d: *rhi.Device, list: *std.ArrayList(rhi.Buffer), desc: rhi.BufferDesc) !rhi.Buffer {
                const result = try d.createBuffer(desc);
                list.appendAssumeCapacity(result);
                if (desc.memory == .gpu_to_cpu) @memset(d.mapped(result), 0);
                return result;
            }
        };
        const cull_counts = try Local.buffer(device, &made, .{ .name = "cull counts", .size = view_count * 2 * @sizeOf(u32), .usage = .{ .storage = true, .indirect = true, .copy_src = true } });
        const cull_mesh_draws = try Local.buffer(device, &made, .{ .name = "cull mesh draws", .size = view_count * 2 * @sizeOf(gpu.MeshDraw), .usage = .{ .storage = true, .indirect = true, .copy_dst = true } });
        const impostor_draw = try Local.buffer(device, &made, .{ .name = "impostor draw", .size = @sizeOf(gpu.DrawIndirect), .usage = .{ .storage = true, .indirect = true, .copy_dst = true } });
        const cull_dispatch = try Local.buffer(device, &made, .{ .name = "cull dispatch", .size = view_count * @sizeOf(gpu.CullDispatch), .usage = .{ .storage = true, .indirect = true, .copy_dst = true } });
        const clusters = try Local.buffer(device, &made, .{ .name = "light clusters", .size = gpu.cluster_count * @sizeOf(gpu.Cluster), .usage = .{ .storage = true } });
        const pick_buffer = try Local.buffer(device, &made, .{ .name = "pick", .size = @sizeOf(gpu.Pick), .usage = .{ .storage = true, .copy_src = true } });
        var count_readback: [rhi.frames_in_flight]rhi.Buffer = undefined;
        for (&count_readback) |*buffer| buffer.* = try Local.buffer(device, &made, .{ .name = "cull count readback", .size = (view_count * 2 + 1) * @sizeOf(u32), .usage = .{}, .memory = .gpu_to_cpu });
        var pick_readback: [rhi.frames_in_flight]rhi.Buffer = undefined;
        for (&pick_readback) |*buffer| buffer.* = try Local.buffer(device, &made, .{ .name = "pick readback", .size = @sizeOf(gpu.Pick), .usage = .{}, .memory = .gpu_to_cpu });

        const local_shadow_map = try device.createTexture(.{
            .name = "local shadow atlas",
            .width = self.options.shadows.local_resolution,
            .height = self.options.shadows.local_resolution,
            .format = .depth32_float,
            .usage = .{ .sampled = true, .depth_attachment = true },
        });
        errdefer device.destroyTexture(local_shadow_map);
        const shadow_map = try device.createTexture(.{
            .name = "shadow fallback",
            .width = 1,
            .height = 1,
            .format = .depth32_float,
            .usage = .{ .sampled = true, .depth_attachment = true },
            .layers = gpu.cascade_count,
            .kind = .@"2d_array",
        });
        errdefer device.destroyTexture(shadow_map);
        const brdf_lut = try device.createTexture(.{
            .name = "brdf lut",
            .width = 128,
            .height = 128,
            .format = .rg16_float,
            .usage = .{ .sampled = true, .color_attachment = true },
        });
        errdefer device.destroyTexture(brdf_lut);

        const brdf_pipeline = try self.internal.pipelines.of(brdfLutPipeline);
        try cmd.beginRendering(.{ .color = &.{.{ .texture = brdf_lut, .load = .discard }} });
        cmd.bindPipeline(brdf_pipeline);
        cmd.drawFullscreen();
        cmd.endRendering();
        for (0..gpu.cascade_count) |cascade| {
            try cmd.beginRendering(.{ .depth = .{ .texture = shadow_map, .layer = @intCast(cascade), .clear = 1 } });
            cmd.endRendering();
        }
        try cmd.beginRendering(.{ .depth = .{ .texture = local_shadow_map, .clear = 0 } });
        cmd.endRendering();

        self.internal.cull_counts = cull_counts;
        self.internal.cull_mesh_draws = cull_mesh_draws;
        self.internal.impostor_draw = impostor_draw;
        self.internal.cull_dispatch = cull_dispatch;
        self.internal.clusters = clusters;
        self.internal.pick_buffer = pick_buffer;
        self.internal.count_readback = count_readback;
        self.internal.pick_readback = pick_readback;
        self.internal.local_shadow_map = local_shadow_map;
        self.internal.shadow_map = shadow_map;
        self.internal.brdf_lut = brdf_lut;
        self.internal.scene_ready = true;
    }

    /// Waits for the GPU, then destroys everything, including the device and
    /// the renderer. Takes no lock: no other thread may be using it.
    pub fn deinit(self: *Renderer) void {
        const device = self.device;
        device.waitIdle() catch {};
        self.internal.pending.deinit(self.internal.gpa);
        self.internal.applying.deinit(self.internal.gpa);
        self.internal.entity_transforms.deinit(self.internal.gpa);
        self.internal.entity_previous.deinit(self.internal.gpa);
        self.internal.entity_marks.deinit(self.internal.gpa);
        inline for (stores) |name| {
            const store = &@field(self, name);
            while (store.table.popAny()) |value| {
                var entry = value;
                @TypeOf(store.*).free(self, &entry);
            }
            store.table.deinit();
        }
        while (self.hairs.fields.popAny()) |field| device.destroyTexture(field.texture);
        self.hairs.fields.deinit();
        self.internal.shade_variants.deinit(self.internal.gpa);
        for (&self.internal.pose_scratch) |*scratch| scratch.deinit(self.internal.gpa);
        self.internal.prepare_chunks.deinit(self.internal.gpa);
        self.canvas.deinit(self.internal.gpa, device);
        self.internal.target_pool.deinit(self.internal.gpa, device);
        for (self.fonts.list.items, self.fonts.textures.items) |font, texture| {
            device.destroyTexture(texture);
            font.deinit();
            self.internal.gpa.destroy(font);
        }
        self.fonts.list.deinit(self.internal.gpa);
        self.fonts.textures.deinit(self.internal.gpa);
        for (self.images.list.items) |entry| device.destroyTexture(entry.texture);
        self.images.list.deinit(self.internal.gpa);
        self.internal.pipelines.deinit();
        for (self.internal.material_samplers) |sampler| if (sampler) |value| device.destroySampler(value);
        device.destroySampler(self.internal.sampler_linear_clamp);
        device.destroySampler(self.internal.sampler_nearest_clamp);
        device.destroySampler(self.internal.sampler_linear_repeat);
        device.destroySampler(self.internal.sampler_shadow);
        device.destroySampler(self.internal.sampler_local_shadow);
        self.internal.transparent_order.deinit(self.internal.gpa);
        inline for (.{ "vertices", "skin_vertices", "morph_deltas", "indices", "meshlets", "meshes" }) |name| @field(self.internal, name).deinit(self);
        self.internal.rays.deinit(self);
        self.materials.pool.deinit(self);
        for (&self.internal.arenas) |*arena| arena.deinit(device);
        self.internal.scratch_impostors.deinit(self.internal.gpa);
        for (self.materials.shaders) |shader| if (shader) |pipelines| {
            device.destroyPipeline(pipelines.plain);
            device.destroyPipeline(pipelines.reflective);
        };
        if (self.internal.cull_commands) |buffer| device.destroyBuffer(buffer);
        if (self.internal.scene_ready) {
            for ([_]rhi.Buffer{ self.internal.cull_counts, self.internal.cull_dispatch, self.internal.impostor_draw, self.internal.cull_mesh_draws, self.internal.clusters, self.internal.pick_buffer }) |buffer| device.destroyBuffer(buffer);
            for (self.internal.count_readback) |buffer| device.destroyBuffer(buffer);
            for (self.internal.pick_readback) |buffer| device.destroyBuffer(buffer);
            device.destroyTexture(self.internal.local_shadow_map);
            device.destroyTexture(self.internal.shadow_map);
            device.destroyTexture(self.internal.brdf_lut);
        }
        if (self.internal.cloud_noise) |texture| device.destroyTexture(texture);
        if (self.internal.cloud_weather) |texture| device.destroyTexture(texture);
        self.internal.skin_jobs.deinit(self.internal.gpa);
        self.internal.skin_weights.deinit(self.internal.gpa);
        self.internal.bounds_jobs.deinit(self.internal.gpa);
        self.internal.scratch_locals.deinit(self.internal.gpa);
        self.internal.scratch_refs.deinit(self.internal.gpa);
        self.internal.scratch_settling.deinit(self.internal.gpa);
        self.internal.scratch_moved.deinit(self.internal.gpa);
        self.internal.scratch_instances.deinit(self.internal.gpa);
        self.internal.scratch_static_cull.deinit(self.internal.gpa);
        self.internal.dlss.stop(device);
        pipelines_module.releaseOverrides();
        const gpa = self.internal.gpa;
        const io = self.internal.io;
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

    /// What this renderer can do on this device. Safe from any thread.
    pub fn capabilities(self: *Renderer) Capabilities {
        const device = self.device;
        const built = struct {
            fn in(present: bool, runs: bool) api.Support {
                return if (!present) .not_built else if (runs) .available else .no_device_support;
            }
        }.in;
        const offered = struct {
            fn by(asked: bool, has: bool) api.Support {
                return if (!asked) .off else if (has) .available else .no_device_support;
            }
        }.by;
        self.lock();
        defer self.unlock();
        return .{
            .ray_tracing = offered(self.options.ray_tracing.hardware, device.caps.ray_tracing),
            .path_tracing = view_render_module.pathTracingSupport(self),
            .mesh_shaders = offered(self.options.geometry.mesh_shaders, device.caps.mesh_shaders),
            .variable_rate_shading = if (device.caps.shading_rate_tile != 0) .available else .no_device_support,
            .fidelityfx = built(@import("ffx.zig").available, device.caps.storage_images),
            .dlss = built(@import("dlss.zig").available, device.caps.storage_images and self.internal.dlss.super_resolution),
            .dlss_ray_reconstruction = built(@import("dlss.zig").available, device.caps.storage_images and self.internal.dlss.ray_reconstruction),
            .hdr_output = offered(self.options.hdr_output, device.hdr_active),
        };
    }

    /// Last frame's counters, with current loading count and GPU memory use.
    /// Safe from any thread.
    pub fn getStats(self: *Renderer) Stats {
        self.lock();
        defer self.unlock();
        var stats = self.internal.stats;
        stats.models_loading = self.internal.loading_count;
        stats.gpu_memory_bytes = self.device.memoryStats().used_bytes;
        stats.pipelines = self.internal.pipelines.count();
        return stats;
    }

    /// True while any model or environment is still streaming in.
    pub fn isLoading(self: *Renderer) bool {
        self.lock();
        defer self.unlock();
        return self.internal.loading_count != 0;
    }

    /// Blocks until every pending asset is on the GPU. For tools and tests.
    pub fn waitUntilLoaded(self: *Renderer) !void {
        while (true) {
            {
                self.lock();
                defer self.unlock();
                if (self.internal.loading_count == 0) return;
                if (self.anyJobFinished()) {
                    var cmd = try self.device.beginImmediate();
                    _ = try self.pumpAssets(&cmd, std.math.maxInt(u64));
                    try cmd.flushUploads();
                    try buildPendingBlas(self, &cmd, null);
                    try cmd.flushUploads();
                    try self.device.endImmediate(&cmd);
                    continue;
                }
            }
            try self.internal.io.sleep(std.Io.Duration.fromMilliseconds(1), .awake);
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
        if (self.internal.loading_count == 0) return false;
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
                self.internal.loading_count -= 1;
                self.internal.asset_generation += 1;
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
            self.internal.loading_count -= 1;
        };
        return progressed;
    }

    /// Deletes the oldest-written asset cache files until at most `max_bytes`
    /// remain; returns the bytes freed.
    pub fn trimAssetCache(self: *Renderer, max_bytes: u64) !u64 {
        const directory = self.options.cache.assets orelse return 0;
        return gltf.trimCache(self.internal.gpa, self.internal.io, directory, max_bytes);
    }

    /// Takes the renderer lock. Public methods lock internally; hold it only
    /// to use `device` from a non-rendering thread. Not reentrant: call no
    /// renderer methods while holding it.
    pub fn lock(self: *Renderer) void {
        self.internal.mutex.lockUncancelable(self.internal.io);
        if (self.internal.pending_any.load(.acquire)) self.applyPending();
    }

    /// Must be called from the thread that took the lock.
    pub fn unlock(self: *Renderer) void {
        self.internal.mutex.unlock(self.internal.io);
    }

    /// Takes the lock if nothing holds it. The entity setters use it so as
    /// not to wait for a frame that is being recorded; see `queueEdit`.
    pub fn tryLock(self: *Renderer) bool {
        if (!self.internal.mutex.tryLock()) return false;
        if (self.internal.pending_any.load(.acquire)) self.applyPending();
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
            self.internal.pending_mutex.lockUncancelable(self.internal.io);
            defer self.internal.pending_mutex.unlock(self.internal.io);
            self.internal.pending.appendSlice(self.internal.gpa, edits) catch break :queued false;
            self.internal.pending_any.store(true, .release);
            break :queued true;
        };
        if (queued) return;
        self.lock();
        defer self.unlock();
        for (edits) |edit| applyEdit(self, edit);
    }

    fn applyPending(self: *Renderer) void {
        {
            self.internal.pending_mutex.lockUncancelable(self.internal.io);
            defer self.internal.pending_mutex.unlock(self.internal.io);
            std.mem.swap(std.ArrayList(EntityEdit), &self.internal.pending, &self.internal.applying);
            self.internal.pending_any.store(false, .release);
        }
        for (self.internal.applying.items) |edit| applyEdit(self, edit);
        self.internal.applying.clearRetainingCapacity();
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
        if (entity.index >= self.internal.entity_marks.items.len) return null;
        const mark = &self.internal.entity_marks.items[entity.index];
        return if (mark.handle == @as(u64, @bitCast(entity))) mark else null;
    }

    /// An entity's transform; the identity for a stale handle.
    pub fn transformOf(self: *Renderer, entity: Entity) Mat4 {
        return if (self.markOf(entity) != null) self.internal.entity_transforms.items[entity.index] else math.identity;
    }

    /// Gives an entity a transform. A teleport is not motion.
    pub fn moveEntity(self: *Renderer, entity: Entity, transform: Mat4, teleport: bool) void {
        const mark = self.markOf(entity) orelse return;
        const slot = &self.internal.entity_transforms.items[entity.index];
        if (teleport) {
            self.internal.entity_previous.items[entity.index] = transform;
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
        scene.edited.append(self.internal.gpa, index) catch {
            scene.records_valid = false;
            return;
        };
        scene.edited_entries += mark.layout_count;
        mark.bits |= EntityMark.listed;
    }

    /// Starts the bookkeeping of a new entity.
    pub fn markEntity(self: *Renderer, entity: Entity, scene: Scene, transform: Mat4) !void {
        const needed = @as(usize, entity.index) + 1;
        if (self.internal.entity_marks.items.len < needed) {
            try self.internal.entity_transforms.ensureTotalCapacity(self.internal.gpa, needed);
            try self.internal.entity_previous.ensureTotalCapacity(self.internal.gpa, needed);
            try self.internal.entity_marks.ensureTotalCapacity(self.internal.gpa, needed);
            @memset(self.internal.entity_transforms.addManyAsSliceAssumeCapacity(needed - self.internal.entity_transforms.items.len), math.identity);
            @memset(self.internal.entity_previous.addManyAsSliceAssumeCapacity(needed - self.internal.entity_previous.items.len), math.identity);
            @memset(self.internal.entity_marks.addManyAsSliceAssumeCapacity(needed - self.internal.entity_marks.items.len), .{});
        }
        self.internal.entity_transforms.items[entity.index] = transform;
        self.internal.entity_previous.items[entity.index] = transform;
        self.internal.entity_marks.items[entity.index] = .{ .handle = @bitCast(entity), .scene = scene };
    }

    /// Asks which entity is under `pixel` (in the view's pixels; null is the
    /// main view). The answer arrives through `takePick` a few frames later.
    /// A new request replaces an unserved one. Blended surfaces do not pick.
    pub fn requestPick(self: *Renderer, view: ?View, pixel: [2]u32) void {
        self.lock();
        defer self.unlock();
        self.internal.pick_request = .{ .view = view orelse self.internal.main_view, .pixel = pixel };
    }

    /// Returns the answer to a `requestPick` once, when it is ready.
    pub fn takePick(self: *Renderer) ?PickResult {
        self.lock();
        defer self.unlock();
        defer self.internal.pick_result = null;
        return self.internal.pick_result;
    }

    /// Collects the pick the GPU wrote in this frame slot's previous use.
    fn resolvePick(self: *Renderer, slot: usize) void {
        const pending = self.internal.pick_pending[slot] orelse return;
        self.internal.pick_pending[slot] = null;
        const raw = self.device.mappedSlice(gpu.Pick, self.internal.pick_readback[slot])[0];
        var result = PickResult{ .pixel = pending.pixel, .hit = null };
        defer self.internal.pick_result = result;
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
                    .distance = view_math_module.viewDepth(pending.depth_terms, raw.depth),
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
            .distance = view_math_module.viewDepth(pending.depth_terms, raw.depth),
        };
    }

    /// Renders one frame; false when skipped because the window has no
    /// drawable surface. Call from one thread at a time; the lock is held
    /// only while recording, not while waiting for the GPU or display.
    pub fn render(self: *Renderer, desc: FrameDesc) !bool {
        const device = self.device;
        var failure: ?anyerror = null;
        if (self.options.deterministic) try self.waitUntilLoaded();
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
            const cpu_start = std.Io.Clock.Timestamp.now(self.internal.io, .awake);
            const frame = try device.startFrame();
            self.renderFrame(frame, desc) catch |err| {
                failure = err;
                device.closeFailedFrame();
                for (self.internal.frame_targets[0..self.internal.frame_target_count]) |target| {
                    const is_backbuffer = if (frame.backbuffer) |backbuffer| std.meta.eql(backbuffer, target) else false;
                    if (!is_backbuffer) frame.cmd.transition(target, .shader_read);
                }
                if (frame.backbuffer) |backbuffer| if (!targetWritten(self, backbuffer)) {
                    if (frame.cmd.beginRendering(.{ .color = &.{.{ .texture = backbuffer, .load = .clear, .clear = .{ 0, 0, 0, 1 } }} })) |_|
                        frame.cmd.endRendering()
                    else |_| {}
                };
            };
            self.internal.stats.indirect_draws = frame.cmd.indirect_draws;
            device.setFrameGenerator(if (self.internal.generating != null and failure == null) .{ .context = self, .generate = generateFrame } else null);
            try device.submitFrame();
            self.internal.stats.cpu_ms = @as(f32, @floatFromInt(cpu_start.untilNow(self.internal.io).raw.nanoseconds)) / 1e6;
            self.internal.frame_index += 1;
            self.internal.time += desc.delta_time;
        }
        try device.presentFrame();
        if (failure) |err| return err;
        return true;
    }

    fn generateFrame(context: *anyopaque, cmd: *rhi.CommandEncoder, shown: rhi.Texture, output: rhi.Texture) bool {
        const self: *Renderer = @ptrCast(@alignCast(context));
        const generator = self.internal.generating orelse return false;
        return generator.generate(self.device, cmd, shown, output, self.internal.generating_reset) catch {
            if (!self.internal.generating_failed) std.log.warn("frame generation failed; frames are shown without it", .{});
            self.internal.generating_failed = true;
            return false;
        };
    }

    fn renderFrame(self: *Renderer, frame: rhi.Frame, desc: FrameDesc) !void {
        const frame_zone = Zone.start(self.options.profiler, "render frame");
        defer frame_zone.stop();
        const cmd = frame.cmd;
        const arena = &self.internal.arenas[@intCast(frame.index % rhi.frames_in_flight)];
        self.internal.stats.draw_list_triangles = 0;
        self.internal.stats.path_traced_frames = 0;
        self.internal.stats.views = @intCast(desc.views.len);
        arena.reset(self.device);
        self.internal.frame_target_count = 0;
        self.internal.frame_scene_views = 0;
        self.internal.downgrades.count = 0;
        self.canvas.beginFrame(self.device, self.internal.frame_index);
        self.internal.target_pool.collect(self.device, self.internal.frame_index);
        self.internal.generating = null;
        self.resolvePick(@intCast(frame.index % rhi.frames_in_flight));

        cmd.beginScope("streaming");
        _ = try self.pumpAssets(cmd, stream_budget_bytes);
        try updateTextureStreaming(self, frame, desc);
        try updateGeometryStreaming(self, desc);
        if (self.internal.skies_dirty) {
            self.internal.skies_dirty = false;
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
        self.internal.stats.downgrades = self.internal.downgrades.items;
        self.internal.stats.downgrade_count = self.internal.downgrades.count;
        if (frame.backbuffer) |backbuffer| if (!targetWritten(self, backbuffer)) {
            try cmd.beginRendering(.{ .color = &.{.{ .texture = backbuffer, .load = .clear, .clear = .{ 0, 0, 0, 1 } }} });
            cmd.endRendering();
        };
    }

    /// See `Quality.recommended`. Safe from any thread.
    pub fn recommendedQuality(self: *const Renderer) Quality {
        return Quality.recommended(self.device.adapterInfo());
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

fn brdfLutPipeline(_: *rhi.Device) pipelines_module.Desc {
    return pipelines_module.pass("brdf lut", pipelines_module.shaderCode("brdf_lut.frag.spv"), &.{.{ .format = .rg16_float }});
}
