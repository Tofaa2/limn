//! What a frame records as a scene grows: commands, barriers, bytes the CPU
//! writes and CPU time, for 2D, 2D over 3D, lightweight 3D and everything on,
//! at several sizes. Each row is one steady frame; a cost that grows where
//! the work does not is overhead. Draws without a window. `zig build costs`.
const std = @import("std");
const gfx = @import("limn");
const math = gfx.math;

const width = 640;
const height = 360;
const warmup_frames = 24;
const measured_frames = 16;

const lightweight = gfx.Settings.lightweight;

const Bench = struct {
    gpa: std.mem.Allocator,
    renderer: *gfx.Renderer,
    counting: *CountingAllocator,
    target: gfx.rhi.Texture,
    box: gfx.Model,
    list: gfx.DrawList,
    /// Views drawn after the first, each with its own state.
    extra_views: [7]gfx.View,
    /// Print the GPU scopes of each scenario's first size.
    show_passes: bool,

    const Row = struct {
        size: u32,
        work: gfx.rhi.Work,
        frame_data_bytes: u64,
        cpu_ms: f32,
        /// Most allocations in one measured frame.
        allocations: usize,
        /// GPU time of the scenario's `scope` in the last measured frame.
        scope_ms: f32 = 0,
    };

    const Scenario = struct {
        name: []const u8,
        unit: []const u8,
        sizes: []const u32,
        build: *const fn (bench: *Bench, scene: ?gfx.Scene, size: u32) anyerror!Setup,
        /// A GPU scope whose time each row also prints.
        scope: ?[]const u8 = null,
    };

    const Setup = struct {
        settings: gfx.Settings = lightweight,
        views: u32 = 1,
        moving: []const gfx.Entity = &.{},
        draw_list: bool = false,
        /// Rect count the list is cleared and drawn again with every frame.
        rebuild: ?u32 = null,
        scene: bool = true,
        /// Entities made every frame, and those made the frame before destroyed.
        churn: u32 = 0,
        /// Views after the first draw scenes of their own, each with the
        /// first scene's boxes.
        scene_per_view: bool = false,
    };

    fn run(bench: *Bench, scenario: Scenario) !void {
        std.debug.print("\n{s} (per {s})\n", .{ scenario.name, scenario.unit });
        std.debug.print("{s:>7} {s:>6} {s:>6} {s:>6} {s:>6} {s:>6} {s:>6} {s:>6} {s:>6} {s:>6} {s:>6} {s:>9} {s:>10} {s:>7} {s:>6}\n", .{ "size", "passes", "draws", "indir", "disp", "barr", "imgbar", "binds", "push", "xfer", "builds", "staged B", "frame B", "cpu ms", "allocs" });
        var previous: ?Row = null;
        for (scenario.sizes) |size| {
            const row = try bench.measure(scenario, size);
            var scope_buffer: [64]u8 = undefined;
            const scope_text = if (scenario.scope) |name| std.fmt.bufPrint(&scope_buffer, "  {s} {d:.3} ms", .{ name, row.scope_ms }) catch "" else "";
            std.debug.print("{d:>7} {d:>6} {d:>6} {d:>6} {d:>6} {d:>6} {d:>6} {d:>6} {d:>6} {d:>6} {d:>6} {d:>9} {d:>10} {d:>7.3} {d:>6}{s}\n", .{
                row.size,
                row.work.render_passes,
                row.work.draws,
                row.work.indirect_draws,
                row.work.dispatches,
                row.work.barriers,
                row.work.image_barriers,
                row.work.pipeline_binds,
                row.work.push_constants,
                row.work.transfers,
                row.work.builds,
                row.work.staged_bytes,
                row.frame_data_bytes,
                row.cpu_ms,
                row.allocations,
                scope_text,
            });
            if (previous) |before| if (row.size > before.size) {
                const added: f64 = @floatFromInt(row.size - before.size);
                const growth = struct {
                    fn of(now: anytype, then: anytype, units: f64) f64 {
                        return (@as(f64, @floatFromInt(now)) - @as(f64, @floatFromInt(then))) / units;
                    }
                };
                std.debug.print("{s:>7} {d:>6.2} {d:>6.2} {d:>6.2} {d:>6.2} {d:>6.2} {d:>6.2} {d:>6.2} {d:>6.2} {d:>6.2} {d:>6.2} {d:>9.1} {d:>10.1} {d:>7.4}\n", .{
                    "  +1",
                    growth.of(row.work.render_passes, before.work.render_passes, added),
                    growth.of(row.work.draws, before.work.draws, added),
                    growth.of(row.work.indirect_draws, before.work.indirect_draws, added),
                    growth.of(row.work.dispatches, before.work.dispatches, added),
                    growth.of(row.work.barriers, before.work.barriers, added),
                    growth.of(row.work.image_barriers, before.work.image_barriers, added),
                    growth.of(row.work.pipeline_binds, before.work.pipeline_binds, added),
                    growth.of(row.work.push_constants, before.work.push_constants, added),
                    growth.of(row.work.transfers, before.work.transfers, added),
                    growth.of(row.work.builds, before.work.builds, added),
                    growth.of(row.work.staged_bytes, before.work.staged_bytes, added),
                    growth.of(row.frame_data_bytes, before.frame_data_bytes, added),
                    (row.cpu_ms - before.cpu_ms) / added,
                });
            };
            previous = row;
        }
    }

    fn measure(bench: *Bench, scenario: Scenario, size: u32) !Row {
        const renderer = bench.renderer;
        const scene = try renderer.scenes.create();
        defer renderer.scenes.destroy(scene);
        renderer.scenes.setSun(scene, .{ .direction = .{ -0.4, -0.8, -0.3 }, .color = .{ 1, 1, 1 }, .intensity = 4 });
        bench.list.clear();
        const setup = try scenario.build(bench, scene, size);
        try renderer.waitUntilLoaded();

        var own_scenes: [8]?gfx.Scene = @splat(null);
        defer for (own_scenes) |made| if (made) |own| renderer.scenes.destroy(own);
        if (setup.scene_per_view) for (own_scenes[1..setup.views]) |*own| {
            own.* = try renderer.scenes.create();
            renderer.scenes.setSun(own.*.?, .{ .direction = .{ -0.4, -0.8, -0.3 }, .color = .{ 1, 1, 1 }, .intensity = 4 });
            bench.gpa.free(try bench.spawnBoxes(own.*.?, 100));
        };
        try renderer.waitUntilLoaded();
        var targets: [8]gfx.rhi.Texture = undefined;
        for (targets[1..setup.views]) |*target| target.* = try renderer.views.createTarget(width / 2, height / 2);
        defer for (targets[1..setup.views]) |target| renderer.views.destroyTarget(target);
        targets[0] = bench.target;

        const churned = try bench.gpa.alloc(?gfx.Entity, setup.churn);
        defer bench.gpa.free(churned);
        @memset(churned, null);
        defer for (churned) |entity| if (entity) |made| renderer.entities.destroy(made);
        var cpu: [measured_frames]f32 = undefined;
        var allocations: usize = 0;
        var last: gfx.Stats = undefined;
        for (0..warmup_frames + measured_frames) |frame| {
            const time: f32 = @as(f32, @floatFromInt(frame)) / 60.0;
            if (setup.rebuild) |items| {
                bench.list.clear();
                try bench.fillList(items);
            }
            for (setup.moving, 0..) |entity, index| {
                const along: f32 = @floatFromInt(index);
                renderer.entities.setTransform(entity, math.translation(gridPoint(@intCast(index), @intCast(setup.moving.len), @sin(time + along))));
            }
            for (churned, 0..) |*entity, index| {
                if (entity.*) |old| renderer.entities.destroy(old);
                entity.* = try renderer.entities.create(scene, .{ .model = bench.box, .transform = math.translation(gridPoint(@intCast(index), setup.churn, 3)) });
            }
            var views: [8]gfx.ViewDesc = undefined;
            for (views[0..setup.views], targets[0..setup.views], 0..) |*view, target, index| {
                const angle: f32 = @as(f32, @floatFromInt(index)) * 0.7;
                view.* = .{
                    .view = if (index == 0) null else bench.extra_views[index - 1],
                    .scene = if (!setup.scene) null else if (own_scenes[index]) |own| own else scene,
                    .camera = gfx.Camera.lookAt(.{ 30 * @sin(angle), 18, 30 * @cos(angle) }, .{ 0, 0, 0 }),
                    .target = .{ .texture = target },
                    .settings = setup.settings,
                    .draw_lists = if (setup.draw_list and index == 0) &.{.{ .list = &bench.list }} else &.{},
                };
            }
            const before = bench.counting.count.load(.monotonic);
            _ = try renderer.render(.{ .views = views[0..setup.views], .delta_time = 1.0 / 60.0 });
            if (frame >= warmup_frames) allocations = @max(allocations, bench.counting.count.load(.monotonic) - before);
            if (frame >= warmup_frames) {
                last = renderer.stats();
                cpu[frame - warmup_frames] = last.cpu_ms;
            }
        }
        if (bench.show_passes and size == scenario.sizes[0]) {
            for (renderer.device.passTimings()) |timing| {
                const work = timing.work;
                std.debug.print("        {s}{s:<24} passes {d} draws {d}+{d} dispatches {d} barriers {d}/{d} binds {d} push {d} transfers {d} builds {d}\n", .{ "                "[0..@min(timing.depth * 2, 16)], timing.name, work.render_passes, work.draws, work.indirect_draws, work.dispatches, work.barriers, work.image_barriers, work.pipeline_binds, work.push_constants, work.transfers, work.builds });
            }
        }
        var scope_ms: f32 = 0;
        if (scenario.scope) |name| for (renderer.device.passTimings()) |timing| {
            if (std.mem.eql(u8, timing.name, name)) scope_ms += timing.milliseconds;
        };
        try renderer.device.waitIdle();
        std.mem.sort(f32, &cpu, {}, std.sort.asc(f32));
        bench.gpa.free(setup.moving);
        return .{ .size = size, .work = last.commands, .frame_data_bytes = last.frame_data_bytes, .cpu_ms = cpu[measured_frames / 2], .allocations = allocations, .scope_ms = scope_ms };
    }

    fn spawnBoxes(bench: *Bench, scene: gfx.Scene, count: u32) ![]gfx.Entity {
        const entities = try bench.gpa.alloc(gfx.Entity, count);
        for (entities, 0..) |*entity, index| entity.* = try bench.renderer.entities.create(scene, .{ .model = bench.box, .transform = math.translation(gridPoint(@intCast(index), count, 0)) });
        return entities;
    }

    fn fillList(bench: *Bench, items: u32) !void {
        const font = bench.renderer.fonts.default();
        for (0..items) |index| {
            const x: f32 = @floatFromInt(index % 64 * 10);
            const y: f32 = @floatFromInt(index / 64 % 36 * 10);
            try bench.list.rect(.{ .x = x, .y = y, .width = 8, .height = 8 }, gfx.Color.rgba(200, 120, 40, 200));
            if (index % 10 == 0) try bench.list.text(font, "costs 0123", .{ x, y }, .{ .size = 12 });
        }
    }
};

/// Counts allocations and growing resizes, from any thread.
const CountingAllocator = struct {
    backing: std.mem.Allocator,
    count: std.atomic.Value(usize) = .init(0),
    /// Bytes allocated and not yet freed.
    live: std.atomic.Value(i64) = .init(0),

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        _ = self.count.fetchAdd(1, .monotonic);
        const result = self.backing.rawAlloc(len, alignment, return_address) orelse return null;
        _ = self.live.fetchAdd(@intCast(len), .monotonic);
        return result;
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        if (new_len > memory.len) _ = self.count.fetchAdd(1, .monotonic);
        if (!self.backing.rawResize(memory, alignment, new_len, return_address)) return false;
        _ = self.live.fetchAdd(@as(i64, @intCast(new_len)) - @as(i64, @intCast(memory.len)), .monotonic);
        return true;
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        if (new_len > memory.len) _ = self.count.fetchAdd(1, .monotonic);
        const result = self.backing.rawRemap(memory, alignment, new_len, return_address) orelse return null;
        _ = self.live.fetchAdd(@as(i64, @intCast(new_len)) - @as(i64, @intCast(memory.len)), .monotonic);
        return result;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        _ = self.live.fetchSub(@intCast(memory.len), .monotonic);
        self.backing.rawFree(memory, alignment, return_address);
    }
};
/// Streaming churn: every frame a model is made and shown, and the one
/// shown 50 frames before is destroyed, as a world that streams chunks
/// does. Prints the heap bytes still held after each stretch; growth per
/// frame is what the churn leaves behind.
fn churn(bench: *Bench) !void {
    const renderer = bench.renderer;
    std.debug.print("\nstreaming churn (a model made and one destroyed per frame)\n", .{});
    const scene = try renderer.scenes.create();
    defer renderer.scenes.destroy(scene);
    const kept = 50;
    var models: [kept]?gfx.Model = @splat(null);
    var entities: [kept]gfx.Entity = undefined;
    const corners = [8][3]f32{ .{ -0.5, 0, -0.5 }, .{ 0.5, 0, -0.5 }, .{ 0.5, 1, -0.5 }, .{ -0.5, 1, -0.5 }, .{ -0.5, 0, 0.5 }, .{ 0.5, 0, 0.5 }, .{ 0.5, 1, 0.5 }, .{ -0.5, 1, 0.5 } };
    const faces = [36]u32{ 0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7, 0, 1, 5, 0, 5, 4, 3, 7, 6, 3, 6, 2, 0, 4, 7, 0, 7, 3, 1, 2, 6, 1, 6, 5 };
    var frame: usize = 0;
    var previous: ?i64 = null;
    var previous_frame: usize = 0;
    for ([_]usize{ 500, 1500, 3000, 6000 }) |until| {
        while (frame < until) : (frame += 1) {
            const slot = frame % kept;
            if (models[slot]) |old| {
                renderer.entities.destroy(entities[slot]);
                renderer.models.destroy(old);
            }
            const model = try renderer.models.create(&.{.{ .positions = &corners, .indices = &faces }});
            models[slot] = model;
            entities[slot] = try renderer.entities.create(scene, .{ .model = model, .transform = math.translation(gridPoint(@intCast(slot), kept, 0)) });
            _ = try renderer.render(.{ .views = &.{.{ .scene = scene, .camera = gfx.Camera.lookAt(.{ 0, 18, 30 }, .{ 0, 0, 0 }), .target = .{ .texture = bench.target }, .settings = lightweight }}, .delta_time = 1.0 / 60.0 });
        }
        const live = bench.counting.live.load(.monotonic);
        if (previous) |before| {
            std.debug.print("{d:>7} frames: {d:>10} bytes held, {d:.1} bytes a frame since the last line\n", .{ frame, live, @as(f64, @floatFromInt(live - before)) / @as(f64, @floatFromInt(frame - previous_frame)) });
        } else std.debug.print("{d:>7} frames: {d:>10} bytes held\n", .{ frame, live });
        previous = live;
        previous_frame = frame;
    }
    for (models, entities) |model, entity| if (model) |made| {
        renderer.entities.destroy(entity);
        renderer.models.destroy(made);
    };
}

/// Spread over a square grid on the ground, lifted by `lift`.
fn gridPoint(index: u32, count: u32, lift: f32) math.Vec3 {
    const side: u32 = @max(std.math.sqrt(count), 1);
    const spacing: f32 = 40.0 / @as(f32, @floatFromInt(side));
    const column: f32 = @floatFromInt(index % side);
    const row: f32 = @floatFromInt(index / side);
    return .{ (column - @as(f32, @floatFromInt(side)) / 2) * spacing, lift, (row - @as(f32, @floatFromInt(side)) / 2) * spacing };
}

fn uiRebuilt(bench: *Bench, _: ?gfx.Scene, size: u32) !Bench.Setup {
    return .{ .scene = false, .draw_list = true, .rebuild = size, .moving = try bench.gpa.alloc(gfx.Entity, 0) };
}

fn ui(bench: *Bench, _: ?gfx.Scene, size: u32) !Bench.Setup {
    try bench.fillList(size);
    return .{ .scene = false, .draw_list = true, .moving = try bench.gpa.alloc(gfx.Entity, 0) };
}

fn uiOverScene(bench: *Bench, scene: ?gfx.Scene, size: u32) !Bench.Setup {
    try bench.fillList(size);
    bench.gpa.free(try bench.spawnBoxes(scene.?, 100));
    return .{ .draw_list = true, .moving = try bench.gpa.alloc(gfx.Entity, 0) };
}

fn still(bench: *Bench, scene: ?gfx.Scene, size: u32) !Bench.Setup {
    bench.gpa.free(try bench.spawnBoxes(scene.?, size));
    return .{ .moving = try bench.gpa.alloc(gfx.Entity, 0) };
}

fn allMoving(bench: *Bench, scene: ?gfx.Scene, size: u32) !Bench.Setup {
    return .{ .moving = try bench.spawnBoxes(scene.?, size) };
}

fn tenMoving(bench: *Bench, scene: ?gfx.Scene, size: u32) !Bench.Setup {
    const entities = try bench.spawnBoxes(scene.?, size);
    defer bench.gpa.free(entities);
    return .{ .moving = try bench.gpa.dupe(gfx.Entity, entities[0..@min(10, entities.len)]) };
}

fn fullStill(bench: *Bench, scene: ?gfx.Scene, size: u32) !Bench.Setup {
    var setup = try still(bench, scene, size);
    setup.settings = .{};
    return setup;
}

fn fullLights(bench: *Bench, scene: ?gfx.Scene, size: u32) !Bench.Setup {
    bench.gpa.free(try bench.spawnBoxes(scene.?, 100));
    const lights = try bench.gpa.alloc(gfx.LightDesc, size);
    defer bench.gpa.free(lights);
    for (lights, 0..) |*light, index| light.* = .{ .position = gridPoint(@intCast(index), size, 2), .color = .{ 1, 0.8, 0.6 }, .intensity = 4, .range = 6 };
    try bench.renderer.scenes.setLights(scene.?, lights);
    return .{ .settings = .{}, .moving = try bench.gpa.alloc(gfx.Entity, 0) };
}

fn churning(bench: *Bench, scene: ?gfx.Scene, size: u32) !Bench.Setup {
    var setup = try still(bench, scene, size);
    setup.churn = 10;
    return setup;
}

fn manyViews(bench: *Bench, scene: ?gfx.Scene, size: u32) !Bench.Setup {
    bench.gpa.free(try bench.spawnBoxes(scene.?, 100));
    return .{ .views = size, .moving = try bench.gpa.alloc(gfx.Entity, 0) };
}

fn sceneViews(bench: *Bench, scene: ?gfx.Scene, size: u32) !Bench.Setup {
    var setup = try manyViews(bench, scene, size);
    setup.settings = .{};
    setup.scene_per_view = true;
    return setup;
}

fn manyViewsFull(bench: *Bench, scene: ?gfx.Scene, size: u32) !Bench.Setup {
    var setup = try manyViews(bench, scene, size);
    setup.settings = .{};
    return setup;
}

fn instanced(bench: *Bench, scene: ?gfx.Scene, size: u32) !Bench.Setup {
    const transforms = try bench.gpa.alloc(math.Mat4, size);
    defer bench.gpa.free(transforms);
    for (transforms, 0..) |*transform, index| transform.* = math.translation(gridPoint(@intCast(index), size, 0));
    _ = try bench.renderer.instances.create(scene.?, bench.box, transforms);
    return .{ .moving = try bench.gpa.alloc(gfx.Entity, 0) };
}

const scenarios = [_]Bench.Scenario{
    .{ .name = "2D only", .unit = "rect, a tenth with text", .sizes = &.{ 0, 100, 1000, 10000 }, .build = ui },
    .{ .name = "2D only, rebuilt every frame", .unit = "rect, a tenth with text", .sizes = &.{ 0, 100, 1000, 10000 }, .build = uiRebuilt },
    .{ .name = "2D over lightweight 3D (100 boxes)", .unit = "rect, a tenth with text", .sizes = &.{ 0, 100, 1000, 10000 }, .build = uiOverScene },
    .{ .name = "lightweight 3D, still", .unit = "entity", .sizes = &.{ 1, 100, 1000, 10000 }, .build = still },
    .{ .name = "lightweight 3D, all moving", .unit = "entity", .sizes = &.{ 1, 100, 1000, 10000 }, .build = allMoving },
    .{ .name = "lightweight 3D, ten moving", .unit = "entity", .sizes = &.{ 10, 100, 1000, 10000 }, .build = tenMoving },
    .{ .name = "lightweight 3D, ten made and destroyed a frame", .unit = "entity", .sizes = &.{ 100, 1000, 10000, 100000 }, .build = churning },
    .{ .name = "lightweight 3D, instance group", .unit = "instance", .sizes = &.{ 1, 100, 1000, 10000 }, .build = instanced },
    .{ .name = "lightweight 3D, views (100 boxes)", .unit = "view", .sizes = &.{ 1, 2, 4, 8 }, .build = manyViews },
    .{ .name = "everything on, still", .unit = "entity", .sizes = &.{ 1, 100, 1000, 10000 }, .build = fullStill },
    .{ .name = "everything on, lights (100 boxes)", .unit = "light", .sizes = &.{ 0, 64, 256, 1024, 4096 }, .build = fullLights, .scope = "light clusters" },
    .{ .name = "everything on, views of scenes of their own (100 boxes each)", .unit = "view", .sizes = &.{ 1, 2, 4, 8 }, .build = sceneViews },
    .{ .name = "everything on, views (100 boxes)", .unit = "view", .sizes = &.{ 1, 2, 4, 8 }, .build = manyViewsFull },
};

pub fn main(init: std.process.Init) !void {
    var only: ?[]const u8 = null;
    var device: ?[]const u8 = null;
    var show_passes = false;
    var threads: u32 = 0;
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--passes")) {
            show_passes = true;
        } else if (std.mem.eql(u8, arg, "--threads")) {
            threads = try std.fmt.parseInt(u32, args.next() orelse return error.MissingArgument, 10);
        } else if (std.mem.eql(u8, arg, "--device")) {
            device = try init.gpa.dupe(u8, args.next() orelse return error.MissingArgument);
        } else only = try init.gpa.dupe(u8, arg);
    }
    defer if (only) |name| init.gpa.free(name);
    defer if (device) |name| init.gpa.free(name);

    var counting = CountingAllocator{ .backing = init.gpa };
    const renderer = try gfx.Renderer.init(counting.allocator(), init.io, .{ .application_name = "limn costs", .deterministic = true, .job_allocator = counting.allocator(), .preferred_device = device, .worker_threads = threads });
    defer renderer.deinit();
    std.debug.print("{s} GPU, unified memory {}\n", .{ @tagName(renderer.device.adapterInfo().kind), renderer.device.caps.unified_memory });
    const target = try renderer.views.createTarget(width, height);
    defer renderer.views.destroyTarget(target);
    const corners = [8][3]f32{ .{ -0.5, 0, -0.5 }, .{ 0.5, 0, -0.5 }, .{ 0.5, 1, -0.5 }, .{ -0.5, 1, -0.5 }, .{ -0.5, 0, 0.5 }, .{ 0.5, 0, 0.5 }, .{ 0.5, 1, 0.5 }, .{ -0.5, 1, 0.5 } };
    const faces = [36]u32{ 0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7, 0, 1, 5, 0, 5, 4, 3, 7, 6, 3, 6, 2, 0, 4, 7, 0, 7, 3, 1, 2, 6, 1, 6, 5 };
    var bench = Bench{
        .gpa = init.gpa,
        .renderer = renderer,
        .counting = &counting,
        .target = target,
        .box = try renderer.models.create(&.{.{ .positions = &corners, .indices = &faces }}),
        .list = gfx.DrawList.init(init.gpa),
        .extra_views = undefined,
        .show_passes = show_passes,
    };
    for (&bench.extra_views) |*view| view.* = try renderer.views.create();
    defer bench.list.deinit();
    for (scenarios) |scenario| {
        if (only) |name| if (std.mem.indexOf(u8, scenario.name, name) == null) continue;
        try bench.run(scenario);
    }
    if (only == null or std.mem.indexOf(u8, "streaming churn", only.?) != null) try churn(&bench);
}
