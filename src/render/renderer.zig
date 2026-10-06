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

const Mat4 = math.Mat4;
const Vec3 = math.Vec3;
const ScenePass = scene_pass.ScenePass;
const SceneFrame = scene_pass.SceneFrame;
const SunShadows = scene_pass.SunShadows;
const CascadePlan = scene_pass.CascadePlan;
const LocalShadows = scene_pass.LocalShadows;
const ProbeList = scene_pass.ProbeList;
const CullState = scene_pass.CullState;
const DrawPush = scene_pass.DrawPush;
const CullPush = scene_pass.CullPush;
const Lighting = scene_pass.Lighting;

/// Marker type that makes `Model` a distinct handle type.
pub const ModelTag = opaque {};
/// Marker type that makes `Environment` a distinct handle type.
pub const EnvironmentTag = opaque {};
/// Marker type that makes `Scene` a distinct handle type.
pub const SceneTag = opaque {};
/// Marker type that makes `Entity` a distinct handle type.
pub const EntityTag = opaque {};
/// Marker type that makes `View` a distinct handle type.
pub const ViewTag = opaque {};
/// Marker type that makes `Emitter` a distinct handle type.
pub const EmitterTag = opaque {};
/// Marker type that makes `ReflectionProbe` a distinct handle type.
pub const ReflectionProbeTag = opaque {};
/// Marker type that makes `Fluid` a distinct handle type.
pub const FluidTag = opaque {};
/// Marker type that makes `Water` a distinct handle type.
pub const WaterTag = opaque {};
/// Marker type that makes `Liquid` a distinct handle type.
pub const LiquidTag = opaque {};
/// Marker type that makes `InstanceGroup` a distinct handle type.
pub const InstanceGroupTag = opaque {};
/// Geometry, materials and animations shared by any number of entities;
/// see `Renderer.loadModel` and `Renderer.createModel`. Like every handle
/// here it is a 32-bit value, free to copy, that stops resolving once the
/// thing it names is destroyed: calls given a stale handle do nothing or
/// return an error instead of touching whatever reused the slot.
pub const Model = handle.Handle(ModelTag);
/// A sky and the image-based lighting made from it; see
/// `Renderer.loadEnvironment` and `Renderer.setEnvironment`.
pub const Environment = handle.Handle(EnvironmentTag);
/// A world of entities, lights and effects that views draw; see
/// `Renderer.createScene`.
pub const Scene = handle.Handle(SceneTag);
/// One placement of a model in a scene; see `Renderer.spawn`.
pub const Entity = handle.Handle(EntityTag);
/// Per-camera state that persists between frames.
pub const View = handle.Handle(ViewTag);
/// A particle emitter in a scene.
pub const Emitter = handle.Handle(EmitterTag);
/// A local reflection probe in a scene.
pub const ReflectionProbe = handle.Handle(ReflectionProbeTag);
/// A box of simulated smoke and fire in a scene; see `Renderer.createFluid`.
pub const Fluid = handle.Handle(FluidTag);
/// A sheet of simulated water in a scene; see `Renderer.createWater`.
pub const Water = handle.Handle(WaterTag);
/// A body of particle-simulated liquid in a scene; see
/// `Renderer.createLiquid`.
pub const Liquid = handle.Handle(LiquidTag);
/// Many copies of one model; see `Renderer.createInstances`.
pub const InstanceGroup = handle.Handle(InstanceGroupTag);
/// Which animation clips an entity plays and how far into them it is; see
/// `Renderer.setPose`.
pub const Pose = animation.Pose;
/// Application-supplied geometry for `Renderer.createModel`.
pub const MeshDesc = gltf.MeshDesc;
/// Surface description of a mesh, as imported from glTF or given in a
/// `MeshDesc`.
pub const Material = gltf.Material;
/// Collects 2D shapes, images and text for a view to draw over its picture.
pub const DrawList = draw_list.DrawList;
/// A texture that draw lists, lights and settings can refer to; see
/// `Renderer.createImage` and `Renderer.loadImage`.
pub const Image = draw_list.Image;
/// A font baked into a distance-field atlas; see `Renderer.loadFont`.
pub const Font = font_module.Font;

/// Choices made when the renderer is created (`Renderer.init`). They stay
/// fixed for its lifetime; what can change from frame to frame is in
/// `Settings`.
pub const Options = struct {
    /// Name reported to the Vulkan driver.
    application_name: [:0]const u8 = "limn",
    /// Vulkan validation layers, including synchronization validation.
    /// Meant for development; requires the Khronos layers to be installed.
    validation: bool = false,
    /// Window to present to. Null renders offscreen only.
    surface: ?rhi.Surface = null,
    /// Part of the name of the GPU to prefer on a machine with several.
    preferred_device: ?[]const u8 = null,
    /// File the driver's pipeline cache is kept in between runs, so later
    /// starts compile fewer shaders. Null keeps none.
    pipeline_cache_path: ?[]const u8 = null,
    /// Name GPU objects and label passes for debuggers such as RenderDoc,
    /// without turning validation on. Where the driver has no
    /// `VK_EXT_debug_utils`, this does nothing.
    debug_names: bool = false,
    /// Ask for an HDR10 window surface. If the display or driver has none,
    /// the window stays SDR; `Renderer.hdrActive` tells which it is.
    hdr_output: bool = false,
    /// Use the GPU's ray tracing where it has it. False does without
    /// even there: no ray-traced reflections, shadows or bounce light,
    /// and path tracing follows its rays in an ordinary shader. Meant
    /// for comparing the two and for testing the second.
    ray_tracing: bool = true,
    /// Path tracing on a GPU without ray tracing: build for every model as
    /// it loads what `Settings.path_tracing` needs to follow rays in a
    /// shader (a tree over its triangles). Off by default, since it costs
    /// loading time and a few bytes a triangle whether or not anything
    /// is ever path traced; without it path tracing does nothing on such
    /// a GPU. Has no effect where the GPU traces rays itself.
    path_tracing_fallback: bool = false,
    /// Called around the renderer's CPU work, for a profiler such as
    /// Tracy; see `Profiler`.
    profiler: ?Profiler = null,
    /// Size of each of the four sun shadow cascades, in texels per side.
    shadow_resolution: u32 = 2048,
    /// Size of the atlas shared by spot and point light shadows; it holds
    /// 16 tiles, so each tile is a quarter of this per side.
    local_shadow_resolution: u32 = 2048,
    /// Anisotropic filtering for color and normal maps (1 disables).
    texture_anisotropy: f32 = 8,
    /// Anisotropic filtering for roughness/metalness, occlusion and
    /// emissive maps. 1 is noticeably cheaper per pixel.
    data_texture_anisotropy: f32 = 1,
    /// Most probes along X, Y and Z in one light probe grid. More covers a
    /// scene at a finer spacing; cost and memory grow with the product.
    gi_max_probes: [3]u32 = .{ 24, 12, 24 },
    /// The local-light shadow atlas is divided into this many tiles per
    /// side, 1..4: 4 gives 16 tiles (a spot light uses one, a point light
    /// six), 2 gives four tiles of four times the resolution each.
    local_shadow_tiles_per_side: u32 = 4,
    /// How material textures are stored on the GPU. `.bc7` uses a quarter of
    /// the memory of `.none` and filters faster, at a small loss of detail
    /// in blocks that mix unrelated colors; `.none` keeps every texel
    /// exact. Falls back to `.none` on hardware without BC formats.
    texture_compression: TextureCompression = .bc7,
    /// With compression on, store normal maps as BC5: two channels at far
    /// higher precision than BC7 gives them, the third rebuilt when
    /// shading. False keeps them in BC7 like every other texture.
    normal_maps_bc5: bool = true,
    /// Directory for processed assets (compressed textures), so later runs
    /// skip decoding and encoding. Null processes everything on each load.
    asset_cache_dir: ?[]const u8 = null,
    /// Size the asset cache is trimmed to when the renderer starts, oldest
    /// files first; 0 never deletes anything. See `trimAssetCache`.
    asset_cache_max_bytes: u64 = 0,
    /// Allocator for work done on worker threads: decoding models and
    /// environments, and the models that result. It must be safe to use
    /// from several threads at once. Null uses a general-purpose one.
    job_allocator: ?std.mem.Allocator = null,
    /// Build the shading pass again for each set of optional features a
    /// view uses (local lights, sized lamps, traced light shadows, smoke
    /// and cloud shadows, decals), leaving the rest out: code that never
    /// runs still slows a shader down. Each build is compiled on a worker
    /// thread while the full pass stands in, so nothing stalls; false
    /// always uses the full pass.
    shader_variants: bool = true,
    /// Work out the bounds of every meshlet of skinned and morphed meshes
    /// on the GPU each frame, after they are deformed, so that animated
    /// characters are culled piece by piece (frustum, occlusion, shadow
    /// views) instead of as one sphere each. Costs a pass over their
    /// triangles; worth it for large or many characters that are often
    /// partly hidden.
    skinned_meshlet_bounds: bool = false,
    /// Build levels of detail as a hierarchy of clusters (after Nanite):
    /// every meshlet-sized piece of a mesh picks its own level by its own
    /// distance, and neighbouring pieces of different levels still meet
    /// exactly. A large mesh the camera stands inside, which whole-mesh
    /// levels can never coarsen, is then coarse far away and fine close
    /// by. Meshes of fewer than about eight thousand triangles, which gain
    /// nothing from it, and skinned meshes keep whole-mesh levels.
    cluster_lods: bool = true,
    /// How much a change of normals counts when levels of detail are
    /// built: higher keeps shading closer to the full mesh at the price
    /// of levels that switch later; 0 looks at shape alone. See
    /// `gltf.LodOptions.normal_weight`.
    lod_normal_weight: f32 = gltf.default_lod_normal_weight,
    /// How much texture sliding over the surface counts when levels of
    /// detail are built: 1 treats a texture moved by some distance as a
    /// shape error of that distance, 0 ignores it.
    lod_uv_weight: f32 = gltf.default_lod_uv_weight,
    /// Threads that animated entities' poses are worked out on, counting
    /// the one that renders: 0 picks by the machine (at most 8), 1 never
    /// uses another thread. More than one is only used for scenes with
    /// enough animated entities to be worth it.
    pose_threads: u32 = 0,
    /// Put skinned and morphed meshes into the ray-tracing structure, so
    /// animated characters block and bounce probe light and show in
    /// ray-traced reflections. Costs one structure build per such mesh per
    /// frame. False leaves them out, as static-only GI.
    gi_dynamic_geometry: bool = true,
    /// How many of those structures are brought up to date each frame; 0
    /// for all of them. With a limit they take turns, so in a crowd each
    /// character's shape as rays see it lags its pose by a few frames,
    /// for a fraction of the cost. New ones are always built at once.
    gi_dynamic_refits: u32 = 0,
    /// Instance groups join the ray-tracing structure (blocking and
    /// bouncing probe light, showing in ray-traced reflections) while a
    /// scene holds at most this many group instances; larger scenes leave
    /// them out. 0 always leaves them out.
    gi_instance_limit: u32 = 65536,
    /// Loads texture detail by distance instead of all at once. Null keeps
    /// every texture fully loaded.
    texture_streaming: ?TextureStreaming = null,
    /// Keeps a model's geometry on the GPU only while something drawn
    /// with it is near a camera: its room in the vertex and index pools is
    /// handed to other models and its ray-tracing structures are freed.
    /// Null keeps every loaded
    /// model's geometry there.
    geometry_streaming: ?GeometryStreaming = null,
};

/// Where liquid pours into a `LiquidDesc` volume.
pub const LiquidSource = struct {
    /// Mouth of the jet, in the world.
    position: Vec3,
    /// Direction and speed of the jet.
    velocity: Vec3 = .{ 0, -1, 0 },
    radius: f32 = 0.12,
    /// Particles a second; 0 fills the jet solid at its speed. Either
    /// way they leave in whole layers across the jet.
    rate: f32 = 0,
};

/// A volume of liquid (`Renderer.createLiquid`): particles held in a box
/// that pour, slosh, splash and break as waves, drawn as one surface.
/// Unlike `WaterDesc`, which is a sheet whose height is simulated, this
/// is liquid that can come apart; it costs far more for the same area and
/// suits a tank, a fountain or a spill rather than a lake.
pub const LiquidDesc = struct {
    /// Places the box the liquid is held in: the unit cube centered on the
    /// origin, scaled to the box's size, turned and moved into place. Its
    /// faces are the liquid's only walls.
    transform: Mat4,
    /// Most particles there can be; fixed when the liquid is created.
    /// Pouring stops when they are all in use.
    capacity: u32 = 30000,
    /// Half the distance between neighbouring particles at rest: the
    /// grain of the liquid. Smaller is finer and needs more particles for
    /// the same amount (eight times as many at half the radius). Fixed
    /// when the liquid is created.
    particle_radius: f32 = 0.04,
    /// The liquid there is at the start: a block in the box's low corner,
    /// this share of the box along each of its axes. Zeros start empty.
    fill: [3]f32 = .{ 0, 0, 0 },
    /// Up to four jets pouring in.
    sources: []const LiquidSource = &.{},
    gravity: Vec3 = .{ 0, -9.8, 0 },
    /// The color it takes on with depth, and how quickly: 0 is clear.
    color: [3]f32 = .{ 0.1, 0.38, 0.5 },
    murk: f32 = 3,
    /// How much of the sun's light it stops: 0 casts no shadow, 1 a
    /// solid one. Costs drawing the particles once more into each
    /// shadow cascade that is refreshed.
    shadow: f32 = 0.5,
    /// Count as a surface for what is drawn after it: fog stops at the
    /// liquid, particles are hidden behind it, antialiasing follows it as
    /// the camera moves, and depth of field and
    /// motion blur focus and blur it by its own distance rather than by
    /// that of what shows through.
    write_depth: bool = true,
    /// How far the slope of the surface shifts what is seen through it.
    refraction: f32 = 0.3,
    /// Steps of simulation a frame, and rounds of pushing particles
    /// apart in each. More of either holds the liquid's volume better
    /// (it squashes less under its own weight) at that many times the
    /// cost.
    substeps: u32 = 2,
    iterations: u32 = 3,
    /// Share of its speed the liquid loses a second: thick liquids high.
    damping: f32 = 0.05,
    /// How much neighbouring liquid shares its speed, 0 to 1: higher
    /// moves more as one body and settles sooner; 0 is a swarm of
    /// particles each going its own way.
    viscosity: f32 = 0.08,
    /// Fine ripples the open surface is shaded with (see
    /// `WaterDesc.ripple_detail`); 0 for none.
    ripple_detail: f32 = 0.4,
    /// Entities push the liquid aside, by the bounding spheres of their
    /// models (the nearest sixteen that reach into the box).
    obstacles: bool = true,
    /// 0 stands still.
    time_scale: f32 = 1,
};

/// Geometry by distance (`Options.geometry_streaming`).
pub const GeometryStreaming = struct {
    /// A model's vertices and indices are on the GPU while anything
    /// drawn with it is within this distance of a camera (measured to
    /// the nearest point of its bounds). Set it past the farthest you
    /// can see, or things will be missing from the picture: what is
    /// drawn with a released model is left out of its scene altogether,
    /// shadows, reflections and bounced light included.
    distance: f32 = 200,
    /// A model is released only beyond `distance` times this, so one
    /// near the edge does not come and go.
    release_factor: f32 = 1.25,
    /// Most bytes of geometry brought back in one frame; the rest waits
    /// for the next. A model larger than this still loads, alone.
    upload_bytes_per_frame: u64 = 16 * 1024 * 1024,
    /// Beyond this distance a model keeps only its coarser levels of
    /// detail in GPU memory: the vertices those use, and the indices
    /// of every level but the finest. It is still drawn, at the detail
    /// it would mostly be drawn at from there anyway, and brought back
    /// whole when a camera comes within nine tenths of this. While it
    /// is so it takes no part in ray tracing. 0 never does this; a
    /// value at or past `distance` does nothing.
    coarse_distance: f32 = 0,
};

/// Keeps only as much of each model texture in GPU memory as the cameras
/// can make use of. Applies to compressed textures (`texture_compression`
/// or KTX2 files); the full mip chains stay in system memory.
pub const TextureStreaming = struct {
    /// GPU memory the streamed textures may take. When what the views want
    /// exceeds it, every texture drops the same number of top levels.
    /// 0 means no limit.
    budget_bytes: u64 = 0,
    /// Levels this small or smaller always stay loaded.
    min_size: u32 = 64,
    /// Texture data uploaded per frame at most (one texture always goes
    /// through, however large).
    upload_bytes_per_frame: u64 = 16 * 1024 * 1024,
    /// Added to the level each texture wants: positive keeps less detail,
    /// negative more.
    mip_bias: f32 = 0,
    /// Frames a texture must go on wanting less detail before detail is
    /// dropped, unless the budget forces it sooner.
    evict_delay_frames: u32 = 120,
    /// Ask for detail only on what is inside a camera's view. Saves the
    /// memory of what is behind the camera; turning around then shows
    /// blurry textures until they load.
    visible_only: bool = false,
    /// Ask for detail only on what a camera actually drew: what is hidden
    /// behind other things asks for none, as if it were out of view. What
    /// was drawn is read back from the GPU a few frames late, so something
    /// coming out from behind cover shows blurry textures until they load.
    skip_occluded: bool = false,
    /// Keep only each texture's small, always-loaded levels in system
    /// memory and read the larger ones from the asset cache file when a
    /// camera wants them. Frees the memory of the full mip chains; the
    /// reads happen on the rendering thread, a few megabytes at a time.
    /// Needs `Options.asset_cache_dir` and compressed textures; a texture
    /// whose cache file is missing stays in memory as before.
    from_cache: bool = false,
};

/// A camera's view volume, for asking whether a sphere can be seen.
const StreamFrustum = struct {
    view: Mat4,
    tan_x: f32,
    tan_y: f32,

    fn touches(self: StreamFrustum, center: Vec3, radius: f32) bool {
        const p = math.transformPoint(self.view, center);
        const depth = -p[2];
        if (depth + radius < 0) return false;
        // Distance outside each side plane, which passes through the eye.
        const out_x = (@abs(p[0]) - depth * self.tan_x) / @sqrt(1 + self.tan_x * self.tan_x);
        const out_y = (@abs(p[1]) - depth * self.tan_y) / @sqrt(1 + self.tan_y * self.tan_y);
        return out_x < radius and out_y < radius;
    }
};

/// The GPU format of a model texture that is stored compressed.
fn blockFormat(block: gltf.Image.Block, one_channel: bool, two_channel: bool, srgb: bool) rhi.Format {
    return switch (block) {
        .bc1 => if (srgb) .bc1_srgb else .bc1_unorm,
        .bc3 => if (srgb) .bc3_srgb else .bc3_unorm,
        .bc6h => .bc6h_ufloat,
        .rgba8 => if (srgb) .rgba8_srgb else .rgba8_unorm,
        .bc7 => if (one_channel) .bc4_unorm else if (two_channel) .bc5_unorm else if (srgb) .bc7_srgb else .bc7_unorm,
    };
}

const TextureStream = struct {
    /// The whole BC7 mip chain; empty for textures that are not streamed.
    data: []u8 = &.{},
    width: u32 = 0,
    height: u32 = 0,
    levels: u32 = 0,
    srgb: bool = false,
    two_channel: bool = false,
    block: gltf.Image.Block = .bc7,
    one_channel: bool = false,
    /// With levels read from the asset cache on demand: the size of the
    /// whole chain, where in it `data` begins (only the small levels are
    /// kept in memory then), and the cache file the rest is read from.
    total: usize = 0,
    tail_offset: usize = 0,
    path: []u8 = &.{},
    /// Coarsest first level allowed: this and below always stay loaded.
    floor: u32 = 0,
    /// First level in GPU memory now, and the one the views ask for.
    resident: u32 = 0,
    wanted: u32 = 0,
    low_frames: u32 = 0,

    fn levelSize(self: TextureStream, level: u32) usize {
        return @intCast(self.format().dataSize(@max(self.width >> @intCast(level), 1), @max(self.height >> @intCast(level), 1)));
    }

    fn format(self: TextureStream) rhi.Format {
        return blockFormat(self.block, self.one_channel, self.two_channel, self.srgb);
    }

    fn levelOffset(self: TextureStream, level: u32) usize {
        var offset: usize = 0;
        for (0..level) |index| offset += self.levelSize(@intCast(index));
        return offset;
    }

    fn bytesFrom(self: TextureStream, first: u32) u64 {
        if (self.total != 0) return self.total - self.levelOffset(first);
        return self.data.len - self.levelOffset(first);
    }
};

/// How material textures are stored on the GPU; see
/// `Options.texture_compression`. `.none` keeps them as plain RGBA8,
/// `.bc7` block-compresses them to a quarter of that.
pub const TextureCompression = enum { none, bc7 };
/// A sheet of simulated water; see `createWater`.
pub const WaterDesc = struct {
    /// Cells of the simulation along each side, 16..1024.
    resolution: [2]u32 = .{ 256, 256 },
    /// Places the surface in the world: a unit square in the XZ plane
    /// centered on the origin, +Y up. The Y scale is the unit of height.
    transform: Mat4 = math.identity,
    /// How fast ripples travel, in world units per second (limited by the
    /// resolution: a wave cannot cross more than about two thirds of a
    /// cell per step).
    wave_speed: f32 = 3,
    /// Share of the motion lost per second; higher calms the water sooner.
    damping: f32 = 0.5,
    /// Raindrops per second landing at random places; 0 for none.
    rain: f32 = 0,
    /// Entities moving through the surface disturb it: how strongly (1 is
    /// a plausible wake), 0 for not at all. An entity counts by the
    /// bounding sphere of its model.
    object_ripples: f32 = 1,
    /// Spray thrown up where an entity moves through the surface: how
    /// much (1 is a plausible splash for something dropped in), 0 for
    /// none. The drops are particles of an emitter the water keeps for
    /// itself, lit and shadowed like any others; they take the water's
    /// color. It goes by the same bounding spheres as `object_ripples`,
    /// which must be on, and throws from one place a frame: the
    /// strongest.
    splashes: f32 = 0,
    /// A steady swell laid over the ripples: its height and wave length in
    /// world units. 0 leaves still water flat.
    swell: f32 = 0,
    swell_length: f32 = 6,
    /// Speed of the simulation; 0 freezes it.
    time_scale: f32 = 1,
    /// Color the water takes on with depth, and how quickly (per world
    /// unit looked through).
    color: Vec3 = .{ 0.02, 0.1, 0.12 },
    murk: f32 = 0.5,
    /// Blur of what the surface mirrors.
    roughness: f32 = 0.04,
    /// How strongly the slope of the surface shifts what is seen under it.
    refraction: f32 = 1.2,
    /// White froth at shallow edges (walls, things standing in the water)
    /// and where the surface is churning, 0..1; 0 for none.
    foam: f32 = 0.6,
    /// Patterns of light on what lies under the water, cast by the waves
    /// above (so still water has none), 0..1; 0 for none. They show
    /// through the surface and from below it, in sunlight.
    caustics: f32 = 0.6,
    /// Fine wind ripples laid over the surface for the light only: they
    /// tilt what is mirrored and seen through, and scatter the sun into
    /// glitter, without moving the surface. 0 is glass-still; 1 a
    /// breezy pond.
    ripple_detail: f32 = 0.5,
    /// When the camera is under the surface: tint the view by how much
    /// water it looks through, as the surface does from above.
    underwater: bool = true,
    /// Count as a surface for what is drawn after it: fog stops at the
    /// water, particles fade into it and are hidden below it, and
    /// transparent things under it are covered. False leaves the water
    /// out of the depth those passes see, so they treat it as not there.
    write_depth: bool = true,
};

/// What happens at the sides of a fluid's box.
pub const FluidWalls = enum(u32) {
    /// The fluid leaves through every side.
    open,
    /// Solid underneath, open elsewhere: a fire on the ground.
    floor,
    /// A sealed box: smoke fills it.
    closed,
};

/// A place inside a fluid's box where smoke, heat or fuel enters.
pub const FluidSource = struct {
    /// Center, as a share of the box along each axis (0..1).
    position: Vec3 = .{ 0.5, 0.08, 0.5 },
    /// Radius as a share of the box's height.
    radius: f32 = 0.07,
    /// Where the fluid is pushed inside the source, in box heights per second.
    velocity: Vec3 = .{ 0, 0.5, 0 },
    /// Smoke, fuel and heat added per second at the center. Fuel burns
    /// where it is hot, giving heat and smoke of its own.
    smoke: f32 = 0,
    fuel: f32 = 0,
    temperature: f32 = 0,
};

/// Something solid inside a fluid's box that the flow goes around. In the
/// box's own coordinates: 0..1 along each axis.
pub const FluidObstacle = union(enum) {
    /// `radius` is a share of the box's height.
    sphere: struct { center: Vec3, radius: f32 },
    box: struct { min: Vec3, max: Vec3 },
};

/// A sheet of frames recorded from a running fluid (`recordFluidFlipbook`).
pub const FluidFlipbookDesc = struct {
    columns: u32 = 8,
    rows: u32 = 8,
    /// Simulation steps from one frame to the next, at least 1.
    interval: u32 = 2,
    /// Size of one frame in pixels; null uses the fluid's resolution.
    frame_size: ?[2]u32 = null,
};

/// A box of simulated smoke and fire; see `createFluid`.
pub const FluidDesc = struct {
    /// Cells along each axis, 8..256. A depth of 1 makes the fluid 2D.
    resolution: [3]u32 = .{ 64, 96, 64 },
    /// Places the box in the world: a unit cube centered on the origin,
    /// with +Y up for the fluid.
    transform: Mat4 = math.identity,
    /// Up to 8.
    sources: []const FluidSource = &.{},
    /// Up to 8. The flow does not see the scene's geometry; describe what
    /// stands in its way here.
    obstacles: []const FluidObstacle = &.{},
    /// Treat the scene's own geometry inside the box as solid too: each
    /// frame the cells a surface passes through are found with short
    /// rays. Needs ray tracing and a view of the scene with global
    /// illumination on; costs six short rays per cell per frame.
    scene_obstacles: bool = false,
    walls: FluidWalls = .floor,
    /// How hard heat lifts the gas and smoke weighs it down, in box
    /// heights per second squared per unit of each.
    buoyancy: f32 = 1.6,
    weight: f32 = 0.1,
    /// Strength of the swirls put back into the flow (vorticity
    /// confinement). 0 gives a smooth, lazy flow.
    vorticity: f32 = 12,
    /// A steady push on all of the fluid, in box heights per second squared.
    wind: Vec3 = .{ 0, 0, 0 },
    /// Share lost per second: motion dying down, smoke thinning, gas
    /// cooling, fuel burning.
    velocity_loss: f32 = 0.25,
    smoke_loss: f32 = 0.45,
    cooling: f32 = 1.4,
    burn_rate: f32 = 5,
    /// Heat and smoke given off per unit of fuel burned.
    heat: f32 = 3,
    soot: f32 = 0.6,
    /// Correct the error of carrying smoke and heat along the flow
    /// (MacCormack advection): wisps stay sharp instead of blurring out.
    /// One more pass and a dozen more lookups per cell.
    sharp_advection: bool = true,
    /// The same correction for the flow itself: swirls keep their energy
    /// instead of dying down, so the fluid stays livelier with less
    /// `vorticity`. Needs `sharp_advection`; a dozen more lookups.
    sharp_velocity: bool = false,
    /// Jacobi iterations of the pressure solve per step, 1..200. More
    /// keeps the flow from compressing in large or fast fluids.
    pressure_iterations: u32 = 24,
    /// Speed of the simulation; 0 freezes it.
    time_scale: f32 = 1,

    /// Color the smoke scatters, and how much light a unit of smoke takes
    /// out per world unit.
    smoke_color: Vec3 = .{ 0.55, 0.55, 0.58 },
    absorption: f32 = 8,
    /// Tint and brightness of the glow of hot gas.
    fire_color: Vec3 = .{ 1, 1, 1 },
    fire_intensity: f32 = 6,
    /// How strongly the fire lights the scene around it: a light is kept
    /// at the middle of the glow, as bright and as colored as the flames
    /// are at that moment, flickering with them. 0 gives off no light.
    light: f32 = 1,
    /// How far that light reaches; 0 picks three times the box's height.
    light_range: f32 = 0,
    /// Width of that light as a share of the box's height. 0 casts sharp
    /// shadows from the middle of the flame; more (a flame is about 0.08)
    /// softens them where ray-traced light shadows are on, at the price
    /// of grain wherever only a sliver of the flame is in sight, which
    /// `Settings.light_shadow_rays` reduces.
    light_size: f32 = 0,
    /// How much of the flames' height the light takes: 1 makes it a
    /// standing line as tall as the glow, so a tall fire lights what is
    /// beside it evenly; 0 is a single point at the middle of the glow.
    /// A tall light casts soft shadows where they are ray traced.
    light_tall: f32 = 1,
    /// How strongly the smoke shadows itself from the sun, 0..1.
    shadow: f32 = 1,
    /// How much light keeps its direction through the smoke: higher gives
    /// a brighter rim toward the sun.
    anisotropy: f32 = 0.35,
    /// How much ambient light the smoke picks up.
    ambient: f32 = 1,
};

/// A layer of volumetric clouds over a scene; see `setClouds`.
pub const CloudDesc = struct {
    /// Share of the sky the clouds fill, 0..1.
    coverage: f32 = 0.5,
    /// How much coverage varies from place to place: 0 is an even field,
    /// higher gathers the clouds into banks with clear sky between.
    variation: f32 = 0.6,
    /// Light lost per meter inside a cloud. Higher is darker and
    /// harder-edged.
    density: f32 = 0.012,
    /// Altitude of the cloud base and how tall the layer is, in world units
    /// above y = 0.
    bottom: f32 = 1500,
    thickness: f32 = 1400,
    /// Size of the cloud shapes; 1 gives clouds a few kilometres across.
    scale: f32 = 1,
    /// How strongly small-scale noise eats into the edges, 0..1.
    detail: f32 = 0.35,
    /// World units per second the clouds drift.
    wind: Vec3 = .{ 12, 0, 5 },
    /// Tint of the scattered light.
    color: Vec3 = .{ 1, 1, 1 },
    /// How much sky light the clouds pick up, relative to the environment.
    ambient: f32 = 1,
    /// How strongly light keeps its direction passing through: higher
    /// gives a brighter rim toward the sun.
    anisotropy: f32 = 0.6,
    /// How dark the shadow under a cloud is, 0..1; 0 casts none. The
    /// shadows fall on everything the sun lights, fog included.
    shadow: f32 = 0.8,
    /// Seconds between rebuilds of the sky's lighting with the clouds in
    /// it, so that ambient light dims under overcast and sky reflections
    /// show clouds. A loaded environment's clouds are lit by the scene's
    /// sun. 0 leaves the
    /// lighting as a clear sky. Each rebuild costs a sky bake.
    environment_interval: f32 = 4,
    /// Cover of a second layer far above the first: thin streaks of ice
    /// cloud, 0..1; 0 for none. It casts no shadow.
    cirrus: f32 = 0,
    /// Storm cells, 0..1: where the weather is heaviest (see `variation`)
    /// the cloud stands solid to the top of the layer and spreads out
    /// there, like the anvil of a thunderstorm. Wants a thick layer.
    anvil: f32 = 0,
    /// Lightning: flashes per minute, at random places in the layer
    /// within a few kilometres of the camera, each lighting the cloud
    /// around it for a moment; and how bright they are. The scene is not
    /// lit by them unless the application adds a light where
    /// `Renderer.cloudFlash` says one is.
    lightning: f32 = 0,
    lightning_brightness: f32 = 40,
    /// Radius of the planet the layer wraps around; decides how the
    /// clouds sink toward the horizon.
    planet_radius: f32 = 6_360_000,
};

/// A lightning flash in a cloud layer; see `Renderer.cloudFlash`.
pub const CloudFlash = struct { position: Vec3, brightness: f32 };

/// How overlapping transparent surfaces are combined; see
/// `Settings.transparency`.
pub const TransparencyMode = enum {
    /// Whole meshes, drawn farthest first.
    sorted,
    /// Order-independent by weighting: any number of layers in one pass,
    /// but an average rather than true layering.
    weighted,
    /// Depth peeling: exact per pixel for the nearest
    /// `Settings.transparency_layers` surfaces, at one pass over the
    /// transparent geometry per layer.
    peeled,
};

/// What the haze of aerial perspective is made of; see
/// `Settings.aerial_model`. `.atmosphere` is air lit by sun and sky, `.sky`
/// a plain fade to the sky behind.
pub const AerialModel = enum { atmosphere, sky };

/// Which level of detail a local light's shadow is drawn from: the one the
/// camera sees, or the one that suits the light's distance. See
/// `Settings.shadow_lod`.
pub const ShadowLod = enum { camera, light };

/// How a view's final picture is encoded; see `Settings.output_encoding`.
/// `.auto` follows the target, `.srgb` and `.hdr10` force one.
pub const OutputEncoding = enum { auto, srgb, hdr10 };

/// Hooks for an external CPU profiler. `begin` is called with a static
/// zone name when the renderer starts a piece of work and returns whatever
/// the profiler needs to close the zone; `end` receives it back. With
/// Tracy: `begin` calls `___tracy_emit_zone_begin_alloc` and returns the
/// context, `end` calls `___tracy_emit_zone_end`.
pub const Profiler = struct {
    /// Passed back to `begin` and `end` unchanged.
    context: ?*anyopaque = null,
    begin: *const fn (context: ?*anyopaque, name: [:0]const u8) u64,
    end: *const fn (context: ?*anyopaque, zone: u64) void,
};

/// A profiler zone that closes itself.
const Zone = struct {
    profiler: ?Profiler,
    id: u64 = 0,

    fn start(profiler: ?Profiler, name: [:0]const u8) Zone {
        var zone = Zone{ .profiler = profiler };
        if (profiler) |p| zone.id = p.begin(p.context, name);
        return zone;
    }

    fn stop(self: Zone) void {
        if (self.profiler) |p| p.end(p.context, self.id);
    }
};

/// Where a model or environment is on its way from a file to the GPU.
pub const AssetState = enum {
    /// Still being decoded or uploaded; entities that use it are not drawn
    /// yet.
    loading,
    ready,
    /// The load ended in an error (see `Renderer.modelError`), or the
    /// handle names nothing.
    failed,
};

/// Where a view is seen from. The projection is a perspective one with no
/// far plane; its aspect ratio follows the size the view is drawn at.
pub const Camera = struct {
    /// Position of the eye, in world units.
    position: Vec3 = .{ 0, 0, 3 },
    /// Direction the camera looks along; need not be normalized.
    forward: Vec3 = .{ 0, 0, -1 },
    /// Roughly which way is up in the picture; need not be perpendicular
    /// to `forward`. Where the two are parallel, +Z is used instead.
    up: Vec3 = .{ 0, 1, 0 },
    /// Vertical field of view in radians.
    fov_y: f32 = std.math.degreesToRadians(60.0),
    /// Distance to the near plane, in world units; nothing closer is drawn.
    near: f32 = 0.1,

    /// A camera at `position` looking toward `target`, with every other
    /// field at its default. The two points must differ.
    pub fn lookAt(position: Vec3, target: Vec3) Camera {
        return .{ .position = position, .forward = math.sub(target, position) };
    }
};

/// The scene's one shadow-casting directional light; see `Renderer.setSun`.
pub const Sun = struct {
    /// Direction the light travels (from the sun toward the scene).
    direction: Vec3 = .{ -0.4, -1.0, -0.3 },
    /// Linear color of the light; `intensity` scales it.
    color: Vec3 = .{ 1.0, 0.96, 0.9 },
    /// Radiometric scale in the same units as the environment map. 0, the
    /// default, turns the sun off.
    intensity: f32 = 0,
};

/// The shape of a `Light`.
pub const LightKind = enum {
    /// Shines in every direction from `position`.
    point,
    /// A cone from `position` along `direction`, between `inner_angle`
    /// and `outer_angle`.
    spot,
    /// Parallel light from infinitely far away, like the sun but without
    /// shadows: a moon beside the sun, a fill light, sky bounce. `position`
    /// and `range` are ignored.
    directional,
    /// A glowing panel (a window, a screen, a ceiling light): a rectangle
    /// centered on `position`, `source_length` wide and `source_height`
    /// tall, shining along `direction`. Its shadows are ray traced.
    rectangle,
};

/// A point or spot light. Lights are culled into view-space clusters, so
/// cost scales with lights per cluster rather than total light count.
pub const Light = struct {
    kind: LightKind = .point,
    /// Where the light is, in world units.
    position: Vec3,
    /// Direction a spot light points; ignored for point lights.
    direction: Vec3 = .{ 0, -1, 0 },
    /// Linear color of the light; `intensity` scales it.
    color: Vec3 = .{ 1, 1, 1 },
    intensity: f32 = 1,
    /// Distance at which the light's contribution reaches zero.
    range: f32 = 5,
    /// Spot cone half-angles in radians: full brightness inside `inner`,
    /// none outside `outer`.
    inner_angle: f32 = 0.35,
    outer_angle: f32 = 0.6,
    /// Shadows use one atlas tile for a spot light and six for a point
    /// light; at most 16 tiles are available per frame, assigned in order.
    cast_shadows: bool = false,
    /// Radius of the glowing sphere the light comes from. 0 is an ideal
    /// point; larger sources give wider, softer highlights (a bulb, a
    /// paper lantern) and stop getting brighter once a surface touches
    /// them.
    source_radius: f32 = 0,
    /// Point lights only: makes the source a tube this long, centered on
    /// `position` and lying along `direction` (a fluorescent strip, a
    /// neon sign). `source_radius` is then the tube's thickness. Shadows
    /// are still cast from the center.
    source_length: f32 = 0,
    /// Rectangle lights only: the panel's height (`source_length` is its
    /// width).
    source_height: f32 = 0,
    /// Spot lights only: an image projected like a slide (a window frame,
    /// a stained glass pattern, a flashlight's rings).
    cookie: ?Image = null,
    /// Brightness by angle from `direction`: a strip image whose left edge
    /// is the brightness along the axis and whose right edge is straight
    /// behind it. See `Renderer.loadLightProfile` for measured IES data.
    profile: ?Image = null,
};

/// What `Renderer.spawn` makes an entity from. Everything but the model
/// can be changed afterwards (`setTransform`, `setVisible`, `setTint`,
/// `setParams`).
pub const EntityDesc = struct {
    /// The model to draw. It may still be loading; the entity appears
    /// once it is ready.
    model: Model,
    /// Places the model's space in the world.
    transform: Mat4 = math.identity,
    /// False keeps the entity in the scene without drawing it.
    visible: bool = true,
    /// Multiplies the base color of every material on the entity.
    tint: [3]f32 = .{ 1, 1, 1 },
    /// Free numbers handed to custom material shaders as
    /// `MaterialContext.instance_params`.
    params: [4]f32 = .{ 0, 0, 0, 0 },
    /// False keeps the scene's decals off this entity (a character
    /// walking over a painted floor).
    receive_decals: bool = true,
};

/// One animation clip of a model; see `Renderer.animationInfo`.
pub const AnimationInfo = struct {
    /// The clip's name in the file. The bytes belong to the model and are
    /// valid until it is destroyed.
    name: []const u8,
    /// Length of the clip in seconds.
    duration: f32,
};

/// Size and extent of a loaded model; see `Renderer.modelInfo`.
pub const ModelInfo = struct {
    mesh_count: u32,
    triangle_count: u32,
    meshlet_count: u32,
    texture_count: u32,
    /// Joints of all the model's skins together; 0 for a rigid model.
    joint_count: u32,
    /// Meshes that have morph targets, and the most any one has.
    morph_meshes: u32 = 0,
    morph_targets: u32 = 0,
    /// Axis-aligned bounds of the rest pose, in model space.
    bounds_min: Vec3,
    bounds_max: Vec3,
    /// Bounding sphere of the rest pose, in model space.
    bounds_center: Vec3,
    bounds_radius: f32,
};

/// What is known about a loaded environment; see
/// `Renderer.environmentInfo`.
pub const EnvironmentInfo = struct {
    /// Direction toward the brightest part of the panorama, usually the sun.
    /// Negate it to get a matching `Sun.direction`.
    brightest_direction: Vec3,
};

/// Quality and look of one view (`ViewDesc.settings`). Unlike `Options`
/// these may differ between views and change from frame to frame.
/// Distances are in world units.
pub const Settings = struct {
    /// Sun and local light shadows. False draws no shadow maps at all.
    shadows: bool = true,
    /// Distance from the camera covered by the shadow cascades.
    shadow_distance: f32 = 60,
    /// Penumbra radius in world units.
    shadow_softness: f32 = 0.035,
    /// Shadow maps the sun's shadow distance is split over, 1..4. Fewer
    /// cost less to render and blur more at range.
    shadow_cascades: u32 = 4,
    /// Leave out of each sun shadow cascade whatever is smaller than this
    /// many of its texels across: a caster that small leaves a shadow of
    /// a texel or two that the filter blurs to nothing, but still costs a
    /// draw. With very many small things (debris, grass, a field of
    /// blocks) it removes most of the far cascades' work. 0 draws
    /// everything; a value around 2 is rarely visible. It goes by the
    /// size of a whole mesh, so large things keep their shadows.
    shadow_small_feature_texels: f32 = 0,
    /// Leave out of a sun shadow cascade every caster whose shadow cannot
    /// fall on anything the camera sees: its bounds, swept along the
    /// light, miss the part of the view the cascade shadows, or lie
    /// behind what is drawn there (the air in front of surfaces counts as
    /// seen, so fog and see-through surfaces keep their shadows). Nothing
    /// in the picture changes. It applies to cascades drawn afresh every
    /// frame: all of them without `shadow_cascade_stagger`, only the
    /// nearest with it, since a map kept for several frames must also
    /// hold what the camera comes to see in the meantime.
    shadow_receiver_culling: bool = true,
    /// Reach, in world units, of small screen-space shadows added to the
    /// sun's (where feet meet the floor, under ledges); 0.2 to 0.5 is
    /// typical. 0 turns them off. Opaque surfaces only, and only what is
    /// on screen casts them.
    contact_shadows: f32 = 0,
    /// Lights that cast shadows but have no shadow map (extra directional
    /// lights, panels, lamps past the shadow tile budget) are shadowed by
    /// a ray each in the opaque pass. Needs ray tracing and
    /// `global_illumination`. One ray per light per pixel; lights with a
    /// size get a soft edge once temporal antialiasing has averaged it.
    ray_traced_light_shadows: bool = true,
    /// Rays per pixel toward each ray-shadowed light that has a size
    /// (sphere, tube, panel), 1..15. More gives a smoother penumbra.
    light_shadow_rays: u32 = 4,
    /// Carry how much of each soft-shadowed light reaches a surface from
    /// frame to frame, so that the few rays per pixel add up instead of
    /// showing as grain. The shadows of moving things trail by a few
    /// frames. Needs temporal antialiasing; off takes each frame's rays
    /// as they come.
    light_shadow_filter: bool = true,
    /// Samples of the sun shadow filter where a shadow's edge falls: 4, 8
    /// or 16. Fewer are cheaper and grainier.
    shadow_samples: u32 = 16,
    /// Darken creases and corners where little ambient light reaches,
    /// from what is on screen (GTAO).
    ambient_occlusion: bool = true,
    /// World-space radius searched for occluders.
    ao_radius: f32 = 1.2,
    /// Blend each frame's ambient occlusion with the previous frames',
    /// reprojected. Removes the grain and flicker of the sampling pattern;
    /// occlusion then takes a few frames to follow fast-moving objects.
    ao_temporal_filter: bool = true,
    /// Light from what occludes: where ambient occlusion finds a nearby
    /// surface in the way of the sky, that surface's own light (as it
    /// was lit last frame) arrives in the sky's place, so a red wall
    /// tints the floor at its foot and a lit floor brightens the
    /// underside of what stands on it. This is the indirect light too
    /// fine for the probes of `global_illumination`. A strength, 0 for
    /// none; costs one texture fetch per occlusion sample and a filter
    /// pass. Needs `ambient_occlusion` and `temporal_antialiasing`.
    ao_bounce: f32 = 1,
    /// Exponent applied to the occlusion term; higher is darker.
    ao_intensity: f32 = 1.3,
    /// Skip geometry hidden behind what was visible last frame, using a
    /// depth pyramid. Never drops visible geometry.
    occlusion_culling: bool = true,
    /// Resolution the scene is rendered at, as a fraction of the size it is
    /// shown at: 0.5 renders a quarter of the pixels and upscales, above 1
    /// supersamples. Draw lists and text are always drawn at full size.
    render_scale: f32 = 1,
    /// How a picture rendered below the output size (`render_scale` under
    /// 1) is brought up to it. `.temporal` lets temporal antialiasing
    /// build the full-size picture out of several frames' samples, which
    /// recovers detail a single frame does not have; `.spatial` stretches
    /// each frame by itself. Temporal needs `temporal_antialiasing`.
    upscaling: Upscaling = .temporal,
    /// Meshes switch to a coarser level of detail once the detail lost
    /// would be smaller than this many pixels on screen. Higher draws
    /// fewer triangles and may show the switch; 0 always draws full detail.
    lod_error_pixels: f32 = 1,
    /// Cross-fade between levels of detail instead of switching: over
    /// this share of the switching distance (0.25 is a good width) both
    /// levels are drawn, each on a dithered share of the pixels that
    /// temporal antialiasing blends. 0 switches at once, which can pop.
    /// Costs drawing two levels of whatever is inside the band.
    lod_cross_fade: f32 = 0,
    /// Which level of detail a local light's shadow is drawn from.
    /// `.camera`: the one the camera sees, so a thing and its shadow
    /// always agree. `.light`: the one that suits the shadow tile, by
    /// distance from the light, which draws far less when a light is far
    /// from what the camera is close to, at the risk of a coarse shadow
    /// on a finely drawn thing. The sun's cascades always follow the
    /// camera.
    shadow_lod: ShadowLod = .camera,
    /// How overlapping transparent surfaces are combined. `.sorted` draws
    /// each mesh back to front, exact for surfaces that do not intersect.
    /// `.weighted` needs no order and never pops when two meshes swap
    /// places, but blends by a weighted average rather than true layering.
    transparency: TransparencyMode = .sorted,
    /// Layers of the `.peeled` mode, 1..16: how many transparent surfaces
    /// behind one another are resolved at each pixel.
    transparency_layers: u32 = 4,
    /// Transparent surfaces cast shadows as dark as they are opaque.
    transparent_shadows: bool = true,
    /// A surface that bends light shows the see-through surfaces behind
    /// it as well, not only the solid scene: the picture is copied again
    /// before each such surface is drawn, which is what it costs. Only
    /// with `.sorted` transparency.
    layered_refraction: bool = false,
    /// See-through surfaces tint the sunlight that passes through them
    /// (stained glass on a floor) instead of only dimming it. Costs a
    /// second, half-size picture per shadow cascade and a pass over the
    /// see-through casters. Sun shadows only; needs `transparent_shadows`.
    colored_shadows: bool = false,
    /// Glossy surfaces mirror what is on screen around them (floors show
    /// the walls, puddles the lamps) instead of only the sky. What is off
    /// screen or hidden cannot be mirrored and falls back to the sky.
    screen_space_reflections: bool = true,
    /// Resolution the reflection rays are traced at. Half traces a quarter
    /// of the rays and joins them back up with regard to depth; mirrors
    /// lose a little sharpness, rough reflections lose nothing visible.
    reflection_resolution: EffectResolution = .full,
    /// Surfaces rougher than this reflect only the sky.
    reflection_max_roughness: f32 = 0.5,
    /// Samples along each reflection ray, 4..256.
    reflection_steps: u32 = 32,
    /// How far a reflection ray travels, in world units.
    reflection_distance: f32 = 30,
    /// How thick surfaces are assumed to be when a ray passes behind them.
    reflection_thickness: f32 = 0.3,
    /// Average reflections over frames. Removes sparkle at thin objects and
    /// screen edges; reflections of moving things trail slightly.
    reflection_temporal_filter: bool = true,
    /// Where the screen has no answer for a reflection (off screen, behind
    /// something), trace a real ray and shade what it hits with sun and
    /// probe light. Needs ray tracing and `global_illumination`. What is
    /// hit shows no highlights of its own, and animated or transparent
    /// things are not hit.
    reflection_ray_tracing: bool = true,
    /// Ray-traced reflections (and water's) show see-through surfaces
    /// too: the nearest one along the ray, laid over what a second ray
    /// finds behind it. Costs that second ray where one is hit.
    reflect_transparent: bool = true,
    /// Samples of the blur that makes reflections softer the rougher the
    /// surface is, 0..32. 0 leaves them sharp at any roughness.
    reflection_blur_samples: u32 = 8,
    /// Draw the scene's fluids (`createFluid`). They are simulated either way.
    fluids: bool = true,
    /// Resolution of the pass that draws them.
    fluid_resolution: EffectResolution = .half,
    /// Samples along each ray through a fluid's box, 4..256, and toward
    /// the sun from each of them, 1..32.
    fluid_steps: u32 = 48,
    fluid_light_steps: u32 = 6,
    /// Smoke shadows what the sun lights behind it (surfaces, fog, other
    /// smoke): a short march through each fluid the sun's ray crosses.
    fluid_shadows: bool = true,
    /// Smoke and flame write motion vectors, so that antialiasing over
    /// frames follows them as they drift instead of smearing them over
    /// what is behind. Costs a look at the flow at every step of the march.
    fluid_motion_vectors: bool = true,
    /// Rays pass through smoke and see fire: ray-traced reflections show
    /// them, and the probes' rays are dimmed by smoke and pick up the
    /// flames. A short march through each fluid box per ray.
    fluid_rays: bool = true,
    /// Draw the scene's cloud layer, if it has one (`setClouds`).
    clouds: bool = true,
    /// Resolution of the cloud pass.
    cloud_resolution: EffectResolution = .half,
    /// Samples along each cloud ray, 8..256, and toward the sun from each
    /// of them, 1..16.
    cloud_steps: u32 = 48,
    cloud_light_steps: u32 = 6,
    /// How far clouds are drawn, in world units; they fade out before it.
    cloud_distance: f32 = 60_000,
    /// Average clouds over frames, which fills in between the samples.
    /// Without it they are grainy unless `cloud_steps` is raised a lot.
    cloud_temporal_filter: bool = true,
    /// Diffuse global illumination from ray-traced irradiance probes.
    /// Ignored (sky light is used instead) on hardware without ray queries.
    global_illumination: bool = true,
    /// Distance between probes; grows automatically for large scenes.
    gi_probe_spacing: f32 = 1.5,
    /// Rays traced per probe per frame, 16..256.
    gi_rays: u32 = 64,
    /// Multiplies the indirect light the probes give; 1 is unchanged.
    gi_intensity: f32 = 1,
    /// Resolution at which probe irradiance is evaluated. `.full` looks the
    /// probes up per pixel with the normal-mapped normal. Lower settings
    /// gather with geometric normals and upsample, which is cheaper but
    /// drops normal-map detail from indirect light.
    gi_resolution: EffectResolution = .full,
    /// Each probe is re-traced once every this many frames (1..16). Higher
    /// values cost less and react to lighting changes more slowly.
    gi_update_interval: u32 = 4,
    /// How much of a probe's previous value survives each frame, 0..1.
    /// Higher is steadier and slower to follow small lighting changes:
    /// 0.995 settles in about four seconds at 60 fps and 0.99 in two, with
    /// bounce light that drifts half as much again; 0.9 takes a sixth of
    /// a second but flickers visibly at low ray counts. Large changes do
    /// not wait for it: see `gi_change_tolerance`.
    gi_hysteresis: f32 = 0.995,
    /// What to do in a scene too large for the probe grid at
    /// `gi_probe_spacing`. True keeps that spacing in a grid that moves
    /// with the camera and adds a coarse grid over the whole scene behind
    /// it; false uses only the coarse one. Following costs the second
    /// grid's update (about 0.1 ms in the Sponza test).
    gi_follow_camera: bool = true,
    /// How much wider than `gi_probe_spacing` the probes would have to be
    /// spread to cover the scene before the following grid is used.
    gi_follow_threshold: f32 = 1.25,
    /// Frames between updates of the coarse grid behind a following one,
    /// once it has settled. 1 updates it every frame; higher saves that
    /// cost on the frames between and makes distant bounce light slower
    /// to follow changes.
    gi_coarse_interval: u32 = 1,
    /// For very large worlds: when the coarse grid's probes end up more
    /// than this many times as far apart as the main grid's, a third
    /// grid goes between them, following the camera at a spacing halfway
    /// (geometrically) between the two. 0 never adds one.
    gi_middle_ratio: f32 = 6,
    /// Local lights (up to the first 32) light what probe and reflection
    /// rays hit, each tested with a shadow ray: lamps then bounce off
    /// walls, and lamp-lit surfaces show in ray-traced reflections. Costs
    /// a ray per light in range per hit.
    gi_local_lights: bool = true,
    /// Most local lights whose light bounces: the first this many of the
    /// scene's list, up to 1023. Every ray that hits something looks at
    /// each of them and sends a shadow ray to those in range, so the cost
    /// grows with it; lights past the count still light surfaces directly.
    gi_bounce_lights: u32 = 32,
    /// Probes that sit inside geometry (most of their rays meet the backs
    /// of surfaces) are traced only every eighth turn: nothing is lit by
    /// them, so their rays are wasted. A probe uncovered by something
    /// moving away takes up to eight updates to notice.
    gi_skip_buried_probes: bool = false,
    /// Move probes out of walls and off surfaces they sit too close to,
    /// each within its own cell, from what their rays meet. A probe in a
    /// wall is dark and one against a surface sees little of the room;
    /// moved, both light their surroundings properly. Costs a small pass
    /// per probe update and eight texture fetches per shaded pixel.
    gi_probe_relocation: bool = false,
    /// How far a probe's fast estimate may differ from its steady value
    /// before the steady value is pulled along, as a fraction (0.25 = 25%).
    /// This is what lets `gi_hysteresis` be high without making light
    /// changes lag: noise stays inside the band and is averaged away, a
    /// door opening or a light switching on leaves it and shows within a
    /// few frames. 0 turns the mechanism off.
    gi_change_tolerance: f32 = 0.3,
    /// Resolution of the ambient occlusion pass; upsampled with depth
    /// weights. Lower is cheaper and softer.
    ao_resolution: EffectResolution = .half,
    /// Resolution of the volumetric fog pass.
    fog_resolution: EffectResolution = .half,
    /// Samples along each fog ray, 4..128.
    fog_steps: u32 = 12,
    /// Directions searched for occluders per pixel, 1..8.
    ao_slices: u32 = 2,
    /// Samples per direction, 1..32.
    ao_steps: u32 = 5,
    /// Refresh the far sun cascades every 2nd, 4th and 8th frame instead of
    /// every frame. Turn off if far shadows of moving objects must not lag.
    shadow_cascade_stagger: bool = true,
    /// Antialias by jittering the camera and blending each frame with the
    /// reprojected ones before it (TAA). Several other settings rely on it
    /// to average their noise away.
    temporal_antialiasing: bool = true,
    /// Mip bias for material textures while temporal antialiasing is on.
    /// Negative values pick sharper mips, which the accumulation resolves
    /// into extra detail at the cost of more shimmer on very fine patterns;
    /// 0 is the unbiased, most stable choice.
    texture_mip_bias: f32 = -0.25,
    /// Widen highlights where normals vary faster than pixels can show
    /// (distant normal-mapped metal, fabric weave), which otherwise sparkle.
    specular_antialiasing: bool = true,
    /// Fraction of the image replaced by its blurred self; 0 disables bloom.
    bloom: f32 = 0.04,
    /// How many halvings the bloom blur goes through, 1..6. More spreads
    /// the glow wider.
    bloom_levels: u32 = 6,
    /// Adapt exposure to the picture's average brightness over time, as
    /// an eye or a camera does. False uses `exposure_compensation` alone.
    automatic_exposure: bool = true,
    /// Stops added on top of automatic exposure, or the absolute exposure
    /// (as 2^EV) when automatic exposure is off.
    exposure_compensation: f32 = 0,
    /// Extinction of the volumetric fog per world unit; 0 disables it.
    fog_density: f32 = 0,
    /// How quickly the fog thins with height.
    fog_height_falloff: f32 = 0.08,
    /// Forward-scattering bias, 0 isotropic .. 1 all toward the viewer.
    fog_anisotropy: f32 = 0.6,
    /// Aerial perspective: haze per world unit that distant opaque
    /// surfaces fade into the sky by (0.0005 turns hills a kilometre away
    /// pale). 0 for none. Needs an environment.
    aerial_perspective: f32 = 0,
    /// What the haze is made of. `.atmosphere`: air, which scatters blue
    /// more than red (far things turn blue), glows around the sun and is
    /// lit by sun and sky. `.sky`: one grey haze that fades things to the
    /// sky seen behind them, which matches any backdrop exactly.
    aerial_model: AerialModel = .atmosphere,
    /// Strength of the post-TAA sharpening filter, 0..1.
    sharpen: f32 = 0.35,
    /// Read text from a three-channel distance field, in which the
    /// corners of letters stay sharp however large the text is drawn.
    /// False reads the plain field, which rounds corners off at large
    /// sizes but cannot show the rare speck the three channels can.
    sharp_text: bool = true,
    /// Darkening toward the corners of the picture, 0..1.
    vignette: f32 = 0,
    /// Film grain strength, 0..1.
    film_grain: f32 = 0,
    /// 0 is black and white, 1 unchanged, above 1 more vivid.
    saturation: f32 = 1,
    /// Contrast around middle grey; 1 unchanged.
    contrast: f32 = 1,
    /// White balance: negative cooler (bluer), positive warmer, -1..1.
    temperature: f32 = 0,
    /// Multiplies the picture before tone mapping, like a lens filter.
    color_filter: [3]f32 = .{ 1, 1, 1 },
    /// A color lookup table applied to the finished picture, as graded in
    /// an image editor: a strip of N slices, each N by N, N squared wide
    /// and N tall (16 or 32 are usual), in sRGB. Load it with
    /// `createImage(..., false)` so it is not converted.
    color_lut: ?Image = null,
    /// How much of the table's result to use, 0..1.
    color_lut_strength: f32 = 1,
    /// Red/blue fringing toward the corners, 0..1.
    chromatic_aberration: f32 = 0,
    /// Lens flare: faint mirrored copies of, and a ring around, things far
    /// brighter than white (the sun, lamps). 0 is none, 1 is plain to see.
    lens_flare: f32 = 0,
    /// How the final picture is encoded. `.auto` matches the target: sRGB
    /// for ordinary targets, HDR10 for the window when `Options.hdr_output`
    /// got an HDR surface. The others force one, for rendering to a
    /// texture meant for something else.
    output_encoding: OutputEncoding = .auto,
    /// HDR10 only: how bright white (a page, the UI) is, in nits.
    hdr_paper_white: f32 = 200,
    /// HDR10 only: the brightest the display can show, in nits. Highlights
    /// roll off toward it instead of clipping.
    hdr_peak: f32 = 1000,
    /// Depth of field: how wide the lens is open. 0 keeps everything
    /// sharp; 1 blurs distant things by about 24 pixels at 1080p when
    /// focused close.
    dof_aperture: f32 = 0,
    /// Distance from the camera that is in perfect focus.
    dof_focus_distance: f32 = 10,
    /// Focus on whatever is at the middle of the picture instead, easing
    /// to it over a moment (`dof_autofocus_speed`).
    dof_autofocus: bool = false,
    /// How quickly the autofocus follows, per second; higher refocuses
    /// faster.
    dof_autofocus_speed: f32 = 4,
    /// Largest blur radius, in pixels at 1080p.
    dof_max_blur: f32 = 16,
    /// Samples gathered per pixel, 4..128.
    dof_samples: u32 = 32,
    /// Resolution the blur is gathered at. Half or quarter costs a fraction
    /// and is joined back onto the sharp picture by how far each pixel is
    /// out of focus; fine detail inside the blur is softer still.
    dof_resolution: EffectResolution = .full,
    /// Blades of the aperture: out-of-focus highlights become polygons
    /// with this many sides (5 to 9 are what lenses have). 0 keeps them
    /// round.
    dof_blades: u32 = 0,
    /// Motion blur: the fraction of a frame the shutter stays open. 0 is
    /// off, 0.5 is the film look.
    motion_blur: f32 = 0,
    /// Samples along each pixel's path, 2..64.
    motion_blur_samples: u32 = 10,
    /// Let fast things smear over what is next to them, past their own
    /// outline, as a real shutter does. Off blurs each pixel only by its
    /// own motion, which leaves moving things with hard edges; it costs
    /// one more lookup per sample.
    motion_blur_spread: bool = true,
    /// Draw the scene by path tracing instead: every pixel follows a ray
    /// from surface to surface and gathers the light of the sun, the
    /// lamps, the sky and what glows. One frame is noisy; frames are
    /// averaged for as long as the camera, the scene and the lights
    /// stand still, and start over when one of them moves. A reference
    /// to compare the usual picture with, and a way to make a still.
    /// Uses the GPU's ray tracing where there is some and a shader
    /// that walks a tree built on the CPU where there is not (far
    /// slower, and only with `Options.path_tracing_fallback`);
    /// `Renderer.pathTracing` says which
    /// and how many frames have been gathered. Not traced: skinned
    /// meshes without ray tracing, water, liquids, smoke, clouds,
    /// particles and decals, and refraction through glass.
    path_tracing: bool = false,
    /// Surfaces a path may bounce off before it ends, 1..16. 1 is
    /// direct light only.
    path_tracing_bounces: u32 = 4,
    /// Paths followed for each pixel every frame, 1..64.
    path_tracing_samples: u32 = 1,
    /// Most light a path may bring back by way of a rough bounce, in the
    /// scene's units before exposure; what is seen directly or in a mirror
    /// is not limited. Lower hides the sparkle of rare bright paths sooner
    /// and loses a little of their light.
    path_tracing_clamp: f32 = 12,
    /// Clear the grain of a path-traced picture that has not gathered
    /// many frames yet, by averaging the light of neighbouring pixels
    /// on the same surface. Textures, edges, mirrors and what glows
    /// are left alone, and the averaging narrows as frames are
    /// gathered, so a finished picture is as it was traced. False
    /// shows the picture exactly as gathered. Two passes over the
    /// picture.
    path_tracing_denoise: bool = true,
    /// Show one input of the shading instead of the lit picture.
    debug_view: DebugView = .none,
};

/// What `Settings.debug_view` shows in place of the lit picture. The
/// values match the switch in `shaders/shade.glsl`.
pub const DebugView = enum(u32) {
    /// The normal, lit picture.
    none,
    /// Base color of the material, without lighting.
    albedo,
    /// Shading normal, mapped from -1..1 to 0..1 per axis.
    normal,
    roughness,
    metallic,
    ambient_occlusion,
    /// How much of the sun reaches each point: white lit, black shadowed.
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

/// How a picture rendered below the output size is brought up to it; see
/// `Settings.upscaling`.
pub const Upscaling = enum { spatial, temporal };

/// Fraction of the output resolution an effect is computed at. Reduced
/// rates are brought back to full resolution with a depth-aware upsample.
pub const EffectResolution = enum {
    full,
    /// Half the width and height: a quarter of the pixels.
    half,
    /// A quarter of the width and height: a sixteenth of the pixels.
    quarter,

    fn extent(self: EffectResolution, size: u32) u32 {
        return @max(size >> @intFromEnum(self), 1);
    }
};

const EffectScales = struct {
    ao: EffectResolution,
    fog: EffectResolution,
    gi: EffectResolution,
    reflections: ?EffectResolution,
    clouds: ?EffectResolution,
    fluid: ?EffectResolution,
    lens: bool,
    /// Set when depth of field is gathered at reduced resolution.
    dof: ?EffectResolution = null,
    oit: bool,
    peel: bool,
    refraction: bool,
    /// The scene holds a liquid: the targets its surface is built in.
    liquid: bool = false,
    output_width: u32,
    output_height: u32,
    /// Temporal antialiasing resolves at the output size: its history and
    /// what follows it are that large.
    temporal_upscale: bool = false,
};

/// Where a view's picture goes; see `ViewDesc.target`.
pub const Target = union(enum) {
    /// The window surface passed in `Options.surface`.
    backbuffer,
    /// Any color texture created with `.color_attachment` usage.
    texture: rhi.Texture,
};

/// A rectangle of a target, in pixels from the top-left corner.
pub const Region = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

/// Points in a view's frame where application code can record its own GPU
/// work.
pub const PassStage = enum {
    /// Opaque surfaces are lit. `color` is the HDR scene color and `depth`
    /// the scene depth; draw your own opaque geometry or decals here.
    after_opaque,
    /// Transparency and fog are in. Still HDR, before antialiasing, bloom
    /// and exposure, so effects drawn here are antialiased with the scene.
    after_transparency,
    /// The picture is tone-mapped. `color` is the view's output in display
    /// colors; draw lists come after this.
    after_tonemap,
};

/// What a custom pass gets to work with. Textures are in the shader-read
/// state unless noted; `cmd.beginRendering` moves them to attachments and
/// the renderer restores them afterwards.
pub const PassContext = struct {
    cmd: *rhi.CommandEncoder,
    device: *rhi.Device,
    stage: PassStage,
    /// Address of this view's `FrameConstants` (see `shaders/common.glsl`):
    /// camera matrices, jitter, time, the scene buffers and lighting.
    frame: u64,
    color: rhi.Texture,
    color_format: rhi.Format,
    /// Reverse-Z scene depth (near plane at 1, far at 0).
    depth: rhi.Texture,
    /// Screen-space motion vectors; write them for geometry that moves.
    motion: rhi.Texture,
    width: u32,
    height: u32,
};

/// Application code run at a `PassStage` of a view. It is called while the
/// frame is being recorded, with the renderer locked: record commands and
/// use `device`, but do not call back into the `Renderer`.
pub const Pass = struct {
    stage: PassStage,
    context: ?*anyopaque = null,
    run: *const fn (context: ?*anyopaque, pass: PassContext) anyerror!void,
};

/// Format of `PassContext.color` before tone mapping.
pub const scene_color_format: rhi.Format = .rgba16_float;

/// What was found under a pixel.
pub const Pick = struct {
    /// The entity hit, or `.invalid` when it was a copy in an instance group.
    entity: Entity,
    /// The instance group and which of its copies was hit, if it was one.
    instances: ?InstanceGroup = null,
    copy: u32 = 0,
    /// Which of the entity's model's mesh instances was hit.
    mesh_instance: u32,
    /// World-space point on the surface.
    position: Vec3,
    /// Distance from the camera plane.
    distance: f32,
};

/// Application surface code; see `Renderer.createMaterialShader`.
pub const MaterialShader = struct {
    /// Value for `Material.shader`.
    slot: u32,
};

/// The answer to a `Renderer.requestPick`, returned by `Renderer.takePick`.
pub const PickResult = struct {
    /// The pixel that was asked about.
    pixel: [2]u32,
    /// Null when nothing opaque is there, or the scene's contents changed
    /// before the answer came back.
    hit: ?Pick,
};

/// A box that projects a color or an image onto the opaque surfaces inside
/// it: bullet marks, blood, paint, road markings, blob shadows.
pub const DecalDesc = struct {
    /// Places a unit cube (-0.5..0.5) in the world. The image is projected
    /// along the cube's local -Z, so +Z should point away from the surface;
    /// X and Y are the image's width and height, Z how deep it reaches.
    transform: Mat4,
    /// Linear color and opacity, multiplied with the image if there is one.
    color: [4]f32 = .{ 1, 1, 1, 1 },
    image: ?Image = null,
    /// A normal map laid over the surface inside the box (cracks, bullet
    /// holes, tyre tracks), and how strongly it bends the surface.
    normal_image: ?Image = null,
    normal_strength: f32 = 1,
    /// Roughness to give the covered surface (wet paint, dry dust); null
    /// keeps what the surface has.
    roughness: ?f32 = null,
    /// How much the decal glows with its own color.
    emissive: f32 = 0,
    /// Surfaces facing away from the projection by more than this cosine
    /// are left alone, so a decal on a floor does not smear up a wall.
    angle_fade: f32 = 0.2,
};

/// Most decals a scene can hold. They are sorted into the same view-space
/// clusters as lights, so a pixel only tests the ones near it.
pub const max_decals = gpu.cluster_decal_words * 32;

/// A clear sky computed from the sun's position instead of loaded from a
/// photograph. See `Renderer.createSky`.
pub const SkyDesc = struct {
    /// Direction the sun's light travels, as in `Sun.direction`.
    sun_direction: Vec3 = .{ -0.4, -1.0, -0.3 },
    /// Haze: 1 is very clear air, 10 a hazy day with a pale sky and a wide
    /// glow around the sun.
    turbidity: f32 = 2.5,
    /// Ozone in the air, 1 for the Earth's. It absorbs orange and green
    /// light high up, which is what keeps the sky overhead blue at dusk;
    /// 0 leaves it out (a greener, yellower twilight).
    ozone: f32 = 1,
    /// Frames a change to the sky is spread over: 1 redraws it all in the
    /// frame it changes; more draws a part per frame, so a sky that
    /// changes all the time (a moving sun) costs a fraction per frame and
    /// follows a few frames behind. While it is under way the faces of
    /// the sky are from two different moments. Ignored (taken as 1) while
    /// a cloud layer is baked into the lighting.
    rebuild_frames: u32 = 1,
    /// Overall brightness of the sky.
    intensity: f32 = 1,
    /// Color of the ground below the horizon, as seen in reflections and
    /// bouncing light up into the scene.
    ground_color: [3]f32 = .{ 0.25, 0.23, 0.2 },
    /// Draw the sun's disc into the sky, so it shows and reflects.
    sun_disc: bool = true,
    /// Brightness of the stars, which show once the sun is down. 0 leaves
    /// the night sky empty.
    stars: f32 = 0,
    /// A moon: the direction its light travels (as for the sun) and how
    /// bright its disc is drawn; 0 for no moon. It gives no light by
    /// itself: pair it with a directional light for moonlight.
    moon_direction: Vec3 = .{ 0.3, -0.6, 0.5 },
    moon: f32 = 0,
};

/// Brightness of the sun above the atmosphere; matches env_sky.frag.
const sky_sun_strength = 8.0;

/// The sun that goes with a sky: its direction, and the color and strength
/// left after the light has crossed the atmosphere (white at noon, weak and
/// red near the horizon, nothing below it). Pass it to `Renderer.setSun`.
pub fn skySun(desc: SkyDesc) Sun {
    const to_sun = math.normalize(math.scale(desc.sun_direction, -1));
    if (to_sun[1] <= -0.02) return .{ .direction = desc.sun_direction, .intensity = 0 };
    // The same integral as the shader's light march, from the ground up.
    const planet = 6360e3;
    const top = 6420e3;
    const origin_height = planet + 200.0;
    const b = origin_height * @max(to_sun[1], 0.0);
    const exit = -b + @sqrt(@max(b * b - (origin_height * origin_height - top * top), 0));
    var rayleigh: f32 = 0;
    var mie: f32 = 0;
    var ozone: f32 = 0;
    const steps = 32;
    const step_length = exit / steps;
    for (0..steps) |index| {
        const t = step_length * (@as(f32, @floatFromInt(index)) + 0.5);
        const height = @sqrt(origin_height * origin_height + t * t + 2 * origin_height * t * @max(to_sun[1], 0.0)) - planet;
        rayleigh += @exp(-height / 8000.0) * step_length;
        mie += @exp(-height / 1200.0) * step_length;
        ozone += @max(1 - @abs(height - 25e3) / 15e3, 0) * step_length;
    }
    const beta = [3]f32{ 5.8e-6, 13.5e-6, 33.1e-6 };
    const absorbed = [3]f32{ 0.650e-6, 1.881e-6, 0.085e-6 };
    var color: Vec3 = undefined;
    inline for (0..3) |c| color[c] = @exp(-(beta[c] * rayleigh + 4e-6 * desc.turbidity * 1.1 * mie + absorbed[c] * @max(desc.ozone, 0) * ozone));
    const strongest = @max(color[0], @max(color[1], color[2]));
    if (strongest < 1e-6) return .{ .direction = desc.sun_direction, .intensity = 0 };
    // Fade out over the last degree as the disc sinks below the horizon.
    const above = std.math.clamp((to_sun[1] + 0.02) / 0.04, 0, 1);
    return .{
        .direction = desc.sun_direction,
        .color = math.scale(color, 1 / strongest),
        .intensity = sky_sun_strength * strongest * desc.intensity * above,
    };
}

/// How an emitter's particles are laid over the picture.
pub const ParticleBlend = enum {
    /// Covers what is behind it in proportion to its opacity (smoke, dust).
    alpha,
    /// Adds light without hiding anything (fire, sparks, magic).
    additive,
};

/// Most keys a particle curve can have.
pub const max_curve_keys = gpu.emitter_curve_keys;

/// Most remembered points a particle's trail can have.
pub const max_trail_points = 32;

/// Colors (linear, with opacity) at evenly spaced moments of a particle's
/// life. Fewer than two keys means no curve.
pub const ColorCurve = struct {
    keys: [max_curve_keys][4]f32 = @splat(.{ 1, 1, 1, 1 }),
    count: u32 = 0,

    /// Keys past `max_curve_keys` are dropped.
    pub fn init(keys: []const [4]f32) ColorCurve {
        var curve = ColorCurve{ .count = @intCast(@min(keys.len, max_curve_keys)) };
        @memcpy(curve.keys[0..curve.count], keys[0..curve.count]);
        return curve;
    }
};

/// Diameters at evenly spaced moments of a particle's life.
pub const SizeCurve = struct {
    keys: [max_curve_keys]f32 = @splat(0),
    count: u32 = 0,

    /// Copies `keys` into a curve. Keys past `max_curve_keys` are dropped.
    pub fn init(keys: []const f32) SizeCurve {
        var curve = SizeCurve{ .count = @intCast(@min(keys.len, max_curve_keys)) };
        @memcpy(curve.keys[0..curve.count], keys[0..curve.count]);
        return curve;
    }
};

/// A local reflection probe: a picture of the surroundings taken from one
/// place, which surfaces inside the probe's box mirror where neither the
/// screen nor a ray gives them a reflection (indoors, that is otherwise
/// the sky dimmed by how little of it is visible). See
/// `Renderer.createReflectionProbe`.
pub const ReflectionProbeDesc = struct {
    /// Where the picture is taken from, and the middle of the box.
    position: Vec3,
    /// Half the size of the box of space the probe answers for. Mirror
    /// rays are followed to the box's walls, so a box that matches the
    /// room gives reflections that sit where the walls are.
    extent: Vec3 = .{ 5, 3, 5 },
    /// Share of the box, inward from its faces, over which the probe
    /// fades into whatever lies outside it.
    fade: f32 = 0.15,
    intensity: f32 = 1,
    /// Pixels along each side of the six pictures taken, 16..1024.
    resolution: u32 = 256,
    /// Frames to let the scene's bounced light settle before the first
    /// pictures are taken.
    settle_frames: u32 = 40,
    /// Brightest value kept, so one hot highlight does not sparkle
    /// across every rough surface.
    max_radiance: f32 = 32,
};

/// Most reflection probes a scene can hold.
pub const max_reflection_probes = 16;

/// A source of particles in a scene. Everything except `capacity` can be
/// changed at any time with `Renderer.setEmitter`.
pub const EmitterDesc = struct {
    position: Vec3 = .{ 0, 0, 0 },
    /// Particles are born inside a sphere of this radius.
    radius: f32 = 0.1,
    /// Most particles alive at once; fixed when the emitter is created. If
    /// `rate` times the lifetime exceeds it, the oldest are replaced early.
    capacity: u32 = 1024,
    /// Births per second. 0 stops emitting; living particles finish.
    rate: f32 = 100,
    /// Seconds a particle lives, chosen between these two.
    lifetime: [2]f32 = .{ 1, 2 },
    /// Axis of the cone particles are launched into.
    direction: Vec3 = .{ 0, 1, 0 },
    /// Half-angle of that cone in radians; pi launches in every direction.
    spread: f32 = 0.4,
    /// Launch speed, chosen between these two.
    speed: [2]f32 = .{ 1, 2 },
    /// Constant acceleration. Negative Y falls, positive rises like smoke.
    gravity: Vec3 = .{ 0, 0, 0 },
    /// How quickly particles lose speed, per second.
    drag: f32 = 0.5,
    /// Diameter in world units at birth and at death.
    size: [2]f32 = .{ 0.05, 0.2 },
    /// Linear color and opacity at birth and at death. Values above 1 glow
    /// and feed bloom.
    color_start: [4]f32 = .{ 1, 1, 1, 1 },
    color_end: [4]f32 = .{ 1, 1, 1, 0 },
    blend: ParticleBlend = .alpha,
    /// Lit by the sun (with shadows) and the surroundings; turn off for
    /// particles that are themselves a light source.
    lit: bool = true,
    /// Distance over which a particle fades out as it nears a surface; 0
    /// gives a hard edge.
    softness: f32 = 0.3,
    /// Draw the particles farthest first, sorted on the GPU for every
    /// view. Alpha-blended particles that overlap (smoke, dust) need it
    /// to layer correctly; additive ones do not. Fixed when the emitter
    /// is created, like `capacity`.
    sorted: bool = false,
    /// Seconds of simulation to run before the emitter is first shown, so
    /// it starts full (smoke already risen, snow already falling) instead
    /// of empty. Costs that many frames of simulation on its first frame.
    prewarm: f32 = 0,
    /// A third color and size partway through a particle's life, at `mid`
    /// (0..1). Null goes straight from start to end.
    color_mid: ?[4]f32 = null,
    size_mid: ?f32 = null,
    mid: f32 = 0.5,
    /// Free-form color and size over a particle's life: 2 to
    /// `max_curve_keys` keys spaced evenly from birth to death, which
    /// replace the start, mid and end values above. See `ColorCurve.init`.
    color_curve: ColorCurve = .{},
    size_curve: SizeCurve = .{},
    /// Draw each particle as a copy of this model's first mesh instead of
    /// a flat sprite (debris, leaves, shards): the model's unit is `size`
    /// across, colored by the particle's color (times the mesh's vertex
    /// colors and `image`, laid out by the mesh's texture coordinates),
    /// matte when `lit`. The copies hide each other and are hidden by the
    /// scene exactly, so they need no sorting; `softness` and `stretch`
    /// do not apply. Nothing is drawn until the model has loaded.
    mesh: ?Model = null,
    /// Radians per second a mesh particle tumbles, about an axis of its
    /// own and at up to half again or half this pace.
    spin: f32 = 0,
    /// Draw a ribbon behind each particle through the places it has been:
    /// this many remembered points per particle (up to `max_trail_points`;
    /// 0 for none), reaching `trail_seconds` back. The ribbon is as wide
    /// as the particle at its head and narrows and fades to nothing at
    /// its tail; with an `image`, the image runs once along it. The point
    /// count is fixed when the emitter is created, like `capacity`.
    trail: u32 = 0,
    trail_seconds: f32 = 0.4,
    /// A fluid whose flow carries the particles while they are inside its
    /// box (embers in a fire, dust in smoke), and how quickly they take
    /// on its velocity, per second.
    fluid: ?Fluid = null,
    fluid_follow: f32 = 6,
    /// Bounce off the surfaces the first view of the scene saw last frame,
    /// keeping this share of their speed. Only what is on screen can be
    /// hit.
    collide: bool = false,
    bounce: f32 = 0.4,
    /// Draw each particle as a streak along its motion, this many seconds
    /// of travel long (sparks, rain). 0 draws it round.
    stretch: f32 = 0,
    /// Columns and rows of frames in `image`; they play once over the
    /// particle's life.
    sheet: [2]u32 = .{ 1, 1 },
    /// Sprite to draw; null draws a soft round blob.
    image: ?Image = null,
};

/// One camera's picture: what to draw, from where, and where it goes.
pub const ViewDesc = struct {
    /// Which persistent view state to use (temporal history, exposure,
    /// shadow cascades, occlusion results). Null is the renderer's built-in
    /// main view. Every camera that is drawn in the same frame needs its
    /// own `View`; see `Renderer.createView`.
    view: ?View = null,
    /// The 3D scene to draw, or null for a purely 2D view.
    scene: ?Scene = null,
    /// Shapes, images and text drawn over the scene, in order. The lists
    /// must not be modified until `render` returns.
    draw_lists: []const *const DrawList = &.{},
    /// Background when there is no scene. Linear RGBA. Only the first view
    /// drawn to a target in a frame clears it; later ones draw over it.
    clear_color: [4]f32 = .{ 0, 0, 0, 1 },
    /// Where the scene is seen from; unused without a scene.
    camera: Camera = .{},
    /// Where the picture goes: the window or a texture.
    target: Target = .backbuffer,
    /// Part of the target to draw into, for split screen and insets. Null
    /// covers the whole target.
    region: ?Region = null,
    /// Application passes run at fixed points of this view's frame.
    passes: []const Pass = &.{},
    settings: Settings = .{},
};

/// Everything `Renderer.render` draws in one frame.
pub const FrameDesc = struct {
    /// Drawn in order. A view may draw into a texture that a later view
    /// shows (see `Renderer.targetImage`), or over an earlier view.
    views: []const ViewDesc,
    /// Seconds since the previous frame; drives exposure adaptation.
    delta_time: f32 = 1.0 / 60.0,
};

/// How path tracing follows its rays on a device; see
/// `Renderer.pathTracing`.
pub const PathTracing = enum {
    /// By the GPU's own ray tracing.
    hardware,
    /// By an ordinary shader walking trees built on the CPU: the GPU has
    /// no ray tracing (or `Options.ray_tracing` is off) and
    /// `Options.path_tracing_fallback` is on.
    shader,
    /// Not at all: the GPU has no ray tracing and the fallback was not
    /// asked for. `Settings.path_tracing` then leaves the usual picture.
    unavailable,
};

/// Counters describing the last frame; see `Renderer.getStats`.
pub const Stats = struct {
    /// Views drawn in the last frame. The scene numbers below describe the
    /// first one that showed a scene.
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
    /// Triangles in the scene at full detail, visible entities and
    /// instance copies together, before culling and level of detail.
    triangles: u64 = 0,
    /// Vertices deformed by skinning or morphing this frame.
    skinned_vertices: u32 = 0,
    /// Models and environments still loading.
    models_loading: u32 = 0,
    /// GPU memory the device has allocated, in bytes.
    gpu_memory_bytes: u64 = 0,
    /// Textures under `Options.texture_streaming`, the GPU memory they
    /// take now, and how many are waiting to load more detail.
    streamed_textures: u32 = 0,
    streamed_texture_bytes: u64 = 0,
    streamed_textures_pending: u32 = 0,
    /// With geometry streaming: the models whose geometry is out of GPU
    /// memory just now, and how many bytes of vertices and indices that
    /// is.
    geometry_models_released: u32 = 0,
    geometry_bytes_released: u64 = 0,
    /// Bytes of vertices and indices moved toward the start of their
    /// pools since the renderer started, to close gaps that freed models
    /// left and let the pools shrink.
    geometry_bytes_compacted: u64 = 0,
    /// Models of which only the coarser levels of detail are in GPU
    /// memory (`GeometryStreaming.coarse_distance`).
    geometry_models_coarse: u32 = 0,
    /// Triangles drawn from draw lists, over all views.
    draw_list_triangles: u32 = 0,
    /// Frames gathered into the path-traced picture of the view drawn
    /// last, 0 when none was path traced; and whether its rays were
    /// followed by the GPU's ray tracing or by a shader.
    path_traced_frames: u32 = 0,
    path_tracing_hardware: bool = false,
    /// CPU time spent building and submitting the last frame, excluding
    /// waits on the GPU and the display.
    cpu_ms: f32 = 0,
    /// Irradiance probes updated this frame; 0 when GI is inactive.
    gi_probes: u32 = 0,
};

/// Format of the targets the scene is lit into, before tone mapping.
pub const hdr_format = scene_color_format;
const bloom_format: rhi.Format = .b10g11r11_float;
/// Most levels a bloom chain can have; see `Settings.bloom_levels`.
pub const bloom_levels = 6;
const ao_depth_mips = 5;
/// Culling views of a frame: the main view, the shadow cascades, the main
/// view's late (post-occlusion) phase and the local lights' shadow views.
pub const view_count = 2 + gpu.cascade_count + max_local_shadow_views;
/// Index of the culling view that is the main view's late phase.
pub const main_late_view = 1 + gpu.cascade_count;
/// Index of the first of the local lights' culling views.
pub const local_view_base = main_late_view + 1;
/// Most shadow-casting views that local lights can have between them;
/// each fills a tile of their shadow atlas.
pub const max_local_shadow_views = 16;
/// Moving things listed per scene before giving up and calling all of it moving.
const max_movers = 256;

/// Most tiles along one side of the local lights' shadow atlas.
pub const local_shadow_tiles_per_side = 4;
/// Clusters are spaced exponentially in depth between these distances.
const cluster_near: f32 = 0.3;
const cluster_far: f32 = 200;
const cluster_z_scale: f32 = @as(f32, gpu.clusters_z) / @log2(cluster_far / cluster_near);
const env_cube_size = 512;
const env_specular_size = 256;
const env_specular_mips = 6;
const env_irradiance_size = 32;
const stream_budget_bytes = 48 * 1024 * 1024;

// ------------------------------------------------------------------ storage

const Range = struct { offset: u32, count: u32 };

/// First-fit range allocator over element indices with coalescing frees.
const RangeAllocator = struct {
    free_ranges: std.ArrayList(Range) = .empty,
    top: u32 = 0,
    capacity: u32,

    fn alloc(self: *RangeAllocator, count: u32) ?u32 {
        for (self.free_ranges.items, 0..) |*range, index| {
            if (range.count < count) continue;
            const offset = range.offset;
            if (range.count == count) {
                _ = self.free_ranges.orderedRemove(index);
            } else {
                range.offset += count;
                range.count -= count;
            }
            return offset;
        }
        if (self.top + count > self.capacity) return null;
        defer self.top += count;
        return self.top;
    }

    fn free(self: *RangeAllocator, gpa: std.mem.Allocator, offset: u32, count: u32) void {
        if (count == 0) return;
        var index: usize = 0;
        while (index < self.free_ranges.items.len and self.free_ranges.items[index].offset < offset) index += 1;
        self.free_ranges.insert(gpa, index, .{ .offset = offset, .count = count }) catch return; // leak the range
        if (index + 1 < self.free_ranges.items.len) {
            const next = self.free_ranges.items[index + 1];
            if (offset + count == next.offset) {
                self.free_ranges.items[index].count += next.count;
                _ = self.free_ranges.orderedRemove(index + 1);
            }
        }
        if (index > 0) {
            const previous = &self.free_ranges.items[index - 1];
            if (previous.offset + previous.count == offset) {
                previous.count += self.free_ranges.items[index].count;
                _ = self.free_ranges.orderedRemove(index);
            }
        }
        if (self.free_ranges.items.len != 0) {
            const last = self.free_ranges.items[self.free_ranges.items.len - 1];
            if (last.offset + last.count == self.top) {
                self.top = last.offset;
                _ = self.free_ranges.pop();
            }
        }
    }
};

/// A growable GPU array shared by every model (vertices, indices, ...).
const Pool = struct {
    name: [:0]const u8,
    stride: u32,
    buffer: rhi.Buffer,
    ranges: RangeAllocator,
    usage: rhi.BufferUsage,
    /// The size it was created with; it never gets smaller than this.
    minimum: u32,

    fn init(device: *rhi.Device, name: [:0]const u8, stride: u32, capacity: u32, usage: rhi.BufferUsage) !Pool {
        return .{
            .name = name,
            .stride = stride,
            .buffer = try device.createBuffer(.{ .name = name, .size = @as(u64, capacity) * stride, .usage = usage }),
            .ranges = .{ .capacity = capacity },
            .usage = usage,
            .minimum = capacity,
        };
    }

    fn deinit(self: *Pool, renderer: *Renderer) void {
        renderer.device.destroyBuffer(self.buffer);
        self.ranges.free_ranges.deinit(renderer.gpa);
    }

    fn alloc(self: *Pool, renderer: *Renderer, count: u32) !u32 {
        if (count == 0) return 0;
        if (self.ranges.alloc(count)) |offset| return offset;
        // Out of room: move to a buffer twice the size. The copy is ordered
        // with pending uploads, and addresses are re-read every frame.
        const device = renderer.device;
        const old_capacity = self.ranges.capacity;
        const new_capacity = @max(old_capacity * 2, self.ranges.top + count);
        const new_buffer = try device.createBuffer(.{
            .name = self.name,
            .size = @as(u64, new_capacity) * self.stride,
            .usage = self.usage,
        });
        // An empty pool has nothing to carry over.
        if (self.ranges.top != 0) {
            errdefer device.destroyBuffer(new_buffer);
            try device.queueBufferCopy(self.buffer, new_buffer, @as(u64, self.ranges.top) * self.stride);
        } else device.destroyBuffer(self.buffer);
        self.buffer = new_buffer;
        self.ranges.capacity = new_capacity;
        return self.ranges.alloc(count).?;
    }

    fn free(self: *Pool, renderer: *Renderer, offset: u32, count: u32) void {
        self.ranges.free(renderer.gpa, offset, count);
        // Giving memory back is a saving, not a need: if it cannot be
        // done now, the pool stays as it is.
        self.trim(renderer) catch {};
    }

    /// Moves to a smaller buffer once no more than a quarter of this one
    /// is in use, measured to the last element: what lies free between
    /// elements stays where it is, so nothing that points into the pool
    /// has to change. The new buffer leaves as much room again as is in
    /// use, which keeps a model loaded and dropped in turn from moving
    /// the pool every time.
    fn trim(self: *Pool, renderer: *Renderer) !void {
        const capacity = self.ranges.capacity;
        if (capacity <= self.minimum or @as(u64, self.ranges.top) * 4 > capacity) return;
        const new_capacity = @max(self.minimum, self.ranges.top * 2);
        if (new_capacity >= capacity) return;
        const device = renderer.device;
        const new_buffer = try device.createBuffer(.{
            .name = self.name,
            .size = @as(u64, new_capacity) * self.stride,
            .usage = self.usage,
        });
        if (self.ranges.top != 0) {
            errdefer device.destroyBuffer(new_buffer);
            try device.queueBufferCopy(self.buffer, new_buffer, @as(u64, self.ranges.top) * self.stride);
        } else device.destroyBuffer(self.buffer);
        self.buffer = new_buffer;
        self.ranges.capacity = new_capacity;
    }

    fn write(self: *Pool, device: *rhi.Device, offset: u32, bytes: []const u8) !void {
        try device.uploadBuffer(self.buffer, @as(u64, offset) * self.stride, bytes);
    }
};

const arena_usage = rhi.BufferUsage{ .storage = true, .acceleration_input = true, .copy_src = true };

/// Bump allocator over a mapped buffer for data rewritten every frame.
pub const FrameArena = struct {
    buffer: rhi.Buffer,
    capacity: u64,
    cursor: u64 = 0,
    /// Buffers this arena outgrew since it was last reset. What was
    /// allocated from them earlier in the frame is still in use, so they
    /// are kept until `reset`.
    outgrown: [16]?rhi.Buffer = @splat(null),

    fn Allocation(comptime T: type) type {
        return struct {
            address: u64,
            items: []T,
            /// The buffer the allocation lives in and where: not always
            /// the arena's current buffer, which is replaced when it grows.
            buffer: rhi.Buffer,
            offset: u64,
        };
    }

    fn init(device: *rhi.Device, capacity: u64) !FrameArena {
        return .{
            .buffer = try device.createBuffer(.{ .name = "frame arena", .size = capacity, .usage = arena_usage, .memory = .cpu_to_gpu }),
            .capacity = capacity,
        };
    }

    /// Starts a new frame: everything allocated before is forgotten.
    fn reset(self: *FrameArena, device: *rhi.Device) void {
        self.cursor = 0;
        for (&self.outgrown) |*slot| {
            if (slot.*) |buffer| device.destroyBuffer(buffer);
            slot.* = null;
        }
    }

    fn deinit(self: *FrameArena, device: *rhi.Device) void {
        self.reset(device);
        device.destroyBuffer(self.buffer);
    }

    /// Room for `count` values of `T`, good until the arena is next reset:
    /// the mapped memory to fill and the address shaders find it at.
    pub fn alloc(self: *FrameArena, device: *rhi.Device, comptime T: type, count: usize) !Allocation(T) {
        const size = @sizeOf(T) * @max(count, 1);
        var offset = std.mem.alignForward(u64, self.cursor, 16);
        if (offset + size > self.capacity) {
            // Earlier allocations of this frame keep pointing into the old
            // buffer, which stays until the arena is reset.
            const capacity = @max(self.capacity * 2, size * 2);
            const buffer = try device.createBuffer(.{ .name = "frame arena", .size = capacity, .usage = arena_usage, .memory = .cpu_to_gpu });
            for (&self.outgrown) |*slot| {
                if (slot.* != null) continue;
                slot.* = self.buffer;
                break;
            } else {
                // More doublings in one frame than there are slots.
                device.destroyBuffer(buffer);
                return error.FrameArenaExhausted;
            }
            self.buffer = buffer;
            self.capacity = capacity;
            offset = 0;
        }
        self.cursor = offset + size;
        const bytes = device.mapped(self.buffer)[@intCast(offset)..][0..size];
        return .{
            .address = device.bufferAddress(self.buffer) + offset,
            .items = @as([*]T, @ptrCast(@alignCast(bytes.ptr)))[0..count],
            .buffer = self.buffer,
            .offset = offset,
        };
    }
};

// ------------------------------------------------------------------- assets

const ModelJob = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []u8,
    options: gltf.LoadOptions = .{},
    group: std.Io.Group = .init,
    done: std.atomic.Value(bool) = .init(false),
    model: ?gltf.Model = null,
    failure: ?anyerror = null,
};

fn runModelJob(job: *ModelJob) std.Io.Cancelable!void {
    if (gltf.load(job.gpa, job.io, job.path, job.options)) |model| {
        job.model = model;
    } else |err| {
        if (err == error.Canceled) return error.Canceled;
        job.failure = err;
    }
    job.done.store(true, .release);
}

/// One build of the standard shading pass: with or without reflection
/// targets, and with a set of optional features compiled in.
const ShadeVariant = struct {
    reflective: bool,
    features: u32,
    /// Null while it is still being compiled.
    pipeline: ?rhi.Pipeline = null,
    job: ?*ShadeVariantJob = null,
};

/// The compiling of one `ShadeVariant` on a worker thread.
pub const ShadeVariantJob = struct {
    device: *const rhi.Device,
    io: std.Io,
    reflective: bool,
    constants: [1]u32,
    group: std.Io.Group = .init,
    done: std.atomic.Value(bool) = .init(false),
    compiled: ?rhi.Device.CompiledPipeline = null,
    failure: ?anyerror = null,
};

/// The pipeline of a shading pass built with the features in `constants`.
pub fn shadeVariantDesc(device: *const rhi.Device, reflective: bool, constants: []const u32) rhi.GraphicsPipelineDesc {
    return .{
        .name = if (reflective) "shading (reflective, variant)" else "shading (variant)",
        .vertex = shaderCode("fullscreen.vert.spv"),
        .fragment = if (device.ray_tracing) shaderCode("shade_rt.frag.spv") else shaderCode("shade.frag.spv"),
        .color_targets = if (reflective) &shade_reflective_targets else &shade_plain_targets,
        .cull = .none,
        .fragment_constants = constants,
    };
}

/// Runs on a worker thread. Compiling touches nothing the render thread
/// changes (see `Device.compileGraphicsPipeline`), and the shader code it
/// reads is only replaced after every job has been waited for.
pub fn runShadeVariantJob(job: *ShadeVariantJob) std.Io.Cancelable!void {
    if (job.device.compileGraphicsPipeline(std.heap.smp_allocator, shadeVariantDesc(job.device, job.reflective, &job.constants))) |compiled| {
        job.compiled = compiled;
    } else |err| job.failure = err;
    job.done.store(true, .release);
}

const EnvironmentJob = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []u8,
    group: std.Io.Group = .init,
    done: std.atomic.Value(bool) = .init(false),
    image: ?gltf.HdrImage = null,
    /// A cube map read from a KTX2 file, instead of `image`.
    cube: ?ktx2.Texture = null,
    cube_brightest: ?Vec3 = null,
    failure: ?anyerror = null,
};

fn runEnvironmentJob(job: *EnvironmentJob) std.Io.Cancelable!void {
    if (loadEnvironmentFile(job)) |_| {} else |err| {
        if (err == error.Canceled) return error.Canceled;
        job.failure = err;
    }
    job.done.store(true, .release);
}

fn loadEnvironmentFile(job: *EnvironmentJob) !void {
    const bytes = try gltf.readFile(job.gpa, job.io, job.path);
    const is_cube = ktx2.isKtx2(bytes);
    if (!is_cube) {
        job.gpa.free(bytes);
        job.image = try gltf.loadHdr(job.gpa, job.io, job.path);
        return;
    }
    defer job.gpa.free(bytes);
    const cube = try ktx2.read(job.gpa, bytes);
    errdefer job.gpa.free(cube.data);
    if (cube.faces != 6 or cube.layers != 1) return error.NotACubeMap;
    if (cube.format != .rgba16f and cube.format != .bc6h) return error.UnsupportedTextureFormat;
    job.cube_brightest = if (cube.format == .rgba16f) brightestCubeDirection(cube) else null;
    job.cube = cube;
}

/// The direction toward the brightest texel of a half-float cube map's
/// largest level. Matches `cubeDirection` in the environment shaders.
fn brightestCubeDirection(cube: ktx2.Texture) Vec3 {
    const size: usize = cube.width;
    var best: f32 = -1;
    var best_direction: Vec3 = .{ 0, 1, 0 };
    for (0..6) |face| for (0..size) |y| for (0..size) |x| {
        const texel = cube.data[((face * size + y) * size + x) * 8 ..][0..6];
        var rgb: [3]f32 = undefined;
        for (&rgb, 0..) |*channel, index| channel.* = @as(f16, @bitCast(std.mem.readInt(u16, texel[index * 2 ..][0..2], .little)));
        const luminance = rgb[0] * 0.2126 + rgb[1] * 0.7152 + rgb[2] * 0.0722;
        if (!(luminance > best)) continue;
        best = luminance;
        const px = (@as(f32, @floatFromInt(x)) + 0.5) / @as(f32, @floatFromInt(size)) * 2 - 1;
        const py = (@as(f32, @floatFromInt(y)) + 0.5) / @as(f32, @floatFromInt(size)) * 2 - 1;
        best_direction = math.normalize(switch (face) {
            0 => Vec3{ 1, -py, -px },
            1 => Vec3{ -1, -py, px },
            2 => Vec3{ px, 1, py },
            3 => Vec3{ px, -1, -py },
            4 => Vec3{ px, -py, 1 },
            else => Vec3{ -px, -py, -1 },
        });
    };
    return best_direction;
}

/// Where one mesh of a loaded model lies in the shared geometry buffers.
pub const ModelMesh = struct {
    vertex_offset: u32,
    vertex_count: u32,
    skin_offset: ?u32,
    /// Morph target deltas: `morph_targets` runs of `vertex_count`.
    morph_offset: ?u32 = null,
    morph_targets: u32 = 0,
    index_offset: u32,
    index_count: u32,
    /// Indices of the full-detail level, which come first.
    lod0_index_count: u32 = 0,
    meshlet_offset: u32,
    meshlet_count: u32,
    material: u32,
    /// Uses alpha blending; drawn by the forward pass.
    blend: bool,
    /// Its tree in `bvh_nodes` and the triangles its leaves list in
    /// `bvh_items`, when one was built (`Options.path_tracing_fallback`).
    bvh_nodes: ?u32 = null,
    bvh_node_count: u32 = 0,
    bvh_items: u32 = 0,
    bvh_item_count: u32 = 0,
    /// The box of the tree's root, in the mesh's own space.
    bvh_min: [3]f32 = .{ 0, 0, 0 },
    bvh_max: [3]f32 = .{ 0, 0, 0 },
    /// How the mesh splits into a coarse part and the rest (from
    /// `gltf.Mesh`), and whether only the coarse part is in GPU memory
    /// now: the first `coarse_vertex_count` vertices, and the indices
    /// past the full-detail level's.
    coarse_vertex_count: u32 = 0,
    coarse_error: f32 = 0,
    coarse: bool = false,
    /// Ray-tracing structure for static (unskinned) meshes.
    blas: ?rhi.AccelerationStructure = null,
};

/// Application images to use as a material's textures (see
/// `Renderer.setMaterialTextures`). Null leaves the model's own texture,
/// or none, in place. Channels are read as glTF lays them out: roughness
/// in green and metallic in blue of `metallic_roughness`, occlusion in
/// red, coat strength in red, coat roughness in green, sheen roughness in
/// alpha.
pub const MaterialTextures = struct {
    base_color: ?Image = null,
    normal: ?Image = null,
    metallic_roughness: ?Image = null,
    occlusion: ?Image = null,
    emissive: ?Image = null,
    clearcoat: ?Image = null,
    clearcoat_roughness: ?Image = null,
    clearcoat_normal: ?Image = null,
    sheen_color: ?Image = null,
    sheen_roughness: ?Image = null,
};

const ModelEntry = struct {
    state: AssetState = .loading,
    job: ?*ModelJob = null,
    failure: ?anyerror = null,
    source: ?gltf.Model = null,
    textures: []?rhi.Texture = &.{},
    /// Parallel to `textures`; entries with data are streamed.
    streams: []TextureStream = &.{},
    streamed: u32 = 0,
    materials_stale: bool = false,
    /// Application images standing in for a material's textures
    /// (`setMaterialTextures`); empty, or one per material.
    material_images: []MaterialTextures = &.{},
    next_image: usize = 0,
    meshes: []ModelMesh = &.{},
    mesh_base: u32 = 0,
    material_base: u32 = 0,
    /// Where the per-texture coordinate transforms of this model's
    /// materials sit in the material buffer, for those that need them.
    transform_base: u32 = 0,
    transform_count: u32 = 0,
    /// Parents-before-children node order and rest-pose world matrices.
    order: []u32 = &.{},
    /// The part of `order` a posed entity needs: nodes that carry a mesh,
    /// the joints of the skins, and everything above those.
    pose_order: []u32 = &.{},
    node_world: []Mat4 = &.{},
    info: ModelInfo = std.mem.zeroes(ModelInfo),
    references: u32 = 0,
    /// Acceleration structures created but not yet built.
    blas_pending: bool = false,
    /// Whether the vertices and indices are in GPU memory (they leave it
    /// under geometry streaming); what is drawn with the model is left
    /// out of its scene while they are not.
    geometry_resident: bool = true,
    /// Some of its meshes hold only their coarse part (`ModelMesh.coarse`).
    geometry_coarse: bool = false,
    /// Something other than entities draws with the geometry (an
    /// emitter's particles), so it stays.
    geometry_pinned: bool = false,
    /// This frame's distance from the nearest camera to the nearest
    /// thing drawn with the model.
    stream_distance: f32 = 0,
};

const EnvironmentEntry = struct {
    state: AssetState = .loading,
    job: ?*EnvironmentJob = null,
    failure: ?anyerror = null,
    max_radiance: f32,
    sky: ?rhi.Texture = null,
    specular: ?rhi.Texture = null,
    irradiance: ?rhi.Texture = null,
    brightest_direction: Vec3 = .{ 0, 1, 0 },
    /// Set for computed skies; `sky_dirty` asks for a rebuild.
    sky_desc: ?SkyDesc = null,
    sky_dirty: bool = false,
    /// A rebuild under way: the next face to draw (0 when idle) and the
    /// description it is being drawn from.
    bake_step: u32 = 0,
    bake_desc: SkyDesc = .{},
    /// The cloud layer baked into the lighting cubes, and when.
    clouds: ?gpu.Clouds = null,
    cloud_bake_time: f32 = 0,
    /// For a loaded environment under clouds: the picture as loaded, and
    /// the sun the clouds in its lighting are lit by.
    clear: ?rhi.Texture = null,
    cloud_to_sun: Vec3 = .{ 0, 1, 0 },
    cloud_sunlight: Vec3 = .{ 0, 0, 0 },
};

const LayoutEntry = struct {
    entity: Entity,
    model_instance: u32,
    first_of_entity: bool,
};

/// Everything that belongs to one scene: its entities, lights and effects,
/// and the GPU buffers they are laid out in.
pub const SceneData = struct {
    /// Bounds (center, radius) of what moved this frame, for deciding
    /// which shadow tiles to redraw; `movers_overflow` if there were too
    /// many to list.
    movers: std.ArrayList([4]f32) = .empty,
    movers_overflow: bool = false,
    entities: std.ArrayList(Entity) = .empty,
    sun: Sun = .{},
    environment: ?Environment = null,
    environment_intensity: f32 = 1,
    lights: std.ArrayList(Light) = .empty,
    /// Bumped whenever the lights are replaced or moved.
    lights_version: u64 = 0,
    emitters: std.ArrayList(Emitter) = .empty,
    probes: std.ArrayList(ReflectionProbe) = .empty,
    fluids: std.ArrayList(Fluid) = .empty,
    waters: std.ArrayList(Water) = .empty,
    liquids: std.ArrayList(Liquid) = .empty,
    groups: std.ArrayList(InstanceGroup) = .empty,
    /// GPU instances that come from groups, and a counter bumped whenever
    /// their records must be rewritten.
    static_count: u32 = 0,
    static_version: u64 = 0,
    /// The groups' entries for the ray-tracing structure, and the state
    /// of the groups they were made from.
    static_tlas: std.ArrayList(rhi.AccelerationInstance) = .empty,
    static_tlas_version: u64 = std.math.maxInt(u64),
    static_tlas_base: usize = 0,
    /// A view drew this scene by path tracing without the GPU's ray
    /// tracing: the tree over its instances is kept up for the next
    /// frame.
    trace_wanted: bool = false,
    trace_ready: bool = false,
    /// Changes with what the tree holds; a picture gathered over
    /// frames starts over when it does.
    trace_hash: u64 = 0,
    trace_nodes: ?rhi.Buffer = null,
    trace_nodes_capacity: u32 = 0,
    trace_instances: ?rhi.Buffer = null,
    trace_instances_capacity: u32 = 0,
    instance_slots: [rhi.frames_in_flight]InstanceSlot = @splat(.{}),
    decals: std.ArrayList(DecalDesc) = .empty,
    /// Some transparent surface in view of the layout refracts.
    transmissive: bool = false,
    /// GPU instance indices of blended geometry, drawn in the forward pass.
    transparent: std.ArrayList(TransparentDraw) = .empty,
    /// The blended meshes of instance groups, worked out when the groups
    /// change and added to `transparent` every frame.
    static_transparent: std.ArrayList(TransparentDraw) = .empty,
    static_transmissive: bool = false,
    /// Flattened (entity, model instance) list; index = GPU instance index.
    layout: std.ArrayList(LayoutEntry) = .empty,
    layout_dirty: bool = true,
    layout_generation: u64 = 0,
    refs: ?rhi.Buffer = null,
    refs_capacity: u32 = 0,
    /// Per instance, whether a camera drew any part of it this frame, and
    /// the copies of it the CPU reads a few frames later (kept only when
    /// texture streaming skips what is hidden).
    seen: ?rhi.Buffer = null,
    seen_capacity: u32 = 0,
    seen_readback: [rhi.frames_in_flight]?rhi.Buffer = @splat(null),
    seen_tags: [rhi.frames_in_flight]SeenTag = @splat(.{}),
    /// Meshlet bounds of the scene's deformed meshes, rewritten on the GPU
    /// every frame (`Options.skinned_meshlet_bounds`).
    skin_bounds: ?rhi.Buffer = null,
    skin_bounds_capacity: u32 = 0,
    /// Bumped whenever meshlet references are renumbered.
    layout_version: u64 = 0,
    /// Renderer frame the per-frame data below was written for; a scene
    /// shown by several views is prepared once.
    prepared_frame: u64 = std.math.maxInt(u64),
    prepared: SceneFrame = undefined,
    gi_frame: u64 = std.math.maxInt(u64),
    gi_updated_frame: u64 = std.math.maxInt(u64),
    ref_count: u32 = 0,
    joint_count: u32 = 0,
    triangle_count: u64 = 0,
    tlas: ?rhi.AccelerationStructure = null,
    tlas_capacity: u32 = 0,
    /// Hash of the instance list the TLAS was last built from.
    tlas_hash: u64 = 0,
    gi: ?GiVolume = null,
    /// Coarse grid over the whole scene, present while the main one
    /// follows the camera.
    gi_coarse: ?GiVolume = null,
    /// Between the two, for worlds so large that the coarse grid's probes
    /// are very far apart: follows the camera like the main grid, at a
    /// spacing between theirs.
    gi_middle: ?GiVolume = null,
    /// Explicit probe volume; null derives it from the static geometry.
    gi_bounds: ?[2]Vec3 = null,
    /// Where this scene's zero is in the application's world; see
    /// `shiftScene`.
    origin: [3]f64 = .{ 0, 0, 0 },
    clouds: ?CloudDesc = null,
    /// How far the wind has carried the clouds, and when that was last
    /// brought up to date.
    cloud_drift: [3]f64 = .{ 0, 0, 0 },
    cloud_time: f32 = 0,
    /// The lightning flash under way: when it began and where.
    flash_start: f32 = -1000,
    flash_position: [3]f64 = .{ 0, 0, 0 },
    flash_brightness: f32 = 0,
    flash_checked: f32 = -1,
};

const no_skin = std.math.maxInt(u32);

const EntityData = struct {
    scene: Scene,
    /// Met by rays only: it is in the ray-tracing structure and has an
    /// instance record, and is never drawn.
    rays_only: bool = false,
    model: Model,
    transform: Mat4,
    previous_transform: Mat4,
    visible: bool,
    /// World units moved since the previous frame.
    travelled: f32 = 0,
    tint: u32 = 0xffffffff,
    params: [4]f32 = .{ 0, 0, 0, 0 },
    receive_decals: bool = true,
    pose: ?Pose = null,
    /// Morph target weights set by hand, replacing the animation's.
    morph_weights: ?[gltf.max_morph_targets]f32 = null,
    /// Allocated once the model is ready, and only for models that animate.
    node_world: []Mat4 = &.{},
    previous_node_world: []Mat4 = &.{},
    /// Per model instance: base of its 2x vertex range for skinned output.
    skin_offsets: []u32 = &.{},
    /// Set to the current round of texture streaming when a camera was
    /// found to have drawn this entity.
    seen_round: u64 = 0,
    /// Where the entity's instances start in the scene's layout, as of
    /// that round.
    seen_first: u32 = 0,
    /// Per model instance: the deformed mesh's own acceleration structure,
    /// rebuilt each frame, for instances that are skinned or morphed.
    skin_blas: []?rhi.AccelerationStructure = &.{},
    /// Per model instance: where its meshlet bounds are this frame, or
    /// `gpu.invalid_id`.
    bounds_offsets: []u32 = &.{},
    /// Where the posed skeleton is, in model space: center and radius
    /// (with some room for the skin around the bones). Instance groups
    /// that follow this entity's pose are culled by it.
    skin_bounds: [4]f32 = .{ 0, 0, 0, 0 },
    /// Frames this entity has been skinned for; 0 means no valid history.
    history_frames: u32 = 0,
    resolved: bool = false,
};

/// One see-through mesh of a scene, as the transparency pass draws it.
pub const TransparentDraw = struct {
    instance: u32,
    first_index: u32,
    index_count: u32,
    /// World-space center, for back-to-front sorting.
    center: Vec3,
    depth: f32 = 0,
    /// Bends what is seen through it, so it reads the picture behind.
    transmissive: bool = false,
};

const BlasJob = struct { blas: rhi.AccelerationStructure, vertex_offset: u32, mesh: ModelMesh };
/// `BoundsJob` in skin_bounds.comp: one deformed mesh to take the meshlet
/// bounds of.
pub const BoundsJob = extern struct {
    vertex_offset: u32,
    meshlet_offset: u32,
    meshlet_count: u32,
    bounds_offset: u32,
    first_group: u32 = 0,
    pad: [3]u32 = .{ 0, 0, 0 },
};

/// `SkinJob` in skin.comp: one mesh to deform.
pub const SkinJob = extern struct {
    source_offset: u32,
    destination_offset: u32,
    skin_offset: u32,
    joint_offset: u32,
    vertex_count: u32,
    /// First delta of the mesh's first morph target, and how many targets.
    morph_offset: u32 = 0,
    target_count: u32 = 0,
    /// The first work group of the batched dispatch that is this job's.
    first_group: u32 = 0,
    /// Where this job's target weights start in the frame's weight list.
    weights_offset: u32 = 0,
    pad: [3]u32 = .{ 0, 0, 0 },
};

comptime {
    std.debug.assert(@sizeOf(SkinJob) == 48);
}

// ----------------------------------------------------------- render targets

/// The render targets of one view at one resolution. Made again when the
/// size or the resolutions of the effects change.
pub const ViewState = struct {
    width: u32,
    height: u32,
    depth: rhi.Texture,
    visibility: rhi.Texture,
    motion: rhi.Texture,
    ao_raw: rhi.Texture,
    /// Half-resolution linear depth with mips, sampled by the AO pass.
    ao_depth: rhi.Texture,
    ao: rhi.Texture,
    hdr: rhi.Texture,
    fog: rhi.Texture,
    history: [2]rhi.Texture,
    /// Depth pyramid for occlusion culling (power-of-two, full mip chain).
    hiz: rhi.Texture,
    hiz_width: u32,
    hiz_height: u32,
    hiz_mips: u32,
    bloom: [bloom_levels]rhi.Texture,
    history_valid: bool = false,
    /// Last frame's filtered ambient occlusion, and whether it is usable.
    ao_history: rhi.Texture,
    ao_history_valid: bool = false,
    /// Light gathered from nearby occluders (see `Settings.ao_bounce`):
    /// as sampled, filtered, and last frame's.
    bounce_raw: rhi.Texture,
    bounce: rhi.Texture,
    bounce_history: rhi.Texture,
    bounce_history_valid: bool = false,
    /// Resolutions the reduced-rate targets were created for.
    scales: EffectScales,
    /// Probe irradiance gathered below full resolution; null at full rate,
    /// where the shading pass evaluates the probes itself.
    gi_gather: ?rhi.Texture,
    /// Targets of order-independent transparency; null in sorted mode.
    oit: ?OitTargets,
    /// Targets of depth-peeled transparency; null in the other modes.
    peel: ?PeelTargets,
    /// The scene before transparent surfaces, for refraction; null when
    /// nothing in the scene is transmissive.
    scene_copy: ?rhi.Texture,
    /// Where a liquid's surface is put together: the nearest depth of its
    /// particles, how much liquid each pixel looks through, and the
    /// smoothed distance in two copies that take turns.
    liquid: ?LiquidTargets = null,
    /// The picture at output resolution, when the scene is rendered at
    /// another one.
    upscaled: ?rhi.Texture,
    /// Targets of depth of field and motion blur; null while both are off.
    lens: ?[2]rhi.Texture,
    dof_reduced: ?rhi.Texture = null,
    /// Smoke and fire, before they are laid over the scene; null while
    /// the scene has no fluids.
    fluid: ?rhi.Texture,
    /// The smoke's own screen motion and cover, at the fluid pass's size.
    fluid_motion: ?rhi.Texture = null,
    /// Clouds this frame and last; null while the scene has none.
    clouds: ?CloudTargets,
    /// Targets of the reflection pass; null while reflections are off.
    reflections: ?ReflectionTargets,

    fn init(device: *rhi.Device, width: u32, height: u32, scales: EffectScales) !ViewState {
        const color = rhi.TextureUsage{ .sampled = true, .color_attachment = true };
        var self: ViewState = undefined;
        self.width = width;
        self.height = height;
        self.history_valid = false;
        self.scales = scales;
        self.peel = if (!scales.peel) null else .{
            .layer = try device.createTexture(.{ .name = "peel layer", .width = width, .height = height, .format = hdr_format, .usage = color }),
            .accumulation = try device.createTexture(.{ .name = "peel accumulation", .width = width, .height = height, .format = hdr_format, .usage = color }),
            .depth = .{
                try device.createTexture(.{ .name = "peel depth", .width = width, .height = height, .format = .depth32_float, .usage = .{ .sampled = true, .depth_attachment = true } }),
                try device.createTexture(.{ .name = "peel depth", .width = width, .height = height, .format = .depth32_float, .usage = .{ .sampled = true, .depth_attachment = true } }),
            },
        };
        self.oit = if (!scales.oit) null else .{
            .accumulation = try device.createTexture(.{ .name = "transparency accumulation", .width = width, .height = height, .format = hdr_format, .usage = color }),
            .reveal = try device.createTexture(.{ .name = "transparency reveal", .width = width, .height = height, .format = .r8_unorm, .usage = color }),
        };
        // The size antialiasing resolves to, and the lens passes after it work at.
        const resolved_width = if (scales.temporal_upscale) scales.output_width else width;
        const resolved_height = if (scales.temporal_upscale) scales.output_height else height;
        self.upscaled = if (scales.temporal_upscale or (scales.output_width == width and scales.output_height == height)) null else try device.createTexture(.{ .name = "upscaled", .width = scales.output_width, .height = scales.output_height, .format = hdr_format, .usage = color });
        self.scene_copy = if (!scales.refraction) null else try device.createTexture(.{ .name = "scene behind glass", .width = width, .height = height, .format = hdr_format, .usage = color });
        self.liquid = if (!scales.liquid) null else .{
            .depth = try device.createTexture(.{ .name = "liquid depth", .width = width, .height = height, .format = .depth32_float, .usage = .{ .sampled = true, .depth_attachment = true } }),
            .thickness = try device.createTexture(.{ .name = "liquid thickness", .width = width, .height = height, .format = .r16_float, .usage = color }),
            .smooth = .{
                try device.createTexture(.{ .name = "liquid surface", .width = width, .height = height, .format = .r32_float, .usage = color }),
                try device.createTexture(.{ .name = "liquid surface", .width = width, .height = height, .format = .r32_float, .usage = color }),
            },
        };
        self.dof_reduced = if (scales.dof) |scale| try device.createTexture(.{ .name = "depth of field (reduced)", .width = scale.extent(resolved_width), .height = scale.extent(resolved_height), .format = hdr_format, .usage = color }) else null;
        self.lens = if (!scales.lens) null else .{
            try device.createTexture(.{ .name = "depth of field", .width = resolved_width, .height = resolved_height, .format = hdr_format, .usage = color }),
            try device.createTexture(.{ .name = "motion blur", .width = resolved_width, .height = resolved_height, .format = hdr_format, .usage = color }),
        };
        self.fluid = if (scales.fluid) |scale| try device.createTexture(.{ .name = "fluids", .width = scale.extent(width), .height = scale.extent(height), .format = hdr_format, .usage = color }) else null;
        self.fluid_motion = if (scales.fluid) |scale| try device.createTexture(.{ .name = "fluid motion", .width = scale.extent(width), .height = scale.extent(height), .format = .rgba16_float, .usage = color }) else null;
        self.clouds = if (scales.clouds) |scale| .{
            .current = try device.createTexture(.{ .name = "clouds", .width = scale.extent(width), .height = scale.extent(height), .format = hdr_format, .usage = color }),
            .history = try device.createTexture(.{ .name = "clouds (history)", .width = scale.extent(width), .height = scale.extent(height), .format = hdr_format, .usage = color }),
        } else null;
        self.reflections = if (scales.reflections) |scale| .{
            .weight = try device.createTexture(.{ .name = "reflection weight", .width = width, .height = height, .format = hdr_format, .usage = color }),
            .surface = try device.createTexture(.{ .name = "reflection surface", .width = width, .height = height, .format = hdr_format, .usage = color }),
            .traced = try device.createTexture(.{ .name = "reflections", .width = scale.extent(width), .height = scale.extent(height), .format = hdr_format, .usage = color }),
            .history = try device.createTexture(.{ .name = "reflections (history)", .width = scale.extent(width), .height = scale.extent(height), .format = hdr_format, .usage = color }),
        } else null;
        self.gi_gather = if (scales.gi == .full) null else try device.createTexture(.{
            .name = "gi gather",
            .width = scales.gi.extent(width),
            .height = scales.gi.extent(height),
            .format = hdr_format,
            .usage = color,
        });
        self.depth = try device.createTexture(.{ .name = "depth", .width = width, .height = height, .format = .depth32_float, .usage = .{ .sampled = true, .depth_attachment = true } });
        self.visibility = try device.createTexture(.{ .name = "visibility", .width = width, .height = height, .format = .r32_uint, .usage = color });
        self.motion = try device.createTexture(.{ .name = "motion", .width = width, .height = height, .format = .rg16_float, .usage = color });
        self.ao_raw = try device.createTexture(.{ .name = "ao raw", .width = scales.ao.extent(width), .height = scales.ao.extent(height), .format = .rg16_float, .usage = color });
        self.ao = try device.createTexture(.{ .name = "ao", .width = width, .height = height, .format = .r16_float, .usage = color });
        self.ao_history = try device.createTexture(.{ .name = "ao history", .width = width, .height = height, .format = .r16_float, .usage = color });
        self.ao_history_valid = false;
        self.bounce_raw = try device.createTexture(.{ .name = "bounce raw", .width = scales.ao.extent(width), .height = scales.ao.extent(height), .format = .rgba16_float, .usage = color });
        self.bounce = try device.createTexture(.{ .name = "bounce", .width = width, .height = height, .format = .rgba16_float, .usage = color });
        self.bounce_history = try device.createTexture(.{ .name = "bounce history", .width = width, .height = height, .format = .rgba16_float, .usage = color });
        self.bounce_history_valid = false;
        self.ao_depth = try device.createTexture(.{
            .name = "ao depth",
            .width = scales.ao.extent(width),
            .height = scales.ao.extent(height),
            .format = .r16_float,
            .usage = color,
            .mip_levels = @min(ao_depth_mips, rhi.TextureDesc.fullMipCount(scales.ao.extent(width), scales.ao.extent(height))),
        });
        self.hdr = try device.createTexture(.{ .name = "hdr", .width = width, .height = height, .format = hdr_format, .usage = color });
        self.hiz_width = std.math.floorPowerOfTwo(u32, @max(width, 2));
        self.hiz_height = std.math.floorPowerOfTwo(u32, @max(height, 2));
        self.hiz_mips = rhi.TextureDesc.fullMipCount(self.hiz_width, self.hiz_height);
        self.hiz = try device.createTexture(.{
            .name = "depth pyramid",
            .width = self.hiz_width,
            .height = self.hiz_height,
            .format = .r32_float,
            .usage = color,
            .mip_levels = self.hiz_mips,
        });
        self.fog = try device.createTexture(.{ .name = "fog", .width = scales.fog.extent(width), .height = scales.fog.extent(height), .format = hdr_format, .usage = color });
        for (&self.history) |*texture| {
            texture.* = try device.createTexture(.{ .name = "taa history", .width = resolved_width, .height = resolved_height, .format = hdr_format, .usage = color });
        }
        for (&self.bloom, 0..) |*texture, level| {
            texture.* = try device.createTexture(.{
                .name = "bloom",
                .width = @max(width >> @intCast(level + 1), 1),
                .height = @max(height >> @intCast(level + 1), 1),
                .format = bloom_format,
                .usage = color,
            });
        }
        return self;
    }

    fn deinit(self: *ViewState, device: *rhi.Device) void {
        for ([_]rhi.Texture{ self.depth, self.visibility, self.motion, self.ao_raw, self.ao, self.ao_history, self.bounce_raw, self.bounce, self.bounce_history, self.ao_depth, self.hdr, self.fog, self.hiz }) |texture|
            device.destroyTexture(texture);
        for (self.history) |texture| device.destroyTexture(texture);
        if (self.gi_gather) |texture| device.destroyTexture(texture);
        if (self.lens) |lens| for (lens) |texture| device.destroyTexture(texture);
        if (self.dof_reduced) |texture| device.destroyTexture(texture);
        if (self.oit) |oit| {
            device.destroyTexture(oit.accumulation);
            device.destroyTexture(oit.reveal);
        }
        if (self.scene_copy) |texture| device.destroyTexture(texture);
        if (self.liquid) |targets| {
            device.destroyTexture(targets.depth);
            device.destroyTexture(targets.thickness);
            for (targets.smooth) |texture| device.destroyTexture(texture);
        }
        if (self.peel) |peel| for ([_]rhi.Texture{ peel.layer, peel.accumulation, peel.depth[0], peel.depth[1] }) |texture| device.destroyTexture(texture);
        if (self.upscaled) |texture| device.destroyTexture(texture);
        if (self.reflections) |targets| for ([_]rhi.Texture{ targets.weight, targets.surface, targets.traced, targets.history }) |texture| device.destroyTexture(texture);
        if (self.clouds) |targets| for ([_]rhi.Texture{ targets.current, targets.history }) |texture| device.destroyTexture(texture);
        if (self.fluid) |texture| device.destroyTexture(texture);
        if (self.fluid_motion) |texture| device.destroyTexture(texture);
        for (self.bloom) |texture| device.destroyTexture(texture);
    }
};

/// Everything that belongs to one camera rather than to a scene or to the
/// renderer: its render targets and whatever it carries from frame to frame.
pub const ViewData = struct {
    state: ?ViewState = null,
    /// Display-referred picture of a view drawn into part of a target;
    /// copied into place once its draw lists are done.
    output: ?rhi.Texture = null,
    output_format: rhi.Format = undefined,
    exposure: rhi.Buffer,
    exposure_reset: bool = true,
    previous_view_proj: Mat4 = math.identity,
    /// The scene origin `previous_view_proj` was made under.
    scene_origin: [3]f64 = .{ 0, 0, 0 },
    previous_jitter: [2]f32 = .{ 0, 0 },
    /// Frames this view has rendered; drives jitter and history swaps.
    frames: u64 = 0,
    /// Renderer frame this view was last drawn in.
    last_frame: u64 = std.math.maxInt(u64),
    /// Sun shadow cascades, created the first time the view needs them.
    shadow_map: ?rhi.Texture = null,
    /// What see-through casters do to the sunlight, per cascade.
    shadow_color: ?rhi.Texture = null,
    shadows_colored: bool = false,
    cascade_cache: CascadeCache = .{},
    /// Path tracing: the average of the frames gathered so far, how
    /// many they are, and what they were gathered of (see
    /// `Settings.path_tracing`).
    path_accum: ?rhi.Texture = null,
    /// The color of what each pixel shows, gathered alongside, and the
    /// picture between the two runs of the pass that clears its grain.
    path_guide: ?rhi.Texture = null,
    path_filtered: ?rhi.Texture = null,
    /// Last frame's gathered picture and guide: each pixel looks up in
    /// them where its surface was, so that the picture survives the
    /// camera moving. And the camera they were gathered from.
    path_accum_old: ?rhi.Texture = null,
    path_guide_old: ?rhi.Texture = null,
    path_camera: Camera = .{},
    path_size: [2]u32 = .{ 0, 0 },
    path_gathered: u32 = 0,
    path_key: u64 = 0,
    /// One word per meshlet reference: was it visible last frame.
    visibility: ?rhi.Buffer = null,
    visibility_capacity: u32 = 0,
    visibility_scene: ?Scene = null,
    visibility_layout: u64 = 0,

    fn deinit(self: *ViewData, device: *rhi.Device) void {
        if (self.state) |*state| state.deinit(device);
        if (self.output) |texture| device.destroyTexture(texture);
        if (self.shadow_map) |texture| device.destroyTexture(texture);
        if (self.shadow_color) |texture| device.destroyTexture(texture);
        if (self.path_accum) |texture| device.destroyTexture(texture);
        if (self.path_guide) |texture| device.destroyTexture(texture);
        if (self.path_filtered) |texture| device.destroyTexture(texture);
        if (self.path_accum_old) |texture| device.destroyTexture(texture);
        if (self.path_guide_old) |texture| device.destroyTexture(texture);
        if (self.visibility) |buffer| device.destroyBuffer(buffer);
        device.destroyBuffer(self.exposure);
    }
};

/// Where a view's tone-mapped picture and draw lists go.
const Output = struct {
    texture: rhi.Texture,
    format: rhi.Format,
    region: Region,
    load: rhi.LoadOp,
    clear: [4]f32,
    /// Scene depth for world-space draw list items; null without a scene.
    depth: ?rhi.Texture = null,
};

const Pipelines = struct {
    skin: rhi.Pipeline,
    cull: rhi.Pipeline,
    cluster: rhi.Pipeline,
    local_shadow: rhi.Pipeline,
    local_shadow_masked: rhi.Pipeline,
    forward: rhi.Pipeline,
    forward_weighted: ?rhi.Pipeline,
    oit_composite: rhi.Pipeline,
    forward_peel: ?rhi.Pipeline,
    peel_under: rhi.Pipeline,
    peel_composite: rhi.Pipeline,
    copy: rhi.Pipeline,
    upscale: rhi.Pipeline,
    hiz: rhi.Pipeline,
    visibility: rhi.Pipeline,
    visibility_masked: rhi.Pipeline,
    shadow: rhi.Pipeline,
    shadow_masked: rhi.Pipeline,
    shadow_color: rhi.Pipeline,
    gtao: rhi.Pipeline,
    gtao_bounce_denoise: rhi.Pipeline,
    ao_depth: rhi.Pipeline,
    gi_gather: rhi.Pipeline,
    gtao_denoise: rhi.Pipeline,
    /// Shading without the reflection outputs; made on first use, since
    /// views with reflections on (the default) never need it.
    shade: ?rhi.Pipeline,
    shade_reflective: rhi.Pipeline,
    ssr: rhi.Pipeline,
    /// The reflection pass with ray queries; the plain one again on a
    /// device without ray tracing.
    ssr_traced: rhi.Pipeline,
    ssr_composite: rhi.Pipeline,
    cloud_noise: rhi.Pipeline,
    cloud: rhi.Pipeline,
    cloud_composite: rhi.Pipeline,
    fluid_advect: rhi.Pipeline,
    fluid_curl: rhi.Pipeline,
    fluid_force: rhi.Pipeline,
    fluid_divergence: rhi.Pipeline,
    fluid_pressure: rhi.Pipeline,
    fluid_project: rhi.Pipeline,
    fluid_present: rhi.Pipeline,
    water_sim: rhi.Pipeline,
    water: rhi.Pipeline,
    underwater: rhi.Pipeline,
    water_depth: rhi.Pipeline,
    liquid_sim: rhi.Pipeline,
    liquid_depth: rhi.Pipeline,
    liquid_shadow: rhi.Pipeline,
    liquid_surface: rhi.Pipeline,
    path_trace: rhi.Pipeline,
    path_denoise: rhi.Pipeline,
    path_denoise_final: rhi.Pipeline,
    liquid_thickness: rhi.Pipeline,
    liquid_blur: rhi.Pipeline,
    liquid: rhi.Pipeline,
    fluid_light: rhi.Pipeline,
    fluid_solid: rhi.Pipeline,
    fluid_solid_traced: rhi.Pipeline,
    fluid_carry: rhi.Pipeline,
    fluid: rhi.Pipeline,
    dof: rhi.Pipeline,
    dof_composite: rhi.Pipeline,
    motion_blur: rhi.Pipeline,
    fog: rhi.Pipeline,
    fog_composite: rhi.Pipeline,
    taa: rhi.Pipeline,
    bloom_down: rhi.Pipeline,
    bloom_up: rhi.Pipeline,
    exposure: rhi.Pipeline,
    pick: rhi.Pipeline,
    particle_sim: rhi.Pipeline,
    particle_sort_keys: rhi.Pipeline,
    particle_sort: rhi.Pipeline,
    particles: rhi.Pipeline,
    particle_mesh: rhi.Pipeline,
    probe_face: rhi.Pipeline,
    fluid_motion: rhi.Pipeline,
    skin_bounds: rhi.Pipeline,
    particle_trails: rhi.Pipeline,
    env_cube: rhi.Pipeline,
    env_sky: rhi.Pipeline,
    env_irradiance: rhi.Pipeline,
    env_prefilter: rhi.Pipeline,
    brdf_lut: rhi.Pipeline,
};

/// Pipelines that need ray queries; absent on hardware without them.
const GiPipelines = struct {
    trace: rhi.Pipeline,
    irradiance: rhi.Pipeline,
    clamp_upper: rhi.Pipeline,
    clamp_lower: rhi.Pipeline,
    relocate: rhi.Pipeline,
    visibility: rhi.Pipeline,
};

/// A grid of irradiance probes covering the scene's static geometry.
pub const GiVolume = struct {
    origin: Vec3,
    /// The origin in whole grid cells, and how far it moved this frame.
    cell: [3]i32 = .{ 0, 0, 0 },
    shift: [3]i32 = .{ 0, 0, 0 },
    spacing: f32,
    counts: [3]u32,
    rays_per_probe: u32,
    /// What shading reads: a slow, steady average of the probe rays.
    irradiance: rhi.Texture,
    /// A quick average of the same rays; it is noisy but shows within a
    /// few frames when the lighting really changed.
    irradiance_fast: rhi.Texture,
    visibility: rhi.Texture,
    rays: rhi.Buffer,
    /// Where probes have been moved to get them out of walls: a texel per
    /// probe, in two textures that take turns being read and written.
    offsets: [2]rhi.Texture,
    offset_turn: u32 = 0,
    /// Whether `offsets` holds anything yet.
    offsets_valid: bool = false,
    /// Updates since creation; drives how quickly new data replaces old.
    frames: u32 = 0,

    /// How many probes the grid holds.
    pub fn probeCount(self: GiVolume) u32 {
        return self.counts[0] * self.counts[1] * self.counts[2];
    }

    pub fn deinit(self: GiVolume, device: *rhi.Device) void {
        device.destroyTexture(self.irradiance);
        device.destroyTexture(self.irradiance_fast);
        device.destroyTexture(self.visibility);
        device.destroyBuffer(self.rays);
        for (self.offsets) |texture| device.destroyTexture(texture);
    }
};

/// Texels along each side of one probe's square of irradiance.
pub const gi_irradiance_texels = 8;
/// Texels along each side of one probe's square of visibility.
pub const gi_visibility_texels = 16;
/// Upper bound on `Options.gi_max_probes`: the scroll offset has 10 bits.
pub const gi_probe_limit = 256;

const TonemapPipeline = struct { format: rhi.Format, pipeline: rhi.Pipeline };
const PickRequest = struct { view: View, pixel: [2]u32 };
/// A view's targets for screen-space reflections.
pub const ReflectionTargets = struct {
    /// Mirror weight (rgb) and roughness (a) of every surface.
    weight: rhi.Texture,
    /// Shading normal (octahedral, rg) and sky visibility (b).
    surface: rhi.Texture,
    /// What the trace found (rgb) and how sure it is (a), and the same
    /// from the frame before.
    traced: rhi.Texture,
    history: rhi.Texture,
    history_valid: bool = false,
};
const CloudTargets = struct { current: rhi.Texture, history: rhi.Texture, history_valid: bool = false };
/// Size of the noise volume that clouds are shaped by.
pub const cloud_noise_size = [3]i32{ 128, 128, 64 };
/// The volume is kept as a sheet of slices, this many to a row.
pub const cloud_noise_tiles = 8;
const MaterialPipelines = struct { plain: rhi.Pipeline, reflective: rhi.Pipeline };
/// The 2x2 matrix (by rows) of a coordinate transform: scale, then rotate.
fn uvMatrix(scale: [2]f32, rotation: f32) [4]f32 {
    return .{
        @cos(rotation) * scale[0],  @sin(rotation) * scale[1],
        -@sin(rotation) * scale[0], @cos(rotation) * scale[1],
    };
}

/// Slot of a material's per-texture transforms, if it has any.
fn transformSlot(entry: *const ModelEntry, index: usize) u32 {
    const materials = (entry.source orelse return gpu.invalid_id).materials;
    if (entry.transform_count == 0 or index >= materials.len or !materials[index].hasOwnTransforms()) return gpu.invalid_id;
    var before: u32 = 0;
    for (materials[0..index]) |material| {
        if (material.hasOwnTransforms()) before += 1;
    }
    return entry.transform_base + before * gpu.texture_transform_slots;
}

fn uvSetBit(reference: ?gltf.TextureRef, bit: u5) u32 {
    return if (reference) |ref| @as(u32, ref.uv_set & 1) << bit else 0;
}

/// A color as the instance records hold it: 8 bits a channel, opaque.
pub fn packTint(color: [3]f32) u32 {
    var packed_color: u32 = 0xff000000;
    inline for (0..3) |channel| packed_color |= @as(u32, @intFromFloat(std.math.clamp(color[channel], 0, 1) * 255 + 0.5)) << (channel * 8);
    return packed_color;
}

/// Most fluids a view marches at once.
pub const max_fluids = 8;
const max_pose_threads = 8;
/// Animated entities per thread below which splitting the work does not pay.
const pose_batch = 48;
const max_liquids = 4;
/// Particles a grid cell can list. A cell at rest holds eight; one that
/// cannot list all it holds would hide how crowded it is, and the liquid
/// would let itself be squashed flat there.
pub const liquid_cell_slots = 48;

const LiquidTargets = struct {
    depth: rhi.Texture,
    thickness: rhi.Texture,
    smooth: [2]rhi.Texture,
};

const LiquidState = struct {
    scene: Scene,
    /// Time the simulation has not stepped through yet; see `steadyStep`.
    time_owed: f32 = 0,
    /// An entity only rays meet, standing in for the liquid in ray-traced
    /// reflections: a box as large as the liquid there is.
    proxy: ?Entity = null,
    desc: LiquidDesc,
    /// The description's jets, kept here: the caller's slice need not
    /// outlive the call.
    sources: [4]LiquidSource = undefined,
    source_count: u32 = 0,
    capacity: u32,
    particles: rhi.Buffer,
    /// Per grid cell, how many particles it lists, and the lists.
    counts: rhi.Buffer,
    cells: rhi.Buffer,
    /// The records of a frame's steps, in GPU memory.
    params_buffer: rhi.Buffer,
    cell_count: u32,
    grid: [3]i32,
    /// Particles in use.
    live: u32 = 0,
    /// The block the liquid starts as.
    block: [3]u32,
    started: bool = false,
    /// Births owed by each jet: the fractions of a particle left over.
    owed: [4]f32 = @splat(0),
    /// This frame's record on the GPU, for the passes that draw it.
    params: u64 = 0,
    params_frame: u64 = std.math.maxInt(u64),

    fn deinit(self: *LiquidState, device: *rhi.Device) void {
        device.destroyBuffer(self.particles);
        device.destroyBuffer(self.counts);
        device.destroyBuffer(self.cells);
        device.destroyBuffer(self.params_buffer);
    }

    fn setSources(self: *LiquidState, sources: []const LiquidSource) void {
        self.source_count = @intCast(@min(sources.len, self.sources.len));
        @memcpy(self.sources[0..self.source_count], sources[0..self.source_count]);
        self.desc.sources = &.{};
    }
};

const max_waters = 8;
/// Quads along each side of the grid a water surface is drawn with.
pub const water_quads = 160;
const WaterState = struct {
    scene: Scene,
    desc: WaterDesc,
    size: [2]u32 = .{ 0, 0 },
    /// Height and its rate of change; the two alternate, `current` is newer.
    state: [2]rhi.Texture = undefined,
    current: u32 = 0,
    cleared: bool = false,
    /// The emitter its spray comes from, while `WaterDesc.splashes` asks
    /// for any.
    splash: ?Emitter = null,
    /// The hardest of the dents asked for with `addRipple` since the last
    /// step, for the spray.
    hit_strength: f32 = 0,
    hit_at: Vec3 = .{ 0, 0, 0 },
    hit_radius: f32 = 0,
    /// Disturbances waiting for the next step.
    ripples: [gpu.max_water_ripples]gpu.WaterRipple = @splat(.{}),
    ripple_count: u32 = 0,
    /// Fractional raindrops carried to the next frame.
    rain_pending: f32 = 0,
    /// Time the simulation has not stepped through yet: frames too short
    /// to step by are saved up (see `steadyStep`).
    time_owed: f32 = 0,
    params: u64 = 0,
    params_frame: u64 = std.math.maxInt(u64),
};
const FluidState = struct {
    /// Time the simulation has not stepped through yet; see `steadyStep`.
    time_owed: f32 = 0,
    scene: Scene,
    desc: FluidDesc,
    sources: [gpu.max_fluid_sources]FluidSource = @splat(.{}),
    source_count: u32 = 0,
    obstacles: [gpu.max_fluid_obstacles]FluidObstacle = undefined,
    obstacle_count: u32 = 0,
    size: [3]u32 = .{ 0, 0, 0 },
    tiles_x: u32 = 1,
    /// Each a sheet of slices. Velocity and the scalars (smoke, heat,
    /// fuel) alternate between two textures; `current` is the newer.
    velocity: [2]rhi.Texture = undefined,
    scalars: [2]rhi.Texture = undefined,
    pressure: [2]rhi.Texture = undefined,
    divergence: rhi.Texture = undefined,
    curl: rhi.Texture = undefined,
    /// 1 in the cells inside an obstacle.
    solid: rhi.Texture = undefined,
    /// The advection's first guess at the scalars.
    carried: rhi.Texture = undefined,
    /// And at the velocity, when `sharp_velocity` is on.
    carried_velocity: rhi.Texture = undefined,
    current: u32 = 0,
    pressure_current: u32 = 0,
    /// False until the textures have been emptied.
    cleared: bool = false,
    /// The emitter its spray comes from, while `WaterDesc.splashes` asks
    /// for any.
    splash: ?Emitter = null,
    /// The hardest of the dents asked for with `addRipple` since the last
    /// step, for the spray.
    hit_strength: f32 = 0,
    hit_at: Vec3 = .{ 0, 0, 0 },
    hit_radius: f32 = 0,
    /// The flattened picture `fluidImage` hands out, once asked for.
    picture: ?rhi.Texture = null,
    picture_drawn: bool = false,
    /// The sheet `recordFluidFlipbook` fills, and how far it has got.
    flipbook: ?rhi.Texture = null,
    flipbook_desc: FluidFlipbookDesc = .{},
    flipbook_frame: [2]u32 = .{ 0, 0 },
    flipbook_recorded: u32 = 0,
    flipbook_wait: u32 = 0,
    /// What the solid mask was last drawn from; 0 for never.
    mask_key: u64 = 0,
    /// This frame's description on the GPU; 0 until first simulated.
    params: u64 = 0,
    params_frame: u64 = std.math.maxInt(u64),

    fn setSources(self: *FluidState, sources: []const FluidSource) void {
        self.source_count = @intCast(sources.len);
        @memcpy(self.sources[0..sources.len], sources);
        // The description must not point at the caller's memory.
        self.desc.sources = &.{};
        self.obstacle_count = @intCast(self.desc.obstacles.len);
        @memcpy(self.obstacles[0..self.desc.obstacles.len], self.desc.obstacles);
        self.desc.obstacles = &.{};
    }

    /// Order matters: 4 to 6 hold one number per cell, 8 is the mask.
    pub fn textures(self: *FluidState) [11]*rhi.Texture {
        return .{ &self.velocity[0], &self.velocity[1], &self.scalars[0], &self.scalars[1], &self.pressure[0], &self.pressure[1], &self.divergence, &self.curl, &self.solid, &self.carried, &self.carried_velocity };
    }
};
const OitTargets = struct { accumulation: rhi.Texture, reveal: rhi.Texture };
const PeelTargets = struct { layer: rhi.Texture, accumulation: rhi.Texture, depth: [2]rhi.Texture };
const shade_plain_targets = [_]rhi.ColorTarget{ .{ .format = hdr_format }, .{ .format = .rg16_float } };
const shade_reflective_targets = [_]rhi.ColorTarget{ .{ .format = hdr_format }, .{ .format = .rg16_float }, .{ .format = hdr_format }, .{ .format = hdr_format } };
const InstanceGroupData = struct {
    scene: Scene,
    model: Model,
    transforms: []Mat4,
    /// One packed color per copy, or empty for no tint.
    tints: []u32 = &.{},
    /// One set of shader parameters per copy, or empty for zeros.
    params: [][4]f32 = &.{},
    /// The entity whose pose every copy takes; see `setInstancesPose`.
    driver: ?Entity = null,
    /// First GPU instance index, and GPU instances per copy (one per
    /// mesh instance of the model); set when the layout is rebuilt.
    base: u32 = 0,
    per_copy: u32 = 0,
};
const InstanceSlot = struct {
    buffer: ?rhi.Buffer = null,
    capacity: u32 = 0,
    static_version: u64 = std.math.maxInt(u64),
    entity_count: usize = 0,
};

/// One particle emitter of a scene and its particles on the GPU.
pub const EmitterData = struct {
    scene: Scene,
    desc: EmitterDesc,
    buffer: rhi.Buffer,
    capacity: u32,
    /// Next slot to be born into; slots are reused in a ring.
    cursor: u32 = 0,
    /// Fractional births carried to the next frame.
    pending: f32 = 0,
    /// Drawing order for sorted emitters: one entry per slot, rounded up
    /// to a power of two.
    order: ?rhi.Buffer = null,
    order_count: u32 = 0,
    /// Remembered positions for trails: `trail_points` per slot, the
    /// newest at `trail_head`; `trail_clock` counts toward the next one.
    trail: ?rhi.Buffer = null,
    trail_points: u32 = 0,
    trail_head: u32 = 0,
    trail_clock: f32 = 0,
    /// Set once `prewarm` has been applied.
    warmed: bool = false,
    /// How far the scene was shifted since the particles were last simulated.
    shift: Vec3 = .{ 0, 0, 0 },
    /// This frame's parameters on the GPU; 0 until first simulated.
    frame_params: u64 = 0,
};
/// A reflection probe: its description, the view and target its pictures
/// are taken with, and the cubes they are filtered into.
const ProbeData = struct {
    scene: Scene,
    desc: ReflectionProbeDesc,
    target: rhi.Texture,
    view: View,
    cubes: EnvironmentEntry,
    dirty: bool = true,
    /// Frames waited before the first pictures.
    waited: u32 = 0,
    /// The next of the six pictures to take; 0 when none is under way.
    face: u32 = 0,
    /// Its pictures are being taken: it is left out of them.
    capturing: bool = false,
    captured: bool = false,
};
const PickPending = struct { pixel: [2]u32, scene: Scene, layout_version: u64, near: f32 };

/// What a read-back copy of a scene's seen instances describes.
const SeenTag = struct { layout_version: u64 = 0, count: u32 = 0, valid: bool = false };
const DrawPipelines = struct { format: rhi.Format, flat: rhi.Pipeline, depth_tested: rhi.Pipeline };
const ImageEntry = struct { texture: rhi.Texture, index: u32 };

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
            // Mostly the ray tracing structures of deformed meshes: one
            // refit each, which the driver takes its time over.
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

        // Surfaces and volumes that are seen through, over the opaque picture.
        try transparency_passes.drawLiquids(self, &pass);
        try transparency_passes.drawWater(self, &pass);
        try transparency_passes.drawTransparency(self, &pass);
        try volume_passes.drawFluids(self, &pass);
        if (settings.fog_density > 0 and !debugging) try volume_passes.drawFog(self, &pass);
        if (!debugging) try particle_passes.drawParticles(self, cmd, scene, view, frame_address, desc.camera.position);
        try self.runPasses(&pass, .after_transparency, view.hdr, hdr_format, width, height);

        // The last steps work on the whole picture; each hands the next
        // the texture it left its result in.
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
const CascadeCache = struct {
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
