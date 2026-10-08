#version 460
#include "common.glsl"
#include "shading.glsl"

layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    uint instance_index;
    uint mode;
    uint scene_texture;
    uint opaque_depth;
    uint peel_depth;
} push;

layout(location = 0) in vec3 in_position;
layout(location = 1) in vec3 in_normal;
layout(location = 2) in vec4 in_tangent;
layout(location = 3) in vec2 in_uv;
layout(location = 4) in vec4 in_clip;
layout(location = 5) in vec4 in_previous_clip;
layout(location = 6) in vec4 in_vertex_color;
layout(location = 7) in vec2 in_uv1;

layout(location = 0) out vec4 out_color;
layout(location = 1) out vec4 out_motion;
#ifdef WEIGHTED
layout(location = 2) out float out_reveal;
#endif

void main() {
    FrameConstants frame = push.frame;
    if (push.mode == 2u) {
        ivec2 at = ivec2(gl_FragCoord.xy);
        if (gl_FragCoord.z < texelFetch(TEX(push.opaque_depth, frame.sampler_nearest_clamp), at, 0).r) discard;
        if (push.peel_depth != INVALID_ID && gl_FragCoord.z >= texelFetch(TEX(push.peel_depth, frame.sampler_nearest_clamp), at, 0).r) discard;
    }
    Instance instance = frame.instances.data[push.instance_index];
    Material material = frame.materials.data[instance.material];
    uint s = material.sampler_index;
    vec2 raw_uv[2] = vec2[](in_uv, in_uv1);
    vec2 shared_uv[2] = vec2[](materialUv(material, in_uv), materialUv(material, in_uv1));
#define UV_OF(bit) textureUv(frame, material, uint(bit), shared_uv[(material.uv_sets >> bit) & 1u], raw_uv[(material.uv_sets >> bit) & 1u], true)

    vec4 base_color = material.base_color;
    if (material.base_color_texture != INVALID_ID) base_color *= texture(TEX(material.base_color_texture, s), UV_OF(0));
    base_color.rgb *= unpackUnorm4x8(instance.tint).rgb;
    base_color *= in_vertex_color;
    float roughness = material.roughness;
    float metallic = material.metallic;
    vec4 mr = vec4(1.0);
    if (material.metallic_roughness_texture != INVALID_ID) mr = texture(TEX(material.metallic_roughness_texture, s), UV_OF(2));
    if ((material.flags & MATERIAL_SPECULAR_GLOSSINESS) != 0u) {
        specularGlossiness(material, mr, base_color.rgb, roughness, metallic);
    } else {
        roughness *= mr.g;
        metallic *= mr.b;
    }
    vec3 emissive = material.emissive;
    if (material.emissive_texture != INVALID_ID) emissive *= texture(TEX(material.emissive_texture, s), UV_OF(4)).rgb;

    vec3 normal = normalize(in_normal);
    if (!gl_FrontFacing) normal = -normal;
    vec3 coat_normal = normal;
    float clearcoat = material.clearcoat;
    float clearcoat_roughness = material.clearcoat_roughness;
    if (clearcoat > 0.0) {
        if (material.clearcoat_texture != INVALID_ID) clearcoat *= texture(TEX(material.clearcoat_texture, s), UV_OF(5)).r;
        if (material.clearcoat_roughness_texture != INVALID_ID) clearcoat_roughness *= texture(TEX(material.clearcoat_roughness_texture, s), UV_OF(6)).g;
        if (material.clearcoat_normal_texture != INVALID_ID && dot(in_tangent.xyz, in_tangent.xyz) > 1e-12) {
            vec3 t = normalize(in_tangent.xyz - normal * dot(normal, in_tangent.xyz));
            vec3 b = cross(normal, t) * (in_tangent.w < 0.0 ? -1.0 : 1.0);
            vec3 sampled = vec3(texture(TEX(material.clearcoat_normal_texture, s), UV_OF(7)).xy * 2.0 - 1.0, 0.0);
            sampled.z = sqrt(max(1.0 - dot(sampled.xy, sampled.xy), 0.0));
            sampled.xy *= material.clearcoat_normal_scale;
            coat_normal = normalize(t * sampled.x + b * sampled.y + normal * sampled.z);
        }
    }
    vec3 sheen_color = material.sheen_color;
    float sheen_roughness = material.sheen_roughness;
    if (dot(sheen_color, vec3(1.0)) > 0.0) {
        if (material.sheen_color_texture != INVALID_ID) sheen_color *= texture(TEX(material.sheen_color_texture, s), UV_OF(8)).rgb;
        if (material.sheen_roughness_texture != INVALID_ID) sheen_roughness *= texture(TEX(material.sheen_roughness_texture, s), UV_OF(9)).a;
    }
    if (material.normal_texture != INVALID_ID && dot(in_tangent.xyz, in_tangent.xyz) > 1e-12) {
        vec3 t = normalize(in_tangent.xyz - normal * dot(normal, in_tangent.xyz));
        vec3 b = cross(normal, t) * (in_tangent.w < 0.0 ? -1.0 : 1.0);
        vec3 sampled = vec3(texture(TEX(material.normal_texture, s), UV_OF(1)).xy * 2.0 - 1.0, 0.0);
        sampled.z = sqrt(max(1.0 - dot(sampled.xy, sampled.xy), 0.0));
        sampled.xy *= material.normal_scale;
        normal = normalize(t * sampled.x + b * sampled.y + normal * sampled.z);
    }

    DECAL_LOOP_BEGIN(in_position)
        Decal decal = frame.decals.data[i];
        vec3 local = (decal.world_to_decal * vec4(in_position, 1.0)).xyz;
        if (any(greaterThan(abs(local), vec3(0.5)))) continue;
        vec3 axis = normalize(vec3(decal.world_to_decal[0][2], decal.world_to_decal[1][2], decal.world_to_decal[2][2]));
        float weight = smoothstep(decal.angle_fade, decal.angle_fade + 0.25, abs(dot(normal, axis)));
        weight *= 1.0 - smoothstep(0.35, 0.5, abs(local.z));
        vec4 tint = decal.color;
        if (decal.image != INVALID_ID) tint *= texture(TEX(decal.image, frame.sampler_linear_clamp), vec2(local.x + 0.5, 0.5 - local.y));
        weight *= tint.a;
        base_color.rgb = mix(base_color.rgb, tint.rgb, weight);
        base_color.a = mix(base_color.a, 1.0, weight);
        emissive += tint.rgb * (decal.emissive * weight);
        if (decal.roughness >= 0.0) roughness = mix(roughness, clamp(decal.roughness, 0.045, 1.0), weight);
    }

    Surface surface;
    surface.position = in_position;
    surface.normal = normal;
    surface.view = normalize(frame.camera_position - in_position);
    surface.diffuse_color = base_color.rgb * (1.0 - metallic);
    surface.f0 = mix(vec3(0.04), base_color.rgb, metallic);
    surface.roughness = clamp(roughness, 0.045, 1.0);
    surface.ao = 1.0;
    surface.bounce = vec3(0.0);
    surface.view_depth = -(frame.view * vec4(in_position, 1.0)).z;
    surface.clearcoat = clamp(clearcoat, 0.0, 1.0);
    surface.clearcoat_roughness = clamp(clearcoat_roughness, 0.0, 1.0);
    surface.coat_normal = coat_normal;
    surface.sheen_color = sheen_color;
    surface.sheen_roughness = clamp(sheen_roughness, 0.07, 1.0);
    surface.subsurface = material.subsurface;
    surface.anisotropy = 0.0;
    surface.grain = vec3(1.0, 0.0, 0.0);
    if (material.anisotropy > 0.0 && dot(in_tangent.xyz, in_tangent.xyz) > 1e-12) {
        vec3 along_u = normalize(in_tangent.xyz - normal * dot(normal, in_tangent.xyz));
        vec3 along_v = cross(normal, along_u) * (in_tangent.w < 0.0 ? -1.0 : 1.0);
        surface.grain = normalize(along_u * cos(material.anisotropy_rotation) + along_v * sin(material.anisotropy_rotation));
        surface.anisotropy = material.anisotropy;
    }

    Surface specular_only = surface;
    specular_only.diffuse_color = vec3(0.0);
    float noise = interleavedGradientNoise(gl_FragCoord.xy, frame.frame_index);
    vec3 specular = shadeSurface(frame, specular_only, gl_FragCoord.xy, noise, vec4(0.0));
    vec3 total = shadeSurface(frame, surface, gl_FragCoord.xy, noise, vec4(0.0));
    vec3 diffuse = max(total - specular, vec3(0.0));
    float alpha = base_color.a * (1.0 - material.transmission);
    float fresnel = max(surface.f0.r, max(surface.f0.g, surface.f0.b));
    fresnel += (1.0 - fresnel) * pow(1.0 - clamp(dot(surface.normal, surface.view), 0.0, 1.0), 5.0);
    float coverage = clamp(alpha + (1.0 - alpha) * fresnel * (1.0 - surface.roughness), 0.0, 1.0);
    vec3 color = (diffuse + emissive) * alpha + specular;
    if (material.transmission > 0.0 && push.scene_texture != INVALID_ID) {
        vec3 bent = refract(-surface.view, surface.normal, 1.0 / max(material.ior, 1.0));
        vec4 exit = frame.view_proj * vec4(in_position + bent * material.thickness, 1.0);
        vec2 uv_behind = clamp(exit.xy / exit.w * 0.5 + 0.5, vec2(0.0), vec2(1.0));
        vec3 behind = textureLod(TEX(push.scene_texture, frame.sampler_linear_clamp), uv_behind, 0.0).rgb;
        if (surface.roughness > 0.08) {
            float spread = surface.roughness * surface.roughness * 0.06;
            float spin = noise * 6.2831853;
            for (int i = 0; i < 8; i++) {
                float angle = float(i) * 2.39996323 + spin;
                vec2 tap = uv_behind + vec2(cos(angle), sin(angle)) * (spread * sqrt((float(i) + 0.5) / 8.0)) * vec2(frame.resolution.y / frame.resolution.x, 1.0);
                behind += textureLod(TEX(push.scene_texture, frame.sampler_linear_clamp), clamp(tap, vec2(0.0), vec2(1.0)), 0.0).rgb;
            }
            behind /= 9.0;
        }
        float through = 1.0 - coverage;
        color += behind * base_color.rgb * through;
        coverage += through;
    }
    if (frame.aerial != 0.0 && (frame.flags & FRAME_ENVIRONMENT) != 0u) {
        vec3 air_through;
        vec3 air;
        aerialHaze(frame, surface.view, length(in_position - frame.camera_position), air_through, air);
        color = color * air_through + air * coverage * (1.0 - air_through);
    }
    out_motion = vec4((in_clip.xy / in_clip.w - in_previous_clip.xy / in_previous_clip.w) * 0.5, 0.0, coverage);
    if (push.mode == 1u) {
        float weight = clamp(pow(min(1.0, coverage * 10.0) + 0.01, 3.0) * 1e8 * pow(gl_FragCoord.z * 0.9 + 0.1, 3.0), 1e-2, 3e3);
        out_color = vec4(color, coverage) * weight;
#ifdef WEIGHTED
        out_reveal = coverage;
#endif
        return;
    }
    out_color = vec4(color, coverage);
}
