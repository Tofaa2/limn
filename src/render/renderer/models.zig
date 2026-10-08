//! Models: loading, building their GPU records and freeing them. Internal to the renderer.
const std = @import("std");
const rhi = @import("../../rhi/rhi.zig");
const math = @import("../../math.zig");
const gltf = @import("../../asset/gltf.zig");
const gpu = @import("../gpu.zig");
const animation = @import("../animation.zig");
const bvh = @import("../bvh.zig");
const api = @import("../api.zig");
const renderer_state = @import("../state.zig");
const geometry_passes = @import("../passes/geometry.zig");
const render = @import("../renderer.zig");

const Renderer = render.Renderer;
const Mat4 = math.Mat4;
const Vec3 = math.Vec3;
const Model = api.Model;
const MeshDesc = api.MeshDesc;
const blockFormat = renderer_state.blockFormat;
const TextureStream = renderer_state.TextureStream;
const AssetState = api.AssetState;
const AnimationInfo = api.AnimationInfo;
const ModelInfo = api.ModelInfo;
const ModelJob = renderer_state.ModelJob;
const runModelJob = renderer_state.runModelJob;
const ModelMesh = renderer_state.ModelMesh;
const ModelEntry = renderer_state.ModelEntry;
const SceneData = renderer_state.SceneData;
const uvMatrix = renderer_state.uvMatrix;
const createStreamTexture = @import("streaming.zig").createStreamTexture;
const encodeMaterial = @import("materials.zig").encodeMaterial;
const freeMeshGeometry = @import("streaming.zig").freeMeshGeometry;

fn lodOptions(self: *const Renderer) gltf.LodOptions {
    return .{ .clusters = self.options.cluster_lods, .normal_weight = self.options.lod_normal_weight, .uv_weight = self.options.lod_uv_weight };
}

/// Starts loading a glTF model in the background. Entities may reference
/// it at once; they appear when it is ready.
pub fn loadModel(self: *Renderer, path: []const u8) !Model {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const job = try self.gpa.create(ModelJob);
    errdefer self.gpa.destroy(job);
    job.* = .{
        .gpa = self.options.job_allocator orelse std.heap.smp_allocator,
        .io = self.io,
        .path = try self.gpa.dupe(u8, path),
        .options = .{
            .compress_textures = self.options.texture_compression == .bc7 and self.device.bc_textures,
            .normal_maps_bc5 = self.options.normal_maps_bc5,
            .raw_mips = self.options.texture_streaming != null,
            .lods = lodOptions(self),
            .cache_dir = self.options.asset_cache_dir,
        },
    };
    errdefer self.gpa.free(job.path);
    const model = try self.models.insert(.{ .job = job });
    job.group.concurrent(self.io, runModelJob, .{job}) catch job.group.async(self.io, runModelJob, .{job});
    self.loading_count += 1;
    return model;
}

/// Creates a model from geometry in memory. Ready on the next frame or
/// `waitUntilLoaded`.
pub fn createModel(self: *Renderer, meshes: []const MeshDesc) !Model {
    var source = try gltf.fromMeshes(self.options.job_allocator orelse std.heap.smp_allocator, meshes, lodOptions(self));
    errdefer source.deinit();
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const model = try self.models.insert(.{ .source = source });
    self.loading_count += 1;
    return model;
}

/// A handle that names no model reports `.failed`. Safe from any thread.
pub fn modelState(self: *Renderer, model: Model) AssetState {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return (self.models.get(model) orelse return .failed).state;
}

/// The error a failed load ended with, if any.
pub fn modelError(self: *Renderer, model: Model) ?anyerror {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return (self.models.get(model) orelse return error.InvalidModel).failure;
}

/// Null until the model is ready.
pub fn modelInfo(self: *Renderer, model: Model) ?ModelInfo {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const entry = self.models.get(model) orelse return null;
    return if (entry.state == .ready) entry.info else null;
}

/// Number of animation clips; 0 until the model is ready.
pub fn animationCount(self: *Renderer, model: Model) u32 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const entry = self.models.get(model) orelse return 0;
    if (entry.state != .ready) return 0;
    return @intCast(entry.source.?.animations.len);
}

/// Null until the model is ready or when `index` is out of range. The
/// name is not copied: valid until the model is destroyed.
pub fn animationInfo(self: *Renderer, model: Model, index: u32) ?AnimationInfo {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const entry = self.models.get(model) orelse return null;
    if (entry.state != .ready or index >= entry.source.?.animations.len) return null;
    const clip = entry.source.?.animations[index];
    return .{ .name = clip.name, .duration = clip.duration };
}

/// Index of the named node, for `Pose.Blend.root`. Null until loaded or
/// if there is none.
pub fn findNode(self: *Renderer, model: Model, name: []const u8) ?u32 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const entry = self.models.get(model) orelse return null;
    if (entry.state != .ready) return null;
    for (entry.source.?.nodes, 0..) |node, index| {
        if (std.mem.eql(u8, node.name, name)) return @intCast(index);
    }
    return null;
}

/// How far an animation carries `node` between two times, in model
/// space. Times past the clip's length count whole loops.
pub fn rootMotion(self: *Renderer, model: Model, animation_index: u32, node: u32, from: f32, to: f32) !Vec3 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const entry = self.models.get(model) orelse return error.InvalidModel;
    if (entry.state != .ready) return error.ModelNotReady;
    const source = &entry.source.?;
    if (node >= source.nodes.len) return error.InvalidNode;
    try self.scratch_locals.resize(self.gpa, source.nodes.len * 3);
    const moved = animation.rootMotion(source, self.scratch_locals.items, animation_index, node, from, to, true);
    return if (source.nodes[node].parent) |parent| math.transformDirection(entry.node_world[parent], moved) else moved;
}

/// Index of the first clip with exactly this name, for `Pose.animation`.
/// Null until loaded or if there is none.
pub fn findAnimation(self: *Renderer, model: Model, name: []const u8) ?u32 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const entry = self.models.get(model) orelse return null;
    if (entry.state != .ready) return null;
    for (entry.source.?.animations, 0..) |clip, index| {
        if (std.mem.eql(u8, clip.name, name)) return @intCast(index);
    }
    return null;
}

/// Fails with `error.ModelInUse` while any entity still references it.
pub fn destroyModel(self: *Renderer, model: Model) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const entry = self.models.get(model) orelse return error.InvalidModel;
    if (entry.references != 0) return error.ModelInUse;
    var removed = self.models.remove(model).?;
    if (removed.state == .loading) self.loading_count -= 1;
    freeModel(self, &removed);
    self.asset_generation += 1;
}

pub fn finalizeModel(self: *Renderer, entry: *ModelEntry, budget: *u64) !bool {
    const device = self.device;
    const gpa = self.gpa;
    if (entry.job) |job| {
        job.group.await(job.io) catch {};
        const failure = job.failure;
        entry.source = job.model;
        gpa.free(job.path);
        gpa.destroy(job);
        entry.job = null;
        if (failure) |err| return err;
        entry.textures = try gpa.alloc(?rhi.Texture, entry.source.?.images.len);
        @memset(entry.textures, null);
        entry.streams = try gpa.alloc(TextureStream, entry.source.?.images.len);
        @memset(entry.streams, .{});
    }
    const source = &entry.source.?;

    while (entry.next_image < source.images.len) : (entry.next_image += 1) {
        if (budget.* == 0) return false;
        const image = source.images[entry.next_image];
        if (image.compressed) |data| {
            const mips = if (image.mip_levels != 0) image.mip_levels else rhi.TextureDesc.fullMipCount(image.width, image.height);
            const compressed_format = blockFormat(image.block, image.one_channel, image.two_channel, image.srgb);
            if (self.options.texture_streaming) |streaming| {
                var floor: u32 = 0;
                while (floor + 1 < mips and @max(image.width, image.height) >> @intCast(floor) > streaming.min_size) floor += 1;
                const stream = &entry.streams[entry.next_image];
                stream.* = .{ .data = source.takeCompressed(entry.next_image), .width = image.width, .height = image.height, .levels = mips, .srgb = image.srgb, .two_channel = image.two_channel, .one_channel = image.one_channel, .block = image.block, .floor = floor, .resident = floor, .wanted = floor };
                stream.total = stream.data.len;
                if (streaming.from_cache and floor > 0 and image.block == .bc7 and image.cache_key != 0) if (self.options.asset_cache_dir) |directory| {
                    const extension: []const u8 = if (image.two_channel) "bc5" else if (image.one_channel) "bc4" else "bc7";
                    const path = try std.fmt.allocPrint(self.gpa, "{s}/{x:0>16}.{s}", .{ directory, image.cache_key, extension });
                    const tail_offset = stream.levelOffset(floor);
                    const in_cache = blk: {
                        const file = std.Io.Dir.cwd().openFile(self.io, path, .{}) catch break :blk false;
                        defer file.close(self.io);
                        const stat = file.stat(self.io) catch break :blk false;
                        break :blk stat.size == 12 + stream.total;
                    };
                    if (in_cache) {
                        const tail = try source.arena.child_allocator.dupe(u8, stream.data[tail_offset..]);
                        source.freeCompressed(stream.data);
                        stream.data = tail;
                        stream.tail_offset = tail_offset;
                        stream.path = path;
                    } else self.gpa.free(path);
                };
                entry.streamed += 1;
                entry.textures[entry.next_image] = try createStreamTexture(self, stream, floor);
                budget.* -|= stream.bytesFrom(floor);
                continue;
            }
            const texture = try device.createTexture(.{
                .name = "material texture",
                .width = image.width,
                .height = image.height,
                .format = compressed_format,
                .usage = .{ .sampled = true, .copy_dst = true },
                .mip_levels = mips,
            });
            entry.textures[entry.next_image] = texture;
            const offset = data.len;
            try device.uploadTextureLevels(texture, 0, 0, data);
            source.releaseImage(entry.next_image);
            budget.* -|= offset;
            continue;
        }
        const pixels = image.pixels();
        if (pixels.len == 0) continue;
        const texture = try device.createTexture(.{
            .name = "material texture",
            .width = image.width,
            .height = image.height,
            .format = if (image.srgb) .rgba8_srgb else .rgba8_unorm,
            .usage = .{ .sampled = true, .copy_dst = true },
            .mip_levels = rhi.TextureDesc.fullMipCount(image.width, image.height),
        });
        entry.textures[entry.next_image] = texture;
        try device.uploadTexture(texture, 0, 0, pixels);
        try device.generateMips(texture);
        source.releaseImage(entry.next_image);
        budget.* -|= pixels.len;
    }

    entry.material_base = try self.materials.alloc(self, @intCast(source.materials.len));
    var transform_count: u32 = 0;
    for (source.materials) |material| {
        if (material.hasOwnTransforms()) transform_count += 1;
    }
    if (transform_count != 0) {
        entry.transform_base = try self.materials.alloc(self, transform_count * gpu.texture_transform_slots);
        entry.transform_count = transform_count;
        self.texture_transform_users += 1;
        var slot = entry.transform_base;
        for (source.materials) |material| {
            if (!material.hasOwnTransforms()) continue;
            var block: [gpu.material_texture_count]gpu.TextureTransform = undefined;
            for (material.textureRefs(), &block) |maybe, *out| {
                const transform = if (maybe) |ref| ref.transform else material.sharedTransform();
                out.* = .{ .matrix = uvMatrix(transform.scale, transform.rotation), .offset = transform.offset };
            }
            try self.materials.write(device, slot, std.mem.sliceAsBytes(&block));
            slot += gpu.texture_transform_slots;
        }
    }
    const materials = try gpa.alloc(gpu.Material, source.materials.len);
    defer gpa.free(materials);
    for (source.materials, materials, 0..) |material, *out, index| {
        out.* = try encodeMaterial(self, entry, material, index);
        self.material_shader_users[out.shader] += 1;
    }
    try self.materials.write(device, entry.material_base, std.mem.sliceAsBytes(materials));

    entry.mesh_base = try self.meshes.alloc(self, @intCast(source.meshes.len));
    entry.meshes = try gpa.alloc(ModelMesh, source.meshes.len);
    @memset(entry.meshes, std.mem.zeroes(ModelMesh));
    const mesh_records = try gpa.alloc(gpu.Mesh, source.meshes.len);
    defer gpa.free(mesh_records);
    var triangle_count: u32 = 0;
    var meshlet_count: u32 = 0;
    for (source.meshes, entry.meshes, mesh_records) |mesh, *out, *record| {
        out.* = .{
            .vertex_offset = try self.vertices.alloc(self, @intCast(mesh.vertices.len)),
            .vertex_count = @intCast(mesh.vertices.len),
            .skin_offset = null,
            .index_offset = try self.indices.alloc(self, @intCast(mesh.indices.len)),
            .index_count = @intCast(mesh.indices.len),
            .lod0_index_count = mesh.lod0_index_count,
            .meshlet_offset = try self.meshlets.alloc(self, @intCast(mesh.meshlets.len)),
            .meshlet_count = @intCast(mesh.meshlets.len),
            .material = entry.material_base + mesh.material,
            .blend = source.materials[mesh.material].alpha_mode == .blend or source.materials[mesh.material].transmission > 0,
            .masked = source.materials[mesh.material].alpha_mode != .@"opaque" or source.materials[mesh.material].transmission > 0 or source.materials[mesh.material].double_sided,
            .blas = null,
            .coarse_vertex_count = mesh.coarse_vertex_count,
            .coarse_error = mesh.coarse_error,
        };
        try self.vertices.write(device, out.vertex_offset, std.mem.sliceAsBytes(mesh.vertices));
        try self.indices.write(device, out.index_offset, std.mem.sliceAsBytes(mesh.indices));
        try self.meshlets.write(device, out.meshlet_offset, std.mem.sliceAsBytes(mesh.meshlets));
        if (self.options.path_tracing_fallback and !device.ray_tracing and mesh.skin == null) try buildMeshTree(self, mesh, out, entry.mesh_base + @as(u32, @intCast((@intFromPtr(out) - @intFromPtr(entry.meshes.ptr)) / @sizeOf(ModelMesh))));
        if (mesh.skin) |skin| {
            out.skin_offset = try self.skin_vertices.alloc(self, @intCast(skin.len));
            try self.skin_vertices.write(device, out.skin_offset.?, std.mem.sliceAsBytes(skin));
            if (mesh.morph_targets != 0) {
                out.morph_offset = try self.morph_deltas.alloc(self, @intCast(mesh.morph_deltas.len));
                out.morph_targets = mesh.morph_targets;
                try self.morph_deltas.write(device, out.morph_offset.?, std.mem.sliceAsBytes(mesh.morph_deltas));
            }
        }
        record.* = .{
            .center = mesh.bounds_center,
            .radius = mesh.bounds_radius,
            .index_offset = out.index_offset,
            .meshlet_offset = out.meshlet_offset,
            .meshlet_count = out.meshlet_count,
            .bvh = out.bvh_nodes orelse gpu.invalid_id,
        };
        triangle_count += out.lod0_index_count / 3;
        meshlet_count += out.meshlet_count;
    }
    try self.meshes.write(device, entry.mesh_base, std.mem.sliceAsBytes(mesh_records));

    entry.order = try animation.topologicalOrder(gpa, source.nodes);
    entry.node_world = try gpa.alloc(Mat4, source.nodes.len);
    try self.scratch_locals.resize(gpa, source.nodes.len * 3);
    animation.evaluate(source, entry.order, null, self.scratch_locals.items, entry.node_world);
    {
        const needed = try gpa.alloc(bool, source.nodes.len);
        defer gpa.free(needed);
        @memset(needed, false);
        for (source.instances) |instance| needed[instance.node] = true;
        for (source.skins) |skin| for (skin.joints) |joint| {
            needed[joint] = true;
        };
        var remaining = entry.order.len;
        var count: usize = 0;
        while (remaining > 0) {
            remaining -= 1;
            const node = entry.order[remaining];
            if (!needed[node]) continue;
            count += 1;
            if (source.nodes[node].parent) |parent| needed[parent] = true;
        }
        entry.pose_order = try gpa.alloc(u32, count);
        var next: usize = 0;
        for (entry.order) |node| if (needed[node]) {
            entry.pose_order[next] = node;
            next += 1;
        };
        std.log.debug("model: {d} of {d} nodes posed", .{ count, source.nodes.len });
    }

    var minimum: Vec3 = @splat(std.math.inf(f32));
    var maximum: Vec3 = @splat(-std.math.inf(f32));
    var joint_count: u32 = 0;
    for (source.skins) |skin| joint_count += @intCast(skin.joints.len);
    for (source.instances) |instance| {
        const mesh = source.meshes[instance.mesh];
        const world = if (instance.skin != null) math.identity else entry.node_world[instance.node];
        const center = math.transformPoint(world, mesh.bounds_center);
        const radius = mesh.bounds_radius * math.maxScale(world);
        inline for (0..3) |axis| {
            minimum[axis] = @min(minimum[axis], center[axis] - radius);
            maximum[axis] = @max(maximum[axis], center[axis] + radius);
        }
    }
    var morph_meshes: u32 = 0;
    var morph_targets: u32 = 0;
    for (source.meshes) |mesh| {
        if (mesh.morph_targets == 0) continue;
        morph_meshes += 1;
        morph_targets = @max(morph_targets, mesh.morph_targets);
    }
    var texture_count: u32 = 0;
    for (entry.textures) |texture| {
        if (texture != null) texture_count += 1;
    }
    entry.info = .{
        .mesh_count = @intCast(source.meshes.len),
        .triangle_count = triangle_count,
        .meshlet_count = meshlet_count,
        .texture_count = texture_count,
        .joint_count = joint_count,
        .morph_meshes = morph_meshes,
        .morph_targets = morph_targets,
        .bounds_min = minimum,
        .bounds_max = maximum,
        .bounds_center = math.scale(math.add(minimum, maximum), 0.5),
        .bounds_radius = math.length(math.sub(maximum, minimum)) * 0.5,
    };
    if (device.ray_tracing) {
        for (entry.meshes) |*mesh| {
            if (mesh.skin_offset != null) continue;
            const made = try device.createBlas(geometry_passes.blasDesc(self, mesh.*));
            if (device.detached_queue != null) mesh.blas_building = made else mesh.blas = made;
        }
        entry.blas_pending = true;
        entry.blas_frame = null;
        self.blas_pending += 1;
    }
    entry.state = .ready;
    return true;
}

/// `BvhInstance` in trace.glsl.
const TraceInstance = extern struct {
    /// World to mesh space: 3 rows of each of 4 columns.
    to_mesh: [12]f32,
    instance: u32,
    pad: [3]u32 = .{ 0, 0, 0 },
};

/// Rebuilds the scene's instance BVH for the path tracing fallback if
/// its contents changed. `entities` are this frame's entity records;
/// instance groups follow them, as in the instance buffer.
pub fn buildSceneTree(self: *Renderer, scene: *SceneData, entities: []const gpu.Instance) !void {
    const gpa = self.gpa;
    const device = self.device;
    const Placed = extern struct { transform: Mat4, mesh: u32, instance: u32 };
    var placed: std.ArrayList(Placed) = .empty;
    defer placed.deinit(gpa);
    for (entities, 0..) |record, index| {
        if (record.flags & (gpu.instance_skinned | gpu.instance_proxy) != 0) continue;
        if (record.mesh >= self.mesh_boxes.items.len or self.mesh_boxes.items[record.mesh] == null) continue;
        try placed.append(gpa, .{ .transform = gpu.expand(record.transform), .mesh = record.mesh, .instance = @intCast(index) });
    }
    var record: u32 = @intCast(entities.len);
    for (scene.groups.items) |group_handle| {
        const group = self.instance_groups.get(group_handle) orelse continue;
        if (group.per_copy == 0) continue;
        const model = self.models.get(group.model) orelse continue;
        const source = &model.source.?;
        for (group.transforms) |placement| {
            for (source.instances) |instance| {
                defer record += 1;
                const mesh = model.mesh_base + instance.mesh;
                if (model.meshes[instance.mesh].skin_offset != null) continue;
                if (mesh >= self.mesh_boxes.items.len or self.mesh_boxes.items[mesh] == null) continue;
                try placed.append(gpa, .{ .transform = math.mul(placement, model.node_world[instance.node]), .mesh = mesh, .instance = record });
            }
        }
    }
    const hash = std.hash.Wyhash.hash(placed.items.len, std.mem.sliceAsBytes(placed.items)) | 1;
    if (scene.trace_ready and hash == scene.trace_hash) return;

    const lo = try gpa.alloc([3]f32, placed.items.len);
    defer gpa.free(lo);
    const hi = try gpa.alloc([3]f32, placed.items.len);
    defer gpa.free(hi);
    for (placed.items, lo, hi) |item, *low, *high| {
        const box = self.mesh_boxes.items[item.mesh].?;
        low.* = @splat(std.math.inf(f32));
        high.* = @splat(-std.math.inf(f32));
        for (0..8) |corner| {
            const point = math.transformPoint(item.transform, .{
                box[corner & 1][0],
                box[(corner >> 1) & 1][1],
                box[(corner >> 2) & 1][2],
            });
            inline for (0..3) |axis| {
                low[axis] = @min(low[axis], point[axis]);
                high[axis] = @max(high[axis], point[axis]);
            }
        }
    }
    var tree = try bvh.build(gpa, lo, hi, 2);
    defer tree.deinit(gpa);
    const records = try gpa.alloc(TraceInstance, @max(placed.items.len, 1));
    defer gpa.free(records);
    records[0] = .{ .to_mesh = @splat(0), .instance = 0 };
    for (tree.order, 0..) |item, place| {
        const m = math.inverse(placed.items[item].transform);
        records[place] = .{
            .to_mesh = .{ m[0], m[1], m[2], m[4], m[5], m[6], m[8], m[9], m[10], m[12], m[13], m[14] },
            .instance = placed.items[item].instance,
        };
    }
    if (scene.trace_nodes == null or scene.trace_nodes_capacity < tree.nodes.len) {
        if (scene.trace_nodes) |old| device.destroyBuffer(old);
        scene.trace_nodes = null;
        scene.trace_nodes_capacity = @intCast(tree.nodes.len + tree.nodes.len / 2);
        scene.trace_nodes = try device.createBuffer(.{ .name = "scene tree", .size = @as(u64, scene.trace_nodes_capacity) * @sizeOf(bvh.Node), .usage = .{ .storage = true, .copy_dst = true } });
    }
    if (scene.trace_instances == null or scene.trace_instances_capacity < records.len) {
        if (scene.trace_instances) |old| device.destroyBuffer(old);
        scene.trace_instances = null;
        scene.trace_instances_capacity = @intCast(records.len + records.len / 2);
        scene.trace_instances = try device.createBuffer(.{ .name = "scene tree instances", .size = @as(u64, scene.trace_instances_capacity) * @sizeOf(TraceInstance), .usage = .{ .storage = true, .copy_dst = true } });
    }
    try device.uploadBuffer(scene.trace_nodes.?, 0, std.mem.sliceAsBytes(tree.nodes));
    try device.uploadBuffer(scene.trace_instances.?, 0, std.mem.sliceAsBytes(records));
    scene.trace_hash = hash;
    scene.trace_ready = true;
}

/// Builds a mesh's full-detail triangle BVH into the BVH pools; see
/// `Options.path_tracing_fallback`.
fn buildMeshTree(self: *Renderer, mesh: gltf.Mesh, out: *ModelMesh, record: u32) !void {
    const gpa = self.gpa;
    const triangles = mesh.lod0_index_count / 3;
    if (triangles == 0) return;
    const lo = try gpa.alloc([3]f32, triangles);
    defer gpa.free(lo);
    const hi = try gpa.alloc([3]f32, triangles);
    defer gpa.free(hi);
    for (lo, hi, 0..) |*low, *high, triangle| {
        low.* = @splat(std.math.inf(f32));
        high.* = @splat(-std.math.inf(f32));
        for (mesh.indices[triangle * 3 ..][0..3]) |index| {
            const position = mesh.vertices[index].position;
            inline for (0..3) |axis| {
                low[axis] = @min(low[axis], position[axis]);
                high[axis] = @max(high[axis], position[axis]);
            }
        }
    }
    var tree = try bvh.build(gpa, lo, hi, 4);
    defer tree.deinit(gpa);
    const items = try self.bvh_items.alloc(self, triangles);
    errdefer self.bvh_items.free(self, items, triangles);
    const nodes = try self.bvh_nodes.alloc(self, @intCast(tree.nodes.len));
    errdefer self.bvh_nodes.free(self, nodes, @intCast(tree.nodes.len));
    for (tree.nodes) |*node| {
        if (node.count != 0) node.first += items;
    }
    try self.bvh_items.write(self.device, items, std.mem.sliceAsBytes(tree.order));
    try self.bvh_nodes.write(self.device, nodes, std.mem.sliceAsBytes(tree.nodes));
    out.bvh_nodes = nodes;
    out.bvh_node_count = @intCast(tree.nodes.len);
    out.bvh_items = items;
    out.bvh_item_count = triangles;
    out.bvh_min = tree.nodes[0].min;
    out.bvh_max = tree.nodes[0].max;
    while (self.mesh_boxes.items.len <= record) try self.mesh_boxes.append(gpa, null);
    self.mesh_boxes.items[record] = .{ tree.nodes[0].min, tree.nodes[0].max };
}

pub fn freeModel(self: *Renderer, entry: *ModelEntry) void {
    const gpa = self.gpa;
    if (entry.blas_job) |job| self.device.releaseDetached(job);
    entry.blas_job = null;
    if (entry.job) |job| {
        job.group.cancel(job.io);
        if (job.model) |*model| model.deinit();
        gpa.free(job.path);
        gpa.destroy(job);
        entry.job = null;
    }
    if (entry.source) |*source| for (entry.streams) |stream| {
        if (stream.data.len != 0) source.freeCompressed(stream.data);
        gpa.free(stream.path);
    };
    gpa.free(entry.material_images);
    entry.material_images = &.{};
    gpa.free(entry.streams);
    entry.streams = &.{};
    entry.streamed = 0;
    for (entry.textures) |texture| if (texture) |value| self.device.destroyTexture(value);
    gpa.free(entry.textures);
    entry.textures = &.{};
    for (entry.meshes) |*mesh| {
        if (entry.geometry_resident) freeMeshGeometry(self, mesh);
        self.meshlets.free(self, mesh.meshlet_offset, mesh.meshlet_count);
        if (mesh.bvh_nodes) |offset| {
            self.bvh_nodes.free(self, offset, mesh.bvh_node_count);
            self.bvh_items.free(self, mesh.bvh_items, mesh.bvh_item_count);
        }
        if (mesh.skin_offset) |offset| self.skin_vertices.free(self, offset, mesh.vertex_count);
        if (mesh.morph_offset) |offset| self.morph_deltas.free(self, offset, mesh.vertex_count * mesh.morph_targets);
        if (mesh.blas) |blas| self.device.destroyAcceleration(blas);
        if (mesh.blas_building) |blas| self.device.destroyAcceleration(blas);
    }
    for (0..entry.meshes.len) |index| {
        if (entry.mesh_base + index < self.mesh_boxes.items.len) self.mesh_boxes.items[entry.mesh_base + index] = null;
    }
    if (entry.source) |*source| {
        if (entry.transform_count != 0) {
            self.materials.free(self, entry.transform_base, entry.transform_count * gpu.texture_transform_slots);
            self.texture_transform_users -= 1;
            entry.transform_count = 0;
        }
        if (entry.meshes.len != 0) self.meshes.free(self, entry.mesh_base, @intCast(source.meshes.len));
        if (entry.state == .ready) {
            for (source.materials) |material| self.material_shader_users[if (material.shader < self.material_shaders.len) material.shader else 0] -= 1;
            self.materials.free(self, entry.material_base, @intCast(source.materials.len));
        }
        source.deinit();
        entry.source = null;
    }
    gpa.free(entry.meshes);
    gpa.free(entry.order);
    gpa.free(entry.pose_order);
    gpa.free(entry.node_world);
    entry.meshes = &.{};
    entry.order = &.{};
    entry.pose_order = &.{};
    entry.node_world = &.{};
}
