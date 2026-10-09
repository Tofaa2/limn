//! Renderer state kept between calls: GPU buffer allocators, loaded
//! assets, scenes, views and per-effect state. Internal to the renderer.
const std = @import("std");
const rhi = @import("../rhi/rhi.zig");
const math = @import("../math.zig");
const gltf = @import("../asset/gltf.zig");
const ktx2 = @import("../asset/ktx2.zig");
const texture_codec = @import("texture_codec");
const shader_sources = @import("shader_sources");
const png = @import("../png.zig");
const gpu = @import("gpu.zig");
const animation = @import("animation.zig");
const bvh = @import("bvh.zig");
const handle = @import("../handle.zig");
const draw_list = @import("draw_list.zig");
const font_module = @import("font_baker").font;
const text_layout = @import("text_layout.zig");
const render = @import("renderer.zig");

const Profiler = render.Profiler;
const EffectResolution = render.EffectResolution;
const AssetState = render.AssetState;
const Camera = render.Camera;
const CascadeCache = render.CascadeCache;
const CloudDesc = render.CloudDesc;
const DecalDesc = render.DecalDesc;
const Emitter = render.Emitter;
const EmitterDesc = render.EmitterDesc;
const Entity = render.Entity;
const Environment = render.Environment;
const Fluid = render.Fluid;
const FluidDesc = render.FluidDesc;
const FluidFlipbookDesc = render.FluidFlipbookDesc;
const FluidObstacle = render.FluidObstacle;
const FluidSource = render.FluidSource;
const Image = render.Image;
const InstanceGroup = render.InstanceGroup;
const Light = render.Light;
const Liquid = render.Liquid;
const LiquidDesc = render.LiquidDesc;
const LiquidSource = render.LiquidSource;
const Mat4 = render.Mat4;
const Model = render.Model;
const ModelInfo = render.ModelInfo;
const Pose = render.Pose;
const ReflectionProbe = render.ReflectionProbe;
const ReflectionProbeDesc = render.ReflectionProbeDesc;
const Region = render.Region;
const Renderer = render.Renderer;
const Scene = render.Scene;
const SceneFrame = render.SceneFrame;
const SkyDesc = render.SkyDesc;
const Sun = render.Sun;
const Vec3 = render.Vec3;
const View = render.View;
const Water = render.Water;
const WaterDesc = render.WaterDesc;
const scene_color_format = render.scene_color_format;
const shaderCode = render.shaderCode;

pub const hdr_format = scene_color_format;
pub const bloom_format: rhi.Format = .b10g11r11_float;
/// Most levels a bloom chain can have; see `Settings.bloom_levels`.
pub const bloom_levels = 6;
pub const ao_depth_mips = 5;
/// Culling views of a frame: main view, shadow cascades, the main view's
/// late (post-occlusion) phase, local light shadows and VSM pages.
pub const view_count = 2 + gpu.cascade_count + max_local_shadow_views + gpu.vsm_pages_per_frame;
pub const main_late_view = 1 + gpu.cascade_count;
pub const local_view_base = main_late_view + 1;
/// Most shadow-casting views (atlas tiles) local lights share.
pub const max_local_shadow_views = 16;
pub const vsm_view_base = local_view_base + max_local_shadow_views;
/// Movers listed per scene; beyond this the whole scene counts as moving.
pub const max_movers = 256;

pub const local_shadow_tiles_per_side = 4;
/// Clusters are spaced exponentially in depth between these distances.
pub const cluster_near: f32 = 0.3;
pub const cluster_far: f32 = 200;
pub const cluster_z_scale: f32 = @as(f32, gpu.clusters_z) / @log2(cluster_far / cluster_near);
pub const env_cube_size = 512;
pub const env_specular_size = 256;
pub const env_specular_mips = 6;
pub const env_irradiance_size = 32;
pub const stream_budget_bytes = 48 * 1024 * 1024;

pub const Range = struct { offset: u32, count: u32 };

/// First-fit range allocator over element indices with coalescing frees.
pub const RangeAllocator = struct {
    free_ranges: std.ArrayList(Range) = .empty,
    top: u32 = 0,
    capacity: u32,

    pub fn alloc(self: *RangeAllocator, count: u32) ?u32 {
        for (self.free_ranges.items, 0..) |*range, index| {
            if (range.count < count) continue;
            const offset = range.offset;
            if (range.count == count) {
                _ = self.free_ranges.orderedRemove(index);
            } else {
                range.offset += count;
                range.count -= count;
            }
            return offset;
        }
        if (self.top + count > self.capacity) return null;
        defer self.top += count;
        return self.top;
    }

    pub fn free(self: *RangeAllocator, gpa: std.mem.Allocator, offset: u32, count: u32) void {
        if (count == 0) return;
        var index: usize = 0;
        while (index < self.free_ranges.items.len and self.free_ranges.items[index].offset < offset) index += 1;
        self.free_ranges.insert(gpa, index, .{ .offset = offset, .count = count }) catch return;
        if (index + 1 < self.free_ranges.items.len) {
            const next = self.free_ranges.items[index + 1];
            if (offset + count == next.offset) {
                self.free_ranges.items[index].count += next.count;
                _ = self.free_ranges.orderedRemove(index + 1);
            }
        }
        if (index > 0) {
            const previous = &self.free_ranges.items[index - 1];
            if (previous.offset + previous.count == offset) {
                previous.count += self.free_ranges.items[index].count;
                _ = self.free_ranges.orderedRemove(index);
            }
        }
        if (self.free_ranges.items.len != 0) {
            const last = self.free_ranges.items[self.free_ranges.items.len - 1];
            if (last.offset + last.count == self.top) {
                self.top = last.offset;
                _ = self.free_ranges.pop();
            }
        }
    }
};

/// A growable GPU array shared by every model (vertices, indices, ...).
pub const Pool = struct {
    name: [:0]const u8,
    stride: u32,
    buffer: rhi.Buffer,
    ranges: RangeAllocator,
    usage: rhi.BufferUsage,
    /// Initial size; the pool never shrinks below it.
    minimum: u32,

    pub fn init(device: *rhi.Device, name: [:0]const u8, stride: u32, capacity: u32, usage: rhi.BufferUsage) !Pool {
        return .{
            .name = name,
            .stride = stride,
            .buffer = try device.createBuffer(.{ .name = name, .size = @as(u64, capacity) * stride, .usage = usage }),
            .ranges = .{ .capacity = capacity },
            .usage = usage,
            .minimum = capacity,
        };
    }

    pub fn deinit(self: *Pool, renderer: *Renderer) void {
        renderer.device.destroyBuffer(self.buffer);
        self.ranges.free_ranges.deinit(renderer.gpa);
    }

    pub fn alloc(self: *Pool, renderer: *Renderer, count: u32) !u32 {
        if (count == 0) return 0;
        if (self.ranges.alloc(count)) |offset| return offset;
        const device = renderer.device;
        const old_capacity = self.ranges.capacity;
        const new_capacity = @max(old_capacity * 2, self.ranges.top + count);
        const new_buffer = try device.createBuffer(.{
            .name = self.name,
            .size = @as(u64, new_capacity) * self.stride,
            .usage = self.usage,
        });
        if (self.ranges.top != 0) {
            errdefer device.destroyBuffer(new_buffer);
            try device.queueBufferCopy(self.buffer, new_buffer, @as(u64, self.ranges.top) * self.stride);
        } else device.destroyBuffer(self.buffer);
        self.buffer = new_buffer;
        self.ranges.capacity = new_capacity;
        return self.ranges.alloc(count).?;
    }

    pub fn free(self: *Pool, renderer: *Renderer, offset: u32, count: u32) void {
        self.ranges.free(renderer.gpa, offset, count);
        self.trim(renderer) catch {};
    }

    /// Moves to a smaller buffer once at most a quarter is in use, measured
    /// to the last element. Elements keep their indices.
    pub fn trim(self: *Pool, renderer: *Renderer) !void {
        const capacity = self.ranges.capacity;
        if (capacity <= self.minimum or @as(u64, self.ranges.top) * 4 > capacity) return;
        const new_capacity = @max(self.minimum, self.ranges.top * 2);
        if (new_capacity >= capacity) return;
        const device = renderer.device;
        const new_buffer = try device.createBuffer(.{
            .name = self.name,
            .size = @as(u64, new_capacity) * self.stride,
            .usage = self.usage,
        });
        if (self.ranges.top != 0) {
            errdefer device.destroyBuffer(new_buffer);
            try device.queueBufferCopy(self.buffer, new_buffer, @as(u64, self.ranges.top) * self.stride);
        } else device.destroyBuffer(self.buffer);
        self.buffer = new_buffer;
        self.ranges.capacity = new_capacity;
    }

    pub fn write(self: *Pool, device: *rhi.Device, offset: u32, bytes: []const u8) !void {
        try device.uploadBuffer(self.buffer, @as(u64, offset) * self.stride, bytes);
    }
};

pub const arena_usage = rhi.BufferUsage{ .storage = true, .acceleration_input = true, .copy_src = true };

/// Bump allocator over a mapped buffer for data rewritten every frame.
pub const FrameArena = struct {
    buffer: rhi.Buffer,
    capacity: u64,
    cursor: u64 = 0,
    /// Buffers outgrown this frame, kept until `reset`.
    outgrown: [16]?rhi.Buffer = @splat(null),

    pub fn Allocation(comptime T: type) type {
        return struct {
            address: u64,
            items: []T,
            /// Not always the arena's current buffer.
            buffer: rhi.Buffer,
            offset: u64,
        };
    }

    pub fn init(device: *rhi.Device, capacity: u64) !FrameArena {
        return .{
            .buffer = try device.createBuffer(.{ .name = "frame arena", .size = capacity, .usage = arena_usage, .memory = .cpu_to_gpu }),
            .capacity = capacity,
        };
    }

    pub fn reset(self: *FrameArena, device: *rhi.Device) void {
        self.cursor = 0;
        for (&self.outgrown) |*slot| {
            if (slot.*) |buffer| device.destroyBuffer(buffer);
            slot.* = null;
        }
    }

    pub fn deinit(self: *FrameArena, device: *rhi.Device) void {
        self.reset(device);
        device.destroyBuffer(self.buffer);
    }

    /// Room for `count` values of `T`, valid until the next `reset`.
    pub fn alloc(self: *FrameArena, device: *rhi.Device, comptime T: type, count: usize) !Allocation(T) {
        const size = @sizeOf(T) * @max(count, 1);
        var offset = std.mem.alignForward(u64, self.cursor, 16);
        if (offset + size > self.capacity) {
            const capacity = @max(self.capacity * 2, size * 2);
            const buffer = try device.createBuffer(.{ .name = "frame arena", .size = capacity, .usage = arena_usage, .memory = .cpu_to_gpu });
            for (&self.outgrown) |*slot| {
                if (slot.* != null) continue;
                slot.* = self.buffer;
                break;
            } else {
                device.destroyBuffer(buffer);
                return error.FrameArenaExhausted;
            }
            self.buffer = buffer;
            self.capacity = capacity;
            offset = 0;
        }
        self.cursor = offset + size;
        const bytes = device.mapped(self.buffer)[@intCast(offset)..][0..size];
        return .{
            .address = device.bufferAddress(self.buffer) + offset,
            .items = @as([*]T, @ptrCast(@alignCast(bytes.ptr)))[0..count],
            .buffer = self.buffer,
            .offset = offset,
        };
    }
};

pub const ModelJob = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []u8,
    options: gltf.LoadOptions = .{},
    group: std.Io.Group = .init,
    done: std.atomic.Value(bool) = .init(false),
    model: ?gltf.Model = null,
    failure: ?anyerror = null,
};

pub fn runModelJob(job: *ModelJob) std.Io.Cancelable!void {
    if (gltf.load(job.gpa, job.io, job.path, job.options)) |model| {
        job.model = model;
    } else |err| {
        if (err == error.Canceled) return error.Canceled;
        job.failure = err;
    }
    job.done.store(true, .release);
}

/// One build of the standard shading pass.
pub const ShadeVariant = struct {
    reflective: bool,
    features: u32,
    pipeline: ?rhi.Pipeline = null,
    job: ?*ShadeVariantJob = null,
};

pub const ShadeVariantJob = struct {
    device: *const rhi.Device,
    io: std.Io,
    reflective: bool,
    constants: [1]u32,
    group: std.Io.Group = .init,
    done: std.atomic.Value(bool) = .init(false),
    compiled: ?rhi.Device.CompiledPipeline = null,
    failure: ?anyerror = null,
};

pub fn shadeVariantDesc(device: *const rhi.Device, reflective: bool, constants: []const u32) rhi.GraphicsPipelineDesc {
    return .{
        .name = if (reflective) "shading (reflective, variant)" else "shading (variant)",
        .vertex = shaderCode("fullscreen.vert.spv"),
        .fragment = if (reflective)
            (if (device.ray_tracing) shaderCode("shade_rt.frag.spv") else shaderCode("shade.frag.spv"))
        else if (device.ray_tracing) shaderCode("shade_rt_plain.frag.spv") else shaderCode("shade_plain.frag.spv"),
        .color_targets = if (reflective) &shade_reflective_targets else &shade_plain_targets,
        .cull = .none,
        .fragment_constants = constants,
    };
}

/// Runs on a worker thread. The shader code it reads is only replaced
/// after every job has been waited for.
pub fn runShadeVariantJob(job: *ShadeVariantJob) std.Io.Cancelable!void {
    if (job.device.compileGraphicsPipeline(std.heap.smp_allocator, shadeVariantDesc(job.device, job.reflective, &job.constants))) |compiled| {
        job.compiled = compiled;
    } else |err| job.failure = err;
    job.done.store(true, .release);
}

pub const EnvironmentJob = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []u8,
    group: std.Io.Group = .init,
    done: std.atomic.Value(bool) = .init(false),
    image: ?gltf.HdrImage = null,
    /// A cube map read from a KTX2 file, instead of `image`.
    cube: ?ktx2.Texture = null,
    cube_brightest: ?Vec3 = null,
    failure: ?anyerror = null,
};

pub fn runEnvironmentJob(job: *EnvironmentJob) std.Io.Cancelable!void {
    if (loadEnvironmentFile(job)) |_| {} else |err| {
        if (err == error.Canceled) return error.Canceled;
        job.failure = err;
    }
    job.done.store(true, .release);
}

pub fn loadEnvironmentFile(job: *EnvironmentJob) !void {
    const bytes = try gltf.readFile(job.gpa, job.io, job.path);
    const is_cube = ktx2.isKtx2(bytes);
    if (!is_cube) {
        job.gpa.free(bytes);
        job.image = try gltf.loadHdr(job.gpa, job.io, job.path);
        return;
    }
    defer job.gpa.free(bytes);
    const cube = try ktx2.read(job.gpa, bytes);
    errdefer job.gpa.free(cube.data);
    if (cube.faces != 6 or cube.layers != 1) return error.NotACubeMap;
    if (cube.format != .rgba16f and cube.format != .bc6h) return error.UnsupportedTextureFormat;
    job.cube_brightest = if (cube.format == .rgba16f) brightestCubeDirection(cube) else null;
    job.cube = cube;
}

/// Direction toward the brightest texel of a half-float cube map's
/// largest level. Matches `cubeDirection` in the environment shaders.
pub fn brightestCubeDirection(cube: ktx2.Texture) Vec3 {
    const size: usize = cube.width;
    var best: f32 = -1;
    var best_direction: Vec3 = .{ 0, 1, 0 };
    for (0..6) |face| for (0..size) |y| for (0..size) |x| {
        const texel = cube.data[((face * size + y) * size + x) * 8 ..][0..6];
        var rgb: [3]f32 = undefined;
        for (&rgb, 0..) |*channel, index| channel.* = @as(f16, @bitCast(std.mem.readInt(u16, texel[index * 2 ..][0..2], .little)));
        const luminance = rgb[0] * 0.2126 + rgb[1] * 0.7152 + rgb[2] * 0.0722;
        if (!(luminance > best)) continue;
        best = luminance;
        const px = (@as(f32, @floatFromInt(x)) + 0.5) / @as(f32, @floatFromInt(size)) * 2 - 1;
        const py = (@as(f32, @floatFromInt(y)) + 0.5) / @as(f32, @floatFromInt(size)) * 2 - 1;
        best_direction = math.normalize(switch (face) {
            0 => Vec3{ 1, -py, -px },
            1 => Vec3{ -1, -py, px },
            2 => Vec3{ px, 1, py },
            3 => Vec3{ px, -1, -py },
            4 => Vec3{ px, -py, 1 },
            else => Vec3{ -px, -py, -1 },
        });
    };
    return best_direction;
}

pub const ModelMesh = struct {
    vertex_offset: u32,
    vertex_count: u32,
    skin_offset: ?u32,
    /// Morph target deltas: `morph_targets` runs of `vertex_count`.
    morph_offset: ?u32 = null,
    morph_targets: u32 = 0,
    index_offset: u32,
    index_count: u32,
    /// Indices of the full-detail level, which come first.
    lod0_index_count: u32 = 0,
    meshlet_offset: u32,
    meshlet_count: u32,
    material: u32,
    /// Uses alpha blending; drawn by the forward pass.
    blend: bool,
    /// Cut out, blended or two-sided.
    masked: bool = false,
    /// Its tree in `bvh_nodes` and leaf triangles in `bvh_items`, when built
    /// (`Options.path_tracing_fallback`).
    bvh_nodes: ?u32 = null,
    bvh_node_count: u32 = 0,
    bvh_items: u32 = 0,
    bvh_item_count: u32 = 0,
    /// Root box of the tree, in mesh space.
    bvh_min: [3]f32 = .{ 0, 0, 0 },
    bvh_max: [3]f32 = .{ 0, 0, 0 },
    /// The coarse part (from `gltf.Mesh`): the first `coarse_vertex_count`
    /// vertices and the indices past the full-detail level's. `coarse` is
    /// set while only that part is in GPU memory.
    coarse_vertex_count: u32 = 0,
    coarse_error: f32 = 0,
    coarse: bool = false,
    blas: ?rhi.AccelerationStructure = null,
    blas_building: ?rhi.AccelerationStructure = null,
};

/// Application images used as a material's textures (see
/// `Renderer.materials.setTextures`). Null keeps the model's own. Channels
/// follow glTF: roughness in green and metallic in blue, occlusion in red,
/// coat strength in red, coat roughness in green, sheen roughness in alpha.
pub const MaterialTextures = struct {
    base_color: ?Image = null,
    normal: ?Image = null,
    metallic_roughness: ?Image = null,
    occlusion: ?Image = null,
    emissive: ?Image = null,
    clearcoat: ?Image = null,
    clearcoat_roughness: ?Image = null,
    clearcoat_normal: ?Image = null,
    sheen_color: ?Image = null,
    sheen_roughness: ?Image = null,
    /// Filtering and wrapping for all of them; null keeps the material's own.
    sampler: ?gltf.SamplerData = null,
};

pub const ModelEntry = struct {
    state: AssetState = .loading,
    job: ?*ModelJob = null,
    failure: ?anyerror = null,
    source: ?gltf.Model = null,
    textures: []?rhi.Texture = &.{},
    /// Parallel to `textures`; entries with data are streamed.
    streams: []TextureStream = &.{},
    stream_parts: []StreamPart = &.{},
    streamed: u32 = 0,
    materials_stale: bool = false,
    /// Overrides from `materials.setTextures`; empty, or one per material.
    material_images: []MaterialTextures = &.{},
    next_image: usize = 0,
    meshes: []ModelMesh = &.{},
    mesh_base: u32 = 0,
    material_base: u32 = 0,
    /// First material buffer slot of this model's per-texture transforms.
    transform_base: u32 = 0,
    transform_count: u32 = 0,
    /// Parents-before-children node order and rest-pose world matrices.
    order: []u32 = &.{},
    /// The part of `order` a posed entity needs: nodes an animation can
    /// move that have a mesh, are skin joints or are ancestors of such.
    pose_order: []u32 = &.{},
    /// Per node, whether an animation can move it.
    node_moves: []bool = &.{},
    node_world: []Mat4 = &.{},
    info: ModelInfo = std.mem.zeroes(ModelInfo),
    references: u32 = 0,
    blas_pending: bool = false,
    /// Frame the geometry was uploaded in; structures are built after it.
    blas_frame: ?u64 = null,
    blas_job: ?rhi.Detached = null,
    /// Whether vertices and indices are in GPU memory (geometry streaming);
    /// while not, what is drawn with the model is left out of its scene.
    geometry_resident: bool = true,
    geometry_coarse: bool = false,
    /// Drawn by something other than entities; never streamed out.
    geometry_pinned: bool = false,
    /// This frame's distance from the nearest camera to the nearest use.
    stream_distance: f32 = 0,
};

pub const EnvironmentEntry = struct {
    state: AssetState = .loading,
    job: ?*EnvironmentJob = null,
    failure: ?anyerror = null,
    max_radiance: f32,
    sky: ?rhi.Texture = null,
    specular: ?rhi.Texture = null,
    irradiance: ?rhi.Texture = null,
    brightest_direction: Vec3 = .{ 0, 1, 0 },
    /// Set for computed skies; `sky_dirty` asks for a rebuild.
    sky_desc: ?SkyDesc = null,
    sky_dirty: bool = false,
    /// A rebuild under way: the next face to draw (0 when idle) and the
    /// description it is drawn from.
    bake_step: u32 = 0,
    bake_desc: SkyDesc = .{},
    /// The cloud layer baked into the lighting cubes, and when.
    clouds: ?gpu.Clouds = null,
    cloud_bake_time: f32 = 0,
    /// For a loaded environment under clouds: the picture as loaded, and
    /// the sun its clouds are lit by.
    clear: ?rhi.Texture = null,
    cloud_to_sun: Vec3 = .{ 0, 1, 0 },
    cloud_sunlight: Vec3 = .{ 0, 0, 0 },
};

pub const LayoutEntry = struct {
    entity: Entity,
    model_instance: u32,
    first_of_entity: bool,
};

/// What `prepareScene` needs of a layout entry when its entity moves, kept
/// apart from the entity and its model.
pub const EntryInfo = struct {
    /// Model-space bounds of the mesh.
    center: Vec3,
    radius: f32,
    /// The model's matrix of the node the mesh hangs from; null when it is
    /// skinned or an animation can move that node.
    rest: ?*const Mat4 = null,
    /// Where its ray-tracing instance is, or `gpu.invalid_id`.
    tlas_slot: u32 = gpu.invalid_id,
    bits: u8 = 0,

    pub const skinned: u8 = 1;
    /// Skinned, or on a node an animation can move.
    pub const posed: u8 = 2;
    pub const glows: u8 = 8;
    /// Its record says it moved; the next frame must say otherwise.
    pub const moved: u8 = 16;
};

/// An entity's transform bookkeeping, by entity slot. Small and apart from
/// `EntityData` so that moving many entities touches little memory.
pub const EntityMark = struct {
    /// The entity's handle as bits; 0 while the slot is free.
    handle: u64 = 0,
    scene: Scene = undefined,
    /// Its entries in the scene's layout.
    layout_first: u32 = 0,
    layout_count: u32 = 0,
    /// Distance moved in the last prepared frame.
    travelled: f32 = 0,
    bits: u32 = 0,

    /// In its scene's `edited` list.
    pub const listed: u32 = 1;
    pub const moved: u32 = 2;
    /// Moved without it counting as motion.
    pub const teleported: u32 = 4;
    /// Tint, params or lightmap changed: its records are rewritten whole.
    pub const restyled: u32 = 8;
};

/// `Move` in instance_update.comp: a new transform for one instance.
pub const InstanceMove = extern struct {
    instance: u32,
    tlas_slot: u32 = gpu.invalid_id,
    flags: u32,
    pad: u32 = 0,
    transform: [12]f32,

    /// The record is marked as moving.
    pub const moved: u32 = 1;
    /// The transform it had becomes last frame's transform.
    pub const keep: u32 = 2;
};

/// `Rewrite` in instance_update.comp: a whole record for one instance.
pub const InstanceRewrite = extern struct {
    instance: u32,
    tlas_slot: u32 = gpu.invalid_id,
    pad: [2]u32 = .{ 0, 0 },
    previous: [12]f32,
    record: gpu.Instance,
};

/// `Glowing` in pathtrace.frag: an evenly emissive instance and the
/// triangle count of its full-detail level.
pub const Glowing = extern struct { instance: u32, triangles: u32 };
/// Most glowing instances path tracing samples directly.
pub const max_glowing = 1024;

pub const SceneData = struct {
    /// Bounds (center, radius) of what moved this frame, for choosing shadow
    /// tiles to redraw; `movers_overflow` if there were too many to list.
    movers: std.ArrayList([4]f32) = .empty,
    movers_overflow: bool = false,
    entities: std.ArrayList(Entity) = .empty,
    sun: Sun = .{},
    environment: ?Environment = null,
    environment_intensity: f32 = 1,
    lights: std.ArrayList(Light) = .empty,
    /// Bumped whenever the lights are replaced or moved.
    lights_version: u64 = 0,
    emitters: std.ArrayList(Emitter) = .empty,
    probes: std.ArrayList(ReflectionProbe) = .empty,
    fluids: std.ArrayList(Fluid) = .empty,
    waters: std.ArrayList(Water) = .empty,
    hairs: std.ArrayList(render.Hair) = .empty,
    liquids: std.ArrayList(Liquid) = .empty,
    groups: std.ArrayList(InstanceGroup) = .empty,
    /// GPU instances that come from groups, and a counter bumped whenever
    /// their records must be rewritten.
    static_count: u32 = 0,
    static_version: u64 = 0,
    /// Which lights `prepareLights` gave shadow atlas tiles, and the frame it
    /// chose them in.
    shadow_grants: std.ArrayList(bool) = .empty,
    shadow_grants_frame: u64 = std.math.maxInt(u64),
    shadow_grants_traced: bool = false,
    /// The groups' ray-tracing instances, and the group state they were made
    /// from.
    static_tlas: std.ArrayList(rhi.AccelerationInstance) = .empty,
    static_tlas_version: u64 = std.math.maxInt(u64),
    static_tlas_base: usize = 0,
    /// Keep the CPU instance tree up to date for fallback path tracing.
    trace_wanted: bool = false,
    trace_ready: bool = false,
    /// Changes with the tree's contents; resets accumulated pictures.
    trace_hash: u64 = 0,
    trace_nodes: ?rhi.Buffer = null,
    trace_nodes_capacity: u32 = 0,
    trace_instances: ?rhi.Buffer = null,
    trace_instances_capacity: u32 = 0,
    instance_slots: [rhi.frames_in_flight]InstanceSlot = @splat(.{}),
    decals: std.ArrayList(DecalDesc) = .empty,
    transmissive: bool = false,
    /// GPU instance indices of blended geometry, drawn in the forward pass.
    transparent: std.ArrayList(TransparentDraw) = .empty,
    /// Blended meshes of instance groups, added to `transparent` each frame.
    static_transparent: std.ArrayList(TransparentDraw) = .empty,
    static_transmissive: bool = false,
    /// Flattened (entity, model instance) list; index = GPU instance index.
    layout: std.ArrayList(LayoutEntry) = .empty,
    /// The entities of `layout` that animate, and the most nodes one has.
    posed: std.ArrayList(Entity) = .empty,
    posed_nodes: usize = 0,
    /// One per layout entry, and its world-space bounding sphere.
    entries: std.ArrayList(EntryInfo) = .empty,
    spheres: std.ArrayList([4]f32) = .empty,
    /// The blended layout entries, without their centers; whether any
    /// lets light through; and the first entries that glow.
    blended: std.ArrayList(TransparentDraw) = .empty,
    blended_transmissive: bool = false,
    /// Layout entries of the animated entities.
    posed_entries: u32 = 0,
    glowing: std.ArrayList(Glowing) = .empty,
    /// Bounds of the ray-traced entries of each `prepare_batch` of the
    /// layout, and which must be measured again.
    chunk_bounds: std.ArrayList([2]Vec3) = .empty,
    chunk_stale: std.ArrayList(bool) = .empty,
    /// Entity slots changed since the scene was last prepared.
    edited: std.ArrayList(u32) = .empty,
    /// Layout entries of the entities in `edited`, and of those among them
    /// whose records are to be written whole.
    edited_entries: usize = 0,
    restyled_entries: usize = 0,
    /// Layout entries whose records say they moved last frame, each with
    /// its entity's slot.
    settling: std.ArrayList([2]u32) = .empty,
    /// False when every record must be written again, not only the edited.
    records_valid: bool = false,
    /// Last frame's transform of each entity instance.
    previous: ?rhi.Buffer = null,
    previous_capacity: u32 = 0,
    /// Ray-tracing instances: entities', then groups', then skinned ones.
    tlas_instances: ?rhi.Buffer = null,
    tlas_instances_capacity: u32 = 0,
    rigid_tlas: u32 = 0,
    skinned_entries: u32 = 0,
    /// Changes whenever the ray-tracing instances do.
    tlas_content: u64 = 0,
    static_tlas_uploaded: bool = false,
    layout_dirty: bool = true,
    layout_generation: u64 = 0,
    refs: ?rhi.Buffer = null,
    refs_capacity: u32 = 0,
    /// Meshlet references of entities; they precede instance groups'.
    entity_ref_count: u32 = 0,
    masked_ref_count: u32 = 0,
    /// First reference and count for each instance of the instance groups,
    /// in instance record order.
    static_ranges: std.ArrayList([2]u32) = .empty,
    static_cull: ?rhi.Buffer = null,
    static_cull_capacity: u32 = 0,
    /// One `gpu.Impostor` per instance group that has one, their count, and
    /// the copies culling chose to draw as impostors in the current view.
    impostor_table: ?rhi.Buffer = null,
    impostor_table_capacity: u32 = 0,
    impostor_count: u32 = 0,
    lightmaps_baking: u32 = 0,
    impostor_list: ?rhi.Buffer = null,
    impostor_list_capacity: u32 = 0,
    /// Per view, the meshlet references of instances that passed culling:
    /// room for all of the instance groups', `candidate_views` times over.
    candidates: ?rhi.Buffer = null,
    candidate_capacity: u32 = 0,
    candidate_views: u32 = 0,
    /// Per instance, whether a camera drew any part of it this frame, and
    /// its CPU read-back copies (only when texture streaming skips what is
    /// hidden).
    seen: ?rhi.Buffer = null,
    seen_capacity: u32 = 0,
    seen_readback: [rhi.frames_in_flight]?rhi.Buffer = @splat(null),
    seen_tags: [rhi.frames_in_flight]SeenTag = @splat(.{}),
    /// Meshlet bounds of deformed meshes, rewritten on the GPU every frame
    /// (`Options.skinned_meshlet_bounds`).
    skin_bounds: ?rhi.Buffer = null,
    skin_bounds_capacity: u32 = 0,
    layout_version: u64 = 0,
    /// Renderer frame the per-frame data below was written for.
    prepared_frame: u64 = std.math.maxInt(u64),
    prepared: SceneFrame = undefined,
    gi_frame: u64 = std.math.maxInt(u64),
    gi_updated_frame: u64 = std.math.maxInt(u64),
    ref_count: u32 = 0,
    joint_count: u32 = 0,
    triangle_count: u64 = 0,
    tlas: ?rhi.AccelerationStructure = null,
    tlas_capacity: u32 = 0,
    tlas_hash: u64 = 0,
    gi: ?GiVolume = null,
    /// Coarse grid over the whole scene, present while the main one follows
    /// the camera.
    gi_coarse: ?GiVolume = null,
    /// Camera-following grid at a spacing between the main and coarse ones,
    /// for very large worlds.
    gi_middle: ?GiVolume = null,
    /// Explicit probe volume; null derives it from the static geometry.
    gi_bounds: ?[2]Vec3 = null,
    /// This scene's origin in the application's world; see `scenes.shift`.
    origin: [3]f64 = .{ 0, 0, 0 },
    clouds: ?CloudDesc = null,
    /// Accumulated cloud drift, and when it was last updated.
    cloud_drift: [3]f64 = .{ 0, 0, 0 },
    cloud_time: f32 = 0,
    /// The lightning flash under way: when it began and where.
    flash_start: f32 = -1000,
    flash_position: [3]f64 = .{ 0, 0, 0 },
    flash_brightness: f32 = 0,
    flash_checked: f32 = -1,
};

pub const no_skin = std.math.maxInt(u32);

pub const LightmapState = struct {
    /// Accumulated light and the next round's target; swapped every round.
    gathered: [2]rhi.Texture,
    /// The same with the gaps between patches filled: what shading reads.
    shown: rhi.Texture,
    rounds: u32 = 0,
    wanted: u32,
    rays: u32,
    reach: f32,
};

pub const EntityData = struct {
    lightmap: ?LightmapState = null,
    scene: Scene,
    /// In the ray-tracing structure with an instance record, but never drawn.
    rays_only: bool = false,
    model: Model,
    visible: bool,
    tint: u32 = 0xffffffff,
    params: [4]f32 = .{ 0, 0, 0, 0 },
    receive_decals: bool = true,
    pose: ?Pose = null,
    morph_weights: ?[gltf.max_morph_targets]f32 = null,
    /// Allocated once the model is ready, and only for models that animate.
    node_world: []Mat4 = &.{},
    previous_node_world: []Mat4 = &.{},
    /// Per model instance: base of its 2x vertex range for skinned output.
    skin_offsets: []u32 = &.{},
    /// The texture streaming round in which a camera last drew this entity.
    seen_round: u64 = 0,
    /// Where the entity's instances start in the layout, as of that round.
    seen_first: u32 = 0,
    /// Per model instance: per-frame BLAS of skinned or morphed meshes.
    skin_blas: []?rhi.AccelerationStructure = &.{},
    /// Per model instance: meshlet bounds offset, or `gpu.invalid_id`.
    bounds_offsets: []u32 = &.{},
    /// Model-space center and radius of the posed skeleton, padded for the
    /// skin. Instance groups that follow this entity's pose are culled by it.
    skin_bounds: [4]f32 = .{ 0, 0, 0, 0 },
    /// Frames this entity has been skinned for; 0 means no valid history.
    history_frames: u32 = 0,
    resolved: bool = false,
};

pub const TransparentDraw = struct {
    instance: u32,
    first_index: u32,
    index_count: u32,
    /// World-space center, for back-to-front sorting.
    center: Vec3,
    depth: f32 = 0,
    transmissive: bool = false,
};

pub const BlasJob = struct { blas: rhi.AccelerationStructure, vertex_offset: u32, mesh: ModelMesh };
/// `BoundsJob` in skin_bounds.comp.
pub const BoundsJob = extern struct {
    vertex_offset: u32,
    meshlet_offset: u32,
    meshlet_count: u32,
    bounds_offset: u32,
    first_group: u32 = 0,
    pad: [3]u32 = .{ 0, 0, 0 },
};

/// `SkinJob` in skin.comp.
pub const SkinJob = extern struct {
    source_offset: u32,
    destination_offset: u32,
    skin_offset: u32,
    joint_offset: u32,
    vertex_count: u32,
    /// First delta of the mesh's first morph target, and how many targets.
    morph_offset: u32 = 0,
    target_count: u32 = 0,
    /// This job's first work group in the batched dispatch.
    first_group: u32 = 0,
    /// Where this job's target weights start in the frame's weight list.
    weights_offset: u32 = 0,
    pad: [3]u32 = .{ 0, 0, 0 },
};

comptime {
    std.debug.assert(@sizeOf(SkinJob) == 48);
}

/// Tracks textures a constructor has made, for `errdefer made.destroy()`.
pub const MadeTextures = struct {
    device: *rhi.Device,
    textures: [96]rhi.Texture = undefined,
    count: usize = 0,

    pub fn texture(self: *MadeTextures, desc: rhi.TextureDesc) !rhi.Texture {
        std.debug.assert(self.count < self.textures.len);
        const made = try self.device.createTexture(desc);
        self.textures[self.count] = made;
        self.count += 1;
        return made;
    }

    pub fn destroy(self: *MadeTextures) void {
        for (self.textures[0..self.count]) |made| self.device.destroyTexture(made);
        self.count = 0;
    }
};

/// One view's render targets at one resolution.
pub const ViewState = struct {
    width: u32,
    height: u32,
    depth: rhi.Texture,
    /// Last frame's depth; the two swap every frame.
    previous_depth: rhi.Texture,
    /// Last frame's motion; swapped like the depth.
    previous_motion: rhi.Texture,
    visibility: rhi.Texture,
    motion: rhi.Texture,
    ao_raw: rhi.Texture,
    ao_depth: rhi.Texture,
    ao: rhi.Texture,
    hdr: rhi.Texture,
    fog: rhi.Texture,
    history: [2]rhi.Texture,
    /// Depth pyramid for occlusion culling (power-of-two, full mip chain).
    hiz: rhi.Texture,
    hiz_width: u32,
    hiz_height: u32,
    hiz_mips: u32,
    bloom: [bloom_levels]rhi.Texture,
    history_valid: bool = false,
    ao_history: rhi.Texture,
    ao_history_valid: bool = false,
    /// `Settings.ao_bounce` light: as sampled, filtered, and last frame's.
    bounce_raw: rhi.Texture,
    bounce: rhi.Texture,
    bounce_history: rhi.Texture,
    bounce_history_valid: bool = false,
    scales: EffectScales,
    /// Probe irradiance gathered below full resolution; null at full rate.
    gi_gather: ?rhi.Texture,
    oit: ?OitTargets,
    peel: ?PeelTargets,
    /// The scene before transparent surfaces; null without transmission.
    scene_copy: ?rhi.Texture,
    /// Liquid surface targets: nearest particle depth, thickness, and the
    /// smoothed distance in two ping-ponged copies.
    liquid: ?LiquidTargets = null,
    upscaled: ?rhi.Texture,
    /// `Settings.variable_rate_shading` tiles; null where unsupported.
    shading_rate: ?rhi.Texture,
    /// Output of the first `Upscaling.fsr` pass, sharpened into `upscaled`.
    upscaled_edges: ?rhi.Texture,
    /// Targets of depth of field and motion blur; null while both are off.
    lens: ?[2]rhi.Texture,
    dof_reduced: ?rhi.Texture = null,
    fluid: ?rhi.Texture,
    fluid_motion: ?rhi.Texture = null,
    clouds: ?CloudTargets,
    reflections: ?ReflectionTargets,

    pub fn init(device: *rhi.Device, width: u32, height: u32, scales: EffectScales) !ViewState {
        const color = rhi.TextureUsage{ .sampled = true, .color_attachment = true };
        var self: ViewState = undefined;
        var made = MadeTextures{ .device = device };
        errdefer made.destroy();
        self.width = width;
        self.height = height;
        self.history_valid = false;
        self.scales = scales;
        self.peel = if (!scales.peel) null else .{
            .layer = try made.texture(.{ .name = "peel layer", .width = width, .height = height, .format = hdr_format, .usage = color }),
            .accumulation = try made.texture(.{ .name = "peel accumulation", .width = width, .height = height, .format = hdr_format, .usage = color }),
            .depth = .{
                try made.texture(.{ .name = "peel depth", .width = width, .height = height, .format = .depth32_float, .usage = .{ .sampled = true, .depth_attachment = true } }),
                try made.texture(.{ .name = "peel depth", .width = width, .height = height, .format = .depth32_float, .usage = .{ .sampled = true, .depth_attachment = true } }),
            },
        };
        self.oit = if (!scales.oit) null else .{
            .accumulation = try made.texture(.{ .name = "transparency accumulation", .width = width, .height = height, .format = hdr_format, .usage = color }),
            .reveal = try made.texture(.{ .name = "transparency reveal", .width = width, .height = height, .format = .r8_unorm, .usage = color }),
        };
        const resolved_width = if (scales.temporal_upscale) scales.output_width else width;
        const resolved_height = if (scales.temporal_upscale) scales.output_height else height;
        self.upscaled = if (scales.temporal_upscale or (scales.output_width == width and scales.output_height == height)) null else try made.texture(.{ .name = "upscaled", .width = scales.output_width, .height = scales.output_height, .format = hdr_format, .usage = color });
        const tile = device.shading_rate_tile;
        self.shading_rate = if (tile == 0) null else try made.texture(.{
            .name = "shading rate",
            .width = (width + tile - 1) / tile,
            .height = (height + tile - 1) / tile,
            .format = .r8_uint,
            .usage = .{ .color_attachment = true, .shading_rate = true },
        });
        self.upscaled_edges = if (self.upscaled == null or !scales.fsr) null else try made.texture(.{ .name = "upscaled edges", .width = scales.output_width, .height = scales.output_height, .format = hdr_format, .usage = color });
        self.scene_copy = if (!scales.refraction) null else try made.texture(.{ .name = "scene behind glass", .width = width, .height = height, .format = hdr_format, .usage = color });
        self.liquid = if (!scales.liquid) null else .{
            .depth = try made.texture(.{ .name = "liquid depth", .width = width, .height = height, .format = .depth32_float, .usage = .{ .sampled = true, .depth_attachment = true } }),
            .thickness = try made.texture(.{ .name = "liquid thickness", .width = width, .height = height, .format = .r16_float, .usage = color }),
            .smooth = .{
                try made.texture(.{ .name = "liquid surface", .width = width, .height = height, .format = .r32_float, .usage = color }),
                try made.texture(.{ .name = "liquid surface", .width = width, .height = height, .format = .r32_float, .usage = color }),
            },
        };
        self.dof_reduced = if (scales.dof) |scale| try made.texture(.{ .name = "depth of field (reduced)", .width = scaledExtent(scale, resolved_width), .height = scaledExtent(scale, resolved_height), .format = hdr_format, .usage = color }) else null;
        self.lens = if (!scales.lens) null else .{
            try made.texture(.{ .name = "depth of field", .width = resolved_width, .height = resolved_height, .format = hdr_format, .usage = color }),
            try made.texture(.{ .name = "motion blur", .width = resolved_width, .height = resolved_height, .format = hdr_format, .usage = color }),
        };
        self.fluid = if (scales.fluid) |scale| try made.texture(.{ .name = "fluids", .width = scaledExtent(scale, width), .height = scaledExtent(scale, height), .format = hdr_format, .usage = color }) else null;
        self.fluid_motion = if (scales.fluid) |scale| try made.texture(.{ .name = "fluid motion", .width = scaledExtent(scale, width), .height = scaledExtent(scale, height), .format = .rgba16_float, .usage = color }) else null;
        self.clouds = if (scales.clouds) |scale| .{
            .current = try made.texture(.{ .name = "clouds", .width = scaledExtent(scale, width), .height = scaledExtent(scale, height), .format = hdr_format, .usage = color }),
            .history = try made.texture(.{ .name = "clouds (history)", .width = scaledExtent(scale, width), .height = scaledExtent(scale, height), .format = hdr_format, .usage = color }),
        } else null;
        self.reflections = if (scales.reflections) |scale| .{
            .weight = try made.texture(.{ .name = "reflection weight", .width = width, .height = height, .format = hdr_format, .usage = color }),
            .surface = try made.texture(.{ .name = "reflection surface", .width = width, .height = height, .format = hdr_format, .usage = color }),
            .traced = try made.texture(.{ .name = "reflections", .width = scaledExtent(scale, width), .height = scaledExtent(scale, height), .format = hdr_format, .usage = color }),
            .history = try made.texture(.{ .name = "reflections (history)", .width = scaledExtent(scale, width), .height = scaledExtent(scale, height), .format = hdr_format, .usage = color }),
        } else null;
        self.gi_gather = if (scales.gi == .full) null else try made.texture(.{
            .name = "gi gather",
            .width = scaledExtent(scales.gi, width),
            .height = scaledExtent(scales.gi, height),
            .format = hdr_format,
            .usage = color,
        });
        self.depth = try made.texture(.{ .name = "depth", .width = width, .height = height, .format = .depth32_float, .usage = .{ .sampled = true, .depth_attachment = true } });
        self.previous_depth = try made.texture(.{ .name = "depth", .width = width, .height = height, .format = .depth32_float, .usage = .{ .sampled = true, .depth_attachment = true } });
        self.visibility = try made.texture(.{ .name = "visibility", .width = width, .height = height, .format = .r32_uint, .usage = color });
        self.motion = try made.texture(.{ .name = "motion", .width = width, .height = height, .format = .rg16_float, .usage = color });
        self.previous_motion = try made.texture(.{ .name = "motion", .width = width, .height = height, .format = .rg16_float, .usage = color });
        self.ao_raw = try made.texture(.{ .name = "ao raw", .width = scaledExtent(scales.ao, width), .height = scaledExtent(scales.ao, height), .format = .rg16_float, .usage = color });
        self.ao = try made.texture(.{ .name = "ao", .width = width, .height = height, .format = .r16_float, .usage = color });
        self.ao_history = try made.texture(.{ .name = "ao history", .width = width, .height = height, .format = .r16_float, .usage = color });
        self.ao_history_valid = false;
        self.bounce_raw = try made.texture(.{ .name = "bounce raw", .width = scaledExtent(scales.ao, width), .height = scaledExtent(scales.ao, height), .format = .rgba16_float, .usage = color });
        self.bounce = try made.texture(.{ .name = "bounce", .width = width, .height = height, .format = .rgba16_float, .usage = color });
        self.bounce_history = try made.texture(.{ .name = "bounce history", .width = width, .height = height, .format = .rgba16_float, .usage = color });
        self.bounce_history_valid = false;
        self.ao_depth = try made.texture(.{
            .name = "ao depth",
            .width = scaledExtent(scales.ao, width),
            .height = scaledExtent(scales.ao, height),
            .format = .r16_float,
            .usage = color,
            .mip_levels = @min(ao_depth_mips, rhi.TextureDesc.fullMipCount(scaledExtent(scales.ao, width), scaledExtent(scales.ao, height))),
        });
        self.hdr = try made.texture(.{ .name = "hdr", .width = width, .height = height, .format = hdr_format, .usage = color });
        self.hiz_width = std.math.floorPowerOfTwo(u32, @max(width, 2));
        self.hiz_height = std.math.floorPowerOfTwo(u32, @max(height, 2));
        self.hiz_mips = rhi.TextureDesc.fullMipCount(self.hiz_width, self.hiz_height);
        self.hiz = try made.texture(.{
            .name = "depth pyramid",
            .width = self.hiz_width,
            .height = self.hiz_height,
            .format = .r32_float,
            .usage = .{ .sampled = true, .color_attachment = true, .storage = device.storage_images },
            .mip_levels = self.hiz_mips,
        });
        self.fog = try made.texture(.{ .name = "fog", .width = scaledExtent(scales.fog, width), .height = scaledExtent(scales.fog, height), .format = hdr_format, .usage = color });
        for (&self.history) |*texture| {
            texture.* = try made.texture(.{ .name = "taa history", .width = resolved_width, .height = resolved_height, .format = hdr_format, .usage = .{ .sampled = true, .color_attachment = true, .storage = device.storage_images, .copy_dst = true } });
        }
        for (&self.bloom, 0..) |*texture, level| {
            texture.* = try made.texture(.{
                .name = "bloom",
                .width = @max(width >> @intCast(level + 1), 1),
                .height = @max(height >> @intCast(level + 1), 1),
                .format = bloom_format,
                .usage = color,
            });
        }
        return self;
    }

    pub fn deinit(self: *ViewState, device: *rhi.Device) void {
        for ([_]rhi.Texture{ self.depth, self.previous_depth, self.visibility, self.motion, self.previous_motion, self.ao_raw, self.ao, self.ao_history, self.bounce_raw, self.bounce, self.bounce_history, self.ao_depth, self.hdr, self.fog, self.hiz }) |texture|
            device.destroyTexture(texture);
        for (self.history) |texture| device.destroyTexture(texture);
        if (self.gi_gather) |texture| device.destroyTexture(texture);
        if (self.lens) |lens| for (lens) |texture| device.destroyTexture(texture);
        if (self.dof_reduced) |texture| device.destroyTexture(texture);
        if (self.oit) |oit| {
            device.destroyTexture(oit.accumulation);
            device.destroyTexture(oit.reveal);
        }
        if (self.scene_copy) |texture| device.destroyTexture(texture);
        if (self.liquid) |targets| {
            device.destroyTexture(targets.depth);
            device.destroyTexture(targets.thickness);
            for (targets.smooth) |texture| device.destroyTexture(texture);
        }
        if (self.peel) |peel| for ([_]rhi.Texture{ peel.layer, peel.accumulation, peel.depth[0], peel.depth[1] }) |texture| device.destroyTexture(texture);
        if (self.upscaled) |texture| device.destroyTexture(texture);
        if (self.upscaled_edges) |texture| device.destroyTexture(texture);
        if (self.shading_rate) |texture| device.destroyTexture(texture);
        if (self.reflections) |targets| for ([_]rhi.Texture{ targets.weight, targets.surface, targets.traced, targets.history }) |texture| device.destroyTexture(texture);
        if (self.clouds) |targets| for ([_]rhi.Texture{ targets.current, targets.history }) |texture| device.destroyTexture(texture);
        if (self.fluid) |texture| device.destroyTexture(texture);
        if (self.fluid_motion) |texture| device.destroyTexture(texture);
        for (self.bloom) |texture| device.destroyTexture(texture);
    }
};

pub const ViewData = struct {
    state: ?ViewState = null,
    /// Display-referred picture of a view drawn into part of a target;
    /// copied into place once its draw lists are done.
    output: ?rhi.Texture = null,
    output_format: rhi.Format = undefined,
    exposure: rhi.Buffer,
    exposure_reset: bool = true,
    previous_view_proj: Mat4 = math.identity,
    /// The scene origin `previous_view_proj` was made under.
    scene_origin: [3]f64 = .{ 0, 0, 0 },
    previous_jitter: [2]f32 = .{ 0, 0 },
    /// Frames this view has rendered; drives jitter and history swaps.
    frames: u64 = 0,
    last_frame: u64 = std.math.maxInt(u64),
    /// Whether `previous_view_proj` is the camera of one frame ago: the view
    /// drew the previous frame into its current targets.
    camera_known: bool = false,
    shadow_map: ?rhi.Texture = null,
    /// Tint of sunlight passed by see-through casters, per cascade.
    shadow_color: ?rhi.Texture = null,
    shadows_colored: bool = false,
    cascade_cache: CascadeCache = .{},
    /// Path tracing: the running average, its frame count, and a key of
    /// what was accumulated (see `Settings.path_tracing`).
    path_accum: ?rhi.Texture = null,
    /// Albedo guide accumulated alongside, and the denoiser's intermediate.
    path_guide: ?rhi.Texture = null,
    path_filtered: ?rhi.Texture = null,
    /// Last frame's accumulation and guide, for reprojection, and the camera
    /// they were gathered from.
    path_accum_old: ?rhi.Texture = null,
    path_guide_old: ?rhi.Texture = null,
    /// The noisy part of a path-traced picture, this frame's and last
    /// frame's, and the two targets its filter ping-pongs between.
    path_soft: ?rhi.Texture = null,
    path_soft_old: ?rhi.Texture = null,
    path_filtered_other: ?rhi.Texture = null,
    /// Normal and distance of what each path-traced pixel shows, seen
    /// through mirrors; this frame's and last frame's.
    path_facing: ?rhi.Texture = null,
    path_facing_old: ?rhi.Texture = null,
    /// Normal, roughness and distance of the primary hit, for the reflection
    /// denoiser; this frame's and last frame's.
    path_surface: ?rhi.Texture = null,
    path_surface_old: ?rhi.Texture = null,
    /// Lamp and glow light on the surface seen, over its color; this frame's
    /// and last frame's.
    path_lamp: ?rhi.Texture = null,
    path_lamp_old: ?rhi.Texture = null,
    /// The light sample each pixel keeps for lamp and glow light (`Reservoir`
    /// in pathtrace.frag); this frame's and last frame's.
    path_reservoir: ?rhi.Texture = null,
    path_reservoir_old: ?rhi.Texture = null,
    /// Glossy reflections as traced this frame, and the reflection
    /// denoiser's (ffx_reflections.glsl) targets and history.
    path_gloss_gathered: ?rhi.Texture = null,
    path_gloss_gathered_old: ?rhi.Texture = null,
    reflection_reprojected: ?rhi.Texture = null,
    reflection_samples: ?rhi.Texture = null,
    reflection_samples_old: ?rhi.Texture = null,
    reflection_average: ?rhi.Texture = null,
    reflection_prefiltered: ?rhi.Texture = null,
    reflection_resolved: ?rhi.Texture = null,
    reflection_resolved_old: ?rhi.Texture = null,
    path_camera: Camera = .{},
    path_size: [2]u32 = .{ 0, 0 },
    path_gathered: u32 = 0,
    /// Whether last frame's light samples and surfaces are there to reuse.
    path_reusable: bool = false,
    path_traced: bool = false,
    path_still: u32 = 0,
    path_key: u64 = 0,
    /// The sun's virtual shadow map state, once the view has used one.
    vsm: ?@import("passes/virtual_shadows.zig").State = null,
    /// One word per meshlet reference: was it visible last frame.
    visibility: ?rhi.Buffer = null,
    visibility_capacity: u32 = 0,
    /// The FidelityFX upscaler this view resolves with, and whether one was
    /// asked for and would not start.
    upscaler: ?@import("ffx.zig").Upscaler = null,
    upscaler_refused: ?@import("ffx.zig").Generation = null,
    /// Renderer frame the upscaler last ran in; its history is stale after a
    /// gap.
    upscaler_frame: u64 = 0,
    /// The DLSS feature this view resolves with, the one that would not start,
    /// and the renderer frame it last ran in.
    dlss: ?@import("dlss.zig").Upscaler = null,
    dlss_refused: ?@import("dlss.zig").Feature = null,
    dlss_frame: u64 = 0,
    /// The view was path traced for DLSS Ray Reconstruction this frame: its
    /// path tracing targets hold what that reads, not what is gathered.
    path_reconstructing: bool = false,
    /// One word per instance of the instance groups: seen last frame
    /// (`InstanceVisibility` in cull_view.glsl).
    instance_visibility: ?rhi.Buffer = null,
    instance_visibility_capacity: u32 = 0,
    visibility_scene: ?Scene = null,
    visibility_layout: u64 = 0,

    pub fn deinit(self: *ViewData, device: *rhi.Device) void {
        if (self.state) |*state| state.deinit(device);
        if (self.output) |texture| device.destroyTexture(texture);
        if (self.shadow_map) |texture| device.destroyTexture(texture);
        if (self.shadow_color) |texture| device.destroyTexture(texture);
        if (self.path_accum) |texture| device.destroyTexture(texture);
        if (self.path_guide) |texture| device.destroyTexture(texture);
        if (self.path_filtered) |texture| device.destroyTexture(texture);
        if (self.path_accum_old) |texture| device.destroyTexture(texture);
        if (self.path_guide_old) |texture| device.destroyTexture(texture);
        if (self.path_soft) |texture| device.destroyTexture(texture);
        if (self.path_soft_old) |texture| device.destroyTexture(texture);
        if (self.path_filtered_other) |texture| device.destroyTexture(texture);
        inline for (.{ "path_facing", "path_facing_old", "path_surface", "path_surface_old", "path_reservoir", "path_reservoir_old", "path_lamp", "path_lamp_old", "path_gloss_gathered", "path_gloss_gathered_old", "reflection_reprojected", "reflection_samples", "reflection_samples_old", "reflection_average", "reflection_prefiltered", "reflection_resolved", "reflection_resolved_old" }) |name| {
            if (@field(self, name)) |texture| device.destroyTexture(texture);
        }
        if (self.visibility) |buffer| device.destroyBuffer(buffer);
        if (self.instance_visibility) |buffer| device.destroyBuffer(buffer);
        if (self.vsm) |vsm| vsm.deinit(device);
        if (self.upscaler) |upscaler| {
            device.waitIdle() catch {};
            upscaler.destroy();
        }
        if (self.dlss) |upscaler| {
            device.waitIdle() catch {};
            upscaler.destroy();
        }
        device.destroyBuffer(self.exposure);
    }
};

pub const Output = struct {
    texture: rhi.Texture,
    format: rhi.Format,
    region: Region,
    load: rhi.LoadOp,
    clear: [4]f32,
    /// Scene depth for world-space draw list items; null without a scene.
    depth: ?rhi.Texture = null,
};

pub const Pipelines = struct {
    skin: rhi.Pipeline,
    cull: rhi.Pipeline,
    cull_instances: rhi.Pipeline,
    cluster: rhi.Pipeline,
    local_shadow: rhi.Pipeline,
    local_shadow_masked: rhi.Pipeline,
    forward: rhi.Pipeline,
    forward_weighted: ?rhi.Pipeline,
    oit_composite: rhi.Pipeline,
    forward_peel: ?rhi.Pipeline,
    peel_under: rhi.Pipeline,
    peel_composite: rhi.Pipeline,
    copy: rhi.Pipeline,
    upscale: rhi.Pipeline,
    fsr_easu: rhi.Pipeline,
    shading_rate: rhi.Pipeline,
    fsr_rcas: rhi.Pipeline,
    hiz: rhi.Pipeline,
    hiz_compute: ?rhi.Pipeline = null,
    visibility: rhi.Pipeline,
    visibility_masked: rhi.Pipeline,
    shadow: rhi.Pipeline,
    shadow_masked: rhi.Pipeline,
    shadow_color: rhi.Pipeline,
    gtao: rhi.Pipeline,
    gtao_bounce_denoise: rhi.Pipeline,
    ao_depth: rhi.Pipeline,
    gi_gather: rhi.Pipeline,
    gtao_denoise: rhi.Pipeline,
    /// Shading without the reflection outputs; made on first use.
    shade: ?rhi.Pipeline,
    shade_reflective: rhi.Pipeline,
    ssr: rhi.Pipeline,
    /// Reflections with ray queries; the plain pass without ray tracing.
    ssr_traced: rhi.Pipeline,
    ssr_composite: rhi.Pipeline,
    cloud_noise: rhi.Pipeline,
    cloud: rhi.Pipeline,
    cloud_composite: rhi.Pipeline,
    fluid_advect: rhi.Pipeline,
    fluid_curl: rhi.Pipeline,
    fluid_force: rhi.Pipeline,
    fluid_divergence: rhi.Pipeline,
    fluid_pressure: rhi.Pipeline,
    fluid_project: rhi.Pipeline,
    fluid_present: rhi.Pipeline,
    water_sim: rhi.Pipeline,
    water: rhi.Pipeline,
    underwater: rhi.Pipeline,
    water_depth: rhi.Pipeline,
    liquid_sim: rhi.Pipeline,
    liquid_depth: rhi.Pipeline,
    liquid_shadow: rhi.Pipeline,
    liquid_surface: rhi.Pipeline,
    path_trace: rhi.Pipeline,
    path_denoise: rhi.Pipeline,
    path_denoise_final: rhi.Pipeline,
    /// Denoisers for path-traced gloss (ffx_reflections.glsl).
    reflection_reproject: rhi.Pipeline,
    reflection_average: rhi.Pipeline,
    reflection_prefilter: rhi.Pipeline,
    reflection_resolve: rhi.Pipeline,
    liquid_thickness: rhi.Pipeline,
    liquid_blur: rhi.Pipeline,
    liquid: rhi.Pipeline,
    fluid_light: rhi.Pipeline,
    fluid_solid: rhi.Pipeline,
    fluid_solid_traced: rhi.Pipeline,
    fluid_carry: rhi.Pipeline,
    fluid: rhi.Pipeline,
    dof: rhi.Pipeline,
    dof_composite: rhi.Pipeline,
    motion_blur: rhi.Pipeline,
    fog: rhi.Pipeline,
    fog_composite: rhi.Pipeline,
    taa: rhi.Pipeline,
    bloom_down: rhi.Pipeline,
    bloom_up: rhi.Pipeline,
    exposure: rhi.Pipeline,
    pick: rhi.Pipeline,
    particle_sim: rhi.Pipeline,
    particle_sort_keys: rhi.Pipeline,
    particle_sort: rhi.Pipeline,
    particles: rhi.Pipeline,
    particle_mesh: rhi.Pipeline,
    hair: rhi.Pipeline,
    hair_simulation: rhi.Pipeline,
    hair_shadow: rhi.Pipeline,
    impostor: rhi.Pipeline,
    impostor_bake: rhi.Pipeline,
    lightmap_bake: ?rhi.Pipeline = null,
    lightmap_dilate: rhi.Pipeline,
    vsm_mark: rhi.Pipeline,
    vsm_allocate: rhi.Pipeline,
    vsm_clear: rhi.Pipeline,
    probe_face: rhi.Pipeline,
    fluid_motion: rhi.Pipeline,
    skin_bounds: rhi.Pipeline,
    instance_moves: rhi.Pipeline,
    instance_rewrites: rhi.Pipeline,
    particle_trails: rhi.Pipeline,
    env_cube: rhi.Pipeline,
    env_sky: rhi.Pipeline,
    env_irradiance: rhi.Pipeline,
    env_prefilter: rhi.Pipeline,
    brdf_lut: rhi.Pipeline,
};

pub const GiPipelines = struct {
    trace: rhi.Pipeline,
    irradiance: rhi.Pipeline,
    clamp_upper: rhi.Pipeline,
    clamp_lower: rhi.Pipeline,
    relocate: rhi.Pipeline,
    visibility: rhi.Pipeline,
};

pub const GiVolume = struct {
    origin: Vec3,
    /// The origin in whole grid cells, and how far it moved this frame.
    cell: [3]i32 = .{ 0, 0, 0 },
    shift: [3]i32 = .{ 0, 0, 0 },
    spacing: f32,
    counts: [3]u32,
    rays_per_probe: u32,
    /// What shading reads: a slow average of the probe rays.
    irradiance: rhi.Texture,
    /// A fast, noisy average of the same rays, to detect lighting changes.
    irradiance_fast: rhi.Texture,
    visibility: rhi.Texture,
    rays: rhi.Buffer,
    /// Per-probe relocation offsets, in two ping-ponged textures.
    offsets: [2]rhi.Texture,
    offset_turn: u32 = 0,
    offsets_valid: bool = false,
    /// Updates since creation; drives the blend rate.
    frames: u32 = 0,

    pub fn probeCount(self: GiVolume) u32 {
        return self.counts[0] * self.counts[1] * self.counts[2];
    }

    pub fn deinit(self: GiVolume, device: *rhi.Device) void {
        device.destroyTexture(self.irradiance);
        device.destroyTexture(self.irradiance_fast);
        device.destroyTexture(self.visibility);
        device.destroyBuffer(self.rays);
        for (self.offsets) |texture| device.destroyTexture(texture);
    }
};

pub const gi_irradiance_texels = 8;
pub const gi_visibility_texels = 16;
/// Upper bound on `Options.gi_max_probes`: the scroll offset has 10 bits.
pub const gi_probe_limit = 256;

pub const TonemapPipeline = struct { format: rhi.Format, pipeline: rhi.Pipeline };
pub const PickRequest = struct { view: View, pixel: [2]u32 };
pub const ReflectionTargets = struct {
    /// Mirror weight (rgb) and roughness (a) of every surface.
    weight: rhi.Texture,
    /// Shading normal (octahedral, rg) and sky visibility (b).
    surface: rhi.Texture,
    /// Traced radiance (rgb) and confidence (a), and last frame's.
    traced: rhi.Texture,
    history: rhi.Texture,
    history_valid: bool = false,
};
pub const CloudTargets = struct { current: rhi.Texture, history: rhi.Texture, history_valid: bool = false };
pub const cloud_noise_size = [3]i32{ 128, 128, 64 };
/// The volume is stored as a sheet of slices, this many to a row.
pub const cloud_noise_tiles = 8;
pub const MaterialPipelines = struct { plain: rhi.Pipeline, reflective: rhi.Pipeline };
/// The 2x2 matrix (by rows) of a coordinate transform: scale, then rotate.
pub fn uvMatrix(scale: [2]f32, rotation: f32) [4]f32 {
    return .{
        @cos(rotation) * scale[0],  @sin(rotation) * scale[1],
        -@sin(rotation) * scale[0], @cos(rotation) * scale[1],
    };
}

/// Slot of a material's per-texture transforms, if it has any.
pub fn transformSlot(entry: *const ModelEntry, index: usize) u32 {
    const materials = (entry.source orelse return gpu.invalid_id).materials;
    if (entry.transform_count == 0 or index >= materials.len or !materials[index].hasOwnTransforms()) return gpu.invalid_id;
    var before: u32 = 0;
    for (materials[0..index]) |material| {
        if (material.hasOwnTransforms()) before += 1;
    }
    return entry.transform_base + before * gpu.texture_transform_slots;
}

pub fn uvSetBit(reference: ?gltf.TextureRef, bit: u5) u32 {
    return if (reference) |ref| @as(u32, ref.uv_set & 1) << bit else 0;
}

/// Packs a color as instance records hold it: RGBA8, opaque.
pub fn packTint(color: [3]f32) u32 {
    var packed_color: u32 = 0xff000000;
    inline for (0..3) |channel| packed_color |= @as(u32, @intFromFloat(std.math.clamp(color[channel], 0, 1) * 255 + 0.5)) << (channel * 8);
    return packed_color;
}

pub const max_fluids = 8;
pub const max_worker_threads = 8;
/// A change to an entity that can be made later.
pub const EntityEdit = struct {
    entity: Entity,
    change: Change,

    pub const Change = union(enum) {
        transform: Mat4,
        /// A transform that is not motion.
        teleport: Mat4,
        /// As `packTint` packs it.
        tint: u32,
        params: [4]f32,
        pose: ?Pose,
    };
};
/// Layout entries `prepareScene` hands a thread at a time.
pub const prepare_batch = 2048;
/// Edited entities per thread below which moving them is not split.
pub const move_batch = 4096;
/// What one batch of `prepareScene` found.
pub const PrepareChunk = struct {
    any_moving: bool = false,
};
/// Animated entities per thread below which the work is not split.
pub const pose_batch = 48;
pub const max_liquids = 4;
/// Particles a grid cell can list; a cell at rest holds eight. Overflow
/// hides crowding from the solver and lets the liquid collapse.
pub const liquid_cell_slots = 48;

pub const LiquidTargets = struct {
    depth: rhi.Texture,
    thickness: rhi.Texture,
    smooth: [2]rhi.Texture,
};

pub const LiquidState = struct {
    scene: Scene,
    /// Time not yet simulated; see `steadyStep`.
    time_owed: f32 = 0,
    /// Rays-only box standing in for the liquid in traced reflections.
    proxy: ?Entity = null,
    desc: LiquidDesc,
    /// Copy of the description's jets.
    sources: [4]LiquidSource = undefined,
    source_count: u32 = 0,
    capacity: u32,
    particles: rhi.Buffer,
    /// Per grid cell, how many particles it lists, and the lists.
    counts: rhi.Buffer,
    cells: rhi.Buffer,
    /// The records of a frame's steps, in GPU memory.
    params_buffer: rhi.Buffer,
    cell_count: u32,
    grid: [3]i32,
    live: u32 = 0,
    block: [3]u32,
    started: bool = false,
    /// Fractional births carried over, per jet.
    owed: [4]f32 = @splat(0),
    /// Address of this frame's record on the GPU.
    params: u64 = 0,
    params_frame: u64 = std.math.maxInt(u64),

    pub fn deinit(self: *LiquidState, device: *rhi.Device) void {
        device.destroyBuffer(self.particles);
        device.destroyBuffer(self.counts);
        device.destroyBuffer(self.cells);
        device.destroyBuffer(self.params_buffer);
    }

    pub fn setSources(self: *LiquidState, sources: []const LiquidSource) void {
        self.source_count = @intCast(@min(sources.len, self.sources.len));
        @memcpy(self.sources[0..self.source_count], sources[0..self.source_count]);
        self.desc.sources = &.{};
    }
};

pub const max_waters = 8;
pub const water_quads = 160;
pub const HairState = struct {
    scene: Scene,
    desc: render.HairDesc,
    /// One `HairPoint` (hair.glsl) per point of every strand.
    points: rhi.Buffer,
    stretches: u32,
    strands: u32,
    /// Bounding sphere of the strands as given, in the hair's own space.
    bounds: [4]f32 = .{ 0, 0, 0, 0 },
    /// Transform the hair was last drawn with, for motion vectors.
    shown_transform: ?Mat4 = null,
    /// Strand simulation settings and state; its colliders are in
    /// `colliders`.
    simulation: ?render.HairSimulation = null,
    colliders: [max_hair_colliders][4]f32 = undefined,
    collider_count: u32 = 0,
    moving: ?HairMotion = null,
};

pub const max_hair_colliders = 6;

/// A `CollisionField` as a texture with one layer per cell along z.
pub const CollisionFieldState = struct {
    texture: rhi.Texture,
    low: [3]f32,
    cell: f32,
    size: u32,
};

pub const hair_density_size = 40;

/// World-space positions of a simulated hair's points, now and a step
/// ago; swapped every step.
pub const HairMotion = struct {
    points: [2]rhi.Buffer,
    /// Points per cell of a grid round the hair, a step ago and now, and
    /// the bounds the first was counted in.
    density: [2]rhi.Buffer,
    density_low: [3]f32 = .{ 0, 0, 0 },
    density_cell: f32 = 1,
    current: u32 = 0,
    steps: u32 = 0,
    previous_dt: f32 = 1.0 / 60.0,
};

pub const WaterState = struct {
    scene: Scene,
    desc: WaterDesc,
    size: [2]u32 = .{ 0, 0 },
    /// Height and its rate of change; the two alternate, `current` is newer.
    state: [2]rhi.Texture = undefined,
    current: u32 = 0,
    cleared: bool = false,
    /// The spray emitter, when `WaterDesc.splashes` asks for one.
    splash: ?Emitter = null,
    /// Strongest `addRipple` dent since the last step, for the spray.
    hit_strength: f32 = 0,
    hit_at: Vec3 = .{ 0, 0, 0 },
    hit_radius: f32 = 0,
    ripples: [gpu.max_water_ripples]gpu.WaterRipple = @splat(.{}),
    ripple_count: u32 = 0,
    /// Fractional raindrops carried to the next frame.
    rain_pending: f32 = 0,
    time_owed: f32 = 0,
    params: u64 = 0,
    params_frame: u64 = std.math.maxInt(u64),
};
pub const FluidState = struct {
    time_owed: f32 = 0,
    scene: Scene,
    desc: FluidDesc,
    sources: [gpu.max_fluid_sources]FluidSource = @splat(.{}),
    source_count: u32 = 0,
    obstacles: [gpu.max_fluid_obstacles]FluidObstacle = undefined,
    obstacle_count: u32 = 0,
    size: [3]u32 = .{ 0, 0, 0 },
    tiles_x: u32 = 1,
    /// Each a sheet of slices. Velocity and the scalars (smoke, heat, fuel)
    /// alternate between two textures; `current` is the newer.
    velocity: [2]rhi.Texture = undefined,
    scalars: [2]rhi.Texture = undefined,
    pressure: [2]rhi.Texture = undefined,
    divergence: rhi.Texture = undefined,
    curl: rhi.Texture = undefined,
    /// 1 in the cells inside an obstacle.
    solid: rhi.Texture = undefined,
    /// The advection's first guess at the scalars.
    carried: rhi.Texture = undefined,
    /// The same for the velocity, when `sharp_velocity` is on.
    carried_velocity: rhi.Texture = undefined,
    current: u32 = 0,
    pressure_current: u32 = 0,
    cleared: bool = false,
    /// The flattened picture `fluids.image` hands out, once asked for.
    picture: ?rhi.Texture = null,
    picture_drawn: bool = false,
    /// The sheet `fluids.recordFlipbook` fills, and its progress.
    flipbook: ?rhi.Texture = null,
    flipbook_desc: FluidFlipbookDesc = .{},
    flipbook_frame: [2]u32 = .{ 0, 0 },
    flipbook_recorded: u32 = 0,
    flipbook_wait: u32 = 0,
    /// Key of what the solid mask was last drawn from; 0 for never.
    mask_key: u64 = 0,
    /// Address of this frame's description on the GPU; 0 until simulated.
    params: u64 = 0,
    params_frame: u64 = std.math.maxInt(u64),

    pub fn setSources(self: *FluidState, sources: []const FluidSource) void {
        self.source_count = @intCast(sources.len);
        @memcpy(self.sources[0..sources.len], sources);
        self.desc.sources = &.{};
        self.obstacle_count = @intCast(self.desc.obstacles.len);
        @memcpy(self.obstacles[0..self.desc.obstacles.len], self.desc.obstacles);
        self.desc.obstacles = &.{};
    }

    /// Order matters: 4 to 6 hold one number per cell, 8 is the mask.
    pub fn textures(self: *FluidState) [11]*rhi.Texture {
        return .{ &self.velocity[0], &self.velocity[1], &self.scalars[0], &self.scalars[1], &self.pressure[0], &self.pressure[1], &self.divergence, &self.curl, &self.solid, &self.carried, &self.carried_velocity };
    }
};
pub const OitTargets = struct { accumulation: rhi.Texture, reveal: rhi.Texture };
pub const PeelTargets = struct { layer: rhi.Texture, accumulation: rhi.Texture, depth: [2]rhi.Texture };
pub const shade_plain_targets = [_]rhi.ColorTarget{ .{ .format = hdr_format }, .{ .format = .rg16_float } };
pub const shade_reflective_targets = [_]rhi.ColorTarget{ .{ .format = hdr_format }, .{ .format = .rg16_float }, .{ .format = hdr_format }, .{ .format = hdr_format } };
pub const InstanceGroupData = struct {
    scene: Scene,
    model: Model,
    transforms: []Mat4,
    /// One packed color per copy, or empty for no tint.
    tints: []u32 = &.{},
    /// One set of shader parameters per copy, or empty for zeros.
    params: [][4]f32 = &.{},
    /// The entity whose pose every copy takes; see `instances.setPose`.
    driver: ?Entity = null,
    /// First GPU instance index, and GPU instances per copy; set when the
    /// layout is rebuilt.
    base: u32 = 0,
    per_copy: u32 = 0,
    impostor: ?ImpostorState = null,
};

pub const ImpostorState = struct {
    /// The model's color and normals from 64 directions, a tile each.
    color: rhi.Texture,
    normal: rhi.Texture,
    pixels: f32,
    resolution: u32,
    baked: bool = false,
};
pub const InstanceSlot = struct {
    buffer: ?rhi.Buffer = null,
    capacity: u32 = 0,
    static_version: u64 = std.math.maxInt(u64),
    entity_count: usize = 0,
};

pub const EmitterData = struct {
    scene: Scene,
    desc: EmitterDesc,
    buffer: rhi.Buffer,
    capacity: u32,
    /// Next slot to spawn into; slots are reused in a ring.
    cursor: u32 = 0,
    pending: f32 = 0,
    /// Sort order for sorted emitters: one entry per slot, padded to 2^n.
    order: ?rhi.Buffer = null,
    order_count: u32 = 0,
    /// Trail positions: `trail_points` per slot, the newest at `trail_head`;
    /// `trail_clock` counts toward the next one.
    trail: ?rhi.Buffer = null,
    trail_points: u32 = 0,
    trail_head: u32 = 0,
    trail_clock: f32 = 0,
    warmed: bool = false,
    /// Scene shift since the particles were last simulated.
    shift: Vec3 = .{ 0, 0, 0 },
    /// Address of this frame's parameters on the GPU; 0 until simulated.
    frame_params: u64 = 0,
};
/// A reflection probe and its capture state.
pub const ProbeData = struct {
    scene: Scene,
    desc: ReflectionProbeDesc,
    target: rhi.Texture,
    view: View,
    cubes: EnvironmentEntry,
    dirty: bool = true,
    waited: u32 = 0,
    /// The next of the six faces to capture; 0 when idle.
    face: u32 = 0,
    /// Being captured: it is left out of its own pictures.
    capturing: bool = false,
    captured: bool = false,
};
pub const PickPending = struct { pixel: [2]u32, scene: Scene, layout_version: u64, near: f32 };

/// What a read-back copy of a scene's seen instances describes.
pub const SeenTag = struct { layout_version: u64 = 0, count: u32 = 0, valid: bool = false };
pub const DrawPipelines = struct { format: rhi.Format, flat: rhi.Pipeline, depth_tested: rhi.Pipeline };
pub const ImageEntry = struct { texture: rhi.Texture, index: u32, id: u32 };

pub const StreamFrustum = struct {
    view: Mat4,
    tan_x: f32,
    tan_y: f32,

    pub fn touches(self: StreamFrustum, center: Vec3, radius: f32) bool {
        const p = math.transformPoint(self.view, center);
        const depth = -p[2];
        if (depth + radius < 0) return false;
        const out_x = (@abs(p[0]) - depth * self.tan_x) / @sqrt(1 + self.tan_x * self.tan_x);
        const out_y = (@abs(p[1]) - depth * self.tan_y) / @sqrt(1 + self.tan_y * self.tan_y);
        return out_x < radius and out_y < radius;
    }
};

pub fn blockFormat(block: gltf.Image.Block, one_channel: bool, two_channel: bool, srgb: bool) rhi.Format {
    return switch (block) {
        .bc1 => if (srgb) .bc1_srgb else .bc1_unorm,
        .bc3 => if (srgb) .bc3_srgb else .bc3_unorm,
        .bc6h => .bc6h_ufloat,
        .rgba8 => if (srgb) .rgba8_srgb else .rgba8_unorm,
        .bc7 => if (one_channel) .bc4_unorm else if (two_channel) .bc5_unorm else if (srgb) .bc7_srgb else .bc7_unorm,
    };
}

/// What texture streaming reads of one mesh of a model, in instance order.
pub const StreamPart = struct {
    /// Texture coordinate change per meter on the mesh; 0 or less skips it.
    density: f32,
    center: Vec3,
    radius: f32,
    /// The node it hangs from; null for a skinned mesh.
    node: ?u32,
    /// Streamed images its material uses, and the base-2 logarithm of
    /// their larger side.
    streams: [5]u32 = @splat(gpu.invalid_id),
    log_sizes: [5]f32 = @splat(0),
};

pub const TextureStream = struct {
    /// The whole BC7 mip chain; empty for textures that are not streamed.
    data: []u8 = &.{},
    width: u32 = 0,
    height: u32 = 0,
    levels: u32 = 0,
    srgb: bool = false,
    two_channel: bool = false,
    block: gltf.Image.Block = .bc7,
    one_channel: bool = false,
    /// With levels read from the asset cache on demand: the whole chain's
    /// size, the offset in it where `data` begins, and the cache file.
    total: usize = 0,
    tail_offset: usize = 0,
    path: []u8 = &.{},
    /// Coarsest first level allowed: this and below always stay loaded.
    floor: u32 = 0,
    /// First level in GPU memory now, and the one the views ask for.
    resident: u32 = 0,
    wanted: u32 = 0,
    low_frames: u32 = 0,

    pub fn levelSize(self: TextureStream, level: u32) usize {
        return @intCast(self.format().dataSize(@max(self.width >> @intCast(level), 1), @max(self.height >> @intCast(level), 1)));
    }

    pub fn format(self: TextureStream) rhi.Format {
        return blockFormat(self.block, self.one_channel, self.two_channel, self.srgb);
    }

    pub fn levelOffset(self: TextureStream, level: u32) usize {
        var offset: usize = 0;
        for (0..level) |index| offset += self.levelSize(@intCast(index));
        return offset;
    }

    pub fn bytesFrom(self: TextureStream, first: u32) u64 {
        if (self.total != 0) return self.total - self.levelOffset(first);
        return self.data.len - self.levelOffset(first);
    }
};

pub const Zone = struct {
    profiler: ?Profiler,
    id: u64 = 0,

    pub fn start(profiler: ?Profiler, name: [:0]const u8) Zone {
        var zone = Zone{ .profiler = profiler };
        if (profiler) |p| zone.id = p.begin(p.context, name);
        return zone;
    }

    pub fn stop(self: Zone) void {
        if (self.profiler) |p| p.end(p.context, self.id);
    }
};

pub const EffectScales = struct {
    ao: EffectResolution,
    fog: EffectResolution,
    gi: EffectResolution,
    reflections: ?EffectResolution,
    clouds: ?EffectResolution,
    fluid: ?EffectResolution,
    lens: bool,
    /// Set when depth of field is gathered at reduced resolution.
    dof: ?EffectResolution = null,
    oit: bool,
    peel: bool,
    refraction: bool,
    liquid: bool = false,
    output_width: u32,
    output_height: u32,
    /// Temporal antialiasing resolves at the output size.
    temporal_upscale: bool = false,
    fsr: bool = false,
};

pub fn scaledExtent(resolution: EffectResolution, size: u32) u32 {
    return @max(size >> @intFromEnum(resolution), 1);
}
