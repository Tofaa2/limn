//! The part of GLFW the examples use, on Android: the `NativeActivity`'s
//! window, touch for the cursor and a held finger pair for the forward key,
//! and the back button for escape. `host.zig` feeds it from the activity's
//! callbacks; the example's thread reads it.
const std = @import("std");

pub const GLFWwindow = opaque {};

pub const GLFW_TRUE = 1;
pub const GLFW_FALSE = 0;
pub const GLFW_PRESS = 1;
pub const GLFW_RELEASE = 0;
pub const GLFW_CLIENT_API = 0x00022001;
pub const GLFW_NO_API = 0;
pub const GLFW_RESIZABLE = 0x00020003;
pub const GLFW_CURSOR = 0x00033001;
pub const GLFW_CURSOR_NORMAL = 0x00034001;
pub const GLFW_CURSOR_DISABLED = 0x00034003;
pub const GLFW_PLATFORM_X11 = 0x00060004;
pub const GLFW_PLATFORM_WAYLAND = 0x00060003;
pub const GLFW_KEY_SPACE = 32;
pub const GLFW_KEY_0 = 48;
pub const GLFW_KEY_1 = 49;
pub const GLFW_KEY_2 = 50;
pub const GLFW_KEY_3 = 51;
pub const GLFW_KEY_4 = 52;
pub const GLFW_KEY_5 = 53;
pub const GLFW_KEY_6 = 54;
pub const GLFW_KEY_7 = 55;
pub const GLFW_KEY_8 = 56;
pub const GLFW_KEY_9 = 57;
pub const GLFW_KEY_A = 65;
pub const GLFW_KEY_B = 66;
pub const GLFW_KEY_C = 67;
pub const GLFW_KEY_D = 68;
pub const GLFW_KEY_E = 69;
pub const GLFW_KEY_F = 70;
pub const GLFW_KEY_G = 71;
pub const GLFW_KEY_H = 72;
pub const GLFW_KEY_I = 73;
pub const GLFW_KEY_L = 76;
pub const GLFW_KEY_M = 77;
pub const GLFW_KEY_N = 78;
pub const GLFW_KEY_O = 79;
pub const GLFW_KEY_P = 80;
pub const GLFW_KEY_Q = 81;
pub const GLFW_KEY_R = 82;
pub const GLFW_KEY_S = 83;
pub const GLFW_KEY_T = 84;
pub const GLFW_KEY_U = 85;
pub const GLFW_KEY_V = 86;
pub const GLFW_KEY_W = 87;
pub const GLFW_KEY_X = 88;
pub const GLFW_KEY_Z = 90;
pub const GLFW_KEY_ESCAPE = 256;
pub const GLFW_KEY_TAB = 258;
pub const GLFW_KEY_RIGHT = 262;
pub const GLFW_KEY_LEFT = 263;
pub const GLFW_KEY_DOWN = 264;
pub const GLFW_KEY_UP = 265;
pub const GLFW_KEY_F5 = 294;
pub const GLFW_KEY_LEFT_SHIFT = 340;
pub const GLFW_KEY_LEFT_CONTROL = 341;
pub const GLFW_KEY_LAST = 348;

pub const ANativeWindow = opaque {};
pub const AInputQueue = opaque {};
pub const AInputEvent = opaque {};
extern fn ANativeWindow_getWidth(window: *ANativeWindow) i32;
extern fn ANativeWindow_getHeight(window: *ANativeWindow) i32;
extern fn AInputQueue_hasEvents(queue: *AInputQueue) i32;
extern fn AInputQueue_getEvent(queue: *AInputQueue, event: *?*AInputEvent) i32;
extern fn AInputQueue_preDispatchEvent(queue: *AInputQueue, event: *AInputEvent) i32;
extern fn AInputQueue_finishEvent(queue: *AInputQueue, event: *AInputEvent, handled: i32) void;
extern fn AInputEvent_getType(event: *const AInputEvent) i32;
extern fn AKeyEvent_getAction(event: *const AInputEvent) i32;
extern fn AKeyEvent_getKeyCode(event: *const AInputEvent) i32;
extern fn AMotionEvent_getAction(event: *const AInputEvent) i32;
extern fn AMotionEvent_getPointerCount(event: *const AInputEvent) usize;
extern fn AMotionEvent_getX(event: *const AInputEvent, pointer: usize) f32;
extern fn AMotionEvent_getY(event: *const AInputEvent, pointer: usize) f32;

/// What the window did since the example last looked.
pub const SurfaceChange = enum(u8) { none, lost, gained };

/// Shared between the activity's thread and the example's.
pub const App = struct {
    io: std.Io = undefined,
    window: std.atomic.Value(?*ANativeWindow) = .init(null),
    queue: std.atomic.Value(?*AInputQueue) = .init(null),
    change: std.atomic.Value(SurfaceChange) = .init(.none),
    /// Set by the example once it drew to the window: from then on a lost
    /// window waits for the example to let go of it.
    using: std.atomic.Value(bool) = .init(false),
    released: std.atomic.Value(bool) = .init(false),
    closing: std.atomic.Value(bool) = .init(false),
    /// Set while the example reads the input queue, which the activity
    /// must not destroy then.
    polling: std.atomic.Value(bool) = .init(false),
    cursor: [2]f64 = .{ 0, 0 },
    keys: [GLFW_KEY_LAST + 1]bool = @splat(false),
    start: std.Io.Timestamp = .zero,
};

pub var app: App = .{};

fn sleep() void {
    app.io.sleep(std.Io.Duration.fromMilliseconds(5), .awake) catch {};
}

pub fn glfwInit() c_int {
    app.start = std.Io.Timestamp.now(app.io, .awake);
    return GLFW_TRUE;
}

pub fn glfwTerminate() void {}

pub fn glfwWindowHint(_: c_int, _: c_int) void {}

/// Waits for the activity's window.
pub fn glfwCreateWindow(_: c_int, _: c_int, _: [*:0]const u8, _: ?*anyopaque, _: ?*anyopaque) ?*GLFWwindow {
    while (app.window.load(.acquire) == null) {
        if (app.closing.load(.acquire)) return null;
        sleep();
    }
    app.using.store(true, .release);
    return @ptrCast(&app);
}

pub fn glfwDestroyWindow(_: *GLFWwindow) void {
    app.using.store(false, .release);
}

pub fn glfwWindowShouldClose(_: *GLFWwindow) c_int {
    return @intFromBool(app.closing.load(.acquire));
}

pub fn glfwGetFramebufferSize(_: *GLFWwindow, width: *c_int, height: *c_int) void {
    const window = app.window.load(.acquire) orelse {
        width.* = 0;
        height.* = 0;
        return;
    };
    width.* = ANativeWindow_getWidth(window);
    height.* = ANativeWindow_getHeight(window);
}

pub fn glfwSetWindowSize(_: *GLFWwindow, _: c_int, _: c_int) void {}

pub fn glfwSetWindowTitle(_: *GLFWwindow, _: [*:0]const u8) void {}

pub fn glfwSetInputMode(_: *GLFWwindow, _: c_int, _: c_int) void {}

pub fn glfwGetTime() f64 {
    const elapsed = app.start.durationTo(std.Io.Timestamp.now(app.io, .awake));
    return @as(f64, @floatFromInt(elapsed.toNanoseconds())) / std.time.ns_per_s;
}

pub fn glfwGetKey(_: *GLFWwindow, key: c_int) c_int {
    return @intFromBool(app.keys[@intCast(key)]);
}

pub fn glfwGetCursorPos(_: *GLFWwindow, x: *f64, y: *f64) void {
    x.* = app.cursor[0];
    y.* = app.cursor[1];
}

/// Reads the activity's input queue: the first finger moves the cursor, a
/// second held down is the forward key, and back is escape.
pub fn glfwPollEvents() void {
    app.polling.store(true, .release);
    defer app.polling.store(false, .release);
    const queue = app.queue.load(.acquire) orelse return;
    while (AInputQueue_hasEvents(queue) > 0) {
        var event: ?*AInputEvent = null;
        if (AInputQueue_getEvent(queue, &event) < 0) return;
        const got = event orelse return;
        if (AInputQueue_preDispatchEvent(queue, got) != 0) continue;
        var handled = false;
        switch (AInputEvent_getType(got)) {
            1 => if (AKeyEvent_getKeyCode(got) == 4) {
                app.keys[GLFW_KEY_ESCAPE] = AKeyEvent_getAction(got) == 0;
                handled = true;
            },
            2 => {
                const action = AMotionEvent_getAction(got) & 0xff;
                app.cursor = .{ AMotionEvent_getX(got, 0), AMotionEvent_getY(got, 0) };
                app.keys[GLFW_KEY_W] = action != 1 and action != 3 and AMotionEvent_getPointerCount(got) >= 2;
                handled = true;
            },
            else => {},
        }
        AInputQueue_finishEvent(queue, got, @intFromBool(handled));
    }
}

/// The activity's window, for the renderer's surface.
pub fn androidWindow() ?*ANativeWindow {
    return app.window.load(.acquire);
}

/// What happened to the window since the last call.
pub fn surfaceChange() SurfaceChange {
    return app.change.swap(.none, .acq_rel);
}

/// The example stopped presenting to the lost window; Android may now
/// destroy it. Then waits for the next one, and returns false if the
/// activity ends first.
pub fn surfaceReleased() bool {
    app.released.store(true, .release);
    while (true) {
        if (app.closing.load(.acquire)) return false;
        if (app.change.load(.acquire) == .gained) {
            _ = app.change.swap(.none, .acq_rel);
            return true;
        }
        sleep();
    }
}

/// From the activity: a window to draw to.
pub fn windowCreated(window: *ANativeWindow) void {
    const had = app.using.load(.acquire);
    app.window.store(window, .release);
    if (had) app.change.store(.gained, .release);
}

/// From the activity: the input queue is going away. Returns once the
/// example is not reading it.
pub fn queueDestroyed() void {
    app.queue.store(null, .release);
    while (app.polling.load(.acquire)) sleep();
}

/// From the activity: the window is going away. Returns once the example
/// no longer presents to it.
pub fn windowDestroyed() void {
    if (app.using.load(.acquire)) {
        app.released.store(false, .release);
        app.change.store(.lost, .release);
        while (!app.released.load(.acquire) and app.using.load(.acquire)) sleep();
    }
    app.window.store(null, .release);
}
