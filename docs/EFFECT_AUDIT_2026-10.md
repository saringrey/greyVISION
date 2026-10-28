# Effect audit — October 2026

Every effect was rendered and judged twice:

1. **Live, through the production graph.** `--effect-audit` with
   `--synthetic-still <file>` drives the workspace through every effect over a
   photograph fed in place of the camera (slow pan and zoom plus a moving light),
   with a synthetic 120 BPM audio signal. Captures are taken from the simulator
   on each `GVAUDIT READY` log line. This is the only view that shows feedback
   behaviour, because temporal history is the previous *presented* frame.
2. **Statically, per kernel.** `--effect-probe <file>` (or
   `EffectCostBenchmarkTests` with `GV_EFFECT_SIGNATURES`/`GV_AUDIT_STILL`)
   renders each kernel once over the photograph at default controls and records
   its mean change from the source. This separates "invisible at defaults" from
   "only moves over time".

Both tools are DEBUG-only: `GVEffectAuditRunner`, `GVAuditStillFeed`,
`GVEffectKernelProbe`.

## Fixed

| Effect | Defect | Fix |
| --- | --- | --- |
| Motion Bloom | Gain up to 2.4× on fed-back history; frame walked to white in about a second | Carry only light the live frame lacks, at gain < 1 |
| Pixel Gravity | Drop of up to a third of the frame per frame at 82% history; picture dissolved to grey | Per-frame step, luma-weighted history share, live frame always shows |
| Frame-Hold Smear | 82% history in every block; muddy recursive blur | Only some blocks hold at a time |
| Memory Burn-In | Retention near 1 compounded the ghost tint to white | Retention capped below loop gain (0.84) |
| Burn Through | Front overshot the noise range: fully black for ~40% of each cycle; holes ignored mix | Front advances and recedes, caps at about two thirds, ember holes, glowing rim, scorch band |
| CRT | Scanline pitch of 2px and 1px mask triads vanished at phone resolution | Picture-relative pitch, scaled mask, stronger defaults |
| All audio effects | Renderer read the audio snapshot only when SwiftUI re-rendered the surface | Renderer reads the analyser mailbox every draw |

## Retired

Each retired name resolves to its replacement when decoding saved recipes,
presets, favourites, recents and broadcast commands
(`WorkspaceAdjustableEffect.retiredReplacements`), and is a search alias of the
replacement. Entries in that table are permanent.

Look-alikes (the survivor is the more striking): Audio Kaleido → Kaleidoscope,
Astral Plasma → Nebula Drift, Singularity Lens → Event Horizon, Twirl → Spiral
Warp, Fractal Zoom → Fractal Burst, Barrel Warp → Fisheye, Chromatic Aberration
→ RGB Split, Audio Chroma → Audio Spectral, Blue Noise → Dither, Halftone → CMYK
Press, Worley Cracks → Shatter, Voronoi → Hex Tile, Curl Warp → Flow Field, Wave
→ Vector Warp, Spectral Nova → Waveform Tunnel, Particle Life → Neon Orbit, Voxel
Storm → Pixel Confetti, Audio Grain → Grain, Corrode → Ash Drift, Luma Feedback →
Feedback, Rolling Time → Shear Stack, Optical-Flow Liquid → Liquid Mosh.

Near-invisible at defaults, with a sibling that does the job: Luma Diffusion
(bokeh) → Soft Focus, Tape Warp → VHS Tracking, Interlace → CRT, Print-Through →
Super 8, DCT Ringing → Audio Macroblock, Audio Posterize → Posterize, Topography
→ Contour Lines, Luma Sort → Sort, Edge Sort → Sort, Luma Extrusion → Luma Point
Smear.

The catalogue went from 189 to 157 kernel-backed effects; 32 shader arms were
removed from the style and temporal kernels.

## Kept deliberately, though quiet in the audit

- **Highlight-gated lens effects** (Anamorphic Flare, Star Filter, Halation,
  Lens Dirt, Spectral Diffraction) do nothing on a scene with no highlights; they
  responded correctly to the moving light. That is the physics they model.
- **Touch-driven effects** (Freeze/Sort/Mosh Brush, Touch Warp, Ripple) are idle
  until touched.
- **Motion-driven effects** (Datamosh, Temporal Pixel Sort, Buffer Underrun,
  Packet Loss, Chroma Failure, Frame-Hold Smear, the codebook/transplant/latch
  research moshes) need real camera motion; the simulator pan is too slow to show
  them at strength.
- **World Feedback / Time Graffiti** need AR world tracking and cannot be judged
  on the simulator.

## Unresolved technical debt

- **No device performance numbers.** The simulator's GPU timestamps are not
  credible (about 13 µs for a 3-megapixel pass), so cost was judged from kernel
  structure: per-pixel taps are bounded everywhere (largest: Kuwahara 64,
  Vectorscope 64 inside its panel only, Waveform/Parade 32). Run
  `--effect-probe` on a phone and rank `GVBENCH` lines to get real numbers.
- **XCTest could not run in this environment.** Xcode's test runner failed to
  attach to any simulator ("DTServiceHubClient failed to bless service hub";
  "test runner hung before establishing connection"). The app and test targets
  build. `EffectCatalogTests` gained a retirement-decoding test that has not yet
  been executed.
- **Temporal history is the presented frame.** Every temporal effect runs inside
  a feedback loop. Any future arm that applies gain ≥ 1 to history will diverge
  the same way Motion Bloom and Memory Burn-In did. Review new arms for loop gain.
- **Frame-Hold Smear** reads as a soft directional drag rather than crisp tears,
  for the same reason; a crisp version would need an older-input tap instead of
  the presented history.

## Liveness pass — effects that "did nothing"

Measured, not eyeballed: `GVEffectEnergyProbe` (DEBUG) reads the mean
per-channel change between the clean source and the graph output on a 64×64
lattice every frame, and the audit runner logs it per effect. Run under the
worst case — `--synthetic-still-static --effect-audit-silent`, a tripod in a
quiet room with nobody touching — and under a moving feed with sound.

| Cause | Effects | Fix |
| --- | --- | --- |
| **Effect clock was raw uptime.** At days of uptime a Float has no fractional bits left at `time * 12`, so every `fract(sin(dot(p, k)) * 43758)` hash keyed on time collapsed to a constant and time-gated effects never fired — on device as well as in the simulator. | Signal Tear, Dropout, Color Bar Tear, Data Bend, Flow Field, Pixel Shift, Buffer Underrun, Packet Loss and every other time-hashed arm (energy 0.0001 → 0.02–0.05) | Renderer-relative effect clock, wrapped at 4096 s (~0.5 ms precision) |
| **Drawn by touch.** Output is exactly zero until a finger is down. | Freeze Brush, Sort Brush, Mosh Brush, Fluid | `GVGhostFinger`: a slow Lissajous path drives them while nobody touches; a real finger replaces it on the same frame |
| **Driven by the analyser.** In silence — or with the microphone off — they render the camera untouched. | The Spectrum shelf's audio looks (Macroblock, Fracture, Stretch, Repair, Displace, Kick, …) | `GVAudioIdle`: a quiet breathing floor; live audio always wins (max). Scopes are excluded so silence still reads as silence |

Motion-only research moshes (Causal Smear, Cavitation, Vector Codebook, Motion
Transplant, World Feedback, Memory Burn-In) are inert on a perfectly static
feed by construction — they render what moved. They are checked on the moving
feed instead.

## Tracking suite

The old tracker hue-keyed raw camera buffers at 8 Hz, had no identity across
frames, drew boxes only, and exposed four sliders. It is now a suite:

- **Feed.** The renderer downsamples the clean, pre-effect source to a 256 px
  sRGB analysis frame (`gvTrackingDownsample`) — only the region the preview
  actually shows — at the chosen analysis rate. Tracking therefore works on the
  camera, the simulator feed and scrubbed takes alike, and never tracks
  anything off-screen.
- **Detectors.** Grid segmentation for Color, Bright, Shadow, Vivid, Motion and
  Skin (bright/shadow adapt to the frame's own range); Vision for Faces (with
  landmarks), Hands and Bodies (full skeletons) and Salient objects.
- **Tracker.** Persistent identities, greedy association on predicted
  positions, alpha-beta smoothing with velocity, confirmation hits, coasting
  through dropouts, trails.
- **Overlay.** 60 fps Canvas with prediction between passes: six reticle
  styles, five label kinds, chain/nearest/web links, velocity vectors,
  skeletons, a dithered detection mask and a HUD.
- **Controls.** Detect / Track / Draw deck pages (mode-specific controls only)
  and a Tracking shelf in the browser with twelve preset looks. Setup persists.

### Tracking debt

- The overlay is SwiftUI and is not burned into recordings or stills. Burning it
  in needs the overlay drawn on the GPU (or rasterised into a texture the
  recorder composites), which is its own piece of work.
- Hand and body pose need the Neural Engine and may report "Vision unavailable"
  on some simulators; faces and saliency run anywhere.
- `TrackingSuiteTests` and `EffectLivenessTests` build but were not executed: the
  XCTest runner still cannot attach to simulators in this environment.
