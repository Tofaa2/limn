//! Pipelines and the shader code they are built from. Internal to the renderer.
const std = @import("std");
const rhi = @import("../../rhi/rhi.zig");
const shader_sources = @import("shader_sources");
const renderer_state = @import("../state.zig");
const render = @import("../renderer.zig");

const Renderer = render.Renderer;
pub const hdr_format = renderer_state.hdr_format;
pub const bloom_format = renderer_state.bloom_format;
const pipeline_cache = @import("../core/pipeline_cache.zig");
const spirv_readonly = @import("../core/spirv_readonly.zig");
const canvas_feature = @import("../features/canvas.zig");
pub const shade_plain_targets = renderer_state.shade_plain_targets;
pub const shade_reflective_targets = renderer_state.shade_reflective_targets;

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
        const gpa = self.internal.gpa;
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
            const result = try std.process.run(gpa, self.internal.io, .{ .argv = argv[0..count] });
            defer gpa.free(result.stderr);
            defer gpa.free(result.stdout);
            const ok = switch (result.term) {
                .exited => |code| code == 0,
                else => false,
            };
            const code: []u8 = if (!ok)
                &.{}
            else if (read_only)
                try markedSpirv(gpa, std.Io.Dir.cwd().readFileAlloc(self.internal.io, written, gpa, .unlimited) catch &.{})
            else
                std.Io.Dir.cwd().readFileAlloc(self.internal.io, written, gpa, .unlimited) catch &.{};
            std.Io.Dir.cwd().deleteFile(self.internal.io, written) catch {};
            if (code.len == 0 or code.len % 4 != 0) {
                std.log.err("shader {s} did not compile:\n{s}", .{ name, result.stderr });
                gpa.free(code);
                return error.ShaderCompileFailed;
            }
            errdefer gpa.free(code);
            try compiled.append(gpa, code);
        }

        try overrideShaders(shader_sources.names, compiled.items);
        self.internal.shade_variants.clearRetainingCapacity();
        try device.waitIdle();
        self.internal.pipelines.reset();
        canvas_feature.resetPipelines(&self.canvas, device);
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
                if (!self.internal.pipelines.compiling()) return;
            }
            try self.internal.io.sleep(std.Io.Duration.fromMilliseconds(1), .awake);
        }
    }
};

/// Shaders that `shaders.reload` has compiled, by name. Every renderer in
/// the process shares them; `releaseOverrides` frees them with the last one.
var shader_overrides: std.StringHashMapUnmanaged([]u8) = .empty;
/// Code a reload replaced, kept because pipelines may still be compiling it.
var retired_overrides: std.ArrayList([]u8) = .empty;
var override_users: u32 = 0;
var overrides_locked: std.atomic.Value(bool) = .init(false);
/// Whether `shader_overrides` holds anything, read without the lock.
var overridden: std.atomic.Value(bool) = .init(false);
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
    overridden.store(false, .release);
    for (retired_overrides.items) |code| override_allocator.free(code);
    retired_overrides.deinit(override_allocator);
    retired_overrides = .empty;
}

/// Replaces the code of every shader in `names` together: on failure none
/// is replaced, so a reload never mixes old and new shaders.
fn overrideShaders(names: []const []const u8, codes: []const []u8) !void {
    const copies = try override_allocator.alloc([]u8, codes.len);
    defer override_allocator.free(copies);
    var made: usize = 0;
    errdefer for (copies[0..made]) |copy| override_allocator.free(copy);
    for (codes, copies) |code, *copy| {
        copy.* = try override_allocator.dupe(u8, code);
        made += 1;
    }
    lockOverrides();
    defer unlockOverrides();
    try shader_overrides.ensureUnusedCapacity(override_allocator, @intCast(names.len));
    try retired_overrides.ensureUnusedCapacity(override_allocator, names.len);
    for (names, copies) |name, copy| if (shader_overrides.fetchPutAssumeCapacity(name, copy)) |old| retired_overrides.appendAssumeCapacity(old.value);
    overridden.store(true, .release);
}

/// Shader code by name: what `shaders.reload` last compiled, or else what
/// was built into the program.
pub fn shaderCode(comptime name: []const u8) []const u8 {
    if (!overridden.load(.acquire)) return @embedFile(name);
    lockOverrides();
    defer unlockOverrides();
    if (shader_overrides.get(name)) |code| return code;
    return @embedFile(name);
}

/// What a pipeline is built from; see `PipelineCache`.
pub const Desc = pipeline_cache.Desc;

/// Every built-in pipeline, each built on first use.
pub const Pipelines = pipeline_cache.PipelineCache;

/// A fullscreen pass drawing `fragment` into `targets`.
pub fn pass(name: [:0]const u8, fragment: []const u8, targets: []const rhi.ColorTarget) Desc {
    return .{ .graphics = .{
        .name = name,
        .vertex = shaderCode("fullscreen.vert.spv"),
        .fragment = fragment,
        .color_targets = targets,
        .cull = .none,
    } };
}

pub const local_shadow_depth = rhi.DepthState{
    .compare = .greater_or_equal,
    .bias = .{ .constant = -1.5, .slope = -2.0 },
};

pub const shadow_depth = rhi.DepthState{
    .compare = .less_or_equal,
    .bias = .{ .constant = 1.5, .slope = 2.0 },
    .clamp = true,
};

pub fn shadowPipeline(device: *rhi.Device) Desc {
    return .{ .graphics = .{
        .name = "shadow",
        .vertex = shaderCode("visibility.vert.spv"),
        .mesh = if (device.caps.mesh_shaders) shaderCode("visibility.mesh.spv") else null,
        .task = if (device.caps.mesh_shaders) shaderCode("visibility.task.spv") else null,
        .depth = shadow_depth,
        .cull = .back,
    } };
}

pub fn shadowMaskedPipeline(device: *rhi.Device) Desc {
    return .{ .graphics = .{
        .name = "shadow masked",
        .vertex = shaderCode("visibility.vert.spv"),
        .mesh = if (device.caps.mesh_shaders) shaderCode("visibility.mesh.spv") else null,
        .task = if (device.caps.mesh_shaders) shaderCode("visibility.task.spv") else null,
        .fragment = shaderCode("shadow_masked.frag.spv"),
        .depth = shadow_depth,
        .cull = .none,
    } };
}

pub fn fogCompositePipeline(_: *rhi.Device) Desc {
    return pass("fog composite", shaderCode("fog_composite.frag.spv"), &.{.{ .format = hdr_format, .blend = .premultiplied }});
}
