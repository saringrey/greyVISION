# grey//cam — Native iOS Camera App prompt

Build a native iOS camera app called **grey//cam** that shares the visual and interaction language of the existing **grey//vision** project in this repository, but is a focused photography instrument rather than a live datamosh/decay surface.

## Current branch
`codex/cohesive-flagship-effects` — reuse anything cohesive on this branch; do not start from an unrelated branch.

## Design language to inherit
- Palette from `GreyVision/DesignSystem/GVTheme.swift`: void black canvas, warm `bone` type, `ash` secondary, `violet` selection, `acid` armed/ready, `record` recording/error, `warn` warning. Six colours carrying meaning; accents are information, not decoration.
- Surfaces from the same file: `surfacePrimary` (black 0.68 opacity), `surfaceSecondary` (black 0.30), `surfaceArmed` (black 0.74) — three tiers, not eleven.
- Layout constants from `GreyVision/DesignSystem/GM...` — tight radii (`radiusTight 4`, `radius 7`, `radiusPanel 14`), dense spacing scale (`gapHair 3`, `gapTight 5`, `gap 8`, `gapWide 13`, `screenInset 12`, `cornerShoulderInset 25`), hairline borders, `controlHeight 40`, `touchTarget 44`.
- Type from `GVTheme.TypeLevel`: `.branding 25 / .control 16 / .telemetry 14 / .diagnostic 8.5`, monospaced design, tracking 1.6 / 0.4 / 0.2 / 1.3. The `.terminal()` condensed helper exists for machine-type labels.
- Primitives reuse from `GVPrimitives.swift`: `GVRule`, `GVBrackets`, `GVPanel`, `GVInstrumentButton`, `GVStatusPip`, `GVScanlines`, `GVGridField`, `GVChamferedPlate`, `GVPlateRegistration`, `GVEdgeRule`.
- Stardust treatment from `GVStardustButton.swift`: frosted glass over a deterministic starfield, darker than standard chrome, inverts to a bright plate with the starfield retained when active, dimmed to ~38% opacity in non-selected states. Reuse for any selection UI.
- Glass material from `GVGlass.swift` and ambient-light reactive borders from `GVLightReactiveBorderOverlay` / `GVBreathingBorder`.
- The existing motion subsystem (`CameraLevelMotion`, `GVAmbientLight`, `GVMotion`) is available — reuse device-motion and ambient-light sampling rather than inventing new sensor plumbing.
- The existing `DeterministicStarfield` shader/view and the general shader pipeline (`CameraShaders.metal` style) are available for any on-GPU atmospheres.

Grey//cam should read as the same instrument family: same type, same spacing, same three-surface palette, same hairlines, same starfield-into-glass for selected controls. It should not look like a generic iOS settings app nor like grey//vision's decay-first creative surface.

## Product positioning
grey//cam is a native iOS camera app for people who want the hardware and computational photography of the device, wrapped in an instrument UI instead of the system camera. It is not a filter app. The value is control, fidelity, and a distinctive capture experience.

The three grey//vision things that MUST carry over fully and work correctly:
1. **Lunar mode** — a true low-light moon capture mode, not a cosmetic tint. It should do what lunar/nightmode photography requires: long-ish integration, scene-referred highlight discipline, stable autoexposure behavior aimed at a small bright subject against black, zero moon blooming, and UI language that says what it is. This must actually work as a camera mode.
2. **Nightmode** — a genuine low-light still mode with multi-frame integration behavior appropriate to the device, not a dark vignette filter. Nightmode is the daytime sibling of lunar, tuned for terrestrial darkness.
3. **Cohesive codec/format flags** — grey//vision already has codec/FPS/resolution selection that shrinks and feels cohesive. grey//cam should inherit the same kind of selection treatment for capture format, codec/bitrate choices, aspect, and any other format flags, with the active selection carrying the stardust active treatment.

## The five flagship features
Each one should feel like a reason to choose grey//cam over the system camera. They must be creative, coherent with the design language, and actually implemented — not placeholder screens.

### 1. Void frame — exposure discipline mode
A photographic mode whose point is restraint: the UI stops trying to make the image light and starts protecting highlights and shadows the way a photographer would metering for a scene. Think: scene-referred capture behavior, controlled highlight rolloff, a live exposure ladder in the UI, and an explicit "protect highlights" stance for high-contrast subjects. Visually, the overlay is quiet and instrument-like — a small exposure readout and a defended-highlights indicator — rather than a bright HDR glow. This is the mode for shooting into streetlights, backlit subjects, anything where the system camera's autoexposure would blow the subject.

### 2. Afterimage buffer — the last 6 seconds are always recoverable
grey//cam keeps a rolling buffer of the last several seconds of viewfinder so that when something happens — a passerby, a light change, a gesture, a bird — the operator can pull the frame back from before they pressed. The UI is a wristwatch-style "rewind" gesture: a deliberate drag backward re-scans the buffer, a tap commits. This must feel like film advance in reverse. The buffer must be real capture data, not a screenshot replay, so resolution and EXIF metadata come with it. Show a timecode-style indicator of where in the buffer the finger is.

### 3. Apertur viewfinder — depth as composition
The viewfinder itself becomes a depth instrument. Use the LiDAR/depth data the device provides to draw a live depth map or depth ribbon inside the overlay — not as a gimmick but as a compositional aid. The operator can choose to see depth as a faint heatmap, as contour hatch, or as a focus-priority overlay that tells them what will be sharp. This turns the depth sensor from a portrait-blur tool into a compositional instrument. It must work with the real depth pipeline on device and degrade gracefully when depth is unavailable.

### 4. Tether light meter — the screen becomes a spot meter
When the operator long-presses somewhere in the frame, that point becomes the meter reference and the exposure settings around it respond as a spot meter would: the readout at the press point shows luminance and the exposure adjusts to it. The rest of the meter UI falls back until the press releases. This is the handheld version of "metering from a point." Make the press point read out like a small instrument — luminance, EV, and the resulting exposure decision — with the same type and spacing as the rest of the app.

### 5. One-shot silhouette — instant shape extraction
A capture mode that does not try to make a beautiful photo first. It captures, immediately extracts a clean high-contrast shape/mask from the frame using the depth and luminance data available, and presents the operator with a black-and-white silhouette they can keep or discard in one gesture. The intent is speed and clarity: the app turns a complex extraction into a single capture-and-keep action. Silhouettes are saved as real assets with proper metadata, not as ephemeral views. The UI for this should feel like a different kind of capture button, with a clear "KEEP / DISCARD" moment.

## What grey//cam is NOT
- Not a live shader/decay surface. grey//vision owns that; grey//cam's overlays are photographic instruments, not datamosh.
- Not a social app, not a gallery app, not a full photo editor. Capture and shape extraction are in scope; heavy post is not.
- Not a reskin with no real camera behavior. The lunar, nightmode, and exposure-discipline features must be real capture modes.

## Scope of implementation
- A working capture stack with at least the lunar and nightmode capture modes genuinely implemented.
- The five flagship features above, each implemented enough to be usable and distinctive, not mock screens.
- The cohesive format/codec selection treatment from grey//vision, applied to capture format choices.
- A coherent main capture screen that reads like the grey//vision instrument family.
- Shared design-system reuse where it already exists; do not duplicate primitives that already live in grey//vision — import and use them.

## Deliverables expected from this prompt
- A plan for grey//cam scoped to the existing repository and branch.
- Working code for the capture modes and the five features, wired into a real camera flow.
- A visual main capture surface that uses the inherited type, palette, spacing, and stardust/glass treatments.
- Build verification at the end, and install to Nick's iPhone when asked.
