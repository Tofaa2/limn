#version 460
#include "common.glsl"

// AMD FidelityFX Super Resolution 1 sharpening pass (RCAS), from
// src/third_party/ffx_fsr1. Input is compressed to 0..1 (see fsr_easu.frag);
// the output is expanded back to HDR.
layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    uint source_texture;
    uint pad;
    // Constants from `FsrRcasCon`.
    uvec4 con;
} push;

layout(location = 0) out vec4 out_color;

#define A_GPU 1
#define A_GLSL 1
#include "../../third_party/ffx_fsr1/ffx_a.h"

#define FSR_RCAS_F 1
AF4 FsrRcasLoadF(ASU2 p) { return texelFetch(TEX(push.source_texture, push.frame.sampler_nearest_clamp), p, 0); }
void FsrRcasInputF(inout AF1 r, inout AF1 g, inout AF1 b) {}
#include "../../third_party/ffx_fsr1/ffx_fsr1.h"

void main() {
    AF1 r;
    AF1 g;
    AF1 b;
    FsrRcasF(r, g, b, AU2(gl_FragCoord.xy), push.con);
    vec3 color = clamp(vec3(r, g, b), 0.0, 0.9999);
    out_color = vec4(color / (1.0 - color), 1.0);
}
