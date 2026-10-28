#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>

using namespace metal;

// MARK: - Cold-start CRT terminal

static inline float terminalHash(float2 p) {
    p = fract(p * float2(0.1031, 0.1030));
    p += dot(p, p.yx + 33.33);
    return fract((p.x + p.y) * p.x);
}

/// The whole terminal raster as one CRT: power-on aperture, line tears,
/// scanlines, rolling sync bar, grain, and finally the digital
/// decay that breaks the screen into dropping blocks.
///
/// `dot` is the centre dot's brightness while `power` is still 0.
/// `power` 0→1 opens the raster from a dot to a line to the full screen.
/// `tear` 0→1 scales the tears. `decay` 0→1 grows the pixel
/// blocks and drops them out. The layer is opaque: the terminal draws its own
/// black field.
[[ stitchable ]]
half4 terminalBoot(float2 position, SwiftUI::Layer layer, float2 size, float time,
                   float power, float tear, float decay, float seed, float dot) {
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

    // Line tears: horizontal bands slide sideways during a burst.
    float tick = floor(time * 18.0);
    float band = floor(uv.y * 38.0);
    float bandHash = terminalHash(float2(band + seed, tick));
    if (bandHash > 1.0 - tear * 0.42) {
        p.x += (terminalHash(float2(band * 1.7, tick + 7.0)) - 0.5) * tear * 110.0;
    }

    // Digital decay: the raster quantises into blocks that grow and drop out.
    if (decay > 0.0) {
        float block = mix(2.0, 22.0, decay * decay);
        float2 cell = floor(p / block);
        float drop = terminalHash(cell + seed * 3.1);
        if (drop < decay * 1.2 - 0.2) {
            return half4(0, 0, 0, 1);
        }
        p = (cell + 0.5) * block;
    }

    // Outside the layer the sample is undefined; tears must not reach it.
    // One sample per pixel: the chroma split is composed in SwiftUI
    // (GVTerminalBoot), because sampling this layer at several offsets drops
    // text from the raster on the iOS 26 simulator while plain shapes survive.
    p = clamp(p, float2(0.5), extent - 0.5);
    half3 color = layer.sample(p).rgb;
    // While the raster is still a line it reads as a light source, not type.
    float flare = pow(1.0 - saturate(power), 3.0);
    color = mix(color, half3(0.92, 0.98, 1.0), half(flare));

    float scan = 0.74 + 0.26 * (0.5 + 0.5 * sin(position.y * 2.094));
    float roll = smoothstep(0.0, 0.06, fract(uv.y * 0.9 - time * 0.33))
               * (1.0 - smoothstep(0.06, 0.16, fract(uv.y * 0.9 - time * 0.33)));
    float flicker = 0.95 + 0.05 * terminalHash(float2(tick, 3.0));
    float grain = (terminalHash(position + fract(time * 61.0) * 97.0) - 0.5) * 0.07;
    float2 centred = uv - 0.5;
    float vignette = 1.0 - 0.55 * pow(saturate(length(centred * float2(1.0, 0.85)) * 1.35), 2.6);

    float gain = (scan * flicker + roll * 0.08) * vignette;
    color = color * half(gain) + half(grain);
    return half4(saturate(color), 1.0);
}
