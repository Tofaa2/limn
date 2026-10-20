//! A scene's ray tracing structure: made when a view first asks for rays and
//! rebuilt once a frame when the instances in it changed. Global illumination,
//! traced reflections and shadows, path tracing, lightmaps and fluid obstacles
//! all trace it; none of them owns it. Internal to the renderer.
const std = @import("std");
const rhi = @import("../../rhi/rhi.zig");
const api = @import("../api.zig");
const render = @import("../renderer.zig");
const scene_pass = @import("../scene_pass.zig");

const Renderer = render.Renderer;
const SceneData = render.SceneData;
const SceneFrame = scene_pass.SceneFrame;
const geometry_feature = @import("../features/geometry.zig");
const renderer_state = @import("../state.zig");
const ModelEntry = renderer_state.ModelEntry;
const Pool = renderer_state.Pool;
const BlasJob = renderer_state.BlasJob;

/// The renderer's ray tracing structures besides each scene's TLAS: the
/// meshes' BLASes as they are built and compacted, and the triangle trees
/// path tracing walks without hardware rays.
pub const Structures = struct {
    /// Per-mesh triangle BVHs for the path tracing fallback.
    bvh_nodes: Pool,
    bvh_items: Pool,
    /// Mesh-space box of each mesh with a BVH, by mesh record index.
    mesh_boxes: std.ArrayList(?[2][3]f32) = .empty,
    /// Models whose structures are still being built.
    blas_pending: u32 = 0,
    /// Models with acceleration structures waiting for smaller copies.
    blas_compacting: u32 = 0,
    /// Deformed-mesh acceleration structures to rebuild after skinning.
    blas_jobs: std.ArrayList(BlasJob) = .empty,
    /// Progress through the round of acceleration structure refits.
    refit_cursor: usize = 0,

    pub fn init(storage: rhi.BufferUsage) Structures {
        return .{
            .bvh_nodes = .init("bvh nodes", @sizeOf(@import("../bvh.zig").Node), 1 << 10, storage),
            .bvh_items = .init("bvh items", @sizeOf(u32), 1 << 10, storage),
        };
    }

    pub fn ensure(self: *Structures, device: *rhi.Device) !void {
        try self.bvh_nodes.ensure(device);
        try self.bvh_items.ensure(device);
    }

    pub fn deinit(self: *Structures, renderer: *Renderer) void {
        self.bvh_nodes.deinit(renderer);
        self.bvh_items.deinit(renderer);
        self.mesh_boxes.deinit(renderer.internal.gpa);
        self.blas_jobs.deinit(renderer.internal.gpa);
    }
};

/// Whether `scene` needs its structure for a view whose features asked for
/// rays or not (`Resolve.rays`): baking lightmaps and fluids that meet the
/// scene trace it too.
pub fn wanted(renderer: *Renderer, scene: *const SceneData, rays: bool) bool {
    if (!renderer.device.caps.ray_tracing) return false;
    if (rays) return true;
    if (scene.lightmaps_baking != 0) return true;
    for (scene.fluids.items) |handle| {
        const fluid = renderer.fluids.table.get(handle) orelse continue;
        if (fluid.desc.scene_obstacles) return true;
    }
    return false;
}

/// Makes or grows the structure for this frame's instances. Only the first
/// view to draw the scene in a frame may make it, since the acceleration
/// structures of animated meshes are rebuilt for it then; a later view's
/// request is kept for the next frame.
pub fn prepare(renderer: *Renderer, scene: *SceneData, scene_frame: SceneFrame, want: bool, fresh_scene: bool) !void {
    if (want) scene.rays_wanted = true;
    if (!scene.rays_wanted or scene_frame.tlas_count == 0) return;
    if (scene.tlas != null and scene.tlas_capacity >= scene_frame.tlas_count) return;
    if (!fresh_scene) return;
    const device = renderer.device;
    if (scene.tlas) |old| device.destroyAcceleration(old);
    scene.tlas = null;
    scene.tlas_hash = 0;
    scene.tlas_capacity = @max(scene_frame.tlas_count * 2, 256);
    scene.tlas = try device.createTlas(.{ .max_instances = scene.tlas_capacity });
}

/// Rebuilds the structure if its instances changed since it was last built.
/// After the frame's animated meshes are rebuilt and before anything traces.
pub fn build(cmd: *rhi.CommandEncoder, scene: *SceneData, scene_frame: SceneFrame) void {
    const tlas = scene.tlas orelse return;
    if (scene_frame.tlas_count == 0 or scene_frame.tlas_count > scene.tlas_capacity) return;
    if (scene.tlas_hash == scene_frame.tlas_hash) return;
    cmd.beginScope("ray scene");
    defer cmd.endScope();
    cmd.buildTlas(tlas, scene_frame.tlas_instances, scene_frame.tlas_count);
    scene.tlas_hash = scene_frame.tlas_hash;
}

/// The structure, once it holds this frame's instances.
pub fn current(scene: *const SceneData, scene_frame: SceneFrame) ?rhi.AccelerationStructure {
    const tlas = scene.tlas orelse return null;
    if (scene.tlas_hash == 0 or scene.tlas_hash != scene_frame.tlas_hash) return null;
    return tlas;
}

/// Whether `build` will leave a structure for this frame's instances.
pub fn ready(scene: *const SceneData, scene_frame: SceneFrame) bool {
    return scene.tlas != null and scene_frame.tlas_count != 0 and scene_frame.tlas_count <= scene.tlas_capacity;
}

/// Builds acceleration structures of newly loaded models. With
/// `frame_index` and a second GPU queue they build asynchronously and are
/// adopted when done; otherwise `cmd` builds them at once. Must run after
/// their geometry uploads have been recorded, and waits for a geometry pool
/// that moved to a new buffer to be filled.
pub fn buildPendingBlas(self: *Renderer, cmd: *rhi.CommandEncoder, frame_index: ?u64) !void {
    if (frame_index) |frame_now| if (self.internal.vertices.replaced or self.internal.indices.replaced) {
        self.internal.vertices.replaced = false;
        self.internal.indices.replaced = false;
        self.internal.geometry_replaced = frame_now;
    };
    if (self.internal.rays.blas_compacting != 0) try compactBuiltBlas(self, cmd);
    if (self.internal.rays.blas_pending == 0) return;
    const device = self.device;
    var still_pending: u32 = 0;
    var finished = false;
    for (self.models.table.slots.items) |*slot| if (slot.value) |*entry| {
        if (!entry.blas_pending) continue;
        const frame_now = frame_index orelse {
            if (entry.blas_job) |job| {
                device.releaseDetached(job);
                entry.blas_job = null;
            } else {
                try geometry_feature.buildMeshBlases(self, cmd, entry.meshes, buildingOrBuiltBlas);
                for (entry.meshes) |mesh| {
                    if (mesh.blas_building orelse mesh.blas) |blas| try cmd.measureBlas(blas);
                }
            }
            finished = adoptBlas(self, entry) or finished;
            continue;
        };
        if (entry.blas_job) |job| {
            if (!device.detachedDone(job)) {
                still_pending += 1;
                continue;
            }
            device.releaseDetached(job);
            entry.blas_job = null;
            finished = adoptBlas(self, entry) or finished;
            continue;
        }
        var detached = false;
        for (entry.meshes) |mesh| detached = detached or mesh.blas_building != null;
        if (!detached) {
            entry.blas_pending = false;
            try geometry_feature.buildMeshBlases(self, cmd, entry.meshes, builtBlas);
            for (entry.meshes) |mesh| if (mesh.blas) |blas| try cmd.measureBlas(blas);
            markCompacting(self, entry);
            continue;
        }
        still_pending += 1;
        const carried = entry.blas_frame orelse {
            entry.blas_frame = frame_now;
            continue;
        };
        if (frame_now < carried + rhi.frames_in_flight) continue;
        // A pool that has just moved holds nothing yet for the second queue
        // to read. Its contents may be copied a frame after the move is seen.
        if (self.internal.geometry_replaced) |replaced| if (frame_now <= replaced + rhi.frames_in_flight) continue;
        var encoder = (try device.beginDetached()).?;
        try geometry_feature.buildMeshBlases(self, &encoder, entry.meshes, buildingBlas);
        for (entry.meshes) |mesh| if (mesh.blas_building) |blas| try encoder.measureBlas(blas);
        entry.blas_job = try device.submitDetached(encoder);
    };
    self.internal.rays.blas_pending = still_pending;
    if (finished) self.internal.asset_generation += 1;
}

/// Has `compactBuiltBlas` look at the model's structures.
fn markCompacting(self: *Renderer, entry: *ModelEntry) void {
    if (entry.blas_compacting) return;
    entry.blas_compacting = true;
    self.internal.rays.blas_compacting += 1;
}

/// Most structures replaced by smaller copies in one frame.
const compactions_per_frame = 64;

/// Replaces the built structures whose compacted size has come back from
/// the GPU with copies of that size. The copy is made by `cmd`, ahead of
/// anything that traces rays this frame.
fn compactBuiltBlas(self: *Renderer, cmd: *rhi.CommandEncoder) !void {
    const device = self.device;
    var budget: u32 = compactions_per_frame;
    var replaced = false;
    for (self.models.table.slots.items) |*slot| if (slot.value) |*entry| {
        if (!entry.blas_compacting or entry.blas_pending) continue;
        var waiting = false;
        for (entry.meshes) |*mesh| {
            const built = mesh.blas orelse continue;
            if (!device.blasMeasured(built)) continue;
            if (budget == 0) {
                waiting = true;
                continue;
            }
            const size = device.compactedBlasSize(built) orelse {
                waiting = waiting or device.blasMeasured(built);
                continue;
            };
            const compact = device.createCompactBlas(built, size) catch continue;
            cmd.compactBlas(built, compact);
            device.destroyAcceleration(built);
            mesh.blas = compact;
            replaced = true;
            budget -= 1;
        }
        if (!waiting) {
            entry.blas_compacting = false;
            self.internal.rays.blas_compacting -= 1;
        }
    };
    if (replaced) self.internal.asset_generation += 1;
}

/// Makes a model's finished acceleration structures the live ones.
/// Returns whether there were any.
fn adoptBlas(self: *Renderer, entry: *ModelEntry) bool {
    var any = false;
    for (entry.meshes) |*mesh| if (mesh.blas_building) |built| {
        mesh.blas = built;
        mesh.blas_building = null;
        any = true;
    };
    entry.blas_pending = false;
    entry.blas_frame = null;
    markCompacting(self, entry);
    return any;
}

fn buildingOrBuiltBlas(mesh: renderer_state.ModelMesh) ?rhi.AccelerationStructure {
    return mesh.blas_building orelse mesh.blas;
}

fn builtBlas(mesh: renderer_state.ModelMesh) ?rhi.AccelerationStructure {
    return mesh.blas;
}

fn buildingBlas(mesh: renderer_state.ModelMesh) ?rhi.AccelerationStructure {
    return mesh.blas_building;
}
