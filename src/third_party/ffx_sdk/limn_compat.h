// Not part of the FidelityFX SDK: force-included by build.zig to stand in
// for what its sources expect from MSVC.
#ifndef LIMN_FFX_COMPAT_H
#define LIMN_FFX_COMPAT_H
#include <volk.h>

// The pipeline cache the SDK compiles its shaders into; set by limn_ffx.cpp.
extern VkPipelineCache limnFfxPipelineCache;
#ifndef _WIN32
#ifdef __cplusplus
#include <codecvt>
#include <cstdarg>
#include <cstddef>
#include <cstdio>
#include <cstring>
#include <cwchar>
#include <locale>
#include <string>

template <typename T, std::size_t N>
constexpr std::size_t limnCountOf(T (&)[N]) { return N; }
#define _countof(array) limnCountOf(array)

inline int wcscpy_s(wchar_t* destination, std::size_t size, const wchar_t* source) {
    if (size == 0) return 1;
    std::wcsncpy(destination, source, size - 1);
    destination[size - 1] = 0;
    return 0;
}
template <std::size_t N>
inline int wcscpy_s(wchar_t (&destination)[N], const wchar_t* source) { return wcscpy_s(destination, N, source); }
inline int strcpy_s(char* destination, std::size_t size, const char* source) {
    if (size == 0) return 1;
    std::strncpy(destination, source, size - 1);
    destination[size - 1] = 0;
    return 0;
}
template <std::size_t N>
inline int strcpy_s(char (&destination)[N], const char* source) { return strcpy_s(destination, N, source); }
template <typename... Arguments>
inline int sprintf_s(char* destination, std::size_t size, const char* format, Arguments... arguments) {
    return std::snprintf(destination, size, format, arguments...);
}
template <std::size_t N, typename... Arguments>
inline int sprintf_s(char (&destination)[N], const char* format, Arguments... arguments) {
    return std::snprintf(destination, N, format, arguments...);
}
#endif
#include "FidelityFX/host/ffx_util.h"
#endif
#endif
