//! Fluid volumes and the pictures saved from them. Internal to the renderer.
const std = @import("std");
const handle = @import("../../handle.zig");
const rhi = @import("../../rhi/rhi.zig");
const png = @import("../../png.zig");
const gpu = @import("../gpu.zig");
const api = @import("../api.zig");
const renderer_state = @import("../state.zig");
const render = @import("../renderer.zig");

const Renderer = render.Renderer;
const Scene = api.Scene;
const Fluid = api.Fluid;
const Image = api.Image;
const FluidFlipbookDesc = api.FluidFlipbookDesc;
const FluidDesc = api.FluidDesc;
const hdr_format = renderer_state.hdr_format;
const max_fluids = renderer_state.max_fluids;
const FluidState = renderer_state.FluidState;

/// Boxes of simulated smoke and fire.
pub const Fluids = struct {
    table: handle.HandleTable(renderer_state.FluidState, api.FluidTag),

    fn renderer(fluids: *Fluids) *Renderer {
        return @alignCast(@fieldParentPtr("fluids", fluids));
    }

    /// Adds a box of GPU-simulated smoke and fire to a scene.
    pub fn create(fluids: *Fluids, scene: Scene, desc: FluidDesc) !Fluid {
        const self = fluids.renderer();
        self.lock();
        defer self.unlock();
        const data = self.scenes.table.get(scene) orelse return error.InvalidScene;
        if (data.fluids.items.len == max_fluids) return error.TooManyFluids;
        if (desc.sources.len > gpu.max_fluid_sources) return error.TooManyFluidSources;
        if (desc.obstacles.len > gpu.max_fluid_obstacles) return error.TooManyFluidObstacles;
        var state = FluidState{ .scene = scene, .desc = desc };
        state.setSources(desc.sources);
        try createFluidTextures(self, &state);
        errdefer destroyFluidTextures(self, &state);
        const fluid = try self.fluids.table.insert(state);
        errdefer _ = self.fluids.table.remove(fluid);
        try data.fluids.append(self.gpa, fluid);
        return fluid;
    }

    /// Replaces a fluid's description. Changing the resolution restarts the
    /// simulation.
    pub fn set(fluids: *Fluids, fluid: Fluid, desc: FluidDesc) !void {
        const self = fluids.renderer();
        self.lock();
        defer self.unlock();
        const state = self.fluids.table.get(fluid) orelse return;
        if (desc.sources.len > gpu.max_fluid_sources) return error.TooManyFluidSources;
        if (desc.obstacles.len > gpu.max_fluid_obstacles) return error.TooManyFluidObstacles;
        const resized = !std.mem.eql(u32, &desc.resolution, &state.desc.resolution);
        state.desc = desc;
        state.setSources(desc.sources);
        if (resized) {
            destroyFluidTextures(self, state);
            try createFluidTextures(self, state);
        }
    }

    /// Empties a fluid: no smoke, no heat, no motion.
    pub fn reset(fluids: *Fluids, fluid: Fluid) void {
        const self = fluids.renderer();
        self.lock();
        defer self.unlock();
        if (self.fluids.table.get(fluid)) |state| state.cleared = false;
    }

    /// The fluid seen along its depth (smoke as coverage, fire as glow),
    /// redrawn each frame its scene renders. `resolution` pixels in size;
    /// lasts as long as the fluid.
    pub fn image(fluids: *Fluids, fluid: Fluid) !Image {
        const self = fluids.renderer();
        self.lock();
        defer self.unlock();
        const state = self.fluids.table.get(fluid) orelse return error.InvalidFluid;
        if (state.picture == null) {
            state.picture = try self.device.createTexture(.{
                .name = "fluid picture",
                .width = state.size[0],
                .height = state.size[1],
                .format = hdr_format,
                .usage = .{ .sampled = true, .color_attachment = true, .copy_src = true },
            });
            state.picture_drawn = false;
        }
        return .{ .index = self.device.textureIndex(state.picture.?), .width = state.size[0], .height = state.size[1] };
    }

    /// Saves the fluid's picture as a PNG with alpha. Waits for the GPU; call
    /// between frames, after `fluids.image` and at least one rendered frame.
    pub fn saveImage(fluids: *Fluids, fluid: Fluid, path: []const u8) !void {
        const self = fluids.renderer();
        self.lock();
        defer self.unlock();
        const state = self.fluids.table.get(fluid) orelse return error.InvalidFluid;
        const picture = state.picture orelse return error.NoFluidImage;
        try saveHdrPicture(self, picture, state.size[0], state.size[1], path);
    }

    /// Starts recording the fluid's picture into a `columns` x `rows` sheet,
    /// one frame every `interval` steps, row-major from the top left. The
    /// sheet lasts while the fluid keeps its resolution; calling again
    /// restarts it.
    pub fn recordFlipbook(fluids: *Fluids, fluid: Fluid, desc: FluidFlipbookDesc) !Image {
        const self = fluids.renderer();
        self.lock();
        defer self.unlock();
        const state = self.fluids.table.get(fluid) orelse return error.InvalidFluid;
        if (desc.columns == 0 or desc.rows == 0) return error.InvalidFlipbook;
        const frame = desc.frame_size orelse [2]u32{ state.size[0], state.size[1] };
        const width = frame[0] * desc.columns;
        const height = frame[1] * desc.rows;
        if (frame[0] == 0 or frame[1] == 0 or width > 16384 or height > 16384) return error.InvalidFlipbook;
        const old = state.flipbook_desc;
        if (state.flipbook == null or old.columns != desc.columns or old.rows != desc.rows or !std.meta.eql(state.flipbook_frame, frame)) {
            const sheet = try self.device.createTexture(.{
                .name = "fluid flipbook",
                .width = width,
                .height = height,
                .format = hdr_format,
                .usage = .{ .sampled = true, .color_attachment = true, .copy_src = true },
            });
            if (state.flipbook) |texture| self.device.destroyTexture(texture);
            state.flipbook = sheet;
        }
        state.flipbook_desc = desc;
        state.flipbook_frame = frame;
        state.flipbook_recorded = 0;
        state.flipbook_wait = 0;
        return .{ .index = self.device.textureIndex(state.flipbook.?), .width = width, .height = height };
    }

    /// Flipbook frames recorded so far; `columns * rows` when full.
    pub fn flipbookFrames(fluids: *Fluids, fluid: Fluid) u32 {
        const self = fluids.renderer();
        self.lock();
        defer self.unlock();
        const state = self.fluids.table.get(fluid) orelse return 0;
        return state.flipbook_recorded;
    }

    /// Saves the flipbook as recorded so far as a PNG with alpha. Waits for
    /// the GPU; call between frames.
    pub fn saveFlipbook(fluids: *Fluids, fluid: Fluid, path: []const u8) !void {
        const self = fluids.renderer();
        self.lock();
        defer self.unlock();
        const state = self.fluids.table.get(fluid) orelse return error.InvalidFluid;
        const sheet = state.flipbook orelse return error.NoFluidImage;
        if (state.flipbook_recorded == 0) return error.NoFluidImage;
        try saveHdrPicture(self, sheet, state.flipbook_frame[0] * state.flipbook_desc.columns, state.flipbook_frame[1] * state.flipbook_desc.rows, path);
    }

    /// A stale handle is ignored.
    pub fn destroy(fluids: *Fluids, fluid: Fluid) void {
        const self = fluids.renderer();
        self.lock();
        defer self.unlock();
        var removed = self.fluids.table.remove(fluid) orelse return;
        destroyFluidTextures(self, &removed);
        const scene = self.scenes.table.get(removed.scene) orelse return;
        for (scene.fluids.items, 0..) |item, index| if (std.meta.eql(item, fluid)) {
            _ = scene.fluids.orderedRemove(index);
            break;
        };
    }
};

/// Writes a half-float, linear, straight-alpha texture as an 8-bit
/// sRGB PNG.
fn saveHdrPicture(self: *Renderer, texture: rhi.Texture, width: u32, height: u32, path: []const u8) !void {
    const raw = try self.device.readTexture(self.gpa, texture);
    defer self.gpa.free(raw);
    const count = @as(usize, width) * height;
    const pixels = try self.gpa.alloc(u8, count * 4);
    defer self.gpa.free(pixels);
    for (0..count) |index| {
        inline for (0..4) |channel| {
            const half: f16 = @bitCast(std.mem.readInt(u16, raw[index * 8 + channel * 2 ..][0..2], .little));
            const value = std.math.clamp(@as(f32, half), 0, 1);
            const encoded = if (channel == 3) value else if (value <= 0.0031308) value * 12.92 else 1.055 * std.math.pow(f32, value, 1.0 / 2.4) - 0.055;
            pixels[index * 4 + channel] = @intFromFloat(encoded * 255 + 0.5);
        }
    }
    try png.write(self.gpa, self.io, path, .{ .width = width, .height = height, .pixels = pixels });
}

fn createFluidTextures(self: *Renderer, state: *FluidState) !void {
    const device = self.device;
    inline for (0..3) |axis| state.size[axis] = std.math.clamp(state.desc.resolution[axis], if (axis == 2) 1 else 8, 256);
    state.tiles_x = @intFromFloat(@ceil(@sqrt(@as(f32, @floatFromInt(state.size[2])))));
    const tiles_y = (state.size[2] + state.tiles_x - 1) / state.tiles_x;
    const width = state.size[0] * state.tiles_x;
    const height = state.size[1] * tiles_y;
    const usage = rhi.TextureUsage{ .sampled = true, .color_attachment = true };
    var made: usize = 0;
    const textures = state.textures();
    errdefer for (textures[0..made]) |texture| device.destroyTexture(texture.*);
    for (textures, 0..) |texture, index| {
        texture.* = try device.createTexture(.{
            .name = "fluid",
            .width = width,
            .height = height,
            .format = if (index == 8) .r8_unorm else if (index >= 4 and index < 7) .rg16_float else .rgba16_float,
            .usage = usage,
        });
        made += 1;
    }
    state.cleared = false;
    state.current = 0;
}

pub fn destroyFluidTextures(self: *Renderer, state: *FluidState) void {
    for (state.textures()) |texture| self.device.destroyTexture(texture.*);
    if (state.picture) |texture| self.device.destroyTexture(texture);
    if (state.flipbook) |texture| self.device.destroyTexture(texture);
    state.flipbook = null;
    state.picture = null;
}
