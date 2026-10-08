#ifndef VOLUME_GLSL
#define VOLUME_GLSL

vec2 volumeTileUv(vec2 texel, int slice, ivec3 size, int tiles_x) {
    texel = clamp(texel, vec2(0.5), vec2(size.xy) - 0.5);
    vec2 tile = vec2(slice % tiles_x, slice / tiles_x);
    int tiles_y = (size.z + tiles_x - 1) / tiles_x;
    return (tile * vec2(size.xy) + texel) / (vec2(tiles_x, tiles_y) * vec2(size.xy));
}

vec4 sampleVolume(uint texture_index, uint sampler_index, vec3 uvw, ivec3 size, int tiles_x) {
    vec2 texel = uvw.xy * vec2(size.xy);
    float z = clamp(uvw.z * float(size.z) - 0.5, 0.0, float(size.z - 1));
    int below = int(floor(z));
    int above = min(below + 1, size.z - 1);
    vec4 a = textureLod(TEX(texture_index, sampler_index), volumeTileUv(texel, below, size, tiles_x), 0.0);
    if (above == below) return a;
    vec4 b = textureLod(TEX(texture_index, sampler_index), volumeTileUv(texel, above, size, tiles_x), 0.0);
    return mix(a, b, z - float(below));
}

vec4 sampleVolumeRepeat(uint texture_index, uint sampler_index, vec3 uvw, ivec3 size, int tiles_x) {
    uvw = fract(uvw);
    vec2 texel = uvw.xy * vec2(size.xy);
    float z = uvw.z * float(size.z) - 0.5;
    float below = floor(z);
    int slice_a = (int(below) + size.z) % size.z;
    int slice_b = (slice_a + 1) % size.z;
    vec4 a = textureLod(TEX(texture_index, sampler_index), volumeTileUv(texel, slice_a, size, tiles_x), 0.0);
    vec4 b = textureLod(TEX(texture_index, sampler_index), volumeTileUv(texel, slice_b, size, tiles_x), 0.0);
    return mix(a, b, z - below);
}

ivec3 volumeCell(ivec2 pixel, ivec3 size, int tiles_x) {
    ivec2 tile = pixel / size.xy;
    return ivec3(pixel - tile * size.xy, tile.y * tiles_x + tile.x);
}

#endif
