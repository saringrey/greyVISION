// Run on Apple Silicon: swiftc GreyVision/Engine/Rendering/GVFrameDatamosh.swift scripts/check-datamosh.swift -o /tmp/check-datamosh
// /tmp/check-datamosh GreyVision/Resources/Shaders/FrameDatamosh.metal [--realtime]
// Readbacks exist only in this acceptance harness, never in the effect.
import Foundation
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@main
struct CheckDatamosh {
    static func main() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("A real Metal device is required")
        }
        let shader = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
        let library = try device.makeLibrary(source: shader, options: nil)
        let realtime = CommandLine.arguments.contains("--realtime")
        let width = realtime ? 1920 : 384, height = realtime ? 1080 : 216
        func texture(_ w: Int, _ h: Int) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
            d.storageMode = .shared
            d.usage = [.shaderRead, .shaderWrite]
            return device.makeTexture(descriptor: d)!
        }
        let source = texture(width, height), replacement = texture(width, height), output = texture(width, height)
        var pattern = [Float16](repeating: 1, count: width * height * 4)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let i = (y * width + x) * 4
                let u = Float(x) / Float(width), v = Float(y) / Float(height)
                pattern[i] = Float16((x / 48 + y / 48) % 2 == 0 ? 0.9 : 0.1)
                pattern[i + 1] = Float16(u)
                pattern[i + 2] = Float16(v)
                if abs(u - 0.5) < 0.1 && abs(v - 0.5) < 0.25 {
                    pattern[i] = 0.1; pattern[i + 1] = 0.9; pattern[i + 2] = 0.3
                }
            }
        }
        pattern.withUnsafeBytes { source.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 8) }
        let replacementPixels = [Float16](repeating: 0.75, count: pattern.count)
        replacementPixels.withUnsafeBytes { replacement.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 8) }
        func read(_ texture: MTLTexture) -> [Float16] {
            let shared = CheckDatamosh.sharedCopy(texture, device: device, queue: queue)
            var result = [Float16](repeating: 0, count: shared.width * shared.height * 4)
            result.withUnsafeMutableBytes { shared.getBytes($0.baseAddress!, bytesPerRow: shared.width * 8, from: MTLRegionMake2D(0, 0, shared.width, shared.height), mipmapLevel: 0) }
            assert(result.allSatisfy { $0.isFinite }, "Non-finite GPU pixels")
            return result
        }
        func difference(_ a: [Float16], _ b: [Float16]) -> Float {
            var sum: Float = 0
            for i in stride(from: 0, to: a.count, by: 16) { sum += abs(Float(a[i]) - Float(b[i])) }
            return sum / Float(a.count / 16)
        }
        let engine = try GVFrameDatamosh(device: device, library: library)
        var transport = GVDatamoshTransport()
        var settings = GVFrameDatamosh.Settings(persistence: 0.998, strength: 0.65)
        var timings: [Double] = []
        func frame(_ input: MTLTexture = source, _ target: MTLTexture = output) {
            let command = queue.makeCommandBuffer()!
            assert(engine.encode(commandBuffer: command, source: input, destination: target,
                                 settings: settings, transport: transport, deltaTime: 1 / 60))
            command.commit(); command.waitUntilCompleted()
            assert(command.status == .completed, "GPU error: \(String(describing: command.error))")
            timings.append((command.gpuEndTime - command.gpuStartTime) * 1000)
        }
        frame()
        transport.send(.hold)
        frame()
        let heldSource = read(engine.sourceReference!)
        let allocations = engine.allocationCount
        var last = read(output)
        let initial = last
        var changes: [Float] = []
        let start = ProcessInfo.processInfo.systemUptime
        for i in 1 ... 1920 {
            frame(replacement) // Incoming camera changes completely while HOLD must ignore it.
            if i % 60 == 0 {
                let now = read(output)
                let change = difference(last, now)
                assert(change > 0.00001, "HOLD stopped evolving at second \(i / 60): \(change)")
                changes.append(change)
                last = now
            }
            if realtime {
                let remaining = start + Double(i) / 60 - ProcessInfo.processInfo.systemUptime
                if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
            }
        }
        assert(read(engine.sourceReference!) == heldSource, "HOLD source changed")
        assert(engine.allocationCount == allocations, "Per-frame textures allocated")
        assert(difference(initial, last) > 0.01, "No accumulated corruption")
        try save(initial, width, height, "diagnostics/datamosh/source.png")
        try save(last, width, height, "diagnostics/datamosh/hold-32s.png")
        transport.send(.freeze)
        frame(replacement)
        let frozen = read(output)
        for _ in 0 ..< 120 { frame(replacement) }
        assert(read(output) == frozen, "FREEZE evolved")
        transport.send(.hold)
        for _ in 0 ..< 60 { frame(replacement) }
        assert(difference(read(output), frozen) > 0.00001, "HOLD did not resume after FREEZE")
        let beforeRelease = read(output)
        transport.send(.release)
        frame(replacement)
        let afterRelease = read(output)
        assert(difference(afterRelease, beforeRelease) < 0.025, "RELEASE snapped")
        assert(difference(afterRelease, replacementPixels) > 0.05, "RELEASE cleared feedback")
        for _ in 0 ..< 180 { frame(replacement) }
        assert(read(engine.sourceReference!).prefix(3) == replacementPixels.prefix(3), "RELEASE did not resume live source")
        transport.send(.reset)
        frame(replacement)
        assert(difference(read(output), replacementPixels) < 0.0001, "RESET failed")
        // Reset takes effect without allocating; block size changes retain the image history.
        assert(engine.allocationCount == allocations)
        for block in [8, 16, 32] {
            settings.blockSize = block
            transport.send(.reset); frame(); transport.send(.hold); frame()
            let reference = read(engine.sourceReference!)
            for _ in 0 ..< 120 { frame(replacement) }
            assert(read(engine.sourceReference!) == reference)
            assert(difference(read(output), pattern) > 0.005, "Block size \(block) does not move")
        }
        let retained = read(engine.sourceReference!)
        let resized = texture(width / 2, height / 2)
        frame(replacement, resized)
        let resizedReference = read(engine.sourceReference!)
        assert(abs(Float(resizedReference[0]) - Float(retained[0])) < 0.01, "Resize lost held source")
        let sorted = timings.sorted()
        print("PASS: 32 seconds HOLD, immutable source, evolving output every second, FREEZE/resume, smooth RELEASE, RESET, 8/16/32 blocks, resize preservation, no steady-state allocations")
        print("GPU \(device.name), \(width)x\(height), median \(sorted[sorted.count / 2]) ms, p95 \(sorted[Int(Double(sorted.count) * 0.95)]) ms; realtime=\(realtime)")
        print("Second-to-second image change min=\(changes.min()!), final=\(changes.last!)")
    }

    static func sharedCopy(_ input: MTLTexture, device: MTLDevice, queue: MTLCommandQueue) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: input.pixelFormat, width: input.width, height: input.height, mipmapped: false)
        descriptor.storageMode = .shared
        let output = device.makeTexture(descriptor: descriptor)!
        let command = queue.makeCommandBuffer()!, blit = command.makeBlitCommandEncoder()!
        blit.copy(from: input, to: output); blit.endEncoding(); command.commit(); command.waitUntilCompleted()
        assert(command.status == .completed)
        return output
    }

    static func save(_ pixels: [Float16], _ width: Int, _ height: Int, _ path: String) throws {
        let bytes = pixels.map { UInt8(min(max(Float($0), 0), 1) * 255) }
        let data = Data(bytes)
        let provider = CGDataProvider(data: data as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        try FileManager.default.createDirectory(atPath: "diagnostics/datamosh", withIntermediateDirectories: true)
        let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        assert(CGImageDestinationFinalize(destination))
    }
}
