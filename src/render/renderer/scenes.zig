//! Scenes and the entities in them. Internal to the renderer.
const std = @import("std");
const handle = @import("../../handle.zig");
const rhi = @import("../../rhi/rhi.zig");
const math = @import("../../math.zig");
const gltf = @import("../../asset/gltf.zig");
const gpu = @import("../gpu.zig");
const api = @import("../api.zig");
const renderer_state = @import("../state.zig");
const render = @import("../renderer.zig");

const Renderer = render.Renderer;
const Mat4 = math.Mat4;
const Vec3 = math.Vec3;
const Environment = api.Environment;
const Scene = api.Scene;
const Entity = api.Entity;
const LightmapDesc = api.LightmapDesc;
const Pose = api.Pose;
const CloudDesc = api.CloudDesc;
const CloudFlash = api.CloudFlash;
const Sun = api.Sun;
const Light = api.Light;
const EntityDesc = api.EntityDesc;
const DecalDesc = api.DecalDesc;
const max_decals = api.max_decals;
const hdr_format = renderer_state.hdr_format;
const ModelEntry = renderer_state.ModelEntry;
const SceneData = renderer_state.SceneData;
const no_skin = renderer_state.no_skin;
const EntityData = renderer_state.EntityData;
const packTint = renderer_state.packTint;
const InstanceGroupData = renderer_state.InstanceGroupData;
const destroyFluidTextures = @import("fluid.zig").destroyFluidTextures;
const freeHair = @import("hair.zig").freeHair;
const freeProbe = @import("probes.zig").freeProbe;

/// Worlds of entities, lights and effects.
pub const Scenes = struct {
    table: handle.HandleTable(renderer_state.SceneData, api.SceneTag),

    fn renderer(scenes: *Scenes) *Renderer {
        return @alignCast(@fieldParentPtr("scenes", scenes));
    }

    /// Sets the scene's volumetric cloud layer; null removes it. Drawn by
    /// views with `Settings.clouds` on.
    pub fn setClouds(scenes: *Scenes, scene: Scene, clouds: ?CloudDesc) !void {
        const self = scenes.renderer();
        self.lock();
        defer self.unlock();
        const data = self.scenes.table.get(scene) orelse return;
        data.clouds = clouds;
    }

    /// Position and brightness of the lightning flash in the scene's clouds
    /// right now, if any.
    pub fn cloudFlash(scenes: *Scenes, scene: Scene) ?CloudFlash {
        const self = scenes.renderer();
        self.lock();
        defer self.unlock();
        const data = self.scenes.table.get(scene) orelse return null;
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

    /// Replaces the scene's decals. They apply to opaque surfaces before
    /// lighting.
    pub fn setDecals(scenes: *Scenes, scene: Scene, decals: []const DecalDesc) !void {
        const self = scenes.renderer();
        self.lock();
        defer self.unlock();
        const data = self.scenes.table.get(scene) orelse return;
        if (decals.len > max_decals) return error.TooManyDecals;
        data.decals.clearRetainingCapacity();
        try data.decals.appendSlice(self.gpa, decals);
    }

    /// Creates an empty scene: no entities or lights, sun off, no
    /// environment.
    pub fn create(scenes: *Scenes) !Scene {
        const self = scenes.renderer();
        self.lock();
        defer self.unlock();
        return self.scenes.table.insert(.{});
    }

    /// Destroys the scene and every entity in it.
    pub fn destroy(scenes: *Scenes, scene: Scene) void {
        const self = scenes.renderer();
        self.lock();
        defer self.unlock();
        var removed = self.scenes.table.remove(scene) orelse return;
        for (removed.entities.items) |entity| {
            const data = self.entities.table.remove(entity) orelse continue;
            self.entity_marks.items[entity.index] = .{};
            if (self.models.table.get(data.model)) |model| model.references -= 1;
            freeEntityStorage(self, data);
        }
        freeScene(self, &removed);
    }

    /// Replaces the scene's sun. `intensity` 0 turns it and its shadows off.
    pub fn setSun(scenes: *Scenes, scene: Scene, sun: Sun) void {
        const self = scenes.renderer();
        self.lock();
        defer self.unlock();
        if (self.scenes.table.get(scene)) |data| data.sun = sun;
    }

    /// Sets the HDR environment used for the sky and image-based lighting.
    pub fn setEnvironment(scenes: *Scenes, scene: Scene, environment: ?Environment, intensity: f32) void {
        const self = scenes.renderer();
        self.lock();
        defer self.unlock();
        if (self.scenes.table.get(scene)) |data| {
            data.environment = environment;
            data.environment_intensity = intensity;
        }
    }

    /// Replaces the scene's point and spot lights.
    pub fn setLights(scenes: *Scenes, scene: Scene, lights: []const Light) !void {
        const self = scenes.renderer();
        self.lock();
        defer self.unlock();
        const data = self.scenes.table.get(scene) orelse return;
        data.lights.clearRetainingCapacity();
        try data.lights.appendSlice(self.gpa, lights);
        data.lights_version += 1;
    }

    /// Moves everything in a scene by `offset` without it counting as motion,
    /// for keeping float precision in large worlds. The camera, draw lists
    /// and world-unit settings are the caller's to shift.
    pub fn shift(scenes: *Scenes, scene: Scene, offset: Vec3) !void {
        const self = scenes.renderer();
        self.lock();
        defer self.unlock();
        const data = self.scenes.table.get(scene) orelse return;
        inline for (0..3) |axis| data.origin[axis] -= offset[axis];
        for (data.entities.items) |item| {
            if (self.markOf(item) == null) continue;
            inline for (0..3) |axis| {
                self.entity_transforms.items[item.index][12 + axis] += offset[axis];
                self.entity_previous.items[item.index][12 + axis] += offset[axis];
            }
        }
        data.records_valid = false;
        for (data.groups.items) |item| {
            const group = self.instances.table.get(item) orelse continue;
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
            const emitter = self.emitters.table.get(item) orelse continue;
            emitter.desc.position = math.add(emitter.desc.position, offset);
            emitter.shift = math.add(emitter.shift, offset);
        }
        for (data.fluids.items) |item| {
            const fluid = self.fluids.table.get(item) orelse continue;
            inline for (0..3) |axis| fluid.desc.transform[12 + axis] += offset[axis];
        }
        for (data.waters.items) |item| {
            const water = self.waters.table.get(item) orelse continue;
            inline for (0..3) |axis| water.desc.transform[12 + axis] += offset[axis];
        }
        if (data.gi_bounds) |*bounds| {
            bounds[0] = math.add(bounds[0], offset);
            bounds[1] = math.add(bounds[1], offset);
        }
        inline for (.{ &data.gi, &data.gi_coarse, &data.gi_middle }) |slot| {
            if (slot.*) |*volume| volume.origin = math.add(volume.origin, offset);
        }
    }

    /// The scene's zero in the application's world: minus the sum of every
    /// `scenes.shift` offset.
    pub fn origin(scenes: *Scenes, scene: Scene) [3]f64 {
        const self = scenes.renderer();
        self.lock();
        defer self.unlock();
        return if (self.scenes.table.get(scene)) |data| data.origin else .{ 0, 0, 0 };
    }

    /// Pins the irradiance probe volume to a world-space box; null derives it
    /// from the scene's static geometry (the default).
    pub fn setGiVolume(scenes: *Scenes, scene: Scene, bounds: ?[2]Vec3) void {
        const self = scenes.renderer();
        self.lock();
        defer self.unlock();
        if (self.scenes.table.get(scene)) |data| data.gi_bounds = bounds;
    }
};

pub fn freeScene(self: *Renderer, scene: *SceneData) void {
    scene.entities.deinit(self.gpa);
    scene.lights.deinit(self.gpa);
    scene.shadow_grants.deinit(self.gpa);
    for (scene.emitters.items) |emitter| if (self.emitters.table.remove(emitter)) |removed| {
        self.device.destroyBuffer(removed.buffer);
        if (removed.order) |order| self.device.destroyBuffer(order);
        if (removed.trail) |trail| self.device.destroyBuffer(trail);
    };
    scene.emitters.deinit(self.gpa);
    for (scene.probes.items) |probe| if (self.probes.table.remove(probe)) |removed_probe| {
        var removed = removed_probe;
        freeProbe(self, &removed);
    };
    scene.probes.deinit(self.gpa);
    for (scene.fluids.items) |fluid| if (self.fluids.table.remove(fluid)) |removed| {
        var state = removed;
        destroyFluidTextures(self, &state);
    };
    scene.fluids.deinit(self.gpa);
    for (scene.waters.items) |water| if (self.waters.table.remove(water)) |removed| {
        for (removed.state) |texture| self.device.destroyTexture(texture);
    };
    scene.waters.deinit(self.gpa);
    for (scene.hairs.items) |hair| if (self.hairs.table.remove(hair)) |removed| freeHair(self, removed);
    scene.hairs.deinit(self.gpa);
    for (scene.liquids.items) |liquid| if (self.liquids.table.remove(liquid)) |removed_liquid| {
        var removed = removed_liquid;
        removed.deinit(self.device);
    };
    scene.liquids.deinit(self.gpa);
    if (scene.trace_nodes) |buffer| self.device.destroyBuffer(buffer);
    if (scene.trace_instances) |buffer| self.device.destroyBuffer(buffer);
    scene.decals.deinit(self.gpa);
    scene.movers.deinit(self.gpa);
    for (scene.groups.items) |group| if (self.instances.table.remove(group)) |removed| {
        if (removed.impostor) |impostor| {
            self.device.destroyTexture(impostor.color);
            self.device.destroyTexture(impostor.normal);
        }
        self.gpa.free(removed.transforms);
        self.gpa.free(removed.tints);
        self.gpa.free(removed.params);
        if (self.models.table.get(removed.model)) |model| model.references -= 1;
    };
    scene.groups.deinit(self.gpa);
    scene.static_tlas.deinit(self.gpa);
    for (scene.instance_slots) |slot| if (slot.buffer) |buffer| self.device.destroyBuffer(buffer);
    scene.transparent.deinit(self.gpa);
    scene.static_transparent.deinit(self.gpa);
    scene.layout.deinit(self.gpa);
    scene.posed.deinit(self.gpa);
    scene.entries.deinit(self.gpa);
    scene.spheres.deinit(self.gpa);
    scene.blended.deinit(self.gpa);
    scene.glowing.deinit(self.gpa);
    scene.chunk_bounds.deinit(self.gpa);
    scene.chunk_stale.deinit(self.gpa);
    scene.edited.deinit(self.gpa);
    scene.settling.deinit(self.gpa);
    if (scene.previous) |buffer| self.device.destroyBuffer(buffer);
    if (scene.tlas_instances) |buffer| self.device.destroyBuffer(buffer);
    if (scene.refs) |buffer| self.device.destroyBuffer(buffer);
    scene.static_ranges.deinit(self.gpa);
    if (scene.static_cull) |buffer| self.device.destroyBuffer(buffer);
    if (scene.impostor_table) |buffer| self.device.destroyBuffer(buffer);
    if (scene.impostor_list) |buffer| self.device.destroyBuffer(buffer);
    if (scene.candidates) |buffer| self.device.destroyBuffer(buffer);
    if (scene.seen) |buffer| self.device.destroyBuffer(buffer);
    for (scene.seen_readback) |readback| if (readback) |buffer| self.device.destroyBuffer(buffer);
    if (scene.skin_bounds) |buffer| self.device.destroyBuffer(buffer);
    if (scene.tlas) |tlas| self.device.destroyAcceleration(tlas);
    if (scene.gi) |volume| volume.deinit(self.device);
    if (scene.gi_coarse) |volume| volume.deinit(self.device);
    if (scene.gi_middle) |volume| volume.deinit(self.device);
}

/// Placements of models in scenes.
pub const Entities = struct {
    table: handle.HandleTable(renderer_state.EntityData, api.EntityTag),

    fn renderer(entities: *Entities) *Renderer {
        return @alignCast(@fieldParentPtr("entities", entities));
    }

    /// Adds an entity; the model may still be loading. The entity holds a
    /// reference to the model until `despawn` or `scenes.destroy`. Fails with
    /// `error.InvalidScene` or `error.InvalidModel` for a stale handle.
    pub fn spawn(entities: *Entities, scene: Scene, desc: EntityDesc) !Entity {
        const self = entities.renderer();
        self.lock();
        defer self.unlock();
        const scene_data = self.scenes.table.get(scene) orelse return error.InvalidScene;
        const model = self.models.table.get(desc.model) orelse return error.InvalidModel;
        const entity = try self.entities.table.insert(.{
            .scene = scene,
            .model = desc.model,
            .visible = desc.visible,
            .tint = packTint(desc.tint),
            .params = desc.params,
            .receive_decals = desc.receive_decals,
        });
        errdefer _ = self.entities.table.remove(entity);
        try self.markEntity(entity, scene, desc.transform);
        errdefer self.entity_marks.items[entity.index] = .{};
        try scene_data.entities.append(self.gpa, entity);
        model.references += 1;
        scene_data.layout_dirty = true;
        return entity;
    }

    /// Removes an entity and releases its model reference. A stale handle is
    /// ignored.
    pub fn despawn(entities: *Entities, entity: Entity) void {
        const self = entities.renderer();
        self.lock();
        defer self.unlock();
        const data = self.entities.table.remove(entity) orelse return;
        self.entity_marks.items[entity.index] = .{};
        if (self.scenes.table.get(data.scene)) |scene| {
            for (scene.entities.items, 0..) |candidate, index| if (std.meta.eql(candidate, entity)) {
                _ = scene.entities.orderedRemove(index);
                break;
            };
            scene.layout_dirty = true;
        }
        if (self.models.table.get(data.model)) |model| model.references -= 1;
        freeEntityStorage(self, data);
    }

    /// Sets the model-to-world transform. The change from last frame counts
    /// as motion; use `teleport` for a jump that should not.
    pub fn setTransform(entities: *Entities, entity: Entity, transform: Mat4) void {
        const self = entities.renderer();
        if (!self.tryLock()) return self.queueEdit(entity, .{ .transform = transform });
        defer self.unlock();
        self.moveEntity(entity, transform, false);
    }

    /// `setTransform` for many entities at once; the slices pair up.
    pub fn setTransforms(entities: *Entities, handles: []const Entity, transforms: []const Mat4) void {
        const self = entities.renderer();
        if (!self.tryLock()) return queueTransforms(self, handles, transforms);
        defer self.unlock();
        for (handles, transforms) |entity, transform| self.moveEntity(entity, transform, false);
    }

    /// Like `setTransform`, but resets motion history.
    pub fn teleport(entities: *Entities, entity: Entity, transform: Mat4) void {
        const self = entities.renderer();
        if (!self.tryLock()) return self.queueEdit(entity, .{ .teleport = transform });
        defer self.unlock();
        self.moveEntity(entity, transform, true);
    }

    /// Changes the color an entity's materials are multiplied by.
    pub fn setTint(entities: *Entities, entity: Entity, tint: [3]f32) void {
        const self = entities.renderer();
        if (!self.tryLock()) return self.queueEdit(entity, .{ .tint = packTint(tint) });
        defer self.unlock();
        const data = self.entities.table.get(entity) orelse return;
        if (data.tint == packTint(tint)) return;
        data.tint = packTint(tint);
        self.restyleEntity(entity);
    }

    /// Sets the entity's `MaterialContext.instance_params`.
    pub fn setParams(entities: *Entities, entity: Entity, params: [4]f32) void {
        const self = entities.renderer();
        if (!self.tryLock()) return self.queueEdit(entity, .{ .params = params });
        defer self.unlock();
        const data = self.entities.table.get(entity) orelse return;
        if (std.mem.eql(f32, &data.params, &params)) return;
        data.params = params;
        self.restyleEntity(entity);
    }

    /// Overrides morph target weights (up to 64, in model order) on every
    /// mesh that has any; null returns them to the animation. Only skinned
    /// meshes morph.
    pub fn setMorphWeights(entities: *Entities, entity: Entity, weights: ?[]const f32) void {
        const self = entities.renderer();
        self.lock();
        defer self.unlock();
        const data = self.entities.table.get(entity) orelse return;
        if (weights) |values| {
            var stored: [gltf.max_morph_targets]f32 = @splat(0);
            for (values[0..@min(values.len, stored.len)], 0..) |value, index| stored[index] = value;
            data.morph_weights = stored;
        } else data.morph_weights = null;
    }

    /// Bakes a lightmap for a static entity over `LightmapDesc.frames`
    /// frames; it replaces the irradiance probes on its surfaces. Null removes
    /// it. Needs non-overlapping `MeshDesc.uvs1`, ray tracing
    /// (`error.RayTracingUnavailable`) and `Settings.global_illumination`.
    pub fn bakeLightmap(entities: *Entities, entity: Entity, desc: ?LightmapDesc) !void {
        const self = entities.renderer();
        self.lock();
        defer self.unlock();
        const data = self.entities.table.get(entity) orelse return;
        const scene = self.scenes.table.get(data.scene) orelse return;
        if (data.lightmap) |old| {
            for (old.gathered) |texture| self.device.destroyTexture(texture);
            self.device.destroyTexture(old.shown);
            data.lightmap = null;
        }
        const wanted = desc orelse return;
        if (self.pipelines.lightmap_bake == null) return error.RayTracingUnavailable;
        const size = std.math.clamp(wanted.resolution, 16, 4096);
        var made: [3]?rhi.Texture = @splat(null);
        errdefer for (made) |texture| if (texture) |value| self.device.destroyTexture(value);
        for (&made) |*texture| texture.* = try self.device.createTexture(.{ .name = "lightmap", .width = size, .height = size, .format = hdr_format, .usage = .{ .sampled = true, .color_attachment = true } });
        data.lightmap = .{
            .gathered = .{ made[0].?, made[1].? },
            .shown = made[2].?,
            .wanted = @max(wanted.frames, 1),
            .rays = std.math.clamp(wanted.rays, 1, 256),
            .reach = @max(wanted.reach, 0.01),
        };
        scene.lightmaps_baking += 1;
    }

    /// Baked fraction of an entity's lightmap, 0 to 1; null if it has none.
    pub fn lightmapProgress(entities: *Entities, entity: Entity) ?f32 {
        const self = entities.renderer();
        self.lock();
        defer self.unlock();
        const data = self.entities.table.get(entity) orelse return null;
        const lightmap = data.lightmap orelse return null;
        return @as(f32, @floatFromInt(@min(lightmap.rounds, lightmap.wanted))) / @as(f32, @floatFromInt(lightmap.wanted));
    }

    /// Shows or hides an entity. A hidden entity is not drawn and casts no
    /// shadows; showing it again resets its motion history.
    pub fn setVisible(entities: *Entities, entity: Entity, visible: bool) void {
        const self = entities.renderer();
        self.lock();
        defer self.unlock();
        const data = self.entities.table.get(entity) orelse return;
        if (data.visible == visible) return;
        data.visible = visible;
        data.history_frames = 0;
        if (self.scenes.table.get(data.scene)) |scene| scene.layout_dirty = true;
    }

    /// Sets the animation pose. Null returns the model to its rest pose.
    pub fn setPose(entities: *Entities, entity: Entity, pose: ?Pose) void {
        const self = entities.renderer();
        if (!self.tryLock()) return self.queueEdit(entity, .{ .pose = pose });
        defer self.unlock();
        if (self.entities.table.get(entity)) |data| data.pose = pose;
    }
};

/// Queues transforms a chunk at a time, so that the queue is not held long.
fn queueTransforms(self: *Renderer, handles: []const Entity, transforms: []const Mat4) void {
    var edits: [64]renderer_state.EntityEdit = undefined;
    var done: usize = 0;
    while (done < handles.len) {
        const count = @min(edits.len, handles.len - done);
        for (edits[0..count], handles[done..][0..count], transforms[done..][0..count]) |*edit, entity, transform| {
            edit.* = .{ .entity = entity, .change = .{ .transform = transform } };
        }
        self.queueEdits(edits[0..count]);
        done += count;
    }
}

pub fn freeEntityStorage(self: *Renderer, entity: EntityData) void {
    if (entity.lightmap) |lightmap| {
        for (lightmap.gathered) |texture| self.device.destroyTexture(texture);
        self.device.destroyTexture(lightmap.shown);
    }
    if (self.models.table.get(entity.model)) |model| {
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

/// Allocates per-entity animation state once its model is ready.
pub fn resolveEntity(self: *Renderer, entity: *EntityData, model: *ModelEntry) !void {
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

/// The entity whose pose a group's copies take, if posed this frame.
pub fn groupDriver(self: *Renderer, group: *const InstanceGroupData, model_instances: usize) ?*EntityData {
    const entity = self.entities.table.get(group.driver orelse return null) orelse return null;
    if (!entity.visible or !entity.resolved) return null;
    if (!std.meta.eql(entity.model, group.model) or !std.meta.eql(entity.scene, group.scene)) return null;
    if (entity.skin_offsets.len != model_instances) return null;
    return entity;
}
