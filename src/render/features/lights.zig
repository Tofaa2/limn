//! Sorts a view's local lights and decals into clusters for shading to look up.
const features = @import("../core/features.zig");
const renderer_state = @import("../state.zig");
const gpu = @import("../gpu.zig");
const std = @import("std");

const cluster_far = renderer_state.cluster_far;
const cluster_near = renderer_state.cluster_near;
const ViewContext = features.ViewContext;

/// Adds the feature's passes to a view of a scene. A path traced view leaves
/// out those whose result the tracer replaces.
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
    cmd.bindPipeline(try self.pipelines.get(.cluster));
    cmd.pushConstants(extern struct { frame: u64, z_near: f32, z_ratio: f32 }{
        .frame = p.frame_address,
        .z_near = cluster_near,
        .z_ratio = std.math.pow(f32, cluster_far / cluster_near, 1.0 / @as(f32, gpu.clusters_z)),
    });
    cmd.dispatch((gpu.cluster_count + 63) / 64, 1, 1);
    cmd.sync(.compute_to_all);
    cmd.endScope();
}
