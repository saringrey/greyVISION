import CoreVideo
import Foundation
import simd

extension DepthGeometry {
    /// Mirrors gvSensorUV: aspect-fill in oriented view space, then undo orientation.
    static func sensorUV(viewUV: SIMD2<Float>, viewport: SIMD2<Float>, image: SIMD2<Float>, orientation: CapturedFrameOrientation) -> SIMD2<Float>? {
        guard viewUV.x.isFinite, viewUV.y.isFinite, viewport.x.isFinite, viewport.y.isFinite,
              image.x.isFinite, image.y.isFinite, viewport.x > 0, viewport.y > 0, image.x > 0, image.y > 0 else { return nil }
        let portrait = orientation == .portrait || orientation == .portraitUpsideDown
        let sourceAspect = portrait ? image.y / image.x : image.x / image.y
        let viewAspect = viewport.x / viewport.y
        var cropped = simd_clamp(viewUV, .zero, SIMD2(repeating: 1))
        if sourceAspect > viewAspect { cropped.x = (cropped.x - 0.5) * viewAspect / sourceAspect + 0.5 }
        else { cropped.y = (cropped.y - 0.5) * sourceAspect / viewAspect + 0.5 }
        switch orientation {
        case .portrait: return SIMD2(cropped.y, 1 - cropped.x)
        case .portraitUpsideDown: return SIMD2(1 - cropped.y, cropped.x)
        case .landscapeLeft: return cropped
        case .landscapeRight: return SIMD2(repeating: 1) - cropped
        }
    }

    static func worldPoint(pixel: SIMD2<Float>, depthMeters: Float, intrinsics: SIMD4<Float>, worldFromCamera: simd_float4x4) -> SIMD3<Float>? {
        guard let optical = cameraPoint(pixel: pixel, depthMeters: depthMeters, intrinsics: intrinsics) else { return nil }
        let world = worldFromCamera * SIMD4(optical.x, -optical.y, -optical.z, 1)
        guard world.x.isFinite, world.y.isFinite, world.z.isFinite else { return nil }
        return SIMD3(world.x, world.y, world.z)
    }

    /// Nine bounded CPU reads only when acquiring an anchor. Closest valid sample
    /// wins; invalid/low-confidence taps leave the previous anchor intact.
    static func anchor(viewUV: SIMD2<Float>, viewport: SIMD2<Float>, frame: DepthFrame, parameters: DepthEffectParameters) -> SIMD3<Float>? {
        guard let uv = sensorUV(viewUV: viewUV, viewport: viewport,
                                image: SIMD2(Float(frame.imageDimensions.width), Float(frame.imageDimensions.height)), orientation: frame.orientation) else { return nil }
        let map = frame.depthMap
        let width = CVPixelBufferGetWidth(map), height = CVPixelBufferGetHeight(map)
        guard width > 0, height > 0, CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_DepthFloat32 else { return nil }
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let confidence = frame.confidenceMap
        if let confidence { CVPixelBufferLockBaseAddress(confidence, .readOnly) }
        defer { if let confidence { CVPixelBufferUnlockBaseAddress(confidence, .readOnly) } }
        let safe = parameters.sanitized
        let centerX = min(Int(uv.x * Float(width)), width - 1)
        let centerY = min(Int(uv.y * Float(height)), height - 1)
        let scaleX = Float(width) / Float(frame.imageDimensions.width)
        let scaleY = Float(height) / Float(frame.imageDimensions.height)
        let k = frame.intrinsics
        let intrinsics = SIMD4(k.columns.0.x * scaleX, k.columns.1.y * scaleY, k.columns.2.x * scaleX, k.columns.2.y * scaleY)
        let offsets = [(0, 0), (-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, -1), (-1, 1), (1, 1)]
        for (dx, dy) in offsets {
            let x = centerX + dx, y = centerY + dy
            guard x >= 0, x < width, y >= 0, y < height else { continue }
            let depth = base.advanced(by: y * CVPixelBufferGetBytesPerRow(map)).assumingMemoryBound(to: Float.self)[x]
            guard depth.isFinite, depth > Float(safe.nearMeters), depth < Float(safe.farMeters) else { continue }
            if let confidence, let confidenceBase = CVPixelBufferGetBaseAddress(confidence) {
                let cx = min(x * CVPixelBufferGetWidth(confidence) / width, CVPixelBufferGetWidth(confidence) - 1)
                let cy = min(y * CVPixelBufferGetHeight(confidence) / height, CVPixelBufferGetHeight(confidence) - 1)
                let level = confidenceBase.advanced(by: cy * CVPixelBufferGetBytesPerRow(confidence)).assumingMemoryBound(to: UInt8.self)[cx]
                guard Int(level) >= Int(safe.confidenceThreshold.rounded()) else { continue }
            }
            if let result = worldPoint(pixel: SIMD2(Float(x), Float(y)), depthMeters: depth, intrinsics: intrinsics, worldFromCamera: frame.cameraTransform) { return result }
        }
        return nil
    }
}
