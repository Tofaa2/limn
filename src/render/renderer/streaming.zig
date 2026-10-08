//! Geometry and texture streaming: what each frame keeps resident. Internal to the renderer.
const std = @import("std");
const rhi = @import("../../rhi/rhi.zig");
const math = @import("../../math.zig");
const gpu = @import("../gpu.zig");
const api = @import("../api.zig");
const renderer_state = @import("../state.zig");
const geometry_passes = @import("../passes/geometry.zig");
const render = @import("../renderer.zig");

const Renderer = render.Renderer;
const Mat4 = math.Mat4;
const Vec3 = math.Vec3;
const StreamFrustum = renderer_state.StreamFrustum;
const TextureStream = renderer_state.TextureStream;
const Zone = renderer_state.Zone;
const Camera = api.Camera;
const FrameDesc = api.FrameDesc;
const ModelMesh = renderer_state.ModelMesh;
const ModelEntry = renderer_state.ModelEntry;
const SceneData = renderer_state.SceneData;
const encodeMaterial = @import("materials.zig").encodeMaterial;

/// Releases geometry of models far from every camera and restores it for
/// near ones.
pub fn updateGeometryStreaming(self: *Renderer, desc: FrameDesc) !void {
    const streaming = self.options.geometry_streaming orelse return;
    const near_enough = if (streaming.coarse_distance > 0) @min(streaming.distance, streaming.coarse_distance * 0.9) else streaming.distance;
    const zone = Zone.start(self.options.profiler, "geometry streaming");
    defer zone.stop();
    for (self.models.table.slots.items) |*slot| if (slot.value) |*entry| {
        entry.stream_distance = std.math.inf(f32);
    };
    for (desc.views) |view_desc| {
        const scene = self.scenes.table.get(view_desc.scene orelse continue) orelse continue;
        const eye = view_desc.camera.position;
        for (scene.entities.items) |item| {
            const entity = self.entities.table.get(item) orelse continue;
            if (!entity.visible) continue;
            const model = self.models.table.get(entity.model) orelse continue;
            if (model.state != .ready) continue;
            const center = math.transformPoint(entity.transform, model.info.bounds_center);
            const radius = model.info.bounds_radius * math.maxScale(entity.transform);
            model.stream_distance = @min(model.stream_distance, @max(math.length(math.sub(center, eye)) - radius, 0));
        }
        for (scene.groups.items) |item| {
            const group = self.instances.table.get(item) orelse continue;
            const model = self.models.table.get(group.model) orelse continue;
            if (model.state != .ready) continue;
            for (group.transforms) |transform| {
                if (model.stream_distance < near_enough) break;
                const center = math.transformPoint(transform, model.info.bounds_center);
                const radius = model.info.bounds_radius * math.maxScale(transform);
                model.stream_distance = @min(model.stream_distance, @max(math.length(math.sub(center, eye)) - radius, 0));
            }
        }
    }

    var changed = false;
    var budget = streaming.upload_bytes_per_frame;
    var released: u32 = 0;
    var released_bytes: u64 = 0;
    var coarse_models: u32 = 0;
    for (self.models.table.slots.items) |*slot| if (slot.value) |*entry| {
        if (entry.state != .ready) continue;
        const source = &entry.source.?;
        var bytes: u64 = 0;
        for (entry.meshes) |mesh| bytes += @as(u64, mesh.vertex_count) * @sizeOf(gpu.Vertex) + @as(u64, mesh.index_count) * @sizeOf(u32);
        if (entry.geometry_resident) {
            if (source.skins.len != 0 or entry.geometry_pinned or entry.blas_pending) continue;
            const far = entry.stream_distance != std.math.inf(f32) and entry.stream_distance > streaming.distance * @max(streaming.release_factor, 1);
            if (!far) {
                const coarse_wanted = streaming.coarse_distance > 0 and entry.stream_distance != std.math.inf(f32) and entry.stream_distance > streaming.coarse_distance;
                if (coarse_wanted and !entry.geometry_coarse) {
                    if (keepCoarse(self, entry)) changed = true;
                } else if (entry.geometry_coarse and entry.stream_distance < streaming.coarse_distance * 0.9 and bytes <= budget) {
                    for (entry.meshes) |*mesh| freeMeshGeometry(self, mesh);
                    entry.geometry_resident = false;
                    entry.geometry_coarse = false;
                    budget -|= bytes;
                    try restoreGeometry(self, entry);
                    changed = true;
                }
                if (entry.geometry_coarse) coarse_models += 1;
                continue;
            }
            for (entry.meshes) |*mesh| {
                freeMeshGeometry(self, mesh);
                if (mesh.blas) |blas| self.device.destroyAcceleration(blas);
                mesh.blas = null;
            }
            entry.geometry_resident = false;
            entry.geometry_coarse = false;
            changed = true;
        } else if (entry.geometry_pinned or entry.stream_distance < streaming.distance) {
            if (bytes > budget and budget != streaming.upload_bytes_per_frame) {
                released += 1;
                released_bytes += bytes;
                continue;
            }
            budget -|= bytes;
            try restoreGeometry(self, entry);
            changed = true;
        }
        if (!entry.geometry_resident) {
            released += 1;
            released_bytes += bytes;
        }
    };
    self.stats.geometry_models_released = released;
    self.stats.geometry_bytes_released = released_bytes;
    self.stats.geometry_models_coarse = coarse_models;
    if (changed) for (self.scenes.table.slots.items) |*slot| if (slot.value) |*scene| {
        scene.layout_dirty = true;
    };
}

/// Frees a mesh's vertex and index pool ranges, whole or coarse.
pub fn freeMeshGeometry(self: *Renderer, mesh: *ModelMesh) void {
    if (mesh.coarse) {
        self.vertices.free(self, mesh.vertex_offset, mesh.coarse_vertex_count);
        self.indices.free(self, mesh.index_offset + mesh.lod0_index_count, mesh.index_count - mesh.lod0_index_count);
        mesh.coarse = false;
    } else {
        self.vertices.free(self, mesh.vertex_offset, mesh.vertex_count);
        self.indices.free(self, mesh.index_offset, mesh.index_count);
    }
}

/// Frees the vertices and indices only the finest LOD uses, for every
/// mesh that can be split. Returns whether anything was freed.
fn keepCoarse(self: *Renderer, entry: *ModelEntry) bool {
    var any = false;
    for (entry.meshes) |*mesh| {
        if (mesh.coarse or mesh.coarse_vertex_count == 0 or mesh.bvh_nodes != null or mesh.skin_offset != null) continue;
        self.vertices.free(self, mesh.vertex_offset + mesh.coarse_vertex_count, mesh.vertex_count - mesh.coarse_vertex_count);
        self.indices.free(self, mesh.index_offset, mesh.lod0_index_count);
        if (mesh.blas) |blas| self.device.destroyAcceleration(blas);
        mesh.blas = null;
        mesh.coarse = true;
        any = true;
    }
    if (any) entry.geometry_coarse = true;
    return any;
}

/// Restores a released model's geometry from the copy in system memory.
fn restoreGeometry(self: *Renderer, entry: *ModelEntry) !void {
    const device = self.device;
    const source = &entry.source.?;
    const records = try self.gpa.alloc(gpu.Mesh, entry.meshes.len);
    defer self.gpa.free(records);
    var reserved: usize = 0;
    errdefer for (entry.meshes[0..reserved]) |mesh| {
        self.vertices.free(self, mesh.vertex_offset, mesh.vertex_count);
        self.indices.free(self, mesh.index_offset, mesh.index_count);
    };
    for (entry.meshes) |*mesh| {
        const vertex_offset = try self.vertices.alloc(self, mesh.vertex_count);
        mesh.index_offset = self.indices.alloc(self, mesh.index_count) catch |err| {
            self.vertices.free(self, vertex_offset, mesh.vertex_count);
            return err;
        };
        mesh.vertex_offset = vertex_offset;
        reserved += 1;
    }
    for (source.meshes, entry.meshes, records) |mesh, placed, *record| {
        try self.vertices.write(device, placed.vertex_offset, std.mem.sliceAsBytes(mesh.vertices));
        try self.indices.write(device, placed.index_offset, std.mem.sliceAsBytes(mesh.indices));
        record.* = .{
            .center = mesh.bounds_center,
            .radius = mesh.bounds_radius,
            .index_offset = placed.index_offset,
            .meshlet_offset = placed.meshlet_offset,
            .meshlet_count = placed.meshlet_count,
            .bvh = placed.bvh_nodes orelse gpu.invalid_id,
        };
    }
    try self.meshes.write(device, entry.mesh_base, std.mem.sliceAsBytes(records));
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
    entry.geometry_resident = true;
}

pub fn createStreamTexture(self: *Renderer, stream: *const TextureStream, wanted_first: u32) !rhi.Texture {
    const device = self.device;
    var first = wanted_first;
    var from_file: []u8 = &.{};
    defer self.gpa.free(from_file);
    const file_start = stream.levelOffset(first);
    if (file_start < stream.tail_offset) {
        if (readStreamLevels(self, stream, file_start, stream.tail_offset - file_start)) |bytes| {
            from_file = bytes;
        } else |err| {
            std.log.warn("texture streaming: could not read {s}: {s}", .{ stream.path, @errorName(err) });
            first = stream.floor;
        }
    }
    const texture = try device.createTexture(.{
        .name = "material texture",
        .width = @max(stream.width >> @intCast(first), 1),
        .height = @max(stream.height >> @intCast(first), 1),
        .format = stream.format(),
        .usage = .{ .sampled = true, .copy_dst = true },
        .mip_levels = stream.levels - first,
    });
    errdefer device.destroyTexture(texture);
    var offset = stream.levelOffset(first);
    for (first..stream.levels) |level| {
        const size = stream.levelSize(@intCast(level));
        const bytes = if (offset < stream.tail_offset) from_file[offset - file_start ..][0..size] else stream.data[offset - stream.tail_offset ..][0..size];
        try device.uploadTexture(texture, @intCast(level - first), 0, bytes);
        offset += size;
    }
    return texture;
}

/// Reads part of a texture's mip chain from its asset cache file (12-byte
/// header, then the chain). Caller frees.
fn readStreamLevels(self: *Renderer, stream: *const TextureStream, offset: usize, size: usize) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(self.io, stream.path, .{});
    defer file.close(self.io);
    const bytes = try self.gpa.alloc(u8, size);
    errdefer self.gpa.free(bytes);
    if (try file.readPositionalAll(self.io, bytes, 12 + offset) != size) return error.EndOfStream;
    return bytes;
}

/// Lowers the wanted mip level of each texture a model's meshes use, for
/// one copy of the model and the on-screen size of a meter at distance 1.
fn wantModelTextures(
    model: *ModelEntry,
    transform: Mat4,
    camera: Camera,
    pixels_at_one_meter: f32,
    bias: f32,
    frustum: ?StreamFrustum,
    /// Per mesh, whether a camera drew it; null asks for all.
    drawn: ?[]const u32,
) void {
    const source = &model.source.?;
    for (source.instances, 0..) |instance, part| {
        if (drawn) |parts| if (parts[part] == 0) continue;
        const mesh = source.meshes[instance.mesh];
        if (mesh.uv_density <= 0) continue;
        const world = if (instance.skin != null) transform else math.mul(transform, model.node_world[instance.node]);
        const scale = @max(math.maxScale(world), 1e-6);
        const center = math.transformPoint(world, mesh.bounds_center);
        const distance = @max(math.length(math.sub(center, camera.position)) - mesh.bounds_radius * scale, camera.near);
        if (frustum) |seen| if (!seen.touches(center, mesh.bounds_radius * scale)) continue;
        const material = source.materials[mesh.material];
        const uv_per_pixel = mesh.uv_density * @max(@abs(material.uv_scale[0]), @abs(material.uv_scale[1])) / scale * distance / pixels_at_one_meter;
        inline for (.{ "base_color_texture", "normal_texture", "metallic_roughness_texture", "occlusion_texture", "emissive_texture" }) |field| {
            if (@field(material, field)) |ref| {
                const stream = &model.streams[ref.image];
                if (stream.data.len != 0) {
                    const texels = uv_per_pixel * @as(f32, @floatFromInt(@max(stream.width, stream.height)));
                    const level = @log2(@max(texels, 1e-6)) + bias;
                    const wanted: u32 = if (level <= 0) 0 else @min(@as(u32, @intFromFloat(level)), stream.floor);
                    stream.wanted = @min(stream.wanted, wanted);
                }
            }
        }
    }
}

/// Instances a camera drew a few frames ago; null when not known (no
/// readback yet, or the scene's layout changed since).
fn seenInstances(device: *rhi.Device, scene: *const SceneData, frame: rhi.Frame) ?[]const u32 {
    if (scene.layout_dirty) return null;
    const slot: usize = @intCast(frame.index % rhi.frames_in_flight);
    const tag = scene.seen_tags[slot];
    const buffer = scene.seen_readback[slot] orelse return null;
    if (!tag.valid or tag.layout_version != scene.layout_version) return null;
    return device.mappedSlice(u32, buffer)[0..tag.count];
}

/// Decides which mip levels the frame's views need, fits them to the
/// budget, and loads or drops levels to match.
pub fn updateTextureStreaming(self: *Renderer, frame: rhi.Frame, desc: FrameDesc) !void {
    const streaming = self.options.texture_streaming orelse return;
    const zone = Zone.start(self.options.profiler, "texture streaming");
    defer zone.stop();
    const device = self.device;
    for (self.models.table.slots.items) |*slot| if (slot.value) |*entry| {
        for (entry.streams) |*stream| stream.wanted = stream.floor;
    };
    for (desc.views) |view_desc| {
        const scene = self.scenes.table.get(view_desc.scene orelse continue) orelse continue;
        const target = switch (view_desc.target) {
            .backbuffer => frame.backbuffer orelse continue,
            .texture => |texture| texture,
        };
        const height = if (view_desc.region) |region| region.height else device.textureInfo(target).height;
        const camera = view_desc.camera;
        const pixels_at_one_meter = @as(f32, @floatFromInt(height)) * 0.5 / @tan(camera.fov_y * 0.5) *
            std.math.clamp(view_desc.settings.render_scale, 0.25, 1);
        const bias = streaming.mip_bias + view_desc.settings.texture_mip_bias;
        const frustum: ?StreamFrustum = if (streaming.visible_only) blk: {
            const info = device.textureInfo(target);
            const width = if (view_desc.region) |region| region.width else info.width;
            const tan_y = @tan(camera.fov_y * 0.5);
            break :blk .{
                .view = math.lookTo(camera.position, camera.forward, camera.up),
                .tan_x = tan_y * @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height)),
                .tan_y = tan_y,
            };
        } else null;
        const seen: ?[]const u32 = if (streaming.skip_occluded) seenInstances(device, scene, frame) else null;
        self.seen_round += 1;
        if (seen != null) for (scene.layout.items, 0..) |placed, index| {
            if (!placed.first_of_entity) continue;
            const entity = self.entities.table.get(placed.entity) orelse continue;
            entity.seen_round = self.seen_round;
            entity.seen_first = @intCast(index);
        };
        for (scene.entities.items) |item| {
            const entity = self.entities.table.get(item) orelse continue;
            if (!entity.visible) continue;
            const model = self.models.table.get(entity.model) orelse continue;
            if (model.state != .ready or model.streamed == 0) continue;
            const parts: ?[]const u32 = if (seen) |drawn| blk: {
                if (entity.seen_round != self.seen_round) continue;
                const count = model.source.?.instances.len;
                if (entity.seen_first + count > drawn.len) continue;
                break :blk drawn[entity.seen_first..][0..count];
            } else null;
            wantModelTextures(model, entity.transform, camera, pixels_at_one_meter, bias, frustum, parts);
        }
        for (scene.groups.items) |item| {
            const group = self.instances.table.get(item) orelse continue;
            const model = self.models.table.get(group.model) orelse continue;
            if (model.state != .ready or model.streamed == 0 or group.transforms.len == 0) continue;
            var nearest: ?usize = null;
            var nearest_distance = std.math.inf(f32);
            for (group.transforms, 0..) |transform, index| {
                if (seen) |drawn| {
                    const first = group.base + @as(u32, @intCast(index)) * group.per_copy;
                    var any = false;
                    for (0..group.per_copy) |part| {
                        if (first + part < drawn.len and drawn[first + part] != 0) any = true;
                    }
                    if (!any) continue;
                }
                const delta = math.sub(Vec3{ transform[12], transform[13], transform[14] }, camera.position);
                const distance = math.dot(delta, delta);
                if (distance < nearest_distance) {
                    nearest_distance = distance;
                    nearest = index;
                }
            }
            wantModelTextures(model, group.transforms[nearest orelse continue], camera, pixels_at_one_meter, bias, null, null);
        }
    }

    var extra: u32 = 0;
    var resident_bytes: u64 = 0;
    var count: u32 = 0;
    while (true) : (extra += 1) {
        var wanted_bytes: u64 = 0;
        resident_bytes = 0;
        count = 0;
        for (self.models.table.slots.items) |*slot| if (slot.value) |*entry| {
            for (entry.streams) |*stream| {
                if (stream.data.len == 0) continue;
                wanted_bytes += stream.bytesFrom(@min(stream.wanted + extra, stream.floor));
                resident_bytes += stream.bytesFrom(stream.resident);
                count += 1;
            }
        };
        if (streaming.budget_bytes == 0 or wanted_bytes <= streaming.budget_bytes or extra == 16) break;
    }

    var pending: u32 = 0;
    var upload_left = streaming.upload_bytes_per_frame;
    for ([_]bool{ false, true }) |loading| {
        for (self.models.table.slots.items) |*slot| if (slot.value) |*entry| {
            if (entry.state != .ready) continue;
            for (entry.streams, 0..) |*stream, index| {
                if (stream.data.len == 0) continue;
                const goal = @min(stream.wanted + extra, stream.floor);
                if (goal == stream.resident) {
                    stream.low_frames = 0;
                    continue;
                }
                if (loading != (goal < stream.resident)) continue;
                const before = stream.bytesFrom(stream.resident);
                const after = stream.bytesFrom(goal);
                if (loading) {
                    stream.low_frames = 0;
                    const fits = streaming.budget_bytes == 0 or resident_bytes - before + after <= streaming.budget_bytes;
                    if (upload_left == 0 or !fits) {
                        pending += 1;
                        continue;
                    }
                    upload_left -|= after;
                } else {
                    stream.low_frames += 1;
                    const over = streaming.budget_bytes != 0 and resident_bytes > streaming.budget_bytes;
                    if (!over and stream.low_frames < streaming.evict_delay_frames) continue;
                    stream.low_frames = 0;
                }
                const texture = try createStreamTexture(self, stream, goal);
                device.destroyTexture(entry.textures[index].?);
                entry.textures[index] = texture;
                stream.resident = goal;
                resident_bytes = resident_bytes - before + after;
                entry.materials_stale = true;
            }
        };
    }
    for (self.models.table.slots.items) |*slot| if (slot.value) |*entry| {
        if (!entry.materials_stale) continue;
        entry.materials_stale = false;
        for (entry.source.?.materials, 0..) |material, index| {
            const encoded = try encodeMaterial(self, entry, material, index);
            try self.materials.pool.write(device, entry.material_base + @as(u32, @intCast(index)), std.mem.asBytes(&encoded));
        }
    };
    self.stats.streamed_textures = count;
    self.stats.streamed_texture_bytes = resident_bytes;
    self.stats.streamed_textures_pending = pending;
}
