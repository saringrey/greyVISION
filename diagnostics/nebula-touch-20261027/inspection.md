# Bounded splash inspection — 2026-10-27

Target: GreyVision Title QA, 661801FF-8825-42FC-A52E-AD48D2837767. App: com.saringrey.greyvision (already running, --uitesting supplied by main).
Requested context: /Users/grey/Documents/greyvisionMASTER/GreyVision.xcodeproj; scheme GreyVision; derived data /private/tmp/gv-title-20261027. session_show_defaults was not exposed to this agent, so saved MCP defaults could not be verified. No build, install, launch, or source mutation was performed.

Read device-interaction and MobileBuildMCP skills. Captures used explicit-UDID simctl fallback; runtime hierarchy and real direct input used CUA Device Hub, window GreyVision Title QA. The legacy Simulator bundle ID was unavailable; Device Hub was available and unlocked. No original simulator was targeted.

Confirmed:
- Default portrait captured with content_size=large; screenshot is 1179x2556 pixels.
- Default CODEC/FPS/RES row is visually about 300pt wide and 44pt high (screenshot estimate assuming 3x scale). This is a rendered-bound estimate; no exact accessibility hit-target bounds were exposed.
- Both ASCII title lines are horizontally centered; glyph patterns change between observations without visible geometry displacement, consistent with decryption.
- Dithered blue/teal/purple nebula visible; no rain visible in the sampled frames. No long recording or FPS assertion.
- Exactly one codec tap: CUA direct coordinate click [416,1338] on the observed Device Hub screenshot. It opened Encoding; hierarchy changed Collapsed to Expanded and exposed four formats, HEVC selected. Blue/navy submenu body and cyan/blue border are visible. No format selection was changed.
- accessibility-extra-extra-large was set, queried, and captured. Restored and queried large afterwards and at end.

Defect:
- At accessibility-extra-extra-large CODEC wraps as CODE / C. Its button becomes taller than adjacent FPS/RES buttons. Evidence: portrait-accessibility-xxl.png. No overlap or off-screen controls observed in this capture.

Unverified:
- Background reaction: one real CUA drag [380,480] -> [730,610] across unobstructed background, with codec submenu open. The API completed and after-state was captured, but autonomous nebula animation prevents attributing a distinct local response to this drag from the stills. Do not claim touch reaction passed or failed based on these frames.
- Exact minimum touch-target dimensions and physical iPhone behavior were not measured.

Final state: owned simulator left running on splash, codec submenu open, HEVC/60/4K unchanged, text size large. No extra app launches or recordings.

Evidence: portrait-default.png; portrait-accessibility-xxl.png; devicehub-before.png/.txt; codec-after.png/.txt; submenu-blue.png; background-drag-after.png/.txt; final-hierarchy.txt; final-large.png.

## Final confirmation after correction

The main agent fixed the large-text CODEC wrap with a single-line, scaling label. Rebuilt simulator and signed device products. `large-text-fixed.png` confirms all three labels remain on one line with equal-height controls at accessibility-extra-extra-large. Restored the simulator's text size to large.

Direct Device Hub input confirmed CODEC, FPS, and RES open their blue submenus. After background touch input, choosing H.264 updated CODEC and collapsed the chooser; choosing 30 FPS likewise updated FPS and collapsed the chooser. The resolution menu was also inspected and closed. These interactions occurred only on the QA simulator.

A held background touch and a drag were recorded in `touch-preview.mp4`. The recording shows a localized circular dither glow/ripple that resolves back into the nebula. `touch-demo.mp4` is a shorter excerpt. Rain is absent; the centered, sequentially decrypting title remains present.

The current production nebula input passed a standalone Swift self-check over 141 fade frames, normalized-coordinate bounds, invalid inputs, bounded tilt, and wrapped time. The XCTest targets compiled, but execution could not begin because `DTServiceHubClient` could not bless the simulator's Instruments service; the blocked run was canceled. No XCTest pass is claimed.

The final signed build was installed and launched on Nick's iPhone. An independent CoreDevice process query confirmed PID 2885 in the newly installed container `16A14E89-776A-43A9-94F7-5B07B2F2DAAB`. Physical tilt response and device FPS were not measured. The QA simulator was shut down after verification.
