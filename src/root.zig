//! A GPU-driven Vulkan 1.3 renderer for 2D and 3D. `Renderer` draws scenes of
//! glTF models through the full frame pipeline; `rhi` is the explicit device
//! layer it is built on.
const renderer = @import("render/renderer.zig");

/// The explicit Vulkan 1.3 device layer. `Renderer.device` is the shared
/// device.
pub const rhi = @import("rhi/rhi.zig");
/// Vectors, quaternions and column-major 4x4 matrices. Right-handed, +Y
/// up, cameras look down -Z; `mul(a, b)` applies `b` first.
pub const math = @import("math.zig");
/// A minimal PNG encoder.
pub const png = @import("png.zig");
/// TrueType loading and glyph metrics; see `Renderer.fonts.load`.
pub const font = @import("font_baker").font;
/// KTX2 texture files, including Basis Universal and Zstandard.
pub const ktx2 = @import("asset/ktx2.zig");
/// DDS texture files with block-compressed data.
pub const dds = @import("asset/dds.zig");
/// The `KHR_lights_punctual` lights of a glTF file.
pub const SceneLight = @import("asset/gltf.zig").SceneLight;
pub const loadSceneLights = @import("asset/gltf.zig").loadLights;

/// Owns the device, assets, scenes and frame pipeline. Callable from any
/// thread; `render` from one thread at a time.
pub const Renderer = renderer.Renderer;
/// Creation-time options for `Renderer.init`; fixed for its lifetime.
pub const Options = renderer.Options;
/// Hooks for an external CPU profiler; see `Options.profiler`.
pub const Profiler = renderer.Profiler;
/// Handle to shared geometry, materials and animations; see
/// `Renderer.models.load`. Handles are copyable values that stop resolving once
/// their object is destroyed.
pub const Model = renderer.Model;
/// Handle to a sky and its image-based lighting; see `Renderer.environments.load`
/// and `Renderer.environments.createSky`.
pub const Environment = renderer.Environment;
/// Handle to a world of entities, lights and effects; see
/// `Renderer.scenes.create`.
pub const Scene = renderer.Scene;
/// Handle to one placement of a model in a scene; see `Renderer.entities.spawn`.
pub const Entity = renderer.Entity;
/// What `Renderer.entities.spawn` makes an entity from.
pub const EntityDesc = renderer.EntityDesc;
/// Load state of a model or environment; see `Renderer.models.state`.
pub const AssetState = renderer.AssetState;
/// GPU storage of material textures; see `Options.texture_compression`.
pub const TextureCompression = renderer.TextureCompression;
/// Distance-based texture residency; see `Options.texture_streaming`.
pub const TextureStreaming = renderer.TextureStreaming;
/// How overlapping transparent surfaces are combined; see
/// `Settings.transparency`.
pub const TransparencyMode = renderer.TransparencyMode;
/// Encoding of a view's final picture; see `Settings.output_encoding`.
pub const OutputEncoding = renderer.OutputEncoding;
/// Counts and rest-pose bounds of a model; see `Renderer.models.info`.
pub const ModelInfo = renderer.ModelInfo;
/// Name and duration of an animation clip; see `Renderer.models.animationInfo`.
pub const AnimationInfo = renderer.AnimationInfo;
/// See `Renderer.environments.info`.
pub const EnvironmentInfo = renderer.EnvironmentInfo;
/// Where a view is seen from; see `ViewDesc.camera`.
pub const Camera = renderer.Camera;
/// A scene's shadow-casting directional light; see `Renderer.scenes.setSun`.
pub const Sun = renderer.Sun;
/// A point, spot, directional or rectangle light; see `Renderer.scenes.setLights`.
pub const Light = renderer.Light;
/// Application-supplied geometry for `Renderer.models.create`; its slices are
/// only read during that call.
pub const MeshDesc = renderer.MeshDesc;
/// Surface description in glTF's metallic-roughness model.
pub const Material = renderer.Material;
pub const LightKind = renderer.LightKind;
/// Animation clips an entity plays and their blend; see `Renderer.entities.setPose`.
pub const Pose = renderer.Pose;
/// Per-view quality and look; see `ViewDesc.settings`. May change every frame.
pub const Settings = renderer.Settings;
/// Effect quality level to start `Settings` from; see `Settings.preset`.
pub const Quality = renderer.Quality;
/// Where a view's picture goes: the window or a color texture.
pub const Target = renderer.Target;
/// Shading input shown instead of the lit picture; see `Settings.debug_view`.
pub const DebugView = renderer.DebugView;
/// How a picture rendered below output size is scaled up; see
/// `Settings.upscaling`.
pub const Upscaling = renderer.Upscaling;
/// Fraction of the output resolution an effect is computed at.
pub const EffectResolution = renderer.EffectResolution;
/// Everything `Renderer.render` draws in one frame.
pub const FrameDesc = renderer.FrameDesc;
/// One camera's picture within a frame; see `FrameDesc.views`.
pub const ViewDesc = renderer.ViewDesc;
/// Handle to per-camera state kept between frames. Needed only when several
/// cameras are drawn in one frame; see `Renderer.views.create`.
pub const View = renderer.View;
/// A rectangle of a target, in pixels from the top-left corner.
pub const Region = renderer.Region;
/// Custom surface code from `Renderer.materials.createShader`; its `slot` goes in
/// `Material.shader`.
pub const MaterialShader = renderer.MaterialShader;
/// A box projecting a color or image onto opaque surfaces; see
/// `Renderer.scenes.setDecals`.
pub const DecalDesc = renderer.DecalDesc;
/// Replacement textures for a material; see `Renderer.materials.setTextures`.
pub const MaterialTextures = renderer.MaterialTextures;
/// A layer of volumetric clouds over a scene; see `Renderer.scenes.setClouds`.
pub const CloudDesc = renderer.CloudDesc;
/// Handle to a box of simulated smoke and fire; see `Renderer.fluids.create`.
pub const Fluid = renderer.Fluid;
/// See `Renderer.fluids.create` and `Renderer.fluids.set`.
pub const FluidDesc = renderer.FluidDesc;
/// Frames recorded from a fluid as a sprite sheet; see
/// `Renderer.fluids.recordFlipbook`.
pub const FluidFlipbookDesc = renderer.FluidFlipbookDesc;
/// Where smoke, heat or fuel enters a fluid; see `FluidDesc.sources`.
pub const FluidSource = renderer.FluidSource;
/// What happens at the sides of a fluid's box; see `FluidDesc.walls`.
pub const FluidWalls = renderer.FluidWalls;
/// A solid inside a fluid's box, in box coordinates 0..1; see
/// `FluidDesc.obstacles`.
pub const FluidObstacle = renderer.FluidObstacle;
/// How an entity's lightmap is baked; see `Renderer.entities.bakeLightmap`.
pub const LightmapDesc = renderer.LightmapDesc;
/// How far copies of an instance group are drawn as cards; see
/// `Renderer.instances.setImpostor`.
pub const ImpostorDesc = renderer.ImpostorDesc;
/// Handle to strands of hair, fur or grass; see `Renderer.hairs.create`.
pub const Hair = renderer.Hair;
/// Strands as rows of points, drawn as camera-facing ribbons.
pub const HairDesc = renderer.HairDesc;
/// Handle to a shape hair is kept out of; see `Renderer.hairs.createCollisionField`.
pub const CollisionField = renderer.CollisionField;
/// Hair strand dynamics; see `HairDesc.simulation`.
pub const HairSimulation = renderer.HairSimulation;
/// Handle to a sheet of simulated water; see `Renderer.waters.create`.
pub const Water = renderer.Water;
/// A height-simulated sheet of water; see `Renderer.waters.create`.
pub const WaterDesc = renderer.WaterDesc;
/// Handle to a volume of particle-simulated liquid; see
/// `Renderer.liquids.create`.
pub const Liquid = renderer.Liquid;
/// A particle-simulated liquid volume; far costlier than a `WaterDesc` sheet.
pub const LiquidDesc = renderer.LiquidDesc;
/// A jet pouring into a liquid; see `LiquidDesc.sources`.
pub const LiquidSource = renderer.LiquidSource;
/// Handle to many copies of one model; see `Renderer.instances.create`.
pub const InstanceGroup = renderer.InstanceGroup;
/// A procedural clear sky; see `Renderer.environments.createSky` and `Renderer.environments.setSky`.
pub const SkyDesc = renderer.SkyDesc;
/// The `Sun` matching a sky, attenuated by the atmosphere; pass it to
/// `Renderer.scenes.setSun`.
pub const skySun = renderer.skySun;
/// Handle to a particle emitter in a scene; see `Renderer.emitters.create`.
pub const Emitter = renderer.Emitter;
/// A particle source; see `Renderer.emitters.create`.
pub const EmitterDesc = renderer.EmitterDesc;
/// A lightning flash in a cloud layer; see `Renderer.scenes.cloudFlash`.
pub const CloudFlash = renderer.CloudFlash;
/// The 64 two-group splits of a BC7 block (bit i set: texel i is in the
/// second group); for tests of the texture encoder.
pub const bc7_partitions = @import("texture_codec").partitions;
/// Handle to a local reflection probe; see `Renderer.probes.create`.
pub const ReflectionProbe = renderer.ReflectionProbe;
/// A local reflection capture, used inside its box where neither the screen nor
/// a ray gives a reflection.
pub const ReflectionProbeDesc = renderer.ReflectionProbeDesc;
/// How particles blend with the picture; see `EmitterDesc.blend`.
pub const ParticleBlend = renderer.ParticleBlend;
/// What was found under a pixel; see `PickResult.hit`.
pub const Pick = renderer.Pick;
/// The answer to a `Renderer.requestPick`; see `Renderer.takePick`.
pub const PickResult = renderer.PickResult;
/// Application code run at a `PassStage`; see `ViewDesc.passes`. It must not
/// call back into the `Renderer`.
pub const Pass = renderer.Pass;
/// The points in a view's frame where a `Pass` can run.
pub const PassStage = renderer.PassStage;
/// What a `Pass` is given: the device, the encoder and the view's textures.
pub const PassContext = renderer.PassContext;
/// Format of `PassContext.color` before tone mapping (RGBA16F).
pub const scene_color_format = renderer.scene_color_format;
/// How path tracing follows rays on this device; see `Renderer.pathTracing`.
pub const PathTracing = renderer.PathTracing;
/// Counters for the last frame; see `Renderer.getStats`.
pub const Stats = renderer.Stats;

const draw_list = @import("render/draw_list.zig");
/// Immediate-mode shapes, images and text. CPU data owned by the caller; see
/// `ViewDesc.draw_lists`. Free with `deinit`.
pub const DrawList = draw_list.DrawList;
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
    _ = @import("render/frame_graph.zig");
    _ = @import("render/collision_field.zig");
    _ = @import("render/api.zig");
    _ = @import("render/gpu.zig");
    _ = @import("render/animation.zig");
    _ = @import("render/draw_list.zig");
    _ = @import("render/bvh.zig");
    _ = @import("rhi/rhi.zig");
}
