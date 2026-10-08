#ifndef LIMN_FFX_H
#define LIMN_FFX_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct LimnFfx LimnFfx;

typedef struct LimnFfxCreate {
    void* physical_device;
    void* device;
    void* get_device_proc_addr;
    uint64_t pipeline_cache;
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
    void* command_buffer;
    LimnFfxImage color;
    LimnFfxImage depth;
    LimnFfxImage motion;
    LimnFfxImage output;
    float jitter[2];
    float motion_scale[2];
    uint32_t render_width;
    uint32_t render_height;
    float sharpness;
    float frame_milliseconds;
    float camera_near;
    float camera_fov_y;
    uint32_t reset;
} LimnFfxFrame;

typedef struct LimnFfxGenerate {
    void* command_buffer;
    LimnFfxImage shown;
    LimnFfxImage output;
    uint32_t pq;
    uint32_t reset;
} LimnFfxGenerate;

LimnFfx* limnFfxCreate(const LimnFfxCreate* desc);
int32_t limnFfxDispatch(LimnFfx* ffx, const LimnFfxFrame* frame);
int32_t limnFfxGenerateFrame(LimnFfx* ffx, const LimnFfxGenerate* frame);
void limnFfxDestroy(LimnFfx* ffx);

#ifdef __cplusplus
}
#endif

#endif
