//! Plain-data descriptions used by the RHI. Nothing here touches Vulkan.
const std = @import("std");
const builtin = @import("builtin");
const Handle = @import("../handle.zig").Handle;

/// Type tags that keep handles of different resources from being mixed up
/// at compile time. They are never instantiated.
pub const BufferTag = opaque {};
/// See `BufferTag`.
pub const TextureTag = opaque {};
/// See `BufferTag`.
pub const SamplerTag = opaque {};
/// See `BufferTag`.
pub const PipelineTag = opaque {};
/// See `BufferTag`.
pub const AccelerationTag = opaque {};
/// A ray-tracing acceleration structure (bottom or top level).
pub const AccelerationStructure = Handle(AccelerationTag);
/// Generation-checked handle to a GPU buffer, from `Device.createBuffer`.
/// Four bytes, freely copyable; it goes stale when the buffer is destroyed.
pub const Buffer = Handle(BufferTag);
/// Generation-checked handle to a texture, from `Device.createTexture` or
/// `Frame.backbuffer`. Goes stale when the texture is destroyed; backbuffer
/// handles also go stale whenever the swapchain is rebuilt.
pub const Texture = Handle(TextureTag);
/// Generation-checked handle to a sampler, from `Device.createSampler`.
pub const Sampler = Handle(SamplerTag);
/// Generation-checked handle to a graphics or compute pipeline.
pub const Pipeline = Handle(PipelineTag);

/// The platform window to present to. The pointers are borrowed: the window
/// must outlive the device.
pub const NativeWindow = union(enum) {
    /// Xlib `Display*` and `Window` id.
    xlib: struct { display: *anyopaque, window: usize },
    /// Wayland `wl_display*` and `wl_surface*`.
    wayland: struct { display: *anyopaque, surface: *anyopaque },
    /// Win32 `HINSTANCE` (may be null) and `HWND`.
    win32: struct { instance: ?*anyopaque, window: *anyopaque },
};

/// Presentation target handed to `Device.init`.
pub const Surface = struct {
    window: NativeWindow,
    /// Initial framebuffer size in pixels, not window units. Follow later
    /// changes with `Device.resize`. The swapchain uses the size the window
    /// system reports when it reports one.
    width: u32,
    height: u32,
    /// Wait for vertical blank (FIFO). When false, presents immediately
    /// (tearing) if the surface allows it, else in mailbox mode, else it
    /// still waits. Change later with `Device.setVsync`.
    vsync: bool = true,
};

/// Options for `Device.init`. The defaults give a headless device with
/// validation in debug builds.
pub const DeviceDesc = struct {
    /// Reported to the driver as the application name.
    application_name: [:0]const u8 = "limn",
    /// Khronos validation plus synchronization validation. Meant for
    /// development builds; requires the validation layers to be installed.
    validation: bool = builtin.mode == .Debug,
    /// Substring of the adapter name to prefer, for multi-GPU machines.
    preferred_device: ?[]const u8 = null,
    /// Present to a window. Leave null for headless/offscreen use.
    surface: ?Surface = null,
    /// Enable ray queries when the adapter supports them; check
    /// `Device.ray_tracing` afterwards.
    ray_tracing: bool = true,
    /// File used to persist the driver pipeline cache between runs.
    pipeline_cache_path: ?[]const u8 = null,
    /// Name GPU objects and label passes for debuggers such as RenderDoc,
    /// without the cost of validation.
    debug_names: bool = false,
    /// Prefer an HDR10 surface (10-bit, PQ, Rec.2020) when there is one.
    hdr_output: bool = false,
};

/// Texture and attachment formats. `unorm` channels read as 0..1, `srgb`
/// ones are decoded to linear when sampled and encoded when written, and
/// `float` ones are stored as is.
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
    /// Four 32-bit floats: for sums that 16 bits would round away.
    rgba32_float,
    r32_float,
    r32_uint,
    /// Packed unsigned floats, 11/11/10 bits, no alpha, no negative values.
    b10g11r11_float,
    /// Packed 10-bit color with 2-bit alpha; the HDR10 backbuffer format.
    a2b10g10r10_unorm,
    /// Depth formats, for depth attachments and shadow maps.
    depth16_unorm,
    depth32_float,
    /// Block-compressed RGBA, 8 bits per texel. Needs `Device.bc_textures`.
    bc7_unorm,
    bc7_srgb,
    /// Block-compressed red and green, 8 bits per texel. Needs
    /// `Device.bc_textures`.
    bc5_unorm,
    /// Block-compressed red, 4 bits per texel. Needs `Device.bc_textures`.
    bc4_unorm,
    /// Older block formats, read from KTX2 files: opaque color at 4 bits
    /// per texel, color with alpha at 8, and HDR color at 8.
    bc1_unorm,
    bc1_srgb,
    bc3_unorm,
    bc3_srgb,
    bc6h_ufloat,

    /// True for the formats usable as a depth attachment.
    pub fn isDepth(self: Format) bool {
        return self == .depth16_unorm or self == .depth32_float;
    }

    /// True when the format stores sRGB-encoded color.
    pub fn isSrgb(self: Format) bool {
        return self == .rgba8_srgb or self == .bgra8_srgb or self == .bc7_srgb or self == .bc1_srgb or self == .bc3_srgb;
    }

    /// True for the BC formats, which are stored as 4x4 texel blocks. They
    /// can be sampled and uploaded but not rendered to or read back.
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

    /// Bytes of one texel. Not defined for block-compressed formats (use
    /// `dataSize`); asking for one is illegal behavior.
    pub fn bytesPerPixel(self: Format) u32 {
        return switch (self) {
            .r8_unorm => 1,
            .rg8_unorm, .r16_float, .depth16_unorm => 2,
            .rgba8_unorm, .rgba8_srgb, .bgra8_unorm, .bgra8_srgb, .rg16_unorm, .rg16_float => 4,
            .r32_float, .r32_uint, .b10g11r11_float, .a2b10g10r10_unorm, .depth32_float => 4,
            .rgba16_unorm, .rgba16_float => 8,
            .rgba32_float => 16,
            .bc7_unorm, .bc7_srgb, .bc5_unorm, .bc4_unorm, .bc1_unorm, .bc1_srgb, .bc3_unorm, .bc3_srgb, .bc6h_ufloat => unreachable,
        };
    }
};

/// What a texture may be used for. Set everything the texture will ever
/// need; usage cannot be changed after creation.
pub const TextureUsage = packed struct(u8) {
    /// Read in shaders. Gives the texture a slot in the bindless table,
    /// see `Device.textureIndex`.
    sampled: bool = false,
    /// Bound as a color attachment in `CommandEncoder.beginRendering`.
    color_attachment: bool = false,
    /// Bound as the depth attachment; needs a depth format.
    depth_attachment: bool = false,
    /// Source of copies and blits, e.g. `Device.readTexture`. Implied when
    /// the texture has more than one mip level.
    copy_src: bool = false,
    /// Destination of copies and blits, e.g. `Device.uploadTexture`. Implied
    /// when the texture has more than one mip level.
    copy_dst: bool = false,
    _padding: u3 = 0,
};

/// How shaders see the layers: a single image, an array indexed by layer,
/// or six faces in the order +X, -X, +Y, -Y, +Z, -Z. Rendering always
/// targets one layer (or face) at a time.
pub const TextureKind = enum { @"2d", @"2d_array", cube };

/// Description of a texture for `Device.createTexture`. Textures are
/// two-dimensional, single-sampled and live in device-local memory.
pub const TextureDesc = struct {
    /// Debug name, shown by RenderDoc and validation messages when
    /// `DeviceDesc.debug_names` or validation is on.
    name: [:0]const u8 = "texture",
    /// Size of mip 0 in texels. Must not be zero.
    width: u32,
    height: u32,
    format: Format,
    usage: TextureUsage,
    /// Levels in the mip chain, from 1 to 16. The levels below 0 start
    /// empty: upload them or call `Device.generateMips`.
    mip_levels: u32 = 1,
    /// Array layers. Cube textures always have six.
    layers: u32 = 1,
    /// See `TextureKind`.
    kind: TextureKind = .@"2d",

    /// Levels in a complete mip chain, down to 1x1, for a texture this size.
    pub fn fullMipCount(width: u32, height: u32) u32 {
        return std.math.log2_int(u32, @max(width, height, 1)) + 1;
    }
};

/// What a buffer may be used for. Every buffer can additionally be
/// addressed from shaders through `Device.bufferAddress`.
pub const BufferUsage = packed struct(u8) {
    /// Usable as a storage buffer. Access through a buffer address works
    /// without it.
    storage: bool = false,
    /// Bound with `CommandEncoder.bindIndexBuffer`.
    index: bool = false,
    /// Bound with `CommandEncoder.bindVertexBuffer`.
    vertex: bool = false,
    /// Holds draw commands or the draw count of an indirect draw.
    indirect: bool = false,
    /// Source of `copyBuffer`, `Device.readBuffer` and queued copies.
    copy_src: bool = false,
    /// Destination of copies and fills. Every buffer is created with this,
    /// so it need not be set.
    copy_dst: bool = false,
    /// Read by acceleration-structure builds (vertices, indices, instances).
    acceleration_input: bool = false,
    /// Backing storage of an acceleration structure.
    acceleration_storage: bool = false,
};

/// Where a buffer's memory lives and how the CPU reaches it.
pub const BufferMemory = enum {
    /// Lives in VRAM; filled through `Device.uploadBuffer`.
    gpu,
    /// Persistently mapped; write through `Device.mapped`.
    cpu_to_gpu,
    /// Persistently mapped; for reading results back.
    gpu_to_cpu,
};

/// Description of a buffer for `Device.createBuffer`.
pub const BufferDesc = struct {
    /// Debug name, see `TextureDesc.name`.
    name: [:0]const u8 = "buffer",
    /// Size in bytes. Must not be zero.
    size: u64,
    usage: BufferUsage,
    memory: BufferMemory = .gpu,
};

/// Texel filtering: nearest texel, or linear interpolation between
/// neighbours (between mip levels for `SamplerDesc.mip_filter`).
pub const Filter = enum { nearest, linear };
/// What sampling outside 0..1 returns. The border of `clamp_to_border` is
/// opaque white.
pub const AddressMode = enum { repeat, mirrored_repeat, clamp_to_edge, clamp_to_border };
/// Comparison of a new value against the stored one: the incoming fragment
/// depth against the depth buffer, or the shader's reference against the
/// texel for comparison samplers. The test passes when
/// `new <op> stored` holds.
pub const CompareOp = enum { never, less, equal, less_or_equal, greater, not_equal, greater_or_equal, always };

/// Description of a sampler for `Device.createSampler`. Samplers are
/// separate from textures; shaders combine the two by index.
pub const SamplerDesc = struct {
    /// Filter used when the texture is minified.
    min_filter: Filter = .linear,
    /// Filter used when the texture is magnified.
    mag_filter: Filter = .linear,
    /// Blend between mip levels (`linear`, trilinear filtering) or pick the
    /// nearest one.
    mip_filter: Filter = .linear,
    /// Addressing along each texture axis.
    address_u: AddressMode = .repeat,
    address_v: AddressMode = .repeat,
    address_w: AddressMode = .repeat,
    /// Maximum anisotropy. 1 turns anisotropic filtering off; larger values
    /// are clamped to what the device supports.
    max_anisotropy: f32 = 1,
    /// Set to make this a depth-comparison (shadow) sampler.
    compare: ?CompareOp = null,
    /// Largest level of detail sampled. 0 restricts sampling to mip 0; the
    /// default does not limit it.
    max_lod: f32 = 1000,
};

/// Which triangle faces are discarded. Front faces wind counter-clockwise.
pub const CullMode = enum { none, front, back };
/// How vertices are assembled into primitives.
pub const Topology = enum { triangle_list, line_list };

/// How a fragment's color is combined with the color target. `src` is the
/// fragment shader output, `dst` what the target holds and `a` the source
/// alpha. All four channels are always written.
pub const BlendMode = enum {
    /// Overwrite the destination.
    none,
    /// src * a + dst * (1 - a).
    alpha,
    /// Premultiplied: src + dst * (1 - a).
    premultiplied,
    /// min(src, dst) per channel.
    minimum,
    /// max(src, dst) per channel.
    maximum,
    /// Color: dst * src, each layer tinting what passes through it. Alpha:
    /// min(src, dst), which keeps the nearest layer's depth.
    tint,
    /// dst * (1 - src): each layer hides its share of what is behind.
    revealage,
    /// Under: src * (1 - dst.a) + dst. Lays what is drawn behind what is
    /// already there, for front-to-back accumulation.
    under,
    /// src + dst.
    additive,
};

/// Type of a vertex attribute in the vertex buffer: two to four 32-bit
/// floats, four bytes read as 0..1, or one 32-bit unsigned integer.
pub const VertexFormat = enum { float2, float3, float4, unorm8x4, uint1 };

/// One vertex shader input read from the vertex buffer.
pub const VertexAttribute = struct {
    /// The `layout(location = n)` of the shader input.
    location: u32,
    /// Byte offset of the attribute from the start of the vertex.
    offset: u32,
    format: VertexFormat,
};

/// Vertex buffer layout for pipelines that use
/// `CommandEncoder.bindVertexBuffer`. There is one buffer binding,
/// stepped per vertex, with at most 16 attributes.
pub const VertexLayout = struct {
    /// Bytes from one vertex to the next.
    stride: u32,
    attributes: []const VertexAttribute,
};

/// Depth test configuration of a graphics pipeline.
pub const DepthState = struct {
    /// Format of the depth attachment the pipeline is used with.
    format: Format = .depth32_float,
    /// Discard fragments that fail `compare`.
    @"test": bool = true,
    /// Write the depth of fragments that pass.
    write: bool = true,
    /// The renderer uses reverse-Z, so nearer fragments have larger depth.
    compare: CompareOp = .greater,
    /// Constant and slope-scaled bias applied in the rasterizer.
    bias: ?struct { constant: f32, slope: f32 } = null,
    /// Clamp instead of clipping against the near/far planes.
    clamp: bool = false,
};

/// One color output of a graphics pipeline.
pub const ColorTarget = struct {
    /// Format of the attachment bound at this index; it must match the
    /// texture given to `beginRendering`.
    format: Format,
    blend: BlendMode = .none,
};

/// Description of a graphics pipeline for `Device.createGraphicsPipeline`
/// and `Device.compileGraphicsPipeline`. The slices are only read during
/// the call. Viewport and scissor are set on the encoder, not here.
pub const GraphicsPipelineDesc = struct {
    /// Debug name, see `TextureDesc.name`.
    name: [:0]const u8 = "graphics pipeline",
    /// SPIR-V words as bytes, e.g. from `@embedFile`.
    vertex: []const u8,
    /// Fragment shader SPIR-V with entry point `main`. Null for depth-only
    /// pipelines.
    fragment: ?[]const u8 = null,
    /// Color attachments the pipeline draws to, in attachment order. At most
    /// 8.
    color_targets: []const ColorTarget = &.{},
    /// Null for passes without a depth attachment: no depth test or write.
    depth: ?DepthState = null,
    cull: CullMode = .back,
    topology: Topology = .triangle_list,
    /// Null for shaders that pull vertices through buffer addresses.
    vertex_layout: ?VertexLayout = null,
    /// Values for the fragment shader's specialization constants, by
    /// constant id from 0. The shader is compiled as if they were written
    /// into its source, so branches on them cost nothing.
    fragment_constants: []const u32 = &.{},
};

/// Description of a compute pipeline for `Device.createComputePipeline`.
pub const ComputePipelineDesc = struct {
    /// Debug name, see `TextureDesc.name`.
    name: [:0]const u8 = "compute pipeline",
    /// SPIR-V words as bytes, with entry point `main`.
    shader: []const u8,
};

/// How a texture is about to be used. The command encoder turns changes of
/// state into image layout transitions with correct stage/access masks.
pub const TextureState = enum {
    /// Contents are unknown. A texture starts here, and a transition away
    /// from it discards what the texture held.
    undefined,
    /// Sampled in any shader stage.
    shader_read,
    /// Bound as a color attachment; `beginRendering` does this itself.
    color_attachment,
    /// Bound as the depth attachment; `beginRendering` does this itself.
    depth_attachment,
    /// Read by copies and blits.
    copy_src,
    /// Written by copies and blits.
    copy_dst,
    /// Ready to present. Only for the backbuffer; the device does this when
    /// the frame is submitted.
    present,
};

/// What happens to an attachment's contents when a pass begins: keep them,
/// fill with the clear value, or leave them undefined (`discard`, the
/// cheapest, for passes that overwrite every pixel).
pub const LoadOp = enum { load, clear, discard };

/// A color target of one render pass. Its contents are always stored.
pub const ColorAttachment = struct {
    texture: Texture,
    /// Mip level and array layer (or cube face) rendered to.
    mip: u32 = 0,
    layer: u32 = 0,
    load: LoadOp = .clear,
    /// Clear color for `LoadOp.clear`.
    clear: [4]f32 = .{ 0, 0, 0, 0 },
    /// Integer clear value, used for `*_uint` formats.
    clear_uint: [4]u32 = .{ 0, 0, 0, 0 },
};

/// The depth target of one render pass.
pub const DepthAttachment = struct {
    texture: Texture,
    /// Mip level and array layer (or cube face) rendered to.
    mip: u32 = 0,
    layer: u32 = 0,
    load: LoadOp = .clear,
    /// Depth for `LoadOp.clear`. With reverse-Z, 0 is the far plane.
    clear: f32 = 0,
    /// Keep the depth after the pass. Set false when nothing reads it later,
    /// which lets the driver skip writing it back.
    store: bool = true,
    /// Reserved. The encoder does not read it yet: the attachment is always
    /// bound writable, and the pipeline's `DepthState.write` decides.
    read_only: bool = false,
};

/// Attachments of one `CommandEncoder.beginRendering` pass. All of them
/// must have the same size at the chosen mip; the pass covers all of it.
pub const RenderingDesc = struct {
    /// At most 8, in the order of `GraphicsPipelineDesc.color_targets`.
    color: []const ColorAttachment = &.{},
    depth: ?DepthAttachment = null,
};

/// Coarse buffer synchronization points. Buffers are not tracked
/// individually; passes that hand buffer data to later passes declare it.
pub const BufferSync = enum {
    /// Compute writes become visible to draws, indirect arguments, compute
    /// and copies out of the buffer.
    compute_to_all,
    /// Copies/fills become visible to every later stage.
    transfer_to_all,
    /// Everything settles before transfer reads.
    all_to_transfer,
};

/// Width of the indices in an index buffer.
pub const IndexType = enum { uint16, uint32 };

/// Properties of an existing texture, from `Device.textureInfo`.
pub const TextureInfo = struct {
    /// Size of mip 0 in texels.
    width: u32,
    height: u32,
    format: Format,
    mip_levels: u32,
    /// Array layers; 6 for cube textures.
    layers: u32,
    kind: TextureKind,
};

/// GPU time of one `CommandEncoder.beginScope` region, from
/// `Device.passTimings`.
pub const PassTiming = struct {
    /// The string given to `beginScope`; not copied.
    name: []const u8,
    /// GPU time between the start and the end of the region.
    milliseconds: f32,
    /// Nesting level; sum only depth 0 for a frame total.
    depth: u8,
};

/// What kind of GPU a device runs on; see `AdapterInfo.kind`.
pub const AdapterKind = enum {
    /// A graphics card with memory of its own.
    discrete,
    /// Built into the processor and sharing the system's memory.
    integrated,
    /// A GPU handed through by a virtual machine.
    virtual,
    /// A rasterizer running on the CPU, such as Mesa's lavapipe.
    software,
    other,
};

/// The GPU a device was created on, from `Device.adapterInfo`.
pub const AdapterInfo = struct {
    kind: AdapterKind,
    /// PCI vendor identifier: 0x10de NVIDIA, 0x1002 AMD, 0x8086 Intel.
    vendor_id: u32,
    /// Bytes of memory the driver reports as the GPU's own, summed over
    /// its heaps. For an integrated GPU this is a share of system memory.
    memory_bytes: u64,
    /// Ray queries and acceleration structures are available.
    ray_tracing: bool,
};

/// Totals of device memory managed by the RHI, from `Device.memoryStats`.
pub const MemoryStats = struct {
    /// Bytes reserved from the driver.
    reserved_bytes: u64,
    /// Bytes handed out to live resources.
    used_bytes: u64,
};

/// Triangle geometry for a bottom-level acceleration structure. Positions
/// are three floats at the start of each `vertex_stride`-byte vertex.
pub const BlasDesc = struct {
    /// Vertex buffer. Needs `acceleration_input` usage.
    vertices: Buffer,
    /// Byte offset of the first vertex.
    vertex_offset: u64 = 0,
    /// Number of vertices the indices may refer to.
    vertex_count: u32,
    /// Bytes from one vertex to the next.
    vertex_stride: u32,
    /// 32-bit indices.
    indices: Buffer,
    /// Byte offset of the first index.
    index_offset: u64 = 0,
    /// Number of indices, three per triangle.
    index_count: u32,
    /// The geometry changes every frame and the structure is rebuilt each
    /// time: build quickly and keep the scratch memory.
    dynamic: bool = false,
};

/// Layout of `VkAccelerationStructureInstanceKHR`, for filling the instance
/// buffer of a top-level build.
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
