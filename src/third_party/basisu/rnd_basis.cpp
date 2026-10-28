// The renderer's way into the Basis Universal transcoder: a KTX2 file held
// in memory is opened, described, and turned level by level into BC7 (or
// BC6H for high dynamic range). See src/asset/ktx2.zig.
#include "transcoder/basisu_transcoder.h"

#include <mutex>
#include <new>

extern "C" {

// On success returns a handle and fills `info` with width, height, levels,
// layers, faces, whether the pixels are high dynamic range, whether they
// are sRGB and whether there is an alpha channel. Null if the file is not
// one the transcoder reads. `data` must outlive the handle.
void* rnd_basis_open(const void* data, uint32_t size, uint32_t* info) {
    static std::once_flag once;
    std::call_once(once, [] { basist::basisu_transcoder_init(); });
    basist::ktx2_transcoder* transcoder = new (std::nothrow) basist::ktx2_transcoder();
    if (!transcoder) return nullptr;
    if (!transcoder->init(data, size) || !transcoder->start_transcoding()) {
        delete transcoder;
        return nullptr;
    }
    info[0] = transcoder->get_width();
    info[1] = transcoder->get_height();
    info[2] = transcoder->get_levels();
    info[3] = transcoder->get_layers();
    info[4] = transcoder->get_faces();
    info[5] = transcoder->is_hdr() ? 1 : 0;
    info[6] = transcoder->is_srgb() ? 1 : 0;
    info[7] = transcoder->get_has_alpha() ? 1 : 0;
    return transcoder;
}

// Writes one image of one level as 16-byte blocks (BC7, or BC6H when
// `hdr`); `blocks` is how many `out` has room for. Returns 0 on failure.
// target: 0 BC7, 1 BC6H, 2 ASTC 4x4, 3 RGBA8 texels, 4 RGBA16F texels. `units`
// counts blocks, or texels for the last two.
int rnd_basis_level(void* handle, uint32_t level, uint32_t layer, uint32_t face, void* out, uint32_t units, int target) {
    basist::ktx2_transcoder* transcoder = static_cast<basist::ktx2_transcoder*>(handle);
    basist::transcoder_texture_format format = basist::transcoder_texture_format::cTFBC7_RGBA;
    switch (target) {
        case 1: format = basist::transcoder_texture_format::cTFBC6H; break;
        case 2: format = basist::transcoder_texture_format::cTFASTC_4x4_RGBA; break;
        case 3: format = basist::transcoder_texture_format::cTFRGBA32; break;
        case 4: format = basist::transcoder_texture_format::cTFRGBA_HALF; break;
        default: break;
    }
    return transcoder->transcode_image_level(level, layer, face, out, units, format) ? 1 : 0;
}

void rnd_basis_close(void* handle) {
    delete static_cast<basist::ktx2_transcoder*>(handle);
}

}
