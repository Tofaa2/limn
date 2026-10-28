//! GLFW glue shared by the windowed examples. The renderer itself never
//! touches a windowing library; it only needs the native handles.
const std = @import("std");
const builtin = @import("builtin");
const gfx = @import("limn");
pub const glfw = @import("glfw");

pub const Window = struct {
    handle: *glfw.GLFWwindow,

    pub fn init(width: u32, height: u32, title: [:0]const u8) !Window {
        if (glfw.glfwInit() != glfw.GLFW_TRUE) return error.GlfwInitializationFailed;
        glfw.glfwWindowHint(glfw.GLFW_CLIENT_API, glfw.GLFW_NO_API);
        glfw.glfwWindowHint(glfw.GLFW_RESIZABLE, glfw.GLFW_TRUE);
        const handle = glfw.glfwCreateWindow(@intCast(width), @intCast(height), title.ptr, null, null) orelse
            return error.WindowCreationFailed;
        return .{ .handle = handle };
    }

    pub fn deinit(self: Window) void {
        glfw.glfwDestroyWindow(self.handle);
        glfw.glfwTerminate();
    }

    pub fn surface(self: Window, vsync: bool) !gfx.rhi.Surface {
        const size = self.framebufferSize();
        return .{ .window = try self.native(), .width = size[0], .height = size[1], .vsync = vsync };
    }

    pub fn framebufferSize(self: Window) [2]u32 {
        var width: c_int = 0;
        var height: c_int = 0;
        glfw.glfwGetFramebufferSize(self.handle, &width, &height);
        return .{ @intCast(@max(width, 0)), @intCast(@max(height, 0)) };
    }

    pub fn shouldClose(self: Window) bool {
        return glfw.glfwWindowShouldClose(self.handle) == glfw.GLFW_TRUE;
    }

    pub fn pollEvents(_: Window) void {
        glfw.glfwPollEvents();
    }

    pub fn time(_: Window) f64 {
        return glfw.glfwGetTime();
    }

    pub fn keyDown(self: Window, key: c_int) bool {
        return glfw.glfwGetKey(self.handle, key) == glfw.GLFW_PRESS;
    }

    pub fn cursor(self: Window) [2]f64 {
        var x: f64 = 0;
        var y: f64 = 0;
        glfw.glfwGetCursorPos(self.handle, &x, &y);
        return .{ x, y };
    }

    pub fn captureCursor(self: Window, capture: bool) void {
        glfw.glfwSetInputMode(self.handle, glfw.GLFW_CURSOR, if (capture) glfw.GLFW_CURSOR_DISABLED else glfw.GLFW_CURSOR_NORMAL);
    }

    pub fn setTitle(self: Window, title: [:0]const u8) void {
        glfw.glfwSetWindowTitle(self.handle, title.ptr);
    }

    fn native(self: Window) !gfx.rhi.NativeWindow {
        if (comptime builtin.abi.isAndroid()) return .{ .android = .{ .window = glfw.androidWindow() orelse return error.NativeWindowUnavailable } };
        if (comptime builtin.os.tag == .macos) return .{ .metal = .{ .layer = try metalLayer(glfw.glfwGetCocoaWindow(self.handle) orelse return error.NativeWindowUnavailable) } };
        if (comptime builtin.os.tag == .windows) return .{ .win32 = .{
            .instance = @ptrCast(glfw.GetModuleHandleW(null)),
            .window = @ptrCast(glfw.glfwGetWin32Window(self.handle) orelse return error.NativeWindowUnavailable),
        } };
        return switch (glfw.glfwGetPlatform()) {
            glfw.GLFW_PLATFORM_X11 => .{ .xlib = .{
                .display = @ptrCast(glfw.glfwGetX11Display() orelse return error.NativeWindowUnavailable),
                .window = @intCast(glfw.glfwGetX11Window(self.handle)),
            } },
            glfw.GLFW_PLATFORM_WAYLAND => .{ .wayland = .{
                .display = @ptrCast(glfw.glfwGetWaylandDisplay() orelse return error.NativeWindowUnavailable),
                .surface = @ptrCast(glfw.glfwGetWaylandWindow(self.handle) orelse return error.NativeWindowUnavailable),
            } },
            else => error.UnsupportedWindowPlatform,
        };
    }
};

/// Gives the content view of an `NSWindow` a `CAMetalLayer`, which MoltenVK
/// presents to, through the Objective-C runtime.
fn metalLayer(window: *anyopaque) !*anyopaque {
    const objc = struct {
        extern "objc" fn objc_getClass(name: [*:0]const u8) ?*anyopaque;
        extern "objc" fn sel_registerName(name: [*:0]const u8) *anyopaque;
        extern "objc" fn objc_msgSend() void;
    };
    const Send = *const fn (*anyopaque, *anyopaque) callconv(.c) ?*anyopaque;
    const SendFlag = *const fn (*anyopaque, *anyopaque, bool) callconv(.c) void;
    const SendObject = *const fn (*anyopaque, *anyopaque, *anyopaque) callconv(.c) void;
    const send: Send = @ptrCast(&objc.objc_msgSend);
    const view = send(window, objc.sel_registerName("contentView")) orelse return error.NativeWindowUnavailable;
    const class = objc.objc_getClass("CAMetalLayer") orelse return error.NativeWindowUnavailable;
    const layer = send(class, objc.sel_registerName("layer")) orelse return error.NativeWindowUnavailable;
    @as(SendFlag, @ptrCast(&objc.objc_msgSend))(view, objc.sel_registerName("setWantsLayer:"), true);
    @as(SendObject, @ptrCast(&objc.objc_msgSend))(view, objc.sel_registerName("setLayer:"), layer);
    return layer;
}

/// CPU time of the renderer's zones, for `--timings`.
const Zones = struct {
    io: std.Io = undefined,
    names: [32][]const u8 = undefined,
    totals: [32]f64 = @splat(0),
    depths: [32]usize = undefined,
    count: usize = 0,
    open: [8]struct { zone: usize, start: std.Io.Clock.Timestamp } = undefined,
    depth: usize = 0,

    fn begin(_: ?*anyopaque, name: [:0]const u8) u64 {
        if (zones.depth == zones.open.len) return 0;
        const zone = for (zones.names[0..zones.count], 0..) |known, index| {
            if (known.ptr == name.ptr) break index;
        } else new: {
            if (zones.count == zones.names.len) return 0;
            zones.names[zones.count] = name;
            zones.depths[zones.count] = @min(zones.depth, 3);
            zones.count += 1;
            break :new zones.count - 1;
        };
        zones.open[zones.depth] = .{ .zone = zone, .start = std.Io.Clock.Timestamp.now(zones.io, .awake) };
        zones.depth += 1;
        return 1;
    }

    fn end(_: ?*anyopaque, opened: u64) void {
        if (opened == 0) return;
        zones.depth -= 1;
        const entry = zones.open[zones.depth];
        zones.totals[entry.zone] += @as(f64, @floatFromInt(entry.start.untilNow(zones.io).raw.nanoseconds)) / 1e6;
    }
};
var zones: Zones = .{};

/// `--frames N` makes an example exit after N frames, for smoke tests.
pub fn frameLimit(init: std.process.Init) !?u64 {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.skip();
    while (args.next()) |argument| {
        if (std.mem.eql(u8, argument, "--frames"))
            return try std.fmt.parseInt(u64, args.next() orelse return error.MissingFrameCount, 10);
    }
    return null;
}

/// The scaffolding the scene examples share: command line, a window or an
/// offscreen target, the renderer, frame timing and key presses.
///
///   --frames N           exit after N frames
///   --screenshot f.png   render without a window, with validation and
///                        `Options.deterministic` on, and
///                        write the last frame, to check the picture
///   --timings            render without a window and print the average
///                        GPU time of each pass and the CPU time of a frame
///   --validation         turn the Vulkan validation layers on
///   --names              name GPU objects and label passes for debuggers
///                        such as RenderDoc; always on in a debug build
///   --uneven-frames      without a window, step time by an uneven, repeating
///                        run of frame lengths instead of 1/60 s, as a
///                        window does; finds what depends on the frame rate
///   --memory N           print GPU memory and resident memory every N
///                        frames, to find what grows in long runs
pub const Stage = struct {
    init: std.process.Init,
    window: ?Window,
    renderer: *gfx.Renderer,
    offscreen: ?gfx.rhi.Texture,
    screenshot: ?[]const u8,
    frame_limit: ?u64,
    frames: u64 = 0,
    time: f32 = 0,
    last: f64 = 0,
    keys: [glfw.GLFW_KEY_LAST + 1]bool = @splat(false),
    /// Frames and GPU time, refreshed twice a second for a HUD.
    fps: f32 = 0,
    /// Images shown a second: above `fps` when frames are generated.
    shown_fps: f32 = 0,
    meter_presented: u64 = 0,
    gpu_ms: f32 = 0,
    meter_time: f32 = 0,
    meter_frames: u32 = 0,
    timings: bool = false,
    uneven: bool = false,
    memory_every: u64 = 0,
    timed_frames: u32 = 0,
    timed_cpu: f64 = 0,
    /// GPU time of the slowest frame once the scene has settled.
    timed_worst: f64 = 0,
    timed: [128]Timed = undefined,
    timed_count: usize = 0,

    const Timed = struct { name: []const u8, depth: u32, total: f64 };
    /// Frames left out of `--timings`, while pipelines compile and history fills.
    const timing_warmup = 60;
    /// Frames left out of the slowest frame, while lighting is first gathered.
    const timing_settle = 300;

    /// Frame lengths `--uneven-frames` cycles through: vsync jitter at
    /// several refresh rates, and the odd hitch.
    pub const uneven_frames = [_]f32{ 1.0 / 144.0, 1.0 / 98.0, 1.0 / 144.0, 1.0 / 60.0, 1.0 / 240.0, 1.0 / 75.0, 1.0 / 30.0, 1.0 / 120.0, 1.0 / 11.0, 1.0 / 165.0 };

    pub const width = 1280;
    pub const height = 720;

    pub const Tick = struct {
        /// Seconds since the previous frame.
        dt: f32,
        /// Seconds since the start.
        time: f32,
        size: [2]u32,
    };

    pub fn create(init: std.process.Init, title: [:0]const u8, options: gfx.Options) !Stage {
        var frame_limit: ?u64 = null;
        var screenshot: ?[]const u8 = null;
        var debug_names = builtin.mode == .Debug;
        var validation = false;
        var timings = false;
        var uneven = false;
        var memory_every: u64 = 0;
        var args = try init.minimal.args.iterateAllocator(init.gpa);
        defer args.deinit();
        _ = args.skip();
        var own_value = false;
        while (args.next()) |arg| {
            const value = own_value and !std.mem.startsWith(u8, arg, "--");
            own_value = false;
            if (value) continue;
            if (std.mem.eql(u8, arg, "--frames")) {
                frame_limit = try std.fmt.parseInt(u64, args.next() orelse return error.MissingArgument, 10);
            } else if (std.mem.eql(u8, arg, "--screenshot")) {
                screenshot = try init.gpa.dupe(u8, args.next() orelse return error.MissingArgument);
            } else if (std.mem.eql(u8, arg, "--names")) {
                debug_names = true;
            } else if (std.mem.eql(u8, arg, "--validation")) {
                validation = true;
            } else if (std.mem.eql(u8, arg, "--timings")) {
                timings = true;
            } else if (std.mem.eql(u8, arg, "--uneven-frames")) {
                uneven = true;
            } else if (std.mem.eql(u8, arg, "--memory")) {
                memory_every = try std.fmt.parseInt(u64, args.next() orelse return error.MissingArgument, 10);
            } else if (std.mem.startsWith(u8, arg, "--")) {
                own_value = true;
            } else return error.InvalidArgument;
        }
        const headless = screenshot != null or timings;
        if (headless and frame_limit == null) frame_limit = 240;

        const window: ?Window = if (headless) null else try Window.init(width, height, title);
        var renderer_options = options;
        renderer_options.application_name = title;
        renderer_options.surface = if (window) |value| try value.surface(false) else null;
        if (screenshot != null or validation) renderer_options.validation = true;
        if (screenshot != null) renderer_options.deterministic = true;
        if (debug_names) renderer_options.debug_names = true;
        if (renderer_options.cache.pipelines == null) renderer_options.cache.pipelines = "zig-out/pipeline.cache";
        if (timings and renderer_options.profiler == null) {
            zones.io = init.io;
            renderer_options.profiler = .{ .begin = Zones.begin, .end = Zones.end };
        }
        const renderer = try gfx.Renderer.init(init.gpa, init.io, renderer_options);
        return .{
            .init = init,
            .window = window,
            .renderer = renderer,
            .offscreen = if (headless) try renderer.views.createTarget(width, height) else null,
            .screenshot = screenshot,
            .timings = timings,
            .uneven = uneven,
            .memory_every = memory_every,
            .frame_limit = frame_limit,
            .last = if (window) |value| value.time() else 0,
        };
    }

    /// Starts a frame. Null when the example should end.
    pub fn begin(self: *Stage) ?Tick {
        if (self.frame_limit) |limit| if (self.frames >= limit) return null;
        var tick = Tick{ .dt = if (self.uneven) uneven_frames[self.frames % uneven_frames.len] else 1.0 / 60.0, .time = 0, .size = .{ width, height } };
        if (self.window) |window| {
            if (window.shouldClose() or window.keyDown(glfw.GLFW_KEY_ESCAPE)) return null;
            window.pollEvents();
            if (comptime builtin.abi.isAndroid()) if (!self.followSurface(window)) return null;
            const now = window.time();
            tick.dt = @floatCast(@min(now - self.last, 0.1));
            self.last = now;
            tick.size = window.framebufferSize();
            self.renderer.resize(tick.size[0], tick.size[1]);
        }
        self.time += tick.dt;
        tick.time = self.time;
        return tick;
    }

    /// On Android, lets go of a window the activity is losing, waits for
    /// the next and presents to that. False if the activity ends first.
    fn followSurface(self: *Stage, window: Window) bool {
        switch (glfw.surfaceChange()) {
            .none => return true,
            .gained => {},
            .lost => {
                self.renderer.setSurface(null) catch |err| std.log.err("could not drop the window: {t}", .{err});
                if (!glfw.surfaceReleased()) return false;
            },
        }
        const next = window.surface(false) catch return false;
        self.renderer.setSurface(next) catch |err| {
            std.log.err("could not present to the new window: {t}", .{err});
            return false;
        };
        return true;
    }

    pub fn keyDown(self: *const Stage, key: c_int) bool {
        return if (self.window) |window| window.keyDown(key) else false;
    }

    /// True once per press.
    pub fn keyPressed(self: *Stage, key: c_int) bool {
        const down = self.keyDown(key);
        defer self.keys[@intCast(key)] = down;
        return down and !self.keys[@intCast(key)];
    }

    /// Where views should draw: the window, or the offscreen picture.
    pub fn target(self: *const Stage) gfx.Target {
        return if (self.offscreen) |texture| .{ .texture = texture } else .backbuffer;
    }

    /// The renderer's counters, with CPU time left at 0 in a `--screenshot`
    /// run, so that its picture comes out the same every time.
    pub fn stats(self: *const Stage) gfx.Stats {
        var counted = self.renderer.stats();
        if (self.screenshot != null) counted.cpu_ms = 0;
        return counted;
    }

    /// GPU times of the passes of a recent frame. None in a `--screenshot`
    /// run, so that its picture comes out the same every time.
    pub fn passTimings(self: *const Stage) []const gfx.rhi.PassTiming {
        if (self.screenshot != null) return &.{};
        return self.renderer.device.passTimings();
    }

    /// Call with the result of `render`.
    pub fn end(self: *Stage, presented: bool) !void {
        if (!presented) return self.init.io.sleep(std.Io.Duration.fromMilliseconds(10), .awake);
        self.frames += 1;
        self.meter_frames += 1;
        if (self.timings and self.frames == timing_warmup) zones.totals = @splat(0);
        if (self.timings and self.frames > timing_warmup) self.noteTimings();
        if (self.memory_every != 0 and self.frames % self.memory_every == 0) self.logMemory();
        if (self.time - self.meter_time >= 0.5) {
            self.fps = @as(f32, @floatFromInt(self.meter_frames)) / (self.time - self.meter_time);
            const images = self.renderer.device.presented.load(.monotonic);
            self.shown_fps = @as(f32, @floatFromInt(images - self.meter_presented)) / (self.time - self.meter_time);
            self.meter_presented = images;
            self.gpu_ms = 0;
            for (self.passTimings()) |timing| {
                if (timing.depth == 0) self.gpu_ms += timing.milliseconds;
            }
            self.meter_time = self.time;
            self.meter_frames = 0;
        }
    }

    fn logMemory(self: *Stage) void {
        const frame_stats = self.renderer.stats();
        const peak = if (comptime builtin.os.tag == .windows) 0 else std.posix.getrusage(std.posix.rusage.SELF).maxrss;
        var statm: [128]u8 = undefined;
        const resident: u64 = if (std.Io.Dir.cwd().readFile(self.init.io, "/proc/self/statm", &statm)) |text| blk: {
            var fields = std.mem.tokenizeScalar(u8, text, ' ');
            _ = fields.next();
            const pages = std.fmt.parseInt(u64, fields.next() orelse "0", 10) catch 0;
            break :blk pages * 4;
        } else |_| 0;
        std.log.info("memory: frame {d} · gpu {d} KiB · resident {d} KiB (peak {d}) · {d} pipelines", .{ self.frames, frame_stats.gpu_memory_bytes / 1024, resident, peak, frame_stats.pipelines });
    }

    fn noteTimings(self: *Stage) void {
        self.timed_frames += 1;
        self.timed_cpu += self.renderer.stats().cpu_ms;
        var frame_gpu: f64 = 0;
        for (self.renderer.device.passTimings()) |timing| {
            if (timing.depth == 0) frame_gpu += timing.milliseconds;
        }
        if (self.frames > timing_settle) self.timed_worst = @max(self.timed_worst, frame_gpu);
        for (self.renderer.device.passTimings()) |timing| {
            const entry = for (self.timed[0..self.timed_count]) |*entry| {
                if (entry.depth == timing.depth and std.mem.eql(u8, entry.name, timing.name)) break entry;
            } else new: {
                if (self.timed_count == self.timed.len) continue;
                self.timed[self.timed_count] = .{ .name = timing.name, .depth = timing.depth, .total = 0 };
                self.timed_count += 1;
                break :new &self.timed[self.timed_count - 1];
            };
            entry.total += timing.milliseconds;
        }
    }

    fn printTimings(self: *Stage) void {
        const frames: f64 = @floatFromInt(@max(self.timed_frames, 1));
        var gpu: f64 = 0;
        for (self.timed[0..self.timed_count]) |entry| {
            if (entry.depth == 0) gpu += entry.total;
            std.debug.print("{d:8.3} ms  {s}{s}\n", .{ entry.total / frames, "        "[0..@min(entry.depth * 2, 8)], entry.name });
        }
        std.debug.print("{d:8.3} ms  GPU\n{d:8.3} ms  GPU slowest frame\n{d:8.3} ms  CPU\n", .{ gpu / frames, self.timed_worst, self.timed_cpu / frames });
        const counted = self.renderer.stats();
        std.debug.print("{d:8.1} MiB GPU memory\n{d:8} pipelines\n", .{ @as(f64, @floatFromInt(counted.gpu_memory_bytes)) / (1024 * 1024), counted.pipelines });
        for (counted.downgraded()) |downgrade| {
            std.debug.print("{s}: asked for {s}, got {s} ({s})\n", .{ downgrade.feature, downgrade.requested, downgrade.used, @tagName(downgrade.reason) });
        }
        for (zones.names[0..zones.count], zones.totals[0..zones.count], zones.depths[0..zones.count]) |name, total, depth| {
            std.debug.print("{d:8.3} ms  {s}{s}\n", .{ total / frames, "        "[0 .. depth * 2 + 2], name });
        }
    }

    /// Writes the screenshot if one was asked for, and shuts down.
    pub fn finish(self: *Stage) !void {
        const gpa = self.init.gpa;
        try self.renderer.device.waitIdle();
        if (self.timings) self.printTimings();
        if (self.screenshot) |path| {
            const pixels = try self.renderer.device.readTexture(gpa, self.offscreen.?);
            defer gpa.free(pixels);
            try gfx.png.write(gpa, self.init.io, path, .{ .width = width, .height = height, .pixels = pixels });
            gpa.free(path);
        }
        const failed = self.renderer.device.validationErrorCount() != 0;
        if (self.offscreen) |texture| self.renderer.views.destroyTarget(texture);
        self.renderer.deinit();
        if (self.window) |window| window.deinit();
        if (failed) return error.ValidationFailed;
    }
};

/// A box centered on the origin, for floors and props.
pub fn boxMesh(half: [3]f32, positions: *[24][3]f32, indices: *[36]u32) void {
    for (0..6) |face| {
        const axis = face / 2;
        const sign: f32 = if (face % 2 == 0) 1 else -1;
        const u = (axis + 1) % 3;
        const v = (axis + 2) % 3;
        for (0..4) |corner| {
            var p: [3]f32 = undefined;
            p[axis] = sign * half[axis];
            p[u] = (if (corner == 1 or corner == 2) half[u] else -half[u]) * sign;
            p[v] = if (corner >= 2) half[v] else -half[v];
            positions[face * 4 + corner] = p;
        }
        const base: u32 = @intCast(face * 4);
        indices[face * 6 ..][0..6].* = .{ base, base + 1, base + 2, base, base + 2, base + 3 };
    }
}

pub const sphere_rings = 24;
pub const sphere_segments = 48;
pub const sphere_vertex_count = (sphere_rings + 1) * (sphere_segments + 1);
pub const sphere_index_count = sphere_rings * sphere_segments * 6;

/// A sphere centered on the origin with smooth normals.
pub fn sphereMesh(
    radius: f32,
    positions: *[sphere_vertex_count][3]f32,
    normals: *[sphere_vertex_count][3]f32,
    indices: *[sphere_index_count]u32,
) void {
    for (0..sphere_rings + 1) |ring| {
        const theta = std.math.pi * @as(f32, @floatFromInt(ring)) / sphere_rings;
        for (0..sphere_segments + 1) |segment| {
            const phi = std.math.tau * @as(f32, @floatFromInt(segment)) / sphere_segments;
            const n = [3]f32{ @sin(theta) * @cos(phi), @cos(theta), @sin(theta) * @sin(phi) };
            normals[ring * (sphere_segments + 1) + segment] = n;
            positions[ring * (sphere_segments + 1) + segment] = .{ n[0] * radius, n[1] * radius, n[2] * radius };
        }
    }
    for (0..sphere_rings) |ring| for (0..sphere_segments) |segment| {
        const a: u32 = @intCast(ring * (sphere_segments + 1) + segment);
        const b: u32 = a + sphere_segments + 1;
        indices[(ring * sphere_segments + segment) * 6 ..][0..6].* = .{ a, a + 1, b, a + 1, b + 1, b };
    };
}
