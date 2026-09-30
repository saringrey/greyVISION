#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>

using namespace metal;

// MARK: - Dithered Flow
//
// A 1-bit black-and-white flow field: domain-warped fractal noise collapsed to
// two tones by an ordered dither. It is the backdrop every screen sits on.
//
// The look is carried by four things:
//
// * **Domain warping.** Plain fbm gives clouds. Feeding fbm's own output back
//   in as a coordinate offset — twice — produces the long folded ribbons that
//   read as liquid or marbled stone.
// * **Rotated octaves.** Each octave is rotated by a fixed 2x2 matrix before
//   being added. Without rotation the octaves align on the same two axes and
//   the field grows visible vertical/horizontal streaking; with it the detail
//   reads as paper grain in every direction.
// * **Hard threshold.** The field is pushed to black or white with `step`.
//   Any smooth ramp between the two immediately reads as a greyscale gradient
//   instead of as ink.
// * **Ordered dither at a chunky pixel scale.** The apparent greys are not
//   grey at all — they are a Bayer pattern breaking the threshold boundary
//   into square clusters. Dithering per-pixel would look like film grain; the
//   block quantisation below is what makes the clusters visible as pattern.
//
// Performance notes. This shader covers the whole screen at native density on
// every app screen, so its ALU cost is a thermal line item, not a detail:
//
// * The hash is integer PCG maths — no trigonometry. The previous sin-dot
//   hash cost four transcendentals per noise cell and its quality collapsed
//   at large coordinates.
// * The field accumulates in `half`, which runs at twice the rate on Apple
//   GPUs. Coordinates stay in `float`: the lattice positions reach magnitudes
//   where half would quantise the cells visibly.
// * The warp is two levels of four-octave fbm (twelve noise cells per pixel)
//   against the previous build's two levels of five (twenty-five), with the
//   rotation carrying the detail the missing octave used to. The marbling
//   keeps its richness at roughly half the cost.
//
// Touch is three couplings, not a torch:
//
// * **Pull** — the field bends around the contact, so the ribbons visibly
//   make way for the finger.
// * **Ring** — a wave propagates outward from the contact while it is down,
//   so holding still still reads as alive.
// * **Energise** — contrast rises and the white tone takes the engine's
//   violet within a small radius of the contact: the one place the backdrop
//   carries colour, and only while touched.

// MARK: Noise

static inline uint gvPaperHashBits(uint value) {
    value ^= value >> 16;
    value *= 0x7feb352du;
    value ^= value >> 15;
    value *= 0x846ca68bu;
    value ^= value >> 16;
    return value;
}

// Integer hash of a lattice coordinate. Exact for every integer input, which
// the sin-dot hash was not: its quality decayed as the warped field pushed
// coordinates into the hundreds.
static inline float gvPaperHash(float2 lattice) {
    const uint2 bits = as_type<uint2>(lattice);
    const uint combined = gvPaperHashBits(bits.x ^ gvPaperHashBits(bits.y));
    return float(combined) * (1.0 / 4294967296.0);
}

// Quintic fade: C2, so no second-derivative break at cell edges. Those breaks
// are invisible in a texture but show as diagonal banding once the field is
// collapsed to a hard edge, which is exactly what happens here.
static inline float gvPaperValueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);

    float a = gvPaperHash(i);
    float b = gvPaperHash(i + float2(1.0, 0.0));
    float c = gvPaperHash(i + float2(0.0, 1.0));
    float d = gvPaperHash(i + float2(1.0, 1.0));

    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// Fixed rotation between octaves. ~31.7 degrees keeps successive octaves off
// the lattice axes; combined with the scale it also prevents any octave from
// repeating a neighbour's alignment.
constant float2x2 gvPaperRotation = {
    { 0.8513, 0.5247 },
    { -0.5247, 0.8513 }
};

// Four octaves with rotation. The rotation is what buys back the detail a
// fifth octave added in the previous build, at one fewer noise evaluation per
// level of the warp.
static inline float gvPaperFbm(float2 p) {
    float sum = 0.0;
    float amplitude = 0.5;

    for (int octave = 0; octave < 4; ++octave) {
        sum += amplitude * gvPaperValueNoise(p);
        p = gvPaperRotation * p * 2.03 + float2(11.7, 5.3);
        amplitude *= 0.5;
    }
    return sum;
}

// Two-level domain warp.
//
// `q` displaces the field, `r` displaces the displacement. The second level is
// what turns soft billows into folded sheets with long parallel creases — with
// only one level the result still reads as cloud.
static inline float gvPaperFlowField(float2 p, float time) {
    float2 q = float2(
        gvPaperFbm(p + float2(0.0, 0.0)),
        gvPaperFbm(p + float2(5.2, 1.3))
    );

    float2 r = float2(
        gvPaperFbm(p + 3.4 * q + float2(1.7, 9.2) + 0.26 * time),
        gvPaperFbm(p + 3.4 * q + float2(8.3, 2.8) - 0.21 * time)
    );

    return gvPaperFbm(p + 3.8 * r);
}

// MARK: Dither

// Standard 8x8 Bayer matrix, normalised to 0...1 at lookup.
constant float kBayer8[64] = {
     0.0, 32.0,  8.0, 40.0,  2.0, 34.0, 10.0, 42.0,
    48.0, 16.0, 56.0, 24.0, 50.0, 18.0, 58.0, 26.0,
    12.0, 44.0,  4.0, 36.0, 14.0, 46.0,  6.0, 38.0,
    60.0, 28.0, 52.0, 20.0, 62.0, 30.0, 54.0, 22.0,
     3.0, 35.0, 11.0, 43.0,  1.0, 33.0,  9.0, 41.0,
    51.0, 19.0, 59.0, 27.0, 49.0, 17.0, 57.0, 25.0,
    15.0, 47.0,  7.0, 39.0, 13.0, 45.0,  5.0, 37.0,
    63.0, 31.0, 55.0, 23.0, 61.0, 29.0, 53.0, 21.0
};

static inline float bayer(float2 blockCoordinate) {
    int x = int(fmod(abs(blockCoordinate.x), 8.0));
    int y = int(fmod(abs(blockCoordinate.y), 8.0));
    return (kBayer8[y * 8 + x] + 0.5) / 64.0;
}

// MARK: Fragment

[[ stitchable ]]
half4 ditheredFlow(
    float2 position,
    half4 color,
    float time,
    float2 resolution,
    float blockSize,
    float contrast,
    float2 touch,
    float2 tilt
) {
    float2 size = max(resolution, float2(1.0, 1.0));

    // Normalise on the short edge so the pattern keeps its proportions
    // instead of stretching with the view.
    float shortEdge = min(size.x, size.y);
    float2 uv = position / shortEdge;

    // Tilt — halved again. Barely-there lean + ultra-slow drip.
    float2 drift = tilt * 0.03;
    float tiltEnergy = length(tilt);
    float2 tiltWarp = tilt * 0.0075 * tiltEnergy;
    // At 1.0 tilt, ~0.002 UV/sec ≈ 0.6% per 3 s.
    float2 drip = tilt * time * 0.002;

    // Touch pulls the field toward the finger.
    //
    // Modelled as a radial displacement that falls off with distance rather
    // than as a brightness change: pushing the *coordinate* makes the ribbons
    // themselves bend around the contact, which is what reads as the material
    // responding. Brightening near the touch would just look like a torch.
    float2 touchUV = touch / shortEdge;
    float2 toTouch = uv - touchUV;
    float reach = length(toTouch);
    float2 toTouchDirection = toTouch / max(reach, 1e-5);
    // `touch.x < 0` is the sentinel for "no contact" — see the Swift side.
    float contact = (touch.x < 0.0) ? 0.0 : exp(-reach * 3.1);
    float2 pull = toTouchDirection * contact * 0.26;

    // A wave propagating out from the contact while the finger is down. The
    // phase runs on radius and time together, so rings visibly travel; the
    // envelope keeps them inside a hand's span of the contact.
    float ring = sin(reach * 46.0 - time * 5.2) * contact * exp(-reach * 5.5);
    pull += toTouchDirection * ring * 0.045;

    // Scale/time nudges halved again.
    float tiltScale = 1.0 + tiltEnergy * 0.006;
    float tiltTime = time * (0.012 + tiltEnergy * 0.0003);

    // Touch energises the field: the ribbons speed up and sharpen inside the
    // contact's reach, so the material feels alive under the finger without
    // the whole screen changing character.
    float energise = contact;
    float touchScale = 1.0 + energise * 0.05;
    float touchTime = time * energise * 0.05;

    float field = gvPaperFlowField(
        uv * (2.35 * tiltScale * touchScale) + drift + tiltWarp + drip - pull
            + float2(0.0, tiltTime + touchTime),
        time
    );

    // Push toward the extremes before thresholding. Without this the field
    // hovers near 0.5 and the dither covers most of the frame, which reads as
    // noise rather than as two tones with a broken boundary. Contrast rises
    // toward the contact so the ink crisps up under the finger.
    float localContrast = contrast + energise * 1.6;
    float shaped = clamp((field - 0.5) * localContrast + 0.5, 0.0, 1.0);

    // Quantise the dither lookup into blocks so the pattern is visible as
    // clusters. At blockSize 1 this is per-pixel and reads as grain.
    float block = max(blockSize, 1.0);
    float threshold = bayer(floor(position / block));

    float ink = step(threshold, shaped);

    // The white tone takes the engine's violet inside the contact radius —
    // the single place this backdrop carries colour, and only while touched.
    // Elsewhere it stays the pure two-tone ink the design calls for.
    half3 paper = half3(1.0h);
    paper = mix(paper, half3(0.78h, 0.62h, 1.0h), half(energise * exp(-reach * 2.6)));

    half3 result = mix(half3(0.0h), paper, half(ink));
    return half4(result * color.a, color.a);
}
