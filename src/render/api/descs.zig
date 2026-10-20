//! Descriptions of the objects a scene holds.
const std = @import("std");
const math = @import("../../math.zig");
const gltf = @import("../../asset/gltf.zig");
const gpu = @import("../gpu.zig");
const render = @import("../renderer.zig");

const Mat4 = render.Mat4;
const Vec3 = render.Vec3;

const api = @import("../api.zig");
const CollisionField = api.CollisionField;
const Environment = api.Environment;
const Fluid = api.Fluid;
const Hair = api.Hair;
const Image = api.Image;
const Material = api.Material;
const Model = api.Model;
const Pass = api.Pass;
const Pick = api.Pick;
const Reflections = api.Reflections;
const Settings = api.Settings;
const Sun = api.Sun;

/// Where liquid pours into a `LiquidDesc` volume.
pub const LiquidSource = struct {
    /// Mouth of the jet, in world space.
    position: Vec3,
    /// Direction and speed of the jet.
    velocity: Vec3 = .{ 0, -1, 0 },
    radius: f32 = 0.12,
    /// Particles per second; 0 fills the jet solid at its speed.
    rate: f32 = 0,
};

/// A box of particle-simulated liquid; see `Renderer.liquids.create`. Costs far
/// more than a `WaterDesc` sheet of the same area.
pub const LiquidDesc = struct {
    /// Places the containing box: the unit cube centered on the origin. Its
    /// faces are the liquid's only walls.
    transform: Mat4,
    /// Maximum particles; fixed at creation.
    capacity: u32 = 30000,
    /// Half the rest distance between particles; fixed at creation.
    particle_radius: f32 = 0.04,
    /// Initial fill from the box's low corner, as a share of each axis.
    fill: [3]f32 = .{ 0, 0, 0 },
    /// Up to four jets pouring in.
    sources: []const LiquidSource = &.{},
    gravity: Vec3 = .{ 0, -9.8, 0 },
    /// Color taken on with depth, and how quickly; `murk` 0 is clear.
    color: [3]f32 = .{ 0.1, 0.38, 0.5 },
    murk: f32 = 1.5,
    /// Light scattered inside per world unit, which gives the liquid a lit
    /// body of its own colour; 0 is perfectly clear.
    scatter: f32 = 0.15,
    /// How readily the liquid froths white where it is churned or flung
    /// apart, 0..1; foam fades over a second or so.
    foam: f32 = 0.6,
    /// Sun shadow opacity, 0..1; above 0 costs a draw per refreshed cascade.
    shadow: f32 = 0.5,
    /// Write depth, so fog, particles, antialiasing, depth of field and motion
    /// blur treat the liquid as a surface.
    write_depth: bool = true,
    /// How far the slope of the surface shifts what is seen through it.
    refraction: f32 = 0.3,
    /// Simulation steps per frame, and solver iterations per step.
    substeps: u32 = 2,
    iterations: u32 = 3,
    /// Share of its speed lost per second.
    damping: f32 = 0.05,
    /// How much neighbouring particles share velocity, 0..1.
    viscosity: f32 = 0.08,
    /// Fine shading ripples (see `WaterDesc.ripple_detail`); 0 for none.
    ripple_detail: f32 = 0.4,
    /// Entities displace the liquid by their models' bounding spheres (the
    /// nearest 16 that reach into the box).
    obstacles: bool = true,
    /// Simulation speed; 0 freezes it.
    time_scale: f32 = 1,
};

/// See `Renderer.entities.bakeLightmap`.
pub const LightmapDesc = struct {
    /// Texels per side.
    resolution: u32 = 256,
    /// Frames the bake is spread over, and rays per texel per frame.
    frames: u32 = 256,
    rays: u32 = 16,
    /// Maximum ray length, in world units.
    reach: f32 = 200,
};

/// See `Renderer.instances.setImpostor`.
pub const ImpostorDesc = struct {
    /// Copies smaller than this many pixels across are drawn as impostor cards.
    pixels: f32 = 24,
    /// Pixels per side of each of the 64 captured directions.
    resolution: u32 = 64,
};

/// Strands of hair, fur or grass; see `Renderer.hairs.create`. Each strand is a
/// row of points drawn as a camera-facing ribbon. Strands cast no shadows.
pub const HairDesc = struct {
    /// All strands' points, each root to tip, in hair space. Copied.
    points: []const [3]f32,
    /// Points per strand; at least 2.
    points_per_strand: u32,
    /// Hair space to world.
    transform: Mat4 = math.identity,
    /// Width at the root, in hair-space units.
    width: f32 = 0.002,
    /// Tip width as a share of `width`.
    taper: f32 = 0.3,
    root_color: [3]f32 = .{ 0.10, 0.06, 0.03 },
    tip_color: [3]f32 = .{ 0.30, 0.20, 0.11 },
    /// Width of the highlights along the strands, 0..1.
    roughness: f32 = 0.35,
    /// How much the strands differ in pigment, 0..1: some darker and
    /// richer, some paler.
    variation: f32 = 0.5,
    /// Draws each strand this many times, offset sideways.
    copies: u32 = 1,
    /// Maximum sideways offset of the copies, in hair-space units; less toward
    /// the root.
    spread: f32 = 0,
    /// How much the copies gather back to their strand toward the tip, 0..1,
    /// which parts the hair into locks.
    clump: f32 = 0.3,
    /// Radius of the copies' curls round their strand, in hair-space units,
    /// and how many turns they make from root to tip.
    curl: f32 = 0,
    curl_turns: f32 = 4,
    /// Stray kinks of the copies toward the tip, in hair-space units.
    frizz: f32 = 0,
    /// Null leaves the strands static.
    simulation: ?HairSimulation = null,
};

/// Strand dynamics; see `HairDesc.simulation` and `Renderer.hairs.setSimulation`.
/// Roots stay fixed; strands keep their length and are pulled toward their
/// given shape. At most 64 points per strand. World units and seconds.
pub const HairSimulation = struct {
    gravity: Vec3 = .{ 0, -9.8, 0 },
    /// Average wind acceleration, added to gravity.
    wind: Vec3 = .{ 0, 0, 0 },
    /// Gust variation: 0 is steady, 1 drops to nothing between gusts.
    gustiness: f32 = 0.6,
    /// Pull toward the given shape: share of the way restored per 1/60 s; 0
    /// hangs free, 1 is rigid. `root_stiffness` applies at the root and gives
    /// way to `stiffness` over the first third of the strand.
    stiffness: f32 = 0.006,
    root_stiffness: f32 = 0.35,
    /// Share of its speed a strand loses each step.
    damping: f32 = 0.04,
    /// Collision spheres: center and radius, in world space. At most 6; copied.
    colliders: []const [4]f32 = &.{},
    /// Collision shape from `Renderer.hairs.createCollisionField`; `field_transform`
    /// places it in the world.
    field: ?CollisionField = null,
    field_transform: Mat4 = math.identity,
    /// Distance strands are kept from the field, in world units.
    margin: f32 = 0.002,
    /// Strand-to-strand repulsion; 0 for none.
    volume: f32 = 0.4,
};

/// A sheet of simulated water; see `Renderer.waters.create`.
pub const WaterDesc = struct {
    /// Cells of the simulation along each side, 16..1024.
    resolution: [2]u32 = .{ 256, 256 },
    /// Places the surface in the world: a unit square in the XZ plane
    /// centered on the origin, +Y up. The Y scale is the unit of height.
    transform: Mat4 = math.identity,
    /// Ripple speed in world units per second; at most about 2/3 cell per step.
    wave_speed: f32 = 3,
    /// Share of the motion lost per second.
    damping: f32 = 0.5,
    /// Raindrops per second landing at random places; 0 for none.
    rain: f32 = 0,
    /// Strength of ripples from entities moving through the surface, by their
    /// models' bounding spheres; 0 for none.
    object_ripples: f32 = 1,
    /// Spray where an entity moves through the surface; 0 for none. Needs
    /// `object_ripples`. One splash location per frame.
    splashes: f32 = 0,
    /// Swell height and wave length, in world units; 0 for none.
    swell: f32 = 0,
    swell_length: f32 = 6,
    /// Speed of the simulation; 0 freezes it.
    time_scale: f32 = 1,
    /// Color taken on with depth, and how quickly per world unit.
    color: Vec3 = .{ 0.02, 0.1, 0.12 },
    murk: f32 = 0.5,
    /// Roughness of reflections.
    roughness: f32 = 0.04,
    /// Refraction strength.
    refraction: f32 = 1.2,
    /// Foam at shallow edges and churning water, 0..1.
    foam: f32 = 0.6,
    /// Caustics under the water in sunlight, 0..1.
    caustics: f32 = 0.6,
    /// Fine shading-only ripples: 0 is glass-still, 1 a breezy pond.
    ripple_detail: f32 = 0.5,
    /// Tint the view by water depth when the camera is under the surface.
    underwater: bool = true,
    /// Write depth, so fog, particles and transparents treat it as a surface.
    write_depth: bool = true,
    /// Stretched over the sheet; where its red channel is below one half no
    /// water is drawn. Null draws the whole sheet. Not applied to `write_depth`.
    mask: ?Image = null,
};

/// What happens at the sides of a fluid's box.
pub const FluidWalls = enum(u32) {
    open,
    /// Solid underneath, open elsewhere.
    floor,
    /// Sealed on every side.
    closed,
};

/// A place inside a fluid's box where smoke, heat or fuel enters.
pub const FluidSource = struct {
    /// Center, in box coordinates 0..1.
    position: Vec3 = .{ 0.5, 0.08, 0.5 },
    /// Radius as a share of the box's height.
    radius: f32 = 0.07,
    /// Velocity imposed inside the source, in box heights per second.
    velocity: Vec3 = .{ 0, 0.5, 0 },
    /// Amounts added per second at the center. Fuel burns where it is hot,
    /// giving heat and smoke.
    smoke: f32 = 0,
    fuel: f32 = 0,
    temperature: f32 = 0,
};

/// A solid inside a fluid's box, in box coordinates 0..1.
pub const FluidObstacle = union(enum) {
    /// `radius` is a share of the box's height.
    sphere: struct { center: Vec3, radius: f32 },
    box: struct { min: Vec3, max: Vec3 },
};

/// Frames recorded from a running fluid; see `Renderer.fluids.recordFlipbook`.
pub const FluidFlipbookDesc = struct {
    columns: u32 = 8,
    rows: u32 = 8,
    /// Simulation steps from one frame to the next, at least 1.
    interval: u32 = 2,
    /// Size of one frame in pixels; null uses the fluid's resolution.
    frame_size: ?[2]u32 = null,
};

/// A box of simulated smoke and fire; see `Renderer.fluids.create`.
pub const FluidDesc = struct {
    /// Cells along each axis, 8..256. A depth of 1 makes the fluid 2D.
    resolution: [3]u32 = .{ 64, 96, 64 },
    /// Places the box: a unit cube centered on the origin, +Y up.
    transform: Mat4 = math.identity,
    /// Up to 8.
    sources: []const FluidSource = &.{},
    /// Up to 8.
    obstacles: []const FluidObstacle = &.{},
    /// Treat scene geometry inside the box as solid. Needs ray tracing;
    /// six short rays per cell per frame.
    scene_obstacles: bool = false,
    walls: FluidWalls = .floor,
    /// Lift per unit of heat and sink per unit of smoke, in box heights per
    /// second squared.
    buoyancy: f32 = 1.6,
    weight: f32 = 0.1,
    /// Vorticity confinement strength; 0 for none.
    vorticity: f32 = 12,
    /// Constant acceleration, in box heights per second squared.
    wind: Vec3 = .{ 0, 0, 0 },
    /// Shares lost per second: velocity, smoke, heat, fuel.
    velocity_loss: f32 = 0.25,
    smoke_loss: f32 = 0.45,
    cooling: f32 = 1.4,
    burn_rate: f32 = 5,
    /// Heat and smoke given off per unit of fuel burned.
    heat: f32 = 3,
    soot: f32 = 0.6,
    /// MacCormack advection of smoke and heat: sharper, at one more pass.
    sharp_advection: bool = true,
    /// MacCormack advection of velocity too. Needs `sharp_advection`.
    sharp_velocity: bool = false,
    /// Jacobi pressure iterations per step, 1..200.
    pressure_iterations: u32 = 24,
    /// Speed of the simulation; 0 freezes it.
    time_scale: f32 = 1,

    /// Scattering color, and extinction per unit of smoke per world unit.
    smoke_color: Vec3 = .{ 0.55, 0.55, 0.58 },
    absorption: f32 = 8,
    /// Tint and brightness of the glow of hot gas.
    fire_color: Vec3 = .{ 1, 1, 1 },
    fire_intensity: f32 = 6,
    /// Strength of the light the fire casts on the scene; 0 for none.
    light: f32 = 1,
    /// How far that light reaches; 0 picks three times the box's height.
    light_range: f32 = 0,
    /// Size of that light as a share of the box's height; above 0 softens its
    /// ray-traced shadows (see `Settings.shadows.light_rays`).
    light_size: f32 = 0,
    /// Height of that light: 1 is a line as tall as the glow, 0 a point.
    light_tall: f32 = 1,
    /// Self-shadowing from the sun, 0..1.
    shadow: f32 = 1,
    /// Forward-scattering anisotropy.
    anisotropy: f32 = 0.35,
    /// Ambient light multiplier.
    ambient: f32 = 1,
};

/// A layer of volumetric clouds; see `Renderer.scenes.setClouds`.
pub const CloudDesc = struct {
    /// Share of the sky the clouds fill, 0..1.
    coverage: f32 = 0.5,
    /// Variation of coverage: 0 is even, higher gathers the clouds into banks.
    variation: f32 = 0.6,
    /// Extinction per meter inside a cloud.
    density: f32 = 0.012,
    /// Cloud base altitude and layer height, in world units above y = 0.
    bottom: f32 = 1500,
    thickness: f32 = 1400,
    /// Size of the cloud shapes; 1 gives clouds a few kilometres across.
    scale: f32 = 1,
    /// Edge erosion by detail noise, 0..1.
    detail: f32 = 0.35,
    /// Swirl of the shapes and their edges by curling noise, 0..1.
    curl: f32 = 0.5,
    /// The kind of cloud where the weather does not say: 0 flat sheets, 0.5
    /// heaped cumulus, 1 towers filling the layer.
    kind: f32 = 0.5,
    /// Weather over the land, stretched over `weather_size` and repeated: red
    /// above one half adds cover and below it takes cover away, by up to
    /// `variation`; green above one half makes the clouds taller and below it
    /// flatter. Null uses built-in weather.
    weather: ?Image = null,
    /// World units the weather image covers; 0 is 16 times the cloud shapes'
    /// repeat.
    weather_size: f32 = 0,
    /// Drift, in world units per second.
    wind: Vec3 = .{ 12, 0, 5 },
    /// Tint of the scattered light.
    color: Vec3 = .{ 1, 1, 1 },
    /// Sky light multiplier.
    ambient: f32 = 1,
    /// Forward-scattering anisotropy.
    anisotropy: f32 = 0.6,
    /// Darkness of cloud shadows, 0..1; 0 casts none.
    shadow: f32 = 0.8,
    /// Seconds between rebuilds of the sky's lighting with the clouds in it; 0
    /// never rebuilds. Each rebuild costs a sky bake.
    environment_interval: f32 = 4,
    /// Coverage of a high cirrus layer, 0..1. Casts no shadow.
    cirrus: f32 = 0,
    /// Storm cells, 0..1: anvil-topped towers where coverage is heaviest.
    anvil: f32 = 0,
    /// Lightning flashes per minute near the camera, and their brightness. They
    /// light only the cloud; see `Renderer.scenes.cloudFlash`.
    lightning: f32 = 0,
    lightning_brightness: f32 = 40,
    /// Radius of the planet the layer wraps around.
    planet_radius: f32 = 6_360_000,
};

/// A lightning flash in a cloud layer; see `Renderer.scenes.cloudFlash`.
pub const CloudFlash = struct { position: Vec3, brightness: f32 };

/// See `Renderer.images.create`.
pub const ImageDesc = struct {
    width: u32,
    height: u32,
    /// Tightly packed RGBA8, top row first.
    pixels: []const u8,
    /// True for color, false for data.
    srgb: bool = true,
    /// Most mips made; 0 is the full chain. An atlas wants no more than its
    /// smallest cell can be halved.
    mip_levels: u32 = 0,
};

/// See `Renderer.environments.load`.
/// See `Renderer.environments.load`.
pub const EnvironmentDesc = struct {
    /// An equirectangular `.hdr`, or a KTX2 cube of half floats or BC6H.
    path: []const u8,
    /// Radiance is clamped to this, which keeps a small sun from sparkling.
    max_radiance: f32 = 64,
};

/// See `Renderer.scenes.setEnvironment`.
pub const SceneEnvironment = struct {
    /// Null for none.
    environment: ?Environment,
    /// Multiplies its radiance.
    intensity: f32 = 1,
};

/// Application images used as a material's textures (see
/// `Renderer.materials.setTextures`). Null keeps the model's own. Channels
/// follow glTF: roughness in green and metallic in blue, occlusion in red,
/// coat strength in red, coat roughness in green, sheen roughness in alpha.
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
    /// Filtering and wrapping for all of them; null keeps the material's own.
    sampler: ?gltf.SamplerData = null,
};

/// See `Renderer.materials.setShader`.
pub const ShaderAssignment = struct {
    /// Index of the material; null for every material of the model.
    material: ?u32 = null,
    /// Null restores the standard shader.
    shader: ?MaterialShader = null,
    params: [4]f32 = .{ 0, 0, 0, 0 },
};

/// See `Renderer.materials.createShader`.
pub const MaterialShader = struct {
    /// Value for `Material.shader`.
    slot: u32,
};

/// The answer to a `Renderer.requestPick`, returned by `Renderer.takePick`.
pub const PickResult = struct {
    pixel: [2]u32,
    /// Null when nothing opaque is there, or the scene's contents changed
    /// before the answer came back.
    hit: ?Pick,
};

/// A box that projects a color or image onto the opaque surfaces inside it.
pub const DecalDesc = struct {
    /// Places a unit cube (-0.5..0.5) in the world. The image is projected
    /// along the cube's local -Z, so +Z should point away from the surface;
    /// X and Y are the image's width and height, Z how deep it reaches.
    transform: Mat4,
    /// Linear color and opacity, multiplied with the image if there is one.
    color: [4]f32 = .{ 1, 1, 1, 1 },
    image: ?Image = null,
    /// Normal map applied inside the box, and its strength.
    normal_image: ?Image = null,
    normal_strength: f32 = 1,
    /// Roughness given to the covered surface; null keeps the surface's own.
    roughness: ?f32 = null,
    /// Emission, in the decal's color.
    emissive: f32 = 0,
    /// Surfaces facing away from the projection by more than this cosine are
    /// left alone.
    angle_fade: f32 = 0.2,
};

/// Most decals a scene can hold.
pub const max_decals = gpu.cluster_decal_words * 32;

/// A procedural clear sky; see `Renderer.environments.createSky`.
pub const SkyDesc = struct {
    /// Direction the sun's light travels, as in `Sun.direction`.
    sun_direction: Vec3 = .{ -0.4, -1.0, -0.3 },
    /// Haze: 1 is very clear air, 10 a hazy day.
    turbidity: f32 = 2.5,
    /// Ozone, 1 for the Earth's; 0 leaves it out.
    ozone: f32 = 1,
    /// Frames a change to the sky is spread over; above 1 the sky lags and
    /// briefly mixes two moments. Taken as 1 while a cloud layer is baked into
    /// the lighting.
    rebuild_frames: u32 = 1,
    /// Overall brightness of the sky.
    intensity: f32 = 1,
    /// Color of the ground below the horizon.
    ground_color: [3]f32 = .{ 0.25, 0.23, 0.2 },
    /// Draw the sun's disc into the sky.
    sun_disc: bool = true,
    /// Brightness of the stars, shown once the sun is down.
    stars: f32 = 0,
    /// Direction the moon's light travels and the brightness of its disc; 0 for
    /// no moon. It gives no light: pair it with a directional light.
    moon_direction: Vec3 = .{ 0.3, -0.6, 0.5 },
    moon: f32 = 0,
};

/// Brightness of the sun above the atmosphere; matches environment.slang.
pub const sky_sun_strength = 8.0;

/// The `Sun` matching a sky: its direction, and its color and intensity after
/// crossing the atmosphere (zero below the horizon). Pass it to
/// `Renderer.scenes.setSun`.
pub fn skySun(desc: SkyDesc) Sun {
    const to_sun = math.normalize(math.scale(desc.sun_direction, -1));
    if (to_sun[1] <= -0.02) return .{ .direction = desc.sun_direction, .intensity = 0 };
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
    const above = std.math.clamp((to_sun[1] + 0.02) / 0.04, 0, 1);
    return .{
        .direction = desc.sun_direction,
        .color = math.scale(color, 1 / strongest),
        .intensity = sky_sun_strength * strongest * desc.intensity * above,
    };
}

/// How an emitter's particles are laid over the picture.
pub const ParticleBlend = enum {
    /// Covers what is behind it in proportion to its opacity.
    alpha,
    /// Adds light without hiding anything.
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

    /// Keys past `max_curve_keys` are dropped.
    pub fn init(keys: []const f32) SizeCurve {
        var curve = SizeCurve{ .count = @intCast(@min(keys.len, max_curve_keys)) };
        @memcpy(curve.keys[0..curve.count], keys[0..curve.count]);
        return curve;
    }
};

/// A local reflection capture, used by surfaces inside its box where neither
/// the screen nor a ray gives a reflection. See
/// `Renderer.probes.create`.
pub const ReflectionProbeDesc = struct {
    /// Capture point and center of the box.
    position: Vec3,
    /// Half the size of the box. Reflections are projected onto its walls, so
    /// match it to the room.
    extent: Vec3 = .{ 5, 3, 5 },
    /// Share of the box, inward from its faces, over which the probe fades out.
    fade: f32 = 0.15,
    intensity: f32 = 1,
    /// Pixels per side of each of the six faces, 16..1024.
    resolution: u32 = 256,
    /// Frames to let bounce light settle before capturing.
    settle_frames: u32 = 40,
    /// Brightest value kept.
    max_radiance: f32 = 32,
};

/// Most reflection probes a scene can hold.
pub const max_reflection_probes = 16;

/// A source of particles; see `Renderer.emitters.create`.
pub const EmitterDesc = struct {
    position: Vec3 = .{ 0, 0, 0 },
    /// Particles are born inside a sphere of this radius.
    radius: f32 = 0.1,
    /// Most particles alive at once; fixed at creation. If `rate` times the
    /// lifetime exceeds it, the oldest are replaced early.
    capacity: u32 = 1024,
    /// Births per second.
    rate: f32 = 100,
    /// Seconds a particle lives, chosen between these two.
    lifetime: [2]f32 = .{ 1, 2 },
    /// Axis of the cone particles are launched into.
    direction: Vec3 = .{ 0, 1, 0 },
    /// Half-angle of that cone in radians; pi launches in every direction.
    spread: f32 = 0.4,
    /// Launch speed, chosen between these two.
    speed: [2]f32 = .{ 1, 2 },
    /// Constant acceleration.
    gravity: Vec3 = .{ 0, 0, 0 },
    /// How quickly particles lose speed, per second.
    drag: f32 = 0.5,
    /// Diameter in world units at birth and at death.
    size: [2]f32 = .{ 0.05, 0.2 },
    /// Linear color and opacity at birth and at death.
    color_start: [4]f32 = .{ 1, 1, 1, 1 },
    color_end: [4]f32 = .{ 1, 1, 1, 0 },
    blend: ParticleBlend = .alpha,
    /// Lit by the sun (with shadows) and the surroundings.
    lit: bool = true,
    /// Distance over which a particle fades out as it nears a surface; 0
    /// gives a hard edge.
    softness: f32 = 0.3,
    /// Sort particles farthest first on the GPU for every view, as overlapping
    /// alpha-blended particles need. Fixed at creation.
    sorted: bool = false,
    /// Seconds of simulation run before the emitter is first shown.
    prewarm: f32 = 0,
    /// A third color and size partway through a particle's life, at `mid`
    /// (0..1). Null goes straight from start to end.
    color_mid: ?[4]f32 = null,
    size_mid: ?f32 = null,
    mid: f32 = 0.5,
    /// Color and size over life: 2 to `max_curve_keys` evenly spaced keys,
    /// replacing the start, mid and end values.
    color_curve: ColorCurve = .{},
    size_curve: SizeCurve = .{},
    /// Draw each particle as this model's first mesh instead of a sprite,
    /// `size` across and tinted by the particle color and `image`. `softness`
    /// and `stretch` do not apply.
    mesh: ?Model = null,
    /// Tumble rate of a mesh particle, in radians per second.
    spin: f32 = 0,
    /// Ribbon trail: remembered points per particle (up to `max_trail_points`,
    /// 0 for none), reaching `trail_seconds` back. The point count is fixed at
    /// creation.
    trail: u32 = 0,
    trail_seconds: f32 = 0.4,
    /// A fluid whose flow carries the particles inside its box, and how quickly
    /// they take on its velocity, per second.
    fluid: ?Fluid = null,
    fluid_follow: f32 = 6,
    /// Bounce off the surfaces the scene's first view saw last frame, keeping
    /// `bounce` of their speed.
    collide: bool = false,
    bounce: f32 = 0.4,
    /// Stretch along motion by this many seconds of travel; 0 draws it round.
    stretch: f32 = 0,
    /// Columns and rows of frames in `image`; they play once over the
    /// particle's life.
    sheet: [2]u32 = .{ 1, 1 },
    /// Sprite to draw; null draws a soft round blob.
    image: ?Image = null,
};
