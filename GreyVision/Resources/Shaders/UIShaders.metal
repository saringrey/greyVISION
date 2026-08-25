#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>

using namespace metal;

[[ stitchable ]]
half4 logoSignal(float2 position, half4 source, float time, float intensity) {
    if (source.a <= 0.001h) {
        return source;
    }

    const float scan = 0.5 + 0.5 * sin(position.y * 0.19 + time * 3.1);
    const float noise = fract(sin(dot(floor(position * 0.35), float2(12.9898, 78.233))) * 43758.5453);
    // Signal lift is neutral white — the palette carries exactly one accent,
    // and a violet cast here read as a colour error rather than as energy.
    const half lift = half((scan * 0.14 + noise * 0.05) * intensity);
    source.rgb += half3(lift);
    source.rgb *= half(0.94 + scan * 0.08 * intensity);
    return source;
}

[[ stitchable ]]
float2 logoDisintegration(float2 position, float time, float amount) {
    if (amount <= 0.0001) {
        return position;
    }

    const float band = floor(position.y / 7.0);
    const float noise = fract(sin(band * 91.713 + floor(time * 8.0) * 17.31) * 43758.5453);
    const float active = step(0.82, noise);
    const float direction = noise > 0.91 ? 1.0 : -1.0;
    return position + float2(active * direction * amount * 5.0, 0.0);
}

// MARK: - Boot sequence

float gvBootHash(float2 value) {
    return fract(sin(dot(value, float2(127.1, 311.7))) * 43758.5453123);
}

float gvBootLuma(half3 color) {
    return dot(float3(color), float3(0.2126, 0.7152, 0.0722));
}

/// Reconstructs the mark through the engine's own visual language:
/// point cloud -> wireframe -> broken raster blocks -> datamosh displacement ->
/// pixel-sort streak -> clean. `progress` runs 0...1 across the phase.
[[ stitchable ]]
half4 bootReconstruct(
    float2 position,
    SwiftUI::Layer layer,
    float2 size,
    float progress,
    float time
) {
    const half4 source = layer.sample(position);
    if (progress >= 0.995) {
        return source;
    }

    const float2 safeSize = max(size, float2(1.0));
    const float span = max(safeSize.x, safeSize.y);

    // Stage weights. Each stage owns a window and cross-fades into the next.
    const float pointCloud = 1.0 - smoothstep(0.10, 0.26, progress);
    const float wireframe = smoothstep(0.14, 0.28, progress) * (1.0 - smoothstep(0.34, 0.46, progress));
    const float blocks = smoothstep(0.36, 0.48, progress) * (1.0 - smoothstep(0.56, 0.66, progress));
    const float mosh = smoothstep(0.54, 0.64, progress) * (1.0 - smoothstep(0.72, 0.82, progress));
    const float sorted = smoothstep(0.74, 0.82, progress) * (1.0 - smoothstep(0.90, 0.99, progress));

    half4 result = source;

    // Broken raster blocks + datamosh displacement share block geometry.
    if (blocks > 0.001 || mosh > 0.001) {
        const float blockSize = mix(26.0, 7.0, progress);
        const float2 block = floor(position / blockSize);
        const float noise = gvBootHash(block + floor(time * 9.0));
        const float2 displaced = position + float2(
            (noise - 0.5) * mix(30.0, 2.0, progress),
            (gvBootHash(block + 41.0) - 0.5) * mix(11.0, 1.0, progress)
        );
        const half4 moshed = layer.sample(displaced);
        const half4 quantized = layer.sample((block + 0.5) * blockSize);
        // Some blocks are simply missing while the raster is still broken.
        const half dropout = half(step(0.82 - progress * 0.42, noise));
        result = mix(result, quantized * dropout, half(blocks));
        result = mix(result, moshed, half(mosh));
    }

    // Short horizontal pixel-sort streak.
    if (sorted > 0.001) {
        const float reach = mix(22.0, 2.0, progress);
        half4 winner = result;
        float best = gvBootLuma(result.rgb);
        for (uint index = 1; index <= 5; ++index) {
            const half4 candidate = layer.sample(position - float2(reach * float(index) * 0.2, 0.0));
            const float candidateLuma = gvBootLuma(candidate.rgb) * float(candidate.a);
            if (candidateLuma > best) {
                best = candidateLuma;
                winner = candidate;
            }
        }
        result = mix(result, winner, half(sorted * 0.85));
    }

    // Edge structure.
    if (wireframe > 0.001) {
        const float edgeStep = max(span * 0.004, 1.0);
        const float centre = float(layer.sample(position).a);
        const float dx = float(layer.sample(position + float2(edgeStep, 0.0)).a) -
            float(layer.sample(position - float2(edgeStep, 0.0)).a);
        const float dy = float(layer.sample(position + float2(0.0, edgeStep)).a) -
            float(layer.sample(position - float2(0.0, edgeStep)).a);
        const float structural = saturate(length(float2(dx, dy)) * 2.6 + centre * 0.06);
        const half3 wire = half3(half(structural * 0.70), half(structural * 0.28), half(structural));
        result = mix(result, half4(wire, half(structural)), half(wireframe));
    }

    // Sparse point cloud.
    if (pointCloud > 0.001) {
        const float cell = mix(4.5, 13.0, pointCloud);
        const float2 local = fract(position / cell) - 0.5;
        const float2 cellID = floor(position / cell);
        const float jitter = gvBootHash(cellID);
        const float radius = 0.14 + jitter * 0.12;
        const float dotMask = 1.0 - smoothstep(radius, radius + 0.14, length(local));
        const half occupancy = layer.sample((cellID + 0.5) * cell).a;
        const float sparkle = 0.55 + 0.45 * sin(time * 6.0 + jitter * 22.0);
        const half3 cloud = half3(half(0.72 * sparkle), half(0.36 * sparkle), half(sparkle));
        const half mask = half(dotMask) * occupancy;
        result = mix(result, half4(cloud * mask, mask), half(pointCloud));
    }

    return result;
}

/// A one-frame RGB separation used immediately after the synchronisation sweep.
[[ stitchable ]]
half4 bootChromaShift(float2 position, SwiftUI::Layer layer, float amount) {
    if (amount <= 0.001) {
        return layer.sample(position);
    }
    const float offset = amount * 3.4;
    const half4 base = layer.sample(position);
    const half red = layer.sample(position + float2(offset, 0.0)).r;
    const half blue = layer.sample(position - float2(offset, 0.0)).b;
    return half4(red, base.g, blue, base.a);
}

/// Horizontal raster tear used when the splash opens a signal path into the
/// camera. `progress` runs 0...1; slices displace, then settle.
[[ stitchable ]]
half4 bootRasterTear(
    float2 position,
    SwiftUI::Layer layer,
    float2 size,
    float progress
) {
    const float2 safeSize = max(size, float2(1.0));
    const float slices = 5.0;
    const float slice = floor(position.y / safeSize.y * slices);
    const float noise = gvBootHash(float2(slice, 3.0));
    const float envelope = sin(saturate(progress) * 3.14159265);
    const float shift = (noise - 0.5) * envelope * safeSize.x * 0.06;
    const float2 torn = float2(position.x + shift, position.y);

    half4 result = layer.sample(torn);
    // A travelling tear line reads as the raster head crossing the frame.
    // Neutral white: the palette carries exactly one accent, and this line
    // used to add a violet flash that read as a rendering fault.
    const float head = progress * safeSize.y * 1.2;
    const float distanceToHead = abs(position.y - head);
    if (distanceToHead < 1.6) {
        result.rgb += half3(0.70h) * half(envelope);
    }
    result.a *= half(1.0 - saturate(progress * progress));
    return result;
}

struct GVDepthUniforms {
    float4 intrinsics;
    float4 viewport;
    float4 tuning;
    float4 pose;
    float4 controls;
    float4 interaction;
    uint4 source;
    uint4 options;
};

struct GVDepthRaster {
    float4 position [[position]];
    float2 uv;
};

struct GVDepthPointRaster {
    float4 position [[position]];
    float pointSize [[point_size]];
    float4 color;
    /// View-space surface normal, used to shade the splat as geometry rather
    /// than as a flat emissive disc.
    float3 normal;
    /// LiDAR confidence 0..1. Low-confidence returns are kept but rendered
    /// weaker, which is what a real scanner does — culling them outright
    /// leaves holes that read as broken capture.
    float confidence;
    /// Metres, for distance-based fog.
    float viewDepth;
};

constexpr sampler gvLinearSampler(coord::normalized, address::clamp_to_edge, filter::linear);

float3 gvCameraColor(
    float2 uv,
    texture2d<float, access::sample> lumaTexture,
    texture2d<float, access::sample> chromaTexture
) {
    const float y = lumaTexture.sample(gvLinearSampler, uv).r;
    const float2 chroma = chromaTexture.sample(gvLinearSampler, uv).rg - float2(0.5);
    return saturate(float3(
        y + 1.5748 * chroma.y,
        y - 0.1873 * chroma.x - 0.4681 * chroma.y,
        y + 1.8556 * chroma.x
    ));
}

float2 gvSensorUV(float2 viewUV, constant GVDepthUniforms &uniforms) {
    const uint orientation = uniforms.options.y;
    const bool portrait = orientation <= 1;
    const float sourceWidth = portrait ? uniforms.viewport.w : uniforms.viewport.z;
    const float sourceHeight = portrait ? uniforms.viewport.z : uniforms.viewport.w;
    const float sourceAspect = sourceWidth / max(sourceHeight, 1.0);
    const float viewportAspect = uniforms.viewport.x / max(uniforms.viewport.y, 1.0);

    float2 cropped = viewUV;
    if (sourceAspect > viewportAspect) {
        cropped.x = (viewUV.x - 0.5) * (viewportAspect / sourceAspect) + 0.5;
    } else {
        cropped.y = (viewUV.y - 0.5) * (sourceAspect / viewportAspect) + 0.5;
    }

    switch (orientation) {
        case 0:
            return float2(cropped.y, 1.0 - cropped.x);
        case 1:
            return float2(1.0 - cropped.y, cropped.x);
        case 3:
            return 1.0 - cropped;
        default:
            return cropped;
    }
}

float3 gvDepthPalette(float normalizedDepth) {
    const float t = saturate(normalizedDepth);
    const float3 nearColor = float3(0.73, 0.18, 1.0);
    const float3 middleColor = float3(0.10, 0.88, 0.72);
    const float3 farColor = float3(1.0, 0.40, 0.08);
    return t < 0.5
        ? mix(nearColor, middleColor, t * 2.0)
        : mix(middleColor, farColor, (t - 0.5) * 2.0);
}

bool gvValidDepth(float depth, constant GVDepthUniforms &uniforms) {
    return isfinite(depth) && depth > uniforms.tuning.x && depth < uniforms.tuning.y;
}

vertex GVDepthRaster gvDepthFullscreenVertex(uint vertexID [[vertex_id]]) {
    const float2 positions[3] = {
        float2(-1.0, -1.0),
        float2(3.0, -1.0),
        float2(-1.0, 3.0)
    };
    const float2 coordinates[3] = {
        float2(0.0, 1.0),
        float2(2.0, 1.0),
        float2(0.0, -1.0)
    };
    GVDepthRaster output;
    output.position = float4(positions[vertexID], 0.0, 1.0);
    output.uv = coordinates[vertexID];
    return output;
}

fragment float4 gvDepthCompositeFragment(
    GVDepthRaster input [[stage_in]],
    texture2d<float, access::sample> lumaTexture [[texture(0)]],
    texture2d<float, access::sample> chromaTexture [[texture(1)]],
    texture2d<float, access::sample> depthTexture [[texture(2)]],
    texture2d<uint, access::read> confidenceTexture [[texture(3)]],
    texture2d<float, access::sample> personMaskTexture [[texture(4)]],
    texture2d<float, access::sample> historyTexture [[texture(5)]],
    constant GVDepthUniforms &uniforms [[buffer(0)]]
) {
    const float2 sensorUV = gvSensorUV(input.uv, uniforms);
    const float depth = depthTexture.sample(gvLinearSampler, sensorUV).r;
    const float range = max(uniforms.tuning.y - uniforms.tuning.x, 0.001);
    const float normalizedDepth = saturate((depth - uniforms.tuning.x) / range);
    const float3 cameraColor = gvCameraColor(sensorUV, lumaTexture, chromaTexture);
    const uint mode = uniforms.options.x;
    const float wet = saturate(uniforms.tuning.z);
    const float2 texel = 1.0 / max(float2(uniforms.source.xy), float2(1.0));
    const uint2 confidenceCoordinate = min(
        uint2(saturate(sensorUV) * float2(uniforms.source.xy)),
        uniforms.source.xy - 1
    );
    const uint confidence = uniforms.options.z == 1
        ? confidenceTexture.read(confidenceCoordinate).r
        : 2;
    const float confidenceValue = float(confidence) / 2.0;
    const bool confidenceValid = confidence >= uniforms.source.w;

    if (mode == 15) {
        const float2 viewTexel = 1.0 / max(uniforms.viewport.xy, float2(1.0));
        const float person = personMaskTexture.sample(gvLinearSampler, input.uv).r;
        const float personLeft = personMaskTexture.sample(
            gvLinearSampler,
            input.uv - float2(viewTexel.x * 2.0, 0.0)
        ).r;
        const float personRight = personMaskTexture.sample(
            gvLinearSampler,
            input.uv + float2(viewTexel.x * 2.0, 0.0)
        ).r;
        const float personTop = personMaskTexture.sample(
            gvLinearSampler,
            input.uv - float2(0.0, viewTexel.y * 2.0)
        ).r;
        const float personBottom = personMaskTexture.sample(
            gvLinearSampler,
            input.uv + float2(0.0, viewTexel.y * 2.0)
        ).r;
        const float maskGradient = length(float2(
            personRight - personLeft,
            personBottom - personTop
        ));
        const float edgeThreshold = mix(0.42, 0.06, uniforms.controls.w);
        const float outerEdge = smoothstep(edgeThreshold, edgeThreshold + 0.18, maskGradient) *
            smoothstep(0.12, 0.72, person);
        const float3 historyColor = uniforms.options.w == 1
            ? historyTexture.sample(gvLinearSampler, input.uv).rgb
            : cameraColor;
        const float currentLuma = dot(cameraColor, float3(0.2126, 0.7152, 0.0722));
        const float historyLuma = dot(historyColor, float3(0.2126, 0.7152, 0.0722));
        const float temporalMotion = abs(currentLuma - historyLuma);
        const float currentRight = dot(
            gvCameraColor(sensorUV + float2(texel.x * 3.0, 0.0), lumaTexture, chromaTexture),
            float3(0.2126, 0.7152, 0.0722)
        );
        const float currentDown = dot(
            gvCameraColor(sensorUV + float2(0.0, texel.y * 3.0), lumaTexture, chromaTexture),
            float3(0.2126, 0.7152, 0.0722)
        );
        const float historyRight = dot(
            historyTexture.sample(gvLinearSampler, input.uv + float2(viewTexel.x * 3.0, 0.0)).rgb,
            float3(0.2126, 0.7152, 0.0722)
        );
        const float historyDown = dot(
            historyTexture.sample(gvLinearSampler, input.uv + float2(0.0, viewTexel.y * 3.0)).rgb,
            float3(0.2126, 0.7152, 0.0722)
        );
        const float2 opticalFlow = float2(
            (currentRight - currentLuma) - (historyRight - historyLuma),
            (currentDown - currentLuma) - (historyDown - historyLuma)
        );
        const bool depthAccepted = gvValidDepth(depth, uniforms) && confidenceValid;
        const float depthGate = depthAccepted
            ? mix(1.35, 0.45, normalizedDepth)
            : 0.0;
        const float motionGate = smoothstep(0.012, mix(0.05, 0.22, uniforms.controls.y), temporalMotion);
        const float silhouetteMotion = outerEdge * max(motionGate, 0.12) * depthGate;
        const float2 originVector = input.uv - uniforms.interaction.xy;
        const float originDistance = max(length(originVector), 0.0001);
        const float2 originDirection = originVector / originDistance;
        const float pulse = 0.72 + 0.28 * sin(uniforms.interaction.z * 2.4 + originDistance * 24.0);
        const float touchVelocity = length(uniforms.pose.zw);
        const float stretchAmount = silhouetteMotion * uniforms.controls.x * pulse * (0.30 + touchVelocity * 0.18);
        const float2 flowOffset = opticalFlow * uniforms.controls.y * 0.48;
        const float2 stretchedUV = input.uv - originDirection * stretchAmount - flowOffset;
        const float3 stretched = historyTexture.sample(gvLinearSampler, stretchedUV).rgb;
        const float trailAmount = mix(0.62, 0.96, uniforms.controls.z) * person;
        float3 feedback = mix(cameraColor, historyColor, trailAmount);
        const float decayNoise = fract(sin(dot(
            floor(input.uv * uniforms.viewport.xy / 6.0) + floor(uniforms.interaction.z * 8.0),
            float2(12.9898, 78.233)
        )) * 43758.5453);
        const float decayGate = silhouetteMotion * step(0.20, decayNoise);
        feedback = mix(feedback, max(stretched, feedback * 0.74), saturate(silhouetteMotion + decayGate));
        feedback += float3(0.48, 0.08, 0.82) * silhouetteMotion * 0.42;
        return float4(mix(cameraColor, feedback, wet), 1.0);
    }

    if (!gvValidDepth(depth, uniforms) || !confidenceValid) {
        return float4(cameraColor * 0.16, 1.0);
    }

    if (mode == 1) {
        const float contrast = mix(0.55, 2.25, uniforms.controls.y);
        const float shapedDepth = saturate((normalizedDepth - 0.5) * contrast + 0.5);
        const float3 palette = gvDepthPalette(fract(shapedDepth + uniforms.controls.x * 0.38));
        return float4(mix(cameraColor, palette, wet), 1.0);
    }

    if (mode == 2) {
        const float sampleWidth = mix(0.75, 4.0, uniforms.controls.x);
        const float rightSample = depthTexture.sample(
            gvLinearSampler,
            sensorUV + float2(texel.x * sampleWidth, 0.0)
        ).r;
        const float downSample = depthTexture.sample(
            gvLinearSampler,
            sensorUV + float2(0.0, texel.y * sampleWidth)
        ).r;
        const float right = gvValidDepth(rightSample, uniforms) ? rightSample : depth;
        const float down = gvValidDepth(downSample, uniforms) ? downSample : depth;
        const float gradient = max(abs(depth - right), abs(depth - down));
        const float threshold = mix(0.18, 0.008, uniforms.controls.y);
        const float edge = smoothstep(threshold * 0.35, threshold, gradient);
        const float3 edgeColor = mix(float3(0.18, 0.88, 0.82), float3(0.78, 0.30, 1.0), normalizedDepth);
        const float3 effectColor = mix(cameraColor * 0.24, edgeColor, edge);
        return float4(mix(cameraColor, effectColor, wet), 1.0);
    }

    if (mode == 3) {
        // The parallax field centres on the finger while it is in contact, and
        // dragging it stirs the field with the touch velocity.
        const float2 touchOrigin = uniforms.interaction.w > 0.5
            ? uniforms.interaction.xy
            : float2(0.5);
        const float2 direction = input.uv - touchOrigin;
        const float touchVelocity = length(uniforms.pose.zw);
        const float curvedDepth = pow(max(1.0 - normalizedDepth, 0.001), mix(0.45, 2.4, uniforms.controls.y));
        const float parallax = curvedDepth * uniforms.tuning.z * mix(0.018, 0.14, uniforms.controls.x);
        const float2 warpedSensorUV = gvSensorUV(
            input.uv + direction * (parallax + curvedDepth * touchVelocity * 0.055),
            uniforms
        );
        const float3 warpedColor = gvCameraColor(warpedSensorUV, lumaTexture, chromaTexture);
        return float4(warpedColor, 1.0);
    }

    if (mode == 4) {
        const float3 lowColor = mix(float3(0.025), float3(0.18, 0.02, 0.24), uniforms.controls.x);
        const float3 highColor = mix(float3(0.10, 0.80, 0.64), float3(0.72, 0.28, 1.0), uniforms.controls.y);
        const float3 effectColor = mix(lowColor, highColor, confidenceValue);
        return float4(mix(cameraColor, effectColor, wet), 1.0);
    }

    if (mode == 5) {
        const float density = pow(normalizedDepth, mix(0.35, 3.2, uniforms.controls.x));
        const float3 fogColor = mix(
            float3(0.20, 0.09, 0.32),
            float3(0.18, 0.72, 0.78),
            uniforms.controls.y
        );
        // Dragging through the fog clears a wake behind the finger.
        const float touchVelocity = length(uniforms.pose.zw);
        const float wake = touchVelocity * smoothstep(0.30, 0.03, length(input.uv - uniforms.interaction.xy));
        const float fogAmount = saturate(density * uniforms.tuning.z * (1.0 - wake * 0.85));
        return float4(mix(cameraColor, fogColor, fogAmount), 1.0);
    }

    if (mode == 6) {
        const float width = max(uniforms.controls.w, 0.01);
        const float distanceToSlice = abs(normalizedDepth - uniforms.controls.z);
        const float feather = mix(0.002, width * 0.85, uniforms.controls.y);
        const float inside = 1.0 - smoothstep(width, width + feather, distanceToSlice);
        const float boundary = 1.0 - smoothstep(0.0, max(feather, 0.002), abs(distanceToSlice - width));
        const float3 isolated = mix(cameraColor * 0.08, cameraColor, inside);
        const float3 effectColor = isolated + float3(0.56, 0.12, 0.92) * boundary * 0.52;
        return float4(mix(cameraColor, effectColor, wet), 1.0);
    }

    if (mode == 7) {
        const float frequency = mix(5.0, 52.0, uniforms.controls.y);
        const float phase = uniforms.controls.z * 6.2831853;
        const float wave = abs(sin(normalizedDepth * frequency * 3.1415927 + phase));
        const float lineWidth = mix(0.035, 0.72, uniforms.controls.w);
        const float contour = 1.0 - smoothstep(lineWidth, min(lineWidth + 0.16, 0.99), wave);
        const float3 contourColor = mix(float3(0.20, 0.95, 0.78), float3(0.84, 0.22, 1.0), normalizedDepth);
        const float3 effectColor = mix(cameraColor * 0.42, contourColor, contour);
        return float4(mix(cameraColor, effectColor, wet), 1.0);
    }

    if (mode == 8) {
        const float levels = floor(mix(2.0, 18.0, uniforms.controls.y));
        const float quantized = floor(normalizedDepth * levels) / max(levels - 1.0, 1.0);
        const float3 palette = gvDepthPalette(fract(quantized + uniforms.controls.x * 0.35));
        return float4(mix(cameraColor, palette, wet), 1.0);
    }

    if (mode == 9) {
        const float sampleWidth = mix(4.0, 0.65, uniforms.controls.x);
        const float rightSample = depthTexture.sample(
            gvLinearSampler,
            sensorUV + float2(texel.x * sampleWidth, 0.0)
        ).r;
        const float downSample = depthTexture.sample(
            gvLinearSampler,
            sensorUV + float2(0.0, texel.y * sampleWidth)
        ).r;
        const float right = gvValidDepth(rightSample, uniforms) ? rightSample : depth;
        const float down = gvValidDepth(downSample, uniforms) ? downSample : depth;
        const float strength = mix(2.0, 34.0, uniforms.controls.y);
        const float3 normal = normalize(float3((depth - right) * strength, (depth - down) * strength, 1.0));
        const float3 normalColor = normal * 0.5 + 0.5;
        return float4(mix(cameraColor, normalColor, wet), 1.0);
    }

    if (mode == 10) {
        const float cutRange = uniforms.controls.z;
        const float feather = mix(0.003, 0.18, uniforms.controls.w);
        const float mask = 1.0 - smoothstep(cutRange - feather, cutRange + feather, normalizedDepth);
        const float edge = 1.0 - smoothstep(0.0, feather * mix(0.25, 1.4, uniforms.controls.y), abs(normalizedDepth - cutRange));
        const float3 cutout = mix(cameraColor * 0.025, cameraColor, mask);
        const float3 effectColor = cutout + float3(0.72, 0.20, 1.0) * edge;
        return float4(mix(cameraColor, effectColor, wet), 1.0);
    }

    if (mode == 11) {
        const float curve = pow(max(1.0 - normalizedDepth, 0.001), mix(0.4, 2.8, uniforms.controls.x));
        const float offset = curve * mix(0.0015, 0.035, uniforms.controls.y) * uniforms.tuning.z;
        const float3 redSample = gvCameraColor(sensorUV + float2(offset, 0.0), lumaTexture, chromaTexture);
        const float3 blueSample = gvCameraColor(sensorUV - float2(offset, 0.0), lumaTexture, chromaTexture);
        return float4(redSample.r, cameraColor.g, blueSample.b, 1.0);
    }

    if (mode == 12) {
        const float baseBlock = mix(2.0, 42.0, uniforms.controls.y);
        const float depthScale = mix(0.35, 2.5, uniforms.controls.x);
        const float2 blockSize = max(texel * baseBlock * (0.65 + normalizedDepth * depthScale), texel);
        const float2 mosaicUV = (floor(sensorUV / blockSize) + 0.5) * blockSize;
        const float3 mosaicColor = gvCameraColor(mosaicUV, lumaTexture, chromaTexture);
        return float4(mix(cameraColor, mosaicColor, wet), 1.0);
    }

    if (mode == 13) {
        const float sampleWidth = mix(0.8, 5.0, uniforms.controls.w);
        const float rightSample = depthTexture.sample(
            gvLinearSampler,
            sensorUV + float2(texel.x * sampleWidth, 0.0)
        ).r;
        const float downSample = depthTexture.sample(
            gvLinearSampler,
            sensorUV + float2(0.0, texel.y * sampleWidth)
        ).r;
        const float right = gvValidDepth(rightSample, uniforms) ? rightSample : depth;
        const float down = gvValidDepth(downSample, uniforms) ? downSample : depth;
        const float gradient = max(abs(depth - right), abs(depth - down));
        const float threshold = mix(0.15, 0.006, uniforms.controls.x);
        const float glow = smoothstep(threshold, threshold * 3.5, gradient) * mix(0.4, 2.4, uniforms.controls.y);
        const float3 glowColor = mix(float3(0.22, 0.94, 0.80), float3(0.80, 0.18, 1.0), normalizedDepth);
        // The finger leaves a violet heat bloom while in contact.
        const float touchGlow = uniforms.interaction.w *
            (1.0 - smoothstep(0.0, 0.42, length(input.uv - uniforms.interaction.xy)));
        return float4(cameraColor + glowColor * (glow * uniforms.tuning.z + touchGlow * 0.55), 1.0);
    }

    if (mode == 14) { // Depth bands - explicit branch so a future mode can't hijack the fallthrough
        const float frequency = mix(3.0, 34.0, uniforms.controls.y);
        const float phase = uniforms.controls.z * 6.2831853;
        const float bandWave = 0.5 + 0.5 * sin(normalizedDepth * frequency * 6.2831853 + phase);
        const float bandWidth = mix(0.96, 0.08, uniforms.controls.w);
        const float band = smoothstep(bandWidth, min(bandWidth + 0.12, 1.0), bandWave);
        const float3 bandColor = mix(float3(0.08, 0.88, 0.72), float3(0.78, 0.22, 1.0), normalizedDepth);
        const float3 effectColor = mix(cameraColor * 0.52, bandColor, band);
        return float4(mix(cameraColor, effectColor, wet), 1.0);
    }

    if (mode == 16) { // Night vision - LiDAR-gated image intensifier (raw value 16)
        // Photocathode gain. Real intensifiers amplify a narrow luminance band
        // hard and clip everything above it, which is why the image reads as
        // flat glowing green rather than as a tinted photograph.
        const float luma = dot(cameraColor, float3(0.2126, 0.7152, 0.0722));
        const float gain = mix(2.0, 14.0, uniforms.controls.y);
        float intensified = 1.0 - exp(-luma * gain);

        // The illuminator falls off with the square of distance, so LiDAR range
        // drives the exposure. This is what makes it behave like an active IR
        // system instead of a green colour filter: near surfaces blow out, far
        // ones sink into the noise floor regardless of ambient light.
        const float metres = max(depth, 0.05);
        const float falloff = 1.0 / (1.0 + metres * metres * mix(0.05, 0.6, uniforms.controls.z));
        intensified *= mix(1.0, falloff * 3.0, uniforms.controls.w);

        // Scintillation: individual photon events in the tube. Uncorrelated per
        // pixel per frame, and stronger where the signal is weakest.
        const float grainSeed = gvBootHash(input.uv * 900.0 + uniforms.pose.z * 60.0);
        const float shotNoise = (grainSeed - 0.5) * mix(0.5, 0.06, saturate(intensified));
        intensified = saturate(intensified + shotNoise * uniforms.controls.x);

        // Depth edges, drawn brighter than the surfaces they bound. An
        // intensifier has no colour to separate objects, so geometry has to
        // come from range discontinuity.
        const float depthRight = depthTexture.sample(
            gvLinearSampler, sensorUV + float2(texel.x * 2.0, 0.0)
        ).r;
        const float depthDown = depthTexture.sample(
            gvLinearSampler, sensorUV + float2(0.0, texel.y * 2.0)
        ).r;
        const float edge = saturate(
            (abs(depthRight - depth) + abs(depthDown - depth)) * 14.0
        );

        // P43 phosphor: yellow-green, not pure green.
        const float3 phosphor = float3(0.32, 1.0, 0.45);
        float3 nightColor = phosphor * intensified;
        nightColor += phosphor * edge * 0.85;

        // Tube vignette and a faint blooming halo around hot returns.
        const float radius = length(input.uv - 0.5) * 2.0;
        nightColor *= 1.0 - smoothstep(0.72, 1.35, radius) * 0.85;
        nightColor += phosphor * pow(saturate(intensified - 0.72), 2.0) * 0.6;

        // Out-of-range returns get no illuminator, so they stay black.
        const float ranged = gvValidDepth(depth, uniforms) ? 1.0 : 0.25;
        return float4(mix(cameraColor, nightColor * ranged, wet), 1.0);
    }

    // Unknown future modes degrade to the raw camera feed instead of silently
    // reusing the last branch's look.
    return float4(cameraColor, 1.0);
}

fragment float4 gvDepthPresentFragment(
    GVDepthRaster input [[stage_in]],
    texture2d<float, access::sample> sourceTexture [[texture(0)]]
) {
    return sourceTexture.sample(gvLinearSampler, input.uv);
}

/// Unprojects one depth sample into view space using the real intrinsics.
static float3 gvUnproject(uint2 coordinate, float depth, constant GVDepthUniforms &uniforms) {
    const float x = (float(coordinate.x) - uniforms.intrinsics.z) * depth / uniforms.intrinsics.x;
    const float y = (float(coordinate.y) - uniforms.intrinsics.w) * depth / uniforms.intrinsics.y;
    return float3(x, -y, depth);
}

/// Applies the interface-orientation swizzle and the operator's yaw/pitch.
static float3 gvOrientPoint(float3 point, constant GVDepthUniforms &uniforms) {
    switch (uniforms.options.y) {
        case 0: point.xy = float2(-point.y, point.x); break;
        case 1: point.xy = float2(point.y, -point.x); break;
        case 3: point.xy = -point.xy; break;
        default: break;
    }
    const float cosineYaw = cos(uniforms.pose.x);
    const float sineYaw = sin(uniforms.pose.x);
    const float cosinePitch = cos(uniforms.pose.y);
    const float sinePitch = sin(uniforms.pose.y);
    point = float3(
        cosineYaw * point.x + sineYaw * point.z,
        point.y,
        -sineYaw * point.x + cosineYaw * point.z
    );
    return float3(
        point.x,
        cosinePitch * point.y - sinePitch * point.z,
        sinePitch * point.y + cosinePitch * point.z
    );
}

vertex GVDepthPointRaster gvDepthPointVertex(
    uint vertexID [[vertex_id]],
    texture2d<float, access::read> depthTexture [[texture(2)]],
    texture2d<uint, access::read> confidenceTexture [[texture(3)]],
    texture2d<float, access::sample> lumaTexture [[texture(0)]],
    texture2d<float, access::sample> chromaTexture [[texture(1)]],
    constant GVDepthUniforms &uniforms [[buffer(0)]]
) {
    GVDepthPointRaster output;
    output.normal = float3(0.0, 0.0, 1.0);
    output.confidence = 0.0;
    output.viewDepth = 0.0;

    const uint stride = max(uniforms.source.z, 1u);
    const uint columns = (uniforms.source.x + stride - 1) / stride;
    const uint2 coordinate = uint2((vertexID % columns) * stride, (vertexID / columns) * stride);

    if (coordinate.x >= uniforms.source.x || coordinate.y >= uniforms.source.y) {
        output.position = float4(2.0, 2.0, 1.0, 1.0);
        output.pointSize = 0.0;
        output.color = float4(0.0);
        return output;
    }

    const float depth = depthTexture.read(coordinate).r;
    const uint rawConfidence = uniforms.options.z == 1 ? confidenceTexture.read(coordinate).r : 2u;

    if (!gvValidDepth(depth, uniforms) || rawConfidence < uniforms.source.w) {
        output.position = float4(2.0, 2.0, 1.0, 1.0);
        output.pointSize = 0.0;
        output.color = float4(0.0);
        return output;
    }

    // Surface normal from neighbouring depth samples. Reading one stride left
    // and down gives two tangent vectors; their cross product is the normal.
    // Without this every point is a flat disc and the cloud has no form.
    const uint2 rightCoordinate = uint2(min(coordinate.x + stride, uniforms.source.x - 1), coordinate.y);
    const uint2 downCoordinate = uint2(coordinate.x, min(coordinate.y + stride, uniforms.source.y - 1));
    const float rightDepth = depthTexture.read(rightCoordinate).r;
    const float downDepth = depthTexture.read(downCoordinate).r;

    const float3 origin = gvUnproject(coordinate, depth, uniforms);
    float3 normal = float3(0.0, 0.0, 1.0);
    // Reject neighbours across a depth discontinuity: at an object edge the
    // tangent spans empty space and would produce a normal facing nowhere.
    const float discontinuity = depth * 0.06;
    if (gvValidDepth(rightDepth, uniforms) && gvValidDepth(downDepth, uniforms) &&
        abs(rightDepth - depth) < discontinuity && abs(downDepth - depth) < discontinuity) {
        const float3 tangentX = gvUnproject(rightCoordinate, rightDepth, uniforms) - origin;
        const float3 tangentY = gvUnproject(downCoordinate, downDepth, uniforms) - origin;
        const float3 crossed = cross(tangentX, tangentY);
        if (length_squared(crossed) > 1e-12) {
            normal = normalize(crossed);
        }
    }

    const float3 point = gvOrientPoint(origin, uniforms);
    const float3 orientedNormal = normalize(gvOrientPoint(normal, uniforms));
    // Matches the vertical flip applied to the position below.
    output.normal = float3(-orientedNormal.x, -orientedNormal.y, orientedNormal.z);

    const float projectionZ = max(point.z, 0.04);
    const float projectionScale = 1.72;
    const float aspect = uniforms.viewport.x / max(uniforms.viewport.y, 1.0);

    // Linear [0,1] clip depth. The previous `projectionZ * 0.5` divided by w to
    // a constant 0.5 for every point, so the depth test compared equal
    // everywhere and kept whichever splat rasterised first — worse than no
    // test at all.
    const float nearPlane = 0.05;
    const float farPlane = 12.0;
    const float clipDepth = saturate((projectionZ - nearPlane) / (farPlane - nearPlane));

    output.position = float4(
        // Both axes are flipped: correcting the vertical mirror last round left
        // the cloud horizontally mirrored against the camera image.
        -point.x * projectionScale / aspect,
        -point.y * projectionScale,
        clipDepth * projectionZ,
        projectionZ
    );

    // Splat size.
    //
    // Each sample covers `stride` depth-map pixels, i.e. a fixed *angular*
    // size of stride/focal — and the distance term cancels when that angle is
    // projected, so the correct splat is z-independent. The previous linear
    // ramp on normalised depth bloated distant points, which is what made the
    // cloud look soft and fake.
    const float angularSize = float(stride) * projectionScale / max(uniforms.intrinsics.x, 1.0);
    const float pixels = angularSize * (uniforms.viewport.x * 0.5) / max(aspect, 0.05);
    // Surfaces seen edge-on need slightly wider splats or the sheet tears open.
    const float facing = max(abs(output.normal.z), 0.30);
    output.pointSize = clamp(pixels * uniforms.tuning.w * 0.5 / facing, 1.0, 24.0);

    output.confidence = uniforms.options.z == 1 ? saturate(float(rawConfidence) / 2.0) : 1.0;
    output.viewDepth = depth;

    const float2 cameraUV = (float2(coordinate) + 0.5) / float2(uniforms.source.xy);
    const float3 cameraColor = gvCameraColor(cameraUV, lumaTexture, chromaTexture);
    const float normalizedDepth = saturate(
        (depth - uniforms.tuning.x) / max(uniforms.tuning.y - uniforms.tuning.x, 0.001)
    );
    const float3 depthColor = gvDepthPalette(normalizedDepth);
    output.color = float4(mix(cameraColor, depthColor, uniforms.controls.y), 1.0);
    return output;
}

fragment float4 gvDepthPointFragment(
    GVDepthPointRaster input [[stage_in]],
    float2 pointCoordinate [[point_coord]]
) {
    // Round splat with a one-pixel soft edge. Previously a large radial glow,
    // which merged neighbouring points into a haze instead of resolving as
    // discrete samples.
    const float distanceFromCenter = distance(pointCoordinate, float2(0.5));
    if (distanceFromCenter > 0.5) {
        discard_fragment();
    }
    const float coverage = smoothstep(0.5, 0.42, distanceFromCenter);

    // Lambert plus a rim term from a fixed key light. This is what makes the
    // cloud read as a surface rather than as confetti.
    const float3 lightDirection = normalize(float3(-0.35, 0.55, -0.75));
    const float3 normal = normalize(input.normal);
    const float lambert = saturate(dot(normal, lightDirection)) * 0.72 + 0.28;
    const float rim = pow(1.0 - saturate(abs(normal.z)), 2.4) * 0.5;

    // Distant returns fall off, and low-confidence returns are dimmed rather
    // than dropped, so uncertainty reads as noise instead of holes.
    const float fog = 1.0 - saturate((input.viewDepth - 0.6) / 6.0) * 0.55;
    const float trust = mix(0.35, 1.0, input.confidence);

    float3 shaded = input.color.rgb * lambert * fog * trust;
    shaded += float3(0.42, 0.20, 0.85) * rim * trust;

    // Blending is off on this pipeline (depth-tested opaque splats), so
    // confidence and coverage are folded into the colour rather than alpha.
    return float4(shaded * mix(0.55, 1.0, coverage), 1.0);
}

