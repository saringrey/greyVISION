#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>

using namespace metal;

// MARK: - Tilt- and touch-responsive ordered-dither nebula

constant float kBayer4[16] = {
     0.0 / 16.0,  8.0 / 16.0,  2.0 / 16.0, 10.0 / 16.0,
    12.0 / 16.0,  4.0 / 16.0, 14.0 / 16.0,  6.0 / 16.0,
     3.0 / 16.0, 11.0 / 16.0,  1.0 / 16.0,  9.0 / 16.0,
    15.0 / 16.0,  7.0 / 16.0, 13.0 / 16.0,  5.0 / 16.0,
};

static inline float cascadeHash(float2 p) {
    p = fract(p * float2(0.1031, 0.1030));
    p += dot(p, p.yx + 33.33);
    return fract((p.x + p.y) * p.x);
}

static inline float cascadeNoise(float2 p) {
    float2 cell = floor(p);
    float2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(cascadeHash(cell), cascadeHash(cell + float2(1, 0)), f.x),
               mix(cascadeHash(cell + float2(0, 1)), cascadeHash(cell + float2(1, 1)), f.x), f.y);
}

static inline float cascadeCloud(float2 p) {
    return cascadeNoise(p) * 0.57
         + cascadeNoise(p * 2.03 + 9.7) * 0.29
         + cascadeNoise(p * 4.11 + 23.1) * 0.14;
}

// No microphone uniforms; the Bayer pattern stays anchored as the cloud moves.
//
// Black and white. The cloud is rendered as ordered dither in white on true
// black, five levels deep, with a soft glow under its densest cores so the
// highlights read as light rather than as grey. A faint dither field runs
// across the whole screen, so even the empty black has grain. The cloud and
// its dither grid fall slowly down the screen together, in whole dither
// cells so the grid never shimmers; the envelope and ribbon stay put, so the
// field drifts through a fixed glow rather than sliding off the screen.
[[ stitchable ]]
half4 splashNebula(float2 position, half4 source, float2 size, float time,
                   float2 tilt, float3 touch, float touchAge, float3 glowColor, float3 shadeColor) {
    float2 uv = position / max(size, float2(1.0));
    float aspect = size.x / max(size.y, 1.0);
    float2 fieldPoint = (uv - 0.5) * float2(aspect, 1.0);
    float2 touchDelta = (uv - touch.xy) * float2(aspect, 1.0);
    float glow = exp(-dot(touchDelta, touchDelta) * 36.0) * touch.z;
    float ripple = (1.0 - smoothstep(0.006, 0.025,
        abs(length(touchDelta) - 0.025 - touchAge * 0.18))) * touch.z;
    fieldPoint += tilt * 0.16 + touchDelta * glow * 0.3;
    const float ditherPixel = 1.5;
    const float fallSpeed = 34.0; // points per second
    float fall = floor(time * fallSpeed / ditherPixel) * ditherPixel;
    float2 fallen = position - float2(0.0, fall);
    // Stretched tall, so the cloud reads as falling streaks; tilt only
    // leans it a little.
    float2 fallPoint = (fallen / max(size, float2(1.0)) - 0.5) * float2(aspect, 0.45)
                     + tilt * 0.05 + touchDelta * glow * 0.3;
    float2 drift = float2(time * 0.006, 0.0);
    float warp = cascadeCloud(fallPoint * 3.8 + drift);
    float cloud = cascadeCloud(fallPoint * 5.4 + float2(warp * 1.8, warp) + drift);
    float ribbon = 1.0 - smoothstep(0.04, 0.30,
        abs(fieldPoint.y + 0.18 * sin(fieldPoint.x * 4.0 + warp * 3.0)));
    float envelope = exp(-dot(fieldPoint * float2(1.2, 1.5), fieldPoint * float2(1.2, 1.5)) * 2.2);
    float dust = smoothstep(0.21, 0.72, cloud);
    float density = clamp((dust * 0.7 + ribbon * 0.4) * envelope
                          + glow * 0.45 + ripple * 0.25, 0.0, 1.0);

    // 4x4 Bayer cells, falling with the cloud, turn it into ordered texture.
    int2 ditherCell = int2(floor(fallen / ditherPixel)) & 3;
    float threshold = kBayer4[ditherCell.y * 4 + ditherCell.x];
    float dither = floor(density * 4.0 + threshold) / 4.0;
    // Grey at the thin edges of the cloud, white at its cores.
    float3 ink = mix(shadeColor, glowColor, smoothstep(0.25, 0.8, density));
    float3 color = ink * dither * 0.74;

    // Glow: a smooth bloom under the densest dither, so the white burns.
    color += glowColor * pow(density, 3.2) * 0.09;

    // Grain everywhere: a sparse, slowly drifting dither field over the black.
    float haze = cascadeNoise(fallPoint * 2.2) * 0.16 + 0.02;
    color += shadeColor * step(1.0 - haze, threshold) * 0.22;

    // The image recedes below the format controls rather than competing with them.
    float edge = smoothstep(0.0, 0.10, uv.y);
    float controlsShade = 1.0 - smoothstep(0.60, 1.0, uv.y) * 0.72;
    color *= edge * controlsShade;
    return half4(half3(clamp(color, 0.0, 1.0)), 1.0h);
}

// Controls and submenu panels share the nebula's ordered white texture.
[[ stitchable ]]
half4 splashPlate(float2 position, half4 source, float2 size, float active,
                  float3 glowColor, float3 shadeColor) {
    float2 uv = position / max(size, float2(1.0));
    int2 cell = int2(floor(position / 1.5)) & 3;
    float threshold = kBayer4[cell.y * 4 + cell.x];
    float density = (1.0 - uv.y) * (0.25 + 0.65 * (1.0 - uv.x));
    float dots = step(threshold, density);
    float3 tint = mix(glowColor, shadeColor, uv.x);
    float3 color = float3(0.018, 0.018, 0.02) + tint * dots * mix(0.07, 0.18, active);
    return half4(half3(color), 1.0h);
}
