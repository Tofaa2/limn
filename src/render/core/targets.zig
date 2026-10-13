//! Render targets that outlive a pass: pictures kept from frame to frame with
//! their history, and a pool of short-lived ones shared by descriptor.
const std = @import("std");
const rhi = @import("../../rhi/rhi.zig");

/// Frames a target may go unused before it is destroyed.
const idle_frames = 8;

fn sameShape(a: rhi.TextureDesc, b: rhi.TextureDesc) bool {
    return a.width == b.width and a.height == b.height and a.format == b.format and
        a.mip_levels == b.mip_levels and a.layers == b.layers and a.kind == b.kind and
        std.meta.eql(a.usage, b.usage);
}

/// This frame's picture of a kept target and, when it was drawn the frame
/// before at the same shape, last frame's.
pub const History = struct {
    current: rhi.Texture,
    previous: ?rhi.Texture,
};

/// One view's targets that are kept between frames, found by name. Asking
/// for one each frame keeps it; one that goes unasked is destroyed, so a
/// feature that is switched off gives its memory back and takes nothing
/// else's history with it.
pub const Kept = struct {
    entries: std.ArrayList(Entry) = .empty,

    const Entry = struct {
        name: [:0]const u8,
        desc: rhi.TextureDesc,
        textures: [2]?rhi.Texture = .{ null, null },
        turn: u1 = 0,
        /// Frame the entry was last asked for, and last given out as a
        /// history.
        asked: u64,
        drawn: ?u64 = null,
    };

    pub fn deinit(self: *Kept, gpa: std.mem.Allocator, device: *rhi.Device) void {
        for (self.entries.items) |entry| release(device, entry);
        self.entries.deinit(gpa);
    }

    fn release(device: *rhi.Device, entry: Entry) void {
        for (entry.textures) |texture| if (texture) |made| device.destroyTexture(made);
    }

    fn find(self: *Kept, gpa: std.mem.Allocator, device: *rhi.Device, desc: rhi.TextureDesc, frame: u64) !*Entry {
        for (self.entries.items) |*entry| {
            if (!std.mem.eql(u8, entry.name, desc.name)) continue;
            if (!sameShape(entry.desc, desc)) {
                release(device, entry.*);
                entry.* = .{ .name = desc.name, .desc = desc, .asked = frame };
            }
            entry.asked = frame;
            return entry;
        }
        try self.entries.append(gpa, .{ .name = desc.name, .desc = desc, .asked = frame });
        return &self.entries.items[self.entries.items.len - 1];
    }

    /// The target named `desc.name`, made on first use and again when its
    /// shape changes. Its contents stay from frame to frame.
    pub fn single(self: *Kept, gpa: std.mem.Allocator, device: *rhi.Device, desc: rhi.TextureDesc, frame: u64) !rhi.Texture {
        const entry = try self.find(gpa, device, desc, frame);
        if (entry.textures[0] == null) entry.textures[0] = try device.createTexture(desc);
        return entry.textures[0].?;
    }

    /// A target to draw this frame's picture into and the one drawn last
    /// frame. Call once a frame. `previous` is null on first use, after a
    /// change of shape and after a frame in which it was not asked for.
    pub fn history(self: *Kept, gpa: std.mem.Allocator, device: *rhi.Device, desc: rhi.TextureDesc, frame: u64) !History {
        const entry = try self.find(gpa, device, desc, frame);
        for (&entry.textures) |*texture| {
            if (texture.* == null) texture.* = try device.createTexture(desc);
        }
        const continuous = if (entry.drawn) |drawn| drawn +% 1 == frame else false;
        const previous = entry.textures[entry.turn].?;
        entry.turn ^= 1;
        entry.drawn = frame;
        return .{ .current = entry.textures[entry.turn].?, .previous = if (continuous) previous else null };
    }

    /// Whether `history` would hand out a last frame's picture for `name`.
    pub fn continues(self: *const Kept, name: []const u8, frame: u64) bool {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return if (entry.drawn) |drawn| drawn +% 1 == frame else false;
        }
        return false;
    }

    /// The picture `history` handed out for `name` this frame.
    pub fn latest(self: *const Kept, name: []const u8, frame: u64) ?rhi.Texture {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.name, name) and entry.drawn == frame) return entry.textures[entry.turn];
        }
        return null;
    }

    /// Forgets every history, as when the camera cuts.
    pub fn invalidate(self: *Kept) void {
        for (self.entries.items) |*entry| entry.drawn = null;
    }

    /// Destroys what has not been asked for lately.
    pub fn collect(self: *Kept, device: *rhi.Device, frame: u64) void {
        var index: usize = 0;
        while (index < self.entries.items.len) {
            const entry = self.entries.items[index];
            if (frame -% entry.asked <= idle_frames) {
                index += 1;
                continue;
            }
            release(device, entry);
            _ = self.entries.swapRemove(index);
        }
    }
};

/// Targets that live for part of a frame, shared between every pass and
/// view that asks for the same shape.
pub const Pool = struct {
    entries: std.ArrayList(Entry) = .empty,

    const Entry = struct {
        desc: rhi.TextureDesc,
        texture: rhi.Texture,
        taken: bool = false,
        used: u64,
    };

    pub fn deinit(self: *Pool, gpa: std.mem.Allocator, device: *rhi.Device) void {
        for (self.entries.items) |entry| device.destroyTexture(entry.texture);
        self.entries.deinit(gpa);
    }

    /// A target of the shape of `desc` that no one else holds. Its contents
    /// are undefined.
    pub fn acquire(self: *Pool, gpa: std.mem.Allocator, device: *rhi.Device, desc: rhi.TextureDesc, frame: u64) !rhi.Texture {
        for (self.entries.items) |*entry| {
            if (entry.taken or !sameShape(entry.desc, desc)) continue;
            entry.taken = true;
            entry.used = frame;
            return entry.texture;
        }
        const texture = try device.createTexture(desc);
        errdefer device.destroyTexture(texture);
        try self.entries.append(gpa, .{ .desc = desc, .texture = texture, .taken = true, .used = frame });
        return texture;
    }

    pub fn release(self: *Pool, texture: rhi.Texture) void {
        for (self.entries.items) |*entry| {
            if (std.meta.eql(entry.texture, texture)) entry.taken = false;
        }
    }

    /// Destroys what has not been used lately. Call once a frame.
    pub fn collect(self: *Pool, device: *rhi.Device, frame: u64) void {
        var index: usize = 0;
        while (index < self.entries.items.len) {
            const entry = self.entries.items[index];
            if (entry.taken or frame -% entry.used <= idle_frames) {
                index += 1;
                continue;
            }
            device.destroyTexture(entry.texture);
            _ = self.entries.swapRemove(index);
        }
    }
};
