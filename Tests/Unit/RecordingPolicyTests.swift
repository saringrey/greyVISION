@testable import GreyVision
import AVFoundation
import CoreVideo
import Metal
import XCTest

/// Every take carries the effect stack and the HUD. RAW is the one codec that
/// cannot — it records the sensor around the effect graph — so it can never
/// be the selected codec, whatever a recipe or an old draft asks for.
final class RecordingPolicyTests: XCTestCase {
    func testRecordedColorUsesTheViewfinderTransfer() {
        XCTAssertEqual(GVRealtimeRecordingSession.colorProperties[AVVideoTransferFunctionKey], AVVideoTransferFunction_IEC_sRGB)
        XCTAssertEqual(GVRealtimeRecordingSession.colorProperties[AVVideoColorPrimariesKey], AVVideoColorPrimaries_ITU_R_709_2)
        XCTAssertEqual(GVRealtimeRecordingSession.colorProperties[AVVideoYCbCrMatrixKey], AVVideoYCbCrMatrix_ITU_R_709_2)
    }

    func testRecordingResolveMatchesHardwareSRGBForBothBufferFormats() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let library = try device.makeDefaultLibrary(bundle: Bundle(for: AppModel.self))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let resolve = try device.makeComputePipelineState(function: XCTUnwrap(library.makeFunction(name: "gvCameraRecordResolve")))
        func texture(_ format: MTLPixelFormat) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: 32, height: 1, mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
            return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        }
        let source = try texture(.rgba16Float)
        let reference = try texture(.bgra8Unorm_srgb)
        var ramp = (0 ..< 32).flatMap { index -> [Float16] in
            let value = Float(index) / 31
            return [Float16(value), Float16(value * 0.5), Float16(value * 0.25), 1]
        }
        source.replace(region: MTLRegionMake2D(0, 0, 32, 1), mipmapLevel: 0, withBytes: &ramp, bytesPerRow: 32 * 8)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "gvCameraPreviewVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "gvCameraStillFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let buffer = try XCTUnwrap(queue.makeCommandBuffer())
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = reference
        pass.colorAttachments[0].storeAction = .store
        let renderer = try XCTUnwrap(buffer.makeRenderCommandEncoder(descriptor: pass))
        renderer.setRenderPipelineState(pipeline)
        renderer.setFragmentTexture(source, index: 0)
        renderer.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        renderer.endEncoding()
        let outputs = try [texture(.bgra8Unorm), texture(.rgba16Float)]
        for output in outputs {
            let encoder = try XCTUnwrap(buffer.makeComputeCommandEncoder())
            encoder.setComputePipelineState(resolve)
            encoder.setTexture(source, index: 0)
            encoder.setTexture(output, index: 1)
            encoder.dispatchThreads(MTLSize(width: 32, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
            encoder.endEncoding()
        }
        buffer.commit()
        buffer.waitUntilCompleted()
        XCTAssertNil(buffer.error)
        var expected = [UInt8](repeating: 0, count: 128)
        reference.getBytes(&expected, bytesPerRow: 128, from: MTLRegionMake2D(0, 0, 32, 1), mipmapLevel: 0)
        var bytes = [UInt8](repeating: 0, count: 128)
        outputs[0].getBytes(&bytes, bytesPerRow: 128, from: MTLRegionMake2D(0, 0, 32, 1), mipmapLevel: 0)
        for index in bytes.indices { XCTAssertEqual(Double(bytes[index]), Double(expected[index]), accuracy: 1) }
        var halves = [Float16](repeating: 0, count: 128)
        outputs[1].getBytes(&halves, bytesPerRow: 256, from: MTLRegionMake2D(0, 0, 32, 1), mipmapLevel: 0)
        for x in 0 ..< 32 {
            for (rgba, bgra) in [2, 1, 0, 3].enumerated() {
                XCTAssertEqual(Double(halves[x * 4 + rgba]), Double(expected[x * 4 + bgra]) / 255, accuracy: 0.006)
            }
        }
    }

    @MainActor
    func testProResBrandingPreservesHalfFloatPixelsOutsideTheHUD() throws {
        var optional: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 512, 512, kCVPixelFormatType_64RGBAHalf, nil, &optional), kCVReturnSuccess)
        let buffer = try XCTUnwrap(optional)
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
        let row = CVPixelBufferGetBytesPerRow(buffer)
        let components = base.bindMemory(to: Float16.self, capacity: row * 512 / 2)
        for y in 0 ..< 512 { for x in 0 ..< 512 {
            let index = y * row / 2 + x * 4
            components[index] = 0.25; components[index + 1] = 0.5
            components[index + 2] = 0.75; components[index + 3] = 1
        } }
        let before = Data(bytes: base, count: row * 512)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        RecordingOverlayRenderer().composite(into: buffer, timestamp: 1)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let center = 256 * row / 2 + 256 * 4
        XCTAssertEqual(Array(UnsafeBufferPointer(start: components + center, count: 4)), [0.25, 0.5, 0.75, 1])
        XCTAssertNotEqual(Data(bytes: base, count: row * 512), before, "The HUD must be drawn")
        XCTAssertTrue(UnsafeBufferPointer(start: components, count: row * 512 / 2).allSatisfy { $0.isFinite })
    }

    func testEncodedMoviesPreserveMidtonesAndDeclareSRGB() async throws {
        for codec in [AVVideoCodecType.h264, .hevc, .proRes422HQ, AVVideoCodecType(rawValue: "ap4x")] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("color-\(UUID().uuidString).mov")
            defer { try? FileManager.default.removeItem(at: url) }
            let session = GVRealtimeRecordingSession(outputURL: url, size: CGSize(width: 512, height: 512), saveToPhotos: false, codec: codec)
            XCTAssertTrue(session.start(), codec.rawValue)
            for frame in 0 ..< 6 {
                if let buffer = session.nextPixelBuffer() {
                    CVPixelBufferLockBaseAddress(buffer, [])
                    let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
                    let row = CVPixelBufferGetBytesPerRow(buffer)
                    if session.pixelFormat == kCVPixelFormatType_64RGBAHalf {
                        let values = base.bindMemory(to: Float16.self, capacity: row * 512 / 2)
                        for y in 0 ..< 512 { for x in 0 ..< 512 {
                            let index = y * row / 2 + x * 4
                            values[index] = Float16(118.0 / 255); values[index + 1] = values[index]
                            values[index + 2] = values[index]; values[index + 3] = 1
                        } }
                    } else {
                        base.assumingMemoryBound(to: UInt32.self).initialize(repeating: 0xFF767676, count: row * 512 / 4)
                    }
                    CVPixelBufferUnlockBaseAddress(buffer, [])
                    session.append(buffer, timestamp: 1000 + Double(frame) / 30)
                }
                try await Task.sleep(for: .milliseconds(34))
            }
            let saved = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                session.finish { continuation.resume(with: $0) }
            }
            XCTAssertGreaterThan(session.encodedFrameCount, 0)
            let asset = AVURLAsset(url: saved)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let track = try XCTUnwrap(tracks.first)
            let formats = try await track.load(.formatDescriptions)
            let format = try XCTUnwrap(formats.first)
            XCTAssertEqual(CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String,
                           kCVImageBufferTransferFunction_sRGB as String)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
            reader.add(output)
            XCTAssertTrue(reader.startReading())
            let sample = try XCTUnwrap(output.copyNextSampleBuffer())
            let image = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
            CVPixelBufferLockBaseAddress(image, .readOnly)
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(image)).assumingMemoryBound(to: UInt8.self)
            let center = 256 * CVPixelBufferGetBytesPerRow(image) + 256 * 4
            for channel in 0 ..< 3 { XCTAssertEqual(Double(base[center + channel]), 118, accuracy: 6, codec.rawValue) }
            CVPixelBufferUnlockBaseAddress(image, .readOnly)
            reader.cancelReading()
        }
    }

    func testRAWCodecsAreNeverSelectableAndLandOnTheBestProcessedCodec() {
        XCTAssertFalse(CaptureSetupDraft.VideoCodec.curated.contains(where: \.isProResRAW))
        var setup = CaptureSetupDraft()
        setup.videoCodec = .proResRAWHQ
        XCTAssertEqual(setup.videoCodec, .proRes4444XQ)
        setup.videoCodec = .proResRAW
        XCTAssertEqual(setup.videoCodec, .proRes4444XQ)
        setup.videoCodec = .hevc
        XCTAssertEqual(setup.videoCodec, .hevc)
    }
}
