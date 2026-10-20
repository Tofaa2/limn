#include "surface.slang"
#include "brdf.slang"
#include "gi.slang"
#include "clouds.slang"
#include "path_history.slang"

#include "light_sampling.slang"

#ifdef SOFTWARE_RAYS
typedef BvhNode* SceneTree;
typedef BvhInstance* SceneInstances;
typedef uint* MeshItems;
#else
typedef uint64_t SceneTree;
typedef uint64_t SceneInstances;
typedef uint64_t MeshItems;
#endif

#include "pathtrace.Push.slang"

[[vk::push_constant]] Push push;

/// What one frame's paths found at a pixel. Nothing in it comes from
/// earlier frames: gathering over frames and filtering are the denoiser's.
struct Output {
    /// Light that needs no filtering, as it reaches the eye; alpha is 1
    /// where the first surface is a mirror.
    float4 color : SV_Target0;
    /// Color of the surface seen, through mirrors, and how far its
    /// reflections reach.
    float4 guide : SV_Target1;
    /// Bounced light on that surface, over its color, with how far the
    /// bounce went in alpha.
    float4 soft : SV_Target2;
    /// Its normal and distance; the distance is negative through a mirror.
    float4 facing : SV_Target3;
    /// Lamp and glow light on it, over its color.
    float4 lamp : SV_Target4;
    /// Glossy reflections in it.
    float4 gloss : SV_Target5;
    /// Normal, roughness and distance of the first surface on the ray.
    float4 surface : SV_Target6;
    /// The light sample the pixel keeps; the tracer's own.
    float4 reservoir : SV_Target7;
};

/// What a denoiser that works from the whole picture is given besides.
struct Guides {
    /// What the surface seen scatters, and what it reflects.
    float4 scatter;
    float4 reflect;
    /// Its normal, with roughness in alpha.
    float4 normal_roughness;
};

static Tracer tracer;
static float2 fragment;

static float3 first_color;
static bool first_met;
static float first_distance;
static bool first_mirrored;
static float3 first_facing;
static float3 first_scatter;
static float3 first_reflect;
static float first_roughness;
static bool primary_met;
static float3 primary_facing;
static float primary_roughness;
static float primary_distance;
static bool primary_mirror;
static float gloss_reach;
static float soft_reach;
static bool split_met;

static uint random_state;

uint pcg(uint value) {
    uint state = value * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

float random() {
    random_state = pcg(random_state);
    return float(random_state >> 8) / 16777216.0;
}

static uint sequence_seed;
static uint sequence_index;
static uint sequence_dimension;

uint scrambled(uint value, uint seed) {
    value = reversebits(value) + seed;
    value ^= value * 0x6c50b47cu;
    value ^= value * 0xb82f1e52u;
    value ^= value * 0xc7afe638u;
    value ^= value * 0x8d22f6e6u;
    return reversebits(value);
}

/// The next two numbers of this pixel's Owen-scrambled Sobol sequence, which
/// cover the unit square evenly over the frames a pixel accumulates.
float2 randomPair() {
    uint seed = pcg(sequence_seed + sequence_dimension * 0x9e3779b9u);
    sequence_dimension++;
    uint index = scrambled(sequence_index, seed);
    uint second = 0u;
    uint bits = index;
    uint direction = 0x80000000u;
    while (bits != 0u) {
        if ((bits & 1u) != 0u) second ^= direction;
        bits >>= 1u;
        direction ^= direction >> 1u;
    }
    uint2 spot = uint2(scrambled(reversebits(index), pcg(seed + 1u)), scrambled(second, pcg(seed + 2u)));
    return float2(spot >> 8u) / 16777216.0;
}

struct Surface {
    float3 position;
    float3 flat_normal;
    float3 normal;
    float3 albedo;
    float3 emissive;
    bool even_glow;
    float metallic;
    float roughness;
    float through;
    /// Index of refraction of a surface that bends what passes through it; 0
    /// for one that does not.
    float bend;
};

Surface pathSurface(FrameConstants frame, TraceHit hit, float3 origin, float3 direction, float footprint) {
    HitSurface met = surfaceAt(frame, hit, origin, direction, SurfaceDetail.matched(footprint));
    Surface surface;
    surface.position = met.position;
    surface.flat_normal = met.back_face ? -met.geometric_normal : met.geometric_normal;
    surface.normal = met.normal;
    surface.albedo = met.base_color.rgb;
    surface.emissive = met.emissive;
    surface.even_glow = (met.instance_flags & INSTANCE_AIMED) != 0u;
    surface.metallic = met.metallic;
    surface.roughness = met.roughness;
    surface.through = 0.0;
    if ((met.material_flags & MATERIAL_ALPHA_TEST) != 0u && met.base_color.a < met.alpha_cutoff) surface.through = 1.0;
    else if ((met.material_flags & MATERIAL_BLEND) != 0u) surface.through = clamp(1.0 - met.base_color.a * (1.0 - met.transmission), 0.0, 1.0);
    if ((met.instance_flags & INSTANCE_PROXY) != 0u) surface.through = 1.0;
    surface.bend = (met.material_flags & MATERIAL_BLEND) != 0u && met.transmission > 0.0 ? max(met.ior, 1.0) : 0.0;
    return surface;
}

bool pathAny(float3 origin, float3 direction, float reach) {
    return tracer.any(origin, direction, reach, RAY_EVERYTHING, Cutouts.whole);
}

static const float mirror_roughness = 0.08;
static const float glossy_roughness = 0.4;
static const float softened_mirror = 0.3;
static const float lit_by_itself = 0.5;
static const float lamp_clamp = 8.0;

/// Share of light from all directions a surface of reflectance `f0` reflects
/// toward the eye, by Karis's fit. DLSS Ray Reconstruction reads it as the
/// specular albedo.
float3 reflectedOverall(float3 f0, float roughness, float n_dot_v) {
    float4 fit = roughness * float4(-1.0, -0.0275, -0.572, 0.022) + float4(1.0, 0.0425, 1.04, -0.04);
    float bent = min(fit.x * fit.x, exp2(-9.28 * n_dot_v)) * fit.x + fit.y;
    float2 scale_bias = float2(-1.04, 1.04) * bent + fit.zw;
    return f0 * scale_bias.x + scale_bias.y;
}

bool mirrorLike(Surface surface) {
    return surface.roughness <= mirror_roughness;
}

/// Light reflected toward `view` per unit arriving from `light`; `shine` is the
/// part of it that is specular.
float3 surfaceResponse(Surface surface, float3 view, float3 light, out float3 shine) {
    shine = float3(0.0);
    float n_dot_l = dot(surface.normal, light);
    float n_dot_v = max(dot(surface.normal, view), 1e-4);
    if (n_dot_l <= 0.0) return float3(0.0);
    float3 half_vector = normalize(view + light);
    float alpha = surface.roughness * surface.roughness;
    float3 f0 = lerp(float3(0.04), surface.albedo, surface.metallic);
    float3 fresnel = fresnelSchlick(max(dot(view, half_vector), 0.0), f0);
    float3 specular = mirrorLike(surface) ? float3(0.0) : fresnel * distributionGgx(max(dot(surface.normal, half_vector), 0.0), alpha) * visibilitySmithGgx(n_dot_l, n_dot_v, alpha);
    float3 diffuse = surface.albedo * (1.0 - surface.metallic) * (1.0 - fresnel) / PI;
    shine = specular * n_dot_l;
    return (diffuse + specular) * n_dot_l;
}

float3 skyLight(FrameConstants frame, float3 direction, bool with_sun) {
    if (frame.environment == 0u) return float3(0.0);
    if (!with_sun) {
        const float disc_angle = 0.0175;
        float texel_angle = 1.6 / cubeSize(frame.env_sky).x;
        float kept_clear = disc_angle + 2.5 * texel_angle;
        float toward_sun = dot(direction, frame.sun_direction);
        if (toward_sun > cos(kept_clear)) {
            float3 away = direction - frame.sun_direction * toward_sun;
            float away_length = length(away);
            away = away_length > 1e-6 ? away / away_length : tangentBasis(frame.sun_direction).side;
            float beside = kept_clear + texel_angle;
            direction = frame.sun_direction * cos(beside) + away * sin(beside);
        }
    }
    return sampleCubeLod(frame.env_sky, frame.sampler_linear_clamp, direction, 0.0).rgb * frame.env_intensity;
}

/// One point on a lamp or on a glowing triangle. `source` is 0 for none, a
/// lamp's index plus one, or `glow_source` plus a glowing instance's index plus
/// one. `place` picks the point on it.
/// The lights this pass samples.
LightSet pathLights() {
    LightSet lights;
    lights.light_count = push.light_count;
    lights.glowing = push.glowing;
    lights.glowing_count = push.glowing_count;
    return lights;
}

static bool reuse_lamps;
static float3 reuse_toward;
static float3 reuse_point;
static bool reuse_mirrored;
static float reuse_reach;
static float4 reservoir_kept;

static const float reused_frames = 20.0;
static const int reused_neighbours = 3;
static const float reused_radius = 24.0;

bool seenBefore(FrameConstants frame, float3 spot, float reach, bool mirrored, out float2 was_at) {
    return seenLastFrame(frame, fragment, push.moved != 0u, push.depth, push.motion, spot, reach, mirrored, was_at);
}

/// Whether the surface a pixel showed last frame is close enough to `surface`
/// for its reservoir to be reused.
bool alike(FrameConstants frame, int2 at, Surface surface, float expected, float slack) {
    float4 before = fetchTexel(push.history_facing, at);
    if (any(isnan(before)) || (before.a < 0.0) != reuse_mirrored) return false;
    float size = length(before.rgb);
    if (size < 1e-4 || dot(before.rgb / size, surface.normal) < 0.8) return false;
    return abs(abs(before.a) - expected) <= slack * expected + 0.02;
}

/// Lamp and glow light on the surface the pixel shows, resampled from this
/// frame's candidates, the pixel's reservoir of last frame and its neighbours'.
float3 reusedLamps(FrameConstants frame, Surface surface, float3 view, float3 start, out float3 shine) {
    Resampling fresh = freshCandidates(pathLights(), frame, surface, view);
    if (fresh.reservoir.worth > 0.0) {
        if (pathAny(start, fresh.toward, fresh.reach)) fresh.reservoir.worth = 0.0;
    }
    Resampling resampling = emptyResampling();
    resampling.reservoir.pick = fresh.reservoir.pick;
    resampling.reservoir.count = fresh.reservoir.count;
    resampling.light = fresh.light;
    resampling.shine = fresh.shine;
    resampling.toward = fresh.toward;
    resampling.reach = fresh.reach;
    resampling.target = fresh.target;
    resampling.weight_sum = fresh.target * fresh.reservoir.worth * fresh.reservoir.count;
    bool reused = false;
    float2 was_at;
    bool seen = false;
    was_at = float2(0.0);
    if (push.reusable != 0u) seen = seenBefore(frame, reuse_point, reuse_reach, reuse_mirrored, was_at);
    was_at *= frame.resolution;
    if (seen) {
        float expected = distance(push.previous_camera, reuse_point);
        float limit = reused_frames * max(fresh.reservoir.count, 1.0);
        int2 last = int2(frame.resolution) - 1;
        for (int index = 0; index <= reused_neighbours; index++) {
            float2 place = was_at;
            if (index > 0) {
                float turn = 2.0 * PI * random();
                place += float2(cos(turn), sin(turn)) * (reused_radius * sqrt(random()));
            }
            int2 at = int2(floor(place));
            if (any(at < 0) || any(at > last)) continue;
            if (!alike(frame, at, surface, expected, index == 0 ? 0.03 : 0.1)) continue;
            Reservoir before = unpackReservoir(fetchTexel(push.history_reservoir, at));
            if (before.count <= 0.0) continue;
            if (offer(pathLights(), resampling, frame, surface, view, before.pick, before.worth, min(before.count, limit))) reused = true;
        }
    }
    settle(resampling);
    if (reused && resampling.reservoir.worth > 0.0) {
        if (pathAny(start, resampling.toward, resampling.reach)) resampling.reservoir.worth = 0.0;
    }
    reservoir_kept = packReservoir(resampling.reservoir);
    shine = resampling.shine * resampling.reservoir.worth;
    return resampling.light * resampling.reservoir.worth;
}

/// Sun light on `surface`. `lamps` is the light of lamps and glowing triangles
/// and `shine` the specular part of that.
float3 directLight(FrameConstants frame, Surface surface, float3 view, bool reusing, out float3 lamps, out float3 shine) {
    float3 total = float3(0.0);
    lamps = float3(0.0);
    shine = float3(0.0);
    float3 sun_shine;
    float3 start = surface.position + surface.flat_normal * 0.002;
    if (dot(frame.sun_radiance, float3(1.0)) > 0.0) {
        TangentBasis basis = tangentBasis(frame.sun_direction);
        float2 xi = randomPair();
        float turn = 2.0 * PI * xi.x;
        float reach = push.sun_radius * sqrt(xi.y);
        float3 toward = normalize(basis.toWorld(float3(cos(turn) * reach, sin(turn) * reach, 1.0)));
        float3 response = surfaceResponse(surface, view, toward, sun_shine);
        if (dot(response, float3(1.0)) > 0.0 && dot(surface.flat_normal, toward) > 0.0) {
            if (!pathAny(start, toward, 1e4)) total += response * frame.sun_radiance * cloudShadow(frame, surface.position) * fluidShadow(frame, surface.position);
        }
    }
    if (min(frame.lights.light_count, push.light_count) == 0u && push.glowing_count == 0u) return total;
    if (reusing) {
        lamps = reusedLamps(frame, surface, view, start, shine);
        return total;
    }
    Resampling fresh = freshCandidates(pathLights(), frame, surface, view);
    bool reached = false;
    if (fresh.reservoir.worth > 0.0) reached = !pathAny(start, fresh.toward, fresh.reach);
    if (reached) {
        float through_smoke = fluidShadowToward(frame, start, fresh.toward, fresh.reach);
        lamps = fresh.light * fresh.reservoir.worth * through_smoke;
        shine = fresh.shine * fresh.reservoir.worth * through_smoke;
    }
    return total;
}

float3 visibleFacet(float3 view, float alpha, float2 xi) {
    float3 stretched = normalize(float3(alpha * view.xy, view.z));
    float across = dot(stretched.xy, stretched.xy);
    float3 side = across > 0.0 ? float3(-stretched.y, stretched.x, 0.0) * rsqrt(across) : float3(1.0, 0.0, 0.0);
    float3 other = cross(stretched, side);
    float radius = sqrt(xi.x);
    float turn = 2.0 * PI * xi.y;
    float a = radius * cos(turn);
    float b = radius * sin(turn);
    float lean = 0.5 * (1.0 + stretched.z);
    b = (1.0 - lean) * sqrt(max(1.0 - a * a, 0.0)) + lean * b;
    float3 facet = a * side + b * other + sqrt(max(1.0 - a * a - b * b, 0.0)) * stretched;
    return normalize(float3(alpha * facet.xy, max(facet.z, 1e-6)));
}

float reflectedShare(float n_dot_l, float n_dot_v, float alpha) {
    float a2 = alpha * alpha;
    float seen_out = sqrt(a2 + (1.0 - a2) * n_dot_l * n_dot_l);
    float seen_in = sqrt(a2 + (1.0 - a2) * n_dot_v * n_dot_v);
    return n_dot_l * (n_dot_v + seen_in) / max(n_dot_v * seen_out + n_dot_l * seen_in, 1e-6);
}

float3 tracePath(FrameConstants frame, float3 origin, float3 direction, bool scattering, out float3 soft, out float3 indirect, out float3 gloss) {
    soft = float3(0.0);
    indirect = float3(0.0);
    gloss = float3(0.0);
    bool glossy_first = false;
    bool awaiting_reach = false;
    bool awaiting_soft = false;
    float travelled = 0.0;
    bool rough_bounce = false;
    bool split = false;
    bool unaimed = true;
    float3 gathered = float3(0.0);
    float3 carried = float3(1.0);
    float cone_width = 0.0;
    float cone_angle = 2.0 / (abs(frame.proj[1][1]) * frame.resolution.y);
    for (uint bounce = 0u; bounce <= push.bounces; bounce++) {
        TraceHit hit;
        bool met;
        Surface surface;
        for (uint holes = 0u;; holes++) {
            met = tracer.closest(origin, direction, 1e5, RAY_EVERYTHING, Cutouts.whole, hit);
            if (!met) break;
            surface = pathSurface(frame, hit, origin, direction, cone_width + cone_angle * hit.t);
            if (surface.through < 1.0 || holes >= 16u) break;
            cone_width += cone_angle * hit.t;
            travelled += hit.t;
            origin = surface.position + direction * 0.002;
        }
        if (awaiting_reach) {
            gloss_reach = met ? hit.t : 1000.0;
            awaiting_reach = false;
        }
        if (awaiting_soft) {
            soft_reach = met ? hit.t : 1000.0;
            awaiting_soft = false;
        }
        if (!met) {
            float3 sky = carried * skyLight(frame, direction, unaimed);
            if (glossy_first) gloss += sky;
            else if (!rough_bounce) gathered += sky;
            else indirect += sky;
            break;
        }
        cone_width += cone_angle * hit.t;
        travelled += hit.t;
        if (rough_bounce) surface.roughness = max(surface.roughness, softened_mirror);
        float let_through = surface.through;
        float mirrored = 0.0;
        if (surface.bend > 0.0) {
            float facing = clamp(dot(surface.normal, -direction), 0.0, 1.0);
            float head_on = (surface.bend - 1.0) / (surface.bend + 1.0);
            head_on *= head_on;
            float bounced_off = head_on + (1.0 - head_on) * pow(1.0 - facing, 5.0);
            mirrored = let_through * bounced_off;
            let_through -= mirrored;
        }
        float chosen = 1.0;
        if (let_through + mirrored > 0.0) chosen = random();
        if (chosen >= let_through && chosen < let_through + mirrored) {
            direction = reflect(direction, surface.normal);
            origin = surface.position + direction * 0.002;
            continue;
        }
        if (chosen < let_through) {
            origin = surface.position + direction * 0.002;
            if (surface.bend > 0.0) {
                float3 bent = refract(direction, surface.normal, 1.0 / surface.bend);
                if (dot(bent, bent) > 0.0) direction = normalize(bent);
                origin = surface.position - surface.flat_normal * 0.002;
                carried *= lerp(float3(1.0), surface.albedo, 0.5);
            }
            continue;
        }
        bool glows = luminance(surface.emissive) > lit_by_itself;
        bool pure_mirror = mirrorLike(surface) && surface.metallic > 0.5 && !glows;
        if (!primary_met) {
            primary_met = true;
            primary_facing = surface.normal;
            primary_roughness = surface.roughness;
            primary_distance = travelled;
            primary_mirror = pure_mirror;
        }
        bool first_here = !first_met && !pure_mirror;
        if (first_here) {
            first_met = true;
            first_distance = travelled;
            first_mirrored = bounce > 0u;
            first_color = glows ? float3(0.0) : max(surface.albedo, float3(0.03));
            first_facing = surface.normal;
            first_scatter = surface.albedo * (1.0 - surface.metallic);
            first_reflect = reflectedOverall(lerp(float3(0.04), surface.albedo, surface.metallic), surface.roughness, max(dot(surface.normal, -direction), 0.0));
            first_roughness = surface.roughness;
        }
        if (unaimed || !surface.even_glow) {
            if (glossy_first) gloss += carried * surface.emissive;
            else if (!rough_bounce) gathered += carried * surface.emissive;
            else indirect += carried * surface.emissive;
        }
        if (bounce == push.bounces) break;
        float3 view = -direction;
        float3 lamps;
        float3 shine;
        reuse_point = frame.camera_position + reuse_toward * travelled;
        reuse_mirrored = first_mirrored;
        reuse_reach = travelled;
        float3 sun = carried * directLight(frame, surface, view, reuse_lamps && first_here && !scattering, lamps, shine);
        lamps *= carried;
        shine *= carried;
        if (glossy_first) gloss += sun + lamps;
        else if (rough_bounce) indirect += sun + lamps;
        else {
            gathered += sun;
            soft += lamps - shine;
            float shine_brightness = luminance(shine);
            float most = lamp_clamp * push.clamp_radiance;
            if (shine_brightness > most) shine *= most / shine_brightness;
            gathered += shine;
        }
        if ((rough_bounce || glossy_first) && !mirrorLike(surface) && push.probes != 0u && frame.gi.enabled != 0u) {
            float coverage = giCoverage(frame, surface.position);
            bool ended = false;
            if (coverage > 0.0) ended = random() < coverage;
            if (ended) {
                float3 bounced = carried * surface.albedo * giIrradiance(frame, surface.position, surface.normal, view);
                if (glossy_first) gloss += bounced;
                else indirect += bounced;
                break;
            }
        }

        float3 f0 = lerp(float3(0.04), surface.albedo, surface.metallic);
        float n_dot_v = max(dot(surface.normal, view), 1e-4);
        float3 fresnel_view = fresnelSchlick(n_dot_v, f0);
        float3 scattered = surface.albedo * (1.0 - surface.metallic);
        float mirror_share = luminance(scattered) > 1e-4 ? clamp(luminance(fresnel_view) / (luminance(fresnel_view) + luminance(scattered)), 0.1, 0.9) : 1.0;
        if (!rough_bounce && !mirrorLike(surface) && surface.roughness < glossy_roughness) mirror_share = max(mirror_share, 0.5);
        bool reflects;
        if (!split && !rough_bounce && !glossy_first && mirrorLike(surface) && mirror_share < 1.0) {
            split = true;
            split_met = true;
            reflects = !scattering;
            mirror_share = reflects ? 1.0 : 0.0;
            if (scattering) {
                gathered = float3(0.0);
                soft = float3(0.0);
                indirect = float3(0.0);
                gloss = float3(0.0);
            }
        } else {
            reflects = random() < mirror_share;
        }
        TangentBasis basis = tangentBasis(surface.normal);
        float3 next;
        if (reflects) {
            float alpha = surface.roughness * surface.roughness;
            float3 view_local = basis.toLocal(view);
            float3 half_vector = basis.toWorld(visibleFacet(float3(view_local.xy, max(view_local.z, 1e-3)), alpha, randomPair()));
            next = reflect(direction, half_vector);
            float n_dot_l = dot(surface.normal, next);
            if (n_dot_l <= 0.0 || dot(surface.flat_normal, next) <= 0.0) break;
            float3 fresnel = fresnelSchlick(max(dot(view, half_vector), 1e-4), f0);
            carried *= fresnel * reflectedShare(n_dot_l, n_dot_v, alpha) / mirror_share;
            unaimed = mirrorLike(surface);
            if (!rough_bounce && !glossy_first && (unaimed ? mirror_share < 1.0 : surface.roughness < glossy_roughness)) {
                glossy_first = true;
                awaiting_reach = true;
            }
            if (!unaimed) {
                awaiting_soft = !rough_bounce;
                rough_bounce = true;
            }
        } else {
            float2 xi = randomPair();
            float turn = 2.0 * PI * xi.x;
            float radius = sqrt(xi.y);
            next = normalize(basis.toWorld(float3(cos(turn) * radius, sin(turn) * radius, sqrt(max(1.0 - radius * radius, 0.0)))));
            if (dot(surface.flat_normal, next) <= 0.0) break;
            carried *= scattered * (1.0 - fresnel_view) / (1.0 - mirror_share);
            unaimed = false;
            awaiting_soft = !rough_bounce;
            rough_bounce = true;
        }
        cone_angle = max(cone_angle, unaimed ? cone_angle : 0.05 + 0.25 * surface.roughness);
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

/// Traces the pixel whose center is `position`.
Output tracePixel(float4 position, out Guides guides) {
    FrameConstants frame = push.frame;
    fragment = position.xy;
    tracer.frame = frame;
#ifdef SOFTWARE_RAYS
    tracer.scene_nodes = push.scene;
    tracer.scene_instances = push.scene_instances;
    tracer.mesh_nodes = push.mesh_nodes;
    tracer.mesh_items = push.mesh_items;
#else
    tracer.scene = push.scene;
#endif
    int2 pixel = int2(fragment);
    random_state = pcg(uint(pixel.x) + pcg(uint(pixel.y) + pcg(push.gathered * 7919u + frame.frame_index)));
    sequence_seed = pcg(uint(pixel.x) + pcg(uint(pixel.y)));
    sequence_dimension = 0u;
    reservoir_kept = float4(0.0);
    reuse_toward = normalize(worldPositionFromDepth((float2(pixel) + 0.5) * frame.inv_resolution, 0.5, frame.inv_view_proj) - frame.camera_position);
    float3 total = float3(0.0);
    float3 total_soft = float3(0.0);
    float3 total_lamp = float3(0.0);
    float3 total_scatter = float3(0.0);
    float3 total_reflect = float3(0.0);
    float4 total_facing = float4(0.0);
    float3 total_gloss = float3(0.0);
    float3 guide = float3(0.0);
    uint samples = max(push.samples, 1u);
    for (uint index = 0u; index < samples; index++) {
        sequence_index = frame.frame_index * samples + index;
        float2 offset = float2(0.5);
        if (push.centered == 0u) offset = randomPair();
        float2 uv = (float2(pixel) + offset) * frame.inv_resolution;
        float3 through = worldPositionFromDepth(uv, 0.5, frame.inv_view_proj);
        float3 direction = normalize(through - frame.camera_position);
        first_met = false;
        first_distance = 60000.0;
        first_mirrored = false;
        first_color = float3(0.0);
        first_facing = float3(0.0, 1.0, 0.0);
        first_scatter = float3(0.0);
        first_reflect = float3(0.0);
        first_roughness = 1.0;
        primary_met = false;
        primary_facing = float3(0.0, 1.0, 0.0);
        primary_roughness = 1.0;
        primary_distance = 60000.0;
        primary_mirror = false;
        gloss_reach = 0.0;
        soft_reach = 0.0;
        float3 soft;
        float3 indirect;
        float3 gloss;
        split_met = false;
        reuse_lamps = index == 0u;
        float3 light = tracePath(frame, frame.camera_position, direction, false, soft, indirect, gloss);
        if (split_met) {
            split_met = false;
            reuse_lamps = false;
            float3 scattered_soft;
            float3 scattered_indirect;
            float3 scattered_gloss;
            float3 scattered_light = tracePath(frame, frame.camera_position, direction, true, scattered_soft, scattered_indirect, scattered_gloss);
            if (split_met) {
                light += scattered_light;
                soft += scattered_soft;
                indirect += scattered_indirect;
                gloss += scattered_gloss;
            }
        }
        if (broken(light)) light = float3(0.0);
        if (broken(soft)) soft = float3(0.0);
        if (broken(indirect)) indirect = float3(0.0);
        if (broken(gloss)) gloss = float3(0.0);
        float gloss_brightness = luminance(gloss);
        if (gloss_brightness > push.clamp_radiance) gloss *= push.clamp_radiance / gloss_brightness;
        float brightness = luminance(indirect);
        if (brightness > push.clamp_radiance) indirect *= push.clamp_radiance / brightness;
        float lamp_brightness = luminance(soft);
        if (lamp_brightness > lamp_clamp * push.clamp_radiance) soft *= lamp_clamp * push.clamp_radiance / lamp_brightness;
        total += light;
        float3 tint = dot(first_color, float3(1.0)) > 0.0 ? first_color : float3(1.0);
        total_soft += indirect / tint;
        total_lamp += soft / tint;
        total_scatter += first_scatter;
        total_reflect += first_reflect;
        total_facing += float4(first_met ? first_facing : float3(0.0), first_roughness);
        total_gloss += gloss;
        guide += first_color;
    }
    float3 shown = guide / float(samples);
    if (broken(shown)) shown = float3(0.0);
    if (isnan(first_distance) || isinf(first_distance)) first_distance = 60000.0;
    float shown_distance = min(first_distance, 60000.0);
    Output result;
    result.color = float4(total / float(samples), primary_mirror ? 1.0 : 0.0);
    result.guide = float4(shown, gloss_reach);
    result.soft = float4(total_soft / float(samples), soft_reach);
    result.facing = float4(first_facing, first_mirrored ? -shown_distance : shown_distance);
    result.lamp = float4(min(total_lamp / float(samples), float3(60000.0)), 1.0);
    result.gloss = float4(min(total_gloss / float(samples), float3(60000.0)), 1.0);
    result.surface = float4(unpackSnormPair(packDirection(primary_facing)), primary_roughness, min(primary_distance, 60000.0));
    result.reservoir = reservoir_kept;
    guides.scatter = float4(total_scatter / float(samples), 1.0);
    guides.reflect = float4(total_reflect / float(samples), 1.0);
    guides.normal_roughness = total_facing / float(samples);
    return result;
}

[shader("fragment")]
Output fragmentMain(float4 position : SV_Position) {
    Guides guides;
    return tracePixel(position, guides);
}

#ifdef STORAGE_IMAGES
[shader("compute")]
[numthreads(8, 8, 1)]
void computeMain(uint3 id : SV_DispatchThreadID) {
    if (any(float2(id.xy) >= push.frame.resolution)) return;
    Guides guides;
    Output result = tracePixel(float4(float2(id.xy) + 0.5, 0.0, 1.0), guides);
    storage_2d[push.targets[0]][id.xy] = result.color;
    storage_2d[push.targets[1]][id.xy] = result.guide;
    storage_2d[push.targets[2]][id.xy] = result.soft;
    storage_2d[push.targets[3]][id.xy] = result.facing;
    storage_2d[push.targets[4]][id.xy] = result.lamp;
    storage_2d[push.targets[5]][id.xy] = result.gloss;
    storage_2d[push.targets[6]][id.xy] = result.surface;
    storage_2d[push.targets[7]][id.xy] = result.reservoir;
    if (push.reconstructed == 0u) return;
    storage_2d[push.targets[8]][id.xy] = guides.scatter;
    storage_2d[push.targets[9]][id.xy] = guides.reflect;
    storage_2d[push.targets[10]][id.xy] = guides.normal_roughness;
}
#endif
