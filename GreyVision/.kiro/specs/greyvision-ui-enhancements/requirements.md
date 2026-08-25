# Requirements Document

## Introduction

The grey//VISION UI Enhancement project aims to transform the existing iOS native app into a high-end creative instrument. This is a live visualizer/creative engine for video processing that already has a complete core camera pipeline and rendering infrastructure. The UI needs significant refinement to achieve a premium, cinematic feel with professional creative tool aesthetics.

## Glossary

- **GreyVision**: The existing iOS native application (SwiftUI + Metal) serving as a live visualizer/creative engine for video processing
- **Camera Viewport**: The primary display area showing live camera input, including overlays and telemetry
- **CRT/Phosphor Aesthetic**: Visual style mimicking cathode ray tube displays with phosphor glow effects
- **Signal Fracture**: Two-finger gesture interaction that tears open the camera signal to reveal temporal layers
- **Time Scrub**: Touch-and-hold gesture to navigate through recent camera history frames
- **Depth Peel**: LiDAR-based layer separation showing depth-based layering of the scene
- **Modulation Orbits**: Radial parameter modulation menus for creative control
- **Audio Damage**: Sound-based effects that create visual distortion when audio levels exceed thresholds
- **Control Terminal Style**: UI controls inspired by video synthesizers and audio mixing consoles with precise, granular control
- **System/Term**: [Definition]

## Requirements

### Requirement 1: Premium Camera Viewport

**User Story:** As a creative operator, I want the camera viewport to feel like a high-end professional instrument, so that I can trust the quality of my visual output.

#### Acceptance Criteria

1. THE Camera_Viewport SHALL render subtle corner brackets at all four corners of the viewport
2. WHEN the camera is active, THE Camera_Viewport SHALL display contextual telemetry including capture status, resolution, frame rate, and zoom level
3. WHILE the camera is running, THE Camera_Viewport SHALL render corner brackets with opacity that fades in over 300ms on startup
4. THE Corner_Bracket SHALL be configurable in color, thickness, and offset from viewport edges
5. WHERE a new camera configuration is applied, THE Camera_Viewport SHALL update telemetry display within 100ms
6. WHEN accessibility.reduceMotion is enabled, THE Corner_Bracket SHALL render without animation and use static opacity

### Requirement 2: Asymmetrical Layout Engine

**User Story:** As a creative director, I want the interface to use controlled asymmetry in layout, so that the visual composition feels intentional and artistic rather than template-based.

#### Acceptance Criteria

1. THE Layout_Engine SHALL provide at least three distinct asymmetrical layout presets
2. WHEN the workspace layout changes, THE Layout_Engine SHALL calculate viewport area as the largest contiguous rectangle excluding docked control panels
3. WHILE resizing the interface, THE Layout_Engine SHALL maintain aspect ratio constraints for key compositional elements
4. WHERE viewport area becomes zero (no usable space), THEN THE Layout_Engine SHALL continue enforcing aspect ratio constraints
5. IF a panel position conflicts with viewport boundaries, THEN THE Layout_Engine SHALL automatically adjust panel z-index and overlap
6. WHERE user-defined layouts are saved, THEN THE Layout_Engine SHALL persist panel positions, sizes, and z-orders as a complete unit - either all three properties together, or none at all
7. WHEN layout preset changes, THE Layout_Engine SHALL animate transitions with spring physics (damping: 0.7, stiffness: 400)

### Requirement 3: Cinematic Boot Sequence

**User Story:** As a creative professional, I want a cinematic boot sequence that establishes the tool's premium nature, so that users immediately recognize the quality of the creative instrument.

#### Acceptance Criteria

1. THE Boot_Sequence SHALL last between 2.5 and 4 seconds
2. WHEN the application launches, THE Boot_Sequence SHALL play in sequence: phosphor bloom → CRT scanline reveal → system status → main interface
3. WHILE the boot sequence is playing, THE Boot_Sequence SHALL disable all touch input to the application
4. THE Phosphor_Bloom Effect SHALL create a gradient that expands from center to corners over 1200ms with ease-out timing
5. WHEN boot sequence completes, THE Boot_Sequence SHALL transition to main interface with fade-in duration of 400ms
6. IF userForceQuickBoot environment variable is set, THEN THE Boot_Sequence SHALL skip visual effects and transition directly to main interface in 500ms
7. WHERE accessibility.reduceMotion is enabled, THEN THE Boot_Sequence SHALL skip all animations and show static CRT scanlines for 1500ms

### Requirement 4: Signal Fracture Interaction

**User Story:** As a visual artist, I want to use a two-finger gesture to tear open the camera signal and reveal temporal layers, so that I can creatively manipulate depth and time in my compositions.

#### Acceptance Criteria

1. WHEN a two-finger pinch-out gesture is detected on the camera viewport, THE Signal_Fracture_Interpreter SHALL recognize and trigger fracture mode
2. WHILE fracture mode is active, THE Signal_Fracture_Renderer SHALL display at least 3 temporal layers with depth separation
3. THE Temporal_Layer SHALL show camera frames from different time offsets: current (0ms), recent (200ms), past (500ms)
4. WHERE fracture scale exceeds 2.0, THEN THE Signal_Fracture_Renderer SHALL apply chromatic aberration with maximum 5px offset
5. WHEN fracture mode ends, THE Signal_Fracture_Interpreter SHALL return to standard view within 300ms with smooth interpolation
6. IF no gesture detected for 3 seconds, THEN THE Signal_Fracture_System SHALL automatically exit fracture mode
7. WHERE fracture layers exceed screen boundaries, THEN THE Signal_Fracture_Renderer SHALL clamp and mask overflow

### Requirement 5: Time Scrub Navigation

**User Story:** As a video editor, I want to touch and hold to scrub through recent camera history, so that I can quickly find and reference specific moments in my recording session.

#### Acceptance Criteria

1. WHEN a touch-and-hold gesture is detected on the camera viewport for 250ms, THE Time_Scrub_Interpreter SHALL activate
2. WHILE time scrub is active, THE Time_Scrub_Renderer SHALL display a timeline overlay at the viewport bottom
3. THE Timeline_Overlay SHALL show at least 30 seconds of camera history in scrollable format
4. WHEN finger position moves horizontally, THE Time_Scrub_Renderer SHALL seek to corresponding time position with 50ms latency maximum
5. IF scrub speed exceeds 2 seconds of content per second of real time, THEN THE Time_Scrub_Renderer SHALL accelerate playback rate up to 4x
6. WHERE scrub duration exceeds 30 seconds, THEN THE Time_Scrub_Renderer SHALL show "END" indicator and disable further scrubbing
7. WHEN scrub ends, THE Time_Scrub_Renderer SHALL return to live camera feed within 100ms

### Requirement 6: Depth Peel Visualization

**User Story:** As a 3D artist, I want LiDAR-based layer separation showing depth-based layering, so that I can creatively work with spatial depth in my compositions.

#### Acceptance Criteria

1. WHEN LiDAR depth data is available, THE Depth_Peel_Engine SHALL parse depth maps at 30Hz minimum
2. THE Depth_Peel_Engine SHALL provide at least 4 depth layers with configurable thresholds
3. WHILE depth peel is active, THE Depth_Peel_Renderer SHALL render each layer with separate opacity and blending
4. THE Layer_Offset SHALL be configurable per layer with minimum 5px horizontal separation
5. IF depth confidence below 0.3, THEN THE Depth_Peel_Renderer SHALL apply gaussian blur with sigma 2.0 to that pixel region
6. WHERE depth peel mode activates, THE Depth_Peel_Engine SHALL initialize with default thresholds: foreground (0-1m), midground (1-3m), background (3-5m), far (5m+)
7. WHEN device lacks LiDAR capability, THEN THE Depth_Peel_Engine SHALL use synthetic depth estimation with the same 0.3 confidence threshold for gaussian blur effects, and show warning indicator

### Requirement 7: Modulation Orbits Menu

**User Story:** As a sound designer, I want radial parameter modulation menus, so that I can intuitively control multiple parameters with circular gestures.

#### Acceptance Criteria

1. WHEN a circular gesture is detected, THE Modulation_Orbit_Interpreter SHALL recognize and display modulation orbits
2. THE Modulation_Orbit_Render SHALL display at least 3 orbital rings with configurable parameters
3. WHILE an orbit ring is active, THE Modulation_Orbit_Renderer SHALL update target parameter at 60Hz
4. THE Parameter_Deadzone SHALL be configurable with default radius of 10 pixels
5. WHERE multiple fingers interact, THE Modulation_Orbit_System SHALL support up to 3 simultaneous orbit controls
6. WHEN orbit radius exceeds 80% of viewport smallest dimension, THEN Modulation_Orbit_Renderer SHALL clamp to maximum parameter value
7. IF no parameter selection within 10 seconds, THEN Modulation_Orbit_System SHALL deactivate

### Requirement 8: Audio Damage Effects

**User Story:** As a creative audio-visual artist, I want sound-based effects that create visual distortion, so that audio intensity directly influences the visual output.

#### Acceptance Criteria

1. WHEN audio peak level exceeds 0dB, THE Audio_Damage_Engine SHALL trigger visual distortion effects
2. THE Audio_Damage_Renderer SHALL provide at least 3 distortion types: color shift (RGB separation), pixelation, and scanline jitter
3. WHILE audio damage is active, THE Audio_Damage_Renderer SHALL update effect intensity based on current dB level (0-1.0 normalized)
4. THE Damage_Threshold SHALL be configurable with default 0dB threshold
5. IF audio sample rate changes, THEN THE Audio_Damage_Engine SHALL reinitialize audio analyser within 200ms
6. WHERE damage exceeds 80% intensity, THEN THE Audio_Damage_Renderer SHALL apply chromatic aberration with 8px RGB separation
7. WHEN audio level drops below threshold, THE Audio_Damage_Engine SHALL fade out damage effect over 500ms

### Requirement 9: Terminal-Style Control System

**User Story:** As a video synthesizer operator, I want terminal-inspired controls with precise, granular parameter adjustment, so that I can make fine-tuned creative decisions.

#### Acceptance Criteria

1. THE Control_Render SHALL display sliders with 1000+ discrete steps for fine-grained control
2. WHEN slider interaction begins, THE Control_Renderer SHALL show numeric value overlay with 0.01 precision
3. WHERE modifier key (Command/Ctrl) is held during interaction, THE Control_Renderer SHALL multiply precision by 10x
4. THE Slider_Interaction SHALL support click-to-set, drag, and scroll-wheel input methods
5. WHILE slider value changes, THE Control_Renderer SHALL call onValueChange callback at 60Hz maximum rate
6. IF slider value changes by more than 50% in single gesture, THEN THE Control_Renderer SHALL show confirmation overlay
7. WHEN control preset is loaded, THE Control_Renderer SHALL animate all controls to new values over 300ms

## Correctness Properties

### Camera Viewport Correctness

1. **Invariant**: Corner bracket count = 4 when viewport is active
2. **Round Trip**: Configure corner brackets → Update parameters → Read back → Parameters match configuration
3. **Idempotence**: Apply same viewport configuration multiple times → Final state identical to single application

### Time Scrub Correctness

1. **Invariant**: Time scrub timeline length = min(30s, recording duration)
2. **Round Trip**: Seek to time T → Return to live → Seek to T again → Same frame displayed
3. **Metamorphic**: `length(scrubbed_frames) ≥ 1` when scrub completes successfully

### Audio Damage Correctness

1. **Invariant**: Damage effect intensity = normalized audio peak level
2. **Round Trip**: Apply damage → Remove audio → Re-apply same audio → Same damage effect
3. **Error Conditions**: Generate audio with NaN/Infinity values → System handles gracefully without crash

### Control System Correctness

1. **Round Trip**: Set slider value V → Read slider value → Result equals V within tolerance 0.001
2. **Metamorphic**: `abs(final_value - initial_value) ≤ abs(gesture_delta)` for single gesture
3. **Idempotence**: Apply same slider value multiple times → Control state unchanged after first application

## Property-Based Testing Guidance

**When to Use Property-Based Testing:**

| Component | Property Test | Integration Test |
|-----------|---------------|------------------|
| Time scrub frame seeking | Round trip seeking | End-to-end gesture detection |
| Audio damage distortion | Intensity matches dB level | Audio input → Visual output |
| Control slider precision | Value round trip | Multi-touch interactions |
| Depth peel layering | Layer count invariant | LiDAR data parsing |

**When NOT to Use Property-Based Testing:**

- Camera viewport corner bracket rendering (visual consistency tests)
- Boot sequence timing (smoke test with single execution)
- Audio damage trigger thresholds (single threshold value)

## Glossary

- **GreyVision**: The existing iOS native application serving as a live visualizer/creative engine for video processing
- **Camera_Viewport**: The primary display area showing live camera input with overlays and telemetry
- **Corner_Bracket**: UI element at viewport corners with configurable appearance
- **Layout_Engine**: System managing asymmetrical layout calculations and panel positioning
- **Boot_Sequence**: Application startup sequence with CRT/phosphor aesthetic
- **Phosphor_Bloom**: CRT-style gradient effect expanding from center during boot
- **Signal_Fracture_Interpreter**: Gesture recognition system for two-finger tearing interaction
- **Signal_Fracture_Renderer**: System displaying temporal layers during fracture mode
- **Temporal_Layer**: Displayed version of camera feed from different time offset
- **Time_Scrub_Interpreter**: Gesture recognition for touch-and-hold history navigation
- **Time_Scrub_Renderer**: System displaying timeline and seeking through camera history
- **Depth_Peel_Engine**: LiDAR-based depth parsing and layer separation system
- **Depth_Peel_Renderer**: System rendering depth-based layer separation
- **Modulation_Orbit_Interpreter**: Gesture recognition for radial parameter modulation
- **Modulation_Orbit_Renderer**: System displaying and updating radial modulation controls
- **Audio_Damage_Engine**: System interpreting audio levels as visual damage intensity
- **Audio_Damage_Renderer**: System applying distortion effects based on audio input
- **Control_Renderer**: System rendering terminal-style parameter controls
- **Control_Interaction**: User input handling for parameter adjustments
