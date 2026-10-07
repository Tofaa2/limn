#include "common.glsl"
#define DEFER_REFLECTIONS
// Only passes that do not write depth may read it.
#define CONTACT_SHADOWS
#include "shading.glsl"

// Visibility-buffer shading: each pixel refetches its triangle, computes
// barycentrics with analytic derivatives, samples the material and lights it.
// Outputs lit color and motion vectors.
layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    uint visibility_texture;
    uint ao_texture;
    uint debug_view;
    // Reduced-resolution probe irradiance (rgb) and its depth (a), or
    // INVALID_ID for per-pixel probes.
    uint gi_texture;
    // Built-in pass: bit i set when material shader i has its own pass. Custom
    // pass: the material shader this pass is for.
    uint material_shader;
    // Last frame's TAA output, whose alpha holds soft-shadow visibility, or
    // INVALID_ID.
    uint shadow_history;
    // Bounce light from gtao.frag, or INVALID_ID, and its strength.
    uint bounce_texture;
    float bounce_strength;
} push;

layout(location = 0) in vec2 in_uv;

layout(location = 0) out vec4 out_color;
layout(location = 1) out vec2 out_motion;   // current uv - previous uv
// For the reflection pass: specular weight and roughness, then octahedral
// normal and sky visibility.
layout(location = 2) out vec4 out_reflection;
layout(location = 3) out vec4 out_surface;

// Material outputs. A custom material shader receives the standard material's
// values and may change any.
struct MaterialSurface {
    vec3 base_color;
    float metallic;
    float roughness;
    // Material AO, 1 = unoccluded.
    float occlusion;
    vec3 emissive;
    // World-space shading normal.
    vec3 normal;
    // Clearcoat strength, roughness and world-space normal.
    float clearcoat;
    float clearcoat_roughness;
    vec3 clearcoat_normal;
};

struct MaterialContext {
    vec3 position;        // world space
    vec3 geometric_normal;
    vec3 view;            // towards the camera
    vec2 uv;
    vec2 uv_dx;
    vec2 uv_dy;
    float time;           // seconds
    vec4 params;          // the material's `params`
    uint instance;        // index into frame.instances
    vec4 instance_params; // the entity's or the copy's `params`
};

#ifdef CUSTOM_MATERIAL
// Defined by the file that includes this one.
void customMaterial(inout MaterialSurface surface, MaterialContext context, FrameConstants frame);
#endif

struct Barycentrics {
    vec3 lambda;
    vec3 ddx;
    vec3 ddy;
};

// Barycentrics after "Deferred Attribute Interpolation Shading", for Vulkan NDC
// (y down).
Barycentrics barycentrics(vec4 p0, vec4 p1, vec4 p2, vec2 ndc, vec2 resolution) {
    Barycentrics result;
    vec3 inv_w = 1.0 / vec3(p0.w, p1.w, p2.w);
    vec2 n0 = p0.xy * inv_w.x;
    vec2 n1 = p1.xy * inv_w.y;
    vec2 n2 = p2.xy * inv_w.z;
    float inv_det = 1.0 / determinant(mat2(n2 - n1, n0 - n1));
    result.ddx = vec3(n1.y - n2.y, n2.y - n0.y, n0.y - n1.y) * inv_det * inv_w;
    result.ddy = vec3(n2.x - n1.x, n0.x - n2.x, n1.x - n0.x) * inv_det * inv_w;
    float ddx_sum = dot(result.ddx, vec3(1.0));
    float ddy_sum = dot(result.ddy, vec3(1.0));
    vec2 delta = ndc - n0;
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

vec3 hashColor(uint value) {
    value = (value ^ 61u) ^ (value >> 16u);
    value *= 9u;
    value ^= value >> 4u;
    value *= 0x27d4eb2du;
    value ^= value >> 15u;
    return vec3(float(value & 255u), float((value >> 8u) & 255u), float((value >> 16u) & 255u)) / 255.0;
}

// Cofactor matrix: the inverse transpose up to scale.
mat3 normalMatrix(mat4x3 m) {
    vec3 c0 = m[0];
    vec3 c1 = m[1];
    vec3 c2 = m[2];
    return mat3(cross(c1, c2), cross(c2, c0), cross(c0, c1));
}

void main() {
    FrameConstants frame = push.frame;
    uint nearest = frame.sampler_nearest_clamp;
    ivec2 pixel = ivec2(gl_FragCoord.xy);
    uint id = texelFetch(TEX_UINT(push.visibility_texture, nearest), pixel, 0).r;
    vec2 ndc = in_uv * 2.0 - 1.0;

    if (id == INVALID_ID) {
#ifdef CUSTOM_MATERIAL
        discard;
#endif
        // Sky: camera motion only.
        vec4 world = frame.inv_view_proj * vec4(ndc, 1e-6, 1.0);
        vec3 direction = normalize(world.xyz / world.w - frame.camera_position);
        vec4 current = frame.view_proj_unjittered * vec4(direction, 0.0);
        vec4 previous = frame.prev_view_proj_unjittered * vec4(direction, 0.0);
        vec3 sky = vec3(0.0);
        if ((frame.flags & FRAME_ENVIRONMENT) != 0u)
            sky = textureLod(TEX_CUBE(frame.env_sky, frame.sampler_linear_clamp), direction, 0.0).rgb * frame.env_intensity;
        out_color = vec4(sky, 1.0);
        out_reflection = vec4(0.0);
        out_surface = vec4(0.0);
        out_motion = (current.xy / current.w - previous.xy / previous.w) * 0.5;
        return;
    }

    MeshletRef ref = frame.meshlet_refs.data[id >> 7];
    uint triangle = id & 127u;
    Instance instance = frame.instances.data[ref.instance];
    Mesh mesh = frame.meshes.data[instance.mesh];
    Meshlet meshlet = frame.meshlets.data[ref.meshlet];
    Material material = frame.materials.data[instance.material];
#ifdef CUSTOM_MATERIAL
    if (material.shader != push.material_shader) discard;
#else
    // Materials with their own shading pass are skipped.
    if (material.shader != 0u && ((push.material_shader >> material.shader) & 1u) != 0u) discard;
#endif

    uint base = mesh.index_offset + meshlet.index_offset + triangle * 3u;
    uint i0 = frame.indices.data[base];
    uint i1 = frame.indices.data[base + 1u];
    uint i2 = frame.indices.data[base + 2u];
    Vertex v0 = frame.vertices.data[instance.vertex_offset + i0];
    Vertex v1 = frame.vertices.data[instance.vertex_offset + i1];
    Vertex v2 = frame.vertices.data[instance.vertex_offset + i2];

    vec3 w0 = (instance.transform * vec4(v0.position, 1.0)).xyz;
    vec3 w1 = (instance.transform * vec4(v1.position, 1.0)).xyz;
    vec3 w2 = (instance.transform * vec4(v2.position, 1.0)).xyz;
    // Same wind sway as the geometry pass.
    float sway = frame.materials.data[instance.material].sway;
    if (sway != 0.0) {
        vec3 stands = instance.transform[3].xyz;
        w0 += swayOffset(sway, stands, w0, frame.time);
        w1 += swayOffset(sway, stands, w1, frame.time);
        w2 += swayOffset(sway, stands, w2, frame.time);
    }
    vec4 clip0 = frame.view_proj * vec4(w0, 1.0);
    vec4 clip1 = frame.view_proj * vec4(w1, 1.0);
    vec4 clip2 = frame.view_proj * vec4(w2, 1.0);
    Barycentrics bary = barycentrics(clip0, clip1, clip2, ndc, frame.resolution);
    vec3 lambda = bary.lambda;

    vec2 raw0 = v0.uv * lambda.x + v1.uv * lambda.y + v2.uv * lambda.z;
    vec2 raw0_dx = (v0.uv * bary.ddx.x + v1.uv * bary.ddx.y + v2.uv * bary.ddx.z) * frame.texture_gradient_scale;
    vec2 raw0_dy = (v0.uv * bary.ddy.x + v1.uv * bary.ddy.y + v2.uv * bary.ddy.z) * frame.texture_gradient_scale;
    vec2 raw1 = v0.uv1 * lambda.x + v1.uv1 * lambda.y + v2.uv1 * lambda.z;
    vec2 raw1_dx = (v0.uv1 * bary.ddx.x + v1.uv1 * bary.ddx.y + v2.uv1 * bary.ddx.z) * frame.texture_gradient_scale;
    vec2 raw1_dy = (v0.uv1 * bary.ddy.x + v1.uv1 * bary.ddy.y + v2.uv1 * bary.ddy.z) * frame.texture_gradient_scale;
    vec2 uv = materialUv(material, raw0);
    vec2 uv_dx = materialUvDerivative(material, raw0_dx);
    vec2 uv_dy = materialUvDerivative(material, raw0_dy);
    vec2 uvb = materialUv(material, raw1);
    vec2 uvb_dx = materialUvDerivative(material, raw1_dx);
    vec2 uvb_dy = materialUvDerivative(material, raw1_dy);
#define UV_PICK(bit, second, first) (((material.uv_sets >> bit) & 1u) != 0u ? second : first)
#define UV_OF(bit) textureUv(frame, material, uint(bit), UV_PICK(bit, uvb, uv), UV_PICK(bit, raw1, raw0), true), textureUv(frame, material, uint(bit), UV_PICK(bit, uvb_dx, uv_dx), UV_PICK(bit, raw1_dx, raw0_dx), false), textureUv(frame, material, uint(bit), UV_PICK(bit, uvb_dy, uv_dy), UV_PICK(bit, raw1_dy, raw0_dy), false)

    vec3 world_position = w0 * lambda.x + w1 * lambda.y + w2 * lambda.z;
    mat3 normal_matrix = normalMatrix(instance.transform);
    vec3 geometric_normal = normalize(normal_matrix * cross(v1.position - v0.position, v2.position - v0.position));
    vec3 normal = normalize(normal_matrix * (vertexNormal(v0) * lambda.x + vertexNormal(v1) * lambda.y + vertexNormal(v2) * lambda.z));
    vec4 tangent_object = vertexTangent(v0) * lambda.x + vertexTangent(v1) * lambda.y + vertexTangent(v2) * lambda.z;
    vec3 tangent = mat3(instance.transform) * tangent_object.xyz;

    vec3 view_direction = normalize(frame.camera_position - world_position);
    if ((material.flags & MATERIAL_DOUBLE_SIDED) != 0u && dot(geometric_normal, view_direction) < 0.0) {
        normal = -normal;
    }

    uint s = material.sampler_index;
    vec4 base_color = material.base_color;
    if (material.base_color_texture != INVALID_ID)
        base_color *= textureGrad(TEX(material.base_color_texture, s), UV_OF(0));
    base_color.rgb *= unpackUnorm4x8(instance.tint).rgb;
    base_color *= unpackUnorm4x8(v0.color) * lambda.x + unpackUnorm4x8(v1.color) * lambda.y + unpackUnorm4x8(v2.color) * lambda.z;

    uint d = material.detail_sampler;
    float roughness = material.roughness;
    float metallic = material.metallic;
    vec4 mr = vec4(1.0);
    if (material.metallic_roughness_texture != INVALID_ID) {
        mr = textureGrad(TEX(material.metallic_roughness_texture, d), UV_OF(2));
        roughness *= mr.g;
        metallic *= mr.b;
    }
    roughness = clamp(roughness, 0.045, 1.0);
    metallic = clamp(metallic, 0.0, 1.0);

    float ao = 1.0;
    if (material.occlusion_texture != INVALID_ID) {
        // Occlusion may share the metallic-roughness image (ORM).
        float sampled = material.occlusion_texture == material.metallic_roughness_texture && ((material.uv_sets >> 2) & 1u) == ((material.uv_sets >> 3) & 1u) && ((SHADE_FEATURES & FEATURE_TEXTURE_TRANSFORMS) == 0u || material.texture_transforms == INVALID_ID)
            ? mr.r
            : textureGrad(TEX(material.occlusion_texture, d), UV_OF(3)).r;
        ao = mix(1.0, sampled, material.occlusion_strength);
    }
    float screen_ao = 1.0;
    if ((frame.flags & FRAME_AMBIENT_OCCLUSION) != 0u)
        screen_ao = texelFetch(TEX(push.ao_texture, nearest), pixel, 0).r;

    vec3 emissive = material.emissive;
    if (material.emissive_texture != INVALID_ID && dot(emissive, vec3(1.0)) > 0.0)
        emissive *= textureGrad(TEX(material.emissive_texture, d), UV_OF(4)).rgb;

    vec3 coat_normal = normal;
    float clearcoat = material.clearcoat;
    float clearcoat_roughness = material.clearcoat_roughness;
    if (clearcoat > 0.0) {
        if (material.clearcoat_texture != INVALID_ID) clearcoat *= textureGrad(TEX(material.clearcoat_texture, d), UV_OF(5)).r;
        if (material.clearcoat_roughness_texture != INVALID_ID) clearcoat_roughness *= textureGrad(TEX(material.clearcoat_roughness_texture, d), UV_OF(6)).g;
        if (material.clearcoat_normal_texture != INVALID_ID && dot(tangent, tangent) > 1e-12) {
            vec3 t = normalize(tangent - normal * dot(normal, tangent));
            vec3 b = cross(normal, t) * (tangent_object.w < 0.0 ? -1.0 : 1.0);
            vec3 sampled = vec3(textureGrad(TEX(material.clearcoat_normal_texture, s), UV_OF(7)).xy * 2.0 - 1.0, 0.0);
            sampled.z = sqrt(max(1.0 - dot(sampled.xy, sampled.xy), 0.0));
            sampled.xy *= material.clearcoat_normal_scale;
            coat_normal = normalize(t * sampled.x + b * sampled.y + normal * sampled.z);
        }
    }
    vec3 sheen_color = material.sheen_color;
    float sheen_roughness = material.sheen_roughness;
    if (dot(sheen_color, vec3(1.0)) > 0.0) {
        if (material.sheen_color_texture != INVALID_ID) sheen_color *= textureGrad(TEX(material.sheen_color_texture, s), UV_OF(8)).rgb;
        if (material.sheen_roughness_texture != INVALID_ID) sheen_roughness *= textureGrad(TEX(material.sheen_roughness_texture, d), UV_OF(9)).a;
    }

    if (material.normal_texture != INVALID_ID && dot(tangent, tangent) > 1e-12) {
        vec3 t = normalize(tangent - normal * dot(normal, tangent));
        vec3 b = cross(normal, t) * (tangent_object.w < 0.0 ? -1.0 : 1.0);
        // Two-channel normal maps: z is reconstructed.
        vec3 sampled = vec3(textureGrad(TEX(material.normal_texture, s), UV_OF(1)).xy * 2.0 - 1.0, 0.0);
        sampled.z = sqrt(max(1.0 - dot(sampled.xy, sampled.xy), 0.0));
        sampled.xy *= material.normal_scale;
        normal = normalize(t * sampled.x + b * sampled.y + normal * sampled.z);
    }

#ifdef CUSTOM_MATERIAL
    {
        MaterialSurface custom = MaterialSurface(base_color.rgb, metallic, roughness, ao, emissive, normal, clearcoat, clearcoat_roughness, coat_normal);
        MaterialContext context = MaterialContext(world_position, geometric_normal, view_direction, uv, uv_dx, uv_dy,
            frame.time, material.params, ref.instance, instance.params);
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
    DECAL_LOOP_BEGIN(world_position)
        Decal decal = frame.decals.data[i];
        vec3 local = (decal.world_to_decal * vec4(world_position, 1.0)).xyz;
        if (any(greaterThan(abs(local), vec3(0.5)))) continue;
        // Projection axis: gradient of local z.
        vec3 axis = normalize(vec3(decal.world_to_decal[0][2], decal.world_to_decal[1][2], decal.world_to_decal[2][2]));
        float facing = dot(geometric_normal, axis) * (dot(geometric_normal, view_direction) < 0.0 ? -1.0 : 1.0);
        float weight = smoothstep(decal.angle_fade, decal.angle_fade + 0.25, facing);
        weight *= 1.0 - smoothstep(0.35, 0.5, abs(local.z));
        vec4 tint = decal.color;
        if (decal.image != INVALID_ID) {
            vec2 decal_uv = vec2(local.x + 0.5, 0.5 - local.y);
            tint *= textureGrad(TEX(decal.image, frame.sampler_linear_clamp), decal_uv, dFdx(decal_uv), dFdy(decal_uv));
        }
        weight *= tint.a;
        base_color.rgb = mix(base_color.rgb, tint.rgb, weight);
        emissive += tint.rgb * (decal.emissive * weight);
        if (decal.roughness >= 0.0) roughness = mix(roughness, clamp(decal.roughness, 0.045, 1.0), weight);
        if (decal.normal_image != INVALID_ID) {
            vec2 decal_uv = vec2(local.x + 0.5, 0.5 - local.y);
            vec3 mapped = textureGrad(TEX(decal.normal_image, frame.sampler_linear_clamp), decal_uv, dFdx(decal_uv), dFdy(decal_uv)).xyz * 2.0 - 1.0;
            mapped.xy *= decal.normal_strength;
            vec3 right = normalize(vec3(decal.world_to_decal[0][0], decal.world_to_decal[1][0], decal.world_to_decal[2][0]));
            vec3 up = normalize(vec3(decal.world_to_decal[0][1], decal.world_to_decal[1][1], decal.world_to_decal[2][1]));
            vec3 bent = normalize(normal + right * mapped.x + up * mapped.y);
            normal = normalize(mix(normal, bent, weight));
        }
    }

    ao = min(ao, screen_ao);

    // Previous position from last frame's vertices and transform; static
    // instances skip the fetches.
    vec3 previous_world = world_position;
    if ((instance.flags & INSTANCE_MOVING) != 0u) {
        vec3 p0 = frame.vertices.data[instance.previous_vertex_offset + i0].position;
        vec3 p1 = frame.vertices.data[instance.previous_vertex_offset + i1].position;
        vec3 p2 = frame.vertices.data[instance.previous_vertex_offset + i2].position;
        previous_world = previousTransform(frame, instance, ref.instance) * vec4(p0 * lambda.x + p1 * lambda.y + p2 * lambda.z, 1.0);
    }
    if (sway != 0.0) previous_world += swayOffset(sway, previousTransform(frame, instance, ref.instance)[3], previous_world, frame.time - frame.delta_time) - swayOffset(sway, previousTransform(frame, instance, ref.instance)[3], previous_world, frame.time);
    vec4 current_clip = frame.view_proj_unjittered * vec4(world_position, 1.0);
    vec4 previous_clip = frame.prev_view_proj_unjittered * vec4(previous_world, 1.0);
    out_motion = (current_clip.xy / current_clip.w - previous_clip.xy / previous_clip.w) * 0.5;

    if ((frame.flags & FRAME_SPECULAR_AA) != 0u) {
        // Specular antialiasing (Kaplanyan et al.).
        vec3 normal_dx = dFdx(normal);
        vec3 normal_dy = dFdy(normal);
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
    surface.f0 = mix(vec3(0.04), base_color.rgb, metallic);
    surface.roughness = roughness;
    surface.ao = ao;
    surface.bounce = push.bounce_texture != INVALID_ID ? texelFetch(TEX(push.bounce_texture, nearest), pixel, 0).rgb * push.bounce_strength : vec3(0.0);
    surface.view_depth = -(frame.view * vec4(world_position, 1.0)).z;
    surface.clearcoat = clamp(clearcoat, 0.0, 1.0);
    surface.clearcoat_roughness = clamp(clearcoat_roughness, 0.0, 1.0);
    surface.coat_normal = coat_normal;
    surface.sheen_color = sheen_color;
    surface.sheen_roughness = clamp(sheen_roughness, 0.07, 1.0);
    surface.subsurface = material.subsurface;
    surface.anisotropy = 0.0;
    surface.grain = vec3(1.0, 0.0, 0.0);
    if (material.anisotropy > 0.0 && dot(tangent, tangent) > 1e-12) {
        vec3 along_u = normalize(tangent - normal * dot(normal, tangent));
        vec3 along_v = cross(normal, along_u) * (tangent_object.w < 0.0 ? -1.0 : 1.0);
        surface.grain = normalize(along_u * cos(material.anisotropy_rotation) + along_v * sin(material.anisotropy_rotation));
        surface.anisotropy = material.anisotropy;
    }
    float noise = interleavedGradientNoise(gl_FragCoord.xy, frame.frame_index);

    if (push.debug_view != 0u) {
        // Must match `DebugView` in renderer.zig. Output is display-referred.
        vec3 debug = vec3(0.0);
        switch (push.debug_view) {
        case 1u: debug = base_color.rgb; break;
        case 2u: debug = normal * 0.5 + 0.5; break;
        case 3u: debug = vec3(roughness); break;
        case 4u: debug = vec3(metallic); break;
        case 5u: debug = vec3(ao); break;
        case 6u: debug = vec3(sunShadow(frame, world_position, normal, clamp(dot(normal, frame.sun_direction), 0.0, 1.0), surface.view_depth, noise)); break;
        case 7u: {
            uint cascade = 0u;
            for (uint i = 0u; i < 3u; i++) {
                if (surface.view_depth > frame.cascade_splits[i]) cascade = i + 1u;
            }
            const vec3 tints[4] = vec3[](vec3(1.0, 0.3, 0.3), vec3(0.3, 1.0, 0.3), vec3(0.3, 0.4, 1.0), vec3(1.0, 1.0, 0.3));
            vec3 tint = surface.view_depth > frame.cascade_splits[3] ? vec3(0.5) : tints[cascade];
            debug = tint * (0.3 + 0.7 * luminance(base_color.rgb));
            break;
        }
        case 8u: debug = vec3(abs(out_motion) * 40.0, 0.0); break;
        case 9u: debug = vec3(fract(surface.view_depth * 0.25), fract(surface.view_depth), fract(surface.view_depth * 4.0)); break;
        case 10u: debug = hashColor(id >> 7); break;
        default: debug = hashColor(id); break;
        }
        out_color = vec4(debug, 1.0);
        out_reflection = vec4(0.0);
        out_surface = vec4(0.0);
        return;
    }

    vec4 gathered = vec4(0.0);
    if (push.gi_texture != INVALID_ID) {
        ivec2 size = textureSize(TEX(push.gi_texture, nearest), 0);
        vec2 position = in_uv * vec2(size) - 0.5;
        ivec2 corner = ivec2(floor(position));
        vec2 f = position - vec2(corner);
        vec4 total = vec4(0.0);
        float weight_total = 0.0;
        for (int i = 0; i < 4; i++) {
            ivec2 offset = ivec2(i & 1, i >> 1);
            vec4 tap = texelFetch(TEX(push.gi_texture, nearest), clamp(corner + offset, ivec2(0), size - 1), 0);
            float bilinear = (offset.x == 0 ? 1.0 - f.x : f.x) * (offset.y == 0 ? 1.0 - f.y : f.y);
            float weight = bilinear / (1e-3 + abs(tap.a - surface.view_depth) / max(surface.view_depth, 1e-3) * 20.0);
            total += vec4(tap.rgb, 1.0) * weight;
            weight_total += weight;
        }
        gathered = vec4(total.rgb / max(weight_total, 1e-6), 1.0);
    }
    if (push.shadow_history != INVALID_ID) {
        vec2 previous_uv = in_uv - out_motion;
        if (all(greaterThanEqual(previous_uv, vec2(0.0))) && all(lessThanEqual(previous_uv, vec2(1.0)))) {
            // Soft-shadow history: this pixel and four neighbours. Values above
            // 1 hold no result.
            ivec2 history_size = textureSize(TEX(push.shadow_history, frame.sampler_nearest_clamp), 0);
            ivec2 at = ivec2(previous_uv * vec2(history_size));
            ivec2 last = history_size - 1;
            const ivec2 offsets[5] = ivec2[](ivec2(0, 0), ivec2(1, 0), ivec2(-1, 0), ivec2(0, 1), ivec2(0, -1));
            float here = frame.contact_depth != INVALID_ID ? linearDepth(texelFetch(TEX(frame.contact_depth, frame.sampler_nearest_clamp), pixel, 0).r, frame.near) : 0.0;
            float total = 0.0;
            float weight = 0.0;
            for (int i = 0; i < 5; i++) {
                float value = texelFetch(TEX(push.shadow_history, frame.sampler_nearest_clamp), clamp(at + offsets[i], ivec2(0), last), 0).a;
                if (value > 1.0) continue;
                if (i != 0 && here > 0.0) {
                    float there = linearDepth(texelFetch(TEX(frame.contact_depth, frame.sampler_nearest_clamp), clamp(pixel + offsets[i], ivec2(0), ivec2(frame.resolution) - 1), 0).r, frame.near);
                    if (abs(there - here) > 0.03 * here) continue;
                }
                float tap = i == 0 ? 2.0 : 1.0;
                total += value * tap;
                weight += tap;
            }
            if (weight > 0.0) soft_shadow_history = total / weight;
        }
    }
    if (instance.lightmap != INVALID_ID) gathered = vec4(textureLod(TEX(instance.lightmap, frame.sampler_linear_clamp), raw1, 0.0).rgb, 1.0);
    vec3 lit = emissive + shadeSurface(frame, surface, gl_FragCoord.xy, noise, gathered);
    if ((SHADE_FEATURES & FEATURE_AERIAL) != 0u && frame.aerial != 0.0 && (frame.flags & FRAME_ENVIRONMENT) != 0u) {
        // Aerial perspective (see aerialHaze).
        vec3 air_through;
        vec3 air;
        aerialHaze(frame, view_direction, length(world_position - frame.camera_position), air_through, air);
        lit = lit * air_through + air * (1.0 - air_through);
    }
    out_color = vec4(lit, soft_shadow_visibility);
    out_reflection = vec4(deferred_reflection.rgb, roughness);
    out_surface = vec4(encodeNormal(normal), deferred_reflection.a, 1.0);
}
