//! Checks of what no example shows: picking, stale handles, moved entities,
//! other threads editing a scene, a pass that fails, shader reloading, texture
//! streaming from the asset cache, geometry compaction and
//! running out of memory. Draws without a window, with validation on, and
//! fails on the first check that does not hold. `zig build verify` runs it.
const std = @import("std");
const gfx = @import("limn");
const math = gfx.math;

const width = 320;
const height = 180;
const cache_dir = ".zig-cache/limn-checks";
const fox_path = "examples/assets/world/Fox.glb";

pub const std_options: std.Options = .{ .log_level = .info, .logFn = log };

/// Leaves out the model loads the out of memory check fails on purpose.
fn log(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    if (comptime std.mem.startsWith(u8, format, "model load failed")) return;
    std.log.defaultLog(level, scope, format, args);
}

const Checks = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    renderer: *gfx.Renderer,
    failing: *FailingAllocator,
    scene: gfx.Scene,
    target: gfx.rhi.Texture,
    camera: gfx.Camera,
    box: gfx.Entity,
    box_model: gfx.Model,

    fn draw(self: *Checks, frames: usize) !void {
        for (0..frames) |_| _ = try self.renderer.render(.{
            .views = &.{.{ .scene = self.scene, .camera = self.camera, .target = .{ .texture = self.target } }},
            .delta_time = 1.0 / 60.0,
        });
    }

    fn pickAt(self: *Checks, pixel: [2]u32) !?gfx.Pick {
        _ = self.renderer.takePick();
        for (0..60) |_| {
            self.renderer.requestPick(null, pixel);
            try self.draw(1);
            if (self.renderer.takePick()) |result| {
                if (std.meta.eql(result.pixel, pixel)) return result.hit;
            }
        }
        return error.PickNeverAnswered;
    }

    fn picking(self: *Checks) !void {
        const hit = (try self.pickAt(.{ width / 2, height / 2 })) orelse return error.PickMissedTheBox;
        if (!std.meta.eql(hit.entity, self.box)) return error.PickHitSomethingElse;
        if (@abs(hit.distance - 4.5) > 0.2) return error.PickDistanceWrong;
        if (try self.pickAt(.{ 4, 4 }) != null) return error.PickHitTheSky;
        std.log.info("picking: the box {d:.2} m away, and nothing in the sky", .{hit.distance});
    }

    /// Setters and `destroy` ignore a handle whose object is gone, queries
    /// answer empty, and only making something from one fails.
    fn staleHandles(self: *Checks) !void {
        const renderer = self.renderer;
        const scene = try renderer.scenes.create();
        const triangle = [_][3]f32{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 1, 0 } };
        const model = try renderer.models.create(&.{.{ .positions = &triangle, .indices = &.{ 0, 1, 2 } }});
        const entity = try renderer.entities.spawn(scene, .{ .model = model, .transform = math.identity });
        const group = try renderer.instances.create(scene, model, &.{math.identity});
        renderer.instances.destroy(group);
        renderer.entities.despawn(entity);
        renderer.scenes.destroy(scene);
        try renderer.models.destroy(model);

        renderer.entities.despawn(entity);
        renderer.entities.setTransform(entity, math.identity);
        renderer.entities.setTransforms(&.{entity}, &.{math.identity});
        renderer.entities.setVisible(entity, false);
        try renderer.entities.bakeLightmap(entity, null);
        try renderer.instances.set(group, &.{math.identity});
        renderer.instances.destroy(group);
        try renderer.scenes.setLights(scene, &.{});
        try renderer.scenes.setDecals(scene, &.{});
        renderer.scenes.setSun(scene, .{ .direction = .{ 0, -1, 0 }, .color = .{ 1, 1, 1 }, .intensity = 1 });
        renderer.scenes.destroy(scene);
        try renderer.materials.setShader(model, null, null, .{ 0, 0, 0, 0 });
        try renderer.models.destroy(model);

        if (renderer.models.state(model) != .failed) return error.StaleModelHasState;
        if (renderer.models.info(model) != null) return error.StaleModelHasInfo;
        if (renderer.entities.lightmapProgress(entity) != null) return error.StaleEntityAnswered;
        if (renderer.entities.spawn(scene, .{ .model = self.box_model, .transform = math.identity }) != error.InvalidScene) return error.SpawnedInStaleScene;
        if (renderer.entities.spawn(self.scene, .{ .model = model, .transform = math.identity }) != error.InvalidModel) return error.SpawnedStaleModel;
        try self.draw(2);
        std.log.info("stale handles: ignored by setters, empty to queries, refused by spawn", .{});
    }

    /// Other threads move and spawn entities while frames are drawn. The crowd
    /// is large enough for its instance records to be written across threads.
    fn threads(self: *Checks) !void {
        const renderer = self.renderer;
        const crowd = try self.gpa.alloc(gfx.Entity, 12_000);
        defer self.gpa.free(crowd);
        const home = try self.gpa.alloc(math.Mat4, crowd.len);
        defer self.gpa.free(home);
        for (crowd, home, 0..) |*entity, *at, index| {
            at.* = math.translation(.{ @floatFromInt(index % 32), 0, -4 - @as(f32, @floatFromInt(index / 32)) });
            entity.* = try renderer.entities.spawn(self.scene, .{ .model = self.box_model, .transform = at.* });
        }
        var stop: std.atomic.Value(bool) = .init(false);
        var failed: std.atomic.Value(bool) = .init(false);
        const Worker = struct {
            fn move(checks: *Checks, entities: []const gfx.Entity, places: []const math.Mat4, done: *std.atomic.Value(bool)) void {
                var step: f32 = 0;
                while (!done.load(.acquire)) : (step += 0.01) {
                    for (entities, 0..) |entity, index| {
                        const at = math.translation(.{ @floatFromInt(index % 32), @sin(step), -4 - @as(f32, @floatFromInt(index / 32)) });
                        checks.renderer.entities.setTransform(entity, at);
                        checks.renderer.entities.setTint(entity, .{ 1, 0.5 + 0.5 * @sin(step), 1 });
                    }
                    checks.renderer.entities.setTransforms(entities, places);
                }
            }
            fn churn(checks: *Checks, done: *std.atomic.Value(bool), broke: *std.atomic.Value(bool)) void {
                while (!done.load(.acquire)) {
                    const entity = checks.renderer.entities.spawn(checks.scene, .{ .model = checks.box_model, .transform = math.translation(.{ 0, 3, 0 }) }) catch return broke.store(true, .release);
                    checks.renderer.entities.setTransform(entity, math.translation(.{ 0, 4, 0 }));
                    _ = checks.renderer.getStats();
                    checks.renderer.entities.despawn(entity);
                    checks.renderer.entities.setTransform(entity, math.identity);
                }
            }
        };
        var group: std.Io.Group = .init;
        try group.concurrent(self.io, Worker.move, .{ self, crowd, home, &stop });
        const alone = self.draw(30);
        const churned = group.concurrent(self.io, Worker.churn, .{ self, &stop, &failed });
        const drawn = self.draw(60);
        stop.store(true, .release);
        group.await(self.io) catch {};
        try alone;
        try churned;
        try drawn;
        if (failed.load(.acquire)) return error.SpawnFailedWhileDrawing;
        for (crowd) |entity| renderer.entities.despawn(entity);
        try self.draw(2);
        std.log.info("threads: 90 frames of {d} entities drawn while other threads edited them", .{crowd.len});
    }

    fn levelsApart(before: []const u8, after: []const u8) f32 {
        var total: u64 = 0;
        for (before, after) |a, b| total += @abs(@as(i32, a) - @as(i32, b));
        return @as(f32, @floatFromInt(total)) / @as(f32, @floatFromInt(before.len));
    }

    /// Entities that are moved, teleported and tinted have only their own
    /// records brought up to date. The picture must be the one that writing
    /// every record again gives.
    fn moves(self: *Checks) !void {
        const renderer = self.renderer;
        var row: [24]gfx.Entity = undefined;
        for (&row, 0..) |*entity, index| {
            const x = @as(f32, @floatFromInt(index)) * 0.25 - 2.9;
            entity.* = try renderer.entities.spawn(self.scene, .{ .model = self.box_model, .transform = math.mul(math.translation(.{ x, 1.2, -1 }), math.scaling(.{ 0.24, 0.5, 0.24 })) });
        }
        try self.draw(30);
        const pixels_before = try renderer.device.readTexture(self.gpa, self.target);
        defer self.gpa.free(pixels_before);
        for (row, 0..) |entity, index| {
            const x = @as(f32, @floatFromInt(index)) * 0.25 - 2.9;
            const at = math.mul(math.translation(.{ x, 1.8 + 0.3 * @sin(@as(f32, @floatFromInt(index))), -1 }), math.scaling(.{ 0.24, 0.5, 0.24 }));
            if (index % 3 == 1) renderer.entities.teleport(entity, at) else renderer.entities.setTransform(entity, at);
            if (index % 3 == 2) renderer.entities.setTint(entity, .{ 1, 0.2, 0.2 });
        }
        try self.draw(30);
        const pixels_moved = try renderer.device.readTexture(self.gpa, self.target);
        defer self.gpa.free(pixels_moved);
        renderer.entities.setVisible(row[0], false);
        renderer.entities.setVisible(row[0], true);
        try self.draw(30);
        const pixels_whole = try renderer.device.readTexture(self.gpa, self.target);
        defer self.gpa.free(pixels_whole);
        const changed = levelsApart(pixels_before, pixels_moved);
        const apart = levelsApart(pixels_moved, pixels_whole);
        if (changed < 0.05) return error.MovedEntitiesDrawnWhereTheyWere;
        if (apart > changed * 0.3) return error.MovedEntitiesDrawnWrong;
        for (row) |entity| renderer.entities.despawn(entity);
        try self.draw(2);
        std.log.info("moves: the picture changed by {d:.2} levels, and differs by {d:.2} from one drawn afresh", .{ changed, apart });
    }

    fn failedPass(self: *Checks) !void {
        const broken: []const gfx.Pass = &.{.{ .stage = .after_opaque, .run = failingPass }};
        const outcome = self.renderer.render(.{ .views = &.{.{ .scene = self.scene, .camera = self.camera, .target = .{ .texture = self.target }, .passes = broken }} });
        if (outcome != error.InjectedFailure) return error.FailureNotReported;
        try self.draw(2);
        std.log.info("failed pass: reported, and the next frame drew", .{});
    }

    fn shaderReload(self: *Checks) !void {
        const count = self.renderer.shaders.reload() catch |err| {
            if (@as(anyerror, err) != error.ShaderReloadDisabled) return err;
            return std.log.info("shader reload: left out of this build", .{});
        };
        if (count == 0) return error.NoShaderReloaded;
        try self.draw(4);
        std.log.info("shader reload: {d} shaders", .{count});
    }

    fn streaming(self: *Checks) !void {
        const fox = try self.renderer.models.load(fox_path);
        try self.renderer.waitUntilLoaded();
        if (self.renderer.models.state(fox) != .ready) return error.ModelNotLoaded;
        const entity = try self.renderer.entities.spawn(self.scene, .{ .model = fox, .transform = math.mul(math.translation(.{ 1.5, 0, 0 }), math.scaling(.{ 0.02, 0.02, 0.02 })) });
        var settled = false;
        for (0..300) |_| {
            try self.draw(1);
            const stats = self.renderer.getStats();
            if (stats.streamed_textures != 0 and stats.streamed_textures_pending == 0) {
                settled = true;
                break;
            }
        }
        const stats = self.renderer.getStats();
        if (stats.streamed_textures == 0) return error.NothingStreamed;
        if (!settled) return error.StreamingNeverSettled;

        var folder = try std.Io.Dir.cwd().openDir(self.io, cache_dir, .{ .iterate = true });
        defer folder.close(self.io);
        var files = folder.iterate();
        var cached: usize = 0;
        while (try files.next(self.io)) |_| cached += 1;
        if (cached == 0) return error.NothingCached;

        self.renderer.entities.despawn(entity);
        try self.renderer.models.destroy(fox);
        try self.draw(4);
        std.log.info("streaming: {d} textures, {d} KiB loaded; {d} files in the cache", .{ stats.streamed_textures, stats.streamed_texture_bytes / 1024, cached });
    }

    /// A large model is destroyed under a small one; the small one must be
    /// moved down and still draw the same.
    fn compaction(self: *Checks) !void {
        const side = 500;
        const positions = try self.gpa.alloc([3]f32, side * side);
        defer self.gpa.free(positions);
        const indices = try self.gpa.alloc(u32, (side - 1) * (side - 1) * 6);
        defer self.gpa.free(indices);
        for (0..side) |z| for (0..side) |x| {
            positions[z * side + x] = .{ @as(f32, @floatFromInt(x)) * 0.01, 0, @as(f32, @floatFromInt(z)) * 0.01 };
        };
        var at: usize = 0;
        for (0..side - 1) |z| for (0..side - 1) |x| {
            const corner: u32 = @intCast(z * side + x);
            indices[at..][0..6].* = .{ corner, corner + side, corner + 1, corner + 1, corner + side, corner + side + 1 };
            at += 6;
        };
        const large = try self.renderer.models.create(&.{.{ .positions = positions, .indices = indices }});
        const small = try self.renderer.models.create(&.{.{ .positions = positions[0 .. side * 60], .indices = indices[0 .. (side - 1) * 6 * 59], .material = .{ .base_color = .{ 0.9, 0.2, 0.1, 1 }, .double_sided = true } }});
        const entity = try self.renderer.entities.spawn(self.scene, .{ .model = small, .transform = math.translation(.{ -3, 1.5, 0 }) });
        try self.renderer.waitUntilLoaded();
        try self.draw(40);
        const pixels_before = try self.renderer.device.readTexture(self.gpa, self.target);
        defer self.gpa.free(pixels_before);
        const before = self.renderer.getStats();
        try self.renderer.models.destroy(large);
        try self.draw(12);
        const moved = self.renderer.getStats().geometry_bytes_compacted - before.geometry_bytes_compacted;
        if (moved == 0) return error.GeometryNotCompacted;
        const pixels_after = try self.renderer.device.readTexture(self.gpa, self.target);
        defer self.gpa.free(pixels_after);
        var difference: u64 = 0;
        for (pixels_before, pixels_after) |a, b| difference += @abs(@as(i32, a) - @as(i32, b));
        const mean = @as(f32, @floatFromInt(difference)) / @as(f32, @floatFromInt(pixels_before.len));
        if (mean > 3) return error.CompactedGeometryDrawnWrong;
        self.renderer.entities.despawn(entity);
        try self.renderer.models.destroy(small);
        try self.draw(2);
        std.log.info("compaction: {d} KiB moved, the picture differs by {d:.2} levels", .{ moved / 1024, mean });
    }

    /// Fails one allocation per round, each further into the same work. Each
    /// round must succeed or return `error.OutOfMemory`, and the next frame
    /// must draw.
    fn outOfMemory(self: *Checks, rounds: usize) !void {
        const renderer = self.renderer;
        const failing = self.failing;
        const triangle = [_][3]f32{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 1, 0 } };
        const indices = [_]u32{ 0, 1, 2 };
        var list = gfx.DrawList.init(failing.allocator());
        defer list.deinit();
        var failures: usize = 0;
        for (0..rounds) |round| {
            failing.failAfter(round);
            const outcome: anyerror!void = blk: {
                const model = renderer.models.create(&.{.{ .positions = &triangle, .indices = &indices }}) catch |err| break :blk err;
                defer renderer.models.destroy(model) catch {};
                const entity = renderer.entities.spawn(self.scene, .{ .model = model, .transform = math.translation(.{ 2, 1, 0 }) }) catch |err| break :blk err;
                defer renderer.entities.despawn(entity);
                list.clear();
                list.text(renderer.fonts.default(), "out of memory", .{ 20, 20 }, .{ .size = 18 }) catch |err| break :blk err;
                const lights = [_]gfx.Light{.{ .position = .{ 2, 2, 0 }, .color = .{ 1, 1, 1 }, .intensity = 5, .range = 6 }};
                renderer.scenes.setLights(self.scene, &lights) catch |err| break :blk err;
                _ = renderer.render(.{ .views = &.{.{ .scene = self.scene, .camera = self.camera, .draw_lists = &.{&list}, .target = .{ .texture = self.target } }} }) catch |err| break :blk err;
            };
            failing.failNever();
            if (outcome) |_| {} else |err| {
                if (err != error.OutOfMemory) return err;
                failures += 1;
            }
            try self.draw(1);
        }
        try renderer.scenes.setLights(self.scene, &.{});

        const before = failing.alloc_index.load(.monotonic);
        {
            const clean = try renderer.models.load(fox_path);
            try renderer.waitUntilLoaded();
            if (renderer.models.state(clean) != .ready) return error.ModelNotLoaded;
            try renderer.models.destroy(clean);
        }
        const allocations = failing.alloc_index.load(.monotonic) - before;
        var load_failures: usize = 0;
        for (0..rounds) |round| {
            failing.failAfter(round * allocations / rounds);
            const loaded: ?gfx.Model = renderer.models.load(fox_path) catch |err| blk: {
                if (err != error.OutOfMemory) return err;
                break :blk null;
            };
            if (loaded) |model| {
                renderer.waitUntilLoaded() catch |err| if (err != error.OutOfMemory) return err;
                failing.failNever();
                try renderer.waitUntilLoaded();
                switch (renderer.models.state(model)) {
                    .ready => {},
                    .failed => {
                        const cause = renderer.models.loadError(model) orelse return error.UnexpectedLoadFailure;
                        if (cause != error.OutOfMemory) return cause;
                        load_failures += 1;
                    },
                    else => return error.ModelStillLoading,
                }
                try renderer.models.destroy(model);
            } else load_failures += 1;
            failing.failNever();
            try self.draw(1);
        }
        if (failures == 0 or load_failures == 0) return error.NoFailureInjected;
        std.log.info("out of memory: {d} of {d} rounds failed drawing and {d} loading, all recovered", .{ failures, rounds, load_failures });
    }

    /// Fails one GPU memory allocation per round while resources are made
    /// and a frame is drawn; the next frame must draw.
    fn outOfGpuMemory(self: *Checks, rounds: usize) !void {
        const renderer = self.renderer;
        const device = renderer.device;
        const triangle = [_][3]f32{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 1, 0 } };
        const indices = [_]u32{ 0, 1, 2 };
        const pixels = [_]u8{200} ** (16 * 16 * 4);
        var failures: usize = 0;
        for (0..rounds) |round| {
            device.failGpuAllocation(@intCast(round));
            const outcome: anyerror!void = blk: {
                const view = renderer.views.create() catch |err| break :blk err;
                defer renderer.views.destroy(view);
                const small = device.createTexture(.{
                    .name = "small output",
                    .width = @intCast(192 + round * 2),
                    .height = 108,
                    .format = .rgba8_unorm,
                    .usage = .{ .color_attachment = true, .sampled = true, .copy_src = true },
                }) catch |err| break :blk err;
                defer device.destroyTexture(small);
                const image = renderer.images.create(16, 16, &pixels, true) catch |err| break :blk err;
                defer renderer.images.destroy(image);
                const model = renderer.models.create(&.{.{ .positions = &triangle, .indices = &indices }}) catch |err| break :blk err;
                defer renderer.models.destroy(model) catch {};
                const entity = renderer.entities.spawn(self.scene, .{ .model = model, .transform = math.translation(.{ 2, 1, 0 }) }) catch |err| break :blk err;
                defer renderer.entities.despawn(entity);
                _ = renderer.render(.{ .views = &.{.{ .view = view, .scene = self.scene, .camera = self.camera, .target = .{ .texture = small } }} }) catch |err| break :blk err;
            };
            if (!device.gpuAllocationFailurePending()) failures += 1;
            device.failGpuAllocation(null);
            if (outcome) |_| {} else |err| {
                if (err != error.OutOfDeviceMemory) return err;
            }
            try self.draw(1);
        }
        if (failures == 0) return error.NoFailureInjected;
        std.log.info("out of GPU memory: {d} of {d} rounds hit a failure, all recovered", .{ failures, rounds });
    }
};

fn failingPass(_: ?*anyopaque, pass: gfx.PassContext) anyerror!void {
    try pass.cmd.beginRendering(.{ .color = &.{.{ .texture = pass.color, .load = .load }} });
    return error.InjectedFailure;
}

/// Fails one chosen allocation. Thread-safe.
const FailingAllocator = struct {
    backing: std.mem.Allocator,
    alloc_index: std.atomic.Value(usize) = .init(0),
    fail_index: std.atomic.Value(usize) = .init(std.math.maxInt(usize)),

    fn allocator(self: *FailingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    /// The allocation `count` after the next one fails.
    fn failAfter(self: *FailingAllocator, count: usize) void {
        self.fail_index.store(self.alloc_index.load(.monotonic) + count, .monotonic);
    }

    fn failNever(self: *FailingAllocator) void {
        self.fail_index.store(std.math.maxInt(usize), .monotonic);
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const self: *FailingAllocator = @ptrCast(@alignCast(context));
        if (self.alloc_index.fetchAdd(1, .monotonic) == self.fail_index.load(.monotonic)) return null;
        return self.backing.rawAlloc(len, alignment, return_address);
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) bool {
        const self: *FailingAllocator = @ptrCast(@alignCast(context));
        return self.backing.rawResize(memory, alignment, new_len, return_address);
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) ?[*]u8 {
        const self: *FailingAllocator = @ptrCast(@alignCast(context));
        return self.backing.rawRemap(memory, alignment, new_len, return_address);
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        const self: *FailingAllocator = @ptrCast(@alignCast(context));
        self.backing.rawFree(memory, alignment, return_address);
    }
};

pub fn main(init: std.process.Init) !void {
    var failing = FailingAllocator{ .backing = init.gpa };
    const renderer = try gfx.Renderer.init(failing.allocator(), init.io, .{
        .application_name = "limn checks",
        .validation = true,
        .mesh_shaders = true,
        .job_allocator = failing.allocator(),
        .asset_cache_dir = cache_dir,
        .texture_streaming = .{ .budget_bytes = 4 * 1024 * 1024, .evict_delay_frames = 8, .from_cache = true },
    });
    defer renderer.deinit();
    const target = try renderer.device.createTexture(.{
        .name = "output",
        .width = width,
        .height = height,
        .format = .rgba8_unorm,
        .usage = .{ .color_attachment = true, .sampled = true, .copy_src = true },
    });
    defer renderer.device.destroyTexture(target);

    const scene = try renderer.scenes.create();
    const sky = gfx.SkyDesc{ .sun_direction = .{ -0.5, -0.3, -0.6 } };
    renderer.scenes.setEnvironment(scene, try renderer.environments.createSky(sky), 1);
    renderer.scenes.setSun(scene, gfx.skySun(sky));
    const corners = [8][3]f32{ .{ -0.5, 0, -0.5 }, .{ 0.5, 0, -0.5 }, .{ 0.5, 1, -0.5 }, .{ -0.5, 1, -0.5 }, .{ -0.5, 0, 0.5 }, .{ 0.5, 0, 0.5 }, .{ 0.5, 1, 0.5 }, .{ -0.5, 1, 0.5 } };
    const faces = [36]u32{ 0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7, 0, 1, 5, 0, 5, 4, 3, 7, 6, 3, 6, 2, 0, 4, 7, 0, 7, 3, 1, 2, 6, 1, 6, 5 };
    const box = try renderer.models.create(&.{.{ .positions = &corners, .indices = &faces }});

    var checks = Checks{
        .gpa = init.gpa,
        .io = init.io,
        .renderer = renderer,
        .failing = &failing,
        .scene = scene,
        .target = target,
        .camera = gfx.Camera.lookAt(.{ 0, 0.5, 5 }, .{ 0, 0.5, 0 }),
        .box_model = box,
        .box = try renderer.entities.spawn(scene, .{ .model = box, .transform = math.identity }),
    };
    try renderer.waitUntilLoaded();
    try checks.draw(8);
    try checks.picking();
    try checks.staleHandles();
    try checks.moves();
    try checks.threads();
    try checks.failedPass();
    try checks.shaderReload();
    try checks.streaming();
    try checks.compaction();
    try checks.outOfMemory(40);
    try checks.outOfGpuMemory(45);
    try renderer.device.waitIdle();
}
