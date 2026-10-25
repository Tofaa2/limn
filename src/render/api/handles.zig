//! Handles to the renderer's objects.
const gltf = @import("../../asset/gltf.zig");
const animation = @import("../animation.zig");
const handle = @import("../../handle.zig");
const draw_list = @import("../draw_list.zig");
const font_module = @import("font_baker").font;

const api = @import("../api.zig");
const Geometry = api.Geometry;

pub const ModelTag = opaque {};
pub const EnvironmentTag = opaque {};
pub const SceneTag = opaque {};
pub const EntityTag = opaque {};
pub const ViewTag = opaque {};
pub const EmitterTag = opaque {};
pub const ReflectionProbeTag = opaque {};
pub const FluidTag = opaque {};
pub const WaterTag = opaque {};
pub const HairTag = opaque {};
pub const CollisionFieldTag = opaque {};
pub const LiquidTag = opaque {};
pub const InstanceGroupTag = opaque {};
pub const LightTag = opaque {};
pub const DecalTag = opaque {};
/// Geometry, materials and animations shared by entities; see
/// `Renderer.models.load`. Handles are 64-bit copyable values; calls given a
/// stale handle do nothing or return an error.
pub const Model = handle.Handle(ModelTag);
/// A sky and its image-based lighting; see `Renderer.environments.load`.
pub const Environment = handle.Handle(EnvironmentTag);
/// A world of entities, lights and effects; see `Renderer.scenes.create`.
pub const Scene = handle.Handle(SceneTag);
/// One placement of a model in a scene; see `Renderer.entities.create`.
pub const Entity = handle.Handle(EntityTag);
/// Per-camera state that persists between frames.
pub const View = handle.Handle(ViewTag);
/// A particle emitter in a scene.
pub const Emitter = handle.Handle(EmitterTag);
/// A local reflection probe in a scene.
pub const ReflectionProbe = handle.Handle(ReflectionProbeTag);
/// One light of a scene; see `Renderer.lights`.
pub const Light = handle.Handle(LightTag);
/// One decal of a scene; see `Renderer.decals`.
pub const Decal = handle.Handle(DecalTag);
/// A box of simulated smoke and fire in a scene; see `Renderer.fluids.create`.
pub const Fluid = handle.Handle(FluidTag);
/// A shape that hair is kept out of; see `Renderer.hairs.createCollisionField`.
pub const CollisionField = handle.Handle(CollisionFieldTag);
/// Strands of hair, fur or grass in a scene; see `Renderer.hairs.create`.
pub const Hair = handle.Handle(HairTag);
/// A sheet of simulated water in a scene; see `Renderer.waters.create`.
pub const Water = handle.Handle(WaterTag);
/// A volume of particle-simulated liquid; see `Renderer.liquids.create`.
pub const Liquid = handle.Handle(LiquidTag);
/// Many copies of one model; see `Renderer.instances.create`.
pub const InstanceGroup = handle.Handle(InstanceGroupTag);
/// Animation clips an entity plays; see `Renderer.entities.setPose`.
pub const Pose = animation.Pose;
/// Application-supplied geometry for `Renderer.models.create`.
/// Surface description of a mesh.
pub const Material = gltf.Material;
/// 2D shapes, images and text drawn over a view.
pub const DrawList = draw_list.DrawList;
/// A texture for draw lists, lights and settings; see `Renderer.images.create`.
pub const Image = draw_list.Image;
/// A font baked into a distance-field atlas; see `Renderer.fonts.load`.
pub const Font = font_module.Font;
