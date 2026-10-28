//! Shadows of the sun and of local lights.
const pipelines_module = @import("../renderer/pipelines.zig");
const liquid_push = @import("../shaders/push/liquid.zig");
const render = @import("../renderer.zig");
const ray_scene = @import("../scene/ray_scene.zig");
const scene_pass = @import("../scene_pass.zig");
const geometry_feature = @import("geometry.zig");
const hair_feature = @import("hair.zig");
const hooks = @import("hooks.zig");
const gpu = @import("../gpu.zig");
const rhi = @import("../../rhi/rhi.zig");
const filled = @import("../api.zig").filled;
const std = @import("std");
const math = @import("../../math.zig");
const api = @import("../api.zig");
const features = @import("../core/features.zig");

const local_view_base = render.local_view_base;
const local_shadow_tiles_per_side = render.local_shadow_tiles_per_side;
const Lighting = scene_pass.Lighting;
const LocalShadows = scene_pass.LocalShadows;
const max_local_shadow_views = render.max_local_shadow_views;
const DrawPush = scene_pass.DrawPush;
const SunShadows = scene_pass.SunShadows;
const Mat4 = math.Mat4;
const CascadePlan = scene_pass.CascadePlan;
const ScenePass = scene_pass.ScenePass;
const computeCascades = render.computeCascades;
const Renderer = render.Renderer;
const SceneData = render.SceneData;
const Vec3 = math.Vec3;
const ViewContext = features.ViewContext;

pub const name = "shadows";

pub const Settings = struct {
    /// Distance from the camera covered by the shadow cascades.
    distance: f32 = 60,
    /// Penumbra radius in world units.
    softness: f32 = 0.035,
    /// Number of sun shadow cascades, 1..4.
    cascades: u32 = 4,
    /// Leave out of each sun cascade meshes smaller than this many of its
    /// texels across. 0 draws everything; around 2 is rarely visible.
    small_feature_texels: f32 = 0,
    /// Cull sun shadow casters whose shadow cannot reach anything the camera
    /// sees. Applies to cascades redrawn every frame: all without
    /// `Settings.shadows.cascade_stagger`, only the nearest with it.
    receiver_culling: bool = true,
    /// Refresh the far sun cascades every 2nd, 4th and 8th frame. A cascade
    /// with a moving caster is still redrawn every frame.
    cascade_stagger: bool = false,
    /// Sun shadow filter samples: 4, 8 or 16.
    samples: u32 = 16,
    /// LOD used for local light shadows: `.camera` matches what the camera
    /// sees, `.light` picks by distance from the light. Sun cascades always
    /// follow the camera.
    lod: api.ShadowLod = .camera,
    /// Use a virtual shadow map for the sun: four nested 4096-texel levels out
    /// to `Settings.shadows.distance`, drawn page by page on demand and cached. Cascades
    /// are used where pages are not yet drawn.
    virtual: bool = false,
    /// Reach of screen-space contact shadows for the sun, in world units; 0.2
    /// to 0.5 is typical, 0 is off. Opaque surfaces only.
    contact: f32 = 0,
    /// Transparent surfaces cast shadows as dark as they are opaque.
    transparent: bool = true,
    /// Transparent surfaces tint the sunlight passing through them. Sun shadows
    /// only; needs `Settings.shadows.transparent`.
    colored: bool = false,
    /// Ray trace the shadows of shadow-casting lights that have no shadow map
    /// (directional, rectangle, lights past the tile budget). Needs ray tracing.
    traced_lights: bool = true,
    /// Rays per pixel toward each ray-shadowed light that has a size, 1..15.
    light_rays: u32 = 4,
    /// Accumulate soft light shadows over frames; moving shadows trail by a few
    /// frames. Needs `Settings.resolution.temporal_antialiasing`.
    light_filter: bool = true,
};

pub fn preset(quality: api.Quality) ?Settings {
    return switch (quality) {
        .ultra => .{},
        .high => .{ .light_rays = 2 },
        .medium => .{ .samples = 8, .light_rays = 2 },
        .low => .{ .cascades = 3, .samples = 4, .light_rays = 1 },
    };
}

pub fn resolve(setting: *?Settings, r: *features.Resolve) void {
    const s = &(setting.* orelse return);
    if (s.traced_lights and !r.caps.ray_tracing) {
        s.traced_lights = false;
        r.downgrade("shadows.traced_lights", "on", "off", .no_ray_tracing);
    }
    if (s.traced_lights) r.rays = true;
    if (r.debugging) s.virtual = false;
}

/// Adds the feature's passes to a view of a scene. A path traced view leaves
/// out those whose result the tracer replaces.
/// A view's sun shadow maps, and the cascades they were last drawn for. The
/// maps are in the view's kept targets, freed once shadows stop asking.
pub const View = struct {
    /// This frame's maps; set by `fitMaps`.
    map: ?rhi.Texture = null,
    /// Tint of sunlight passed by see-through casters, per cascade.
    tint: ?rhi.Texture = null,
    colored: bool = false,
    cascade_cache: render.CascadeCache = .{},

    pub fn init(_: *rhi.Device) !View {
        return .{};
    }

    pub fn deinit(_: *View, _: *rhi.Device) void {}
};

/// Finds the maps a view with these shadows draws into in its kept
/// targets; new maps, and a change between plain and colored shadows,
/// redraw every cascade.
pub fn fitMaps(renderer: *Renderer, view_data: *render.ViewData, enabled: bool, colored: bool) !*View {
    const device = renderer.device;
    const own = try features.stateOf(view_data, device, @This());
    const resolution = renderer.options.shadows.resolution;
    const gpa = renderer.internal.gpa;
    const frame = renderer.internal.frame_index;
    const tint: ?rhi.Texture = if (colored) try view_data.kept.single(gpa, device, .{
        .name = "shadow tint",
        .width = @max(resolution / 2, 1),
        .height = @max(resolution / 2, 1),
        .format = .rgba8_unorm,
        .usage = .{ .sampled = true, .color_attachment = true },
        .layers = gpu.cascade_count,
        .kind = .@"2d_array",
    }, frame) else null;
    const map: ?rhi.Texture = if (enabled) try view_data.kept.single(gpa, device, .{
        .name = "shadow cascades",
        .width = resolution,
        .height = resolution,
        .format = .depth32_float,
        .usage = .{ .sampled = true, .depth_attachment = true },
        .layers = gpu.cascade_count,
        .kind = .@"2d_array",
    }, frame) else null;
    if (own.colored != colored or !std.meta.eql(own.map, map) or !std.meta.eql(own.tint, tint)) own.cascade_cache.valid = false;
    own.colored = colored;
    own.map = map;
    own.tint = tint;
    return own;
}

/// `Shared` values this feature's `prepare` sets, and those it reads.
pub const provides = .{ "sun", "local_shadows", "shadow_tlas", "colored_shadows" };
pub const uses = .{"lighting"};

/// Makes the view's sun shadow maps and picks the cascades to redraw, then
/// plans the local light shadows this frame draws.
pub fn prepare(ctx: *ViewContext) !void {
    const p = ctx.scene orelse return;
    const renderer = ctx.renderer;
    const device = ctx.device;
    const settings = p.settings;
    const enabled = p.shared.shadows_enabled;
    const colored = enabled and filled(settings.shadows).colored and filled(settings.shadows).transparent;
    const maps = try fitMaps(renderer, p.view_data, enabled, colored);
    const plan = try updateCascades(renderer, p, enabled);
    const cascades = maps.cascade_cache.cascades;
    const map = if (enabled) maps.map.? else renderer.internal.shadow_map;
    const sun = try ctx.make(SunShadows);
    sun.* = .{ .enabled = enabled, .colored = colored, .map = map, .cascades = cascades, .count = plan.count, .update = plan.update };
    const traced = (if (settings.shadows) |shadows| shadows.traced_lights else false) and ray_scene.ready(p.scene, p.scene_frame);
    const tlas: u64 = if (traced) device.accelerationAddress(p.scene.tlas.?) else 0;
    const local = try ctx.make(LocalShadows);
    local.* = planLocalShadows(renderer, p, p.shared.lighting);
    if (local.draw) try fitLocalAtlas(renderer, local, p.shared.lighting.tile_count);
    p.shared.sun = sun;
    p.shared.local_shadows = local;
    p.shared.shadow_tlas = tlas;
    p.shared.colored_shadows = colored;
    const c = ctx.constants;
    c.shadows.cascade_view_proj = cascades.view_proj;
    c.shadows.cascade_splits = cascades.splits;
    c.shadows.cascade_texel_size = cascades.texel_size;
    c.shadows.shadow_map = device.textureIndex(map);
    c.shadows.shadow_sampler = device.samplerIndex(renderer.internal.sampler_shadow);
    c.shadows.local_shadow_map = device.textureIndex(renderer.internal.local_shadow_map);
    c.shadows.local_shadow_sampler = device.samplerIndex(renderer.internal.sampler_local_shadow);
    c.shadows.tlas_low = @truncate(tlas);
    c.shadows.tlas_high = @truncate(tlas >> 32);
    c.shadows.shadow_color = if (colored) device.textureIndex(maps.tint.?) else gpu.invalid_id;
    c.shadows.contact_depth = if (!p.debugging) device.textureIndex(p.view.depth) else gpu.invalid_id;
    c.shadows.enabled = @intFromBool(enabled);
    c.shadows.colored = @intFromBool(colored);
}

pub fn declare(ctx: *ViewContext) !void {
    const p = ctx.scene orelse return;
    const own = filled(p.settings.shadows);
    ctx.constants.shadows.shadow_softness = own.softness;
    ctx.constants.shadows.shadow_taps = own.samples;
    ctx.constants.shadows.contact_length = @max(own.contact, 0);
    ctx.constants.shadows.light_rays = std.math.clamp(own.light_rays, 1, 15);
    const g = ctx.graph;
    try g.add(.{ .name = "sun shadows", .stage = .shadows, .always = true, .scope = false }, ctx, sunShadows);
    try g.add(.{ .name = "local shadows", .stage = .lighting, .always = true, .scope = false }, ctx, localShadows);
}

fn sunShadows(ctx: *ViewContext) !void {
    const p = ctx.scene.?;
    const c = p.shared;
    if (!c.shadows_enabled) return;
    try drawSunShadows(ctx.renderer, p, c.sun);
    try hooks.sunShadows(ctx, c.sun.map, &c.sun.cascades.view_proj, &c.sun.update);
}

fn localShadows(ctx: *ViewContext) !void {
    const p = ctx.scene.?;
    const c = p.shared;
    if (!c.local_shadows.draw) return;
    try drawLocalShadows(ctx.renderer, p, c.lighting, c.local_shadows);
    const options = ctx.renderer.options.shadows;
    const per_side = std.math.clamp(options.local_tiles_per_side, 1, local_shadow_tiles_per_side);
    const count = c.lighting.tile_count;
    try hooks.lightShadows(ctx, ctx.renderer.internal.local_shadow_map, c.lighting.tile_view_proj[0..count], c.local_shadows.tile_dirty[0..count], options.local_resolution / per_side, per_side);
}

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
/// `Settings.shadows.cascade_stagger` far cascades are redrawn every 2nd, 4th
/// and 8th frame, or early when the camera leaves their coverage or a moving
/// caster reaches them.
pub fn updateCascades(renderer: *Renderer, p: *const ScenePass, shadows_enabled: bool) !CascadePlan {
    const desc = p.desc;
    const settings = p.settings;
    const scene_handle = p.scene_handle;
    const view_data = p.view_data;
    const aspect = p.aspect;
    const view_matrix = p.view_matrix;
    const sun_travel = p.sun_travel;
    const cascade_total = std.math.clamp(filled(settings.shadows).cascades, 1, gpu.cascade_count);
    const ideal = computeCascades(desc.camera, view_matrix, aspect, sun_travel, filled(settings.shadows).distance, renderer.options.shadows.resolution, cascade_total);
    var cascade_update: [gpu.cascade_count]bool = @splat(false);
    {
        const cache = &(try features.stateOf(view_data, renderer.device, @This())).cascade_cache;
        const stale = !cache.valid or cache.count != cascade_total or !std.meta.eql(cache.scene, scene_handle) or cache.shadow_distance != filled(settings.shadows).distance or cache.near != desc.camera.near or !std.meta.eql(cache.orthographic, desc.camera.orthographic) or
            math.length(math.sub(cache.sun, sun_travel)) > 1e-6;
        for (0..gpu.cascade_count) |cascade| {
            if (cascade >= cascade_total) continue;
            const interval = @as(u64, 1) << @intCast(cascade);
            const due = !filled(settings.shadows).cascade_stagger or view_data.frames % interval == interval / 2;
            const uncovered = math.length(math.sub(ideal.centers[cascade], cache.cascades.centers[cascade])) + ideal.tight_radii[cascade] >
                cache.cascades.radii[cascade];
            const caster_moved = hooks.movingCasters(&p.desc, .sun_shadow) or moverCastsInto(p.scene, cache.cascades.centers[cascade], cache.cascades.radii[cascade], sun_travel);
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
            cache.shadow_distance = filled(settings.shadows).distance;
            cache.near = desc.camera.near;
            cache.orthographic = desc.camera.orthographic;
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
    const frame_address = p.frame_address;
    const colored_shadows = sun.colored;
    const shadow_map = sun.map;
    const cascades = sun.cascades;
    const cascade_update = sun.update;
    cmd.beginScope("shadows");
    for (0..gpu.cascade_count) |cascade| {
        if (!cascade_update[cascade]) continue;
        try cmd.beginRendering(.{ .depth = .{ .texture = shadow_map, .layer = @intCast(cascade), .clear = 1 } });
        cmd.bindIndexBuffer(renderer.internal.indices.get(), 0, .uint32);
        const cascade_push = DrawPush{ .frame = frame_address, .tinted = @intFromBool(colored_shadows), .view_proj = cascades.view_proj[cascade] };
        cmd.bindPipeline(try renderer.internal.pipelines.of(pipelines_module.shadowPipeline));
        geometry_feature.drawMeshlets(renderer, cmd, cascade_push, 1 + cascade, 0, scene.ref_count);
        cmd.bindPipeline(try renderer.internal.pipelines.of(pipelines_module.shadowMaskedPipeline));
        geometry_feature.drawMeshlets(renderer, cmd, cascade_push, 1 + cascade, 1, scene.ref_count);
        try hair_feature.drawHairShadows(renderer, p, cascades.view_proj[cascade], cascades.texel_size[cascade], 0);
        for (scene.liquids.items) |item| {
            const state = renderer.liquids.internal.table.get(item) orelse continue;
            if (state.params_frame != renderer.internal.frame_index or state.live == 0 or state.desc.shadow <= 0) continue;
            cmd.bindPipeline(try renderer.internal.pipelines.of(liquidShadowPipeline));
            cmd.pushConstants(liquid_push.ShadowPush{
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
        const tint = (try features.stateOf(p.view_data, renderer.device, @This())).tint.?;
        for (0..gpu.cascade_count) |cascade| {
            if (!cascade_update[cascade]) continue;
            try cmd.beginRendering(.{ .color = &.{.{ .texture = tint, .layer = @intCast(cascade), .load = .clear, .clear = .{ 1, 1, 1, 1 } }} });
            cmd.bindIndexBuffer(renderer.internal.indices.get(), 0, .uint32);
            cmd.bindPipeline(try renderer.internal.pipelines.of(shadowColorPipeline));
            geometry_feature.drawMeshlets(renderer, cmd, .{ .frame = frame_address, .view_proj = cascades.view_proj[cascade] }, 1 + cascade, 1, scene.ref_count);
            cmd.endRendering();
        }
        cmd.transition(tint, .shader_read);
    }
    cmd.endScope();
}

/// Makes the local shadow atlas full size the first time a light draws into
/// it; until then it is a single texel. A new atlas is drawn whole.
fn fitLocalAtlas(renderer: *Renderer, local: *LocalShadows, tile_count: u32) !void {
    const device = renderer.device;
    const size = renderer.options.shadows.local_resolution;
    if (device.textureInfo(renderer.internal.local_shadow_map).width == size) return;
    const atlas = try device.createTexture(.{
        .name = "local shadow atlas",
        .width = size,
        .height = size,
        .format = .depth32_float,
        .usage = .{ .sampled = true, .depth_attachment = true },
    });
    device.destroyTexture(renderer.internal.local_shadow_map);
    renderer.internal.local_shadow_map = atlas;
    local.same_atlas = false;
    @memset(local.tile_dirty[0..tile_count], true);
}

/// Picks the local shadow atlas tiles to redraw for this view.
pub fn planLocalShadows(renderer: *Renderer, p: *const ScenePass, lighting: *const Lighting) LocalShadows {
    const scene_handle = p.scene_handle;
    const scene = p.scene;
    const scene_frame = p.scene_frame;
    const local_shadows_current = renderer.internal.local_shadow_frame == renderer.internal.frame_index and
        renderer.internal.local_shadow_scene != null and std.meta.eql(renderer.internal.local_shadow_scene.?, scene_handle);
    var shadow_key_hasher = std.hash.Wyhash.init(lighting.tiles_key);
    shadow_key_hasher.update(std.mem.asBytes(&scene.lights_version));
    shadow_key_hasher.update(std.mem.asBytes(&scene.layout_version));
    shadow_key_hasher.update(std.mem.asBytes(&scene.static_version));
    const shadow_key = shadow_key_hasher.final() | 1;
    const same_atlas = renderer.internal.local_shadow_key == shadow_key and
        renderer.internal.local_shadow_scene != null and std.meta.eql(renderer.internal.local_shadow_scene.?, scene_handle);
    var tile_dirty: [max_local_shadow_views]bool = @splat(true);
    var any_tile_dirty = lighting.tile_count != 0;
    if (same_atlas and !local_shadows_current) {
        any_tile_dirty = false;
        for (0..lighting.tile_count) |tile| {
            var reached = scene.movers_overflow or hooks.movingCasters(&p.desc, .light_shadow);
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
            tile_dirty[tile] = reached or renderer.internal.local_tile_had_mover[tile];
            renderer.internal.local_tile_had_mover[tile] = reached;
            any_tile_dirty = any_tile_dirty or tile_dirty[tile];
        }
    } else if (!local_shadows_current) {
        for (0..lighting.tile_count) |tile| renderer.internal.local_tile_had_mover[tile] = scene_frame.any_moving;
    }
    const draw_local_shadows = any_tile_dirty and scene.ref_count != 0 and !local_shadows_current;
    if (draw_local_shadows) {
        renderer.internal.local_shadow_scene = scene_handle;
        renderer.internal.local_shadow_frame = renderer.internal.frame_index;
        renderer.internal.local_shadow_key = shadow_key;
    }
    return .{ .draw = draw_local_shadows, .same_atlas = same_atlas, .key = shadow_key, .tile_dirty = tile_dirty };
}

/// Draws the changed tiles of the local shadow atlas.
pub fn drawLocalShadows(renderer: *Renderer, p: *const ScenePass, lighting: *const Lighting, local: *const LocalShadows) !void {
    const cmd = p.cmd;
    const scene = p.scene;
    const frame_address = p.frame_address;
    const same_atlas = local.same_atlas;
    const tile_dirty = local.tile_dirty;
    cmd.beginScope("local shadows");
    try cmd.beginRendering(.{ .depth = .{ .texture = renderer.internal.local_shadow_map, .load = if (same_atlas) .load else .clear, .clear = 0 } });
    cmd.bindIndexBuffer(renderer.internal.indices.get(), 0, .uint32);
    const tiles_per_side = std.math.clamp(renderer.options.shadows.local_tiles_per_side, 1, local_shadow_tiles_per_side);
    const tile_size = renderer.options.shadows.local_resolution / tiles_per_side;
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
        cmd.bindPipeline(try renderer.internal.pipelines.of(localShadowPipeline));
        geometry_feature.drawMeshlets(renderer, cmd, tile_push, view_index, 0, scene.ref_count);
        cmd.bindPipeline(try renderer.internal.pipelines.of(localShadowMaskedPipeline));
        geometry_feature.drawMeshlets(renderer, cmd, tile_push, view_index, 1, scene.ref_count);
    }
    cmd.endRendering();
    cmd.endScope();
}

fn localShadowPipeline(device: *rhi.Device) pipelines_module.Desc {
    return .{ .graphics = .{
        .name = "local shadow",
        .vertex = pipelines_module.visibilityVertex(device),
        .mesh = if (device.caps.mesh_shaders) pipelines_module.shaderCode("visibility.mesh.spv") else null,
        .task = if (device.caps.mesh_shaders) pipelines_module.shaderCode("visibility.task.spv") else null,
        .depth = pipelines_module.local_shadow_depth,
        .cull = .back,
    } };
}

fn localShadowMaskedPipeline(device: *rhi.Device) pipelines_module.Desc {
    return .{ .graphics = .{
        .name = "local shadow masked",
        .vertex = pipelines_module.visibilityVertex(device),
        .mesh = if (device.caps.mesh_shaders) pipelines_module.shaderCode("visibility.mesh.spv") else null,
        .task = if (device.caps.mesh_shaders) pipelines_module.shaderCode("visibility.task.spv") else null,
        .fragment = pipelines_module.shaderCode("shadow_masked.frag.spv"),
        .depth = pipelines_module.local_shadow_depth,
        .cull = .none,
    } };
}

fn shadowColorPipeline(device: *rhi.Device) pipelines_module.Desc {
    return .{ .graphics = .{
        .name = "shadow tint",
        .vertex = pipelines_module.visibilityVertex(device),
        .mesh = if (device.caps.mesh_shaders) pipelines_module.shaderCode("visibility.mesh.spv") else null,
        .task = if (device.caps.mesh_shaders) pipelines_module.shaderCode("visibility.task.spv") else null,
        .fragment = pipelines_module.shaderCode("shadow_color.frag.spv"),
        .color_targets = &.{.{ .format = .rgba8_unorm, .blend = .tint }},
        .cull = .none,
    } };
}

fn liquidShadowPipeline(_: *rhi.Device) pipelines_module.Desc {
    return .{ .graphics = .{
        .name = "liquid shadow",
        .vertex = pipelines_module.shaderCode("liquid_shadow.vert.spv"),
        .fragment = pipelines_module.shaderCode("liquid_shadow.frag.spv"),
        .depth = pipelines_module.shadow_depth,
        .cull = .none,
    } };
}
