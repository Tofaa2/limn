//! Options fixed when a renderer is created.
const std = @import("std");
const rhi = @import("../../rhi/rhi.zig");
const gltf = @import("../../asset/gltf.zig");
const animation = @import("../animation.zig");
const render = @import("../renderer.zig");
const features = @import("../core/features.zig");

const api = @import("../api.zig");
const Geometry = api.Geometry;
const Settings = api.Settings;

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
    /// Size of each of the four sun shadow cascades, in texels per side; not
    /// 0, or `Renderer.init` fails with `error.InvalidOptions`.
    resolution: u32 = 2048,
    /// Size per side of the spot and point light shadow atlas, in texels; at
    /// least `local_tiles_per_side`.
    local_resolution: u32 = 2048,
    /// Tiles per side of the local-light shadow atlas, 1..4. A spot light uses
    /// one tile, a point light six.
    local_tiles_per_side: u32 = 4,
};

/// How textures are stored and sampled; see `Options.textures`.
pub const TextureOptions = struct {
    /// Use the GPU's block-compressed formats where it has them. Off, textures
    /// load as on GPUs without BC or ASTC: Basis Universal files as plain
    /// texels.
    block_formats: bool = true,
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
    /// Read the triangle a pixel belongs to from `SV_PrimitiveID` where the
    /// device can. Off, indirect draws pull their indices in the vertex
    /// shader instead, as on devices without the `geometryShader` feature.
    primitive_id: bool = true,
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
    /// Directory for processed assets; null caches nothing, so textures are
    /// compressed again (`TextureOptions.compression`) on every run.
    assets: ?[]const u8 = null,
    /// Size the asset cache is trimmed to at startup, oldest files first; 0
    /// never trims. See `Renderer.trimAssetCache`.
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
    /// Ask for an HDR10 surface; see `Renderer.capabilities` for the result.
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
    /// Make runs of the same frames give the same picture, for comparing
    /// pictures between runs: shading variants, asset loads and ray tracing
    /// structures are waited for instead of arriving when they are ready,
    /// and liquids add up neighbours in a fixed order. Surfaces at exactly
    /// the same depth are still drawn in the order culling finds them, and
    /// vendor upscalers keep their own order, so a few pixels can differ by
    /// a level. Slower to start.
    deterministic: bool = false,
    /// Threads for animation poses and instance records, including the render
    /// thread: 0 picks automatically (at most 8), 1 uses no other thread.
    worker_threads: u32 = 0,
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
    /// top mips. 0 keeps the process under 90% of the budget the driver
    /// reports, and means no limit where it reports none.
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

/// Hooks for an external CPU profiler such as Tracy. `begin` gets a static zone
/// name and returns a value that `end` receives back.
pub const Profiler = struct {
    /// Passed back to `begin` and `end` unchanged.
    context: ?*anyopaque = null,
    begin: *const fn (context: ?*anyopaque, name: [:0]const u8) u64,
    end: *const fn (context: ?*anyopaque, zone: u64) void,
};
