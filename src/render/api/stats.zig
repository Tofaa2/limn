//! What the device supports and what a frame cost.
const api = @import("../api.zig");
const Denoiser = api.Denoiser;
const FrameGeneration = api.FrameGeneration;
const GeometryStreaming = api.GeometryStreaming;
const Options = api.Options;
const Scene = api.Scene;
const Settings = api.Settings;
const Upscaler = api.Upscaler;
const rhi = @import("../../rhi/rhi.zig");

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

/// Counters describing the last frame; see `Renderer.stats`.
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
    /// Device-local memory the driver lets this process use; 0 when it does
    /// not say. Texture streaming without a budget of its own stays under 90%.
    gpu_memory_budget_bytes: u64 = 0,
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
    /// Every command the last frame recorded.
    commands: rhi.Work = .{},
    /// Bytes the CPU wrote for the GPU to read during the last frame, in
    /// the per-frame arena; staged uploads are `commands.staged_bytes`.
    frame_data_bytes: u64 = 0,
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
