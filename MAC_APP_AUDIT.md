# GreyVision macOS Capture Audit

**Date:** 2026-08-28 CDT  
**Scope:** `GreyVisionMacCapture/` standalone receiver and preview application

## Audit outcome

The macOS target builds successfully with the current Xcode beta toolchain when code signing is disabled for local validation. The active receiver architecture is coherent: SwiftUI owns presentation, `GVPhoneLink` owns Bonjour/TLS/framing, `GVVideoDecoder` owns VideoToolbox decode, and the shared broadcast models are compiled into the Mac target.

## Findings and changes

| Area | Finding | Change |
|---|---|---|
| Window lifecycle | `WindowGroup` permitted additional windows, conflicting with the product requirement for a standalone single-window app. | Replaced it with `Window("GreyVision Capture", id: "main")`. |
| Source switching | Switching from LINK to CONTINUITY left the network receiver running; switching back did not explicitly stop the camera path. This could keep an unnecessary camera/network pipeline active. | Source changes now stop the inactive pipeline through `receiver.stop()` or `continuity.stop()`. |
| Bonjour selection | The browser connected to the first `_greyvision._tcp` result, even when it did not match the requested service name. | Results are filtered by the entered service name, case-insensitively, before connecting. |
| Session state | Frame count and preview throttle state could carry across reconnects, which made first-frame status and initial preview timing less deterministic. | Frame count resets on start/stop; decoder preview timing resets in `reset()`. |
| Decoder diagnostics | A malformed or unsupported video format could be accepted into UI state without a clear decoder failure message. | The format is configured before publication, and failure reports `Video format is not supported by this Mac.`. |

## Verification

The following command completed with `** BUILD SUCCEEDED **`:

```bash
xcodebuild -project GreyVisionMacCapture.xcodeproj \
  -scheme GreyVisionMacCapture \
  -configuration Debug \
  -derivedDataPath /tmp/GreyVisionMacAuditBuild \
  CODE_SIGNING_ALLOWED=NO build
```

The resulting app artifact was verified at:

```text
/tmp/GreyVisionMacAuditBuild/Build/Products/Debug/GreyVisionMacCapture.app
```

Focused static checks confirmed the single `Window` scene, source-switch stop behavior, Bonjour service matching, and unsupported-format diagnostic are present in the source.

## Remaining validation

A live iPhone-to-Mac session should still be exercised on the user's network after installing the newly built app. The highest-value manual checks are: two simultaneous Bonjour services with a deliberate service-name selection; switching LINK ↔ CONTINUITY while active; reconnecting after a stream interruption; and confirming HEVC plus H.264 fallback behavior. The current local build was unsigned, so installation/signing remains a deployment step rather than part of this validation run.

## External skill search note

The requested external skill search could not run because the referenced helper script was not present at `/home/ubuntu/skills/internet-skill-finder/scripts/fetch_skills.py` in the sandbox. The repository-specific iOS/Swift guidance, clean-code guidance, and mobile design guidance were applied directly.
