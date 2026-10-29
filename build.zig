const std = @import("std");
const shader_gen = @import("src/render/core/shader_gen.zig");

const manifest = @import("src/render/shaders/manifest.zig");
/// A Slang shader entry point to compile, for `addShaders`.
pub const Shader = manifest.Shader;

/// Arguments every Slang shader is compiled with; `shaders.reload` uses the
/// same ones.
const slang_arguments = [_][]const u8{ "-profile", "spirv_1_5", "-target", "spirv", "-fvk-use-scalar-layout", "-matrix-layout-column-major", "-O2", "-warnings-disable", "39001,41012,41035" };

const shader_dir = "src/render/shaders";

/// What `zig build cross` builds the library for.
const cross_targets = [_][]const u8{ "x86_64-linux-gnu", "aarch64-linux-gnu", "x86_64-windows-gnu", "x86_64-macos", "aarch64-macos", "aarch64-linux-android" };

/// A program the build runs on the machine doing the build: one the package
/// manager fetched or built, or one found on PATH.
const Tool = union(enum) {
    path: std.Build.LazyPath,
    system: []const u8,

    /// A run step that starts the tool through `depfile` (src/depfile.zig),
    /// named for the work it does.
    fn command(self: Tool, b: *std.Build, depfile: std.Build.LazyPath, label: []const u8) *std.Build.Step.Run {
        const run = std.Build.Step.Run.create(b, b.fmt("compile {s}", .{label}));
        run.addFileArg(depfile);
        switch (self) {
            .path => |path| run.addFileArg(path),
            .system => |name| run.addArg(name),
        }
        return run;
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
    const depfile = b.addExecutable(.{
        .name = "depfile",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/depfile.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const shader_tools: ShaderTools = .{
        .slangc = slangc,
        .depfile = depfile.getEmittedBin(),
        .spirv_readonly = spirv_readonly.getEmittedBin(),
        .include = b.path(shader_dir),
        .generated = generated_dir,
    };
    compileShaders(b, renderer, manifest.renderer, shader_tools, shaders_step);
    b.addNamedLazyPath("shader_generated", generated_dir);
    b.addNamedLazyPath("depfile", shader_tools.depfile);
    b.addNamedLazyPath("spirv_readonly", shader_tools.spirv_readonly);
    switch (slangc) {
        .path => |path| b.addNamedLazyPath("slangc", path),
        .system => {},
    }
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
    if (fidelityfx) addFidelityFx(b, renderer, target, asset_optimize, vulkan_include, volk, shader_tools.depfile, if (system_tools) .{ .system = "glslangValidator" } else glslangCompiler(b) orelse return);
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

    const check_step = b.step("check", "Compile the renderer, its tests and its tools without running them");
    const tests = b.addTest(.{ .root_module = renderer, .use_llvm = true });
    check_step.dependOn(&tests.step);
    const apk_packer = b.addExecutable(.{
        .name = "apk",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/apk.zig"), .target = b.graph.host, .optimize = .ReleaseSafe }),
    });
    b.addNamedLazyPath("apk", apk_packer.getEmittedBin());
    const test_step = b.step("test", "Run unit tests");
    for ([_]*std.Build.Step.Compile{
        tests,
        b.addTest(.{ .root_module = texture_codec }),
        b.addTest(.{ .root_module = font_baker }),
        b.addTest(.{ .root_module = depfile.root_module }),
        b.addTest(.{ .root_module = apk_packer.root_module }),
    }) |compile| {
        const run = b.addRunArtifact(compile);
        run.setCwd(b.path("."));
        test_step.dependOn(&run.step);
    }

    const format_check = b.addSystemCommand(&.{
        b.graph.zig_exe, "fmt", "--check", "build.zig", "src",
    });
    format_check.setCwd(b.path("."));
    const verify_step = b.step("verify", "Check formatting, and run the tests and `checks`");
    verify_step.dependOn(&format_check.step);
    verify_step.dependOn(test_step);
    const cross_step = b.step("cross", "Build the library for every target, into zig-out/cross/<target>");
    var previous_cross: ?*std.Build.Step = null;
    for (cross_targets) |cross_target| {
        const cross = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "install", b.fmt("-Dtarget={s}", .{cross_target}), "--prefix", b.pathFromRoot(b.fmt("zig-out/cross/{s}", .{cross_target})) });
        cross.setCwd(b.path("."));
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
    run_checks.setCwd(b.path("."));
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
    if (android) applyAndroidLibc(b);
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
/// src/ffx_permutations.zig. SPD takes its barrier-only path: its wave path
/// writes shared memory that other quads may still be reading.
fn addFidelityFx(
    b: *std.Build,
    renderer: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    vulkan_include: std.Build.LazyPath,
    volk: *std.Build.Dependency,
    depfile: std.Build.LazyPath,
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
                const compile = glslang.command(b, depfile, b.fmt("{s}_{d}", .{ pass, combination }));
                compile.addArgs(&.{ "-V", "-S", "comp", "--target-env", "vulkan1.2", "-g", "-DFFX_GLSL=1", "-DFFX_GPU=1", "-DFFX_HALF=0", "-DFFX_SPD_NO_WAVE_OPERATIONS" });
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
const dlss_sdk_version = "v310.9.1";

/// The Android API level builds target: Android 10.
const android_api = 29;

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
/// An application building for Android calls it last in its own `build`,
/// once it depends on limn.
pub fn applyAndroidLibc(b: *std.Build) void {
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

/// What compiling a shader takes: the compiler, the two programs it runs
/// through and after, and the directories it includes from.
const ShaderTools = struct {
    slangc: Tool,
    depfile: std.Build.LazyPath,
    spirv_readonly: std.Build.LazyPath,
    include: std.Build.LazyPath,
    generated: std.Build.LazyPath,
};

/// Compiles an application's own Slang shaders the way limn compiles its
/// own, and gives `module` each one's SPIR-V as an anonymous import named
/// after it, for `@embedFile`. `limn` is the application's dependency on
/// this package; `Shader.src` is relative to the application's build root,
/// and the shaders can include limn's. Does nothing while limn's own
/// dependencies are being fetched.
pub fn addShaders(b: *std.Build, limn: *std.Build.Dependency, module: *std.Build.Module, shaders: []const Shader) void {
    const paths = limn.builder.named_lazy_paths;
    const tools: ShaderTools = .{
        .slangc = if (paths.get("slangc")) |path| .{ .path = path } else .{ .system = "slangc" },
        .depfile = paths.get("depfile") orelse return,
        .spirv_readonly = paths.get("spirv_readonly") orelse return,
        .include = paths.get("shader_include") orelse return,
        .generated = paths.get("shader_generated") orelse return,
    };
    compileShaders(b, module, shaders, tools, null);
}

/// Compiles each shader with slangc, followed by `spirv_readonly` unless the
/// shader opts out, and exposes the SPIR-V to `module` as an anonymous
/// import. Included files are tracked through a depfile, so editing a shared
/// header rebuilds exactly the shaders that use it.
fn compileShaders(b: *std.Build, module: *std.Build.Module, shaders: []const Shader, tools: ShaderTools, shaders_step: ?*std.Build.Step) void {
    for (shaders) |shader| {
        const command = tools.slangc.command(b, tools.depfile, shader.name);
        command.addFileArg(b.path(shader.src));
        command.addArgs(&slang_arguments);
        command.addArgs(&.{ "-stage", shader.stage, "-entry", shader.entry });
        command.addPrefixedDirectoryArg("-I", tools.include);
        command.addPrefixedDirectoryArg("-I", tools.generated);
        for (shader.defines) |define| command.addArg(b.fmt("-D{s}", .{define}));
        command.addArg("-depfile");
        _ = command.addDepFileOutputArg(b.fmt("{s}.d", .{shader.name}));
        command.addArg("-o");
        if (shader.writable_reads) {
            const output = command.addOutputFileArg(shader.name);
            module.addAnonymousImport(shader.name, .{ .root_source_file = output });
            if (shaders_step) |step| step.dependOn(&command.step);
            continue;
        }
        const compiled = command.addOutputFileArg(b.fmt("{s}.slang.spv", .{shader.name}));
        const mark = std.Build.Step.Run.create(b, b.fmt("mark {s} read-only", .{shader.name}));
        mark.addFileArg(tools.spirv_readonly);
        mark.addFileArg(compiled);
        const output = mark.addOutputFileArg(shader.name);
        module.addAnonymousImport(shader.name, .{ .root_source_file = output });
        if (shaders_step) |step| step.dependOn(&mark.step);
    }
}
