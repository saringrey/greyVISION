#include <metal_stdlib>

using namespace metal;

// MARK: - Audit still feed (DEBUG diagnostics)
//
// Stands in for the camera on the simulator when an audit still is supplied.
// The still drifts and breathes so temporal, flow and mosh effects have real
// motion to work with, and a light sweeps across it so feedback and trail
// effects have a bright moving subject. The still is loaded as sRGB, so
// sampling already returns linear light — the same space the camera feed
// writes into.
kernel void gvCameraSyntheticStill(
    texture2d<half, access::sample> stillTexture [[texture(0)]],
    texture2d<half, access::write> outputTexture [[texture(1)]],
    constant float &time [[buffer(0)]],
    uint2 position [[thread_position_in_grid]]
) {
    const uint width = outputTexture.get_width();
    const uint height = outputTexture.get_height();
    if (position.x >= width || position.y >= height) {
        return;
    }
    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
    const float2 size = float2(width, height);
    const float2 uv = (float2(position) + 0.5) / size;

    // Aspect-fill the still into the frame, then a slow pan and zoom.
    const float2 stillSize = float2(stillTexture.get_width(), stillTexture.get_height());
    const float fill = max(size.x / stillSize.x, size.y / stillSize.y);
    const float2 span = size / (stillSize * fill);
    const float zoom = 1.12 + 0.08 * sin(time * 0.31);
    const float2 pan = float2(sin(time * 0.23), cos(time * 0.17)) * 0.05;
    const float2 stillUV = 0.5 + (uv - 0.5) * span / zoom + pan;
    float3 color = float3(stillTexture.sample(linearSampler, stillUV).rgb);

    // A soft light orbiting the frame.
    const float2 orb = float2(0.5 + 0.32 * sin(time * 0.9), 0.45 + 0.22 * sin(time * 1.3));
    const float2 delta = (uv - orb) * float2(size.x / size.y, 1.0);
    color += float3(1.0, 0.92, 0.80) * exp(-dot(delta, delta) * 900.0) * 2.4;

    outputTexture.write(half4(half3(color), 1.0h), position);
}

// MARK: - Effect energy (DEBUG diagnostics)
//
// How much the effect graph changed the frame: mean absolute difference
// between the clean source and the graph output over a 64×64 lattice,
// accumulated as fixed-point into one atomic. An effect that "does nothing"
// reads as zero here, whatever it looks like in a screenshot.
kernel void gvEffectEnergy(
    texture2d<half, access::sample> source [[texture(0)]],
    texture2d<half, access::sample> output [[texture(1)]],
    device atomic_uint *sum [[buffer(0)]],
    uint2 position [[thread_position_in_grid]]
) {
    if (position.x >= 64 || position.y >= 64) {
        return;
    }
    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
    const float2 uv = (float2(position) + 0.5) / 64.0;
    const float3 a = saturate(float3(source.sample(linearSampler, uv).rgb));
    const float3 b = saturate(float3(output.sample(linearSampler, uv).rgb));
    const float delta = (abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b)) / 3.0;
    atomic_fetch_add_explicit(sum, uint(delta * 65535.0), memory_order_relaxed);
}
