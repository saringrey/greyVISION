// Host-only regression check; no app build, simulator, or XCTest runner needed.
// swiftc -swift-version 6 -D TRACKING_BURN_IN_SELF_CHECK -o /tmp/gv-tracking-check \
//   GreyVision/Engine/Vision/Tracking/{GVTrackingModel,GVTrackingFeed,GVTrackingDisplayList,GVVisionDetector}.swift \
//   GreyVision/Engine/Rendering/GVTrackingBurnIn.swift GreyVisionTests/TrackingBurnInSelfCheck.swift
// /tmp/gv-tracking-check [existing.metallib | GreyVision/Resources/Shaders/TrackingShaders.metal]
#if TRACKING_BURN_IN_SELF_CHECK
import CoreGraphics
import Darwin
import Foundation
import Metal

@main
@MainActor
enum TrackingBurnInSelfCheck {
    static let width = 512
    static let height = 512
    static var failures = 0

    static func check(_ passed: Bool, _ message: String) {
        print("\(passed ? "PASS" : "FAIL") \(message)")
        if !passed { failures += 1 }
    }

    static func snapshot(_ mode: GVTrackingMode = .hand, x: CGFloat = 0.65, time: Double = 1) -> GVTrackingSnapshot {
        var parameters = BlobTrackingParameters.defaults
        parameters.mode = mode
        parameters.palette = .mono
        parameters.style = .box
        parameters.labels = .none
        parameters.glow = 0
        parameters.lineWidth = 3
        parameters.prediction = 0
        parameters.showCentroids = false
        let blob = TrackedBlob(
            id: 1, rect: CGRect(x: x - 0.08, y: 0.08, width: 0.16, height: 0.16),
            velocity: .zero, color: SIMD3(1, 0.4, 0.2), area: 0.0256, confidence: 1,
            label: "HAND", age: 1, isCoasting: false, trail: [],
            joints: [CGPoint(x: x - 0.05, y: 0.12), CGPoint(x: x, y: 0.16), CGPoint(x: x + 0.05, y: 0.12)],
            bones: [[0, 1], [1, 2]]
        )
        return GVTrackingSnapshot(parameters: parameters, blobs: [blob], mask: nil,
                                  region: CGRect(x: 0, y: 0, width: 1, height: 1), passRate: 15, timestamp: time)
    }

    static func texture(_ device: MTLDevice, width: Int = width, height: Int = height) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite]
        return try require(device.makeTexture(descriptor: descriptor), "texture")
    }

    static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw NSError(domain: message, code: 1) }
        return value
    }

    // Alternating sorted-looking bands stand in for an already processed stack output.
    static func processed(_ device: MTLDevice) throws -> MTLTexture {
        let frame = try texture(device)
        var pixels = [Float16](repeating: 0, count: width * height * 4)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let offset = (y * width + x) * 4
                pixels[offset] = Float16(x / 32 % 2 == 0 ? 0.08 : 0.25)
                pixels[offset + 1] = Float16(Double(y) / Double(height) * 0.2)
                pixels[offset + 2] = 0.12
                pixels[offset + 3] = 1
            }
        }
        pixels.withUnsafeBytes { frame.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                                              withBytes: $0.baseAddress!, bytesPerRow: width * 8) }
        return frame
    }

    static func readback(_ source: MTLTexture, device: MTLDevice, buffer: MTLCommandBuffer) throws -> MTLTexture {
        let target = try texture(device, width: source.width, height: source.height)
        let encoder = try require(buffer.makeBlitCommandEncoder(), "readback encoder")
        encoder.copy(from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                     sourceSize: MTLSize(width: source.width, height: source.height, depth: 1),
                     to: target, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        encoder.endEncoding()
        return target
    }

    static func pixel(_ texture: MTLTexture, x: CGFloat, y: CGFloat) -> [Float] {
        var values = [Float16](repeating: 0, count: 4)
        values.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: 8,
                             from: MTLRegionMake2D(Int(x * CGFloat(texture.width)), Int(y * CGFloat(texture.height)), 1, 1), mipmapLevel: 0)
        }
        return values.map(Float.init)
    }

    static func finish(_ buffer: MTLCommandBuffer) throws {
        buffer.commit()
        buffer.waitUntilCompleted()
        if let error = buffer.error { throw error }
    }

    static func preservesBands(_ result: MTLTexture, frame: MTLTexture) -> Bool {
        (0 ..< 16).allSatisfy { band in
            let x = (CGFloat(band) + 0.5) / 16
            return pixel(result, x: x, y: 0.75) == pixel(frame, x: x, y: 0.75)
        }
    }

    static func main() throws {
        let device = try require(MTLCreateSystemDefaultDevice(), "Metal unavailable")
        let queue = try require(device.makeCommandQueue(), "queue")
        let path = CommandLine.arguments.dropFirst().first ?? "GreyVision/Resources/Shaders/TrackingShaders.metal"
        let library: MTLLibrary
        if path.hasSuffix(".metallib") {
            library = try device.makeLibrary(URL: URL(fileURLWithPath: path))
        } else {
            library = try device.makeLibrary(source: String(contentsOfFile: path, encoding: .utf8), options: nil)
        }
        let frame = try processed(device)

        // Every mode publishes identical snapshot data, including skeletons.
        let feed = GVTrackingFeed()
        feed.attach(rate: 15) { _ in }
        for mode in GVTrackingMode.allCases {
            let value = snapshot(mode)
            feed.publish(value)
            check(feed.latestSnapshot?.parameters.mode == mode && feed.latestSnapshot?.blobs.first?.joints.count == 3,
                  "\(mode.rawValue) snapshot retains geometry")
            let burn = try require(GVTrackingBurnIn(device: device, library: library), "burn-in pipeline")
            let command = try require(queue.makeCommandBuffer(), "command")
            let output = burn.composite(frame: frame, snapshot: feed.latestSnapshot, commandBuffer: command, now: 1)
            check(output !== frame, "\(mode.rawValue) first captured frame includes a burn-in pass")
            let result = try readback(output, device: device, buffer: command)
            try finish(command)
            check(pixel(result, x: 0.65, y: 0.16)[0] > 0.7, "\(mode.rawValue) joint is visible at top-left coordinates")
            check(pixel(result, x: 0.625, y: 0.14)[0] > 0.5, "\(mode.rawValue) skeleton bone survives compositing")
            check(preservesBands(result, frame: frame), "\(mode.rawValue) preserves all processed bands outside marks")

            // A size change must not stretch the old overlay or wait for the 30 Hz timer.
            let resizedFrame = try texture(device, width: 256, height: 512)
            let resizedCommand = try require(queue.makeCommandBuffer(), "resize command")
            let resized = burn.composite(frame: resizedFrame, snapshot: value, commandBuffer: resizedCommand, now: 1.001)
            check(resized !== resizedFrame, "\(mode.rawValue) resize immediately refreshes overlay geometry")
            let resizedResult = try readback(resized, device: device, buffer: resizedCommand)
            try finish(resizedCommand)
            check(pixel(resizedResult, x: 0.65, y: 0.16)[0] > 0.7, "\(mode.rawValue) resized joint stays in place")
        }
        feed.detach()
        check(feed.latestSnapshot == nil, "detaching clears capture snapshot")

        // A CPU raster must not overwrite an overlay still referenced by an uncommitted GPU frame.
        let burn = try require(GVTrackingBurnIn(device: device, library: library), "burn-in pipeline")
        let warm = try require(queue.makeCommandBuffer(), "warm command")
        _ = burn.composite(frame: frame, snapshot: snapshot(), commandBuffer: warm, now: 1)
        try finish(warm)
        Thread.sleep(forTimeInterval: 0.1)
        let held = try require(queue.makeCommandBuffer(), "held command")
        let heldOutput = burn.composite(frame: frame, snapshot: snapshot(), commandBuffer: held, now: 1.01)
        let heldResult = try readback(heldOutput, device: device, buffer: held)
        for index in 0 ..< 4 {
            let command = try require(queue.makeCommandBuffer(), "update command")
            _ = burn.composite(frame: frame, snapshot: snapshot(x: 0.3, time: Double(index + 2)),
                               commandBuffer: command, now: Double(index + 2))
            try finish(command)
            Thread.sleep(forTimeInterval: 0.05)
        }
        try finish(held)
        check(pixel(heldResult, x: 0.65, y: 0.16)[0] > 0.7, "GPU frame keeps its original hand overlay while later rasters run")
        check(pixel(heldResult, x: 0.3, y: 0.16) == pixel(frame, x: 0.3, y: 0.16), "later hand positions cannot leak into an earlier GPU frame")
        let disabled = try require(queue.makeCommandBuffer(), "disable command")
        check(burn.composite(frame: frame, snapshot: nil, commandBuffer: disabled, now: 8) === frame, "nil snapshot passes processed texture through")
        try finish(disabled)
        let restarted = try require(queue.makeCommandBuffer(), "restart command")
        let restartedOutput = burn.composite(frame: frame, snapshot: snapshot(), commandBuffer: restarted, now: 8.001)
        check(restartedOutput !== frame, "restart immediately restores marks")
        let restartedResult = try readback(restartedOutput, device: device, buffer: restarted)
        try finish(restarted)
        check(pixel(restartedResult, x: 0.65, y: 0.16)[0] > 0.7, "restart does not resurrect the old shifted raster")

        let croppedBurn = try require(GVTrackingBurnIn(device: device, library: library), "crop burn-in")
        let hand = snapshot()
        let cropped = GVTrackingSnapshot(parameters: hand.parameters, blobs: hand.blobs, mask: nil,
                                         region: CGRect(x: 0.2, y: 0.1, width: 0.5, height: 0.5), passRate: 15, timestamp: 1)
        let cropCommand = try require(queue.makeCommandBuffer(), "crop command")
        let cropOutput = croppedBurn.composite(frame: frame, snapshot: cropped, commandBuffer: cropCommand, now: 1)
        let cropResult = try readback(cropOutput, device: device, buffer: cropCommand)
        try finish(cropCommand)
        check(pixel(cropResult, x: 0.2 + 0.65 * 0.5, y: 0.1 + 0.16 * 0.5)[0] > 0.7,
              "hand joints map from analysis crop into full recorded frame")
        check(pixel(cropResult, x: 0.65, y: 0.16) == pixel(frame, x: 0.65, y: 0.16), "crop does not leave marks in uncropped coordinates")

        // Exercise the capped 1920px raster used for 4K output; keep GPU waits outside CPU timing.
        let largeFrame = try texture(device, width: 3840, height: 2160)
        let largeBurn = try require(GVTrackingBurnIn(device: device, library: library), "4K burn-in")
        let largeCommand = try require(queue.makeCommandBuffer(), "4K command")
        let initialStart = ProcessInfo.processInfo.systemUptime
        let largeOutput = largeBurn.composite(frame: largeFrame, snapshot: snapshot(), commandBuffer: largeCommand, now: 1)
        let initialMS = (ProcessInfo.processInfo.systemUptime - initialStart) * 1000
        let largeResult = try readback(largeOutput, device: device, buffer: largeCommand)
        try finish(largeCommand)
        check(pixel(largeResult, x: 0.65, y: 0.16)[0] > 0.7, "hand skeleton survives capped raster at 4K")
        var longestWarmMS = 0.0
        for index in 0 ..< 60 {
            let command = try require(queue.makeCommandBuffer(), "steady command")
            let start = ProcessInfo.processInfo.systemUptime
            _ = largeBurn.composite(frame: largeFrame, snapshot: snapshot(time: Double(index + 2)),
                                    commandBuffer: command, now: Double(index + 2))
            longestWarmMS = max(longestWarmMS, (ProcessInfo.processInfo.systemUptime - start) * 1000)
            try finish(command)
        }
        print(String(format: "4K host CPU encode: cold %.2f ms; max of 60 warm frames %.2f ms (not device FPS)", initialMS, longestWarmMS))
        print("\(failures) failures; production Swift sources, library: \(path)")
        exit(failures == 0 ? 0 : 1)
    }
}
#endif
