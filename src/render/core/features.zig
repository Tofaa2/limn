//! The render features and what the renderer does with all of them: resolve
//! their settings, keep their per-view state and let them add their passes
//! to a view's graph. A feature is a file that declares
//!
//!   name      the field of `Settings` that configures it
//!   Settings  the type of that field, or of its payload when optional
//!   preset    the field's value at a quality level
//!   resolve   clamps the field and turns off what the view cannot do
//!   declare   adds the feature's passes to the graph
//!   View      state kept per view, with `deinit` (optional)
//!
//! and is listed in `list`.
const std = @import("std");
const upscaling = @import("../techniques/upscaling.zig");
const rhi = @import("../../rhi/rhi.zig");
const gpu = @import("../gpu.zig");
const api = @import("../api.zig");
const graph_module = @import("graph.zig");
const targets = @import("targets.zig");
const renderer_state = @import("../state.zig");
const scene_pass = @import("../scene_pass.zig");
const render = @import("../renderer.zig");

/// In the order their passes run within a stage.
pub const list = .{
    @import("../features/canvas.zig"),
    @import("../features/geometry.zig"),
    @import("../features/simulation.zig"),
    @import("../features/ambient_occlusion.zig"),
    @import("../features/virtual_shadows.zig"),
    @import("../features/lights.zig"),
    @import("../features/shadows.zig"),
    @import("../features/global_illumination.zig"),
    @import("../features/lightmaps.zig"),
    @import("../features/shading.zig"),
    @import("../features/hooks.zig"),
    @import("../features/path_tracing.zig"),
    @import("../features/clouds.zig"),
    @import("../features/reflections.zig"),
    @import("../features/impostors.zig"),
    @import("../features/hair.zig"),
    @import("../features/liquids.zig"),
    @import("../features/water.zig"),
    @import("../features/transparency.zig"),
    @import("../features/fluids.zig"),
    @import("../features/fog.zig"),
    @import("../features/particles.zig"),
    @import("../features/resolution.zig"),
    @import("../features/post.zig"),
    @import("../features/output.zig"),
};

pub const graph = graph_module;
pub const Graph = graph_module.Graph;
pub const Target = graph_module.Target;

fn ViewOf(comptime Feature: type) type {
    return if (@hasDecl(Feature, "View")) ?Feature.View else void;
}

/// Each feature's state for one view; null until the feature first runs
/// on it.
pub const ViewStates = blk: {
    var types: [list.len]type = undefined;
    for (list, 0..) |Feature, index| types[index] = ViewOf(Feature);
    break :blk std.meta.Tuple(&types);
};

pub fn emptyViewStates() ViewStates {
    var states: ViewStates = undefined;
    inline for (list, 0..) |Feature, index| states[index] = if (@hasDecl(Feature, "View")) null else {};
    return states;
}

pub fn deinitViewStates(states: *ViewStates, device: *rhi.Device) void {
    inline for (list, 0..) |Feature, index| {
        if (!@hasDecl(Feature, "View")) continue;
        if (states[index]) |*state| state.deinit(device);
        states[index] = null;
    }
}

/// `Feature`'s state for `view`, if it has made one.
pub fn viewState(view: *renderer_state.ViewData, comptime Feature: type) ?*Feature.View {
    inline for (list, 0..) |Listed, at| {
        if (Listed != Feature) continue;
        return if (view.features[at]) |*state| state else null;
    }
    @compileError("not a listed feature");
}

/// What `resolve` is told about the view, and where it reports what it
/// could not give.
pub const Resolve = struct {
    caps: rhi.Capabilities,
    /// The view draws a scene.
    scene: bool,
    /// A debug view is shown: effects that would hide it are left out.
    debugging: bool,
    temporal_antialiasing: bool,
    /// The camera is orthographic.
    orthographic: bool = false,
    /// The vendor upscalers that can run.
    upscalers: upscaling.Availability = .{},
    /// NRD is built in and the device can run it.
    nrd: bool = false,
    /// The upscaler asked for, before any feature's `resolve`.
    upscaler: api.Upscaler = .temporal,
    /// How the device would path trace.
    path_tracing: api.PathTracingSupport = .unavailable,
    downgrades: *Downgrades,

    /// Records that `feature` was asked for `requested` and gets `used`.
    pub fn downgrade(self: *Resolve, feature: []const u8, requested: []const u8, used: []const u8, reason: api.DowngradeReason) void {
        self.downgrades.add(.{ .feature = feature, .requested = requested, .used = used, .reason = reason });
    }
};

pub const Downgrades = struct {
    items: [api.max_downgrades]api.Downgrade = undefined,
    count: u32 = 0,

    pub fn add(self: *Downgrades, item: api.Downgrade) void {
        for (self.items[0..self.count]) |existing| {
            if (std.mem.eql(u8, existing.feature, item.feature) and std.mem.eql(u8, existing.requested, item.requested)) return;
        }
        if (self.count == self.items.len) return;
        self.items[self.count] = item;
        self.count += 1;
    }
};

/// Fills each feature's settings in with what the view will really get.
pub fn resolve(settings: *api.Settings, r: *Resolve) void {
    inline for (list) |Feature| {
        if (@hasDecl(Feature, "name")) Feature.resolve(&@field(settings, Feature.name), r);
    }
}

/// Sets each feature's settings to its own for `quality`.
pub fn preset(settings: *api.Settings, quality: api.Quality) void {
    inline for (list) |Feature| {
        if (@hasDecl(Feature, "name")) @field(settings, Feature.name) = Feature.preset(quality);
    }
}

pub fn declare(ctx: *ViewContext) !void {
    inline for (list) |Feature| try Feature.declare(ctx);
}

/// One view of one frame, as features see it while they add their passes
/// and while those run.
pub const ViewContext = struct {
    renderer: *render.Renderer,
    device: *rhi.Device,
    cmd: *rhi.CommandEncoder,
    arena: *renderer_state.FrameArena,
    graph: *Graph,
    /// Holds what passes need until the graph has run; see `make`.
    scratch: std.mem.Allocator,
    desc: *const api.ViewDesc,
    /// `desc.settings` after `resolve`.
    settings: *const api.Settings,
    /// The view's kept state; null for a view that keeps none.
    view: ?*renderer_state.ViewData,
    /// Where the view's picture goes.
    output: renderer_state.Output,
    /// The frame constants being put together; a feature sets the fields
    /// that are its own while it declares. Their address is `frame_address`.
    constants: *gpu.FrameConstants,
    frame_address: u64,
    /// Set on a view of a scene.
    scene: ?*const scene_pass.ScenePass = null,

    /// Room for a pass's context, valid until the graph has run.
    pub fn make(self: *ViewContext, comptime T: type) !*T {
        return self.scratch.create(T);
    }

    /// `Feature`'s state for this view, made by `Feature.View.init` on
    /// first use.
    pub fn state(self: *ViewContext, comptime Feature: type) !*Feature.View {
        inline for (list, 0..) |Listed, at| {
            if (Listed != Feature) continue;
            const slot = &self.view.?.features[at];
            if (slot.* == null) slot.* = try Feature.View.init(self.device);
            return &slot.*.?;
        }
        @compileError("not a listed feature");
    }

    /// A target kept for this view from frame to frame; see `targets.Kept`.
    pub fn kept(self: *ViewContext, desc: rhi.TextureDesc) !Target {
        const view = self.view.?;
        return self.graph.import(try view.kept.single(self.renderer.gpa, self.device, desc, self.renderer.frame_index));
    }

    pub const History = struct { current: Target, previous: ?Target };

    /// A kept target to draw this frame and the one drawn last frame.
    pub fn history(self: *ViewContext, desc: rhi.TextureDesc) !History {
        const view = self.view.?;
        const pair = try view.kept.history(self.renderer.gpa, self.device, desc, self.renderer.frame_index);
        return .{
            .current = try self.graph.import(pair.current),
            .previous = if (pair.previous) |previous| try self.graph.import(previous) else null,
        };
    }

    /// The bindless index of `target`, inside a pass that names it.
    pub fn index(self: *const ViewContext, target: Target) u32 {
        return self.device.textureIndex(self.graph.texture(target));
    }
};

test "a feature that cannot run as asked is turned down and reported" {
    var settings = api.Settings{ .resolution = .{ .temporal_antialiasing = false } };
    var downgrades = Downgrades{};
    var r = Resolve{ .caps = .{}, .scene = true, .debugging = false, .temporal_antialiasing = false, .downgrades = &downgrades };
    resolve(&settings, &r);
    resolve(&settings, &r);
    try std.testing.expectEqual(@as(f32, 0), settings.ambient_occlusion.?.bounce);
    try std.testing.expect(settings.global_illumination == null);
    var reported = false;
    for (downgrades.items[0..downgrades.count]) |item| {
        if (std.mem.eql(u8, item.feature, "ambient_occlusion.bounce")) reported = item.reason == .needs_temporal_antialiasing;
    }
    try std.testing.expect(reported);
    const count = downgrades.count;
    resolve(&settings, &r);
    try std.testing.expectEqual(count, downgrades.count);

    r.scene = false;
    resolve(&settings, &r);
    try std.testing.expect(settings.ambient_occlusion == null);
}
