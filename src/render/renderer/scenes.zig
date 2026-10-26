//! Scenes and the entities in them. Internal to the renderer.
const std = @import("std");
const releaseModel = @import("models.zig").releaseModel;
const handle = @import("../../handle.zig");
const rhi = @import("../../rhi/rhi.zig");
const math = @import("../../math.zig");
const gltf = @import("../../asset/gltf.zig");
const gpu = @import("../gpu.zig");
const api = @import("../api.zig");
const renderer_state = @import("../state.zig");
const scene_update = @import("scene_update.zig");
const render = @import("../renderer.zig");
const restyleEntity = render.restyleEntity;
const transformOf = render.transformOf;
const moveEntity = render.moveEntity;
const queueEdit = render.queueEdit;
const queueEdits = render.queueEdits;
const tryLock = render.tryLock;
const markEntity = render.markEntity;
const markOf = render.markOf;
const followParent = render.followParent;

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
const SunDesc = api.SunDesc;
const LightDesc = api.LightDesc;
const EntityDesc = api.EntityDesc;
const EntityInfo = api.EntityInfo;
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
    internal: Internal,

    /// Not part of the API.
    pub const Internal = struct {
        table: handle.HandleTable(renderer_state.SceneData, api.SceneTag),

        /// Frees what one of them holds, as when the renderer is destroyed.
        pub fn free(owner: *Renderer, entry: *renderer_state.SceneData) void {
            freeScene(owner, entry);
        }
    };

    fn renderer(scenes: *Scenes) *Renderer {
        return @alignCast(@fieldParentPtr("scenes", scenes));
    }

    /// Sets the scene's volumetric cloud layer; null removes it. Drawn by
    /// views with `Settings.clouds` on.
    pub fn setClouds(scenes: *Scenes, scene: Scene, clouds: ?CloudDesc) !void {
        const self = scenes.renderer();
        self.lock();
        defer self.unlock();
        const data = self.scenes.internal.table.get(scene) orelse return;
        data.clouds = clouds;
    }

    /// Position and brightness of the lightning flash in the scene's clouds
    /// right now, if any.
    pub fn cloudFlash(scenes: *Scenes, scene: Scene) ?CloudFlash {
        const self = scenes.renderer();
        self.lock();
        defer self.unlock();
        const data = self.scenes.internal.table.get(scene) orelse return null;
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
    /// lighting. Handles from `Renderer.decals` for this scene stop resolving.
    pub fn setDecals(scenes: *Scenes, scene: Scene, decals: []const DecalDesc) !void {
        const self = scenes.renderer();
        self.lock();
        defer self.unlock();
        const data = self.scenes.internal.table.get(scene) orelse return;
        if (decals.len > max_decals) return error.TooManyDecals;
        self.decals.internal.forget(data);
        data.decals.clearRetainingCapacity();
        try data.decals.appendSlice(self.internal.gpa, decals);
    }

    /// Creates an empty scene: no entities or lights, sun off, no
    /// environment.
    pub fn create(scenes: *Scenes) !Scene {
        const self = scenes.renderer();
        self.lock();
        defer self.unlock();
        return self.scenes.internal.table.insert(.{});
    }

    /// Destroys the scene and every entity in it.
    pub fn destroy(scenes: *Scenes, scene: Scene) void {
        const self = scenes.renderer();
        self.lock();
        defer self.unlock();
        var removed = self.scenes.internal.table.remove(scene) orelse return;
        for (removed.entities.items) |entity| {
            const data = self.entities.internal.table.remove(entity) orelse continue;
            self.internal.entity_marks.items[entity.index] = .{};
            releaseModel(self, data.model);
            freeEntityStorage(self, data);
        }
        freeScene(self, &removed);
    }

    /// Replaces the scene's sun. `intensity` 0 turns it and its shadows off.
    pub fn setSun(scenes: *Scenes, scene: Scene, sun: SunDesc) void {
        const self = scenes.renderer();
        self.lock();
        defer self.unlock();
        const data = self.scenes.internal.table.get(scene) orelse return;
        // Probes forget slowly, and light bounced between bright surfaces
        // more slowly still, so a sun that jumps starts them over.
        const change = @abs(sun.intensity - data.sun.intensity);
        const strongest = @max(sun.intensity, data.sun.intensity);
        const turned = math.dot(math.normalize(sun.direction), math.normalize(data.sun.direction)) < 0.9;
        if ((change > 1 and change > 0.5 * strongest) or (turned and @min(sun.intensity, data.sun.intensity) > 1)) {
            for (&data.gi_cascades) |*slot| {
                if (slot.*) |*volume| volume.frames = 0;
            }
        }
        data.sun = sun;
    }

    /// Sets the HDR environment used for the sky and image-based lighting.
    pub fn setEnvironment(scenes: *Scenes, scene: Scene, desc: api.SceneEnvironment) void {
        const self = scenes.renderer();
        self.lock();
        defer self.unlock();
        if (self.scenes.internal.table.get(scene)) |data| {
            data.environment = desc.environment;
            data.environment_intensity = desc.intensity;
        }
    }

    /// Replaces the scene's lights. Handles from `Renderer.lights` for this
    /// scene stop resolving. Each cell of the view's light grid holds at most
    /// 127; where more reach one cell, the rest do not light it.
    pub fn setLights(scenes: *Scenes, scene: Scene, lights: []const LightDesc) !void {
        const self = scenes.renderer();
        self.lock();
        defer self.unlock();
        const data = self.scenes.internal.table.get(scene) orelse return;
        self.lights.internal.forget(data);
        data.lights.clearRetainingCapacity();
        try data.lights.appendSlice(self.internal.gpa, lights);
        data.lights_version += 1;
    }

    /// Moves everything in a scene by `offset` without it counting as motion,
    /// for keeping float precision in large worlds. The camera, draw lists
    /// and world-unit settings are the caller's to shift.
    pub fn shift(scenes: *Scenes, scene: Scene, offset: Vec3) !void {
        const self = scenes.renderer();
        self.lock();
        defer self.unlock();
        const data = self.scenes.internal.table.get(scene) orelse return;
        inline for (0..3) |axis| data.origin[axis] -= offset[axis];
        for (data.entities.items) |item| {
            const mark = markOf(self, item) orelse continue;
            if (mark.related) if (self.entities.internal.table.get(item)) |entity| if (entity.parent == null) {
                inline for (0..3) |axis| entity.local[12 + axis] += offset[axis];
            };
            inline for (0..3) |axis| {
                self.internal.entity_transforms.items[item.index][12 + axis] += offset[axis];
                self.internal.entity_previous.items[item.index][12 + axis] += offset[axis];
            }
        }
        data.records_valid = false;
        for (data.groups.items) |item| {
            const group = self.instances.internal.table.get(item) orelse continue;
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
            const emitter = self.emitters.internal.table.get(item) orelse continue;
            emitter.desc.position = math.add(emitter.desc.position, offset);
            emitter.shift = math.add(emitter.shift, offset);
        }
        for (data.fluids.items) |item| {
            const fluid = self.fluids.internal.table.get(item) orelse continue;
            inline for (0..3) |axis| fluid.desc.transform[12 + axis] += offset[axis];
        }
        for (data.waters.items) |item| {
            const water = self.waters.internal.table.get(item) orelse continue;
            inline for (0..3) |axis| water.desc.transform[12 + axis] += offset[axis];
        }
        if (data.gi_bounds) |*bounds| {
            bounds[0] = math.add(bounds[0], offset);
            bounds[1] = math.add(bounds[1], offset);
        }
        for (&data.gi_cascades) |*slot| {
            if (slot.*) |*volume| volume.origin = math.add(volume.origin, offset);
        }
    }

    /// The scene's zero in the application's world: minus the sum of every
    /// `scenes.shift` offset.
    pub fn origin(scenes: *Scenes, scene: Scene) [3]f64 {
        const self = scenes.renderer();
        self.lock();
        defer self.unlock();
        return if (self.scenes.internal.table.get(scene)) |data| data.origin else .{ 0, 0, 0 };
    }

    /// Pins the irradiance probe volume to a world-space box; null derives it
    /// from the scene's static geometry (the default).
    pub fn setGiVolume(scenes: *Scenes, scene: Scene, bounds: ?[2]Vec3) void {
        const self = scenes.renderer();
        self.lock();
        defer self.unlock();
        if (self.scenes.internal.table.get(scene)) |data| data.gi_bounds = bounds;
    }
};

pub fn freeScene(self: *Renderer, scene: *SceneData) void {
    scene.entities.deinit(self.internal.gpa);
    self.lights.internal.forget(scene);
    scene.lights.deinit(self.internal.gpa);
    scene.light_handles.deinit(self.internal.gpa);
    scene.shadow_grants.deinit(self.internal.gpa);
    for (scene.emitters.items) |emitter| if (self.emitters.internal.table.remove(emitter)) |removed| {
        self.device.destroyBuffer(removed.buffer);
        if (removed.order) |order| self.device.destroyBuffer(order);
        if (removed.trail) |trail| self.device.destroyBuffer(trail);
    };
    scene.emitters.deinit(self.internal.gpa);
    for (scene.probes.items) |probe| if (self.reflection_probes.internal.table.remove(probe)) |removed_probe| {
        var removed = removed_probe;
        freeProbe(self, &removed);
    };
    scene.probes.deinit(self.internal.gpa);
    for (scene.fluids.items) |fluid| if (self.fluids.internal.table.remove(fluid)) |removed| {
        var state = removed;
        destroyFluidTextures(self, &state);
    };
    scene.fluids.deinit(self.internal.gpa);
    for (scene.waters.items) |water| if (self.waters.internal.table.remove(water)) |removed| {
        for (removed.state) |texture| self.device.destroyTexture(texture);
        if (removed.ocean) |ocean| for (ocean) |buffer| self.device.destroyBuffer(buffer);
    };
    scene.waters.deinit(self.internal.gpa);
    for (scene.hairs.items) |hair| if (self.hairs.internal.table.remove(hair)) |removed| freeHair(self, removed);
    scene.hairs.deinit(self.internal.gpa);
    for (scene.liquids.items) |liquid| if (self.liquids.internal.table.remove(liquid)) |removed_liquid| {
        var removed = removed_liquid;
        removed.deinit(self.device);
    };
    scene.liquids.deinit(self.internal.gpa);
    if (scene.trace_nodes) |buffer| self.device.destroyBuffer(buffer);
    if (scene.trace_instances) |buffer| self.device.destroyBuffer(buffer);
    self.decals.internal.forget(scene);
    scene.decals.deinit(self.internal.gpa);
    scene.decal_handles.deinit(self.internal.gpa);
    scene.movers.deinit(self.internal.gpa);
    for (scene.groups.items) |group| if (self.instances.internal.table.remove(group)) |removed| {
        if (removed.impostor) |impostor| {
            self.device.destroyTexture(impostor.color);
            self.device.destroyTexture(impostor.normal);
        }
        self.internal.gpa.free(removed.transforms);
        self.internal.gpa.free(removed.tints);
        self.internal.gpa.free(removed.params);
        releaseModel(self, removed.model);
    };
    scene.groups.deinit(self.internal.gpa);
    scene.static_tlas.deinit(self.internal.gpa);
    for (scene.instance_slots) |slot| if (slot.buffer) |buffer| self.device.destroyBuffer(buffer);
    scene.transparent.deinit(self.internal.gpa);
    scene.static_transparent.deinit(self.internal.gpa);
    scene.layout.deinit(self.internal.gpa);
    scene.posed.deinit(self.internal.gpa);
    scene.entries.deinit(self.internal.gpa);
    scene.spheres.deinit(self.internal.gpa);
    scene.blended.deinit(self.internal.gpa);
    scene.glowing.deinit(self.internal.gpa);
    scene.chunk_bounds.deinit(self.internal.gpa);
    scene.chunk_stale.deinit(self.internal.gpa);
    scene.edited.deinit(self.internal.gpa);
    scene.settling.deinit(self.internal.gpa);
    if (scene.previous) |buffer| self.device.destroyBuffer(buffer);
    if (scene.tlas_instances) |buffer| self.device.destroyBuffer(buffer);
    if (scene.refs) |buffer| self.device.destroyBuffer(buffer);
    scene.static_ranges.deinit(self.internal.gpa);
    scene.instance_ranges.free_ranges.deinit(self.internal.gpa);
    scene.ref_ranges.free_ranges.deinit(self.internal.gpa);
    scene.tlas_ranges.free_ranges.deinit(self.internal.gpa);
    scene.added.deinit(self.internal.gpa);
    scene.removed.deinit(self.internal.gpa);
    scene.quarantine.deinit(self.internal.gpa);
    scene.skin_jobs.deinit(self.internal.gpa);
    scene.skin_weights.deinit(self.internal.gpa);
    scene.bounds_jobs.deinit(self.internal.gpa);
    scene.blas_jobs.deinit(self.internal.gpa);
    if (scene.static_cull) |buffer| self.device.destroyBuffer(buffer);
    if (scene.impostor_table) |buffer| self.device.destroyBuffer(buffer);
    if (scene.impostor_list) |buffer| self.device.destroyBuffer(buffer);
    if (scene.candidates) |buffer| self.device.destroyBuffer(buffer);
    if (scene.seen) |buffer| self.device.destroyBuffer(buffer);
    for (scene.seen_readback) |readback| if (readback) |buffer| self.device.destroyBuffer(buffer);
    if (scene.skin_bounds) |buffer| self.device.destroyBuffer(buffer);
    if (scene.tlas) |tlas| self.device.destroyAcceleration(tlas);
    for (scene.gi_cascades) |slot| {
        if (slot) |volume| volume.deinit(self.device);
    }
}

/// Placements of models in scenes.
pub const Entities = struct {
    internal: Internal,

    /// Not part of the API.
    pub const Internal = struct {
        table: handle.HandleTable(renderer_state.EntityData, api.EntityTag),

        /// Frees what one of them holds, as when the renderer is destroyed.
        pub fn free(owner: *Renderer, entry: *renderer_state.EntityData) void {
            freeEntityStorage(owner, entry.*);
        }
    };

    fn renderer(entities: *Entities) *Renderer {
        return @alignCast(@fieldParentPtr("entities", entities));
    }

    /// Adds an entity; the model may still be loading. The entity holds a
    /// reference to the model until `destroy` or `scenes.destroy`. Fails with
    /// `error.InvalidScene` or `error.InvalidModel` for a stale handle.
    pub fn create(entities: *Entities, scene: Scene, desc: EntityDesc) !Entity {
        const self = entities.renderer();
        self.lock();
        defer self.unlock();
        const scene_data = self.scenes.internal.table.get(scene) orelse return error.InvalidScene;
        const model = self.models.internal.table.get(desc.model) orelse return error.InvalidModel;
        if (model.orphaned) return error.InvalidModel;
        const entity = try self.entities.internal.table.insert(.{
            .scene = scene,
            .model = desc.model,
            .visible = desc.visible,
            .tint = packTint(desc.tint),
            .params = desc.params,
            .receive_decals = desc.receive_decals,
        });
        errdefer _ = self.entities.internal.table.remove(entity);
        try markEntity(self, entity, scene, desc.transform);
        errdefer self.internal.entity_marks.items[entity.index] = .{};
        try scene_data.entities.append(self.internal.gpa, entity);
        self.internal.entity_marks.items[entity.index].listed_at = @intCast(scene_data.entities.items.len - 1);
        model.references += 1;
        scene_data.added.append(self.internal.gpa, entity) catch {
            scene_data.layout_dirty = true;
        };
        return entity;
    }

    /// Removes an entity and releases its model reference. A stale handle is
    /// ignored.
    pub fn destroy(entities: *Entities, entity: Entity) void {
        const self = entities.renderer();
        self.lock();
        defer self.unlock();
        unlinkEntity(self, entity);
        const data = self.entities.internal.table.remove(entity) orelse return;
        const listed_at = self.internal.entity_marks.items[entity.index].listed_at;
        const span = self.internal.entity_spans.items[entity.index];
        self.internal.entity_marks.items[entity.index] = .{};
        self.internal.entity_spans.items[entity.index] = .{};
        if (self.scenes.internal.table.get(data.scene)) |scene| {
            if (listed_at < scene.entities.items.len and std.meta.eql(scene.entities.items[listed_at], entity)) {
                _ = scene.entities.swapRemove(listed_at);
                if (listed_at < scene.entities.items.len) self.internal.entity_marks.items[scene.entities.items[listed_at].index].listed_at = listed_at;
            } else for (scene.entities.items, 0..) |candidate, index| if (std.meta.eql(candidate, entity)) {
                _ = scene.entities.orderedRemove(index);
                for (scene.entities.items[index..], index..) |after, at| self.internal.entity_marks.items[after.index].listed_at = @intCast(at);
                break;
            };
            scene_update.forgetEntity(self, scene, span);
        }
        releaseModel(self, data.model);
        freeEntityStorage(self, data);
    }

    /// Sets the model-to-world transform, or to its parent's space once it has
    /// one (`setParent`). The change from last frame counts
    /// as motion; use `teleport` for a jump that should not.
    pub fn setTransform(entities: *Entities, entity: Entity, transform: Mat4) void {
        const self = entities.renderer();
        if (!tryLock(self)) return queueEdit(self, entity, .{ .transform = transform });
        defer self.unlock();
        moveEntity(self, entity, transform, false);
    }

    /// `setTransform` for many entities at once; the slices pair up, and the
    /// longer one's extra items are ignored.
    pub fn setTransforms(entities: *Entities, handles: []const Entity, transforms: []const Mat4) void {
        const self = entities.renderer();
        const count = @min(handles.len, transforms.len);
        if (!tryLock(self)) return queueTransforms(self, handles[0..count], transforms[0..count]);
        defer self.unlock();
        for (handles[0..count], transforms[0..count]) |entity, transform| moveEntity(self, entity, transform, false);
    }

    /// Like `setTransform`, but resets motion history.
    pub fn teleport(entities: *Entities, entity: Entity, transform: Mat4) void {
        const self = entities.renderer();
        if (!tryLock(self)) return queueEdit(self, entity, .{ .teleport = transform });
        defer self.unlock();
        moveEntity(self, entity, transform, true);
    }

    /// Changes the color an entity's materials are multiplied by.
    pub fn setTint(entities: *Entities, entity: Entity, tint: [3]f32) void {
        const self = entities.renderer();
        if (!tryLock(self)) return queueEdit(self, entity, .{ .tint = packTint(tint) });
        defer self.unlock();
        const data = self.entities.internal.table.get(entity) orelse return;
        if (data.tint == packTint(tint)) return;
        data.tint = packTint(tint);
        restyleEntity(self, entity);
    }

    /// Sets the entity's `MaterialContext.instance_params`.
    pub fn setParams(entities: *Entities, entity: Entity, params: [4]f32) void {
        const self = entities.renderer();
        if (!tryLock(self)) return queueEdit(self, entity, .{ .params = params });
        defer self.unlock();
        const data = self.entities.internal.table.get(entity) orelse return;
        if (std.mem.eql(f32, &data.params, &params)) return;
        data.params = params;
        restyleEntity(self, entity);
    }

    /// Overrides morph target weights (up to 64, in model order) on every
    /// mesh that has any; null returns them to the animation. Only skinned
    /// meshes morph.
    pub fn setMorphWeights(entities: *Entities, entity: Entity, weights: ?[]const f32) void {
        const self = entities.renderer();
        self.lock();
        defer self.unlock();
        const data = self.entities.internal.table.get(entity) orelse return;
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
        const data = self.entities.internal.table.get(entity) orelse return;
        const scene = self.scenes.internal.table.get(data.scene) orelse return;
        if (data.lightmap) |old| {
            for (old.gathered) |texture| self.device.destroyTexture(texture);
            self.device.destroyTexture(old.shown);
            data.lightmap = null;
        }
        const wanted = desc orelse return;
        if (!self.device.caps.ray_tracing) return error.RayTracingUnavailable;
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
        const data = self.entities.internal.table.get(entity) orelse return null;
        const lightmap = data.lightmap orelse return null;
        return @as(f32, @floatFromInt(@min(lightmap.rounds, lightmap.wanted))) / @as(f32, @floatFromInt(lightmap.wanted));
    }

    /// Shows or hides an entity. A hidden entity is not drawn and casts no
    /// shadows; showing it again resets its motion history.
    pub fn setVisible(entities: *Entities, entity: Entity, visible: bool) void {
        const self = entities.renderer();
        self.lock();
        defer self.unlock();
        const data = self.entities.internal.table.get(entity) orelse return;
        if (data.visible == visible) return;
        data.visible = visible;
        data.history_frames = 0;
        const scene = self.scenes.internal.table.get(data.scene) orelse return;
        if (visible) {
            scene.added.append(self.internal.gpa, entity) catch {
                scene.layout_dirty = true;
            };
            return;
        }
        const mark = &self.internal.entity_marks.items[entity.index];
        scene_update.forgetEntity(self, scene, self.internal.entity_spans.items[entity.index]);
        self.internal.entity_spans.items[entity.index] = .{};
        mark.layout_first = 0;
        mark.layout_count = 0;
    }

    /// Sets the animation pose. Null returns the model to its rest pose.
    pub fn setPose(entities: *Entities, entity: Entity, pose: ?Pose) void {
        const self = entities.renderer();
        if (!tryLock(self)) return queueEdit(self, entity, .{ .pose = pose });
        defer self.unlock();
        if (self.entities.internal.table.get(entity)) |data| data.pose = pose;
    }

    /// Makes `entity` move with `parent`, which must be in the same scene
    /// and not follow `entity` itself (`error.InvalidParent`); null lets it
    /// go. From here on `setTransform` and the transform it was last given
    /// place it relative to the parent; the jump this makes is not motion.
    /// When the parent is destroyed its children stay where they are.
    pub fn setParent(entities: *Entities, entity: Entity, parent: ?Entity) !void {
        const self = entities.renderer();
        self.lock();
        defer self.unlock();
        const data = self.entities.internal.table.get(entity) orelse return error.InvalidEntity;
        if (parent) |new_parent| {
            const parent_data = self.entities.internal.table.get(new_parent) orelse return error.InvalidParent;
            if (!std.meta.eql(parent_data.scene, data.scene)) return error.InvalidParent;
            var above: ?Entity = new_parent;
            while (above) |ancestor| : (above = self.entities.internal.table.get(ancestor).?.parent) {
                if (std.meta.eql(ancestor, entity)) return error.InvalidParent;
            }
            if (data.parent) |old| if (std.meta.eql(old, new_parent)) return;
            try parent_data.children.ensureUnusedCapacity(self.internal.gpa, 1);
        } else if (data.parent == null) return;
        if (!markOf(self, entity).?.related) data.local = transformOf(self, entity);
        detachEntity(self, entity, data);
        data.parent = parent;
        if (parent) |new_parent| {
            const parent_data = self.entities.internal.table.get(new_parent).?;
            parent_data.children.appendAssumeCapacity(entity);
            const parent_mark = markOf(self, new_parent).?;
            if (!parent_mark.related) parent_data.local = transformOf(self, new_parent);
            parent_mark.related = true;
        }
        markOf(self, entity).?.related = data.parent != null or data.children.items.len != 0;
        followParent(self, entity, data, true);
    }

    /// What an entity is and where; null for a stale handle.
    pub fn info(entities: *Entities, entity: Entity) ?EntityInfo {
        const self = entities.renderer();
        self.lock();
        defer self.unlock();
        const data = self.entities.internal.table.get(entity) orelse return null;
        const mark = markOf(self, entity) orelse return null;
        var tint: [3]f32 = undefined;
        inline for (0..3) |channel| tint[channel] = @as(f32, @floatFromInt(data.tint >> (channel * 8) & 0xff)) / 255;
        return .{
            .scene = data.scene,
            .model = data.model,
            .transform = if (mark.related) data.local else transformOf(self, entity),
            .world_transform = transformOf(self, entity),
            .parent = data.parent,
            .visible = data.visible,
            .tint = tint,
            .params = data.params,
            .receive_decals = data.receive_decals,
            .pose = data.pose,
        };
    }
};

/// Takes an entity off its parent's list of children.
fn detachEntity(self: *Renderer, entity: Entity, data: *EntityData) void {
    const old = data.parent orelse return;
    data.parent = null;
    const parent_data = self.entities.internal.table.get(old) orelse return;
    for (parent_data.children.items, 0..) |child, index| if (std.meta.eql(child, entity)) {
        _ = parent_data.children.swapRemove(index);
        break;
    };
    if (markOf(self, old)) |mark| mark.related = parent_data.parent != null or parent_data.children.items.len != 0;
}

/// Before an entity is destroyed: off its parent, and its children left
/// where they are.
fn unlinkEntity(self: *Renderer, entity: Entity) void {
    const data = self.entities.internal.table.get(entity) orelse return;
    const mark = markOf(self, entity) orelse return;
    if (!mark.related) return;
    detachEntity(self, entity, data);
    for (data.children.items) |child| if (self.entities.internal.table.get(child)) |child_data| {
        child_data.parent = null;
        child_data.local = transformOf(self, child);
        if (markOf(self, child)) |child_mark| child_mark.related = child_data.children.items.len != 0;
    };
    data.children.clearRetainingCapacity();
    mark.related = false;
}

/// Queues transforms a chunk at a time, so that the queue is not held long.
fn queueTransforms(self: *Renderer, handles: []const Entity, transforms: []const Mat4) void {
    var edits: [64]renderer_state.EntityEdit = undefined;
    var done: usize = 0;
    while (done < handles.len) {
        const count = @min(edits.len, handles.len - done);
        for (edits[0..count], handles[done..][0..count], transforms[done..][0..count]) |*edit, entity, transform| {
            edit.* = .{ .entity = entity, .change = .{ .transform = transform } };
        }
        queueEdits(self, edits[0..count]);
        done += count;
    }
}

pub fn freeEntityStorage(self: *Renderer, entity: EntityData) void {
    if (entity.lightmap) |lightmap| {
        for (lightmap.gathered) |texture| self.device.destroyTexture(texture);
        self.device.destroyTexture(lightmap.shown);
    }
    if (self.models.internal.table.get(entity.model)) |model| {
        if (model.source) |source| for (entity.skin_offsets, 0..) |offset, index| {
            if (offset == no_skin) continue;
            self.internal.vertices.free(self, offset, model.meshes[source.instances[index].mesh].vertex_count * 2);
        };
    }
    var children = entity.children;
    children.deinit(self.internal.gpa);
    self.internal.gpa.free(entity.skin_offsets);
    for (entity.skin_blas) |blas| if (blas) |value| self.device.destroyAcceleration(value);
    self.internal.gpa.free(entity.skin_blas);
    self.internal.gpa.free(entity.bounds_offsets);
    self.internal.gpa.free(entity.node_world);
    self.internal.gpa.free(entity.previous_node_world);
}

/// Allocates per-entity animation state once its model is ready.
pub fn resolveEntity(self: *Renderer, entity: *EntityData, model: *ModelEntry) !void {
    if (entity.resolved) return;
    const source = &model.source.?;
    const gpa = self.internal.gpa;
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
        offset.* = try self.internal.vertices.alloc(self, mesh.vertex_count * 2);
    }
    entity.history_frames = 0;
    entity.resolved = true;
}

/// The entity whose pose a group's copies take, if posed this frame.
pub fn groupDriver(self: *Renderer, group: *const InstanceGroupData, model_instances: usize) ?*EntityData {
    const entity = self.entities.internal.table.get(group.driver orelse return null) orelse return null;
    if (!entity.visible or !entity.resolved) return null;
    if (!std.meta.eql(entity.model, group.model) or !std.meta.eql(entity.scene, group.scene)) return null;
    if (entity.skin_offsets.len != model_instances) return null;
    return entity;
}
