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
        if (comptime builtin.os.tag == .windows) return .{ .win32 = .{
            .instance = @ptrCast(glfw.GetModuleHandleW(null)),
            .window = @ptrCast(glfw.glfwGetWin32Window(self.handle) orelse return error.NativeWindowUnavailable),
        } };
        // GLFW before 3.4 is built for one window system and cannot be asked
        // which; the libraries distributions ship of it are X11 ones.
        if (comptime !@hasDecl(glfw, "glfwGetPlatform")) return .{ .xlib = .{
            .display = @ptrCast(glfw.glfwGetX11Display() orelse return error.NativeWindowUnavailable),
            .window = @intCast(glfw.glfwGetX11Window(self.handle)),
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
///   --screenshot f.png   render without a window (with validation on) and
///                        write the last frame, to check the picture
///   --validation         turn the Vulkan validation layers on
///   --names              name GPU objects and label passes for debuggers
///                        such as RenderDoc; always on in a debug build
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
        var args = try init.minimal.args.iterateAllocator(init.gpa);
        defer args.deinit();
        _ = args.skip();
        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--frames")) {
                frame_limit = try std.fmt.parseInt(u64, args.next() orelse return error.MissingArgument, 10);
            } else if (std.mem.eql(u8, arg, "--screenshot")) {
                screenshot = try init.gpa.dupe(u8, args.next() orelse return error.MissingArgument);
            } else if (std.mem.eql(u8, arg, "--names")) {
                debug_names = true;
            } else if (std.mem.eql(u8, arg, "--validation")) {
                validation = true;
            } else if (std.mem.startsWith(u8, arg, "--")) {
                // An option of the example itself, with its value.
                _ = args.next();
            } else return error.InvalidArgument;
        }
        if (screenshot != null and frame_limit == null) frame_limit = 240;

        const window: ?Window = if (screenshot != null) null else try Window.init(width, height, title);
        var renderer_options = options;
        renderer_options.application_name = title;
        renderer_options.surface = if (window) |value| try value.surface(false) else null;
        if (screenshot != null or validation) renderer_options.validation = true;
        if (debug_names) renderer_options.debug_names = true;
        // Compiled shaders are kept between runs; the first run of a build
        // pays for compiling them, later ones start at once.
        if (renderer_options.pipeline_cache_path == null) renderer_options.pipeline_cache_path = "zig-out/pipeline.cache";
        const renderer = try gfx.Renderer.init(init.gpa, init.io, renderer_options);
        return .{
            .init = init,
            .window = window,
            .renderer = renderer,
            .offscreen = if (screenshot != null) try renderer.createTarget(width, height) else null,
            .screenshot = screenshot,
            .frame_limit = frame_limit,
            .last = if (window) |value| value.time() else 0,
        };
    }

    /// Starts a frame. Null when the example should end.
    pub fn begin(self: *Stage) ?Tick {
        if (self.frame_limit) |limit| if (self.frames >= limit) return null;
        var tick = Tick{ .dt = 1.0 / 60.0, .time = 0, .size = .{ width, height } };
        if (self.window) |window| {
            if (window.shouldClose() or window.keyDown(glfw.GLFW_KEY_ESCAPE)) return null;
            window.pollEvents();
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

    /// Call with the result of `render`.
    pub fn end(self: *Stage, presented: bool) !void {
        if (!presented) return self.init.io.sleep(std.Io.Duration.fromMilliseconds(10), .awake);
        self.frames += 1;
        self.meter_frames += 1;
        if (self.time - self.meter_time >= 0.5) {
            self.fps = @as(f32, @floatFromInt(self.meter_frames)) / (self.time - self.meter_time);
            const images = self.renderer.device.presented.load(.monotonic);
            self.shown_fps = @as(f32, @floatFromInt(images - self.meter_presented)) / (self.time - self.meter_time);
            self.meter_presented = images;
            self.gpu_ms = 0;
            for (self.renderer.device.passTimings()) |timing| {
                if (timing.depth == 0) self.gpu_ms += timing.milliseconds;
            }
            self.meter_time = self.time;
            self.meter_frames = 0;
        }
    }

    /// Writes the screenshot if one was asked for, and shuts down.
    pub fn finish(self: *Stage) !void {
        const gpa = self.init.gpa;
        try self.renderer.device.waitIdle();
        if (self.screenshot) |path| {
            const pixels = try self.renderer.device.readTexture(gpa, self.offscreen.?);
            defer gpa.free(pixels);
            try gfx.png.write(gpa, self.init.io, path, .{ .width = width, .height = height, .pixels = pixels });
            gpa.free(path);
        }
        const failed = self.renderer.device.validationErrorCount() != 0;
        if (self.offscreen) |texture| self.renderer.destroyTarget(texture);
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
