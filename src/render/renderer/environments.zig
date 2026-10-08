//! Environments: loaded panoramas and computed skies, filtered for image-based lighting. Internal to the renderer.
const std = @import("std");
const rhi = @import("../../rhi/rhi.zig");
const math = @import("../../math.zig");
const gpu = @import("../gpu.zig");
const api = @import("../api.zig");
const renderer_state = @import("../state.zig");
const render = @import("../renderer.zig");

const Renderer = render.Renderer;
const Environment = api.Environment;
const AssetState = api.AssetState;
const EnvironmentInfo = api.EnvironmentInfo;
const SkyDesc = api.SkyDesc;
const hdr_format = renderer_state.hdr_format;
const env_cube_size = renderer_state.env_cube_size;
const env_specular_size = renderer_state.env_specular_size;
const env_specular_mips = renderer_state.env_specular_mips;
const env_irradiance_size = renderer_state.env_irradiance_size;
const EnvironmentJob = renderer_state.EnvironmentJob;
const runEnvironmentJob = renderer_state.runEnvironmentJob;
const EnvironmentEntry = renderer_state.EnvironmentEntry;

/// Starts loading an environment: an equirectangular `.hdr`, or a KTX2
/// cube of half floats or BC6H. Radiance is clamped to `max_radiance`.
/// A BC6H cube's `brightest_direction` stays straight up.
pub fn loadEnvironment(self: *Renderer, path: []const u8, max_radiance: f32) !Environment {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const job = try self.gpa.create(EnvironmentJob);
    errdefer self.gpa.destroy(job);
    job.* = .{ .gpa = self.options.job_allocator orelse std.heap.smp_allocator, .io = self.io, .path = try self.gpa.dupe(u8, path) };
    errdefer self.gpa.free(job.path);
    const environment = try self.environments.insert(.{ .job = job, .max_radiance = max_radiance });
    job.group.concurrent(self.io, runEnvironmentJob, .{job}) catch job.group.async(self.io, runEnvironmentJob, .{job});
    self.loading_count += 1;
    return environment;
}

/// Creates an environment from a computed clear sky; ready on return.
pub fn createSky(self: *Renderer, desc: SkyDesc) !Environment {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const environment = try self.environments.insert(.{ .max_radiance = 64, .sky_desc = desc });
    errdefer _ = self.environments.remove(environment);
    const entry = self.environments.get(environment).?;
    errdefer freeEnvironment(self, entry);
    try ensureEnvironmentTextures(self, entry);
    var cmd = try self.device.beginImmediate();
    try bakeSky(self, entry, &cmd, true);
    try self.device.endImmediate();
    entry.state = .ready;
    return environment;
}

/// Changes a `createSky` sky; rebuilt during the next frame (about 1 ms
/// of GPU time).
pub fn setSky(self: *Renderer, environment: Environment, desc: SkyDesc) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const entry = self.environments.get(environment) orelse return;
    if (entry.sky_desc == null) return;
    if (std.meta.eql(entry.sky_desc.?, desc)) return;
    entry.sky_desc = desc;
    entry.sky_dirty = true;
    self.skies_dirty = true;
}

/// Draws a computed sky's cube and filters its lighting: all at once
/// with `whole`, else `rebuild_frames` worth per call, resuming.
pub fn bakeSky(self: *Renderer, entry: *EnvironmentEntry, cmd: *rhi.CommandEncoder, whole: bool) !void {
    const sky = entry.sky.?;
    cmd.beginScope("sky bake");
    defer cmd.endScope();
    if (entry.bake_step == 0) {
        entry.bake_desc = entry.sky_desc.?;
        entry.sky_dirty = false;
    }
    const desc = entry.bake_desc;
    const passes: u32 = if (entry.clouds != null) 2 else 1;
    const stepped = passes == 1;
    const total = if (stepped) 6 + 1 + env_specular_mips else passes * 6;
    const spread = if (whole or entry.clouds != null) 1 else @max(desc.rebuild_frames, 1);
    var budget: u32 = (total + spread - 1) / spread;
    while (entry.bake_step < total and budget > 0) : (budget -= 1) {
        if (stepped and entry.bake_step >= 6) {
            if (entry.bake_step == 6) try filterIrradiance(self, entry, cmd) else try filterSpecularMip(self, entry, cmd, entry.bake_step - 7);
            entry.bake_step += 1;
            continue;
        }
        const pass = entry.bake_step / 6;
        const face = entry.bake_step % 6;
        var clouds = std.mem.zeroes(gpu.Clouds);
        if (pass == 0) if (entry.clouds) |layer| {
            clouds = layer;
            clouds.depth = self.device.samplerIndex(self.sampler_linear_clamp);
        };
        try cmd.beginRendering(.{ .color = &.{.{ .texture = sky, .layer = face, .load = .discard }} });
        cmd.bindPipeline(self.pipelines.env_sky);
        cmd.pushConstants(extern struct { to_sun: [3]f32, face: u32, ground_color: [3]f32, turbidity: f32, intensity: f32, max_radiance: f32, sun_disc: f32, stars: f32, to_moon: [3]f32, moon: f32, ozone: f32, clouds: gpu.Clouds }{
            .to_sun = math.scale(math.normalize(desc.sun_direction), -1),
            .face = @intCast(face),
            .ground_color = desc.ground_color,
            .turbidity = std.math.clamp(desc.turbidity, 1, 10),
            .intensity = desc.intensity,
            .max_radiance = entry.max_radiance,
            .sun_disc = @floatFromInt(@intFromBool(desc.sun_disc)),
            .stars = @max(desc.stars, 0),
            .to_moon = math.scale(math.normalize(desc.moon_direction), -1),
            .moon = @max(desc.moon, 0),
            .ozone = @max(desc.ozone, 0),
            .clouds = clouds,
        });
        cmd.drawFullscreen();
        cmd.endRendering();
        entry.bake_step += 1;
        if (face == 5) {
            cmd.generateMips(sky);
            if (pass == 0 and !stepped) try filterEnvironment(self, entry, cmd);
        }
    }
    if (entry.bake_step >= total) entry.bake_step = 0;
    if (entry.bake_step != 0 or entry.sky_dirty) self.skies_dirty = true;
}

/// A handle that names no environment reports `.failed`. Safe from any
/// thread.
pub fn environmentState(self: *Renderer, environment: Environment) AssetState {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return (self.environments.get(environment) orelse return .failed).state;
}

/// Null until the environment is ready.
pub fn environmentInfo(self: *Renderer, environment: Environment) ?EnvironmentInfo {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const entry = self.environments.get(environment) orelse return null;
    return if (entry.state == .ready) .{ .brightest_direction = entry.brightest_direction } else null;
}

/// Frees an environment, cancelling a load under way. Scenes that have it
/// set draw as if they had none.
pub fn destroyEnvironment(self: *Renderer, environment: Environment) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var removed = self.environments.remove(environment) orelse return;
    if (removed.state == .loading) self.loading_count -= 1;
    freeEnvironment(self, &removed);
}

pub fn finalizeEnvironment(self: *Renderer, entry: *EnvironmentEntry, cmd: *rhi.CommandEncoder) !void {
    const device = self.device;
    const job = entry.job.?;
    job.group.await(job.io) catch {};
    defer {
        if (job.image) |*image| image.deinit();
        if (job.cube) |cube| job.gpa.free(cube.data);
        self.gpa.free(job.path);
        self.gpa.destroy(job);
        entry.job = null;
    }
    if (job.failure) |err| return err;

    var from_cube = false;
    const source = if (job.cube) |cube| blk: {
        from_cube = true;
        if (cube.format == .bc6h and !device.bc_textures) return error.UnsupportedTextureFormat;
        if (job.cube_brightest) |direction| entry.brightest_direction = direction;
        const format: rhi.Format = if (cube.format == .bc6h) .bc6h_ufloat else .rgba16_float;
        const texture = try device.createTexture(.{
            .name = "environment source",
            .width = cube.width,
            .height = cube.height,
            .format = format,
            .usage = .{ .sampled = true, .copy_dst = true },
            .mip_levels = cube.levels,
            .kind = .cube,
        });
        errdefer device.destroyTexture(texture);
        var offset: usize = 0;
        for (0..cube.levels) |level| {
            const size: usize = @intCast(format.dataSize(@max(cube.width >> @intCast(level), 1), @max(cube.height >> @intCast(level), 1)));
            for (0..6) |face| {
                try device.uploadTexture(texture, @intCast(level), @intCast(face), cube.data[offset..][0..size]);
                offset += size;
            }
        }
        break :blk texture;
    } else blk: {
        const image = job.image.?;
        entry.brightest_direction = image.brightest_direction;
        const texture = try device.createTexture(.{
            .name = "equirect",
            .width = image.width,
            .height = image.height,
            .format = .rgba16_float,
            .usage = .{ .sampled = true, .copy_dst = true },
        });
        errdefer device.destroyTexture(texture);
        try device.uploadTexture(texture, 0, 0, image.pixels());
        break :blk texture;
    };
    defer device.destroyTexture(source);
    try cmd.flushUploads();

    try ensureEnvironmentTextures(self, entry);
    const sky = entry.sky.?;

    cmd.beginScope("environment bake");
    for (0..6) |face| try drawEnvironmentFace(self, cmd, entry, sky, source, from_cube, @intCast(face), null);
    cmd.generateMips(sky);

    try filterEnvironment(self, entry, cmd);
    cmd.endScope();
    entry.state = .ready;
}

/// One face of a sky cube from a panorama or another cube, with the
/// cloud layer over it if given.
fn drawEnvironmentFace(self: *Renderer, cmd: *rhi.CommandEncoder, entry: *const EnvironmentEntry, target: rhi.Texture, source: rhi.Texture, from_cube: bool, face: u32, layer: ?gpu.Clouds) !void {
    const device = self.device;
    var clouds = std.mem.zeroes(gpu.Clouds);
    if (layer) |value| {
        clouds = value;
        clouds.depth = device.samplerIndex(self.sampler_linear_clamp);
    }
    try cmd.beginRendering(.{ .color = &.{.{ .texture = target, .layer = face, .load = .discard }} });
    cmd.bindPipeline(self.pipelines.env_cube);
    cmd.pushConstants(extern struct { source: u32, sampler: u32, face: u32, max_radiance: f32, from_cube: u32, to_sun: [3]f32, sunlight: [3]f32, clouds: gpu.Clouds }{
        .source = device.textureIndex(source),
        .sampler = device.samplerIndex(if (from_cube) self.sampler_linear_clamp else self.sampler_linear_repeat),
        .face = face,
        .max_radiance = entry.max_radiance,
        .from_cube = @intFromBool(from_cube),
        .to_sun = entry.cloud_to_sun,
        .sunlight = entry.cloud_sunlight,
        .clouds = clouds,
    });
    cmd.drawFullscreen();
    cmd.endRendering();
}

/// Filters a loaded environment's lighting cubes with the cloud layer
/// over it, then restores the clear backdrop.
pub fn bakeLoadedClouds(self: *Renderer, entry: *EnvironmentEntry, cmd: *rhi.CommandEncoder) !void {
    entry.sky_dirty = false;
    const sky = entry.sky orelse return;
    cmd.beginScope("environment clouds");
    defer cmd.endScope();
    if (entry.clear == null) {
        if (entry.clouds == null) return;
        const clear = try self.device.createTexture(.{
            .name = "environment clear sky",
            .width = env_cube_size,
            .height = env_cube_size,
            .format = hdr_format,
            .usage = .{ .sampled = true, .color_attachment = true },
            .kind = .cube,
        });
        entry.clear = clear;
        for (0..6) |face| try drawEnvironmentFace(self, cmd, entry, clear, sky, true, @intCast(face), null);
        cmd.transition(clear, .shader_read);
    }
    const clear = entry.clear.?;
    if (entry.clouds) |layer| {
        for (0..6) |face| try drawEnvironmentFace(self, cmd, entry, sky, clear, true, @intCast(face), layer);
        cmd.generateMips(sky);
        try filterEnvironment(self, entry, cmd);
    }
    for (0..6) |face| try drawEnvironmentFace(self, cmd, entry, sky, clear, true, @intCast(face), null);
    cmd.generateMips(sky);
    if (entry.clouds == null) try filterEnvironment(self, entry, cmd);
}

/// Creates the three cube maps of an environment if it has none yet.
pub fn ensureEnvironmentTextures(self: *Renderer, entry: *EnvironmentEntry) !void {
    if (entry.sky != null) return;
    const device = self.device;
    const cube_usage = rhi.TextureUsage{ .sampled = true, .color_attachment = true };
    const sky = try device.createTexture(.{
        .name = "environment sky",
        .width = env_cube_size,
        .height = env_cube_size,
        .format = hdr_format,
        .usage = cube_usage,
        .mip_levels = rhi.TextureDesc.fullMipCount(env_cube_size, env_cube_size),
        .kind = .cube,
    });
    entry.sky = sky;
    const specular = try device.createTexture(.{
        .name = "environment specular",
        .width = env_specular_size,
        .height = env_specular_size,
        .format = hdr_format,
        .usage = cube_usage,
        .mip_levels = env_specular_mips,
        .kind = .cube,
    });
    entry.specular = specular;
    const irradiance = try device.createTexture(.{
        .name = "environment irradiance",
        .width = env_irradiance_size,
        .height = env_irradiance_size,
        .format = hdr_format,
        .usage = cube_usage,
        .kind = .cube,
    });
    entry.irradiance = irradiance;
}

/// Derives the diffuse and reflection cubes from the sky cube.
pub fn filterEnvironment(self: *Renderer, entry: *EnvironmentEntry, cmd: *rhi.CommandEncoder) !void {
    try filterIrradiance(self, entry, cmd);
    for (0..env_specular_mips) |mip| try filterSpecularMip(self, entry, cmd, @intCast(mip));
}

/// The diffuse lighting cube, from the sky cube.
fn filterIrradiance(self: *Renderer, entry: *EnvironmentEntry, cmd: *rhi.CommandEncoder) !void {
    const device = self.device;
    const irradiance = entry.irradiance.?;
    for (0..6) |face| {
        try cmd.beginRendering(.{ .color = &.{.{ .texture = irradiance, .layer = @intCast(face), .load = .discard }} });
        cmd.bindPipeline(self.pipelines.env_irradiance);
        cmd.pushConstants(extern struct { source: u32, sampler: u32, face: u32, source_size: f32 }{
            .source = device.textureIndex(entry.sky.?),
            .sampler = device.samplerIndex(self.sampler_linear_clamp),
            .face = @intCast(face),
            .source_size = env_cube_size,
        });
        cmd.drawFullscreen();
        cmd.endRendering();
    }
    cmd.transition(irradiance, .shader_read);
}

/// One roughness level of the reflection cube, from the sky cube.
fn filterSpecularMip(self: *Renderer, entry: *EnvironmentEntry, cmd: *rhi.CommandEncoder, mip: u32) !void {
    const device = self.device;
    const specular = entry.specular.?;
    const roughness = @as(f32, @floatFromInt(mip)) / @as(f32, env_specular_mips - 1);
    for (0..6) |face| {
        try cmd.beginRendering(.{ .color = &.{.{ .texture = specular, .mip = mip, .layer = @intCast(face), .load = .discard }} });
        cmd.bindPipeline(self.pipelines.env_prefilter);
        cmd.pushConstants(extern struct { source: u32, sampler: u32, face: u32, source_size: f32, roughness: f32 }{
            .source = device.textureIndex(entry.sky.?),
            .sampler = device.samplerIndex(self.sampler_linear_clamp),
            .face = @intCast(face),
            .source_size = env_cube_size,
            .roughness = roughness,
        });
        cmd.drawFullscreen();
        cmd.endRendering();
    }
    cmd.transition(specular, .shader_read);
}

pub fn freeEnvironment(self: *Renderer, entry: *EnvironmentEntry) void {
    if (entry.job) |job| {
        job.group.cancel(job.io);
        if (job.image) |*image| image.deinit();
        if (job.cube) |cube| job.gpa.free(cube.data);
        self.gpa.free(job.path);
        self.gpa.destroy(job);
        entry.job = null;
    }
    inline for (.{ "sky", "specular", "irradiance", "clear" }) |name| {
        if (@field(entry, name)) |texture| self.device.destroyTexture(texture);
        @field(entry, name) = null;
    }
}
