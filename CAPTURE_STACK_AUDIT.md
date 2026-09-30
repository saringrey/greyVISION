# GreyVision Capture Stack Audit — Agent 4

**Date:** 2026-08-29
**Auditor:** Agent 4 (Capture + Recording + Reliability + QA)

---

## 1. AVCaptureSession Ownership

**Owner:** `CameraController` (Engine/Capture/CameraController.swift:8)
- Single `AVCaptureSession` instance owned by `CameraController`
- Session lifecycle managed via `start()`, `stop()`, `stopSoon()`
- `CameraRuntime` wraps `CameraController` and exposes `captureSession` property
- Session runs on dedicated `sessionQueue` (userInitiated QoS)

**Lifecycle:**
- `CameraRuntime.start()` → `CameraController.start(configuration:)` → `captureSession.startRunning()`
- `CameraRuntime.stop()` → `CameraController.stop()` → `captureSession.stopRunning()`
- Interruption handling via `AVCaptureSession` notifications (wasInterrupted, interruptionEnded, runtimeError)

---

## 2. AVCaptureDevice Configuration

**Location:** `CameraController.configureDevice()` (lines 539-590)

**Configuration applied:**
- `activeFormat` selected via `CameraDiscovery.format()`
- `videoZoomFactor` = minimum
- Frame rate: clamps requested FPS to format's supported ranges, sets `activeVideoMinFrameDuration` / `activeVideoMaxFrameDuration`
- HDR: `automaticallyAdjustsVideoHDREnabled = false`, `isVideoHDREnabled` per config
- Focus: `.continuousAutoFocus` if supported
- Exposure: `.continuousAutoExposure` if supported
- White balance: `.locked` for ProRes RAW, else `.continuousAutoWhiteBalance`
- Low light boost: `automaticallyEnablesLowLightBoostWhenAvailable = true`

**Manual controls exposed (via CameraRuntime):**
- Zoom (clamped to device range)
- Exposure bias (clamped)
- ISO + shutter (custom exposure mode, clamped to format range)
- White balance Kelvin (clamped to device gains range)
- Torch (level clamped to 0.65)
- Focus lock / lens position (locked mode)
- White balance lock

---

## 3. Active Pixel Formats

**Video Data Output (preview/processing path):**
- `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange` (preferred)
- Falls back to `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`
- Configured in `CameraController.configure()` lines 448-455
- `automaticallyConfiguresOutputBufferDimensions = false`
- `deliversPreviewSizedOutputBuffers = true` only for ProRes RAW

**Recording path (processed frames):**
- `kCVPixelFormatType_32BGRA` (8-bit) via `GVVideoRecorder` pixel buffer adaptor
- `kCVPixelFormatType_64RGBAHalf` (16-bit float) for ProRes in `GVRealtimeRecordingSession`

---

## 4. AVCaptureVideoDataOutput Path

**Pipeline:**
```
AVCaptureSession → AVCaptureVideoDataOutput (outputQueue) 
  → CameraController.captureOutput() delegate 
  → CapturedFrame { sampleBuffer, presentationTime, dimensions, orientation, isMirrored }
  → LatestCapturedFrameMailbox.publish()
  → CameraMetalSurface.draw() consumes via frameHandler
```

**Key characteristics:**
- `alwaysDiscardsLateVideoFrames = true` (line 37 CameraController.swift)
- Sample buffer delegate on dedicated `outputQueue` (userInteractive QoS)
- YUV → linear conversion in Metal shader (`gvCameraYUVToLinear`)

---

## 5. Photo Capture Path

**Two paths exist:**

**A. Window screenshot (CameraRuntime.takeScreenshot() line 139):**
- Captures entire window including SwiftUI chrome via `UIGraphicsImageRenderer`
- `drawHierarchy(in:afterScreenUpdates: true)` required for Metal layer
- Saved via `GVScreenCapture.save()` → PNG → Photos
- **This is NOT the processed camera frame** — it's the composed UI

**B. Processed still (not fully implemented):**
- `CameraScreenshotMailbox` in CameraMetalSurface requests single-frame capture
- Renderer blits `drawable.texture` to pixel buffer (lines 1275-1298)
- Not yet wired to high-resolution still capture

**Gap:** No high-resolution processed still capture that runs effect stack at full sensor resolution.

---

## 6. Audio Capture Path

**Pipeline:**
```
AVCaptureAudioDataOutput (outputQueue)
  → CameraController.captureOutput() 
  → audioHandler (set by CameraRuntime line 187)
  → CameraRuntime.recordingMailbox.appendAudio(sampleBuffer)
  → CameraRecordingMailbox.appendAudio() 
  → GVRealtimeRecordingSession.appendAudio() (writerQueue)
```

**Audio settings (GVRealtimeRecordingSession line 138-143):**
- Format: AAC (`kAudioFormatMPEG4AAC`)
- Channels: 2
- Sample rate: 44100 Hz
- Bitrate: 128 kbps
- Timestamp rewriting: capture PTS → session-relative PTS (lines 261-292)

---

## 7. Existing Supported Codecs

**From `CaptureSetupDraft.VideoCodec` (CaptureTypes.swift:193-237):**

| Codec | AVVideoCodecType | iOS Requirement |
|-------|------------------|-----------------|
| h264 | `.h264` | All |
| hevc | `.hevc` | All |
| hevcWithAlpha | `.hevcWithAlpha` | All |
| proRes422Proxy | `.proRes422Proxy` | All |
| proRes422LT | `.proRes422LT` | All |
| proRes422 | `.proRes422` | All |
| proRes422HQ | `.proRes422HQ` | All |
| proRes4444 | `.proRes4444` | All |
| proRes4444XQ | `ap4x` | iOS 18+ |
| proResRAW | `.proResRAW` | iOS 26+ |
| proResRAWHQ | `.proResRAWHQ` | iOS 26+ |
| jpegXL | `jxlc` | iOS 18+ |

**Availability checked at runtime:**
- `videoOutput.availableVideoCodecTypesForAssetWriter(writingTo: .mov)` for processed frames
- `movieOutput.availableVideoCodecTypes` for ProRes RAW

---

## 8. ProRes Handling

**Processed frames (GVRealtimeRecordingSession):**
- Lines 105-114: Sets color properties for high-precision ProRes:
  - Primaries: `AVVideoColorPrimaries_ITU_R_709_2`
  - Transfer: `AVVideoTransferFunction_Linear`
  - Matrix: `AVVideoYCbCrMatrix_ITU_R_709_2`
- Pixel format: `kCVPixelFormatType_64RGBAHalf` (16-bit float RGBA)
- Metal-compatible, IOSurface-backed

**ProRes RAW (sensor path):**
- Uses `AVCaptureMovieFileOutput` directly (CameraController lines 61-96)
- Bypasses Metal effect graph entirely — sensor data written directly
- RAW sensels unrotated; orientation stored in QuickTime track matrix
- Preview runs as 4:2:2 proxy via normal video output

---

## 9. HDR Handling

**Capture:** `device.isVideoHDREnabled = configuration.prefersHDR && format.isVideoHDRSupported` (line 571)

**Recording:**
- Processed frame path: No explicit HDR metadata in `GVVideoRecorder` or `GVRealtimeRecordingSession`
- ProRes path: Linear transfer function set (which is HDR-compatible)
- **Gap:** No HDR metadata (CLLI, MDCV) written for processed recordings

---

## 10. LOG Handling

**Status:** Not implemented for recording path.
- Camera capture may receive LOG-encoded frames from sensor
- Metal renderer works in linear space
- No LOG curve encoding in recording writers
- No LUT baking option for processed recordings

---

## 11. AVAssetWriter Usage

**Two implementations:**

**A. GVVideoRecorder (GVCaptureWriter.swift:80-292):**
- Used by `GVProcessedFramesAdapter` for processed frames
- Single video track, no audio (audio handled by ARRecordingSession path)
- `startWriting()` / `startSession(atSourceTime: .zero)`
- `finishWriting()` with Photos save completion

**B. GVRealtimeRecordingSession (ARRecordingSession.swift:50-362):**
- Used by both CameraMetalSurface (processed frames) and ARObjectRuntime
- Video + optional audio tracks
- Dedicated `writerQueue` (userInitiated)
- `WriterBox` / `MediaBox` for Sendable boundary crossing
- Backpressure: `pendingBuffers < 4` limit

---

## 12. AVAssetWriterInput Configuration

**Common:**
- `expectsMediaDataInRealTime = true`
- Added to writer after `canAdd()` check

**Video input settings (GVVideoRecorder):**
```swift
[AVVideoCodecKey: codec,
 AVVideoWidthKey: evenWidth,
 AVVideoHeightKey: evenHeight]
```

**Video input settings (GVRealtimeRecordingSession):**
- Same + color properties for ProRes (lines 110-114)

**Audio input settings (GVRealtimeRecordingSession):**
- AAC, stereo, 44.1kHz, 128kbps

---

## 13. AVAssetWriterInputPixelBufferAdaptor

**GVVideoRecorder (GVCaptureWriter.swift:142-150):**
```swift
sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey: evenWidth,
    kCVPixelBufferHeightKey: evenHeight,
    kCVPixelBufferMetalCompatibilityKey: true
]
```

**GVRealtimeRecordingSession (ARRecordingSession.swift:121-130):**
```swift
sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey: pixelFormat (32BGRA or 64RGBAHalf),
    kCVPixelBufferWidthKey: width,
    kCVPixelBufferHeightKey: height,
    kCVPixelBufferMetalCompatibilityKey: true,
    kCVPixelBufferIOSurfacePropertiesKey: [:]
]
```

---

## 14. CVPixelBufferPools

**Both recorders use the adaptor's built-in pool:**
- `adaptor.pixelBufferPool` (GVCaptureWriter.swift:195, ARRecordingSession.swift:175)
- `CVPixelBufferPoolCreatePixelBuffer()` for allocation
- **No preallocation** — buffers created on-demand
- **No exhaustion monitoring** — returns nil if pool fails

**Pool sizing:** Default (unconfigured). AVFoundation manages internally.

---

## 15. Preview Output Source

**CameraMetalSurface.draw() (lines 1226-1250):**
- Final rendered texture: `presentedTexture` (result of full effect stack)
- Render pass to `MTKView.currentDrawable.texture`
- Preview pipeline: `previewPipeline` with `CameraPreviewUniforms`
- Scanline overlay applied in preview fragment shader
- **This IS the final processed output** — includes all effects

---

## 16. Recording Output Source

**CameraMetalSurface.draw() (lines 1300-1317):**
```swift
if let session = recordingSession, recordingMailbox.isActive() {
    if let lease = makeRecordLease(recording: session, texture: presentedTexture) {
        // Compute blit: presentedTexture → lease.texture (backed by recorder's pixel buffer)
        encoder.setComputePipelineState(historyTapPipeline)
        encoder.setTexture(presentedTexture, index: 0)
        encoder.setTexture(lease.texture, index: 1)
        dispatch(encoder, pipeline: historyTapPipeline, texture: lease.texture)
        recordLease = lease
    }
}
```

**Completion handler (lines 1346-1364):**
```swift
commandBuffer.addCompletedHandler { buffer in
    guard let pixelBuffer = retainedRecordLease?.pixelBuffer else { return }
    retainedRecordLease?.session.append(pixelBuffer, timestamp: recordTimestamp)
}
```

**✅ CRITICAL: Records `presentedTexture` = FINAL PROCESSED OUTPUT**
- This is the correct path: preview and recording share the same final texture
- Datamosh freeze / feedback / warp / repeat will be recorded correctly

---

## 17. Orientation Handling

**Capture side (CameraController lines 403-421):**
- `videoOutput.connection.videoRotationAngle` set per interface orientation
- `movieOutput.connection.videoRotationAngle` for RAW
- Mapping (lines 417-428):
  - `.portrait` → 90°
  - `.portraitUpsideDown` → 270°
  - `.landscapeLeft` → 180°
  - `.landscapeRight` → 0°
- Front camera: `connection.isVideoMirrored = true` (line 501)

**Recording side:**
- `GVVideoRecorder`: No explicit orientation — relies on pixel buffer content being pre-rotated
- `GVRealtimeRecordingSession`: No orientation metadata written
- **Risk:** If preview rotation differs from recording path, saved file may have wrong orientation

**Front camera mirroring:**
- Preview: Mirrored via `connection.isVideoMirrored = true`
- Recording: Uses same `presentedTexture` so mirroring is baked in
- **Intentional** — front camera preview matches recording

---

## 18. Timestamp Handling

**GVVideoRecorder (GVCaptureWriter.swift:179, 231):**
- `frameDuration = CMTime(value: 1, timescale: framesPerSecond)`
- `presentation = frameDuration * frameIndex`
- **Fixed frame rate** — no variable frame timing

**GVRealtimeRecordingSession (ARRecordingSession.swift:200-213):**
- `startTime` = first frame's `ProcessInfo.processInfo.systemUptime`
- `presentationTime = CMTime(seconds: timestamp - baseTime, preferredTimescale: 600)`
- **Variable frame timing** — uses actual frame timestamps

**Audio (ARRecordingSession.swift:261-292):**
- Rewrites CMSampleBuffer PTS to session-relative time
- `CMSampleBufferCreateCopyWithNewTiming`

---

## 19. Dropped-Frame Logic

**GVVideoRecorder:**
- `nextTexture()` returns nil if `input?.isReadyForMoreMediaData != true` (line 196)
- `append()` checks same condition (line 230)
- **No frame counting / metrics exposed**

**GVRealtimeRecordingSession:**
- `nextPixelBuffer()` returns nil if `pendingBuffers >= 4` (line 174)
- `append()` checks `isReadyForMoreMediaData` on writer queue (line 228)
- **Silent drops** — no metrics, no callbacks

---

## 20. Storage Error Handling

**GVVideoRecorder.finish() (lines 253-270):**
- Checks `writer.status == .completed` and `wroteFrames > 0`
- On failure: deletes temp file, publishes `.failed` state
- On success: `GVPhotoLibrary.saveVideo()` → completion

**GVRealtimeRecordingSession.finish() (lines 295-322):**
- Same pattern: checks status, deletes on failure
- `saveToPhotoLibrary()` handles authorization

**Photos authorization:** Requested at save time (not proactively)

---

## 21. Photos Export

**GVPhotoLibrary (GVCaptureWriter.swift:295-350):**
- `saveImage()` / `saveVideo()` both request `.addOnly` authorization
- `PHAssetCreationRequest` with file URL or PNG data
- Completion callback with `Bool` success

**GVRealtimeRecordingSession (ARRecordingSession.swift:325-348):**
- Duplicate implementation of Photos save logic
- **Code duplication** identified in CODE_AUDIT.md §9.2

---

## 22. External Storage Behavior

**Status:** Not implemented.
- All recordings go to `FileManager.default.temporaryDirectory`
- Then moved to Photos library
- No support for external drives, Files app, or custom URLs

---

## CRITICAL FINDINGS

### ✅ CORRECT: Final Rendered Output Recording
The recording path in `CameraMetalSurface` captures `presentedTexture` — the **final post-effect output**. This means:
- Datamosh freeze: source freezes, mosh continues animating → **recorded correctly**
- Feedback: recursive frames → **recorded correctly**
- Warp/repeat: temporal effects → **recorded correctly**
- Preview and recording are visually identical

### ❌ GAPS REQUIRING ACTION

| Area | Gap | Priority |
|------|-----|----------|
| **Performance Metadata** | No session/sidecar recording of effect graph, parameters, gestures, seeds | HIGH |
| **Deterministic Seeds** | No seed capture/storage for procedural effects | HIGH |
| **Recording State Machine** | Exists in `GVRecordingTransaction` but split across coordinator/renderer | MEDIUM |
| **Backpressure Metrics** | No dropped frame counters exposed | MEDIUM |
| **Orientation Metadata** | No orientation written to processed recordings | MEDIUM |
| **HDR/LOG Metadata** | No HDR metadata (CLLI/MDCV) or LOG curve tags | MEDIUM |
| **High-Res Still Capture** | No processed still at sensor resolution | MEDIUM |
| **Audio Sync Verification** | No long-take A/V drift test | MEDIUM |
| **Thermal Monitoring** | No thermal state exposure to recording | LOW |
| **External Storage** | Not implemented | LOW |
| **Session Recovery** | No crash recovery for in-progress recordings | MEDIUM |
| **Photos Save Consolidation** | Duplicate code in 3 places | LOW |

---

## ARCHITECTURE SUMMARY

```
┌─────────────────────────────────────────────────────────────────┐
│                     CAPTURE PIPELINE                            │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  AVCaptureDevice                                                │
│       │                                                         │
│       ▼                                                         │
│  AVCaptureSession (CameraController)                            │
│       │                                                         │
│       ├──────────────────┬──────────────────┐                  │
│       ▼                  ▼                  ▼                  │
│  VideoOutput         AudioOutput       MovieOutput             │
│  (YUV 420)           (PCM)            (ProRes RAW only)       │
│       │                  │                  │                  │
│       ▼                  ▼                  ▼                  │
│  CameraController    recordingMailbox   NativeMovieRecording   │
│  .captureOutput()    .appendAudio()     Delegate               │
│       │                  │                  │                  │
│       ▼                  ▼                  ▼                  │
│  CapturedFrame ──────▶ CameraMetalSurface ◀── Recording        │
│  (YUV + timing)          │              Mailbox                 │
│                          ▼                                    │
│              ┌────────────────────────┐                       │
│              │   METAL EFFECT GRAPH   │                       │
│              │  (CameraMetalSurface)  │                       │
│              │                        │                       │
│              │ YUV→Linear → Effects → │                       │
│              │ RGB Split → Composite  │                       │
│              └───────────┬────────────┘                       │
│                          ▼                                    │
│                 presentedTexture                              │
│                    │       │                                  │
│                    ▼       ▼                                  │
│             ┌─────────┐ ┌─────────┐                           │
│             │ Preview │ │Recording│                           │
│             │ (MTKView)│ │(PixelBuf)│                          │
│             └────┬────┘ └────┬────┘                           │
│                  │          │                                 │
│                  ▼          ▼                                 │
│           Screen/UI    GVRealtimeRecordingSession             │
│           (screenshot)  (AVAssetWriter + PixelBufferPool)     │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## RECOMMENDED IMMEDIATE ACTIONS

### Milestone 1: Core Recording Reliability (Week 1)
1. **Consolidate recording state machine** — Single source of truth in `GVRecordingTransaction`
2. **Add dropped-frame metrics** — Expose rendered/encoded/dropped counts
3. **Fix orientation metadata** — Write orientation to QuickTime track for processed recordings
4. **Add pre-recording storage check** — Warn before large format recordings
5. **Consolidate Photos save logic** — Single `MediaLibrary` service

### Milestone 2: Performance Metadata Foundation (Week 2)
1. **Define `PerformanceEvent` schema** — Codable, versioned, timestamped
2. **Implement `PerformanceRecorder`** — Sidecar file (.gvperf JSON) alongside video
3. **Capture:** effect graph, parameters, gestures, seeds, camera settings
4. **Timebase:** `sessionTime` (monotonic) + `frameIndex` + `presentationTime`

### Milestone 3: Advanced Capture Features (Week 3+)
1. **High-res processed still capture** — Render effect stack at sensor resolution
2. **ProRes LOG/HDR metadata** — Write proper color tags
3. **Dual recording prototype** — Sensor original + processed (where performance allows)
4. **Long-run test harness** — Automated 5/10/20 min recordings with validation

### Milestone 4: Reliability Hardening (Ongoing)
1. **Interruption recovery** — Camera session resume, recording salvage
2. **Memory pressure handling** — Trim caches, protect active recording
3. **Thermal state integration** — Quality reduction hooks for Agent 1
4. **Automated regression tests** — Datamosh freeze, stutter, long-file validation

---

## INTEGRATION POINTS FOR OTHER AGENTS

### From Agent 1 (Rendering Core) — NEED:
- `finalRenderedTexture` (already available as `presentedTexture`)
- Output resolution / pixel format
- Render timestamps (frame index, GPU completion time)
- Engine lifecycle callbacks (start/stop/frame)
- Texture format for encoder compatibility
- Render state serialization hooks (for performance metadata)

### From Agent 2 (Creative Effects) — NEED:
- Deterministic seed per effect instance
- Effect reset semantics (temporal state clear on source change)
- Effect identifiers (stable strings for metadata)
- Parameter change notifications

### To Agent 3 (UI/Interaction) — PROVIDE:
- `RecordingState` (idle/preparing/recording/finalizing/failed/saved)
- `recordingDuration` / `recordingStartedAt`
- `CaptureCapabilities` (lenses, FPS, codecs, formats per device)
- Manual camera setters (zoom, exposure, focus, WB, ISO, shutter)
- `PerformanceEventSink` for gesture/modulation recording
- `lockableSettings` (codec/resolution disabled during recording)
- Error/warning stream (disk full, thermal, encoder failure)

---

## FILES IN CAPTURE STACK

| File | Lines | Role |
|------|-------|------|
| `CameraController.swift` | 839 | AVFoundation session, device config, RAW recording |
| `CameraRuntime.swift` | 517 | Main-actor wrapper, permissions, manual controls |
| `CameraDiscovery.swift` | ~400 | Device/format enumeration |
| `CaptureTypes.swift` | 245 | Data types, codecs, capabilities |
| `GVCaptureCoordinator.swift` | 696 | Recording transaction, adapters, state machine |
| `GVCaptureWriter.swift` | 358 | `GVVideoRecorder`, `GVPhotoLibrary`, pixel buffer pool |
| `CameraMetalSurface.swift` | 2579 | Metal renderer, effect graph, recording blit |
| `ARRecordingSession.swift` | 363 | `GVRealtimeRecordingSession` (shared recorder) |
| `CameraSurfaceView.swift` | ~300 | MTKView wrapper, touch handling |

---

## VERIFICATION CHECKLIST FOR MILESTONE 1

- [ ] Launch camera, enable animated effect (datamosh/feedback)
- [ ] Record 10 seconds
- [ ] Stop, play file
- [ ] ✅ Confirm processed output present (not raw camera)
- [ ] ✅ Confirm orientation correct
- [ ] ✅ Confirm audio sync (if enabled)
- [ ] ✅ Confirm no corruption
- [ ] ✅ Repeat start/stop 10× without failure
- [ ] **Datamosh freeze test:** Source freeze + mosh animating → verify recorded
- [ ] **Stutter test:** Repeat/microloop → verify recorded frames repeat
- [ ] **Long file test:** 5+ min → verify moov atom, playable

---

*End of Audit*