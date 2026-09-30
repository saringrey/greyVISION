#include <metal_stdlib>

using namespace metal;

// The renderer builds a lazy, per-mode pipeline cache from this constant.
// A separate generic entry point remains available while a specialization
// compiles in the background. Once defined, Metal can remove the other 139
// switch arms and their register pressure from that pipeline.
constant uint gvStyleModeConstant [[function_constant(0)]];

// Camera helper function forward declarations (defined later in this file)
static inline float gvCameraHash(float2 value);
static inline float gvCameraLuma(float3 color);
static inline float3 gvCameraSample(texture2d<half, access::sample> texture, float2 uv);
static inline float3 gvMoshStaleColor(float3 color, float staleness, float2 seed, float time);

struct GVCameraConversionUniforms {
    uint4 source;
    float4 tuning;
};

struct GVCameraRGBSplitUniforms {
    float4 parameters;
};

struct GVCameraEffectUniforms {
    uint4 mode;
    float4 parameters;
    float4 viewport;
    float4 extra;
    float4 audio;
    float4 touch;          // xy = normalized touch position, z = velocity, w = active
    float4 touchImpact;    // xy = impact position, z = age seconds, w = present
    // Raw drag vector: xy = pointer velocity in screen fractions per second
    // (direction preserved, unlike `touch.z` which is a scalar speed), w = 1
    // while the finger is down and moving. The mosh engine injects this as
    // directional force into the block transport field.
    float4 touchDrag;
    float4 audioDynamics;  // x = peak, y = transient onset, z = sustain, w = silence
    float4 blobs[4];       // up to 4 tracked fields: xy = normalized center, z = size, w = present
    // Sixteen log-spaced FFT bands, 40 Hz to 14 kHz, each 0...1, packed four
    // to a vector. Zero when the analyser is off. Read with gvSpectrumBand.
    float4 spectrum[4];
    // Frame-to-frame world reprojection. Maps a ray in this frame to where it
    // sat in the previous one. Identity unless a world-anchored mode is armed.
    float3x3 worldReprojection;
};

struct GVCameraPreviewUniforms {
    float4 viewport;       // xy = drawable size, zw = source texture size
    float4 scanlines;      // x = line spacing px, y = drift phase px, z = line width px, w = opacity
    float4 scanlineFlags;  // x = direction (0 h, 1 v, 2 diagonal)
    float4 overlays;       // y = framing mode; 4 means full-sensor OPEN GATE
};

struct GVCameraRaster {
    float4 position [[position]];
    float2 uv;
};

constexpr sampler gvCameraLinearSampler(
    coord::normalized,
    address::clamp_to_edge,
    filter::linear
);

// Samples a two-channel vector texture with clamped linear filtering.
// Declared up here with the other samplers because the temporal kernel reads
// the motion field long before the flow kernels are defined.
static inline float2 gvCameraSampleVector(texture2d<half, access::sample> texture, float2 uv) {
    return float2(texture.sample(gvCameraLinearSampler, clamp(uv, 0.0, 1.0)).rg);
}

// MARK: - Spectrum access
//
// The sixteen bands arrive packed four to a float4 because Metal argument
// buffers cannot carry a bare float[16] without padding every element out to
// sixteen bytes. These two helpers hide the packing so an effect reads bands
// by index, and reads *between* bands by position, without unpacking anything.

static inline float gvSpectrumBand(constant float4 *spectrum, int index) {
    const int clamped = clamp(index, 0, 15);
    return spectrum[clamped >> 2][clamped & 3];
}

/// Continuous read across the spectrum: `position` 0 is the lowest band and 1
/// the highest, interpolating between neighbours so a bar chart or a ring can
/// be drawn at any resolution without stepping.
static inline float gvSpectrumAt(constant float4 *spectrum, float position) {
    const float scaled = clamp(position, 0.0, 1.0) * 15.0;
    const int low = int(floor(scaled));
    const float blend = scaled - float(low);
    return mix(gvSpectrumBand(spectrum, low), gvSpectrumBand(spectrum, low + 1), blend);
}

// MARK: - Datamosh engine
//
// Structural, stateful image transport — not a glitch filter. The mosh is a
// small simulation running beside the camera:
//
//     source(t) → block vectors → displaced history → output(t) → history
//          ▲----------------------------------------------------------┘
//
// The history every mosh mode reads is the previous OUTPUT, carried in a
// dedicated ping-pong pair the renderer swaps every frame whether the camera
// is live or frozen under a held finger. Corruption therefore compounds frame
// over frame even while the source clock is stopped — camera time stops, mosh
// time continues.
//
// Block state lives in its own ping-pong pair at one texel per 8px cell:
//
//     xy = transport vector, normalised UV per frame
//     z  = staleness, 0 fresh … 1 fully stale
//     w  = refresh tick the block last obeyed
//
// Any macroblock size reads the same field; linear filtering between cells is
// what makes neighbouring blocks pull in similar directions, so smears are
// coherent instead of salt-and-pepper noise.

struct GVMoshState {
    float2 vector;
    float staleness;
    float tick;
};

static inline GVMoshState gvMoshReadState(
    texture2d<half, access::sample> state,
    float2 uv
) {
    const float4 raw = float4(state.sample(gvCameraLinearSampler, clamp(uv, 0.0, 1.0)));
    return GVMoshState{raw.xy, raw.z, raw.w};
}

static inline float2 gvMoshHash2(float2 value) {
    return fract(sin(float2(
        dot(value, float2(127.1, 311.7)),
        dot(value, float2(269.5, 183.3))
    )) * 43758.5453123);
}

/// Touch impact rings expand; radius in UV is age × speed.
static inline float gvMoshImpactRadius(float age) {
    return age * 0.85;
}

/// Drag force as a vector field. Direction and speed come from the raw drag
/// vector (`touchDrag.xy`, screen fractions per second), positioned around the
/// contact point with a wide falloff; a recent tap rings outward instead, so
/// an impulse breaks blocks apart without giving them a direction.
static inline float2 gvMoshTouchForce(
    float2 uv,
    float4 touch,
    float4 touchImpact,
    float4 touchDrag,
    float strength,
    float dt
) {
    float2 force = float2(0.0);
    if (touchDrag.w > 0.5) {
        const float2 delta = uv - touch.xy;
        const float falloff = 1.0 - smoothstep(0.05, 0.46, length(delta));
        force += touchDrag.xy * falloff * strength * dt;
    }
    if (touch.w > 0.5 && touchImpact.w > 0.5) {
        const float2 toFinger = uv - touchImpact.xy;
        const float span = max(length(toFinger), 1e-4);
        const float ring = exp(-abs(span - gvMoshImpactRadius(touchImpact.z)) * 11.0) *
            exp(-touchImpact.z * 2.4);
        force += (toFinger / span) * ring * strength * dt * 0.55;
    }
    return force;
}

/// Per-frame evolution of one block's transport vector.
///
/// Vectors carry momentum: they follow the live flow field plus finger force,
/// and decay toward rest over a fraction of a second after the motion stops.
/// Under MOTION LOCK the vectors present at touch-down keep travelling; under
/// VECTOR DRIFT they slowly rotate and wander so a frozen frame's prediction
/// field keeps mutating instead of repeating one displacement forever.
static inline float2 gvMoshUpdateVector(
    float2 previousVector,
    float2 liveFlow,
    bool flowReady,
    float gain,
    float momentumBase,
    float drift,
    float4 touch,
    float4 touchImpact,
    float4 touchDrag,
    bool holdActive,
    uint holdStyle,
    float holdSeconds,
    float2 blockId,
    float2 blockUV,
    float time,
    float dt
) {
    float momentum = momentumBase;
    if (holdActive && (holdStyle & 2u) != 0u) {
        momentum = 0.995;   // MOTION LOCK
    }
    // Frame-rate independent follow: how much of this frame's motion the
    // vector adopts, with the rest carried by its own momentum.
    const float follow = min((1.0 - momentum) * 1.6, 1.0);
    float2 vector = previousVector * momentum +
        (flowReady ? liveFlow : float2(0.0)) * gain * follow +
        gvMoshTouchForce(blockUV, touch, touchImpact, touchDrag, 0.28 + gain * 0.06, dt) * (1.0 - momentum) * 22.0;

    float driftNow = drift;
    if (holdActive && (holdStyle & 16u) != 0u) {
        driftNow *= 1.0 + min(holdSeconds, 6.0) * 0.55;   // VECTOR DRIFT ramps in while held
    }
    if (driftNow > 0.0) {
        const float angle = driftNow * dt * (gvCameraHash(blockId * 3.71) - 0.5) * 4.0;
        const float ca = cos(angle);
        const float sa = sin(angle);
        vector = float2(ca * vector.x - sa * vector.y, sa * vector.x + ca * vector.y);
        vector += (gvMoshHash2(blockId * 1.91 + fract(time * 0.37)) - 0.5) * driftNow * dt * 0.4;
    }

    // Hard clamp: an unbounded field samples arbitrarily far away and the
    // frame collapses to one smeared colour.
    const float limit = 0.22;
    const float magnitude = length(vector);
    if (magnitude > limit) {
        vector *= limit / magnitude;
    }
    return vector;
}

/// Corruption of stale image data. The failure mode of a lost reference is
/// colour bleeding off stale prediction and a coarsely re-quantised residual
/// — deliberately not RGB splitting.
static inline float3 gvMoshStaleColor(float3 color, float staleness, float2 seed, float time) {
    if (staleness <= 0.002) {
        return color;
    }
    const float2 direction = gvMoshHash2(seed * 1.37 + floor(time * 0.6)) - 0.5;
    const float y = gvCameraLuma(color);
    const float co = color.r - color.b;
    const float cg = color.g - color.b;
    const float drift = staleness * 0.22;
    const float driftedCo = co + direction.x * drift;
    const float driftedCg = cg + direction.y * drift;
    float3 rgb = float3(y - driftedCg + driftedCo, y + driftedCg, y - driftedCg - driftedCo);
    const float levels = mix(48.0, 10.0, staleness);
    rgb = floor(rgb * levels + 0.5) / levels;
    return saturate(rgb + staleness * 0.02);
}

struct GVMoshControls {
    float blockSize;
    float gain;           // flow → displacement scaling
    float momentum;       // per-frame vector persistence at 60 fps
    float refreshChance;  // probability a block obeys a refresh decision
    float stalenessRate;  // staleness accrued per second while unrefreshed
    float drift;          // vector mutation strength
    float fresh;          // how strongly a refreshed block snaps to the source
};

/// The core transport: one macroblock grid over the whole frame, per-block
/// vectors with momentum, partial frame replacement through a coherent
/// refresh map, and staleness that deepens the longer a block goes
/// unrefreshed. State is written back for the next frame.
static inline float3 gvMoshTransport(
    GVMoshControls mosh,
    float3 current,
    texture2d<half, access::sample> history,
    texture2d<half, access::sample> stateIn,
    texture2d<half, access::write> stateOut,
    float2 liveFlow,
    bool flowReady,
    float4 touch,
    float4 touchImpact,
    float4 touchDrag,
    bool holdActive,
    uint holdStyle,
    float holdSeconds,
    float time,
    float dt,
    float2 uv,
    float2 size,
    uint2 position
) {
    const float2 blockPos = floor(float2(position) / mosh.blockSize);
    const float2 blockId = blockPos + 0.5;
    const float2 centreUV = (blockPos * mosh.blockSize + mosh.blockSize * 0.5) / size;
    const GVMoshState previous = gvMoshReadState(stateIn, centreUV);

    // Block fates are decided on ~90ms ticks, so a decision survives several
    // frames the way a decoder's refresh map does, and neighbours inherit it
    // through the filtered state field — repair fronts sweep instead of
    // sprinkling.
    const float tick = floor(time * 11.0);
    const float decisionHash = gvCameraHash(blockId * 7.13 + float2(tick * 0.311, tick * 0.127));

    float refreshChance = mosh.refreshChance;
    if (holdActive) {
        if ((holdStyle & 8u) != 0u) {
            // FRAME STARVATION: the frozen frame only trickles through, and
            // the trickle dries up the longer the hold lasts.
            refreshChance *= exp(-holdSeconds * 0.9);
        }
        if ((holdStyle & 4u) != 0u) {
            // FEEDBACK RUNAWAY: the image slowly consumes itself.
            refreshChance *= exp(-holdSeconds * 0.45);
        }
    }
    // A block surrounded by stale prediction is far less likely to refresh:
    // corruption is a region, not a coin flip.
    const float neighbourStale = max(
        gvMoshReadState(stateIn, centreUV + float2(mosh.blockSize / size.x, 0.0)).staleness,
        gvMoshReadState(stateIn, centreUV - float2(mosh.blockSize / size.x, 0.0)).staleness
    );
    refreshChance = saturate(refreshChance * (1.0 - neighbourStale * 0.65));
    const bool refreshed = decisionHash < refreshChance;

    const float2 vector = gvMoshUpdateVector(
        previous.vector, liveFlow, flowReady, mosh.gain, mosh.momentum, mosh.drift,
        touch, touchImpact, touchDrag, holdActive, holdStyle, holdSeconds,
        blockId, centreUV, time, dt
    );

    float staleness = refreshed
        ? 0.0
        : min(previous.staleness + mosh.stalenessRate * dt, 1.0);

    const float3 sampledHistory = gvCameraSample(history, clamp(uv - vector, 0.001, 0.999));
    const float3 carried = gvMoshStaleColor(sampledHistory, staleness, blockId, time);

    float fresh = mosh.fresh;
    if (holdActive && (holdStyle & 4u) != 0u) {
        fresh *= exp(-holdSeconds * 0.35);
    }
    // A refreshed block still inherits a trace of what it carried, so repairs
    // read as compression settling rather than a cut to the live frame.
    float3 result = mix(carried, current, refreshed ? saturate(fresh) : 0.0);
    result = mix(result, current, refreshed ? 0.12 : 0.0);

    if (all((position & uint2(7)) == uint2(0))) {
        stateOut.write(half4(half2(vector), half(staleness), half(tick)), position >> 3);
    }
    return result;
}

// MARK: - Temporal engine
//
// History addressed in seconds, not in frame strides. Effects ask for "1.4
// seconds ago" and get the same result at 30fps and 120fps, which fixed-stride
// taps cannot do: a stride of 12 frames is 400ms on one device and 100ms on
// another, so anything tuned against it is wrong everywhere else.

struct GVTemporalRing {
    uint slotCount;
    uint head;
    uint validCount;
    uint isPrimed;
    float currentTime;   // seconds since the ring's origin
    float historySpan;   // seconds between oldest and newest valid slice
    float2 padding;
};

/// Samples the ring at a given age in seconds, interpolating between the two
/// bracketing slices.
///
/// Returns the live colour untouched when the ring has nothing usable, so an
/// effect degrades to "no history yet" rather than to black — a temporal effect
/// that flashes black on the first frames reads as broken.
static inline float3 gvTemporalSample(
    texture2d_array<half, access::sample> ring,
    constant float *timestamps,
    constant GVTemporalRing &info,
    float2 uv,
    float ageSeconds,
    float3 live
) {
    if (info.validCount < 2u) {
        return live;
    }

    const float target = info.currentTime - max(ageSeconds, 0.0);

    // Find the closest slice at or before the target, and the closest after.
    // Linear over at most 16 entries: cheaper than any search structure at
    // this size, and branch-free enough to stay warp-coherent.
    int beforeIndex = -1;
    int afterIndex = -1;
    float beforeTime = -1e9;
    float afterTime = 1e9;

    for (uint i = 0u; i < info.slotCount; ++i) {
        const float stamp = timestamps[i];
        if (stamp < -1e8) {
            continue;   // slice never written
        }
        if (stamp <= target && stamp > beforeTime) {
            beforeTime = stamp;
            beforeIndex = int(i);
        }
        if (stamp > target && stamp < afterTime) {
            afterTime = stamp;
            afterIndex = int(i);
        }
    }

    // Older than anything held: clamp to the oldest rather than wrapping,
    // which would make a slow drag through time jump back to the present.
    if (beforeIndex < 0) {
        return afterIndex < 0
            ? live
            : float3(ring.sample(gvCameraLinearSampler, uv, uint(afterIndex)).rgb);
    }
    if (afterIndex < 0) {
        return float3(ring.sample(gvCameraLinearSampler, uv, uint(beforeIndex)).rgb);
    }

    const float span = max(afterTime - beforeTime, 1e-5);
    const float blend = saturate((target - beforeTime) / span);
    const float3 older = float3(ring.sample(gvCameraLinearSampler, uv, uint(beforeIndex)).rgb);
    const float3 newer = float3(ring.sample(gvCameraLinearSampler, uv, uint(afterIndex)).rgb);
    return mix(older, newer, blend);
}

/// Per-pixel age map: how far back this pixel should reach, driven by a source
/// value in 0...1. Shared so every effect that maps a signal onto time agrees
/// on the curve.
static inline float gvTemporalAge(float source, float depth, float bias, float contrast) {
    const float shaped = saturate((source - bias) * contrast + 0.5);
    return shaped * depth;
}



float gvCameraToLinear(float value, uint transferKind) {
    const float channel = saturate(value);
    // fast::pow trades a few ULP for a materially cheaper transcendental on
    // Apple GPUs. This runs three times per pixel of the full-rate conversion
    // pass every frame, where the error — well under a display step — cannot
    // survive contact with camera noise.
    if (transferKind == 1) {
        return channel <= 0.04045
            ? channel / 12.92
            : fast::pow((channel + 0.055) / 1.055, 2.4);
    }
    return channel < 0.081
        ? channel / 4.5
        : fast::pow((channel + 0.099) / 1.099, 1.0 / 0.45);
}

float3 gvCameraToLinear(float3 value, uint transferKind) {
    return float3(
        gvCameraToLinear(value.r, transferKind),
        gvCameraToLinear(value.g, transferKind),
        gvCameraToLinear(value.b, transferKind)
    );
}

float3 gvCameraYUVToRGB(float y, float2 chroma, uint matrixKind) {
    if (matrixKind == 0) {
        return float3(
            y + 1.4020 * chroma.y,
            y - 0.344136 * chroma.x - 0.714136 * chroma.y,
            y + 1.7720 * chroma.x
        );
    }
    if (matrixKind == 2) {
        return float3(
            y + 1.4746 * chroma.y,
            y - 0.164553 * chroma.x - 0.571353 * chroma.y,
            y + 1.8814 * chroma.x
        );
    }
    return float3(
        y + 1.5748 * chroma.y,
        y - 0.187324 * chroma.x - 0.468124 * chroma.y,
        y + 1.8556 * chroma.x
    );
}

kernel void gvCameraYUVToLinear(
    texture2d<float, access::sample> lumaTexture [[texture(0)]],
    texture2d<float, access::sample> chromaTexture [[texture(1)]],
    texture2d<half, access::write> outputTexture [[texture(2)]],
    constant GVCameraConversionUniforms &uniforms [[buffer(0)]],
    uint2 position [[thread_position_in_grid]]
) {
    if (position.x >= outputTexture.get_width() || position.y >= outputTexture.get_height()) {
        return;
    }

    const float2 size = float2(outputTexture.get_width(), outputTexture.get_height());
    const float2 uv = (float2(position) + 0.5) / size;
    float y = lumaTexture.sample(gvCameraLinearSampler, uv).r;
    float2 chroma = chromaTexture.sample(gvCameraLinearSampler, uv).rg;

    if (uniforms.source.z == 0) {
        y = (y - 16.0 / 255.0) * (255.0 / 219.0);
        chroma = (chroma - float2(0.5)) * (255.0 / 224.0);
    } else {
        chroma -= float2(0.5);
    }

    const float3 encodedRGB = saturate(gvCameraYUVToRGB(y, chroma, uniforms.source.w));
    const float3 linearRGB = gvCameraToLinear(encodedRGB, uint(uniforms.tuning.x));
    outputTexture.write(half4(half3(linearRGB), 1.0h), position);
}

float3 gvSyntheticColor(float2 uv, float time) {
    const float3 upperBars[7] = {
        float3(0.74),
        float3(0.73, 0.73, 0.08),
        float3(0.08, 0.70, 0.70),
        float3(0.08, 0.66, 0.12),
        float3(0.68, 0.09, 0.68),
        float3(0.66, 0.08, 0.10),
        float3(0.08, 0.10, 0.68)
    };
    const float3 lowerBars[6] = {
        float3(0.0),
        float3(0.18),
        float3(1.0),
        float3(0.08),
        float3(0.46, 0.10, 0.94),
        float3(0.0)
    };

    float3 color;
    if (uv.y < 0.58) {
        const uint index = min(uint(uv.x * 7.0), 6u);
        color = upperBars[index];
    } else {
        const uint index = min(uint(uv.x * 6.0), 5u);
        color = lowerBars[index];
    }

    const bool inChecker = uv.x > 0.05 && uv.x < 0.27 && uv.y > 0.66 && uv.y < 0.89;
    if (inChecker) {
        const uint2 checker = uint2((uv - float2(0.05, 0.66)) * float2(92.0, 126.0));
        color = ((checker.x + checker.y) & 1u) == 0u ? float3(1.0) : float3(0.0);
    }

    const float2 circleCenter = float2(0.845, 0.765);
    const float circleDistance = distance(uv, circleCenter);
    if (abs(circleDistance - 0.082) < 0.0022) {
        color = float3(0.95);
    }

    const float motion = fract(time * 0.24);
    const float2 squareCenter = float2(0.30 + motion * 0.46, 0.46);
    const float2 squareDistance = abs(uv - squareCenter);
    if (squareDistance.x < 0.038 && squareDistance.y < 0.038) {
        color = float3(0.72, 0.28, 1.0);
        if (squareDistance.x < 0.026 && squareDistance.y < 0.026) {
            color = float3(0.08);
        }
    }

    const bool vectorLine = abs(uv.y - 0.46) < 0.0013 && uv.x > 0.30 && uv.x < 0.76;
    if (vectorLine && uint(uv.x * 120.0) % 3u != 0u) {
        color = float3(0.92);
    }
    return color;
}

kernel void gvCameraSyntheticLinear(
    texture2d<half, access::write> outputTexture [[texture(0)]],
    constant GVCameraConversionUniforms &uniforms [[buffer(0)]],
    uint2 position [[thread_position_in_grid]]
) {
    if (position.x >= outputTexture.get_width() || position.y >= outputTexture.get_height()) {
        return;
    }
    const float2 uv = (float2(position) + 0.5) /
        float2(outputTexture.get_width(), outputTexture.get_height());
    const float3 encodedColor = gvSyntheticColor(uv, uniforms.tuning.y);
    outputTexture.write(half4(half3(gvCameraToLinear(encodedColor, 1)), 1.0h), position);
}

kernel void gvCameraRGBSplit(
    texture2d<half, access::sample> inputTexture [[texture(0)]],
    texture2d<half, access::write> outputTexture [[texture(1)]],
    constant GVCameraRGBSplitUniforms &uniforms [[buffer(0)]],
    uint2 position [[thread_position_in_grid]]
) {
    if (position.x >= outputTexture.get_width() || position.y >= outputTexture.get_height()) {
        return;
    }
    const float2 size = float2(outputTexture.get_width(), outputTexture.get_height());
    const float2 uv = (float2(position) + 0.5) / size;
    const float2 offset = uniforms.parameters.x * uniforms.parameters.yz;
    const half4 base = inputTexture.sample(gvCameraLinearSampler, uv);
    const half red = inputTexture.sample(gvCameraLinearSampler, uv + offset).r;
    const half blue = inputTexture.sample(gvCameraLinearSampler, uv - offset).b;
    const half3 split = half3(red, base.g, blue);
    const half mixAmount = half(saturate(uniforms.parameters.w));
    outputTexture.write(half4(mix(base.rgb, split, mixAmount), base.a), position);
}

float gvCameraHash(float2 value) {
    return fract(sin(dot(value, float2(127.1, 311.7))) * 43758.5453123);
}

float gvCameraLuma(float3 color) {
    return dot(color, float3(0.2126, 0.7152, 0.0722));
}

float3 gvCameraRGBToHSV(float3 color) {
    const float4 key = color.g < color.b
        ? float4(color.bg, -1.0, 2.0 / 3.0)
        : float4(color.gb, 0.0, -1.0 / 3.0);
    const float4 mixValue = color.r < key.x
        ? float4(key.xyw, color.r)
        : float4(color.r, key.yzx);
    const float chroma = mixValue.x - min(mixValue.w, mixValue.y);
    const float epsilon = 1e-10;
    return float3(
        abs(mixValue.z + (mixValue.w - mixValue.y) / (6.0 * chroma + epsilon)),
        chroma / (mixValue.x + epsilon),
        mixValue.x
    );
}

float3 gvCameraHSVToRGB(float3 color) {
    const float3 ramp = abs(fract(color.xxx + float3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
    return color.z * mix(float3(1.0), saturate(ramp - 1.0), color.y);
}

float3 gvCameraThermal(float value, float shift) {
    const float heat = saturate(value + (shift - 0.5) * 0.5);
    const float3 cold = float3(0.015, 0.02, 0.28);
    const float3 violet = float3(0.34, 0.02, 0.72);
    const float3 red = float3(0.92, 0.04, 0.05);
    const float3 yellow = float3(1.0, 0.82, 0.02);
    const float3 white = float3(1.0, 0.98, 0.82);
    float3 color = mix(cold, violet, smoothstep(0.0, 0.28, heat));
    color = mix(color, red, smoothstep(0.24, 0.52, heat));
    color = mix(color, yellow, smoothstep(0.48, 0.78, heat));
    return mix(color, white, smoothstep(0.76, 1.0, heat));
}

/// Compresses an SDR highlight without clipping its channels independently.
/// Independent `saturate` turns bright cyan/amber/magenta emissions white at
/// their peaks. Scaling by the peak channel keeps the hue and channel ratios,
/// while values already inside the display gamut pass through unchanged.
float3 gvCameraGamutCompress(float3 color) {
    const float3 positive = max(color, 0.0);
    const float peak = max(positive.r, max(positive.g, positive.b));
    return peak > 1.0 ? positive / peak : positive;
}

/// True for modes that only remap colour and never displace a sample.
static bool gvIsColourOnlyMode(uint mode) {
    switch (mode) {
        case 2:  // posterize
        case 3:  // dither
        case 9:  // vignette
        case 10: // grain
        case 11: // thermal
        case 13: // threshold
        case 14: // invert
        case 16: // solarize
        case 17: // hue shift
        case 18: // monochrome
        case 73: // gradient map
        case 74: // false colour
        case 91: // spectral tint
        case 97: // blue-noise dither
            return true;
        default:
            return false;
    }
}

float3 gvCameraSample(
    texture2d<half, access::sample> texture,
    float2 uv
) {
    return float3(texture.sample(gvCameraLinearSampler, uv).rgb);
}

float2 gvCameraRotate(float2 value, float angle);

// MARK: - Helpers for the extended effect library

/// Value noise. Cheap, tileable enough for screen-space fields, and stable
/// frame to frame for a fixed input so warps do not shimmer.
float gvNoise(float2 p) {
    const float2 i = floor(p);
    const float2 f = fract(p);
    const float2 u = f * f * (3.0 - 2.0 * f);
    const float a = gvCameraHash(i);
    const float b = gvCameraHash(i + float2(1.0, 0.0));
    const float c = gvCameraHash(i + float2(0.0, 1.0));
    const float d = gvCameraHash(i + float2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

/// Four-octave fractal noise — the base for flow fields, cracks and decay.
float gvFbm(float2 p) {
    float sum = 0.0;
    float amplitude = 0.5;
    for (int i = 0; i < 4; i++) {
        sum += gvNoise(p) * amplitude;
        p *= 2.02;
        amplitude *= 0.5;
    }
    return sum;
}

struct GVNoiseGradient {
    float value;
    float2 gradient;
};

/// Value noise and its analytic derivative from the same four hash reads.
/// The old central difference evaluated four complete FBMs (64 hash calls)
/// for one gradient. This evaluates four noise cells total (16 hash calls),
/// is independent of an arbitrary epsilon, and no longer shimmers as scale
/// changes move that epsilon through the field.
GVNoiseGradient gvNoiseGradient(float2 p) {
    const float2 cell = floor(p);
    const float2 local = fract(p);
    const float2 blend = local * local * (3.0 - 2.0 * local);
    const float2 blendDerivative = 6.0 * local * (1.0 - local);
    const float a = gvCameraHash(cell);
    const float b = gvCameraHash(cell + float2(1.0, 0.0));
    const float c = gvCameraHash(cell + float2(0.0, 1.0));
    const float d = gvCameraHash(cell + float2(1.0, 1.0));

    GVNoiseGradient sample;
    sample.value = mix(mix(a, b, blend.x), mix(c, d, blend.x), blend.y);
    sample.gradient = float2(
        mix(b - a, d - c, blend.y) * blendDerivative.x,
        mix(c - a, d - b, blend.x) * blendDerivative.y
    );
    return sample;
}

/// Analytic gradient of the FBM field, used to build curl/flow directions
/// without another texture or four redundant FBM evaluations.
float2 gvFbmGradient(float2 p, float epsilon) {
    float2 gradient = float2(0.0);
    float amplitude = 0.5;
    float frequency = 1.0;
    for (int octave = 0; octave < 4; ++octave) {
        const GVNoiseGradient sample = gvNoiseGradient(p);
        gradient += sample.gradient * amplitude * frequency;
        p *= 2.02;
        frequency *= 2.02;
        amplitude *= 0.5;
    }
    return gradient;
}

/// Worley / cellular distance field. Returns x = nearest distance,
/// y = second-nearest, so `y - x` gives clean cell borders for cracks.
float2 gvWorley(float2 p) {
    const float2 cell = floor(p);
    const float2 local = fract(p);
    float nearest = 8.0;
    float second = 8.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            const float2 offset = float2(x, y);
            const float2 point = float2(
                gvCameraHash(cell + offset),
                gvCameraHash(cell + offset + float2(17.3, 5.1))
            );
            const float distance = length(offset + point - local);
            if (distance < nearest) {
                second = nearest;
                nearest = distance;
            } else if (distance < second) {
                second = distance;
            }
        }
    }
    return float2(nearest, second);
}

/// Nine-tap blur around `uv`. Camera colour and weights stay in half precision:
/// this is filter accumulation, not geometry, and doubling register width here
/// only lowers occupancy on Apple GPUs.
float3 gvBlur(texture2d<half, access::sample> texture, float2 uv, float2 radius) {
    half3 sum = half3(0.0h);
    sum += texture.sample(gvCameraLinearSampler, uv).rgb * 0.24h;
    sum += texture.sample(gvCameraLinearSampler, uv + float2(radius.x, 0.0)).rgb * 0.13h;
    sum += texture.sample(gvCameraLinearSampler, uv - float2(radius.x, 0.0)).rgb * 0.13h;
    sum += texture.sample(gvCameraLinearSampler, uv + float2(0.0, radius.y)).rgb * 0.13h;
    sum += texture.sample(gvCameraLinearSampler, uv - float2(0.0, radius.y)).rgb * 0.13h;
    sum += texture.sample(gvCameraLinearSampler, uv + radius * 0.7).rgb * 0.06h;
    sum += texture.sample(gvCameraLinearSampler, uv - radius * 0.7).rgb * 0.06h;
    sum += texture.sample(gvCameraLinearSampler, uv + float2(radius.x, -radius.y) * 0.7).rgb * 0.06h;
    sum += texture.sample(gvCameraLinearSampler, uv + float2(-radius.x, radius.y) * 0.7).rgb * 0.06h;
    return float3(sum);
}

/// Samples R, G and B along a direction at different magnitudes. The single
/// most reusable primitive in the analog/optics families.
float3 gvChromaSplit(
    texture2d<half, access::sample> texture,
    float2 uv,
    float2 direction
) {
    return float3(
        texture.sample(gvCameraLinearSampler, uv + direction).r,
        texture.sample(gvCameraLinearSampler, uv).g,
        texture.sample(gvCameraLinearSampler, uv - direction).b
    );
}


// MARK: - Glyph and scope helpers
//
// Used by the ASCII mosaic and by the four measurement scopes. Declared here
// rather than inside the kernel because Metal has no local functions and the
// scopes each need the same panel maths.

/// One pixel of a 5x5 bitmap glyph, indexed by ink level 0 (blank) to 8 (solid).
///
/// A real font atlas would be a texture and another binding; nine hand-drawn
/// bitmaps cost twenty-five bits each and cover the density ramp that an ASCII
/// renderer actually needs.
static inline float gvAsciiGlyph(int level, int2 cell) {
    if (cell.x < 0 || cell.x > 4 || cell.y < 0 || cell.y > 4) {
        return 0.0;
    }
    const uint glyphs[9] = {
        0x0000000u, 0x0020000u, 0x0020080u, 0x0003800u, 0x00701c0u,
        0x0023880u, 0x0053940u, 0x0afabeau, 0x1fdd77fu
    };
    const uint bits = glyphs[clamp(level, 0, 8)];
    return float((bits >> uint(cell.y * 5 + cell.x)) & 1u);
}

/// Where a pixel sits inside a scope panel, and whether it is inside at all.
///
/// `panel` is (originX, originY, width, height) in normalised frame space.
/// Returns local coordinates 0...1 within the panel; `inside` is false when
/// the pixel is elsewhere, which is what lets a scope cost nothing over the
/// nine tenths of the frame it does not draw on.
struct GVScopePanel {
    float2 local;
    bool inside;
};

static inline GVScopePanel gvScopePanel(float2 uv, float4 panel) {
    GVScopePanel result;
    result.local = (uv - panel.xy) / max(panel.zw, float2(0.0001));
    result.inside = all(result.local >= 0.0) && all(result.local <= 1.0);
    return result;
}

/// Rec.709 chroma coordinates, scaled so full saturation lands near unit
/// radius. This is what a vectorscope plots.
static inline float2 gvChromaCoordinate(float3 color) {
    const float luma = gvCameraLuma(color);
    return float2((color.b - luma) * 0.565, (color.r - luma) * 0.713) * 1.6;
}

static inline void gvCameraStyleEffectBody(
    texture2d<half, access::sample> inputTexture,
    texture2d<half, access::write> outputTexture,
    constant GVCameraEffectUniforms &uniforms,
    uint2 position,
    uint styleMode
) {
    if (position.x >= outputTexture.get_width() || position.y >= outputTexture.get_height()) {
        return;
    }

    const float2 size = uniforms.viewport.xy;
    const float2 texel = uniforms.viewport.zw;
    float2 uv = (float2(position) + 0.5) / size;
    float4 controls = uniforms.parameters;
    controls.x = saturate(controls.x + uniforms.audio.y * 0.18);
    controls.y = saturate(controls.y + uniforms.audio.z * 0.10);
    controls.z = saturate(controls.z + uniforms.audio.w * 0.12);

    // MARK: Universal touch modulation
    //
    // Applied once here rather than per-effect, so every style mode responds to
    // the finger without 92 individual edits. Three couplings:
    //
    //   proximity - the effect intensifies toward the contact point, which is
    //               what makes the filter feel attached to the hand
    //   position  - X and Y bias the two primary parameters, so sliding the
    //               finger sweeps the effect through its range
    //   velocity  - a fast drag pushes the third parameter, so flicks register
    //
    // Effects that already read `uniforms.touch` directly (ripple, twirl,
    // finger gravity) still do; this only shifts their controls underneath.
    float touchIntensity = 1.0;
    if (uniforms.touch.w > 0.5) {
        const float reach = 0.55;
        const float proximity = 1.0 - smoothstep(0.0, reach, distance(uv, uniforms.touch.xy));
        const float velocity = saturate(uniforms.touch.z);

        controls.x = saturate(controls.x + (uniforms.touch.x - 0.5) * 0.42 * proximity);
        controls.y = saturate(controls.y + (0.5 - uniforms.touch.y) * 0.42 * proximity);
        controls.z = saturate(controls.z + velocity * 0.24);

        // Local strength lift. Capped so the effect never fully takes over the
        // frame from a single touch.
        touchIntensity = 1.0 + proximity * 0.55;
    }
    // A recent tap leaves an expanding ring of extra intensity behind it.
    if (uniforms.touchImpact.w > 0.5) {
        const float age = uniforms.touchImpact.z;
        const float ringRadius = age * 0.9;
        const float ring = exp(-abs(distance(uv, uniforms.touchImpact.xy) - ringRadius) * 14.0);
        touchIntensity += ring * exp(-age * 2.4) * 0.85;
    }

    // Drag inertia. While a finger moves, the sampled coordinate lags behind
    // the motion, so every style mode shares one physical response to a
    // flick: the frame has apparent mass. Direction comes from the raw drag
    // vector, and the clamp keeps a violent swipe from pulling samples far
    // enough to smear.
    if (uniforms.touchDrag.w > 0.5) {
        const float2 lag = clamp(uniforms.touchDrag.xy, float2(-2.0), float2(2.0));
        uv -= lag * 0.006;
    }

    const float3 base = gvCameraSample(inputTexture, uv);
    const float time = controls.w;
    float3 result = base;

    switch (styleMode) {
    case 0: { // Ripple
        // The ripple centres on the finger while it is in contact, and recent
        // impacts add an expanding ring so a tap visibly disturbs the surface.
        const float2 anchor = uniforms.touch.w > 0.5 ? uniforms.touch.xy : float2(0.5);
        const float2 centered = uv - anchor;
        const float radius = length(centered);
        const float amount = mix(0.002, 0.075, controls.x) * (1.0 + uniforms.audio.y * 0.5);
        const float frequency = mix(4.0, 52.0, controls.y);
        const float speed = mix(-4.0, 4.0, controls.z);
        const float2 direction = radius > 0.0001 ? centered / radius : float2(0.0);
        // Two harmonics rather than one: the secondary runs at an
        // incommensurate ratio so rings interfere and break into the choppy
        // crests real surfaces show, instead of one clean concentric groove.
        const float wave = (
            sin(radius * frequency - time * speed) +
            0.38 * sin(radius * frequency * 2.17 - time * speed * 1.41)
        ) * amount;
        const float velocityLift = 1.0 + saturate(uniforms.touch.z) * 0.9;
        result = gvCameraSample(inputTexture, uv + direction * wave * velocityLift);
        if (uniforms.touchImpact.w > 0.5) {
            const float2 impactDelta = uv - uniforms.touchImpact.xy;
            const float impactRadius = max(length(impactDelta), 0.0001);
            const float2 impactDirection = impactDelta / impactRadius;
            const float ring = (
                sin(impactRadius * frequency * 1.6 - uniforms.touchImpact.z * speed * 2.4) +
                0.3 * sin(impactRadius * frequency * 3.7 - uniforms.touchImpact.z * speed * 3.1)
            ) * amount * 1.7 * exp(-impactRadius * 2.6) * exp(-uniforms.touchImpact.z * 2.0);
            result = gvCameraSample(inputTexture, uv + impactDirection * ring);
        }
        // Tracked blobs ring outward too, scaled by their size.
        for (int i = 0; i < 4; i++) {
            if (uniforms.blobs[i].w > 0.5) {
                const float2 blobDelta = uv - uniforms.blobs[i].xy;
                const float blobRadius = max(length(blobDelta), 0.0001);
                const float blobRing = (
                    sin(blobRadius * frequency * 1.5 - time * speed * 1.8) +
                    0.3 * sin(blobRadius * frequency * 3.3 - time * speed * 2.2)
                ) * amount * 1.4 * uniforms.blobs[i].z * exp(-blobRadius * 2.8);
                result = gvCameraSample(inputTexture, uv + blobDelta / blobRadius * blobRing);
            }
        }
        break;
    }
    case 1: { // Pixelate
        const float block = mix(2.0, 96.0, controls.x);
        const float aspect = mix(0.5, 2.0, controls.z);
        const float2 blockSize = float2(block * aspect, block / aspect);
        const float2 pixelUV = (floor(float2(position) / blockSize) * blockSize + blockSize * 0.5) / size;
        result = mix(base, gvCameraSample(inputTexture, pixelUV), controls.y);
        break;
    }
    case 2: { // Posterize
        const float levels = floor(mix(2.0, 24.0, controls.x));
        const float contrast = mix(0.55, 1.85, controls.z);
        const float3 adjusted = saturate((base - 0.5) * contrast + 0.5);
        const float3 quantized = floor(adjusted * levels + 0.5) / levels;
        result = mix(base, quantized, controls.y);
        break;
    }
    case 3: { // Ordered Bayer dither
        const float bayer[16] = {
            0.0, 8.0, 2.0, 10.0,
            12.0, 4.0, 14.0, 6.0,
            3.0, 11.0, 1.0, 9.0,
            15.0, 7.0, 13.0, 5.0
        };
        const uint scale = uint(max(1.0, floor(mix(1.0, 8.0, controls.x))));
        const uint2 cell = (position / scale) & uint2(3u);
        const float threshold = (bayer[cell.y * 4u + cell.x] / 16.0 - 0.5) * controls.y;
        const float levels = floor(mix(2.0, 8.0, controls.z));
        result = saturate(floor(base * levels + threshold + 0.5) / levels);
        break;
    }
    case 4: { // Sobel edge
        const float2 stepUV = texel * mix(0.75, 4.0, controls.x);
        const float tl = gvCameraLuma(gvCameraSample(inputTexture, uv + stepUV * float2(-1.0, -1.0)));
        const float tc = gvCameraLuma(gvCameraSample(inputTexture, uv + stepUV * float2(0.0, -1.0)));
        const float tr = gvCameraLuma(gvCameraSample(inputTexture, uv + stepUV * float2(1.0, -1.0)));
        const float ml = gvCameraLuma(gvCameraSample(inputTexture, uv + stepUV * float2(-1.0, 0.0)));
        const float mr = gvCameraLuma(gvCameraSample(inputTexture, uv + stepUV * float2(1.0, 0.0)));
        const float bl = gvCameraLuma(gvCameraSample(inputTexture, uv + stepUV * float2(-1.0, 1.0)));
        const float bc = gvCameraLuma(gvCameraSample(inputTexture, uv + stepUV * float2(0.0, 1.0)));
        const float br = gvCameraLuma(gvCameraSample(inputTexture, uv + stepUV * float2(1.0, 1.0)));
        const float gx = -tl - 2.0 * ml - bl + tr + 2.0 * mr + br;
        const float gy = -tl - 2.0 * tc - tr + bl + 2.0 * bc + br;
        const float edge = smoothstep(mix(0.02, 0.55, controls.y), 1.0, length(float2(gx, gy)));
        result = mix(base, float3(edge), controls.z);
        break;
    }
    case 5: { // Signal tear
        const float bands = floor(mix(4.0, 64.0, controls.y));
        const float band = floor(uv.y * bands);
        const float tick = floor(time * mix(0.5, 12.0, controls.z));
        const float gate = step(0.70, gvCameraHash(float2(band, tick)));
        const float offset = (gvCameraHash(float2(tick, band + 19.0)) - 0.5) * controls.x * 0.42 * gate;
        float2 tornUV = uv + float2(offset, 0.0);
        result = gvCameraSample(inputTexture, tornUV);
        if (gate > 0.5) {
            const float channelOffset = controls.x * 0.035;
            result.r = gvCameraSample(inputTexture, tornUV + float2(channelOffset, 0.0)).r;
            result.b = gvCameraSample(inputTexture, tornUV - float2(channelOffset, 0.0)).b;
        }
        break;
    }
    case 6: { // VHS
        const float line = floor(uv.y * size.y * 0.45);
        const float jitter = (gvCameraHash(float2(line, floor(time * 24.0))) - 0.5) * controls.x * 0.045;
        const float2 damagedUV = uv + float2(jitter, 0.0);
        const float chroma = controls.x * 0.012;
        result = gvCameraSample(inputTexture, damagedUV);
        result.r = gvCameraSample(inputTexture, damagedUV + float2(chroma, 0.0)).r;
        result.b = gvCameraSample(inputTexture, damagedUV - float2(chroma, 0.0)).b;
        const float scan = 1.0 - controls.y * 0.28 * (0.5 + 0.5 * sin(uv.y * mix(180.0, 1100.0, controls.y)));
        const float noise = (gvCameraHash(float2(position) + time * 83.0) - 0.5) * controls.z * 0.22;
        result = saturate(result * scan + noise);
        break;
    }
    case 7: { // Kaleidoscope
        float2 point = uv - 0.5;
        float angle = atan2(point.y, point.x) + (controls.y - 0.5) * 6.2831853;
        const float segments = floor(mix(2.0, 18.0, controls.x));
        const float sector = 6.2831853 / segments;
        angle = fmod(abs(angle), sector);
        angle = min(angle, sector - angle);
        const float radius = length(point) * mix(0.55, 1.85, controls.z);
        result = gvCameraSample(inputTexture, 0.5 + float2(cos(angle), sin(angle)) * radius);
        break;
    }
    case 8: { // Mirror
        const float angle = controls.x * 3.14159265;
        const float2 axis = float2(cos(angle), sin(angle));
        const float2 perpendicular = float2(-axis.y, axis.x);
        float2 point = uv - 0.5;
        float axial = dot(point, axis) + (controls.y - 0.5) * 0.5;
        const float crossAxis = dot(point, perpendicular);
        axial = abs(axial);
        const float2 mirroredUV = 0.5 + axis * axial + perpendicular * crossAxis;
        result = mix(base, gvCameraSample(inputTexture, mirroredUV), controls.z);
        break;
    }
    case 9: { // Vignette
        const float2 point = (uv - 0.5) * float2(size.x / max(size.y, 1.0), 1.0);
        const float roundness = mix(0.65, 2.2, controls.z);
        const float distanceValue = pow(length(point) * 1.55, roundness);
        const float edge = smoothstep(mix(0.92, 0.18, controls.y), 1.15, distanceValue);
        result = base * (1.0 - edge * controls.x);
        break;
    }
    case 10: { // Grain
        const float scale = mix(1.0, 9.0, controls.y);
        const float2 grainCell = floor(float2(position) / scale);
        const float monoNoise = gvCameraHash(grainCell + floor(time * 48.0)) - 0.5;
        const float3 chromaNoise = float3(
            monoNoise,
            gvCameraHash(grainCell + float2(31.0, time * 43.0)) - 0.5,
            gvCameraHash(grainCell + float2(time * 39.0, 71.0)) - 0.5
        );
        const float3 noise = mix(float3(monoNoise), chromaNoise, controls.z);
        result = saturate(base + noise * controls.x * 0.42);
        break;
    }
    case 11: { // Thermal
        const float contrast = mix(0.55, 2.5, controls.y);
        const float luma = saturate((gvCameraLuma(base) - 0.5) * contrast + 0.5);
        result = mix(base, gvCameraThermal(luma, controls.x), controls.z);
        break;
    }
    case 12: { // Halftone
        const float angle = controls.y * 3.14159265;
        const float2 axisX = float2(cos(angle), sin(angle));
        const float2 axisY = float2(-axisX.y, axisX.x);
        const float2 rotated = float2(dot(float2(position), axisX), dot(float2(position), axisY));
        const float dotSize = mix(3.0, 34.0, controls.x);
        const float2 local = fract(rotated / dotSize) - 0.5;
        const float radius = mix(0.46, 0.08, gvCameraLuma(base));
        const float dotMask = 1.0 - smoothstep(radius - 0.05, radius + 0.05, length(local));
        const float3 ink = base * dotMask;
        result = mix(base, ink, controls.z);
        break;
    }
    case 13: { // Threshold
        const float softness = mix(0.001, 0.24, controls.y);
        const float level = smoothstep(controls.x - softness, controls.x + softness, gvCameraLuma(base));
        result = mix(base, float3(level), controls.z);
        break;
    }
    case 14: { // Invert
        const float3 selector = saturate(1.0 - abs(float3(0.0, 0.5, 1.0) - controls.y) * 1.35);
        const float3 inverted = mix(base, 1.0 - base, mix(float3(controls.x), selector, 0.42));
        result = mix(base, inverted, controls.z);
        break;
    }
    case 15: { // Lens warp
        float2 point = uv - 0.5;
        const float radius = max(mix(0.22, 0.92, controls.y), 0.001);
        const float normalizedRadius = length(point) / radius;
        const float strength = (controls.x - 0.5) * 1.8;
        point *= 1.0 + strength * normalizedRadius * normalizedRadius;
        point /= mix(0.72, 1.34, controls.z);
        const float2 warpedUV = point + 0.5;
        result = all(warpedUV >= 0.0) && all(warpedUV <= 1.0)
            ? gvCameraSample(inputTexture, warpedUV)
            : float3(0.0);
        break;
    }
    case 16: { // Solarize
        const float threshold = mix(0.08, 0.92, controls.x);
        const float3 solarized = select(base, 1.0 - base, base > threshold);
        const float3 shifted = gvCameraHSVToRGB(
            gvCameraRGBToHSV(solarized) + float3((controls.y - 0.5) * 0.35, 0.0, 0.0)
        );
        result = mix(base, shifted, controls.z);
        break;
    }
    case 17: { // Hue shift
        float3 hsv = gvCameraRGBToHSV(base);
        hsv.x = fract(hsv.x + controls.x - 0.5);
        hsv.y = saturate(hsv.y * mix(0.0, 2.0, controls.y));
        result = mix(base, gvCameraHSVToRGB(hsv), controls.z);
        break;
    }
    case 18: { // Monochrome
        const float luma = saturate((gvCameraLuma(base) - 0.5) * mix(0.55, 2.1, controls.y) + 0.5);
        const float3 cool = float3(0.48, 0.34, 0.92);
        const float3 warm = float3(0.96, 0.58, 0.28);
        const float3 tint = mix(cool, warm, controls.x);
        result = mix(base, luma * tint, controls.z);
        break;
    }
    case 19: { // Sharpen
        const float2 radius = texel * mix(0.75, 4.0, controls.y);
        const float3 blur = (
            gvCameraSample(inputTexture, uv + float2(radius.x, 0.0)) +
            gvCameraSample(inputTexture, uv - float2(radius.x, 0.0)) +
            gvCameraSample(inputTexture, uv + float2(0.0, radius.y)) +
            gvCameraSample(inputTexture, uv - float2(0.0, radius.y))
        ) * 0.25;
        const float3 sharp = saturate(base + (base - blur) * controls.x * 3.2);
        result = mix(base, sharp, controls.z);
        break;
    }
    case 20: { // Emboss
        const float angle = controls.y * 6.2831853;
        const float2 direction = float2(cos(angle), sin(angle)) * texel * mix(1.0, 5.0, controls.x);
        const float3 difference = gvCameraSample(inputTexture, uv + direction) -
            gvCameraSample(inputTexture, uv - direction);
        const float3 embossed = saturate(0.5 + difference * mix(1.0, 5.0, controls.x));
        result = mix(base, embossed, controls.z);
        break;
    }
    case 21: { // Wave
        const float amount = controls.x * 0.11;
        const float frequency = mix(2.0, 44.0, controls.y);
        const float speed = mix(-5.0, 5.0, controls.z);
        const float2 warpedUV = uv + float2(
            sin(uv.y * frequency + time * speed),
            cos(uv.x * frequency * 0.72 - time * speed * 0.62)
        ) * amount;
        result = gvCameraSample(inputTexture, warpedUV);
        break;
    }
    case 22: { // CRT
        float2 point = uv * 2.0 - 1.0;
        const float curve = controls.x * 0.32;
        point *= 1.0 + curve * float2(point.y * point.y, point.x * point.x);
        const float2 crtUV = point * 0.5 + 0.5;
        if (any(crtUV < 0.0) || any(crtUV > 1.0)) {
            result = float3(0.0);
        } else {
            result = gvCameraSample(inputTexture, crtUV);
            const float scan = 1.0 - controls.y * 0.34 * (0.5 + 0.5 * sin(crtUV.y * size.y * 3.14159265));
            const uint channel = position.x % 3u;
            const float3 grille = channel == 0u
                ? float3(1.0, 0.72, 0.72)
                : channel == 1u ? float3(0.72, 1.0, 0.72) : float3(0.72, 0.72, 1.0);
            result *= scan * mix(float3(1.0), grille, controls.z);
        }
        break;
    }
    case 23: { // Data bend
        const float rows = floor(mix(8.0, 92.0, controls.y));
        const float row = floor(uv.y * rows);
        const float tick = floor(time * mix(1.5, 11.0, controls.x));
        const float gate = step(0.46, gvCameraHash(float2(row, tick)));
        const float addressShift = (gvCameraHash(float2(tick, row + 31.0)) - 0.5) * controls.x * 0.58;
        const float2 bentUV = float2(fract(uv.x + addressShift * gate), uv.y);
        const float channelShift = texel.x * mix(1.0, 22.0, controls.x) * gate;
        const float3 bent = float3(
            gvCameraSample(inputTexture, bentUV + float2(channelShift, 0.0)).r,
            gvCameraSample(inputTexture, bentUV).g,
            gvCameraSample(inputTexture, bentUV - float2(channelShift, 0.0)).b
        );
        result = mix(base, bent, controls.z);
        break;
    }
    case 24: { // Prism streak
        const float luma = gvCameraLuma(base);
        const float gate = smoothstep(controls.y, min(controls.y + 0.25, 1.0), luma);
        const float angle = time * 0.14 + uniforms.audio.w * 2.2;
        const float2 direction = float2(cos(angle), sin(angle)) * texel * mix(4.0, 72.0, controls.x);
        float3 streak = base;
        for (uint index = 1; index <= 6; ++index) {
            const float weight = (7.0 - float(index)) / 21.0;
            const float3 sampleColor = gvCameraSample(inputTexture, uv - direction * float(index));
            streak += sampleColor * weight * gate;
        }
        const float3 prism = float3(streak.r, gvCameraSample(inputTexture, uv - direction * 2.0).g, streak.b);
        result = mix(base, prism, controls.z);
        break;
    }
    case 25: { // Curl vector warp
        const float scale = mix(3.0, 28.0, controls.y);
        const float speed = mix(-2.4, 2.4, controls.z);
        const float phase = time * speed;
        const float2 field = float2(
            sin(uv.y * scale + phase) + cos(uv.x * scale * 0.63 - phase * 0.7),
            cos(uv.x * scale - phase) - sin(uv.y * scale * 0.71 + phase * 0.8)
        );
        const float audioLift = 1.0 + uniforms.audio.y * 1.8;
        result = gvCameraSample(inputTexture, uv + field * controls.x * 0.038 * audioLift);
        break;
    }
    case 26: { // Audio spectral refraction
        const float2 centered = uv - 0.5;
        const float radius = max(length(centered), 0.0001);
        const float2 radial = centered / radius;
        const float bands = floor(mix(5.0, 42.0, controls.y));
        const float band = floor(radius * bands);
        const float spectrum = mix(uniforms.audio.z, uniforms.audio.w, fract(band * 0.618));
        const float pulse = uniforms.audio.x + uniforms.audio.y * 1.4 + spectrum;
        const float shift = controls.x * pulse * (0.006 + 0.028 * sin(band + time * 2.0));
        const float3 refracted = float3(
            gvCameraSample(inputTexture, uv + radial * shift).r,
            gvCameraSample(inputTexture, uv - radial * shift * 0.42).g,
            gvCameraSample(inputTexture, uv - radial * shift).b
        );
        result = mix(base, refracted, controls.z);
        break;
    }
    case 27: { // Audio scan bend
        const float lines = floor(mix(60.0, 520.0, controls.y));
        const float line = floor(uv.y * lines);
        const float energy = uniforms.audio.y * 1.4 + uniforms.audio.x * 0.6;
        const float bend = sin(line * 0.37 + time * 3.1) * energy * controls.x * 0.06;
        const float3 bent = gvCameraSample(inputTexture, uv + float2(bend, 0.0));
        const float rule = 0.5 + 0.5 * sin(uv.y * lines * 3.14159265);
        result = mix(base, bent * (1.0 - 0.22 * rule * saturate(energy)), controls.z);
        break;
    }
    case 28: { // Audio chroma pulse
        // Transient energy separates the channels; silence leaves the frame clean.
        const float attack = pow(saturate(uniforms.audio.x * mix(1.0, 3.2, controls.y)), 1.6);
        const float2 direction = float2(cos(time * 0.7), sin(time * 0.53));
        const float2 offset = direction * attack * controls.x * 0.035;
        const float3 pulsed = float3(
            gvCameraSample(inputTexture, uv + offset).r,
            base.g,
            gvCameraSample(inputTexture, uv - offset).b
        );
        result = mix(base, pulsed, controls.z);
        break;
    }
    case 29: { // Audio waveform trace
        const float bands = 4.0;
        const float band = floor(uv.x * bands);
        const float level = band < 1.0
            ? uniforms.audio.y
            : band < 2.0 ? uniforms.audio.z : band < 3.0 ? uniforms.audio.w : uniforms.audio.x;
        const float height = mix(0.04, 0.42, controls.x) * level;
        const float baseline = 1.0 - mix(0.06, 0.34, controls.y);
        const float trace = 1.0 - smoothstep(0.0, 0.006, abs(uv.y - (baseline - height)));
        const float fill = step(baseline - height, uv.y) * step(uv.y, baseline) * 0.22;
        result = mix(base, saturate(base + float3(0.62, 0.30, 1.0) * (trace + fill)), controls.z);
        break;
    }
    case 30: { // Audio band slice
        const float slices = floor(mix(4.0, 40.0, controls.y));
        const float slice = floor(uv.y * slices);
        const float selector = fract(slice * 0.6180339);
        const float level = selector < 0.33
            ? uniforms.audio.y
            : selector < 0.66 ? uniforms.audio.z : uniforms.audio.w;
        const float direction = fmod(slice, 2.0) < 1.0 ? 1.0 : -1.0;
        const float2 slicedUV = float2(fract(uv.x + direction * level * controls.x * 0.24), uv.y);
        const float3 sliced = gvCameraSample(inputTexture, slicedUV);
        result = mix(base, sliced, controls.z * saturate(level * 2.2));
        break;
    }
    case 31: { // Water - touch-rippled surface
        const float2 touchPosition = uniforms.touch.w > 0.5 ? uniforms.touch.xy : float2(0.5);
        const float amplitude = mix(0.004, 0.085, controls.x) * (1.0 + uniforms.audio.y * 0.5);
        const float frequency = mix(6.0, 58.0, controls.y);
        const float speed = mix(-3.0, 3.0, controls.z);
        const float2 delta = uv - touchPosition;
        const float radius = max(length(delta), 0.0001);
        const float2 direction = delta / radius;
        // Secondary harmonic at an incommensurate ratio: two wave trains
        // interfering read as chop on the surface, where a single sinusoid
        // reads as one machined groove.
        const float fingerWave = (
            sin(radius * frequency - time * speed) +
            0.35 * sin(radius * frequency * 2.19 - time * speed * 1.47)
        ) * amplitude;
        float displacement = fingerWave;
        if (uniforms.touchImpact.w > 0.5) {
            const float2 impactDelta = uv - uniforms.touchImpact.xy;
            const float impactRadius = max(length(impactDelta), 0.0001);
            const float ringPhase = impactRadius * frequency * 1.5 - uniforms.touchImpact.z * speed * 2.2;
            displacement += (
                sin(ringPhase) +
                0.28 * sin(ringPhase * 2.31)
            ) * amplitude * 1.9 *
                exp(-impactRadius * 3.2) * exp(-uniforms.touchImpact.z * 1.7);
        }
        // Tracked blobs stir the surface like objects dropped in the water.
        for (int i = 0; i < 4; i++) {
            if (uniforms.blobs[i].w > 0.5) {
                const float2 blobDelta = uv - uniforms.blobs[i].xy;
                const float blobRadius = max(length(blobDelta), 0.0001);
                displacement += sin(blobRadius * frequency * 1.5 - time * speed * 1.6) *
                    amplitude * 1.6 * uniforms.blobs[i].z * exp(-blobRadius * 3.0);
            }
        }
        const float velocityStir = saturate(uniforms.touch.z) * 0.12;
        const float2 shear = float2(
            sin(uv.y * 13.0 + time * 1.7),
            cos(uv.x * 11.0 - time * 1.3)
        ) * (0.003 + velocityStir);
        result = gvCameraSample(inputTexture, uv + direction * displacement + shear);
        break;
    }
    case 32: { // Touch warp - finger gravity lens
        const float2 touchPosition = uniforms.touch.w > 0.5 ? uniforms.touch.xy : float2(0.5);
        const float pull = mix(-0.7, 0.85, controls.x);
        const float radius = mix(0.08, 0.62, controls.y);
        const float2 delta = uv - touchPosition;
        const float distanceValue = length(delta);
        const float falloff = 1.0 - smoothstep(0.0, radius, distanceValue);
        const float2 direction = distanceValue > 0.0001 ? delta / distanceValue : float2(0.0);
        const float velocity = saturate(uniforms.touch.z) * 0.85;
        const float turbulence = sin(distanceValue * 92.0 - time * 6.0) * 0.14 * velocity;
        const float2 warped = uv + direction * (pull * falloff * (0.10 + turbulence) + velocity * falloff * 0.05);
        result = mix(base, gvCameraSample(inputTexture, warped), controls.z);
        break;
    }
    case 33: { // Hatch - engraved crosshatch
        const float scale = mix(36.0, 300.0, controls.x);
        const float luma = gvCameraLuma(base);
        const float level = 1.0 - smoothstep(mix(0.06, 0.88, controls.y), 0.97, luma);
        const float angle = (controls.y - 0.5) * 0.7;
        const float2 first = gvCameraRotate(float2(position), angle);
        const float2 second = gvCameraRotate(float2(position), angle + 1.5707963);
        const float hatch = step(fract(first.x / scale), 0.055) + step(fract(first.y / scale), 0.055) +
            step(fract(second.x / scale), 0.045);
        const float ink = 1.0 - hatch * level * mix(0.30, 1.0, controls.z);
        const float3 engraved = base * ink + float3(0.94, 0.88, 1.0) * (1.0 - ink) * 0.16;
        result = mix(base, engraved, controls.z);
        break;
    }
    case 34: { // Phosphor - hot bloom accumulation
        const float threshold = mix(0.16, 0.74, controls.y);
        const float luma = gvCameraLuma(base);
        const float hot = smoothstep(threshold, threshold + 0.20, luma) * mix(0.45, 2.2, controls.x);
        const float2 stepSize = texel * mix(1.0, 6.0, controls.x);
        const float weights[4] = { 0.40, 0.28, 0.19, 0.13 };
        float3 bloom = float3(0.0);
        for (uint index = 1; index <= 4; ++index) {
            const float weight = weights[index - 1];
            bloom += gvCameraSample(inputTexture, uv + float2(stepSize.x * float(index), 0.0)) * weight;
            bloom += gvCameraSample(inputTexture, uv - float2(stepSize.x * float(index), 0.0)) * weight;
            bloom += gvCameraSample(inputTexture, uv + float2(0.0, stepSize.y * float(index))) * weight;
            bloom += gvCameraSample(inputTexture, uv - float2(0.0, stepSize.y * float(index))) * weight;
        }
        const float3 violet = float3(0.55, 0.24, 1.0);
        const float3 glowed = saturate(base + bloom * hot * 0.5) + violet * hot * 0.10;
        result = mix(base, glowed, controls.z);
        break;
    }
    case 35: { // Voronoi - cell fracture field
        const float cells = mix(8.0, 60.0, controls.x);
        const float drift = floor(time * mix(0.1, 1.1, controls.z));
        const float2 cell = floor(uv * cells);
        const float2 local = fract(uv * cells);
        float bestDistance = 8.0;
        float2 bestCell = float2(0.0);
        for (int y = -1; y <= 1; ++y) {
            for (int x = -1; x <= 1; ++x) {
                const float2 neighbor = cell + float2(float(x), float(y));
                const float2 jitter = float2(
                    gvCameraHash(neighbor + float2(drift, 0.0)),
                    gvCameraHash(neighbor + float2(0.0, drift))
                ) - 0.5;
                const float2 toCenter = (local - float2(float(x), float(y))) - jitter;
                const float distanceValue = dot(toCenter, toCenter);
                if (distanceValue < bestDistance) {
                    bestDistance = distanceValue;
                    bestCell = neighbor;
                }
            }
        }
        const float edge = smoothstep(0.0, mix(0.03, 0.22, controls.y), bestDistance);
        const float3 cellColor = gvCameraSample(inputTexture, (bestCell + 0.5) / cells);
        const float3 fractured = mix(base, cellColor, 0.80) * (0.70 + edge * 0.55);
        const float cellGlow = (1.0 - edge) * mix(0.0, 0.65, controls.y);
        result = mix(base, fractured + float3(0.45, 0.18, 1.0) * cellGlow, controls.z);
        break;
    }
    case 36: { // Hologram - interference projection
        const float lineFrequency = mix(140.0, 640.0, controls.y);
        const float scanline = 0.5 + 0.5 * sin(uv.y * lineFrequency);
        const float fringe = 0.5 + 0.5 * sin(uv.x * lineFrequency * 0.62 + time * 4.0);
        const float interference = 0.5 + 0.5 * sin(
            dot(uv, float2(9.0, 7.0)) * mix(20.0, 120.0, controls.x) + time * mix(0.5, 3.0, controls.z)
        );
        const float3 shift = float3(interference * 0.05, interference * 0.035, -interference * 0.055) *
            (controls.x - 0.5) * 0.9;
        const float3 projected = float3(
            gvCameraSample(inputTexture, uv + float2(shift.x, 0.0)).r,
            gvCameraSample(inputTexture, uv + float2(shift.y, 0.0)).g,
            gvCameraSample(inputTexture, uv + float2(shift.z, 0.0)).b
        );
        const float3 holographic = projected * (0.70 + scanline * 0.46) +
            float3(0.22, 0.55, 1.0) * fringe * 0.13;
        result = mix(base, holographic, controls.z * (0.65 + interference * 0.35));
        break;
    }
    // MARK: OPTICS 37-46

    case 37: { // Chromatic aberration - radial lens dispersion
        const float2 centered = uv - 0.5;
        const float radius = length(centered);
        const float strength = mix(0.0, 0.045, controls.x) * pow(radius, mix(1.0, 3.2, controls.y));
        result = gvChromaSplit(inputTexture, uv, centered * strength);
        result = mix(base, result, controls.z);
        break;
    }
    case 38: { // Anamorphic flare - horizontal streak off highlights
        const float threshold = mix(0.55, 0.95, controls.y);
        float3 streak = float3(0.0);
        const float length_ = mix(0.02, 0.22, controls.x);
        for (int i = 1; i <= 8; i++) {
            const float t = float(i) / 8.0;
            const float2 offset = float2(length_ * t, 0.0);
            const float3 left = gvCameraSample(inputTexture, uv - offset);
            const float3 right = gvCameraSample(inputTexture, uv + offset);
            const float weight = (1.0 - t) * 0.25;
            streak += max(left - threshold, 0.0) * weight;
            streak += max(right - threshold, 0.0) * weight;
        }
        result = base + streak * float3(0.35, 0.55, 1.0) * mix(1.0, 4.0, controls.z);
        break;
    }
    case 39: { // Bokeh - depth-of-field style disc blur outside the focal band
        const float focus = controls.y;
        const float distance = abs(gvCameraLuma(base) - focus);
        const float2 radius = texel * mix(1.0, 26.0, controls.x) * smoothstep(0.0, 0.5, distance);
        result = mix(base, gvBlur(inputTexture, uv, radius), controls.z);
        break;
    }
    case 40: { // Tilt-shift - sharp horizontal band, blurred above and below
        const float band = abs(uv.y - mix(0.25, 0.75, controls.y));
        const float falloff = smoothstep(mix(0.04, 0.3, controls.z), 0.5, band);
        const float2 radius = texel * mix(1.0, 22.0, controls.x) * falloff;
        result = gvBlur(inputTexture, uv, radius);
        // Tilt-shift reads as miniature partly because of the saturation lift.
        result = mix(gvCameraLuma(result), result, 1.28);
        break;
    }
    case 41: { // Fisheye - strong barrel projection
        const float2 centered = (uv - 0.5) * 2.0;
        const float radius = length(centered);
        const float amount = mix(0.0, 1.1, controls.x);
        const float scale = 1.0 / (1.0 + amount);
        const float2 warped = centered * (1.0 + amount * radius * radius) * scale;
        const float2 sampleUV = warped * 0.5 + 0.5;
        result = radius > mix(1.6, 1.05, controls.y)
            ? float3(0.0)
            : gvCameraSample(inputTexture, sampleUV);
        result = mix(base, result, controls.z);
        break;
    }
    case 42: { // Lens dirt - static smudge field lit by scene highlights
        const float2 field = uv * mix(3.0, 14.0, controls.y);
        const float smudge = pow(gvFbm(field), 3.0) * 4.0;
        const float3 bloom = gvBlur(inputTexture, uv, texel * 18.0);
        const float highlight = saturate(gvCameraLuma(bloom) - 0.45) * 2.0;
        result = base + smudge * highlight * controls.x * float3(0.9, 0.92, 1.0) * 1.6;
        result = mix(base, result, controls.z);
        break;
    }
    case 43: { // Light leak - drifting warm gradient bleeding from an edge
        const float phase = time * mix(0.05, 0.6, controls.y);
        const float edge = fract(phase);
        const float2 axis = float2(cos(phase * 2.3), sin(phase * 1.7));
        const float projection = dot(uv - 0.5, normalize(axis)) + 0.5;
        const float leak = pow(saturate(1.0 - abs(projection - edge) * mix(6.0, 1.6, controls.x)), 2.2);
        const float3 warm = float3(1.0, 0.44, 0.16);
        result = base + warm * leak * controls.z * 1.5;
        break;
    }
    case 44: { // Star filter - cross diffraction spikes on speculars
        const float threshold = mix(0.6, 0.95, controls.y);
        float3 spikes = float3(0.0);
        const float reach = mix(0.01, 0.14, controls.x);
        for (int i = 1; i <= 6; i++) {
            const float t = float(i) / 6.0;
            const float weight = (1.0 - t) * 0.3;
            const float2 h = float2(reach * t, 0.0);
            const float2 v = float2(0.0, reach * t);
            spikes += max(gvCameraSample(inputTexture, uv + h) - threshold, 0.0) * weight;
            spikes += max(gvCameraSample(inputTexture, uv - h) - threshold, 0.0) * weight;
            spikes += max(gvCameraSample(inputTexture, uv + v) - threshold, 0.0) * weight;
            spikes += max(gvCameraSample(inputTexture, uv - v) - threshold, 0.0) * weight;
        }
        result = base + spikes * mix(1.0, 5.0, controls.z);
        break;
    }
    case 45: { // Barrel / pincushion - signed geometric distortion
        const float2 centered = (uv - 0.5) * 2.0;
        const float radius2 = dot(centered, centered);
        // controls.x below 0.5 pincushions, above 0.5 barrels.
        const float amount = (controls.x - 0.5) * mix(0.2, 1.4, controls.y);
        const float2 warped = centered * (1.0 + amount * radius2);
        result = gvCameraSample(inputTexture, warped * 0.5 + 0.5);
        result = mix(base, result, controls.z);
        break;
    }
    case 46: { // Soft focus - bloom-veiled diffusion, classic portrait filter
        const float3 veil = gvBlur(inputTexture, uv, texel * mix(2.0, 24.0, controls.x));
        const float3 lifted = max(veil - mix(0.1, 0.6, controls.y), 0.0);
        result = base + lifted * controls.z * 1.8;
        break;
    }

    // MARK: ANALOG 47-56

    case 47: { // Halation - red-biased glow bleeding out of highlights
        const float3 bloom = gvBlur(inputTexture, uv, texel * mix(4.0, 30.0, controls.x));
        const float3 hot = max(bloom - mix(0.4, 0.8, controls.y), 0.0);
        result = base + hot * float3(1.0, 0.32, 0.16) * controls.z * 3.0;
        break;
    }
    case 48: { // VHS tracking - drifting misaligned band with head noise
        const float bandPosition = fract(time * mix(0.02, 0.5, controls.y));
        const float distance = abs(uv.y - bandPosition);
        const float band = smoothstep(mix(0.14, 0.02, controls.x), 0.0, distance);
        const float jitter = (gvCameraHash(float2(floor(uv.y * 220.0), floor(time * 24.0))) - 0.5);
        float2 sampleUV = uv;
        sampleUV.x += jitter * band * mix(0.02, 0.16, controls.x);
        result = gvChromaSplit(inputTexture, sampleUV, float2(band * 0.008, 0.0));
        result += band * gvCameraHash(uv * 900.0 + time) * 0.22;
        result = mix(base, result, controls.z);
        break;
    }
    case 49: { // Super 8 - gate weave, warm stock and edge falloff
        const float weaveX = (gvNoise(float2(time * 2.6, 0.0)) - 0.5) * mix(0.0, 0.02, controls.x);
        const float weaveY = (gvNoise(float2(0.0, time * 2.1)) - 0.5) * mix(0.0, 0.02, controls.x);
        float3 stock = gvCameraSample(inputTexture, uv + float2(weaveX, weaveY));
        stock *= float3(1.08, 0.98, 0.86);
        const float grain = gvCameraHash(uv * 1400.0 + time * 60.0) - 0.5;
        stock += grain * mix(0.0, 0.22, controls.y);
        const float vignette = 1.0 - smoothstep(0.32, 0.86, length(uv - 0.5));
        result = mix(base, stock * mix(1.0, vignette, 0.85), controls.z);
        break;
    }
    case 50: { // Chroma bleed - luma stays sharp, colour smears sideways
        const float3 hsvBase = gvCameraRGBToHSV(base);
        const float reach = mix(0.002, 0.05, controls.x);
        float3 chroma = float3(0.0);
        for (int i = 0; i < 5; i++) {
            const float3 tap = gvCameraSample(inputTexture, uv - float2(reach * float(i) / 4.0, 0.0));
            chroma += gvCameraRGBToHSV(tap) * 0.2;
        }
        const float3 bled = gvCameraHSVToRGB(float3(chroma.x, chroma.y * mix(1.0, 1.9, controls.y), hsvBase.z));
        result = mix(base, bled, controls.z);
        break;
    }
    case 51: { // Tape warp - wow and flutter bending the raster vertically
        const float wow = sin(time * mix(0.4, 3.0, controls.y) + uv.y * 5.0);
        const float flutter = gvNoise(float2(uv.y * 40.0, time * 8.0)) - 0.5;
        const float bend = (wow * 0.6 + flutter * 0.4) * mix(0.0, 0.06, controls.x);
        result = gvCameraSample(inputTexture, float2(uv.x + bend, uv.y));
        result = mix(base, result, controls.z);
        break;
    }
    case 52: { // Dropout - tape hits punching bright/dead scanline runs
        const float row = floor(uv.y * mix(60.0, 400.0, controls.y));
        const float seed = gvCameraHash(float2(row, floor(time * mix(2.0, 20.0, controls.x))));
        const bool dead = seed > mix(0.995, 0.86, controls.x);
        if (dead) {
            const float polarity = gvCameraHash(float2(row, 3.7)) > 0.5 ? 1.0 : 0.0;
            result = mix(base, float3(polarity), controls.z);
        }
        break;
    }
    case 53: { // Colour bar tear - SMPTE bars punched through torn rows
        const float row = floor(uv.y * mix(20.0, 120.0, controls.y));
        const float torn = gvCameraHash(float2(row, floor(time * 6.0)));
        if (torn > mix(0.99, 0.72, controls.x)) {
            const int bar = int(uv.x * 7.0);
            const float3 bars[7] = {
                float3(0.75), float3(0.75, 0.75, 0.0), float3(0.0, 0.75, 0.75),
                float3(0.0, 0.75, 0.0), float3(0.75, 0.0, 0.75), float3(0.75, 0.0, 0.0),
                float3(0.0, 0.0, 0.75)
            };
            result = mix(base, bars[clamp(bar, 0, 6)], controls.z);
        }
        break;
    }
    case 54: { // Interlace - alternating fields sampled a step apart in y
        const float field = fmod(floor(uv.y * size.y), 2.0);
        const float offset = mix(0.0, 0.01, controls.x) * (field * 2.0 - 1.0);
        float3 woven = gvCameraSample(inputTexture, uv + float2(offset, 0.0));
        woven *= mix(1.0, field > 0.5 ? 1.12 : 0.84, controls.y);
        result = mix(base, woven, controls.z);
        break;
    }
    case 55: { // Degauss - CRT power-on colour warp rippling from centre
        const float2 centered = uv - 0.5;
        const float radius = length(centered);
        const float pulse = exp(-fract(time * mix(0.1, 0.8, controls.y)) * 4.0);
        const float wave = sin(radius * 40.0 - time * 12.0) * pulse * mix(0.0, 0.06, controls.x);
        const float2 direction = radius > 0.0001 ? centered / radius : float2(0.0);
        result = gvChromaSplit(inputTexture, uv + direction * wave, direction * wave * 1.8);
        result = mix(base, result, controls.z);
        break;
    }
    case 56: { // Print-through - a ghost of the frame offset like bled tape
        const float2 ghostOffset = float2(mix(0.0, 0.09, controls.x), mix(-0.04, 0.04, controls.y));
        const float3 ghost = gvCameraSample(inputTexture, uv + ghostOffset);
        result = mix(base, max(base, ghost * 0.62), controls.z);
        break;
    }

    // MARK: GEOMETRY 57-66

    case 57: { // Polar warp - rectangular image mapped into angle/radius space
        const float2 centered = uv - 0.5;
        const float angle = atan2(centered.y, centered.x);
        const float radius = length(centered) * 2.0;
        const float2 polar = float2(
            fract(angle / (2.0 * M_PI_F) * mix(1.0, 6.0, controls.y) + time * 0.05 * controls.z),
            pow(saturate(radius), mix(0.4, 2.4, controls.x))
        );
        result = gvCameraSample(inputTexture, polar);
        break;
    }
    case 58: { // Twirl - rotation falling off with radius, anchored to touch
        const float2 anchor = uniforms.touch.w > 0.5 ? uniforms.touch.xy : float2(0.5);
        const float2 centered = uv - anchor;
        const float radius = length(centered);
        const float reach = mix(0.08, 0.7, controls.y);
        const float falloff = saturate(1.0 - radius / reach);
        const float angle = falloff * falloff * mix(-8.0, 8.0, controls.x) + time * 0.2 * controls.z;
        result = gvCameraSample(inputTexture, anchor + gvCameraRotate(centered, angle));
        break;
    }
    case 59: { // Hex tile - image resampled onto a hexagonal lattice
        const float scale = mix(8.0, 90.0, controls.x);
        float2 p = uv * scale;
        p.x *= 1.1547;
        const float2 a = floor(p) + 0.5;
        const float2 b = floor(p + float2(0.5, 0.5)) ;
        const float2 nearest = length(p - a) < length(p - b) ? a : b;
        float2 cellUV = nearest;
        cellUV.x /= 1.1547;
        result = gvCameraSample(inputTexture, cellUV / scale);
        const float border = smoothstep(0.42, 0.5, length(p - nearest));
        result = mix(result, result * 0.35, border * controls.y);
        result = mix(base, result, controls.z);
        break;
    }
    case 60: { // Shatter - image broken into cells that slide apart
        const float2 cell = gvWorley(uv * mix(4.0, 30.0, controls.y));
        const float2 seedPoint = floor(uv * mix(4.0, 30.0, controls.y));
        const float2 drift = float2(
            gvCameraHash(seedPoint) - 0.5,
            gvCameraHash(seedPoint + 11.3) - 0.5
        ) * mix(0.0, 0.2, controls.x);
        result = gvCameraSample(inputTexture, uv + drift);
        // Darken the seams so the fracture reads as separation, not blur.
        result *= smoothstep(0.0, 0.06, cell.y - cell.x);
        result = mix(base, result, controls.z);
        break;
    }
    case 61: { // Six-fold kaleidoscope
        const float2 centered = uv - 0.5;
        float angle = atan2(centered.y, centered.x) + time * 0.1 * (controls.z - 0.5);
        const float radius = length(centered);
        const float segment = M_PI_F / 3.0;
        angle = abs(fmod(angle, segment * 2.0) - segment);
        const float2 folded = float2(cos(angle), sin(angle)) * radius * mix(0.6, 1.8, controls.y);
        result = gvCameraSample(inputTexture, folded + 0.5);
        result = mix(base, result, controls.x);
        break;
    }
    case 62: { // Quad mirror - four-way symmetry about the centre
        float2 folded = abs(uv - 0.5) * mix(0.7, 2.0, controls.y);
        folded = 0.5 + folded * (controls.x > 0.5 ? 1.0 : -1.0);
        result = gvCameraSample(inputTexture, fract(folded));
        result = mix(base, result, controls.z);
        break;
    }
    case 63: { // Spiral warp - angular offset scaling with log radius
        const float2 centered = uv - 0.5;
        const float radius = max(length(centered), 0.0001);
        const float angle = log(radius) * mix(0.0, 6.0, controls.x) + time * 0.3 * (controls.z - 0.5);
        result = gvCameraSample(inputTexture, 0.5 + gvCameraRotate(centered, angle));
        result = mix(base, result, controls.y);
        break;
    }
    case 64: { // Shear stack - horizontal bands slid by band index
        const float bands = mix(3.0, 48.0, controls.y);
        const float index = floor(uv.y * bands);
        const float shear = (gvCameraHash(float2(index, 1.0)) - 0.5) * mix(0.0, 0.4, controls.x);
        result = gvCameraSample(inputTexture, float2(fract(uv.x + shear), uv.y));
        result = mix(base, result, controls.z);
        break;
    }
    case 65: { // Lens array - a grid of miniature fisheye lenslets
        const float pitch = mix(4.0, 40.0, controls.y);
        const float2 cell = floor(uv * pitch);
        const float2 local = fract(uv * pitch) - 0.5;
        const float radius = length(local) * 2.0;
        const float2 warped = local * (1.0 + mix(0.0, 1.6, controls.x) * radius * radius);
        result = gvCameraSample(inputTexture, (cell + warped + 0.5) / pitch);
        result = mix(base, result, controls.z);
        break;
    }
    case 66: { // Fold - repeated reflection about a rotating axis
        float2 p = uv - 0.5;
        const float angle = time * 0.15 * controls.z;
        for (int i = 0; i < 3; i++) {
            p = gvCameraRotate(p, angle + float(i) * 0.7);
            p.x = abs(p.x) - mix(0.0, 0.22, controls.x);
        }
        result = gvCameraSample(inputTexture, fract(p * mix(0.8, 2.0, controls.y) + 0.5));
        break;
    }

    // MARK: FIELD 67-76

    case 67: { // Flow field - image advected along a noise vector field
        const float2 gradient = gvFbmGradient(uv * mix(2.0, 12.0, controls.y) + time * 0.1, 0.01);
        const float2 flow = float2(-gradient.y, gradient.x);
        result = gvCameraSample(inputTexture, uv + flow * mix(0.0, 0.09, controls.x));
        result = mix(base, result, controls.z);
        break;
    }
    case 68: { // Curl warp - divergence-free swirl, no pooling artefacts
        const float scale = mix(2.0, 16.0, controls.y);
        const float2 g1 = gvFbmGradient(uv * scale + time * 0.07, 0.008);
        const float2 g2 = gvFbmGradient(uv * scale * 1.7 - time * 0.05, 0.008);
        const float2 curl = float2(g1.y - g2.x, g2.y - g1.x);
        result = gvCameraSample(inputTexture, uv + curl * mix(0.0, 0.07, controls.x));
        result = mix(base, result, controls.z);
        break;
    }
    case 69: { // Worley cracks - cell borders etched into the image
        const float2 cell = gvWorley(uv * mix(5.0, 50.0, controls.y));
        const float crack = 1.0 - smoothstep(0.0, mix(0.02, 0.14, controls.x), cell.y - cell.x);
        result = mix(base, base * 0.1 + float3(0.35, 0.12, 0.6) * crack * 0.5, crack * controls.z);
        break;
    }
    case 70: { // Plasma - classic interference field modulating the frame
        const float scale = mix(2.0, 20.0, controls.y);
        const float plasma =
            sin(uv.x * scale + time) +
            sin(uv.y * scale * 1.3 - time * 0.8) +
            sin((uv.x + uv.y) * scale * 0.7 + time * 1.4) +
            sin(length(uv - 0.5) * scale * 2.0 - time * 1.1);
        const float3 tint = 0.5 + 0.5 * cos(plasma + float3(0.0, 2.1, 4.2));
        result = mix(base, base * tint * 1.6, controls.x * controls.z);
        break;
    }
    case 71: { // Contour lines - iso-luminance banding, like a topo map
        const float levels = mix(4.0, 40.0, controls.y);
        const float luma = gvCameraLuma(base);
        const float band = fract(luma * levels);
        const float line = 1.0 - smoothstep(0.0, mix(0.06, 0.4, controls.x), min(band, 1.0 - band));
        result = mix(base, mix(base * 0.2, float3(0.62, 0.35, 1.0), line), controls.z);
        break;
    }
    case 72: { // Topography - luminance read as height, shaded by its slope
        const float2 stepUV = texel * mix(1.0, 6.0, controls.y);
        const float lx = gvCameraLuma(gvCameraSample(inputTexture, uv + float2(stepUV.x, 0.0))) -
            gvCameraLuma(gvCameraSample(inputTexture, uv - float2(stepUV.x, 0.0)));
        const float ly = gvCameraLuma(gvCameraSample(inputTexture, uv + float2(0.0, stepUV.y))) -
            gvCameraLuma(gvCameraSample(inputTexture, uv - float2(0.0, stepUV.y)));
        const float3 normal = normalize(float3(-lx * mix(1.0, 14.0, controls.x), -ly * mix(1.0, 14.0, controls.x), 1.0));
        const float3 lightDirection = normalize(float3(cos(time * 0.4), sin(time * 0.4), 0.8));
        const float shade = saturate(dot(normal, lightDirection));
        result = mix(base, base * (0.25 + shade * 1.5), controls.z);
        break;
    }
    case 73: { // Gradient map - luminance remapped through a violet ramp
        const float luma = pow(gvCameraLuma(base), mix(0.4, 2.4, controls.y));
        const float3 shadow = float3(0.02, 0.01, 0.10);
        const float3 midtone = float3(0.42, 0.08, 0.78);
        const float3 highlight = float3(1.0, 0.86, 0.62);
        float3 mapped = mix(shadow, midtone, smoothstep(0.0, 0.55, luma));
        mapped = mix(mapped, highlight, smoothstep(0.5, 1.0, luma));
        result = mix(base, mapped, controls.x * controls.z);
        break;
    }
    case 74: { // False colour - exposure analysis palette
        const float luma = gvCameraLuma(base);
        const float scaled = saturate((luma - (controls.y - 0.5) * 0.5) * mix(0.6, 2.4, controls.x));
        float3 mapped;
        if (scaled < 0.25) {
            mapped = mix(float3(0.0, 0.0, 0.6), float3(0.0, 0.7, 0.9), scaled / 0.25);
        } else if (scaled < 0.5) {
            mapped = mix(float3(0.0, 0.7, 0.9), float3(0.1, 0.9, 0.1), (scaled - 0.25) / 0.25);
        } else if (scaled < 0.75) {
            mapped = mix(float3(0.1, 0.9, 0.1), float3(1.0, 0.85, 0.0), (scaled - 0.5) / 0.25);
        } else {
            mapped = mix(float3(1.0, 0.85, 0.0), float3(1.0, 0.0, 0.0), (scaled - 0.75) / 0.25);
        }
        result = mix(base, mapped, controls.z);
        break;
    }
    case 75: { // Edge glow - Sobel edges re-lit as emissive lines
        const float2 stepUV = texel * mix(1.0, 5.0, controls.y);
        const float l = gvCameraLuma(gvCameraSample(inputTexture, uv - float2(stepUV.x, 0.0)));
        const float r = gvCameraLuma(gvCameraSample(inputTexture, uv + float2(stepUV.x, 0.0)));
        const float t = gvCameraLuma(gvCameraSample(inputTexture, uv - float2(0.0, stepUV.y)));
        const float b = gvCameraLuma(gvCameraSample(inputTexture, uv + float2(0.0, stepUV.y)));
        const float edge = saturate(length(float2(r - l, b - t)) * mix(2.0, 22.0, controls.x));
        result = base * 0.35 + float3(0.55, 0.25, 1.0) * edge * 1.8;
        result = mix(base, result, controls.z);
        break;
    }
    case 76: { // Reaction bands - two competing noise scales fighting
        const float scaleA = mix(3.0, 18.0, controls.y);
        const float a = gvFbm(uv * scaleA + time * 0.12);
        const float b = gvFbm(uv * scaleA * 2.3 - time * 0.09);
        const float reaction = saturate((a - b) * mix(1.0, 8.0, controls.x) + 0.5);
        const float banded = step(0.5, fract(reaction * 6.0));
        result = mix(base, base * (0.3 + banded * 1.4), controls.z);
        break;
    }

    // MARK: DECAY 77-81

    case 77: { // Pixel melt - columns sag downward, weighted by darkness
        const float column = floor(uv.x * mix(20.0, 400.0, controls.y));
        const float weight = 1.0 - gvCameraLuma(base);
        const float drip = gvCameraHash(float2(column, 0.0)) * weight;
        const float sag = drip * mix(0.0, 0.4, controls.x) * (0.5 + 0.5 * sin(time * 0.4 + column));
        result = gvCameraSample(inputTexture, float2(uv.x, saturate(uv.y - sag)));
        result = mix(base, result, controls.z);
        break;
    }
    case 78: { // Corrode - cellular pitting eating into the image
        const float2 cell = gvWorley(uv * mix(8.0, 60.0, controls.y) + time * 0.03);
        const float pit = smoothstep(mix(0.5, 0.05, controls.x), 0.0, cell.x);
        const float3 rust = float3(0.36, 0.14, 0.05);
        result = mix(base, mix(base * 0.25, rust, 0.6), pit * controls.z);
        break;
    }
    case 79: { // Burn-through - an advancing front that chars and holes out
        const float front = fract(time * mix(0.02, 0.35, controls.y));
        const float field = gvFbm(uv * mix(3.0, 14.0, controls.x) );
        const float burn = field - front * 1.6 + 0.4;
        if (burn < 0.0) {
            result = float3(0.0);
        } else if (burn < 0.12) {
            // Charred rim just inside the hole.
            const float rim = 1.0 - burn / 0.12;
            result = mix(base, mix(float3(0.9, 0.35, 0.05), float3(0.08, 0.02, 0.0), rim), controls.z);
        }
        break;
    }
    case 80: { // Ash drift - bright motes lifting off and blowing sideways
        const float2 drift = float2(time * mix(0.02, 0.3, controls.y), -time * 0.12);
        const float motes = pow(gvNoise(uv * mix(30.0, 200.0, controls.x) + drift * 20.0), 6.0) * 6.0;
        const float3 lifted = gvCameraSample(inputTexture, uv + drift * 0.05);
        result = mix(base, base * 0.7 + lifted * motes, controls.z);
        break;
    }
    case 81: { // Bit rot - progressive quantisation failure per channel
        const float depth = mix(8.0, 1.5, controls.x);
        const float2 blockUV = floor(uv * mix(40.0, 500.0, controls.y));
        const float corruptSeed = gvCameraHash(blockUV + floor(time * 3.0));
        float3 rotted = base;
        if (corruptSeed < controls.x * 0.7) {
            rotted = floor(base * depth + 0.5) / depth;
            // Channel-selective failure reads as data damage, not posterise.
            if (corruptSeed < controls.x * 0.25) { rotted.r = 1.0 - rotted.r; }
            if (corruptSeed > controls.x * 0.55) { rotted.b = fract(rotted.b * 3.0); }
        }
        result = mix(base, rotted, controls.z);
        break;
    }

    // MARK: SPECTRAL - audio as destructive energy, 82-91

    case 82: { // Audio macroblock - bass hits punch blocks out of the frame
        const float energy = uniforms.audio.y;
        const float blockSize = mix(60.0, 8.0, controls.y);
        const float2 blockUV = floor(uv * blockSize);
        const float seed = gvCameraHash(blockUV + floor(time * 8.0));
        // Only blocks below the bass energy are displaced, so quiet passages
        // leave the frame intact and a kick knocks a visible patch loose.
        const float punched = step(seed, energy * controls.x * 1.4);
        const float2 kick = float2(
            gvCameraHash(blockUV + 3.1) - 0.5,
            gvCameraHash(blockUV + 7.7) - 0.5
        ) * punched * energy * mix(0.02, 0.25, controls.x);
        result = gvCameraSample(inputTexture, uv + kick);
        result = mix(base, result, controls.z);
        break;
    }
    case 83: { // Audio fracture - transients split the RGB channels apart
        const float onset = uniforms.audioDynamics.y;
        const float2 axis = normalize(float2(
            gvCameraHash(float2(floor(time * 12.0), 1.0)) - 0.5,
            gvCameraHash(float2(floor(time * 12.0), 9.0)) - 0.5
        ) + 1e-4);
        const float2 offset = axis * onset * mix(0.005, 0.09, controls.x);
        result = gvChromaSplit(inputTexture, uv, offset);
        // A hard onset also tears a row band for a single frame.
        if (onset > mix(0.9, 0.25, controls.y)) {
            const float row = floor(uv.y * 90.0);
            const float tear = (gvCameraHash(float2(row, floor(time * 30.0))) - 0.5) * onset * 0.14;
            result = gvChromaSplit(inputTexture, uv + float2(tear, 0.0), offset);
        }
        result = mix(base, result, controls.z);
        break;
    }
    case 84: { // Audio stretch - sustained tones drag pixels into streaks
        const float held = uniforms.audioDynamics.z;
        const float direction = controls.y > 0.5 ? 1.0 : -1.0;
        float3 smear = float3(0.0);
        const float reach = held * mix(0.0, 0.3, controls.x);
        for (int i = 0; i < 6; i++) {
            const float t = float(i) / 5.0;
            smear += gvCameraSample(inputTexture, uv - float2(0.0, reach * t * direction)) / 6.0;
        }
        result = mix(base, smear, held * controls.z);
        break;
    }
    case 85: { // Audio repair - damage in sound, healing in silence
        const float quiet = uniforms.audioDynamics.w;
        const float energy = saturate(uniforms.audio.x * 1.4);
        // Damage scales with live energy and is subtracted as silence grows.
        const float damage = saturate(energy - quiet) * controls.x;
        const float2 blockUV = floor(uv * mix(30.0, 220.0, controls.y));
        const float seed = gvCameraHash(blockUV + floor(time * 6.0));
        float3 damaged = base;
        if (seed < damage) {
            damaged = gvCameraSample(inputTexture, uv + (float2(
                gvCameraHash(blockUV + 2.3),
                gvCameraHash(blockUV + 8.9)
            ) - 0.5) * damage * 0.2);
            damaged = floor(damaged * 3.0 + 0.5) / 3.0;
        }
        // Blur the repair back in so healing is gradual rather than a cut.
        result = mix(damaged, gvBlur(inputTexture, uv, texel * 1.5), quiet * 0.4);
        result = mix(base, result, controls.z);
        break;
    }
    case 86: { // Audio tunnel - spectrum drives a zooming corridor
        const float2 centered = uv - 0.5;
        const float pull = (uniforms.audio.y * 0.6 + uniforms.audio.z * 0.4) * mix(0.0, 0.5, controls.x);
        const float angle = uniforms.audio.w * mix(0.0, 2.0, controls.y) + time * 0.2;
        const float2 warped = gvCameraRotate(centered * (1.0 - pull), angle);
        result = gvCameraSample(inputTexture, warped + 0.5);
        result *= 1.0 + uniforms.audioDynamics.y * 0.9;
        result = mix(base, result, controls.z);
        break;
    }
    case 87: { // Audio kaleidoscope - segment count follows the treble band
        const float2 centered = uv - 0.5;
        const float segments = floor(mix(3.0, 14.0, controls.y * 0.5 + uniforms.audio.w * 0.5));
        const float segment = M_PI_F / max(segments, 1.0);
        float angle = atan2(centered.y, centered.x) + time * 0.1;
        angle = abs(fmod(angle, segment * 2.0) - segment);
        const float radius = length(centered) * (1.0 + uniforms.audio.y * controls.x);
        result = gvCameraSample(inputTexture, float2(cos(angle), sin(angle)) * radius + 0.5);
        result = mix(base, result, controls.z);
        break;
    }
    case 88: { // Audio grain - noise floor rising with level
        const float level = uniforms.audio.x;
        const float grain = gvCameraHash(uv * 1600.0 + time * 90.0) - 0.5;
        const float amount = level * mix(0.05, 0.8, controls.x);
        result = base + grain * amount;
        // Peaks bleach the frame briefly.
        result += uniforms.audioDynamics.x * controls.y * 0.25;
        result = mix(base, result, controls.z);
        break;
    }
    case 89: { // Audio displace - per-band vertical slices shifted apart
        const float slices = mix(4.0, 60.0, controls.y);
        const float index = floor(uv.x * slices);
        const float band = fmod(index, 3.0);
        const float energy = band < 1.0 ? uniforms.audio.y
            : (band < 2.0 ? uniforms.audio.z : uniforms.audio.w);
        const float shift = (gvCameraHash(float2(index, 1.0)) - 0.5) * energy * mix(0.0, 0.4, controls.x);
        result = gvCameraSample(inputTexture, float2(uv.x, fract(uv.y + shift)));
        result = mix(base, result, controls.z);
        break;
    }
    case 90: { // Audio posterize - quantisation collapsing as the mix gets loud
        const float level = saturate(uniforms.audio.x * 1.3);
        const float levels = mix(mix(24.0, 6.0, controls.y), 2.0, level * controls.x);
        float3 quantised = floor(base * levels + 0.5) / levels;
        quantised = mix(quantised, 1.0 - quantised, uniforms.audioDynamics.y * 0.5);
        result = mix(base, quantised, controls.z);
        break;
    }
    case 91: { // Spectral tint - bass, mid and treble drive R, G and B gain
        const float3 spectrum = float3(uniforms.audio.y, uniforms.audio.z, uniforms.audio.w);
        const float3 gain = 1.0 + (spectrum - 0.33) * mix(0.0, 3.0, controls.x);
        float3 tinted = base * gain;
        // Sustained energy pushes saturation, silence drains it.
        const float saturation = 1.0 + uniforms.audioDynamics.z * controls.y * 1.5 -
            uniforms.audioDynamics.w * 0.6;
        tinted = mix(float3(gvCameraLuma(tinted)), tinted, saturation);
        result = mix(base, tinted, controls.z);
        break;
    }
    case 92: { // Kuwahara - edge-preserving painterly quantisation
        // Four overlapping quadrants are averaged; the one with the lowest
        // variance wins. Because the winning region never straddles an edge,
        // flat areas flatten into brush strokes while edges stay hard - which
        // is the difference between this and a blur.
        //
        // The loop count is fixed at 4x4x4 and the *spacing* is what the
        // radius control moves. A growing loop would make the cost of this
        // effect a function of a slider, which the frame budget cannot plan
        // around.
        const float2 spread = texel * mix(0.7, 3.6, controls.x);
        float3 bestMean = base;
        float bestScore = 1e9;
        for (int quadrant = 0; quadrant < 4; quadrant++) {
            const float2 quadrantSign = float2(
                (quadrant & 1) != 0 ? 1.0 : -1.0,
                (quadrant & 2) != 0 ? 1.0 : -1.0
            );
            float3 sum = float3(0.0);
            float3 sumSquares = float3(0.0);
            for (int y = 0; y < 4; y++) {
                for (int x = 0; x < 4; x++) {
                    const float3 tap = gvCameraSample(
                        inputTexture,
                        uv + float2(float(x), float(y)) * quadrantSign * spread
                    );
                    sum += tap;
                    sumSquares += tap * tap;
                }
            }
            const float3 mean = sum * 0.0625;
            const float3 variance = sumSquares * 0.0625 - mean * mean;
            const float score = variance.r + variance.g + variance.b;
            if (score < bestScore) {
                bestScore = score;
                bestMean = mean;
            }
        }
        // Averaging drains contrast; this puts the stroke back.
        const float3 painted = saturate((bestMean - 0.5) * (1.0 + controls.y * 1.1) + 0.5);
        result = mix(base, painted, controls.z);
        break;
    }
    case 93: { // ASCII mosaic - luminance rendered as a character grid
        const float cellSize = mix(6.0, 34.0, controls.x);
        const float2 cellOrigin = floor(float2(position) / cellSize) * cellSize;
        const float2 cellUV = (cellOrigin + cellSize * 0.5) / size;
        const float3 cellColor = gvCameraSample(inputTexture, cellUV);
        // Gamma on the ramp, so the glyph ladder spends its levels where the
        // eye reads density rather than bunching them all in the highlights.
        const float density = pow(saturate(gvCameraLuma(cellColor)), mix(1.6, 0.6, controls.y));
        const int level = int(round(density * 8.0));
        const int2 glyphCell = int2(floor((float2(position) - cellOrigin) / cellSize * 5.0));
        const float ink = gvAsciiGlyph(level, glyphCell);
        // Terminal green when desaturated, the sampled colour when not, so the
        // same effect covers both the console look and a colour mosaic.
        // COLOUR crossfades between the console green and the sampled hue. It
        // must not also set presence: BLEND is the mix control on every other
        // effect, and having one slider mean both makes a full-colour mosaic
        // impossible to get at full strength.
        const float3 terminal = float3(0.62, 1.0, 0.72);
        const float3 glyphColor = mix(terminal, cellColor / max(gvCameraLuma(cellColor), 0.08), controls.z);
        result = glyphColor * ink * (0.35 + density * 0.9);
        break;
    }
    case 94: { // Frosted glass - per-cell refraction plus diffusion
        const float scale = mix(8.0, 120.0, controls.y);
        const float2 cell = floor(uv * scale) / scale;
        const float2 jitter = float2(
            gvCameraHash(cell * 37.0),
            gvCameraHash(cell * 91.0 + 13.0)
        ) - 0.5;
        const float roughness = mix(0.002, 0.055, controls.x);
        const float3 frosted = gvBlur(
            inputTexture,
            uv + jitter * roughness,
            texel * mix(0.6, 3.2, controls.x)
        );
        result = mix(base, frosted, controls.z);
        break;
    }
    case 95: { // DCT ringing - lossy codec block artefacts
        // Not a real transform. It reproduces what a viewer actually sees from
        // one: a block DC term, a coarsely quantised residual on top of it,
        // and mosquito ringing crowding the block boundary. Sits with the
        // datamosh family because it is the same failure at a different stage.
        const float blockSize = mix(4.0, 26.0, controls.y);
        const float2 blockOrigin = floor(float2(position) / blockSize) * blockSize;
        float3 dc = float3(0.0);
        for (int y = 0; y < 4; y++) {
            for (int x = 0; x < 4; x++) {
                const float2 tapUV =
                    (blockOrigin + (float2(float(x), float(y)) + 0.5) * blockSize * 0.25) / size;
                dc += gvCameraSample(inputTexture, tapUV);
            }
        }
        dc *= 0.0625;
        const float levels = mix(26.0, 2.0, controls.x);
        const float3 residual = floor((base - dc) * levels + 0.5) / levels;
        const float2 blockPhase = fract(float2(position) / blockSize) - 0.5;
        const float edge = smoothstep(0.30, 0.5, max(abs(blockPhase.x), abs(blockPhase.y)));
        const float ring = sin(length(residual) * 42.0 + time * 3.1) * edge * controls.x * 0.24;
        result = mix(base, saturate(dc + residual + ring), controls.z);
        break;
    }
    case 96: { // Domain warp - fbm displaced by its own fbm
        const float scale = mix(1.4, 9.0, controls.y);
        const float2 drift = float2(time * 0.07, time * -0.05);
        const float2 inner = float2(
            gvFbm(uv * scale + drift),
            gvFbm(uv * scale + drift + 5.2)
        );
        const float2 outer = float2(
            gvFbm(uv * scale + inner * 2.4 + 1.7),
            gvFbm(uv * scale + inner * 2.4 + 9.3)
        );
        const float amount = mix(0.004, 0.14, controls.x);
        result = gvCameraSample(inputTexture, uv + (outer - 0.5) * amount);
        result = mix(base, result, controls.z);
        break;
    }
    case 97: { // Blue-noise dither - palette quantisation on a spatial ramp
        // Interleaved gradient noise rather than a Bayer matrix: it has no
        // repeating grid, so the quantisation error scatters instead of
        // printing the 4x4 tile that ordered dithering leaves behind.
        const float pixelScale = mix(1.0, 5.0, controls.y);
        const float2 grid = floor(float2(position) / pixelScale);
        const float noise = fract(52.9829189 * fract(dot(grid, float2(0.06711056, 0.00583715))));
        const float levels = max(floor(mix(9.0, 2.0, controls.x)), 2.0);
        const float3 dithered = floor(base * (levels - 1.0) + noise) / (levels - 1.0);
        result = mix(base, saturate(dithered), controls.z);
        break;
    }
    case 98: { // Spectrum bars - sixteen live FFT bands drawn over the frame
        const float bars = floor(mix(8.0, 32.0, controls.y));
        const float column = floor(uv.x * bars);
        const float band = gvSpectrumAt(uniforms.spectrum, (column + 0.5) / bars);
        const float height = band * mix(0.25, 0.92, controls.x);
        const float gutter = smoothstep(0.0, 0.10, fract(uv.x * bars));
        const float lit = step(1.0 - uv.y, height) * gutter;
        // Cap line, so a bar reads as a level and not as a block of paint.
        const float cap = smoothstep(0.020, 0.0, abs((1.0 - uv.y) - height)) * gutter;
        const float3 low = float3(0.42, 0.86, 1.0);
        const float3 high = float3(1.0, 0.36, 0.52);
        const float3 barColor = mix(low, high, column / max(bars - 1.0, 1.0));
        const float3 drawn = base * (1.0 - lit * 0.55) + barColor * (lit * 0.55 + cap * 0.9);
        result = mix(base, drawn, controls.z);
        break;
    }
    case 99: { // Radial spectrum - the same bands wrapped into a ring
        const float2 centered = (uv - 0.5) * float2(size.x / max(size.y, 1.0), 1.0);
        const float radius = length(centered);
        const float angle = fract(atan2(centered.y, centered.x) / 6.2831853 + 0.5);
        // Mirrored so the ring reads symmetrically instead of tearing at the
        // seam where the highest band meets the lowest.
        const float folded = angle < 0.5 ? angle * 2.0 : (1.0 - angle) * 2.0;
        const float band = gvSpectrumAt(uniforms.spectrum, folded);
        const float inner = mix(0.10, 0.30, controls.y);
        const float reach = inner + band * mix(0.06, 0.34, controls.x);
        const float ring = smoothstep(reach, reach - 0.012, radius) * step(inner, radius);
        const float rim = smoothstep(0.010, 0.0, abs(radius - reach));
        const float3 ringColor = mix(float3(0.35, 0.95, 1.0), float3(1.0, 0.42, 0.30), band);
        const float3 drawn = base * (1.0 - ring * 0.45) + ringColor * (ring * 0.45 + rim);
        result = mix(base, drawn, controls.z);
        break;
    }
    case 100: { // Lissajous scope - audio drawn as an oscilloscope trace
        const float2 centered = (uv - 0.5) * float2(size.x / max(size.y, 1.0), 1.0);
        const float gain = mix(0.12, 0.42, controls.x);
        const float ratio = mix(1.0, 5.0, controls.y);
        // The curve is driven by the live bands, so its shape follows the
        // material rather than animating on a fixed clock.
        const float lowBand = gvSpectrumAt(uniforms.spectrum, 0.12);
        const float highBand = gvSpectrumAt(uniforms.spectrum, 0.78);
        float nearest = 1e9;
        for (int index = 0; index < 48; index++) {
            const float t = float(index) / 48.0 * 6.2831853;
            const float2 point = float2(
                sin(t * ratio + time * 1.3 + lowBand * 6.0),
                sin(t + time * 0.9 + highBand * 6.0)
            ) * gain * (0.45 + uniforms.audio.x * 1.4);
            nearest = min(nearest, distance(centered, point));
        }
        const float trace = smoothstep(0.006, 0.0, nearest);
        const float glow = smoothstep(0.045, 0.0, nearest) * 0.35;
        const float3 phosphor = float3(0.55, 1.0, 0.72);
        result = mix(base, base * 0.35 + phosphor * (trace + glow), controls.z);
        break;
    }
    case 101: { // Vectorscope - chroma of the frame plotted on a colour wheel
        // A real broadcast scope, gated to its own panel so the cost is paid
        // over a tenth of the frame instead of all of it.
        const float span = mix(0.20, 0.42, controls.y);
        const GVScopePanel panel = gvScopePanel(uv, float4(1.0 - span - 0.03, 0.03, span, span));
        if (!panel.inside) {
            result = base;
            break;
        }
        const float2 target = (panel.local - 0.5) * 2.0;
        const float targetRadius = length(target);
        if (targetRadius > 1.0) {
            result = mix(base, base * 0.25, controls.z);
            break;
        }
        // The frame is sampled at 64 points on an R2 low-discrepancy sequence
        // rather than at hashed positions: sin-hash clusters badly at low
        // counts and a scope that misses whole regions of the frame is
        // reporting something untrue. The set is shifted eight times a second
        // so the plot integrates over the image instead of measuring the same
        // sixty-four pixels forever - slow enough not to read as flicker.
        const float2 alpha = float2(0.7548776662, 0.5698402909);
        const float sweep = floor(time * 8.0) * 0.0173;
        float energy = 0.0;
        for (int index = 0; index < 64; index++) {
            const float2 site = fract(alpha * float(index) + sweep);
            const float3 tap = gvCameraSample(inputTexture, site);
            const float2 chroma = gvChromaCoordinate(tap);
            energy += smoothstep(0.09, 0.0, distance(chroma, target));
        }
        const float plot = saturate(energy * mix(0.10, 0.45, controls.x));
        // Graticule: the unit circle and the four axes a colourist reads.
        const float circle = smoothstep(0.020, 0.0, abs(targetRadius - 1.0));
        const float axes = smoothstep(0.010, 0.0, min(abs(target.x), abs(target.y)));
        const float3 wheel = gvCameraHSVToRGB(float3(
            fract(atan2(target.y, target.x) / 6.2831853),
            1.0,
            1.0
        ));
        const float3 drawn = float3(0.04) + wheel * plot + float3(0.30) * max(circle, axes * 0.45);
        result = mix(base, drawn, controls.z);
        break;
    }
    case 102: { // Waveform monitor - luma of each column plotted as a trace
        const float height = mix(0.16, 0.40, controls.y);
        const GVScopePanel panel = gvScopePanel(uv, float4(0.0, 1.0 - height, 1.0, height));
        if (!panel.inside) {
            result = base;
            break;
        }
        const float target = 1.0 - panel.local.y;
        float energy = 0.0;
        for (int index = 0; index < 32; index++) {
            const float sampleY = (float(index) + 0.5) / 32.0;
            const float luma = gvCameraLuma(gvCameraSample(inputTexture, float2(panel.local.x, sampleY)));
            energy += smoothstep(0.035, 0.0, abs(luma - target));
        }
        const float trace = saturate(energy * mix(0.06, 0.30, controls.x));
        // IRE graticule at 0 / 50 / 100, which is what the trace is measured
        // against; without it the panel is a shape rather than an instrument.
        const float grid = smoothstep(0.006, 0.0, min(min(target, abs(target - 0.5)), abs(target - 1.0)));
        const float3 drawn = float3(0.02, 0.03, 0.03) +
            float3(0.42, 1.0, 0.62) * trace +
            float3(0.22, 0.26, 0.24) * grid;
        result = mix(base, drawn, controls.z);
        break;
    }
    case 103: { // RGB parade - three waveform panels, one per channel
        const float height = mix(0.16, 0.40, controls.y);
        const GVScopePanel panel = gvScopePanel(uv, float4(0.0, 1.0 - height, 1.0, height));
        if (!panel.inside) {
            result = base;
            break;
        }
        const int lane = clamp(int(panel.local.x * 3.0), 0, 2);
        const float laneX = fract(panel.local.x * 3.0);
        const float target = 1.0 - panel.local.y;
        float energy = 0.0;
        for (int index = 0; index < 32; index++) {
            const float sampleY = (float(index) + 0.5) / 32.0;
            const float3 tap = gvCameraSample(inputTexture, float2(laneX, sampleY));
            const float channel = lane == 0 ? tap.r : (lane == 1 ? tap.g : tap.b);
            energy += smoothstep(0.035, 0.0, abs(channel - target));
        }
        const float trace = saturate(energy * mix(0.06, 0.30, controls.x));
        const float3 laneColor = lane == 0
            ? float3(1.0, 0.28, 0.28)
            : (lane == 1 ? float3(0.30, 1.0, 0.40) : float3(0.36, 0.52, 1.0));
        const float divider = smoothstep(0.008, 0.0, min(laneX, 1.0 - laneX));
        const float grid = smoothstep(0.006, 0.0, min(min(target, abs(target - 0.5)), abs(target - 1.0)));
        const float3 drawn = float3(0.02) +
            laneColor * trace +
            float3(0.20) * max(grid, divider * 0.8);
        result = mix(base, drawn, controls.z);
        break;
    }
    // MARK: SHADERS 104-139
    //
    // These are scenes, not renamed grades. Each arm has its own geometry,
    // palette and motion response while retaining enough of the camera to stay
    // useful in a live Composition. Audio enters the construction rather than
    // merely changing final opacity; touch is both directly spatial and fed
    // through the universal control modulation above.
    case 104: { // Cyber grid - perspective floor and horizon city
        const float2 anchor = uniforms.touch.w > 0.5 ? uniforms.touch.xy : float2(0.5, 0.54);
        float2 p = (uv - anchor) * float2(size.x / max(size.y, 1.0), 1.0);
        const float horizon = p.y + 0.12;
        const float depth = 0.11 / max(abs(horizon), 0.018);
        const float lane = abs(fract((p.x * depth + time * 0.18) * mix(5.0, 16.0, controls.x)) - 0.5);
        const float rung = abs(fract(depth * 0.72 - time * (0.7 + uniforms.audio.y * 2.0)) - 0.5);
        const float grid = smoothstep(0.10, 0.0, min(lane, rung)) * step(0.0, horizon);
        const float skylineCell = floor((uv.x + time * 0.004) * 42.0);
        const float skylineHeight = 0.07 + gvCameraHash(float2(skylineCell, 8.0)) * 0.23;
        const float skyline = step(abs(uv.x * 42.0 - skylineCell - 0.5), 0.43) *
            step(abs(uv.y - 0.48), skylineHeight);
        const float3 neon = mix(float3(0.05, 0.75, 1.0), float3(1.0, 0.08, 0.78), saturate(uv.x + uniforms.audio.z));
        const float3 scene = base * 0.34 + neon * (grid * 1.35 + skyline * 0.24);
        result = mix(base, gvCameraGamutCompress(scene), controls.z);
        break;
    }
    case 105: { // Astral plasma - layered gaseous interference
        const float2 origin = uniforms.touch.w > 0.5 ? uniforms.touch.xy : float2(0.5);
        const float2 p = (uv - origin) * mix(2.0, 7.0, controls.x);
        const float2 drift = float2(time * 0.10, -time * 0.073);
        const float fieldA = gvFbm(p + drift + gvFbm(p * 0.7 - drift) * 2.1);
        const float fieldB = gvFbm(p * 1.8 - drift * 1.3 + 7.1);
        const float plasma = sin((fieldA - fieldB) * 12.0 + time + uniforms.audio.y * 5.0) * 0.5 + 0.5;
        const float hue = fract(0.67 + fieldA * 0.34 + fieldB * 0.18 + time * 0.025);
        const float3 gas = gvCameraHSVToRGB(float3(hue, 0.82, 0.45 + plasma * 0.75));
        result = mix(base, gvCameraGamutCompress(base * 0.38 + gas * mix(0.8, 2.2, controls.y)), controls.z);
        break;
    }
    case 106: { // Quantum raymarch - audio-breathing torus SDF
        const float2 p = (uv - 0.5) * float2(size.x / max(size.y, 1.0), 1.0);
        const float3 ray = normalize(float3(p, 1.35));
        const float3 origin = float3(0.0, 0.0, -2.6);
        float distanceTravelled = 0.0;
        float glow = 0.0;
        float hit = 0.0;
        for (int step = 0; step < 28; ++step) {
            float3 point = origin + ray * distanceTravelled;
            point.xz = gvCameraRotate(point.xz, time * 0.24 + uniforms.audio.z);
            point.xy = gvCameraRotate(point.xy, time * -0.17);
            const float ring = length(float2(length(point.xz) - 0.72, point.y)) -
                mix(0.08, 0.24, controls.x) * (1.0 + uniforms.audio.y * 0.25);
            const float distanceValue = abs(ring);
            glow += 0.004 / max(distanceValue, 0.006);
            if (distanceValue < 0.006) { hit = 1.0; break; }
            distanceTravelled += distanceValue * 0.72;
            if (distanceTravelled > 5.0) { break; }
        }
        const float3 quantum = gvCameraHSVToRGB(float3(
            fract(distanceTravelled * 0.09 + time * 0.035), 0.76, saturate(glow * mix(0.4, 1.3, controls.y))
        ));
        result = mix(base, gvCameraGamutCompress(base * (0.30 + hit * 0.22) + quantum), controls.z);
        break;
    }
    case 107: { // Liquid chroma - refractive spectral current
        const float scale = mix(2.0, 11.0, controls.x);
        const float2 gradientA = gvFbmGradient(uv * scale + float2(time * 0.12, -time * 0.08), 0.012);
        const float2 gradientB = gvFbmGradient(uv * scale * 1.7 - float2(time * 0.05, time * 0.11), 0.009);
        const float2 currentFlow = float2(-gradientA.y, gradientA.x) + gradientB * 0.55;
        const float spread = mix(0.003, 0.055, controls.y) * (1.0 + uniforms.audio.x);
        float3 liquid = gvChromaSplit(inputTexture, uv + currentFlow * spread, currentFlow * spread * 0.55);
        float3 hsv = gvCameraRGBToHSV(liquid);
        hsv.x = fract(hsv.x + length(currentFlow) * 0.22 + time * 0.018);
        hsv.y = saturate(hsv.y * 1.45 + uniforms.audio.z * 0.25);
        result = mix(base, gvCameraHSVToRGB(hsv), controls.z);
        break;
    }
    case 108: { // Holo aurora - parallax light curtains
        const float2 p = (uv - 0.5) * float2(size.x / max(size.y, 1.0), 1.0);
        float curtain = 0.0;
        float depthColor = 0.0;
        for (int layer = 0; layer < 5; ++layer) {
            const float z = float(layer) / 4.0;
            const float wave = sin(p.x * mix(5.0, 16.0, controls.x) + time * (0.35 + z) + z * 4.7) *
                (0.08 + z * 0.05);
            const float line = exp(-abs(p.y - wave + 0.05 - z * 0.045) * mix(18.0, 48.0, controls.y));
            curtain += line * (0.35 + z * 0.2);
            depthColor += line * z;
        }
        curtain *= 0.7 + uniforms.audio.z * 1.4;
        const float3 aurora = gvCameraHSVToRGB(float3(fract(0.42 + depthColor * 0.12 + time * 0.01), 0.72, curtain));
        result = mix(base, gvCameraGamutCompress(base * 0.46 + aurora * 1.45), controls.z);
        break;
    }
    case 109: { // Neural flow - firing nodes linked by travelling axons
        const float scale = mix(5.0, 15.0, controls.x);
        const float2 cell = floor(uv * scale);
        const float2 local = fract(uv * scale) - 0.5;
        const float2 node = gvMoshHash2(cell) - 0.5;
        const float nodeDistance = length(local - node * 0.72);
        const float soma = smoothstep(0.16, 0.025, nodeDistance);
        float axon = 0.0;
        for (int neighbour = 0; neighbour < 4; ++neighbour) {
            const float angle = float(neighbour) * 1.5707963;
            const float2 direction = float2(cos(angle), sin(angle));
            const float2 other = direction + (gvMoshHash2(cell + direction) - 0.5) * 0.72;
            const float2 segment = other - node * 0.72;
            const float along = saturate(dot(local - node * 0.72, segment) / max(dot(segment, segment), 1e-4));
            axon = max(axon, smoothstep(0.045, 0.006, length(local - node * 0.72 - segment * along)));
        }
        const float firing = pow(sin(time * mix(1.0, 5.0, controls.y) + gvCameraHash(cell) * 9.0) * 0.5 + 0.5, 8.0);
        const float signal = soma * (0.35 + firing * 1.8 + uniforms.audioDynamics.y) + axon * (0.22 + firing);
        const float3 neural = mix(float3(0.12, 0.42, 1.0), float3(1.0, 0.18, 0.72), firing);
        result = mix(base, gvCameraGamutCompress(base * 0.34 + neural * signal), controls.z);
        break;
    }
    case 110: { // Voxel storm - tumbling depth-sorted cubes
        const float density = mix(8.0, 28.0, controls.x);
        const float2 grid = uv * density;
        const float2 cell = floor(grid);
        float2 local = fract(grid) - 0.5;
        const float seed = gvCameraHash(cell);
        const float depth = fract(seed + time * mix(0.08, 0.55, controls.y) * (0.35 + seed));
        local = gvCameraRotate(local, time * (seed - 0.5) * 1.4);
        const float cube = smoothstep(0.48, 0.34, max(abs(local.x), abs(local.y)));
        const float edge = cube - smoothstep(0.39, 0.30, max(abs(local.x), abs(local.y)));
        const float3 voxelColor = gvCameraHSVToRGB(float3(fract(seed * 0.45 + depth * 0.2), 0.72, 0.35 + depth));
        const float3 cameraCell = gvCameraSample(inputTexture, (cell + 0.5) / density);
        result = mix(base, gvCameraGamutCompress(
            cameraCell * cube * 0.45 + voxelColor * (cube * 0.25 + edge * 1.4) *
                (1.0 + uniforms.audio.y)
        ), controls.z);
        break;
    }
    case 111: { // Fractal zoom - animated Julia set window
        const float2 centre = uniforms.touch.w > 0.5 ? uniforms.touch.xy : float2(0.5);
        const float zoom = exp2(mix(0.0, 7.0, controls.x));
        float2 z = (uv - centre) * float2(size.x / max(size.y, 1.0), 1.0) * 2.6 / zoom;
        const float2 c = float2(-0.76 + sin(time * 0.13) * 0.08, 0.16 + cos(time * 0.17) * 0.08);
        float iterations = 0.0;
        for (int index = 0; index < 36; ++index) {
            z = float2(z.x * z.x - z.y * z.y, 2.0 * z.x * z.y) + c;
            if (dot(z, z) > 16.0) { break; }
            iterations += 1.0;
        }
        const float escape = iterations / 36.0;
        const float3 fractalColor = gvCameraHSVToRGB(float3(
            fract(escape * 0.72 + time * 0.025 + uniforms.audio.z * 0.18), 0.86, pow(escape, mix(0.4, 1.8, controls.y))
        ));
        result = mix(base, gvCameraGamutCompress(base * 0.28 + fractalColor * 1.5), controls.z);
        break;
    }
    case 112: { // Particle life - a deterministic living particle field
        const float2 p = (uv - 0.5) * float2(size.x / max(size.y, 1.0), 1.0);
        float glow = 0.0;
        float hueSum = 0.0;
        for (int index = 0; index < 18; ++index) {
            const float fi = float(index);
            const float2 seed = gvMoshHash2(float2(fi, fi * 2.17));
            const float orbit = time * mix(0.12, 0.9, controls.y) * (seed.x > 0.5 ? 1.0 : -1.0);
            const float2 particle = (seed - 0.5) * 0.85 + float2(cos(orbit + fi), sin(orbit * 0.73 + fi)) *
                (0.03 + uniforms.audio.x * 0.08);
            const float light = smoothstep(mix(0.045, 0.012, controls.x), 0.0, distance(p, particle));
            glow += light;
            hueSum += light * seed.y;
        }
        const float3 life = gvCameraHSVToRGB(float3(fract(0.48 + hueSum * 0.12 + time * 0.01), 0.76, glow));
        result = mix(base, gvCameraGamutCompress(base * 0.36 + life), controls.z);
        break;
    }
    case 113: { // Waveform tunnel - spectrum wrapped through a deep corridor
        const float2 p = (uv - 0.5) * float2(size.x / max(size.y, 1.0), 1.0);
        const float angle = fract(atan2(p.y, p.x) / 6.2831853 + 0.5);
        const float radius = max(length(p), 0.004);
        const float depth = fract(0.16 / radius - time * mix(0.08, 0.6, controls.x));
        const float band = gvSpectrumAt(uniforms.spectrum, angle);
        const float wall = smoothstep(0.08 + band * controls.y * 0.26, 0.0, abs(depth - 0.5));
        const float spoke = smoothstep(0.055, 0.0, abs(fract(angle * 16.0) - 0.5));
        const float3 tunnel = gvCameraHSVToRGB(float3(fract(angle + time * 0.025), 0.86, wall + spoke * band));
        result = mix(base, gvCameraGamutCompress(base * 0.30 + tunnel * 1.6), controls.z);
        break;
    }
    case 114: { // Spectral flower - FFT petals around a reactive core
        const float2 p = (uv - 0.5) * float2(size.x / max(size.y, 1.0), 1.0);
        const float radius = length(p);
        const float angle = atan2(p.y, p.x);
        const float bandPosition = fract(angle / 6.2831853 + 0.5);
        const float energy = gvSpectrumAt(uniforms.spectrum, bandPosition);
        const float petals = mix(4.0, 18.0, controls.x);
        const float petalRadius = 0.17 + abs(cos(angle * petals * 0.5 + time * 0.32)) *
            (0.10 + energy * mix(0.05, 0.32, controls.y));
        const float petal = smoothstep(0.025, 0.0, abs(radius - petalRadius));
        const float core = smoothstep(0.10, 0.0, radius) * (0.4 + uniforms.audio.y);
        const float3 flower = gvCameraHSVToRGB(float3(fract(bandPosition + time * 0.018), 0.82, petal + core));
        result = mix(base, gvCameraGamutCompress(base * 0.38 + flower * 1.45), controls.z);
        break;
    }
    case 115: { // Glitch weave - interlocked temporal signal ribbons
        const float rows = mix(12.0, 90.0, controls.x);
        const float columns = mix(9.0, 70.0, controls.y);
        const float row = floor(uv.y * rows);
        const float column = floor(uv.x * columns);
        const float rowGate = step(gvCameraHash(float2(row, floor(time * 7.0))), 0.30 + uniforms.audio.y * 0.55);
        const float columnGate = step(gvCameraHash(float2(column, floor(time * 5.0) + 17.0)), 0.20 + uniforms.audio.z * 0.5);
        const float2 offset = float2((gvCameraHash(float2(row, time)) - 0.5) * rowGate * 0.16,
            (gvCameraHash(float2(column, time + 9.0)) - 0.5) * columnGate * 0.12);
        const float3 woven = gvChromaSplit(inputTexture, uv + offset, offset * 0.18);
        const float weaveThread = max(rowGate * smoothstep(0.15, 0.0, fract(uv.y * rows)),
            columnGate * smoothstep(0.15, 0.0, fract(uv.x * columns)));
        result = mix(base, gvCameraGamutCompress(woven + float3(0.24, 0.04, 0.45) * weaveThread), controls.z);
        break;
    }
    case 116: { // Hologram matrix - falling code reconstructed from the camera
        const float columns = mix(18.0, 72.0, controls.x);
        const float2 grid = float2(floor(uv.x * columns), floor(uv.y * columns * 1.55));
        const float speed = mix(0.35, 2.4, controls.y);
        const float trail = fract(grid.y * 0.073 - time * speed + gvCameraHash(float2(grid.x, 4.0)) * 5.0);
        const float glyph = step(0.48, gvCameraHash(grid + floor(time * speed * 5.0))) *
            smoothstep(0.46, 0.32, abs(fract(uv.x * columns) - 0.5));
        const float brightness = pow(1.0 - trail, 5.0) * glyph * (0.6 + uniforms.audio.z * 1.8);
        const float cameraLuma = gvCameraLuma(base);
        const float3 hologram = float3(0.08, 1.0, 0.56) * brightness * (0.3 + cameraLuma);
        const float scan = 0.84 + 0.16 * sin(uv.y * size.y * 3.14159);
        result = mix(base, gvCameraGamutCompress(base * float3(0.24, 0.58, 0.44) * scan + hologram), controls.z);
        break;
    }
    case 117: { // Singularity lens - gravitational camera warp
        const float2 centre = uniforms.touch.w > 0.5 ? uniforms.touch.xy : float2(0.5);
        const float2 p = (uv - centre) * float2(size.x / max(size.y, 1.0), 1.0);
        const float radius = max(length(p), 0.012);
        const float pull = mix(0.003, 0.055, controls.x) / (radius * radius + 0.025);
        const float spin = mix(0.0, 2.8, controls.y) * exp(-radius * 3.2) + time * 0.08;
        const float2 lensed = centre + gvCameraRotate(p * (1.0 - pull), spin) /
            float2(size.x / max(size.y, 1.0), 1.0);
        const float3 warped = gvChromaSplit(inputTexture, lensed, normalize(p + 1e-4) * pull * 0.035);
        const float photonRing = smoothstep(0.025, 0.0, abs(radius - (0.13 + uniforms.audio.y * 0.035)));
        result = mix(base, gvCameraGamutCompress(
            warped * step(0.075, radius) + float3(1.0, 0.48, 0.16) * photonRing
        ), controls.z);
        break;
    }
    case 118: { // Caustic reactor - colliding refractive wave fronts
        const float2 p = (uv - 0.5) * mix(5.0, 18.0, controls.x);
        const float phase = time * mix(0.25, 2.0, controls.y);
        const float waves = sin(p.x + sin(p.y * 1.3 - phase)) +
            sin(p.y * 1.4 + cos(p.x * 0.8 + phase * 0.7)) +
            sin(length(p) * 1.8 - phase * 1.3);
        const float caustic = pow(saturate(1.0 - abs(waves) * 0.34), 9.0) * (1.0 + uniforms.audio.x * 2.0);
        const float2 refract = gvFbmGradient(p * 0.35 + phase * 0.04, 0.025) * 0.018;
        const float3 warped = gvCameraSample(inputTexture, uv + refract);
        const float3 reactor = warped * 0.62 + mix(float3(0.10, 0.52, 1.0), float3(1.0, 0.24, 0.58), uv.y) * caustic;
        result = mix(base, gvCameraGamutCompress(reactor), controls.z);
        break;
    }
    case 119: { // Event horizon - accretion disc around a black core
        const float2 centre = uniforms.touch.w > 0.5 ? uniforms.touch.xy : float2(0.5);
        float2 p = (uv - centre) * float2(size.x / max(size.y, 1.0), 1.0);
        const float radius = max(length(p), 0.005);
        const float angle = atan2(p.y, p.x) + time * mix(0.15, 1.2, controls.y) / (radius + 0.12);
        const float discRadius = mix(0.16, 0.36, controls.x);
        const float disc = smoothstep(0.08, 0.0, abs(radius - discRadius - sin(angle * 5.0) * 0.018));
        const float beam = pow(saturate(cos(angle) * 0.5 + 0.5), 4.0);
        const float3 accretion = mix(float3(1.0, 0.18, 0.03), float3(0.28, 0.50, 1.0), beam) *
            disc * (1.0 + uniforms.audio.y * 2.0);
        const float lens = mix(0.0, 0.07, controls.x) / (radius + 0.04);
        const float3 warped = gvCameraSample(inputTexture, centre + normalize(p) * (radius + lens) /
            float2(size.x / max(size.y, 1.0), 1.0));
        result = mix(base, gvCameraGamutCompress(
            warped * step(discRadius * 0.42, radius) * 0.55 + accretion
        ), controls.z);
        break;
    }
    case 120: { // Prism portal - faceted chromatic aperture
        const float2 centre = uniforms.touch.w > 0.5 ? uniforms.touch.xy : float2(0.5);
        const float2 p = (uv - centre) * float2(size.x / max(size.y, 1.0), 1.0);
        const float radius = length(p);
        const float angle = atan2(p.y, p.x);
        const float facets = floor(mix(3.0, 14.0, controls.y));
        const float facetedRadius = radius * (0.92 + cos(angle * facets) * 0.08);
        const float portalRadius = mix(0.12, 0.44, controls.x);
        const float rim = smoothstep(0.035, 0.0, abs(facetedRadius - portalRadius));
        const float2 normal = normalize(p + 1e-4);
        const float3 prism = gvChromaSplit(inputTexture, uv + normal * rim * 0.025, normal * rim * 0.022);
        const float3 spectral = gvCameraHSVToRGB(float3(fract(angle / 6.2831853 + time * 0.035), 0.92, rim));
        result = mix(base, gvCameraGamutCompress(prism + spectral * (0.8 + uniforms.audio.z)), controls.z);
        break;
    }
    case 121: { // Neon orbit - luminous bodies on nested ellipses
        const float2 p = (uv - 0.5) * float2(size.x / max(size.y, 1.0), 1.0);
        float light = 0.0;
        float hue = 0.0;
        for (int orbitIndex = 0; orbitIndex < 6; ++orbitIndex) {
            const float fi = float(orbitIndex);
            const float radius = 0.08 + fi * mix(0.035, 0.075, controls.x);
            const float phase = time * mix(0.3, 2.4, controls.y) * (0.45 + fi * 0.12) + fi * 1.71;
            const float2 body = float2(cos(phase) * radius, sin(phase) * radius * (0.42 + fi * 0.06));
            const float glow = smoothstep(0.045, 0.0, distance(p, body));
            const float track = smoothstep(0.008, 0.0, abs(length(p / float2(1.0, 0.55)) - radius));
            light += glow + track * 0.18;
            hue += glow * fi / 6.0;
        }
        const float3 neon = gvCameraHSVToRGB(float3(fract(0.55 + hue + time * 0.018), 0.84, light * (0.7 + uniforms.audio.x)));
        result = mix(base, gvCameraGamutCompress(base * 0.32 + neon), controls.z);
        break;
    }
    case 122: { // Chrome ripple - liquid-metal camera relief
        const float2 origin = uniforms.touch.w > 0.5 ? uniforms.touch.xy : float2(0.5);
        const float2 p = (uv - origin) * float2(size.x / max(size.y, 1.0), 1.0);
        const float radius = length(p);
        const float wave = sin(radius * mix(24.0, 90.0, controls.x) - time * mix(1.0, 8.0, controls.y));
        const float2 normal = normalize(p + 1e-4) * wave;
        const float3 refracted = gvCameraSample(inputTexture, uv + normal * 0.018);
        const float luminance = gvCameraLuma(refracted);
        const float specular = pow(saturate(0.5 + wave * 0.5), 12.0) * (1.0 + uniforms.audioDynamics.x);
        const float3 chrome = mix(float3(luminance * 0.35), float3(0.65, 0.78, 1.0), specular) + refracted * 0.34;
        result = mix(base, gvCameraGamutCompress(chrome), controls.z);
        break;
    }
    case 123: { // Laser garden - perspective blades growing from the floor
        const float2 p = (uv - 0.5) * float2(size.x / max(size.y, 1.0), 1.0);
        float beams = 0.0;
        float hue = 0.0;
        for (int index = 0; index < 10; ++index) {
            const float fi = float(index);
            const float seed = gvCameraHash(float2(fi, 3.7));
            const float root = (seed - 0.5) * 1.1;
            const float bend = sin(time * mix(0.25, 1.8, controls.y) + fi) * mix(0.02, 0.18, controls.x);
            const float lineX = root + p.y * bend;
            const float blade = smoothstep(0.012, 0.001, abs(p.x - lineX)) * smoothstep(0.58, -0.3, p.y);
            beams += blade;
            hue += blade * seed;
        }
        const float3 laser = gvCameraHSVToRGB(float3(fract(hue * 0.17 + time * 0.014), 0.94, beams * (0.6 + uniforms.audio.z * 1.8)));
        result = mix(base, gvCameraGamutCompress(base * 0.27 + laser), controls.z);
        break;
    }
    case 124: { // Hyper bloom - thresholded camera light becomes a living halo
        const float threshold = mix(0.82, 0.20, controls.y);
        const float reach = mix(2.0, 34.0, controls.x);
        const float3 blurred = gvBlur(inputTexture, uv, texel * reach);
        const float3 hot = max(blurred - threshold, 0.0);
        const float halo = gvCameraLuma(hot) * (2.0 + uniforms.audio.x * 5.0);
        const float hue = fract(gvCameraLuma(base) * 0.38 + time * 0.025);
        const float3 spectralHalo = gvCameraHSVToRGB(float3(hue, 0.72, halo));
        const float pulse = 0.76 + 0.24 * sin(time * 2.0 + uniforms.audio.y * 6.0);
        result = mix(base, gvCameraGamutCompress(base + spectralHalo * pulse), controls.z);
        break;
    }
    case 125: { // Pixel confetti - image cells burst into reactive colour chips
        const float density = mix(10.0, 55.0, controls.x);
        const float2 cell = floor(uv * density);
        const float2 local = fract(uv * density) - 0.5;
        const float seed = gvCameraHash(cell);
        const float burst = uniforms.audioDynamics.y + uniforms.audio.y * 0.6;
        const float2 drift = (gvMoshHash2(cell) - 0.5) * burst * sin(time * (1.0 + seed * 4.0));
        const float chip = smoothstep(0.42, 0.30, max(abs(local.x - drift.x), abs(local.y - drift.y)));
        const float enabled = step(seed, mix(0.12, 0.88, controls.y) + burst * 0.2);
        const float3 color = gvCameraHSVToRGB(float3(fract(seed + time * 0.04), 0.90, 1.0));
        const float3 sampled = gvCameraSample(inputTexture, (cell + 0.5) / density);
        result = mix(base, gvCameraGamutCompress(sampled * 0.35 + color * chip * enabled), controls.z);
        break;
    }
    case 126: { // Solar flare - anamorphic star driven from touch
        const float2 centre = uniforms.touch.w > 0.5 ? uniforms.touch.xy : float2(0.5, 0.5);
        const float2 p = (uv - centre) * float2(size.x / max(size.y, 1.0), 1.0);
        const float radius = max(length(p), 0.003);
        const float core = pow(saturate(1.0 - radius / mix(0.04, 0.24, controls.x)), 4.0);
        const float horizontal = exp(-abs(p.y) * mix(20.0, 120.0, controls.y)) /
            (1.0 + abs(p.x) * 5.0);
        const float rays = pow(abs(sin(atan2(p.y, p.x) * 9.0 + time * 0.25)), 22.0) /
            (1.0 + radius * 14.0);
        const float energy = (core + horizontal + rays) * (0.6 + uniforms.audio.x * 1.8);
        const float3 flare = mix(float3(1.0, 0.24, 0.05), float3(0.45, 0.72, 1.0), saturate(radius * 2.5)) * energy;
        result = mix(base, gvCameraGamutCompress(base + flare), controls.z);
        break;
    }
    case 127: { // Candy mesh - glossy warped candy lattice
        const float2 p = (uv - 0.5) * mix(5.0, 18.0, controls.x);
        const float warp = sin(p.y * 0.8 + time) + cos(p.x * 0.7 - time * 0.8);
        const float2 q = p + float2(sin(p.y + time), cos(p.x - time)) * warp * 0.18;
        const float mesh = min(abs(sin(q.x * 3.14159)), abs(sin(q.y * 3.14159)));
        const float ribbon = smoothstep(mix(0.42, 0.08, controls.y), 0.0, mesh);
        const float highlight = pow(1.0 - mesh, 9.0);
        const float hue = fract(q.x * 0.045 + q.y * 0.035 + time * 0.025 + uniforms.audio.z * 0.2);
        const float3 candy = gvCameraHSVToRGB(float3(hue, 0.76, ribbon * 0.72 + highlight));
        result = mix(base, gvCameraGamutCompress(base * 0.32 + candy), controls.z);
        break;
    }
    case 128: { // Aurora glass - layered translucent refraction
        const float scale = mix(2.0, 9.0, controls.x);
        const float2 flowA = gvFbmGradient(uv * scale + float2(time * 0.08, 0.0), 0.012);
        const float2 flowB = gvFbmGradient(uv * scale * 1.9 - float2(0.0, time * 0.06), 0.008);
        const float2 normal = flowA + float2(-flowB.y, flowB.x) * 0.65;
        const float sheen = pow(saturate(0.5 + dot(normalize(float3(normal, 0.4)), normalize(float3(-0.3, 0.5, 0.8)))),
            mix(3.0, 16.0, controls.y));
        const float3 refracted = gvChromaSplit(inputTexture, uv + normal * 0.025, normal * 0.008);
        const float hue = fract(0.42 + normal.x * 0.28 + normal.y * 0.18 + time * 0.012);
        const float3 glass = refracted * 0.72 + gvCameraHSVToRGB(float3(hue, 0.62, sheen * (1.0 + uniforms.audio.z)));
        result = mix(base, gvCameraGamutCompress(glass), controls.z);
        break;
    }
    case 129: { // Cosmic knot - projected luminous torus knot
        const float2 p = (uv - 0.5) * float2(size.x / max(size.y, 1.0), 1.0);
        float nearest = 1e6;
        float knotHue = 0.0;
        const float spin = time * mix(0.08, 0.75, controls.y);
        for (int index = 0; index < 40; ++index) {
            const float t = float(index) / 40.0 * 6.2831853;
            const float radius = 0.23 + 0.075 * cos(3.0 * t + spin);
            float3 knot = float3(radius * cos(2.0 * t), radius * sin(2.0 * t), 0.075 * sin(3.0 * t + spin));
            knot.xz = gvCameraRotate(knot.xz, spin * 0.7);
            const float2 projected = knot.xy / (0.8 + knot.z);
            const float distanceValue = distance(p, projected);
            if (distanceValue < nearest) {
                nearest = distanceValue;
                knotHue = t / 6.2831853;
            }
        }
        const float line = smoothstep(mix(0.030, 0.008, controls.x), 0.0, nearest);
        const float glow = smoothstep(0.075, 0.0, nearest) * 0.35;
        const float3 knotColor = gvCameraHSVToRGB(float3(fract(knotHue + time * 0.02), 0.84, (line + glow) *
            (0.7 + uniforms.audio.y * 1.5)));
        result = mix(base, gvCameraGamutCompress(base * 0.30 + knotColor), controls.z);
        break;
    }
    case 130: { // Nebula drift - swirling interstellar clouds with audio-reactivity
        const float2 aspect = float2(size.x / max(size.y, 1.0), 1.0);
        float2 p = (uv - 0.5) * aspect * mix(2.2, 6.5, controls.y);
        const float driftSpeed = mix(0.015, 0.18, controls.x);
        const float2 drift = float2(time * driftSpeed, -time * driftSpeed * 0.63);
        const float2 warp = float2(gvFbm(p + drift), gvFbm(p - drift + 8.4)) - 0.5;
        const float cloudA = gvFbm(p + warp * 3.2 + drift);
        const float cloudB = gvFbm(p * 1.9 - warp * 2.1 - drift * 0.7);
        const float density = smoothstep(0.25, 0.83, cloudA * 0.72 + cloudB * 0.48 + uniforms.audio.y * 0.16);
        const float3 cold = float3(0.05, 0.08, 0.34);
        const float3 hot = float3(0.96, 0.22, 0.62);
        const float3 gas = mix(cold, hot, saturate(cloudB + uniforms.audio.z * 0.25)) * density * 1.8;
        const float2 starCell = floor(uv * 180.0);
        const float stars = pow(gvCameraHash(starCell), 42.0) * (0.4 + uniforms.audioDynamics.x * 1.5);
        result = mix(base, gvCameraGamutCompress(base * 0.34 + gas + stars), controls.z);
        break;
    }
    case 131: { // Quantum bloom - pulsing quantum-circuit field with temporal glow
        const float2 aspect = float2(size.x / max(size.y, 1.0), 1.0);
        const float2 p = (uv - 0.5) * aspect;
        const float radius = length(p);
        const float growth = fract(time * mix(0.08, 0.7, controls.x) + uniforms.audioDynamics.y * 0.18);
        float bloom = 0.0;
        for (int ringIndex = 0; ringIndex < 5; ++ringIndex) {
            const float ringRadius = fract(growth + float(ringIndex) / 5.0) * 0.62;
            bloom += smoothstep(0.025, 0.0, abs(radius - ringRadius)) * (1.0 - ringRadius);
        }
        const float2 cell = gvWorley(p * mix(5.0, 18.0, controls.y) + time * 0.04);
        const float circuit = smoothstep(0.055, 0.0, cell.y - cell.x);
        const float3 quantum = gvCameraHSVToRGB(float3(
            fract(radius * 0.7 + time * 0.025), 0.78, bloom * 1.3 + circuit * 0.32
        ));
        result = mix(base, gvCameraGamutCompress(
            base * 0.31 + quantum * (0.8 + uniforms.audio.x)
        ), controls.z);
        break;
    }
    case 132: { // Plasma ripple - fluid plasma tendrils with touch displacement
        const float2 aspect = float2(size.x / max(size.y, 1.0), 1.0);
        const float2 origin = uniforms.touch.w > 0.5 ? uniforms.touch.xy : float2(0.5);
        const float2 p = (uv - origin) * aspect;
        const float radius = length(p);
        const float scale = mix(8.0, 32.0, controls.x);
        const float2 field = gvFbmGradient(uv * scale + float2(time * 0.16, -time * 0.11), 0.009);
        const float ripple = sin(radius * scale * 1.7 - time * mix(1.0, 7.0, controls.y) +
            gvFbm(uv * scale * 0.32) * 5.0);
        const float2 displacement = normalize(p + 1e-4) * ripple * 0.014 + field * 0.020;
        const float3 warped = gvChromaSplit(inputTexture, uv + displacement, displacement * 0.35);
        const float filament = pow(saturate(0.5 + ripple * 0.5), 8.0) * (0.5 + uniforms.audio.x * 1.6);
        const float3 plasma = gvCameraHSVToRGB(float3(fract(0.72 + radius + time * 0.03), 0.88, filament));
        result = mix(base, gvCameraGamutCompress(warped * 0.62 + plasma), controls.z);
        break;
    }
    case 133: { // Chroma scrape - MTV-style glitch with audio-driven chrome strips
        const float rows = mix(18.0, 160.0, controls.x);
        const float row = floor(uv.y * rows);
        const float tick = floor(time * mix(5.0, 24.0, controls.y));
        const float seed = gvCameraHash(float2(row, tick));
        const float active = step(seed, 0.15 + uniforms.audioDynamics.x * 0.75);
        const float reach = (gvCameraHash(float2(row, tick + 17.0)) - 0.5) *
            mix(0.015, 0.34, controls.x) * active;
        const float3 scraped = gvChromaSplit(inputTexture, uv + float2(reach, 0.0), float2(reach * 0.12, 0.0));
        const float ridge = smoothstep(0.18, 0.0, min(fract(uv.y * rows), 1.0 - fract(uv.y * rows))) * active;
        const float chrome = pow(saturate(gvCameraLuma(scraped)), 0.45) * ridge * mix(0.5, 2.8, controls.y);
        const float3 sheen = gvCameraHSVToRGB(float3(fract(uv.x + time * 0.06), 0.58, chrome));
        result = mix(base, gvCameraGamutCompress(scraped * 0.58 + sheen), controls.z);
        break;
    }
    case 134: { // Singularity weave - gravitational lensing with touch vortex
        const float2 aspect = float2(size.x / max(size.y, 1.0), 1.0);
        const float2 origin = uniforms.touch.w > 0.5 ? uniforms.touch.xy : float2(0.5);
        const float2 p = (uv - origin) * aspect;
        const float radius = max(length(p), 0.012);
        const float angle = atan2(p.y, p.x) + mix(0.2, 3.8, controls.x) / (radius + 0.08) + time * 0.18;
        const float2 wovenCoordinates = float2(angle / 6.2831853, log(radius) * mix(4.0, 15.0, controls.y));
        const float warpThread = min(abs(fract(wovenCoordinates.x * 18.0) - 0.5),
            abs(fract(wovenCoordinates.y) - 0.5));
        const float weave = smoothstep(0.11, 0.0, warpThread);
        const float lens = mix(0.0, 0.09, controls.x) / (radius + 0.04);
        const float2 sampleUV = origin + normalize(p) * (radius - lens) / aspect;
        const float3 warped = gvChromaSplit(inputTexture, sampleUV, normalize(p) * lens * 0.025);
        const float3 filament = gvCameraHSVToRGB(float3(fract(angle / 6.2831853), 0.82, weave *
            (0.5 + uniforms.audio.z * 1.4)));
        result = mix(base, gvCameraGamutCompress(warped * 0.48 + filament), controls.z);
        break;
    }
    case 135: { // Fractal burst - explosive Mandelbrot fractal expansion
        const float2 aspect = float2(size.x / max(size.y, 1.0), 1.0);
        const float burstScale = mix(3.2, 0.55, controls.x) * (1.0 + uniforms.audioDynamics.y * 0.18);
        const float2 p = (uv - 0.5) * aspect * burstScale;
        const float2 c = p + float2(-0.62 + sin(time * 0.11) * 0.06, cos(time * 0.09) * 0.08);
        float2 z = float2(0.0, 0.0);
        float iter = 0.0;
        for (int i = 0; i < 36; i++) {
            if (dot(z, z) >= 16.0) { break; }
            z = float2(z.x * z.x - z.y * z.y, 2.0 * z.x * z.y) + c;
            iter = float(i) + 1.0;
        }
        const float escaped = iter / 36.0;
        const float shockwave = smoothstep(0.035, 0.0, abs(length(p) - fract(time * 0.22) * 1.8));
        const float3 fractal = gvCameraHSVToRGB(float3(
            fract(iter * 0.055 + time * 0.025), 0.88, pow(escaped, mix(0.45, 1.8, controls.y))
        ));
        result = mix(base, gvCameraGamutCompress(
            base * 0.27 + fractal * 1.6 + float3(1.0, 0.38, 0.08) * shockwave *
                (0.5 + uniforms.audio.x)
        ), controls.z);
        break;
    }
    case 136: { // Vortex pulse - radial vortex with audio-pumped intensity
        const float2 aspect = float2(size.x / max(size.y, 1.0), 1.0);
        const float2 origin = uniforms.touch.w > 0.5 ? uniforms.touch.xy : float2(0.5);
        const float2 p = (uv - origin) * aspect;
        const float radius = max(length(p), 0.004);
        const float pulse = 0.5 + 0.5 * sin(time * mix(1.0, 7.0, controls.x) - radius * 18.0);
        const float twist = mix(0.0, 5.0, controls.y) * exp(-radius * 3.4) *
            (0.45 + pulse + uniforms.audio.y * 0.8);
        const float2 warpedP = gvCameraRotate(p, twist);
        const float2 sampleUV = origin + warpedP / aspect;
        const float3 warped = gvChromaSplit(inputTexture, sampleUV, normalize(p) * pulse * 0.009);
        const float ring = smoothstep(0.025, 0.0, abs(radius - (0.12 + pulse * 0.25)));
        const float3 energy = gvCameraHSVToRGB(float3(fract(0.72 + pulse * 0.22 + time * 0.02), 0.86,
            ring * (0.6 + uniforms.audioDynamics.x * 1.7)));
        result = mix(base, gvCameraGamutCompress(warped * 0.60 + energy), controls.z);
        break;
    }
    case 137: { // Spectral nova - expanding rainbow ring with FFT-driven colors
        const float2 aspect = float2(size.x / max(size.y, 1.0), 1.0);
        const float2 p = (uv - 0.5) * aspect;
        const float radius = length(p);
        const float angle = fract(atan2(p.y, p.x) / 6.2831853 + 0.5);
        const float mirroredBand = angle < 0.5 ? angle * 2.0 : (1.0 - angle) * 2.0;
        const float spectrum = gvSpectrumAt(uniforms.spectrum, mirroredBand);
        const float expansion = fract(time * mix(0.08, 0.65, controls.x) + uniforms.audioDynamics.y * 0.16);
        float nova = 0.0;
        for (int ringIndex = 0; ringIndex < 3; ++ringIndex) {
            const float ringRadius = fract(expansion + float(ringIndex) / 3.0) * 0.72;
            nova += smoothstep(0.018 + spectrum * 0.018, 0.0, abs(radius - ringRadius)) *
                (0.3 + spectrum * mix(0.8, 2.6, controls.y));
        }
        const float rays = pow(abs(cos(angle * 6.2831853 * 12.0)), 28.0) * spectrum /
            (1.0 + radius * 12.0);
        const float3 rainbow = gvCameraHSVToRGB(float3(fract(angle + time * 0.04), 0.92, nova + rays));
        result = mix(base, gvCameraGamutCompress(base * 0.29 + rainbow), controls.z);
        break;
    }
    case 138: { // Ion storm - charged flow field that refracts the live image
        const float2 aspect = float2(size.x / max(size.y, 1.0), 1.0);
        const float2 origin = uniforms.touch.w > 0.5 ? uniforms.touch.xy : float2(0.5);
        const float2 p = (uv - origin) * aspect;
        const float audioEnergy = saturate(uniforms.audio.x * 0.55 + uniforms.audio.y * 0.90 +
            uniforms.audioDynamics.y * 0.45);
        const float scale = mix(3.0, 18.0, controls.x);
        const float phase = time * mix(0.28, 1.85, controls.y);
        const float2 field = gvFbmGradient(p * scale + float2(phase, -phase * 0.73), 0.025);
        const float2 curl = float2(-field.y, field.x);
        const float2 refractedUV = uv + curl * mix(0.004, 0.050, controls.x) * (0.45 + audioEnergy);
        const float3 refracted = gvChromaSplit(
            inputTexture,
            refractedUV,
            curl * mix(0.001, 0.014, controls.y) * (0.4 + audioEnergy)
        );
        const float filaments = pow(saturate(1.0 - abs(sin(dot(p, curl * 22.0) + phase * 5.0))), 14.0);
        const float3 charge = gvCameraHSVToRGB(float3(
            fract(0.55 + gvFbm(p * 5.0 - phase) * 0.42 + audioEnergy * 0.18),
            0.80,
            1.0
        ));
        result = gvCameraGamutCompress(refracted + charge * filaments * (0.45 + audioEnergy * 1.35));
        break;
    }
    case 139: { // Opal wave - iridescent caustics driven by audio and gesture
        const float2 aspect = float2(size.x / max(size.y, 1.0), 1.0);
        const float2 p = (uv - 0.5) * aspect;
        const float audioEnergy = saturate(uniforms.audio.x * 0.45 + uniforms.audio.z * 0.75 +
            uniforms.audioDynamics.x * 0.35);
        const float speed = mix(0.18, 1.35, controls.y);
        const float timePhase = time * speed;
        const float2 warp = float2(
            gvFbm(p * mix(4.0, 14.0, controls.x) + float2(timePhase, 1.7)),
            gvFbm(p * mix(4.0, 14.0, controls.x) + float2(-2.3, -timePhase))
        ) - 0.5;
        const float wave = sin((p.x + warp.x * 0.42) * 17.0 +
            (p.y + warp.y * 0.42) * 13.0 + timePhase * 3.0);
        const float caustic = pow(saturate(0.5 + 0.5 * wave), mix(7.0, 2.2, controls.x));
        const float radius = length(p + warp * 0.18);
        const float hue = fract(radius * 0.78 - wave * 0.13 + timePhase * 0.08 + audioEnergy * 0.22);
        const float3 iridescence = gvCameraHSVToRGB(float3(hue, 0.72 + audioEnergy * 0.28, 1.0));
        const float2 offset = warp * mix(0.002, 0.022, controls.x) * (1.0 + audioEnergy);
        const float3 refracted = gvChromaSplit(inputTexture, uv + offset, offset * 0.72);
        result = gvCameraGamutCompress(
            refracted * (0.74 + caustic * 0.26) + iridescence * caustic *
                (0.28 + audioEnergy * 0.82)
        );
        break;
    }
    case 140: { // CMYK press: four independent, rotated subtractive screens.
        const float pitch = mix(3.5, 22.0, controls.x);
        const float registration = controls.y * pitch * 0.32;
        const float angles[4] = {0.261799, 1.308997, 0.0, 0.785398};
        const float2 offsets[4] = {float2(1, 0.2), float2(-0.4, 1), float2(-0.6, -0.8), float2(0)};
        float4 screens = float4(0);
        for (uint plate = 0; plate < 4; ++plate) {
            const float2 registered = float2(position) + offsets[plate] * registration;
            const float2 rotated = gvCameraRotate(registered, angles[plate]);
            const float2 cellCenter = (floor(rotated / pitch) + 0.5) * pitch;
            const float2 samplePosition = gvCameraRotate(cellCenter, -angles[plate]) - offsets[plate] * registration;
            const float3 rgb = saturate(gvCameraSample(inputTexture, (samplePosition + 0.5) / size));
            const float black = 1.0 - max(rgb.r, max(rgb.g, rgb.b));
            const float3 cmy = saturate((1.0 - rgb - black) / max(1.0 - black, 0.001));
            const float ink = plate == 3 ? black : cmy[plate];
            const float dotRadius = sqrt(ink) * 0.7071;
            const float radius = length(fract(rotated / pitch) - 0.5);
            screens[plate] = 1.0 - smoothstep(dotRadius - 0.7 / pitch, dotRadius + 0.7 / pitch, radius);
        }
        const float density = mix(0.45, 1.0, controls.z);
        const float3 paper = float3(0.97, 0.945, 0.89);
        const float3 colorInk = 1.0 - screens.xyz * density;
        result = paper * colorInk * (1.0 - screens.w * density);
        break;
    }
    case 141: { // Highlight-gated multiorder spectral diffraction, bounded to 24 taps.
        const float pitch = mix(0.002, 0.030, controls.x);
        const uint orders = 1u + uint(round(controls.y * 3.0));
        const float gate = mix(0.25, 0.92, controls.z);
        float3 spectrum = float3(0);
        float normalization = 0;
        for (uint order = 1; order <= 4; ++order) {
            if (order > orders) break;
            const float weight = 1.0 / float(order * order);
            for (int side = -1; side <= 1; side += 2) {
                for (uint channel = 0; channel < 3; ++channel) {
                    const float wavelength = channel == 0 ? 0.650 : (channel == 1 ? 0.530 : 0.460);
                    const float displacement = float(side) * float(order) * pitch * wavelength / 0.530;
                    const float3 light = gvCameraSample(inputTexture, uv + float2(displacement, displacement * 0.22));
                    const float highlight = smoothstep(gate, min(gate + 0.15, 1.0), gvCameraLuma(light));
                    spectrum[channel] += light[channel] * highlight * weight;
                }
                normalization += weight;
            }
        }
        result = base + spectrum / max(normalization, 1.0) * 0.75;
        break;
    }
    default:
        break;
    }

    // Colour-only modes have no geometry to push, so the parameter coupling
    // above is invisible on them. For those, the finger drives the palette
    // instead: X rotates hue, Y trades saturation, proximity lifts value.
    if (uniforms.touch.w > 0.5 && gvIsColourOnlyMode(styleMode)) {
        const float proximity = 1.0 - smoothstep(0.0, 0.55, distance(uv, uniforms.touch.xy));
        float3 hsv = gvCameraRGBToHSV(result);
        hsv.x = fract(hsv.x + (uniforms.touch.x - 0.5) * 0.5 * proximity);
        hsv.y = saturate(hsv.y * (1.0 + (0.5 - uniforms.touch.y) * 1.2 * proximity));
        hsv.z = saturate(hsv.z * (1.0 + proximity * 0.35));
        result = gvCameraHSVToRGB(hsv);
    }

    result = mix(base, result, saturate(uniforms.extra.x * touchIntensity));
	    outputTexture.write(half4(half3(gvCameraGamutCompress(result)), 1.0h), position);
	}

/// Correct fallback while a mode specialization compiles. Keeping this as a
/// distinct entry point is required by Metal: a function with an unresolved
/// function constant can be retrieved from a library but cannot form a PSO.
kernel void gvCameraStyleEffectGeneric(
    texture2d<half, access::sample> inputTexture [[texture(0)]],
    texture2d<half, access::write> outputTexture [[texture(1)]],
    constant GVCameraEffectUniforms &uniforms [[buffer(0)]],
    uint2 position [[thread_position_in_grid]]
) {
    gvCameraStyleEffectBody(inputTexture, outputTexture, uniforms, position, uniforms.mode.x);
}

/// Function-constant entry point. The inlined body receives a compile-time
/// mode, allowing the compiler to dead-strip every unrelated effect arm.
kernel void gvCameraStyleEffect(
    texture2d<half, access::sample> inputTexture [[texture(0)]],
    texture2d<half, access::write> outputTexture [[texture(1)]],
    constant GVCameraEffectUniforms &uniforms [[buffer(0)]],
    uint2 position [[thread_position_in_grid]]
) {
    gvCameraStyleEffectBody(inputTexture, outputTexture, uniforms, position, gvStyleModeConstant);
}

	float2 gvCameraRotate(float2 value, float angle) {
	    const float sine = sin(angle);
	    const float cosine = cos(angle);
	    return float2(
	        value.x * cosine - value.y * sine,
	        value.x * sine + value.y * cosine
	    );
	}

	float3 gvCameraLumaRankedSample(
	    texture2d<half, access::sample> texture,
	    float2 uv,
	    float2 delta,
	    float rank
	) {
	    float3 lowColor = gvCameraSample(texture, uv - delta);
	    float3 midColor = gvCameraSample(texture, uv);
	    float3 highColor = gvCameraSample(texture, uv + delta);
	    float lowLuma = gvCameraLuma(lowColor);
	    float midLuma = gvCameraLuma(midColor);
	    float highLuma = gvCameraLuma(highColor);

	    if (lowLuma > midLuma) {
	        const float3 swapColor = lowColor;
	        lowColor = midColor;
	        midColor = swapColor;
	        const float swapLuma = lowLuma;
	        lowLuma = midLuma;
	        midLuma = swapLuma;
	    }
	    if (midLuma > highLuma) {
	        const float3 swapColor = midColor;
	        midColor = highColor;
	        highColor = swapColor;
	        const float swapLuma = midLuma;
	        midLuma = highLuma;
	        highLuma = swapLuma;
	    }
	    if (lowLuma > midLuma) {
	        const float3 swapColor = lowColor;
	        lowColor = midColor;
	        midColor = swapColor;
	    }

	    if (rank < 0.34) {
	        return lowColor;
	    }
	    if (rank < 0.67) {
	        return midColor;
	    }
	    return highColor;
	}

	kernel void gvCameraTemporalEffect(
	    texture2d<half, access::sample> inputTexture [[texture(0)]],
	    texture2d<half, access::sample> historyTexture [[texture(1)]],
    texture2d<half, access::write> outputTexture [[texture(2)]],
    // Shared aged-frame ring. Strides are 1/4/12/30 captured frames, so at
    // 60fps these are roughly 17ms / 67ms / 200ms / 500ms in the past. Bound
    // for every temporal mode; only the damage modes currently read them.
    texture2d<half, access::sample> tap0 [[texture(3)]],
    texture2d<half, access::sample> tap1 [[texture(4)]],
    texture2d<half, access::sample> tap2 [[texture(5)]],
    texture2d<half, access::sample> tap3 [[texture(6)]],
    // Persistent motion field from the shared optical-flow pipeline. Vectors
    // are in normalised UV, so a value of 0.01 displaces by 1% of the frame.
    // Gated by `uniforms.extra.z`; before flow primes this binding aliases the
    // history texture and must not be sampled as vectors.
    texture2d<half, access::sample> flowField [[texture(7)]],
    // Timestamped history. Addressed in seconds via gvTemporalSample.
    texture2d_array<half, access::sample> temporalRing [[texture(8)]],
    // Datamosh engine block state, one texel per 8px cell. Read is the field
    // as of last frame; write is the field this frame produces. The renderer
    // ping-pongs both pairs; non-mosh modes never touch them.
    texture2d<half, access::sample> moshStateIn [[texture(9)]],
    texture2d<half, access::write> moshStateOut [[texture(10)]],
    constant float *ringTimestamps [[buffer(1)]],
    constant GVTemporalRing &ringInfo [[buffer(2)]],
    constant GVCameraEffectUniforms &uniforms [[buffer(0)]],
    uint2 position [[thread_position_in_grid]]
) {
    if (position.x >= outputTexture.get_width() || position.y >= outputTexture.get_height()) {
        return;
    }

	    const float2 size = uniforms.viewport.xy;
	    const float2 texel = uniforms.viewport.zw;
	    const float2 uv = (float2(position) + 0.5) / size;
	    float4 controls = uniforms.parameters;
	    controls.x = saturate(controls.x + uniforms.audio.y * 0.20);
	    controls.y = saturate(controls.y + uniforms.audio.z * 0.12);
	    controls.z = saturate(controls.z + uniforms.audio.w * 0.14);

    // MARK: Universal touch modulation
    //
    // Applied once here rather than per-effect, so every style mode responds to
    // the finger without 92 individual edits. Three couplings:
    //
    //   proximity - the effect intensifies toward the contact point, which is
    //               what makes the filter feel attached to the hand
    //   position  - X and Y bias the two primary parameters, so sliding the
    //               finger sweeps the effect through its range
    //   velocity  - a fast drag pushes the third parameter, so flicks register
    //
    // Effects that already read `uniforms.touch` directly (ripple, twirl,
    // finger gravity) still do; this only shifts their controls underneath.
    float touchIntensity = 1.0;
    if (uniforms.touch.w > 0.5) {
        const float reach = 0.55;
        const float proximity = 1.0 - smoothstep(0.0, reach, distance(uv, uniforms.touch.xy));
        const float velocity = saturate(uniforms.touch.z);

        controls.x = saturate(controls.x + (uniforms.touch.x - 0.5) * 0.42 * proximity);
        controls.y = saturate(controls.y + (0.5 - uniforms.touch.y) * 0.42 * proximity);
        controls.z = saturate(controls.z + velocity * 0.24);

        // Local strength lift. Capped so the effect never fully takes over the
        // frame from a single touch.
        touchIntensity = 1.0 + proximity * 0.55;
    }
    // A recent tap leaves an expanding ring of extra intensity behind it.
    if (uniforms.touchImpact.w > 0.5) {
        const float age = uniforms.touchImpact.z;
        const float ringRadius = age * 0.9;
        const float ring = exp(-abs(distance(uv, uniforms.touchImpact.xy) - ringRadius) * 14.0);
        touchIntensity += ring * exp(-age * 2.4) * 0.85;
    }
	    // Shared motion. Read once here so every mode below can use it without
	    // each one re-sampling or, worse, estimating its own.
	    const bool flowReady = uniforms.extra.z > 0.5;
	    const float2 flow = flowReady ? gvCameraSampleVector(flowField, uv) : float2(0.0);
	    const float flowMagnitude = length(flow);
	    const bool holdActive = uniforms.extra.y > 0.5 && uniforms.mode.x >= 4u;

	    // SOURCE CLOCK vs SIMULATION CLOCK. `holdActive` means the camera
	    // frame is frozen — the renderer simply stopped ingesting, so
	    // `inputTexture` already IS the frozen frame; the pipeline above kept
	    // running and the mosh keeps evolving underneath it. The hold has been
	    // running for `holdSeconds`, `holdStyle` selects the mixed hold
	    // behaviours (see gvMoshUpdateVector), and `dt` arrives packed in
	    // mode.z as seconds × 65536 so momentum is frame-rate independent.
	    const float holdSeconds = max(uniforms.extra.w, 0.0);
	    const uint holdStyle = uniforms.mode.y;
	    const float dt = clamp(float(uniforms.mode.z) / 65536.0, 1.0 / 240.0, 0.1);
	    const float3 current = gvCameraSample(inputTexture, uv);
	    const float time = controls.w;
	    float3 result = current;

    switch (uniforms.mode.x) {
    case 0: { // Feedback
        const float zoom = (controls.y - 0.5) * 0.22;
        const float drift = (controls.z - 0.5) * 0.06;
        const float2 historyUV = (uv - 0.5) * (1.0 + zoom) + 0.5 +
            float2(sin(time * 0.73), cos(time * 0.61)) * drift;
        const float3 history = gvCameraSample(historyTexture, historyUV);
        result = mix(current, history, controls.x * 0.96);
        break;
    }
    case 1: { // Trails
        const float decay = mix(0.48, 0.995, controls.x);
        const float smear = controls.z * 0.055;
        const float2 historyUV = uv - float2(smear, smear * 0.34);
        float3 history = gvCameraSample(historyTexture, historyUV) * decay;
        history = mix(history, history.brg, controls.y * 0.32);
        result = max(current, history);
        break;
    }
    case 2: { // Echo
        const float angle = controls.y * 6.2831853;
        const float distanceValue = controls.x * 0.20;
        const float2 offset = float2(cos(angle), sin(angle)) * distanceValue;
        const float3 history = gvCameraSample(historyTexture, uv - offset);
        result = mix(current, history, controls.z * 0.92);
        break;
    }
    case 3: { // Freeze
        float3 frozen = gvCameraSample(historyTexture, uv);
        float3 hsv = gvCameraRGBToHSV(frozen);
        hsv.x = fract(hsv.x + (controls.y - 0.5) * 0.16);
        frozen = gvCameraHSVToRGB(hsv);
        const float noise = (gvCameraHash(float2(position) + floor(time * 12.0)) - 0.5) *
            controls.z * 0.24;
        result = mix(current, saturate(frozen + noise), controls.x);
        break;
    }
case 4: { // Datamosh - stateful macroblock transport
        // The previous OUTPUT is the reference: each block carries a
        // transport vector with momentum, and either obeys a refresh
        // decision (fresh source pixels) or keeps carrying displaced,
        // progressively staler history. Corruption compounds frame over
        // frame because the history this mode reads is its own output —
        // held or not. DECAY deepens staleness and thins refresh; BLOCK
        // sets the macroblock size; FLOW scales motion into displacement.
const GVMoshControls mosh = GVMoshControls{
            mix(8.0, 64.0, controls.z),
            mix(0.4, 6.0, controls.x),
            mix(0.55, 0.93, controls.y),
            mix(0.50, 0.045, controls.y),
            mix(0.25, 1.5, controls.y),
            0.35,
            0.9
        };
	        result = gvMoshTransport(
	            mosh, current, historyTexture, moshStateIn, moshStateOut,
	            flow, flowReady, uniforms.touch, uniforms.touchImpact, uniforms.touchDrag,
	            holdActive, holdStyle, holdSeconds, time, dt, uv, size, position
	        );
	        break;
	    }
	    case 5: { // Sort
	        const float row = floor(uv.y * mix(18.0, 160.0, controls.y));
	        const float rank = fract(row * 0.6180339 + time * 0.09);
	        const float2 delta = float2(mix(2.0, 48.0, controls.x) * texel.x, 0.0);
	        const float3 sorted = gvCameraLumaRankedSample(historyTexture, uv, delta, rank);
	        result = mix(current, sorted, controls.z);
	        break;
	    }
	    case 6: { // Depth sort
	        const float depth = gvCameraLuma(current);
	        const float gate = smoothstep(controls.y, controls.y + 0.22, depth);
	        const float2 offset = float2(0.0, (depth - 0.5) * controls.x * 0.34);
	        const float3 sorted = gvCameraSample(historyTexture, uv + offset);
	        result = mix(current, sorted, gate * controls.z);
	        break;
	    }
	    case 7: { // Object sort
	        const float left = gvCameraLuma(gvCameraSample(inputTexture, uv - float2(texel.x * 2.0, 0.0)));
	        const float right = gvCameraLuma(gvCameraSample(inputTexture, uv + float2(texel.x * 2.0, 0.0)));
	        const float top = gvCameraLuma(gvCameraSample(inputTexture, uv - float2(0.0, texel.y * 2.0)));
	        const float bottom = gvCameraLuma(gvCameraSample(inputTexture, uv + float2(0.0, texel.y * 2.0)));
	        const float edge = length(float2(right - left, bottom - top));
	        const float mask = smoothstep(mix(0.015, 0.22, controls.y), mix(0.04, 0.34, controls.y), edge);
	        const float2 delta = normalize(float2(right - left, bottom - top) + float2(0.0001)) * controls.x * 0.18;
	        const float3 sorted = gvCameraLumaRankedSample(historyTexture, uv, delta, fract(time * 0.11 + edge));
	        result = mix(current, sorted, mask * controls.z);
	        break;
	    }
	    case 8: { // Radial sort
	        const float2 centered = uv - 0.5;
	        const float radius = length(centered);
	        const float2 direction = radius > 0.0001 ? centered / radius : float2(1.0, 0.0);
	        const float spin = (controls.y - 0.5) * time * 0.34;
	        const float2 radial = gvCameraRotate(direction, spin) * texel * mix(4.0, 86.0, controls.x);
	        const float rank = fract(radius * mix(6.0, 80.0, controls.x) + time * 0.08);
	        const float3 sorted = gvCameraLumaRankedSample(historyTexture, uv, radial, rank);
	        result = mix(current, sorted, controls.z);
	        break;
	    }
	    case 9: { // Temporal pixel sort
	        const float3 history = gvCameraSample(historyTexture, uv);
	        const float delta = abs(gvCameraLuma(current) - gvCameraLuma(history));
	        const float gate = holdActive
	            ? 1.0
	            : max(0.24, smoothstep(mix(0.01, 0.32, controls.y), mix(0.06, 0.46, controls.y), delta));
	        const float2 sortStep = float2(texel.x * mix(3.0, 64.0, controls.x), texel.y * mix(0.0, 10.0, controls.x));
	        const float rank = fract(delta * 11.0 + time * 0.13 + uv.y);
	        const float3 sorted = gvCameraLumaRankedSample(historyTexture, uv, sortStep, rank);
	        result = mix(current, sorted, gate * controls.z);
	        break;
	    }
	    case 10: { // Point-cloud smear
	        const float cellSize = mix(5.0, 34.0, controls.x);
	        const float2 cell = floor(float2(position) / cellSize);
	        const float2 local = fract(float2(position) / cellSize) - 0.5;
	        const float pointMask = 1.0 - smoothstep(0.12, 0.48, length(local));
	        const float jitter = gvCameraHash(cell + float2(floor(time * 10.0)));
	        const float luma = gvCameraLuma(gvCameraSample(historyTexture, uv));
	        const float2 smear = float2(jitter - 0.5, luma - 0.5) * controls.z * 0.28;
	        const float3 cloud = gvCameraSample(historyTexture, uv + smear);
	        result = mix(current * 0.58, cloud, pointMask * mix(0.35, 1.0, controls.y));
	        break;
	    }
	    case 11: { // Depth feedback
	        const float luma = gvCameraLuma(current);
	        const float2 centered = uv - 0.5;
	        const float zoom = mix(-0.08, 0.22, controls.y) * (luma - 0.15);
	        const float2 historyUV = centered * (1.0 + zoom + controls.x * luma * 0.28) + 0.5;
	        const float3 history = gvCameraSample(historyTexture, historyUV);
	        result = mix(current, history, controls.z);
	        break;
	    }
	    case 12: { // Freeze brush
	        const float2 brush = uniforms.touch.xy;
	        const float radius = mix(0.08, 0.42, controls.x);
	        const float mask = uniforms.touch.w * (1.0 - smoothstep(radius * 0.72, radius, distance(uv, brush)));
	        const float3 held = gvCameraSample(historyTexture, uv + float2(sin(time + uv.y * 12.0), cos(time + uv.x * 10.0)) * 0.006);
	        result = mix(current, held, max(mask, holdActive ? controls.z : 0.0));
	        break;
	    }
	    case 13: { // Sort brush
	        const float2 brush = uniforms.touch.xy;
	        const float radius = mix(0.07, 0.36, controls.x);
	        const float mask = uniforms.touch.w * (1.0 - smoothstep(radius * 0.72, radius, distance(uv, brush)));
	        const float2 direction = normalize((uv - brush) + float2(0.0001)) * texel * mix(4.0, 76.0, controls.y);
	        const float3 sorted = gvCameraLumaRankedSample(historyTexture, uv, direction, fract(time * 0.17 + uv.x + uv.y));
	        result = mix(current, sorted, mask * controls.z);
	        break;
	    }
	    case 14: { // Feedback tunnel
	        float2 centered = uv - 0.5;
	        centered = gvCameraRotate(centered, (controls.y - 0.5) * 0.12 + sin(time * 0.23) * 0.035);
	        const float pull = mix(-0.04, 0.18, controls.x);
	        const float2 historyUV = centered * (1.0 + pull) + 0.5;
	        const float3 history = gvCameraSample(historyTexture, historyUV) * mix(0.72, 1.04, controls.z);
	        result = max(current * 0.74, history);
	        break;
	    }
	    case 15: { // Luma extrusion
	        const float luma = gvCameraLuma(current);
	        const float gate = smoothstep(controls.y, controls.y + 0.20, luma);
	        const float2 offset = float2(0.0, -luma * controls.x * 0.34);
	        const float3 extruded = max(current, gvCameraSample(historyTexture, uv + offset));
	        result = mix(current, extruded, gate * controls.z);
	        break;
	    }
	    case 16: { // Optical-flow liquid approximation
	        const float3 history = gvCameraSample(historyTexture, uv);
	        const float motion = holdActive ? 0.18 : gvCameraLuma(abs(current - history));
	        const float2 flow = float2(
	            gvCameraLuma(gvCameraSample(historyTexture, uv + float2(texel.x * 3.0, 0.0))) -
	                gvCameraLuma(gvCameraSample(historyTexture, uv - float2(texel.x * 3.0, 0.0))),
	            gvCameraLuma(gvCameraSample(historyTexture, uv + float2(0.0, texel.y * 3.0))) -
	                gvCameraLuma(gvCameraSample(historyTexture, uv - float2(0.0, texel.y * 3.0)))
	        );
	        const float2 liquidUV = uv - flow * controls.x * 0.42 + float2(sin(uv.y * 14.0 + time), cos(uv.x * 12.0 - time)) * controls.y * motion * 0.035;
	        const float3 liquid = gvCameraSample(historyTexture, liquidUV);
	        result = mix(current, liquid, max(0.20, smoothstep(0.02, 0.22, motion)) * controls.z);
	        break;
	    }
	    case 17: { // Rolling time
	        const float bands = floor(mix(3.0, 34.0, controls.y));
	        const float band = floor(uv.y * bands);
	        const float phase = fract(band * 0.137 + time * mix(0.04, 0.62, controls.x));
	        const float2 offset = float2((phase - 0.5) * controls.x * 0.22, 0.0);
	        const float3 rolled = gvCameraSample(historyTexture, uv + offset);
	        result = mix(current, rolled, controls.z);
	        break;
	    }
	    case 18: { // Frame-hold smear
	        const float angle = controls.y * 6.2831853;
	        const float2 direction = float2(cos(angle), sin(angle));
	        const float2 block = floor(float2(position) / mix(6.0, 52.0, controls.z));
	        const float stagger = gvCameraHash(block + floor(time * 5.0)) - 0.5;
	        const float2 offset = direction * controls.z * (0.06 + controls.x * 0.24) * stagger;
	        const float3 held = gvCameraSample(historyTexture, uv + offset);
	        result = mix(current, held, controls.x);
	        break;
	    }
	    case 19: { // Pixel gravity
	        const float luma = gvCameraLuma(current);
	        const float2 cell = floor(float2(position) / mix(3.0, 18.0, controls.y));
	        const float drift = fract(time * mix(0.05, 0.70, controls.x) + gvCameraHash(cell));
	        const float drop = (1.0 - luma) * controls.x * (0.04 + drift * 0.30);
	        const float sway = (gvCameraHash(cell + float2(19.0)) - 0.5) * controls.y * 0.045;
	        const float3 fallen = gvCameraSample(historyTexture, uv - float2(sway, drop));
	        result = mix(current, fallen, controls.z);
	        break;
	    }
	    case 20: { // Pixel shift
	        const float bands = floor(mix(5.0, 56.0, controls.y));
	        const float band = floor(uv.y * bands);
	        const float tick = floor(time * (holdActive ? 16.0 : 9.0));
	        const float direction = gvCameraHash(float2(band, tick)) > 0.5 ? 1.0 : -1.0;
	        const float gate = step(0.36, gvCameraHash(float2(tick + 13.0, band)));
	        const float offset = direction * gate * controls.x * mix(0.015, 0.34, gvCameraHash(float2(band + 7.0, tick)));
	        const float2 shiftedUV = float2(fract(uv.x + offset), uv.y);
	        const float channel = texel.x * mix(2.0, 26.0, controls.x) * gate;
	        const float3 shifted = float3(
	            gvCameraSample(historyTexture, shiftedUV + float2(channel, 0.0)).r,
	            gvCameraSample(historyTexture, shiftedUV).g,
	            gvCameraSample(historyTexture, shiftedUV - float2(channel, 0.0)).b
	        );
	        result = mix(current, shifted, controls.z * mix(0.48, 1.0, gate));
	        break;
	    }
	    case 21: { // Slit scan
	        const float width = mix(0.018, 0.18, controls.y);
	        const float scanner = fract(time * mix(0.04, 0.72, controls.x));
	        const float distanceFromSlit = abs(uv.y - scanner);
	        const float slit = 1.0 - smoothstep(width * 0.55, width, distanceFromSlit);
	        const float band = floor(uv.y / max(width, 0.001));
	        const float2 offset = float2(
	            (gvCameraHash(float2(band, floor(time * 5.0))) - 0.5) * controls.x * 0.22,
	            (scanner - 0.5) * controls.x * 0.08
	        );
	        const float3 timeSlice = gvCameraSample(historyTexture, uv + offset);
	        result = mix(current, timeSlice, max(slit, 0.18) * controls.z);
	        break;
	    }
	    case 22: { // Motion bloom
	        const float3 history = gvCameraSample(historyTexture, uv);
	        const float motion = gvCameraLuma(abs(current - history));
	        const float gate = smoothstep(0.012, mix(0.08, 0.34, controls.y), motion);
	        const float2 radius = texel * mix(2.0, 36.0, controls.y) * (1.0 + uniforms.audio.y * 2.0);
	        float3 bloom = float3(0.0);
	        bloom += gvCameraSample(historyTexture, uv + float2(radius.x, 0.0));
	        bloom += gvCameraSample(historyTexture, uv - float2(radius.x, 0.0));
	        bloom += gvCameraSample(historyTexture, uv + float2(0.0, radius.y));
	        bloom += gvCameraSample(historyTexture, uv - float2(0.0, radius.y));
	        bloom *= 0.25 * mix(0.7, 2.4, controls.x);
	        result = mix(current, max(current, bloom), max(gate, uniforms.audio.x * 0.18) * controls.z);
	        break;
	    }
	    case 23: { // Audio bloom - energy halo driven by the live spectrum
	        const float energy = saturate(uniforms.audio.x * 0.7 + uniforms.audio.y * 1.1);
	        const float2 haloRadius = texel * mix(3.0, 44.0, controls.y) * (0.35 + energy * 1.9);
	        float3 halo = float3(0.0);
	        halo += gvCameraSample(historyTexture, uv + float2(haloRadius.x, 0.0));
	        halo += gvCameraSample(historyTexture, uv - float2(haloRadius.x, 0.0));
	        halo += gvCameraSample(historyTexture, uv + float2(0.0, haloRadius.y));
	        halo += gvCameraSample(historyTexture, uv - float2(0.0, haloRadius.y));
	        halo += gvCameraSample(historyTexture, uv + haloRadius * 0.71);
	        halo += gvCameraSample(historyTexture, uv - haloRadius * 0.71);
	        halo *= (1.0 / 6.0) * mix(0.6, 2.6, controls.x);
	        result = mix(current, max(current, halo * float3(0.86, 0.62, 1.0)), energy * controls.z);
	        break;
	    }
	    case 24: { // Audio kick - bass transients stutter the frame
	        const float kick = saturate((uniforms.audio.y - mix(0.55, 0.12, controls.y)) * 3.4);
	        const float2 punch = (uv - 0.5) * (1.0 + kick * 0.05 * controls.x) + 0.5;
	        const float3 held = gvCameraSample(historyTexture, punch);
	        result = mix(current, mix(current, held, kick * controls.x), controls.z);
	        break;
	    }
	    case 25: { // Frame tear - horizontal bands running on split clocks
	        // Each band picks one of the ring taps, so the bands genuinely
	        // hold different moments rather than being offset copies of now.
	        const float bands = floor(mix(3.0, 42.0, controls.y));
	        const float band = floor(uv.y * bands);
	        const float drift = (controls.z - 0.5) * 2.0;
	        const float wander = sin(time * (0.6 + drift * 1.7) + band * 2.39);
	        const float pick = gvCameraHash(float2(band, floor(time * mix(0.4, 9.0, controls.z))));
	        // Slip the band sideways by an amount tied to its own age, which is
	        // what sells the bands as separate scanout passes.
	        const float slip = (pick - 0.5) * controls.x * 0.34 * (0.35 + abs(wander));
	        const float2 bandUV = float2(fract(uv.x + slip), uv.y);
	        float3 aged;
	        if (pick < 0.30) {
	            aged = gvCameraSample(tap0, bandUV);
	        } else if (pick < 0.58) {
	            aged = gvCameraSample(tap1, bandUV);
	        } else if (pick < 0.82) {
	            aged = gvCameraSample(tap2, bandUV);
	        } else {
	            aged = gvCameraSample(tap3, bandUV);
	        }
	        // Some bands stay live so the tear reads against a stable reference.
	        const float torn = step(1.0 - controls.x, gvCameraHash(float2(band * 0.71, 3.1)));
	        result = mix(current, aged, torn * touchIntensity);
	        break;
	    }
	    case 26: { // Buffer underrun - blocks that miss their refresh
	        // Blocks hold real historical imagery. The age a block is stuck at
	        // is derived from its own hash and a slow clock, so neighbours
	        // recover independently instead of flickering in unison.
	        const float blockSize = mix(8.0, 96.0, controls.y);
	        const float2 block = floor(float2(position) / blockSize);
	        const float clock = floor(time * mix(6.0, 0.7, controls.z));
	        const float roll = gvCameraHash(block * 0.37 + clock * 0.19);
	        const float stale = step(1.0 - controls.x, roll);
	        const float age = gvCameraHash(block * 1.93 + clock * 0.07);
	        float3 held;
	        if (age < 0.28) {
	            held = gvCameraSample(tap0, uv);
	        } else if (age < 0.55) {
	            held = gvCameraSample(tap1, uv);
	        } else if (age < 0.80) {
	            held = gvCameraSample(tap2, uv);
	        } else {
	            held = gvCameraSample(tap3, uv);
	        }
	        result = mix(current, held, stale * touchIntensity);
	        break;
	    }
	    case 27: { // Packet loss - regions drop, stale, smear or collapse
	        const float blockSize = mix(6.0, 64.0, controls.y);
	        const float2 block = floor(float2(position) / blockSize);
	        // Bursts: a row-wide seed gates the per-block seed, so losses
	        // arrive in runs the way real dropped packets do rather than as
	        // uniform salt.
	        const float burstSeed = gvCameraHash(float2(block.y, floor(time * 3.1)));
	        const float burst = step(1.0 - mix(0.15, 1.0, controls.y), burstSeed);
	        const float roll = gvCameraHash(block * 0.83 + floor(time * 5.0) * 0.31);
	        const float lost = step(1.0 - controls.x, roll) * max(burst, 0.35);
	        if (lost > 0.0) {
	            const float mode = gvCameraHash(block * 2.71);
	            float3 replacement;
	            if (mode < 0.34) {
	                // Stale: the block keeps an older frame entirely.
	                replacement = gvCameraSample(tap2, uv);
	            } else if (mode < 0.67) {
	                // Neighbour collapse: the block takes the one beside it.
	                const float2 donor = (block + float2(-1.0, 0.0)) * blockSize / size;
	                replacement = gvCameraSample(tap1, donor);
	            } else {
	                // Smear: the block is dragged from its own left edge.
	                const float2 edge = float2(block.x * blockSize / size.x, uv.y);
	                replacement = gvCameraSample(tap1, mix(edge, uv, 1.0 - controls.z));
	            }
	            result = mix(current, replacement, saturate(lost * touchIntensity));
	        }
	        break;
	    }
	    case 28: { // Chroma failure - colour belongs to an older frame
	        // Luma is taken live and chroma from the ring, so the image can
	        // stay sharp while its colour visibly lags. Cb and Cr are pulled
	        // from different taps and offset independently.
	        const float delay = controls.x;
	        const float2 drift = float2(sin(time * 0.7), cos(time * 0.53)) *
	            (controls.y - 0.5) * 0.06;
	        const float3 lumaSource = current;
	        const float3 cbSource = gvCameraSample(delay < 0.5 ? tap1 : tap2, uv + drift);
	        const float3 crSource = gvCameraSample(delay < 0.5 ? tap2 : tap3, uv - drift);
	        // Rec.709 luma/chroma split, reassembled from three different
	        // moments. Working in YCbCr rather than RGB is what makes this read
	        // as a colour-subcarrier fault instead of a channel offset.
	        const float yNow = gvCameraLuma(lumaSource);
	        const float cbValue = (cbSource.b - dot(cbSource, float3(0.299, 0.587, 0.114))) * 0.564;
	        const float crValue = (crSource.r - dot(crSource, float3(0.299, 0.587, 0.114))) * 0.713;
	        float3 rebuilt = float3(
	            yNow + 1.402 * crValue,
	            yNow - 0.344136 * cbValue - 0.714136 * crValue,
	            yNow + 1.772 * cbValue
	        );
	        // Smear pulls the chroma along its own drift for a few taps.
	        if (controls.z > 0.01) {
	            float3 trail = rebuilt;
	            for (uint i = 1; i <= 4; ++i) {
	                const float3 s = gvCameraSample(tap2, uv - drift * float(i) * 2.0);
	                trail += s * (0.25 * controls.z);
	            }
	            rebuilt = mix(rebuilt, trail / (1.0 + controls.z), controls.z);
	        }
	        result = mix(current, saturate(rebuilt), saturate(delay * 1.15) * touchIntensity);
	        break;
	    }
	    case 29: { // Sensor smear - highlight charge bleeding down the sensor
	        // Vertical charge transfer: only pixels above threshold contribute,
	        // and the streak accumulates upward through the column so bright
	        // sources rip a trail through everything beneath them.
	        const float threshold = mix(0.95, 0.18, controls.x);
	        const float reach = mix(0.01, 0.42, controls.y);
	        float3 bleed = float3(0.0);
	        float weightSum = 0.0;
	        const uint taps = 18u;
	        for (uint i = 1u; i <= taps; ++i) {
	            const float t = float(i) / float(taps);
	            const float2 sampleUV = float2(uv.x, uv.y - t * reach);
	            const float3 s = gvCameraSample(inputTexture, sampleUV);
	            const float lum = gvCameraLuma(s);
	            const float over = max(lum - threshold, 0.0) / max(1.0 - threshold, 0.001);
	            const float weight = over * (1.0 - t);
	            bleed += s * weight;
	            weightSum += weight;
	        }
	        if (weightSum > 0.0001) {
	            bleed /= weightSum;
	            const float strength = saturate(weightSum / float(taps) * 6.0);
	            // Persistence: the previous frame's smear is retained so a
	            // moving light leaves a wake rather than a static bar.
	            const float3 previous = gvCameraSample(historyTexture, uv);
	            const float3 wake = mix(bleed, previous, controls.z * 0.62);
	            result = current + wake * strength * mix(0.4, 2.6, controls.y) * touchIntensity;
	        }
	        result = saturate(result);
	        break;
	    }
	    case 30: { // Causal smear - corruption arrives ahead of the motion
	        // Every other motion effect trails backward: it samples where a
	        // thing was. This samples where a thing is GOING. The flow vector
	        // is extrapolated forward along its own trajectory, and the scene
	        // at that predicted location is corrupted before the subject
	        // arrives. Raise an arm and the wall above it starts melting
	        // before the hand gets there.
	        const float horizon = mix(1.0, 14.0, controls.x);
	        const float gain = mix(0.5, 5.0, controls.y);
	        const float spread = mix(0.004, 0.06, controls.z);

	        // Look backward along the flow to find the motion that is heading
	        // into this pixel. If a strong vector upstream points at us, this
	        // pixel is about to be reached.
	        float3 arriving = float3(0.0);
	        float weight = 0.0;
	        for (uint step = 1u; step <= 5u; ++step) {
	            const float t = float(step) / 5.0;
	            const float2 probe = uv - flow * horizon * t;
	            const float2 probeFlow = flowReady
	                ? gvCameraSampleVector(flowField, probe)
	                : float2(0.0);
	            // Does this upstream vector point toward us?
	            const float2 toHere = uv - probe;
	            const float alignment = dot(normalize(probeFlow + 1e-6), normalize(toHere + 1e-6));
	            const float strength = length(probeFlow) * saturate(alignment);
	            if (strength > 0.0) {
	                // Uncertainty grows with distance into the future, so the
	                // prediction blurs out rather than staying crisp — which is
	                // what makes it read as anticipation rather than a copy.
	                const float2 jitter = float2(
	                    gvCameraHash(float2(position) * 0.013 + t),
	                    gvCameraHash(float2(position) * 0.017 - t)
	                ) - 0.5;
	                arriving += gvCameraSample(inputTexture, probe + jitter * spread * t);
	                weight += strength * (1.0 - t * 0.5);
	            }
	        }
	        if (weight > 0.0001) {
	            arriving /= max(weight, 0.0001) * 5.0;
	            const float presence = saturate(weight * gain * 6.0);
	            result = mix(current, saturate(arriving), presence * touchIntensity);
	        }
	        break;
	    }
	    case 31: { // Reality cavitation - fast motion punches holes
	        // Above a velocity threshold the image is not distorted, it is
	        // removed, and what shows through is an older frame. The void has
	        // a lit rim so it reads as material torn away rather than as a
	        // region that was simply dimmed.
	        const float threshold = mix(0.05, 0.005, controls.x);
	        const float size = mix(1.0, 5.0, controls.y);
	        const float residue = controls.z;

	        const float speed = flowMagnitude * size;
	        const float cavity = smoothstep(threshold, threshold * 3.0, speed);
	        if (cavity > 0.001) {
	            // Exposed layer deepens with speed: a fast movement tears
	            // through to older material than a slow one.
	            const float3 exposed = speed > threshold * 6.0
	                ? gvCameraSample(tap3, uv)
	                : gvCameraSample(tap1, uv);
	            // Rim: the boundary of the void catches light.
	            const float rim = smoothstep(0.75, 1.0, cavity) * (1.0 - smoothstep(0.92, 1.0, cavity));
	            float3 hole = mix(exposed * (1.0 - residue * 0.55), float3(0.0), cavity * 0.35);
	            hole += float3(0.55, 0.30, 0.95) * rim * 1.4;
	            result = mix(current, hole, cavity * touchIntensity);
	        }
	        break;
	    }
	    case 32: { // Time fracture - a mosaic of incompatible timelines
	        // Voronoi cells rather than bands or blocks, because rectangles
	        // read as a digital artefact while irregular cells read as reality
	        // itself having come apart. Each cell carries its own timestamp
	        // and its own flow gain.
	        const float density = mix(3.0, 16.0, controls.x);
	        float2 cellUV = uv * density;
	        float2 base = floor(cellUV);
	        float nearest = 1e6;
	        float2 winner = base;
	        for (int y = -1; y <= 1; ++y) {
	            for (int x = -1; x <= 1; ++x) {
	                const float2 neighbour = base + float2(x, y);
	                // Sites drift slowly, so the mosaic reorganises rather
	                // than sitting as a fixed pattern.
	                const float2 jitter = float2(
	                    gvCameraHash(neighbour),
	                    gvCameraHash(neighbour + 41.0)
	                );
	                const float2 site = neighbour + 0.5 +
	                    (jitter - 0.5) * (0.8 + sin(time * 0.25 + jitter.x * 6.28) * controls.z * 0.5);
	                const float distance = length(site - cellUV);
	                if (distance < nearest) {
	                    nearest = distance;
	                    winner = neighbour;
	                }
	            }
	        }
	        const float pick = gvCameraHash(winner * 1.77);
	        const float2 cellFlow = flow * mix(0.0, 6.0, gvCameraHash(winner * 3.1)) * controls.y;
	        const float2 cellUVSample = uv - cellFlow;
	        float3 cell;
	        if (pick < 0.25) {
	            cell = gvCameraSample(inputTexture, cellUVSample);
	        } else if (pick < 0.50) {
	            cell = gvCameraSample(tap0, cellUVSample);
	        } else if (pick < 0.72) {
	            cell = gvCameraSample(tap1, cellUVSample);
	        } else if (pick < 0.90) {
	            cell = gvCameraSample(tap2, cellUVSample);
	        } else {
	            cell = gvCameraSample(tap3, cellUVSample);
	        }
	        result = mix(current, cell, touchIntensity);
	        break;
	    }
	    case 33: { // Anti-camera - only change is drawn
	        // A camera that refuses to show anything that is not happening.
	        // Static regions fall away toward black and motion rebuilds them.
	        // INVERT flips the rule so movement is what disappears, and the
	        // still world is all that survives.
	        const float gate = mix(0.002, 0.04, 1.0 - controls.x);
	        const float persist = controls.y;
	        const float invert = controls.z;

	        // Change is measured two ways: the flow field catches coherent
	        // movement, and a luma difference against history catches change
	        // that produced no usable vector, such as a light switching on.
	        const float3 past = gvCameraSample(tap1, uv);
	        const float lumaDelta = abs(gvCameraLuma(current) - gvCameraLuma(past));
	        const float change = saturate(max(flowMagnitude / gate, lumaDelta * 8.0));
	        const float presence = mix(change, 1.0 - change, invert);

	        // Persistence keeps a decaying trace, so a hand moving through
	        // frame leaves a wake instead of a hard silhouette.
	        const float3 trace = gvCameraSample(historyTexture, uv) * persist;
	        result = max(current * presence, trace * 0.92);
	        break;
	    }
	    case 34: { // Memory burn-in - stable regions engrave themselves
	        // Where nothing has moved for a while, the image sets. That burnt
	        // material then resists being replaced, so panning away leaves the
	        // ghost of what was there while the new scene fills in around it.
	        // Motion is what erases it.
	        const float burn = controls.x;
	        const float hold = controls.y;
	        const float erase = mix(1.0, 14.0, controls.z);

	        // Stillness is the inverse of local motion. Accumulated in the
	        // feedback texture, which is already a per-pixel store updated
	        // every frame — no second buffer needed for this.
	        const float stillness = 1.0 - saturate(flowMagnitude * erase * 40.0);
	        const float3 engraved = gvCameraSample(historyTexture, uv);

	        // The burnt layer only strengthens where the scene is still, and
	        // only releases where it moves.
	        const float retention = saturate(stillness * hold * 1.4 + burn * 0.35);
	        const float3 held = mix(current, engraved, retention);
	        // Slight bloom on the burn so the ghost reads as phosphor rather
	        // than as a dirty lens.
	        const float ghost = saturate(gvCameraLuma(engraved) - gvCameraLuma(current));
	        result = held + float3(0.42, 0.22, 0.62) * ghost * retention * 0.45;
	        break;
	    }
	    case 35: { // Spectral depth - channels separated by time, not offset
	        // An RGB split where the channels are not moved sideways but taken
	        // from different moments and displaced along their own motion. The
	        // ghosting therefore has real spatial structure: it follows what
	        // actually moved rather than smearing the whole frame.
	        const float split = controls.x;
	        const float reach = mix(0.0, 5.0, controls.y);

	        const float2 redUV = uv - flow * reach * 0.3;
	        const float2 greenUV = uv - flow * reach * 1.0;
	        const float2 blueUV = uv - flow * reach * 2.2;

	        const float red = gvCameraSample(inputTexture, redUV).r;
	        const float green = gvCameraSample(split < 0.5 ? tap0 : tap1, greenUV).g;
	        const float blue = gvCameraSample(split < 0.5 ? tap1 : tap3, blueUV).b;

	        result = mix(current, float3(red, green, blue), saturate(split * 1.3) * touchIntensity);
	        break;
	    }
	    case 36: { // Vector necromancy - resurrecting dead motion
	        // The flow field holds one present. This reaches for motion that
	        // has already died: differences between history taps are read back
	        // as vectors and driven into the current frame, so movement that
	        // happened seconds ago starts pushing pixels around now.
	        const float age = controls.x;
	        const float gain = mix(0.5, 8.0, controls.y);
	        const float cycle = controls.z;

	        // Reconstruct a vector from the luma gradient between two aged
	        // taps. Crude next to the live estimator, but it is measuring
	        // something the estimator no longer has: the past.
	        const float2 step = texel * 3.0;
	        const float3 oldA = age < 0.5 ? gvCameraSample(tap1, uv) : gvCameraSample(tap2, uv);
	        const float3 oldB = age < 0.5 ? gvCameraSample(tap2, uv) : gvCameraSample(tap3, uv);
	        const float dx =
	            gvCameraLuma(gvCameraSample(tap2, uv + float2(step.x, 0.0))) -
	            gvCameraLuma(gvCameraSample(tap2, uv - float2(step.x, 0.0)));
	        const float dy =
	            gvCameraLuma(gvCameraSample(tap2, uv + float2(0.0, step.y))) -
	            gvCameraLuma(gvCameraSample(tap2, uv - float2(0.0, step.y)));
	        const float delta = gvCameraLuma(oldA) - gvCameraLuma(oldB);
	        const float2 resurrected = float2(dx, dy) * delta * gain * 0.06;

	        // Cycling walks the graveyard, so held down it plays back a
	        // sequence of dead motions rather than one.
	        const float phase = fract(time * mix(0.05, 0.9, cycle));
	        const float2 driven = resurrected * (0.4 + phase * 1.2);
	        result = gvCameraSample(inputTexture, uv - driven);
	        break;
	    }
	    case 37: { // World feedback - trails that stay with the room
	        // The reprojection homography maps this frame's ray to where the
	        // same ray sat in the previous frame. Sampling the accumulation
	        // through it stops the buffer being screen-space: turning the phone
	        // slides the trail off the edge of the frame instead of dragging it
	        // along, so what was painted on a wall stays on that wall.
	        //
	        // This mode and TIME GRAFFITI were shipped with no shader arm at
	        // all - `uniforms.mode.x` fell straight through to `default` and
	        // the effect was a passthrough. The matrix was already being
	        // uploaded every frame with nothing reading it.
	        const float3 ray = float3(uv - 0.5, 1.0);
	        const float3 reprojected = uniforms.worldReprojection * ray;
	        const float2 anchoredUV = reprojected.xy / max(abs(reprojected.z), 1e-4) + 0.5;
	        const float3 anchored = gvCameraSample(historyTexture, anchoredUV);
	        // Blur is applied to the anchored read, not the live frame, so the
	        // softening accumulates with the trail rather than veiling the
	        // scene.
	        const float3 softened = mix(
	            anchored,
	            gvBlur(historyTexture, anchoredUV, texel * mix(0.6, 3.4, controls.z)),
	            controls.z
	        );
	        const float decay = mix(0.62, 0.995, controls.y);
	        result = max(current, softened * decay * mix(0.55, 1.15, controls.x));
	        break;
	    }
	    case 38: { // Time graffiti - painting held time onto the room
	        // The brush does not deposit the live frame. It deposits a slice
	        // pulled out of the ring at a chosen age, into a buffer that is
	        // world-anchored - so the mark is a piece of the past pinned to a
	        // physical surface, and it stays there when the phone moves.
	        const float3 ray = float3(uv - 0.5, 1.0);
	        const float3 reprojected = uniforms.worldReprojection * ray;
	        const float2 anchoredUV = reprojected.xy / max(abs(reprojected.z), 1e-4) + 0.5;
	        const float fade = mix(0.90, 0.9995, controls.z);
	        float3 canvas = gvCameraSample(historyTexture, anchoredUV) * fade;

	        const float radius = mix(0.04, 0.32, controls.x);
	        const float age = mix(0.15, 2.6, controls.y);
	        if (uniforms.touch.w > 0.5) {
	            const float brush = 1.0 -
	                smoothstep(radius * 0.5, radius, distance(uv, uniforms.touch.xy));
	            const float3 held = gvTemporalSample(
	                temporalRing, ringTimestamps, ringInfo, uv, age, current
	            );
	            canvas = mix(canvas, held, saturate(brush));
	        }
	        // A tap stamps a ring, so the surface can be marked without a drag.
	        if (uniforms.touchImpact.w > 0.5) {
	            const float stamp = 1.0 -
	                smoothstep(radius * 0.35, radius * 0.8, distance(uv, uniforms.touchImpact.xy));
	            const float3 held = gvTemporalSample(
	                temporalRing, ringTimestamps, ringInfo, uv, age, current
	            );
	            canvas = mix(canvas, held, saturate(stamp * exp(-uniforms.touchImpact.z * 1.6)));
	        }
	        result = max(current * 0.80, canvas);
	        break;
	    }
	    case 39: { // Liquid mosh - iterated advection through the block vector field
	        // Every step walks further back along the transport vectors AND
	        // samples the previous OUTPUT, so a pixel is rebuilt from the path
	        // its content travelled through its own corruption. That integration
	        // reads as liquid instead of as a block smear. INJECT decides how
	        // much live frame re-enters the flow; VISCOSITY weights the walk.
	        const float gain = mix(0.25, 2.2, controls.x);
	        const float viscosity = mix(0.35, 0.97, controls.y);
	        const float blockSize = mix(10.0, 30.0, controls.y);
	        const float2 blockPos = floor(float2(position) / blockSize);
	        const float2 blockId = blockPos + 0.5;
	        const float2 centreUV = (blockPos * blockSize + blockSize * 0.5) / size;
	        const GVMoshState previous = gvMoshReadState(moshStateIn, centreUV);

	        const float2 vector = gvMoshUpdateVector(
	            previous.vector, flow, flowReady, gain, mix(0.60, 0.94, controls.y), 0.2,
	            uniforms.touch, uniforms.touchImpact, uniforms.touchDrag,
	            holdActive, holdStyle, holdSeconds, blockId, centreUV, time, dt
	        );

	        float2 trace = uv;
	        float3 accumulated = float3(0.0);
	        float weightSum = 0.0;
	        for (int index = 0; index < 5; index++) {
	            const float2 cellVector = gvCameraSampleVector(moshStateIn, clamp(trace, 0.0, 1.0));
	            trace = clamp(trace - cellVector, 0.001, 0.999);
	            const float weight = pow(viscosity, float(index));
	            accumulated += gvCameraSample(historyTexture, trace) * weight;
	            weightSum += weight;
	        }
	        float3 liquid = accumulated / max(weightSum, 1e-4);
	        // Staleness deepens the longer the field has been running, so held
	        // frames darken and quantise instead of smearing forever.
	        const float staleness = min(previous.staleness + dt * mix(0.18, 0.72, controls.y), 1.0);
	        liquid = gvMoshStaleColor(liquid, staleness, blockId, time);

	        float injection = mix(0.01, 0.58, controls.z);
	        if (holdActive && (holdStyle & 4u) != 0u) {
	            injection *= exp(-holdSeconds * 0.55);   // FEEDBACK RUNAWAY
	        }
	        // INJECT is genuinely source injection: zero leaves the recursive
	        // liquid prediction alone, one continually repairs it with camera.
	        // Motion increases corruption, never the amount of fresh source.
	        const float liquidPresence = saturate(0.62 + length(vector) * 16.0);
	        result = mix(current, mix(liquid, current, injection), liquidPresence);

	        if (all((position & uint2(7)) == uint2(0))) {
	            moshStateOut.write(
	                half4(half2(vector), half(staleness), half(floor(time * 11.0))),
	                position >> 3
	            );
	        }
	        break;
	    }
	    case 40: { // Heavy mosh - the reference frame never refreshes
	        // The difference from DATAMOSH is not a larger number, it is that
	        // no fresh pixel is ever injected: refreshChance is zero. A decoder
	        // that has lost its I-frame keeps applying motion vectors to a
	        // reference nothing is correcting, so the image is rebuilt entirely
	        // out of its own stale output and drifts further from the scene the
	        // longer it runs. GAIN scales the vectors, BLOCK sets the grid, ROT
	        // mutates the prediction field over time.
const GVMoshControls mosh = GVMoshControls{
            mix(8.0, 64.0, controls.y),
            mix(2.0, 14.0, controls.x),
            0.97,
            0.0,
            mix(0.6, 2.0, controls.z),
            mix(0.0, 1.4, controls.z),
            0.0
        };
	        result = gvMoshTransport(
	            mosh, current, historyTexture, moshStateIn, moshStateOut,
	            flow, flowReady, uniforms.touch, uniforms.touchImpact, uniforms.touchDrag,
	            holdActive, holdStyle, holdSeconds, time, dt, uv, size, position
	        );
	        break;
	    }
	    case 41: { // Mosh brush - motion painted by the finger
	        // The touch uniforms carry position and speed every frame, and
	        // strokes persist in the block state: drag and the stroke deposits
	        // displacement that keeps dragging history after the finger lifts,
	        // decaying with momentum instead of vanishing the moment the
	        // gesture ends. PUSH is stroke strength, REACH the brush radius,
	        // BLOCK the grid the strokes live on.
	        const float blockSize = mix(8.0, 40.0, controls.z);
	        const float reach = mix(0.06, 0.44, controls.y);
	        const float push = mix(0.02, 0.26, controls.x);
	        const float2 blockPos = floor(float2(position) / blockSize);
	        const float2 blockId = blockPos + 0.5;
	        const float2 centreUV = (blockPos * blockSize + blockSize * 0.5) / size;
	        const GVMoshState previous = gvMoshReadState(moshStateIn, centreUV);

	        float2 painted = float2(0.0);
	        if (uniforms.touch.w > 0.5 || uniforms.touchDrag.w > 0.5) {
	            const float2 toFinger = centreUV - uniforms.touch.xy;
	            const float span = length(toFinger);
	            const float falloff = 1.0 - smoothstep(reach * 0.35, reach, span);
	            const float2 direction = span > 1e-4 ? toFinger / span : float2(0.0);
	            // Radial push while the finger rests, directional drag while it
	            // moves.
	            painted = direction * saturate(uniforms.touch.z) * falloff * push;
	            painted += uniforms.touchDrag.xy * falloff * push * 8.0 * dt;
	        }
	        const float momentum = mix(0.82, 0.97, controls.z);
	        float2 vector = previous.vector * momentum + painted * (1.0 - momentum) * 10.0;
	        const float limit = 0.22;
	        const float magnitude = length(vector);
	        if (magnitude > limit) {
	            vector *= limit / magnitude;
	        }

	        const float staleness = min(previous.staleness + dt * 0.3, 1.0);
	        const float3 dragged = gvCameraSample(historyTexture, clamp(uv - vector, 0.001, 0.999));
	        const float3 carried = gvMoshStaleColor(dragged, staleness, blockId, time);
	        result = mix(current, carried, saturate(length(vector) * 22.0));

	        if (all((position & uint2(7)) == uint2(0))) {
	            moshStateOut.write(
	                half4(half2(vector), half(staleness), half(floor(time * 11.0))),
	                position >> 3
	            );
	        }
	        break;
	    }
	    case 42: { // Luma time map - brightness chooses how far back a pixel reaches
	        // Every other temporal mode reads history at one age for the whole
	        // frame. Here the age is per pixel, so a single image is assembled
	        // out of many different moments at once: highlights can sit in the
	        // present while shadows are seconds behind, or the reverse.
	        //
	        // `gvTemporalAge` is the shared curve for exactly this mapping. It
	        // was written, documented and then left with no caller.
	        const float depth = mix(0.05, 3.0, controls.x);
	        const float bias = controls.y;
	        const float contrast = mix(0.6, 5.0, controls.z);
	        const float age = gvTemporalAge(gvCameraLuma(current), depth, bias, contrast);
	        result = gvTemporalSample(
	            temporalRing, ringTimestamps, ringInfo, uv, age, current
	        );
	        break;
	    }
	    case 43: { // Prediction drift - differential-motion video feedback
        // Inspired by luma's differential-motion construction: compare the
        // live frame with a motion-compensated prediction, preserve the parts
        // that prediction explains, and feed the unexplained residual back as
        // new motion. Unlike a difference matte drawn over the camera, the
        // prediction is this Slot's previous output, so errors accumulate into
        // drifting decoder memory while stationary detail remains anchored.
        const float blockSize = mix(8.0, 36.0, controls.z);
        const float2 blockPos = floor(float2(position) / blockSize);
        const float2 blockId = blockPos + 0.5;
        const float2 centreUV = (blockPos * blockSize + blockSize * 0.5) / size;
        const GVMoshState previous = gvMoshReadState(moshStateIn, centreUV);

        const float3 priorPrediction = gvCameraSample(
            historyTexture,
            clamp(uv - previous.vector, 0.001, 0.999)
        );
        const float lumaResidual = abs(gvCameraLuma(current) - gvCameraLuma(priorPrediction));
        const float chromaResidual = length(current - priorPrediction) * 0.24;
        const float threshold = mix(0.20, 0.025, controls.z);
        const float differential = smoothstep(
            threshold * 0.35,
            threshold,
            lumaResidual + chromaResidual + flowMagnitude * 2.0
        );

        // Residual regions accept the new measured vector; predicted regions
        // retain their old vector and slowly rotate. DECAY controls how long a
        // correct prediction survives, DRIFT controls the mutation rate.
        const float gain = mix(1.0, 10.0, controls.x) * mix(0.28, 1.0, differential);
        float2 vector = gvMoshUpdateVector(
            previous.vector,
            flow,
            flowReady,
            gain,
            mix(0.74, 0.992, controls.y),
            mix(0.10, 2.1, controls.x) * (0.25 + differential),
            uniforms.touch,
            uniforms.touchImpact,
            uniforms.touchDrag,
            holdActive,
            holdStyle,
            holdSeconds,
            blockId,
            centreUV,
            time,
            dt
        );

        // Coherent row loss turns large residuals into prediction tears rather
        // than independent noisy pixels. The decision persists for several
        // frames, matching the cadence of a damaged inter-frame stream.
        const float row = floor(float(position.y) / blockSize);
        const float tearTick = floor(time * 9.0);
        const float tearDecision = gvCameraHash(float2(row, tearTick));
        const float tearGate = step(tearDecision, differential * controls.z * 0.72);
        const float tear = (gvCameraHash(float2(row, tearTick + 19.0)) - 0.5) *
            tearGate * mix(0.0, 0.12, controls.z);

        const float2 predictionUV = clamp(uv - vector + float2(tear, 0.0), 0.001, 0.999);
        float3 prediction = gvCameraSample(historyTexture, predictionUV);
        float staleness = previous.staleness;
        staleness = differential > 0.18
            ? max(staleness - dt * mix(0.4, 2.0, 1.0 - controls.y), 0.0)
            : min(staleness + dt * mix(0.10, 0.9, controls.y), 1.0);
        prediction = gvMoshStaleColor(prediction, staleness, blockId, time);

        // Only the differential can write substantial new image data. A tiny
        // floor prevents total lock-up when both the camera and field settle.
        const float sourceLeak = 0.025 + differential * mix(0.18, 0.72, 1.0 - controls.y);
        result = mix(prediction, current, sourceLeak);
        const float residualEdge = smoothstep(threshold, threshold * 2.4, lumaResidual);
        result += float3(0.08, 0.22, 0.42) * residualEdge * controls.x * 0.18;

        if (all((position & uint2(7)) == uint2(0))) {
            moshStateOut.write(
                half4(half2(vector), half(staleness), half(tearTick)),
                position >> 3
            );
        }
	        break;
	    }
    case 44: { // Vector codebook: quantize measured direction AND magnitude before transport.
        const uint2 stateCell = position >> 3;
        const float2 cellUV = (float2(stateCell * 8u) + 4.0) / size;
        const GVMoshState previous = gvMoshReadState(moshStateIn, cellUV);
        const float2 measured = flowReady ? gvCameraSampleVector(flowField, cellUV) : float2(0);
        const float directions = 2.0 + round(controls.x * 14.0);
        const float angleStep = 6.2831853 / directions;
        const float angle = round(atan2(measured.y, measured.x) / angleStep) * angleStep;
        const float magnitudeStep = mix(0.0005, 0.008, controls.y);
        const float magnitude = round(length(measured) / magnitudeStep) * magnitudeStep;
        const float2 coded = float2(cos(angle), sin(angle)) * magnitude;
        const float memory = pow(mix(0.35, 0.98, controls.z), dt * 60.0);
        const float2 vector = clamp(mix(coded * 4.0, previous.vector, memory), -0.08, 0.08);
        const float3 carried = gvCameraSample(historyTexture, clamp(uv - vector * dt * 60.0, 0.001, 0.999));
        result = mix(current, carried, mix(0.40, 0.985, controls.z));
        if (all((position & uint2(7)) == uint2(0)))
            moshStateOut.write(half4(half2(vector), half(length(measured)), 0), stateCell);
        break;
    }
    case 45: { // Transplant a stable permutation of measured donor-region flow.
        const float regions = 2.0 + round(controls.x * 6.0);
        const float2 region = min(floor(uv * regions), regions - 1.0);
        // Translation modulo N is bijective, has no fixed region, and remains
        // stable until REGION changes. Motion comes from this donor, never noise.
        const float2 donor = fmod(region + float2(1.0, ceil(regions * 0.5)), regions);
        const float2 donorUV = (donor + 0.5) / regions;
        const float2 measured = flowReady ? gvCameraSampleVector(flowField, donorUV) : float2(0);
        const float2 cellUV = (float2((position >> 3) * 8u) + 4.0) / size;
        const GVMoshState previous = gvMoshReadState(moshStateIn, cellUV);
        const float memory = pow(mix(0.25, 0.96, controls.z), dt * 60.0);
        const float2 vector = clamp(mix(measured * mix(1.0, 9.0, controls.y), previous.vector, memory), -0.1, 0.1);
        const float3 carried = gvCameraSample(historyTexture, clamp(uv - vector * dt * 60.0, 0.001, 0.999));
        result = mix(current, carried, mix(0.35, 0.99, controls.z));
        if (all((position & uint2(7)) == uint2(0)))
            moshStateOut.write(half4(half2(vector), half(length(measured)), 0), position >> 3);
        break;
    }
    case 46: { // Independent bit planes latch or refresh against motion.
        constexpr sampler nearest(coord::normalized, address::clamp_to_edge, filter::nearest);
        const uint planes = 1u + uint(round(controls.x * 7.0));
        const uint levels = (1u << planes) - 1u;
        const uint3 liveBits = uint3(round(saturate(current) * float(levels)));
        const uint3 memoryBits = uint3(round(saturate(float3(historyTexture.sample(nearest, uv).rgb)) * float(levels)));
        const float moving = smoothstep(0.0003, mix(0.02, 0.001, controls.z), flowMagnitude);
        const float refresh = 1.0 - pow(1.0 - mix(0.002, 0.28, controls.y) * (0.08 + moving * 0.92), dt * 60.0);
        const float tick = floor(time * 60.0);
        uint3 assembled = uint3(0);
        for (uint plane = 0; plane < 8; ++plane) {
            if (plane >= planes) break;
            const uint mask = 1u << plane;
            for (uint channel = 0; channel < 3; ++channel) {
                const float hash = gvCameraHash(float2(position >> 3) + float2(float(plane) * 19.17 + tick * 0.317, float(channel) * 31.73));
                const bool replace = hash < refresh * mix(1.6, 0.65, float(plane) / max(float(planes - 1u), 1.0));
                assembled[channel] |= (replace ? liveBits[channel] : memoryBits[channel]) & mask;
            }
        }
        result = float3(assembled) / float(levels);
        if (all((position & uint2(7)) == uint2(0)))
            moshStateOut.write(half4(0, 0, half(moving), half(planes)), position >> 3);
        break;
    }
	    default:
	        break;
	    }

    result = mix(current, result, saturate(uniforms.extra.x * touchIntensity));
    outputTexture.write(half4(half3(saturate(result)), 1.0h), position);
}

// MARK: - Signal fracture

struct GVFractureUniforms {
    float4 anchors;   // xy = finger A in texture UV, zw = finger B
    float4 geometry;  // x openness, y rotation, z velocity, w stillness
    float4 timing;    // x time, y repair, z break, w seam
    float4 viewport;  // x width, y height, z 1/width, w 1/height
    uint4 options;    // x tap count, y phase, z frame number, w reserved
};

/// Bounded downsampling copy used to age a frame into the temporal ring.
kernel void gvCameraHistoryTap(    texture2d<half, access::sample> inputTexture [[texture(0)]],
    texture2d<half, access::write> outputTexture [[texture(1)]],
    uint2 position [[thread_position_in_grid]]
) {
    if (position.x >= outputTexture.get_width() || position.y >= outputTexture.get_height()) {
        return;
    }
    const float2 uv = (float2(position) + 0.5) /
        float2(outputTexture.get_width(), outputTexture.get_height());
    outputTexture.write(inputTexture.sample(gvCameraLinearSampler, uv), position);
}

/// Zeroes the datamosh block-state field. Dispatched over both ping-pong
/// halves when the operator explicitly clears temporal memory (double tap):
/// vectors, staleness and refresh ticks all return to a clean decoder.
kernel void gvMoshClearState(
    texture2d<half, access::write> state [[texture(0)]],
    uint2 position [[thread_position_in_grid]]
) {
    if (position.x >= state.get_width() || position.y >= state.get_height()) {
        return;
    }
    state.write(half4(0.0h, 0.0h, 0.0h, 0.0h), position);
}

kernel void gvCameraCompositeWatermark(
    texture2d<half, access::sample> watermarkTexture [[texture(0)]],
    texture2d<half, access::read_write> frameTexture [[texture(1)]],
    uint2 position [[thread_position_in_grid]]
) {
    if (position.x >= watermarkTexture.get_width() || position.y >= watermarkTexture.get_height()) {
        return;
    }
    
    // Scale watermark to be resolution-independent? The UI is fixed size.
    // If the video is 1080p, maybe it's fine 1:1.
    // We'll let the Swift side handle size by creating the right size texture.
    const uint2 offset = uint2(48, 48); 
    const uint2 framePos = position + offset;
    
    if (framePos.x >= frameTexture.get_width() || framePos.y >= frameTexture.get_height()) {
        return;
    }
    
    const float2 uv = (float2(position) + 0.5) / 
        float2(watermarkTexture.get_width(), watermarkTexture.get_height());
    
    half4 watermark = watermarkTexture.sample(gvCameraLinearSampler, uv);
    if (watermark.a > 0.0) {
        half4 frame = frameTexture.read(framePos);
        half4 blended = watermark + frame * (1.0 - watermark.a);
        frameTexture.write(blended, framePos);
    }
}

float2 gvFractureHash2(float2 value) {
    const float first = gvCameraHash(value);
    const float second = gvCameraHash(value + float2(37.19, 11.71));
    return float2(first, second);
}

float3 gvFractureLayer(
    texture2d<half, access::sample> history0,
    texture2d<half, access::sample> history1,
    texture2d<half, access::sample> history2,
    texture2d<half, access::sample> history3,
    float2 uv,
    float depth,
    uint tapCount
) {
    // Depth into the tear selects progressively older frames. When the render
    // budget tightens `tapCount` drops and the deepest layers collapse into the
    // shallower ones instead of being sampled.
    const float tap = depth * float(max(tapCount, 1u));
    if (tapCount <= 1u || tap < 1.0) {
        return gvCameraSample(history0, uv);
    }
    if (tapCount <= 2u || tap < 2.0) {
        return gvCameraSample(history1, uv);
    }
    if (tapCount <= 3u || tap < 3.0) {
        return gvCameraSample(history2, uv);
    }
    return gvCameraSample(history3, uv);
}

// swiftlint:disable:next line_length
kernel void gvCameraSignalFracture(
    texture2d<half, access::sample> inputTexture [[texture(0)]],
    texture2d<half, access::sample> history0 [[texture(1)]],
    texture2d<half, access::sample> history1 [[texture(2)]],
    texture2d<half, access::sample> history2 [[texture(3)]],
    texture2d<half, access::sample> history3 [[texture(4)]],
    texture2d<half, access::write> outputTexture [[texture(5)]],
    constant GVFractureUniforms &uniforms [[buffer(0)]],
    uint2 position [[thread_position_in_grid]]
) {
    if (position.x >= outputTexture.get_width() || position.y >= outputTexture.get_height()) {
        return;
    }

    const float2 size = uniforms.viewport.xy;
    const float2 texel = uniforms.viewport.zw;
    const float2 uv = (float2(position) + 0.5) / size;
    const float time = uniforms.timing.x;
    const float repair = saturate(uniforms.timing.y);
    const float breakProgress = saturate(uniforms.timing.z);
    const float seam = saturate(uniforms.timing.w);
    const float velocity = saturate(uniforms.geometry.z);
    const float stillness = saturate(uniforms.geometry.w);
    const uint tapCount = max(uniforms.options.x, 1u);

    const float3 live = gvCameraSample(inputTexture, uv);

    // Complete break: the frame separates, then rebuilds from macroblocks out.
    if (breakProgress > 0.0001) {
        const float blockSize = mix(72.0, 1.0, smoothstep(0.18, 1.0, breakProgress));
        const float2 block = floor(float2(position) / max(blockSize, 1.0));
        const float2 blockUV = (block + 0.5) * max(blockSize, 1.0) / size;
        const float3 quantized = gvCameraSample(inputTexture, blockUV);
        const float reveal = smoothstep(0.10, 0.92, breakProgress);
        const float presence = step(1.0 - reveal, gvCameraHash(block * 1.31));
        float3 rebuilt = mix(quantized, live, smoothstep(0.55, 1.0, breakProgress));
        rebuilt *= presence;
        outputTexture.write(half4(half3(saturate(rebuilt)), 1.0h), position);
        return;
    }

    const float2 anchorA = uniforms.anchors.xy;
    const float2 anchorB = uniforms.anchors.zw;
    const float2 midpoint = (anchorA + anchorB) * 0.5;
    const float2 span = anchorB - anchorA;
    const float spanLength = max(length(span), 0.0001);
    const float2 axis = span / spanLength;
    const float2 normalAxis = float2(-axis.y, axis.x);

    // Repair pulls the lips back together with a hard mechanical snap.
    const float closure = 1.0 - repair * repair;
    const float openness = saturate(uniforms.geometry.x) * closure;
    const float rotation = uniforms.geometry.y;

    const float along = dot(uv - midpoint, axis);
    const float across = dot(uv - midpoint, normalAxis);
    const float reach = max(spanLength * 0.5 + 0.14, 0.20);
    const float taper = 1.0 - smoothstep(reach * 0.55, reach * 1.30, abs(across));
    const float halfWidth = mix(0.0, 0.26, openness) * taper;

    float3 result = live;

    if (halfWidth <= 0.0004) {
        result = live;
    } else if (abs(along) > halfWidth) {
        // Live signal on either side, physically displaced away from the tear.
        const float side = along > 0.0 ? 1.0 : -1.0;
        // Structure gate: strongly featured regions resist being pulled apart,
        // which reads as foreground staying attached to the present frame.
        const float centre = gvCameraLuma(live);
        const float dx = gvCameraLuma(gvCameraSample(inputTexture, uv + float2(texel.x * 2.0, 0.0))) -
            gvCameraLuma(gvCameraSample(inputTexture, uv - float2(texel.x * 2.0, 0.0)));
        const float dy = gvCameraLuma(gvCameraSample(inputTexture, uv + float2(0.0, texel.y * 2.0))) -
            gvCameraLuma(gvCameraSample(inputTexture, uv - float2(0.0, texel.y * 2.0)));
        const float structure = saturate(length(float2(dx, dy)) * 3.4 + centre * 0.05);
        const float2 pull = axis * halfWidth * side * (1.0 - structure * 0.45);
        const float2 liveUV = uv - pull;

        result = gvCameraSample(inputTexture, liveUV);

        // RGB separation concentrated at the lips.
        const float lip = 1.0 - smoothstep(halfWidth, halfWidth * 2.1 + 0.006, abs(along));
        const float2 chroma = axis * lip * (0.0022 + velocity * 0.0075);
        result.r = gvCameraSample(inputTexture, liveUV + chroma).r;
        result.b = gvCameraSample(inputTexture, liveUV - chroma).b;

        // Scanline discontinuity riding the lips.
        const float scan = step(0.86, gvCameraHash(float2(floor(uv.y * size.y * 0.5), floor(time * 18.0))));
        result *= 1.0 - lip * scan * 0.45;
    } else {
        // Inside the tear: time becomes depth.
        const float normalized = along / max(halfWidth, 0.0001);
        const float depth = saturate(1.0 - abs(normalized));

        float2 layerUV = uv - midpoint;
        const float shear = rotation * mix(0.25, 1.0, depth);
        layerUV = gvCameraRotate(layerUV, shear);
        layerUV += midpoint;

        // Macroblock displacement scales with gesture violence.
        const float blockSize = mix(52.0, 11.0, velocity);
        const float2 block = floor(layerUV * size / blockSize);
        const float2 jitter = (gvFractureHash2(block + floor(time * 12.0)) - 0.5) *
            velocity * 0.055 * (1.0 - stillness * 0.7);
        // Stretched pixels: samples are dragged along the separation axis.
        const float2 stretched = axis * normalized * 0.055 * (1.0 - stillness * 0.55);
        const float2 sampleUV = layerUV + jitter + stretched;

        float3 layer = gvFractureLayer(history0, history1, history2, history3, sampleUV, depth, tapCount);

        // Holding still resolves the exposed frame.
        const float3 clean = gvFractureLayer(history0, history1, history2, history3, layerUV, depth, tapCount);
        layer = mix(layer, clean, stillness);

        // RGB separated edges inside the opening.
        const float2 channel = axis * (0.0018 + velocity * 0.010);
        layer.r = gvFractureLayer(history0, history1, history2, history3, sampleUV + channel, depth, tapCount).r;
        layer.b = gvFractureLayer(history0, history1, history2, history3, sampleUV - channel, depth, tapCount).b;

        // Optical-flow fragments: the difference between two ages, smeared.
        const float3 flow = abs(
            gvCameraSample(history0, sampleUV) - gvCameraSample(history2, sampleUV)
        );
        layer += flow * (0.35 + velocity * 0.5) * depth;

        // Small regions of pure no-signal.
        const float dropout = step(
            0.90 - velocity * 0.22 - depth * 0.10,
            gvCameraHash(block * 1.73 + floor(time * 7.0))
        );
        layer *= 1.0 - dropout;

        // Scanline discontinuities across the opening.
        const float discontinuity = step(
            0.93,
            gvCameraHash(float2(floor(uv.y * size.y * 0.34), floor(time * 9.0)))
        );
        layer = mix(layer, layer.brg, discontinuity * 0.65);

        // Purple diagnostic geometry: layer boundaries and a centre rule.
        const float boundary = 1.0 - smoothstep(0.0, 0.035, abs(fract(depth * float(tapCount)) - 0.5) * 2.0 - 0.94);
        const float centreRule = 1.0 - smoothstep(0.0, 0.0022, abs(along));
        layer += float3(0.42, 0.10, 0.72) * (boundary * 0.16 + centreRule * 0.32);

        result = layer;
    }

    // The seam that survives for a moment after the signal reconnects.
    if (seam > 0.001) {
        const float line = 1.0 - smoothstep(0.0, 0.0026, abs(along));
        const float extent = 1.0 - smoothstep(reach * 0.7, reach * 1.4, abs(across));
        result += float3(0.62, 0.34, 1.0) * line * extent * seam;
    }

    outputTexture.write(half4(half3(saturate(result)), 1.0h), position);
}

vertex GVCameraRaster gvCameraPreviewVertex(uint vertexID [[vertex_id]]) {
    const float2 positions[4] = {
        float2(-1.0, -1.0),
        float2(1.0, -1.0),
        float2(-1.0, 1.0),
        float2(1.0, 1.0)
    };
    const float2 coordinates[4] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 0.0)
    };
    GVCameraRaster output;
    output.position = float4(positions[vertexID], 0.0, 1.0);
    output.uv = coordinates[vertexID];
    return output;
}

fragment half4 gvCameraPreviewFragment(
    GVCameraRaster input [[stage_in]],
    texture2d<half, access::sample> sourceTexture [[texture(0)]],
    constant GVCameraPreviewUniforms &uniforms [[buffer(0)]]
) {
    const float viewportAspect = uniforms.viewport.x / max(uniforms.viewport.y, 1.0);
    const float sourceAspect = uniforms.viewport.z / max(uniforms.viewport.w, 1.0);
    float2 uv = input.uv;
    // OPEN GATE + NATIVE is the one preview mode that must show every sensor
    // edge. Aspect-fill made a true 4:3 readout look identical to 16:9 because
    // the extra image area was immediately cropped back off.
    const bool showFullSensor = uniforms.overlays.y > 3.5;
    if (showFullSensor && sourceAspect > viewportAspect) {
        const float imageHeight = viewportAspect / sourceAspect;
        if (abs(uv.y - 0.5) > imageHeight * 0.5) {
            return half4(0.0h, 0.0h, 0.0h, 1.0h);
        }
        uv.y = (uv.y - 0.5) / imageHeight + 0.5;
    } else if (showFullSensor) {
        const float imageWidth = sourceAspect / viewportAspect;
        if (abs(uv.x - 0.5) > imageWidth * 0.5) {
            return half4(0.0h, 0.0h, 0.0h, 1.0h);
        }
        uv.x = (uv.x - 0.5) / imageWidth + 0.5;
    } else if (sourceAspect > viewportAspect) {
        uv.x = (uv.x - 0.5) * (viewportAspect / sourceAspect) + 0.5;
    } else {
        uv.y = (uv.y - 0.5) * (sourceAspect / viewportAspect) + 0.5;
    }
    half4 color = sourceTexture.sample(gvCameraLinearSampler, uv);
    // GPU scanlines: the animated HUD lines composite in display space, the
    // same coordinates the SwiftUI canvas used, at a fraction of the cost.
    if (uniforms.scanlines.w > 0.001) {
        const float spacing = max(uniforms.scanlines.x, 1.0);
        const float phase = uniforms.scanlines.y;
        const float lineWidth = max(uniforms.scanlines.z, 0.5);
        const float opacity = uniforms.scanlines.w;
        const int direction = int(uniforms.scanlineFlags.x);
        float coordinate = input.position.y;
        if (direction == 1) {
            coordinate = input.position.x;
        } else if (direction == 2) {
            coordinate = input.position.x + input.position.y;
        }
        const float cycle = fract((coordinate - phase) / spacing);
        const float distanceToLine = min(cycle, 1.0 - cycle) * spacing;
        const float line = 1.0 - smoothstep(0.0, lineWidth, distanceToLine);
        color.rgb = mix(color.rgb, half3(1.0), line * opacity);
    }
    return color;
}

// MARK: - AR objects

struct GVARBackgroundUniforms {
    float4 viewport;  // xy = viewport size, zw = source image size
    uint4 options;    // y = sensor orientation (CapturedFrameOrientation raw value)
};

struct GVARBackgroundRaster {
    float4 position [[position]];
    float2 uv;
};

struct GVARObjectUniforms {
    float4x4 model;
    float4x4 viewProjection;
    float4 cameraPosition;
    float4 tint;      // rgb + emissive alpha
    float4 tuning;    // x time, y reserved, z glow, w reserved
    uint4 options;    // x wireframe flag, y reserved
};

struct GVARObjectVertexIn {
    float3 position [[attribute(0)]];
    float3 normal [[attribute(1)]];
};

struct GVARObjectRaster {
    float4 position [[position]];
    float3 worldNormal;
    float3 viewDirection;
};

vertex GVARBackgroundRaster gvARBackgroundVertex(uint vertexID [[vertex_id]]) {
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
    GVARBackgroundRaster output;
    output.position = float4(positions[vertexID], 0.0, 1.0);
    output.uv = coordinates[vertexID];
    return output;
}

/// Maps the sensor-oriented camera image onto the viewport with the same
/// aspect-fill crop and orientation rotation the camera preview applies, so
/// the 3D projection lines up with the live image.
fragment float4 gvARBackgroundFragment(
    GVARBackgroundRaster input [[stage_in]],
    texture2d<half, access::sample> sourceTexture [[texture(0)]],
    constant GVARBackgroundUniforms &uniforms [[buffer(0)]]
) {
    const uint orientation = uniforms.options.y;
    const bool portrait = orientation <= 1;
    const float sourceWidth = portrait ? uniforms.viewport.w : uniforms.viewport.z;
    const float sourceHeight = portrait ? uniforms.viewport.z : uniforms.viewport.w;
    const float sourceAspect = sourceWidth / max(sourceHeight, 1.0);
    const float viewportAspect = uniforms.viewport.x / max(uniforms.viewport.y, 1.0);

    float2 cropped = input.uv;
    if (sourceAspect > viewportAspect) {
        cropped.x = (input.uv.x - 0.5) * (viewportAspect / sourceAspect) + 0.5;
    } else {
        cropped.y = (input.uv.y - 0.5) * (sourceAspect / viewportAspect) + 0.5;
    }

    float2 sensorUV = cropped;
    switch (orientation) {
        case 0:
            sensorUV = float2(cropped.y, 1.0 - cropped.x);
            break;
        case 1:
            sensorUV = float2(1.0 - cropped.y, cropped.x);
            break;
        case 3:
            sensorUV = 1.0 - cropped;
            break;
        default:
            break;
    }
    const float4 sampled = float4(sourceTexture.sample(gvCameraLinearSampler, sensorUV));
    return float4(sampled.xyz, 1.0);
}

vertex GVARObjectRaster gvARObjectVertex(
    GVARObjectVertexIn input [[stage_in]],
    constant GVARObjectUniforms &uniforms [[buffer(1)]]
) {
    const float4 world = uniforms.model * float4(input.position, 1.0);
    const float3x3 normalMatrix = float3x3(
        uniforms.model[0].xyz,
        uniforms.model[1].xyz,
        uniforms.model[2].xyz
    );
    GVARObjectRaster output;
    output.position = uniforms.viewProjection * world;
    output.worldNormal = normalMatrix * input.normal;
    output.viewDirection = normalize(uniforms.cameraPosition.xyz - world.xyz);
    return output;
}

fragment float4 gvARObjectFragment(
    GVARObjectRaster input [[stage_in]],
    constant GVARObjectUniforms &uniforms [[buffer(0)]]
) {
    const float3 normal = normalize(input.worldNormal);
    const float3 lightDirection = normalize(float3(0.38, 0.72, 0.58));
    const float diffuse = max(dot(normal, lightDirection), 0.0);
    const float backLight = max(dot(normal, -lightDirection), 0.0);
    const float viewDot = abs(dot(normal, normalize(input.viewDirection)));
    const float rim = pow(1.0 - viewDot, 2.4);
    const float3 base = uniforms.tint.rgb;
    const float glow = uniforms.tuning.z;
    const float3 shaded = base * (0.20 + diffuse * 0.90 + backLight * 0.12);
    return float4(shaded + base * rim * glow * 1.6, 1.0);
}

// MARK: - GPU fluid

/// Uniforms for the fluid solver. Kept separate from the effect uniforms
/// because the solver runs its own multi-pass schedule.
struct GVFluidUniforms {
    float2 texel;          // 1 / grid size
    float2 touch;          // normalised contact point
    float2 touchVelocity;  // normalised velocity
    float  touchActive;
    float  deltaTime;
    float  dissipation;    // dye fade per step
    float  viscosity;      // velocity fade per step
    float  forceRadius;
    float  forceStrength;
    float  vorticity;      // curl restoration
    float  cameraInject;   // how much camera colour feeds the dye
};

/// Bilinear fetch with clamped edges.
static float4 gvFluidSample(texture2d<float, access::sample> field, float2 uv) {
    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    return field.sample(linearSampler, uv);
}

/// Semi-Lagrangian advection: trace backwards along the velocity field and
/// read what was there. Unconditionally stable, which is what makes a fluid
/// affordable in realtime.
kernel void gvFluidAdvect(
    texture2d<float, access::sample> velocity [[texture(0)]],
    texture2d<float, access::sample> source [[texture(1)]],
    texture2d<float, access::write> destination [[texture(2)]],
    constant GVFluidUniforms &uniforms [[buffer(0)]],
    uint2 position [[thread_position_in_grid]]
) {
    if (position.x >= destination.get_width() || position.y >= destination.get_height()) { return; }
    const float2 uv = (float2(position) + 0.5) * uniforms.texel;
    const float2 speed = gvFluidSample(velocity, uv).xy;
    const float2 traced = uv - speed * uniforms.deltaTime;
    const float4 carried = gvFluidSample(source, traced);
    destination.write(carried * uniforms.dissipation, position);
}

/// Injects force and dye at the contact point.
kernel void gvFluidSplat(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::sample> camera [[texture(1)]],
    texture2d<float, access::write> destination [[texture(2)]],
    constant GVFluidUniforms &uniforms [[buffer(0)]],
    constant uint &isVelocity [[buffer(1)]],
    uint2 position [[thread_position_in_grid]]
) {
    if (position.x >= destination.get_width() || position.y >= destination.get_height()) { return; }
    const float2 uv = (float2(position) + 0.5) * uniforms.texel;
    float4 value = source.read(position);

    if (uniforms.touchActive > 0.5) {
        const float2 delta = uv - uniforms.touch;
        // Gaussian falloff; a hard disc produces visible square artefacts once
        // it is advected.
        const float falloff = exp(-dot(delta, delta) / max(uniforms.forceRadius, 1e-5));
        if (isVelocity == 1u) {
            value.xy += uniforms.touchVelocity * falloff * uniforms.forceStrength;
        } else {
            // Dye takes the camera's own colour, so the fluid is made of the
            // scene rather than of an arbitrary palette.
            const float3 ink = gvFluidSample(camera, uv).rgb;
            value.rgb += ink * falloff * uniforms.cameraInject;
        }
    }
    destination.write(value, position);
}

/// Divergence of the velocity field — how much each cell is gaining or losing
/// mass. The pressure solve exists to drive this to zero.
kernel void gvFluidDivergence(
    texture2d<float, access::sample> velocity [[texture(0)]],
    texture2d<float, access::write> divergence [[texture(1)]],
    constant GVFluidUniforms &uniforms [[buffer(0)]],
    uint2 position [[thread_position_in_grid]]
) {
    if (position.x >= divergence.get_width() || position.y >= divergence.get_height()) { return; }
    const float2 uv = (float2(position) + 0.5) * uniforms.texel;
    const float left = gvFluidSample(velocity, uv - float2(uniforms.texel.x, 0.0)).x;
    const float right = gvFluidSample(velocity, uv + float2(uniforms.texel.x, 0.0)).x;
    const float down = gvFluidSample(velocity, uv - float2(0.0, uniforms.texel.y)).y;
    const float up = gvFluidSample(velocity, uv + float2(0.0, uniforms.texel.y)).y;
    divergence.write(float4(0.5 * (right - left + up - down), 0.0, 0.0, 1.0), position);
}

/// One Jacobi iteration of the pressure Poisson equation.
kernel void gvFluidPressure(
    texture2d<float, access::sample> pressure [[texture(0)]],
    texture2d<float, access::sample> divergence [[texture(1)]],
    texture2d<float, access::write> destination [[texture(2)]],
    constant GVFluidUniforms &uniforms [[buffer(0)]],
    uint2 position [[thread_position_in_grid]]
) {
    if (position.x >= destination.get_width() || position.y >= destination.get_height()) { return; }
    const float2 uv = (float2(position) + 0.5) * uniforms.texel;
    const float left = gvFluidSample(pressure, uv - float2(uniforms.texel.x, 0.0)).x;
    const float right = gvFluidSample(pressure, uv + float2(uniforms.texel.x, 0.0)).x;
    const float down = gvFluidSample(pressure, uv - float2(0.0, uniforms.texel.y)).x;
    const float up = gvFluidSample(pressure, uv + float2(0.0, uniforms.texel.y)).x;
    const float centre = gvFluidSample(divergence, uv).x;
    destination.write(float4((left + right + down + up - centre) * 0.25, 0.0, 0.0, 1.0), position);
}

/// Subtracts the pressure gradient, leaving a divergence-free field. Without
/// this step the fluid visibly gains and loses mass and reads as smearing
/// rather than as flow.
kernel void gvFluidProject(
    texture2d<float, access::sample> pressure [[texture(0)]],
    texture2d<float, access::sample> velocity [[texture(1)]],
    texture2d<float, access::write> destination [[texture(2)]],
    constant GVFluidUniforms &uniforms [[buffer(0)]],
    uint2 position [[thread_position_in_grid]]
) {
    if (position.x >= destination.get_width() || position.y >= destination.get_height()) { return; }
    const float2 uv = (float2(position) + 0.5) * uniforms.texel;
    const float left = gvFluidSample(pressure, uv - float2(uniforms.texel.x, 0.0)).x;
    const float right = gvFluidSample(pressure, uv + float2(uniforms.texel.x, 0.0)).x;
    const float down = gvFluidSample(pressure, uv - float2(0.0, uniforms.texel.y)).x;
    const float up = gvFluidSample(pressure, uv + float2(0.0, uniforms.texel.y)).x;
    float2 speed = gvFluidSample(velocity, uv).xy;
    speed -= float2(right - left, up - down) * 0.5;
    destination.write(float4(speed * uniforms.viscosity, 0.0, 1.0), position);
}

/// Vorticity confinement. Semi-Lagrangian advection is diffusive and eats
/// small eddies; this feeds their energy back so the flow keeps its curl.
kernel void gvFluidVorticity(
    texture2d<float, access::sample> velocity [[texture(0)]],
    texture2d<float, access::write> destination [[texture(1)]],
    constant GVFluidUniforms &uniforms [[buffer(0)]],
    uint2 position [[thread_position_in_grid]]
) {
    if (position.x >= destination.get_width() || position.y >= destination.get_height()) { return; }
    const float2 uv = (float2(position) + 0.5) * uniforms.texel;
    const float2 dx = float2(uniforms.texel.x, 0.0);
    const float2 dy = float2(0.0, uniforms.texel.y);

    const float curlLeft = gvFluidSample(velocity, uv - dx).y;
    const float curlRight = gvFluidSample(velocity, uv + dx).y;
    const float curlDown = gvFluidSample(velocity, uv - dy).x;
    const float curlUp = gvFluidSample(velocity, uv + dy).x;
    const float curl = (curlRight - curlLeft) - (curlUp - curlDown);

    // Gradient of |curl| points toward the vortex centre.
    const float magLeft = abs((gvFluidSample(velocity, uv - dx * 2.0).y - curlLeft));
    const float magRight = abs((gvFluidSample(velocity, uv + dx * 2.0).y - curlRight));
    const float magDown = abs((gvFluidSample(velocity, uv - dy * 2.0).x - curlDown));
    const float magUp = abs((gvFluidSample(velocity, uv + dy * 2.0).x - curlUp));

    float2 direction = float2(magRight - magLeft, magUp - magDown);
    const float length2 = max(length(direction), 1e-5);
    direction /= length2;

    float2 speed = gvFluidSample(velocity, uv).xy;
    speed += float2(direction.y, -direction.x) * curl * uniforms.vorticity * uniforms.deltaTime;
    destination.write(float4(speed, 0.0, 1.0), position);
}

/// Composites the dye over the camera frame.
kernel void gvFluidComposite(
    texture2d<half, access::sample> inputTexture [[texture(0)]],
    texture2d<float, access::sample> dye [[texture(1)]],
    texture2d<float, access::sample> velocity [[texture(2)]],
    texture2d<half, access::write> outputTexture [[texture(3)]],
    constant GVCameraEffectUniforms &uniforms [[buffer(0)]],
    uint2 position [[thread_position_in_grid]]
) {
    if (position.x >= outputTexture.get_width() || position.y >= outputTexture.get_height()) { return; }
    const float2 size = uniforms.viewport.xy;
    const float2 uv = (float2(position) + 0.5) / size;

    const float2 speed = gvFluidSample(velocity, uv).xy;
    // The camera image itself is dragged by the flow, so the scene deforms
    // rather than merely having colour painted over it.
    const float drag = mix(0.0, 0.35, uniforms.parameters.x);
    const float3 dragged = gvCameraSample(inputTexture, uv - speed * drag);

    const float3 ink = gvFluidSample(dye, uv).rgb;
    const float density = saturate(length(ink));
    const float3 lit = ink * mix(1.0, 2.4, uniforms.parameters.y);

    float3 result = mix(dragged, dragged * 0.35 + lit, saturate(density * 1.6));
    // Velocity shear picks up a violet fringe, so fast flow reads as energy.
    result += float3(0.42, 0.18, 0.92) * saturate(length(speed) * 6.0) * 0.22;

    result = mix(dragged, result, saturate(uniforms.extra.x));
    outputTexture.write(half4(half3(saturate(result)), 1.0h), position);
}

// MARK: - Shared optical flow
//
// One estimator for the whole engine. Datamosh, motion hold, motion transplant
// and flow sort all consume these textures; none of them run their own search.
//
// The method is block matching against the previous frame's luma, refined by a
// gradient step. Block matching is chosen over pure Lucas-Kanade because it
// survives the large inter-frame displacements a handheld camera produces,
// which is exactly the case that matters here — a gradient-only estimator
// silently returns zero when motion exceeds a pixel or two, and zero flow is
// indistinguishable from a still scene. Getting that wrong would make every
// downstream effect look broken in precisely the situation the user is
// testing it: waving a hand across the frame.

struct GVFlowUniforms {
    // x,y = flow texture size. z,w = 1/size.
    float4 viewport;
    // x = search radius in texels
    // y = persistence (0 = follow live flow, 1 = never forget)
    // z = decay applied to the persistent field each frame
    // w = gain applied to the live estimate before accumulation
    float4 controls;
    // x = 1 while the source is frozen under a held finger
    // y = 1 while a captured field is being applied (MOTION TRANSPLANT)
    // z = packed hold-style bits (see the mosh engine above)
    // w = hold duration in seconds × 65536
    uint4 flags;
};

/// Private Metal textures are not zero-initialised. Every shared flow field is
/// cleared before its first estimate so an idle first frame cannot seed the
/// temporal stack with arbitrary vectors.
kernel void gvFlowClear(
    texture2d<half, access::write> field [[texture(0)]],
    uint2 position [[thread_position_in_grid]]
) {
    if (position.x >= field.get_width() || position.y >= field.get_height()) {
        return;
    }
    field.write(half4(0.0h), position);
}

kernel void gvFlowLuma(
    texture2d<half, access::sample> source [[texture(0)]],
    texture2d<half, access::write> luma [[texture(1)]],
    uint2 position [[thread_position_in_grid]]
) {
    if (position.x >= luma.get_width() || position.y >= luma.get_height()) {
        return;
    }
    const float2 size = float2(luma.get_width(), luma.get_height());
    const float2 uv = (float2(position) + 0.5) / size;
    // Box-filtered on the way down. Sampling a single texel of a full
    // resolution frame into a quarter scale target aliases badly, and aliased
    // luma makes the block search lock onto noise instead of structure.
    float total = 0.0;
    for (int y = -1; y <= 1; ++y) {
        for (int x = -1; x <= 1; ++x) {
            const float2 offset = float2(x, y) / size;
            total += gvCameraLuma(gvCameraSample(source, uv + offset));
        }
    }
    luma.write(half4(half(total / 9.0), 0.0h, 0.0h, 1.0h), position);
}

kernel void gvFlowEstimate(
    texture2d<half, access::sample> currentLuma [[texture(0)]],
    texture2d<half, access::sample> previousLuma [[texture(1)]],
    texture2d<half, access::sample> previousFlow [[texture(2)]],
    texture2d<half, access::write> flow [[texture(3)]],
    constant GVFlowUniforms &uniforms [[buffer(0)]],
    uint2 position [[thread_position_in_grid]]
) {
    if (position.x >= flow.get_width() || position.y >= flow.get_height()) {
        return;
    }

    const float2 size = uniforms.viewport.xy;
    const float2 texel = uniforms.viewport.zw;
    const float2 uv = (float2(position) + 0.5) / size;
    const int radius = int(max(uniforms.controls.x, 1.0));

    // Seed from the previous estimate. Motion is temporally coherent, so
    // starting the search where this block went last frame both converges
    // faster and stabilises the field between frames.
    const float2 seed = float2(gvCameraSampleVector(previousFlow, uv));

    float bestError = 1e6;
    float2 bestOffset = float2(0.0);

    // Three-step search. Coarse to fine, halving the stride each pass, which
    // covers a radius of N in log(N) steps instead of N^2 taps.
    float stride = float(radius);
    float2 centre = seed;
    for (uint step = 0; step < 3u; ++step) {
        for (int y = -1; y <= 1; ++y) {
            for (int x = -1; x <= 1; ++x) {
                const float2 candidate = centre + float2(x, y) * stride * texel;
                // Sum of absolute differences over a small patch. A single
                // texel comparison matches flat regions to anything.
                float error = 0.0;
                for (int py = -1; py <= 1; ++py) {
                    for (int px = -1; px <= 1; ++px) {
                        const float2 patch = float2(px, py) * texel;
                        const float a = float(currentLuma.sample(gvCameraLinearSampler, uv + patch).r);
                        const float b = float(previousLuma.sample(gvCameraLinearSampler, uv + patch + candidate).r);
                        error += abs(a - b);
                    }
                }
                // Bias toward smaller vectors. Without this, flat areas pick
                // whichever far-off block happens to match and the field fills
                // with confident nonsense.
                error += length(candidate) * 0.35;
                if (error < bestError) {
                    bestError = error;
                    bestOffset = candidate;
                }
            }
        }
        centre = bestOffset;
        stride *= 0.5;
    }

    // Confidence gate. A block that matches everything equally well has no
    // real motion, and forwarding its vector produces the smeared garbage that
    // makes naive flow effects look like noise rather than movement.
    const float contrast = abs(
        float(currentLuma.sample(gvCameraLinearSampler, uv + float2(texel.x, 0.0)).r) -
        float(currentLuma.sample(gvCameraLinearSampler, uv - float2(texel.x, 0.0)).r)
    ) + abs(
        float(currentLuma.sample(gvCameraLinearSampler, uv + float2(0.0, texel.y)).r) -
        float(currentLuma.sample(gvCameraLinearSampler, uv - float2(0.0, texel.y)).r)
    );
    const float confidence = saturate(contrast * 8.0);
    bestOffset *= confidence;

    // Temporal smoothing of the field itself, separate from persistence.
    const float2 smoothed = mix(seed, bestOffset, 0.55);
    flow.write(half4(half2(smoothed), 0.0h, 1.0h), position);
}

kernel void gvFlowAccumulate(
    texture2d<half, access::sample> liveFlow [[texture(0)]],
    texture2d<half, access::sample> priorPersistent [[texture(1)]],
    texture2d<half, access::sample> frozenFlow [[texture(2)]],
    texture2d<half, access::write> persistent [[texture(3)]],
    constant GVFlowUniforms &uniforms [[buffer(0)]],
    uint2 position [[thread_position_in_grid]]
) {
    if (position.x >= persistent.get_width() || position.y >= persistent.get_height()) {
        return;
    }
    const float2 size = uniforms.viewport.xy;
    const float2 uv = (float2(position) + 0.5) / size;

    const float persistence = saturate(uniforms.controls.y);
    const float decay = saturate(uniforms.controls.z);
    const float gain = uniforms.controls.w;

    const float2 prior = float2(gvCameraSampleVector(priorPersistent, uv));

    // SOURCE FREEZE, as seen by the motion estimator. The captured field
    // keeps driving displacement while the camera frame is held, so the mosh
    // keeps melting along motion that is no longer happening — but unless
    // MOTION LOCK is engaged the captured field bleeds away over a second or
    // two, which is the "motion has inertia, then settles" half of the feel.
    // Locking it forever for every hold is what turned the old hold into a
    // static frame after the initial slide.
    if (uniforms.flags.x != 0u) {
        const float2 held = float2(gvCameraSampleVector(frozenFlow, uv));
        const bool motionLock = (uniforms.flags.z & 2u) != 0u;
        const float holdSeconds = float(uniforms.flags.w) / 65536.0;
        const float decay = motionLock ? 0.0 : 0.55;
        const float2 decayed = held * exp(-holdSeconds * decay);
        persistent.write(half4(half2(decayed), 0.0h, 1.0h), position);
        return;
    }

    const float2 live = float2(gvCameraSampleVector(liveFlow, uv)) * gain;
    // Accumulate, then bleed off. Persistence decides how much of the past
    // survives; decay stops the field growing without bound when motion
    // repeats in one direction.
    float2 accumulated = mix(live, prior + live * (1.0 - persistence), persistence);
    accumulated *= (1.0 - decay * 0.25);
    // Hard clamp. An unbounded field eventually samples arbitrarily far from
    // the pixel and the image collapses to a single smeared colour.
    const float limit = 0.25;
    const float magnitude = length(accumulated);
    if (magnitude > limit) {
        accumulated *= limit / magnitude;
    }
    persistent.write(half4(half2(accumulated), 0.0h, 1.0h), position);
}

// MARK: - Chrome legibility
//
// The interface is unplated type over the live frame. Against a dark subject
// that reads beautifully; against a white wall or a bright sky the dock and the
// telemetry strip disappear entirely. Rather than plating everything
// permanently — which is the thing the design spent its whole diff removing —
// the chrome is told how bright the frame actually is underneath it and darkens
// its scrim only when it has to.
//
// Two bands, top and bottom, because that is where the chrome lives. The middle
// of the frame is the subject and nothing is drawn over it.
//
// Accumulated as fixed point into atomic uints: Metal has no atomic float, and
// a 16-bit fixed point luma summed over a 64x64 grid cannot overflow a uint32.

struct GVBandLumaUniforms {
    // x = bottom edge of the top band, as a fraction of the frame
    // y = top edge of the deck band
    // z = top edge of the bottom band
    // w = perceptual level above which a sample counts as bright
    float4 bands;
};

kernel void gvCameraBandLuma(
    texture2d<half, access::sample> source [[texture(0)]],
    device atomic_uint *bins [[buffer(0)]],
    constant GVBandLumaUniforms &uniforms [[buffer(1)]],
    uint2 position [[thread_position_in_grid]]
) {
    // Fixed 64x64 sample grid regardless of source resolution. The chrome needs
    // to know "is it bright under here", not the frame's histogram, and a
    // coarse grid keeps this off the frame budget entirely.
    const float2 grid = float2(64.0, 64.0);
    if (position.x >= uint(grid.x) || position.y >= uint(grid.y)) {
        return;
    }

    const float2 uv = (float2(position) + 0.5) / grid;

    // Three bands, because chrome lives in three places: the top shell, the
    // parameter deck, and the dock. The gaps between them are the frame — the
    // subject — and nothing is drawn over those.
    uint base;
    if (uv.y < uniforms.bands.x) {
        base = 0;
    } else if (uv.y >= uniforms.bands.z) {
        base = 8;
    } else if (uv.y >= uniforms.bands.y) {
        base = 4;
    } else {
        return;
    }

    // Perceptual, not linear: the working texture is linear light, and a linear
    // mean reads a mid-grey wall as far darker than the eye does — which is
    // exactly the case where the chrome needs help.
    const float luma = saturate(sqrt(max(gvCameraLuma(gvCameraSample(source, uv)), 0.0)));

    atomic_fetch_add_explicit(&bins[base + 0], uint(luma * 65535.0), memory_order_relaxed);
    atomic_fetch_add_explicit(&bins[base + 1], 1u, memory_order_relaxed);

    // Counted as well as averaged. A mean is the wrong statistic on its own:
    // a checkerboard of black and white averages to mid grey and swallows type
    // whole, while a uniformly mid-grey wall averages identically and is fine.
    // What actually costs legibility is how much of the band is bright.
    if (luma > uniforms.bands.w) {
        atomic_fetch_add_explicit(&bins[base + 2], 1u, memory_order_relaxed);
    }
}
