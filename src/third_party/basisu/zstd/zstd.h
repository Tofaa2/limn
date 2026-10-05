// Not Zstandard itself: the few calls the Basis Universal transcoder makes,
// answered by the renderer's own decoder (see src/asset/ktx2.zig).
#ifndef RND_ZSTD_SHIM_H
#define RND_ZSTD_SHIM_H
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
// Returns the number of bytes written, or (size_t)-1 if the data is bad.
size_t rnd_zstd_decompress(void* dst, size_t dst_capacity, const void* src, size_t src_size);
// The decompressed size a frame declares, or one of the two values below.
unsigned long long rnd_zstd_content_size(const void* src, size_t src_size);
#ifdef __cplusplus
}
#endif
#define ZSTD_CONTENTSIZE_UNKNOWN (0ULL - 1)
#define ZSTD_CONTENTSIZE_ERROR (0ULL - 2)
#define ZSTD_decompress rnd_zstd_decompress
#define ZSTD_getFrameContentSize rnd_zstd_content_size
#define ZSTD_isError(code) ((code) == (size_t)-1)
#endif
