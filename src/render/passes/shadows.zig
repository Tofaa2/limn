//! Shadow maps of a view: sun cascades and the local lights' atlas. Internal to
//! the renderer.
const std = @import("std");
const math = @import("../../math.zig");
const gpu = @import("../gpu.zig");
const hair_passes = @import("hair.zig");
const render = @import("../renderer.zig");
const scene_pass = @import("../scene_pass.zig");
const geometry_passes = @import("geometry.zig");

const Mat4 = math.Mat4;
const Vec3 = math.Vec3;
const Renderer = render.Renderer;
const SceneData = render.SceneData;
const computeCascades = render.computeCascades;
const local_shadow_tiles_per_side = render.local_shadow_tiles_per_side;
const local_view_base = render.local_view_base;
const max_local_shadow_views = render.max_local_shadow_views;
const ScenePass = scene_pass.ScenePass;
const SunShadows = scene_pass.SunShadows;
const CascadePlan = scene_pass.CascadePlan;
const LocalShadows = scene_pass.LocalShadows;
const DrawPush = scene_pass.DrawPush;
const Lighting = scene_pass.Lighting;

/// Whether anything that moved this frame casts into a cascade's bounding
/// sphere. Only the distance across the light direction counts.
fn moverCastsInto(scene: *const SceneData, center: Vec3, radius: f32, sun_travel: Vec3) bool {
    if (scene.movers_overflow) return true;
    for (scene.movers.items) |mover| {
        const offset = math.sub(mover[0..3].*, center);
        const across = math.sub(offset, math.scale(sun_travel, math.dot(offset, sun_travel)));
        if (math.length(across) < radius + mover[3]) return true;
    }
    return false;
}

/// Picks the cascades to redraw this frame. With
/// `Settings.shadow_cascade_stagger` far cascades are redrawn every 2nd, 4th
/// and 8th frame, or early when the camera leaves their coverage or a moving
/// caster reaches them.
pub fn updateCascades(renderer: *Renderer, p: *const ScenePass, shadows_enabled: bool) CascadePlan {
    const desc = p.desc;
    const settings = p.settings;
    const scene_handle = p.scene_handle;
    const view_data = p.view_data;
    const aspect = p.aspect;
    const view_matrix = p.view_matrix;
    const sun_travel = p.sun_travel;
    const cascade_total = std.math.clamp(settings.shadow_cascades, 1, gpu.cascade_count);
    const ideal = computeCascades(desc.camera, view_matrix, aspect, sun_travel, settings.shadow_distance, renderer.options.shadow_resolution, cascade_total);
    var cascade_update: [gpu.cascade_count]bool = @splat(false);
    {
        const cache = &view_data.cascade_cache;
        const stale = !cache.valid or cache.count != cascade_total or !std.meta.eql(cache.scene, scene_handle) or cache.shadow_distance != settings.shadow_distance or cache.near != desc.camera.near or
            math.length(math.sub(cache.sun, sun_travel)) > 1e-6;
        for (0..gpu.cascade_count) |cascade| {
            if (cascade >= cascade_total) continue;
            const interval = @as(u64, 1) << @intCast(cascade);
            const due = !settings.shadow_cascade_stagger or view_data.frames % interval == interval / 2;
            const uncovered = math.length(math.sub(ideal.centers[cascade], cache.cascades.centers[cascade])) + ideal.tight_radii[cascade] >
                cache.cascades.radii[cascade];
            const caster_moved = moverCastsInto(p.scene, cache.cascades.centers[cascade], cache.cascades.radii[cascade], sun_travel);
            if (!shadows_enabled or !(stale or due or uncovered or caster_moved)) continue;
            cascade_update[cascade] = true;
            cache.cascades.view_proj[cascade] = ideal.view_proj[cascade];
            cache.cascades.texel_size[cascade] = ideal.texel_size[cascade];
            cache.cascades.centers[cascade] = ideal.centers[cascade];
            cache.cascades.radii[cascade] = ideal.radii[cascade];
        }
        if (shadows_enabled) {
            cache.valid = true;
            cache.scene = scene_handle;
            cache.count = cascade_total;
            cache.sun = sun_travel;
            cache.shadow_distance = settings.shadow_distance;
            cache.near = desc.camera.near;
            cache.cascades.splits = ideal.splits;
        }
    }
    return .{ .count = cascade_total, .update = cascade_update };
}

/// Draws the sun cascades that are due and, with colored shadows, their tint.
pub fn drawSunShadows(renderer: *Renderer, p: *const ScenePass, sun: *const SunShadows) !void {
    const device = renderer.device;
    const cmd = p.cmd;
    const scene = p.scene;
    const view_data = p.view_data;
    const frame_address = p.frame_address;
    const colored_shadows = sun.colored;
    const shadow_map = sun.map;
    const cascades = sun.cascades;
    const cascade_update = sun.update;
    cmd.beginScope("shadows");
    for (0..gpu.cascade_count) |cascade| {
        if (!cascade_update[cascade]) continue;
        try cmd.beginRendering(.{ .depth = .{ .texture = shadow_map, .layer = @intCast(cascade), .clear = 1 } });
        cmd.bindIndexBuffer(renderer.indices.buffer, 0, .uint32);
        const cascade_push = DrawPush{ .frame = frame_address, .tinted = @intFromBool(colored_shadows), .view_proj = cascades.view_proj[cascade] };
        cmd.bindPipeline(renderer.pipelines.shadow);
        geometry_passes.drawMeshlets(renderer, cmd, cascade_push, 1 + cascade, 0, scene.ref_count);
        cmd.bindPipeline(renderer.pipelines.shadow_masked);
        geometry_passes.drawMeshlets(renderer, cmd, cascade_push, 1 + cascade, 1, scene.ref_count);
        hair_passes.drawHairShadows(renderer, p, cascades.view_proj[cascade], cascades.texel_size[cascade], 0);
        for (scene.liquids.items) |item| {
            const state = renderer.liquids.get(item) orelse continue;
            if (state.params_frame != renderer.frame_index or state.live == 0 or state.desc.shadow <= 0) continue;
            cmd.bindPipeline(renderer.pipelines.liquid_shadow);
            cmd.pushConstants(extern struct { frame: u64, liquid: u64, particles: u64, view_proj: Mat4, swell: f32, strength: f32 }{
                .frame = frame_address,
                .liquid = state.params,
                .particles = device.bufferAddress(state.particles),
                .view_proj = cascades.view_proj[cascade],
                .swell = 1.4,
                .strength = std.math.clamp(state.desc.shadow, 0, 1),
            });
            cmd.draw(state.live * 6, 1, 0, 0);
        }
        cmd.endRendering();
    }
    cmd.transition(shadow_map, .shader_read);
    if (colored_shadows) {
        const tint = view_data.shadow_color.?;
        for (0..gpu.cascade_count) |cascade| {
            if (!cascade_update[cascade]) continue;
            try cmd.beginRendering(.{ .color = &.{.{ .texture = tint, .layer = @intCast(cascade), .load = .clear, .clear = .{ 1, 1, 1, 1 } }} });
            cmd.bindIndexBuffer(renderer.indices.buffer, 0, .uint32);
            cmd.bindPipeline(renderer.pipelines.shadow_color);
            geometry_passes.drawMeshlets(renderer, cmd, .{ .frame = frame_address, .view_proj = cascades.view_proj[cascade] }, 1 + cascade, 1, scene.ref_count);
            cmd.endRendering();
        }
        cmd.transition(tint, .shader_read);
    }
    cmd.endScope();
}

/// Picks the local shadow atlas tiles to redraw for this view.
pub fn planLocalShadows(renderer: *Renderer, p: *const ScenePass, lighting: *const Lighting) LocalShadows {
    const scene_handle = p.scene_handle;
    const scene = p.scene;
    const scene_frame = p.scene_frame;
    const local_shadows_current = renderer.local_shadow_frame == renderer.frame_index and
        renderer.local_shadow_scene != null and std.meta.eql(renderer.local_shadow_scene.?, scene_handle);
    var shadow_key_hasher = std.hash.Wyhash.init(lighting.tiles_key);
    shadow_key_hasher.update(std.mem.asBytes(&scene.lights_version));
    shadow_key_hasher.update(std.mem.asBytes(&scene.layout_version));
    shadow_key_hasher.update(std.mem.asBytes(&scene.static_version));
    const shadow_key = shadow_key_hasher.final() | 1;
    const same_atlas = renderer.local_shadow_key == shadow_key and
        renderer.local_shadow_scene != null and std.meta.eql(renderer.local_shadow_scene.?, scene_handle);
    // A tile is redrawn only if a mover is in its light's view now or was when
    // last drawn.
    var tile_dirty: [max_local_shadow_views]bool = @splat(true);
    var any_tile_dirty = lighting.tile_count != 0;
    if (same_atlas and !local_shadows_current) {
        any_tile_dirty = false;
        for (0..lighting.tile_count) |tile| {
            var reached = scene.movers_overflow;
            if (!reached) for (scene.movers.items) |mover| {
                const cull = lighting.tile_views[tile];
                var inside = true;
                for (cull.planes[0..cull.plane_count]) |plane| {
                    if (plane[0] * mover[0] + plane[1] * mover[1] + plane[2] * mover[2] + plane[3] < -mover[3]) {
                        inside = false;
                        break;
                    }
                }
                if (inside) {
                    reached = true;
                    break;
                }
            };
            tile_dirty[tile] = reached or renderer.local_tile_had_mover[tile];
            renderer.local_tile_had_mover[tile] = reached;
            any_tile_dirty = any_tile_dirty or tile_dirty[tile];
        }
    } else if (!local_shadows_current) {
        for (0..lighting.tile_count) |tile| renderer.local_tile_had_mover[tile] = scene_frame.any_moving;
    }
    const draw_local_shadows = any_tile_dirty and scene.ref_count != 0 and !local_shadows_current;
    return .{ .draw = draw_local_shadows, .same_atlas = same_atlas, .key = shadow_key, .tile_dirty = tile_dirty };
}

/// Draws the changed tiles of the local shadow atlas.
pub fn drawLocalShadows(renderer: *Renderer, p: *const ScenePass, lighting: *const Lighting, local: *const LocalShadows) !void {
    const cmd = p.cmd;
    const scene_handle = p.scene_handle;
    const scene = p.scene;
    const frame_address = p.frame_address;
    const same_atlas = local.same_atlas;
    const shadow_key = local.key;
    const tile_dirty = local.tile_dirty;
    renderer.local_shadow_scene = scene_handle;
    renderer.local_shadow_frame = renderer.frame_index;
    renderer.local_shadow_key = shadow_key;
    cmd.beginScope("local shadows");
    try cmd.beginRendering(.{ .depth = .{ .texture = renderer.local_shadow_map, .load = if (same_atlas) .load else .clear, .clear = 0 } });
    cmd.bindIndexBuffer(renderer.indices.buffer, 0, .uint32);
    const tiles_per_side = std.math.clamp(renderer.options.local_shadow_tiles_per_side, 1, local_shadow_tiles_per_side);
    const tile_size = renderer.options.local_shadow_resolution / tiles_per_side;
    for (0..lighting.tile_count) |tile| {
        if (!tile_dirty[tile]) continue;
        const view_index = local_view_base + tile;
        cmd.setViewport(
            @intCast(tile % tiles_per_side * tile_size),
            @intCast(tile / tiles_per_side * tile_size),
            tile_size,
            tile_size,
        );
        if (same_atlas) cmd.clearDepthRect(@intCast(tile % tiles_per_side * tile_size), @intCast(tile / tiles_per_side * tile_size), tile_size, tile_size, 0);
        const tile_push = DrawPush{ .frame = frame_address, .view_proj = lighting.tile_view_proj[tile] };
        cmd.bindPipeline(renderer.pipelines.local_shadow);
        geometry_passes.drawMeshlets(renderer, cmd, tile_push, view_index, 0, scene.ref_count);
        cmd.bindPipeline(renderer.pipelines.local_shadow_masked);
        geometry_passes.drawMeshlets(renderer, cmd, tile_push, view_index, 1, scene.ref_count);
    }
    cmd.endRendering();
    cmd.transition(renderer.local_shadow_map, .shader_read);
    cmd.endScope();
}
