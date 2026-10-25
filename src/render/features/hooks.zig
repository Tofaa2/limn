//! The application's own passes, run at the points of a view's frame they ask for.
const std = @import("std");
const rhi = @import("../../rhi/rhi.zig");
const api = @import("../api.zig");
const math = @import("../../math.zig");
const features = @import("../core/features.zig");
const renderer_state = @import("../state.zig");
const view_math = @import("../renderer/view_math.zig");

const ViewContext = features.ViewContext;

/// Whether any of the view's passes draws into the picture before tone mapping.
pub fn lit(desc: *const api.ViewDesc) bool {
    for (desc.passes) |pass| switch (pass.stage) {
        .after_opaque, .after_transparency, .after_resolve => return true,
        .after_tonemap, .sun_shadow, .light_shadow => {},
    };
    return false;
}

/// Whether a pass of the view at `stage` draws casters that move.
pub fn movingCasters(desc: *const api.ViewDesc, stage: api.PassStage) bool {
    for (desc.passes) |pass| if (pass.stage == stage and pass.moving) return true;
    return false;
}

/// Runs the view's `.light_shadow` passes into each tile of `atlas` that
/// `dirty` marks; `tile_size` texels a side, `per_side` tiles a row.
pub fn lightShadows(ctx: *ViewContext, atlas: rhi.Texture, view_proj: []const math.Mat4, dirty: []const bool, tile_size: u32, per_side: u32) !void {
    if (!wants(ctx.desc, .light_shadow)) return;
    const info = ctx.device.textureInfo(atlas);
    for (view_proj, dirty, 0..) |matrix, wanted, tile| {
        if (!wanted) continue;
        for (ctx.desc.passes) |pass| {
            if (pass.stage != .light_shadow) continue;
            ctx.cmd.beginScope("custom pass");
            defer ctx.cmd.endScope();
            try pass.run(pass.context, .{
                .cmd = ctx.cmd,
                .device = ctx.device,
                .stage = .light_shadow,
                .frame = ctx.frame_address,
                .color = atlas,
                .color_format = info.format,
                .depth = atlas,
                .motion = null,
                .width = tile_size,
                .height = tile_size,
                .origin = .{ @intCast(tile % per_side * tile_size), @intCast(tile / per_side * tile_size) },
                .camera = ctx.desc.camera,
                .view = math.identity,
                .projection = matrix,
                .view_projection = matrix,
                .settings = ctx.settings,
            });
        }
    }
}

/// Runs the view's `.sun_shadow` passes into each cascade of `map` that
/// `update` marks.
pub fn sunShadows(ctx: *ViewContext, map: rhi.Texture, view_proj: []const math.Mat4, update: []const bool) !void {
    if (!wants(ctx.desc, .sun_shadow)) return;
    const info = ctx.device.textureInfo(map);
    for (view_proj, update, 0..) |matrix, wanted, cascade| {
        if (!wanted) continue;
        for (ctx.desc.passes) |pass| {
            if (pass.stage != .sun_shadow) continue;
            ctx.cmd.beginScope("custom pass");
            defer ctx.cmd.endScope();
            try pass.run(pass.context, .{
                .cmd = ctx.cmd,
                .device = ctx.device,
                .stage = .sun_shadow,
                .frame = ctx.frame_address,
                .color = map,
                .color_format = info.format,
                .depth = map,
                .motion = null,
                .width = info.width,
                .height = info.height,
                .layer = @intCast(cascade),
                .camera = ctx.desc.camera,
                .view = math.identity,
                .projection = matrix,
                .view_projection = matrix,
                .settings = ctx.settings,
            });
        }
    }
}

fn wants(desc: *const api.ViewDesc, stage: api.PassStage) bool {
    for (desc.passes) |pass| if (pass.stage == stage) return true;
    return false;
}

fn slotOf(read: api.PassRead) features.graph.Slot {
    return switch (read) {
        .depth => .depth,
        .motion => .motion,
        .visibility => .visibility,
        .ambient_occlusion => .ambient_occlusion,
    };
}

/// The targets the passes of `stage` read that the view has.
const Reads = struct {
    targets: [std.enums.values(api.PassRead).len]features.Target = undefined,
    count: usize = 0,

    fn of(ctx: *ViewContext, stage: api.PassStage) !*Reads {
        const reads = try ctx.make(Reads);
        reads.* = .{};
        for (std.enums.values(api.PassRead)) |read| {
            const wanted = for (ctx.desc.passes) |pass| {
                if (pass.stage == stage and std.mem.indexOfScalar(api.PassRead, pass.reads, read) != null) break true;
            } else false;
            if (!wanted) continue;
            const target = ctx.graph.slot(slotOf(read)) orelse continue;
            reads.targets[reads.count] = target;
            reads.count += 1;
        }
        return reads;
    }

    fn slice(self: *const Reads) []const features.Target {
        return self.targets[0..self.count];
    }
};

pub fn declare(ctx: *ViewContext) !void {
    const g = ctx.graph;
    const desc = ctx.desc;
    if (desc.passes.len == 0) return;
    if (ctx.scene) |p| {
        if (wants(desc, .after_opaque) and !p.tracing)
            try g.add(.{ .name = "after opaque", .stage = .after_opaque, .reads = (try Reads.of(ctx, .after_opaque)).slice(), .always = true, .scope = false }, ctx, afterOpaque);
        if (wants(desc, .after_transparency))
            try g.add(.{ .name = "after transparency", .stage = .after_transparency, .reads = (try Reads.of(ctx, .after_transparency)).slice(), .always = true, .scope = false }, ctx, afterTransparency);
        if (wants(desc, .after_resolve))
            try g.add(.{ .name = "after resolve", .stage = .resolved, .reads = (try Reads.of(ctx, .after_resolve)).slice(), .always = true, .scope = false }, ctx, afterResolve);
        if (wants(desc, .after_tonemap))
            try g.add(.{ .name = "after tone mapping", .stage = .after_tonemap, .reads = (try Reads.of(ctx, .after_tonemap)).slice(), .always = true, .scope = false }, ctx, afterTonemap);
        return;
    }
    if (g.slot(.hdr)) |hdr| {
        if (lit(desc)) try g.add(.{ .name = "before tone mapping", .stage = .resolved, .writes = &.{hdr}, .always = true, .scope = false }, ctx, flatBeforeTonemap);
    }
    if (wants(desc, .after_tonemap))
        try g.add(.{ .name = "after tone mapping", .stage = .after_tonemap, .writes = &.{g.slot(.picture).?}, .always = true, .scope = false }, ctx, flatAfterTonemap);
}

fn afterOpaque(ctx: *ViewContext) !void {
    const p = ctx.scene.?;
    try run(ctx, .after_opaque, p.view.hdr, renderer_state.hdr_format, p.width, p.height);
}

fn afterTransparency(ctx: *ViewContext) !void {
    const p = ctx.scene.?;
    try run(ctx, .after_transparency, p.view.hdr, renderer_state.hdr_format, p.width, p.height);
}

fn afterResolve(ctx: *ViewContext) !void {
    const picture = ctx.scene.?.resolved.*;
    const info = ctx.device.textureInfo(picture);
    try run(ctx, .after_resolve, picture, info.format, info.width, info.height);
}

fn afterTonemap(ctx: *ViewContext) !void {
    const p = ctx.scene.?;
    try run(ctx, .after_tonemap, ctx.output.texture, ctx.output.format, p.output_width, p.output_height);
}

fn flatBeforeTonemap(ctx: *ViewContext) !void {
    const hdr = ctx.graph.texture(ctx.graph.slot(.hdr).?);
    const region = ctx.output.region;
    try run(ctx, .after_opaque, hdr, renderer_state.hdr_format, region.width, region.height);
    try run(ctx, .after_transparency, hdr, renderer_state.hdr_format, region.width, region.height);
    try run(ctx, .after_resolve, hdr, renderer_state.hdr_format, region.width, region.height);
}

fn flatAfterTonemap(ctx: *ViewContext) !void {
    const region = ctx.output.region;
    try run(ctx, .after_tonemap, ctx.graph.texture(ctx.graph.slot(.picture).?), ctx.output.format, region.width, region.height);
}

/// Runs the passes of `stage`, which draw into `color`.
fn run(ctx: *ViewContext, stage: api.PassStage, color: rhi.Texture, color_format: rhi.Format, width: u32, height: u32) !void {
    const cmd = ctx.cmd;
    const camera = ctx.desc.camera;
    const depth: ?rhi.Texture = if (ctx.scene) |p| p.view.depth else null;
    const motion: ?rhi.Texture = if (ctx.scene) |p| p.view.motion else null;
    const view: math.Mat4 = if (ctx.scene != null) ctx.constants.view else math.lookTo(camera.position, camera.forward, camera.up);
    const projection: math.Mat4 = if (ctx.scene != null)
        ctx.constants.proj
    else
        view_math.cameraProjection(camera, @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(@max(height, 1))));
    for (ctx.desc.passes) |pass| {
        if (pass.stage != stage) continue;
        const reads = struct {
            fn texture(context: *ViewContext, wanted: []const api.PassRead, read: api.PassRead) ?rhi.Texture {
                if (std.mem.indexOfScalar(api.PassRead, wanted, read) == null) return null;
                return context.graph.texture(context.graph.slot(slotOf(read)) orelse return null);
            }
        };
        cmd.beginScope("custom pass");
        defer cmd.endScope();
        try pass.run(pass.context, .{
            .cmd = cmd,
            .device = ctx.device,
            .stage = stage,
            .frame = ctx.frame_address,
            .color = color,
            .color_format = color_format,
            .depth = depth,
            .motion = motion,
            .visibility = reads.texture(ctx, pass.reads, .visibility),
            .ambient_occlusion = reads.texture(ctx, pass.reads, .ambient_occlusion),
            .width = width,
            .height = height,
            .camera = camera,
            .view = view,
            .projection = projection,
            .view_projection = math.mul(projection, view),
            .settings = ctx.settings,
        });
    }
}
