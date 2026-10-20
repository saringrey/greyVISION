# Effects menu refinement

## Scope and direction

Confirmed target: iPhone workspace, not the Mac remote panel. Preserve the workspace's camera/capture/dock positions and the browser's sidebar/grid structure. This is an Operate surface within the incumbent instrument, not a new global visual identity.

- **Thesis:** discover effects from rendered samples, not simultaneous metadata.
- **World:** soft charcoal, warm bone type, restrained selection marks; actual effect color remains unmodified.
- **Path:** Effects → category or search → selection → Adjust. Active, Favorites and Recent remain quick shelves.
- **First viewport:** quiet header and search, four personal shelves followed by directly visible effect groups in the left sidebar, image-first tiles with names beneath.
- **Form:** native SwiftUI sidebar, adaptive image grid, persistent selected-effect footer. The Categories dropdown was removed at the user's request. The user pinned layout and quieter refinement, so no visual-world concept roll or comp was used.

## Implemented surface rules

Source: [browser](../GreyVision/Features/Workspace/GVEffectBrowser.swift) and [dock](../GreyVision/Features/Workspace/WorkspaceDockView.swift).

- Browser canvas RGB `(0.075, 0.073, 0.080)`; elevated surface `(0.115, 0.112, 0.122)`.
- Warm primary text inherits `GVTheme.bone`; secondary browser text uses foreground opacity rather than low-contrast ash.
- SF system title3, subheadline, caption and caption2 styles follow Dynamic Type. The adaptive tile minimum and sidebar width scale with caption size.
- Grid spacing: 14 pt. Preview corners: 14 pt. Search corners: 12 pt. Controls retain 44 pt targets.
- Tiles show preview, name and active check only. Render cost, microphone settings and favorites are available through the native context menu; variant editing remains in the existing parameter deck.
- Shelf changes use a 0.18-second ease-out or no animation with Reduce Motion.
- Every sidebar label shares the same 8 pt row inset; glyph offsets and the asymmetrical Categories heading/dropdown are removed. Selected rows use a quiet 0.10-opacity fill and a trailing 3 pt dot. The 112 pt sidebar scales with caption size, capped at 152 pt, and scrolls independently with visible indicators.

These are local surface decisions, not replacements for the project's global theme. No global DESIGN.md or theme change was made by this refinement.

## Preview behavior and limits

[Thumbnail store](../GreyVision/Features/Workspace/GVEffectThumbnailStore.swift) uses the shipping Metal kernels and default parameters, including the fluid and reaction-diffusion engines. Datamosh samples use a bounded real VideoToolbox encode/decode. Samples are generated on demand on one serial utility queue and cached in memory and a versioned disk directory. Completion publishes invalidation so the browser replaces loading states immediately. Disk encoding/writes stay off the main thread.

All previews use a generated reference scene. Touch, FFT and history inputs are illustrative, not the user's live camera/audio/depth. A temporal still cannot communicate an effect's complete motion. Codec or GPU failures show an explicit unavailable state, never a seeded family substitute. Hardware performance and preview parity for every effect remain unverified.

## Finish review

Review performed inline using the skill's degraded reviewer flow; no separate reviewer agent was available. Native surface: no HTML/CSS detector ran. No approved comp or quality-bar board applies to this user-pinned scoped refinement.

**Disposition: ship, at the inspected surface scope.**

### Persistence

[Product context](../PRODUCT.md) records the confirmed creator workflow and refinement constraints. Incumbent global theme remains untouched by this task.

### Fidelity

| Element | Result | Evidence |
| --- | --- | --- |
| Workspace capture/dock placement | Match | [Dock capture](../diagnostics/effects-dock-consolidated.png) |
| Category/sidebar + adaptive grid | Match | [Aligned Color shelf](../diagnostics/launch-effects-polish/0D4A72F7-1C56-445C-8BE3-CC0E68009664.png) |
| Typography | Match | System styles, medium/regular weights, labels separate from media |
| Material | Match | Shipping-effect samples; no decorative glass/gradient overlays in the gallery |
| Ground | Match | Soft charcoal canvas and elevated surface, warm bone foreground |
| Selection → Adjust | Match | [Portrait selection](../diagnostics/effects-gallery-selection.png) and UI test |
| Landscape | Match | [Settled landscape capture](../diagnostics/launch-effects-polish/F3900332-D0E5-4A2A-8E81-32D6CE9521FD.png); grid/sidebar are scrollable |
| Direct group navigation | Match | No Categories dropdown; [research groups](../diagnostics/sidebar-research-verification/E5BF1051-8F4F-4A39-9781-4393FD94EC3F.png) are directly selectable after scrolling |

### Ceiling

Refinement preserves native controls and the instrument's identity. The sample scene is an algorithm reference, not photographic art. Animated/live preview content is deliberately outside this change.

### Material fixes

Resolved during verification: browser-root accessibility identifier propagation, search-placeholder contrast, title-case acronym/mosh labels, and premature rotation screenshot capture. No further material fixes identified in the inspected captures. Large accessibility text, increased contrast and physical-device use were not visually certified.

### Keep

Preserve actual effect colors, quiet chrome, reachable categories and unchanged composition/capture models.

## Launch and codec follow-up

The same scoped refinement now covers the iPhone entry gate and format chooser; Mac remote UI and existing boot artwork are unchanged.

- [Entry gate](../GreyVision/Features/Launch/GVAccessGate.swift): 252 × 54 pt plate inside a stationary 288 × 90 pt hit region. Mouse/trackpad hover attracts the plate by at most 6 pt horizontally and 4 pt vertically, fading to zero at the region boundary. The cursor is not repositioned. Hover brightens/scales the plate; press compresses it with existing haptic/sound feedback. Opening adds a brief decay/perimeter response. Duplicate activation is blocked; the activation task cancels on disappearance. Reduce Motion removes translation/scale and the opening delay. No new idle animation loop.
- [Format console](../GreyVision/Features/Launch/Boot/GVSplashChoiceRail.swift): charcoal chamfered panel, static registration ticks, monospaced codec cards and model-backed chroma/depth/tier/fidelity readouts. Selected cards get a restrained check/fill and 180 ms event-triggered decay, not continuous decorative corruption. ProRes names wrap deliberately. Compact landscape omits the extra spec grid to keep the chooser and dock visible. Availability and saved format IDs are unchanged; SELECTED does not imply verified hardware support.
- [Format dock](../GreyVision/Features/Launch/BootView.swift): cleaner system-monospaced labels, quieter borders and press feedback. The existing 230 ms auto-close remains, with stale close tasks cancelled when changing sections or leaving.
- Inspected: [entry](../diagnostics/launch-polish-final/A39BE429-FD2A-40EB-AFDF-39399BC3695F.png), [codec portrait](../diagnostics/launch-polish-final/codec-portrait-review.png), [codec landscape](../diagnostics/launch-polish-final/EC039FB1-42A2-433A-8D97-0B05FA4CC091.png), and the sidebar captures above.

## Family taxonomy — what each shelf actually is

The user asked for the groups to say what they contain, and for a datamosh group and a LiDAR group specifically. Families are now derived from actual membership rather than inherited names.

| Shelf | Contains |
| --- | --- |
| TONAL | thermal, solarize, hueShift, invert, monochrome — darkroom/film-stock ops |
| DATAMOSH | datamosh, liquidMosh, heavyMosh — the three that really run VideoToolbox |
| SORT | sort, depthSort, objectSort, radialSort, temporalPixelSort, pointCloudSmear, freezeBrush, sortBrush |
| HISTORY | depthFeedback, feedbackTunnel, lumaExtrusion, rollingTime, frameHoldSmear, pixelGravity, pixelShift |
| MOTION | temporal feedback + vector flow |
| DECAY | primitive rebuilds, transport failure, material dissolution |
| ANALOG | analog tape, broadcast artefacts, glitch, dataBend |
| LENS | lens and optical simulation |
| GEOMETRY | spatial geometry + field warps |
| GENERATIVE | single-pass shader looks |
| SPECTRUM | FFT-driven audio effects |
| INSTRUMENTS | measurement scopes |
| SOLVERS | whole-frame solvers and reactive generative work |
| RESEARCH | SARIN experiments, predictive moshes, corruption brush |

TIME previously meant moshes + sorts + frame history at once, so hunting for "the mosh one" meant scrolling past sorts. It is now three shelves, and the partition test enforces that all 192 effects land in exactly one.

**Depth is deliberately not a family.** `depthSort`, `pointCloudSmear` and `depthFeedback` are named for depth but their own detail strings read LUMA SORT / SPARSE CLOUD DRAG / LUMA DEPTH LOOP — they rank pixels, they do not read a scanner. Filing them under "LiDAR" would have overstated them. Instead a separate **Depth** group below the families lists the nine genuine `DepthEffectMode` values (point cloud, heatmap, contours, depth field, parallax, relight, space scan, subject decay, night vision), greyed out with the hardware's own reason when ARKit scene depth is absent. Selecting one runs the real depth path.

`opticalFlowLiquid` is a declared variant of `liquidMosh` and canonicalises to it, so it is filed with the moshes; leaving it in History made that shelf render a tile captioned "Liquid Mosh". `EffectCatalogTests` now asserts that every effect's canonical representative lives in the same group it is filed under, which catches the whole class of bug.

## Verification

- Final simulator build-for-testing: passed (exit 0). Taxonomy tests (family partition, shelf/category agreement, names-for-contents): **3 passed, 0 failed**. Family reachability sweep across all 14 families plus Depth: **1 passed, 0 failed**.
- EffectCatalogTests + magnetic geometry regression: **14 passed, 0 failed**. Geometry covers actual hit-region size, peak bounds, symmetry, invalid input and Reduce Motion.
- Focused FlagshipUITests: **4 passed, 0 failed** across two final runs: aligned direct sidebar groups; research-group scrolling and return to All; portrait/landscape gallery selection → Adjust; entry activation and H.264/HEVC selection/auto-close in portrait and landscape.
- Result bundles: [14 unit tests](../build/EffectsRefinement/Logs/Test/Test-GreyVision-2026.10.02_01-37-54--0500.xcresult), [research sidebar](../build/EffectsRefinement/Logs/Test/Test-GreyVision-2026.10.02_01-37-15--0500.xcresult), [three focused UI tests](../build/EffectsRefinement/Logs/Test/Test-GreyVision-2026.10.02_01-38-45--0500.xcresult).
- `CameraEffectTests.testShaderShowcaseIsACompleteStandaloneFamily` **fails, and did so before this change**: it expects `shaderCategoryEffects` to hold 36 effects with `styleMode` 104–139, but that array already held 25 in the working tree. The GENERATIVE rename only relabelled it. Not repaired here.
- The broader every-category sweep historically timed out and left incomplete bundles. The narrower family sweep covering every shelf including Datamosh and Depth passed.
- Existing audio-session main-thread and gradient-stop runtime warnings remain. The beta simulator also logs a malformed runtime bundle warning; not repaired in this visual task.
- Real mouse/trackpad feel, large accessibility text, increased contrast and physical-device performance remain unverified. These follow-up edits have not been installed on Nick's iPhone. No full-suite or Mac UI validation claimed.

## Earlier gallery verification (before direct-sidebar follow-up)

- Xcode simulator app build and build-for-testing: passed.
- EffectCatalogTests + CameraEffectStackSlotTests: **20 passed, 0 failed**.
- Focused FlagshipUITests: **4 distinct tests passed** (consolidated entry/category menu; portrait/landscape selection and Adjust; quick shelves; every category including research shelves and LiDAR mode access).
- Simulator: iPhone 17 Pro, iOS 27.0. Portrait and settled landscape captures inspected.
- Initial UI runs timed out due simulator lifecycle instability; isolated final runs passed. An unmatched pre-existing brace in CameraEffectTests was minimally removed to unblock test compilation.
- Xcode beta's missing Metal toolchain was downloaded with explicit user approval.
- Existing compiler concurrency/deprecation warnings remain. The all-category run also reports an AVAudioSession main-thread activation warning from the existing audio runtime; not repaired in this visual task.
- The earlier gallery build was subsequently installed on Nick's iPhone in a separate user-requested step. That installation predates the entry/codec/direct-sidebar follow-up above. No full-suite pass, thermal/performance certification or Mac UI changes claimed.
