//! Pipelines built from their descriptions the first time each is asked for,
//! and kept by a hash of the description. Internal to the renderer.
const std = @import("std");
const rhi = @import("../../rhi/rhi.zig");

/// What a pipeline is built from.
pub const Desc = union(enum) {
    graphics: rhi.GraphicsPipelineDesc,
    compute: rhi.ComputePipelineDesc,
};

/// Not thread-safe, apart from the compiling `getLater` hands to workers.
pub const PipelineCache = struct {
    device: *rhi.Device,
    gpa: std.mem.Allocator,
    io: std.Io,
    made: std.AutoHashMapUnmanaged(u64, rhi.Pipeline) = .empty,
    /// Pipelines that would not compile; not tried again until `reset`.
    failed: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// Tells this cache, until its next `reset`, from every other: what `of`
    /// remembers is for one stamp.
    stamp: u64,
    /// Pipelines being compiled on worker threads.
    jobs: std.ArrayList(*Job) = .empty,

    /// A pipeline compiled on a worker thread. It keeps its own copies of the
    /// description's color targets and constants; the shader code, name and
    /// vertex layout must outlive it.
    const Job = struct {
        key: u64,
        device: *const rhi.Device,
        desc: Desc,
        targets: [8]rhi.ColorTarget = undefined,
        constants: [16]u32 = undefined,
        group: std.Io.Group = .init,
        done: std.atomic.Value(bool) = .init(false),
        compiled: ?rhi.Device.CompiledPipeline = null,
        failure: ?anyerror = null,

        fn run(job: *Job) std.Io.Cancelable!void {
            const compiled = switch (job.desc) {
                .graphics => |graphics| job.device.compileGraphicsPipeline(std.heap.smp_allocator, graphics),
                .compute => |compute| job.device.compileComputePipeline(std.heap.smp_allocator, compute),
            };
            if (compiled) |pipeline| job.compiled = pipeline else |err| job.failure = err;
            job.done.store(true, .release);
        }
    };

    pub fn init(gpa: std.mem.Allocator, device: *rhi.Device, io: std.Io) PipelineCache {
        return .{ .device = device, .gpa = gpa, .io = io, .stamp = nextStamp() };
    }

    pub fn deinit(self: *PipelineCache) void {
        self.reset();
        self.made.deinit(self.gpa);
        self.failed.deinit(self.gpa);
        self.jobs.deinit(self.gpa);
    }

    /// The pipeline `desc` describes, built now if this is its first use.
    pub fn get(self: *PipelineCache, desc: Desc) !rhi.Pipeline {
        const key = hash(desc);
        if (self.made.get(key)) |pipeline| return pipeline;
        const pipeline = switch (desc) {
            .graphics => |graphics| try self.device.createGraphicsPipeline(graphics),
            .compute => |compute| try self.device.createComputePipeline(compute),
        };
        errdefer self.device.destroyPipeline(pipeline);
        try self.made.put(self.gpa, key, pipeline);
        return pipeline;
    }

    /// As `get` for the pipeline `describe` gives for this device, which
    /// depends on nothing else: remembered beside `describe` itself, so a
    /// repeat call costs no hashing.
    pub fn of(self: *PipelineCache, comptime describe: fn (device: *rhi.Device) Desc) !rhi.Pipeline {
        const Remembered = struct {
            /// Names `describe`, which gives each one its own slot.
            const of_describe = describe;
            threadlocal var stamp: u64 = 0;
            threadlocal var pipeline: rhi.Pipeline = undefined;
        };
        if (Remembered.stamp == self.stamp) return Remembered.pipeline;
        const pipeline = try self.get(describe(self.device));
        Remembered.stamp = self.stamp;
        Remembered.pipeline = pipeline;
        return pipeline;
    }

    /// The pipeline `desc` describes if it has been built.
    pub fn peek(self: *const PipelineCache, desc: Desc) ?rhi.Pipeline {
        return self.made.get(hash(desc));
    }

    /// The pipeline `desc` describes if it is built; otherwise null, and it
    /// is compiled on a worker thread from the first such call on. One that
    /// fails to compile stays null until `reset`.
    pub fn getLater(self: *PipelineCache, desc: Desc) !?rhi.Pipeline {
        const key = hash(desc);
        if (self.made.get(key)) |pipeline| return pipeline;
        if (self.failed.contains(key)) return null;
        for (self.jobs.items, 0..) |job, index| {
            if (job.key != key) continue;
            if (!job.done.load(.acquire)) return null;
            job.group.cancel(self.io);
            _ = self.jobs.swapRemove(index);
            defer self.gpa.destroy(job);
            const compiled = job.compiled orelse {
                std.log.warn("pipeline did not compile: {}", .{job.failure.?});
                try self.failed.put(self.gpa, key, {});
                return null;
            };
            const pipeline = try self.device.adoptPipeline(compiled, switch (desc) {
                inline else => |inner| inner.name,
            });
            errdefer self.device.destroyPipeline(pipeline);
            try self.made.put(self.gpa, key, pipeline);
            return pipeline;
        }
        const job = try self.gpa.create(Job);
        errdefer self.gpa.destroy(job);
        job.* = .{ .key = key, .device = self.device, .desc = desc };
        switch (job.desc) {
            .graphics => |*graphics| {
                if (graphics.color_targets.len > job.targets.len or graphics.fragment_constants.len > job.constants.len) return error.PipelineTooLarge;
                @memcpy(job.targets[0..graphics.color_targets.len], graphics.color_targets);
                graphics.color_targets = job.targets[0..graphics.color_targets.len];
                @memcpy(job.constants[0..graphics.fragment_constants.len], graphics.fragment_constants);
                graphics.fragment_constants = job.constants[0..graphics.fragment_constants.len];
            },
            .compute => |*compute| {
                if (compute.constants.len > job.constants.len) return error.PipelineTooLarge;
                @memcpy(job.constants[0..compute.constants.len], compute.constants);
                compute.constants = job.constants[0..compute.constants.len];
            },
        }
        try self.jobs.append(self.gpa, job);
        job.group.concurrent(self.io, Job.run, .{job}) catch job.group.async(self.io, Job.run, .{job});
        return null;
    }

    /// Whether any pipeline is still compiling on a worker thread.
    pub fn compiling(self: *const PipelineCache) bool {
        for (self.jobs.items) |job| if (!job.done.load(.acquire)) return true;
        return false;
    }

    /// Number of pipelines built so far.
    pub fn count(self: *const PipelineCache) u32 {
        return self.made.count();
    }

    /// Destroys every pipeline built and waits for and drops those being
    /// compiled; each is built again on its next use.
    pub fn reset(self: *PipelineCache) void {
        for (self.jobs.items) |job| {
            job.group.cancel(self.io);
            if (job.compiled) |compiled| self.device.discardPipeline(compiled);
            self.gpa.destroy(job);
        }
        self.jobs.clearRetainingCapacity();
        self.stamp = nextStamp();
        var entries = self.made.valueIterator();
        while (entries.next()) |pipeline| self.device.destroyPipeline(pipeline.*);
        self.made.clearRetainingCapacity();
        self.failed.clearRetainingCapacity();
    }
};

var stamps: std.atomic.Value(u64) = .init(1);

fn nextStamp() u64 {
    return stamps.fetchAdd(1, .monotonic);
}

/// Shader code and names are told apart by where they are, which stays put
/// until shaders are reloaded (they are embedded or literals); color
/// targets, constants, vertex attributes and the rest by value.
pub fn hash(desc: Desc) u64 {
    var key = Key{};
    switch (desc) {
        .graphics => |g| {
            key.word(0);
            key.text(g.name);
            key.text(g.vertex);
            key.text(g.fragment orelse "");
            key.text(g.mesh orelse "");
            key.text(g.task orelse "");
            key.word(g.color_targets.len);
            for (g.color_targets) |target| key.word(@intFromEnum(target.format) | @as(u64, @intFromEnum(target.blend)) << 32);
            if (g.depth) |depth| {
                key.word(@intFromEnum(depth.format) | @as(u64, @intFromBool(depth.@"test")) << 32 | @as(u64, @intFromBool(depth.write)) << 33 | @as(u64, @intFromBool(depth.clamp)) << 34 | @as(u64, @intFromEnum(depth.compare)) << 40);
                if (depth.bias) |bias| {
                    key.word(@as(u64, @as(u32, @bitCast(bias.constant))) | @as(u64, @as(u32, @bitCast(bias.slope))) << 32);
                } else key.word(0xffff_ffff_ffff_ffff);
            } else key.word(0xffff_ffff_ffff_ffff);
            key.word(@intFromEnum(g.cull) | @as(u64, @intFromEnum(g.topology)) << 8);
            if (g.vertex_layout) |layout| {
                key.word(layout.stride);
                for (layout.attributes) |attribute| key.word(attribute.location | @as(u64, attribute.offset) << 16 | @as(u64, @intFromEnum(attribute.format)) << 48);
            } else key.word(0xffff_ffff);
            key.word(g.fragment_constants.len);
            for (g.fragment_constants) |constant| key.word(constant);
        },
        .compute => |c| {
            key.word(1);
            key.text(c.name);
            key.text(c.shader);
            key.word(c.constants.len);
            for (c.constants) |constant| key.word(constant);
        },
    }
    return std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(key.words[0..key.len]));
}

/// The words a description is told apart by, hashed in one go; past the
/// buffer they are folded in.
const Key = struct {
    words: [64]u64 = undefined,
    len: usize = 0,

    fn word(self: *Key, value: u64) void {
        if (self.len == self.words.len) {
            const folded = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(&self.words));
            self.len = 0;
            self.word(folded);
        }
        self.words[self.len] = value;
        self.len += 1;
    }

    fn text(self: *Key, bytes: []const u8) void {
        self.word(@intFromPtr(bytes.ptr));
        self.word(bytes.len);
    }
};

test "descriptions that differ only in a slice's place hash the same" {
    const targets_a = [_]rhi.ColorTarget{.{ .format = .rgba8_unorm }};
    var targets_b = targets_a;
    const code = [_]u8{0} ** 128;
    const a = Desc{ .graphics = .{ .name = "a", .vertex = &code, .color_targets = &targets_a } };
    const b = Desc{ .graphics = .{ .name = "a", .vertex = &code, .color_targets = &targets_b } };
    try std.testing.expectEqual(hash(a), hash(b));
    targets_b[0].format = .rgba16_float;
    try std.testing.expect(hash(a) != hash(b));
}
