const std = @import("std");

const Shader = struct {
    src: []const u8,
    name: []const u8,
    defines: []const []const u8 = &.{},
};

const shader_dir = "src/render/shaders";

const renderer_shaders: []const Shader = &.{
    .{ .src = shader_dir ++ "/fullscreen.vert", .name = "fullscreen.vert.spv" },
    .{ .src = shader_dir ++ "/skin.comp", .name = "skin.comp.spv" },
    .{ .src = shader_dir ++ "/skin_bounds.comp", .name = "skin_bounds.comp.spv" },
    .{ .src = shader_dir ++ "/cull.comp", .name = "cull.comp.spv" },
    .{ .src = shader_dir ++ "/cull_instances.comp", .name = "cull_instances.comp.spv" },
    .{ .src = shader_dir ++ "/visibility.task", .name = "visibility.task.spv" },
    .{ .src = shader_dir ++ "/visibility.mesh", .name = "visibility.mesh.spv" },
    .{ .src = shader_dir ++ "/hiz.comp", .name = "hiz.comp.spv" },
    .{ .src = shader_dir ++ "/cluster.comp", .name = "cluster.comp.spv" },
    .{ .src = shader_dir ++ "/forward.vert", .name = "forward.vert.spv" },
    .{ .src = shader_dir ++ "/forward.frag", .name = "forward.frag.spv" },
    .{ .src = shader_dir ++ "/forward.frag", .name = "forward_weighted.frag.spv", .defines = &.{"WEIGHTED"} },
    .{ .src = shader_dir ++ "/hiz.frag", .name = "hiz.frag.spv" },
    .{ .src = shader_dir ++ "/gi_trace.comp", .name = "gi_trace.comp.spv" },
    .{ .src = shader_dir ++ "/gi_relocate.frag", .name = "gi_relocate.frag.spv" },
    .{ .src = shader_dir ++ "/gi_gather.frag", .name = "gi_gather.frag.spv" },
    .{ .src = shader_dir ++ "/gi_clamp.frag", .name = "gi_clamp.frag.spv" },
    .{ .src = shader_dir ++ "/gi_update.frag", .name = "gi_irradiance.frag.spv" },
    .{ .src = shader_dir ++ "/gi_update.frag", .name = "gi_visibility.frag.spv", .defines = &.{"VISIBILITY"} },
    .{ .src = shader_dir ++ "/visibility.vert", .name = "visibility.vert.spv" },
    .{ .src = shader_dir ++ "/visibility.frag", .name = "visibility.frag.spv" },
    .{ .src = shader_dir ++ "/visibility.frag", .name = "visibility_masked.frag.spv", .defines = &.{"ALPHA_TEST"} },
    .{ .src = shader_dir ++ "/shadow.frag", .name = "shadow_masked.frag.spv" },
    .{ .src = shader_dir ++ "/shadow_color.frag", .name = "shadow_color.frag.spv" },
    .{ .src = shader_dir ++ "/shade.frag", .name = "shade.frag.spv" },
    .{ .src = shader_dir ++ "/shade.frag", .name = "shade_rt.frag.spv", .defines = &.{"RAY_TRACED"} },
    .{ .src = shader_dir ++ "/ao_depth.frag", .name = "ao_depth.frag.spv" },
    .{ .src = shader_dir ++ "/gtao.frag", .name = "gtao.frag.spv" },
    .{ .src = shader_dir ++ "/gtao_denoise.frag", .name = "gtao_denoise.frag.spv" },
    .{ .src = shader_dir ++ "/gtao_denoise.frag", .name = "gtao_bounce_denoise.frag.spv", .defines = &.{"BOUNCE"} },
    .{ .src = shader_dir ++ "/fog.frag", .name = "fog.frag.spv" },
    .{ .src = shader_dir ++ "/fog_composite.frag", .name = "fog_composite.frag.spv" },
    .{ .src = shader_dir ++ "/taa.frag", .name = "taa.frag.spv" },
    .{ .src = shader_dir ++ "/bloom_down.frag", .name = "bloom_down.frag.spv" },
    .{ .src = shader_dir ++ "/bloom_up.frag", .name = "bloom_up.frag.spv" },
    .{ .src = shader_dir ++ "/exposure.comp", .name = "exposure.comp.spv" },
    .{ .src = shader_dir ++ "/dof.frag", .name = "dof.frag.spv" },
    .{ .src = shader_dir ++ "/dof_composite.frag", .name = "dof_composite.frag.spv" },
    .{ .src = shader_dir ++ "/motion_blur.frag", .name = "motion_blur.frag.spv" },
    .{ .src = shader_dir ++ "/oit_composite.frag", .name = "oit_composite.frag.spv" },
    .{ .src = shader_dir ++ "/copy.frag", .name = "copy.frag.spv" },
    .{ .src = shader_dir ++ "/upscale.frag", .name = "upscale.frag.spv" },
    .{ .src = shader_dir ++ "/shading_rate.frag", .name = "shading_rate.frag.spv" },
    .{ .src = shader_dir ++ "/fsr_easu.frag", .name = "fsr_easu.frag.spv" },
    .{ .src = shader_dir ++ "/fsr_rcas.frag", .name = "fsr_rcas.frag.spv" },
    .{ .src = shader_dir ++ "/ssr.frag", .name = "ssr.frag.spv" },
    .{ .src = shader_dir ++ "/ssr.frag", .name = "ssr_rt.frag.spv", .defines = &.{"RAY_TRACED"} },
    .{ .src = shader_dir ++ "/ssr_composite.frag", .name = "ssr_composite.frag.spv" },
    .{ .src = shader_dir ++ "/cloud_noise.frag", .name = "cloud_noise.frag.spv" },
    .{ .src = shader_dir ++ "/cloud.frag", .name = "cloud.frag.spv" },
    .{ .src = shader_dir ++ "/cloud_composite.frag", .name = "cloud_composite.frag.spv" },
    .{ .src = shader_dir ++ "/fluid_advect.frag", .name = "fluid_advect.frag.spv" },
    .{ .src = shader_dir ++ "/fluid_curl.frag", .name = "fluid_curl.frag.spv" },
    .{ .src = shader_dir ++ "/fluid_force.frag", .name = "fluid_force.frag.spv" },
    .{ .src = shader_dir ++ "/fluid_divergence.frag", .name = "fluid_divergence.frag.spv" },
    .{ .src = shader_dir ++ "/fluid_pressure.frag", .name = "fluid_pressure.frag.spv" },
    .{ .src = shader_dir ++ "/fluid_project.frag", .name = "fluid_project.frag.spv" },
    .{ .src = shader_dir ++ "/fluid_present.frag", .name = "fluid_present.frag.spv" },
    .{ .src = shader_dir ++ "/water_sim.frag", .name = "water_sim.frag.spv" },
    .{ .src = shader_dir ++ "/water.vert", .name = "water.vert.spv" },
    .{ .src = shader_dir ++ "/water.frag", .name = "water.frag.spv" },
    .{ .src = shader_dir ++ "/underwater.frag", .name = "underwater.frag.spv" },
    .{ .src = shader_dir ++ "/water.frag", .name = "water_rt.frag.spv", .defines = &.{"RAY_TRACED"} },
    .{ .src = shader_dir ++ "/liquid_sim.comp", .name = "liquid_sim.comp.spv" },
    .{ .src = shader_dir ++ "/liquid.vert", .name = "liquid.vert.spv" },
    .{ .src = shader_dir ++ "/liquid_depth.frag", .name = "liquid_depth.frag.spv" },
    .{ .src = shader_dir ++ "/liquid_shadow.vert", .name = "liquid_shadow.vert.spv" },
    .{ .src = shader_dir ++ "/liquid_shadow.frag", .name = "liquid_shadow.frag.spv" },
    .{ .src = shader_dir ++ "/liquid_surface.frag", .name = "liquid_surface.frag.spv" },
    .{ .src = shader_dir ++ "/pathtrace_denoise.frag", .name = "pathtrace_denoise.frag.spv" },
    .{ .src = shader_dir ++ "/ffx_reflections_reproject.frag", .name = "ffx_reflections_reproject.frag.spv" },
    .{ .src = shader_dir ++ "/ffx_reflections_average.frag", .name = "ffx_reflections_average.frag.spv" },
    .{ .src = shader_dir ++ "/ffx_reflections_prefilter.frag", .name = "ffx_reflections_prefilter.frag.spv" },
    .{ .src = shader_dir ++ "/ffx_reflections_resolve.frag", .name = "ffx_reflections_resolve.frag.spv" },
    .{ .src = shader_dir ++ "/pathtrace.frag", .name = "pathtrace.frag.spv" },
    .{ .src = shader_dir ++ "/pathtrace.frag", .name = "pathtrace_rt.frag.spv", .defines = &.{"RAY_TRACED"} },
    .{ .src = shader_dir ++ "/liquid_thickness.frag", .name = "liquid_thickness.frag.spv" },
    .{ .src = shader_dir ++ "/liquid_blur.frag", .name = "liquid_blur.frag.spv" },
    .{ .src = shader_dir ++ "/liquid.frag", .name = "liquid.frag.spv" },
    .{ .src = shader_dir ++ "/fluid_solid.frag", .name = "fluid_solid.frag.spv" },
    .{ .src = shader_dir ++ "/fluid_solid.frag", .name = "fluid_solid_rt.frag.spv", .defines = &.{"RAY_TRACED"} },
    .{ .src = shader_dir ++ "/fluid_carry.frag", .name = "fluid_carry.frag.spv" },
    .{ .src = shader_dir ++ "/fluid.frag", .name = "fluid.frag.spv" },
    .{ .src = shader_dir ++ "/fluid_motion.frag", .name = "fluid_motion.frag.spv" },
    .{ .src = shader_dir ++ "/pick.comp", .name = "pick.comp.spv" },
    .{ .src = shader_dir ++ "/fluid_light.comp", .name = "fluid_light.comp.spv" },
    .{ .src = shader_dir ++ "/particle_sim.comp", .name = "particle_sim.comp.spv" },
    .{ .src = shader_dir ++ "/particle_sort_keys.comp", .name = "particle_sort_keys.comp.spv" },
    .{ .src = shader_dir ++ "/particle_sort.comp", .name = "particle_sort.comp.spv" },
    .{ .src = shader_dir ++ "/particle.vert", .name = "particle.vert.spv" },
    .{ .src = shader_dir ++ "/particle_trail.vert", .name = "particle_trail.vert.spv" },
    .{ .src = shader_dir ++ "/impostor.vert", .name = "impostor.vert.spv" },
    .{ .src = shader_dir ++ "/impostor.frag", .name = "impostor.frag.spv" },
    .{ .src = shader_dir ++ "/impostor_bake.vert", .name = "impostor_bake.vert.spv" },
    .{ .src = shader_dir ++ "/impostor_bake.frag", .name = "impostor_bake.frag.spv" },
    .{ .src = shader_dir ++ "/lightmap_bake.vert", .name = "lightmap_bake.vert.spv" },
    .{ .src = shader_dir ++ "/lightmap_bake.frag", .name = "lightmap_bake.frag.spv" },
    .{ .src = shader_dir ++ "/lightmap_dilate.frag", .name = "lightmap_dilate.frag.spv" },
    .{ .src = shader_dir ++ "/vsm_mark.comp", .name = "vsm_mark.comp.spv" },
    .{ .src = shader_dir ++ "/vsm_allocate.comp", .name = "vsm_allocate.comp.spv" },
    .{ .src = shader_dir ++ "/vsm_clear.vert", .name = "vsm_clear.vert.spv" },
    .{ .src = shader_dir ++ "/hair_sim.comp", .name = "hair_sim.comp.spv" },
    .{ .src = shader_dir ++ "/hair_shadow.vert", .name = "hair_shadow.vert.spv" },
    .{ .src = shader_dir ++ "/hair.vert", .name = "hair.vert.spv" },
    .{ .src = shader_dir ++ "/hair.frag", .name = "hair.frag.spv" },
    .{ .src = shader_dir ++ "/particle_mesh.vert", .name = "particle_mesh.vert.spv" },
    .{ .src = shader_dir ++ "/particle_mesh.frag", .name = "particle_mesh.frag.spv" },
    .{ .src = shader_dir ++ "/particle.frag", .name = "particle.frag.spv" },
    .{ .src = shader_dir ++ "/tonemap.frag", .name = "tonemap.frag.spv" },
    .{ .src = shader_dir ++ "/draw.vert", .name = "draw.vert.spv" },
    .{ .src = shader_dir ++ "/draw.frag", .name = "draw.frag.spv" },
    .{ .src = shader_dir ++ "/env_cube.frag", .name = "env_cube.frag.spv" },
    .{ .src = shader_dir ++ "/probe_face.frag", .name = "probe_face.frag.spv" },
    .{ .src = shader_dir ++ "/env_sky.frag", .name = "env_sky.frag.spv" },
    .{ .src = shader_dir ++ "/env_irradiance.frag", .name = "env_irradiance.frag.spv" },
    .{ .src = shader_dir ++ "/env_prefilter.frag", .name = "env_prefilter.frag.spv" },
    .{ .src = shader_dir ++ "/brdf_lut.frag", .name = "brdf_lut.frag.spv" },
};

const Example = struct {
    name: []const u8,
    root: []const u8,
    description: []const u8,
    windowed: bool,
    shaders: []const Shader = &.{},
};

const examples: []const Example = &.{
    .{
        .name = "triangle",
        .root = "examples/triangle/main.zig",
        .description = "Draw a triangle with the bare RHI",
        .windowed = true,
        .shaders = &.{
            .{ .src = "examples/triangle/triangle.vert", .name = "triangle.vert.spv" },
            .{ .src = "examples/triangle/triangle.frag", .name = "triangle.frag.spv" },
        },
    },
    .{
        .name = "canvas",
        .root = "examples/canvas.zig",
        .description = "A 2D-only application: shapes, sprites and text",
        .windowed = true,
    },
    .{
        .name = "meadow",
        .root = "examples/meadow.zig",
        .description = "An open meadow to walk through: grass, trees, a pond, clouds, sun and sky",
        .windowed = true,
    },
    .{
        .name = "materials",
        .root = "examples/materials.zig",
        .description = "A grid of metals and plastics, glass, lacquer, velvet and wax, lit by a studio photograph",
        .windowed = true,
    },
    .{
        .name = "lights",
        .root = "examples/lights.zig",
        .description = "A hall at night: many drifting lamps, a shadowed spot light and a glowing panel",
        .windowed = true,
    },
    .{
        .name = "decals",
        .root = "examples/decals.zig",
        .description = "Markings, stains and glowing signs projected onto a floor, a wall and a ball",
        .windowed = true,
    },
    .{
        .name = "text",
        .root = "examples/text.zig",
        .description = "Text at any size, ligatures, right-to-left and complex scripts, rich text, text in 3D",
        .windowed = true,
    },
    .{
        .name = "views",
        .root = "examples/views.zig",
        .description = "A split screen, a camera rendered to a texture and a 2D layer in one frame",
        .windowed = true,
    },
    .{
        .name = "post",
        .root = "examples/post.zig",
        .description = "Bloom, depth of field, motion blur, grading and the other effects, one key each",
        .windowed = true,
    },
    .{
        .name = "shader",
        .root = "examples/shader.zig",
        .description = "A material written by the application: molten rock that cools per object",
        .windowed = true,
        .shaders = &.{.{ .src = "examples/shaders/lava.frag", .name = "lava.frag.spv" }},
    },
    .{
        .name = "rtx",
        .root = "examples/rtx.zig",
        .description = "Ray tracing a feature at a time in Sponza: bounce light, reflections, soft shadows, path tracing",
        .windowed = true,
    },
    .{
        .name = "pathtrace",
        .root = "examples/pathtrace.zig",
        .description = "Path tracing by the GPU's ray tracing or by a shader, beside the usual picture",
        .windowed = true,
    },
    .{
        .name = "particles",
        .root = "examples/particles.zig",
        .description = "GPU particle emitters: fire, smoke, a fountain, snow and a moving spark",
        .windowed = true,
    },
    .{
        .name = "animation",
        .root = "examples/animation.zig",
        .description = "Clip cross-fades, masked layers and additive layers on one character",
        .windowed = true,
    },
    .{
        .name = "instancing",
        .root = "examples/instancing.zig",
        .description = "A forest placed as one instance group, with picking",
        .windowed = true,
    },
    .{
        .name = "reflections",
        .root = "examples/reflections.zig",
        .description = "Polished floor, spheres from mirror to rough, metals and lacquer, with reflections",
        .windowed = true,
    },
    .{
        .name = "clouds",
        .root = "examples/clouds.zig",
        .description = "Volumetric clouds over a landscape, with time of day",
        .windowed = true,
    },
    .{
        .name = "fluid",
        .root = "examples/fluid.zig",
        .description = "Simulated smoke and fire, in the scene and as a 2D picture",
        .windowed = true,
    },
    .{
        .name = "water",
        .root = "examples/water.zig",
        .description = "A pool of simulated water with ripples, rain, reflection and refraction",
        .windowed = true,
    },
    .{
        .name = "liquid",
        .root = "examples/liquid.zig",
        .description = "A volume of liquid that pours, sloshes and splashes in a tank",
        .windowed = true,
    },
    .{
        .name = "world",
        .root = "examples/world.zig",
        .description = "Walk a skinned character through Sponza",
        .windowed = true,
    },
    .{
        .name = "asteroids",
        .root = "examples/asteroids.zig",
        .description = "A belt of millions of rocks, culled and drawn by the GPU",
        .windowed = true,
    },
    .{
        .name = "shadows",
        .root = "examples/shadows.zig",
        .description = "Virtual shadow maps beside the sun's cascades, down a long avenue of fine shadows",
        .windowed = true,
    },
    .{
        .name = "bistro",
        .root = "examples/bistro.zig",
        .description = "Amazon Lumberyard Bistro: a full street scene by day and by night",
        .windowed = true,
    },
    .{
        .name = "upscaling",
        .root = "examples/upscaling.zig",
        .description = "Drawing fewer pixels: bicubic, temporal and FidelityFX upscaling, and coarse shading",
        .windowed = true,
    },
    .{
        .name = "lightmap",
        .root = "examples/lightmap.zig",
        .description = "A room whose bounce light is baked into lightmaps by rays while you watch",
        .windowed = true,
    },
    .{
        .name = "stereo",
        .root = "examples/stereo.zig",
        .description = "A stereo pair: the scene once for each eye, side by side",
        .windowed = true,
    },
    .{
        .name = "hair",
        .root = "examples/hair.zig",
        .description = "Ten thousand strands of hair that hang, swing and blow about",
        .windowed = true,
    },
    .{
        .name = "voxels",
        .root = "examples/voxels.zig",
        .description = "Fly round a small planet of fifty million voxels as its chunks stream in",
        .windowed = true,
    },
};

/// Shaders of the examples that the verification scene draws with too.
const verify_shaders: []const Shader = &.{
    .{ .src = "examples/shaders/fullscreen.vert", .name = "example_fullscreen.vert.spv" },
    .{ .src = "examples/shaders/outline.frag", .name = "outline.frag.spv" },
    .{ .src = "examples/shaders/lava.frag", .name = "lava.frag.spv" },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const thread_sanitizer = b.option(bool, "tsan", "Build with the thread sanitizer (for the threaded stress test)") orelse false;
    const vulkan_headers = b.dependency("vulkan_headers", .{});
    const vulkan_include = vulkan_headers.path("include");
    const vulkan = b.lazyDependency("vulkan", .{
        .registry = vulkan_headers.path("registry/vk.xml"),
    }) orelse return;

    const asset_optimize: std.builtin.OptimizeMode = if (optimize == .Debug) .ReleaseFast else optimize;
    const validate_input = b.option(bool, "validate_input", "Check asset files before trusting them and keep safety checks in the asset parsers (default: true)") orelse true;
    const parser_optimize: std.builtin.OptimizeMode = if (optimize == .Debug and validate_input) .ReleaseSafe else asset_optimize;
    const fidelityfx = b.option(bool, "fidelityfx", "Build AMD's FidelityFX SDK in, for FSR 2 and FSR 3 upscaling (default: true)") orelse true;
    const features = b.addOptions();
    features.addOption(bool, "fidelityfx", fidelityfx);
    features.addOption(bool, "validate_input", validate_input);
    const features_module = features.createModule();
    const zmesh = b.dependency("zmesh", .{ .target = target, .optimize = asset_optimize });
    const zstbi = b.dependency("zstbi", .{ .target = target, .optimize = asset_optimize });

    const shaders_step = b.step("shaders", "Compile all shaders to SPIR-V");
    b.addNamedLazyPath("shader_include", b.path(shader_dir));

    const renderer = b.addModule("limn", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = thread_sanitizer,
    });
    renderer.addImport("vulkan", vulkan.module("vulkan-zig"));
    const volk = b.dependency("volk", .{});
    renderer.addImport("volk", volkModule(b, target, optimize, vulkan_include, volk));
    renderer.addImport("zmesh", zmesh.module("root"));
    renderer.linkLibrary(zmesh.artifact("zmesh"));
    renderer.addImport("zstbi", zstbi.module("root"));
    const simplifier = b.addLibrary(.{
        .name = "renderer_simplifier",
        .root_module = b.createModule(.{ .target = target, .optimize = asset_optimize, .link_libcpp = true }),
    });
    simplifier.root_module.addCSourceFile(.{
        .file = b.path("src/third_party/meshoptimizer/simplifier.cpp"),
        .flags = &.{
            "-fno-exceptions",                                                     "-fno-rtti",
            "-Dmeshopt=rnd_meshopt",                                               "-Dmeshopt_Allocator=rnd_meshopt_Allocator",
            "-Dmeshopt_simplify=rnd_meshopt_simplify",                             "-Dmeshopt_simplifyEdge=rnd_meshopt_simplifyEdge",
            "-Dmeshopt_simplifyWithAttributes=rnd_meshopt_simplifyWithAttributes", "-Dmeshopt_simplifySloppy=rnd_meshopt_simplifySloppy",
            "-Dmeshopt_simplifyPrune=rnd_meshopt_simplifyPrune",                   "-Dmeshopt_simplifyPoints=rnd_meshopt_simplifyPoints",
            "-Dmeshopt_simplifyScale=rnd_meshopt_simplifyScale",
        },
    });
    renderer.linkLibrary(simplifier);
    const basis = b.addLibrary(.{
        .name = "renderer_basis",
        .root_module = b.createModule(.{ .target = target, .optimize = asset_optimize, .link_libcpp = true }),
    });
    basis.root_module.addCSourceFiles(.{
        .root = b.path("src/third_party/basisu"),
        .files = &.{ "transcoder/basisu_transcoder.cpp", "rnd_basis.cpp" },
        .flags = &.{ "-DBASISD_SUPPORT_KTX2=1", "-DBASISD_SUPPORT_KTX2_ZSTD=1", "-fno-strict-aliasing", "-w" },
    });
    renderer.linkLibrary(basis);
    const texture_codec = b.createModule(.{
        .root_source_file = b.path("src/asset/texture.zig"),
        .target = target,
        .optimize = parser_optimize,
    });
    renderer.addImport("texture_codec", texture_codec);
    const font_baker = b.createModule(.{
        .root_source_file = b.path("src/font_baker.zig"),
        .target = target,
        .optimize = parser_optimize,
    });
    font_baker.addImport("build_features", features_module);
    renderer.addImport("font_baker", font_baker);
    addShaders(b, renderer, renderer_shaders, shaders_step);
    const shader_options = b.addOptions();
    var shader_names: [renderer_shaders.len][]const u8 = undefined;
    var shader_sources: [renderer_shaders.len][]const u8 = undefined;
    var shader_defines: [renderer_shaders.len][]const u8 = undefined;
    for (renderer_shaders, 0..) |shader, index| {
        shader_names[index] = shader.name;
        shader_sources[index] = b.pathFromRoot(shader.src);
        shader_defines[index] = if (shader.defines.len != 0) shader.defines[0] else "";
    }
    shader_options.addOption([]const []const u8, "names", &shader_names);
    shader_options.addOption([]const []const u8, "sources", &shader_sources);
    shader_options.addOption([]const []const u8, "defines", &shader_defines);
    shader_options.addOption([]const u8, "include_dir", b.pathFromRoot(shader_dir));
    renderer.addOptions("shader_sources", shader_options);
    renderer.addImport("build_features", features_module);
    if (fidelityfx) addFidelityFx(b, renderer, target, asset_optimize, vulkan_include, volk);

    const library = b.addLibrary(.{ .name = "limn", .root_module = renderer, .linkage = .static, .use_llvm = true });
    b.installArtifact(library);

    const docs_trim = b.addExecutable(.{
        .name = "docs_trim",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/docs_trim.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const emitted_docs = library.getEmittedDocs();
    const trim_docs = b.addRunArtifact(docs_trim);
    trim_docs.addFileArg(emitted_docs.path(b, "sources.tar"));
    const trimmed_sources = trim_docs.addOutputFileArg("sources.tar");
    trim_docs.addArgs(&.{ "limn", "texture_codec" });
    const docs_step = b.step("docs", "Generate API documentation in zig-out/docs");
    for ([_][]const u8{ "index.html", "main.js", "main.wasm" }) |file| {
        docs_step.dependOn(&b.addInstallFile(emitted_docs.path(b, file), b.fmt("docs/{s}", .{file})).step);
    }
    docs_step.dependOn(&b.addInstallFile(trimmed_sources, "docs/sources.tar").step);

    const check_step = b.step("check", "Compile the renderer, tests and examples without running them");
    const tests = b.addTest(.{ .root_module = renderer, .use_llvm = true });
    check_step.dependOn(&tests.step);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = texture_codec })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = font_baker })).step);

    const glfw = b.addTranslateC(.{
        .root_source_file = b.path("examples/glfw_native.h"),
        .target = target,
        .optimize = optimize,
    });
    glfw.addSystemIncludePath(vulkan_include);
    glfw.addSystemIncludePath(volk.path(""));
    const glfw_source = if (target.result.os.tag == .windows) (b.lazyDependency("glfw", .{}) orelse return) else null;
    if (glfw_source) |source| {
        glfw.addSystemIncludePath(source.path("include"));
    } else glfw.linkSystemLibrary("glfw", .{});
    const glfw_module = glfw.createModule();
    if (glfw_source) |source| {
        const files = [_][]const u8{ "context.c", "init.c", "input.c", "monitor.c", "platform.c", "vulkan.c", "window.c", "egl_context.c", "osmesa_context.c", "null_init.c", "null_monitor.c", "null_window.c", "null_joystick.c", "win32_init.c", "win32_joystick.c", "win32_module.c", "win32_monitor.c", "win32_thread.c", "win32_time.c", "win32_window.c", "wgl_context.c" };
        glfw_module.addIncludePath(source.path("include"));
        glfw_module.link_libc = true;
        glfw_module.addCSourceFiles(.{ .root = source.path("src"), .files = &files, .flags = &.{"-D_GLFW_WIN32"} });
        for ([_][]const u8{ "gdi32", "user32", "shell32" }) |system| glfw_module.linkSystemLibrary(system, .{});
    }
    const window_module = b.createModule(.{
        .root_source_file = b.path("examples/window.zig"),
        .target = target,
        .optimize = optimize,
    });
    window_module.addImport("limn", renderer);
    window_module.addImport("glfw", glfw_module);

    const canvas_scene = b.createModule(.{
        .root_source_file = b.path("examples/canvas_scene.zig"),
        .target = target,
        .optimize = optimize,
    });
    canvas_scene.addImport("limn", renderer);
    const verify_module = b.createModule(.{
        .root_source_file = b.path("src/verify.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = thread_sanitizer,
    });
    verify_module.addImport("limn", renderer);
    verify_module.addImport("canvas_scene", canvas_scene);
    addShaders(b, verify_module, verify_shaders, shaders_step);
    const headless = b.addExecutable(.{ .name = "scene", .root_module = verify_module, .use_llvm = true });
    b.installArtifact(headless);
    check_step.dependOn(&headless.step);
    const run_scene = b.addRunArtifact(headless);
    if (b.args) |args| run_scene.addArgs(args);
    b.step("scene", "Render the verification scene offscreen to a PNG and print timings").dependOn(&run_scene.step);

    var particles_example: ?*std.Build.Step.Compile = null;
    var animation_example: ?*std.Build.Step.Compile = null;
    var instancing_example: ?*std.Build.Step.Compile = null;
    var reflections_example: ?*std.Build.Step.Compile = null;
    var clouds_example: ?*std.Build.Step.Compile = null;
    var fluid_example: ?*std.Build.Step.Compile = null;
    var water_example: ?*std.Build.Step.Compile = null;
    var liquid_example: ?*std.Build.Step.Compile = null;
    var pathtrace_example: ?*std.Build.Step.Compile = null;
    var rtx_example: ?*std.Build.Step.Compile = null;
    const pictured = [_][]const u8{ "meadow", "materials", "lights", "decals", "text", "views", "post", "shader" };
    var pictured_examples: [pictured.len]?*std.Build.Step.Compile = @splat(null);
    for (examples) |example| {
        const module = b.createModule(.{
            .root_source_file = b.path(example.root),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = thread_sanitizer,
        });
        module.addImport("limn", renderer);
        if (example.windowed) {
            module.addImport("glfw", glfw_module);
            module.addImport("window", window_module);
        }
        addShaders(b, module, example.shaders, shaders_step);
        const exe = b.addExecutable(.{ .name = example.name, .root_module = module, .use_llvm = true });
        b.installArtifact(exe);
        check_step.dependOn(&exe.step);
        const run = b.addRunArtifact(exe);
        if (b.args) |args| run.addArgs(args);
        b.step(example.name, example.description).dependOn(&run.step);
        if (std.mem.eql(u8, example.name, "meadow")) b.step("run", example.description).dependOn(&run.step);
        if (std.mem.eql(u8, example.name, "particles")) particles_example = exe;
        if (std.mem.eql(u8, example.name, "animation")) animation_example = exe;
        if (std.mem.eql(u8, example.name, "instancing")) instancing_example = exe;
        if (std.mem.eql(u8, example.name, "reflections")) reflections_example = exe;
        if (std.mem.eql(u8, example.name, "clouds")) clouds_example = exe;
        if (std.mem.eql(u8, example.name, "fluid")) fluid_example = exe;
        if (std.mem.eql(u8, example.name, "water")) water_example = exe;
        if (std.mem.eql(u8, example.name, "liquid")) liquid_example = exe;
        if (std.mem.eql(u8, example.name, "pathtrace")) pathtrace_example = exe;
        if (std.mem.eql(u8, example.name, "rtx")) rtx_example = exe;
        for (pictured, &pictured_examples) |name, *slot| {
            if (std.mem.eql(u8, example.name, name)) slot.* = exe;
        }
    }

    const format_check = b.addSystemCommand(&.{
        "zig", "fmt", "--check", "build.zig", "src", "examples",
    });
    const verify_render = b.addRunArtifact(headless);
    verify_render.addArgs(&.{ "--validation", "--peel", "--sort-test", "--tube", "--tube-shadows", "--flare", "--width", "640", "--height", "360", "--frames", "48", "--motion", "--soak", "3", "--threads", "4", "--crowd", "120", "--render-scale", "0.67", "--refits", "100", "--overlay", "--lights", "--glass", "--flat-panes", "--pane-row", "group", "--relocate", "--gi-spacing", "0.3", "--gi-middle-ratio", "2", "--lod-fade", "0.25", "--clouds", "--morph-row", ".zig-cache/renderer-morph-row", "--colored-shadows", "--decals", "--ktx2-bc1", ".zig-cache/renderer-bc1.ktx2", "--ktx2-model", ".zig-cache/renderer-ktx2-model", "--cube-env", ".zig-cache/renderer-cube-env.ktx2", "--fog", "0.012", "--output" });
    _ = verify_render.addOutputFileArg("verify.png");
    verify_render.has_side_effects = true;
    const verify_views = b.addRunArtifact(headless);
    verify_views.has_side_effects = true;
    verify_views.addArgs(&.{ "--validation", "--width", "640", "--height", "360", "--frames", "24", "--motion", "--views", "--overlay", "--lights", "--custom-pass", "--material", "--instance-params", "--crowd", "40", "--crowd-group", "--meshlet-bounds", "--shadow-small", "2", "--skip-buried", "--shadow-lod-light", "--aerial", "0.004", "--bounce-lights", "64", "--mirror-panel", "--probe", "--probe-settle", "4", "--glass", "--lens-pane", "--layered-refraction", "--particles", "--decals", "--compress-images", "--bc7-test", "--shift-frame", "12", "--clouds", "--fluid", "--fluid-frame", ".zig-cache/renderer-fluid-frame.png", "--fluid-flipbook", ".zig-cache/renderer-fluid-flipbook.png", "--fluid-sharp", "--decal-count", "70", "--light-size", "0.12", "--half-reflections", "--text-fallback", "--lut", "warm", "--bumps", "--tints", "--sheen", "--aniso", "--morph", "--contact-shadows", "0.3", "--autofocus", "--stars", "--gi-coarse-interval", "3", "--stream", "24", "--stream-visible", "--ktx2", ".zig-cache/renderer-decal.ktx2", "--coat", "--coat-maps", "--transform-panel", "--wave", "--instances", "2000", "--gi-spacing", "0.9", "--reload-frame", "8", "--names", "--profile", "--sky-sweep", "--sky-spread", "4", "--grade", "--dof", "6", "--half-dof", "--dof-blades", "6", "--motion-blur", "0.5", "--pick", "200", "200", "--fail-frame", "5", "--oom", "40", "--gpu-oom", "45", "--cache", ".zig-cache/renderer-assets", "--output" });
    _ = verify_views.addOutputFileArg("verify_views.png");
    const verify_step = b.step("verify", "Check formatting, run tests and render the world with validation enabled");
    verify_step.dependOn(&format_check.step);
    verify_step.dependOn(test_step);
    verify_step.dependOn(&verify_render.step);
    verify_step.dependOn(&verify_views.step);
    const verify_particles = b.addRunArtifact(particles_example.?);
    verify_particles.has_side_effects = true;
    verify_particles.addArgs(&.{ "--frames", "90", "--screenshot" });
    _ = verify_particles.addOutputFileArg("verify_particles.png");

    verify_step.dependOn(&verify_particles.step);
    for ([_]*std.Build.Step.Compile{ animation_example.?, instancing_example.?, reflections_example.?, clouds_example.?, fluid_example.?, water_example.? }, [_][]const u8{ "verify_animation.png", "verify_instancing.png", "verify_reflections.png", "verify_clouds.png", "verify_fluid.png", "verify_water.png" }) |exe, name| {
        const run = b.addRunArtifact(exe);
        run.has_side_effects = true;
        run.addArgs(&.{ "--frames", "60", "--screenshot" });
        _ = run.addOutputFileArg(name);
        verify_step.dependOn(&run.step);
    }
    const verify_liquid = b.addRunArtifact(liquid_example.?);
    verify_liquid.has_side_effects = true;
    verify_liquid.addArgs(&.{ "--frames", "90", "--screenshot" });
    _ = verify_liquid.addOutputFileArg("verify_liquid.png");
    verify_step.dependOn(&verify_liquid.step);
    for (pictured, pictured_examples) |name, example| {
        const verify_example = b.addRunArtifact(example.?);
        verify_example.has_side_effects = true;
        verify_example.addArgs(&.{ "--frames", "60", "--screenshot" });
        _ = verify_example.addOutputFileArg(b.fmt("verify_{s}.png", .{name}));
        verify_step.dependOn(&verify_example.step);
    }
    const verify_compaction = b.addRunArtifact(headless);
    verify_compaction.has_side_effects = true;
    verify_compaction.addArgs(&.{ "--validation", "--width", "480", "--height", "270", "--frames", "8", "--compact-test", "--output" });
    _ = verify_compaction.addOutputFileArg("verify_compaction.png");
    verify_step.dependOn(&verify_compaction.step);
    const verify_coarse = b.addRunArtifact(headless);
    verify_coarse.has_side_effects = true;
    verify_coarse.addArgs(&.{ "--validation", "--width", "480", "--height", "270", "--frames", "8", "--coarse-test", "--coarse-near", "--geometry-distance", "500", "--geometry-coarse", "6", "--output" });
    _ = verify_coarse.addOutputFileArg("verify_coarse.png");
    verify_step.dependOn(&verify_coarse.step);
    for ([_][]const []const u8{ &.{}, &.{ "--path", "1" } }, [_][]const u8{ "verify_rtx.png", "verify_rtx_path.png" }) |extra, picture| {
        const verify_rtx = b.addRunArtifact(rtx_example.?);
        verify_rtx.has_side_effects = true;
        verify_rtx.addArgs(&.{ "--frames", "40" });
        verify_rtx.addArgs(extra);
        verify_rtx.addArg("--screenshot");
        _ = verify_rtx.addOutputFileArg(picture);
        verify_step.dependOn(&verify_rtx.step);
    }
    for ([_][]const []const u8{ &.{}, &.{ "--software", "1" } }, [_][]const u8{ "verify_pathtrace.png", "verify_pathtrace_software.png" }) |extra, picture| {
        const verify_pathtrace = b.addRunArtifact(pathtrace_example.?);
        verify_pathtrace.has_side_effects = true;
        verify_pathtrace.addArgs(&.{ "--frames", "60" });
        verify_pathtrace.addArgs(extra);
        verify_pathtrace.addArg("--screenshot");
        _ = verify_pathtrace.addOutputFileArg(picture);
        verify_step.dependOn(&verify_pathtrace.step);
    }
    const verify_dive = b.addRunArtifact(water_example.?);
    verify_dive.has_side_effects = true;
    verify_dive.addArgs(&.{ "--dive", "1", "--frames", "60", "--screenshot" });
    _ = verify_dive.addOutputFileArg("verify_dive.png");
    verify_step.dependOn(&verify_dive.step);
    const verify_storm = b.addRunArtifact(clouds_example.?);
    verify_storm.has_side_effects = true;
    verify_storm.addArgs(&.{ "--storm", "1", "--frames", "60", "--screenshot" });
    _ = verify_storm.addOutputFileArg("verify_storm.png");
    verify_step.dependOn(&verify_storm.step);
    const verify_raw_stream = b.addRunArtifact(headless);
    verify_raw_stream.has_side_effects = true;
    verify_raw_stream.addArgs(&.{ "--validation", "--width", "480", "--height", "270", "--frames", "12", "--no-compress", "--stream", "64", "--output" });
    _ = verify_raw_stream.addOutputFileArg("verify_raw_stream.png");
    verify_step.dependOn(&verify_raw_stream.step);
    const verify_cluster_lods = b.addRunArtifact(headless);
    verify_cluster_lods.has_side_effects = true;
    verify_cluster_lods.addArgs(&.{ "--validation", "--width", "480", "--height", "270", "--frames", "48", "--cache", ".zig-cache/renderer-assets", "--cluster-lods", "--terrain", "--lod-fade", "0.25", "--output" });
    _ = verify_cluster_lods.addOutputFileArg("verify_cluster_lods.png");
    verify_step.dependOn(&verify_cluster_lods.step);
    const verify_receiver_culling = b.addRunArtifact(headless);
    verify_receiver_culling.has_side_effects = true;
    verify_receiver_culling.addArgs(&.{ "--validation", "--width", "480", "--height", "270", "--frames", "48", "--cache", ".zig-cache/renderer-assets", "--no-cascade-stagger", "--output" });
    _ = verify_receiver_culling.addOutputFileArg("verify_receiver_culling.png");
    verify_step.dependOn(&verify_receiver_culling.step);
    const verify_geometry_streaming = b.addRunArtifact(headless);
    verify_geometry_streaming.has_side_effects = true;
    verify_geometry_streaming.addArgs(&.{ "--validation", "--width", "480", "--height", "270", "--frames", "40", "--cache", ".zig-cache/renderer-assets", "--terrain", "--geometry-distance", "20", "--camera", "62", "4", "0", "160", "-4", "0", "--teleport", "16", "-9", "1.6", "0", "4", "1.6", "0", "--output" });
    _ = verify_geometry_streaming.addOutputFileArg("verify_geometry_streaming.png");
    verify_step.dependOn(&verify_geometry_streaming.step);
    const verify_cache_stream = b.addRunArtifact(headless);
    verify_cache_stream.has_side_effects = true;
    verify_cache_stream.addArgs(&.{ "--validation", "--width", "480", "--height", "270", "--frames", "24", "--cache", ".zig-cache/renderer-assets", "--stream", "64", "--stream-from-cache", "--stream-skip-occluded", "--output" });
    _ = verify_cache_stream.addOutputFileArg("verify_cache_stream.png");
    verify_step.dependOn(&verify_cache_stream.step);
}

const ffx_root = "src/third_party/ffx_sdk";
/// An effect of the FidelityFX SDK: each pass is a compute shader compiled
/// once for every combination of `options`.
const FfxEffect = struct {
    /// The directory of its shaders.
    name: []const u8,
    /// What its options' names start with.
    prefix: []const u8,
    /// The first is the lowest bit of a combination's number.
    options: []const []const u8,
    fixed: []const []const u8 = &.{},
    passes: []const []const u8,
};
const ffx_upscaler_options = [_][]const u8{
    "OPTION_REPROJECT_USE_LANCZOS_TYPE",
    "OPTION_HDR_COLOR_INPUT",
    "OPTION_LOW_RESOLUTION_MOTION_VECTORS",
    "OPTION_JITTERED_MOTION_VECTORS",
    "OPTION_INVERTED_DEPTH",
    "OPTION_APPLY_SHARPENING",
};
const ffx_sampler_options = [_][]const u8{
    "OPTION_UPSAMPLE_SAMPLERS_USE_DATA_HALF=0",
    "OPTION_ACCUMULATE_SAMPLERS_USE_DATA_HALF=0",
    "OPTION_REPROJECT_SAMPLERS_USE_DATA_HALF=1",
    "OPTION_POSTPROCESSLOCKSTATUS_SAMPLERS_USE_DATA_HALF=0",
    "OPTION_UPSAMPLE_USE_LANCZOS_TYPE=2",
};
const ffx_effects = [_]FfxEffect{
    .{ .name = "fsr2", .prefix = "FFX_FSR2", .options = &ffx_upscaler_options, .fixed = &ffx_sampler_options, .passes = &.{
        "ffx_fsr2_accumulate_pass",                 "ffx_fsr2_autogen_reactive_pass", "ffx_fsr2_compute_luminance_pyramid_pass",
        "ffx_fsr2_depth_clip_pass",                 "ffx_fsr2_lock_pass",             "ffx_fsr2_rcas_pass",
        "ffx_fsr2_reconstruct_previous_depth_pass", "ffx_fsr2_tcr_autogen_pass",
    } },
    .{ .name = "fsr3upscaler", .prefix = "FFX_FSR3UPSCALER", .options = &ffx_upscaler_options, .fixed = &ffx_sampler_options, .passes = &.{
        "ffx_fsr3upscaler_accumulate_pass",             "ffx_fsr3upscaler_autogen_reactive_pass", "ffx_fsr3upscaler_debug_view_pass",
        "ffx_fsr3upscaler_luma_instability_pass",       "ffx_fsr3upscaler_luma_pyramid_pass",     "ffx_fsr3upscaler_prepare_inputs_pass",
        "ffx_fsr3upscaler_prepare_reactivity_pass",     "ffx_fsr3upscaler_rcas_pass",             "ffx_fsr3upscaler_shading_change_pass",
        "ffx_fsr3upscaler_shading_change_pyramid_pass",
    } },
    .{
        .name = "frameinterpolation",
        .prefix = "FFX_FRAMEINTERPOLATION",
        .options = &.{ "OPTION_LOW_RES_MOTION_VECTORS", "OPTION_JITTER_MOTION_VECTORS", "OPTION_INVERTED_DEPTH" },
        .fixed = &ffx_sampler_options,
        .passes = &.{
            "ffx_frameinterpolation_compute_game_vector_field_inpainting_pyramid_pass",
            "ffx_frameinterpolation_compute_inpainting_pyramid_pass",
            "ffx_frameinterpolation_debug_view_pass",
            "ffx_frameinterpolation_disocclusion_mask_pass",
            "ffx_frameinterpolation_game_motion_vector_field_pass",
            "ffx_frameinterpolation_inpainting_pass",
            "ffx_frameinterpolation_optical_flow_vector_field_pass",
            "ffx_frameinterpolation_pass",
            "ffx_frameinterpolation_reconstruct_and_dilate_pass",
            "ffx_frameinterpolation_reconstruct_previous_depth_pass",
            "ffx_frameinterpolation_setup_pass",
        },
    },
    .{ .name = "opticalflow", .prefix = "FFX_OPTICALFLOW", .options = &.{"OPTION_HDR_COLOR_INPUT"}, .passes = &.{
        "ffx_opticalflow_compute_luminance_pyramid_pass",
        "ffx_opticalflow_compute_optical_flow_advanced_pass_v5",
        "ffx_opticalflow_compute_scd_divergence_pass",
        "ffx_opticalflow_filter_optical_flow_pass_v5",
        "ffx_opticalflow_generate_scd_histogram_pass",
        "ffx_opticalflow_prepare_luma_pass",
        "ffx_opticalflow_scale_optical_flow_advanced_pass_v5",
    } },
};

/// Builds the FidelityFX SDK and the renderer's wrapper round it, and links
/// `renderer` with them. Shader permutations are compiled with glslc and
/// packed into the SDK's headers by src/ffx_permutations.zig.
fn addFidelityFx(
    b: *std.Build,
    renderer: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    vulkan_include: std.Build.LazyPath,
    volk: *std.Build.Dependency,
) void {
    const library = b.addLibrary(.{
        .name = "renderer_fidelityfx",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libcpp = true }),
    });
    const generator = b.addExecutable(.{
        .name = "ffx_permutations",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ffx_permutations.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const gpu = b.path(ffx_root ++ "/include/FidelityFX/gpu");
    for (ffx_effects) |effect| {
        const option_names = b.allocator.alloc([]const u8, effect.options.len) catch @panic("OOM");
        for (effect.options, option_names) |option, *name| name.* = b.fmt("{s}_{s}", .{ effect.prefix, option });
        for (effect.passes) |pass| {
            const generate = b.addRunArtifact(generator);
            const headers = generate.addOutputDirectoryArg(pass);
            generate.addArg(pass);
            generate.addArg(std.mem.join(b.allocator, ",", option_names) catch @panic("OOM"));
            for (0..@as(usize, 1) << @intCast(effect.options.len)) |combination| {
                const compile = b.addSystemCommand(&.{ "glslc", "-fshader-stage=compute", "--target-env=vulkan1.2", "-Os", "-g", "-DFFX_GLSL=1", "-DFFX_GPU=1", "-DFFX_HALF=0" });
                for (effect.fixed) |fixed| compile.addArg(b.fmt("-D{s}_{s}", .{ effect.prefix, fixed }));
                for (option_names, 0..) |name, bit| compile.addArg(b.fmt("-D{s}={d}", .{ name, (combination >> @intCast(bit)) & 1 }));
                compile.addPrefixedDirectoryArg("-I", gpu);
                compile.addPrefixedDirectoryArg("-I", gpu.path(b, effect.name));
                compile.addArg("-MD");
                compile.addArg("-MF");
                _ = compile.addDepFileOutputArg(b.fmt("{s}_{d}.d", .{ pass, combination }));
                compile.addFileArg(b.path(b.fmt("{s}/src/backends/vk/shaders/{s}/{s}.glsl", .{ ffx_root, effect.name, pass })));
                compile.addArg("-o");
                generate.addFileArg(compile.addOutputFileArg(b.fmt("{s}_{d}.spv", .{ pass, combination })));
            }
            library.root_module.addIncludePath(headers);
        }
    }
    for ([_][]const u8{ "include", "src", "src/shared", "src/components", "src/backends/shared" }) |directory| {
        library.root_module.addIncludePath(b.path(b.fmt("{s}/{s}", .{ ffx_root, directory })));
    }
    library.root_module.addIncludePath(vulkan_include);
    library.root_module.addIncludePath(volk.path(""));
    const flags = [_][]const u8{
        "-std=c++17",                                "-w",                                         "-fno-strict-aliasing",
        "-include",                                  b.pathFromRoot(ffx_root ++ "/limn_compat.h"), "-DFFX_FSR2",
        "-DFFX_FI",                                  "-DFFX_OF",                                   "-DFFX_FSR3UPSCALER",
        "-DFFX_SDK_DEFAULT_CONTEXT_SIZE=(1024*256)", "-fmax-type-align=4",
    };
    library.root_module.addCSourceFiles(.{
        .root = b.path(ffx_root),
        .files = &.{
            "src/backends/vk/ffx_vk.cpp",
            "src/components/fsr2/ffx_fsr2.cpp",
            "src/components/fsr3upscaler/ffx_fsr3upscaler.cpp",
            "src/components/frameinterpolation/ffx_frameinterpolation.cpp",
            "src/components/opticalflow/ffx_opticalflow.cpp",
            "src/shared/ffx_assert.cpp",
            "src/shared/ffx_message.cpp",
            "src/shared/ffx_object_management.cpp",
            "src/shared/ffx_breadcrumbs_list.cpp",
            "src/backends/shared/ffx_shader_blobs.cpp",
            "src/backends/shared/blob_accessors/ffx_fsr2_shaderblobs.cpp",
            "src/backends/shared/blob_accessors/ffx_fsr3upscaler_shaderblobs.cpp",
            "src/backends/shared/blob_accessors/ffx_frameinterpolation_shaderblobs.cpp",
            "src/backends/shared/blob_accessors/ffx_opticalflow_shaderblobs.cpp",
        },
        .flags = &flags,
    });
    library.root_module.addCSourceFile(.{ .file = b.path("src/render/ffx/limn_ffx.cpp"), .flags = &flags });
    renderer.linkLibrary(library);
}

fn volkModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    vulkan_include: std.Build.LazyPath,
    /// The loader's source: `volk.c` and `volk.h` at its root.
    source: *std.Build.Dependency,
) *std.Build.Module {
    const volk = b.addTranslateC(.{
        .root_source_file = b.path("src/rhi/volk.h"),
        .target = target,
        .optimize = optimize,
    });
    volk.addSystemIncludePath(vulkan_include);
    volk.addSystemIncludePath(source.path(""));
    const module = volk.createModule();
    module.addIncludePath(vulkan_include);
    module.addIncludePath(source.path(""));
    module.addCSourceFile(.{
        .file = source.path("volk.c"),
        .flags = if (target.result.os.tag == .windows) &.{"-DVK_USE_PLATFORM_WIN32_KHR"} else &.{},
    });
    module.link_libc = true;
    if (target.result.os.tag == .linux) module.linkSystemLibrary("dl", .{});
    return module;
}

/// Compiles each shader with glslc and exposes the SPIR-V to `module` as an
/// anonymous import. `#include`d files are tracked through a depfile, so
/// editing a shared header rebuilds exactly the shaders that use it.
fn addShaders(b: *std.Build, module: *std.Build.Module, shaders: []const Shader, shaders_step: *std.Build.Step) void {
    for (shaders) |shader| {
        const command = b.addSystemCommand(&.{ "glslc", "--target-env=vulkan1.3", "-O", "-g" });
        command.addPrefixedDirectoryArg("-I", b.path(shader_dir));
        for (shader.defines) |define| command.addArg(b.fmt("-D{s}", .{define}));
        command.addArg("-MD");
        command.addArg("-MF");
        _ = command.addDepFileOutputArg(b.fmt("{s}.d", .{shader.name}));
        command.addFileArg(b.path(shader.src));
        command.addArg("-o");
        const output = command.addOutputFileArg(shader.name);
        module.addAnonymousImport(shader.name, .{ .root_source_file = output });
        shaders_step.dependOn(&command.step);
    }
}
