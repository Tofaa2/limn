//! Per-view settings, one nested struct per feature.
const std = @import("std");
const rhi = @import("../../rhi/rhi.zig");
const features = @import("../core/features.zig");

const api = @import("../api.zig");
const Material = api.Material;
const SunDesc = api.SunDesc;
const ViewDesc = api.ViewDesc;

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

    /// A guess from the adapter's kind, ray tracing support and memory. Phone
    /// GPUs, which are tile-based, get `.low`; Apple's get `.medium`.
    pub fn recommended(adapter: rhi.AdapterInfo) Quality {
        const ultra_memory_bytes = 10 << 30;
        if (adapter.tiled) return if (adapter.vendor_id == 0x106b) .medium else .low;
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
pub const AmbientOcclusion = @import("../features/ambient_occlusion.zig").Settings;
/// `Settings.canvas`.
pub const Canvas = @import("../features/canvas.zig").Settings;

/// `Settings.geometry`.
pub const Geometry = @import("../features/geometry.zig").Settings;
/// `Settings.shading`.
pub const Shading = @import("../features/shading.zig").Settings;
/// `Settings.shadows`.
pub const Shadows = @import("../features/shadows.zig").Settings;
/// `Settings.reflections`.
pub const Reflections = @import("../features/reflections.zig").Settings;
/// `Settings.global_illumination`.
pub const GlobalIllumination = @import("../features/global_illumination.zig").Settings;
/// `Settings.path_tracing`.
pub const PathTracing = @import("../features/path_tracing.zig").Settings;
/// `Settings.path_tracing.nrd`.
pub const NrdSettings = @import("../features/path_tracing.zig").Nrd;
/// `Settings.transparency`.
pub const Transparency = @import("../features/transparency.zig").Settings;
/// `Settings.fog`.
pub const Fog = @import("../features/fog.zig").Settings;
/// `Settings.clouds`.
pub const Clouds = @import("../features/clouds.zig").Settings;
/// `Settings.fluids`.
pub const Fluids = @import("../features/fluids.zig").Settings;
/// `Settings.post`.
pub const Post = @import("../features/post.zig").Settings;
/// `Settings.resolution`.
pub const Resolution = @import("../features/resolution.zig").Settings;
/// `Settings.output`.
pub const Output = @import("../features/output.zig").Settings;
/// `Settings.post.depth_of_field`.
pub const DepthOfField = @import("../features/post.zig").DepthOfField;
/// `Settings.post.motion_blur`.
pub const MotionBlur = @import("../features/post.zig").MotionBlur;

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

    /// Every optional feature off. What remains: GPU culling, direct sun,
    /// sky and lamp light, and tone mapping at a fixed exposure. A start for
    /// simple 3D and for views where 2D is drawn over a scene; turn on what a
    /// view needs.
    pub const lightweight = Settings{
        .shadows = null,
        .ambient_occlusion = null,
        .reflections = null,
        .global_illumination = null,
        .clouds = null,
        .fluids = null,
        .post = .{ .bloom = 0, .automatic_exposure = false },
        .resolution = .{ .temporal_antialiasing = false },
    };

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
    /// Height fog lit by the sun and the sky. Null for none.
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

/// See `Settings.debug_view`. Values match the switch in `shaders/shade.slang`.
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

test "a quality level is recommended by the kind of GPU" {
    const gibibyte = 1 << 30;
    try std.testing.expectEqual(Quality.low, Quality.recommended(.{ .kind = .integrated, .vendor_id = 0x8086, .memory_bytes = 16 * gibibyte, .ray_tracing = true }));
    try std.testing.expectEqual(Quality.low, Quality.recommended(.{ .kind = .software, .vendor_id = 0, .memory_bytes = 0, .ray_tracing = false }));
    try std.testing.expectEqual(Quality.medium, Quality.recommended(.{ .kind = .discrete, .vendor_id = 0x1002, .memory_bytes = 8 * gibibyte, .ray_tracing = false }));
    try std.testing.expectEqual(Quality.high, Quality.recommended(.{ .kind = .discrete, .vendor_id = 0x10de, .memory_bytes = 8 * gibibyte, .ray_tracing = true }));
    try std.testing.expectEqual(Quality.ultra, Quality.recommended(.{ .kind = .discrete, .vendor_id = 0x10de, .memory_bytes = 16 * gibibyte, .ray_tracing = true }));
    try std.testing.expectEqual(Quality.low, Quality.recommended(.{ .kind = .integrated, .vendor_id = 0x5143, .memory_bytes = 8 * gibibyte, .ray_tracing = true, .tiled = true }));
}

test "the ultra preset is the default settings" {
    try std.testing.expectEqualDeep(Settings{}, Settings.preset(.ultra));
}
