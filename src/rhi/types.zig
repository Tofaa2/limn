//! Plain-data descriptions used by the RHI. Nothing here touches Vulkan.
const std = @import("std");
const builtin = @import("builtin");
const Handle = @import("../handle.zig").Handle;

/// Type tags that make handles of different resources distinct types.
pub const BufferTag = opaque {};
pub const TextureTag = opaque {};
pub const SamplerTag = opaque {};
pub const PipelineTag = opaque {};
pub const AccelerationTag = opaque {};
/// Bottom- or top-level ray-tracing acceleration structure.
pub const AccelerationStructure = Handle(AccelerationTag);
/// From `Device.createBuffer`; stale once the buffer is destroyed.
pub const Buffer = Handle(BufferTag);
/// From `Device.createTexture` or `Frame.backbuffer`. Backbuffer handles
/// also go stale when the swapchain is rebuilt.
pub const Texture = Handle(TextureTag);
pub const Sampler = Handle(SamplerTag);
/// A graphics or compute pipeline.
pub const Pipeline = Handle(PipelineTag);

/// Borrowed platform window handles; the window must outlive the device.
pub const NativeWindow = union(enum) {
    /// Xlib `Display*` and `Window` id.
    xlib: struct { display: *anyopaque, window: usize },
    /// Wayland `wl_display*` and `wl_surface*`.
    wayland: struct { display: *anyopaque, surface: *anyopaque },
    /// Win32 `HINSTANCE` (may be null) and `HWND`.
    win32: struct { instance: ?*anyopaque, window: *anyopaque },
};

pub const Surface = struct {
    window: NativeWindow,
    /// Initial framebuffer size in pixels; follow changes with `Device.resize`.
    width: u32,
    height: u32,
    /// FIFO when true; otherwise immediate, else mailbox, else FIFO. Change
    /// with `Device.setVsync`.
    vsync: bool = true,
};

/// The defaults give a headless device.
pub const DeviceDesc = struct {
    application_name: [:0]const u8 = "limn",
    /// Khronos and synchronization validation; needs the layers installed.
    validation: bool = builtin.mode == .Debug,
    /// Substring of the adapter name to prefer, for multi-GPU machines.
    preferred_device: ?[]const u8 = null,
    /// Null for headless use.
    surface: ?Surface = null,
    /// Enable ray queries when supported; check `Device.ray_tracing`.
    ray_tracing: bool = true,
    /// Use mesh shaders when supported; check `Device.mesh_shaders`.
    mesh_shaders: bool = true,
    /// File the driver pipeline cache is persisted to.
    pipeline_cache_path: ?[]const u8 = null,
    /// Name objects and label passes for debuggers, without validation.
    debug_names: bool = false,
    /// Prefer an HDR10 surface (10-bit, PQ, Rec.2020) when there is one.
    hdr_output: bool = false,
};

/// `unorm` reads as 0..1; `srgb` is decoded to linear when sampled and
/// encoded when written.
pub const Format = enum {
    r8_unorm,
    rg8_unorm,
    rgba8_unorm,
    rgba8_srgb,
    bgra8_unorm,
    bgra8_srgb,
    rg16_unorm,
    rgba16_unorm,
    r16_float,
    rg16_float,
    rgba16_float,
    rgba32_float,
    r32_float,
    r32_uint,
    r8_uint,
    /// Unsigned floats, 11/11/10 bits, no alpha.
    b10g11r11_float,
    /// The HDR10 backbuffer format.
    a2b10g10r10_unorm,
    depth16_unorm,
    depth32_float,
    /// RGBA, 8 bits per texel. Needs `Device.bc_textures`.
    bc7_unorm,
    bc7_srgb,
    /// Red and green, 8 bits per texel. Needs `Device.bc_textures`.
    bc5_unorm,
    /// Red, 4 bits per texel. Needs `Device.bc_textures`.
    bc4_unorm,
    /// From KTX2 files: opaque color at 4 bits per texel, color with alpha
    /// at 8, HDR color at 8.
    bc1_unorm,
    bc1_srgb,
    bc3_unorm,
    bc3_srgb,
    bc6h_ufloat,

    pub fn isDepth(self: Format) bool {
        return self == .depth16_unorm or self == .depth32_float;
    }

    pub fn isSrgb(self: Format) bool {
        return self == .rgba8_srgb or self == .bgra8_srgb or self == .bc7_srgb or self == .bc1_srgb or self == .bc3_srgb;
    }

    /// BC formats: sampled and uploaded, but not rendered to or read back.
    pub fn isBlockCompressed(self: Format) bool {
        return switch (self) {
            .bc7_unorm, .bc7_srgb, .bc5_unorm, .bc4_unorm, .bc1_unorm, .bc1_srgb, .bc3_unorm, .bc3_srgb, .bc6h_ufloat => true,
            else => false,
        };
    }

    /// Bytes of one mip level of the given size.
    pub fn dataSize(self: Format, width: u32, height: u32) u64 {
        if (self.isBlockCompressed()) return @as(u64, (width + 3) / 4) * ((height + 3) / 4) * @as(u64, if (self == .bc4_unorm or self == .bc1_unorm or self == .bc1_srgb) 8 else 16);
        return @as(u64, width) * height * self.bytesPerPixel();
    }

    /// Illegal for block-compressed formats; use `dataSize`.
    pub fn bytesPerPixel(self: Format) u32 {
        return switch (self) {
            .r8_unorm, .r8_uint => 1,
            .rg8_unorm, .r16_float, .depth16_unorm => 2,
            .rgba8_unorm, .rgba8_srgb, .bgra8_unorm, .bgra8_srgb, .rg16_unorm, .rg16_float => 4,
            .r32_float, .r32_uint, .b10g11r11_float, .a2b10g10r10_unorm, .depth32_float => 4,
            .rgba16_unorm, .rgba16_float => 8,
            .rgba32_float => 16,
            .bc7_unorm, .bc7_srgb, .bc5_unorm, .bc4_unorm, .bc1_unorm, .bc1_srgb, .bc3_unorm, .bc3_srgb, .bc6h_ufloat => unreachable,
        };
    }
};

/// Cannot be changed after creation.
pub const TextureUsage = packed struct(u8) {
    /// Gets a bindless slot; see `Device.textureIndex`.
    sampled: bool = false,
    color_attachment: bool = false,
    /// Needs a depth format.
    depth_attachment: bool = false,
    /// Implied when the texture has more than one mip level.
    copy_src: bool = false,
    /// Implied when the texture has more than one mip level.
    copy_dst: bool = false,
    /// Storage image for compute shaders; see `Device.storageIndex`. Needs
    /// `Device.storage_images`.
    storage: bool = false,
    /// Usable as `RenderingDesc.shading_rate`. Needs
    /// `Device.shading_rate_tile`.
    shading_rate: bool = false,
    _padding: u1 = 0,
};

/// Cube faces are in the order +X, -X, +Y, -Y, +Z, -Z. Rendering targets
/// one layer or face at a time.
pub const TextureKind = enum { @"2d", @"2d_array", cube };

/// Textures are 2D, single-sampled and device-local.
pub const TextureDesc = struct {
    /// Debug name, shown when `DeviceDesc.debug_names` or validation is on.
    name: [:0]const u8 = "texture",
    /// Size of mip 0 in texels; not zero.
    width: u32,
    height: u32,
    format: Format,
    usage: TextureUsage,
    /// 1 to 16. Mips above 0 start empty: upload them or call
    /// `Device.generateMips`.
    mip_levels: u32 = 1,
    /// Cube textures always have six.
    layers: u32 = 1,
    kind: TextureKind = .@"2d",

    /// Levels in a complete mip chain down to 1x1.
    pub fn fullMipCount(width: u32, height: u32) u32 {
        return std.math.log2_int(u32, @max(width, height, 1)) + 1;
    }
};

/// Every buffer can also be addressed through `Device.bufferAddress`.
pub const BufferUsage = packed struct(u8) {
    /// Storage buffer binding; not needed for access by address.
    storage: bool = false,
    index: bool = false,
    vertex: bool = false,
    /// Holds indirect draw commands or counts.
    indirect: bool = false,
    /// Needed by `copyBuffer` sources, `Device.readBuffer` and queued copies.
    copy_src: bool = false,
    /// Always set by the device.
    copy_dst: bool = false,
    /// Read by acceleration-structure builds.
    acceleration_input: bool = false,
    /// Backing storage of an acceleration structure.
    acceleration_storage: bool = false,
};

pub const BufferMemory = enum {
    /// Device-local; filled through `Device.uploadBuffer`.
    gpu,
    /// Persistently mapped; write through `Device.mapped`.
    cpu_to_gpu,
    /// Persistently mapped; for reading results back.
    gpu_to_cpu,
};

pub const BufferDesc = struct {
    name: [:0]const u8 = "buffer",
    /// In bytes; not zero.
    size: u64,
    usage: BufferUsage,
    memory: BufferMemory = .gpu,
};

pub const Filter = enum { nearest, linear };
/// The border of `clamp_to_border` is opaque white.
pub const AddressMode = enum { repeat, mirrored_repeat, clamp_to_edge, clamp_to_border };
/// The test passes when `new <op> stored` holds.
pub const CompareOp = enum { never, less, equal, less_or_equal, greater, not_equal, greater_or_equal, always };

pub const SamplerDesc = struct {
    min_filter: Filter = .linear,
    mag_filter: Filter = .linear,
    mip_filter: Filter = .linear,
    address_u: AddressMode = .repeat,
    address_v: AddressMode = .repeat,
    address_w: AddressMode = .repeat,
    /// 1 turns anisotropic filtering off; clamped to the device limit.
    max_anisotropy: f32 = 1,
    /// Makes this a depth-comparison (shadow) sampler.
    compare: ?CompareOp = null,
    /// 0 restricts sampling to mip 0.
    max_lod: f32 = 1000,
};

/// Front faces wind counter-clockwise.
pub const CullMode = enum { none, front, back };
pub const Topology = enum { triangle_list, line_list };

/// `src` is the fragment output, `dst` the target, `a` the source alpha.
pub const BlendMode = enum {
    none,
    /// src * a + dst * (1 - a).
    alpha,
    /// Premultiplied: src + dst * (1 - a).
    premultiplied,
    /// min(src, dst) per channel.
    minimum,
    /// max(src, dst) per channel.
    maximum,
    /// Color: dst * src. Alpha: min(src, dst).
    tint,
    /// dst * (1 - src).
    revealage,
    /// src * (1 - dst.a) + dst, for front-to-back accumulation.
    under,
    /// src + dst.
    additive,
};

/// `unorm8x4` is four bytes read as 0..1; `uint1` is one 32-bit unsigned.
pub const VertexFormat = enum { float2, float3, float4, unorm8x4, uint1 };

pub const VertexAttribute = struct {
    /// The `layout(location = n)` of the shader input.
    location: u32,
    /// Byte offset from the start of the vertex.
    offset: u32,
    format: VertexFormat,
};

/// One per-vertex buffer binding with at most 16 attributes.
pub const VertexLayout = struct {
    /// Bytes from one vertex to the next.
    stride: u32,
    attributes: []const VertexAttribute,
};

pub const DepthState = struct {
    format: Format = .depth32_float,
    @"test": bool = true,
    write: bool = true,
    /// Reverse-Z: nearer fragments have larger depth.
    compare: CompareOp = .greater,
    bias: ?struct { constant: f32, slope: f32 } = null,
    /// Clamp instead of clipping against the near/far planes.
    clamp: bool = false,
};

pub const ColorTarget = struct {
    /// Must match the texture given to `beginRendering`.
    format: Format,
    blend: BlendMode = .none,
};

/// The slices are only read during the call.
pub const GraphicsPipelineDesc = struct {
    name: [:0]const u8 = "graphics pipeline",
    /// SPIR-V bytes, entry point `main`.
    vertex: []const u8,
    /// Null for depth-only pipelines.
    fragment: ?[]const u8 = null,
    /// Mesh shader replacing `vertex`, and its task shader; drawn with
    /// `CommandEncoder.drawMeshTasksIndirect`. Needs `Device.mesh_shaders`.
    mesh: ?[]const u8 = null,
    task: ?[]const u8 = null,
    /// In attachment order; at most 8.
    color_targets: []const ColorTarget = &.{},
    /// Null for no depth test or write.
    depth: ?DepthState = null,
    cull: CullMode = .back,
    topology: Topology = .triangle_list,
    /// Null for shaders that pull vertices through buffer addresses.
    vertex_layout: ?VertexLayout = null,
    /// Fragment shader specialization constants, by constant id from 0.
    fragment_constants: []const u32 = &.{},
};

pub const ComputePipelineDesc = struct {
    name: [:0]const u8 = "compute pipeline",
    /// SPIR-V bytes, entry point `main`.
    shader: []const u8,
};

/// What a texture is about to be used for; the encoder derives layout
/// transitions from changes of state.
pub const TextureState = enum {
    /// Initial state; transitioning away discards the contents.
    undefined,
    shader_read,
    /// Set by `beginRendering`.
    color_attachment,
    /// Set by `beginRendering`.
    depth_attachment,
    copy_src,
    copy_dst,
    storage,
    /// Set by `beginRendering`.
    shading_rate,
    /// Backbuffer only; set by the device on submit.
    present,
};

/// `discard` leaves the contents undefined.
pub const LoadOp = enum { load, clear, discard };

/// Contents are always stored.
pub const ColorAttachment = struct {
    texture: Texture,
    mip: u32 = 0,
    layer: u32 = 0,
    load: LoadOp = .clear,
    clear: [4]f32 = .{ 0, 0, 0, 0 },
    /// Clear value for `*_uint` formats.
    clear_uint: [4]u32 = .{ 0, 0, 0, 0 },
};

pub const DepthAttachment = struct {
    texture: Texture,
    mip: u32 = 0,
    layer: u32 = 0,
    load: LoadOp = .clear,
    /// With reverse-Z, 0 is the far plane.
    clear: f32 = 0,
    /// False lets the driver skip writing depth back.
    store: bool = true,
    /// Reserved; not read by the encoder.
    read_only: bool = false,
};

/// All attachments must have the same size at the chosen mip.
pub const RenderingDesc = struct {
    /// At most 8, in the order of `GraphicsPipelineDesc.color_targets`.
    color: []const ColorAttachment = &.{},
    depth: ?DepthAttachment = null,
    /// An `r8_uint` texture of `shadingRate` values, one texel per
    /// `Device.shading_rate_tile` pixels each way. Null shades every pixel.
    shading_rate: ?Texture = null,
};

/// Shading rate texel value for fragments of `width` by `height` pixels,
/// each 1, 2 or 4.
pub fn shadingRate(width: u32, height: u32) u8 {
    return @intCast((std.math.log2_int(u32, width) << 2) | std.math.log2_int(u32, height));
}

/// Coarse buffer synchronization points; buffers are not tracked
/// individually.
pub const BufferSync = enum {
    /// Compute writes become visible to every later stage.
    compute_to_all,
    /// Copies/fills become visible to every later stage.
    transfer_to_all,
    /// Everything settles before transfer reads.
    all_to_transfer,
};

pub const IndexType = enum { uint16, uint32 };

/// From `Device.textureInfo`.
pub const TextureInfo = struct {
    width: u32,
    height: u32,
    format: Format,
    mip_levels: u32,
    /// 6 for cube textures.
    layers: u32,
    kind: TextureKind,
};

/// GPU time of one `CommandEncoder.beginScope` region.
pub const PassTiming = struct {
    /// The string given to `beginScope`; not copied.
    name: []const u8,
    milliseconds: f32,
    /// Nesting level; sum only depth 0 for a frame total.
    depth: u8,
};

pub const AdapterKind = enum {
    discrete,
    integrated,
    virtual,
    /// A CPU rasterizer, such as Mesa's lavapipe.
    software,
    other,
};

/// From `Device.adapterInfo`.
pub const AdapterInfo = struct {
    kind: AdapterKind,
    /// PCI vendor identifier: 0x10de NVIDIA, 0x1002 AMD, 0x8086 Intel.
    vendor_id: u32,
    /// Sum of the GPU's own memory heaps; for an integrated GPU a share of
    /// system memory.
    memory_bytes: u64,
    ray_tracing: bool,
};

/// Device memory managed by the RHI.
pub const MemoryStats = struct {
    /// Bytes reserved from the driver.
    reserved_bytes: u64,
    /// Bytes handed out to live resources.
    used_bytes: u64,
};

/// Positions are three floats at the start of each vertex.
pub const BlasDesc = struct {
    /// Needs `acceleration_input` usage.
    vertices: Buffer,
    vertex_offset: u64 = 0,
    /// Number of vertices the indices may refer to.
    vertex_count: u32,
    vertex_stride: u32,
    /// 32-bit indices.
    indices: Buffer,
    index_offset: u64 = 0,
    /// Three per triangle.
    index_count: u32,
    /// Rebuilt every frame: built for speed, scratch memory kept.
    dynamic: bool = false,
};

/// Layout of `VkAccelerationStructureInstanceKHR`.
pub const AccelerationInstance = extern struct {
    /// Row-major 3x4 object-to-world transform.
    transform: [12]f32,
    /// Low 24 bits: custom index returned to shaders. High 8 bits: mask.
    custom_index_and_mask: u32,
    /// Low 24 bits: shader binding offset (unused). High 8 bits: flags.
    offset_and_flags: u32 = 0,
    /// Device address of the bottom-level structure.
    blas: u64,
};
