#include <metal_stdlib>
using namespace metal;

struct GVReactionUniforms { float4 controls; float4 touch; };
constexpr sampler gvReactionSampler(coord::normalized, address::clamp_to_edge, filter::linear);
static inline float gvReactionLuma(float3 rgb) { return dot(rgb, float3(0.2126, 0.7152, 0.0722)); }

kernel void gvReactionSeed(texture2d<half, access::sample> source [[texture(0)]],
    texture2d<half, access::write> field [[texture(2)]], uint2 p [[thread_position_in_grid]]) {
    if (p.x >= field.get_width() || p.y >= field.get_height()) return;
    const float2 uv = (float2(p) + 0.5) / float2(field.get_width(), field.get_height());
    const float2 texel = 1.0 / float2(field.get_width(), field.get_height());
    const float center = gvReactionLuma(float3(source.sample(gvReactionSampler, uv).rgb));
    const float detail = abs(center - gvReactionLuma(float3(source.sample(gvReactionSampler, uv + texel).rgb)));
    // Stable sparse nucleation sites; camera detail chooses additional sites.
    const uint hash = (p.x * 1664525u + p.y * 1013904223u) ^ (p.x * p.y * 747796405u);
    const float seeded = ((hash % 127u) < 3u || detail > 0.055) ? 1.0 : 0.0;
    field.write(half4(half(1.0 - seeded * 0.5), half(seeded * 0.25), 0, 1), p);
}

kernel void gvReactionStep(texture2d<half, access::sample> source [[texture(0)]],
    texture2d<half, access::sample> current [[texture(1)]],
    texture2d<half, access::write> next [[texture(2)]],
    constant GVReactionUniforms &u [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {
    if (p.x >= next.get_width() || p.y >= next.get_height()) return;
    const float2 size = float2(next.get_width(), next.get_height());
    const float2 uv = (float2(p) + 0.5) / size;
    const float2 dx = float2(1.0 / size.x, 0), dy = float2(0, 1.0 / size.y);
    float2 chemical = float2(current.sample(gvReactionSampler, uv).rg);
    float2 laplacian = -chemical;
    laplacian += 0.2 * (float2(current.sample(gvReactionSampler, uv + dx).rg) +
        float2(current.sample(gvReactionSampler, uv - dx).rg) +
        float2(current.sample(gvReactionSampler, uv + dy).rg) +
        float2(current.sample(gvReactionSampler, uv - dy).rg));
    laplacian += 0.05 * (float2(current.sample(gvReactionSampler, uv + dx + dy).rg) +
        float2(current.sample(gvReactionSampler, uv + dx - dy).rg) +
        float2(current.sample(gvReactionSampler, uv - dx + dy).rg) +
        float2(current.sample(gvReactionSampler, uv - dx - dy).rg));
    const float feed = mix(0.022, 0.055, u.controls.x);
    const float kill = mix(0.061, 0.064, u.controls.x);
    const float reaction = chemical.x * chemical.y * chemical.y;
    const float diffusion = mix(0.45, 1.0, u.controls.y);
    // dt=1 chemical unit per Euler step; this nine-point stencil is stable
    // for these bounded diffusion coefficients.
    chemical += float2(diffusion, diffusion * 0.5) * laplacian +
        float2(-reaction + feed * (1.0 - chemical.x), reaction - (kill + feed) * chemical.y);
    if (u.touch.w > 0.5) {
        const float2 aspect = float2(size.x / max(size.y, 1.0), 1);
        const float seed = 1.0 - smoothstep(0.015, 0.045, length((uv - u.touch.xy) * aspect));
        chemical = mix(chemical, float2(0.5, 0.25), seed * 0.8);
    }
    next.write(half4(half2(clamp(chemical, 0.0, 1.0)), 0, 1), p);
}

kernel void gvReactionComposite(texture2d<half, access::sample> source [[texture(0)]],
    texture2d<half, access::sample> field [[texture(1)]],
    texture2d<half, access::write> output [[texture(2)]],
    constant GVReactionUniforms &u [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {
    if (p.x >= output.get_width() || p.y >= output.get_height()) return;
    const float2 uv = (float2(p) + 0.5) / float2(output.get_width(), output.get_height());
    const half4 original = source.sample(gvReactionSampler, uv);
    if (u.controls.w <= 0) { output.write(original, p); return; }
    const float2 texel = 1.0 / float2(field.get_width(), field.get_height());
    const float b = float(field.sample(gvReactionSampler, uv).g);
    const float2 slope = float2(float(field.sample(gvReactionSampler, uv + float2(texel.x, 0)).g) -
        float(field.sample(gvReactionSampler, uv - float2(texel.x, 0)).g),
        float(field.sample(gvReactionSampler, uv + float2(0, texel.y)).g) -
        float(field.sample(gvReactionSampler, uv - float2(0, texel.y)).g));
    const float relief = dot(normalize(float3(-slope * mix(2.0, 25.0, u.controls.z), 1)),
        normalize(float3(-0.4, -0.5, 1)));
    const float pigment = smoothstep(0.04, 0.30, b);
    const float3 dye = mix(float3(original.rgb) * 0.60 + float3(0.02, 0.08, 0.10),
        float3(0.88, 0.42, 0.10) + float3(original.rgb) * 0.2, pigment);
    const float3 result = saturate(dye * (0.4 + relief * 0.9));
    output.write(half4(half3(mix(float3(original.rgb), result, saturate(u.controls.w))), original.a), p);
}

// Preserve the live chemical field when the quality tier changes.
kernel void gvReactionResize(texture2d<half, access::sample> source [[texture(0)]],
    texture2d<half, access::write> output [[texture(1)]], uint2 p [[thread_position_in_grid]]) {
    if (p.x >= output.get_width() || p.y >= output.get_height()) return;
    const float2 uv = (float2(p) + 0.5) / float2(output.get_width(), output.get_height());
    output.write(source.sample(gvReactionSampler, uv), p);
}
