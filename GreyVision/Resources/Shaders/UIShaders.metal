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

// MARK: - Apollonian gasket (passcode screen backdrop, black & white)
// Port of https://www.shadertoy.com/view/4ds3zn
[[ stitchable ]]
half4 gateApollonian(float2 position, half4 source, float time, float2 resolution) {
    // SwiftUI supplies local point coordinates; Shadertoy's `getSpace()` is
    // centered and aspect-corrected. Without this normalization the gasket
    // changes scale with the raw pixel dimensions and becomes a flat noise
    // field on a tall phone.
    float2 safeResolution = max(resolution, float2(1.0));
    float2 centered = (position * 2.0 - safeResolution) / safeResolution.y;
    float3 s = float3(centered, 0.0);
    s.z += 2.0;
    s.y += 0.275;
    s.x += time / 10.0;

    float scale = 29.0;
    float4 orb = float4(0.5);
    float3 pn = s;

    for (int i = 0; i < 7; i++) {
        pn = -1.0 + 2.0 * fract(0.5 * pn + 0.5);
        float r2 = dot(pn, pn);
        float3 r3 = abs(pn);
        float4 r4 = float4(r3.x, r3.z, r3.z, r3.x);
        orb = min(orb, r4);
        float k = 1.25 / max(r2, 1e-6);
        pn *= k;
        scale += k;
    }

    // Orbit-trap edge: the closest approach across all iterations, scaled
    // by the accumulated inversion factor, traces the packing boundaries.
    // Black & white only — the gate carries no accent colour.
    float edge = min(min(orb.x, orb.y), min(orb.z, orb.w));
    float v = 1.0 - clamp(edge * scale * 0.30, 0.0, 1.0);
    v = pow(v, 1.4);

    // The pow ramp compresses most of its energy into the darkest stop, which
    // is where 8-bit stepping shows as contour rings on a monochrome field.
    // One bit of hash dither per pixel breaks the steps without reading as
    // noise — at this amplitude it only trades banding for grain at the
    // threshold of perception.
    const float dither = fract(sin(dot(position, float2(127.1, 311.7))) * 43758.5453);
    v += (dither - 0.5) * (1.5 / 255.0);
    (void)resolution;
    return half4(half3(half(saturate(v))) * source.a, source.a);
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
    float4x4 worldFromCamera;
    /// Four space-scan echo lanes: xyz is the world-space origin, w its age in
    /// seconds. A negative age marks an empty lane.
    float4 pulses[4];
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

// Camera intrinsics are scaled to depth resolution by the CPU. ARKit camera
// coordinates look down -Z with +Y up; depth samples have +Y down and +Z range.
static float3 gvDepthCameraPoint(float2 sensorUV, float depth, constant GVDepthUniforms &u) {
    const float2 pixel = sensorUV * float2(u.source.xy) - 0.5;
    const float2 xy = (pixel - u.intrinsics.zw) * depth / max(u.intrinsics.xy, float2(0.001));
    return float3(xy.x, -xy.y, -depth);
}

static float3 gvDepthWorldPoint(float2 sensorUV, float depth, constant GVDepthUniforms &u) {
    return (u.worldFromCamera * float4(gvDepthCameraPoint(sensorUV, depth, u), 1.0)).xyz;
}

// ---------------------------------------------------------------------------
// Consolidated LiDAR looks.
//
// Nine modes remain, each with a mechanism the others do not have: a shaded
// point cloud (its own pipeline), a metric range palette, iso-range contours, a
// depth-of-field key, an occlusion-aware reprojection, a world-space surface
// light, a metric grid with echoes, a mask-driven decay, and an intensifier.
// Underneath them sits shared machinery: one four-tap gather fits the surface,
// one hash dithers quantisation, one ramp colours range.
// ---------------------------------------------------------------------------

/// Triangular dither in -0.5...0.5. Quantising metres without it produces hard
/// contour bands exactly where the range histogram is busiest.
static float gvDither(float2 viewUV, constant GVDepthUniforms &u) {
    const float2 grid = floor(viewUV * max(u.viewport.xy, float2(1.0)));
    const float a = gvBootHash(grid);
    const float b = gvBootHash(grid + float2(17.13, 9.71));
    const float c = gvBootHash(grid + float2(5.37, 23.71));
    return (a + b + c) / 3.0 - 0.5;
}

/// One depth neighbour, or the centre depth when the neighbour is not a
/// return. Substituting the centre value makes a hole contribute no gradient
/// instead of contributing a false edge around every no-return region.
static float gvNeighbourDepth(
    texture2d<float, access::sample> depthTexture,
    float2 sensorUV, float fallback,
    constant GVDepthUniforms &u, thread bool &valid
) {
    const float value = depthTexture.sample(gvLinearSampler, sensorUV).r;
    valid = gvValidDepth(value, u);
    return valid ? value : fallback;
}

struct GVDepthSurface {
    /// Camera-space normal, oriented toward the camera (+Z).
    float3 normal;
    /// Metric edge strength, metres per depth texel, sample-width normalised.
    float gradient;
    /// Signed metric slope along +u/+v, used to walk toward nearer geometry.
    float2 slope;
    /// 0...1, how occlusion-boundary-like this pixel is.
    float seam;
};

/// The four-tap gather every geometry-driven look reads.
///
/// Two things differ from the two-tap differences this replaces. The normal is
/// fitted to *unprojected* points, so it describes the surface rather than the
/// image - a normal built from raw UV differences changes with focal length and
/// with the depth map's own grid, which is why the old relight swam when the
/// camera format changed. And the fit refuses to cross a discontinuity, which
/// is what stops every surface lighting up along the inside of its own
/// silhouette.
static GVDepthSurface gvDepthSurface(
    texture2d<float, access::sample> depthTexture,
    float2 sensorUV, float depth, float2 texel, float width,
    constant GVDepthUniforms &u
) {
    GVDepthSurface surface;
    surface.normal = float3(0.0, 0.0, 1.0);
    surface.gradient = 0.0;
    surface.slope = float2(0.0);
    surface.seam = 0.0;

    const float2 step = texel * max(width, 1.0);
    bool okRight, okLeft, okDown, okUp;
    const float right = gvNeighbourDepth(depthTexture, sensorUV + float2(step.x, 0.0), depth, u, okRight);
    const float left = gvNeighbourDepth(depthTexture, sensorUV - float2(step.x, 0.0), depth, u, okLeft);
    const float down = gvNeighbourDepth(depthTexture, sensorUV + float2(0.0, step.y), depth, u, okDown);
    const float up = gvNeighbourDepth(depthTexture, sensorUV - float2(0.0, step.y), depth, u, okUp);

    // Rejection tolerance in metres. A real surface departs from the centre
    // plane only by the chord between samples; anything beyond it is a
    // discontinuity, and that pair must not contribute a normal.
    const float tolerance = max(0.02, depth * 0.06);
    const float3 centre = gvDepthCameraPoint(sensorUV, depth, u);
    const float3 pRight = gvDepthCameraPoint(sensorUV + float2(step.x, 0.0), right, u);
    const float3 pLeft = gvDepthCameraPoint(sensorUV - float2(step.x, 0.0), left, u);
    const float3 pDown = gvDepthCameraPoint(sensorUV + float2(0.0, step.y), down, u);
    const float3 pUp = gvDepthCameraPoint(sensorUV - float2(0.0, step.y), up, u);
    const bool useRight = okRight && all(fabs(pRight - centre) < float3(tolerance));
    const bool useLeft = okLeft && all(fabs(pLeft - centre) < float3(tolerance));
    const bool useDown = okDown && all(fabs(pDown - centre) < float3(tolerance));
    const bool useUp = okUp && all(fabs(pUp - centre) < float3(tolerance));

    float3 fitted = float3(0.0);
    float fittedWeight = 0.0;
    if (useRight && useDown) { fitted += normalize(cross(pRight - centre, pDown - centre)); fittedWeight += 1.0; }
    if (useDown && useLeft) { fitted += normalize(cross(pDown - centre, pLeft - centre)); fittedWeight += 1.0; }
    if (useLeft && useUp) { fitted += normalize(cross(pLeft - centre, pUp - centre)); fittedWeight += 1.0; }
    if (useUp && useRight) { fitted += normalize(cross(pUp - centre, pRight - centre)); fittedWeight += 1.0; }
    if (fittedWeight > 0.0) {
        surface.normal = normalize(fitted);
        if (surface.normal.z < 0.0) { surface.normal = -surface.normal; }
    }

    // Edge-avoiding central difference: the smaller one-sided derivative wins,
    // so the ramp leading up to an occlusion reads as flat instead of bright.
    const float dxRight = okRight ? fabs(right - depth) : 0.0;
    const float dxLeft = okLeft ? fabs(depth - left) : 0.0;
    const float dyDown = okDown ? fabs(down - depth) : 0.0;
    const float dyUp = okUp ? fabs(depth - up) : 0.0;
    const float dx = fmin(dxRight, dxLeft);
    const float dy = fmin(dyDown, dyUp);
    surface.gradient = sqrt(dx * dx + dy * dy) / max(width, 1.0);
    surface.slope = float2(
        (okRight ? right : depth) - (okLeft ? left : depth),
        (okDown ? down : depth) - (okUp ? up : depth)
    ) * (0.5 / max(width, 1.0));

    const float rejected = (useRight ? 0.0 : 1.0) + (useLeft ? 0.0 : 1.0)
                         + (useDown ? 0.0 : 1.0) + (useUp ? 0.0 : 1.0);
    surface.seam = saturate(rejected * 0.22 + saturate(surface.gradient / max(tolerance, 0.001)) * 0.7);
    return surface;
}

static float3 gvRangeStop(uint index, float variant) {
    const bool thermal = variant < 0.5;
    switch (index) {
        case 0: return thermal ? float3(0.020, 0.010, 0.090) : float3(0.030, 0.010, 0.080);
        case 1: return thermal ? float3(0.150, 0.150, 0.850) : float3(0.420, 0.060, 0.720);
        case 2: return thermal ? float3(0.050, 0.700, 0.780) : float3(0.090, 0.420, 0.950);
        case 3: return thermal ? float3(0.350, 0.900, 0.300) : float3(0.060, 0.900, 0.720);
        case 4: return thermal ? float3(1.000, 0.680, 0.100) : float3(0.980, 0.860, 0.180);
        default: return thermal ? float3(1.000, 0.980, 0.920) : float3(1.000, 0.350, 0.120);
    }
}

/// Range to colour. Stops are interpolated in the square-root domain, which is
/// a cheap stand-in for a linear-space blend: it keeps saturated midpoints from
/// collapsing through mud without paying for a full transfer function.
static float3 gvRangeRamp(float t, float variant) {
    const float position = saturate(t) * 5.0;
    const uint index = min(uint(floor(position)), 4u);
    const float3 from = sqrt(gvRangeStop(index, variant));
    const float3 to = sqrt(gvRangeStop(index + 1, variant));
    const float3 mixed = mix(from, to, position - float(index));
    return mixed * mixed;
}

/// Thin-lens circle of confusion in pixels. The parallax that actually defocuses
/// an image is |d-F|/d, not |d-F|: a wall two metres behind focus blurs far
/// harder than a hand two metres in front of it does, and any mapping without
/// the divisor reads flat no matter how large you make the blur.
static float gvCircleOfConfusion(float sampleDepth, float focus, float dof, float aperture, constant GVDepthUniforms &u) {
    if (!gvValidDepth(sampleDepth, u)) { return 0.0; }
    const float beyond = fabs(sampleDepth - focus) - dof;
    if (beyond <= 0.0) { return 0.0; }
    return beyond / max(sampleDepth, 0.05) * aperture;
}

/// Defocused camera colour. Scatter-as-gather: a tap only contributes in
/// proportion to how blurred its own neighbourhood is, which is what keeps a
/// sharp foreground from smearing outwards into a blurred background.
static float3 gvDefocus(
    texture2d<float, access::sample> lumaTexture,
    texture2d<float, access::sample> chromaTexture,
    texture2d<float, access::sample> depthTexture,
    float2 viewUV, float radiusPx, float focus, float dof, float aperture,
    constant GVDepthUniforms &u
) {
    const float2 texel = 1.0 / max(u.viewport.xy, float2(1.0));
    float3 total = gvCameraColor(gvSensorUV(viewUV, u), lumaTexture, chromaTexture);
    float weightSum = 1.0;
    for (uint index = 0u; index < 6u; index++) {
        const float angle = float(index) * 1.0471975512;
        const float radius = radiusPx * (index % 2u == 0u ? 1.0 : 0.55);
        const float2 sampledUV = gvSensorUV(viewUV + float2(cos(angle), sin(angle)) * radius * texel, u);
        const float sampleDepth = depthTexture.sample(gvLinearSampler, sampledUV).r;
        const float weight = saturate(gvCircleOfConfusion(sampleDepth, focus, dof, aperture, u) / max(radiusPx, 0.001));
        total += gvCameraColor(sampledUV, lumaTexture, chromaTexture) * weight;
        // A floor on the weight so a ring of in-focus taps cannot punch a hole.
        weightSum += max(weight, 0.08);
    }
    return total / max(weightSum, 1.0);
}

/// Antialiased metric grid over a world-space position. The antialias width is
/// the screen-space derivative of the world position, so a line is exactly
/// `weight` pixels wide at any distance, and every fifth line runs heavier so a
/// 0.25 m cell can be counted without reading it one square at a time.
static float gvMetricGrid(float3 world, float cell, float weight, thread float &major) {
    const float2 plane = world.xz;
    const float2 pixelWidth = max(fwidth(plane) * 0.5, float2(1e-5));
    const float2 halfWidth = pixelWidth * max(weight, 0.5);
    const float2 minorDistance = abs(fract(plane / cell + 0.5) - 0.5) * cell;
    const float2 minor = 1.0 - smoothstep(halfWidth, halfWidth + pixelWidth, minorDistance);
    const float2 indexDistance = abs(fract(plane / (cell * 5.0) + 0.5) - 0.5) * cell * 5.0;
    const float2 indexHalf = halfWidth * 2.0;
    const float2 indexLines = 1.0 - smoothstep(indexHalf, indexHalf + pixelWidth * 2.0, indexDistance);
    major = max(indexLines.x, indexLines.y);
    return saturate(max(max(minor.x, minor.y), major * 0.9));
}

/// The summed wavefront of every live echo at one world position. Four can be
/// in flight at once, so consecutive taps read as a sweep across the room
/// instead of each one cancelling the last.
static float gvEchoField(float3 world, float maxRadius, constant GVDepthUniforms &u) {
    const float speed = max(u.controls.z, 0.05);
    const float width = max(u.controls.w, 0.01);
    float total = 0.0;
    for (uint index = 0u; index < 4u; index++) {
        const float age = u.pulses[index].w;
        if (age < 0.0) { continue; }
        const float radius = age * speed;
        if (radius > maxRadius) { continue; }
        const float separation = distance(world, u.pulses[index].xyz) - radius;
        const float antialias = max(fwidth(distance(world, u.pulses[index].xyz)), 0.002);
        const float shell = 1.0 - smoothstep(width * 0.5, width * 0.5 + antialias, fabs(separation));
        const float trail = separation < 0.0 ? exp(separation / max(width * 3.0, 0.05)) : 0.0;
        const float fade = 1.0 - smoothstep(maxRadius * 0.55, maxRadius, radius);
        total += (shell + trail * 0.45) * fade;
    }
    return saturate(total);
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
    constexpr sampler depthSampler(coord::normalized, address::clamp_to_edge, filter::nearest);
    const float depth = depthTexture.sample(depthSampler, sensorUV).r;
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
    const bool confidenceValid = confidence >= uniforms.source.w;

    // Zero intensity always presents the original feed, including missing depth.
    if (wet <= 0.0) { return float4(cameraColor, 1.0); }
    // The cloud draws itself in its own pipeline; there is nothing to composite.
    if (mode == 0) { return float4(cameraColor, 1.0); }
    // With no trustworthy return there is nothing true to render, so every mode
    // falls back to the camera rather than inventing geometry to fill a hole.
    if (!gvValidDepth(depth, uniforms) || !confidenceValid) {
        return float4(cameraColor, 1.0);
    }

    if (mode == 1) { // HEATMAP: metric range, level of detail, optional buckets.
        // RANGE CURVE reshapes the histogram before anything else reads it, so
        // levels can be spent on the depths that matter instead of being spread
        // evenly across a gate the operator deliberately set wide.
        const float curve = mix(0.35, 3.2, uniforms.controls.z);
        const float shaped = pow(normalizedDepth, curve);

        // BLOCK SIZE is a level-of-detail kernel measured in depth texels.
        // Averaging a metric range is what stops the map aliasing into moire
        // once the gate spans more range than the sensor resolves; below one
        // texel it is a plain point read and costs no extra taps.
        const float blockSize = max(uniforms.controls.y, 0.0);
        float sampled = shaped;
        if (blockSize >= 1.0) {
            const float2 offset = texel * blockSize * 0.5;
            float total = 0.0;
            float weight = 0.0;
            for (uint index = 0u; index < 4u; index++) {
                const float2 tap = sensorUV + float2(
                    index % 2u == 0u ? -offset.x : offset.x,
                    index < 2u ? -offset.y : offset.y
                );
                const float tapDepth = depthTexture.sample(depthSampler, tap).r;
                if (gvValidDepth(tapDepth, uniforms)) {
                    total += pow(saturate((tapDepth - uniforms.tuning.x) / range), curve);
                    weight += 1.0;
                }
            }
            sampled = weight > 0.0 ? total / weight : shaped;
        }

        // LEVELS counts iso-range buckets. One level is the continuous ramp; the
        // dither is one bucket wide, which is exactly the amplitude needed to
        // break the banding a hard quantiser lays across a busy histogram.
        const float levels = clamp(floor(uniforms.controls.x + 0.5), 1.0, 24.0);
        const float dithered = saturate(sampled + gvDither(input.uv, uniforms) / levels);
        const float quantized = levels <= 1.5
            ? dithered
            : floor(dithered * levels) / (levels - 1.0);

        // PALETTE slides between the prism and thermal ramps rather than picking
        // one, so the knob spans the whole family instead of toggling between
        // two unrelated looks.
        const float3 ramp = mix(
            gvRangeRamp(quantized, 1.0),
            gvRangeRamp(quantized, 0.0),
            uniforms.controls.w
        );
        return float4(mix(cameraColor, ramp, wet), 1.0);
    }

    if (mode == 7) { // CONTOURS: iso-range lines placed in metres, not gate fractions.
        const GVDepthSurface surface = gvDepthSurface(depthTexture, sensorUV, depth, texel, 1.0, uniforms);
        const float spacing = max(uniforms.controls.x, 0.02);
        const float position = depth / spacing;
        const float distanceMetres = abs(position - round(position)) * spacing;
        // One screen pixel of depth range is the natural unit of line width
        // here: it holds the line at one pixel wide at every distance instead
        // of thinning out as the surface turns away from the sensor.
        const float pixelRange = max(fwidth(depth), 1e-4);
        const float halfWidth = pixelRange * max(uniforms.controls.y, 0.5) * 0.5;
        const float line = 1.0 - smoothstep(halfWidth, halfWidth + pixelRange, distanceMetres);
        // A slope steep enough to cross a whole bucket between neighbouring
        // pixels would draw a solid sheet of lines. Drop them there and let the
        // edge term describe the cliff, which is what a contour plot of a real
        // surface does instead of filling in its own cliffs.
        const float tooSteep = smoothstep(0.5, 1.5, fwidth(position));
        const float3 ink = mix(float3(0.78, 0.30, 1.0), float3(0.20, 0.95, 0.80), normalizedDepth);
        const float3 filled = mix(gvRangeRamp(normalizedDepth, 1.0), cameraColor, uniforms.controls.z);
        const float3 shaded = mix(filled * 0.55, ink, line * (1.0 - tooSteep))
            + ink * surface.seam * uniforms.controls.w * 0.7;
        return float4(mix(cameraColor, saturate(shaded), wet), 1.0);
    }



    if (mode == 6) { // DEPTH FIELD: thin-lens defocus plus subject isolation.
        const float focus = max(uniforms.controls.x, 0.2);
        const float dof = max(uniforms.controls.y, 0.05);
        const float radius = mix(2.0, 18.0, uniforms.controls.z);
        const float3 defocused = gvDefocus(
            lumaTexture, chromaTexture, depthTexture, input.uv, radius, focus, dof, 1.0, uniforms
        );
        // ISOLATE dims whatever falls outside the in-focus slab and thickens the
        // air inside it. Both terms read the same defocus measurement, so
        // isolation cannot disagree with the blur it is meant to explain.
        const float outside = max(abs(depth - focus) - dof, 0.0);
        const float isolation = saturate(outside * 2.0) * uniforms.controls.w;
        float3 isolated = mix(defocused, mix(defocused * 0.16, float3(0.10, 0.14, 0.22), 0.55), isolation);
        // The slab boundary stays legible even at zero isolation, because the
        // focus plane is the one thing the operator is aiming at.
        const float boundary = 1.0 - smoothstep(0.0, max(dof * 0.25, 0.015), outside);
        isolated += float3(0.35, 0.72, 0.68) * boundary * 0.35;
        return float4(mix(cameraColor, saturate(isolated), wet), 1.0);
    }

    if (mode == 3) { // PARALLAX: occlusion-aware reprojection of the camera feed.
        const GVDepthSurface surface = gvDepthSurface(depthTexture, sensorUV, depth, texel, 1.0, uniforms);
        // Two displacements, because one alone is not enough. The gradient term
        // bends the image exactly where the geometry bends and is silent on a
        // flat wall; the range term pushes nearer geometry outward and is
        // silent on a surface at constant depth. Either one alone leaves the
        // effect looking broken on half the room.
        const float curve = mix(0.45, 2.4, uniforms.controls.y);
        const float gradientResponse = pow(saturate(surface.gradient * 12.0), curve);
        const float2 gradientOffset = surface.slope * gradientResponse * uniforms.controls.x * mix(0.010, 0.055, uniforms.controls.z);
        // Radial term. A plane at constant depth is flat and fronto-parallel, so
        // it has no parallax at all — which is true, and is also exactly the flat
        // backdrop this effect is least interesting on. Range weighting keeps it
        // physical rather than decorative: the far wall stays put, near
        // geometry swells.
        const float nearWeight = pow(saturate(1.0 - normalizedDepth), mix(0.5, 2.6, uniforms.controls.y));
        const float2 origin = uniforms.interaction.w > 0.5 ? uniforms.interaction.xy : float2(0.5);
        const float2 toCentre = input.uv - origin;
        const float radialAmount = nearWeight * uniforms.controls.x * uniforms.tuning.z * 0.055;
        // Stroking stirs the field around the contact point, in proportion to
        // how fast the finger is actually moving.
        const float stir = (1.0 - smoothstep(0.0, 0.38, length(toCentre)))
            * length(uniforms.pose.zw) * uniforms.controls.w * 0.06;
        const float2 offset = gradientOffset + toCentre * (radialAmount + stir);
        const float2 warpedUV = gvSensorUV(input.uv + offset, uniforms);

        // CHROMA splits the same displacement per channel, so the fringe grows
        // with the displacement instead of being a fixed-width decoration.
        const float chroma = uniforms.controls.z * uniforms.tuning.z;
        const float2 fringe = normalize(offset + float2(1e-6, 0.0)) * length(offset) * chroma;
        const float3 displaced = float3(
            gvCameraColor(gvSensorUV(warpedUV + fringe, uniforms), lumaTexture, chromaTexture).r,
            gvCameraColor(warpedUV, lumaTexture, chromaTexture).g,
            gvCameraColor(gvSensorUV(warpedUV - fringe, uniforms), lumaTexture, chromaTexture).b
        );
        // A surface the gather rejected is a silhouette, and stretching across a
        // silhouette drags foreground pixels over the background behind them.
        return float4(mix(displaced, cameraColor, surface.seam * 0.85), 1.0);
    }

    if (mode == 17) { // RELIGHT: a world-space surface light on the fitted normal.
        const GVDepthSurface surface = gvDepthSurface(depthTexture, sensorUV, depth, texel, 1.0, uniforms);
        // The light lives in world space, so it stays where it was placed as the
        // camera moves. A view-space light would make every highlight slide off
        // its surface, which reads as a filter rather than as illumination.
        const float3 worldNormal = normalize((uniforms.worldFromCamera * float4(surface.normal, 0.0)).xyz);
        const float3 viewDirection = normalize((uniforms.worldFromCamera * float4(0.0, 0.0, 0.0, 1.0)).xyz
            - gvDepthWorldPoint(sensorUV, depth, uniforms));
        const float azimuth = uniforms.controls.x * M_PI_F / 180.0;
        const float elevation = uniforms.controls.y * M_PI_F / 180.0;
        const float3 light = normalize(float3(sin(azimuth) * cos(elevation), sin(elevation), cos(azimuth) * cos(elevation)));
        const float roughness = clamp(uniforms.controls.z, 0.05, 1.0);
        const float diffuse = max(dot(worldNormal, light), 0.0);
        // Roughness moves the highlight from a tight glint to a broad sheen by
        // driving both the exponent and the energy, so the total stays bounded.
        const float exponent = mix(128.0, 6.0, roughness);
        const float specular = pow(max(dot(worldNormal, normalize(light + viewDirection)), 0.0), exponent)
            * (1.0 - roughness * 0.85) * 0.4;
        // Ambient comes from the sky term of the normal, which gives unlit faces
        // a gradient instead of a flat floor.
        const float ambient = 0.18 + 0.14 * saturate(worldNormal.y * 0.5 + 0.5);
        const float3 lit = cameraColor * (ambient + diffuse * 1.05) + float3(1.0, 0.97, 0.90) * specular;
        // MATERIAL slides to the raw fitted normal, which is the same geometry
        // with the lighting term switched off.
        const float3 shaded = mix(lit, worldNormal * 0.5 + 0.5, uniforms.controls.w);
        return float4(mix(cameraColor, saturate(shaded), wet * (1.0 - surface.seam)), 1.0);
    }

    if (mode == 18) { // SPACE SCAN: a metric floor with the echo sweeping across it.
        const float3 world = gvDepthWorldPoint(sensorUV, depth, uniforms);
        if (!all(isfinite(world))) { return float4(cameraColor, 1.0); }
        float major = 0.0;
        const float grid = gvMetricGrid(world, max(uniforms.controls.x, 0.05), uniforms.controls.y, major);
        // Echoes are world-anchored, so the grid stays nailed to the floor while
        // the wavefront travels across it.
        const float echo = gvEchoField(world, max(uniforms.tuning.y, 0.2), uniforms);
        const float3 cell = mix(float3(0.10, 0.16, 0.20), float3(0.16, 0.24, 0.30), major);
        const float3 ink = mix(float3(0.14, 0.87, 0.73), float3(0.44, 0.67, 1.0), major);
        const float3 scan = mix(cameraColor * 0.55, ink, grid);
        // The wavefront adds light on top rather than recolouring the grid, so
        // several echoes in flight sum instead of overwriting each other.
        return float4(mix(cameraColor, saturate(scan + cell * 0.4 + float3(0.22, 0.60, 0.72) * echo * wet), wet), 1.0);
    }

    if (mode == 15) { // SUBJECT DECAY: mask-driven feedback torn at occlusion boundaries.
        const float2 viewTexel = 1.0 / max(uniforms.viewport.xy, float2(1.0));
        const float person = personMaskTexture.sample(gvLinearSampler, input.uv).r;
        const float personLeft = personMaskTexture.sample(gvLinearSampler, input.uv - float2(viewTexel.x * 2.0, 0.0)).r;
        const float personRight = personMaskTexture.sample(gvLinearSampler, input.uv + float2(viewTexel.x * 2.0, 0.0)).r;
        const float personTop = personMaskTexture.sample(gvLinearSampler, input.uv - float2(0.0, viewTexel.y * 2.0)).r;
        const float personBottom = personMaskTexture.sample(gvLinearSampler, input.uv + float2(0.0, viewTexel.y * 2.0)).r;
        const float maskGradient = length(float2(personRight - personLeft, personBottom - personTop));
        // EDGE sets where the subject's own contour tears the frame. It is a
        // gradient threshold on the mask, so a soft shoulder does not tear and a
        // hard one does, which is what makes the effect track a silhouette
        // rather than an arbitrary part of the frame.
        const float edgeThreshold = mix(0.42, 0.06, uniforms.controls.z);
        const float outerEdge = smoothstep(edgeThreshold, edgeThreshold + 0.18, maskGradient)
            * smoothstep(0.12, 0.72, person);

        // With no feedback buffer bound there is no previous frame to compare
        // against, so flow is zero by definition and the mode degrades to a
        // static silhouette tint rather than sampling an unrelated texture. The
        // renderer always binds a real buffer in practice; this is the path
        // that keeps the mode honest on its first frame.
        const bool hasHistory = uniforms.options.w == 1;
        const float3 historyColor = hasHistory
            ? historyTexture.sample(gvLinearSampler, input.uv).rgb
            : cameraColor;
        const float3 lumaWeights = float3(0.2126, 0.7152, 0.0722);
        const float currentLuma = dot(cameraColor, lumaWeights);
        const float historyLuma = dot(historyColor, lumaWeights);
        const float currentRight = dot(gvCameraColor(sensorUV + float2(viewTexel.x * 3.0, 0.0), lumaTexture, chromaTexture), lumaWeights);
        const float currentDown = dot(gvCameraColor(sensorUV + float2(0.0, viewTexel.y * 3.0), lumaTexture, chromaTexture), lumaWeights);
        const float historyRight = hasHistory
            ? dot(historyTexture.sample(gvLinearSampler, input.uv + float2(viewTexel.x * 3.0, 0.0)).rgb, lumaWeights)
            : currentRight;
        const float historyDown = hasHistory
            ? dot(historyTexture.sample(gvLinearSampler, input.uv + float2(0.0, viewTexel.y * 3.0)).rgb, lumaWeights)
            : currentDown;
        // Flow is the difference between this frame's luma gradient and the one
        // in the feedback buffer, so it measures real motion between two real
        // frames instead of inferring it from a single image.
        const float2 opticalFlow = float2(
            (currentRight - currentLuma) - (historyRight - historyLuma),
            (currentDown - currentLuma) - (historyDown - historyLuma)
        );
        const float motionGate = smoothstep(0.012, mix(0.05, 0.22, uniforms.controls.y), length(opticalFlow));
        const float silhouetteMotion = outerEdge * max(motionGate, 0.12);

        const float2 toCentre = input.uv - uniforms.interaction.xy;
        const float originDistance = max(length(toCentre), 0.0001);
        const float2 originDirection = toCentre / originDistance;
        const float pulse = 0.72 + 0.28 * sin(uniforms.interaction.z * 2.4 + originDistance * 24.0);
        const float stretch = silhouetteMotion * uniforms.controls.x * pulse * (0.30 + length(uniforms.pose.zw) * 0.18);
        const float3 stretched = hasHistory
            ? historyTexture.sample(
                gvLinearSampler, input.uv - originDirection * stretch - opticalFlow * uniforms.controls.y * 0.48
            ).rgb
            : cameraColor;

        // TRAIL is the persistence of the feedback buffer. Mixing toward the
        // brighter of current and history keeps a decaying subject visible
        // instead of fading it to black a frame after it stops moving.
        const float trailAmount = mix(0.35, 0.92, uniforms.controls.w) * person;
        float3 feedback = mix(cameraColor, historyColor, trailAmount);
        const float decayGate = silhouetteMotion * step(0.20, gvDither(input.uv, uniforms) + 0.5);
        feedback = mix(feedback, max(stretched, feedback * 0.74), saturate(silhouetteMotion + decayGate));
        feedback += float3(0.48, 0.08, 0.82) * silhouetteMotion * 0.42;
        return float4(mix(cameraColor, saturate(feedback), wet), 1.0);
    }

    if (mode == 16) { // NIGHT VISION: an active IR image intensifier gated by LiDAR range.
        // Photocathode gain. A real intensifier amplifies a narrow luminance band
        // hard and clips everything above it, which is why the result reads as
        // flat glowing green rather than as a tinted photograph.
        const float luma = dot(cameraColor, float3(0.2126, 0.7152, 0.0722));
        const float gain = mix(2.0, 14.0, uniforms.controls.x);
        float intensified = 1.0 - exp(-luma * gain);

        // The illuminator falls off with distance and LiDAR range is what
        // exposes it: near returns blow out, far ones sink into the noise floor
        // regardless of how much ambient light there is. That coupling is what
        // makes this an active system rather than a green colour filter.
        const float metres = max(depth, 0.05);
        const float falloff = 1.0 / (1.0 + metres * metres * mix(0.05, 0.6, uniforms.controls.z));
        intensified *= mix(1.0, falloff * 3.0, uniforms.controls.z);

        // SCINTILLATION is uncorrelated per pixel per frame and strongest where
        // the signal is weakest, which is how shot noise actually behaves.
        const float seed = gvBootHash(
            input.uv * uniforms.viewport.xy
                + float2(floor(uniforms.interaction.z * 60.0), floor(uniforms.interaction.z * 47.0))
        );
        intensified = saturate(intensified + (seed - 0.5) * mix(0.5, 0.06, saturate(intensified)) * uniforms.controls.y);

        // An intensifier has no colour to separate objects, so geometry has to
        // come from range discontinuity alone. The metric seam term is used
        // rather than a raw difference so a hole in the depth map does not read
        // as a wall.
        const GVDepthSurface surface = gvDepthSurface(depthTexture, sensorUV, depth, texel, 2.0, uniforms);
        const float3 phosphor = float3(0.32, 1.0, 0.45);
        float3 night = phosphor * (intensified + surface.seam * 0.85);
        const float radius = length(input.uv - 0.5) * 2.0;
        night *= 1.0 - smoothstep(0.72, 1.35, radius) * 0.85;
        night += phosphor * pow(saturate(intensified - 0.72), 2.0) * 0.6;

        // RANGE GATE: a return outside the gate receives no illuminator at all,
        // so it stays black instead of being amplified out of nothing.
        const float gateMeters = mix(uniforms.tuning.y, uniforms.tuning.x + 0.2, uniforms.controls.w);
        const float rangeGate = 1.0 - smoothstep(gateMeters - 0.15, gateMeters + 0.15, depth);
        return float4(mix(cameraColor, night * rangeGate, wet), 1.0);
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
    const float metricSize = mix(1.0, clamp(1.5 / max(depth, 0.1), 0.45, 2.5), uniforms.controls.x);
    output.pointSize = clamp(pixels * uniforms.tuning.w * metricSize * 0.5 / facing, 1.0, 24.0);

    output.confidence = uniforms.options.z == 1 ? saturate(float(rawConfidence) / 2.0) : 1.0;
    output.viewDepth = depth;

    const float2 cameraUV = (float2(coordinate) + 0.5) / float2(uniforms.source.xy);
    const float3 cameraColor = gvCameraColor(cameraUV, lumaTexture, chromaTexture);
    const float normalizedDepth = saturate(
        (depth - uniforms.tuning.x) / max(uniforms.tuning.y - uniforms.tuning.x, 0.001)
    );
    const float3 depthColor = gvDepthPalette(normalizedDepth);
    output.color = float4(mix(cameraColor, depthColor, uniforms.controls.y * saturate(uniforms.tuning.z)), 1.0);
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

