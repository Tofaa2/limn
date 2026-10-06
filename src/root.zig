//! A GPU-driven Vulkan 1.3 renderer for 2D and 3D.
//!
//! Two layers are exposed:
//!
//! * `Renderer` — scenes of glTF models, image-based lighting and the full
//!   frame pipeline. This is what applications normally use:
//!
//!   ```zig
//!   const gfx = @import("limn");
//!
//!   const renderer = try gfx.Renderer.init(gpa, io, .{ .surface = surface });
//!   defer renderer.deinit();
//!   const scene = try renderer.createScene();
//!   const model = try renderer.loadModel("Sponza.glb"); // streams in
//!   _ = try renderer.spawn(scene, .{ .model = model });
//!   renderer.setSun(scene, .{ .direction = .{ -0.3, -1, -0.2 }, .intensity = 20 });
//!   while (running) {
//!       _ = try renderer.render(.{
//!           .views = &.{.{ .scene = scene, .camera = camera }},
//!           .delta_time = dt,
//!       });
//!   }
//!   ```
//!
//! * `rhi` — the explicit device layer (buffers, textures, pipelines, command
//!   encoding, frame loop) the renderer is built on. Use it directly for
//!   custom rendering; `renderer.device` gives access to the shared device.
const renderer = @import("render/renderer.zig");

/// The explicit Vulkan 1.3 device layer: buffers, textures, pipelines,
/// command encoding and the frame loop. `Renderer.device` is the shared
/// device, for custom passes and offscreen targets.
pub const rhi = @import("rhi/rhi.zig");
/// Vectors, quaternions and column-major 4x4 matrices. Right-handed, +Y
/// up, cameras look down -Z; `mul(a, b)` applies `b` first.
pub const math = @import("math.zig");
/// A minimal PNG encoder, for screenshots and tests.
pub const png = @import("png.zig");
/// TrueType loading and glyph metrics; see `Renderer.loadFont`.
pub const font = @import("font_baker").font;
/// KTX2 texture files: block-compressed, uncompressed and Basis Universal
/// textures, plain or Zstandard-compressed.
pub const ktx2 = @import("asset/ktx2.zig");

/// The renderer: owns the device, the loaded assets, the scenes and the
/// frame pipeline. Created on the heap by `Renderer.init`, destroyed by
/// `deinit`. Its functions may be called from any thread; `render` from
/// one thread at a time.
pub const Renderer = renderer.Renderer;
/// Choices made when the renderer is created (`Renderer.init`): the window
/// surface, validation, texture compression and streaming, HDR output.
/// Fixed for the renderer's lifetime; per-frame choices are in `Settings`.
pub const Options = renderer.Options;
/// Hooks called around the renderer's CPU work, for an external profiler
/// such as Tracy; see `Options.profiler`.
pub const Profiler = renderer.Profiler;
/// Handle to geometry, materials and animations shared by any number of
/// entities; see `Renderer.loadModel` and `Renderer.createModel`. Like
/// every handle here it is a small value, free to copy, that stops
/// resolving once the thing it names is destroyed.
pub const Model = renderer.Model;
/// Handle to a sky and the image-based lighting made from it; see
/// `Renderer.loadEnvironment`, `Renderer.createSky` and
/// `Renderer.setEnvironment`.
pub const Environment = renderer.Environment;
/// Handle to a world of entities, lights and effects that views draw; see
/// `Renderer.createScene`.
pub const Scene = renderer.Scene;
/// Handle to one placement of a model in a scene; see `Renderer.spawn`
/// and `Renderer.despawn`.
pub const Entity = renderer.Entity;
/// What `Renderer.spawn` makes an entity from: the model, its transform,
/// visibility, tint and shader parameters.
pub const EntityDesc = renderer.EntityDesc;
/// Whether a model or environment is still loading, ready, or failed; see
/// `Renderer.modelState` and `Renderer.environmentState`.
pub const AssetState = renderer.AssetState;
/// How material textures are stored on the GPU: plain RGBA8 or BC7 at a
/// quarter of the memory; see `Options.texture_compression`.
pub const TextureCompression = renderer.TextureCompression;
/// Keeps only as much of each model texture in GPU memory as the cameras
/// can make use of; see `Options.texture_streaming`.
pub const TextureStreaming = renderer.TextureStreaming;
/// How overlapping transparent surfaces are combined: sorted per mesh,
/// weighted without order, or depth-peeled per pixel; see
/// `Settings.transparency`.
pub const TransparencyMode = renderer.TransparencyMode;
/// How a view's final picture is encoded: sRGB, HDR10, or whichever the
/// target calls for; see `Settings.output_encoding`.
pub const OutputEncoding = renderer.OutputEncoding;
/// Counts and rest-pose bounds of a loaded model; see
/// `Renderer.modelInfo`, which returns null until the model is ready.
pub const ModelInfo = renderer.ModelInfo;
/// Name and duration in seconds of one animation clip of a model; see
/// `Renderer.animationInfo`.
pub const AnimationInfo = renderer.AnimationInfo;
/// What is known about a loaded environment, such as the direction of its
/// brightest part; see `Renderer.environmentInfo`.
pub const EnvironmentInfo = renderer.EnvironmentInfo;
/// Where a view is seen from: position, direction, vertical field of view
/// in radians and near plane; see `ViewDesc.camera`.
pub const Camera = renderer.Camera;
/// A scene's directional light, the one that casts cascaded shadows; see
/// `Renderer.setSun`. `direction` is the way the light travels.
pub const Sun = renderer.Sun;
/// A point, spot, directional or rectangular area light. A scene's lights
/// are replaced as a whole with `Renderer.setLights`.
pub const Light = renderer.Light;
/// Geometry supplied by the application instead of a file: positions,
/// indices and optional normals, UVs and colors; see
/// `Renderer.createModel`. The slices are only read during that call.
pub const MeshDesc = renderer.MeshDesc;
/// Surface description of a mesh in glTF's metallic-roughness model, as
/// imported from a file or given in `MeshDesc.material`.
pub const Material = renderer.Material;
/// The shape of a `Light`; see `Light.kind`.
pub const LightKind = renderer.LightKind;
/// Which animation clips an entity plays, how far into them it is and how
/// they are blended; see `Renderer.setPose`.
pub const Pose = renderer.Pose;
/// Quality and look of one view: shadows, reflections, global
/// illumination, fog, antialiasing, tone mapping and the rest; see
/// `ViewDesc.settings`. May differ between views and change every frame.
pub const Settings = renderer.Settings;
/// A level of effect quality, low to ultra, to start `Settings` from; see
/// `Settings.preset` and `Renderer.recommendedQuality`.
pub const Quality = renderer.Quality;
/// Where a view's picture goes: the window or a color texture; see
/// `ViewDesc.target` and `Renderer.createTarget`.
pub const Target = renderer.Target;
/// One input of the shading shown in place of the lit picture (albedo,
/// normals, shadow cascades, meshlets, ...); see `Settings.debug_view`.
pub const DebugView = renderer.DebugView;
/// Fraction of the output resolution an effect is computed at: full, half
/// or quarter; see the `*_resolution` fields of `Settings`.
pub const EffectResolution = renderer.EffectResolution;
/// Everything `Renderer.render` draws in one frame: the views, in order,
/// and the time since the previous frame in seconds.
pub const FrameDesc = renderer.FrameDesc;
/// One camera's picture within a frame: the scene, the camera, the draw
/// lists laid over it, the target and the settings; see `FrameDesc.views`.
pub const ViewDesc = renderer.ViewDesc;
/// Handle to per-camera state that persists between frames (temporal
/// history, exposure, shadow cascades). Only needed when several cameras
/// are drawn in one frame; see `Renderer.createView` and `ViewDesc.view`.
pub const View = renderer.View;
/// A rectangle of a target, in pixels from the top-left corner, for split
/// screen and insets; see `ViewDesc.region`.
pub const Region = renderer.Region;
/// Application surface code registered with
/// `Renderer.createMaterialShader`; its `slot` goes in `Material.shader`.
pub const MaterialShader = renderer.MaterialShader;
/// A box that projects a color or an image onto the opaque surfaces
/// inside it. A scene's decals are replaced as a whole with
/// `Renderer.setDecals`.
pub const DecalDesc = renderer.DecalDesc;
/// Application images to use as a material's textures in place of the
/// model's own; see `Renderer.setMaterialTextures`.
pub const MaterialTextures = renderer.MaterialTextures;
/// A layer of volumetric clouds over a scene; see `Renderer.setClouds`.
pub const CloudDesc = renderer.CloudDesc;
/// Handle to a box of simulated smoke and fire in a scene; see
/// `Renderer.createFluid`.
pub const Fluid = renderer.Fluid;
/// What a fluid is made from and how it behaves; see
/// `Renderer.createFluid` and `Renderer.setFluid`.
pub const FluidDesc = renderer.FluidDesc;
/// A sheet of frames recorded from a running fluid, to play back as a
/// sprite; see `Renderer.recordFluidFlipbook`.
pub const FluidFlipbookDesc = renderer.FluidFlipbookDesc;
/// A place inside a fluid's box where smoke, heat or fuel enters; see
/// `FluidDesc.sources`.
pub const FluidSource = renderer.FluidSource;
/// What happens at the sides of a fluid's box; see `FluidDesc.walls`.
pub const FluidWalls = renderer.FluidWalls;
/// Something solid inside a fluid's box that the flow goes around, in the
/// box's own 0..1 coordinates; see `FluidDesc.obstacles`.
pub const FluidObstacle = renderer.FluidObstacle;
/// Handle to a sheet of simulated water in a scene; see
/// `Renderer.createWater`.
pub const Water = renderer.Water;
/// A sheet of water whose height is simulated: ripples, rain, swell,
/// reflection and refraction; see `Renderer.createWater` and
/// `Renderer.setWater`.
pub const WaterDesc = renderer.WaterDesc;
/// Handle to a volume of particle-simulated liquid in a scene; see
/// `Renderer.createLiquid`.
pub const Liquid = renderer.Liquid;
/// A volume of liquid made of particles that pour, slosh and splash,
/// drawn as one surface; see `Renderer.createLiquid`. Costs far more than
/// a `WaterDesc` sheet of the same area.
pub const LiquidDesc = renderer.LiquidDesc;
/// Where liquid pours into a `LiquidDesc` volume; see
/// `LiquidDesc.sources`.
pub const LiquidSource = renderer.LiquidSource;
/// Handle to many copies of one model, placed by a list of transforms;
/// see `Renderer.createInstances`.
pub const InstanceGroup = renderer.InstanceGroup;
/// A clear sky computed from the sun's position instead of loaded from a
/// photograph; see `Renderer.createSky` and `Renderer.setSky`.
pub const SkyDesc = renderer.SkyDesc;
/// The `Sun` that goes with a sky: its direction, and the color and
/// strength left after the light has crossed the atmosphere. Pass the
/// result to `Renderer.setSun`.
pub const skySun = renderer.skySun;
/// Handle to a particle emitter in a scene; see `Renderer.createEmitter`.
pub const Emitter = renderer.Emitter;
/// A source of particles in a scene; see `Renderer.createEmitter`.
/// Everything except `capacity` can be changed later with
/// `Renderer.setEmitter`.
pub const EmitterDesc = renderer.EmitterDesc;
/// Where a lightning flash in a scene's cloud layer is and how bright;
/// see `Renderer.cloudFlash`.
pub const CloudFlash = renderer.CloudFlash;
/// The 64 two-group splits of a BC7 block (bit i set: texel i is in the
/// second group); for tests of the texture encoder.
pub const bc7_partitions = @import("texture_codec").partitions;
/// Handle to a local reflection probe in a scene; see
/// `Renderer.createReflectionProbe`.
pub const ReflectionProbe = renderer.ReflectionProbe;
/// A local reflection probe: a picture of the surroundings taken from one
/// place, mirrored by surfaces inside the probe's box where neither the
/// screen nor a ray gives a reflection; see
/// `Renderer.createReflectionProbe`.
pub const ReflectionProbeDesc = renderer.ReflectionProbeDesc;
/// How an emitter's particles are laid over the picture: covering what is
/// behind them or adding light; see `EmitterDesc.blend`.
pub const ParticleBlend = renderer.ParticleBlend;
/// What was found under a pixel: the entity or instance-group copy, the
/// world-space point and its distance; see `PickResult.hit`.
pub const Pick = renderer.Pick;
/// The answer to a `Renderer.requestPick`, handed out once by
/// `Renderer.takePick` a few frames later.
pub const PickResult = renderer.PickResult;
/// Application code run at a `PassStage` of a view, while the frame is
/// being recorded; see `ViewDesc.passes`. It may record GPU commands but
/// must not call back into the `Renderer`.
pub const Pass = renderer.Pass;
/// The points in a view's frame where a `Pass` can run.
pub const PassStage = renderer.PassStage;
/// What a `Pass` gets to work with: the device, the command encoder and
/// the view's textures.
pub const PassContext = renderer.PassContext;
/// Format of `PassContext.color` before tone mapping (RGBA half floats);
/// pipelines of a custom pass that draws there must target it.
pub const scene_color_format = renderer.scene_color_format;
/// How path tracing follows its rays on this device: by the GPU's ray
/// tracing, by a shader, or not at all; see `Renderer.pathTracing`.
pub const PathTracing = renderer.PathTracing;
/// Counters describing the last frame: instances, meshlets and triangles
/// drawn, GPU memory, CPU time; see `Renderer.getStats`.
pub const Stats = renderer.Stats;

const draw_list = @import("render/draw_list.zig");
/// Immediate-mode shapes, images and text, in screen pixels or in the
/// world. Plain CPU data owned by whoever records into it, so each thread
/// can fill its own; see `ViewDesc.draw_lists`. Free with `deinit`.
pub const DrawList = draw_list.DrawList;
/// A font baked into a distance-field atlas, usable at any size in 2D and
/// 3D; see `Renderer.loadFont` and `Renderer.defaultFont`. Owned by the
/// renderer and safe to read from any thread until `Renderer.destroyFont`.
pub const Font = draw_list.Font;
/// A texture usable by draw lists; see `Renderer.createImage`,
/// `Renderer.loadImage` and `Renderer.targetImage`. A plain value, safe to
/// copy and to use from any thread until the image is destroyed.
pub const Image = draw_list.Image;
/// An 8-bit sRGB color with opacity, for draw lists; see
/// `Color.rgb`, `Color.rgba` and `Color.hex`.
pub const Color = draw_list.Color;
/// A rectangle given by its top-left corner and size, in pixels for
/// screen-space draw list calls.
pub const Rect = draw_list.Rect;
/// An outline built from lines and curves, for `DrawList.fillPath` and
/// `DrawList.strokePath`. Owns its points; free with `deinit`.
pub const Path = draw_list.Path;
/// A grid of equally sized frames in one image, for animated sprites and
/// tile sets; `frame` gives the source rectangle of one of them.
pub const SpriteSheet = draw_list.SpriteSheet;
/// A 2D affine transform applied to screen-space drawing; see
/// `DrawList.pushTransform`.
pub const Transform2D = draw_list.Transform2D;
/// Size in pixels per em, color, alignment, fallback fonts and shaping
/// for `DrawList.text`.
pub const TextOptions = draw_list.TextOptions;
/// Size in world units per em, color, alignment and orientation for
/// `DrawList.text3d`.
pub const Text3dOptions = draw_list.Text3dOptions;
/// Horizontal alignment of text relative to its position; see
/// `TextOptions.alignment`.
pub const Alignment = draw_list.Alignment;

test {
    _ = @import("math.zig");
    _ = @import("handle.zig");
    _ = @import("asset/gltf.zig");
    _ = @import("asset/model_cache.zig");
    _ = @import("asset/ktx2.zig");
    _ = @import("render/text_layout.zig");
    _ = @import("render/renderer.zig");
    _ = @import("render/api.zig");
    _ = @import("render/gpu.zig");
    _ = @import("render/animation.zig");
    _ = @import("render/draw_list.zig");
    _ = @import("render/bvh.zig");
    _ = @import("rhi/rhi.zig");
}
