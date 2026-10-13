//! A scene's ray tracing structure: made when a view first asks for rays and
//! rebuilt once a frame when the instances in it changed. Global illumination,
//! traced reflections and shadows, path tracing, lightmaps and fluid obstacles
//! all trace it; none of them owns it. Internal to the renderer.
const std = @import("std");
const filled = @import("../api.zig").filled;
const rhi = @import("../../rhi/rhi.zig");
const api = @import("../api.zig");
const render = @import("../renderer.zig");
const scene_pass = @import("../scene_pass.zig");

const Renderer = render.Renderer;
const SceneData = render.SceneData;
const SceneFrame = scene_pass.SceneFrame;
const Settings = api.Settings;

/// Whether a view with these settings traces rays through `scene`.
pub fn wanted(renderer: *Renderer, scene: *const SceneData, settings: Settings) bool {
    if (!renderer.device.caps.ray_tracing) return false;
    if ((settings.global_illumination != null) or (settings.path_tracing != null) or (if (settings.shadows) |shadows| shadows.traced_lights else false)) return true;
    if ((settings.reflections != null) and filled(settings.reflections).ray_tracing) return true;
    if (scene.lightmaps_baking != 0) return true;
    for (scene.fluids.items) |handle| {
        const fluid = renderer.fluids.table.get(handle) orelse continue;
        if (fluid.desc.scene_obstacles) return true;
    }
    return false;
}

/// Makes or grows the structure for this frame's instances. Only the first
/// view to draw the scene in a frame may make it, since the acceleration
/// structures of animated meshes are rebuilt for it then; a later view's
/// request is kept for the next frame.
pub fn prepare(renderer: *Renderer, scene: *SceneData, scene_frame: SceneFrame, want: bool, fresh_scene: bool) !void {
    if (want) scene.rays_wanted = true;
    if (!scene.rays_wanted or scene_frame.tlas_count == 0) return;
    if (scene.tlas != null and scene.tlas_capacity >= scene_frame.tlas_count) return;
    if (!fresh_scene) return;
    const device = renderer.device;
    if (scene.tlas) |old| device.destroyAcceleration(old);
    scene.tlas = null;
    scene.tlas_hash = 0;
    scene.tlas_capacity = @max(scene_frame.tlas_count * 2, 256);
    scene.tlas = try device.createTlas(scene.tlas_capacity);
}

/// Rebuilds the structure if its instances changed since it was last built.
/// After the frame's animated meshes are rebuilt and before anything traces.
pub fn build(cmd: *rhi.CommandEncoder, scene: *SceneData, scene_frame: SceneFrame) void {
    const tlas = scene.tlas orelse return;
    if (scene_frame.tlas_count == 0 or scene_frame.tlas_count > scene.tlas_capacity) return;
    if (scene.tlas_hash == scene_frame.tlas_hash) return;
    cmd.beginScope("ray scene");
    defer cmd.endScope();
    cmd.buildTlas(tlas, scene_frame.tlas_instances, scene_frame.tlas_count);
    scene.tlas_hash = scene_frame.tlas_hash;
}

/// The structure, once it holds this frame's instances.
pub fn current(scene: *const SceneData, scene_frame: SceneFrame) ?rhi.AccelerationStructure {
    const tlas = scene.tlas orelse return null;
    if (scene.tlas_hash == 0 or scene.tlas_hash != scene_frame.tlas_hash) return null;
    return tlas;
}

/// Whether `build` will leave a structure for this frame's instances.
pub fn ready(scene: *const SceneData, scene_frame: SceneFrame) bool {
    return scene.tlas != null and scene_frame.tlas_count != 0 and scene_frame.tlas_count <= scene.tlas_capacity;
}
