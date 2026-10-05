#version 460
#include "common.glsl"
#include "liquid.glsl"

// A liquid's shadow. A shadow map holds a surface or nothing, so a
// liquid that stops only part of the light is drawn through a screen:
// that share of its texels, chosen by a fixed pattern, and the filtering
// that softens every shadow's edge blends them into a lighter shadow.
layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    LiquidRef liquid;
    LiquidParticles particles;
    mat4 view_proj;
    float swell;
    float strength;
} push;

layout(location = 0) in vec2 in_corner;
layout(location = 1) flat in uint in_slot;

void main() {
    if (dot(in_corner, in_corner) > 1.0) discard;
    // An ordered 4x4 screen: steady from frame to frame, so the shadow
    // does not crawl.
    const float screen[16] = float[](0.0, 8.0, 2.0, 10.0, 12.0, 4.0, 14.0, 6.0, 3.0, 11.0, 1.0, 9.0, 15.0, 7.0, 13.0, 5.0);
    ivec2 texel = ivec2(gl_FragCoord.xy) & 3;
    if ((screen[texel.y * 4 + texel.x] + 0.5) / 16.0 > push.strength) discard;
}
