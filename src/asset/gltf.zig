//! glTF 2.0 import: optimizes geometry into meshlets, decodes images in
//! parallel and keeps node/skin/animation data. CPU only; safe off the
//! render thread.
const std = @import("std");
const zmesh = @import("zmesh");
const zstbi = @import("zstbi");
const texture_codec = @import("texture_codec");
const model_cache = @import("model_cache.zig");
const ktx2 = @import("ktx2.zig");
const dds = @import("dds.zig");
const math = @import("../math.zig");
const build_features = @import("build_features");
const gltf = zmesh.io.zcgltf;

/// Maximum vertices per meshlet.
pub const max_meshlet_vertices = 64;
/// Maximum triangles per meshlet.
pub const max_meshlet_triangles = 124;

/// Unpacked vertex used during import; `Vertex` is the GPU form.
pub const FullVertex = extern struct {
    position: [3]f32,
    normal: [3]f32,
    /// w is the bitangent sign (1 or -1).
    tangent: [4]f32,
    uv: [2]f32,
    /// RGBA8, red in the low byte; multiplies the base color.
    color: u32 = 0xffffffff,
    uv1: [2]f32 = .{ 0, 0 },
};

/// GPU vertex layout (`Vertex` in common.glsl). Normal and tangent are
/// octahedron-encoded signed 16-bit pairs.
pub const Vertex = extern struct {
    position: [3]f32,
    normal: [2]i16,
    /// The lowest bit of the second component is set when the bitangent sign is
    /// -1.
    tangent: [2]i16,
    uv: [2]f32,
    /// RGBA8, red in the low byte; multiplies the base color.
    color: u32 = 0xffffffff,
    uv1: [2]f32 = .{ 0, 0 },

    pub fn pack(full: FullVertex) Vertex {
        var tangent = packDirection(full.tangent[0..3].*);
        tangent[1] = (tangent[1] & ~@as(i16, 1)) | @intFromBool(full.tangent[3] < 0);
        return .{
            .position = full.position,
            .normal = packDirection(full.normal),
            .tangent = tangent,
            .uv = full.uv,
            .color = full.color,
            .uv1 = full.uv1,
        };
    }

    pub fn unpackNormal(self: Vertex) [3]f32 {
        return unpackDirection(self.normal);
    }
};

/// Octahedron encoding (`packDirection` in common.glsl). A zero vector
/// becomes +X.
fn packDirection(direction: [3]f32) [2]i16 {
    const sum = @abs(direction[0]) + @abs(direction[1]) + @abs(direction[2]);
    if (!(sum > 1e-20)) return .{ 32767, 0 };
    var point = [2]f32{ direction[0] / sum, direction[1] / sum };
    if (direction[2] < 0) {
        const folded = [2]f32{ 1 - @abs(point[1]), 1 - @abs(point[0]) };
        point = .{ std.math.copysign(folded[0], point[0]), std.math.copysign(folded[1], point[1]) };
    }
    return .{
        @intFromFloat(@round(std.math.clamp(point[0], -1, 1) * 32767)),
        @intFromFloat(@round(std.math.clamp(point[1], -1, 1) * 32767)),
    };
}

fn unpackDirection(point: [2]i16) [3]f32 {
    var x = @max(@as(f32, @floatFromInt(point[0])) / 32767, -1);
    var y = @max(@as(f32, @floatFromInt(point[1])) / 32767, -1);
    const z = 1 - @abs(x) - @abs(y);
    const fold = @max(-z, 0);
    x += if (x >= 0) -fold else fold;
    y += if (y >= 0) -fold else fold;
    const length = @sqrt(x * x + y * y + z * z);
    return .{ x / length, y / length, z / length };
}

/// `SkinVertex` in common.glsl.
pub const SkinVertex = extern struct {
    joints: [4]u32,
    weights: [4]f32,
};

/// `Meshlet` in common.glsl.
pub const Meshlet = extern struct {
    /// Bounding sphere in mesh space.
    center: [3]f32,
    radius: f32,
    /// Normal cone for backface culling: axis and dot-product cutoff.
    cone_axis: [3]f32,
    cone_cutoff: f32,
    /// Range of `Mesh.indices`, relative to the mesh's first index.
    index_offset: u32,
    index_count: u32,
    /// Geometric error, in mesh units, of this meshlet's level of detail and of
    /// the next coarser one. Drawn when its own error is too small to see and
    /// the parent's is not.
    lod_error: f32 = 0,
    parent_error: f32 = std.math.floatMax(f32),
    /// With a cluster hierarchy: bounds (center, radius) of the group this
    /// meshlet was made from and of the group it was merged into. A negative
    /// radius means none; the whole mesh's bounds are used.
    self_sphere: [4]f32 = .{ 0, 0, 0, -1 },
    parent_sphere: [4]f32 = .{ 0, 0, 0, -1 },
};

comptime {
    std.debug.assert(@sizeOf(Vertex) == 40);
    std.debug.assert(@sizeOf(SkinVertex) == 32);
    std.debug.assert(@sizeOf(Meshlet) == 80);
}

/// glTF `alphaMode`.
pub const AlphaMode = enum { @"opaque", mask, blend };

/// A glTF sampler.
pub const SamplerData = struct {
    /// False for nearest magnification.
    linear: bool = true,
    repeat_u: AddressMode = .repeat,
    repeat_v: AddressMode = .repeat,

    pub const AddressMode = enum { repeat, mirrored_repeat, clamp_to_edge };
};

/// `KHR_texture_transform`: scale, rotate by `rotation` radians, then offset.
pub const UvTransform = struct {
    scale: [2]f32 = .{ 1, 1 },
    rotation: f32 = 0,
    offset: [2]f32 = .{ 0, 0 },

    pub fn eql(a: UvTransform, b: UvTransform) bool {
        return a.scale[0] == b.scale[0] and a.scale[1] == b.scale[1] and a.rotation == b.rotation and a.offset[0] == b.offset[0] and a.offset[1] == b.offset[1];
    }
};

pub const TextureRef = struct {
    /// Index into `Model.images`.
    image: u32,
    sampler: SamplerData = .{},
    transform: UvTransform = .{},
    /// Texture coordinate set: 0 or 1.
    uv_set: u8 = 0,
};

/// glTF metallic-roughness material plus the extensions noted on the fields.
/// Colors are linear. Texture references index a loaded model's images and
/// are ignored for `MeshDesc.material`.
pub const Material = struct {
    /// Linear RGBA, multiplied with `base_color_texture` and vertex colors.
    base_color: [4]f32 = .{ 1, 1, 1, 1 },
    /// Linear RGB, with `KHR_materials_emissive_strength` multiplied in.
    emissive: [3]f32 = .{ 0, 0, 0 },
    /// 0..1, multiplied with the blue (metallic) and green (roughness) channels
    /// of `metallic_roughness_texture`.
    metallic: f32 = 1,
    roughness: f32 = 1,
    /// Scales the normal map's X and Y.
    normal_scale: f32 = 1,
    /// 0 ignores the occlusion map, 1 applies it fully.
    occlusion_strength: f32 = 1,
    /// With `.mask`: alpha below this is not drawn.
    alpha_cutoff: f32 = 0.5,
    alpha_mode: AlphaMode = .@"opaque",
    double_sided: bool = false,
    /// `KHR_materials_pbrSpecularGlossiness`: `base_color` and its texture are
    /// the diffuse color, `roughness` is the glossiness factor, and
    /// `metallic_roughness_texture` holds specular in RGB (sRGB) and glossiness
    /// in alpha.
    specular_glossiness: bool = false,
    /// Linear RGB specular factor of a `specular_glossiness` material.
    specular: [3]f32 = .{ 1, 1, 1 },
    base_color_texture: ?TextureRef = null,
    normal_texture: ?TextureRef = null,
    metallic_roughness_texture: ?TextureRef = null,
    occlusion_texture: ?TextureRef = null,
    emissive_texture: ?TextureRef = null,
    /// `MaterialShader.slot`; 0 for the standard material.
    shader: u32 = 0,
    /// Parameters for the custom material shader.
    params: [4]f32 = .{ 0, 0, 0, 0 },
    /// `KHR_materials_clearcoat` strength, 0..1.
    clearcoat: f32 = 0,
    clearcoat_roughness: f32 = 0.03,
    /// Coat strength in red, roughness in green. Without a coat normal map the
    /// coat ignores the base normal map.
    clearcoat_texture: ?TextureRef = null,
    clearcoat_roughness_texture: ?TextureRef = null,
    clearcoat_normal_texture: ?TextureRef = null,
    clearcoat_normal_scale: f32 = 1,
    /// `KHR_materials_transmission`, 0..1. Drawn with the transparent surfaces,
    /// refracting the scene behind by `ior`.
    transmission: f32 = 0,
    /// Index of refraction (`KHR_materials_ior`).
    ior: f32 = 1.5,
    /// Thickness used for refraction, in world units (`KHR_materials_volume`).
    thickness: f32 = 0.1,
    /// `KHR_materials_sheen`.
    sheen_color: [3]f32 = .{ 0, 0, 0 },
    sheen_roughness: f32 = 0.5,
    /// Sheen color in RGB, roughness in alpha.
    sheen_color_texture: ?TextureRef = null,
    sheen_roughness_texture: ?TextureRef = null,
    /// `KHR_materials_anisotropy`: strength 0..1 and rotation from the tangent
    /// in radians. Needs tangents.
    anisotropy: f32 = 0,
    anisotropy_rotation: f32 = 0,
    /// Subsurface scattering approximation, 0..1. Applied to the sun only.
    subsurface: f32 = 0,
    /// Scale, rotation (radians), then offset, applied to texture coordinates.
    /// Textures with their own `TextureRef.transform` use that instead.
    uv_scale: [2]f32 = .{ 1, 1 },
    uv_rotation: f32 = 0,
    uv_offset: [2]f32 = .{ 0, 0 },
    /// Wind sway: world units a point one unit above the entity or instance
    /// origin moves at the peak of a gust; grows with the square of height. 0
    /// disables. Shadows sway along; ray tracing does not.
    sway: f32 = 0,

    /// Texture references in shader order: base color, normal,
    /// metallic-roughness, occlusion, emissive, coat, coat roughness, coat
    /// normal, sheen color, sheen roughness.
    pub fn textureRefs(self: Material) [10]?TextureRef {
        return .{
            self.base_color_texture,  self.normal_texture,          self.metallic_roughness_texture,  self.occlusion_texture,
            self.emissive_texture,    self.clearcoat_texture,       self.clearcoat_roughness_texture, self.clearcoat_normal_texture,
            self.sheen_color_texture, self.sheen_roughness_texture,
        };
    }

    /// The transform of every texture that carries none of its own.
    pub fn sharedTransform(self: Material) UvTransform {
        return .{ .scale = self.uv_scale, .rotation = self.uv_rotation, .offset = self.uv_offset };
    }

    /// Whether any texture's transform differs from the shared one.
    pub fn hasOwnTransforms(self: Material) bool {
        const shared = self.sharedTransform();
        for (self.textureRefs()) |maybe| if (maybe) |ref| {
            if (!ref.transform.eql(shared)) return true;
        };
        return false;
    }
};

/// One texture image. Exactly one of `decoded` and `compressed` holds the
/// pixels until `Model.releaseImage` or `takeCompressed` takes them.
pub const Image = struct {
    width: u32 = 0,
    height: u32 = 0,
    /// True for color data (base color, emissive).
    srgb: bool = false,
    /// RGBA8 pixels. Freed by `Model.deinit` or `releaseImage`.
    decoded: ?zstbi.Image = null,
    /// Mip chain, largest level first; `decoded` is null then. Owned by the
    /// model's allocator.
    compressed: ?[]u8 = null,
    /// Key in the asset cache; 0 when none.
    cache_key: u64 = 0,
    normal_map: bool = false,
    /// For images in a file of their own: its path, and a stamp of its size and
    /// modification time when read.
    source_path: []const u8 = "",
    source_stamp: u64 = 0,
    /// `compressed` is BC5.
    two_channel: bool = false,
    /// `compressed` is BC4.
    one_channel: bool = false,
    /// Material slots using the image, and how many of those are occlusion.
    uses: u16 = 0,
    occlusion_uses: u16 = 0,
    /// Block format of `compressed` when read from a KTX2 file. `two_channel`
    /// and `one_channel` override `.bc7` with BC5 and BC4.
    block: Block = .bc7,

    /// Mip levels in `compressed`; 0 means the full chain.
    mip_levels: u32 = 0,

    /// Texel format of `compressed`. `.rgba8` is an uncompressed mip chain
    /// (`LoadOptions.raw_mips`).
    pub const Block = enum(u8) { bc7, bc1, bc3, bc6h, rgba8 };

    /// RGBA8 pixels of `decoded`, top row first; empty when compressed or
    /// released.
    pub fn pixels(self: Image) []const u8 {
        return if (self.decoded) |image| image.data else &.{};
    }
};

/// Further morph targets are ignored.
pub const max_morph_targets = 64;

/// One morph target's offsets for one vertex.
pub const MorphDelta = extern struct {
    position: [3]f32,
    normal: [3]f32,
    tangent: [3]f32 = .{ 0, 0, 0 },
};

/// One processed glTF primitive. Slices belong to the model's arena.
pub const Mesh = struct {
    vertices: []Vertex,
    /// Skinned meshes only; parallel to `vertices`.
    skin: ?[]SkinVertex,
    /// Meshlet-ordered triangle list indexing `vertices`.
    indices: []u32,
    meshlets: []Meshlet,
    /// The full-detail level comes first in `indices` and `meshlets`.
    lod0_index_count: u32,
    lod0_meshlet_count: u32,
    /// Bounding sphere of the rest pose, in mesh space.
    bounds_center: [3]f32,
    bounds_radius: f32,
    /// Index into `Model.materials`.
    material: u32,
    /// Texture coordinate units per meter of surface (area-weighted mean). 0 if
    /// unknown.
    uv_density: f32 = 0,
    /// `morph_deltas` holds `morph_targets` runs of one delta per vertex.
    /// Skinned meshes only.
    morph_targets: u32 = 0,
    morph_deltas: []MorphDelta = &.{},
    morph_weights: [max_morph_targets]f32 = @splat(0),
    /// Leading vertices used by the coarser levels. 0 when the mesh cannot be
    /// split (one level, skinned, or clusters with no coarser form).
    coarse_vertex_count: u32 = 0,
    /// Error to draw the mesh at when only its coarse part is loaded.
    coarse_error: f32 = 0,
};

/// Local transform is `matrix` when set, otherwise translation, rotation
/// (quaternion `{x, y, z, w}`) and scale.
pub const Node = struct {
    name: []const u8 = "",
    /// Index into `Model.nodes`; null for a root.
    parent: ?u32 = null,
    translation: [3]f32 = .{ 0, 0, 0 },
    rotation: [4]f32 = .{ 0, 0, 0, 1 },
    scale: [3]f32 = .{ 1, 1, 1 },
    matrix: ?[16]f32 = null,
};

/// A mesh placed by a node, optionally deformed by a skin.
pub const Instance = struct {
    /// Indices into `Model.meshes`, `Model.nodes` and `Model.skins`.
    mesh: u32,
    node: u32,
    skin: ?u32,
};

/// `joints` are node indices; `SkinVertex.joints` index it. The inverse bind
/// matrices are parallel to it and column-major.
pub const Skin = struct {
    joints: []u32,
    inverse_bind: [][16]f32,
};

pub const ChannelPath = enum { translation, rotation, scale, weights };

pub const Channel = struct {
    /// Index into `Model.nodes`.
    node: u32,
    path: ChannelPath,
    /// Hold each key's value instead of interpolating.
    step: bool,
    /// Cubic spline: `values` holds in-tangent, value and out-tangent per key.
    cubic: bool = false,
    /// For `.weights`: values per key (the mesh's target count).
    width: u32 = 0,
    /// Seconds, ascending.
    times: []f32,
    /// 3 floats per key for translation/scale, 4 for rotation.
    values: []f32,
};

/// `duration` is the time of the last key of any channel, in seconds.
pub const Animation = struct {
    name: []const u8,
    duration: f32,
    channels: []Channel,
};

/// A loaded model, CPU side. Allocated from `arena`, except image pixels,
/// which come from the arena's backing allocator. Free with `deinit`.
pub const Model = struct {
    arena: std.heap.ArenaAllocator,
    meshes: []Mesh = &.{},
    materials: []Material = &.{},
    images: []Image = &.{},
    nodes: []Node = &.{},
    instances: []Instance = &.{},
    skins: []Skin = &.{},
    /// While loading: nodes whose unskinned mesh has morph targets. Each gets a
    /// one-joint skin of its own.
    implicit_skins: []u32 = &.{},
    animations: []Animation = &.{},

    /// Frees the model and every image still held, but not chains handed out by
    /// `takeCompressed`.
    pub fn deinit(self: *Model) void {
        for (self.images) |*image| {
            if (image.decoded) |*decoded| decoded.deinit();
            if (image.compressed) |data| self.arena.child_allocator.free(data);
        }
        self.arena.deinit();
        self.* = undefined;
    }

    /// Hands an image's compressed mip chain to the caller, who frees it with
    /// `freeCompressed`.
    pub fn takeCompressed(self: *Model, index: usize) []u8 {
        const data = self.images[index].compressed.?;
        self.images[index].compressed = null;
        return data;
    }

    /// Frees a chain returned by `takeCompressed`. Valid until `deinit`.
    pub fn freeCompressed(self: *Model, data: []u8) void {
        self.arena.child_allocator.free(data);
    }

    /// Frees an image's pixels, decoded or compressed. Its size and flags stay
    /// readable.
    pub fn releaseImage(self: *Model, index: usize) void {
        if (self.images[index].decoded) |*decoded| decoded.deinit();
        self.images[index].decoded = null;
        if (self.images[index].compressed) |data| self.arena.child_allocator.free(data);
        self.images[index].compressed = null;
    }
};

var library_mutex: std.Io.Mutex = .init;
var library_references: u32 = 0;

/// Initializes the importer's C libraries once; reference counted.
pub fn acquireLibraries(io: std.Io) void {
    library_mutex.lockUncancelable(io);
    defer library_mutex.unlock(io);
    if (library_references == 0) {
        zmesh.init(std.heap.smp_allocator);
        zstbi.init(io, std.heap.smp_allocator);
    }
    library_references += 1;
}

/// Undoes one `acquireLibraries`. Models and images must be freed before the
/// last release.
pub fn releaseLibraries(io: std.Io) void {
    library_mutex.lockUncancelable(io);
    defer library_mutex.unlock(io);
    library_references -= 1;
    if (library_references == 0) {
        zstbi.deinit();
        zmesh.deinit();
    }
}

/// Reads a whole file, relative to the working directory. Caller frees with
/// `gpa`. `error.InvalidFileSize` for an empty file or one over 4 GiB.
pub fn readFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]align(16) u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.size == 0 or stat.size > 4 * 1024 * 1024 * 1024) return error.InvalidFileSize;
    const bytes = try gpa.alignedAlloc(u8, .@"16", @intCast(stat.size));
    errdefer gpa.free(bytes);
    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    try reader.interface.readSliceAll(bytes);
    return bytes;
}

/// Loads and processes a `.glb`/`.gltf` file. Requires `acquireLibraries`.
/// The caller owns the result and must `deinit` it.
pub fn load(gpa: std.mem.Allocator, io: std.Io, path: []const u8, options: LoadOptions) !Model {
    const model_cache_dir: ?[]const u8 = if (options.compress_textures) options.cache_dir else null;
    var salt = std.hash.Wyhash.init(@intFromBool(options.lods.clusters));
    salt.update(std.mem.asBytes(&[2]f32{ options.lods.normal_weight, options.lods.uv_weight }));
    salt.update(&.{@intFromBool(options.normal_maps_bc5)});
    if (options.cache_dir != null) salt.update(std.mem.asBytes(&bufferStamp(gpa, io, path)));
    const cache_salt = salt.final();
    if (model_cache_dir) |directory| {
        if (loadCached(gpa, io, path, directory, cache_salt) catch null) |cached| return cached;
    }
    var model = Model{ .arena = .init(gpa) };
    errdefer model.deinit();
    const arena = model.arena.allocator();

    const bytes = try readFile(gpa, io, path);
    defer gpa.free(bytes);
    const parse_options = gltf.Options{ .memory = .{
        .alloc_func = zmesh.mem.zmeshAllocUser,
        .free_func = zmesh.mem.zmeshFreeUser,
    } };
    const data = try gltf.parse(parse_options, bytes);
    defer gltf.free(data);
    const path_z = try gpa.dupeZ(u8, path);
    defer gpa.free(path_z);
    try gltf.loadBuffers(parse_options, data, path_z.ptr);
    if (build_features.validate_input and gltf.validate(data) != .success) return error.InvalidGltf;

    model.images = try arena.alloc(Image, data.images_count);
    for (model.images) |*image| image.* = .{};
    try loadMaterials(arena, data, &model);
    const jobs = try gpa.alloc(ImageJob, data.images_count);
    defer gpa.free(jobs);
    var group: std.Io.Group = .init;
    errdefer group.cancel(io);
    for (jobs, 0..) |*job, index| {
        job.* = .{ .gpa = gpa, .io = io, .source = &data.images.?[index], .model_path = path, .output = &model.images[index], .options = options };
        if (data.images.?[index].buffer_view == null) if (data.images.?[index].uri) |uri_pointer| {
            const uri = std.mem.span(uri_pointer);
            if (std.mem.indexOf(u8, uri, ";base64,") == null) {
                const image_path = try std.fs.path.join(arena, &.{ std.fs.path.dirname(path) orelse ".", uri });
                model.images[index].source_path = image_path;
                model.images[index].source_stamp = modelKey(io, image_path) catch 0;
            }
        };
        group.async(io, decodeImage, .{job});
    }

    const geometry_cache_dir: ?[]const u8 = if (options.compress_textures) null else options.cache_dir;
    const cached_geometry: ?CachedModel = if (geometry_cache_dir) |directory| readCachedGeometry(gpa, io, path, directory, arena, cache_salt) else null;
    if (cached_geometry) |cached| {
        model.meshes = cached.meshes;
        model.materials = cached.materials;
        model.nodes = cached.nodes;
        model.instances = cached.instances;
        model.skins = cached.skins;
        model.animations = cached.animations;
    } else {
        try loadNodes(arena, data, &model);
        try loadMeshes(gpa, arena, data, &model, options.lods);
        try loadSkins(gpa, arena, data, &model);
        try loadAnimations(gpa, arena, data, &model);
    }

    try group.await(io);
    for (jobs) |job| if (job.failure) |err| return err;
    if (geometry_cache_dir) |directory| if (cached_geometry == null) storeCachedGeometry(gpa, io, path, directory, &model, cache_salt) catch |err|
        std.log.warn("model cache: could not store {s}: {s}", .{ path, @errorName(err) });
    if (model_cache_dir) |directory| storeCached(gpa, io, path, directory, &model, cache_salt) catch |err|
        std.log.warn("model cache: could not store {s}: {s}", .{ path, @errorName(err) });
    return model;
}

fn elementIndex(comptime T: type, base: ?[*]T, pointer: *const T) u32 {
    return @intCast((@intFromPtr(pointer) - @intFromPtr(base.?)) / @sizeOf(T));
}

const ImageJob = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    source: *const gltf.Image,
    model_path: []const u8,
    output: *Image,
    options: LoadOptions,
    failure: ?anyerror = null,
};

fn decodeImage(job: *ImageJob) std.Io.Cancelable!void {
    decodeImageInner(job) catch |err| {
        if (err == error.Canceled) return error.Canceled;
        job.failure = err;
    };
}

fn decodeImageInner(job: *ImageJob) !void {
    if (job.output.uses == 0) return;
    var owned: ?[]u8 = null;
    defer if (owned) |bytes| job.gpa.free(bytes);
    const encoded: []const u8 = if (job.source.buffer_view) |view| blk: {
        const buffer = view.buffer.data orelse return error.MissingImageData;
        break :blk @as([*]const u8, @ptrCast(buffer))[view.offset..][0..view.size];
    } else if (job.source.uri) |uri_pointer| blk: {
        const uri = std.mem.span(uri_pointer);
        const marker = ";base64,";
        if (std.mem.indexOf(u8, uri, marker)) |marker_index| {
            const text = uri[marker_index + marker.len ..];
            const decoded = try job.gpa.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(text));
            owned = decoded;
            try std.base64.standard.Decoder.decode(decoded, text);
            break :blk decoded;
        }
        const directory = std.fs.path.dirname(job.model_path) orelse ".";
        const file_name = try job.gpa.dupe(u8, uri);
        defer job.gpa.free(file_name);
        const image_path = try std.fs.path.join(job.gpa, &.{ directory, std.Uri.percentDecodeInPlace(file_name) });
        defer job.gpa.free(image_path);
        const file_bytes = try readFile(job.gpa, job.io, image_path);
        owned = file_bytes;
        break :blk file_bytes;
    } else return error.MissingImageData;

    if (ktx2.isKtx2(encoded)) {
        const texture = try ktx2.read(job.gpa, encoded);
        errdefer job.gpa.free(texture.data);
        if (texture.faces != 1 or texture.layers != 1) return error.UnsupportedKtx2;
        switch (texture.format) {
            .bc7 => {},
            .bc1 => job.output.block = .bc1,
            .bc3 => job.output.block = .bc3,
            .bc6h => job.output.block = .bc6h,
            .bc4 => job.output.one_channel = true,
            .bc5 => job.output.two_channel = true,
            .rgba8, .rgba16f => return error.UnsupportedKtx2,
        }
        job.output.width = texture.width;
        job.output.height = texture.height;
        job.output.mip_levels = texture.levels;
        job.output.compressed = texture.data;
        return;
    }
    if (dds.isDds(encoded)) {
        const texture = try dds.read(encoded);
        switch (texture.format) {
            .bc7 => {},
            .bc1 => job.output.block = .bc1,
            .bc3 => job.output.block = .bc3,
            .bc6h => job.output.block = .bc6h,
            .bc4 => job.output.one_channel = true,
            .bc5 => job.output.two_channel = true,
        }
        job.output.width = texture.width;
        job.output.height = texture.height;
        job.output.mip_levels = texture.levels;
        job.output.compressed = try job.gpa.dupe(u8, texture.data);
        return;
    }
    if (!job.options.compress_textures and job.options.raw_mips) {
        var decoded = try zstbi.Image.loadFromMemory(encoded, 4);
        defer decoded.deinit();
        job.output.width = decoded.width;
        job.output.height = decoded.height;
        job.output.compressed = try texture_codec.rawChain(job.gpa, decoded.data, decoded.width, decoded.height, job.output.srgb);
        job.output.block = .rgba8;
        return;
    }
    if (!job.options.compress_textures) {
        const decoded = try zstbi.Image.loadFromMemory(encoded, 4);
        job.output.width = decoded.width;
        job.output.height = decoded.height;
        job.output.decoded = decoded;
        return;
    }

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    job.output.cache_key = textureKey(encoded, job.output.srgb);
    job.output.two_channel = job.options.normal_maps_bc5 and job.output.normal_map and !job.output.srgb;
    job.output.one_channel = job.options.normal_maps_bc5 and job.output.uses != 0 and job.output.uses == job.output.occlusion_uses and !job.output.two_channel and !job.output.srgb;
    const extension: []const u8 = if (job.output.two_channel) "bc5" else if (job.output.one_channel) "bc4" else "bc7";
    const cached_path: ?[]u8 = if (job.options.cache_dir) |directory|
        try cachePath(&path_buffer, directory, job.output.cache_key, extension)
    else
        null;
    if (cached_path) |path| if (readCachedTexture(job.gpa, job.io, path, job.output)) |data| {
        job.output.compressed = data;
        return;
    };
    var decoded = try zstbi.Image.loadFromMemory(encoded, 4);
    defer decoded.deinit();
    job.output.width = decoded.width;
    job.output.height = decoded.height;
    const data = try texture_codec.encodeChain(job.gpa, decoded.data, decoded.width, decoded.height, job.output.srgb, if (job.output.two_channel) .bc5 else if (job.output.one_channel) .bc4 else .bc7);
    job.output.compressed = data;
    if (cached_path) |path| {
        var header: [12]u8 = undefined;
        header[0..4].* = cache_magic;
        std.mem.writeInt(u32, header[4..8], decoded.width, .little);
        std.mem.writeInt(u32, header[8..12], decoded.height, .little);
        writeCacheFile(job.io, job.options.cache_dir.?, path, &.{ &header, data }) catch |err|
            std.log.warn("texture cache: could not write {s}: {s}", .{ path, @errorName(err) });
    }
}

/// A `KHR_lights_punctual` light, placed by its node.
pub const SceneLight = struct {
    kind: enum { directional, point, spot },
    position: [3]f32,
    /// Unit vector the light shines along.
    direction: [3]f32,
    /// Linear RGB.
    color: [3]f32,
    /// Candela for point and spot lights, lux for directional.
    intensity: f32,
    /// 0 for unlimited.
    range: f32,
    /// Spot cone half-angles, in radians.
    inner_angle: f32,
    outer_angle: f32,
};

/// The lights of a glTF file. Reads only its JSON. Caller frees the result.
pub fn loadLights(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]SceneLight {
    const bytes = try readFile(gpa, io, path);
    defer gpa.free(bytes);
    const data = try gltf.parse(.{ .memory = .{
        .alloc_func = zmesh.mem.zmeshAllocUser,
        .free_func = zmesh.mem.zmeshFreeUser,
    } }, bytes);
    defer gltf.free(data);
    if (build_features.validate_input and gltf.validate(data) != .success) return error.InvalidGltf;
    var lights: std.ArrayList(SceneLight) = .empty;
    errdefer lights.deinit(gpa);
    if (data.nodes_count == 0) return lights.toOwnedSlice(gpa);
    for (data.nodes.?[0..data.nodes_count]) |node| {
        const light = node.light orelse continue;
        const world = node.transformWorld();
        const axis = [3]f32{ -world[8], -world[9], -world[10] };
        const length = @sqrt(axis[0] * axis[0] + axis[1] * axis[1] + axis[2] * axis[2]);
        try lights.append(gpa, .{
            .kind = switch (light.type) {
                .directional => .directional,
                .spot => .spot,
                else => .point,
            },
            .position = .{ world[12], world[13], world[14] },
            .direction = if (length > 0) .{ axis[0] / length, axis[1] / length, axis[2] / length } else .{ 0, -1, 0 },
            .color = light.color,
            .intensity = light.intensity,
            .range = light.range,
            .inner_angle = light.spot_inner_cone_angle,
            .outer_angle = light.spot_outer_cone_angle,
        });
    }
    return lights.toOwnedSlice(gpa);
}

pub const LoadOptions = struct {
    /// Encode textures as BC7 with a full mip chain instead of leaving RGBA8.
    compress_textures: bool = false,
    /// Texture cache directory, keyed by source image content. Null disables.
    cache_dir: ?[]const u8 = null,
    /// Without compression: build and keep each texture's mip levels on the
    /// CPU,
    /// as streaming needs.
    raw_mips: bool = false,
    lods: LodOptions = .{},
    /// Store normal maps as BC5 instead of BC7 when compressing.
    normal_maps_bc5: bool = true,
};

const cache_magic = [4]u8{ 'R', 'T', 'E', 'X' };

fn textureKey(encoded: []const u8, srgb: bool) u64 {
    var hasher = std.hash.Wyhash.init(texture_codec.version);
    hasher.update(encoded);
    hasher.update(&.{@intFromBool(srgb)});
    return hasher.final();
}

fn cachePath(buffer: []u8, directory: []const u8, key: u64, extension: []const u8) ![]u8 {
    return std.fmt.bufPrint(buffer, "{s}/{x:0>16}.{s}", .{ directory, key, extension });
}

/// Returns the cached chain for an image and fills in its size, or null when
/// missing or invalid.
fn readCachedTexture(gpa: std.mem.Allocator, io: std.Io, path: []const u8, output: *Image) ?[]u8 {
    const bytes = readFile(gpa, io, path) catch return null;
    defer gpa.free(bytes);
    if (bytes.len < 12 or !std.mem.eql(u8, bytes[0..4], &cache_magic)) return null;
    const width = std.mem.readInt(u32, bytes[4..8], .little);
    const height = std.mem.readInt(u32, bytes[8..12], .little);
    if (width == 0 or height == 0 or width > 16384 or height > 16384) return null;
    if (bytes.len - 12 != texture_codec.chainSizeOf(if (output.one_channel) .bc4 else .bc7, width, height)) return null;
    const data = gpa.dupe(u8, bytes[12..]) catch return null;
    output.width = width;
    output.height = height;
    return data;
}

/// Writes `parts` back to back as one cache file, renamed into place only
/// once complete.
fn writeCacheFile(io: std.Io, directory: []const u8, path: []const u8, parts: []const []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, directory);
    var temporary_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const temporary = try std.fmt.bufPrint(&temporary_buffer, "{s}.{x}.tmp", .{ path, @intFromPtr(parts.ptr) });
    {
        const file = try std.Io.Dir.cwd().createFile(io, temporary, .{});
        defer file.close(io);
        var buffer: [64 * 1024]u8 = undefined;
        var writer = file.writerStreaming(io, &buffer);
        for (parts) |part| try writer.interface.writeAll(part);
        try writer.interface.flush();
    }
    try std.Io.Dir.cwd().rename(temporary, std.Io.Dir.cwd(), path, io);
}

const CachedImage = struct { width: u32, height: u32, srgb: bool, key: u64, two_channel: bool, one_channel: bool, source_path: []const u8, source_stamp: u64 };

/// Everything `load` produces except texture pixels.
const CachedModel = struct {
    meshes: []Mesh,
    materials: []Material,
    nodes: []Node,
    instances: []Instance,
    skins: []Skin,
    animations: []Animation,
    images: []CachedImage,
};

/// Stamps the buffer files a `.gltf` names, so that the cache notices one
/// changing. 0 for a `.glb`.
fn bufferStamp(gpa: std.mem.Allocator, io: std.Io, path: []const u8) u64 {
    if (!std.ascii.endsWithIgnoreCase(path, ".gltf")) return 0;
    const bytes = readFile(gpa, io, path) catch return 0;
    defer gpa.free(bytes);
    const data = gltf.parse(.{ .memory = .{
        .alloc_func = zmesh.mem.zmeshAllocUser,
        .free_func = zmesh.mem.zmeshFreeUser,
    } }, bytes) catch return 0;
    defer gltf.free(data);
    if (data.buffers_count == 0) return 0;
    const directory = std.fs.path.dirname(path) orelse ".";
    var stamp: u64 = 0;
    for (data.buffers.?[0..data.buffers_count]) |buffer| {
        const uri = std.mem.span(buffer.uri orelse continue);
        if (std.mem.startsWith(u8, uri, "data:")) continue;
        const file_name = gpa.dupe(u8, uri) catch continue;
        defer gpa.free(file_name);
        const buffer_path = std.fs.path.join(gpa, &.{ directory, std.Uri.percentDecodeInPlace(file_name) }) catch continue;
        defer gpa.free(buffer_path);
        stamp = stamp *% 31 +% (modelKey(io, buffer_path) catch 0);
    }
    return stamp;
}

/// Hashes path, size and modification time. Images a `.gltf` references by
/// URI are not included.
fn modelKey(io: std.Io, path: []const u8) !u64 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    var hasher = std.hash.Wyhash.init(model_cache.version +% texture_codec.version *% 65537);
    hasher.update(path);
    hasher.update(std.mem.asBytes(&stat.size));
    hasher.update(std.mem.asBytes(&stat.mtime));
    return hasher.final();
}

const CachedTextureJob = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    directory: []const u8,
    output: *Image,
    missing: bool = false,
};

fn readCachedTextureJob(job: *CachedTextureJob) std.Io.Cancelable!void {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = cachePath(&buffer, job.directory, job.output.cache_key, if (job.output.two_channel) "bc5" else if (job.output.one_channel) "bc4" else "bc7") catch {
        job.missing = true;
        return;
    };
    job.output.compressed = readCachedTexture(job.gpa, job.io, path, job.output);
    job.missing = job.output.compressed == null;
}

/// Null when any part of the cached model is missing or stale.
fn loadCached(gpa: std.mem.Allocator, io: std.Io, path: []const u8, directory: []const u8, salt: u64) !?Model {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cached_path = try cachePath(&path_buffer, directory, (modelKey(io, path) catch return null) ^ salt, "model");
    const bytes = readFile(gpa, io, cached_path) catch return null;
    defer gpa.free(bytes);
    const payload = model_cache.unseal(bytes) orelse return null;

    var model = Model{ .arena = .init(gpa) };
    errdefer model.deinit();
    const arena = model.arena.allocator();
    var reader = model_cache.Reader{ .bytes = payload };
    const cached = reader.get(arena, CachedModel) catch return error.CorruptCache;
    model.meshes = cached.meshes;
    model.materials = cached.materials;
    model.nodes = cached.nodes;
    model.instances = cached.instances;
    model.skins = cached.skins;
    model.animations = cached.animations;
    for (cached.images) |source| {
        if (source.source_path.len == 0) continue;
        if ((modelKey(io, source.source_path) catch 0) != source.source_stamp) {
            model.deinit();
            return null;
        }
    }
    model.images = try arena.alloc(Image, cached.images.len);
    for (model.images, cached.images) |*image, source| {
        image.* = .{ .width = source.width, .height = source.height, .srgb = source.srgb, .cache_key = source.key, .two_channel = source.two_channel, .one_channel = source.one_channel };
    }

    const jobs = try gpa.alloc(CachedTextureJob, model.images.len);
    defer gpa.free(jobs);
    var group: std.Io.Group = .init;
    errdefer group.cancel(io);
    for (jobs, model.images) |*job, *image| {
        job.* = .{ .gpa = gpa, .io = io, .directory = directory, .output = image };
        if (image.width != 0) group.async(io, readCachedTextureJob, .{job});
    }
    try group.await(io);
    for (jobs) |job| if (job.missing) {
        model.deinit();
        return null;
    };
    return model;
}

fn storeCached(gpa: std.mem.Allocator, io: std.Io, path: []const u8, directory: []const u8, model: *const Model, salt: u64) !void {
    for (model.images) |image| if (image.compressed != null and image.cache_key == 0) return;
    const images = try gpa.alloc(CachedImage, model.images.len);
    defer gpa.free(images);
    for (images, model.images) |*out, image| {
        const usable = image.compressed != null;
        out.* = .{
            .width = if (usable) image.width else 0,
            .height = if (usable) image.height else 0,
            .srgb = image.srgb,
            .key = image.cache_key,
            .two_channel = image.two_channel,
            .one_channel = image.one_channel,
            .source_path = image.source_path,
            .source_stamp = image.source_stamp,
        };
    }
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(gpa);
    try model_cache.put(gpa, &payload, CachedModel{
        .meshes = model.meshes,
        .materials = model.materials,
        .nodes = model.nodes,
        .instances = model.instances,
        .skins = model.skins,
        .animations = model.animations,
        .images = images,
    });
    const sealed = try model_cache.seal(gpa, payload.items);
    defer gpa.free(sealed);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    try writeCacheFile(io, directory, try cachePath(&path_buffer, directory, (try modelKey(io, path)) ^ salt, "model"), &.{sealed});
}

/// Reads a model's cached geometry, without images, into `arena`. Null when
/// missing or stale.
fn readCachedGeometry(gpa: std.mem.Allocator, io: std.Io, path: []const u8, directory: []const u8, arena: std.mem.Allocator, salt: u64) ?CachedModel {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cached_path = cachePath(&path_buffer, directory, (modelKey(io, path) catch return null) ^ salt, "geometry") catch return null;
    const bytes = readFile(gpa, io, cached_path) catch return null;
    defer gpa.free(bytes);
    const payload = model_cache.unseal(bytes) orelse return null;
    var reader = model_cache.Reader{ .bytes = payload };
    return reader.get(arena, CachedModel) catch null;
}

fn storeCachedGeometry(gpa: std.mem.Allocator, io: std.Io, path: []const u8, directory: []const u8, model: *const Model, salt: u64) !void {
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(gpa);
    try model_cache.put(gpa, &payload, CachedModel{
        .meshes = model.meshes,
        .materials = model.materials,
        .nodes = model.nodes,
        .instances = model.instances,
        .skins = model.skins,
        .animations = model.animations,
        .images = &.{},
    });
    const sealed = try model_cache.seal(gpa, payload.items);
    defer gpa.free(sealed);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    try writeCacheFile(io, directory, try cachePath(&path_buffer, directory, (try modelKey(io, path)) ^ salt, "geometry"), &.{sealed});
}

/// Equirectangular HDR image, RGBA half floats.
pub const HdrImage = struct {
    width: u32,
    height: u32,
    decoded: zstbi.Image,
    /// World-space direction toward the brightest texel.
    brightest_direction: [3]f32,

    /// `acquireLibraries` must still be in effect.
    pub fn deinit(self: *HdrImage) void {
        self.decoded.deinit();
    }

    /// 8 bytes a texel, top row first. Valid until `deinit`.
    pub fn pixels(self: HdrImage) []const u8 {
        return self.decoded.data;
    }
};

/// Decodes a Radiance `.hdr` panorama. Requires `acquireLibraries`. `gpa` is
/// used only while decoding; free the result with `deinit`.
/// `error.NotAnHdrImage` for any other kind of file.
pub fn loadHdr(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !HdrImage {
    const bytes = try readFile(gpa, io, path);
    defer gpa.free(bytes);
    if (!zstbi.isHdrFromMem(bytes)) return error.NotAnHdrImage;
    var decoded = try zstbi.Image.loadFromMemory(bytes, 4);
    errdefer decoded.deinit();
    const texels: []const [4]f16 = @alignCast(std.mem.bytesAsSlice([4]f16, decoded.data));
    var best: f32 = -1;
    var best_index: usize = 0;
    for (texels, 0..) |texel, index| {
        const luminance = @as(f32, texel[0]) * 0.2126 + @as(f32, texel[1]) * 0.7152 + @as(f32, texel[2]) * 0.0722;
        if (luminance > best) {
            best = luminance;
            best_index = index;
        }
    }
    const u = (@as(f32, @floatFromInt(best_index % decoded.width)) + 0.5) / @as(f32, @floatFromInt(decoded.width));
    const v = (@as(f32, @floatFromInt(best_index / decoded.width)) + 0.5) / @as(f32, @floatFromInt(decoded.height));
    return .{
        .width = decoded.width,
        .height = decoded.height,
        .decoded = decoded,
        .brightest_direction = equirectDirection(u, v),
    };
}

/// Matches `equirectUv` in the environment shaders.
pub fn equirectDirection(u: f32, v: f32) [3]f32 {
    const phi = (u - 0.5) * 2.0 * std.math.pi;
    const theta = v * std.math.pi;
    return .{ @sin(theta) * @cos(phi), @cos(theta), @sin(theta) * @sin(phi) };
}

fn textureRef(data: *gltf.Data, model: *Model, view: gltf.TextureView, srgb: bool) ?TextureRef {
    const texture = view.texture orelse return null;
    const image = (if (texture.has_basisu != 0) texture.basisu_image else null) orelse texture.image orelse return null;
    const index = ddsImage(data, texture) orelse elementIndex(gltf.Image, data.images, image);
    if (srgb) model.images[index].srgb = true;
    model.images[index].uses += 1;
    var sampler: SamplerData = .{};
    if (texture.sampler) |source| {
        sampler.linear = source.mag_filter != .nearest;
        sampler.repeat_u = addressMode(source.wrap_s);
        sampler.repeat_v = addressMode(source.wrap_t);
    }
    var transform: UvTransform = .{};
    var uv_set: u8 = if (view.texcoord == 1) 1 else 0;
    if (view.has_transform != 0) {
        transform = .{ .scale = view.transform.scale, .rotation = view.transform.rotation, .offset = view.transform.offset };
        if (view.transform.has_texcoord != 0) uv_set = if (view.transform.texcoord == 1) 1 else 0;
    }
    return .{ .image = index, .sampler = sampler, .uv_set = uv_set, .transform = transform };
}

/// The image `MSFT_texture_dds` names for a texture.
fn ddsImage(data: *gltf.Data, texture: *const gltf.Texture) ?u32 {
    const extensions = texture.extensions orelse return null;
    for (extensions[0..texture.extensions_count]) |extension| {
        if (!std.mem.eql(u8, std.mem.span(extension.name orelse continue), "MSFT_texture_dds")) continue;
        const json = std.mem.span(extension.data orelse continue);
        const key = std.mem.indexOf(u8, json, "\"source\"") orelse continue;
        const digits = std.mem.trimStart(u8, json[key + 8 ..], ": \t\r\n");
        var end: usize = 0;
        while (end < digits.len and std.ascii.isDigit(digits[end])) end += 1;
        const index = std.fmt.parseInt(u32, digits[0..end], 10) catch continue;
        if (index < data.images_count) return index;
    }
    return null;
}

fn addressMode(mode: gltf.WrapMode) SamplerData.AddressMode {
    return switch (mode) {
        .mirrored_repeat => .mirrored_repeat,
        .clamp_to_edge => .clamp_to_edge,
        else => .repeat,
    };
}

fn loadMaterials(arena: std.mem.Allocator, data: *gltf.Data, model: *Model) !void {
    model.materials = try arena.alloc(Material, data.materials_count + 1);
    for (model.materials) |*material| material.* = .{};
    if (data.materials_count == 0) return;
    for (data.materials.?[0..data.materials_count], 0..) |source, index| {
        var material: Material = .{};
        if (source.has_pbr_metallic_roughness != 0) {
            const pbr = source.pbr_metallic_roughness;
            material.base_color = pbr.base_color_factor;
            material.metallic = pbr.metallic_factor;
            material.roughness = pbr.roughness_factor;
            material.base_color_texture = textureRef(data, model, pbr.base_color_texture, true);
            material.metallic_roughness_texture = textureRef(data, model, pbr.metallic_roughness_texture, false);
        }
        if (source.has_pbr_specular_glossiness != 0) {
            const pbr = source.pbr_specular_glossiness;
            material.specular_glossiness = true;
            material.base_color = pbr.diffuse_factor;
            material.specular = pbr.specular_factor;
            material.roughness = pbr.glossiness_factor;
            material.base_color_texture = textureRef(data, model, pbr.diffuse_texture, true);
            material.metallic_roughness_texture = textureRef(data, model, pbr.specular_glossiness_texture, true);
        }
        material.normal_texture = textureRef(data, model, source.normal_texture, false);
        if (material.normal_texture) |ref| model.images[ref.image].normal_map = true;
        material.occlusion_texture = textureRef(data, model, source.occlusion_texture, false);
        if (material.occlusion_texture) |ref| model.images[ref.image].occlusion_uses += 1;
        material.emissive_texture = textureRef(data, model, source.emissive_texture, true);
        material.emissive = source.emissive_factor;
        if (source.has_emissive_strength != 0) {
            for (&material.emissive) |*value| value.* *= source.emissive_strength.emissive_strength;
        }
        if (source.has_transmission != 0) material.transmission = source.transmission.transmission_factor;
        if (source.has_ior != 0) material.ior = source.ior.ior;
        if (source.has_volume != 0 and source.volume.thickness_factor > 0) material.thickness = source.volume.thickness_factor;
        if (source.has_anisotropy != 0) {
            material.anisotropy = source.anisotropy.anisotropy_strength;
            material.anisotropy_rotation = source.anisotropy.anisotropy_rotation;
        }
        if (source.has_sheen != 0) {
            material.sheen_color = source.sheen.sheen_color_factor;
            material.sheen_roughness = source.sheen.sheen_roughness_factor;
            material.sheen_color_texture = textureRef(data, model, source.sheen.sheen_color_texture, true);
            material.sheen_roughness_texture = textureRef(data, model, source.sheen.sheen_roughness_texture, false);
        }
        if (source.has_clearcoat != 0) {
            material.clearcoat = source.clearcoat.clearcoat_factor;
            material.clearcoat_roughness = source.clearcoat.clearcoat_roughness_factor;
            material.clearcoat_texture = textureRef(data, model, source.clearcoat.clearcoat_texture, false);
            material.clearcoat_roughness_texture = textureRef(data, model, source.clearcoat.clearcoat_roughness_texture, false);
            material.clearcoat_normal_texture = textureRef(data, model, source.clearcoat.clearcoat_normal_texture, false);
            if (material.clearcoat_normal_texture) |ref| {
                model.images[ref.image].normal_map = true;
                material.clearcoat_normal_scale = source.clearcoat.clearcoat_normal_texture.scale;
            }
        }
        if (source.has_pbr_metallic_roughness != 0 and source.pbr_metallic_roughness.base_color_texture.has_transform != 0) {
            const transform = source.pbr_metallic_roughness.base_color_texture.transform;
            material.uv_scale = transform.scale;
            material.uv_rotation = transform.rotation;
            material.uv_offset = transform.offset;
        }
        if (material.normal_texture != null) material.normal_scale = source.normal_texture.scale;
        if (material.occlusion_texture != null) material.occlusion_strength = source.occlusion_texture.scale;
        material.alpha_mode = switch (source.alpha_mode) {
            .mask => .mask,
            .blend => .blend,
            else => .@"opaque",
        };
        material.alpha_cutoff = source.alpha_cutoff;
        material.double_sided = source.double_sided != 0;
        model.materials[index] = material;
    }
}

fn loadNodes(arena: std.mem.Allocator, data: *gltf.Data, model: *Model) !void {
    model.nodes = try arena.alloc(Node, data.nodes_count);
    if (data.nodes_count == 0) return;
    for (data.nodes.?[0..data.nodes_count], model.nodes) |source, *node| {
        node.* = .{
            .name = if (source.name) |name_pointer| try arena.dupe(u8, std.mem.span(name_pointer)) else "",
            .parent = if (source.parent) |parent| elementIndex(gltf.Node, data.nodes, parent) else null,
            .translation = source.translation,
            .rotation = source.rotation,
            .scale = source.scale,
            .matrix = if (source.has_matrix != 0) source.matrix else null,
        };
    }
}

const FatVertex = extern struct {
    vertex: FullVertex,
    skin: SkinVertex,
    /// Index of this vertex in the file, before reordering.
    source: u32 = 0,
};

const MeshoptBounds = extern struct {
    center: [3]f32,
    radius: f32,
    cone_apex: [3]f32,
    cone_axis: [3]f32,
    cone_cutoff: f32,
    cone_axis_s8: [3]i8,
    cone_cutoff_s8: i8,
};

extern fn rnd_meshopt_simplifyWithAttributes(
    destination: [*]u32,
    indices: [*]const u32,
    index_count: usize,
    vertex_positions: [*]const f32,
    vertex_count: usize,
    vertex_positions_stride: usize,
    vertex_attributes: [*]const f32,
    vertex_attributes_stride: usize,
    attribute_weights: [*]const f32,
    attribute_count: usize,
    vertex_lock: ?[*]const u8,
    target_index_count: usize,
    target_error: f32,
    options: u32,
    result_error: *f32,
) usize;
const simplify_lock_border = 1;
/// The indices are a small part of the mesh.
const simplify_sparse = 2;
/// Errors are in mesh units, not relative to mesh size.
const simplify_error_absolute = 4;
extern fn meshopt_simplifyScale(vertex_positions: [*]const f32, vertex_count: usize, vertex_positions_stride: usize) f32;

/// Fewest triangles for `LodOptions.clusters` to apply to a mesh.
const cluster_lod_min_triangles: usize = 8192;

pub const LodOptions = struct {
    /// Build a cluster hierarchy instead of a few levels of each whole mesh.
    clusters: bool = false,
    /// A fully reversed normal counts as a shape error of twice this fraction
    /// of
    /// the simplified extent. 0 considers shape only.
    normal_weight: f32 = default_lod_normal_weight,
    /// 1 counts a texture shifted by some distance as a shape error of that
    /// distance; 0 ignores it.
    uv_weight: f32 = default_lod_uv_weight,
};
pub const default_lod_normal_weight: f32 = 0.5;
pub const default_lod_uv_weight: f32 = 1;

/// Normal and first texture coordinates, as the simplifier reads them.
const SimplifyAttribute = [5]f32;
fn simplifyWeights(normal_weight: f32, uv_weight: f32) [5]f32 {
    return .{ normal_weight, normal_weight, normal_weight, uv_weight, uv_weight };
}

/// Most levels of detail per mesh, including the full one.
const max_lods = 6;

extern fn meshopt_computeMeshletBounds(
    meshlet_vertices: [*]const u32,
    meshlet_triangles: [*]const u8,
    triangle_count: usize,
    vertex_positions: [*]const f32,
    vertex_count: usize,
    vertex_positions_stride: usize,
) MeshoptBounds;

fn findAttribute(primitive: *const gltf.Primitive, kind: gltf.AttributeType) ?*gltf.Accessor {
    for (primitive.attributes[0..primitive.attributes_count]) |attribute| {
        if (attribute.type == kind and attribute.index == 0) return attribute.data;
    }
    return null;
}

/// RGB or RGBA floats to RGBA8 with red in the low byte.
fn packColor(values: []const f32) u32 {
    var result: u32 = 0xff000000;
    for (values, 0..) |value, channel| {
        const byte: u32 = @intFromFloat(std.math.clamp(value, 0, 1) * 255 + 0.5);
        result = (result & ~(@as(u32, 0xff) << @intCast(channel * 8))) | (byte << @intCast(channel * 8));
    }
    return result;
}

fn unpack(gpa: std.mem.Allocator, accessor: *gltf.Accessor, components: usize) ![]f32 {
    const values = try gpa.alloc(f32, accessor.count * components);
    errdefer gpa.free(values);
    if (accessor.unpackFloats(values).len != values.len) return error.InvalidAccessor;
    return values;
}

fn loadMeshes(gpa: std.mem.Allocator, arena: std.mem.Allocator, data: *gltf.Data, model: *Model, lods: LodOptions) !void {
    const first_mesh = try gpa.alloc(u32, data.meshes_count + 1);
    defer gpa.free(first_mesh);
    var mesh_count: u32 = 0;
    if (data.meshes_count != 0) for (data.meshes.?[0..data.meshes_count], 0..) |mesh, index| {
        first_mesh[index] = mesh_count;
        mesh_count += @intCast(mesh.primitives_count);
    };
    first_mesh[data.meshes_count] = mesh_count;

    const skinned = try gpa.alloc(bool, data.meshes_count);
    defer gpa.free(skinned);
    @memset(skinned, false);
    var instances: std.ArrayList(Instance) = .empty;
    var implicit: std.ArrayList(u32) = .empty;
    if (data.nodes_count != 0) for (data.nodes.?[0..data.nodes_count], 0..) |node, node_index| {
        const mesh = node.mesh orelse continue;
        const mesh_index = elementIndex(gltf.Mesh, data.meshes, mesh);
        var skin: ?u32 = if (node.skin) |pointer| elementIndex(gltf.Skin, data.skins, pointer) else null;
        if (skin == null) for (mesh.primitives[0..mesh.primitives_count]) |primitive| {
            if (primitive.targets_count == 0) continue;
            skin = @intCast(data.skins_count + implicit.items.len);
            try implicit.append(arena, @intCast(node_index));
            break;
        };
        if (skin != null) skinned[mesh_index] = true;
        for (first_mesh[mesh_index]..first_mesh[mesh_index + 1]) |primitive| {
            try instances.append(arena, .{ .mesh = @intCast(primitive), .node = @intCast(node_index), .skin = skin });
        }
    };

    var meshes: std.ArrayList(Mesh) = .empty;
    const remap = try gpa.alloc(?u32, mesh_count);
    defer gpa.free(remap);
    if (data.meshes_count != 0) for (data.meshes.?[0..data.meshes_count], 0..) |mesh, mesh_index| {
        for (mesh.primitives[0..mesh.primitives_count], 0..) |*primitive, primitive_index| {
            const slot = first_mesh[mesh_index] + primitive_index;
            remap[slot] = null;
            if (primitive.type != .triangles) continue;
            const material: u32 = if (primitive.material) |pointer|
                elementIndex(gltf.Material, data.materials, pointer)
            else
                @intCast(data.materials_count);
            const built = buildMesh(gpa, arena, primitive, skinned[mesh_index], material, lods) catch |err| switch (err) {
                error.EmptyMesh => continue,
                else => return err,
            };
            var with_weights = built;
            if (mesh.weights) |weights| {
                for (weights[0..@min(mesh.weights_count, max_morph_targets)], 0..) |weight, target| with_weights.morph_weights[target] = weight;
            }
            remap[slot] = @intCast(meshes.items.len);
            try meshes.append(arena, with_weights);
        }
    };
    model.implicit_skins = implicit.items;
    var write: usize = 0;
    for (instances.items) |instance| {
        const mapped = remap[instance.mesh] orelse continue;
        instances.items[write] = .{ .mesh = mapped, .node = instance.node, .skin = instance.skin };
        write += 1;
    }
    model.instances = instances.items[0..write];
    model.meshes = meshes.items;
    if (model.meshes.len == 0 or model.instances.len == 0) return error.EmptyModel;
}

fn buildMesh(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    primitive: *const gltf.Primitive,
    skinned: bool,
    material: u32,
    lods: LodOptions,
) !Mesh {
    const position_accessor = findAttribute(primitive, .position) orelse return error.EmptyMesh;
    const vertex_count = position_accessor.count;
    if (vertex_count == 0) return error.EmptyMesh;
    const positions = try unpack(gpa, position_accessor, 3);
    defer gpa.free(positions);
    const normals: ?[]f32 = if (findAttribute(primitive, .normal)) |accessor| try unpack(gpa, accessor, 3) else null;
    defer if (normals) |values| gpa.free(values);
    const uvs: ?[]f32 = if (findAttribute(primitive, .texcoord)) |accessor| try unpack(gpa, accessor, 2) else null;
    defer if (uvs) |values| gpa.free(values);
    var color_components: usize = 4;
    const colors: ?[]f32 = if (findAttribute(primitive, .color)) |accessor|
        (unpack(gpa, accessor, 4) catch blk: {
            color_components = 3;
            break :blk try unpack(gpa, accessor, 3);
        })
    else
        null;
    defer if (colors) |values| gpa.free(values);
    var uvs1: ?[]f32 = null;
    for (primitive.attributes[0..primitive.attributes_count]) |attribute| {
        if (attribute.type == .texcoord and attribute.index == 1) uvs1 = try unpack(gpa, attribute.data, 2);
    }
    defer if (uvs1) |values| gpa.free(values);
    const tangents: ?[]f32 = if (findAttribute(primitive, .tangent)) |accessor| try unpack(gpa, accessor, 4) else null;
    defer if (tangents) |values| gpa.free(values);
    const joints: ?[]f32 = if (skinned) (if (findAttribute(primitive, .joints)) |accessor| try unpack(gpa, accessor, 4) else null) else null;
    defer if (joints) |values| gpa.free(values);
    const weights: ?[]f32 = if (skinned) (if (findAttribute(primitive, .weights)) |accessor| try unpack(gpa, accessor, 4) else null) else null;
    defer if (weights) |values| gpa.free(values);

    const source = try gpa.alloc(FatVertex, vertex_count);
    defer gpa.free(source);
    for (source, 0..) |*fat, index| {
        fat.vertex = .{
            .position = positions[index * 3 ..][0..3].*,
            .normal = if (normals) |values| values[index * 3 ..][0..3].* else .{ 0, 0, 0 },
            .tangent = if (tangents) |values| values[index * 4 ..][0..4].* else .{ 0, 0, 0, 1 },
            .uv = if (uvs) |values| values[index * 2 ..][0..2].* else .{ 0, 0 },
            .color = if (colors) |values| packColor(values[index * color_components ..][0..color_components]) else 0xffffffff,
            .uv1 = if (uvs1) |values| values[index * 2 ..][0..2].* else .{ 0, 0 },
        };
        fat.skin = .{ .joints = .{ 0, 0, 0, 0 }, .weights = .{ 1, 0, 0, 0 } };
        fat.source = @intCast(index);
        if (joints != null and weights != null) {
            var total: f32 = 0;
            for (0..4) |k| {
                fat.skin.joints[k] = @intFromFloat(joints.?[index * 4 + k]);
                fat.skin.weights[k] = weights.?[index * 4 + k];
                total += fat.skin.weights[k];
            }
            if (total > 1e-6) {
                for (&fat.skin.weights) |*weight| weight.* /= total;
            } else fat.skin.weights = .{ 1, 0, 0, 0 };
        }
    }

    const index_count = if (primitive.indices) |accessor| accessor.count else vertex_count;
    if (index_count < 3) return error.EmptyMesh;
    const source_indices = try gpa.alloc(u32, index_count - index_count % 3);
    defer gpa.free(source_indices);
    if (primitive.indices) |accessor| {
        const all = try gpa.alloc(u32, accessor.count);
        defer gpa.free(all);
        if (accessor.unpackIndices(all).len != all.len) return error.InvalidAccessor;
        @memcpy(source_indices, all[0..source_indices.len]);
    } else {
        for (source_indices, 0..) |*value, index| value.* = @intCast(index);
    }
    for (source_indices) |value| if (value >= vertex_count) return error.InvalidAccessor;

    var reordered: []u32 = &.{};
    defer gpa.free(reordered);
    const target_count: usize = if (skinned) @min(primitive.targets_count, max_morph_targets) else 0;
    var mesh = try finishMesh(gpa, arena, source, source_indices, skinned, material, normals != null, tangents != null, if (target_count != 0) &reordered else null, lods);
    if (target_count == 0) try coarseFirst(gpa, &mesh);
    if (target_count != 0) {
        const deltas = try arena.alloc(MorphDelta, target_count * mesh.vertices.len);
        @memset(deltas, .{ .position = .{ 0, 0, 0 }, .normal = .{ 0, 0, 0 }, .tangent = .{ 0, 0, 0 } });
        for (primitive.targets.?[0..target_count], 0..) |target, target_index| {
            const run = deltas[target_index * mesh.vertices.len ..][0..mesh.vertices.len];
            for (target.attributes.?[0..target.attributes_count]) |attribute| {
                if (attribute.type != .position and attribute.type != .normal and attribute.type != .tangent) continue;
                if (attribute.data.count != vertex_count) continue;
                const values = try unpack(gpa, attribute.data, 3);
                defer gpa.free(values);
                for (run, reordered) |*delta, original| {
                    const value = values[original * 3 ..][0..3].*;
                    switch (attribute.type) {
                        .position => delta.position = value,
                        .normal => delta.normal = value,
                        else => delta.tangent = value,
                    }
                }
            }
        }
        mesh.morph_targets = @intCast(target_count);
        mesh.morph_deltas = deltas;
    }
    return mesh;
}

/// A cluster of the level-of-detail hierarchy while it is being built.
const BuildCluster = struct {
    /// Triangle list indexing the mesh's vertices.
    indices: []u32,
    center: [3]f32,
    radius: f32,
    cone_axis: [3]f32,
    cone_cutoff: f32,
    self_error: f32 = 0,
    self_sphere: [4]f32 = .{ 0, 0, 0, 0 },
    parent_error: f32 = std.math.floatMax(f32),
    parent_sphere: [4]f32 = .{ 0, 0, 0, 0 },
};

/// Splits triangles into meshlets and appends them as clusters.
fn appendClusters(
    gpa: std.mem.Allocator,
    scratch: std.mem.Allocator,
    clusters: *std.ArrayList(BuildCluster),
    triangles: []const u32,
    fat: []const FatVertex,
    self_error: f32,
    self_sphere: [4]f32,
) !usize {
    const bound = zmesh.opt.buildMeshletsBound(triangles.len, max_meshlet_vertices, max_meshlet_triangles);
    const native = try gpa.alloc(zmesh.opt.Meshlet, bound);
    defer gpa.free(native);
    const meshlet_vertices = try gpa.alloc(u32, bound * max_meshlet_vertices);
    defer gpa.free(meshlet_vertices);
    const meshlet_triangles = try gpa.alloc(u8, bound * max_meshlet_triangles * 3);
    defer gpa.free(meshlet_triangles);
    const count = zmesh.opt.buildMeshlets(native, meshlet_vertices, meshlet_triangles, triangles, FatVertex, fat, max_meshlet_vertices, max_meshlet_triangles, 0.25);
    for (native[0..count]) |source_meshlet| {
        const local_vertices = meshlet_vertices[source_meshlet.vertex_offset..];
        const local_triangles = meshlet_triangles[source_meshlet.triangle_offset..];
        const bounds = meshopt_computeMeshletBounds(local_vertices.ptr, local_triangles.ptr, source_meshlet.triangle_count, @ptrCast(fat.ptr), fat.len, @sizeOf(FatVertex));
        const indices = try scratch.alloc(u32, source_meshlet.triangle_count * 3);
        for (indices, local_triangles[0..indices.len]) |*index, local| index.* = local_vertices[local];
        try clusters.append(scratch, .{
            .indices = indices,
            .center = bounds.center,
            .radius = bounds.radius,
            .cone_axis = bounds.cone_axis,
            .cone_cutoff = bounds.cone_cutoff,
            .self_error = self_error,
            .self_sphere = self_sphere,
        });
    }
    return count;
}

const KeyedCluster = struct { key: u32, cluster: u32 };

/// Sorts one round's clusters into groups of up to `size` that share as much
/// boundary as possible. Returns the clusters group after group and where
/// each group ends.
fn groupClusters(scratch: std.mem.Allocator, clusters: []const BuildCluster, round: []const KeyedCluster, size: usize) !struct { order: []KeyedCluster, ends: []u32 } {
    const none = std.math.maxInt(u32);
    const Edge = struct { key: u64, cluster: u32 };
    var edge_count: usize = 0;
    for (round) |item| edge_count += clusters[item.cluster].indices.len;
    const edges = try scratch.alloc(Edge, edge_count);
    var filled: usize = 0;
    for (round, 0..) |item, local| {
        const indices = clusters[item.cluster].indices;
        var corner: usize = 0;
        while (corner + 2 < indices.len) : (corner += 3) {
            inline for (0..3) |side| {
                const from = indices[corner + side];
                const to = indices[corner + (side + 1) % 3];
                edges[filled] = .{ .key = (@as(u64, @min(from, to)) << 32) | @max(from, to), .cluster = @intCast(local) };
                filled += 1;
            }
        }
    }
    std.mem.sort(Edge, edges[0..filled], {}, struct {
        fn before(_: void, a: Edge, b: Edge) bool {
            return a.key < b.key;
        }
    }.before);
    var pairs: std.ArrayList(u64) = .empty;
    var run: usize = 0;
    while (run < filled) {
        var end = run + 1;
        while (end < filled and edges[end].key == edges[run].key) end += 1;
        for (edges[run..end], run..) |first, index| for (edges[index + 1 .. end]) |second| {
            if (first.cluster == second.cluster) continue;
            try pairs.append(scratch, (@as(u64, first.cluster) << 32) | second.cluster);
            try pairs.append(scratch, (@as(u64, second.cluster) << 32) | first.cluster);
        };
        run = end;
    }
    std.mem.sort(u64, pairs.items, {}, std.sort.asc(u64));
    const Neighbour = struct { cluster: u32, shared: u32 };
    var neighbours: std.ArrayList(Neighbour) = .empty;
    const first_neighbour = try scratch.alloc(u32, round.len + 1);
    var pair: usize = 0;
    for (0..round.len) |local| {
        first_neighbour[local] = @intCast(neighbours.items.len);
        while (pair < pairs.items.len and pairs.items[pair] >> 32 == local) {
            var end = pair + 1;
            while (end < pairs.items.len and pairs.items[end] == pairs.items[pair]) end += 1;
            try neighbours.append(scratch, .{ .cluster = @truncate(pairs.items[pair]), .shared = @intCast(end - pair) });
            pair = end;
        }
    }
    first_neighbour[round.len] = @intCast(neighbours.items.len);

    const group_of = try scratch.alloc(u32, round.len);
    @memset(group_of, none);
    var sizes: std.ArrayList(u32) = .empty;
    const members = try scratch.alloc(u32, size);
    for (0..round.len) |seed| {
        if (group_of[seed] != none) continue;
        const group: u32 = @intCast(sizes.items.len);
        group_of[seed] = group;
        members[0] = @intCast(seed);
        var member_count: usize = 1;
        while (member_count < size) {
            var best: u32 = none;
            var best_shared: u32 = 0;
            for (members[0..member_count]) |member| for (neighbours.items[first_neighbour[member]..first_neighbour[member + 1]]) |candidate| {
                if (group_of[candidate.cluster] != none) continue;
                var shared: u32 = 0;
                for (neighbours.items[first_neighbour[candidate.cluster]..first_neighbour[candidate.cluster + 1]]) |back| {
                    if (group_of[back.cluster] == group) shared += back.shared;
                }
                if (shared > best_shared) {
                    best_shared = shared;
                    best = candidate.cluster;
                }
            };
            if (best == none) break;
            group_of[best] = group;
            members[member_count] = best;
            member_count += 1;
        }
        try sizes.append(scratch, @intCast(member_count));
    }
    for (0..round.len) |local| {
        if (sizes.items[group_of[local]] != 1) continue;
        var best: u32 = none;
        var best_shared: u32 = 0;
        for (neighbours.items[first_neighbour[local]..first_neighbour[local + 1]]) |candidate| {
            if (candidate.shared > best_shared) {
                best_shared = candidate.shared;
                best = candidate.cluster;
            }
        }
        if (best == none) continue;
        sizes.items[group_of[local]] = 0;
        group_of[local] = group_of[best];
        sizes.items[group_of[local]] += 1;
    }

    const ends = try scratch.alloc(u32, sizes.items.len);
    var total: u32 = 0;
    for (sizes.items, ends) |count, *end| {
        end.* = total;
        total += count;
    }
    const order = try scratch.alloc(KeyedCluster, round.len);
    for (round, group_of) |item, group| {
        order[ends[group]] = item;
        ends[group] += 1;
    }
    return .{ .order = order, .ends = ends };
}

/// Builds a cluster hierarchy for per-cluster level of detail (after Karis
/// et al., "Nanite"): meshlets are merged in groups, each group simplified
/// with its boundary locked and split into meshlets again, level upon level.
fn buildClusterHierarchy(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    fat: []const FatVertex,
    level0: []const u32,
    minimum: [3]f32,
    maximum: [3]f32,
    attributes: []const SimplifyAttribute,
    /// See `LodOptions.normal_weight`.
    normal_weight: f32,
    /// The shape error a texture coordinate change of one counts as.
    uv_length: f32,
) !struct { indices: []u32, meshlets: []Meshlet, lod0_index_count: u32, lod0_meshlet_count: u32 } {
    var scratch_arena = std.heap.ArenaAllocator.init(gpa);
    defer scratch_arena.deinit();
    const scratch = scratch_arena.allocator();
    var clusters: std.ArrayList(BuildCluster) = .empty;
    const lod0_meshlet_count = try appendClusters(gpa, scratch, &clusters, level0, fat, 0, .{ 0, 0, 0, 0 });
    if (lod0_meshlet_count == 0) return error.EmptyMesh;

    const positions: [*]const f32 = @ptrCast(fat.ptr);
    const scale = meshopt_simplifyScale(positions, fat.len, @sizeOf(FatVertex));
    const extent = math.sub(maximum, minimum);
    const Keyed = KeyedCluster;
    var current: std.ArrayList(Keyed) = .empty;
    for (0..lod0_meshlet_count) |index| try current.append(scratch, .{ .key = 0, .cluster = @intCast(index) });
    const group_size = 8;
    var merged: std.ArrayList(u32) = .empty;
    var level: u32 = 0;
    while (current.items.len > 1 and level < 24) : (level += 1) {
        for (current.items) |*item| {
            const center = clusters.items[item.cluster].center;
            var key: u32 = 0;
            inline for (0..3) |axis| {
                const normalized = if (extent[axis] > 0) (center[axis] - minimum[axis]) / extent[axis] else 0;
                var bits: u32 = @intFromFloat(std.math.clamp(normalized, 0, 1) * 1023);
                bits = (bits | (bits << 16)) & 0x030000ff;
                bits = (bits | (bits << 8)) & 0x0300f00f;
                bits = (bits | (bits << 4)) & 0x030c30c3;
                bits = (bits | (bits << 2)) & 0x09249249;
                key |= bits << axis;
            }
            item.key = key;
        }
        std.mem.sort(Keyed, current.items, {}, struct {
            fn before(_: void, a: Keyed, b: Keyed) bool {
                return a.key < b.key;
            }
        }.before);
        const grouped = try groupClusters(scratch, clusters.items, current.items, group_size);
        var next: std.ArrayList(Keyed) = .empty;
        var progressed = false;
        var start: usize = 0;
        for (grouped.ends) |end| {
            const group = grouped.order[start..end];
            start = end;
            merged.clearRetainingCapacity();
            var child_error: f32 = 0;
            for (group) |item| {
                try merged.appendSlice(scratch, clusters.items[item.cluster].indices);
                child_error = @max(child_error, clusters.items[item.cluster].self_error);
            }
            const target = merged.items.len / 6 * 3;
            const simplified = try scratch.alloc(u32, merged.items.len);
            var low: [3]f32 = @splat(std.math.inf(f32));
            var high: [3]f32 = @splat(-std.math.inf(f32));
            for (merged.items) |index| {
                const position = fat[index].vertex.position;
                inline for (0..3) |axis| {
                    low[axis] = @min(low[axis], position[axis]);
                    high[axis] = @max(high[axis], position[axis]);
                }
            }
            const group_extent = @max(high[0] - low[0], @max(high[1] - low[1], high[2] - low[2]));
            const weights = simplifyWeights(normal_weight, if (group_extent > 0) uv_length / group_extent else 0);
            const attribute_count: usize = if (normal_weight > 0 or uv_length > 0) weights.len else 0;
            var simplify_error: f32 = 0;
            const count = if (group.len >= 2 and target >= 3)
                rnd_meshopt_simplifyWithAttributes(simplified.ptr, merged.items.ptr, merged.items.len, positions, fat.len, @sizeOf(FatVertex), @ptrCast(attributes.ptr), @sizeOf(SimplifyAttribute), &weights, attribute_count, null, target, 0.1 * scale, simplify_lock_border | simplify_sparse | simplify_error_absolute, &simplify_error)
            else
                0;
            if (count == 0 or count * 4 > merged.items.len * 3) {
                try next.appendSlice(scratch, group);
                continue;
            }
            progressed = true;
            const center = math.scale(math.add(low, high), 0.5);
            var radius: f32 = 0;
            for (merged.items) |index| radius = @max(radius, math.length(math.sub(fat[index].vertex.position, center)));
            for (group) |item| {
                const child = clusters.items[item.cluster];
                if (child.self_error > 0) radius = @max(radius, math.length(math.sub(child.self_sphere[0..3].*, center)) + child.self_sphere[3]);
            }
            const sphere = [4]f32{ center[0], center[1], center[2], radius };
            const group_error = @max(child_error * 1.0001 + 1e-7, child_error + simplify_error);
            for (group) |item| {
                clusters.items[item.cluster].parent_error = group_error;
                clusters.items[item.cluster].parent_sphere = sphere;
            }
            const first: u32 = @intCast(clusters.items.len);
            const made = try appendClusters(gpa, scratch, &clusters, simplified[0..count], fat, group_error, sphere);
            for (0..made) |index| try next.append(scratch, .{ .key = 0, .cluster = first + @as(u32, @intCast(index)) });
        }
        if (!progressed) break;
        current = next;
    }

    var total_indices: usize = 0;
    for (clusters.items) |cluster| total_indices += cluster.indices.len;
    const indices = try arena.alloc(u32, total_indices);
    const meshlets = try arena.alloc(Meshlet, clusters.items.len);
    var cursor: u32 = 0;
    var lod0_index_count: u32 = 0;
    for (clusters.items, meshlets, 0..) |cluster, *meshlet, index| {
        @memcpy(indices[cursor..][0..cluster.indices.len], cluster.indices);
        meshlet.* = .{
            .center = cluster.center,
            .radius = cluster.radius,
            .cone_axis = cluster.cone_axis,
            .cone_cutoff = cluster.cone_cutoff,
            .index_offset = cursor,
            .index_count = @intCast(cluster.indices.len),
            .lod_error = cluster.self_error,
            .parent_error = cluster.parent_error,
            .self_sphere = cluster.self_sphere,
            .parent_sphere = cluster.parent_sphere,
        };
        cursor += @intCast(cluster.indices.len);
        if (index + 1 == lod0_meshlet_count) lod0_index_count = cursor;
    }
    return .{ .indices = indices, .meshlets = meshlets, .lod0_index_count = lod0_index_count, .lod0_meshlet_count = @intCast(lod0_meshlet_count) };
}

fn finishMesh(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    source: []FatVertex,
    source_indices: []const u32,
    skinned: bool,
    material: u32,
    has_normals: bool,
    has_tangents: bool,
    /// Receives, for every final vertex, its index in `source` (owned by
    /// `gpa`).
    reordered: ?*[]u32,
    /// No cluster hierarchy is built for skinned meshes.
    lods: LodOptions,
) !Mesh {
    const vertex_count = source.len;
    if (!has_normals) generateNormals(source, source_indices);
    if (!has_tangents) try generateTangents(gpa, source, source_indices);

    const cache_indices = try gpa.alloc(u32, source_indices.len);
    defer gpa.free(cache_indices);
    zmesh.opt.optimizeVertexCache(cache_indices, source_indices, vertex_count);
    const fetched = try gpa.alloc(FatVertex, vertex_count);
    defer gpa.free(fetched);
    const final_vertex_count = zmesh.opt.optimizeVertexFetch(FatVertex, fetched, cache_indices, source);
    const fat = fetched[0..final_vertex_count];

    if (reordered) |out| {
        out.* = try gpa.alloc(u32, fat.len);
        for (out.*, fat) |*original, value| original.* = value.source;
    }
    const vertices = try arena.alloc(Vertex, fat.len);
    const skin: ?[]SkinVertex = if (skinned) try arena.alloc(SkinVertex, fat.len) else null;
    var minimum: [3]f32 = @splat(std.math.inf(f32));
    var maximum: [3]f32 = @splat(-std.math.inf(f32));
    for (fat, 0..) |value, index| {
        vertices[index] = .pack(value.vertex);
        if (skin) |influences| influences[index] = value.skin;
        inline for (0..3) |axis| {
            minimum[axis] = @min(minimum[axis], value.vertex.position[axis]);
            maximum[axis] = @max(maximum[axis], value.vertex.position[axis]);
        }
    }
    const center = math.scale(math.add(minimum, maximum), 0.5);
    var radius_squared: f32 = 0;
    for (vertices) |vertex| {
        const delta = math.sub(vertex.position, center);
        radius_squared = @max(radius_squared, math.dot(delta, delta));
    }

    var uv_area: f64 = 0;
    var surface_area: f64 = 0;
    var corner: usize = 0;
    while (corner + 2 < cache_indices.len) : (corner += 3) {
        const a = vertices[cache_indices[corner]];
        const b = vertices[cache_indices[corner + 1]];
        const c = vertices[cache_indices[corner + 2]];
        surface_area += math.length(math.cross(math.sub(b.position, a.position), math.sub(c.position, a.position)));
        uv_area += @abs((b.uv[0] - a.uv[0]) * (c.uv[1] - a.uv[1]) - (c.uv[0] - a.uv[0]) * (b.uv[1] - a.uv[1]));
    }
    const uv_density: f32 = if (surface_area > 0) @floatCast(@sqrt(uv_area / surface_area)) else 0;

    const attributes = try gpa.alloc(SimplifyAttribute, fat.len);
    defer gpa.free(attributes);
    for (attributes, fat) |*attribute, value| attribute.* = value.vertex.normal ++ value.vertex.uv;
    const uv_length: f32 = if (uv_density > 0) lods.uv_weight / uv_density else 0;

    if (lods.clusters and !skinned and cache_indices.len / 3 >= cluster_lod_min_triangles) {
        const built = try buildClusterHierarchy(gpa, arena, fat, cache_indices, minimum, maximum, attributes, lods.normal_weight, uv_length);
        return .{
            .vertices = vertices,
            .skin = skin,
            .indices = built.indices,
            .meshlets = built.meshlets,
            .lod0_index_count = built.lod0_index_count,
            .lod0_meshlet_count = built.lod0_meshlet_count,
            .bounds_center = center,
            .bounds_radius = @sqrt(radius_squared),
            .material = material,
            .uv_density = uv_density,
        };
    }

    var levels: [max_lods][]u32 = undefined;
    var errors: [max_lods]f32 = undefined;
    levels[0] = cache_indices;
    errors[0] = 0;
    var level_count: usize = 1;
    defer for (levels[1..level_count]) |level| gpa.free(level);
    const positions: [*]const f32 = @ptrCast(fat.ptr);
    const scale = meshopt_simplifyScale(positions, fat.len, @sizeOf(FatVertex));
    const weights = simplifyWeights(lods.normal_weight, if (scale > 0) uv_length / scale else 0);
    const attribute_count: usize = if (lods.normal_weight > 0 or uv_length > 0) weights.len else 0;
    while (level_count < max_lods) {
        const previous = levels[level_count - 1];
        if (previous.len / 3 < 192) break;
        const target = previous.len / 6 * 3;
        const simplified = try gpa.alloc(u32, previous.len);
        var relative_error: f32 = 0;
        const count = rnd_meshopt_simplifyWithAttributes(simplified.ptr, previous.ptr, previous.len, positions, fat.len, @sizeOf(FatVertex), @ptrCast(attributes.ptr), @sizeOf(SimplifyAttribute), &weights, attribute_count, null, target, 0.05, simplify_lock_border, &relative_error);
        if (count == 0 or count * 4 > previous.len * 3) {
            gpa.free(simplified);
            break;
        }
        levels[level_count] = try gpa.realloc(simplified, count);
        errors[level_count] = @max(relative_error * scale, errors[level_count - 1] * 1.5 + 1e-6);
        level_count += 1;
    }

    var total_indices: usize = 0;
    var total_bound: usize = 0;
    for (levels[0..level_count]) |level| {
        total_indices += level.len;
        total_bound += zmesh.opt.buildMeshletsBound(level.len, max_meshlet_vertices, max_meshlet_triangles);
    }
    const indices = try arena.alloc(u32, total_indices);
    var meshlets: std.ArrayList(Meshlet) = .empty;
    try meshlets.ensureTotalCapacity(arena, total_bound);
    var cursor: u32 = 0;
    var lod0_index_count: u32 = 0;
    var lod0_meshlet_count: u32 = 0;
    for (levels[0..level_count], 0..) |level, lod| {
        const bound = zmesh.opt.buildMeshletsBound(level.len, max_meshlet_vertices, max_meshlet_triangles);
        const native = try gpa.alloc(zmesh.opt.Meshlet, bound);
        defer gpa.free(native);
        const meshlet_vertices = try gpa.alloc(u32, bound * max_meshlet_vertices);
        defer gpa.free(meshlet_vertices);
        const meshlet_triangles = try gpa.alloc(u8, bound * max_meshlet_triangles * 3);
        defer gpa.free(meshlet_triangles);
        const meshlet_count = zmesh.opt.buildMeshlets(
            native,
            meshlet_vertices,
            meshlet_triangles,
            level,
            FatVertex,
            fat,
            max_meshlet_vertices,
            max_meshlet_triangles,
            0.25,
        );
        if (meshlet_count == 0) {
            if (lod == 0) return error.EmptyMesh;
            continue;
        }
        for (native[0..meshlet_count]) |source_meshlet| {
            const local_vertices = meshlet_vertices[source_meshlet.vertex_offset..];
            const local_triangles = meshlet_triangles[source_meshlet.triangle_offset..];
            const bounds = meshopt_computeMeshletBounds(
                local_vertices.ptr,
                local_triangles.ptr,
                source_meshlet.triangle_count,
                @ptrCast(fat.ptr),
                fat.len,
                @sizeOf(FatVertex),
            );
            meshlets.appendAssumeCapacity(.{
                .center = bounds.center,
                .radius = bounds.radius,
                .cone_axis = bounds.cone_axis,
                .cone_cutoff = bounds.cone_cutoff,
                .index_offset = cursor,
                .index_count = source_meshlet.triangle_count * 3,
                .lod_error = errors[lod],
                .parent_error = if (lod + 1 < level_count) errors[lod + 1] else std.math.floatMax(f32),
            });
            for (local_triangles[0 .. source_meshlet.triangle_count * 3]) |local| {
                indices[cursor] = local_vertices[local];
                cursor += 1;
            }
        }
        if (lod == 0) {
            lod0_index_count = cursor;
            lod0_meshlet_count = @intCast(meshlets.items.len);
        }
    }

    return .{
        .vertices = vertices,
        .skin = skin,
        .indices = indices[0..cursor],
        .meshlets = meshlets.items,
        .lod0_index_count = lod0_index_count,
        .lod0_meshlet_count = lod0_meshlet_count,
        .bounds_center = center,
        .bounds_radius = @sqrt(radius_squared),
        .material = material,
        .uv_density = uv_density,
    };
}

/// Reorders vertices so those the coarser levels use come first; see
/// `Mesh.coarse_vertex_count`.
fn coarseFirst(gpa: std.mem.Allocator, mesh: *Mesh) !void {
    if (mesh.skin != null or mesh.morph_targets != 0) return;
    if (mesh.lod0_meshlet_count == 0 or mesh.lod0_meshlet_count >= mesh.meshlets.len) return;
    var floor: f32 = 0;
    for (mesh.meshlets[0..mesh.lod0_meshlet_count]) |meshlet| floor = @max(floor, meshlet.parent_error);
    if (!(floor > 0) or floor >= std.math.floatMax(f32) * 0.5) return;
    const used = try gpa.alloc(bool, mesh.vertices.len);
    defer gpa.free(used);
    @memset(used, false);
    for (mesh.meshlets[mesh.lod0_meshlet_count..]) |meshlet| {
        for (mesh.indices[meshlet.index_offset..][0..meshlet.index_count]) |index| used[index] = true;
    }
    const place = try gpa.alloc(u32, mesh.vertices.len);
    defer gpa.free(place);
    var next: u32 = 0;
    for (used, place) |is_used, *slot| if (is_used) {
        slot.* = next;
        next += 1;
    };
    const coarse = next;
    if (coarse == 0 or coarse == mesh.vertices.len) return;
    for (used, place) |is_used, *slot| if (!is_used) {
        slot.* = next;
        next += 1;
    };
    const moved = try gpa.dupe(Vertex, mesh.vertices);
    defer gpa.free(moved);
    for (moved, place) |vertex, slot| mesh.vertices[slot] = vertex;
    for (mesh.indices) |*index| index.* = place[index.*];
    mesh.coarse_vertex_count = coarse;
    mesh.coarse_error = floor;
}

fn generateNormals(vertices: []FatVertex, indices: []const u32) void {
    var triangle: usize = 0;
    while (triangle + 2 < indices.len) : (triangle += 3) {
        const a = &vertices[indices[triangle]].vertex;
        const b = &vertices[indices[triangle + 1]].vertex;
        const c = &vertices[indices[triangle + 2]].vertex;
        const face = math.cross(math.sub(b.position, a.position), math.sub(c.position, a.position));
        a.normal = math.add(a.normal, face);
        b.normal = math.add(b.normal, face);
        c.normal = math.add(c.normal, face);
    }
    for (vertices) |*fat| {
        const normal = math.normalize(fat.vertex.normal);
        fat.vertex.normal = if (math.dot(normal, normal) > 0.5) normal else .{ 0, 1, 0 };
    }
}

fn generateTangents(gpa: std.mem.Allocator, vertices: []FatVertex, indices: []const u32) !void {
    const bitangents = try gpa.alloc([3]f32, vertices.len);
    defer gpa.free(bitangents);
    @memset(bitangents, .{ 0, 0, 0 });
    for (vertices) |*fat| fat.vertex.tangent = .{ 0, 0, 0, 1 };
    var triangle: usize = 0;
    while (triangle + 2 < indices.len) : (triangle += 3) {
        const ia = indices[triangle];
        const ib = indices[triangle + 1];
        const ic = indices[triangle + 2];
        const a = vertices[ia].vertex;
        const b = vertices[ib].vertex;
        const c = vertices[ic].vertex;
        const e1 = math.sub(b.position, a.position);
        const e2 = math.sub(c.position, a.position);
        const du1 = b.uv[0] - a.uv[0];
        const dv1 = b.uv[1] - a.uv[1];
        const du2 = c.uv[0] - a.uv[0];
        const dv2 = c.uv[1] - a.uv[1];
        const determinant = du1 * dv2 - du2 * dv1;
        if (@abs(determinant) < 1e-12) continue;
        const r = 1.0 / determinant;
        const tangent = math.scale(math.sub(math.scale(e1, dv2), math.scale(e2, dv1)), r);
        const bitangent = math.scale(math.sub(math.scale(e2, du1), math.scale(e1, du2)), r);
        for ([_]u32{ ia, ib, ic }) |index| {
            const t = &vertices[index].vertex.tangent;
            t[0] += tangent[0];
            t[1] += tangent[1];
            t[2] += tangent[2];
            bitangents[index] = math.add(bitangents[index], bitangent);
        }
    }
    for (vertices, bitangents) |*fat, bitangent| {
        const n = fat.vertex.normal;
        var t: [3]f32 = fat.vertex.tangent[0..3].*;
        t = math.sub(t, math.scale(n, math.dot(n, t)));
        if (math.dot(t, t) < 1e-12) {
            const helper: [3]f32 = if (@abs(n[1]) < 0.99) .{ 0, 1, 0 } else .{ 1, 0, 0 };
            t = math.cross(helper, n);
        }
        t = math.normalize(t);
        const handedness: f32 = if (math.dot(math.cross(n, t), bitangent) < 0) -1 else 1;
        fat.vertex.tangent = .{ t[0], t[1], t[2], handedness };
    }
}

fn loadSkins(gpa: std.mem.Allocator, arena: std.mem.Allocator, data: *gltf.Data, model: *Model) !void {
    model.skins = try arena.alloc(Skin, data.skins_count + model.implicit_skins.len);
    for (model.skins[data.skins_count..], model.implicit_skins) |*skin, node| {
        skin.joints = try arena.dupe(u32, &.{node});
        skin.inverse_bind = try arena.dupe([16]f32, &.{math.identity});
    }
    model.implicit_skins = &.{};
    if (data.skins_count == 0) return;
    for (data.skins.?[0..data.skins_count], model.skins[0..data.skins_count]) |source, *skin| {
        skin.joints = try arena.alloc(u32, source.joints_count);
        skin.inverse_bind = try arena.alloc([16]f32, source.joints_count);
        for (source.joints[0..source.joints_count], skin.joints) |joint, *index|
            index.* = elementIndex(gltf.Node, data.nodes, joint);
        @memset(skin.inverse_bind, math.identity);
        if (source.inverse_bind_matrices) |accessor| {
            const values = try unpack(gpa, accessor, 16);
            defer gpa.free(values);
            for (skin.inverse_bind, 0..) |*matrix, index| {
                if (index < accessor.count) matrix.* = values[index * 16 ..][0..16].*;
            }
        }
    }
}

fn loadAnimations(gpa: std.mem.Allocator, arena: std.mem.Allocator, data: *gltf.Data, model: *Model) !void {
    model.animations = try arena.alloc(Animation, data.animations_count);
    if (data.animations_count == 0) return;
    for (data.animations.?[0..data.animations_count], model.animations) |source, *animation| {
        var channels: std.ArrayList(Channel) = .empty;
        var duration: f32 = 0;
        for (source.channels[0..source.channels_count]) |channel| {
            const target = channel.target_node orelse continue;
            const path: ChannelPath = switch (channel.target_path) {
                .translation => .translation,
                .rotation => .rotation,
                .scale => .scale,
                .weights => .weights,
                else => continue,
            };
            const sampler = channel.sampler;
            const components: usize = switch (path) {
                .rotation => 4,
                .weights => if (sampler.input.count == 0) 0 else sampler.output.count / sampler.input.count / @as(usize, if (sampler.interpolation == .cubic_spline) 3 else 1),
                else => 3,
            };
            if (components == 0) continue;
            const times = try arena.alloc(f32, sampler.input.count);
            if (sampler.input.unpackFloats(times).len != times.len) return error.InvalidAccessor;
            const raw = try unpack(gpa, sampler.output, if (path == .weights) 1 else components);
            defer gpa.free(raw);
            const cubic = sampler.interpolation == .cubic_spline;
            const per_key: usize = if (cubic) 3 else 1;
            if (times.len == 0) continue;
            if (path != .weights and sampler.output.count / per_key < times.len) continue;
            const values = try arena.alloc(f32, times.len * components * per_key);
            @memcpy(values, raw[0..values.len]);
            duration = @max(duration, times[times.len - 1]);
            try channels.append(arena, .{
                .node = elementIndex(gltf.Node, data.nodes, target),
                .path = path,
                .step = sampler.interpolation == .step,
                .cubic = cubic,
                .width = if (path == .weights) @intCast(components) else 0,
                .times = times,
                .values = values,
            });
        }
        animation.* = .{
            .name = if (source.name) |name_pointer| try arena.dupe(u8, std.mem.span(name_pointer)) else "",
            .duration = duration,
            .channels = channels.items,
        };
    }
}

test "skinned glTF keeps skins, clips and per-vertex influences" {
    acquireLibraries(std.testing.io);
    defer releaseLibraries(std.testing.io);
    var model = try load(std.testing.allocator, std.testing.io, "examples/assets/world/Fox.glb", .{});
    defer model.deinit();
    try std.testing.expect(model.skins.len != 0);
    try std.testing.expect(model.animations.len != 0);
    try std.testing.expect(model.animations[0].duration > 0);
    const mesh = model.meshes[model.instances[0].mesh];
    try std.testing.expect(mesh.skin != null);
    try std.testing.expectEqual(mesh.vertices.len, mesh.skin.?.len);
    for (mesh.meshlets) |meshlet| try std.testing.expect(meshlet.index_count <= max_meshlet_triangles * 3);
}

/// Decodes an image file (PNG, JPEG, ...) to RGBA8. Requires
/// `acquireLibraries`. Free the result with `deinit`.
pub fn loadImage(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !zstbi.Image {
    const bytes = try readFile(gpa, io, path);
    defer gpa.free(bytes);
    return zstbi.Image.loadFromMemory(bytes, 4);
}

/// Geometry supplied by the application instead of a file.
pub const MeshDesc = struct {
    positions: []const [3]f32,
    /// Generated from the triangles when null.
    normals: ?[]const [3]f32 = null,
    uvs: ?[]const [2]f32 = null,
    /// Multiplied with the material's base color.
    colors: ?[]const [4]f32 = null,
    uvs1: ?[]const [2]f32 = null,
    /// Triangle list, counter-clockwise front faces.
    indices: []const u32,
    material: Material = .{ .metallic = 0, .roughness = 0.6 },
};

/// Builds a model from in-memory meshes, one instance each at the model
/// origin. Texture references in the materials are ignored.
pub fn fromMeshes(gpa: std.mem.Allocator, descs: []const MeshDesc, lods: LodOptions) !Model {
    var model = Model{ .arena = .init(gpa) };
    errdefer model.deinit();
    const arena = model.arena.allocator();
    if (descs.len == 0) return error.EmptyModel;
    model.meshes = try arena.alloc(Mesh, descs.len);
    model.materials = try arena.alloc(Material, descs.len);
    model.instances = try arena.alloc(Instance, descs.len);
    model.nodes = try arena.alloc(Node, 1);
    model.nodes[0] = .{};
    for (descs, 0..) |desc, index| {
        if (desc.positions.len == 0 or desc.indices.len < 3) return error.EmptyMesh;
        if (desc.normals) |normals| if (normals.len != desc.positions.len) return error.InvalidMesh;
        if (desc.uvs) |uvs| if (uvs.len != desc.positions.len) return error.InvalidMesh;
        for (desc.indices) |value| if (value >= desc.positions.len) return error.InvalidMesh;
        const source = try gpa.alloc(FatVertex, desc.positions.len);
        defer gpa.free(source);
        for (source, 0..) |*fat, vertex| fat.* = .{
            .vertex = .{
                .position = desc.positions[vertex],
                .normal = if (desc.normals) |normals| normals[vertex] else .{ 0, 0, 0 },
                .tangent = .{ 0, 0, 0, 1 },
                .uv = if (desc.uvs) |uvs| uvs[vertex] else .{ 0, 0 },
                .color = if (desc.colors) |colors| packColor(&colors[vertex]) else 0xffffffff,
                .uv1 = if (desc.uvs1) |uvs1| uvs1[vertex] else .{ 0, 0 },
            },
            .skin = .{ .joints = .{ 0, 0, 0, 0 }, .weights = .{ 1, 0, 0, 0 } },
        };
        var material = desc.material;
        material.base_color_texture = null;
        material.normal_texture = null;
        material.metallic_roughness_texture = null;
        material.occlusion_texture = null;
        material.emissive_texture = null;
        model.materials[index] = material;
        const usable = desc.indices.len - desc.indices.len % 3;
        model.meshes[index] = try finishMesh(gpa, arena, source, desc.indices[0..usable], false, @intCast(index), desc.normals != null, false, null, lods);
        try coarseFirst(gpa, &model.meshes[index]);
        model.instances[index] = .{ .mesh = @intCast(index), .node = 0, .skin = null };
    }
    return model;
}

test "procedural meshes become meshlets with generated normals" {
    acquireLibraries(std.testing.io);
    defer releaseLibraries(std.testing.io);
    var model = try fromMeshes(std.testing.allocator, &.{.{
        .positions = &.{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 1, 0, -1 }, .{ 0, 0, -1 } },
        .indices = &.{ 0, 1, 2, 0, 2, 3 },
    }}, .{});
    defer model.deinit();
    try std.testing.expectEqual(@as(usize, 1), model.meshes.len);
    try std.testing.expectEqual(@as(usize, 6), model.meshes[0].indices.len);
    try std.testing.expectApproxEqAbs(@as(f32, 1), model.meshes[0].vertices[0].unpackNormal()[1], 1e-4);
}

test "a cluster hierarchy stays watertight at every cut" {
    acquireLibraries(std.testing.io);
    defer releaseLibraries(std.testing.io);
    const gpa = std.testing.allocator;
    const cells = 96;
    const positions = try gpa.alloc([3]f32, (cells + 1) * (cells + 1));
    defer gpa.free(positions);
    const grid_indices = try gpa.alloc(u32, cells * cells * 6);
    defer gpa.free(grid_indices);
    for (0..cells + 1) |row| for (0..cells + 1) |column| {
        const x: f32 = @floatFromInt(column);
        const z: f32 = @floatFromInt(row);
        positions[row * (cells + 1) + column] = .{ x, 2.0 * @sin(x * 0.2) * @cos(z * 0.17) + 0.1 * @sin(x * 1.3 + z), z };
    };
    for (0..cells) |row| for (0..cells) |column| {
        const corner: u32 = @intCast(row * (cells + 1) + column);
        grid_indices[(row * cells + column) * 6 ..][0..6].* = .{ corner, corner + cells + 1, corner + 1, corner + 1, corner + cells + 1, corner + cells + 2 };
    };
    var model = try fromMeshes(gpa, &.{.{ .positions = positions, .indices = grid_indices }}, .{ .clusters = true });
    defer model.deinit();
    const mesh = model.meshes[0];

    var thresholds: std.ArrayList(f32) = .empty;
    defer thresholds.deinit(gpa);
    try thresholds.append(gpa, 0);
    for (mesh.meshlets) |meshlet| {
        try std.testing.expect(meshlet.self_sphere[3] >= 0);
        try std.testing.expect(meshlet.parent_error > meshlet.lod_error);
        if (meshlet.lod_error > 0) try thresholds.append(gpa, meshlet.lod_error);
        if (meshlet.lod_error > 0 and meshlet.parent_error < std.math.floatMax(f32)) {
            const apart = math.length(math.sub(meshlet.self_sphere[0..3].*, meshlet.parent_sphere[0..3].*));
            try std.testing.expect(apart + meshlet.self_sphere[3] <= meshlet.parent_sphere[3] * 1.0001 + 1e-4);
        }
    }
    std.mem.sort(f32, thresholds.items, {}, std.sort.asc(f32));

    const Shared = struct { count: u32 = 0 };
    var edges: std.AutoHashMap(u64, Shared) = .init(gpa);
    defer edges.deinit();
    var previous_triangles: usize = std.math.maxInt(usize);
    var fewest: usize = std.math.maxInt(usize);
    for (thresholds.items) |threshold| {
        edges.clearRetainingCapacity();
        var triangles: usize = 0;
        var area: f64 = 0;
        for (mesh.meshlets) |meshlet| {
            if (meshlet.lod_error > threshold or meshlet.parent_error <= threshold) continue;
            const indices = mesh.indices[meshlet.index_offset..][0..meshlet.index_count];
            triangles += indices.len / 3;
            var triangle: usize = 0;
            while (triangle + 2 < indices.len) : (triangle += 3) {
                const a = mesh.vertices[indices[triangle]].position;
                const b = mesh.vertices[indices[triangle + 1]].position;
                const c = mesh.vertices[indices[triangle + 2]].position;
                area += 0.5 * @as(f64, (b[2] - a[2]) * (c[0] - a[0]) - (b[0] - a[0]) * (c[2] - a[2]));
            }
            var corner: usize = 0;
            while (corner + 2 < indices.len) : (corner += 3) {
                inline for (0..3) |side| {
                    const from = indices[corner + side];
                    const to = indices[corner + (side + 1) % 3];
                    const entry = try edges.getOrPutValue((@as(u64, @min(from, to)) << 32) | @max(from, to), .{});
                    entry.value_ptr.count += 1;
                }
            }
        }
        var rim: usize = 0;
        var folded: usize = 0;
        var counts = edges.valueIterator();
        while (counts.next()) |shared| {
            if (shared.count > 2) {
                folded += 1;
            }
            if (shared.count == 1) rim += 1;
        }
        try std.testing.expectEqual(@as(usize, cells * 4), rim);
        try std.testing.expect(folded <= 2);
        try std.testing.expectApproxEqRel(@as(f64, cells * cells), area, 1e-4);
        try std.testing.expect(triangles <= previous_triangles);
        previous_triangles = triangles;
        fewest = @min(fewest, triangles);
    }
    try std.testing.expectEqual(@as(usize, cells * cells * 2), mesh.lod0_index_count / 3);
    try std.testing.expect(fewest * 8 < cells * cells * 2);
}

test "Basis Universal textures are transcoded to BC7" {
    const gpa = std.testing.allocator;
    for ([_][]const u8{ "examples/assets/panel/panel_etc1s.ktx2", "examples/assets/panel/panel_uastc.ktx2" }) |path| {
        const bytes = try readFile(gpa, std.testing.io, path);
        defer gpa.free(bytes);
        const texture = try ktx2.read(gpa, bytes);
        defer gpa.free(texture.data);
        try std.testing.expectEqual(ktx2.Format.bc7, texture.format);
        try std.testing.expect(texture.srgb);
        try std.testing.expectEqual(@as(u32, 480), texture.width);
        try std.testing.expectEqual(@as(u32, 270), texture.height);
        try std.testing.expectEqual(@as(u32, 9), texture.levels);
        var expected: usize = 0;
        for (0..9) |level| expected += @as(usize, (@max(@as(u32, 480) >> @intCast(level), 1) + 3) / 4) * ((@max(@as(u32, 270) >> @intCast(level), 1) + 3) / 4) * 16;
        try std.testing.expectEqual(expected, texture.data.len);
        var differing: usize = 0;
        var block: usize = 16;
        while (block + 16 <= 120 * 68 * 16) : (block += 16) {
            if (!std.mem.eql(u8, texture.data[block..][0..16], texture.data[0..16])) differing += 1;
        }
        try std.testing.expect(differing > 120 * 68 / 2);
    }
    var broken: [96]u8 = @splat(0);
    @memcpy(broken[0..12], &[_]u8{ 0xab, 'K', 'T', 'X', ' ', '2', '0', 0xbb, '\r', '\n', 0x1a, '\n' });
    std.mem.writeInt(u32, broken[20..24], 16, .little);
    std.mem.writeInt(u32, broken[24..28], 16, .little);
    std.mem.writeInt(u32, broken[36..40], 1, .little);
    try std.testing.expectError(error.UnsupportedKtx2, ktx2.read(gpa, &broken));
}

/// Deletes the oldest files (by write time) of an asset cache directory
/// until at most `max_bytes` remain. Returns the bytes freed.
pub fn trimCache(gpa: std.mem.Allocator, io: std.Io, directory: []const u8, max_bytes: u64) !u64 {
    var dir = std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer dir.close(io);
    const Cached = struct { name: []u8, size: u64, written: i96 };
    var files: std.ArrayList(Cached) = .empty;
    defer {
        for (files.items) |file| gpa.free(file.name);
        files.deinit(gpa);
    }
    var total: u64 = 0;
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".bc7") and !std.mem.endsWith(u8, entry.name, ".bc5") and !std.mem.endsWith(u8, entry.name, ".bc4") and !std.mem.endsWith(u8, entry.name, ".model") and !std.mem.endsWith(u8, entry.name, ".geometry")) continue;
        const stat = dir.statFile(io, entry.name, .{}) catch continue;
        const name = try gpa.dupe(u8, entry.name);
        errdefer gpa.free(name);
        try files.append(gpa, .{ .name = name, .size = stat.size, .written = stat.mtime.nanoseconds });
        total += stat.size;
    }
    if (total <= max_bytes) return 0;
    std.mem.sort(Cached, files.items, {}, struct {
        fn older(_: void, a: Cached, b: Cached) bool {
            return a.written < b.written;
        }
    }.older);
    var freed: u64 = 0;
    for (files.items) |file| {
        if (total - freed <= max_bytes) break;
        dir.deleteFile(io, file.name) catch continue;
        freed += file.size;
    }
    return freed;
}

test "a node that is its own child is refused" {
    if (!build_features.validate_input) return error.SkipZigTest;
    const io = std.testing.io;
    acquireLibraries(io);
    defer releaseLibraries(io);
    const path = ".zig-cache/limn-test-cycle.gltf";
    {
        const file = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        var buffer: [256]u8 = undefined;
        var writer = file.writerStreaming(io, &buffer);
        try writer.interface.writeAll(
            \\{"asset":{"version":"2.0"},"nodes":[{"children":[0]}]}
        );
        try writer.interface.flush();
    }
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    try std.testing.expectError(error.InvalidGltf, loadLights(std.testing.allocator, io, path));
}
