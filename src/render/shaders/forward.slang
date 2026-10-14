#include "common.slang"
#include "shading.slang"

struct VertexPush {
    FrameConstants frame;
    uint instance_index;
};

[[vk::push_constant]] VertexPush vertex_push;

struct Varyings {
    [[vk::location(0)]] float3 position;
    [[vk::location(1)]] float3 normal;
    [[vk::location(2)]] float4 tangent;
    [[vk::location(3)]] float2 uv;
    [[vk::location(4)]] float4 clip;
    [[vk::location(5)]] float4 previous_clip;
    [[vk::location(6)]] float4 vertex_color;
    [[vk::location(7)]] float2 uv1;
    float4 screen : SV_Position;
};

[shader("vertex")]
Varyings vertexMain(uint vertex_index : SV_VulkanVertexID) {
    FrameConstants frame = vertex_push.frame;
    Instance instance = frame.instances.data[vertex_push.instance_index];
    Vertex vertex = frame.vertices.data[instance.vertex_offset + vertex_index];
    float4 world = float4(mul(instance.transform, float4(vertex.position, 1.0)), 1.0);
    float sway = frame.materials.data[instance.material].sway;
    uint material_flags = frame.materials.data[instance.material].flags;
    if (sway != 0.0) world.xyz += swayOffset(sway, material_flags, matrixColumn(instance.transform, 3), world.xyz, vertex.uv1, frame.time);
    Varyings result;
    result.position = world.xyz;
    result.normal = mul(normalMatrix(instance.transform), vertexNormal(vertex));
    float4 tangent = vertexTangent(vertex);
    result.tangent = float4(mul((float3x3)instance.transform, tangent.xyz), tangent.w);
    result.uv = vertex.uv;
    result.vertex_color = unpackUnorm(vertex.color);
    result.uv1 = vertex.uv1;
    result.screen = mul(frame.view_proj, world);
    Vertex previous = frame.vertices.data[instance.previous_vertex_offset + vertex_index];
    result.clip = mul(frame.view_proj_unjittered, world);
    float3x4 was = previousTransform(frame, instance, vertex_push.instance_index);
    float4 previous_world = float4(mul(was, float4(previous.position, 1.0)), 1.0);
    if (sway != 0.0) previous_world.xyz += swayOffset(sway, material_flags, matrixColumn(was, 3), previous_world.xyz, previous.uv1, frame.time - frame.delta_time);
    result.previous_clip = mul(frame.prev_view_proj_unjittered, previous_world);
    return result;
}

struct FragmentPush {
    FrameConstants frame;
    uint instance_index;
    uint mode;
    uint scene_texture;
    uint opaque_depth;
    uint peel_depth;
};

[[vk::push_constant]] FragmentPush fragment_push;

struct Output {
    float4 color : SV_Target0;
#ifndef PEEL
    float4 motion : SV_Target1;
#endif
#ifdef WEIGHTED
    float reveal : SV_Target2;
#endif
};

[shader("fragment")]
Output fragmentMain(
    [[vk::location(0)]] float3 in_position,
    [[vk::location(1)]] float3 in_normal,
    [[vk::location(2)]] float4 in_tangent,
    [[vk::location(3)]] float2 in_uv,
    [[vk::location(4)]] float4 in_clip,
    [[vk::location(5)]] float4 in_previous_clip,
    [[vk::location(6)]] float4 in_vertex_color,
    [[vk::location(7)]] float2 in_uv1,
    float4 fragment : SV_Position,
    bool front_facing : SV_IsFrontFace) {
    Output result;
    FrameConstants frame = fragment_push.frame;
    if (fragment_push.mode == 2u) {
        int2 at = int2(fragment.xy);
        if (fragment.z < fetchTexel(fragment_push.opaque_depth, at).r) discard;
        if (fragment_push.peel_depth != INVALID_ID && fragment.z >= fetchTexel(fragment_push.peel_depth, at).r) discard;
    }
    Instance instance = frame.instances.data[fragment_push.instance_index];
    Material material = loadAligned<16>(frame.materials.data + instance.material);
    uint s = material.sampler_index;
    float2 raw_uv[2] = { in_uv, in_uv1 };
    float2 shared_uv[2] = { materialUv(material, in_uv), materialUv(material, in_uv1) };
#define UV_OF(bit) textureUv(frame, material, uint(bit), shared_uv[(material.uv_sets >> bit) & 1u], raw_uv[(material.uv_sets >> bit) & 1u], true)

    float4 base_color = material.base_color;
    if (material.base_color_texture != INVALID_ID) base_color *= sampleTexture(material.base_color_texture, s, UV_OF(0));
    base_color = float4(base_color.rgb * unpackUnorm(instance.tint).rgb, base_color.a);
    base_color *= in_vertex_color;
    float roughness = material.roughness;
    float metallic = material.metallic;
    float4 mr = float4(1.0);
    if (material.metallic_roughness_texture != INVALID_ID) mr = sampleTexture(material.metallic_roughness_texture, s, UV_OF(2));
    if ((material.flags & MATERIAL_SPECULAR_GLOSSINESS) != 0u) {
        specularGlossiness(material, mr, base_color.rgb, roughness, metallic);
    } else {
        roughness *= mr.g;
        metallic *= mr.b;
    }
    float3 emissive = material.emissive;
    if (material.emissive_texture != INVALID_ID) emissive *= sampleTexture(material.emissive_texture, s, UV_OF(4)).rgb;

    float3 normal = normalize(in_normal);
    if (!front_facing) normal = -normal;
    float3 coat_normal = normal;
    float clearcoat = material.clearcoat;
    float clearcoat_roughness = material.clearcoat_roughness;
    if (clearcoat > 0.0) {
        if (material.clearcoat_texture != INVALID_ID) clearcoat *= sampleTexture(material.clearcoat_texture, s, UV_OF(5)).r;
        if (material.clearcoat_roughness_texture != INVALID_ID) clearcoat_roughness *= sampleTexture(material.clearcoat_roughness_texture, s, UV_OF(6)).g;
        if (material.clearcoat_normal_texture != INVALID_ID && dot(in_tangent.xyz, in_tangent.xyz) > 1e-12) {
            float3 t = normalize(in_tangent.xyz - normal * dot(normal, in_tangent.xyz));
            float3 b = cross(normal, t) * (in_tangent.w < 0.0 ? -1.0 : 1.0);
            float3 sampled = float3(sampleTexture(material.clearcoat_normal_texture, s, UV_OF(7)).xy * 2.0 - 1.0, 0.0);
            sampled.z = sqrt(max(1.0 - dot(sampled.xy, sampled.xy), 0.0));
            sampled.xy *= material.clearcoat_normal_scale;
            coat_normal = normalize(t * sampled.x + b * sampled.y + normal * sampled.z);
        }
    }
    float3 sheen_color = material.sheen_color;
    float sheen_roughness = material.sheen_roughness;
    if (dot(sheen_color, float3(1.0)) > 0.0) {
        if (material.sheen_color_texture != INVALID_ID) sheen_color *= sampleTexture(material.sheen_color_texture, s, UV_OF(8)).rgb;
        if (material.sheen_roughness_texture != INVALID_ID) sheen_roughness *= sampleTexture(material.sheen_roughness_texture, s, UV_OF(9)).a;
    }
    if (material.normal_texture != INVALID_ID && dot(in_tangent.xyz, in_tangent.xyz) > 1e-12) {
        float3 t = normalize(in_tangent.xyz - normal * dot(normal, in_tangent.xyz));
        float3 b = cross(normal, t) * (in_tangent.w < 0.0 ? -1.0 : 1.0);
        float3 sampled = float3(sampleTexture(material.normal_texture, s, UV_OF(1)).xy * 2.0 - 1.0, 0.0);
        sampled.z = sqrt(max(1.0 - dot(sampled.xy, sampled.xy), 0.0));
        sampled.xy *= material.normal_scale;
        normal = normalize(t * sampled.x + b * sampled.y + normal * sampled.z);
    }

    DECAL_LOOP_BEGIN(in_position, fragment.xy)
        Decal decal = frame.decals.data[i];
        float3 local = (mul(decal.world_to_decal, float4(in_position, 1.0))).xyz;
        if (any((abs(local) > float3(0.5)))) continue;
        float3 axis = normalize(float3(decal.world_to_decal[2][0], decal.world_to_decal[2][1], decal.world_to_decal[2][2]));
        float weight = smoothstep(decal.angle_fade, decal.angle_fade + 0.25, abs(dot(normal, axis)));
        weight *= 1.0 - smoothstep(0.35, 0.5, abs(local.z));
        float4 tint = decal.color;
        if (decal.image != INVALID_ID) tint *= sampleTexture(decal.image, frame.sampler_linear_clamp, float2(local.x + 0.5, 0.5 - local.y));
        weight *= tint.a;
        base_color = float4(lerp(base_color.rgb, tint.rgb, weight), lerp(base_color.a, 1.0, weight));
        emissive += tint.rgb * (decal.emissive * weight);
        if (decal.roughness >= 0.0) roughness = lerp(roughness, clamp(decal.roughness, 0.045, 1.0), weight);
    }

    Surface surface;
    surface.position = in_position;
    surface.normal = normal;
    surface.view = normalize(eyePoint(frame, in_position) - in_position);
    surface.diffuse_color = base_color.rgb * (1.0 - metallic);
    surface.f0 = lerp(float3(0.04), base_color.rgb, metallic);
    surface.roughness = clamp(roughness, 0.045, 1.0);
    surface.ao = 1.0;
    surface.bounce = float3(0.0);
    surface.view_depth = -(mul(frame.view, float4(in_position, 1.0))).z;
    surface.clearcoat = clamp(clearcoat, 0.0, 1.0);
    surface.clearcoat_roughness = clamp(clearcoat_roughness, 0.0, 1.0);
    surface.coat_normal = coat_normal;
    surface.sheen_color = sheen_color;
    surface.sheen_roughness = clamp(sheen_roughness, 0.07, 1.0);
    surface.subsurface = material.subsurface;
    surface.anisotropy = 0.0;
    surface.grain = float3(1.0, 0.0, 0.0);
    if (material.anisotropy > 0.0 && dot(in_tangent.xyz, in_tangent.xyz) > 1e-12) {
        float3 along_u = normalize(in_tangent.xyz - normal * dot(normal, in_tangent.xyz));
        float3 along_v = cross(normal, along_u) * (in_tangent.w < 0.0 ? -1.0 : 1.0);
        surface.grain = normalize(along_u * cos(material.anisotropy_rotation) + along_v * sin(material.anisotropy_rotation));
        surface.anisotropy = material.anisotropy;
    }

    Surface specular_only = surface;
    specular_only.diffuse_color = float3(0.0);
    float noise = interleavedGradientNoise(fragment.xy, frame.frame_index);
    float3 specular = shadeSurface(frame, specular_only, fragment.xy, noise, float4(0.0));
    float3 total = shadeSurface(frame, surface, fragment.xy, noise, float4(0.0));
    float3 diffuse = max(total - specular, float3(0.0));
    float alpha = base_color.a * (1.0 - material.transmission);
    float fresnel = max(surface.f0.r, max(surface.f0.g, surface.f0.b));
    fresnel += (1.0 - fresnel) * pow(1.0 - clamp(dot(surface.normal, surface.view), 0.0, 1.0), 5.0);
    float coverage = clamp(alpha + (1.0 - alpha) * fresnel * (1.0 - surface.roughness), 0.0, 1.0);
    float3 color = (diffuse + emissive) * alpha + specular;
    if (material.transmission > 0.0 && fragment_push.scene_texture != INVALID_ID) {
        float3 bent = refract(-surface.view, surface.normal, 1.0 / max(material.ior, 1.0));
        float4 exit = mul(frame.view_proj, float4(in_position + bent * material.thickness, 1.0));
        float2 uv_behind = clamp(exit.xy / exit.w * 0.5 + 0.5, float2(0.0), float2(1.0));
        float3 behind = sampleTextureLod(fragment_push.scene_texture, frame.sampler_linear_clamp, uv_behind, 0.0).rgb;
        if (surface.roughness > 0.08) {
            float spread = surface.roughness * surface.roughness * 0.06;
            float spin = noise * 6.2831853;
            for (int i = 0; i < 8; i++) {
                float angle = float(i) * 2.39996323 + spin;
                float2 tap = uv_behind + float2(cos(angle), sin(angle)) * (spread * sqrt((float(i) + 0.5) / 8.0)) * float2(frame.resolution.y / frame.resolution.x, 1.0);
                behind += sampleTextureLod(fragment_push.scene_texture, frame.sampler_linear_clamp, clamp(tap, float2(0.0), float2(1.0)), 0.0).rgb;
            }
            behind /= 9.0;
        }
        float through = 1.0 - coverage;
        color += behind * base_color.rgb * through;
        coverage += through;
    }
    if (frame.aerial != 0.0 && (frame.flags & FRAME_ENVIRONMENT) != 0u) {
        float3 air_through;
        float3 air;
        aerialHaze(frame, surface.view, length(in_position - eyePoint(frame, in_position)), air_through, air);
        color = color * air_through + air * coverage * (1.0 - air_through);
    }
#ifndef PEEL
    result.motion = float4((in_clip.xy / in_clip.w - in_previous_clip.xy / in_previous_clip.w) * 0.5, 0.0, coverage);
#endif
    if (fragment_push.mode == 1u) {
        float weight = clamp(pow(min(1.0, coverage * 10.0) + 0.01, 3.0) * 1e8 * pow(fragment.z * 0.9 + 0.1, 3.0), 1e-2, 3e3);
        result.color = float4(color, coverage) * weight;
#ifdef WEIGHTED
        result.reveal = coverage;
#endif
        return result;
    }
    result.color = float4(color, coverage);
    return result;
}
