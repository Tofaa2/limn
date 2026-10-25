//! A GPU-driven Vulkan 1.3 renderer for 2D and 3D. `Renderer` draws scenes of
//! glTF models through the full frame pipeline; `rhi` is the explicit device
//! layer it is built on.
const renderer = @import("render/renderer.zig");
const api = @import("render/api.zig");

/// The explicit Vulkan 1.3 device layer. `Renderer.device` is the shared
/// device.
pub const rhi = @import("rhi/rhi.zig");
/// Vectors, quaternions and column-major 4x4 matrices. Right-handed, +Y
/// up, cameras look down -Z; `mul(a, b)` applies `b` first.
pub const math = @import("math.zig");
/// Simple shapes as mesh data; see `Renderer.models.createPrimitive`.
pub const primitives = @import("render/primitives.zig");
/// A minimal PNG encoder.
pub const png = @import("png.zig");
/// TrueType loading and glyph metrics; see `Renderer.fonts.load`.
pub const font = @import("font_baker").font;
/// KTX2 texture files, including Basis Universal and Zstandard.
pub const ktx2 = @import("asset/ktx2.zig");
/// DDS texture files with block-compressed data.
pub const dds = @import("asset/dds.zig");

/// Owns the device, assets, scenes and frame pipeline. Callable from any
/// thread; `render` from one thread at a time.
pub const Renderer = renderer.Renderer;
/// Creation-time options for `Renderer.init`; fixed for its lifetime.
pub const Options = api.Options;
pub const RayTracingOptions = api.RayTracingOptions;
pub const ShadowOptions = api.ShadowOptions;
pub const TextureOptions = api.TextureOptions;
pub const GeometryOptions = api.GeometryOptions;
pub const CacheOptions = api.CacheOptions;
pub const ImageDesc = api.ImageDesc;
pub const EnvironmentDesc = api.EnvironmentDesc;
pub const SceneEnvironment = api.SceneEnvironment;
pub const ShaderAssignment = api.ShaderAssignment;
/// Hooks for an external CPU profiler; see `Options.profiler`.
pub const Profiler = api.Profiler;
/// Handle to shared geometry, materials and animations; see
/// `Renderer.models.load`. Handles are copyable values that stop resolving once
/// their object is destroyed.
pub const Model = api.Model;
/// Handle to a sky and its image-based lighting; see `Renderer.environments.load`
/// and `Renderer.environments.createSky`.
pub const Environment = api.Environment;
/// Handle to a world of entities, lights and effects; see
/// `Renderer.scenes.create`.
pub const Scene = api.Scene;
/// Handle to one placement of a model in a scene; see `Renderer.entities.create`.
pub const Entity = api.Entity;
/// What `Renderer.entities.create` makes an entity from.
pub const EntityDesc = api.EntityDesc;
pub const EntityInfo = api.EntityInfo;
/// Load state of a model or environment; see `Renderer.models.state`.
pub const AssetState = api.AssetState;
/// GPU storage of material textures; see `Options.textures.compression`.
pub const TextureCompression = api.TextureCompression;
/// Distance-based texture residency; see `Options.textures.streaming`.
pub const TextureStreaming = api.TextureStreaming;
/// Releasing far models' geometry; see `Options.geometry.streaming`.
pub const GeometryStreaming = api.GeometryStreaming;
/// How overlapping transparent surfaces are combined; see
/// `Settings.transparency.mode`.
pub const TransparencyMode = api.TransparencyMode;
/// Encoding of a view's final picture; see `Settings.output.encoding`.
pub const OutputEncoding = api.OutputEncoding;
/// Counts and rest-pose bounds of a model; see `Renderer.models.info`.
pub const ModelInfo = api.ModelInfo;
/// Name and duration of an animation clip; see `Renderer.models.animationInfo`.
pub const AnimationInfo = api.AnimationInfo;
/// See `Renderer.environments.info`.
pub const EnvironmentInfo = api.EnvironmentInfo;
/// Where a view is seen from; see `ViewDesc.camera`.
pub const Camera = api.Camera;
pub const Projected = api.Projected;
pub const Ray = api.Ray;
pub const Orthographic = api.Orthographic;
/// A scene's shadow-casting directional light; see `Renderer.scenes.setSun`.
pub const SunDesc = api.SunDesc;
/// A point, spot, directional or rectangle light; see `Renderer.scenes.setLights`.
pub const LightDesc = api.LightDesc;
/// Application-supplied geometry for `Renderer.models.create`; its slices are
/// only read during that call.
pub const MeshDesc = api.MeshDesc;
pub const PrimitiveDesc = api.PrimitiveDesc;
/// Surface description in glTF's metallic-roughness model.
pub const Material = api.Material;
pub const LightKind = api.LightKind;
/// Animation clips an entity plays and their blend; see `Renderer.entities.setPose`.
pub const Pose = api.Pose;
/// Per-view quality and look; see `ViewDesc.settings`. May change every frame.
pub const Settings = api.Settings;
/// Effect quality level to start `Settings` from; see `Settings.preset`.
pub const Quality = api.Quality;
/// Where a view's picture goes: the window or a color texture.
pub const Target = api.Target;
/// Shading input shown instead of the lit picture; see `Settings.debug_view`.
pub const DebugView = api.DebugView;
/// How a picture rendered below output size is scaled up; see
/// `Settings.resolution.upscaler`.
pub const Upscaler = api.Upscaler;
pub const FrameGeneration = api.FrameGeneration;
pub const Denoiser = api.Denoiser;
pub const DirectSampling = api.DirectSampling;
/// Fraction of the output resolution an effect is computed at.
pub const EffectResolution = api.EffectResolution;
/// Everything `Renderer.render` draws in one frame.
pub const FrameDesc = api.FrameDesc;
/// One camera's picture within a frame; see `FrameDesc.views`.
pub const ViewDesc = api.ViewDesc;
/// A draw list and when in the view's frame it is drawn; see `ViewDesc.draw_lists`.
pub const DrawLayer = api.DrawLayer;
/// When in a view's frame a draw list is drawn.
pub const DrawStage = api.DrawStage;
/// `Settings.ambient_occlusion`.
pub const AmbientOcclusion = api.AmbientOcclusion;
/// `Settings.canvas`.
pub const Canvas = api.Canvas;
/// `Settings.geometry`.
pub const Geometry = api.Geometry;
/// `Settings.shading`.
pub const Shading = api.Shading;
/// `Settings.shadows`.
pub const Shadows = api.Shadows;
/// `Settings.reflections`.
pub const Reflections = api.Reflections;
/// `Settings.global_illumination`.
pub const GlobalIllumination = api.GlobalIllumination;
/// `Settings.path_tracing`.
pub const PathTracing = api.PathTracing;
pub const NrdSettings = api.NrdSettings;
/// `Settings.transparency`.
pub const Transparency = api.Transparency;
/// `Settings.fog`.
pub const Fog = api.Fog;
/// `Settings.clouds`.
pub const Clouds = api.Clouds;
/// `Settings.fluids`.
pub const Fluids = api.Fluids;
/// `Settings.post`.
pub const Post = api.Post;
/// `Settings.post.depth_of_field`.
pub const DepthOfField = api.DepthOfField;
/// `Settings.post.motion_blur`.
pub const MotionBlur = api.MotionBlur;
/// `Settings.resolution`.
pub const Resolution = api.Resolution;
/// `Settings.output`.
pub const Output = api.Output;
/// A setting a view asked for and did not get; see `Stats.downgraded`.
pub const Downgrade = api.Downgrade;
/// Why a view did not get what its settings asked for.
pub const DowngradeReason = api.DowngradeReason;
/// Handle to per-camera state kept between frames. Needed only when several
/// cameras are drawn in one frame; see `Renderer.views.create`.
pub const View = api.View;
/// A rectangle of a target, in pixels from the top-left corner.
pub const Region = api.Region;
/// Custom surface code from `Renderer.materials.createShader`; its `slot` goes in
/// `Material.shader`.
pub const MaterialShader = api.MaterialShader;
/// A box projecting a color or image onto opaque surfaces; see
/// `Renderer.scenes.setDecals`.
pub const DecalDesc = api.DecalDesc;
/// Replacement textures for a material; see `Renderer.materials.setTextures`.
pub const MaterialTextures = api.MaterialTextures;
/// A layer of volumetric clouds over a scene; see `Renderer.scenes.setClouds`.
pub const CloudDesc = api.CloudDesc;
/// Handle to a box of simulated smoke and fire; see `Renderer.fluids.create`.
pub const Fluid = api.Fluid;
/// See `Renderer.fluids.create` and `Renderer.fluids.set`.
pub const FluidDesc = api.FluidDesc;
/// Frames recorded from a fluid as a sprite sheet; see
/// `Renderer.fluids.recordFlipbook`.
pub const FluidFlipbookDesc = api.FluidFlipbookDesc;
/// Where smoke, heat or fuel enters a fluid; see `FluidDesc.sources`.
pub const FluidSource = api.FluidSource;
/// What happens at the sides of a fluid's box; see `FluidDesc.walls`.
pub const FluidWalls = api.FluidWalls;
/// A solid inside a fluid's box, in box coordinates 0..1; see
/// `FluidDesc.obstacles`.
pub const FluidObstacle = api.FluidObstacle;
/// How an entity's lightmap is baked; see `Renderer.entities.bakeLightmap`.
pub const LightmapDesc = api.LightmapDesc;
/// How far copies of an instance group are drawn as cards; see
/// `Renderer.instances.setImpostor`.
pub const ImpostorDesc = api.ImpostorDesc;
/// Handle to strands of hair, fur or grass; see `Renderer.hairs.create`.
pub const Hair = api.Hair;
/// Strands as rows of points, drawn as camera-facing ribbons.
pub const HairDesc = api.HairDesc;
/// Handle to a shape hair is kept out of; see `Renderer.hairs.createCollisionField`.
pub const CollisionField = api.CollisionField;
/// Hair strand dynamics; see `HairDesc.simulation`.
pub const HairSimulation = api.HairSimulation;
/// Handle to a sheet of simulated water; see `Renderer.waters.create`.
pub const Water = api.Water;
/// A height-simulated sheet of water; see `Renderer.waters.create`.
pub const WaterDesc = api.WaterDesc;
/// Handle to a volume of particle-simulated liquid; see
/// `Renderer.liquids.create`.
pub const Liquid = api.Liquid;
/// A particle-simulated liquid volume; far costlier than a `WaterDesc` sheet.
pub const LiquidDesc = api.LiquidDesc;
/// A jet pouring into a liquid; see `LiquidDesc.sources`.
pub const LiquidSource = api.LiquidSource;
/// Handle to many copies of one model; see `Renderer.instances.create`.
pub const InstanceGroup = api.InstanceGroup;
/// A procedural clear sky; see `Renderer.environments.createSky` and `Renderer.environments.setSky`.
pub const SkyDesc = api.SkyDesc;
/// The `SunDesc` matching a sky, attenuated by the atmosphere; pass it to
/// `Renderer.scenes.setSun`.
pub const skySun = api.skySun;
/// Handle to a particle emitter in a scene; see `Renderer.emitters.create`.
pub const Emitter = api.Emitter;
/// A particle source; see `Renderer.emitters.create`.
pub const EmitterDesc = api.EmitterDesc;
/// A lightning flash in a cloud layer; see `Renderer.scenes.cloudFlash`.
pub const CloudFlash = api.CloudFlash;
/// Handle to a local reflection probe; see `Renderer.reflection_probes.create`.
pub const ReflectionProbe = api.ReflectionProbe;
/// One light of a scene, set and removed on its own; see `Renderer.lights`.
pub const Light = api.Light;
/// One decal of a scene, set and removed on its own; see `Renderer.decals`.
pub const Decal = api.Decal;
/// A local reflection capture, used inside its box where neither the screen nor
/// a ray gives a reflection.
pub const ReflectionProbeDesc = api.ReflectionProbeDesc;
/// How particles blend with the picture; see `EmitterDesc.blend`.
pub const ParticleBlend = api.ParticleBlend;
/// What was found under a pixel; see `PickResult.hit`.
pub const Pick = api.Pick;
/// The answer to a `Renderer.requestPick`; see `Renderer.takePick`.
pub const PickResult = api.PickResult;
/// Application code run at a `PassStage`; see `ViewDesc.passes`. It must not
/// call back into the `Renderer`.
pub const Pass = api.Pass;
/// The points in a view's frame where a `Pass` can run.
pub const PassStage = api.PassStage;
/// What a `Pass` can read; see `Pass.reads`.
pub const PassRead = api.PassRead;
/// What a `Pass` is given: the device, the encoder and the view's textures.
pub const PassContext = api.PassContext;
/// Format of `PassContext.color` before tone mapping (RGBA16F).
pub const scene_color_format = api.scene_color_format;
/// How path tracing follows rays on this device; see `Renderer.capabilities`.
pub const PathTracingSupport = api.PathTracingSupport;
pub const Support = api.Support;
pub const Capabilities = api.Capabilities;
/// Counters for the last frame; see `Renderer.stats`.
pub const Stats = api.Stats;

const draw_list = @import("render/draw_list.zig");
/// Immediate-mode shapes, images and text. CPU data owned by the caller; see
/// `ViewDesc.draw_lists`. Free with `deinit`.
pub const DrawList = draw_list.DrawList;
/// How a draw list combines what it draws with the picture; see `DrawList.setBlend`.
pub const Blend = draw_list.Blend;
/// A fragment shader for draw lists; see `Renderer.canvas.createShader`.
pub const CanvasShader = draw_list.CanvasShader;
/// A distance-field font; see `Renderer.fonts.load`. Renderer-owned, readable
/// from any thread until `Renderer.fonts.destroy`.
pub const Font = draw_list.Font;
/// A texture usable by draw lists; see `Renderer.images.create`. Copyable; valid
/// until the image is destroyed.
pub const Image = draw_list.Image;
/// An 8-bit sRGB color with opacity.
pub const Color = draw_list.Color;
/// Top-left corner and size, in pixels for screen-space calls.
pub const Rect = draw_list.Rect;
/// An outline of lines and curves for `DrawList.fillPath` and
/// `DrawList.strokePath`. Free with `deinit`.
pub const Path = draw_list.Path;
/// A grid of equal frames in one image; `frame` gives one's source rectangle.
pub const SpriteSheet = draw_list.SpriteSheet;
/// A 2D affine transform; see `DrawList.pushTransform`.
pub const Transform2D = draw_list.Transform2D;
/// Options for `DrawList.text`; size is in pixels per em.
pub const TextOptions = draw_list.TextOptions;
/// Options for `DrawList.text3d`; size is in world units per em.
pub const Text3dOptions = draw_list.Text3dOptions;
/// Horizontal text alignment; see `TextOptions.alignment`.
pub const Alignment = draw_list.Alignment;

test {
    _ = @import("math.zig");
    _ = @import("handle.zig");
    _ = @import("asset/gltf.zig");
    _ = @import("asset/model_cache.zig");
    _ = @import("asset/ktx2.zig");
    _ = @import("asset/dds.zig");
    _ = @import("render/text_layout.zig");
    _ = @import("render/renderer.zig");
    _ = @import("render/renderer/images.zig");
    _ = @import("render/renderer/view_math.zig");
    _ = @import("render/core/pipeline_cache.zig");
    _ = @import("render/core/graph.zig");
    _ = @import("render/core/spirv_readonly.zig");
    _ = @import("render/core/features.zig");
    _ = @import("render/core/slot.zig");
    _ = @import("render/core/shader_gen.zig");
    _ = @import("render/collision_field.zig");
    _ = @import("render/api.zig");
    _ = @import("render/gpu.zig");
    _ = @import("render/api/scene.zig");
    _ = @import("render/primitives.zig");
    _ = @import("render/animation.zig");
    _ = @import("render/draw_list.zig");
    _ = @import("render/bvh.zig");
    _ = @import("rhi/rhi.zig");
}
