// C interface to the FidelityFX SDK's FSR 2 and FSR 3 upscalers and FSR 3
// frame generation.
// Mirrored in ffx.zig.
#ifndef LIMN_FFX_H
#define LIMN_FFX_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct LimnFfx LimnFfx;

typedef struct LimnFfxCreate {
    // VkPhysicalDevice, VkDevice and vkGetDeviceProcAddr.
    void* physical_device;
    void* device;
    void* get_device_proc_addr;
    // 2 for FSR 2, 3 for the upscaler of FSR 3.
    uint32_t generation;
    uint32_t render_width;
    uint32_t render_height;
    uint32_t output_width;
    uint32_t output_height;
} LimnFfxCreate;

typedef struct LimnFfxImage {
    uint64_t image;
    int32_t format;
    uint32_t width;
    uint32_t height;
} LimnFfxImage;

typedef struct LimnFfxFrame {
    // VkCommandBuffer.
    void* command_buffer;
    // HDR color before tone mapping, reverse-Z depth with infinite far plane
    // and motion vectors at render size; output at display size. All in the
    // shader-read layout, and left in it.
    LimnFfxImage color;
    LimnFfxImage depth;
    LimnFfxImage motion;
    LimnFfxImage output;
    // Subpixel jitter, in pixels.
    float jitter[2];
    // Multiplies motion vectors to give pixels.
    float motion_scale[2];
    uint32_t render_width;
    uint32_t render_height;
    // 0 (none) to 1.
    float sharpness;
    float frame_milliseconds;
    float camera_near;
    float camera_fov_y;
    // Nonzero discards the history.
    uint32_t reset;
} LimnFfxFrame;

typedef struct LimnFfxGenerate {
    // VkCommandBuffer.
    void* command_buffer;
    // This frame's finished picture and where the one before it in time
    // goes. Same size, UNORM formats, shader-read layout and left in it.
    LimnFfxImage shown;
    LimnFfxImage output;
    // Nonzero when `shown` is PQ encoded; sRGB encoded otherwise.
    uint32_t pq;
    // Nonzero discards the history.
    uint32_t reset;
} LimnFfxGenerate;

// Null if the SDK would not start on this device.
LimnFfx* limnFfxCreate(const LimnFfxCreate* desc);
// Returns 0 on success.
int32_t limnFfxDispatch(LimnFfx* ffx, const LimnFfxFrame* frame);
// FSR 3 only, after `limnFfxDispatch` in the same frame. Returns 1 when
// `output` was written, 0 when there is nothing to show, negative on failure.
int32_t limnFfxGenerateFrame(LimnFfx* ffx, const LimnFfxGenerate* frame);
// The device must have finished with everything dispatched.
void limnFfxDestroy(LimnFfx* ffx);

#ifdef __cplusplus
}
#endif

#endif
