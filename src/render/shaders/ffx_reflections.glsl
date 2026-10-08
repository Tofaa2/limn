#ifndef FFX_REFLECTIONS_GLSL
#define FFX_REFLECTIONS_GLSL

// Copyright (c) 2021 Advanced Micro Devices, Inc. All rights reserved.
//
// Permission is hereby granted, free of charge, to any person obtaining a
// copy of this software and associated documentation files (the
// "Software"), to deal in the Software without restriction, including
// without limitation the rights to use, copy, modify, merge, publish,
// distribute, sublicense, and/or sell copies of the Software, and to
// permit persons to whom the Software is furnished to do so, subject to
// the following conditions:
//
// The above copyright notice and this permission notice shall be included
// in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
// OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
// IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
// CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
// TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
// SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

const float FFX_GAUSSIAN_K = 3.0;
const float FFX_RADIANCE_WEIGHT_BIAS = 0.6;
const float FFX_RADIANCE_WEIGHT_VARIANCE_K = 0.1;
const float FFX_AVG_RADIANCE_LUMINANCE_WEIGHT = 0.3;
const float FFX_PREFILTER_VARIANCE_WEIGHT = 4.4;
const float FFX_REPROJECT_SURFACE_DISCARD_VARIANCE_WEIGHT = 1.5;
const float FFX_PREFILTER_VARIANCE_BIAS = 0.1;
const float FFX_PREFILTER_NORMAL_SIGMA = 512.0;
const float FFX_PREFILTER_DEPTH_SIGMA = 4.0;
const float FFX_DISOCCLUSION_NORMAL_WEIGHT = 1.4;
const float FFX_DISOCCLUSION_DEPTH_WEIGHT = 1.0;
const float FFX_DISOCCLUSION_THRESHOLD = 0.9;
const float FFX_REPROJECTION_NORMAL_SIMILARITY_THRESHOLD = 0.9999;

float ffxSamplesForRoughness(float roughness) {
    return 1.0 - exp(-roughness * 100.0);
}

const int FFX_LOCAL_NEIGHBORHOOD_RADIUS = 3;

const float FFX_MAX_SAMPLES = 64.0;

const float FFX_GLOSSY_ROUGHNESS = 0.4;

bool ffxIsGlossy(float roughness) {
    return roughness < FFX_GLOSSY_ROUGHNESS;
}

float ffxLuminance(vec3 color) {
    return max(dot(color, vec3(0.299, 0.587, 0.114)), 0.001);
}

float ffxTemporalVariance(vec3 history_radiance, vec3 radiance) {
    float history_luminance = ffxLuminance(history_radiance);
    float luminance = ffxLuminance(radiance);
    float difference = abs(history_luminance - luminance) / max(max(history_luminance, luminance), 0.5);
    return difference * difference;
}

vec3 ffxClipAabb(vec3 aabb_min, vec3 aabb_max, vec3 previous) {
    vec3 center = 0.5 * (aabb_max + aabb_min);
    vec3 extent = 0.5 * (aabb_max - aabb_min) + 0.001;
    vec3 offset = previous - center;
    vec3 unit = abs(offset / extent);
    float max_unit = max(max(unit.x, unit.y), unit.z);
    return max_unit > 1.0 ? center + offset / max_unit : previous;
}

float ffxLocalKernelWeight(float i) {
    float radius = float(FFX_LOCAL_NEIGHBORHOOD_RADIUS) + 1.0;
    return exp(-FFX_GAUSSIAN_K * (i * i) / (radius * radius));
}

float ffxDisocclusionFactor(vec3 normal, vec3 history_normal, float linear_depth, float history_linear_depth) {
    return exp(-abs(1.0 - max(0.0, dot(normal, history_normal))) * FFX_DISOCCLUSION_NORMAL_WEIGHT) *
        exp(-abs(history_linear_depth - linear_depth) / linear_depth * FFX_DISOCCLUSION_DEPTH_WEIGHT);
}

struct FfxSurface {
    vec3 normal;
    float roughness;
    float depth;
};

FfxSurface ffxSurface(vec4 texel) {
    FfxSurface surface;
    surface.normal = unpackDirection(packSnorm2x16(texel.rg));
    surface.roughness = texel.b;
    surface.depth = max(texel.a, 1e-3);
    return surface;
}

#endif
