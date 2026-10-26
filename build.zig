const std = @import("std");
const shader_gen = @import("src/render/core/shader_gen.zig");

const manifest = @import("src/render/shaders/manifest.zig");
const Shader = manifest.Shader;

/// Arguments every Slang shader is compiled with; `shaders.reload` uses the
/// same ones.
const slang_arguments = [_][]const u8{ "-profile", "spirv_1_5", "-target", "spirv", "-fvk-use-scalar-layout", "-matrix-layout-column-major", "-O2", "-warnings-disable", "39001,41012,41035" };

const shader_dir = "src/render/shaders";

/// What `zig build cross` builds for; Android gets APKs.
const cross_targets = [_][]const u8{ "x86_64-linux-gnu", "aarch64-linux-gnu", "x86_64-windows-gnu", "x86_64-macos", "aarch64-macos", "aarch64-linux-android" };

/// A program the build runs on the machine doing the build: one the package
/// manager fetched or built, or one found on PATH.
const Tool = union(enum) {
    path: std.Build.LazyPath,
    system: []const u8,

    /// A run step that starts the tool, named for the work it does.
    fn command(self: Tool, b: *std.Build, label: []const u8) *std.Build.Step.Run {
        return switch (self) {
            .path => |path| run: {
                const run = std.Build.Step.Run.create(b, b.fmt("compile {s}", .{label}));
                run.addFileArg(path);
                break :run run;
            },
            .system => |name| b.addSystemCommand(&.{name}),
        };
    }
};

/// The prebuilt Slang compiler for the build machine, or null while it is
/// being fetched. Hosts Slang ships no build for use `slangc` on PATH.
fn slangCompiler(b: *std.Build) ?Tool {
    const host = b.graph.host.result;
    const package: []const u8 = switch (host.os.tag) {
        .linux => switch (host.cpu.arch) {
            .x86_64 => "slang_linux_x86_64",
            .aarch64 => "slang_linux_aarch64",
            else => return .{ .system = "slangc" },
        },
        .macos => switch (host.cpu.arch) {
            .x86_64 => "slang_macos_x86_64",
            .aarch64 => "slang_macos_aarch64",
            else => return .{ .system = "slangc" },
        },
        .windows => switch (host.cpu.arch) {
            .x86_64 => "slang_windows_x86_64",
            .aarch64 => "slang_windows_aarch64",
            else => return .{ .system = "slangc" },
        },
        else => return .{ .system = "slangc" },
    };
    const slang = b.lazyDependency(package, .{}) orelse return null;
    return .{ .path = slang.path(if (host.os.tag == .windows) "bin/slangc.exe" else "bin/slangc") };
}

/// glslang's command-line compiler built from source for the build machine,
/// without the HLSL front end or SPIR-V optimizer; null while it is being
/// fetched.
fn glslangCompiler(b: *std.Build) ?Tool {
    const source = b.lazyDependency("glslang", .{}) orelse return null;
    const module = b.createModule(.{ .target = b.graph.host, .optimize = .ReleaseFast, .link_libcpp = true });
    const generated = b.addWriteFiles();
    _ = generated.add("glslang/build_info.h",
        \\#pragma once
        \\#define GLSLANG_VERSION_MAJOR 16
        \\#define GLSLANG_VERSION_MINOR 4
        \\#define GLSLANG_VERSION_PATCH 0
        \\#define GLSLANG_VERSION_FLAVOR ""
        \\#define GLSLANG_VERSION_GREATER_THAN(major, minor, patch) ((GLSLANG_VERSION_MAJOR) > (major) || ((major) == GLSLANG_VERSION_MAJOR && ((GLSLANG_VERSION_MINOR) > (minor) || ((minor) == GLSLANG_VERSION_MINOR && (GLSLANG_VERSION_PATCH) > (patch)))))
        \\#define GLSLANG_VERSION_GREATER_OR_EQUAL_TO(major, minor, patch) ((GLSLANG_VERSION_MAJOR) > (major) || ((major) == GLSLANG_VERSION_MAJOR && ((GLSLANG_VERSION_MINOR) > (minor) || ((minor) == GLSLANG_VERSION_MINOR && (GLSLANG_VERSION_PATCH >= (patch))))))
        \\#define GLSLANG_VERSION_LESS_THAN(major, minor, patch) ((GLSLANG_VERSION_MAJOR) < (major) || ((major) == GLSLANG_VERSION_MAJOR && ((GLSLANG_VERSION_MINOR) < (minor) || ((minor) == GLSLANG_VERSION_MINOR && (GLSLANG_VERSION_PATCH) < (patch)))))
        \\#define GLSLANG_VERSION_LESS_OR_EQUAL_TO(major, minor, patch) ((GLSLANG_VERSION_MAJOR) < (major) || ((major) == GLSLANG_VERSION_MAJOR && ((GLSLANG_VERSION_MINOR) < (minor) || ((minor) == GLSLANG_VERSION_MINOR && (GLSLANG_VERSION_PATCH <= (patch))))))
        \\
    );
    _ = generated.add("glslang/glsl_intrinsic_header.h",
        \\#pragma once
        \\#include <string>
        \\std::string getIntrinsic(const char* const*, int) { return ""; }
        \\
    );
    module.addIncludePath(generated.getDirectory());
    module.addIncludePath(source.path(""));
    module.addIncludePath(source.path("External"));
    const windows = b.graph.host.result.os.tag == .windows;
    module.addCSourceFiles(.{
        .root = source.path(""),
        .files = &(glslang_sources ++ [_][]const u8{if (windows) "glslang/OSDependent/Windows/ossource.cpp" else "glslang/OSDependent/Unix/ossource.cpp"}),
        .flags = &.{ "-std=c++17", "-w", "-DENABLE_SPIRV", "-DENABLE_OPT=0", "-fno-exceptions", "-fno-rtti" },
    });
    const exe = b.addExecutable(.{ .name = "glslang", .root_module = module });
    return .{ .path = exe.getEmittedBin() };
}

const glslang_sources = [_][]const u8{
    "glslang/GenericCodeGen/CodeGen.cpp",
    "glslang/GenericCodeGen/Link.cpp",
    "glslang/MachineIndependent/glslang_tab.cpp",
    "glslang/MachineIndependent/attribute.cpp",
    "glslang/MachineIndependent/Constant.cpp",
    "glslang/MachineIndependent/iomapper.cpp",
    "glslang/MachineIndependent/InfoSink.cpp",
    "glslang/MachineIndependent/Initialize.cpp",
    "glslang/MachineIndependent/IntermTraverse.cpp",
    "glslang/MachineIndependent/Intermediate.cpp",
    "glslang/MachineIndependent/ParseContextBase.cpp",
    "glslang/MachineIndependent/ParseHelper.cpp",
    "glslang/MachineIndependent/PoolAlloc.cpp",
    "glslang/MachineIndependent/RemoveTree.cpp",
    "glslang/MachineIndependent/Scan.cpp",
    "glslang/MachineIndependent/ShaderLang.cpp",
    "glslang/MachineIndependent/SpirvIntrinsics.cpp",
    "glslang/MachineIndependent/SymbolTable.cpp",
    "glslang/MachineIndependent/Versions.cpp",
    "glslang/MachineIndependent/intermOut.cpp",
    "glslang/MachineIndependent/limits.cpp",
    "glslang/MachineIndependent/linkValidate.cpp",
    "glslang/MachineIndependent/parseConst.cpp",
    "glslang/MachineIndependent/reflection.cpp",
    "glslang/MachineIndependent/preprocessor/Pp.cpp",
    "glslang/MachineIndependent/preprocessor/PpAtom.cpp",
    "glslang/MachineIndependent/preprocessor/PpContext.cpp",
    "glslang/MachineIndependent/preprocessor/PpScanner.cpp",
    "glslang/MachineIndependent/preprocessor/PpTokens.cpp",
    "glslang/MachineIndependent/propagateNoContraction.cpp",
    "glslang/ResourceLimits/ResourceLimits.cpp",
    "SPIRV/GlslangToSpv.cpp",
    "SPIRV/InReadableOrder.cpp",
    "SPIRV/Logger.cpp",
    "SPIRV/SpvBuilder.cpp",
    "SPIRV/SpvPostProcess.cpp",
    "SPIRV/doc.cpp",
    "SPIRV/SpvTools.cpp",
    "SPIRV/disassemble.cpp",
    "StandAlone/StandAlone.cpp",
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
            .{ .src = "examples/triangle/triangle.slang", .name = "triangle.vert.spv", .entry = "vertexMain", .stage = "vertex" },
            .{ .src = "examples/triangle/triangle.slang", .name = "triangle.frag.spv", .entry = "fragmentMain", .stage = "fragment" },
        },
    },
    .{
        .name = "canvas",
        .root = "examples/canvas.zig",
        .description = "A 2D-only application: shapes, sprites and text",
        .windowed = true,
        .shaders = &.{
            .{ .src = "examples/shaders/scanlines.slang", .name = "scanlines.frag.spv", .entry = "fragmentMain", .stage = "fragment" },
        },
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
        .name = "isometric",
        .root = "examples/isometric.zig",
        .description = "A terraced diorama through an orthographic camera, with markers drawn into the scene",
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
        .shaders = &.{
            .{ .src = "examples/shaders/lava.slang", .name = "lava.frag.spv", .entry = "fragmentMain", .stage = "fragment" },
            .{ .src = "examples/shaders/lava.slang", .name = "lava_plain.frag.spv", .defines = &.{"PLAIN"}, .entry = "fragmentMain", .stage = "fragment" },
        },
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
        .name = "lightweight",
        .root = "examples/lightweight.zig",
        .description = "Simple 3D at its smallest cost, with a HUD of what each frame records",
        .windowed = true,
    },
    .{
        .name = "passes",
        .root = "examples/passes.zig",
        .description = "The application's own compute, geometry, tone curve and ink lines inside a lit scene",
        .windowed = true,
        .shaders = &.{
            .{ .src = "examples/shaders/passes.slang", .name = "passes_move.comp.spv", .entry = "moveMain", .stage = "compute" },
            .{ .src = "examples/shaders/passes.slang", .name = "passes_fullscreen.vert.spv", .entry = "fullscreenMain", .stage = "vertex" },
            .{ .src = "examples/shaders/passes.slang", .name = "passes_blob.frag.spv", .entry = "orbsMain", .stage = "fragment" },
            .{ .src = "examples/shaders/passes.slang", .name = "passes_copy.frag.spv", .entry = "copyMain", .stage = "fragment" },
            .{ .src = "examples/shaders/passes.slang", .name = "passes_curve.frag.spv", .entry = "curveMain", .stage = "fragment" },
            .{ .src = "examples/shaders/passes.slang", .name = "passes_outline.frag.spv", .entry = "outlineMain", .stage = "fragment" },
            .{ .src = "examples/shaders/passes.slang", .name = "passes_shadow.frag.spv", .entry = "shadowMain", .stage = "fragment" },
            .{ .src = "examples/shaders/passes.slang", .name = "passes_light_shadow.frag.spv", .entry = "lightShadowMain", .stage = "fragment" },
        },
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

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const thread_sanitizer = b.option(bool, "tsan", "Build with the thread sanitizer, with -Dtarget=x86_64-linux-gnu; NVIDIA drivers make threads it cannot see, so run `checks` on Mesa (VK_DRIVER_FILES=.../lvp_icd.x86_64.json)") orelse false;
    const android = target.result.abi.isAndroid();
    if (android and !useAndroidNdk(b, target)) return;
    const vulkan_headers = b.dependency("vulkan_headers", .{});
    const vulkan_include = vulkan_headers.path("include");
    const vulkan = b.lazyDependency("vulkan", .{
        .registry = vulkan_headers.path("registry/vk.xml"),
    }) orelse return;

    const system_tools = b.option(bool, "system_tools", "Run slangc and glslangValidator from PATH instead of fetched builds (default: false)") orelse false;
    const slangc: Tool = if (system_tools) .{ .system = "slangc" } else slangCompiler(b) orelse return;
    const native_target = target.result.os.tag == b.graph.host.result.os.tag and target.result.cpu.arch == b.graph.host.result.cpu.arch and target.result.abi == b.graph.host.result.abi;
    const asset_optimize: std.builtin.OptimizeMode = if (optimize == .Debug) .ReleaseFast else optimize;
    const validate_input = b.option(bool, "validate_input", "Check asset files before trusting them, and in Debug keep safety checks in the texture and font parsers (default: true)") orelse true;
    const parser_optimize: std.builtin.OptimizeMode = if (optimize == .Debug and validate_input) .ReleaseSafe else asset_optimize;
    const fidelityfx = b.option(bool, "fidelityfx", "Build AMD's FidelityFX SDK in, for FSR 2 and FSR 3 upscaling (default: true, false with -Dtsan)") orelse !thread_sanitizer;
    const features = b.addOptions();
    features.addOption(bool, "fidelityfx", fidelityfx);
    const dlss_sdk = b.option([]const u8, "dlss_sdk", "Where NVIDIA's DLSS SDK is (default: dlss_sdk, which `zig build dlss-sdk` fetches)") orelse b.pathFromRoot(dlss_sdk_default);
    const dlss_found = if (b.build_root.handle.access(b.graph.io, b.pathResolve(&.{ dlss_sdk, "include", "nvsdk_ngx.h" }), .{})) |_| true else |_| false;
    const dlss = b.option(bool, "dlss", "Build NVIDIA DLSS upscaling and ray reconstruction in (default: true where the SDK is found)") orelse (dlss_found and native_target and dlssSupported(target) and !thread_sanitizer);
    const nixos = if (b.build_root.handle.access(b.graph.io, nixos_drivers, .{})) |_| true else |_| false;
    if (dlss and !dlss_found) std.debug.panic("no DLSS SDK at {s}; run `zig build dlss-sdk` or pass -Ddlss_sdk", .{dlss_sdk});
    features.addOption(bool, "dlss", dlss);
    features.addOption([:0]const u8, "dlss_libraries", if (dlss) b.allocator.dupeZ(u8, b.pathResolve(&.{ dlss_sdk, dlssLibraries(target), "rel" })) catch @panic("OOM") else "");
    const fetch_dlss = b.addSystemCommand(&.{ "git", "clone", "--depth", "1", "--branch", dlss_sdk_version, "--filter=blob:none", "--sparse", "https://github.com/NVIDIA/DLSS", b.pathFromRoot(dlss_sdk_default) });
    const trim_dlss = b.addSystemCommand(&.{ "git", "-C", b.pathFromRoot(dlss_sdk_default), "sparse-checkout", "set", "include", dlssLibraries(target) });
    trim_dlss.step.dependOn(&fetch_dlss.step);
    b.step("dlss-sdk", "Fetch NVIDIA's DLSS SDK into dlss_sdk, under NVIDIA's license; builds after it have DLSS").dependOn(&trim_dlss.step);
    features.addOption(bool, "dlss_logging", b.option(bool, "dlss_logging", "Let DLSS write its log (default: false)") orelse false);
    const nrd_sdk = b.option([]const u8, "nrd_sdk", "Where NVIDIA's NRD SDK is, built (default: nrd_sdk, which `zig build nrd-sdk` fetches and builds)") orelse b.pathFromRoot(nrd_sdk_default);
    const nrd_found = if (b.build_root.handle.access(b.graph.io, b.pathResolve(&.{ nrd_sdk, "_Bin", "libNRD.a" }), .{})) |_| true else |_| false;
    const nrd = b.option(bool, "nrd", "Build NVIDIA's NRD denoiser in, for path tracing (default: true where the SDK is found)") orelse (nrd_found and native_target and !thread_sanitizer);
    if (nrd and !nrd_found) std.debug.panic("no built NRD SDK at {s}; run `zig build nrd-sdk` or pass -Dnrd_sdk", .{nrd_sdk});
    features.addOption(bool, "nrd", nrd);
    const fetch_nrd = b.addSystemCommand(&.{ "git", "clone", "--depth", "1", "--branch", nrd_sdk_version, "--recurse-submodules", "--shallow-submodules", "https://github.com/NVIDIA-RTX/NRD", b.pathFromRoot(nrd_sdk_default) });
    const configure_nrd = b.addSystemCommand(&.{
        "cmake",                         "-S",                                         b.pathFromRoot(nrd_sdk_default),
        "-B",                            b.pathFromRoot(nrd_sdk_default ++ "/_Build"), "-DCMAKE_BUILD_TYPE=Release",
        "-DNRD_STATIC_LIBRARY=ON",       "-DNRD_EMBEDS_SPIRV_SHADERS=ON",              "-DNRD_EMBEDS_DXIL_SHADERS=OFF",
        "-DNRD_EMBEDS_DXBC_SHADERS=OFF", "-DNRD_NORMAL_ENCODING=4",                    "-DNRD_ROUGHNESS_ENCODING=1",
    });
    if (b.findProgram(&.{"dxc"}, &.{})) |compiler| configure_nrd.addArg(b.fmt("-DNRD_DXC_CUSTOM_PATH={s}", .{compiler})) else |_| {}
    const patch_nrd = b.addSystemCommand(&.{ "sed", "-i", "s/        --allResourcesBound$/        --allResourcesBound\n        -X -fspv-use-unknown-image-format/", b.pathFromRoot(nrd_sdk_default ++ "/CMakeLists.txt") });
    patch_nrd.step.dependOn(&fetch_nrd.step);
    configure_nrd.step.dependOn(&patch_nrd.step);
    const build_nrd = b.addSystemCommand(&.{ "cmake", "--build", b.pathFromRoot(nrd_sdk_default ++ "/_Build"), "-j", "8" });
    build_nrd.step.dependOn(&configure_nrd.step);
    b.step("nrd-sdk", "Fetch NVIDIA's NRD SDK into nrd_sdk, under NVIDIA's license, and build it (needs cmake, a C++ compiler and dxc); builds after it have NRD").dependOn(&build_nrd.step);
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
    simplifier.root_module.addCSourceFiles(.{
        .root = zmesh.path("libs/meshoptimizer"),
        .files = &.{ "vertexcodec.cpp", "indexcodec.cpp", "vertexfilter.cpp" },
        .flags = &.{ "-fno-exceptions", "-fno-rtti" },
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
    const generated_shaders = b.addWriteFiles();
    _ = generated_shaders.add("frame_constants.slang", shader_gen.frame_slang);
    for (shader_gen.push_files) |file| _ = generated_shaders.add(file.name, file.text);
    const generated_dir = generated_shaders.getDirectory();
    const spirv_readonly = b.addExecutable(.{
        .name = "spirv_readonly",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/render/core/spirv_readonly.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    addShaders(b, renderer, manifest.renderer, shaders_step, generated_dir, spirv_readonly, slangc);
    const shader_reload = b.option(bool, "shader_reload", "Keep the shader source paths in the library for `shaders.reload` (default: Debug only)") orelse (optimize == .Debug);
    const shader_options = b.addOptions();
    var shader_names: [manifest.renderer.len][]const u8 = undefined;
    var shader_sources: [manifest.renderer.len][]const u8 = undefined;
    var shader_defines: [manifest.renderer.len][]const u8 = undefined;
    var shader_entries: [manifest.renderer.len][]const u8 = undefined;
    var shader_stages: [manifest.renderer.len][]const u8 = undefined;
    var shader_read_only: [manifest.renderer.len]bool = undefined;
    for (manifest.renderer, 0..) |shader, index| {
        shader_names[index] = shader.name;
        shader_sources[index] = if (shader_reload) b.pathFromRoot(shader.src) else "";
        shader_defines[index] = "";
        shader_entries[index] = shader.entry;
        shader_stages[index] = shader.stage;
        shader_read_only[index] = !shader.writable_reads;
        for (shader.defines) |define| shader_defines[index] = b.fmt("{s} -D{s}", .{ shader_defines[index], define });
    }
    shader_options.addOption([]const []const u8, "names", &shader_names);
    shader_options.addOption([]const []const u8, "sources", &shader_sources);
    shader_options.addOption([]const []const u8, "defines", &shader_defines);
    shader_options.addOption([]const []const u8, "entries", &shader_entries);
    shader_options.addOption([]const []const u8, "stages", &shader_stages);
    shader_options.addOption([]const bool, "read_only", &shader_read_only);
    shader_options.addOption([]const []const u8, "slang_arguments", &slang_arguments);
    shader_options.addOption([]const u8, "include_dir", if (shader_reload) b.pathFromRoot(shader_dir) else "");
    if (shader_reload) shader_options.addOptionPath("generated_dir", generated_dir) else shader_options.addOption([]const u8, "generated_dir", "");
    shader_options.addOption(bool, "reload", shader_reload);
    switch (slangc) {
        .path => |path| shader_options.addOptionPath("slangc", path),
        .system => |name| shader_options.addOption([]const u8, "slangc", name),
    }
    renderer.addOptions("shader_sources", shader_options);
    renderer.addImport("build_features", features_module);
    if (fidelityfx) addFidelityFx(b, renderer, target, asset_optimize, vulkan_include, volk, if (system_tools) .{ .system = "glslangValidator" } else glslangCompiler(b) orelse return);
    if (dlss) addDlss(b, renderer, target, asset_optimize, vulkan_include, dlss_sdk);
    if (nrd) addNrd(b, renderer, target, asset_optimize, vulkan_include, nrd_sdk);

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

    const glfw_module = if (android) b.createModule(.{ .root_source_file = b.path("examples/android/glfw.zig"), .target = target, .optimize = optimize }) else glfw: {
        const glfw_source = b.lazyDependency("glfw", .{}) orelse return;
        const glfw = b.addTranslateC(.{
            .root_source_file = b.path("examples/glfw_native.h"),
            .target = target,
            .optimize = optimize,
        });
        glfw.addSystemIncludePath(glfw_source.path("include"));
        const module = glfw.createModule();
        if (!addGlfw(b, module, target, glfw_source)) return;
        break :glfw module;
    };
    const apk_packer = b.addExecutable(.{
        .name = "apk",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/apk.zig"), .target = b.graph.host, .optimize = .ReleaseSafe }),
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = apk_packer.root_module })).step);
    const window_module = b.createModule(.{
        .root_source_file = b.path("examples/window.zig"),
        .target = target,
        .optimize = optimize,
    });
    window_module.addImport("limn", renderer);
    window_module.addImport("glfw", glfw_module);
    var moltenvk_dir: ?[]const u8 = null;
    if (target.result.os.tag == .macos) {
        const moltenvk = b.lazyDependency("moltenvk", .{}) orelse return;
        const dylib = moltenvk.path("MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib");
        b.getInstallStep().dependOn(&b.addInstallBinFile(dylib, "libMoltenVK.dylib").step);
        moltenvk_dir = moltenvk.path("MoltenVK/dynamic/dylib/macOS").getPath(b);
    }

    var example_exes: std.StringHashMapUnmanaged(*std.Build.Step.Compile) = .empty;
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
        addShaders(b, module, example.shaders, shaders_step, generated_dir, spirv_readonly, slangc);
        if (android) {
            if (example.windowed) if (addAndroidExample(b, example, module, glfw_module, target, optimize, apk_packer)) |packed_apk| b.getInstallStep().dependOn(packed_apk);
            continue;
        }
        const exe = b.addExecutable(.{ .name = example.name, .root_module = module, .use_llvm = true });
        example_exes.put(b.allocator, example.name, exe) catch @panic("OOM");
        b.installArtifact(exe);
        check_step.dependOn(&exe.step);
        const run = b.addRunArtifact(exe);
        if (dlss and nixos) run.setEnvironmentVariable("LD_LIBRARY_PATH", b.fmt("{s}:{s}", .{ b.graph.environ_map.get("LD_LIBRARY_PATH") orelse "", nixos_drivers }));
        if (moltenvk_dir) |dir| run.setEnvironmentVariable("DYLD_LIBRARY_PATH", dir);
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
        b.graph.zig_exe, "fmt", "--check", "build.zig", "src", "examples",
    });
    const verify_step = b.step("verify", "Check formatting, run tests and render the examples with validation enabled");
    verify_step.dependOn(&format_check.step);
    verify_step.dependOn(test_step);
    const cross_step = b.step("cross", "Build the library and examples for every target, into zig-out/cross/<target>, without running them");
    var previous_cross: ?*std.Build.Step = null;
    for (cross_targets) |cross_target| {
        const cross = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "install", b.fmt("-Dtarget={s}", .{cross_target}), "--prefix", b.pathFromRoot(b.fmt("zig-out/cross/{s}", .{cross_target})) });
        cross.has_side_effects = true;
        if (previous_cross) |previous| cross.step.dependOn(previous);
        previous_cross = &cross.step;
        cross_step.dependOn(&cross.step);
    }
    const checks_module = b.createModule(.{
        .root_source_file = b.path("src/checks.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = thread_sanitizer,
    });
    checks_module.addImport("limn", renderer);
    const checks = b.addExecutable(.{ .name = "checks", .root_module = checks_module, .use_llvm = true });
    checks.rdynamic = thread_sanitizer;
    check_step.dependOn(&checks.step);
    const run_checks = b.addRunArtifact(checks);
    run_checks.has_side_effects = true;
    if (b.args) |args| run_checks.addArgs(args);
    if (thread_sanitizer) run_checks.setEnvironmentVariable("TSAN_OPTIONS", b.fmt("suppressions={s}", .{b.pathFromRoot("src/tsan.supp")}));
    b.step("checks", "Check picking, shader reloading, streaming and running out of memory, without a window").dependOn(&run_checks.step);
    verify_step.dependOn(&run_checks.step);
    const costs_module = b.createModule(.{
        .root_source_file = b.path("src/costs.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = thread_sanitizer,
    });
    costs_module.addImport("limn", renderer);
    const costs = b.addExecutable(.{ .name = "costs", .root_module = costs_module, .use_llvm = true });
    costs.rdynamic = thread_sanitizer;
    check_step.dependOn(&costs.step);
    const run_costs = b.addRunArtifact(costs);
    run_costs.has_side_effects = true;
    if (thread_sanitizer) run_costs.setEnvironmentVariable("TSAN_OPTIONS", b.fmt("suppressions={s}", .{b.pathFromRoot("src/tsan.supp")}));
    if (b.args) |args| run_costs.addArgs(args);
    b.step("costs", "Print what frames record as 2D and 3D scenes grow, without a window").dependOn(&run_costs.step);
    if (android) return applyAndroidLibc(b);
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
    for ([_][]const u8{ "shadows", "stereo", "lightmap", "voxels", "asteroids" }) |name| {
        const run = b.addRunArtifact(example_exes.get(name).?);
        run.has_side_effects = true;
        run.addArgs(&.{ "--frames", "30", "--screenshot" });
        _ = run.addOutputFileArg(b.fmt("verify_{s}.png", .{name}));
        verify_step.dependOn(&run.step);
    }
    const Variant = struct { example: []const u8, name: []const u8, arguments: []const []const u8 };
    for ([_]Variant{
        .{ .example = "shadows", .name = "virtual_shadows", .arguments = &.{ "--vsm", "1" } },
        .{ .example = "upscaling", .name = "fsr2", .arguments = &.{ "--mode", "4" } },
        .{ .example = "upscaling", .name = "fsr3", .arguments = &.{ "--mode", "5" } },
        .{ .example = "upscaling", .name = "coarse_shading", .arguments = &.{ "--mode", "2", "--vrs" } },
    }) |variant| {
        const run = b.addRunArtifact(example_exes.get(variant.example).?);
        run.has_side_effects = true;
        run.addArgs(variant.arguments);
        run.addArgs(&.{ "--frames", "30", "--screenshot" });
        _ = run.addOutputFileArg(b.fmt("verify_{s}.png", .{variant.name}));
        verify_step.dependOn(&run.step);
    }
    for (pictured, pictured_examples) |name, example| {
        const verify_example = b.addRunArtifact(example.?);
        verify_example.has_side_effects = true;
        verify_example.addArgs(&.{ "--frames", "60", "--screenshot" });
        _ = verify_example.addOutputFileArg(b.fmt("verify_{s}.png", .{name}));
        verify_step.dependOn(&verify_example.step);
    }
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
}

const ffx_root = "src/third_party/ffx_sdk";
/// A switch of a FidelityFX shader. The flags src/render/ffx/limn_ffx.cpp
/// makes its contexts with decide which values are asked for, and only those
/// are compiled.
const FfxOption = struct {
    name: []const u8,
    /// The only value asked for, or null for both.
    value: ?u1 = null,
    /// The one pass it is ever set in.
    pass: ?[]const u8 = null,

    fn compiled(option: FfxOption, pass: []const u8, value: u1) bool {
        if (option.value) |only| return value == only;
        if (option.pass) |only| return value == 0 or std.mem.eql(u8, pass, only);
        return true;
    }
};
/// An effect of the FidelityFX SDK: each pass is a compute shader compiled
/// once for every combination of `options` that is asked for.
const FfxEffect = struct {
    /// The directory of its shaders.
    name: []const u8,
    /// What its options' names start with.
    prefix: []const u8,
    /// The first is the lowest bit of a combination's number.
    options: []const FfxOption,
    fixed: []const []const u8 = &.{},
    passes: []const []const u8,
};
fn ffxUpscalerOptions(comptime accumulate: []const u8) [6]FfxOption {
    return .{
        .{ .name = "OPTION_REPROJECT_USE_LANCZOS_TYPE" },
        .{ .name = "OPTION_HDR_COLOR_INPUT", .value = 1 },
        .{ .name = "OPTION_LOW_RESOLUTION_MOTION_VECTORS", .value = 1 },
        .{ .name = "OPTION_JITTERED_MOTION_VECTORS", .value = 0 },
        .{ .name = "OPTION_INVERTED_DEPTH", .value = 1 },
        .{ .name = "OPTION_APPLY_SHARPENING", .pass = accumulate },
    };
}
const ffx_sampler_options = [_][]const u8{
    "OPTION_UPSAMPLE_SAMPLERS_USE_DATA_HALF=0",
    "OPTION_ACCUMULATE_SAMPLERS_USE_DATA_HALF=0",
    "OPTION_REPROJECT_SAMPLERS_USE_DATA_HALF=1",
    "OPTION_POSTPROCESSLOCKSTATUS_SAMPLERS_USE_DATA_HALF=0",
    "OPTION_UPSAMPLE_USE_LANCZOS_TYPE=2",
};
const ffx_effects = [_]FfxEffect{
    .{ .name = "fsr2", .prefix = "FFX_FSR2", .options = &ffxUpscalerOptions("ffx_fsr2_accumulate_pass"), .fixed = &ffx_sampler_options, .passes = &.{
        "ffx_fsr2_accumulate_pass",                 "ffx_fsr2_autogen_reactive_pass", "ffx_fsr2_compute_luminance_pyramid_pass",
        "ffx_fsr2_depth_clip_pass",                 "ffx_fsr2_lock_pass",             "ffx_fsr2_rcas_pass",
        "ffx_fsr2_reconstruct_previous_depth_pass", "ffx_fsr2_tcr_autogen_pass",
    } },
    .{ .name = "fsr3upscaler", .prefix = "FFX_FSR3UPSCALER", .options = &ffxUpscalerOptions("ffx_fsr3upscaler_accumulate_pass"), .fixed = &ffx_sampler_options, .passes = &.{
        "ffx_fsr3upscaler_accumulate_pass",             "ffx_fsr3upscaler_autogen_reactive_pass", "ffx_fsr3upscaler_debug_view_pass",
        "ffx_fsr3upscaler_luma_instability_pass",       "ffx_fsr3upscaler_luma_pyramid_pass",     "ffx_fsr3upscaler_prepare_inputs_pass",
        "ffx_fsr3upscaler_prepare_reactivity_pass",     "ffx_fsr3upscaler_rcas_pass",             "ffx_fsr3upscaler_shading_change_pass",
        "ffx_fsr3upscaler_shading_change_pyramid_pass",
    } },
    .{
        .name = "frameinterpolation",
        .prefix = "FFX_FRAMEINTERPOLATION",
        .options = &.{
            .{ .name = "OPTION_LOW_RES_MOTION_VECTORS", .value = 1 },
            .{ .name = "OPTION_JITTER_MOTION_VECTORS", .value = 0 },
            .{ .name = "OPTION_INVERTED_DEPTH", .value = 1 },
        },
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
    .{ .name = "opticalflow", .prefix = "FFX_OPTICALFLOW", .options = &.{.{ .name = "OPTION_HDR_COLOR_INPUT", .value = 0 }}, .passes = &.{
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
/// `renderer` with them. The shader permutations that are asked for are
/// compiled with glslang and packed into the SDK's headers by
/// src/ffx_permutations.zig.
fn addFidelityFx(
    b: *std.Build,
    renderer: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    vulkan_include: std.Build.LazyPath,
    volk: *std.Build.Dependency,
    glslang: Tool,
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
        for (effect.options, option_names) |option, *name| name.* = b.fmt("{s}_{s}", .{ effect.prefix, option.name });
        for (effect.passes) |pass| {
            const generate = b.addRunArtifact(generator);
            const headers = generate.addOutputDirectoryArg(pass);
            generate.addArg(pass);
            generate.addArg(std.mem.join(b.allocator, ",", option_names) catch @panic("OOM"));
            for (0..@as(usize, 1) << @intCast(effect.options.len)) |combination| {
                const asked = for (effect.options, 0..) |option, bit| {
                    if (!option.compiled(pass, @truncate(combination >> @intCast(bit)))) break false;
                } else true;
                if (!asked) {
                    generate.addArg("-");
                    continue;
                }
                const compile = glslang.command(b, b.fmt("{s}_{d}", .{ pass, combination }));
                compile.addArgs(&.{ "-V", "-S", "comp", "--target-env", "vulkan1.2", "-g", "-DFFX_GLSL=1", "-DFFX_GPU=1", "-DFFX_HALF=0" });
                for (effect.fixed) |fixed| compile.addArg(b.fmt("-D{s}_{s}", .{ effect.prefix, fixed }));
                for (option_names, 0..) |name, bit| compile.addArg(b.fmt("-D{s}={d}", .{ name, (combination >> @intCast(bit)) & 1 }));
                compile.addPrefixedDirectoryArg("-I", gpu);
                compile.addPrefixedDirectoryArg("-I", gpu.path(b, effect.name));
                compile.addArg("--depfile");
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

const dlss_sdk_default = "dlss_sdk";
const nrd_sdk_default = "nrd_sdk";
/// The NRD release the shim in src/render/nrd is written against.
const nrd_sdk_version = "v4.9.4";
/// Where NixOS keeps the GPU driver's libraries, which are on no default path;
/// DLSS needs them on the library path of what it runs in.
const nixos_drivers = "/run/opengl-driver/lib";
const dlss_sdk_version = "v310.9.1";

/// Builds GLFW from source into `module` for `target`, with the platform
/// headers and macOS frameworks fetched rather than taken from the system.
/// On Linux it has both X11 and Wayland, and loads their libraries at run
/// time. Returns false while a dependency is being fetched.
fn addGlfw(b: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget, source: *std.Build.Dependency) bool {
    module.link_libc = true;
    module.addIncludePath(source.path("include"));
    const common = [_][]const u8{ "context.c", "init.c", "input.c", "monitor.c", "platform.c", "vulkan.c", "window.c", "egl_context.c", "osmesa_context.c", "null_init.c", "null_monitor.c", "null_window.c", "null_joystick.c" };
    module.addCSourceFiles(.{ .root = source.path("src"), .files = &common, .flags = &.{"-w"} });
    switch (target.result.os.tag) {
        .windows => {
            const files = [_][]const u8{ "win32_init.c", "win32_joystick.c", "win32_module.c", "win32_monitor.c", "win32_thread.c", "win32_time.c", "win32_window.c", "wgl_context.c" };
            module.addCSourceFiles(.{ .root = source.path("src"), .files = &files, .flags = &.{"-w"} });
            module.addCMacro("_GLFW_WIN32", "1");
            for ([_][]const u8{ "gdi32", "user32", "shell32" }) |system| module.linkSystemLibrary(system, .{});
        },
        .macos => {
            const sdk = b.lazyDependency("xcode_frameworks", .{}) orelse return false;
            module.addSystemFrameworkPath(sdk.path("Frameworks"));
            module.addSystemIncludePath(sdk.path("include"));
            module.addLibraryPath(sdk.path("lib"));
            module.addCMacro("_GLFW_COCOA", "1");
            module.addCMacro("__kernel_ptr_semantics", "");
            const files = [_][]const u8{ "cocoa_time.c", "posix_module.c", "posix_thread.c", "cocoa_init.m", "cocoa_joystick.m", "cocoa_monitor.m", "cocoa_window.m", "nsgl_context.m" };
            module.addCSourceFiles(.{ .root = source.path("src"), .files = &files, .flags = &.{"-w"} });
            module.linkSystemLibrary("objc", .{});
            for ([_][]const u8{ "Cocoa", "IOKit", "CoreFoundation", "QuartzCore", "AppKit", "CoreGraphics", "CoreServices", "Foundation", "ApplicationServices", "CFNetwork", "ColorSync", "CoreText", "ImageIO" }) |framework| module.linkFramework(framework, .{});
        },
        else => {
            const x11 = b.lazyDependency("x11_headers", .{}) orelse return false;
            const wayland = b.lazyDependency("wayland_headers", .{}) orelse return false;
            module.addSystemIncludePath(x11.path(""));
            module.addSystemIncludePath(wayland.path("wayland"));
            module.addSystemIncludePath(wayland.path("wayland-protocols"));
            module.addCMacro("_GLFW_X11", "1");
            module.addCMacro("_GLFW_WAYLAND", "1");
            module.addCMacro("HAVE_MEMFD_CREATE", "1");
            const files = [_][]const u8{ "linux_joystick.c", "posix_module.c", "posix_poll.c", "posix_thread.c", "posix_time.c", "xkb_unicode.c", "glx_context.c", "x11_init.c", "x11_monitor.c", "x11_window.c", "wl_init.c", "wl_monitor.c", "wl_window.c" };
            module.addCSourceFiles(.{ .root = source.path("src"), .files = &files, .flags = &.{ "-w", "-Wno-implicit-function-declaration" } });
        },
    }
    return true;
}

/// The Android API level builds target: Android 10.
const android_api = 29;
/// The most asset bytes an APK is packed with; the Bistro scene is left out.
const android_asset_limit = 1 << 30;

/// Writes a libc file for the fetched NDK's Bionic sysroot for `target`,
/// which `applyAndroidLibc` hands to the Android compilations. Returns
/// false while the NDK is being fetched.
fn useAndroidNdk(b: *std.Build, target: std.Build.ResolvedTarget) bool {
    const ndk = b.lazyDependency("android_ndk", .{}) orelse return false;
    const sysroot = ndk.path("toolchains/llvm/prebuilt/linux-x86_64/sysroot").getPath(b);
    const triple = switch (target.result.cpu.arch) {
        .x86_64 => "x86_64-linux-android",
        else => "aarch64-linux-android",
    };
    const text = b.fmt("include_dir={s}/usr/include\nsys_include_dir={s}/usr/include/{s}\ncrt_dir={s}/usr/lib/{s}/{d}\nmsvc_lib_dir=\nkernel32_lib_dir=\ngcc_dir=\n", .{ sysroot, sysroot, triple, sysroot, triple, android_api });
    const path = b.cache_root.join(b.allocator, &.{ "android", b.fmt("{s}.libc", .{triple}) }) catch @panic("OOM");
    b.cache_root.handle.createDirPath(b.graph.io, "android") catch |err| std.debug.panic("cannot write the Android libc file: {t}", .{err});
    b.cache_root.handle.writeFile(b.graph.io, .{ .sub_path = b.fmt("android/{s}.libc", .{triple}), .data = text }) catch |err| std.debug.panic("cannot write the Android libc file: {t}", .{err});
    android_libc = path;
    android_libraries = b.fmt("{s}/usr/lib/{s}/{d}", .{ sysroot, triple, android_api });
    return true;
}

/// The libc file `useAndroidNdk` wrote, and where the NDK keeps the system
/// libraries, for `applyAndroidLibc`.
var android_libc: []const u8 = "";
var android_libraries: []const u8 = "";

/// Gives every Android compilation the build can reach, its packages'
/// included, the NDK's libc; tools built for the build machine keep its own.
fn applyAndroidLibc(b: *std.Build) void {
    var seen: std.AutoHashMapUnmanaged(*std.Build.Step, void) = .empty;
    for (b.top_level_steps.values()) |top| visitAndroidLibc(b, &top.step, &seen);
}

fn visitAndroidLibc(b: *std.Build, step: *std.Build.Step, seen: *std.AutoHashMapUnmanaged(*std.Build.Step, void)) void {
    if ((seen.getOrPut(b.allocator, step) catch @panic("OOM")).found_existing) return;
    if (step.cast(std.Build.Step.Compile)) |compile| {
        if (compile.rootModuleTarget().abi.isAndroid()) {
            compile.setLibCFile(.{ .cwd_relative = android_libc });
            compile.root_module.addLibraryPath(.{ .cwd_relative = android_libraries });
        }
        var modules: std.AutoHashMapUnmanaged(*std.Build.Module, void) = .empty;
        visitModule(b, compile.root_module, &modules, seen);
    }
    for (step.dependencies.items) |dependency| visitAndroidLibc(b, dependency, seen);
}

fn visitModule(b: *std.Build, module: *std.Build.Module, modules: *std.AutoHashMapUnmanaged(*std.Build.Module, void), seen: *std.AutoHashMapUnmanaged(*std.Build.Step, void)) void {
    if ((modules.getOrPut(b.allocator, module) catch @panic("OOM")).found_existing) return;
    if (module.resolved_target) |resolved| if (resolved.result.abi.isAndroid()) {
        module.pic = true;
    };
    for (module.link_objects.items) |object| switch (object) {
        .other_step => |other| visitAndroidLibc(b, &other.step, seen),
        else => {},
    };
    for (module.import_table.values()) |imported| visitModule(b, imported, modules, seen);
}

/// Wraps a windowed example as an Android `NativeActivity` and packs it,
/// with the assets its source names, into zig-out/apk/<name>.apk. Null for
/// an example whose assets would make the package over `android_asset_limit`.
fn addAndroidExample(b: *std.Build, example: Example, module: *std.Build.Module, glfw_module: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, packer: *std.Build.Step.Compile) ?*std.Build.Step {
    const assets = exampleAssets(b, example);
    var bytes: u64 = 0;
    for (assets) |asset| bytes += if (b.build_root.handle.statFile(b.graph.io, asset, .{})) |stat| stat.size else |_| 0;
    if (bytes > android_asset_limit) return null;
    const host = b.createModule(.{ .root_source_file = b.path("examples/android/host.zig"), .target = target, .optimize = optimize, .link_libc = true });
    host.addImport("example", module);
    host.addImport("glfw", glfw_module);
    for ([_][]const u8{ "android", "log", "dl" }) |system| host.linkSystemLibrary(system, .{});
    const library = b.addLibrary(.{ .name = "main", .linkage = .dynamic, .root_module = host, .use_llvm = true });
    const pack = b.addRunArtifact(packer);
    const apk = pack.addOutputFileArg(b.fmt("{s}.apk", .{example.name}));
    pack.addArgs(&.{ b.fmt("org.limn.{s}", .{example.name}), b.fmt("limn {s}", .{example.name}) });
    if (target.result.cpu.arch == .x86_64) pack.addPrefixedFileArg("x86_64:", library.getEmittedBin()) else pack.addFileArg(library.getEmittedBin());
    for (assets) |asset| {
        pack.addArg(b.fmt("assets/{s}", .{asset}));
        pack.addFileArg(b.path(asset));
    }
    const install = b.addInstallFile(apk, b.fmt("apk/{s}.apk", .{example.name}));
    return &install.step;
}

/// The files under examples/assets that an example's source, or a source
/// file next to it that it imports, names; a named directory gives all of
/// its files, and so does the folder of a named `.gltf`, for its buffers and
/// images.
fn exampleAssets(b: *std.Build, example: Example) []const []const u8 {
    const io = b.graph.io;
    var assets: std.ArrayList([]const u8) = .empty;
    var sources: std.ArrayList([]const u8) = .empty;
    sources.appendSlice(b.allocator, &.{ example.root, "examples/window.zig" }) catch @panic("OOM");
    var read: usize = 0;
    while (read < sources.items.len) : (read += 1) {
        const text = b.build_root.handle.readFileAlloc(io, sources.items[read], b.allocator, .unlimited) catch continue;
        var quoted = std.mem.splitScalar(u8, text, '"');
        var inside = false;
        while (quoted.next()) |piece| : (inside = !inside) {
            if (!inside) continue;
            if (std.mem.endsWith(u8, piece, ".zig") and std.mem.indexOfScalar(u8, piece, '/') == null) {
                const local = b.fmt("examples/{s}", .{piece});
                for (sources.items) |known| {
                    if (std.mem.eql(u8, known, local)) break;
                } else sources.append(b.allocator, local) catch @panic("OOM");
                continue;
            }
            if (!std.mem.startsWith(u8, piece, "examples/assets/")) continue;
            const folder = if (std.mem.endsWith(u8, piece, ".gltf")) piece[0 .. std.mem.lastIndexOfScalar(u8, piece, '/').? + 1] else piece;
            if (!std.mem.endsWith(u8, folder, "/")) {
                appendNew(b, &assets, piece);
                continue;
            }
            var directory = b.build_root.handle.openDir(io, folder, .{ .iterate = true }) catch continue;
            defer directory.close(io);
            var walker = directory.walk(b.allocator) catch @panic("OOM");
            defer walker.deinit();
            while (walker.next(io) catch null) |entry| {
                if (entry.kind == .file) appendNew(b, &assets, b.fmt("{s}{s}", .{ folder, entry.path }));
            }
        }
    }
    return assets.items;
}

fn appendNew(b: *std.Build, list: *std.ArrayList([]const u8), item: []const u8) void {
    for (list.items) |known| {
        if (std.mem.eql(u8, known, item)) return;
    }
    list.append(b.allocator, item) catch @panic("OOM");
}

/// Whether the DLSS SDK has libraries for `target`.
fn dlssSupported(target: std.Build.ResolvedTarget) bool {
    return switch (target.result.os.tag) {
        .windows => target.result.cpu.arch == .x86_64,
        .linux => target.result.abi != .android and (target.result.cpu.arch == .x86_64 or target.result.cpu.arch == .aarch64),
        else => false,
    };
}

/// Where the DLSS SDK keeps its libraries for `target`.
fn dlssLibraries(target: std.Build.ResolvedTarget) []const u8 {
    return switch (target.result.os.tag) {
        .windows => "lib/Windows_x86_64",
        else => if (target.result.cpu.arch == .aarch64) "lib/Linux_aarch64" else "lib/Linux_x86_64",
    };
}

/// Builds src/render/dlss/limn_dlss.cpp against the DLSS SDK at `sdk` and links
/// NVIDIA's loader. That is built against the GNU C++ library, which `cc`
/// is asked for.
fn addDlss(
    b: *std.Build,
    renderer: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    vulkan_include: std.Build.LazyPath,
    sdk: []const u8,
) void {
    const library = b.addLibrary(.{
        .name = "renderer_dlss",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libcpp = true }),
    });
    library.root_module.addIncludePath(.{ .cwd_relative = b.pathResolve(&.{ sdk, "include" }) });
    library.root_module.addIncludePath(vulkan_include);
    library.root_module.addCSourceFile(.{ .file = b.path("src/render/dlss/limn_dlss.cpp"), .flags = &.{ "-std=c++17", "-w" } });
    renderer.linkLibrary(library);
    const windows = target.result.os.tag == .windows;
    renderer.addObjectFile(.{ .cwd_relative = b.pathResolve(&.{ sdk, dlssLibraries(target), if (windows) "nvsdk_ngx_s.lib" else "libnvsdk_ngx.a" }) });
    if (!windows) {
        const gnu_cpp = std.mem.trim(u8, b.run(&.{ "cc", "-print-file-name=libstdc++.so.6" }), " \n");
        renderer.addObjectFile(.{ .cwd_relative = gnu_cpp });
        renderer.addRPath(.{ .cwd_relative = std.fs.path.dirname(gnu_cpp) orelse "." });
        renderer.linkSystemLibrary("dl", .{});
    }
}

/// Builds src/render/nrd/limn_nrd.cpp against the NRD SDK built at `sdk`
/// and links its library, which is built against the GNU C++ library.
fn addNrd(
    b: *std.Build,
    renderer: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    vulkan_include: std.Build.LazyPath,
    sdk: []const u8,
) void {
    const library = b.addLibrary(.{
        .name = "renderer_nrd",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libcpp = true }),
    });
    library.root_module.addIncludePath(.{ .cwd_relative = b.pathResolve(&.{ sdk, "Include" }) });
    library.root_module.addIncludePath(vulkan_include);
    library.root_module.addCSourceFile(.{ .file = b.path("src/render/nrd/limn_nrd.cpp"), .flags = &.{ "-std=c++17", "-w", "-DNRD_STATIC_LIBRARY" } });
    renderer.linkLibrary(library);
    renderer.addObjectFile(.{ .cwd_relative = b.pathResolve(&.{ sdk, "_Bin", "libNRD.a" }) });
    if (target.result.os.tag != .windows) {
        const gnu_cpp = std.mem.trim(u8, b.run(&.{ "cc", "-print-file-name=libstdc++.so.6" }), " \n");
        renderer.addObjectFile(.{ .cwd_relative = gnu_cpp });
        renderer.addRPath(.{ .cwd_relative = std.fs.path.dirname(gnu_cpp) orelse "." });
    }
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
        .root_source_file = b.path("src/rhi/vulkan/volk.h"),
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

/// Compiles each shader with slangc, followed by `spirv_readonly` unless the
/// shader opts out, and exposes the SPIR-V to `module` as an anonymous
/// import. Included files are tracked through a depfile, so editing a shared
/// header rebuilds exactly the shaders that use it.
fn addShaders(b: *std.Build, module: *std.Build.Module, shaders: []const Shader, shaders_step: *std.Build.Step, generated_dir: std.Build.LazyPath, spirv_readonly: *std.Build.Step.Compile, slangc: Tool) void {
    for (shaders) |shader| {
        const command = slangc.command(b, shader.name);
        command.addFileArg(b.path(shader.src));
        command.addArgs(&slang_arguments);
        command.addArgs(&.{ "-stage", shader.stage, "-entry", shader.entry });
        command.addPrefixedDirectoryArg("-I", b.path(shader_dir));
        command.addPrefixedDirectoryArg("-I", generated_dir);
        for (shader.defines) |define| command.addArg(b.fmt("-D{s}", .{define}));
        command.addArg("-depfile");
        _ = command.addDepFileOutputArg(b.fmt("{s}.d", .{shader.name}));
        command.addArg("-o");
        if (shader.writable_reads) {
            const output = command.addOutputFileArg(shader.name);
            module.addAnonymousImport(shader.name, .{ .root_source_file = output });
            shaders_step.dependOn(&command.step);
            continue;
        }
        const compiled = command.addOutputFileArg(b.fmt("{s}.slang.spv", .{shader.name}));
        const mark = b.addRunArtifact(spirv_readonly);
        mark.addFileArg(compiled);
        const output = mark.addOutputFileArg(shader.name);
        module.addAnonymousImport(shader.name, .{ .root_source_file = output });
        shaders_step.dependOn(&mark.step);
    }
}
