#ifndef LOBES_SLANG
#define LOBES_SLANG

/// 0 in the subsurface pass, which keeps only the light that scales with
/// the diffuse color, so that every specular term drops out.
#ifdef SUBSURFACE
static const float specular_kept = 0.0;
#else
static const float specular_kept = 1.0;
#endif

float3 directLight(float3 n, float3 v, float3 l, float3 radiance, float3 diffuse_color, float3 f0, float roughness, float energy = 0.0) {
    float n_dot_l = clamp(dot(n, l), 0.0, 1.0);
    if (n_dot_l <= 0.0) return float3(0.0);
    float3 h = normalize(v + l);
    float n_dot_v = max(dot(n, v), 1e-4);
    float n_dot_h = clamp(dot(n, h), 0.0, 1.0);
    float alpha = roughness * roughness;
    float3 fresnel = fresnelSchlick(clamp(dot(v, h), 0.0, 1.0), f0);
    float3 specular = fresnel * (1.0 + f0 * energy) * (distributionGgx(n_dot_h, alpha) * visibilitySmithGgx(n_dot_l, n_dot_v, alpha));
    float3 diffuse = diffuse_color * (1.0 - fresnel) / PI;
    return (diffuse + specular * specular_kept) * radiance * n_dot_l;
}

float3 grainLight(Surface surface, float3 l, float3 radiance) {
    float3 n = surface.normal;
    float3 v = surface.view;
    float n_dot_l = clamp(dot(n, l), 0.0, 1.0);
    if (n_dot_l <= 0.0) return float3(0.0);
    float3 h = normalize(v + l);
    float n_dot_v = max(dot(n, v), 1e-4);
    float3 t = surface.grain;
    float3 b = cross(n, t);
    float across = max(surface.roughness * surface.roughness, 0.002);
    float along = lerp(across, 1.0, surface.anisotropy * surface.anisotropy);
    float3 scaled = float3(dot(t, h) / along, dot(b, h) / across, dot(n, h));
    float distribution = 1.0 / (PI * along * across * dot(scaled, scaled) * dot(scaled, scaled));
    float visibility = 0.5 / max(n_dot_l * length(float3(along * dot(t, v), across * dot(b, v), n_dot_v)) +
        n_dot_v * length(float3(along * dot(t, l), across * dot(b, l), n_dot_l)), 1e-5);
    float3 fresnel = fresnelSchlick(clamp(dot(v, h), 0.0, 1.0), surface.f0);
    float3 diffuse = surface.diffuse_color * (1.0 - fresnel) / PI;
    return (diffuse + fresnel * (1.0 + surface.f0 * surface.energy) * min(distribution * visibility, 1e4) * specular_kept) * radiance * n_dot_l;
}

/// Fresnel reflectance of a hair's cuticle, of index 1.55.
float hairFresnel(float cos_theta) {
    const float f0 = 0.0465;
    return f0 + (1.0 - f0) * pow(1.0 - clamp(cos_theta, 0.0, 1.0), 5.0);
}

float hairLobe(float width, float angle) {
    width = max(width, 1e-3);
    return exp(-0.5 * angle * angle / (width * width)) / (sqrt(2.0 * PI) * width);
}

/// Light a hair fibre along `tangent` sends toward `view` from `l`, after
/// Marschner: a white reflection off the cuticle shifted toward the tip,
/// light through the fibre coloured by `color` toward a light behind, and a
/// coloured reflection from inside it shifted toward the root. The lobes are
/// Karis's fits.
float3 hairFibre(float3 tangent, float3 view, float3 l, float3 color, float roughness) {
    float sin_l = clamp(dot(tangent, l), -1.0, 1.0);
    float sin_v = clamp(dot(tangent, view), -1.0, 1.0);
    float cos_d = max(cos(0.5 * abs(asin(sin_v) - asin(sin_l))), 1e-3);
    float3 across_l = l - sin_l * tangent;
    float3 across_v = view - sin_v * tangent;
    float cos_phi = dot(across_l, across_v) * rsqrt(dot(across_l, across_l) * dot(across_v, across_v) + 1e-4);
    float cos_half_phi = sqrt(clamp(0.5 + 0.5 * cos_phi, 0.0, 1.0));
    float width = max(roughness * roughness, 0.002);
    const float shift = 0.035;
    float3 result = float3(0.0);

    float tilt_sin = sin(-2.0 * shift);
    float tilt_cos = cos(-2.0 * shift);
    float tilt = 2.0 * tilt_sin * (tilt_cos * cos_half_phi * sqrt(max(1.0 - sin_v * sin_v, 0.0)) + tilt_sin * sin_v);
    float reflected = hairLobe(width * sqrt(2.0) * cos_half_phi, sin_l + sin_v - tilt) * 0.25 * cos_half_phi;
    result += reflected * hairFresnel(sqrt(clamp(0.5 + 0.5 * dot(view, l), 0.0, 1.0)));

    float bent = 1.0 / (1.19 / cos_d + 0.36 * cos_d);
    float offset = cos_half_phi * (1.0 + bent * (0.6 - 0.8 * cos_phi));
    float entering = hairFresnel(cos_d * sqrt(clamp(1.0 - offset * offset, 0.0, 1.0)));
    float3 passed = pow(color, 0.5 * sqrt(clamp(1.0 - offset * offset * bent * bent, 0.0, 1.0)) / cos_d);
    result += hairLobe(width * 0.5, sin_l + sin_v - shift) * exp(-3.65 * cos_phi - 3.98) * (1.0 - entering) * (1.0 - entering) * passed;

    float inner = hairFresnel(cos_d * 0.5);
    result += hairLobe(width * 2.0, sin_l + sin_v - 4.0 * shift) * exp(17.0 * cos_phi - 16.78) * (1.0 - inner) * (1.0 - inner) * inner * pow(color, 0.8 / cos_d);
    return max(result, float3(0.0));
}

/// Light scattered back and forth among neighbouring fibres, which gives hair
/// its body and the glow of fair hair; `through` is what is left of it after
/// crossing other fibres on the way in.
float3 hairScatter(float3 tangent, float3 view, float3 l, float3 color, float3 through) {
    float across = 1.0 - abs(dot(tangent, l));
    float3 facing = view - tangent * dot(view, tangent);
    facing *= rsqrt(max(dot(facing, facing), 1e-8));
    float wrapped = clamp((dot(facing, l) + 1.0) * 0.25, 0.0, 1.0);
    return color * through * (lerp(wrapped, across, 0.33) / PI);
}

/// Share of light the sheen lobe reflects toward a direction `cosine` from
/// the normal (an analytic fit of its directional albedo).
float sheenAlbedo(float cosine, float roughness) {
    float r2 = roughness * roughness;
    float a = roughness < 0.25 ? -339.2 * r2 + 161.4 * roughness - 25.9 : -8.48 * r2 + 14.3 * roughness - 9.95;
    float b = roughness < 0.25 ? 44.0 * r2 - 23.7 * roughness + 3.26 : 1.97 * r2 - 3.27 * roughness + 0.72;
    float reflected = exp(a * clamp(cosine, 0.0, 1.0) + b) + (roughness < 0.25 ? 0.0 : 0.1 * (roughness - 0.25));
    return clamp(reflected / PI, 0.0, 1.0);
}

float3 surfaceLight(Surface surface, float3 l, float3 radiance) {
    if (surface.anisotropy < 0.0) return (hairFibre(surface.grain, surface.view, l, surface.diffuse_color, surface.roughness) + hairScatter(surface.grain, surface.view, l, surface.diffuse_color, float3(1.0))) * radiance;
    float3 base;
    if (surface.anisotropy > 0.0) base = grainLight(surface, l, radiance);
    else base = directLight(surface.normal, surface.view, l, radiance, surface.diffuse_color, surface.f0, surface.roughness, surface.energy);
    float sheen_strength = max(surface.sheen_color.r, max(surface.sheen_color.g, surface.sheen_color.b));
    if (surface.clearcoat <= 0.0 && sheen_strength <= 0.0) return base;
    float n_dot_l = clamp(dot(surface.normal, l), 0.0, 1.0);
    if (n_dot_l <= 0.0) return base;
    float3 h = normalize(surface.view + l);
    float n_dot_v = max(dot(surface.normal, surface.view), 1e-4);
    if (sheen_strength > 0.0) {
        float inverse_alpha = 1.0 / max(surface.sheen_roughness * surface.sheen_roughness, 0.005);
        float n_dot_h = clamp(dot(surface.normal, h), 0.0, 1.0);
        float sin_squared = 1.0 - n_dot_h * n_dot_h;
        float distribution = (2.0 + inverse_alpha) * pow(sin_squared, 0.5 * inverse_alpha) / (2.0 * PI);
        float visibility = 1.0 / (4.0 * (n_dot_l + n_dot_v - n_dot_l * n_dot_v));
        float kept = 1.0 - sheen_strength * max(sheenAlbedo(n_dot_v, surface.sheen_roughness), sheenAlbedo(n_dot_l, surface.sheen_roughness));
        base = base * kept + surface.sheen_color * radiance * (distribution * visibility * n_dot_l * specular_kept);
    }
    if (surface.clearcoat <= 0.0) return base;
    float coat_n_dot_l = clamp(dot(surface.coat_normal, l), 0.0, 1.0);
    float coat_fresnel = fresnelSchlick(clamp(dot(surface.view, h), 0.0, 1.0), float3(0.04)).x * surface.clearcoat;
    float alpha = max(surface.clearcoat_roughness * surface.clearcoat_roughness, 0.002);
    float coat = distributionGgx(clamp(dot(surface.coat_normal, h), 0.0, 1.0), alpha) * visibilitySmithGgx(coat_n_dot_l, max(dot(surface.coat_normal, surface.view), 1e-4), alpha) * coat_fresnel;
    return base * (1.0 - coat_fresnel) + radiance * (coat_n_dot_l * coat * specular_kept);
}

float3 multiBounceAo(float ao, float3 albedo) {
    float3 a = 2.0404 * albedo - 0.3324;
    float3 b = -4.7951 * albedo + 0.6417;
    float3 c = 2.7552 * albedo + 0.6903;
    return max(float3(ao), ((ao * a + b) * ao + c) * ao);
}

float specularOcclusion(float n_dot_v, float ao, float roughness) {
    return clamp(pow(n_dot_v + ao, exp2(-16.0 * roughness - 1.0)) - 1.0 + ao, 0.0, 1.0);
}

#endif
