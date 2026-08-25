# Implementation Plan: grey//VISION UI Enhancement Project

## Overview

This implementation plan transforms the existing grey//VISION iOS app (SwiftUI + Metal) into a premium creative instrument with 9 major UI enhancements. The plan follows a modular approach where core infrastructure is built first, followed by individual feature implementations, then polish and optimization.

**Implementation Language:** Swift (SwiftUI + Metal)

**Architecture Pattern:** State-driven rendering with centralized AppStateContainer

**Performance Target:** 60fps with optimized GPU usage

## Tasks

### Phase 1: Core Infrastructure

- [ ] 1. Set up core state management infrastructure
  - [-] 1.1 Create AppStateContainer with @Published properties
    - Implement `AppStateContainer` class with @MainActor annotation
    - Add @Published properties for all gesture states (fractureMode, timeScrubMode, damageMode)
    - Add @Published properties for camera viewport state and telemetry
    - Add @Published properties for layout, terminal controls, and audio state
    - Implement state update methods with proper isolation
    - _Requirements: 1.2, 2.1, 3.1, 4.1, 5.1, 6.1, 7.1, 8.1, 9.1_
  
  - [~] 1.2 Create GestureStateRegistry for gesture conflict resolution
    - Implement gesture priority system
    - Add gesture state tracking and conflict detection
    - Implement gesture timeout handling
    - _Requirements: 4.1, 5.1, 7.1_
  
  - [~] 1.3 Create AccessibilitySettings model and detection system
    - Implement accessibility settings observer
    - Add reduceMotion, preferCrossFadeTransitions properties
    - Add Dynamic Type scale detection
    - Implement settings update notifications
    - _Requirements: 1.6, 3.7_

- [ ] 2. Set up Metal rendering pipeline foundation
  - [~] 2.1 Create CameraMetalSurface view
    - Implement SwiftUI view wrapping MTKView
    - Set up Metal device and command queue
    - Implement CVPixelBuffer to MTLTexture conversion
    - Add frame timing management for 60fps target
    - _Requirements: 1.1, 4.2, 6.2, 8.2_
  
  - [~] 2.2 Implement post-processing effect chain system
    - Create EffectChain protocol and base implementation
    - Implement effect ordering and composition
    - Add effect enable/disable toggle system
    - Implement render pass management
    - _Requirements: 4.4, 6.3, 8.2_
  
  - [ ]* 2.3 Write unit tests for Metal pipeline
    - Test texture creation from pixel buffers
    - Test effect chain ordering
    - Test render pass configuration
    - _Requirements: 2.1, 4.2, 6.2_

- [ ] 3. Create temporal frame buffer system
  - [~] 3.1 Implement TemporalFrameBuffer class
    - Create circular buffer for frame storage (180 frames max)
    - Implement frame addition with timestamp tracking
    - Add frame retrieval by timestamp with interpolation
    - Implement memory pressure handling and eviction
    - Add frame buffer capacity management (500MB max)
    - _Requirements: 4.3, 5.3_
  
  - [ ]* 3.2 Write property tests for temporal frame buffer
    - **Property 1: Frame retrieval consistency**
    - **Validates: Requirements 5.2 (Round trip seeking)**
    - Test that seeking to time T twice returns same frame
    - Test frame interpolation accuracy
    - Test buffer wraparound behavior
    - _Requirements: 5.2_

- [~] 4. Checkpoint - Verify core infrastructure
  - Ensure all tests pass, ask the user if questions arise.

### Phase 2: Camera Viewport Enhancement (Requirement 1)

- [ ] 5. Implement corner bracket rendering
  - [~] 5.1 Create CornerBracketView SwiftUI component
    - Implement bracket geometry with Path API
    - Add configurable color, thickness, and offset properties
    - Implement 300ms fade-in animation with ease-out timing
    - Add accessibility support: instant appearance if reduceMotion enabled
    - Position brackets at all 4 corners with proper insets
    - _Requirements: 1.1, 1.3, 1.4, 1.6_
  
  - [~] 5.2 Create CameraViewportView container
    - Implement viewport container with ZStack layering
    - Integrate CameraMetalSurface as base layer
    - Add corner bracket overlays
    - Implement viewport state management
    - _Requirements: 1.1, 1.2_
  
  - [ ]* 5.3 Write unit tests for corner bracket configuration
    - **Property 2: Corner bracket configuration round trip**
    - **Validates: Requirements 1.4 (Configuration properties)**
    - Test configuration → read back → match
    - Test animation timing
    - Test accessibility overrides
    - _Requirements: 1.4, 1.6_

- [ ] 6. Implement telemetry display system
  - [~] 6.1 Create TelemetryManager for camera status tracking
    - Implement AVCaptureDevice property observers
    - Track resolution, frame rate, zoom level
    - Track exposure, ISO, shutter speed, lens position
    - Implement 100ms update throttling
    - _Requirements: 1.2, 1.5_
  
  - [~] 6.2 Create TelemetryView SwiftUI overlay
    - Design telemetry layout with SF Mono font
    - Implement dynamic type support
    - Add VoiceOver accessibility labels
    - Position telemetry in bottom-left corner
    - _Requirements: 1.2, 1.5_
  
  - [ ]* 6.3 Write integration tests for telemetry updates
    - Test telemetry update within 100ms of config change
    - Test throttling behavior
    - Test Dynamic Type scaling
    - _Requirements: 1.5_

### Phase 3: Asymmetrical Layout Engine (Requirement 2)

- [ ] 7. Implement layout engine core
  - [~] 7.1 Create LayoutEngine with viewport calculation
    - Implement viewport area calculation excluding docked panels
    - Add aspect ratio constraint enforcement
    - Implement z-index conflict resolution
    - Add panel overlap detection and adjustment
    - _Requirements: 2.2, 2.3, 2.4, 2.5_
  
  - [~] 7.2 Create layout preset system
    - Define 3 default presets: Default Asymmetrical, Cinematic Focus, Control-Centric
    - Implement LayoutPreset model with Codable conformance
    - Add preset loading and application
    - Implement spring animation (damping: 0.7, stiffness: 400)
    - _Requirements: 2.1, 2.7_
  
  - [~] 7.3 Implement layout persistence
    - Create Core Data schema for layouts
    - Implement save/load for user-defined layouts
    - Add preset export/import functionality
    - Ensure atomic persistence (all properties or none)
    - _Requirements: 2.6_
  
  - [ ]* 7.4 Write unit tests for layout calculations
    - Test viewport area calculation with various panel configs
    - Test aspect ratio preservation
    - Test z-index conflict resolution
    - _Requirements: 2.2, 2.3, 2.5_

### Phase 4: Cinematic Boot Sequence (Requirement 3)

- [ ] 8. Implement boot sequence orchestration
  - [~] 8.1 Create BootSequenceManager state machine
    - Implement 4-phase boot sequence state machine
    - Add phase timing configuration (phosphor: 1200ms, scanline: 600ms, status: 700ms, fade: 400ms)
    - Implement touch input blocking during boot
    - Add userForceQuickBoot environment variable support
    - Add accessibility reduceMotion fast path (1500ms static)
    - _Requirements: 3.1, 3.2, 3.3, 3.6, 3.7_
  
  - [~] 8.2 Create PhosphorBloomEffect Metal shader
    - Implement radial gradient shader
    - Add center-to-corners expansion animation
    - Implement 1200ms ease-out timing
    - _Requirements: 3.4_
  
  - [~] 8.3 Create CRTScanlineOverlay view
    - Implement scanline reveal animation
    - Add 600ms linear timing
    - Implement static scanline mode for reduceMotion
    - _Requirements: 3.4, 3.7_
  
  - [~] 8.4 Implement boot-to-main transition
    - Create 400ms fade-in animation
    - Add haptic feedback on completion
    - Implement state transition to main interface
    - _Requirements: 3.5_
  
  - [ ]* 8.5 Write integration tests for boot sequence
    - Test full sequence timing (2.5-4s range)
    - Test quick boot bypass
    - Test reduceMotion behavior
    - Test touch blocking during sequence
    - _Requirements: 3.1, 3.3, 3.6, 3.7_

### Phase 5: Signal Fracture Interaction (Requirement 4)

- [ ] 9. Implement signal fracture gesture system
  - [~] 9.1 Create SignalFractureGesture recognizer
    - Implement two-finger pinch-out gesture detection
    - Add scale threshold tracking (recognize > 1.0, fully fractured > 2.0)
    - Implement gesture state machine (inactive → recognizing → fracturing → fullyFractured → returning)
    - Add 3-second inactivity timeout with auto-exit
    - Register with GestureStateRegistry
    - _Requirements: 4.1, 4.6_
  
  - [~] 9.2 Create TemporalLayerRenderer for multi-frame display
    - Implement 3-layer rendering: current (0ms), recent (200ms), past (500ms)
    - Add layer separation with depth offset
    - Implement layer opacity blending
    - Add overflow clamping and masking
    - _Requirements: 4.2, 4.3, 4.7_
  
  - [~] 9.3 Implement ChromaticAberrationEffect Metal shader
    - Create RGB channel separation shader
    - Add 5px maximum offset based on scale
    - Implement effect activation when scale > 2.0
    - _Requirements: 4.4_
  
  - [~] 9.4 Implement fracture return animation
    - Create 300ms smooth interpolation back to normal view
    - Use ease-out-back timing function
    - Reset all fracture state
    - _Requirements: 4.5_
  
  - [ ]* 9.5 Write integration tests for signal fracture lifecycle
    - Test gesture recognition flow
    - Test layer rendering at different scales
    - Test chromatic aberration activation threshold
    - Test auto-exit timeout
    - _Requirements: 4.1, 4.2, 4.4, 4.6_

### Phase 6: Time Scrub Navigation (Requirement 5)

- [ ] 10. Implement time scrub gesture system
  - [~] 10.1 Create TimeScrubGesture recognizer
    - Implement touch-and-hold detection (250ms threshold)
    - Add horizontal position tracking
    - Implement normalized position [0, 1] mapping
    - Calculate playback rate acceleration (2x threshold, 4x max)
    - Register with GestureStateRegistry
    - _Requirements: 5.1, 5.5_
  
  - [~] 10.2 Create TimelineOverlayView
    - Design timeline UI for bottom of viewport
    - Implement 30-second scrollable history display
    - Add current position indicator
    - Show "END" indicator when limit reached
    - Add frame timestamp labels
    - _Requirements: 5.2, 5.3, 5.6_
  
  - [~] 10.3 Implement HistorySeeker with frame buffer integration
    - Create seek algorithm: position → time → frame lookup
    - Implement 50ms maximum seek latency
    - Add frame interpolation for smooth seeking
    - Connect to TemporalFrameBuffer
    - _Requirements: 5.4_
  
  - [~] 10.4 Implement return-to-live functionality
    - Create 100ms transition back to live feed
    - Reset scrub state and clear timeline overlay
    - Resume normal camera processing
    - _Requirements: 5.7_
  
  - [ ]* 10.5 Write property tests for time scrub seeking
    - **Property 3: Seek round trip consistency**
    - **Validates: Requirements 5.4 (Seeking accuracy)**
    - Test seek to T → return to live → seek to T → same frame
    - Test seek latency < 50ms
    - Test acceleration calculation
    - _Requirements: 5.4_

- [~] 11. Checkpoint - Verify gesture systems
  - Ensure all tests pass, ask the user if questions arise.

### Phase 7: Depth Peel Visualization (Requirement 6)

- [ ] 12. Implement depth peel engine
  - [~] 12.1 Create DepthPeelEngine with LiDAR integration
    - Integrate ARKit depth map capture at 30Hz
    - Parse depth maps into layer thresholds
    - Implement default layers: foreground (0-1m), midground (1-3m), background (3-5m), far (5m+)
    - Add per-layer configuration: min/max distance, offset, opacity
    - _Requirements: 6.1, 6.2, 6.6_
  
  - [~] 12.2 Implement depth confidence handling
    - Add confidence map parsing
    - Implement gaussian blur (sigma: 2.0) for confidence < 0.3
    - Create Metal shader for per-pixel confidence processing
    - _Requirements: 6.5_
  
  - [~] 12.3 Create SyntheticDepthFallback for non-LiDAR devices
    - Integrate Core ML depth estimation model
    - Implement same layer separation logic
    - Add warning indicator in UI
    - Apply same confidence threshold (0.3) for blur
    - _Requirements: 6.7_
  
  - [~] 12.4 Create DepthPeelRenderer for layer composition
    - Implement multi-layer rendering with separate opacity
    - Add 5px horizontal offset per layer
    - Implement layer blending modes
    - Optimize for 60fps performance
    - _Requirements: 6.3, 6.4_
  
  - [ ]* 12.5 Write unit tests for depth layer separation
    - **Property 4: Layer count invariant**
    - **Validates: Requirements 6.2 (Layer configuration)**
    - Test layer count = 4 with default configuration
    - Test confidence-based blur application
    - Test fallback activation on non-LiDAR devices
    - _Requirements: 6.2, 6.5, 6.7_

### Phase 8: Modulation Orbits Menu (Requirement 7)

- [ ] 13. Implement modulation orbit system
  - [~] 13.1 Create ModulationOrbitGesture recognizer
    - Implement circular gesture detection
    - Calculate orbital angle from finger position
    - Implement 10px deadzone at center
    - Support up to 3 simultaneous orbit gestures
    - Add 10-second inactivity timeout
    - Register with GestureStateRegistry
    - _Requirements: 7.1, 7.4, 7.5, 7.7_
  
  - [~] 13.2 Create OrbitManager for parameter binding
    - Implement parameter modulation at 60Hz
    - Add angle → normalized value [0, 1] conversion
    - Implement parameter update callbacks
    - Manage multiple active orbits (max 3)
    - _Requirements: 7.3, 7.5_
  
  - [~] 13.3 Create OrbitVisualizer SwiftUI view
    - Implement 3 orbital ring rendering
    - Add radius constraints (min: 50px, max: 200px)
    - Implement radius clamping at viewport edges (80% threshold)
    - Add visual feedback for active orbits
    - _Requirements: 7.2, 7.6_
  
  - [ ]* 13.4 Write integration tests for orbit gestures
    - Test circular gesture recognition
    - Test multi-orbit support (up to 3)
    - Test parameter update rate (60Hz)
    - Test radius clamping behavior
    - _Requirements: 7.3, 7.5, 7.6_

### Phase 9: Audio Damage Effects (Requirement 8)

- [ ] 14. Implement audio damage system
  - [~] 14.1 Create AudioDamageEngine with AVAudioEngine integration
    - Set up audio input tap for peak detection
    - Implement real-time audio level analysis
    - Calculate normalized damage intensity (0-1.0) from dB levels
    - Add configurable threshold (default: 0dB)
    - Handle audio sample rate changes with 200ms reinitialization
    - _Requirements: 8.1, 8.3, 8.4, 8.5_
  
  - [~] 14.2 Implement damage effect renderers
    - Create RGBSeparationEffect Metal shader (8px max at 80% intensity)
    - Create PixelationEffect Metal shader
    - Create ScanlineJitterEffect Metal shader
    - Add effect intensity scaling based on audio level
    - _Requirements: 8.2, 8.6_
  
  - [~] 14.3 Implement damage fade-out system
    - Create 500ms ease-out animation when audio drops below threshold
    - Implement smooth intensity interpolation
    - Reset effects when fully faded
    - _Requirements: 8.7_
  
  - [ ]* 14.4 Write property tests for audio damage intensity
    - **Property 5: Damage intensity matches audio level**
    - **Validates: Requirements 8.3 (Intensity calculation)**
    - Test normalized intensity = audio peak level
    - Test fade-out timing
    - Test effect activation at threshold
    - _Requirements: 8.3, 8.7_
  
  - [ ]* 14.5 Write error condition tests for audio damage
    - **Property 6: Audio error handling**
    - **Validates: Requirements 8.5 (Sample rate changes)**
    - Test system handles NaN/Infinity audio values gracefully
    - Test sample rate change recovery
    - Test audio engine reinitialization
    - _Requirements: 8.5_

### Phase 10: Terminal-Style Control System (Requirement 9)

- [ ] 15. Implement terminal control components
  - [~] 15.1 Create TerminalSlider SwiftUI component
    - Implement high-precision slider with 1000+ discrete steps
    - Add numeric value overlay with 0.01 precision
    - Support click-to-set, drag, and scroll-wheel interactions
    - Implement modifier key (Command/Ctrl) for 10x precision
    - Add 60Hz maximum update rate throttling
    - _Requirements: 9.1, 9.2, 9.3, 9.4, 9.5_
  
  - [~] 15.2 Create ParameterEditor with confirmation overlay
    - Implement large value change detection (>50% threshold)
    - Show confirmation overlay for significant changes
    - Add undo/redo support
    - _Requirements: 9.6_
  
  - [~] 15.3 Implement preset loading with animation
    - Create 300ms spring animation for value transitions
    - Implement parallel parameter updates
    - Add preset validation before load
    - _Requirements: 9.7_
  
  - [ ]* 15.4 Write property tests for slider precision
    - **Property 7: Slider value round trip**
    - **Validates: Requirements 9.2 (Value precision)**
    - Test set value V → read value → equals V within 0.001 tolerance
    - Test modifier key precision multiplication
    - Test update rate throttling
    - _Requirements: 9.2, 9.3, 9.5_

### Phase 11: Performance Optimization

- [ ] 16. Implement performance monitoring and optimization
  - [~] 16.1 Create FrameRateMonitor for 60fps validation
    - Implement frame time measurement
    - Add frame drop detection (threshold: 2x target frame time)
    - Log performance metrics
    - Add on-screen FPS counter for debugging
    - _Requirements: All (60fps target)_
  
  - [~] 16.2 Optimize Metal rendering pipeline
    - Profile GPU usage with Metal Frame Capture
    - Implement texture atlasing for layer separation
    - Add mipmap generation for downsampled rendering
    - Minimize render target switches
    - Cache pipeline states for reuse
    - _Requirements: 4.2, 6.3, 8.2_
  
  - [~] 16.3 Implement memory management for frame buffers
    - Add memory pressure monitoring
    - Implement automatic frame eviction at 500MB limit
    - Optimize CVPixelBuffer retention
    - Add texture compression where possible
    - _Requirements: 4.3, 5.3_
  
  - [~] 16.4 Implement low power mode adaptation
    - Detect low power mode state
    - Reduce frame buffer size (180 → 90 frames)
    - Reduce texture resolution (max 1024px)
    - Simplify effect complexity
    - _Requirements: All (power optimization)_
  
  - [ ]* 16.5 Write performance tests
    - Test sustained 60fps with all effects active
    - Test memory usage stays under 500MB
    - Test GPU utilization < 80%
    - Test thermal throttling behavior
    - _Requirements: All (performance targets)_

### Phase 12: Accessibility & Polish

- [ ] 17. Implement comprehensive accessibility support
  - [~] 17.1 Add Reduce Motion support across all features
    - Override all animations with instant transitions when enabled
    - Update corner bracket fade (instant appearance)
    - Update boot sequence (skip animations, 1.5s static)
    - Update layout transitions (instant updates)
    - Update fracture return (instant return)
    - _Requirements: 1.6, 3.7_
  
  - [~] 17.2 Implement VoiceOver support
    - Add accessibility labels for all interactive elements
    - Create custom rotor actions for gesture controls
    - Add accessibility hints for complex interactions
    - Test navigation with VoiceOver enabled
    - _Requirements: All (accessibility)_
  
  - [~] 17.3 Add Dynamic Type support
    - Update all text to use preferredFont
    - Test layout at all content size categories
    - Adjust telemetry and control displays for large text
    - _Requirements: 1.2, 9.2_
  
  - [~] 17.4 Implement high contrast mode support
    - Adjust colors for high contrast mode
    - Ensure minimum 4.5:1 contrast ratio
    - Test all UI elements in high contrast
    - _Requirements: All (accessibility)_

- [ ] 18. Implement haptic feedback system
  - [~] 18.1 Add CoreHaptics feedback for gestures
    - Add haptic feedback on fracture activation
    - Add haptic feedback on time scrub activation
    - Add haptic feedback on orbit activation
    - Add haptic feedback on boot sequence completion
    - _Requirements: 4.1, 5.1, 7.1, 3.5_

- [ ] 19. Final integration and polish
  - [~] 19.1 Wire all components into main app
    - Integrate all features into ContentView
    - Connect AppStateContainer to all components
    - Verify gesture conflict resolution
    - Test feature interactions
    - _Requirements: All_
  
  - [~] 19.2 Create app settings interface
    - Add settings for feature enable/disable toggles
    - Add settings for effect parameters
    - Add settings for layout preset management
    - Add settings for accessibility overrides
    - _Requirements: 2.1, 2.6, 6.7, 7.2, 8.4, 9.1_
  
  - [ ]* 19.3 Write end-to-end integration tests
    - Test complete workflows: boot → camera → gestures → settings
    - Test feature combinations
    - Test state persistence and restoration
    - Test error recovery
    - _Requirements: All_

- [~] 20. Final checkpoint - Complete validation
  - Ensure all tests pass, ask the user if questions arise.

## Notes

- Tasks marked with `*` are optional and can be skipped for faster MVP delivery
- Each task explicitly references requirements for full traceability
- Checkpoints ensure incremental validation at major milestones
- Property tests validate universal correctness properties from the design
- Unit tests validate specific implementations and edge cases
- Integration tests validate complete feature workflows
- Performance tests ensure 60fps target is maintained
- All tasks build on previous steps with clear dependencies
- The task list covers all 9 major features from requirements
- Accessibility is integrated throughout, not added as afterthought
- Metal shader implementations are paired with their triggering systems

## Task Dependency Graph

```json
{
  "waves": [
    {
      "id": 0,
      "tasks": ["1.1", "1.2", "1.3"]
    },
    {
      "id": 1,
      "tasks": ["2.1", "2.2", "3.1"]
    },
    {
      "id": 2,
      "tasks": ["2.3", "3.2", "5.1", "6.1"]
    },
    {
      "id": 3,
      "tasks": ["5.2", "6.2", "7.1", "8.1"]
    },
    {
      "id": 4,
      "tasks": ["5.3", "6.3", "7.2", "7.3", "8.2", "8.3", "9.1"]
    },
    {
      "id": 5,
      "tasks": ["7.4", "8.4", "9.2", "9.3", "10.1", "12.1"]
    },
    {
      "id": 6,
      "tasks": ["8.5", "9.4", "10.2", "10.3", "12.2", "12.3", "13.1"]
    },
    {
      "id": 7,
      "tasks": ["9.5", "10.4", "12.4", "13.2", "14.1"]
    },
    {
      "id": 8,
      "tasks": ["10.5", "12.5", "13.3", "14.2", "15.1"]
    },
    {
      "id": 9,
      "tasks": ["13.4", "14.3", "15.2"]
    },
    {
      "id": 10,
      "tasks": ["14.4", "14.5", "15.3", "16.1"]
    },
    {
      "id": 11,
      "tasks": ["15.4", "16.2", "16.3", "16.4"]
    },
    {
      "id": 12,
      "tasks": ["16.5", "17.1", "17.2", "17.3"]
    },
    {
      "id": 13,
      "tasks": ["17.4", "18.1", "19.1"]
    },
    {
      "id": 14,
      "tasks": ["19.2"]
    },
    {
      "id": 15,
      "tasks": ["19.3"]
    }
  ]
}
```
