#ifndef LIMN_NRD_H
#define LIMN_NRD_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct LimnNrd LimnNrd;

typedef struct LimnNrdCreate {
    void* instance;
    void* physical_device;
    void* device;
    void* get_instance_proc_addr;
    void* get_device_proc_addr;
    uint32_t width;
    uint32_t height;
} LimnNrdCreate;

/* Image views of the textures a frame is denoised from and into. Inputs are
   in `input_layout`, outputs in VK_IMAGE_LAYOUT_GENERAL. */
typedef struct LimnNrdFrame {
    void* command_buffer;
    uint64_t motion;
    uint64_t normal_roughness;
    uint64_t view_depth;
    uint64_t diffuse;
    uint64_t specular;
    uint64_t diffuse_out;
    uint64_t specular_out;
    int32_t input_layout;
    uint32_t frame_index;
    uint32_t reset;
    float frame_milliseconds;
    /* Most frames of history kept, the fewest for what changes fast, and the
       radius in pixels of the blur ahead of gathering (0 for none). */
    uint32_t history_frames;
    uint32_t fast_history_frames;
    float blur_radius;
    float pad;
    float motion_scale[2];
    float jitter[2];
    float jitter_previous[2];
    float view_to_clip[16];
    float view_to_clip_previous[16];
    float world_to_view[16];
    float world_to_view_previous[16];
} LimnNrdFrame;

LimnNrd* limnNrdCreate(const LimnNrdCreate* desc);
int32_t limnNrdDispatch(LimnNrd* nrd, const LimnNrdFrame* frame);
void limnNrdDestroy(LimnNrd* nrd);

#ifdef __cplusplus
}
#endif

#endif
