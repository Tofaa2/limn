#ifndef LIMN_DLSS_H
#define LIMN_DLSS_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct LimnDlss LimnDlss;

#define LIMN_DLSS_SUPER_RESOLUTION 1u
#define LIMN_DLSS_RAY_RECONSTRUCTION 2u

typedef struct LimnDlssStart {
    void* instance;
    void* physical_device;
    void* device;
    void* get_instance_proc_addr;
    void* get_device_proc_addr;
    const char* library_directory;
    const char* data_directory;
    uint32_t logging;
} LimnDlssStart;

typedef struct LimnDlssCreate {
    void* device;
    void* command_buffer;
    uint32_t feature;
    uint32_t render_width;
    uint32_t render_height;
    uint32_t output_width;
    uint32_t output_height;
} LimnDlssCreate;

typedef struct LimnDlssImage {
    uint64_t image;
    uint64_t view;
    int32_t format;
    uint32_t width;
    uint32_t height;
} LimnDlssImage;

typedef struct LimnDlssFrame {
    void* command_buffer;
    LimnDlssImage color;
    LimnDlssImage depth;
    LimnDlssImage motion;
    LimnDlssImage output;
    LimnDlssImage diffuse_albedo;
    LimnDlssImage specular_albedo;
    LimnDlssImage normal_roughness;
    float jitter[2];
    float motion_scale[2];
    float world_to_view[16];
    float view_to_clip[16];
    float frame_milliseconds;
    uint32_t reset;
} LimnDlssFrame;

uint32_t limnDlssStart(const LimnDlssStart* desc);
void limnDlssStop(void* device);
LimnDlss* limnDlssCreate(const LimnDlssCreate* desc);
int32_t limnDlssDispatch(LimnDlss* dlss, const LimnDlssFrame* frame);
void limnDlssDestroy(LimnDlss* dlss);

#ifdef __cplusplus
}
#endif

#endif
