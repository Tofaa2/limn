#ifndef SURFACE_SLANG
#define SURFACE_SLANG
#include "trace.slang"

/// How finely a ray hit reads its textures: at a fixed mip level, or at the
/// level whose texels match `footprint`, the width of the ray where it lands.
struct SurfaceDetail {
    float lod;
    float footprint;
    bool normal_maps;

    static SurfaceDetail fixed(float lod) {
        SurfaceDetail detail;
        detail.lod = lod;
        detail.footprint = -1.0;
        detail.normal_maps = false;
        return detail;
    }

    static SurfaceDetail matched(float footprint) {
        SurfaceDetail detail;
        detail.lod = 0.0;
        detail.footprint = footprint;
        detail.normal_maps = true;
        return detail;
    }

    float level(uint texture, float texture_per_world) {
        if (footprint < 0.0) return lod;
        float2 size = textureSize(texture);
        return max(log2(footprint * texture_per_world * max(size.x, size.y)) - 1.0, 0.0);
    }
};

/// What a ray met: the surface every traced effect shades from.
struct HitSurface {
    float3 position;
    /// The triangle's own normal, whichever way it faces.
    float3 geometric_normal;
    /// The ray met the triangle from behind.
    bool back_face;
    /// The shading normal, turned toward where the ray came from.
    float3 normal;
    /// Base color and opacity, with vertex colors and the instance's tint.
    float4 base_color;
    float metallic;
    float roughness;
    float3 emissive;
    uint material_flags;
    uint instance_flags;
    float alpha_cutoff;
    float transmission;
    float ior;
};

/// The triangle a ray met, before any of its textures are read.
struct HitGeometry {
    Instance instance;
    Material material;
    Vertex v0;
    Vertex v1;
    Vertex v2;
    float3 lambda;
    float3x3 normal_matrix;
    float3 position;
    float3 direction;
    float3 geometric_normal;
    bool back_face;
};

HitGeometry geometryAt(FrameConstants frame, TraceHit hit, float3 origin, float3 direction) {
    HitGeometry geometry;
    geometry.instance = frame.instances.data[hit.instance];
    Mesh mesh = loadAligned<16>(frame.meshes.data + geometry.instance.mesh);
    geometry.material = loadAligned<16>(frame.materials.data + geometry.instance.material);
    uint base = mesh.index_offset + hit.primitive * 3u;
    geometry.v0 = frame.vertices.data[geometry.instance.vertex_offset + frame.indices.data[base]];
    geometry.v1 = frame.vertices.data[geometry.instance.vertex_offset + frame.indices.data[base + 1u]];
    geometry.v2 = frame.vertices.data[geometry.instance.vertex_offset + frame.indices.data[base + 2u]];
    geometry.lambda = barycentricWeights(hit.barycentric);
    geometry.normal_matrix = normalMatrix(geometry.instance.transform);
    geometry.geometric_normal = normalize(mul(geometry.normal_matrix, cross(geometry.v1.position - geometry.v0.position, geometry.v2.position - geometry.v0.position)));
    geometry.back_face = dot(geometry.geometric_normal, direction) > 0.0;
    geometry.position = origin + direction * hit.t;
    geometry.direction = direction;
    return geometry;
}

HitSurface surfaceOf(HitGeometry geometry, SurfaceDetail detail) {
    HitSurface surface;
    Instance instance = geometry.instance;
    Material material = geometry.material;
    Vertex v0 = geometry.v0;
    Vertex v1 = geometry.v1;
    Vertex v2 = geometry.v2;
    float3 lambda = geometry.lambda;
    float3 direction = geometry.direction;

    float3x3 to_world = (float3x3)instance.transform;
    surface.geometric_normal = geometry.geometric_normal;
    surface.back_face = geometry.back_face;
    float3 facing_normal = surface.back_face ? -surface.geometric_normal : surface.geometric_normal;
    surface.normal = normalize(mul(geometry.normal_matrix, vertexNormal(v0) * lambda.x + vertexNormal(v1) * lambda.y + vertexNormal(v2) * lambda.z));
    if (detail.normal_maps) {
        if (dot(surface.normal, facing_normal) < 0.0) surface.normal = -surface.normal;
    } else if (dot(surface.normal, direction) > 0.0) {
        surface.normal = -surface.normal;
    }
    surface.position = geometry.position;

    float2 uv = v0.uv * lambda.x + v1.uv * lambda.y + v2.uv * lambda.z;
    float2 uvb = v0.uv1 * lambda.x + v1.uv1 * lambda.y + v2.uv1 * lambda.z;
    float texture_per_world = 0.0;
    if (detail.footprint >= 0.0) {
        float3 world_edge_a = mul(to_world, v1.position - v0.position);
        float3 world_edge_b = mul(to_world, v2.position - v0.position);
        float2 uv_edge_a = v1.uv - v0.uv;
        float2 uv_edge_b = v2.uv - v0.uv;
        texture_per_world = sqrt(abs(uv_edge_a.x * uv_edge_b.y - uv_edge_a.y * uv_edge_b.x) / max(length(cross(world_edge_a, world_edge_b)), 1e-12));
    }

    float4 base_color = material.base_color;
    if (material.base_color_texture != INVALID_ID)
        base_color *= sampleTextureLod(material.base_color_texture, material.sampler_index, materialUv(material, (material.uv_sets & 1u) != 0u ? uvb : uv), detail.level(material.base_color_texture, texture_per_world));
    base_color *= unpackUnorm(v0.color) * lambda.x + unpackUnorm(v1.color) * lambda.y + unpackUnorm(v2.color) * lambda.z;
    base_color = float4(base_color.rgb * unpackUnorm(instance.tint).rgb, base_color.a);

    surface.metallic = material.metallic;
    surface.roughness = material.roughness;
    float4 packed = float4(1.0);
    if (material.metallic_roughness_texture != INVALID_ID)
        packed = sampleTextureLod(material.metallic_roughness_texture, material.sampler_index, materialUv(material, uv), detail.level(material.metallic_roughness_texture, texture_per_world));
    if ((material.flags & MATERIAL_SPECULAR_GLOSSINESS) != 0u) {
        float3 color = base_color.rgb;
        specularGlossiness(material, packed, color, surface.roughness, surface.metallic);
        base_color.rgb = color;
    } else {
        surface.metallic *= packed.b;
        surface.roughness *= packed.g;
    }
    surface.roughness = clamp(surface.roughness, 0.03, 1.0);
    surface.base_color = base_color;

    if (detail.normal_maps && material.normal_texture != INVALID_ID) {
        float4 tangent_object = vertexTangent(v0) * lambda.x + vertexTangent(v1) * lambda.y + vertexTangent(v2) * lambda.z;
        float3 tangent = mul(to_world, tangent_object.xyz);
        if (dot(tangent, tangent) > 1e-12) {
            float3 along_u = normalize(tangent - surface.normal * dot(surface.normal, tangent));
            float3 along_v = cross(surface.normal, along_u) * (tangent_object.w < 0.0 ? -1.0 : 1.0);
            float2 normal_uv = materialUv(material, (material.uv_sets & 2u) != 0u ? uvb : uv);
            float3 sampled = float3(sampleTextureLod(material.normal_texture, material.sampler_index, normal_uv, detail.level(material.normal_texture, texture_per_world)).xy * 2.0 - 1.0, 0.0);
            sampled.z = sqrt(max(1.0 - dot(sampled.xy, sampled.xy), 0.0));
            sampled.xy *= material.normal_scale;
            surface.normal = normalize(along_u * sampled.x + along_v * sampled.y + surface.normal * sampled.z);
            float toward_eye = dot(surface.normal, -direction);
            if (toward_eye < 0.01) surface.normal = normalize(surface.normal - direction * (0.01 - toward_eye));
        }
    }

    surface.emissive = material.emissive;
    if (material.emissive_texture != INVALID_ID && any(surface.emissive > 0.0))
        surface.emissive *= sampleTextureLod(material.emissive_texture, material.sampler_index, materialUv(material, uv), detail.level(material.emissive_texture, texture_per_world)).rgb;
    surface.material_flags = material.flags;
    surface.instance_flags = instance.flags;
    surface.alpha_cutoff = material.alpha_cutoff;
    surface.transmission = material.transmission;
    surface.ior = material.ior;
    return surface;
}

HitSurface surfaceAt(FrameConstants frame, TraceHit hit, float3 origin, float3 direction, SurfaceDetail detail) {
    return surfaceOf(geometryAt(frame, hit, origin, direction), detail);
}

#endif
