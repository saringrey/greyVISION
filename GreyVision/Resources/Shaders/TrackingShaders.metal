#include <metal_stdlib>

using namespace metal;

// MARK: - Tracking analysis downsample
//
// Reduces the linear working frame to the small sRGB image the tracker
// segments and Vision reads. Four bilinear taps per output pixel cover the
// footprint of a ~5x reduction, so thin bright edges do not alias into
// flickering cells. Written straight into a shared buffer as tightly packed
// RGBA8, which is the layout both the CPU segmenter and CGImage expect.

static inline float gvTrackingEncode(float value) {
    value = saturate(value);
    return value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1.0 / 2.4) - 0.055;
}

kernel void gvTrackingDownsample(
    texture2d<half, access::sample> source [[texture(0)]],
    device uchar4 *output [[buffer(0)]],
    constant uint2 &size [[buffer(1)]],
    // Visible region of the source in UV: origin.xy, size.zw. Only what the
    // preview shows is analysed, so nothing is tracked off-screen.
    constant float4 &crop [[buffer(2)]],
    uint2 position [[thread_position_in_grid]]
) {
    if (position.x >= size.x || position.y >= size.y) {
        return;
    }
    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
    const float2 cell = crop.zw / float2(size);
    const float2 center = crop.xy + (float2(position) + 0.5) * cell;
    const float2 quarter = cell * 0.25;
    float3 color = float3(source.sample(linearSampler, center + float2(-quarter.x, -quarter.y)).rgb);
    color += float3(source.sample(linearSampler, center + float2(quarter.x, -quarter.y)).rgb);
    color += float3(source.sample(linearSampler, center + float2(-quarter.x, quarter.y)).rgb);
    color += float3(source.sample(linearSampler, center + float2(quarter.x, quarter.y)).rgb);
    color *= 0.25;
    const float3 encoded = float3(gvTrackingEncode(color.r), gvTrackingEncode(color.g), gvTrackingEncode(color.b));
    output[position.y * size.x + position.x] = uchar4(uchar3(round(encoded * 255.0)), 255);
}

// MARK: - Tracking burn-in composite
//
// Blends the rasterised tracking overlay over the finished frame for the
// outputs that leave the device — stills, takes, the Mac link. The overlay is
// premultiplied and read through an sRGB view, so sampling returns linear
// light, the same space as the working frame.
kernel void gvTrackingComposite(
    texture2d<half, access::sample> frame [[texture(0)]],
    texture2d<half, access::sample> overlay [[texture(1)]],
    texture2d<half, access::write> output [[texture(2)]],
    uint2 position [[thread_position_in_grid]]
) {
    if (position.x >= output.get_width() || position.y >= output.get_height()) {
        return;
    }
    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
    const float2 uv = (float2(position) + 0.5) / float2(output.get_width(), output.get_height());
    const half4 base = frame.sample(linearSampler, uv);
    const half4 mark = overlay.sample(linearSampler, uv);
    output.write(half4(mark.rgb + base.rgb * (1.0h - mark.a), base.a), position);
}
