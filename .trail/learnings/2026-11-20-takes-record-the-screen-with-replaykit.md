---
title: "Takes record the screen with ReplayKit; boot sequence replaced by the shared Splash.mp4; browser categories are a mini dock"
author: Grey
date: 2026-11-20
branch: codex/cohesive-flagship-effects
scope: repo
status: active
src: agent
touches:
  - GreyVision/Engine/Capture/GVScreenRecorder.swift
  - GreyVision/Engine/Capture/GVCaptureCoordinator.swift
  - GreyVision/Engine/Capture/GVTakeArchive.swift
  - GreyVision/Features/Launch/GVLaunchSplash.swift
  - GreyVision/Features/Launch/GVSplashStage.swift
  - GreyVision/Features/Workspace/GVEffectDashboardSelector.swift
---

## Decided
- Every non-RAW take (camera and AR) is a ReplayKit in-app screen capture (GVScreenRecorder), because the user wants the saved video to show the interface exactly as seen. The render-loop writers only run when RPScreenRecorder.isAvailable is false; ProRes RAW stays native.
- Mid-take the mark sits in the top-right shoulder (GVRecordingHUD and WorkspaceView.topPanel put the timecode left, wordmark right), so the capture carries the watermark top-right. RecordingOverlayRenderer's burned mark moved top-right for the fallback too.
- The boot sequence (Features/Launch/Boot, BootView, GVAccessGate, GVDitheredSplash) is deleted. The launch screen is the same Splash.mp4 as ~/Documents/venicesarin and ~/Documents/NorahX: venicesarin's x-ray with tracked boxes, NorahX's bracket button (+CAMERA).
- The effect browser's chip wall is a three-group mini dock (Library, Effects, Capture) that expands a tray when tapped.

## Tried and ruled out
- Take records pulled off the phone with devicectl all said photosStatus "saved"; the real losses were movies with no JSON record (session killed before filing). GVTakeArchive.recoverUnsavedTakes files those (if under 7 days old) and retries failed exports at launch.
- CALayer.filters do nothing on iOS, so the x-ray is rendered per frame through a CIContext.
- The old family rows used a GeometryReader inside a ScrollView, which is what left the big empty gaps; GVFlowLayout replaces it.

## Watch out
- The ReplayKit capture handler must be explicitly @Sendable, or Swift 6 infers main-actor isolation and traps on the first off-main frame.
- No iOS simulator runtime is installed on this Mac; verify with a signed device build installed through devicectl.
- UI tests that tap boot.codec / boot.resolution, or browser category chips without opening the dock tray first, need updating.
