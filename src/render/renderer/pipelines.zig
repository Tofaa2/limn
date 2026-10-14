//! Pipelines and the shader code they are built from. Internal to the renderer.
const std = @import("std");
const rhi = @import("../../rhi/rhi.zig");
const shader_sources = @import("shader_sources");
const renderer_state = @import("../state.zig");
const render = @import("../renderer.zig");

const Renderer = render.Renderer;
const hdr_format = renderer_state.hdr_format;
const bloom_format = renderer_state.bloom_format;
const PipelineSet = @import("../core/pipeline_set.zig").PipelineSet;
const spirv_readonly = @import("../core/spirv_readonly.zig");
const shade_plain_targets = renderer_state.shade_plain_targets;
const shade_reflective_targets = renderer_state.shade_reflective_targets;

/// `compiled` with what it only reads marked as such, as the build does
/// after slangc. Takes ownership of `compiled`.
fn markedSpirv(gpa: std.mem.Allocator, compiled: []u8) ![]u8 {
    defer gpa.free(compiled);
    if (compiled.len == 0 or compiled.len % 4 != 0) return gpa.dupe(u8, compiled);
    const words = try gpa.alloc(u32, compiled.len / 4);
    defer gpa.free(words);
    @memcpy(std.mem.sliceAsBytes(words), compiled);
    const marked = try spirv_readonly.markReadOnly(gpa, words);
    defer gpa.free(marked);
    return gpa.dupe(u8, std.mem.sliceAsBytes(marked));
}

/// The built-in shaders.
pub const Shaders = struct {
    fn renderer(shaders: *Shaders) *Renderer {
        return @alignCast(@fieldParentPtr("shaders", shaders));
    }

    /// Recompiles the built-in shaders from source with `slangc` and rebuilds
    /// every pipeline. On a compile error nothing changes. Returns the number
    /// of shaders compiled. `error.ShaderReloadDisabled` unless built with
    /// `-Dshader_reload`, which Debug builds are.
    pub fn reload(shaders: *Shaders) !u32 {
        if (!shader_sources.reload) return error.ShaderReloadDisabled;
        const self = shaders.renderer();
        self.lock();
        defer self.unlock();
        const gpa = self.gpa;
        const device = self.device;
        var compiled: std.ArrayList([]u8) = .empty;
        defer {
            for (compiled.items) |code| gpa.free(code);
            compiled.deinit(gpa);
        }
        const include = try std.fmt.allocPrint(gpa, "-I{s}", .{shader_sources.include_dir});
        defer gpa.free(include);
        const generated = try std.fmt.allocPrint(gpa, "-I{s}", .{shader_sources.generated_dir});
        defer gpa.free(generated);
        for (shader_sources.sources, shader_sources.defines, shader_sources.names, shader_sources.entries, shader_sources.stages, shader_sources.read_only) |source, defines, name, entry, stage, read_only| {
            var argv: [32][]const u8 = undefined;
            var count: usize = 0;
            for ([_][]const u8{ "slangc", include, generated, "-stage", stage, "-entry", entry }) |arg| {
                argv[count] = arg;
                count += 1;
            }
            for (shader_sources.slang_arguments) |arg| {
                argv[count] = arg;
                count += 1;
            }
            var define_args = std.mem.tokenizeScalar(u8, defines, ' ');
            while (define_args.next()) |arg| {
                argv[count] = arg;
                count += 1;
            }
            const written = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ shader_sources.generated_dir, name });
            defer gpa.free(written);
            for ([_][]const u8{ source, "-o", written }) |arg| {
                argv[count] = arg;
                count += 1;
            }
            const result = try std.process.run(gpa, self.io, .{ .argv = argv[0..count] });
            defer gpa.free(result.stderr);
            defer gpa.free(result.stdout);
            const ok = switch (result.term) {
                .exited => |code| code == 0,
                else => false,
            };
            const code: []u8 = if (!ok)
                &.{}
            else if (read_only)
                try markedSpirv(gpa, std.Io.Dir.cwd().readFileAlloc(self.io, written, gpa, .unlimited) catch &.{})
            else
                std.Io.Dir.cwd().readFileAlloc(self.io, written, gpa, .unlimited) catch &.{};
            std.Io.Dir.cwd().deleteFile(self.io, written) catch {};
            if (code.len == 0 or code.len % 4 != 0) {
                std.log.err("shader {s} did not compile:\n{s}", .{ name, result.stderr });
                gpa.free(code);
                return error.ShaderCompileFailed;
            }
            errdefer gpa.free(code);
            try compiled.append(gpa, code);
        }

        dropShadeVariants(self);
        for (shader_sources.names, compiled.items) |name, code| try overrideShader(name, code);
        try device.waitIdle();
        self.pipelines.reset();
        for (self.tonemap_pipelines.items) |entry| device.destroyPipeline(entry.pipeline);
        self.tonemap_pipelines.clearRetainingCapacity();
        for (self.edge_pipelines.items) |entry| device.destroyPipeline(entry.pipeline);
        self.edge_pipelines.clearRetainingCapacity();
        self.canvas.resetPipelines(device);
        return @intCast(shader_sources.names.len);
    }

    /// Blocks until background shading variant compiles are done. For tools,
    /// tests and benchmarks.
    pub fn waitForVariants(shaders: *Shaders) !void {
        const self = shaders.renderer();
        while (true) {
            {
                self.lock();
                defer self.unlock();
                var pending = false;
                for (self.shade_variants.items) |variant| {
                    if (variant.job) |job| if (!job.done.load(.acquire)) {
                        pending = true;
                    };
                }
                if (!pending) return;
            }
            try self.io.sleep(std.Io.Duration.fromMilliseconds(1), .awake);
        }
    }
};

/// Waits for shading variants being compiled and frees them all. Must
/// run before the shader code they are built from goes away.
pub fn dropShadeVariants(self: *Renderer) void {
    for (self.shade_variants.items) |*variant| {
        if (variant.job) |job| {
            job.group.cancel(job.io);
            if (job.compiled) |compiled| self.device.discardPipeline(compiled);
            self.gpa.destroy(job);
        }
        if (variant.pipeline) |pipeline| self.device.destroyPipeline(pipeline);
    }
    self.shade_variants.clearRetainingCapacity();
}

/// The built-in pipelines; see `Pipelines`.
pub const PipelineId = enum {
    skin,
    skin_bounds,
    instance_moves,
    instance_rewrites,
    cull,
    cull_instances,
    cluster,
    local_shadow,
    local_shadow_masked,
    forward,
    forward_weighted,
    oit_composite,
    forward_peel,
    peel_under,
    peel_composite,
    copy,
    upscale,
    shading_rate,
    fsr_easu,
    fsr_rcas,
    hiz,
    hiz_compute,
    visibility,
    visibility_masked,
    shadow,
    shadow_masked,
    shadow_color,
    gtao,
    gtao_bounce_denoise,
    ao_depth,
    gi_gather,
    gtao_denoise,
    shade,
    shade_reflective,
    ssr,
    ssr_traced,
    ssr_composite,
    cloud_noise,
    cloud,
    cloud_composite,
    fluid_advect,
    fluid_curl,
    fluid_force,
    fluid_divergence,
    fluid_pressure,
    fluid_project,
    fluid_present,
    water_sim,
    water,
    underwater,
    liquid_sim,
    path_trace,
    path_trace_compute,
    path_gather,
    nrd_pack,
    nrd_compose,
    path_denoise,
    path_denoise_final,
    reflection_reproject,
    reflection_average,
    reflection_prefilter,
    reflection_resolve,
    liquid_surface,
    liquid_shadow,
    liquid_depth,
    liquid_thickness,
    liquid_blur,
    liquid,
    water_depth,
    fluid_solid,
    fluid_solid_traced,
    fluid_carry,
    fluid,
    fluid_motion,
    dof,
    dof_composite,
    motion_blur,
    fog,
    fog_composite,
    taa,
    bloom_down,
    bloom_up,
    exposure,
    pick,
    particle_sim,
    fluid_light,
    particle_sort_keys,
    particle_sort,
    particles,
    particle_trails,
    impostor,
    impostor_bake,
    lightmap_bake,
    vsm_mark,
    vsm_allocate,
    vsm_clear,
    lightmap_dilate,
    hair_simulation,
    hair_shadow,
    hair,
    particle_mesh,
    probe_face,
    env_cube,
    env_sky,
    env_irradiance,
    env_prefilter,
    brdf_lut,
    gi_trace,
    gi_irradiance,
    gi_clamp_upper,
    gi_relocate,
    gi_clamp_lower,
    gi_visibility,
};

/// Every built-in pipeline, each built on first use.
pub const Pipelines = PipelineSet(PipelineId, makePipeline);

fn makePipeline(device: *rhi.Device, id: PipelineId) anyerror!rhi.Pipeline {
    const Local = struct {
        fn pass(d: *rhi.Device, name: [:0]const u8, fragment: []const u8, targets: []const rhi.ColorTarget) !rhi.Pipeline {
            return d.createGraphicsPipeline(.{
                .name = name,
                .vertex = shaderCode("fullscreen.vert.spv"),
                .fragment = fragment,
                .color_targets = targets,
                .cull = .none,
            });
        }
    };
    const local_shadow_depth = rhi.DepthState{
        .compare = .greater_or_equal,
        .bias = .{ .constant = -1.5, .slope = -2.0 },
    };
    const shadow_depth = rhi.DepthState{
        .compare = .less_or_equal,
        .bias = .{ .constant = 1.5, .slope = 2.0 },
        .clamp = true,
    };
    return switch (id) {
        .skin => device.createComputePipeline(.{ .name = "skin", .shader = shaderCode("skin.comp.spv") }),
        .skin_bounds => device.createComputePipeline(.{ .name = "skin bounds", .shader = shaderCode("skin_bounds.comp.spv") }),
        .instance_moves => device.createComputePipeline(.{ .name = "instance moves", .shader = shaderCode("instance_moves.comp.spv") }),
        .instance_rewrites => device.createComputePipeline(.{ .name = "instance rewrites", .shader = shaderCode("instance_rewrites.comp.spv") }),
        .cull => device.createComputePipeline(.{ .name = "cull", .shader = shaderCode("cull.comp.spv") }),
        .cull_instances => device.createComputePipeline(.{ .name = "cull instances", .shader = shaderCode("cull_instances.comp.spv") }),
        .cluster => device.createComputePipeline(.{ .name = "light clusters", .shader = shaderCode("cluster.comp.spv") }),
        .local_shadow => device.createGraphicsPipeline(.{
            .name = "local shadow",
            .vertex = shaderCode("visibility.vert.spv"),
            .mesh = if (device.caps.mesh_shaders) shaderCode("visibility.mesh.spv") else null,
            .task = if (device.caps.mesh_shaders) shaderCode("visibility.task.spv") else null,
            .depth = local_shadow_depth,
            .cull = .back,
        }),
        .local_shadow_masked => device.createGraphicsPipeline(.{
            .name = "local shadow masked",
            .vertex = shaderCode("visibility.vert.spv"),
            .mesh = if (device.caps.mesh_shaders) shaderCode("visibility.mesh.spv") else null,
            .task = if (device.caps.mesh_shaders) shaderCode("visibility.task.spv") else null,
            .fragment = shaderCode("shadow_masked.frag.spv"),
            .depth = local_shadow_depth,
            .cull = .none,
        }),
        .forward => device.createGraphicsPipeline(.{
            .name = "forward transparent",
            .vertex = shaderCode("forward.vert.spv"),
            .fragment = shaderCode("forward.frag.spv"),
            .color_targets = &.{ .{ .format = hdr_format, .blend = .premultiplied }, .{ .format = .rg16_float, .blend = .alpha } },
            .depth = .{ .write = false, .compare = .greater_or_equal },
            .cull = .none,
        }),
        .forward_weighted => device.createGraphicsPipeline(.{
            .name = "forward transparent (weighted)",
            .vertex = shaderCode("forward.vert.spv"),
            .fragment = shaderCode("forward_weighted.frag.spv"),
            .color_targets = &.{ .{ .format = hdr_format, .blend = .additive }, .{ .format = .rg16_float, .blend = .alpha }, .{ .format = .r8_unorm, .blend = .revealage } },
            .depth = .{ .write = false, .compare = .greater_or_equal },
            .cull = .none,
        }),
        .oit_composite => Local.pass(device, "transparency composite", shaderCode("oit_composite.frag.spv"), &.{.{ .format = hdr_format, .blend = .alpha }}),
        .forward_peel => device.createGraphicsPipeline(.{
            .name = "forward transparent (peel)",
            .vertex = shaderCode("forward.vert.spv"),
            .fragment = shaderCode("forward_peel.frag.spv"),
            .color_targets = &.{.{ .format = hdr_format }},
            .depth = .{ .write = true, .compare = .greater },
            .cull = .none,
        }),
        .peel_under => Local.pass(device, "peel under", shaderCode("copy.frag.spv"), &.{.{ .format = hdr_format, .blend = .under }}),
        .peel_composite => Local.pass(device, "peel composite", shaderCode("copy.frag.spv"), &.{.{ .format = hdr_format, .blend = .premultiplied }}),
        .copy => Local.pass(device, "copy", shaderCode("copy.frag.spv"), &.{.{ .format = hdr_format }}),
        .upscale => Local.pass(device, "upscale", shaderCode("upscale.frag.spv"), &.{.{ .format = hdr_format }}),
        .shading_rate => Local.pass(device, "shading rate", shaderCode("shading_rate.frag.spv"), &.{.{ .format = .r8_uint }}),
        .fsr_easu => Local.pass(device, "fsr upscale", shaderCode("fsr_easu.frag.spv"), &.{.{ .format = hdr_format }}),
        .fsr_rcas => Local.pass(device, "fsr sharpen", shaderCode("fsr_rcas.frag.spv"), &.{.{ .format = hdr_format }}),
        .hiz => Local.pass(device, "depth pyramid", shaderCode("hiz.frag.spv"), &.{.{ .format = .r32_float }}),
        .hiz_compute => device.createComputePipeline(.{ .name = "depth pyramid", .shader = shaderCode("hiz.comp.spv") }),
        .visibility => device.createGraphicsPipeline(.{
            .name = "visibility",
            .vertex = shaderCode("visibility.vert.spv"),
            .mesh = if (device.caps.mesh_shaders) shaderCode("visibility.mesh.spv") else null,
            .task = if (device.caps.mesh_shaders) shaderCode("visibility.task.spv") else null,
            .fragment = shaderCode("visibility.frag.spv"),
            .color_targets = &.{.{ .format = .r32_uint }},
            .depth = .{},
            .cull = .back,
        }),
        .visibility_masked => device.createGraphicsPipeline(.{
            .name = "visibility masked",
            .vertex = shaderCode("visibility.vert.spv"),
            .mesh = if (device.caps.mesh_shaders) shaderCode("visibility.mesh.spv") else null,
            .task = if (device.caps.mesh_shaders) shaderCode("visibility.task.spv") else null,
            .fragment = shaderCode("visibility_masked.frag.spv"),
            .color_targets = &.{.{ .format = .r32_uint }},
            .depth = .{},
            .cull = .none,
        }),
        .shadow => device.createGraphicsPipeline(.{
            .name = "shadow",
            .vertex = shaderCode("visibility.vert.spv"),
            .mesh = if (device.caps.mesh_shaders) shaderCode("visibility.mesh.spv") else null,
            .task = if (device.caps.mesh_shaders) shaderCode("visibility.task.spv") else null,
            .depth = shadow_depth,
            .cull = .back,
        }),
        .shadow_masked => device.createGraphicsPipeline(.{
            .name = "shadow masked",
            .vertex = shaderCode("visibility.vert.spv"),
            .mesh = if (device.caps.mesh_shaders) shaderCode("visibility.mesh.spv") else null,
            .task = if (device.caps.mesh_shaders) shaderCode("visibility.task.spv") else null,
            .fragment = shaderCode("shadow_masked.frag.spv"),
            .depth = shadow_depth,
            .cull = .none,
        }),
        .shadow_color => device.createGraphicsPipeline(.{
            .name = "shadow tint",
            .vertex = shaderCode("visibility.vert.spv"),
            .mesh = if (device.caps.mesh_shaders) shaderCode("visibility.mesh.spv") else null,
            .task = if (device.caps.mesh_shaders) shaderCode("visibility.task.spv") else null,
            .fragment = shaderCode("shadow_color.frag.spv"),
            .color_targets = &.{.{ .format = .rgba8_unorm, .blend = .tint }},
            .cull = .none,
        }),
        .gtao => Local.pass(device, "gtao", shaderCode("gtao.frag.spv"), &.{ .{ .format = .rg16_float }, .{ .format = .rgba16_float } }),
        .gtao_bounce_denoise => Local.pass(device, "gtao bounce denoise", shaderCode("gtao_bounce_denoise.frag.spv"), &.{ .{ .format = .r16_float }, .{ .format = .rgba16_float } }),
        .ao_depth => Local.pass(device, "ao depth", shaderCode("ao_depth.frag.spv"), &.{.{ .format = .r16_float }}),
        .gi_gather => Local.pass(device, "gi gather", shaderCode("gi_gather.frag.spv"), &.{.{ .format = hdr_format }}),
        .gtao_denoise => Local.pass(device, "gtao denoise", shaderCode("gtao_denoise.frag.spv"), &.{.{ .format = .r16_float }}),
        .shade => Local.pass(device, "shading", if (device.caps.ray_tracing) shaderCode("shade_rt_plain.frag.spv") else shaderCode("shade_plain.frag.spv"), &shade_plain_targets),
        .shade_reflective => Local.pass(device, "shading (reflective)", if (device.caps.ray_tracing) shaderCode("shade_rt.frag.spv") else shaderCode("shade.frag.spv"), &shade_reflective_targets),
        .ssr => Local.pass(device, "reflections", shaderCode("ssr.frag.spv"), &.{.{ .format = hdr_format }}),
        .ssr_traced => Local.pass(device, "reflections (ray traced)", if (device.caps.ray_tracing) shaderCode("ssr_rt.frag.spv") else shaderCode("ssr.frag.spv"), &.{.{ .format = hdr_format }}),
        .ssr_composite => Local.pass(device, "reflection composite", shaderCode("ssr_composite.frag.spv"), &.{.{ .format = hdr_format, .blend = .additive }}),
        .cloud_noise => Local.pass(device, "cloud noise", shaderCode("cloud_noise.frag.spv"), &.{.{ .format = .rgba8_unorm }}),
        .cloud => Local.pass(device, "clouds", shaderCode("cloud.frag.spv"), &.{.{ .format = hdr_format }}),
        .cloud_composite => Local.pass(device, "cloud composite", shaderCode("cloud_composite.frag.spv"), &.{.{ .format = hdr_format, .blend = .premultiplied }}),
        .fluid_advect => Local.pass(device, "fluid advect", shaderCode("fluid_advect.frag.spv"), &.{ .{ .format = .rgba16_float }, .{ .format = .rgba16_float } }),
        .fluid_curl => Local.pass(device, "fluid curl", shaderCode("fluid_curl.frag.spv"), &.{.{ .format = .rgba16_float }}),
        .fluid_force => Local.pass(device, "fluid forces", shaderCode("fluid_force.frag.spv"), &.{.{ .format = .rgba16_float }}),
        .fluid_divergence => Local.pass(device, "fluid divergence", shaderCode("fluid_divergence.frag.spv"), &.{.{ .format = .rg16_float }}),
        .fluid_pressure => Local.pass(device, "fluid pressure", shaderCode("fluid_pressure.frag.spv"), &.{.{ .format = .rg16_float }}),
        .fluid_project => Local.pass(device, "fluid projection", shaderCode("fluid_project.frag.spv"), &.{.{ .format = .rgba16_float }}),
        .fluid_present => Local.pass(device, "fluid picture", shaderCode("fluid_present.frag.spv"), &.{.{ .format = hdr_format }}),
        .water_sim => Local.pass(device, "water simulation", shaderCode("water_sim.frag.spv"), &.{.{ .format = .rg16_float }}),
        .water => device.createGraphicsPipeline(.{
            .name = "water",
            .vertex = shaderCode("water.vert.spv"),
            .fragment = if (device.caps.ray_tracing) shaderCode("water_rt.frag.spv") else shaderCode("water.frag.spv"),
            .color_targets = &.{.{ .format = hdr_format }},
            .cull = .none,
        }),
        .underwater => Local.pass(device, "underwater", shaderCode("underwater.frag.spv"), &.{.{ .format = hdr_format }}),
        .liquid_sim => device.createComputePipeline(.{ .name = "liquid simulation", .shader = shaderCode("liquid_sim.comp.spv") }),
        .path_trace_compute => device.createComputePipeline(.{ .name = "path tracing", .shader = if (device.caps.ray_tracing) shaderCode("pathtrace_rt.comp.spv") else shaderCode("pathtrace.comp.spv") }),
        .path_gather => Local.pass(device, "path tracing gather", shaderCode("pathtrace_gather.frag.spv"), &.{ .{ .format = .rgba32_float }, .{ .format = .rgba16_float }, .{ .format = .rgba32_float }, .{ .format = .rgba16_float }, .{ .format = .rgba16_float }, .{ .format = .rgba32_float }, .{ .format = .rgba16_float } }),
        .nrd_compose => Local.pass(device, "nrd compose", shaderCode("nrd_compose.frag.spv"), &.{.{ .format = hdr_format }}),
        .nrd_pack => Local.pass(device, "nrd inputs", shaderCode("nrd_pack.frag.spv"), &.{ .{ .format = .rgba16_float }, .{ .format = .r32_float }, .{ .format = .rgba16_float }, .{ .format = .rgba16_float } }),
        .path_trace => Local.pass(device, "path tracing", if (device.caps.ray_tracing) shaderCode("pathtrace_rt.frag.spv") else shaderCode("pathtrace.frag.spv"), &.{ .{ .format = .rgba32_float }, .{ .format = .rgba16_float }, .{ .format = .rgba32_float }, .{ .format = .rgba16_float }, .{ .format = .rgba16_float }, .{ .format = .rgba32_float }, .{ .format = .rgba16_float }, .{ .format = .rgba32_float } }),
        .path_denoise => Local.pass(device, "path tracing denoise", shaderCode("pathtrace_denoise.frag.spv"), &.{.{ .format = .rgba16_float }}),
        .path_denoise_final => Local.pass(device, "path tracing denoise (last)", shaderCode("pathtrace_denoise.frag.spv"), &.{.{ .format = hdr_format }}),
        .reflection_reproject => Local.pass(device, "reflection denoise: reproject", shaderCode("ffx_reflections_reproject.frag.spv"), &.{ .{ .format = .rgba16_float }, .{ .format = .r16_float } }),
        .reflection_average => Local.pass(device, "reflection denoise: average", shaderCode("ffx_reflections_average.frag.spv"), &.{.{ .format = .rgba16_float }}),
        .reflection_prefilter => Local.pass(device, "reflection denoise: prefilter", shaderCode("ffx_reflections_prefilter.frag.spv"), &.{.{ .format = .rgba16_float }}),
        .reflection_resolve => Local.pass(device, "reflection denoise: resolve", shaderCode("ffx_reflections_resolve.frag.spv"), &.{.{ .format = .rgba16_float }}),
        .liquid_surface => device.createGraphicsPipeline(.{
            .name = "liquid surface depth",
            .vertex = shaderCode("fullscreen.vert.spv"),
            .fragment = shaderCode("liquid_surface.frag.spv"),
            .color_targets = &.{.{ .format = .rg16_float }},
            .depth = .{ .write = true, .compare = .greater },
            .cull = .none,
        }),
        .liquid_shadow => device.createGraphicsPipeline(.{
            .name = "liquid shadow",
            .vertex = shaderCode("liquid_shadow.vert.spv"),
            .fragment = shaderCode("liquid_shadow.frag.spv"),
            .depth = shadow_depth,
            .cull = .none,
        }),
        .liquid_depth => device.createGraphicsPipeline(.{
            .name = "liquid depth",
            .vertex = shaderCode("liquid.vert.spv"),
            .fragment = shaderCode("liquid_depth.frag.spv"),
            .depth = .{ .write = true, .compare = .greater },
            .cull = .none,
        }),
        .liquid_thickness => device.createGraphicsPipeline(.{
            .name = "liquid thickness",
            .vertex = shaderCode("liquid.vert.spv"),
            .fragment = shaderCode("liquid_thickness.frag.spv"),
            .color_targets = &.{.{ .format = .r16_float, .blend = .additive }},
            .cull = .none,
        }),
        .liquid_blur => Local.pass(device, "liquid smoothing", shaderCode("liquid_blur.frag.spv"), &.{.{ .format = .r32_float }}),
        .liquid => Local.pass(device, "liquid", shaderCode("liquid.frag.spv"), &.{.{ .format = hdr_format, .blend = .alpha }}),
        .water_depth => device.createGraphicsPipeline(.{
            .name = "water depth",
            .vertex = shaderCode("water.vert.spv"),
            .depth = .{ .write = true, .compare = .greater },
            .cull = .none,
        }),
        .fluid_solid => Local.pass(device, "fluid obstacles", shaderCode("fluid_solid.frag.spv"), &.{.{ .format = .r8_unorm }}),
        .fluid_solid_traced => Local.pass(device, "fluid obstacles (scene)", if (device.caps.ray_tracing) shaderCode("fluid_solid_rt.frag.spv") else shaderCode("fluid_solid.frag.spv"), &.{.{ .format = .r8_unorm }}),
        .fluid_carry => Local.pass(device, "fluid carry", shaderCode("fluid_carry.frag.spv"), &.{ .{ .format = .rgba16_float }, .{ .format = .rgba16_float } }),
        .fluid => Local.pass(device, "fluids", shaderCode("fluid.frag.spv"), &.{ .{ .format = hdr_format }, .{ .format = .rgba16_float } }),
        .fluid_motion => Local.pass(device, "fluid motion", shaderCode("fluid_motion.frag.spv"), &.{.{ .format = .rg16_float, .blend = .alpha }}),
        .dof => Local.pass(device, "depth of field", shaderCode("dof.frag.spv"), &.{.{ .format = hdr_format }}),
        .dof_composite => Local.pass(device, "depth of field (join)", shaderCode("dof_composite.frag.spv"), &.{.{ .format = hdr_format }}),
        .motion_blur => Local.pass(device, "motion blur", shaderCode("motion_blur.frag.spv"), &.{.{ .format = hdr_format }}),
        .fog => Local.pass(device, "fog", shaderCode("fog.frag.spv"), &.{.{ .format = hdr_format }}),
        .fog_composite => Local.pass(device, "fog composite", shaderCode("fog_composite.frag.spv"), &.{.{ .format = hdr_format, .blend = .premultiplied }}),
        .taa => Local.pass(device, "taa", shaderCode("taa.frag.spv"), &.{.{ .format = hdr_format }}),
        .bloom_down => Local.pass(device, "bloom down", shaderCode("bloom_down.frag.spv"), &.{.{ .format = bloom_format }}),
        .bloom_up => Local.pass(device, "bloom up", shaderCode("bloom_up.frag.spv"), &.{.{ .format = bloom_format, .blend = .additive }}),
        .exposure => device.createComputePipeline(.{ .name = "exposure", .shader = shaderCode("exposure.comp.spv") }),
        .pick => device.createComputePipeline(.{ .name = "pick", .shader = shaderCode("pick.comp.spv") }),
        .particle_sim => device.createComputePipeline(.{ .name = "particle simulation", .shader = shaderCode("particle_sim.comp.spv") }),
        .fluid_light => device.createComputePipeline(.{ .name = "fluid light", .shader = shaderCode("fluid_light.comp.spv") }),
        .particle_sort_keys => device.createComputePipeline(.{ .name = "particle sort keys", .shader = shaderCode("particle_sort_keys.comp.spv") }),
        .particle_sort => device.createComputePipeline(.{ .name = "particle sort", .shader = shaderCode("particle_sort.comp.spv") }),
        .particles => device.createGraphicsPipeline(.{
            .name = "particles",
            .vertex = shaderCode("particle.vert.spv"),
            .fragment = shaderCode("particle.frag.spv"),
            .color_targets = &.{ .{ .format = hdr_format, .blend = .premultiplied }, .{ .format = .rg16_float, .blend = .alpha } },
            .cull = .none,
        }),
        .particle_trails => device.createGraphicsPipeline(.{
            .name = "particle trails",
            .vertex = shaderCode("particle_trail.vert.spv"),
            .fragment = shaderCode("particle.frag.spv"),
            .color_targets = &.{ .{ .format = hdr_format, .blend = .premultiplied }, .{ .format = .rg16_float, .blend = .alpha } },
            .cull = .none,
        }),
        .impostor => device.createGraphicsPipeline(.{
            .name = "impostors",
            .vertex = shaderCode("impostor.vert.spv"),
            .fragment = shaderCode("impostor.frag.spv"),
            .color_targets = &.{ .{ .format = hdr_format, .blend = .premultiplied }, .{ .format = .rg16_float, .blend = .alpha } },
            .depth = .{ .write = true, .compare = .greater_or_equal },
            .cull = .none,
        }),
        .impostor_bake => device.createGraphicsPipeline(.{
            .name = "impostor bake",
            .vertex = shaderCode("impostor_bake.vert.spv"),
            .fragment = shaderCode("impostor_bake.frag.spv"),
            .color_targets = &.{ .{ .format = .rgba8_srgb }, .{ .format = .rgba8_unorm } },
            .depth = .{ .write = true, .compare = .greater_or_equal },
            .cull = .none,
        }),
        .lightmap_bake => device.createGraphicsPipeline(.{
            .name = "lightmap bake",
            .vertex = shaderCode("lightmap_bake.vert.spv"),
            .fragment = shaderCode("lightmap_bake.frag.spv"),
            .color_targets = &.{.{ .format = hdr_format }},
            .cull = .none,
        }),
        .vsm_mark => device.createComputePipeline(.{ .name = "virtual shadow requests", .shader = shaderCode("vsm_mark.comp.spv") }),
        .vsm_allocate => device.createComputePipeline(.{ .name = "virtual shadow pages", .shader = shaderCode("vsm_allocate.comp.spv") }),
        .vsm_clear => device.createGraphicsPipeline(.{
            .name = "virtual shadow clear",
            .vertex = shaderCode("vsm_clear.vert.spv"),
            .depth = .{ .compare = .always },
            .cull = .none,
        }),
        .lightmap_dilate => Local.pass(device, "lightmap dilate", shaderCode("lightmap_dilate.frag.spv"), &.{.{ .format = hdr_format }}),
        .hair_simulation => device.createComputePipeline(.{ .name = "hair simulation", .shader = shaderCode("hair_sim.comp.spv") }),
        .hair_shadow => device.createGraphicsPipeline(.{
            .name = "hair shadow",
            .vertex = shaderCode("hair_shadow.vert.spv"),
            .depth = shadow_depth,
            .cull = .none,
        }),
        .hair => device.createGraphicsPipeline(.{
            .name = "hair",
            .vertex = shaderCode("hair.vert.spv"),
            .fragment = shaderCode("hair.frag.spv"),
            .color_targets = &.{ .{ .format = hdr_format, .blend = .premultiplied }, .{ .format = .rg16_float, .blend = .alpha } },
            .depth = .{ .write = true, .compare = .greater_or_equal },
            .cull = .none,
        }),
        .particle_mesh => device.createGraphicsPipeline(.{
            .name = "mesh particles",
            .vertex = shaderCode("particle_mesh.vert.spv"),
            .fragment = shaderCode("particle_mesh.frag.spv"),
            .color_targets = &.{ .{ .format = hdr_format, .blend = .premultiplied }, .{ .format = .rg16_float, .blend = .alpha } },
            .depth = .{ .write = true, .compare = .greater_or_equal },
            .cull = .none,
        }),
        .probe_face => Local.pass(device, "probe face", shaderCode("probe_face.frag.spv"), &.{.{ .format = hdr_format }}),
        .env_cube => Local.pass(device, "env cube", shaderCode("env_cube.frag.spv"), &.{.{ .format = hdr_format }}),
        .env_sky => Local.pass(device, "env sky", shaderCode("env_sky.frag.spv"), &.{.{ .format = hdr_format }}),
        .env_irradiance => Local.pass(device, "env irradiance", shaderCode("env_irradiance.frag.spv"), &.{.{ .format = hdr_format }}),
        .env_prefilter => Local.pass(device, "env prefilter", shaderCode("env_prefilter.frag.spv"), &.{.{ .format = hdr_format }}),
        .brdf_lut => Local.pass(device, "brdf lut", shaderCode("brdf_lut.frag.spv"), &.{.{ .format = .rg16_float }}),
        .gi_trace => device.createComputePipeline(.{ .name = "gi trace", .shader = shaderCode("gi_trace.comp.spv") }),
        .gi_irradiance => device.createGraphicsPipeline(.{
            .name = "gi irradiance",
            .vertex = shaderCode("fullscreen.vert.spv"),
            .fragment = shaderCode("gi_irradiance.frag.spv"),
            .color_targets = &.{ .{ .format = hdr_format, .blend = .alpha }, .{ .format = hdr_format, .blend = .alpha } },
            .cull = .none,
        }),
        .gi_clamp_upper => device.createGraphicsPipeline(.{
            .name = "gi clamp upper",
            .vertex = shaderCode("fullscreen.vert.spv"),
            .fragment = shaderCode("gi_clamp.frag.spv"),
            .color_targets = &.{.{ .format = hdr_format, .blend = .minimum }},
            .cull = .none,
        }),
        .gi_relocate => device.createGraphicsPipeline(.{
            .name = "gi relocate",
            .vertex = shaderCode("fullscreen.vert.spv"),
            .fragment = shaderCode("gi_relocate.frag.spv"),
            .color_targets = &.{.{ .format = .rgba16_float }},
            .cull = .none,
        }),
        .gi_clamp_lower => device.createGraphicsPipeline(.{
            .name = "gi clamp lower",
            .vertex = shaderCode("fullscreen.vert.spv"),
            .fragment = shaderCode("gi_clamp.frag.spv"),
            .color_targets = &.{.{ .format = hdr_format, .blend = .maximum }},
            .cull = .none,
        }),
        .gi_visibility => device.createGraphicsPipeline(.{
            .name = "gi visibility",
            .vertex = shaderCode("fullscreen.vert.spv"),
            .fragment = shaderCode("gi_visibility.frag.spv"),
            .color_targets = &.{.{ .format = .rg16_float, .blend = .alpha }},
            .cull = .none,
        }),
    };
}

/// Shaders that `shaders.reload` has compiled, by name. Every renderer in
/// the process shares them; `releaseOverrides` frees them with the last one.
var shader_overrides: std.StringHashMapUnmanaged([]u8) = .empty;
/// Code a reload replaced, kept because pipelines may still be compiling it.
var retired_overrides: std.ArrayList([]u8) = .empty;
var override_users: u32 = 0;
var overrides_locked: std.atomic.Value(bool) = .init(false);
const override_allocator = std.heap.page_allocator;

fn lockOverrides() void {
    while (overrides_locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}

fn unlockOverrides() void {
    overrides_locked.store(false, .release);
}

/// Counts a renderer in; pair with `releaseOverrides`.
pub fn acquireOverrides() void {
    lockOverrides();
    defer unlockOverrides();
    override_users += 1;
}

pub fn releaseOverrides() void {
    lockOverrides();
    defer unlockOverrides();
    override_users -= 1;
    if (override_users != 0) return;
    var overrides = shader_overrides.valueIterator();
    while (overrides.next()) |code| override_allocator.free(code.*);
    shader_overrides.deinit(override_allocator);
    shader_overrides = .empty;
    for (retired_overrides.items) |code| override_allocator.free(code);
    retired_overrides.deinit(override_allocator);
    retired_overrides = .empty;
}

fn overrideShader(name: []const u8, code: []const u8) !void {
    const copy = try override_allocator.dupe(u8, code);
    errdefer override_allocator.free(copy);
    lockOverrides();
    defer unlockOverrides();
    try retired_overrides.ensureUnusedCapacity(override_allocator, 1);
    if (try shader_overrides.fetchPut(override_allocator, name, copy)) |old| retired_overrides.appendAssumeCapacity(old.value);
}

/// Shader code by name: what `shaders.reload` last compiled, or else what
/// was built into the program.
pub fn shaderCode(comptime name: []const u8) []const u8 {
    lockOverrides();
    defer unlockOverrides();
    if (shader_overrides.get(name)) |code| return code;
    return @embedFile(name);
}
