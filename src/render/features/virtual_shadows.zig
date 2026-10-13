//! The sun's virtual shadow map (see vsm.glsl): per-view pages and atlas, page
//! requests, allocation and drawing.
const geometry_feature = @import("geometry.zig");
const hair_feature = @import("hair.zig");
const std = @import("std");
const rhi = @import("../../rhi/rhi.zig");
const gpu = @import("../gpu.zig");
const math = @import("../../math.zig");
const render = @import("../renderer.zig");
const scene_pass = @import("../scene_pass.zig");
const features = @import("../core/features.zig");
const api = @import("../api.zig");

const ViewContext = features.ViewContext;
const DrawPush = scene_pass.DrawPush;
const Vec3 = math.Vec3;

/// Depth range of the shadow map along the light, either side of the world
/// origin, in world units. Fixed, so cached pages stay valid.
const depth_reach = 4096.0;

const page_count = gpu.vsm_levels * gpu.vsm_pages * gpu.vsm_pages;

const place_count = gpu.vsm_atlas_pages * gpu.vsm_atlas_pages;

/// A view's pages and atlas.
pub const View = struct {
    pages: rhi.Buffer,
    owners: rhi.Buffer,
    requested: rhi.Buffer,
    page_views: rhi.Buffer,
    atlas: rhi.Texture,
    /// Sun direction and scene origin the pages were drawn for; a change
    /// invalidates all of them.
    sun: Vec3 = .{ 0, 0, 0 },
    origin: [3]f64 = .{ 0, 0, 0 },
    extent: f32 = 0,
    frame: u32 = 0,
    /// Renderer frame and scene the pages were last prepared for; they do
    /// not survive a gap or another scene.
    drawn_frame: u64 = 0,
    scene: ?render.Scene = null,
    /// Pages were reset this frame: clear the atlas before drawing.
    fresh: bool = true,

    pub fn init(device: *rhi.Device) !View {
        const pages = try device.createBuffer(.{ .name = "virtual shadow pages", .size = page_count * @sizeOf(gpu.VsmPage), .usage = .{ .storage = true, .copy_dst = true } });
        errdefer device.destroyBuffer(pages);
        const owners = try device.createBuffer(.{ .name = "virtual shadow places", .size = place_count * @sizeOf(u32), .usage = .{ .storage = true, .copy_dst = true } });
        errdefer device.destroyBuffer(owners);
        const requested = try device.createBuffer(.{ .name = "virtual shadow requests", .size = page_count * @sizeOf(u32), .usage = .{ .storage = true, .copy_dst = true } });
        errdefer device.destroyBuffer(requested);
        const page_views = try device.createBuffer(.{ .name = "virtual shadow page views", .size = gpu.vsm_pages_per_frame * @sizeOf(gpu.VsmPageView), .usage = .{ .storage = true, .copy_dst = true } });
        errdefer device.destroyBuffer(page_views);
        const side = gpu.vsm_atlas_pages * gpu.vsm_page_texels;
        const atlas = try device.createTexture(.{ .name = "virtual shadow atlas", .width = side, .height = side, .format = .depth32_float, .usage = .{ .sampled = true, .depth_attachment = true } });
        return .{ .pages = pages, .owners = owners, .requested = requested, .page_views = page_views, .atlas = atlas };
    }

    pub fn deinit(self: View, device: *rhi.Device) void {
        device.destroyBuffer(self.pages);
        device.destroyBuffer(self.owners);
        device.destroyBuffer(self.requested);
        device.destroyBuffer(self.page_views);
        device.destroyTexture(self.atlas);
    }
};

const Frame = struct {
    ctx: *ViewContext,
    state: *View,
    /// Address of the frame's `gpu.VsmParams`.
    params: u64,
    depth: features.Target,
};

/// Resets the pages when what they were drawn for has changed, hands the
/// frame its `gpu.VsmParams` and adds the pass that draws.
pub fn declare(ctx: *ViewContext) !void {
    const p = ctx.scene orelse return;
    const shadows = ctx.settings.shadows orelse return;
    if (!shadows.virtual or !p.sun_shadows or p.debugging) return;
    const renderer = ctx.renderer;
    const device = ctx.device;
    const scene = p.scene;
    const sun_travel = p.sun_travel;
    const state = try ctx.state(@This());
    const extent = 2 * @max(p.settings.shadows.?.distance, 1) / @as(f32, @floatFromInt(@as(u32, 1) << (gpu.vsm_levels - 1)));
    const moved_sun = math.length(math.sub(state.sun, sun_travel)) > 1e-5;
    const scene_handle: ?render.Scene = p.scene_handle;
    const reset = state.frame == 0 or moved_sun or !std.meta.eql(state.origin, scene.origin) or state.extent != extent or
        state.drawn_frame +% 1 != renderer.frame_index or !std.meta.eql(state.scene, scene_handle);
    state.drawn_frame = renderer.frame_index;
    state.scene = scene_handle;
    state.sun = sun_travel;
    state.origin = scene.origin;
    state.extent = extent;
    state.frame += 1;
    state.fresh = reset;
    if (reset) {
        p.cmd.sync(.all_to_transfer);
        p.cmd.fillBuffer(state.pages, 0, page_count * @sizeOf(gpu.VsmPage), 0);
        p.cmd.fillBuffer(state.owners, 0, place_count * @sizeOf(u32), 0);
        p.cmd.fillBuffer(state.requested, 0, page_count * @sizeOf(u32), 0);
        p.cmd.sync(.transfer_to_all);
    }

    const hint: Vec3 = if (@abs(sun_travel[1]) < 0.99) .{ 0, 1, 0 } else .{ 1, 0, 0 };
    const right = math.normalize(math.cross(hint, sun_travel));
    const up = math.cross(sun_travel, right);
    const eye = p.desc.camera.position;
    const movers = try p.arena.alloc(device, [4]f32, @max(scene.movers.items.len, 1));
    @memcpy(movers.items[0..scene.movers.items.len], scene.movers.items);
    const params = try p.arena.alloc(device, gpu.VsmParams, 1);
    params.items[0] = .{
        .light_view = .{ right[0], up[0], sun_travel[0], 0, right[1], up[1], sun_travel[1], 0, right[2], up[2], sun_travel[2], 0, 0, 0, 0, 1 },
        .camera = .{ math.dot(right, eye), math.dot(up, eye), math.dot(sun_travel, eye) },
        .base_extent = extent,
        .depth_from = -depth_reach,
        .depth_range = 2 * depth_reach,
        .frame = state.frame,
        .reset = @intFromBool(reset),
        .levels = gpu.vsm_levels,
        .atlas_texture = device.textureIndex(state.atlas),
        .mover_count = @intCast(scene.movers.items.len),
        .all_moved = @intFromBool(scene.movers_overflow),
        .pages = device.bufferAddress(state.pages),
        .owners = device.bufferAddress(state.owners),
        .requested = device.bufferAddress(state.requested),
        .page_views = device.bufferAddress(state.page_views),
        .movers = movers.address,
    };
    ctx.constants.vsm = params.address;
    ctx.constants.flags |= gpu.frame_flags.vsm;

    const g = ctx.graph;
    const frame = try ctx.make(Frame);
    frame.* = .{ .ctx = ctx, .state = state, .params = params.address, .depth = g.slot(.depth).? };
    const atlas = try g.import(state.atlas);
    try g.add(.{
        .name = "virtual shadows",
        .stage = .lighting,
        .reads = &.{frame.depth},
        .writes = &.{atlas},
        .always = true,
    }, frame, draw);
}

/// Marks the pages visible surfaces fall in, allocates them and draws the new
/// and invalidated ones.
fn draw(frame: *Frame) !void {
    const ctx = frame.ctx;
    const renderer = ctx.renderer;
    const device = ctx.device;
    const cmd = ctx.cmd;
    const p = ctx.scene.?;
    const culling = p.culling;
    const state = frame.state;
    const params = frame.params;
    cmd.bindPipeline(try renderer.pipelines.get(.vsm_mark));
    cmd.pushConstants(extern struct { frame: u64, vsm: u64, depth: u32, pad: u32 = 0 }{ .frame = ctx.frame_address, .vsm = params, .depth = ctx.index(frame.depth) });
    cmd.dispatch((p.width + 7) / 8, (p.height + 7) / 8, 1);
    cmd.sync(.compute_to_all);
    cmd.bindPipeline(try renderer.pipelines.get(.vsm_allocate));
    cmd.pushConstants(extern struct { frame: u64, vsm: u64, views: u64, first_page_view: u32, pad: u32 = 0 }{
        .frame = ctx.frame_address,
        .vsm = params,
        .views = culling.views,
        .first_page_view = render.vsm_view_base,
    });
    cmd.dispatch(1, 1, 1);
    cmd.sync(.compute_to_all);

    if (p.has_geometry) {
        var views: [render.view_count]bool = @splat(false);
        const phases: [render.view_count]u32 = @splat(0);
        for (0..gpu.vsm_pages_per_frame) |page| views[render.vsm_view_base + page] = true;
        var push = culling.push;
        try geometry_feature.cullViews(renderer, p, &push, culling.views, &views, &phases);
    }

    try cmd.beginRendering(.{ .depth = .{ .texture = state.atlas, .load = if (state.fresh) .clear else .load, .clear = 1 } });
    cmd.bindPipeline(try renderer.pipelines.get(.vsm_clear));
    cmd.pushConstants(extern struct { page_views: u64 }{ .page_views = device.bufferAddress(state.page_views) });
    cmd.draw(6, gpu.vsm_pages_per_frame, 0, 0);
    if (p.has_geometry) {
        cmd.bindIndexBuffer(renderer.indices.get(), 0, .uint32);
        for (0..gpu.vsm_pages_per_frame) |page| {
            const page_push = DrawPush{
                .frame = ctx.frame_address,
                .paged = 1,
                .view_proj = math.identity,
                .page = device.bufferAddress(state.page_views) + page * @sizeOf(gpu.VsmPageView),
            };
            cmd.bindPipeline(try renderer.pipelines.get(.shadow));
            geometry_feature.drawMeshlets(renderer, cmd, page_push, render.vsm_view_base + page, 0, p.scene.ref_count);
            cmd.bindPipeline(try renderer.pipelines.get(.shadow_masked));
            geometry_feature.drawMeshlets(renderer, cmd, page_push, render.vsm_view_base + page, 1, p.scene.ref_count);
        }
    }
    const finest_texel = state.extent / @as(f32, gpu.vsm_pages * gpu.vsm_page_texels);
    for (0..gpu.vsm_pages_per_frame) |page| {
        try hair_feature.drawHairShadows(renderer, p, math.identity, finest_texel, device.bufferAddress(state.page_views) + page * @sizeOf(gpu.VsmPageView));
    }
    cmd.endRendering();
}
