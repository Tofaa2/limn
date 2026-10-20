#ifndef MATERIAL_INPUTS_SLANG
#define MATERIAL_INPUTS_SLANG
#include "common.slang"

/// How a caller fetches a material's texels. `channel` is the texture's bit
/// in `Material.uv_sets` (0 base color, 2 metallic and roughness, 4
/// emissive); `detail` asks for the material's detail sampler.
interface IMaterialTexels {
    float4 texel(uint texture, uint channel, bool detail);
}

/// The material inputs raster shading and ray hits share, before either
/// clamps them.
struct MaterialInputs {
    float4 base_color;
    float metallic;
    float roughness;
    float3 emissive;
    /// The metallic and roughness texel, which also holds occlusion in red.
    float4 packed;
}

/// A material's base color, metallic, roughness and emission at a point,
/// tinted by `tint` and the vertex color.
MaterialInputs materialInputs<T : IMaterialTexels>(Material material, T texels, float3 tint, float4 vertex_color) {
    MaterialInputs inputs;
    inputs.base_color = material.base_color;
    if (material.base_color_texture != INVALID_ID) inputs.base_color *= texels.texel(material.base_color_texture, 0u, false);
    inputs.base_color = float4(inputs.base_color.rgb * tint, inputs.base_color.a);
    inputs.base_color *= vertex_color;
    inputs.metallic = material.metallic;
    inputs.roughness = material.roughness;
    inputs.packed = float4(1.0);
    if (material.metallic_roughness_texture != INVALID_ID) inputs.packed = texels.texel(material.metallic_roughness_texture, 2u, true);
    if ((material.flags & MATERIAL_SPECULAR_GLOSSINESS) != 0u) {
        specularGlossiness(material, inputs.packed, inputs.base_color.rgb, inputs.roughness, inputs.metallic);
    } else {
        inputs.roughness *= inputs.packed.g;
        inputs.metallic *= inputs.packed.b;
    }
    inputs.emissive = material.emissive;
    if (material.emissive_texture != INVALID_ID && dot(inputs.emissive, float3(1.0)) > 0.0)
        inputs.emissive *= texels.texel(material.emissive_texture, 4u, true).rgb;
    return inputs;
}

#endif
