#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>

using namespace metal;

// MARK: - Cold-start CRT terminal

constant float kTerminalBayer[16] = {
     0.0 / 16.0,  8.0 / 16.0,  2.0 / 16.0, 10.0 / 16.0,
    12.0 / 16.0,  4.0 / 16.0, 14.0 / 16.0,  6.0 / 16.0,
     3.0 / 16.0, 11.0 / 16.0,  1.0 / 16.0,  9.0 / 16.0,
    15.0 / 16.0,  7.0 / 16.0, 13.0 / 16.0,  5.0 / 16.0,
};

static inline float terminalHash(float2 p) {
    p = fract(p * float2(0.1031, 0.1030));
    p += dot(p, p.yx + 33.33);
    return fract((p.x + p.y) * p.x);
}

/// The whole terminal raster as one CRT: power-on aperture, scanlines, a
/// faint rolling bar and grain.
///
/// `dot` is the centre dot's brightness while `power` is 0 — before the
/// raster opens, and again as the afterglow once it has switched off.
/// `power` 0→1 opens the raster from a dot to a line to the full screen.
/// `decay` 0→1 is the crash: resolution and bit depth fall away and the
/// picture dissolves block by block to black.
///
/// Kept calm on purpose: no tears, no colour fringing beyond a hair of
/// convergence. Busy glitching is what makes a boot screen read as fake.
[[ stitchable ]]
half4 terminalBoot(float2 position, SwiftUI::Layer layer, float2 size, float time,
                   float power, float seed, float dot, float decay) {
    float2 extent = max(size, float2(1.0));
    float2 uv = position / extent;

    // Before the raster opens: one phosphor dot at centre, flaring on each
    // POST beep. A tight core and a wide halo, broken by the scanlines.
    if (power <= 0.0) {
        float d = length(position - extent * 0.5);
        float glow = exp(-d * d / 18.0) + exp(-d / 26.0) * 0.35 * dot;
        float scan = 0.7 + 0.3 * (0.5 + 0.5 * sin(position.y * 2.094));
        return half4(half3(0.92, 0.98, 1.0) * half(saturate(glow * dot * scan)), 1.0);
    }

    // Power-on: a bright dot stretches into a line, the line opens vertically.
    float openWidth = max(saturate(power * 7.0), 0.002);
    float openHeight = max(power * power, 0.0015);
    float2 local = float2((uv.x - 0.5) / openWidth, (uv.y - 0.5) / openHeight);
    if (abs(local.x) > 0.5 || abs(local.y) > 0.5) {
        return half4(0, 0, 0, 1);
    }
    float2 p = (local + 0.5) * extent;

    // The crash: a fast digital decay. Resolution halves in discrete steps
    // and the picture dissolves block by block in a Bayer order — a decoder
    // losing its data, not noise. Still one sample per pixel.
    float levels = 256.0;
    if (decay > 0.0) {
        float block = exp2(floor(saturate(decay * 1.25) * 5.0));
        float2 cell = floor(p / block);
        p = (cell + 0.5) * block;
        int2 bayer = int2(fmod(cell + seed, 4.0));
        float threshold = kTerminalBayer[bayer.y * 4 + bayer.x];
        if (threshold < saturate((decay - 0.35) / 0.65)) {
            return half4(0, 0, 0, 1);
        }
        levels = mix(32.0, 3.0, saturate(decay * 1.3));
    }

    // Outside the layer the sample is undefined.
    // One sample per pixel: sampling this layer at several offsets drops
    // text from the raster on the iOS 26 simulator while plain shapes survive.
    p = clamp(p, float2(0.5), extent - 0.5);
    half3 color = layer.sample(p).rgb;
    if (levels < 256.0) {
        color = floor(color * half(levels) + 0.5h) / half(levels);
    }
    // While the raster is still a line it reads as a light source, not type.
    float flare = pow(1.0 - saturate(power), 3.0);
    color = mix(color, half3(0.92, 0.98, 1.0), half(flare));

    float tick = floor(time * 18.0);
    float scan = 0.8 + 0.2 * (0.5 + 0.5 * sin(position.y * 2.094));
    float roll = smoothstep(0.0, 0.06, fract(uv.y * 0.9 - time * 0.33))
               * (1.0 - smoothstep(0.06, 0.16, fract(uv.y * 0.9 - time * 0.33)));
    float flicker = 0.985 + 0.015 * terminalHash(float2(tick, 3.0 + seed));
    float grain = (terminalHash(position + fract(time * 61.0) * 97.0) - 0.5) * 0.035;
    float2 centred = uv - 0.5;
    float vignette = 1.0 - 0.45 * pow(saturate(length(centred * float2(1.0, 0.85)) * 1.35), 2.6);

    float gain = (scan * flicker + roll * 0.04) * vignette;
    color = color * half(gain) + half(grain);
    return half4(saturate(color), 1.0);
}
