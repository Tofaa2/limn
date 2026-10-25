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
        const entity = try renderer.entities.create(scene, .{ .model = model, .transform = math.identity });
        const group = try renderer.instances.create(scene, model, &.{math.identity});
        renderer.instances.destroy(group);
        renderer.entities.destroy(entity);
        renderer.scenes.destroy(scene);
        renderer.models.destroy(model);

        renderer.entities.destroy(entity);
        renderer.entities.setTransform(entity, math.identity);
        renderer.entities.setTransforms(&.{entity}, &.{math.identity});
        renderer.entities.setVisible(entity, false);
        try renderer.entities.bakeLightmap(entity, null);
        try renderer.instances.setTransforms(group, &.{math.identity});
        renderer.instances.destroy(group);
        try renderer.scenes.setLights(scene, &.{});
        try renderer.scenes.setDecals(scene, &.{});
        renderer.scenes.setSun(scene, .{ .direction = .{ 0, -1, 0 }, .color = .{ 1, 1, 1 }, .intensity = 1 });
        renderer.scenes.destroy(scene);
        try renderer.materials.setShader(model, null, .{ .params = .{ 0, 0, 0, 0 } });
        renderer.models.destroy(model);

        if (renderer.models.state(model) != .failed) return error.StaleModelHasState;
        if (renderer.models.info(model) != null) return error.StaleModelHasInfo;
        if (renderer.entities.lightmapProgress(entity) != null) return error.StaleEntityAnswered;
        if (renderer.entities.create(scene, .{ .model = self.box_model, .transform = math.identity }) != error.InvalidScene) return error.SpawnedInStaleScene;
        if (renderer.entities.create(self.scene, .{ .model = model, .transform = math.identity }) != error.InvalidModel) return error.SpawnedStaleModel;
        try self.draw(2);
        std.log.info("stale handles: ignored by setters, empty to queries, refused by create", .{});
    }

    /// Images, fonts and canvas shaders destroyed while still in use: draw
    /// lists with them are refused, materials, lights and decals stop
    /// sampling them, and a new image in the freed slot is not mistaken for
    /// the old one.
    fn staleDrawResources(self: *Checks) !void {
        const renderer = self.renderer;
        const pixels = [_]u8{ 255, 255, 255, 255 };
        const gone = try renderer.images.create(.{ .width = 1, .height = 1, .pixels = &pixels });
        const font = try renderer.fonts.load("src/render/fonts/DejaVuSans.ttf", &.{.{ 32, 126 }});
        var list = gfx.DrawList.init(self.gpa);
        defer list.deinit();
        try list.image(gone, .{ .x = 0, .y = 0, .width = 8, .height = 8 }, .{});
        try list.text(font, "stale", .{ 0, 0 }, .{});
        try self.drawList(&list);

        try renderer.materials.setTextures(self.box_model, null, .{ .base_color = gone });
        try renderer.scenes.setLights(self.scene, &.{.{ .kind = .spot, .position = .{ 0, 3, 0 }, .direction = .{ 0, -1, 0 }, .color = .{ 1, 1, 1 }, .intensity = 10, .cookie = gone, .profile = gone }});
        try renderer.scenes.setDecals(self.scene, &.{.{ .transform = math.identity, .image = gone }});
        renderer.images.destroy(gone);
        renderer.fonts.destroy(font);
        var reused: [64]gfx.Image = undefined;
        for (&reused) |*image| image.* = try renderer.images.create(.{ .width = 1, .height = 1, .pixels = &pixels });
        defer for (reused) |image| renderer.images.destroy(image);
        try self.draw(4);
        if (renderer.images.valid(gone)) return error.DestroyedImageValid;
        if (self.drawList(&list) != error.InvalidImage) return error.StaleImageDrawn;
        list.clear();
        try list.text(font, "stale", .{ 0, 0 }, .{});
        if (self.drawList(&list) != error.InvalidFont) return error.StaleFontDrawn;
        list.clear();
        try list.setShader(.{ .slot = 0, .generation = 1234 });
        try list.rect(.{ .x = 0, .y = 0, .width = 8, .height = 8 }, .white);
        if (self.drawList(&list) != error.InvalidShader) return error.StaleShaderDrawn;
        if (renderer.materials.setTextures(self.box_model, null, .{ .base_color = gone }) != error.InvalidImage) return error.StaleImageSet;
        list.clear();
        try list.image(reused[0], .{ .x = 0, .y = 0, .width = 8, .height = 8 }, .{});
        try self.drawList(&list);
        try renderer.scenes.setLights(self.scene, &.{});
        try renderer.scenes.setDecals(self.scene, &.{});
        std.log.info("stale draw resources: images, fonts and canvas shaders refused once destroyed", .{});
    }

    /// Parenting, entity info, unlit materials, primitives with textures,
    /// text measuring and saving a target.
    fn sceneApi(self: *Checks) !void {
        const renderer = self.renderer;
        const scene = try renderer.scenes.create();
        const pixels = [_]u8{ 255, 255, 255, 255 };
        const image = try renderer.images.create(.{ .width = 1, .height = 1, .pixels = &pixels });
        const ball = try renderer.models.createPrimitive(.{ .shape = .{ .sphere = .{ .radius = 0.3 } }, .textures = .{ .base_color = image } });
        renderer.images.destroy(image);
        if (renderer.models.createPrimitive(.{ .shape = .{ .box = .{} }, .textures = .{ .base_color = image } }) != error.InvalidImage) return error.StaleImageTookAtCreate;

        const parent = try renderer.entities.create(scene, .{ .model = ball, .transform = math.translation(.{ 1, 0, 0 }) });
        const child = try renderer.entities.create(scene, .{ .model = ball, .transform = math.translation(.{ 0, 1, 0 }) });
        try renderer.entities.setParent(child, parent);
        if (renderer.entities.setParent(parent, child) != error.InvalidParent) return error.ParentCycleAccepted;
        if (!placedAt(renderer.entities.info(child).?, .{ 1, 1, 0 })) return error.ChildNotUnderParent;
        renderer.entities.setTransform(parent, math.translation(.{ 0, 0, 2 }));
        if (!placedAt(renderer.entities.info(child).?, .{ 0, 1, 2 })) return error.ChildDidNotFollow;
        if (!std.meta.eql(renderer.entities.info(child).?.parent, parent)) return error.WrongParent;
        try renderer.scenes.shift(scene, .{ 1, 0, 0 });
        renderer.entities.setTransform(child, math.translation(.{ 0, 2, 0 }));
        if (!placedAt(renderer.entities.info(parent).?, .{ 1, 0, 2 }) or !placedAt(renderer.entities.info(child).?, .{ 1, 2, 2 })) return error.ShiftLostParent;
        renderer.entities.destroy(parent);
        const orphan = renderer.entities.info(child).?;
        if (orphan.parent != null or !placedAt(orphan, .{ 1, 2, 2 })) return error.OrphanMoved;

        const sky = gfx.SkyDesc{ .sun_direction = .{ -0.3, -1, -0.2 } };
        renderer.scenes.setEnvironment(scene, .{ .environment = try renderer.environments.createSky(sky), .intensity = 1 });
        const lit_box = try renderer.models.createPrimitive(.{ .shape = .{ .box = .{} } });
        const flat_box = try renderer.models.createPrimitive(.{ .shape = .{ .box = .{} }, .material = .{ .base_color = .{ 0.2, 0.5, 0.8, 1 }, .unlit = true } });
        renderer.entities.destroy(child);
        _ = try renderer.entities.create(scene, .{ .model = lit_box, .transform = math.translation(.{ -0.8, 0.5, 0 }) });
        _ = try renderer.entities.create(scene, .{ .model = flat_box, .transform = math.translation(.{ 0.8, 0.5, 0 }) });
        try renderer.waitUntilLoaded();
        const camera = gfx.Camera.lookAt(.{ 0, 1.5, 4 }, .{ 0, 0.5, 0 });
        const size = [2]f32{ width, height };
        const lit_pixel = camera.project(.{ -0.8, 0.5, 0.5 }, size) orelse return error.BoxBehindCamera;
        const flat_pixel = camera.project(.{ 0.8, 0.5, 0.5 }, size) orelse return error.BoxBehindCamera;
        var seen: [2][2][4]u8 = undefined;
        for ([2]f32{ 1, 8 }, 0..) |intensity, round| {
            renderer.scenes.setSun(scene, .{ .direction = sky.sun_direction, .intensity = intensity });
            for (0..4) |_| _ = try renderer.render(.{
                .views = &.{.{ .scene = scene, .camera = camera, .target = .{ .texture = self.target }, .settings = .{ .post = .{ .automatic_exposure = false } } }},
                .delta_time = 1.0 / 60.0,
            });
            try renderer.device.waitIdle();
            const read = try renderer.device.readTexture(self.gpa, self.target);
            defer self.gpa.free(read);
            for ([2][2]f32{ lit_pixel.pixel, flat_pixel.pixel }, 0..) |at, which| {
                const index = (@as(usize, @intFromFloat(at[1])) * width + @as(usize, @intFromFloat(at[0]))) * 4;
                seen[round][which] = read[index..][0..4].*;
            }
        }
        if (std.meta.eql(seen[0][0], seen[1][0])) return error.LitBoxIgnoredTheSun;
        for (0..3) |channel| if (@abs(@as(i32, seen[0][1][channel]) - seen[1][1][channel]) > 2) return error.UnlitBoxWasLit;

        try renderer.views.saveTarget(self.target, cache_dir ++ "/saved.png");
        const saved = try std.Io.Dir.cwd().statFile(self.io, cache_dir ++ "/saved.png", .{});
        if (saved.size < width * height * 4) return error.TargetNotSaved;

        var list = gfx.DrawList.init(self.gpa);
        defer list.deinit();
        const font = renderer.fonts.default();
        const measured = try list.measureText(font, "Limn\nlines", .{ .size = 20 });
        const plain = font.measure("Limn\nlines", 20);
        if (@abs(measured[0] - plain[0]) > 1e-3 or @abs(measured[1] - plain[1]) > 1e-3 or !list.isEmpty()) return error.MeasureDisagrees;
        renderer.scenes.destroy(scene);
        for ([_]gfx.Model{ ball, lit_box, flat_box }) |model| renderer.models.destroy(model);
        try self.draw(2);
        for ([_]gfx.Model{ ball, lit_box, flat_box }) |model| if (renderer.models.state(model) != .failed) return error.ModelOutlivedItsEntities;
        std.log.info("scene api: parents, entity info, unlit, primitives with textures, text measured, target saved", .{});
    }

    fn placedAt(info: gfx.EntityInfo, where: math.Vec3) bool {
        const at = info.world_transform[12..15].*;
        return math.length(math.sub(at, where)) < 1e-4;
    }

    fn drawList(self: *Checks, list: *const gfx.DrawList) !void {
        _ = try self.renderer.render(.{
            .views = &.{.{ .scene = self.scene, .camera = self.camera, .target = .{ .texture = self.target }, .draw_lists = &.{.{ .list = list }} }},
            .delta_time = 1.0 / 60.0,
        });
    }

    /// Other threads move and create entities while frames are drawn. The crowd
    /// is large enough for its instance records to be written across threads.
    fn threads(self: *Checks) !void {
        const renderer = self.renderer;
        const crowd = try self.gpa.alloc(gfx.Entity, 12_000);
        defer self.gpa.free(crowd);
        const home = try self.gpa.alloc(math.Mat4, crowd.len);
        defer self.gpa.free(home);
        for (crowd, home, 0..) |*entity, *at, index| {
            at.* = math.translation(.{ @floatFromInt(index % 32), 0, -4 - @as(f32, @floatFromInt(index / 32)) });
            entity.* = try renderer.entities.create(self.scene, .{ .model = self.box_model, .transform = at.* });
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
                    const entity = checks.renderer.entities.create(checks.scene, .{ .model = checks.box_model, .transform = math.translation(.{ 0, 3, 0 }) }) catch return broke.store(true, .release);
                    checks.renderer.entities.setTransform(entity, math.translation(.{ 0, 4, 0 }));
                    _ = checks.renderer.stats();
                    checks.renderer.entities.destroy(entity);
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
        for (crowd) |entity| renderer.entities.destroy(entity);
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
            entity.* = try renderer.entities.create(self.scene, .{ .model = self.box_model, .transform = math.mul(math.translation(.{ x, 1.2, -1 }), math.scaling(.{ 0.24, 0.5, 0.24 })) });
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
        for (row) |entity| renderer.entities.destroy(entity);
        try self.draw(2);
        std.log.info("moves: the picture changed by {d:.2} levels, and differs by {d:.2} from one drawn afresh", .{ changed, apart });
    }

    fn failedPass(self: *Checks) !void {
        const broken: []const gfx.Pass = &.{.{ .stage = .after_opaque, .run = failingPass }};
        const outcome = self.renderer.render(.{ .views = &.{.{ .scene = self.scene, .camera = self.camera, .target = .{ .texture = self.target }, .passes = broken }}, .delta_time = 1.0 / 60.0 });
        if (outcome != error.InjectedFailure) return error.FailureNotReported;
        try self.draw(2);
        std.log.info("failed pass: reported, and the next frame drew", .{});
    }

    fn placedLightsAndDecals(self: *Checks) !void {
        const renderer = self.renderer;
        try renderer.scenes.setLights(self.scene, &.{.{ .position = .{ 0, 2, 0 }, .intensity = 3 }});
        const first = try renderer.lights.create(self.scene, .{ .position = .{ 1, 2, 0 }, .intensity = 1 });
        const second = try renderer.lights.create(self.scene, .{ .position = .{ -1, 2, 0 }, .intensity = 2 });
        renderer.lights.destroy(first);
        renderer.lights.set(second, .{ .position = .{ -1, 2, 0 }, .intensity = 5 });
        renderer.lights.destroy(first);
        const decal = try renderer.decals.create(self.scene, .{ .transform = math.identity, .color = .{ 1, 0, 0, 1 } });
        try self.draw(2);
        const data = renderer.scenes.internal.table.get(self.scene).?;
        if (data.lights.items.len != 2 or data.lights.items[0].intensity != 3 or data.lights.items[1].intensity != 5) return error.PlacedLightsWrong;
        if (data.decals.items.len != 1) return error.PlacedDecalMissing;
        renderer.decals.destroy(decal);
        try renderer.scenes.setLights(self.scene, &.{});
        renderer.lights.set(second, .{ .position = .{ 0, 0, 0 }, .intensity = 9 });
        if (data.lights.items.len != 0 or data.decals.items.len != 0 or renderer.lights.internal.table.get(second) != null) return error.PlacedHandlesOutlivedTheirLists;
        try self.draw(2);
        std.log.info("placed lights and decals: created, set and destroyed by handle beside the whole list", .{});
    }

    /// A destroyed instance group stops being drawn, a scene can go before
    /// the handles into it, and a scene keeping lights and decals by handle
    /// is left for the renderer to free.
    fn lifecycle(self: *Checks) !void {
        const renderer = self.renderer;
        try self.draw(1);
        const before = renderer.stats().instances;
        const group = try renderer.instances.create(self.scene, self.box_model, &.{ math.translation(.{ 2, 0, 0 }), math.translation(.{ -2, 0, 0 }) });
        try self.draw(2);
        if (renderer.stats().instances != before + 2) return error.GroupNotDrawn;
        renderer.instances.destroy(group);
        try self.draw(2);
        if (renderer.stats().instances != before) return error.DestroyedGroupStillDrawn;

        const gone = try renderer.scenes.create();
        const light = try renderer.lights.create(gone, .{ .position = .{ 0, 2, 0 }, .intensity = 1 });
        const decal = try renderer.decals.create(gone, .{ .transform = math.identity, .color = .{ 1, 0, 0, 1 } });
        const copies = try renderer.instances.create(gone, self.box_model, &.{math.identity});
        renderer.scenes.destroy(gone);
        renderer.lights.set(light, .{ .position = .{ 0, 0, 0 }, .intensity = 2 });
        renderer.lights.destroy(light);
        renderer.decals.destroy(decal);
        renderer.instances.destroy(copies);

        const kept = try renderer.scenes.create();
        _ = try renderer.lights.create(kept, .{ .position = .{ 0, 2, 0 }, .intensity = 1 });
        _ = try renderer.decals.create(kept, .{ .transform = math.identity, .color = .{ 0, 1, 0, 1 } });
        _ = try renderer.instances.create(kept, self.box_model, &.{math.identity});
        try self.draw(2);
        std.log.info("lifecycle: destroyed groups leave the scene, scenes go before their handles", .{});
    }

    /// Six views with different settings drawn together, some destroyed and
    /// others made between frames, then all destroyed: no validation errors,
    /// and their memory is given back.
    fn manyViews(self: *Checks) !void {
        const renderer = self.renderer;
        try self.draw(4);
        try renderer.device.waitIdle();
        const before = renderer.stats().gpu_memory_bytes;
        var views: [6]?gfx.View = @splat(null);
        var targets: [6]gfx.rhi.Texture = undefined;
        for (&targets) |*target| target.* = try renderer.views.createTarget(width / 2, height / 2);
        defer for (targets) |target| renderer.views.destroyTarget(target);
        const settings = [6]gfx.Settings{ .{}, gfx.Settings.lightweight, .{ .shadows = .{ .virtual = true } }, .{ .reflections = null }, .{ .resolution = .{ .scale = 0.5, .upscaler = .fsr } }, gfx.Settings.lightweight };
        for (0..12) |round| {
            for (&views, 0..) |*view, index| {
                const due = (round + index) % 4 == 0;
                if (due) if (view.*) |old| {
                    renderer.views.destroy(old);
                    view.* = null;
                } else {
                    view.* = try renderer.views.create();
                };
            }
            var descs: [6]gfx.ViewDesc = undefined;
            var count: usize = 0;
            for (views, targets, settings, 0..) |view, target, setting, index| {
                const made = view orelse continue;
                const angle: f32 = @floatFromInt(index);
                descs[count] = .{ .view = made, .scene = self.scene, .camera = gfx.Camera.lookAt(.{ 4 * @sin(angle), 1.5, 4 * @cos(angle) }, .{ 0, 0.5, 0 }), .target = .{ .texture = target }, .settings = setting };
                count += 1;
            }
            for (0..3) |_| _ = try renderer.render(.{ .views = descs[0..count], .delta_time = 1.0 / 60.0 });
        }
        for (views) |view| if (view) |made| renderer.views.destroy(made);
        try self.draw(12);
        try renderer.device.waitIdle();
        const after = renderer.stats().gpu_memory_bytes;
        if (renderer.device.validationErrorCount() != 0) return error.ValidationErrors;
        if (after > before + 1024 * 1024) {
            std.log.err("many views: {d} KiB more after all were destroyed", .{(after - before) / 1024});
            return error.DestroyedViewsKeptMemory;
        }
        std.log.info("many views: six views made, drawn and destroyed in turn, memory back within {d} KiB", .{(after -| before) / 1024});
    }

    /// A box and its mirror image through the plane x = 0, lit and seen from
    /// that plane, draw the same: mirrored instances keep their faces and
    /// their normals pointing out.
    fn mirrored(self: *Checks) !void {
        const renderer = self.renderer;
        const scene = try renderer.scenes.create();
        renderer.scenes.setSun(scene, .{ .direction = .{ 0, -0.8, -0.6 }, .color = .{ 1, 1, 1 }, .intensity = 4 });
        const box = try renderer.entities.create(scene, .{ .model = self.box_model, .transform = math.mul(math.translation(.{ 0.3, 0, 0 }), math.rotationY(0.6)) });
        const Frames = struct {
            fn read(checks: *Checks, view_scene: gfx.Scene) ![]u8 {
                for (0..8) |_| _ = try checks.renderer.render(.{ .views = &.{.{ .scene = view_scene, .camera = gfx.Camera.lookAt(.{ 0, 1.6, 3.5 }, .{ 0, 0.4, 0 }), .target = .{ .texture = checks.target }, .settings = gfx.Settings.lightweight }}, .delta_time = 1.0 / 60.0 });
                return checks.renderer.device.readTexture(checks.gpa, checks.target);
            }
        };
        const plain = try Frames.read(self, scene);
        defer self.gpa.free(plain);
        renderer.entities.setTransform(box, math.mul(math.scaling(.{ -1, 1, 1 }), math.mul(math.translation(.{ 0.3, 0, 0 }), math.rotationY(0.6))));
        const mirror = try Frames.read(self, scene);
        defer self.gpa.free(mirror);
        var flipped = try self.gpa.alloc(u8, mirror.len);
        defer self.gpa.free(flipped);
        for (0..height) |y| for (0..width) |x| {
            @memcpy(flipped[(y * width + x) * 4 ..][0..4], mirror[(y * width + (width - 1 - x)) * 4 ..][0..4]);
        };
        const apart = levelsApart(plain, flipped);
        if (apart > 1.0) return error.MirroredInstanceDrawnWrong;
        std.log.info("mirrored: a box and its mirror image draw alike ({d:.4} apart)", .{apart});
    }

    /// Each feature, switched on over a view with everything off and then off
    /// again, leaves the view recording exactly what it did before and gives
    /// back its GPU memory. One with nothing to draw records nothing.
    fn switchedOffCosts(self: *Checks) !void {
        const lightweight = gfx.Settings.lightweight;
        const Toggle = struct { name: []const u8, settings: gfx.Settings, nothing_to_draw: bool = false };
        var toggles: [18]Toggle = undefined;
        for (&toggles) |*toggle| toggle.* = .{ .name = "", .settings = lightweight };
        toggles[0].name = "shadows";
        toggles[0].settings.shadows = .{};
        toggles[1].name = "ambient occlusion";
        toggles[1].settings.ambient_occlusion = .{};
        toggles[2].name = "reflections";
        toggles[2].settings.reflections = .{};
        toggles[3].name = "global illumination";
        toggles[3].settings.global_illumination = .{ .probes = .{} };
        toggles[4].name = "path tracing";
        toggles[4].settings.path_tracing = .{};
        toggles[5].name = "fog";
        toggles[5].settings.fog = .{};
        toggles[6] = .{ .name = "clouds", .settings = lightweight, .nothing_to_draw = true };
        toggles[6].settings.clouds = .{};
        toggles[7] = .{ .name = "fluids", .settings = lightweight, .nothing_to_draw = true };
        toggles[7].settings.fluids = .{};
        toggles[8].name = "bloom";
        toggles[8].settings.post.bloom = 0.04;
        toggles[9].name = "automatic exposure";
        toggles[9].settings.post.automatic_exposure = true;
        toggles[10].name = "depth of field";
        toggles[10].settings.post.depth_of_field = .{};
        toggles[11].name = "motion blur";
        toggles[11].settings.post.motion_blur = .{};
        toggles[12].name = "temporal antialiasing";
        toggles[12].settings.resolution.temporal_antialiasing = true;
        toggles[13].name = "edge antialiasing";
        toggles[13].settings.resolution.edge_antialiasing = true;
        toggles[14].name = "variable rate shading";
        toggles[14].settings.shading.variable_rate = true;
        toggles[15].name = "spatial upscaling";
        toggles[15].settings.resolution.scale = 0.75;
        toggles[15].settings.resolution.upscaler = .fsr;
        toggles[16] = .{ .name = "weighted transparency", .settings = lightweight, .nothing_to_draw = true };
        toggles[16].settings.transparency.mode = .weighted;
        toggles[17] = .{ .name = "peeled transparency", .settings = lightweight, .nothing_to_draw = true };
        toggles[17].settings.transparency.mode = .peeled;

        const Frames = struct {
            fn draw(checks: *Checks, count: usize, settings: gfx.Settings) !gfx.Stats {
                for (0..count) |_| _ = try checks.renderer.render(.{ .views = &.{.{ .scene = checks.scene, .camera = checks.camera, .target = .{ .texture = checks.target }, .settings = settings }}, .delta_time = 1.0 / 60.0 });
                return checks.renderer.stats();
            }

            fn same(a: gfx.rhi.Work, b: gfx.rhi.Work) bool {
                var x = a;
                var y = b;
                x.staged_bytes = 0;
                y.staged_bytes = 0;
                return std.meta.eql(x, y);
            }
        };
        const baseline = try Frames.draw(self, 16, lightweight);
        var failures: usize = 0;
        for (toggles) |toggle| {
            if (std.mem.eql(u8, toggle.name, "path tracing") and self.renderer.capabilities().path_tracing == .unavailable) continue;
            const on = try Frames.draw(self, 16, toggle.settings);
            if (!toggle.nothing_to_draw and on.downgraded().len == 0 and Frames.same(on.commands, baseline.commands)) {
                std.log.err("switched off: {s} recorded nothing when on", .{toggle.name});
                failures += 1;
            }
            if (toggle.nothing_to_draw and !Frames.same(on.commands, baseline.commands)) {
                std.log.err("switched off: {s} has nothing to draw and recorded {any} over {any}", .{ toggle.name, on.commands, baseline.commands });
                failures += 1;
            }
            const off = try Frames.draw(self, 16, lightweight);
            if (!Frames.same(off.commands, baseline.commands)) {
                std.log.err("switched off: {s} still records {any} over {any}", .{ toggle.name, off.commands, baseline.commands });
                failures += 1;
            }
            const grown = on.gpu_memory_bytes -| baseline.gpu_memory_bytes;
            if (off.gpu_memory_bytes > baseline.gpu_memory_bytes + grown / 4 + 64 * 1024) {
                std.log.err("switched off: {s} took {d} KiB and kept {d} KiB", .{ toggle.name, grown / 1024, (off.gpu_memory_bytes - baseline.gpu_memory_bytes) / 1024 });
                failures += 1;
            }
        }
        if (failures != 0) return error.SwitchedOffFeatureStillCosts;
        std.log.info("switched off: {d} features record nothing and keep no memory once off", .{toggles.len});
    }

    /// Path tracing gathers over frames, starts over after a cut or a frame
    /// it did not trace, and gives its targets back within a few frames of
    /// being switched off.
    fn switchedOffMemory(self: *Checks) !void {
        const renderer = self.renderer;
        if (renderer.capabilities().path_tracing == .unavailable) return std.log.info("switched off: skipped, no path tracing", .{});
        const Frames = struct {
            fn draw(checks: *Checks, count: usize, settings: gfx.Settings, cut: bool) !void {
                for (0..count) |_| _ = try checks.renderer.render(.{ .views = &.{.{ .scene = checks.scene, .camera = checks.camera, .target = .{ .texture = checks.target }, .settings = settings, .cut = cut }}, .delta_time = 1.0 / 60.0 });
            }
        };
        try Frames.draw(self, 20, .{}, false);
        const before = renderer.stats().gpu_memory_bytes;
        try Frames.draw(self, 20, .{ .path_tracing = .{} }, false);
        if (renderer.stats().path_traced_frames < 10) return error.PathTracingDidNotGather;
        try Frames.draw(self, 1, .{ .path_tracing = .{} }, true);
        if (renderer.stats().path_traced_frames != 1) return error.CutKeptHistory;
        try Frames.draw(self, 1, .{}, false);
        try Frames.draw(self, 1, .{ .path_tracing = .{} }, false);
        if (renderer.stats().path_traced_frames != 1) return error.GapKeptHistory;
        const tracing = renderer.stats().gpu_memory_bytes;
        if (tracing <= before) return error.PathTracingTookNoMemory;
        try Frames.draw(self, 20, .{}, false);
        const after = renderer.stats().gpu_memory_bytes;
        if (after > before + (tracing - before) / 4) return error.SwitchedOffFeatureKeptItsMemory;
        std.log.info("switched off: path tracing took {d} KiB and gave {d} KiB back", .{ (tracing - before) / 1024, (tracing - after) / 1024 });
    }

    /// A view drawn at a different size every frame, with the temporal
    /// features that keep pictures between frames, and its targets replaced
    /// in between.
    fn resizing(self: *Checks) !void {
        const renderer = self.renderer;
        const sizes = [_][2]u32{ .{ 320, 180 }, .{ 200, 120 }, .{ 640, 360 }, .{ 1, 1 }, .{ 321, 179 } };
        const view = try renderer.views.create();
        defer renderer.views.destroy(view);
        const tracing: @FieldType(gfx.Settings, "path_tracing") = if (renderer.capabilities().path_tracing == .unavailable) null else .{};
        for (0..3) |round| {
            for (sizes) |size| {
                const target = try renderer.views.createTarget(size[0], size[1]);
                defer renderer.views.destroyTarget(target);
                const settings: gfx.Settings = .{ .path_tracing = if (round == 1) tracing else null, .shadows = .{ .virtual = round == 2 } };
                for (0..2) |_| _ = try renderer.render(.{ .views = &.{.{ .view = view, .scene = self.scene, .camera = self.camera, .target = .{ .texture = target }, .settings = settings }}, .delta_time = 1.0 / 60.0 });
            }
        }
        try self.draw(2);
        std.log.info("resizing: {d} sizes a frame apart, with and without path tracing and virtual shadows", .{sizes.len});
    }

    /// Shaders reloaded just before a model comes close enough for finer
    /// texture levels to stream in.
    fn reloadWhileStreaming(self: *Checks) !void {
        const renderer = self.renderer;
        const fox = try renderer.models.load(fox_path);
        defer renderer.models.destroy(fox);
        try renderer.waitUntilLoaded();
        const scale = math.scaling(.{ 0.02, 0.02, 0.02 });
        const entity = try renderer.entities.create(self.scene, .{ .model = fox, .transform = math.mul(math.translation(.{ 0, 0, -60 }), scale) });
        defer renderer.entities.destroy(entity);
        try self.draw(20);
        const far = renderer.stats().streamed_texture_bytes;
        _ = renderer.shaders.reload() catch |err| {
            if (@as(anyerror, err) != error.ShaderReloadDisabled) return err;
            return std.log.info("reload while streaming: shader reload left out of this build", .{});
        };
        renderer.entities.setTransform(entity, math.mul(math.translation(.{ -1.5, 0, 0 }), scale));
        var near = far;
        var still: u32 = 0;
        for (0..300) |_| {
            try self.draw(1);
            const now = renderer.stats().streamed_texture_bytes;
            still = if (now == near) still + 1 else 0;
            near = now;
            if (still == 16) break;
        } else return error.StreamingNeverSettled;
        if (near <= far) return error.NothingStreamedAfterReload;
        std.log.info("reload while streaming: {d} KiB far, {d} KiB once close", .{ far / 1024, near / 1024 });
    }

    fn scenePassReads(self: *Checks) !void {
        var seen = Seen{};
        const passes: []const gfx.Pass = &.{
            .{ .stage = .after_opaque, .reads = &.{ .visibility, .ambient_occlusion }, .context = &seen, .run = readingPass },
            .{ .stage = .after_resolve, .context = &seen, .run = readingPass },
            .{ .stage = .sun_shadow, .context = &seen, .run = readingPass },
        };
        for (0..2) |_| _ = try self.renderer.render(.{ .views = &.{.{ .scene = self.scene, .camera = self.camera, .target = .{ .texture = self.target }, .passes = passes }}, .delta_time = 1.0 / 60.0 });
        if (seen.stages[@intFromEnum(gfx.PassStage.after_opaque)] != 2 or seen.stages[@intFromEnum(gfx.PassStage.after_resolve)] != 2) return error.ScenePassNotRun;
        if (seen.stages[@intFromEnum(gfx.PassStage.sun_shadow)] < 2) return error.ShadowPassNotRun;
        if (!seen.visibility or !seen.ambient_occlusion) return error.PassReadsMissing;
        if (seen.unasked) return error.PassGotUnaskedReads;
        try self.draw(2);
        std.log.info("scene passes: run after opaque, after resolve and into {d} sun cascades, with the textures they read", .{seen.stages[@intFromEnum(gfx.PassStage.sun_shadow)]});
    }

    fn plainViewPasses(self: *Checks) !void {
        var calls: u32 = 0;
        for ([_]gfx.PassStage{ .after_tonemap, .after_opaque }) |stage| {
            const passes: []const gfx.Pass = &.{.{ .stage = stage, .context = &calls, .run = fillingPass }};
            for (0..2) |_| _ = try self.renderer.render(.{ .views = &.{.{ .target = .{ .texture = self.target }, .passes = passes }}, .delta_time = 1.0 / 60.0 });
            const pixels = try self.renderer.device.readTexture(self.gpa, self.target);
            defer self.gpa.free(pixels);
            if (pixels[1] < 100 or pixels[0] > 100) return error.PassOnPlainViewNotDrawn;
        }
        if (calls != 4) return error.PassOnPlainViewNotRun;
        try self.draw(2);
        std.log.info("passes on a view without a scene: drawn before and after tone mapping", .{});
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
        const entity = try self.renderer.entities.create(self.scene, .{ .model = fox, .transform = math.mul(math.translation(.{ 1.5, 0, 0 }), math.scaling(.{ 0.02, 0.02, 0.02 })) });
        var settled = false;
        for (0..300) |_| {
            try self.draw(1);
            const stats = self.renderer.stats();
            if (stats.streamed_textures != 0 and stats.streamed_textures_pending == 0) {
                settled = true;
                break;
            }
        }
        const stats = self.renderer.stats();
        if (stats.streamed_textures == 0) return error.NothingStreamed;
        if (!settled) return error.StreamingNeverSettled;

        var folder = try std.Io.Dir.cwd().openDir(self.io, cache_dir, .{ .iterate = true });
        defer folder.close(self.io);
        var files = folder.iterate();
        var cached: usize = 0;
        while (try files.next(self.io)) |_| cached += 1;
        if (cached == 0) return error.NothingCached;

        self.renderer.entities.destroy(entity);
        self.renderer.models.destroy(fox);
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
        const entity = try self.renderer.entities.create(self.scene, .{ .model = small, .transform = math.translation(.{ -3, 1.5, 0 }) });
        try self.renderer.waitUntilLoaded();
        try self.draw(40);
        const pixels_before = try self.renderer.device.readTexture(self.gpa, self.target);
        defer self.gpa.free(pixels_before);
        const before = self.renderer.stats();
        self.renderer.models.destroy(large);
        try self.draw(12);
        const moved = self.renderer.stats().geometry_bytes_compacted - before.geometry_bytes_compacted;
        if (moved == 0) return error.GeometryNotCompacted;
        const pixels_after = try self.renderer.device.readTexture(self.gpa, self.target);
        defer self.gpa.free(pixels_after);
        var difference: u64 = 0;
        for (pixels_before, pixels_after) |a, b| difference += @abs(@as(i32, a) - @as(i32, b));
        const mean = @as(f32, @floatFromInt(difference)) / @as(f32, @floatFromInt(pixels_before.len));
        if (mean > 3) return error.CompactedGeometryDrawnWrong;
        self.renderer.entities.destroy(entity);
        self.renderer.models.destroy(small);
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
                defer renderer.models.destroy(model);
                const entity = renderer.entities.create(self.scene, .{ .model = model, .transform = math.translation(.{ 2, 1, 0 }) }) catch |err| break :blk err;
                defer renderer.entities.destroy(entity);
                list.clear();
                list.text(renderer.fonts.default(), "out of memory", .{ 20, 20 }, .{ .size = 18 }) catch |err| break :blk err;
                const lights = [_]gfx.LightDesc{.{ .position = .{ 2, 2, 0 }, .color = .{ 1, 1, 1 }, .intensity = 5, .range = 6 }};
                renderer.scenes.setLights(self.scene, &lights) catch |err| break :blk err;
                _ = renderer.render(.{ .views = &.{.{ .scene = self.scene, .camera = self.camera, .draw_lists = &.{.{ .list = &list }}, .target = .{ .texture = self.target } }}, .delta_time = 1.0 / 60.0 }) catch |err| break :blk err;
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
            renderer.models.destroy(clean);
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
                renderer.models.destroy(model);
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
                const image = renderer.images.create(.{ .width = 16, .height = 16, .pixels = &pixels }) catch |err| break :blk err;
                defer renderer.images.destroy(image);
                const model = renderer.models.create(&.{.{ .positions = &triangle, .indices = &indices }}) catch |err| break :blk err;
                defer renderer.models.destroy(model);
                const entity = renderer.entities.create(self.scene, .{ .model = model, .transform = math.translation(.{ 2, 1, 0 }) }) catch |err| break :blk err;
                defer renderer.entities.destroy(entity);
                _ = renderer.render(.{ .views = &.{.{ .view = view, .scene = self.scene, .camera = self.camera, .target = .{ .texture = small } }}, .delta_time = 1.0 / 60.0 }) catch |err| break :blk err;
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

fn fillingPass(context: ?*anyopaque, pass: gfx.PassContext) anyerror!void {
    const calls: *u32 = @ptrCast(@alignCast(context.?));
    calls.* += 1;
    if (pass.depth != null) return error.DepthWithoutScene;
    try pass.cmd.beginRendering(.{ .color = &.{.{ .texture = pass.color, .load = .clear, .clear = .{ 0, 1, 0, 1 } }} });
    pass.cmd.endRendering();
}

const Seen = struct {
    stages: [std.enums.values(gfx.PassStage).len]u32 = @splat(0),
    visibility: bool = false,
    ambient_occlusion: bool = false,
    unasked: bool = false,
};

fn readingPass(context: ?*anyopaque, pass: gfx.PassContext) anyerror!void {
    const seen: *Seen = @ptrCast(@alignCast(context.?));
    seen.stages[@intFromEnum(pass.stage)] += 1;
    if (pass.stage == .after_opaque) {
        seen.visibility = seen.visibility or pass.visibility != null;
        seen.ambient_occlusion = seen.ambient_occlusion or pass.ambient_occlusion != null;
    } else if (pass.visibility != null or pass.ambient_occlusion != null) seen.unasked = true;
}

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
        .geometry = .{ .mesh_shaders = true },
        .job_allocator = failing.allocator(),
        .cache = .{ .assets = cache_dir },
        .textures = .{ .streaming = .{ .budget_bytes = 4 * 1024 * 1024, .evict_delay_frames = 8, .from_cache = true } },
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
    renderer.scenes.setEnvironment(scene, .{ .environment = try renderer.environments.createSky(sky), .intensity = 1 });
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
        .box = try renderer.entities.create(scene, .{ .model = box, .transform = math.identity }),
    };
    try renderer.waitUntilLoaded();
    try checks.draw(8);
    try checks.picking();
    try checks.staleHandles();
    try checks.staleDrawResources();
    try checks.moves();
    try checks.threads();
    try checks.failedPass();
    try checks.plainViewPasses();
    try checks.scenePassReads();
    try checks.placedLightsAndDecals();
    try checks.lifecycle();
    try checks.switchedOffMemory();
    try checks.switchedOffCosts();
    try checks.mirrored();
    try checks.manyViews();
    try checks.resizing();
    try checks.reloadWhileStreaming();
    try checks.shaderReload();
    try checks.streaming();
    try checks.compaction();
    try checks.sceneApi();
    try checks.outOfMemory(40);
    try checks.outOfGpuMemory(45);
    try renderer.device.waitIdle();
    if (renderer.device.validationErrorCount() != 0) return error.ValidationErrors;
    try withoutFeatures(init.gpa, init.io);
}

/// A second renderer with ray tracing, mesh shaders and shading variants
/// turned off, asked for what needs them: it says so in `capabilities`,
/// turns the settings down, reports each in `Stats.downgraded` and draws.
fn withoutFeatures(gpa: std.mem.Allocator, io: std.Io) !void {
    const renderer = try gfx.Renderer.init(gpa, io, .{
        .application_name = "limn checks, reduced",
        .validation = true,
        .ray_tracing = .{ .hardware = false },
        .geometry = .{ .mesh_shaders = false },
        .shader_variants = false,
    });
    defer renderer.deinit();
    const capabilities = renderer.capabilities();
    if (capabilities.ray_tracing == .available or capabilities.mesh_shaders == .available) return error.TurnedOffFeatureAvailable;
    const target = try renderer.views.createTarget(width, height);
    defer renderer.views.destroyTarget(target);
    const scene = try renderer.scenes.create();
    renderer.scenes.setSun(scene, .{ .direction = .{ -0.5, -0.7, -0.4 }, .color = .{ 1, 1, 1 }, .intensity = 3 });
    const triangle = [_][3]f32{ .{ -1, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 1, 0 } };
    const model = try renderer.models.create(&.{.{ .positions = &triangle, .indices = &.{ 0, 1, 2 } }});
    _ = try renderer.entities.create(scene, .{ .model = model, .transform = math.identity });
    const settings: gfx.Settings = .{ .path_tracing = .{}, .shadows = .{ .traced_lights = true } };
    for (0..4) |_| _ = try renderer.render(.{ .views = &.{.{ .scene = scene, .camera = gfx.Camera.lookAt(.{ 0, 0.5, 3 }, .{ 0, 0.5, 0 }), .target = .{ .texture = target }, .settings = settings }}, .delta_time = 1.0 / 60.0 });
    const downgraded = renderer.stats().downgraded();
    var path_tracing = false;
    for (downgraded) |item| {
        if (std.mem.eql(u8, item.feature, "path_tracing")) path_tracing = true;
    }
    if (!path_tracing) return error.DowngradeNotReported;
    try renderer.device.waitIdle();
    if (renderer.device.validationErrorCount() != 0) return error.ValidationErrors;
    std.log.info("without features: {d} settings turned down and reported, and it drew", .{downgraded.len});
}
