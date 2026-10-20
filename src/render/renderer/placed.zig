//! Single lights and decals of a scene by handle, beside setting a scene's
//! whole list at once. A handle keeps naming the same light while others come
//! and go. Internal to the renderer.
const std = @import("std");
const handle = @import("../../handle.zig");
const api = @import("../api.zig");
const render = @import("../renderer.zig");

const Renderer = render.Renderer;
const Scene = api.Scene;

/// Lights of scenes, one at a time.
pub const Lights = Placed(api.Light, api.LightTag, "lights", "light_handles", "lights", null);
/// Decals of scenes, one at a time.
pub const Decals = Placed(api.DecalDesc, api.DecalTag, "decals", "decal_handles", "decals", api.max_decals);

/// A namespace of `Item`s kept in each scene's list `list`, with the handle
/// of each in the scene's list `handles`; `field` is its name in `Renderer`.
/// A scene holds at most `limit`.
fn Placed(comptime Item: type, comptime Tag: type, comptime list: []const u8, comptime handles: []const u8, comptime field: []const u8, comptime limit: ?usize) type {
    return struct {
        const Self = @This();
        pub const Id = handle.Handle(Tag);

        table: handle.HandleTable(Entry, Tag),

        /// Where one is: its scene, and its place in the scene's list.
        pub const Entry = struct { scene: Scene, index: u32 };

        pub fn free(_: *Renderer, _: *Entry) void {}

        fn renderer(self: *Self) *Renderer {
            return @alignCast(@fieldParentPtr(field, self));
        }

        /// Adds one to `scene`.
        pub fn create(self: *Self, scene: Scene, item: Item) !Id {
            const owner = self.renderer();
            owner.lock();
            defer owner.unlock();
            const data = owner.scenes.table.get(scene) orelse return error.InvalidScene;
            const items = &@field(data, list);
            const ids = &@field(data, handles);
            if (limit) |most| if (items.items.len >= most) return error.TooMany;
            try pad(owner, data);
            try items.ensureUnusedCapacity(owner.internal.gpa, 1);
            try ids.ensureUnusedCapacity(owner.internal.gpa, 1);
            const id = try self.table.insert(.{ .scene = scene, .index = @intCast(items.items.len) });
            items.appendAssumeCapacity(item);
            ids.appendAssumeCapacity(id);
            changed(data);
            return id;
        }

        /// Replaces what `id` names. Ignores a destroyed handle.
        pub fn set(self: *Self, id: Id, item: Item) void {
            const owner = self.renderer();
            owner.lock();
            defer owner.unlock();
            const entry = self.table.get(id) orelse return;
            const data = owner.scenes.table.get(entry.scene) orelse return;
            @field(data, list).items[entry.index] = item;
            changed(data);
        }

        /// Removes what `id` names from its scene. Ignores a destroyed handle.
        pub fn destroy(self: *Self, id: Id) void {
            const owner = self.renderer();
            owner.lock();
            defer owner.unlock();
            const entry = self.table.remove(id) orelse return;
            const data = owner.scenes.table.get(entry.scene) orelse return;
            pad(owner, data) catch return;
            const items = &@field(data, list);
            const ids = &@field(data, handles);
            _ = items.swapRemove(entry.index);
            _ = ids.swapRemove(entry.index);
            if (entry.index < ids.items.len) if (ids.items[entry.index]) |moved| {
                if (self.table.get(moved)) |place| place.index = entry.index;
            };
            changed(data);
        }

        /// Forgets the handles into `data`'s list before it is replaced or
        /// freed; they name nothing from here on.
        pub fn forget(self: *Self, data: anytype) void {
            for (@field(data, handles).items) |maybe| if (maybe) |id| {
                _ = self.table.remove(id);
            };
            @field(data, handles).clearRetainingCapacity();
        }

        /// Gives every item of `data`'s list a place in its list of handles;
        /// those set all at once have none.
        fn pad(owner: *Renderer, data: anytype) !void {
            const ids = &@field(data, handles);
            while (ids.items.len < @field(data, list).items.len) try ids.append(owner.internal.gpa, null);
        }

        fn changed(data: anytype) void {
            if (@hasField(@TypeOf(data.*), list ++ "_version")) @field(data, list ++ "_version") += 1;
        }
    };
}
