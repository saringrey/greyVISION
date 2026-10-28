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
[[ stitchable ]]
half4 splashNebula(float2 position, half4 source, float2 size, float time,
                   float2 tilt, float3 touch, float touchAge, float3 cyan, float3 violet) {
    float2 uv = position / max(size, float2(1.0));
    float aspect = size.x / max(size.y, 1.0);
    float2 fieldPoint = (uv - 0.5) * float2(aspect, 1.0);
    float2 touchDelta = (uv - touch.xy) * float2(aspect, 1.0);
    float glow = exp(-dot(touchDelta, touchDelta) * 36.0) * touch.z;
    float ripple = (1.0 - smoothstep(0.006, 0.025,
        abs(length(touchDelta) - 0.025 - touchAge * 0.18))) * touch.z;
    fieldPoint += tilt * 0.16 + touchDelta * glow * 0.3;
    float2 drift = float2(time * 0.008, -time * 0.005);
    float warp = cascadeCloud(fieldPoint * 3.8 + drift);
    float cloud = cascadeCloud(fieldPoint * 5.4 + float2(warp * 1.8, warp) + drift);
    float ribbon = 1.0 - smoothstep(0.04, 0.30,
        abs(fieldPoint.y + 0.18 * sin(fieldPoint.x * 4.0 + warp * 3.0)));
    float envelope = exp(-dot(fieldPoint * float2(1.2, 1.5), fieldPoint * float2(1.2, 1.5)) * 2.2);
    float dust = smoothstep(0.21, 0.72, cloud);
    float density = clamp((dust * 0.65 + ribbon * 0.35) * envelope
                          + glow * 0.35 + ripple * 0.18, 0.0, 1.0);

    // Stable 4x4 Bayer cells turn the cloud into visible, ordered-dither texture.
    const float ditherPixel = 1.5;
    int2 ditherCell = int2(floor(position / ditherPixel)) & 3;
    float threshold = kBayer4[ditherCell.y * 4 + ditherCell.x];
    float dither = floor(density * 3.0 + threshold) / 3.0;
    float hue = smoothstep(-0.25, 0.35, fieldPoint.x + cloud * 0.2);
    float3 nebula = mix(cyan, violet, hue) * dither * 0.34;
    float3 color = float3(0.007, 0.012, 0.023) + nebula;

    // The image recedes below the format controls rather than competing with them.
    float edge = smoothstep(0.0, 0.10, uv.y);
    float controlsShade = 1.0 - smoothstep(0.60, 1.0, uv.y) * 0.72;
    color *= edge * controlsShade;
    return half4(half3(clamp(color, 0.0, 1.0)), 1.0h);
}

// Controls and submenu panels share the nebula's blue, ordered texture.
[[ stitchable ]]
half4 splashPlate(float2 position, half4 source, float2 size, float active,
                  float3 cyan, float3 violet) {
    float2 uv = position / max(size, float2(1.0));
    int2 cell = int2(floor(position / 1.5)) & 3;
    float threshold = kBayer4[cell.y * 4 + cell.x];
    float density = (1.0 - uv.y) * (0.25 + 0.65 * (1.0 - uv.x));
    float dots = step(threshold, density);
    float3 tint = mix(cyan, violet, uv.x);
    float3 color = float3(0.012, 0.035, 0.075) + tint * dots * mix(0.055, 0.14, active);
    return half4(half3(color), 1.0h);
}
