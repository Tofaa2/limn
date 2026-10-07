#version 460
#include "common.glsl"

// AMD FidelityFX Super Resolution 1 upscaling pass (EASU), from
// src/third_party/ffx_fsr1. Input is HDR: each channel is compressed to 0..1
// here and expanded again in fsr_rcas.frag.
layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    uint source_texture;
    uint pad;
    // Constants from `FsrEasuCon`.
    uvec4 con0;
    uvec4 con1;
    uvec4 con2;
    uvec4 con3;
} push;

layout(location = 0) out vec4 out_color;

#define A_GPU 1
#define A_GLSL 1
#include "../../third_party/ffx_fsr1/ffx_a.h"

#define FSR_EASU_F 1
AF4 squeezed(AF4 channel) {
    channel = max(channel, AF4_(0.0));
    return channel / (AF4_(1.0) + channel);
}
AF4 FsrEasuRF(AF2 p) { return squeezed(textureGather(TEX(push.source_texture, push.frame.sampler_linear_clamp), p, 0)); }
AF4 FsrEasuGF(AF2 p) { return squeezed(textureGather(TEX(push.source_texture, push.frame.sampler_linear_clamp), p, 1)); }
AF4 FsrEasuBF(AF2 p) { return squeezed(textureGather(TEX(push.source_texture, push.frame.sampler_linear_clamp), p, 2)); }
#include "../../third_party/ffx_fsr1/ffx_fsr1.h"

void main() {
    AF3 color;
    FsrEasuF(color, AU2(gl_FragCoord.xy), push.con0, push.con1, push.con2, push.con3);
    out_color = vec4(color, 1.0);
}
