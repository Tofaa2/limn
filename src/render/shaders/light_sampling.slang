#ifndef LIGHT_SAMPLING_SLANG
#define LIGHT_SAMPLING_SLANG

/// Sampling the lights a surface sees: one light sample at a time, and
/// resampling among candidates (RIS) into a reservoir that can be kept from
/// frame to frame. The includer provides `Surface`, `surfaceResponse` and
/// `random()`.

struct Glowing {
    uint instance;
    uint triangles;
};

/// The lights to sample: the first `light_count` of `FrameConstants.lights`,
/// and the glowing triangles.
struct LightSet {
    uint light_count;
    Glowing* glowing;
    uint glowing_count;
};

struct LightSample {
    uint source;
    uint facet;
    float2 place;
};

static const uint glow_source = 512u;
static const float place_steps = 4096.0;

/// The light sample a pixel keeps between frames: `worth` scales the sample's
/// light into an estimate of all lamp light, `count` is how many candidates
/// it was chosen from.
struct Reservoir {
    LightSample pick;
    float worth;
    float count;
};

static const float reservoir_count_limit = 255.0;

float4 packReservoir(Reservoir reservoir) {
    uint2 cell = min(uint2(reservoir.pick.place * place_steps), uint2(uint(place_steps) - 1u));
    return float4(float(reservoir.pick.source) + 2048.0 * floor(min(reservoir.count, reservoir_count_limit)), float(reservoir.pick.facet), float(cell.x + cell.y * uint(place_steps)), reservoir.worth);
}

Reservoir unpackReservoir(float4 packed) {
    Reservoir reservoir;
    if (any(isnan(packed)) || any(isinf(packed)) || any(packed < 0.0)) packed = float4(0.0);
    uint head = uint(packed.r);
    uint cell = uint(packed.b);
    reservoir.pick.source = head & 2047u;
    reservoir.pick.facet = uint(packed.g);
    reservoir.pick.place = (float2(cell % uint(place_steps), cell / uint(place_steps)) + 0.5) / place_steps;
    reservoir.count = float(head >> 11u);
    reservoir.worth = packed.a;
    return reservoir;
}

float2 randomPlace() {
    float first = random();
    float second = random();
    return (floor(float2(first, second) * place_steps) + 0.5) / place_steps;
}

LightSample lightSample(uint source, uint facet, float2 place) {
    LightSample pick;
    pick.source = source;
    pick.facet = facet;
    pick.place = place;
    return pick;
}

/// Light `pick` sends to the eye off `surface` before shadowing. `rarity` is
/// one over the chance that uniform picking lands on this sample.
float3 sampleLight(LightSet lights, FrameConstants frame, Surface surface, float3 view, LightSample pick, out float3 toward, out float reach, out float rarity, out float3 shine) {
    shine = float3(0.0);
    toward = float3(0.0);
    reach = 0.0;
    rarity = 0.0;
    if (pick.source == 0u) return float3(0.0);
    if (pick.source <= glow_source) {
        uint light_count = min(frame.lights.light_count, lights.light_count);
        if (pick.source > light_count) return float3(0.0);
        Light light = frame.lights.lights.data[pick.source - 1u];
        rarity = float(light_count);
        float attenuation = 1.0;
        reach = 1e4;
        if ((light.flags & LIGHT_DIRECTIONAL) != 0u) {
            toward = -light.direction;
        } else {
            float3 target = light.position;
            if (light.source_radius > 0.0) {
                float height = 1.0 - 2.0 * pick.place.x;
                float ring = sqrt(max(1.0 - height * height, 0.0));
                float turn = 2.0 * PI * pick.place.y;
                target += float3(ring * cos(turn), ring * sin(turn), height) * light.source_radius * 0.7;
            }
            float3 to_light = target - surface.position;
            float distance_squared = dot(to_light, to_light);
            float range_squared = light.range * light.range;
            if (distance_squared >= range_squared) return float3(0.0);
            float window = clamp(1.0 - (distance_squared * distance_squared) / (range_squared * range_squared), 0.0, 1.0);
            attenuation = window * window / max(distance_squared, 0.01);
            reach = sqrt(distance_squared);
            toward = to_light / max(reach, 1e-5);
            if ((light.flags & LIGHT_SPOT) != 0u) {
                float cone = clamp(dot(-toward, light.direction) * light.cone_scale + light.cone_offset, 0.0, 1.0);
                attenuation *= cone * cone;
            }
            if ((light.flags & LIGHT_RECTANGLE) != 0u) attenuation *= clamp(dot(-toward, light.direction), 0.0, 1.0);
            reach = max(reach - 0.004, 0.0);
            if (light.source_radius > 0.0) {
                float3 to_center = light.position - surface.position;
                float along = dot(to_center, toward);
                float inside = light.source_radius * light.source_radius - (dot(to_center, to_center) - along * along);
                if (inside > 0.0) reach = min(reach, max(along - sqrt(inside), 0.0));
            }
        }
        if (attenuation <= 1e-5 || dot(surface.flat_normal, toward) <= 0.0) return float3(0.0);
        float3 response = surfaceResponse(surface, view, toward, shine);
        shine *= light.color * attenuation;
        return response * light.color * attenuation;
    }
    uint index = pick.source - glow_source - 1u;
    if (index >= lights.glowing_count) return float3(0.0);
    Glowing chosen = lights.glowing[index];
    if (pick.facet >= chosen.triangles) return float3(0.0);
    Instance instance = frame.instances.data[chosen.instance];
    Mesh mesh = loadAligned<16>(frame.meshes.data + instance.mesh);
    uint base = mesh.index_offset + pick.facet * 3u;
    float3 p0 = mul(instance.transform, float4(frame.vertices.data[instance.vertex_offset + frame.indices.data[base]].position, 1.0));
    float3 p1 = mul(instance.transform, float4(frame.vertices.data[instance.vertex_offset + frame.indices.data[base + 1u]].position, 1.0));
    float3 p2 = mul(instance.transform, float4(frame.vertices.data[instance.vertex_offset + frame.indices.data[base + 2u]].position, 1.0));
    float side = sqrt(pick.place.x);
    float2 weights = float2(side * (1.0 - pick.place.y), side * pick.place.y);
    float3 spot = p0 + (p1 - p0) * weights.x + (p2 - p0) * weights.y;
    float3 across = cross(p1 - p0, p2 - p0);
    float area = 0.5 * length(across);
    float3 to_spot = spot - surface.position;
    float distance_squared = dot(to_spot, to_spot);
    if (area <= 0.0 || distance_squared <= 1e-8) return float3(0.0);
    reach = sqrt(distance_squared);
    toward = to_spot / reach;
    reach = max(reach - 0.004, 0.0);
    float facing = abs(dot(across, toward)) / (2.0 * area);
    if (facing <= 1e-4 || dot(surface.flat_normal, toward) <= 0.0) return float3(0.0);
    rarity = area * float(chosen.triangles) * float(lights.glowing_count);
    float3 arriving = frame.materials.data[instance.material].emissive * (facing / max(distance_squared, 0.01));
    float3 response = surfaceResponse(surface, view, toward, shine);
    shine *= arriving;
    return response * arriving;
}

/// A reservoir being filled, with the light of the sample it holds.
struct Resampling {
    Reservoir reservoir;
    float3 light;
    float3 shine;
    float3 toward;
    float reach;
    float target;
    float weight_sum;
};

Resampling emptyResampling() {
    Resampling resampling;
    resampling.reservoir.pick = lightSample(0u, 0u, float2(0.0));
    resampling.reservoir.worth = 0.0;
    resampling.reservoir.count = 0.0;
    resampling.light = float3(0.0);
    resampling.shine = float3(0.0);
    resampling.toward = float3(0.0);
    resampling.reach = 0.0;
    resampling.target = 0.0;
    resampling.weight_sum = 0.0;
    return resampling;
}

/// Offers `pick`, which stands for `count` candidates each worth `worth`, and
/// returns whether it replaced the sample held.
bool offer(LightSet lights, inout Resampling resampling, FrameConstants frame, Surface surface, float3 view, LightSample pick, float worth, float count) {
    resampling.reservoir.count += count;
    float3 toward;
    float reach;
    float rarity;
    float3 shine;
    float3 light = sampleLight(lights, frame, surface, view, pick, toward, reach, rarity, shine);
    float target = luminance(light);
    float weight = target * (worth < 0.0 ? rarity : worth) * count;
    if (!(weight > 0.0) || isinf(weight)) return false;
    resampling.weight_sum += weight;
    if (random() * resampling.weight_sum >= weight) return false;
    resampling.reservoir.pick = pick;
    resampling.light = light;
    resampling.shine = shine;
    resampling.toward = toward;
    resampling.reach = reach;
    resampling.target = target;
    return true;
}

void settle(inout Resampling resampling) {
    resampling.reservoir.worth = resampling.target > 0.0 && resampling.reservoir.count > 0.0 ? resampling.weight_sum / (resampling.reservoir.count * resampling.target) : 0.0;
}

static const uint lamp_candidates = 4u;
static const uint glow_candidates = 4u;

/// A reservoir of fresh candidates from the lamps and glowing triangles.
/// Candidates of the two kinds are weighted for the share each is given.
Resampling freshCandidates(LightSet lights, FrameConstants frame, Surface surface, float3 view) {
    Resampling resampling = emptyResampling();
    uint light_count = min(frame.lights.light_count, lights.light_count);
    uint lamps = light_count != 0u ? lamp_candidates : 0u;
    uint glows = lights.glowing_count != 0u ? glow_candidates : 0u;
    float all = float(lamps + glows);
    for (uint index = 0u; index < lamps; index++) {
        uint source = 1u + min(uint(random() * float(light_count)), light_count - 1u);
        LightSample pick = lightSample(source, 0u, randomPlace());
        offer(lights, resampling, frame, surface, view, pick, -1.0, all / float(lamps));
        resampling.reservoir.count -= all / float(lamps) - 1.0;
    }
    for (uint index = 0u; index < glows; index++) {
        uint chosen = min(uint(random() * float(lights.glowing_count)), lights.glowing_count - 1u);
        uint triangles = lights.glowing[chosen].triangles;
        uint facet = min(uint(random() * float(triangles)), triangles - 1u);
        LightSample pick = lightSample(glow_source + 1u + chosen, facet, randomPlace());
        offer(lights, resampling, frame, surface, view, pick, -1.0, all / float(glows));
        resampling.reservoir.count -= all / float(glows) - 1.0;
    }
    settle(resampling);
    return resampling;
}

#endif
