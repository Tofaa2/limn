#version 460
#include "common.glsl"

// Final composite: exposure, bloom, AgX tone mapping and output encoding.
layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    uint color_texture;
    uint bloom_texture;
    float bloom_strength;
    // How to encode for the target: 0 as is (an sRGB format does it), 1
    // sRGB by hand, 2 HDR10 (PQ, Rec.2020).
    uint encode_srgb;
    float sharpen;
    // 1 / number of bloom levels accumulated into the bloom texture.
    float bloom_scale;
    // Debug views are already display-referred; skip grading.
    uint passthrough;
    // Top-left corner of the area being written, in target pixels.
    ivec2 origin;
    // Grading, all neutral at these values: vignette 0, grain 0,
    // saturation 1, contrast 1, filter white, aberration 0.
    float vignette;
    float grain;
    float saturation;
    float contrast;
    vec3 color_filter;
    float aberration;
    // HDR10 only: brightness of white in nits, and the display's peak.
    float hdr_paper_white;
    float hdr_peak;
    // Color lookup table (a strip of slices) or INVALID_ID, and its share.
    uint lut_texture;
    float lut_strength;
    // Lens flare: ghosts and a halo of the brightest things in view.
    float flare;
    uint flare_pad;
} push;

layout(location = 0) in vec2 in_uv;
layout(location = 0) out vec4 out_color;

// Minimal AgX by Benjamin Wrensch (iolite), after Troy Sobotka.
vec3 agxDefaultContrast(vec3 x) {
    vec3 x2 = x * x;
    vec3 x4 = x2 * x2;
    return 15.5 * x4 * x2 - 40.14 * x4 * x + 31.96 * x4 - 6.868 * x2 * x + 0.4298 * x2 + 0.1191 * x - 0.00232;
}

vec3 agx(vec3 color) {
    const mat3 inset = mat3(
        0.842479062253094, 0.0423282422610123, 0.0423756549057051,
        0.0784335999999992, 0.878468636469772, 0.0784336,
        0.0792237451477643, 0.0791661274605434, 0.879142973793104);
    const float min_ev = -12.47393;
    const float max_ev = 4.026069;
    color = inset * color;
    color = clamp(log2(max(color, vec3(1e-10))), min_ev, max_ev);
    color = (color - min_ev) / (max_ev - min_ev);
    return agxDefaultContrast(color);
}

vec3 agxLook(vec3 color) {
    // A gentle "punchy" grade: a little more contrast and saturation.
    const vec3 slope = vec3(1.0);
    const vec3 power = vec3(1.2);
    const float saturation = 1.25;
    color = pow(color * slope, power);
    float luma = luminance(color);
    return luma + saturation * (color - luma);
}

vec3 agxEotf(vec3 color) {
    const mat3 outset = mat3(
        1.19687900512017, -0.0528968517574562, -0.0529716355144438,
        -0.0980208811401368, 1.15190312990417, -0.0980434501171241,
        -0.0990297440797205, -0.0989611768448433, 1.15107367264116);
    color = outset * color;
    // AgX's base encoding is sRGB-like; linearize to get display-linear.
    return pow(max(color, vec3(0.0)), vec3(2.2));
}

vec3 srgbToLinear(vec3 c) {
    return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), greaterThan(c, vec3(0.04045)));
}

vec3 linearToSrgb(vec3 c) {
    vec3 low = c * 12.92;
    vec3 high = 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055;
    return mix(low, high, step(vec3(0.0031308), c));
}

void main() {
    FrameConstants frame = push.frame;
    uint nearest = frame.sampler_nearest_clamp;
    ivec2 pixel = ivec2(gl_FragCoord.xy) - push.origin;
    // The picture being graded may be at another resolution than the scene
    // was rendered at.
    ivec2 limit = textureSize(TEX(push.color_texture, nearest), 0) - 1;
    vec3 color = texelFetch(TEX(push.color_texture, nearest), pixel, 0).rgb;
    if (push.aberration > 0.0) {
        // Lens fringing: red and blue are sampled slightly apart, more so
        // toward the corners.
        ivec2 shift = ivec2(round((in_uv - 0.5) * push.aberration * 0.008 * frame.resolution));
        color.r = texelFetch(TEX(push.color_texture, nearest), clamp(pixel + shift, ivec2(0), limit), 0).r;
        color.b = texelFetch(TEX(push.color_texture, nearest), clamp(pixel - shift, ivec2(0), limit), 0).b;
    }

    // Contrast-adaptive sharpening recovers detail softened by TAA.
    if (push.sharpen > 0.0) {
        vec3 n = texelFetch(TEX(push.color_texture, nearest), clamp(pixel + ivec2(0, -1), ivec2(0), limit), 0).rgb;
        vec3 s = texelFetch(TEX(push.color_texture, nearest), clamp(pixel + ivec2(0, 1), ivec2(0), limit), 0).rgb;
        vec3 w = texelFetch(TEX(push.color_texture, nearest), clamp(pixel + ivec2(-1, 0), ivec2(0), limit), 0).rgb;
        vec3 e = texelFetch(TEX(push.color_texture, nearest), clamp(pixel + ivec2(1, 0), ivec2(0), limit), 0).rgb;
        float lc = luminance(color);
        float ln = luminance(n);
        float ls = luminance(s);
        float lw = luminance(w);
        float le = luminance(e);
        float low = min(lc, min(min(ln, ls), min(lw, le)));
        float high = max(lc, max(max(ln, ls), max(lw, le)));
        float amount = sqrt(clamp(low / max(high, 1e-5), 0.0, 1.0));
        float weight = -amount * push.sharpen * 0.2;
        color = max((color + (n + s + w + e) * weight) / (1.0 + 4.0 * weight), vec3(0.0));
    }

    if (push.passthrough != 0u) {
        if (push.encode_srgb == 1u) color = linearToSrgb(clamp(color, 0.0, 1.0));
        if (push.encode_srgb == 2u) color = hdr10Encode(clamp(color, 0.0, 1.0) * push.hdr_paper_white);
        out_color = vec4(color, 1.0);
        return;
    }

    vec3 bloom = textureLod(TEX(push.bloom_texture, frame.sampler_linear_clamp), in_uv, 0.0).rgb;
    color = mix(color, bloom * push.bloom_scale, push.bloom_strength);
    if (push.flare > 0.0) {
        // Light bouncing between the elements of a lens shows up as dim
        // copies of bright things, mirrored through the middle of the
        // picture, and as a ring around it. Taken from the blurred bloom
        // picture, keeping only what is far brighter than white.
        vec2 mirrored = vec2(1.0) - in_uv;
        vec2 toward_center = vec2(0.5) - mirrored;
        vec3 flare = vec3(0.0);
        float exposure = frame.exposure.exposure;
        for (int i = 0; i < 4; i++) {
            vec2 uv = mirrored + toward_center * (float(i) * 0.55 - 0.3);
            float falloff = 1.0 - smoothstep(0.2, 0.75, length(uv - 0.5));
            vec3 seen = textureLod(TEX(push.bloom_texture, frame.sampler_linear_clamp), uv, 0.0).rgb * push.bloom_scale * exposure;
            vec3 tint = i == 0 ? vec3(1.0, 0.8, 0.6) : (i == 1 ? vec3(0.6, 0.9, 1.0) : (i == 2 ? vec3(0.9, 0.7, 1.0) : vec3(0.7, 1.0, 0.8)));
            flare += max(seen - 2.0, vec3(0.0)) * tint * falloff;
        }
        vec2 ring = mirrored + normalize(toward_center + 1e-5) * 0.42;
        float ring_weight = pow(1.0 - smoothstep(0.0, 0.25, abs(length(toward_center) - 0.42)), 4.0);
        flare += max(textureLod(TEX(push.bloom_texture, frame.sampler_linear_clamp), ring, 0.0).rgb * push.bloom_scale * exposure - 2.0, vec3(0.0)) * ring_weight * vec3(0.8, 0.9, 1.0);
        color += flare * push.flare * 0.15 / max(exposure, 1e-6);
    }
    color *= frame.exposure.exposure * push.color_filter;

    if (push.encode_srgb == 2u) {
        // An HDR display shows highlights instead of compressing them into
        // white: values up to 1 pass through at paper white, and what is
        // above rolls off smoothly toward the display's peak.
        float peak = max(push.hdr_peak / max(push.hdr_paper_white, 1.0), 1.0);
        color = color * (1.0 + color / (peak * peak)) / (1.0 + color);
        color *= min(peak, 2.0) * 0.5 + 0.5;
    } else {
        color = agxEotf(agxLook(agx(color)));
    }

    // Display-referred grading.
    color = mix(vec3(luminance(color)), color, push.saturation);
    color = 0.18 * pow(max(color, vec3(0.0)) / 0.18, vec3(push.contrast));
    float corner = length(in_uv - 0.5) * 1.4142;
    color *= 1.0 - push.vignette * smoothstep(0.35, 1.0, corner);

    if (push.lut_texture != INVALID_ID && push.encode_srgb != 2u) {
        // The table is indexed by, and holds, sRGB-encoded color.
        vec3 encoded = linearToSrgb(clamp(color, 0.0, 1.0));
        float n = float(textureSize(TEX(push.lut_texture, frame.sampler_linear_clamp), 0).y);
        float slice = encoded.b * (n - 1.0);
        float below = floor(slice);
        vec2 in_slice = (encoded.rg * (n - 1.0) + 0.5) / vec2(n * n, n);
        vec3 a = textureLod(TEX(push.lut_texture, frame.sampler_linear_clamp), in_slice + vec2(below / n, 0.0), 0.0).rgb;
        vec3 b = textureLod(TEX(push.lut_texture, frame.sampler_linear_clamp), in_slice + vec2(min(below + 1.0, n - 1.0) / n, 0.0), 0.0).rgb;
        vec3 graded = srgbToLinear(mix(a, b, slice - below));
        color = mix(color, graded, push.lut_strength);
    }
    if (push.encode_srgb == 1u) color = linearToSrgb(clamp(color, 0.0, 1.0));
    if (push.encode_srgb == 2u) color = hdr10Encode(max(color, vec3(0.0)) * push.hdr_paper_white);
    // Half-LSB dither to break up banding in smooth gradients.
    float dither = interleavedGradientNoise(vec2(pixel) + 0.5, frame.frame_index) - 0.5;
    // Film grain: stronger in the shadows, as on film.
    float grain = (fract(sin(dot(vec2(pixel) + float(frame.frame_index % 61u) * 7.31, vec2(12.9898, 78.233))) * 43758.5453) - 0.5) * push.grain * 0.12;
    grain *= 1.0 - 0.6 * clamp(luminance(color), 0.0, 1.0);
    out_color = vec4(color + grain + dither / 255.0, 1.0);
}
