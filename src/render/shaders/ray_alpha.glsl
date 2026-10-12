#ifndef RAY_ALPHA_GLSL
#define RAY_ALPHA_GLSL

// Whether a ray query's candidate hit lands on a drawn part of its surface.
// Only geometry built without the opaque flag reaches this: meshes whose
// material is alpha tested.
bool rayCandidateSolid(FrameConstants frame, uint instance_index, uint primitive, vec2 barycentric) {
    Instance instance = frame.instances.data[instance_index];
    Material material = frame.materials.data[instance.material];
    if ((material.flags & MATERIAL_ALPHA_TEST) == 0u) return true;
    Mesh mesh = frame.meshes.data[instance.mesh];
    uint base = mesh.index_offset + primitive * 3u;
    Vertex v0 = frame.vertices.data[instance.vertex_offset + frame.indices.data[base]];
    Vertex v1 = frame.vertices.data[instance.vertex_offset + frame.indices.data[base + 1u]];
    Vertex v2 = frame.vertices.data[instance.vertex_offset + frame.indices.data[base + 2u]];
    vec3 lambda = vec3(1.0 - barycentric.x - barycentric.y, barycentric.x, barycentric.y);
    float alpha = material.base_color.a * (unpackUnorm4x8(v0.color).a * lambda.x + unpackUnorm4x8(v1.color).a * lambda.y + unpackUnorm4x8(v2.color).a * lambda.z);
    if (material.base_color_texture != INVALID_ID) {
        vec2 uv = (material.uv_sets & 1u) != 0u
            ? v0.uv1 * lambda.x + v1.uv1 * lambda.y + v2.uv1 * lambda.z
            : v0.uv * lambda.x + v1.uv * lambda.y + v2.uv * lambda.z;
        alpha *= textureLod(TEX(material.base_color_texture, material.sampler_index), materialUv(material, uv), 0.0).a;
    }
    return alpha >= material.alpha_cutoff;
}

// Steps a ray query to its end, letting it through the cut-out parts of
// alpha tested surfaces.
#define RAY_PROCEED(frame, query) \
    while (rayQueryProceedEXT(query)) { \
        if (rayQueryGetIntersectionTypeEXT(query, false) == gl_RayQueryCandidateIntersectionTriangleEXT && \
            rayCandidateSolid(frame, uint(rayQueryGetIntersectionInstanceCustomIndexEXT(query, false)), uint(rayQueryGetIntersectionPrimitiveIndexEXT(query, false)), rayQueryGetIntersectionBarycentricsEXT(query, false))) \
            rayQueryConfirmIntersectionEXT(query); \
    }

#endif
