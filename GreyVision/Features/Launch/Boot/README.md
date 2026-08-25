# Boot Sequence Components

This directory contains both the existing boot sequence implementation and the new spec-compliant components.

## Quick Start

### Using the New Boot Sequence

```swift
import SwiftUI

struct MyBootView: View {
    @StateObject private var sequenceManager = BootSequenceManager()
    @StateObject private var transitionManager = BootTransitionManager()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            // Phase 1: Phosphor Bloom
            if sequenceManager.currentPhase == .phosphorBloom {
                TimelineView(.animation(minimumInterval: 1/60)) { _ in
                    PhosphorBloomEffect(
                        progress: sequenceManager.calculateProgress(
                            duration: sequenceManager.currentPhaseDuration
                        ),
                        isActive: true
                    )
                }
            }
            
            // Phase 2: CRT Scanline
            if sequenceManager.currentPhase == .crtScanline {
                TimelineView(.animation(minimumInterval: 1/60)) { _ in
                    CRTScanlineOverlay(
                        progress: sequenceManager.calculateProgress(
                            duration: sequenceManager.currentPhaseDuration
                        ),
                        isActive: true
                    )
                }
            }
            
            // Phase 3 & 4: Your content here
            if sequenceManager.currentPhase >= .systemStatus {
                YourContent()
                    .bootFadeTransition(
                        opacity: transitionManager.mainInterfaceOpacity
                    )
            }
        }
        .onAppear {
            sequenceManager.start(reduceMotion: reduceMotion)
            
            Task {
                while !sequenceManager.isMainInterfaceVisible {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                transitionManager.beginTransition {
                    print("Boot complete!")
                }
            }
        }
    }
}
```

## Components

### BootSequenceManager (Task 8.1)
**State machine** for 4-phase boot sequence.

- Phosphor bloom: 1200ms
- CRT scanline: 600ms
- System status: 700ms
- Fade-in: 400ms

Features:
- Touch blocking during boot
- `userForceQuickBoot` env variable
- Reduce motion fast path (1500ms)

### PhosphorBloomEffect (Task 8.2)
**Visual effect** for Phase 1 - radial gradient bloom.

- CRT-style purple glow
- Ease-out timing
- Dual-layer depth
- Screen blend mode

### CRTScanlineOverlay (Task 8.3)
**Visual effect** for Phase 2 - scanline reveal.

- Linear timing (600ms)
- Purple-white beam
- Leading edge gradient
- Content reveal effect

### BootTransitionManager (Task 8.4)
**Transition manager** for Phase 4 - main interface fade-in.

- 400ms fade animation
- Haptic feedback
- Completion callback
- State coordination

## Existing Components

### GVBootSequence
Original 7-phase boot sequence (still in use).

### GVStarfieldWake
Star field wake animation.

### GVLogoReconstruction
Logo reconstruction effect.

### GVSyncSweep
CRT synchronization sweep.

## Integration

See `BootSequenceIntegration.swift` for:
- Side-by-side integration pattern
- Complete example view
- Overlay pattern
- Feature flag setup

## Environment Variables

- `userForceQuickBoot` - Skip boot animation, go straight to main interface

## Accessibility

All components support:
- Reduce Motion (static fallbacks)
- VoiceOver
- Dynamic Type (where applicable)

## Performance

Target: 60fps throughout boot sequence

Optimization tips:
- Use `TimelineView` with appropriate intervals
- Minimize state updates
- Use `.allowsHitTesting(false)` on overlays
- Profile with Metal Frame Capture

## Documentation

See `TASK_8_COMPLETION.md` for:
- Detailed implementation notes
- API reference
- Testing checklist
- Integration strategies
- Future enhancements
