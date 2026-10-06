#version 460
#ifdef RAY_TRACED
#extension GL_EXT_ray_query : require
#endif
#extension GL_EXT_shader_explicit_arithmetic_types_int64 : require
#include "common.glsl"
#include "brdf.glsl"

// Path tracing: for every pixel a ray from the camera is followed from
// surface to surface, gathering the light of the sun, the lamps, the sky
// and whatever glows, the way light itself travels, only backwards. One
// frame's answer is noisy; the pass blends each new one into the average
// of those before it, so a picture left alone sharpens by the second.
layout(push_constant, scalar) uniform Push {
    FrameConstants frame;
    // The acceleration structure (ray tracing hardware), or the scene's
    // tree of boxes (without).
    uint64_t scene;
    uint64_t scene_instances;
    uint64_t mesh_nodes;
    uint64_t mesh_items;
    // How many frames have gone into the average so far.
    uint gathered;
    uint bounces;
    uint samples;
    // Most light one path may bring back, against sparkle.
    float clamp_radiance;
    // Angular radius of the sun, for the softness of its shadows.
    float sun_radius;
    uint light_count;
    // The instances that glow evenly, to aim at, and how many.
    uint64_t glowing;
    uint glowing_count;
    // Last frame's gathered picture (rgb, and in alpha how many frames
    // each pixel has gathered) and guide (rgb, and in alpha how far
    // away what the pixel showed was).
    uint history_color;
    uint history_guide;
    // The camera has moved since, and where it was.
    uint moved;
    vec3 previous_camera;
    // 1 to start over.
    uint reset;
} push;

#ifdef RAY_TRACED
uint64_t traceScene() { return push.scene; }
#else
#endif
#include "trace.glsl"
#ifndef RAY_TRACED
BvhNodes traceSceneNodes() { return BvhNodes(push.scene); }
BvhInstances traceSceneInstances() { return BvhInstances(push.scene_instances); }
BvhNodes traceMeshNodes() { return BvhNodes(push.mesh_nodes); }
BvhItems traceMeshItems() { return BvhItems(push.mesh_items); }
FrameConstants traceFrame() { return push.frame; }
#endif

struct Glowing {
    uint instance;
    uint triangles;
};
layout(buffer_reference, scalar) readonly buffer GlowingList { Glowing data[]; };

layout(location = 0) out vec4 out_color;
// The color of the first thing each path meets, for the pass that clears
// the grain (pathtrace_denoise.frag); black where it is to keep its hands
// off: the sky, mirrors and what glows.
layout(location = 1) out vec4 out_guide;

vec3 first_color;
bool first_met;
// How far from the camera that first thing is.
float first_distance;

uint random_state;

uint pcg(uint value) {
    uint state = value * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

float random() {
    random_state = pcg(random_state);
    return float(random_state >> 8) / 16777216.0;
}

// What a ray met, ready to be lit.
struct Surface {
    vec3 position;
    // The triangle's own normal and the smoothed one, both toward where
    // the ray came from.
    vec3 flat_normal;
    vec3 normal;
    vec3 albedo;
    vec3 emissive;
    // It is one of the glowing things paths aim at (see directLight).
    bool even_glow;
    float metallic;
    float roughness;
    // How much of the light passes straight through (see-through
    // materials and cut-outs).
    float through;
};

Surface surfaceAt(FrameConstants frame, TraceHit hit, vec3 origin, vec3 direction, float lod) {
    Surface surface;
    Instance instance = frame.instances.data[hit.instance];
    Mesh mesh = frame.meshes.data[instance.mesh];
    Material material = frame.materials.data[instance.material];
    uint base = mesh.index_offset + hit.primitive * 3u;
    Vertex v0 = frame.vertices.data[instance.vertex_offset + frame.indices.data[base]];
    Vertex v1 = frame.vertices.data[instance.vertex_offset + frame.indices.data[base + 1u]];
    Vertex v2 = frame.vertices.data[instance.vertex_offset + frame.indices.data[base + 2u]];
    vec3 lambda = vec3(1.0 - hit.barycentric.x - hit.barycentric.y, hit.barycentric.x, hit.barycentric.y);

    mat3 normal_matrix = transpose(inverse(mat3(instance.transform)));
    surface.flat_normal = normalize(normal_matrix * cross(v1.position - v0.position, v2.position - v0.position));
    if (dot(surface.flat_normal, direction) > 0.0) surface.flat_normal = -surface.flat_normal;
    surface.normal = normalize(normal_matrix * (vertexNormal(v0) * lambda.x + vertexNormal(v1) * lambda.y + vertexNormal(v2) * lambda.z));
    if (dot(surface.normal, surface.flat_normal) < 0.0) surface.normal = -surface.normal;
    surface.position = origin + direction * hit.t;

    vec2 uv = v0.uv * lambda.x + v1.uv * lambda.y + v2.uv * lambda.z;
    vec2 uvb = v0.uv1 * lambda.x + v1.uv1 * lambda.y + v2.uv1 * lambda.z;
    vec4 base_color = material.base_color;
    if (material.base_color_texture != INVALID_ID)
        base_color *= textureLod(TEX(material.base_color_texture, material.sampler_index), materialUv(material, (material.uv_sets & 1u) != 0u ? uvb : uv), lod);
    base_color *= unpackUnorm4x8(v0.color) * lambda.x + unpackUnorm4x8(v1.color) * lambda.y + unpackUnorm4x8(v2.color) * lambda.z;
    base_color.rgb *= unpackUnorm4x8(instance.tint).rgb;
    surface.albedo = base_color.rgb;
    surface.metallic = material.metallic;
    surface.roughness = material.roughness;
    if (material.metallic_roughness_texture != INVALID_ID) {
        vec4 packed = textureLod(TEX(material.metallic_roughness_texture, material.sampler_index), materialUv(material, uv), lod);
        surface.metallic *= packed.b;
        surface.roughness *= packed.g;
    }
    surface.roughness = clamp(surface.roughness, 0.03, 1.0);
    surface.emissive = material.emissive;
    surface.even_glow = (instance.flags & INSTANCE_AIMED) != 0u;
    if (material.emissive_texture != INVALID_ID)
        surface.emissive *= textureLod(TEX(material.emissive_texture, material.sampler_index), materialUv(material, uv), lod).rgb;
    surface.through = 0.0;
    if ((material.flags & MATERIAL_ALPHA_TEST) != 0u && base_color.a < material.alpha_cutoff) surface.through = 1.0;
    else if ((material.flags & MATERIAL_BLEND) != 0u) surface.through = clamp(1.0 - base_color.a * (1.0 - material.transmission), 0.0, 1.0);
    // Stand-ins are for reflections and the like; a path sees past them.
    if ((instance.flags & INSTANCE_PROXY) != 0u) surface.through = 1.0;
    return surface;
}

// The light a surface sends toward `view` of what reaches it from
// `light`, the angle of arrival included.
vec3 surfaceResponse(Surface surface, vec3 view, vec3 light) {
    float n_dot_l = dot(surface.normal, light);
    float n_dot_v = max(dot(surface.normal, view), 1e-4);
    if (n_dot_l <= 0.0) return vec3(0.0);
    vec3 half_vector = normalize(view + light);
    float alpha = surface.roughness * surface.roughness;
    vec3 f0 = mix(vec3(0.04), surface.albedo, surface.metallic);
    vec3 fresnel = fresnelSchlick(max(dot(view, half_vector), 0.0), f0);
    vec3 specular = fresnel * distributionGgx(max(dot(surface.normal, half_vector), 0.0), alpha) * visibilitySmithGgx(n_dot_l, n_dot_v, alpha);
    vec3 diffuse = surface.albedo * (1.0 - surface.metallic) * (1.0 - fresnel) / PI;
    return (diffuse + specular) * n_dot_l;
}

vec3 skyLight(FrameConstants frame, vec3 direction, float lod) {
    if ((frame.flags & FRAME_ENVIRONMENT) == 0u) return vec3(0.0);
    return textureLod(TEX_CUBE(frame.env_specular, frame.sampler_linear_clamp), direction, lod).rgb * frame.env_intensity;
}

// Light arriving straight from the sun and the lamps, each asked with a
// ray of its own whether anything stands in the way.
vec3 directLight(FrameConstants frame, Surface surface, vec3 view) {
    vec3 total = vec3(0.0);
    vec3 guide = vec3(0.0);
    vec3 start = surface.position + surface.flat_normal * 0.002;
    if (dot(frame.sun_radiance, vec3(1.0)) > 0.0) {
        // A point on the sun's disc, so its shadows soften with distance.
        mat3 basis = tangentBasis(frame.sun_direction);
        float turn = 2.0 * PI * random();
        float reach = push.sun_radius * sqrt(random());
        vec3 toward = normalize(basis * vec3(cos(turn) * reach, sin(turn) * reach, 1.0));
        vec3 response = surfaceResponse(surface, view, toward);
        if (dot(response, vec3(1.0)) > 0.0 && dot(surface.flat_normal, toward) > 0.0 && !traceAny(start, toward, 1e4))
            total += response * frame.sun_radiance;
    }
    // One lamp a path's step, picked at random and weighed up for the
    // ones passed over: many lamps then cost no more than one.
    uint light_count = min(frame.light_count, push.light_count);
    if (light_count != 0u) {
        uint pick = min(uint(random() * float(light_count)), light_count - 1u);
        Light light = frame.lights.data[pick];
        vec3 toward;
        float attenuation = 1.0;
        float reach = 1e4;
        if ((light.flags & LIGHT_DIRECTIONAL) != 0u) {
            toward = -light.direction;
        } else {
            vec3 target = light.position;
            // A lamp with a size is lit from a point within it.
            if (light.source_radius > 0.0) target += (vec3(random(), random(), random()) * 2.0 - 1.0) * light.source_radius * 0.57;
            vec3 to_light = target - surface.position;
            float distance_squared = dot(to_light, to_light);
            float range_squared = light.range * light.range;
            if (distance_squared < range_squared) {
                float window = clamp(1.0 - (distance_squared * distance_squared) / (range_squared * range_squared), 0.0, 1.0);
                attenuation = window * window / max(distance_squared, 0.01);
                reach = sqrt(distance_squared);
                toward = to_light / max(reach, 1e-5);
                if ((light.flags & LIGHT_SPOT) != 0u) {
                    float cone = clamp(dot(-toward, light.direction) * light.cone_scale + light.cone_offset, 0.0, 1.0);
                    attenuation *= cone * cone;
                }
                if ((light.flags & LIGHT_RECTANGLE) != 0u) attenuation *= clamp(dot(-toward, light.direction), 0.0, 1.0);
            } else attenuation = 0.0;
        }
        if (attenuation > 1e-5) {
            vec3 response = surfaceResponse(surface, view, toward);
            if (dot(response, vec3(1.0)) > 0.0 && dot(surface.flat_normal, toward) > 0.0 && !traceAny(start, toward, reach - 0.004))
                total += response * light.color * attenuation * float(light_count);
        }
    }
    // And one glowing surface: a point on one of its triangles, weighed
    // up for all the points and surfaces passed over. A small bright
    // thing lights a room this way from the first frame, where chance
    // would take thousands.
    if (push.glowing_count != 0u) {
        GlowingList list = GlowingList(push.glowing);
        Glowing chosen = list.data[min(uint(random() * float(push.glowing_count)), push.glowing_count - 1u)];
        uint triangle = min(uint(random() * float(chosen.triangles)), chosen.triangles - 1u);
        Instance instance = frame.instances.data[chosen.instance];
        Mesh mesh = frame.meshes.data[instance.mesh];
        uint base = mesh.index_offset + triangle * 3u;
        vec3 p0 = (instance.transform * vec4(frame.vertices.data[instance.vertex_offset + frame.indices.data[base]].position, 1.0)).xyz;
        vec3 p1 = (instance.transform * vec4(frame.vertices.data[instance.vertex_offset + frame.indices.data[base + 1u]].position, 1.0)).xyz;
        vec3 p2 = (instance.transform * vec4(frame.vertices.data[instance.vertex_offset + frame.indices.data[base + 2u]].position, 1.0)).xyz;
        float side = sqrt(random());
        float along = random();
        vec2 weights = vec2(side * (1.0 - along), side * along);
        vec3 point = p0 + (p1 - p0) * weights.x + (p2 - p0) * weights.y;
        vec3 across = cross(p1 - p0, p2 - p0);
        float area = 0.5 * length(across);
        vec3 to_point = point - surface.position;
        float distance_squared = dot(to_point, to_point);
        if (area > 0.0 && distance_squared > 1e-8) {
            float reach = sqrt(distance_squared);
            vec3 toward = to_point / reach;
            // How squarely the triangle faces here; it glows from both sides.
            float facing = abs(dot(across, toward)) / (2.0 * area);
            vec3 response = surfaceResponse(surface, view, toward);
            if (facing > 1e-4 && dot(response, vec3(1.0)) > 0.0 && dot(surface.flat_normal, toward) > 0.0 && !traceAny(start, toward, reach - 0.004)) {
                Material material = frame.materials.data[instance.material];
                // Never more than if the point were a hand's breadth away.
                float spread = facing * area / max(distance_squared, 0.01);
                total += response * material.emissive * (spread * float(chosen.triangles) * float(push.glowing_count));
            }
        }
    }
    return total;
}

// Follows one path. What it gathers comes back in two parts: the light
// seen directly or in a mirror, which is the same from frame to frame,
// and in `indirect` the light that arrived by way of a rough bounce,
// where a rare lucky path can bring back far more than its share.
vec3 tracePath(FrameConstants frame, vec3 origin, vec3 direction, out vec3 indirect) {
    indirect = vec3(0.0);
    bool rough_bounce = false;
    vec3 gathered = vec3(0.0);
    vec3 carried = vec3(1.0);
    // How blurred the sky is read for a ray: sharp for the eye, softer
    // after a rough bounce, against sparkle from a small bright sun.
    float sky_lod = 0.0;
    float texture_lod = 0.0;
    for (uint bounce = 0u; bounce <= push.bounces; bounce++) {
        TraceHit hit;
        if (!traceClosest(origin, direction, 1e5, hit)) {
            vec3 sky = carried * skyLight(frame, direction, sky_lod);
            if (rough_bounce) indirect += sky;
            else gathered += sky;
            break;
        }
        Surface surface = surfaceAt(frame, hit, origin, direction, texture_lod);
        // A see-through surface lets that share of the paths straight on.
        if (surface.through > 0.0 && random() < surface.through) {
            origin = surface.position + direction * 0.002;
            continue;
        }
        if (!first_met) {
            first_met = true;
            first_distance = distance(surface.position, frame.camera_position);
            bool keep = surface.roughness < 0.1 || dot(surface.emissive, vec3(1.0)) > 0.0;
            first_color = keep ? vec3(0.0) : max(surface.albedo, vec3(0.03));
        }
        // What glows evenly was aimed at from the surface before; a
        // path that then runs into it as well would count it twice.
        if (rough_bounce) {
            if (!surface.even_glow) indirect += carried * surface.emissive;
        } else gathered += carried * surface.emissive;
        if (bounce == push.bounces) break;
        vec3 view = -direction;
        vec3 lit = carried * directLight(frame, surface, view);
        if (rough_bounce) indirect += lit;
        else gathered += lit;

        // Where the path goes next: off the surface as a mirror would
        // send it, or scattered, in the share each has in the material.
        vec3 f0 = mix(vec3(0.04), surface.albedo, surface.metallic);
        float n_dot_v = max(dot(surface.normal, view), 1e-4);
        vec3 fresnel_view = fresnelSchlick(n_dot_v, f0);
        vec3 scattered = surface.albedo * (1.0 - surface.metallic);
        float mirror_share = clamp(luminance(fresnel_view) / max(luminance(fresnel_view) + luminance(scattered), 1e-4), 0.1, 0.9);
        mat3 basis = tangentBasis(surface.normal);
        vec3 next;
        if (random() < mirror_share) {
            float alpha = surface.roughness * surface.roughness;
            vec3 half_vector = basis * importanceSampleGgx(vec2(random(), random()), alpha);
            next = reflect(direction, half_vector);
            float n_dot_l = dot(surface.normal, next);
            if (n_dot_l <= 0.0 || dot(surface.flat_normal, next) <= 0.0) break;
            float v_dot_h = max(dot(view, half_vector), 1e-4);
            float n_dot_h = max(dot(surface.normal, half_vector), 1e-4);
            // The response over the chance of having picked this way.
            vec3 fresnel = fresnelSchlick(v_dot_h, f0);
            carried *= fresnel * visibilitySmithGgx(n_dot_l, n_dot_v, alpha) * 4.0 * n_dot_l * v_dot_h / n_dot_h / mirror_share;
            sky_lod = max(sky_lod, surface.roughness * 4.0);
            // At a grazing angle the weight of one direction can run away.
            carried = min(carried, vec3(4.0));
            if (surface.roughness > 0.08) rough_bounce = true;
        } else {
            float turn = 2.0 * PI * random();
            float radius = sqrt(random());
            next = normalize(basis * vec3(cos(turn) * radius, sin(turn) * radius, sqrt(max(1.0 - radius * radius, 0.0))));
            if (dot(surface.flat_normal, next) <= 0.0) break;
            carried *= scattered * (1.0 - fresnel_view) / (1.0 - mirror_share);
            sky_lod = max(sky_lod, 3.0);
            rough_bounce = true;
        }
        texture_lod = 2.0;
        // Paths that carry little are ended by lot, the rest made up for
        // the ones ended.
        if (bounce >= 2u) {
            float keep = clamp(max(carried.r, max(carried.g, carried.b)), 0.05, 1.0);
            if (random() > keep) break;
            carried /= keep;
        }
        origin = surface.position + surface.flat_normal * 0.002;
        direction = next;
    }
    return gathered;
}

// Last frame's picture at a place between its pixels, by a curve through
// the pixels around rather than a straight blend of the nearest four:
// looked up afresh every frame, a straight blend would soften the
// picture a little more each time. (Catmull-Rom, gathered in five
// lookups.)
vec3 historySharp(uint texture_index, uint sampler_index, vec2 uv, vec2 size) {
    vec2 place = uv * size;
    vec2 base = floor(place - 0.5) + 0.5;
    vec2 f = place - base;
    vec2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
    vec2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
    vec2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
    vec2 w3 = f * f * (-0.5 + 0.5 * f);
    vec2 w12 = w1 + w2;
    vec2 near = (base + w2 / w12) / size;
    vec2 before = (base - 1.0) / size;
    vec2 after = (base + 2.0) / size;
    vec3 total = textureLod(TEX(texture_index, sampler_index), vec2(near.x, before.y), 0.0).rgb * (w12.x * w0.y);
    total += textureLod(TEX(texture_index, sampler_index), vec2(before.x, near.y), 0.0).rgb * (w0.x * w12.y);
    total += textureLod(TEX(texture_index, sampler_index), vec2(near.x, near.y), 0.0).rgb * (w12.x * w12.y);
    total += textureLod(TEX(texture_index, sampler_index), vec2(after.x, near.y), 0.0).rgb * (w3.x * w12.y);
    total += textureLod(TEX(texture_index, sampler_index), vec2(near.x, after.y), 0.0).rgb * (w12.x * w3.y);
    float weight = w12.x * w0.y + w0.x * w12.y + w12.x * w12.y + w3.x * w12.y + w12.x * w3.y;
    // The curve swings a little past what it passes through, most at a
    // bright speck; swung again every frame, that would grow without
    // end. It is held to what the four nearest pixels span.
    ivec2 corner = ivec2(base - 0.5);
    ivec2 last = ivec2(size) - 1;
    vec3 a = texelFetch(TEX(texture_index, sampler_index), clamp(corner, ivec2(0), last), 0).rgb;
    vec3 b = texelFetch(TEX(texture_index, sampler_index), clamp(corner + ivec2(1, 0), ivec2(0), last), 0).rgb;
    vec3 c = texelFetch(TEX(texture_index, sampler_index), clamp(corner + ivec2(0, 1), ivec2(0), last), 0).rgb;
    vec3 d = texelFetch(TEX(texture_index, sampler_index), clamp(corner + ivec2(1, 1), ivec2(0), last), 0).rgb;
    return clamp(total / weight, min(min(a, b), min(c, d)), max(max(a, b), max(c, d)));
}

void main() {
    FrameConstants frame = push.frame;
    ivec2 pixel = ivec2(gl_FragCoord.xy);
    random_state = pcg(uint(pixel.x) + pcg(uint(pixel.y) + pcg(push.gathered * 7919u + frame.frame_index)));
    vec3 total = vec3(0.0);
    vec3 guide = vec3(0.0);
    uint samples = max(push.samples, 1u);
    for (uint index = 0u; index < samples; index++) {
        // Somewhere within the pixel: the average over frames smooths
        // edges as it clears the noise.
        vec2 uv = (vec2(pixel) + vec2(random(), random())) * frame.inv_resolution;
        vec3 through = worldPositionFromDepth(uv, 0.5, frame.inv_view_proj);
        vec3 direction = normalize(through - frame.camera_position);
        first_met = false;
        first_distance = 60000.0;
        first_color = vec3(0.0);
        vec3 indirect;
        vec3 light = tracePath(frame, frame.camera_position, direction, indirect);
        // A number that is not one would poison the average for good.
        if (any(isnan(light)) || any(isinf(light))) light = vec3(0.0);
        if (any(isnan(indirect)) || any(isinf(indirect))) indirect = vec3(0.0);
        // One lucky path may not outshine its neighbours: what came by
        // a rough bounce is held to the limit, which trades a little of
        // the light of small bright things for a picture that clears.
        float brightness = luminance(indirect);
        if (brightness > push.clamp_radiance) indirect *= push.clamp_radiance / brightness;
        // What is gathered is the light arriving at the surface, with the
        // surface's own color divided out: the color is put back at
        // the end from this frame's sharp picture of it, so a texture
        // is not blurred by being carried from frame to frame or by
        // the pass that clears the grain. Where there is no such color
        // (the sky, mirrors, what glows) the light is kept as it is.
        vec3 arriving = light + indirect;
        if (dot(first_color, vec3(1.0)) > 0.0) arriving /= first_color;
        total += arriving;
        guide += first_color;
    }
    vec3 light = total / float(samples);
    vec3 shown = guide / float(samples);
    // What this pixel gathered before. With the camera still, that is
    // the same pixel of the last frame. With the camera moving, it is
    // wherever the surface seen here was on screen then, if it was on
    // screen and not behind something: the distance kept with the
    // guide tells. A surface newly come into view starts from nothing.
    float count = 0.0;
    vec3 light_before = vec3(0.0);
    vec3 shown_before = vec3(0.0);
    if (push.reset == 0u) {
        if (push.moved == 0u) {
            vec4 before = texelFetch(TEX(push.history_color, frame.sampler_nearest_clamp), pixel, 0);
            count = before.a;
            light_before = before.rgb;
            shown_before = texelFetch(TEX(push.history_guide, frame.sampler_nearest_clamp), pixel, 0).rgb;
        } else {
            vec2 center = (vec2(pixel) + 0.5) * frame.inv_resolution;
            vec3 toward = normalize(worldPositionFromDepth(center, 0.5, frame.inv_view_proj) - frame.camera_position);
            vec3 point = frame.camera_position + toward * first_distance;
            vec4 clip = frame.prev_view_proj_unjittered * vec4(point, 1.0);
            vec2 was_at = clip.xy / clip.w * 0.5 + 0.5;
            if (clip.w > 0.0 && all(greaterThan(was_at, vec2(0.0))) && all(lessThan(was_at, vec2(1.0)))) {
                vec4 guide_before = textureLod(TEX(push.history_guide, frame.sampler_linear_clamp), was_at, 0.0);
                float expected = distance(push.previous_camera, point);
                // The same surface, by how far it was and by its color: a
                // floor's light is not carried onto the wall that slid
                // in front of it.
                vec3 unlike = abs(guide_before.rgb - shown);
                if (abs(guide_before.a - expected) <= 0.03 * expected + 0.02 && max(unlike.r, max(unlike.g, unlike.b)) < 0.2) {
                    count = textureLod(TEX(push.history_color, frame.sampler_linear_clamp), was_at, 0.0).a;
                    light_before = historySharp(push.history_color, frame.sampler_linear_clamp, was_at, frame.resolution);
                    shown_before = guide_before.rgb;
                }
            }
            // What a moving camera carries along goes stale: highlights
            // and reflections belong to where it was seen from. So less
            // of it is trusted, and of mirrors hardly any.
            count = min(count, dot(shown, vec3(1.0)) > 0.0 ? 32.0 : 4.0);
        }
    }
    // One number that is not one, carried from frame to frame and looked
    // up by its neighbours, would spread until the whole picture is
    // lost: such history is dropped here.
    if (any(isnan(light_before)) || any(isinf(light_before)) || any(isnan(shown_before)) || any(isinf(shown_before)) || isnan(count) || isinf(count)) {
        count = 0.0;
        light_before = vec3(0.0);
        shown_before = vec3(0.0);
    }
    if (any(isnan(shown)) || any(isinf(shown))) shown = vec3(0.0);
    if (isnan(first_distance) || isinf(first_distance)) first_distance = 60000.0;
    count = min(count, 8192.0);
    float weight = 1.0 / (count + 1.0);
    out_color = vec4(mix(light_before, light, weight), count + 1.0);
    // The color of what is shown is steady, so while the camera moves
    // this frame's own counts for most of it and it stays sharp.
    float shown_weight = push.moved != 0u ? max(weight, 0.7) : weight;
    out_guide = vec4(mix(shown_before, shown, shown_weight), min(first_distance, 60000.0));
}
