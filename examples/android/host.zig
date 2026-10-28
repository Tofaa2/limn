//! Runs an example as an Android `NativeActivity`: unpacks its assets into
//! the app's files directory on first start, then calls the example's
//! `main` on its own thread with the activity's window behind the GLFW
//! stand-in in `glfw.zig`.
const std = @import("std");
const glfw = @import("glfw");
const example = @import("example");

const ANativeActivity = extern struct {
    callbacks: *Callbacks,
    vm: ?*anyopaque,
    env: ?*anyopaque,
    clazz: ?*anyopaque,
    internal_data_path: [*:0]const u8,
    external_data_path: ?[*:0]const u8,
    sdk_version: i32,
    instance: ?*anyopaque,
    asset_manager: *AAssetManager,
    obb_path: ?[*:0]const u8,
};

const Activity = *ANativeActivity;
const Callbacks = extern struct {
    on_start: ?*const fn (Activity) callconv(.c) void,
    on_resume: ?*const fn (Activity) callconv(.c) void,
    on_save_instance_state: ?*const fn (Activity, *usize) callconv(.c) ?*anyopaque,
    on_pause: ?*const fn (Activity) callconv(.c) void,
    on_stop: ?*const fn (Activity) callconv(.c) void,
    on_destroy: ?*const fn (Activity) callconv(.c) void,
    on_window_focus_changed: ?*const fn (Activity, c_int) callconv(.c) void,
    on_native_window_created: ?*const fn (Activity, *glfw.ANativeWindow) callconv(.c) void,
    on_native_window_resized: ?*const fn (Activity, *glfw.ANativeWindow) callconv(.c) void,
    on_native_window_redraw_needed: ?*const fn (Activity, *glfw.ANativeWindow) callconv(.c) void,
    on_native_window_destroyed: ?*const fn (Activity, *glfw.ANativeWindow) callconv(.c) void,
    on_input_queue_created: ?*const fn (Activity, *glfw.AInputQueue) callconv(.c) void,
    on_input_queue_destroyed: ?*const fn (Activity, *glfw.AInputQueue) callconv(.c) void,
    on_content_rect_changed: ?*const fn (Activity, *const anyopaque) callconv(.c) void,
    on_configuration_changed: ?*const fn (Activity) callconv(.c) void,
    on_low_memory: ?*const fn (Activity) callconv(.c) void,
};

const AAssetManager = opaque {};
const AAsset = opaque {};
extern fn AAssetManager_open(manager: *AAssetManager, name: [*:0]const u8, mode: c_int) ?*AAsset;
extern fn AAsset_getBuffer(asset: *AAsset) ?*const anyopaque;
extern fn AAsset_getLength64(asset: *AAsset) i64;
extern fn AAsset_close(asset: *AAsset) void;
extern fn __android_log_write(priority: c_int, tag: [*:0]const u8, text: [*:0]const u8) c_int;

pub const std_options: std.Options = .{ .logFn = log };

/// Sends `std.log` to logcat, under the tag "limn".
fn log(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    var buffer: [2048]u8 = undefined;
    const prefix = if (scope == .default) "" else @tagName(scope) ++ ": ";
    const text = std.fmt.bufPrintZ(&buffer, prefix ++ format, args) catch buffer[0 .. buffer.len - 1 :0];
    const priority: c_int = switch (level) {
        .err => 6,
        .warn => 5,
        .info => 4,
        .debug => 3,
    };
    _ = __android_log_write(priority, "limn", text.ptr);
}

var threaded: std.Io.Threaded = undefined;
var arena: std.heap.ArenaAllocator = undefined;
var environ_map: std.process.Environ.Map = undefined;
var thread: ?std.Thread = null;
const argv = [_][*:0]const u8{"limn"};

export fn ANativeActivity_onCreate(activity: Activity, _: ?*anyopaque, _: usize) void {
    activity.callbacks.on_native_window_created = windowCreated;
    activity.callbacks.on_native_window_destroyed = windowDestroyed;
    activity.callbacks.on_input_queue_created = queueCreated;
    activity.callbacks.on_input_queue_destroyed = queueDestroyed;
    activity.callbacks.on_destroy = destroyed;
    if (thread != null) return;
    const gpa = std.heap.c_allocator;
    threaded = .init(gpa, .{});
    glfw.app.io = threaded.io();
    arena = .init(std.heap.page_allocator);
    environ_map = .init(gpa);
    thread = std.Thread.spawn(.{}, run, .{activity}) catch |err| {
        std.log.err("could not start the example: {t}", .{err});
        return;
    };
}

fn run(activity: Activity) void {
    const io = glfw.app.io;
    unpackAssets(activity) catch |err| std.log.err("could not unpack the assets: {t}", .{err});
    const init: std.process.Init = .{
        .minimal = .{ .args = .{ .vector = &argv }, .environ = .empty },
        .arena = &arena,
        .gpa = std.heap.c_allocator,
        .io = io,
        .environ_map = &environ_map,
        .preopens = .empty,
    };
    example.main(init) catch |err| std.log.err("the example failed: {t}", .{err});
    glfw.app.using.store(false, .release);
    std.process.exit(0);
}

/// Moves into the app's files directory and writes each file
/// `assets/limn_files.txt` lists there, unless it is already the same size.
fn unpackAssets(activity: Activity) !void {
    const io = glfw.app.io;
    const root = std.mem.span(activity.internal_data_path);
    var directory = try std.Io.Dir.cwd().openDir(io, root, .{});
    defer directory.close(io);
    try std.process.setCurrentDir(io, directory);
    const listing = AAssetManager_open(activity.asset_manager, "limn_files.txt", 3) orelse return;
    defer AAsset_close(listing);
    const names = assetBytes(listing) orelse return;
    var lines = std.mem.tokenizeScalar(u8, names, '\n');
    var name_buffer: [std.fs.max_path_bytes]u8 = undefined;
    while (lines.next()) |name| {
        const asset = AAssetManager_open(activity.asset_manager, try std.fmt.bufPrintZ(&name_buffer, "{s}", .{name}), 3) orelse continue;
        defer AAsset_close(asset);
        const bytes = assetBytes(asset) orelse continue;
        if (directory.statFile(io, name, .{})) |stat| {
            if (stat.size == bytes.len) continue;
        } else |_| {}
        if (std.fs.path.dirname(name)) |parent| try directory.createDirPath(io, parent);
        try directory.writeFile(io, .{ .sub_path = name, .data = bytes });
    }
}

fn assetBytes(asset: *AAsset) ?[]const u8 {
    const data: [*]const u8 = @ptrCast(AAsset_getBuffer(asset) orelse return null);
    return data[0..@intCast(AAsset_getLength64(asset))];
}

fn windowCreated(_: Activity, window: *glfw.ANativeWindow) callconv(.c) void {
    glfw.windowCreated(window);
}

fn windowDestroyed(_: Activity, _: *glfw.ANativeWindow) callconv(.c) void {
    glfw.windowDestroyed();
}

fn queueCreated(_: Activity, queue: *glfw.AInputQueue) callconv(.c) void {
    glfw.app.queue.store(queue, .release);
}

fn queueDestroyed(_: Activity, _: *glfw.AInputQueue) callconv(.c) void {
    glfw.queueDestroyed();
}

fn destroyed(_: Activity) callconv(.c) void {
    glfw.app.closing.store(true, .release);
}
