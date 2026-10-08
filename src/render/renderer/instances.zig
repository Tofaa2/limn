//! Instance groups. Internal to the renderer.
const std = @import("std");
const math = @import("../../math.zig");
const api = @import("../api.zig");
const renderer_state = @import("../state.zig");
const impostor_passes = @import("../passes/impostors.zig");
const render = @import("../renderer.zig");

const Renderer = render.Renderer;
const Mat4 = math.Mat4;
const Model = api.Model;
const Scene = api.Scene;
const Entity = api.Entity;
const ImpostorDesc = api.ImpostorDesc;
const InstanceGroup = api.InstanceGroup;
const packTint = renderer_state.packTint;

/// Places many static copies of a model, stored on the GPU. They do not
/// animate and blended meshes are skipped. They take part in probe GI
/// while the scene holds at most `Options.gi_instance_limit` of them.
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
        scene.static_version += 1;
        return;
    }
    const copy = try self.gpa.dupe(Mat4, transforms);
    self.gpa.free(data.transforms);
    data.transforms = copy;
    scene.layout_dirty = true;
}

/// Per-copy colors multiplied with the base color, one per transform; an
/// empty slice removes them. Set again after the copy count changes.
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

/// Per-copy `MaterialContext.instance_params`, one per transform; an
/// empty slice removes them. Set again after the copy count changes.
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

/// Draws copies smaller on screen than `ImpostorDesc.pixels` as impostor
/// cards; null turns that off. Only for single-mesh models; groups that
/// take an entity's pose are never impostors.
pub fn setInstancesImpostor(self: *Renderer, group: InstanceGroup, desc: ?ImpostorDesc) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const data = self.instance_groups.get(group) orelse return error.InvalidInstanceGroup;
    const scene = self.scenes.get(data.scene) orelse return error.InvalidScene;
    if (data.impostor) |old| {
        self.device.destroyTexture(old.color);
        self.device.destroyTexture(old.normal);
        data.impostor = null;
    }
    scene.static_version += 1;
    const wanted = desc orelse return;
    const resolution = std.math.clamp(wanted.resolution, 16, 256);
    const size = resolution * impostor_passes.frames;
    const color = try self.device.createTexture(.{ .name = "impostor color", .width = size, .height = size, .format = .rgba8_srgb, .usage = .{ .sampled = true, .color_attachment = true } });
    errdefer self.device.destroyTexture(color);
    const normal = try self.device.createTexture(.{ .name = "impostor normal", .width = size, .height = size, .format = .rgba8_unorm, .usage = .{ .sampled = true, .color_attachment = true } });
    data.impostor = .{ .color = color, .normal = normal, .pixels = @max(wanted.pixels, 0), .resolution = resolution };
}

/// Makes every copy take the pose of `entity`, a visible entity of the
/// same model in the same scene; null gives the rest pose. Posed copies
/// do not take part in ray tracing.
pub fn setInstancesPose(self: *Renderer, group: InstanceGroup, entity: ?Entity) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const data = self.instance_groups.get(group) orelse return;
    const scene = self.scenes.get(data.scene) orelse return;
    data.driver = entity;
    scene.static_version += 1;
}

/// A stale handle is ignored.
pub fn destroyInstances(self: *Renderer, group: InstanceGroup) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const removed = self.instance_groups.remove(group) orelse return;
    if (removed.impostor) |impostor| {
        self.device.destroyTexture(impostor.color);
        self.device.destroyTexture(impostor.normal);
    }
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
