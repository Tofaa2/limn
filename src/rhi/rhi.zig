//! Render hardware interface: a thin, explicit Vulkan 1.3 device layer.
//!
//! ```zig
//! const device = try rhi.Device.init(gpa, io, .{ .surface = surface });
//! defer device.deinit();
//! const pipeline = try device.createGraphicsPipeline(.{ ... });
//! while (running) {
//!     const frame = (try device.beginFrame()) orelse continue;
//!     try frame.cmd.beginRendering(.{ .color = &.{.{ .texture = frame.backbuffer.? }} });
//!     frame.cmd.bindPipeline(pipeline);
//!     frame.cmd.draw(3, 1, 0, 0);
//!     frame.cmd.endRendering();
//!     try device.endFrame();
//! }
//! ```
const types = @import("types.zig");
const device = @import("device.zig");

/// The device: owner of every GPU resource and of the frame loop.
pub const Device = device.Device;
/// What `Device.beginFrame` returns: the encoder and backbuffer of a frame.
pub const Frame = device.Frame;
/// Records draw, compute and copy commands for one frame.
pub const CommandEncoder = @import("command.zig").CommandEncoder;
/// Frames the CPU may record before waiting for the GPU. Destroyed resources
/// are kept alive this many frames.
pub const frames_in_flight = device.frames_in_flight;
/// Bytes of push constants every shader stage of every pipeline can read.
pub const push_constant_size = device.push_constant_size;

/// Handle to a GPU buffer.
pub const Buffer = types.Buffer;
/// Handle to a texture.
pub const Texture = types.Texture;
/// Handle to a sampler.
pub const Sampler = types.Sampler;
/// Handle to a graphics or compute pipeline.
pub const Pipeline = types.Pipeline;
/// Options for `Device.init`.
pub const DeviceDesc = types.DeviceDesc;
/// Window and initial size to present to.
pub const Surface = types.Surface;
/// Native window handles for Xlib, Wayland or Win32.
pub const NativeWindow = types.NativeWindow;
/// Texture and attachment pixel formats.
pub const Format = types.Format;
/// Description of a texture to create.
pub const TextureDesc = types.TextureDesc;
/// Flags for what a texture may be used for.
pub const TextureUsage = types.TextureUsage;
/// Whether a texture is a single image, an array or a cube.
pub const TextureKind = types.TextureKind;
/// Size, format and layout of an existing texture.
pub const TextureInfo = types.TextureInfo;
/// What a texture is about to be used for; drives layout transitions.
pub const TextureState = types.TextureState;
/// Description of a buffer to create.
pub const BufferDesc = types.BufferDesc;
/// Flags for what a buffer may be used for.
pub const BufferUsage = types.BufferUsage;
/// Where a buffer's memory lives: on the GPU or mapped for the CPU.
pub const BufferMemory = types.BufferMemory;
/// Coarse synchronization points between passes that share buffers.
pub const BufferSync = types.BufferSync;
/// Description of a sampler to create.
pub const SamplerDesc = types.SamplerDesc;
/// Nearest or linear texture filtering.
pub const Filter = types.Filter;
/// What sampling outside the 0..1 range returns.
pub const AddressMode = types.AddressMode;
/// Comparison used by depth tests and comparison samplers.
pub const CompareOp = types.CompareOp;
/// Description of a graphics pipeline to create.
pub const GraphicsPipelineDesc = types.GraphicsPipelineDesc;
/// Description of a compute pipeline to create.
pub const ComputePipelineDesc = types.ComputePipelineDesc;
/// Format and blending of one color output of a pipeline.
pub const ColorTarget = types.ColorTarget;
/// Depth test, write, bias and clamp settings of a pipeline.
pub const DepthState = types.DepthState;
/// How a fragment's color is combined with the color target.
pub const BlendMode = types.BlendMode;
/// Which triangle faces are discarded.
pub const CullMode = types.CullMode;
/// Whether vertices form triangles or lines.
pub const Topology = types.Topology;
/// Stride and attributes of a pipeline's vertex buffer.
pub const VertexLayout = types.VertexLayout;
/// One vertex shader input and where it lies in the vertex.
pub const VertexAttribute = types.VertexAttribute;
/// Component type and count of a vertex attribute.
pub const VertexFormat = types.VertexFormat;
/// Color and depth attachments of one render pass.
pub const RenderingDesc = types.RenderingDesc;
/// A color target of a render pass, with its load operation and clear color.
pub const ColorAttachment = types.ColorAttachment;
/// The depth target of a render pass, with its load and store behavior.
pub const DepthAttachment = types.DepthAttachment;
/// Whether an attachment is loaded, cleared or discarded when a pass begins.
pub const LoadOp = types.LoadOp;
/// 16-bit or 32-bit indices.
pub const IndexType = types.IndexType;
/// GPU time of one named region of a frame.
pub const PassTiming = types.PassTiming;
/// Device memory reserved from the driver and in use by resources.
pub const MemoryStats = types.MemoryStats;
/// Handle to a bottom-level or top-level acceleration structure.
pub const AccelerationStructure = types.AccelerationStructure;
/// Triangle geometry for building a bottom-level acceleration structure.
pub const BlasDesc = types.BlasDesc;
/// One instance record of a top-level acceleration structure build.
pub const AccelerationInstance = types.AccelerationInstance;
