# Composition Controls Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Put composition actions beside the effect stack and simplify settings.
**Architecture:** Add the Composition surface to the existing dock, reuse the existing stack strip, and pass workspace action closures through the dock. Keep capture and app settings in the existing settings console.
**Tech Stack:** SwiftUI, iOS 18+, existing EffectEditingSession.
**Spec:** docs/superpowers/specs/2026-11-03-composition-controls-design.md

## Global Constraints
- Preserve existing action handlers, history, source behavior, locks, recording collapse, accessibility identifiers, and Reduce Motion.
- No rendering or history-model redesign is included.

## Review Focus
- Empty stack and Clear leave Undo and Recipes reachable.
- Collapsed adjustment area can be reopened without selecting an effect.
- Slot focus and operations work without parameter selection.
- Global controls remain distinct from slot operations.
- Advanced remains accessible on small screens and honors developer gating.

### Task 1: Composition surface
- [x] Add global actions and Recipes to the dock above the existing stack strip.
- [x] Remove duplicate stack presentation from the effect parameter tools.
- [x] Keep adjustment visibility and action identifiers coherent.

### Task 2: Settings consolidation
- [x] Remove composition controls from settings.
- [x] Group Timer, Audio, Mac Camera, and Render under Capture; Lock, Intro, Help, and Advanced under App.
- [x] Preserve existing handlers, values, and developer gating.

### Task 3: Verification
- [x] Parse edited Swift and typecheck the changed UI against production dependencies where available.
- [x] Run focused lint, review the diff, and review empty-stack/lock/focus behavior.
- [x] Report the existing missing Metal toolchain/simulator limitation if it still prevents runtime verification.

## Verification record

- Edited Swift sources parse, and `git diff --check` passes.
- The final generic iOS Simulator integration build exited 0 with `EXCLUDED_SOURCE_FILE_NAMES=*.metal`; this checks the integrated Swift/UI code without requiring the missing Metal toolchain. Existing compiler warnings remain.
- Focused SwiftLint completed with pre-existing brace/statement/ternary warnings outside changed lines.
- Independent read-only review found no actionable defects. Empty-stack history/Recipes reachability, Adjust reopening, locks, recording collapse, slot focus, and LiDAR Clear behavior were checked in code.
- Runtime/screenshot verification is unavailable: no configured simulator devices and the installed Xcode lacks its Metal toolchain.

## Implementation rulings

- Composition stays available whenever the existing adjustment area is open, including a fresh/cleared session, so Recipes and history do not depend on selection.
- Preserve Clear's existing disable-all and LiDAR-exit behavior rather than deleting retained slots or redesigning history.
- Keep the existing Mac Camera toggle/long press and add an explicit Pair Mac row.
