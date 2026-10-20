//! Sorts a view's local lights and decals into clusters for shading to look up.
const rhi = @import("../../rhi/rhi.zig");
const pipelines_module = @import("../renderer/pipelines.zig");
const cluster_push = @import("../shaders/push/cluster.zig");
const features = @import("../core/features.zig");
const prepareLights = @import("../renderer/scene_update.zig").prepareLights;
const scene_pass = @import("../scene_pass.zig");
const ray_scene = @import("../scene/ray_scene.zig");
const renderer_state = @import("../state.zig");
const gpu = @import("../gpu.zig");
const std = @import("std");

const cluster_far = renderer_state.cluster_far;
const cluster_near = renderer_state.cluster_near;
const ViewContext = features.ViewContext;

/// Adds the feature's passes to a view of a scene. A path traced view leaves
/// out those whose result the tracer replaces.
/// Lists the scene's lights for this view and which of them cast shadows.
pub fn prepare(ctx: *ViewContext) !void {
    const p = ctx.scene orelse return;
    const settings = p.settings;
    const traced = (if (settings.shadows) |shadows| shadows.traced_lights else false) and ray_scene.ready(p.scene, p.scene_frame);
    const lighting = try ctx.make(scene_pass.Lighting);
    lighting.* = try prepareLights(ctx.renderer, p.scene, p.arena, settings.shadows != null, p.desc.camera.position, traced);
    p.shared.lighting = lighting;
    const c = ctx.constants;
    c.lights.light_count = lighting.light_count;
    c.lights.lights = lighting.lights;
    c.lights.shadow_tiles = lighting.tiles;
    c.lights.clusters = ctx.device.bufferAddress(ctx.renderer.internal.clusters);
    c.lights.cluster_z_scale = renderer_state.cluster_z_scale;
    c.lights.cluster_z_bias = -@log2(renderer_state.cluster_near) * renderer_state.cluster_z_scale;
}

pub fn declare(ctx: *ViewContext) !void {
    if (ctx.scene == null) return;
    const g = ctx.graph;
    try g.add(.{ .name = "light clusters", .stage = .lighting, .always = true, .scope = false }, ctx, clusterLights);
}

fn clusterLights(ctx: *ViewContext) !void {
    const p = ctx.scene.?;
    const c = p.shared;
    const self = ctx.renderer;
    const cmd = p.cmd;
    if (c.lighting.light_count == 0 and p.scene.decals.items.len == 0) return;
    cmd.beginScope("light clusters");
    cmd.bindPipeline(try self.internal.pipelines.of(clusterPipeline));
    cmd.pushConstants(cluster_push.Push{
        .frame = p.frame_address,
        .z_near = cluster_near,
        .z_ratio = std.math.pow(f32, cluster_far / cluster_near, 1.0 / @as(f32, gpu.clusters_z)),
    });
    cmd.dispatch((gpu.cluster_count + 63) / 64, 1, 1);
    cmd.sync(.compute_to_all);
    cmd.endScope();
}

fn clusterPipeline(_: *rhi.Device) pipelines_module.Desc {
    return .{ .compute = .{ .name = "light clusters", .shader = pipelines_module.shaderCode("cluster.comp.spv") } };
}
