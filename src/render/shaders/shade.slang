#define DEFER_REFLECTIONS
#define CONTACT_SHADOWS
#include "common.slang"
#include "shading.slang"
#include "material_inputs.slang"

#include "shade.Push.slang"

[[vk::push_constant]] Push push;

struct ShadeOutput {
    float4 color : SV_Target0;
    float2 motion : SV_Target1;
#ifndef PLAIN
    float4 reflection : SV_Target2;
    float4 surface : SV_Target3;
#endif
};

#define UV_PICK(bit, second, first) (((material.uv_sets >> bit) & 1u) != 0u ? second : first)
#define UV_OF(bit) textureUv(frame, material, uint(bit), UV_PICK(bit, uvb, uv), UV_PICK(bit, raw1, raw0), true), textureUv(frame, material, uint(bit), UV_PICK(bit, uvb_dx, uv_dx), UV_PICK(bit, raw1_dx, raw0_dx), false), textureUv(frame, material, uint(bit), UV_PICK(bit, uvb_dy, uv_dy), UV_PICK(bit, raw1_dy, raw0_dy), false)

/// Texels where raster shading draws, with the gradients of the visibility
/// buffer's barycentrics.
struct RasterTexels : IMaterialTexels {
    FrameConstants frame;
    Material material;
    uint s;
    uint d;
    float2 uv;
    float2 uv_dx;
    float2 uv_dy;
    float2 uvb;
    float2 uvb_dx;
    float2 uvb_dy;
    float2 raw0;
    float2 raw0_dx;
    float2 raw0_dy;
    float2 raw1;
    float2 raw1_dx;
    float2 raw1_dy;

    float4 texel(uint texture, uint channel, bool detail) {
        return sampleTextureGrad(texture, detail ? d : s, UV_OF(channel));
    }
}

struct MaterialSurface {
    float3 base_color;
    float metallic;
    float roughness;
    float occlusion;
    float3 emissive;
    float3 normal;
    float clearcoat;
    float clearcoat_roughness;
    float3 clearcoat_normal;
};

struct MaterialContext {
    float3 position;
    float3 geometric_normal;
    float3 view;
    float2 uv;
    float2 uv_dx;
    float2 uv_dy;
    float time;
    float4 params;
    uint instance;
    float4 instance_params;
};

struct Barycentrics {
    float3 lambda;
    float3 ddx;
    float3 ddy;
};

Barycentrics barycentrics(float4 p0, float4 p1, float4 p2, float2 ndc, float2 resolution) {
    Barycentrics result;
    float3 inv_w = 1.0 / float3(p0.w, p1.w, p2.w);
    float2 n0 = p0.xy * inv_w.x;
    float2 n1 = p1.xy * inv_w.y;
    float2 n2 = p2.xy * inv_w.z;
    float inv_det = 1.0 / determinant(float2x2(n2 - n1, n0 - n1));
    result.ddx = float3(n1.y - n2.y, n2.y - n0.y, n0.y - n1.y) * inv_det * inv_w;
    result.ddy = float3(n2.x - n1.x, n0.x - n2.x, n1.x - n0.x) * inv_det * inv_w;
    float ddx_sum = dot(result.ddx, float3(1.0));
    float ddy_sum = dot(result.ddy, float3(1.0));
    float2 delta = ndc - n0;
    float interp_inv_w = inv_w.x + delta.x * ddx_sum + delta.y * ddy_sum;
    float interp_w = 1.0 / interp_inv_w;
    result.lambda.x = interp_w * (inv_w.x + delta.x * result.ddx.x + delta.y * result.ddy.x);
    result.lambda.y = interp_w * (delta.x * result.ddx.y + delta.y * result.ddy.y);
    result.lambda.z = interp_w * (delta.x * result.ddx.z + delta.y * result.ddy.z);
    result.ddx *= 2.0 / resolution.x;
    result.ddy *= 2.0 / resolution.y;
    ddx_sum *= 2.0 / resolution.x;
    ddy_sum *= 2.0 / resolution.y;
    float interp_w_ddx = 1.0 / (interp_inv_w + ddx_sum);
    float interp_w_ddy = 1.0 / (interp_inv_w + ddy_sum);
    result.ddx = interp_w_ddx * (result.lambda * interp_inv_w + result.ddx) - result.lambda;
    result.ddy = interp_w_ddy * (result.lambda * interp_inv_w + result.ddy) - result.lambda;
    return result;
}

float3 hashColor(uint value) {
    value = (value ^ 61u) ^ (value >> 16u);
    value *= 9u;
    value ^= value >> 4u;
    value *= 0x27d4eb2du;
    value ^= value >> 15u;
    return float3(float(value & 255u), float((value >> 8u) & 255u), float((value >> 16u) & 255u)) / 255.0;
}

/// The cofactor matrix of the model matrix as rows: `mul(normal, rows)` turns
/// object normals to world space up to scale.
float3x3 cofactorRows(float3x4 m) {
    float3 c0 = matrixColumn(m, 0);
    float3 c1 = matrixColumn(m, 1);
    float3 c2 = matrixColumn(m, 2);
    return float3x3(cross(c1, c2), cross(c2, c0), cross(c0, c1));
}

[shader("fragment")]
ShadeOutput fragmentMain([[vk::location(0)]] float2 in_uv, float4 fragment : SV_Position) {
    ShadeOutput result;
    FrameConstants frame = push.frame;
    uint nearest = frame.sampler_nearest_clamp;
    int2 pixel = int2(fragment.xy);
    uint id = fetchTexelUint(push.visibility_texture, pixel).r;
    float2 ndc = in_uv * 2.0 - 1.0;

    if (id == INVALID_ID) {
#ifdef CUSTOM_MATERIAL
        discard;
#endif
        float4 world = mul(frame.inv_view_proj, float4(ndc, 1e-6, 1.0));
        float3 far_point = world.xyz / world.w;
        float3 direction = normalize(far_point - eyePoint(frame, far_point));
        float4 current = mul(frame.view_proj_unjittered, float4(direction, 0.0));
        float4 previous = mul(frame.prev_view_proj_unjittered, float4(direction, 0.0));
        float3 sky = float3(0.0);
        if (frame.environment != 0u)
            sky = sampleCubeLod(frame.env_sky, frame.sampler_linear_clamp, skyFromHeight(direction, eyePoint(frame, far_point).y), 0.0).rgb * frame.env_intensity;
        result.color = float4(sky, 1.0);
#ifndef PLAIN
        result.reflection = float4(0.0);
        result.surface = float4(0.0);
#endif
        result.motion = frame.parallel != 0.0 ? float2(0.0) : (current.xy / current.w - previous.xy / previous.w) * 0.5;
        return result;
    }

    MeshletRef ref = frame.meshlet_refs.data[id >> 7];
    uint triangle = id & 127u;
    Instance instance = frame.instances.data[ref.instance];
    Mesh mesh = loadAligned<16>(frame.meshes.data + instance.mesh);
    Meshlet meshlet = loadAligned<16>(frame.meshlets.data + ref.meshlet);
    Material material = loadAligned<16>(frame.materials.data + instance.material);
#ifdef CUSTOM_MATERIAL
    if (material.shader != push.material_shader) discard;
#else
    if (material.shader != 0u && ((push.material_shader >> material.shader) & 1u) != 0u) discard;
#endif

    uint base = mesh.index_offset + meshlet.index_offset + triangle * 3u;
    uint i0 = frame.indices.data[base];
    uint i1 = frame.indices.data[base + 1u];
    uint i2 = frame.indices.data[base + 2u];
    Vertex v0 = frame.vertices.data[instance.vertex_offset + i0];
    Vertex v1 = frame.vertices.data[instance.vertex_offset + i1];
    Vertex v2 = frame.vertices.data[instance.vertex_offset + i2];

    float3 w0 = (mul(instance.transform, float4(v0.position, 1.0))).xyz;
    float3 w1 = (mul(instance.transform, float4(v1.position, 1.0))).xyz;
    float3 w2 = (mul(instance.transform, float4(v2.position, 1.0))).xyz;
    float sway = frame.materials.data[instance.material].sway;
    if (sway != 0.0) {
        float3 stands = matrixColumn(instance.transform, 3);
        w0 += swayOffset(sway, material.flags, stands, w0, v0.uv1, frame.time);
        w1 += swayOffset(sway, material.flags, stands, w1, v1.uv1, frame.time);
        w2 += swayOffset(sway, material.flags, stands, w2, v2.uv1, frame.time);
    }
    float4 clip0 = mul(frame.view_proj, float4(w0, 1.0));
    float4 clip1 = mul(frame.view_proj, float4(w1, 1.0));
    float4 clip2 = mul(frame.view_proj, float4(w2, 1.0));
    Barycentrics bary = barycentrics(clip0, clip1, clip2, ndc, frame.resolution);
    float3 lambda = bary.lambda;

    float2 raw0 = v0.uv * lambda.x + v1.uv * lambda.y + v2.uv * lambda.z;
    float2 raw0_dx = (v0.uv * bary.ddx.x + v1.uv * bary.ddx.y + v2.uv * bary.ddx.z) * frame.texture_gradient_scale;
    float2 raw0_dy = (v0.uv * bary.ddy.x + v1.uv * bary.ddy.y + v2.uv * bary.ddy.z) * frame.texture_gradient_scale;
    float2 raw1 = v0.uv1 * lambda.x + v1.uv1 * lambda.y + v2.uv1 * lambda.z;
    float2 raw1_dx = (v0.uv1 * bary.ddx.x + v1.uv1 * bary.ddx.y + v2.uv1 * bary.ddx.z) * frame.texture_gradient_scale;
    float2 raw1_dy = (v0.uv1 * bary.ddy.x + v1.uv1 * bary.ddy.y + v2.uv1 * bary.ddy.z) * frame.texture_gradient_scale;
    float2 uv = materialUv(material, raw0);
    float2 uv_dx = materialUvDerivative(material, raw0_dx);
    float2 uv_dy = materialUvDerivative(material, raw0_dy);
    float2 uvb = materialUv(material, raw1);
    float2 uvb_dx = materialUvDerivative(material, raw1_dx);
    float2 uvb_dy = materialUvDerivative(material, raw1_dy);

    float3 world_position = w0 * lambda.x + w1 * lambda.y + w2 * lambda.z;
    float3x3 normal_rows = cofactorRows(instance.transform);
    float3 geometric_normal = normalize(mul(cross(v1.position - v0.position, v2.position - v0.position), normal_rows));
    float3 normal = normalize(mul(vertexNormal(v0) * lambda.x + vertexNormal(v1) * lambda.y + vertexNormal(v2) * lambda.z, normal_rows));
    float4 tangent_object = vertexTangent(v0) * lambda.x + vertexTangent(v1) * lambda.y + vertexTangent(v2) * lambda.z;
    float3 tangent = mul((float3x3)instance.transform, tangent_object.xyz);

    float3 view_direction = normalize(eyePoint(frame, world_position) - world_position);
    if ((material.flags & MATERIAL_DOUBLE_SIDED) != 0u && dot(geometric_normal, view_direction) < 0.0) {
        normal = -normal;
    }

    uint s = material.sampler_index;
    uint d = material.detail_sampler;
    RasterTexels texels = { frame, material, s, d, uv, uv_dx, uv_dy, uvb, uvb_dx, uvb_dy, raw0, raw0_dx, raw0_dy, raw1, raw1_dx, raw1_dy };
    MaterialInputs inputs = materialInputs(material, texels, unpackUnorm(instance.tint).rgb, unpackUnorm(v0.color) * lambda.x + unpackUnorm(v1.color) * lambda.y + unpackUnorm(v2.color) * lambda.z);
    float4 base_color = inputs.base_color;
    float roughness = clamp(inputs.roughness, 0.045, 1.0);
    float metallic = clamp(inputs.metallic, 0.0, 1.0);
    float4 mr = inputs.packed;

    float ao = 1.0;
    if (material.occlusion_texture != INVALID_ID) {
        float sampled = mr.r;
        bool shares_texture = material.occlusion_texture == material.metallic_roughness_texture && ((material.uv_sets >> 2) & 1u) == ((material.uv_sets >> 3) & 1u) && ((SHADE_FEATURES & FEATURE_TEXTURE_TRANSFORMS) == 0u || material.texture_transforms == INVALID_ID);
        if (!shares_texture) sampled = sampleTextureGrad(material.occlusion_texture, d, UV_OF(3)).r;
        ao = lerp(1.0, sampled, material.occlusion_strength);
    }
    float screen_ao = 1.0;
    if (frame.ambient_occlusion.enabled != 0u)
        screen_ao = fetchTexel(push.ao_texture, pixel).r;

    float3 emissive = inputs.emissive;

    float3 coat_normal = normal;
    float clearcoat = material.clearcoat;
    float clearcoat_roughness = material.clearcoat_roughness;
    if (clearcoat > 0.0) {
        if (material.clearcoat_texture != INVALID_ID) clearcoat *= sampleTextureGrad(material.clearcoat_texture, d, UV_OF(5)).r;
        if (material.clearcoat_roughness_texture != INVALID_ID) clearcoat_roughness *= sampleTextureGrad(material.clearcoat_roughness_texture, d, UV_OF(6)).g;
        if (material.clearcoat_normal_texture != INVALID_ID && dot(tangent, tangent) > 1e-12) {
            float3 t = normalize(tangent - normal * dot(normal, tangent));
            float3 b = cross(normal, t) * (tangent_object.w < 0.0 ? -1.0 : 1.0);
            float3 sampled = float3(sampleTextureGrad(material.clearcoat_normal_texture, s, UV_OF(7)).xy * 2.0 - 1.0, 0.0);
            sampled.z = sqrt(max(1.0 - dot(sampled.xy, sampled.xy), 0.0));
            sampled.xy *= material.clearcoat_normal_scale;
            coat_normal = normalize(t * sampled.x + b * sampled.y + normal * sampled.z);
        }
    }
    float3 sheen_color = material.sheen_color;
    float sheen_roughness = material.sheen_roughness;
    if (dot(sheen_color, float3(1.0)) > 0.0) {
        if (material.sheen_color_texture != INVALID_ID) sheen_color *= sampleTextureGrad(material.sheen_color_texture, s, UV_OF(8)).rgb;
        if (material.sheen_roughness_texture != INVALID_ID) sheen_roughness *= sampleTextureGrad(material.sheen_roughness_texture, d, UV_OF(9)).a;
    }

    if (material.normal_texture != INVALID_ID && dot(tangent, tangent) > 1e-12) {
        float3 t = normalize(tangent - normal * dot(normal, tangent));
        float3 b = cross(normal, t) * (tangent_object.w < 0.0 ? -1.0 : 1.0);
        float3 sampled = float3(sampleTextureGrad(material.normal_texture, s, UV_OF(1)).xy * 2.0 - 1.0, 0.0);
        sampled.z = sqrt(max(1.0 - dot(sampled.xy, sampled.xy), 0.0));
        sampled.xy *= material.normal_scale;
        normal = normalize(t * sampled.x + b * sampled.y + normal * sampled.z);
    }

#ifdef CUSTOM_MATERIAL
    {
        MaterialSurface custom = { base_color.rgb, metallic, roughness, ao, emissive, normal, clearcoat, clearcoat_roughness, coat_normal };
        MaterialContext context = { world_position, geometric_normal, view_direction, uv, uv_dx, uv_dy,
            frame.time, material.params, ref.instance, instance.params };
        customMaterial(custom, context, frame);
        base_color.rgb = custom.base_color;
        metallic = clamp(custom.metallic, 0.0, 1.0);
        roughness = clamp(custom.roughness, 0.045, 1.0);
        ao = custom.occlusion;
        emissive = custom.emissive;
        normal = normalize(custom.normal);
        clearcoat = custom.clearcoat;
        clearcoat_roughness = custom.clearcoat_roughness;
        coat_normal = normalize(custom.clearcoat_normal);
    }
#endif
    DECAL_LOOP_BEGIN(world_position, fragment.xy)
        Decal decal = frame.shading.decals.data[i];
        float3 local = (mul(decal.world_to_decal, float4(world_position, 1.0))).xyz;
        if (any((abs(local) > float3(0.5)))) continue;
        float3 axis = normalize(float3(decal.world_to_decal[2][0], decal.world_to_decal[2][1], decal.world_to_decal[2][2]));
        float facing = dot(geometric_normal, axis) * (dot(geometric_normal, view_direction) < 0.0 ? -1.0 : 1.0);
        float weight = smoothstep(decal.angle_fade, decal.angle_fade + 0.25, facing);
        weight *= 1.0 - smoothstep(0.35, 0.5, abs(local.z));
        float4 tint = decal.color;
        if (decal.image != INVALID_ID) {
            float2 decal_uv = float2(local.x + 0.5, 0.5 - local.y);
            tint *= sampleTextureGrad(decal.image, frame.sampler_linear_clamp, decal_uv, ddx(decal_uv), ddy(decal_uv));
        }
        weight *= tint.a;
        base_color.rgb = lerp(base_color.rgb, tint.rgb, weight);
        emissive += tint.rgb * (decal.emissive * weight);
        if (decal.roughness >= 0.0) roughness = lerp(roughness, clamp(decal.roughness, 0.045, 1.0), weight);
        if (decal.normal_image != INVALID_ID) {
            float2 decal_uv = float2(local.x + 0.5, 0.5 - local.y);
            float3 mapped = sampleTextureGrad(decal.normal_image, frame.sampler_linear_clamp, decal_uv, ddx(decal_uv), ddy(decal_uv)).xyz * 2.0 - 1.0;
            mapped.xy *= decal.normal_strength;
            float3 right = normalize(float3(decal.world_to_decal[0][0], decal.world_to_decal[0][1], decal.world_to_decal[0][2]));
            float3 up = normalize(float3(decal.world_to_decal[1][0], decal.world_to_decal[1][1], decal.world_to_decal[1][2]));
            float3 bent = normalize(normal + right * mapped.x + up * mapped.y);
            normal = normalize(lerp(normal, bent, weight));
        }
    }

    ao = min(ao, screen_ao);

    float3 previous_world = world_position;
    if ((instance.flags & INSTANCE_MOVING) != 0u) {
        float3 p0 = frame.vertices.data[instance.previous_vertex_offset + i0].position;
        float3 p1 = frame.vertices.data[instance.previous_vertex_offset + i1].position;
        float3 p2 = frame.vertices.data[instance.previous_vertex_offset + i2].position;
        previous_world = mul(previousTransform(frame, instance, ref.instance), float4(p0 * lambda.x + p1 * lambda.y + p2 * lambda.z, 1.0));
    }
    if (sway != 0.0) {
        float3 stood = matrixColumn(previousTransform(frame, instance, ref.instance), 3);
        previous_world += swayOffset(sway, material.flags, stood, previous_world, raw1, frame.time - frame.delta_time) - swayOffset(sway, material.flags, stood, previous_world, raw1, frame.time);
    }
    float4 current_clip = mul(frame.view_proj_unjittered, float4(world_position, 1.0));
    float4 previous_clip = mul(frame.prev_view_proj_unjittered, float4(previous_world, 1.0));
    result.motion = (current_clip.xy / current_clip.w - previous_clip.xy / previous_clip.w) * 0.5;

    if (frame.shading.specular_aa != 0u) {
        float3 normal_dx = ddx(normal);
        float3 normal_dy = ddy(normal);
        float variance = 0.25 * (dot(normal_dx, normal_dx) + dot(normal_dy, normal_dy));
        float kernel = min(2.0 * variance, 0.18);
        float alpha = roughness * roughness;
        roughness = sqrt(sqrt(clamp(alpha * alpha + kernel, 0.0, 1.0)));
    }

    Surface surface;
    surface.position = world_position;
    surface.normal = normal;
    surface.view = view_direction;
    surface.diffuse_color = base_color.rgb * (1.0 - metallic);
    surface.f0 = lerp(float3(0.04), base_color.rgb, metallic);
    surface.roughness = roughness;
    surface.ao = ao;
    surface.bounce = float3(0.0);
    if (push.bounce_texture != INVALID_ID) surface.bounce = fetchTexel(push.bounce_texture, pixel).rgb * push.bounce_strength;
    surface.view_depth = -(mul(frame.view, float4(world_position, 1.0))).z;
    surface.clearcoat = clamp(clearcoat, 0.0, 1.0);
    surface.clearcoat_roughness = clamp(clearcoat_roughness, 0.0, 1.0);
    surface.coat_normal = coat_normal;
    surface.sheen_color = sheen_color;
    surface.sheen_roughness = clamp(sheen_roughness, 0.07, 1.0);
    surface.subsurface = material.subsurface;
    surface.anisotropy = 0.0;
    surface.grain = float3(1.0, 0.0, 0.0);
    if (material.anisotropy > 0.0 && dot(tangent, tangent) > 1e-12) {
        float3 along_u = normalize(tangent - normal * dot(normal, tangent));
        float3 along_v = cross(normal, along_u) * (tangent_object.w < 0.0 ? -1.0 : 1.0);
        surface.grain = normalize(along_u * cos(material.anisotropy_rotation) + along_v * sin(material.anisotropy_rotation));
        surface.anisotropy = material.anisotropy;
    }
    float noise = interleavedGradientNoise(fragment.xy, frame.frame_index);

    if (push.debug_view != 0u) {
        float3 debug = float3(0.0);
        switch (push.debug_view) {
        case 1u: debug = base_color.rgb; break;
        case 2u: debug = normal * 0.5 + 0.5; break;
        case 3u: debug = float3(roughness); break;
        case 4u: debug = float3(metallic); break;
        case 5u: debug = float3(ao); break;
        case 6u: debug = float3(sunShadow(frame, world_position, normal, clamp(dot(normal, frame.sun_direction), 0.0, 1.0), surface.view_depth, noise)); break;
        case 7u: {
            uint cascade = 0u;
            for (uint i = 0u; i < 3u; i++) {
                if (surface.view_depth > frame.shadows.cascade_splits[i]) cascade = i + 1u;
            }
            const float3 tints[4] = { float3(1.0, 0.3, 0.3), float3(0.3, 1.0, 0.3), float3(0.3, 0.4, 1.0), float3(1.0, 1.0, 0.3) };
            float3 tint = surface.view_depth > frame.shadows.cascade_splits[3] ? float3(0.5) : tints[cascade];
            debug = tint * (0.3 + 0.7 * luminance(base_color.rgb));
            break;
        }
        case 8u: debug = float3(abs(result.motion) * 40.0, 0.0); break;
        case 9u: debug = float3(frac(surface.view_depth * 0.25), frac(surface.view_depth), frac(surface.view_depth * 4.0)); break;
        case 10u: debug = hashColor(id >> 7); break;
        default: debug = hashColor(id); break;
        }
        result.color = float4(debug, 1.0);
#ifndef PLAIN
        result.reflection = float4(0.0);
        result.surface = float4(0.0);
#endif
        return result;
    }

    float4 gathered = float4(0.0);
    if (push.gi_texture != INVALID_ID) {
        int2 size = int2(textureSize(push.gi_texture));
        float2 position = in_uv * float2(size) - 0.5;
        int2 corner = int2(floor(position));
        float2 f = position - float2(corner);
        float4 total = float4(0.0);
        float weight_total = 0.0;
        for (int i = 0; i < 4; i++) {
            int2 offset = int2(i & 1, i >> 1);
            float4 tap = fetchTexel(push.gi_texture, clamp(corner + offset, int2(0), size - 1));
            float bilinear = (offset.x == 0 ? 1.0 - f.x : f.x) * (offset.y == 0 ? 1.0 - f.y : f.y);
            float weight = bilinear / (1e-3 + abs(tap.a - surface.view_depth) / max(surface.view_depth, 1e-3) * 20.0);
            total += float4(tap.rgb, 1.0) * weight;
            weight_total += weight;
        }
        gathered = float4(total.rgb / max(weight_total, 1e-6), 1.0);
    }
    soft_history_texture = push.shadow_history;
    soft_history_uv = in_uv - result.motion;
    soft_history_depth_texture = push.shadow_depth;
    soft_history_depth = linearDepth(previous_clip.z / previous_clip.w, frame.depth_terms);
    soft_history_slack = 0.05 * soft_history_depth + 2.0 * fwidth(soft_history_depth);
    if (instance.lightmap != INVALID_ID) gathered = float4(sampleTextureLod(instance.lightmap, frame.sampler_linear_clamp, raw1, 0.0).rgb, 1.0);
    float3 lit = emissive + shadeSurface(frame, surface, fragment.xy, noise, gathered);
    if ((SHADE_FEATURES & FEATURE_AERIAL) != 0u && frame.shading.aerial != 0.0 && frame.environment != 0u) {
        float3 air_through;
        float3 air;
        aerialHaze(frame, view_direction, length(world_position - eyePoint(frame, world_position)), air_through, air);
        lit = lit * air_through + air * (1.0 - air_through);
    }
    result.color = float4(lit, soft_shadow_visibility);
#ifndef PLAIN
    result.reflection = float4(deferred_reflection.rgb, roughness);
    result.surface = float4(encodeNormal(normal), deferred_reflection.a, 1.0);
#endif
    return result;
}
