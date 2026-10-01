import CoreMedia
import CoreVideo
import Foundation
import Metal
import VideoToolbox

/// Real datamoshing: a live H.264 round trip whose reference chain is
/// deliberately broken.
///
/// Everything else in this app is a shader — it computes an artefact. This is
/// not a shader. Frames are pushed through a hardware H.264 encoder, the
/// resulting access units are fed to a decoder, and the *decoder's own
/// reconstruction* is what ends up on screen. Every artefact the operator sees
/// — the block grid, the mosquito noise around moving edges, the chroma
/// bleeding, the way a dragged macroblock keeps its neighbour's colours — is
/// produced by the codec, because it is the codec.
///
/// Three things make it mosh rather than merely lossy, and all three are real
/// encoder/decoder behaviours rather than approximations of them:
///
///   - `keyframeIntervalFrames`   never force a sync sample and the encoder
///         keeps predicting from material the decoder has long since lost.
///         Force one every frame and the picture repairs itself. This is the
///         I-frame-deletion edit datamoshing was built from, done live.
///   - `referenceDropEvery`   an access unit is withheld from the *decoder*
///         while the encoder is left alone. The encoder therefore predicts
///         from frame N-1, the decoder from frame N-2, and the motion vectors
///         of one are applied to the pixels of the other. That mismatch is
///         the drag: real motion compensation against a stale reference.
///   - `recycle`   the encoder's input is its own previous output. Corruption
///         compounds through the codec instead of being re-derived from the
///         clean camera, which is the recursive re-encode that gives a mosh
///         its melting-into-mush tail.
///
/// `bitrateBitsPerSecond` starves the rate controller, which is the crudest
/// and most reliable way to make a real encoder make bad decisions: coarser
/// quantisation, larger skipped blocks, and 4:2:0 chroma smeared across whole
/// macroblocks.
///
/// Threading: locked rather than actor-isolated, because frames are handed in
/// from a Metal command-buffer completion handler, which cannot await, and
/// VideoToolbox calls back on its own threads. Encoding and decoding run on a
/// private serial queue so the render thread never waits on a codec.
final class GVDatamoshEngine: @unchecked Sendable {
    /// One frame's worth of codec intent. Every field maps onto something the
    /// hardware actually does; none of it is interpolated by a shader.
    struct Configuration: Equatable, Sendable {
        /// Long edge in pixels of the *encode*. Below the source resolution
        /// the fixed 16x16 macroblock grid becomes coarse relative to the
        /// image, which is what turns a mosh into the flowing, oversized
        /// `liquid` variant. Zero encodes at source size.
        var encodeLongEdge = 0
        var bitrateBitsPerSecond = 320_000
        /// Frames between forced sync samples. 1 is "repair": every frame
        /// decodes on its own. Large is "never": the drift accumulates.
        var keyframeIntervalFrames = 240
        /// Withhold one access unit in N from the decoder. 0 never withholds.
        var referenceDropEvery = 0
        /// How much of the encoder's input is its own previous output.
        var recycle: Float = 0
        /// Which codec produces the artefacts.
        ///
        /// H.264 in Baseline is the instrument datamoshing was invented on:
        /// 16x16 macroblocks, CAVLC, no B-frames, so the reference chain is
        /// exactly the I/P sequence the technique assumes. HEVC brings 8x8 CTUs
        /// and a far stronger loop filter — finer grain, and block edges that
        /// dissolve into mush instead of staying crisp. Both are real codecs
        /// doing real work; they are different artefacts. A device that refuses
        /// one gets the other rather than nothing (see `Statistics.codec`).
        var codec: Codec = .h264
    }

    enum Codec: String, Equatable, Sendable {
        case h264
        case hevc

        var cmCodecType: CMVideoCodecType {
            switch self {
            case .h264: kCMVideoCodecType_H264
            case .hevc: kCMVideoCodecType_HEVC
            }
        }

        /// Baseline for H.264 is not a compatibility concession, it is the
        /// aesthetic: no B-frames means the frame order on the wire is the
        /// reference order, and CAVLC leaves block edges hard where CABAC and
        /// the deblocking filter of a modern profile would have smoothed away
        /// the very artefacts this effect exists to show.
        var profileLevel: CFString {
            switch self {
            case .h264: kVTProfileLevel_H264_Baseline_3_1
            case .hevc: kVTProfileLevel_HEVC_Main_AutoLevel
            }
        }
    }

    /// The three codec-driven instruments, named for the effects that play them.
    enum Variant: Sendable {
        case datamosh
        case liquidMosh
        case heavyMosh
    }

    /// Maps an effect's three sliders onto codec intent. Every value here is
    /// something an encoder or a decoder actually acts on; none of it is a
    /// shader constant in disguise.
    ///
    /// Lives on the engine rather than on the renderer so that what the sliders
    /// mean is testable without a camera, a Metal device or a view hierarchy.
    static func configuration(variant: Variant,
                              primary: Double,
                              secondary: Double,
                              tertiary: Double,
                              maximumEncodeEdge: Int = 0) -> Configuration {
        func unit(_ value: Double) -> Double { min(max(value, 0), 1) }
        func ramp(_ value: Double, _ low: Double, _ high: Double) -> Double {
            low + (high - low) * unit(value)
        }
        /// A withheld reference is the difference between a lossy encode and a
        /// datamosh, so the bottom of the slider must not silently mean "off"
        /// across half its travel: an effect freshly added at its default
        /// position has to be corrupting something. Below a hair of travel it
        /// stays off — that is the control letting the operator compare the
        /// codec against the same encode with its references intact — and from
        /// there it withholds one access unit in two to eight.
        func drop(_ value: Double) -> Int {
            unit(value) < 0.04 ? 0 : Int(ramp(value, 2, 8).rounded())
        }
        /// The governor's ceiling, applied only where the effect asks to encode
        /// large: an effect already encoding at 48px on a side for the sake of
        /// oversized macroblocks must not be told it is too cheap to deserve the
        /// budget.
        func edge(_ requested: Int) -> Int {
            maximumEncodeEdge > 0 ? min(requested, maximumEncodeEdge) : requested
        }
        var configuration = Configuration()
        switch variant {
        case .datamosh:
            // Bounded rather than full capture resolution, because the frame is
            // copied CPU-side into the encoder's buffer on the simulator. At 960
            // on a long edge the macroblock grid is still 60 x 34 blocks — fine
            // enough that the artefacts read as a real codec rather than as a
            // mosaic, while the copy stays a rounding error next to the encode.
            configuration.encodeLongEdge = edge(960)
            // GOP: at the bottom, a sync sample every couple of frames — an
            // encoder that keeps repairing itself, so the picture stays clean
            // and the mosh has to be earned. At the top, a reference chain that
            // is never refreshed and drifts until something breaks.
            configuration.keyframeIntervalFrames = Int(ramp(primary, 2, 600).rounded())
            configuration.referenceDropEvery = drop(secondary)
            // BITS: what the encoder may spend. Starving a real codec is the
            // crudest way to make it make bad decisions, and the most reliable.
            configuration.bitrateBitsPerSecond = Int(ramp(tertiary, 40_000, 3_000_000).rounded())
        case .liquidMosh:
            // SCALE: the encode's long edge, which the engine quantises to
            // macroblock multiples. Coarse is the entire point — a fixed 16x16
            // macroblock covering a third of the frame is where the liquid look
            // lives, and no shader interpolation buys it instead.
            configuration.encodeLongEdge = Int(ramp(primary, 336, 48).rounded())
            configuration.referenceDropEvery = drop(secondary)
            configuration.bitrateBitsPerSecond = Int(ramp(tertiary, 12_000, 400_000).rounded())
            configuration.keyframeIntervalFrames = 240
        case .heavyMosh:
            // RECYCLE: how much of the encoder's input is its own previous
            // output. This is the cascade; at one, corruption is never again
            // re-derived from the camera but compounds through the codec, which
            // is what turns a few bad frames into soup.
            configuration.recycle = Float(unit(primary))
            configuration.encodeLongEdge = edge(960)
            configuration.keyframeIntervalFrames = Int(ramp(secondary, 60, 900).rounded())
            configuration.bitrateBitsPerSecond = Int(ramp(tertiary, 25_000, 900_000).rounded())
            configuration.referenceDropEvery = 4
            // The cascade is the one instrument that wants HEVC: an 8x8 CTU grid
            // compounds into grain rather than into posterising 16x16 plates,
            // and HEVC's loop filter smears recycled chroma between blocks in a
            // way H.264 simply does not.
            configuration.codec = .hevc
        }
        return configuration
    }

    /// Encoder input for one frame: the Metal texture a kernel writes and the
    /// index of the image buffer the codec will read. The two are the same
    /// format and size; the copy between them happens on the codec queue, after
    /// the GPU has finished with the texture.
    struct StagingFrame: @unchecked Sendable {
        let index: Int
        let texture: MTLTexture
    }

    /// A decoded frame plus the CoreVideo import that keeps its Metal view
    /// valid. Handed to the renderer by value: whoever holds it holds the
    /// import, so a texture cannot be invalidated while an encoder is using it.
    struct DecodedFrame: @unchecked Sendable {
        let texture: MTLTexture
        let generation: UInt64
        /// Retained CoreVideo import. The Metal texture is only valid while
        /// this lives, so whoever displays the frame also holds the import.
        let imported: CVMetalTexture
    }

    /// What the codec actually got up to, counted by the codec rather than
    /// estimated by a shader.
    ///
    /// This exists because "is the round trip really running, and is it really
    /// losing references" is otherwise unfalsifiable from outside — the picture
    /// either looks broken or it does not. Withheld units above zero is the
    /// difference between a datamosh and an expensive video call, and it is the
    /// first thing to look at when a mode goes quiet.
    struct Statistics: Equatable, Sendable {
        var framesSubmitted = 0
        var syncSamples = 0
        var unitsDelivered = 0
        var unitsWithheld = 0
        var unitsBeforeFirstSync = 0
        var framesDecoded = 0
        var decodeFailures = 0
        var decoderRebuilds = 0
        /// The codec the hardware actually agreed to run, which after a refusal
        /// is not necessarily the one that was asked for.
        var codec: Codec?
        var decodeLongEdge = 0
    }

    private let device: MTLDevice
    private let lock = NSLock()
    private let codecQueue = DispatchQueue(label: "greyvision.datamosh.codec", qos: .userInteractive)

    private var encoder: VTCompressionSession?
    private var decoder: VTDecompressionSession?
    private var encoderWidth = 0
    private var encoderHeight = 0
    private var encoderBitrate = 0
    private var encoderKeyframeInterval = 0
    private var encoderDropEvery = -1
    private var pendingKeyframe = true

    private var stagingBuffers: [CVPixelBuffer] = []
    private var stagingTextures: [MTLTexture] = []
    /// CoreVideo imports backing the zero-copy staging ring. The Metal textures
    /// the kernels write are only valid while these live, so the ring holds them
    /// for as long as it holds the image buffers they were made from.
    private var stagingImports: [CVMetalTexture] = []
    /// True when a kernel's write lands in the encoder's own image buffer
    /// because they are the same memory. False means one CPU copy stands between
    /// the GPU and the codec (see `pump`).
    private var stagingIsShared = false
    private var stagingClaimedAt: [UInt64] = []
    private var stagingSize = CGSize.zero
    /// Reusable read-back row buffer for the GPU→codec hand-off. Touched only on
    /// the codec queue, so one buffer serves every slot.
    private var stagingScratch: [UInt8] = []

    private var textureCache: CVMetalTextureCache?
    private var decoded: DecodedFrame?
    private var decodeGeneration: UInt64 = 0
    private var frameCounter: UInt64 = 0
    private var consecutiveDecodeFailures = 0
    private var reportedEncodeFailure = false
    private var reportedDecodeFailure = false
    private var stats = Statistics()
    /// Whether a codec-driven mode is on screen right now. Tracked so that
    /// hardware can be handed back rather than idled.
    private var codecActive = true
    /// The codec the live encoder session was created for.
    private var encoderCodec: Codec?
    /// The format the live decoder was built from, so a mid-stream change of
    /// size or codec rebuilds it instead of feeding it a stream it cannot read.
    private var decoderFormat: CMFormatDescription?
    /// True once the decoder has been given a sync sample it can stand on.
    private var decoderHasSyncSample = false
    private var loggedStatisticsAt = 0

    init?(device: MTLDevice) {
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache
        else { return nil }
        self.device = device
        textureCache = cache
    }

    /// The newest reconstruction the decoder produced, or nil until one exists.
    var latestDecodedFrame: DecodedFrame? {
        lock.withLock { decoded }
    }

    /// Sessions are torn down here, synchronously, rather than left to ARC.
    ///
    /// Finalising a compression session flushes whatever frames are still queued
    /// and calls back through the refcon it was handed at creation. If this object
    /// has already been freed by the time that happens — which is exactly what
    /// happens when the last strong reference drops and VideoToolbox invalidates
    /// asynchronously — that pointer dangles and the callback dies inside
    /// `objc_retain`. Invalidating here means the flush runs while there is still
    /// something on the other end of the pointer to receive it.
    ///
    /// `CVMetalTextureCache` has no `invalidate()`. Eviction is forced with
    /// `CVMetalTextureCacheFlush`, whose second argument is a `CVOptionFlags`
    /// in this SDK rather than a command buffer.
    deinit {
        if let encoder { VTCompressionSessionInvalidate(encoder) }
        if let decoder { VTDecompressionSessionInvalidate(decoder) }
        if let textureCache { CVMetalTextureCacheFlush(textureCache, 0) }
    }

    /// Drops the picture the operator is looking at and forces a fresh sync
    /// sample, so the next frame decodes entirely from itself. This is the
    /// repair half of the technique: without it a mosh could only ever get
    /// worse.
    func requestKeyframe() {
        lock.withLock { pendingKeyframe = true }
    }

    // MARK: - Frame pump

    /// Reserves an encoder-input slot sized for this frame's encode. Returns
    /// nil when every slot in the ring is still in flight, in which case the
    /// caller skips the round trip: the reference chain simply does not
    /// advance, which deepens the mosh rather than breaking it.
    func beginFrame(configuration: Configuration, sourceSize: CGSize) -> StagingFrame? {
        let encodeSize = configuredEncodeSize(configuration: configuration, sourceSize: sourceSize)
        lock.lock()
        defer { lock.unlock() }
        guard encodeSize.width > 0, stagingRingReady(size: encodeSize) else { return nil }
        // A slot is reusable two frames after it was written, which is how
        // long a hardware encoder takes to consume one image. The window is a
        // guarantee that the codec can never read a frame the kernel has
        // already overwritten, and the age limit means a frame VideoToolbox
        // swallows without output cannot hold a slot forever.
        for index in stagingBuffers.indices {
            let claimed = stagingClaimedAt[index]
            if claimed != 0, frameCounter > claimed, frameCounter - claimed >= 2 {
                stagingClaimedAt[index] = 0
            }
            if stagingClaimedAt[index] == 0 {
                stagingClaimedAt[index] = max(frameCounter, 1)
                return StagingFrame(index: index, texture: stagingTextures[index])
            }
        }
        return nil
    }

    /// Hands a written staging frame to the encoder. Safe to call from a
    /// command-buffer completion handler; nothing here waits.
    func endFrame(_ frame: StagingFrame, configuration: Configuration) {
        lock.lock()
        // Nothing is watching the reconstruction, so the round trip does not
        // run: the encoder and the decoder are hardware someone else may want,
        // and the slot goes straight back into the ring.
        guard codecActive else {
            if stagingClaimedAt.indices.contains(frame.index) { stagingClaimedAt[frame.index] = 0 }
            lock.unlock()
            return
        }
        let slot = stagingBuffers.indices.contains(frame.index)
            ? (stagingBuffers[frame.index], stagingTextures[frame.index])
            : nil
        let shared = stagingIsShared
        let counter = frameCounter
        frameCounter &+= 1
        var forceKeyframe = pendingKeyframe
        pendingKeyframe = false
        if !forceKeyframe,
           counter % UInt64(max(1, configuration.keyframeIntervalFrames)) == 0 {
            forceKeyframe = true
        }
        // Asking for a different codec mid-stream is not a property change. The
        // session was created for one family, the parameter sets it emits
        // describe that family, and the decoder was built from them — so the
        // stream is restarted rather than retuned: a new session, opened with a
        // sync sample the decoder can stand on.
        var retiring: VTCompressionSession?
        if let live = encoder, encoderCodec != configuration.codec {
            retiring = live
            encoder = nil
            encoderCodec = nil
            encoderBitrate = 0
            encoderKeyframeInterval = 0
            encoderDropEvery = -1
            decoder = nil
            decoderFormat = nil
            decoderHasSyncSample = false
            forceKeyframe = true
        }
        stats.framesSubmitted += 1
        if forceKeyframe { stats.syncSamples += 1 }
        logStatisticsLocked()
        let encoder = self.encoder
        activeConfiguration = configuration
        lock.unlock()
        if let retiring {
            // Captured strongly for the same reason as in `stagingRingReady`:
            // invalidating flushes queued frames, and the flush calls back
            // through a pointer into this object.
            codecQueue.async { [self] in
                VTCompressionSessionInvalidate(retiring)
                _ = self
            }
        }
        guard let (pixelBuffer, texture) = slot else { return }
        codecQueue.async { [weak self] in
            self?.pump(texture: texture,
                       into: pixelBuffer,
                       configuration: configuration,
                       frame: counter,
                       forceKeyframe: forceKeyframe,
                       session: encoder,
                       sharedSurface: shared)
        }
    }

    /// The codec's own tally. `unitsWithheld` above zero while a mode is on
    /// screen is the proof that the reference chain is really being broken
    /// rather than merely described.
    var statistics: Statistics {
        lock.withLock {
            var snapshot = stats
            snapshot.codec = encoderCodec ?? snapshot.codec
            return snapshot
        }
    }

    /// Logs a compact tally every hundred-odd frames. Must be called with the
    /// lock held; it only ever reads counters another method has just moved.
    private func logStatisticsLocked() {
        stats.codec = encoderCodec ?? stats.codec
        guard stats.framesSubmitted - loggedStatisticsAt >= 120 else { return }
        loggedStatisticsAt = stats.framesSubmitted
        // A local copy, not the property: an os-log interpolation is a closure
        // literal, and reading instance state through one while holding the lock
        // that guards it is exactly the kind of thing that reads as safe and
        // is not.
        let tally = stats
        GVLog.rendering.info("datamosh codec \(tally.codec?.rawValue ?? "none", privacy: .public) submitted \(tally.framesSubmitted) sync \(tally.syncSamples) delivered \(tally.unitsDelivered) withheld \(tally.unitsWithheld) decoded \(tally.framesDecoded) failures \(tally.decodeFailures) rebuilds \(tally.decoderRebuilds)")
    }

    /// GPU to codec.
    ///
    /// There are two ways across this gap and the engine takes whichever one the
    /// platform offers. Where the staging texture was imported from the
    /// encoder's own image buffer (`sharedSurface`), the kernel's write already
    /// landed in the memory the encoder is about to read, so this function only
    /// has to hand the buffer over. Where it was not, there is exactly one copy
    /// and no surface is shared.
    ///
    /// The shared path is the one a shipped video pipeline uses, and the
    /// unshared one exists because of a single platform: in the simulator's
    /// Metal driver, `newTextureWithDescriptor:iosurface:plane:` does not return
    /// an error, it takes the process down asserting inside its XPC layer. An
    /// effect that only survives on one of the two platforms this app builds for
    /// is not worth the copy it avoids — and at the sizes a mosh encodes, between
    /// 48 and a few hundred pixels on a side, the copy is well under a tenth of a
    /// millisecond against a codec round trip that costs milliseconds anyway.
    private func pump(texture: MTLTexture,
                      into pixelBuffer: CVPixelBuffer,
                      configuration: Configuration,
                      frame: UInt64,
                      forceKeyframe: Bool,
                      session: VTCompressionSession?,
                      sharedSurface: Bool) {
        if sharedSurface {
            encode(pixelBuffer: pixelBuffer,
                   configuration: configuration,
                   frame: frame,
                   forceKeyframe: forceKeyframe,
                   session: session)
            return
        }
        guard copy(texture: texture, into: pixelBuffer) else { return }
        encode(pixelBuffer: pixelBuffer,
               configuration: configuration,
               frame: frame,
               forceKeyframe: forceKeyframe,
               session: session)
    }

    /// Reads a frame back out of the texture the kernel wrote and into the image
    /// buffer the encoder is about to read. Both sides are BGRA, so a matching
    /// row pitch makes it one memcpy; a padded destination falls back to copying
    /// row by row rather than smearing the image diagonally.
    private func copy(texture: MTLTexture, into pixelBuffer: CVPixelBuffer) -> Bool {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard texture.width == width, texture.height == height else { return false }
        let rowBytes = width * 4
        guard stagingScratch.count >= rowBytes * height else { return false }
        texture.getBytes(&stagingScratch,
                         bytesPerRow: rowBytes,
                         from: MTLRegionMake2D(0, 0, width, height),
                         mipmapLevel: 0)
        guard CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess,
              let base = CVPixelBufferGetBaseAddress(pixelBuffer)
        else {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            return false
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let destinationRowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        stagingScratch.withUnsafeBufferPointer { source in
            guard let start = source.baseAddress else { return }
            if destinationRowBytes == rowBytes {
                memcpy(base, start, rowBytes * height)
            } else {
                for row in 0 ..< height {
                    memcpy(base + row * destinationRowBytes, start + row * rowBytes, rowBytes)
                }
            }
        }
        return true
    }

    /// Tear both sessions down. Called when the effect leaves the stack so the
    /// hardware is handed back rather than idling on a stream nobody reads.
    func stop() {
        lock.lock()
        let encoder = self.encoder
        let decoder = self.decoder
        self.encoder = nil
        self.decoder = nil
        encoderCodec = nil
        decoderFormat = nil
        decoderHasSyncSample = false
        lock.unlock()
        if let encoder { VTCompressionSessionInvalidate(encoder) }
        if let decoder { VTDecompressionSessionInvalidate(decoder) }
    }

    /// Reports whether a codec-driven mode is on screen right now. Call once per
    /// rendered frame.
    ///
    /// An encoder and a decoder are hardware, and hardware is shared: a recording
    /// wants the same block this effect is holding while nobody is looking at it.
    /// Leaving the stack hands it back, and coming back warms the chain up with a
    /// sync sample so the first frame after the return is a reconstruction rather
    /// than a guess at one.
    func setCodecActive(_ active: Bool) {
        let changed = lock.withLock { () -> Bool in
            let changed = codecActive != active
            codecActive = active
            if !active {
                decoded = nil
                decoderFormat = nil
                decoderHasSyncSample = false
            }
            return changed
        }
        guard changed else { return }
        if active {
            requestKeyframe()
        } else {
            // Not here: invalidating flushes queued frames, and a flush that
            // calls back through a pointer into this object must not be racing
            // the render thread that just stopped looking at it.
            codecQueue.async { [self] in
                stop()
                _ = self
            }
        }
    }

    // MARK: - Encode

    private func encode(pixelBuffer: CVPixelBuffer,
                        configuration: Configuration,
                        frame: UInt64,
                        forceKeyframe: Bool,
                        session: VTCompressionSession?) {
        guard let session = session ?? ensureEncoder(configuration: configuration) else {
            if !reportedEncodeFailure {
                reportedEncodeFailure = true
                GVLog.rendering.error("datamosh: no VideoToolbox encoder available")
            }
            return
        }
        apply(configuration: configuration, to: session)
        var frameProperties: [CFString: Any] = [kCMSampleAttachmentKey_DependsOnOthers: true]
        if forceKeyframe {
            frameProperties[kCMSampleAttachmentKey_NotSync] = false
        }
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: CMTime(value: CMTimeValue(frame), timescale: 30),
            duration: .invalid,
            frameProperties: frameProperties as CFDictionary,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
        if status != noErr, !reportedEncodeFailure {
            reportedEncodeFailure = true
            GVLog.rendering.error("datamosh encode status \(status)")
        }
    }

    /// VideoToolbox calls the encode callback on its own thread with one
    /// encoded access unit. This is where the mosh is actually authored: the
    /// unit is either delivered to the decoder or withheld from it.

    private func deliver(sampleBuffer: CMSampleBuffer) {
        lock.lock()
        // Units still sitting in the encoder when the mode left the screen are
        // discarded rather than reconstructed: nobody is reading the published
        // frame any more, and a reconstruction arriving after the sessions were
        // handed back is a frame from a scene nobody asked about.
        guard codecActive else {
            stats.unitsWithheld += 1
            lock.unlock()
            return
        }
        let configuration = activeConfiguration
        let syncSample = isSyncSample(sampleBuffer)
        let drop = shouldWithhold(sampleBuffer: sampleBuffer, configuration: configuration)
        // A decoder with nothing to stand on cannot be fed. Inter-predicted
        // units that arrive ahead of the first sync sample of a stream are
        // counted and discarded: they produce decode errors, and those errors
        // get blamed on the drift this effect is built from rather than on the
        // ordering they are actually about.
        let beforeSync = !syncSample && !decoderHasSyncSample
        if syncSample { decoderHasSyncSample = true }
        let session = decoder
        if drop { stats.unitsWithheld += 1 }
        else if beforeSync { stats.unitsBeforeFirstSync += 1 }
        else { stats.unitsDelivered += 1 }
        lock.unlock()
        codecQueue.async { [weak self] in
            guard let self else { return }
            // When withheld: the encoder still predicted from this frame and
            // the decoder never received it. That divergence is the effect.
            if drop || beforeSync { return }
            self.decode(sampleBuffer: sampleBuffer,
                        session: session ?? self.ensureDecoder(for: sampleBuffer))
        }
    }

    /// Whether the unit can be decoded on its own — the codec's own word for a
    /// sync sample, an IDR in H.264 and an IRAP in HEVC. A unit that arrives
    /// without attachment information is treated as stand-alone: guessing the
    /// other way would silently starve the decoder forever.
    private func isSyncSample(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first
        else { return true }
        let notSync = (first[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false
        return !notSync
    }

    /// Only ever withholds inter-predicted units. Dropping a sync sample would
    /// leave the decoder with nothing at all, which is a black frame rather
    /// than a mosh.
    private func shouldWithhold(sampleBuffer: CMSampleBuffer, configuration: Configuration) -> Bool {
        guard configuration.referenceDropEvery > 1 else { return false }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]] else {
            return false
        }
        for attachment in attachments {
            let depends = (attachment[kCMSampleAttachmentKey_DependsOnOthers] as? Bool) ?? true
            let notSync = (attachment[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false
            if !notSync, !depends { return false }
        }
        return frameCounter % UInt64(configuration.referenceDropEvery)
            == UInt64(configuration.referenceDropEvery - 1)
    }

    // MARK: - Decode

    private func decode(sampleBuffer: CMSampleBuffer, session: VTDecompressionSession?) {
        guard let session else {
            if !reportedDecodeFailure {
                reportedDecodeFailure = true
                GVLog.rendering.error("datamosh: no VideoToolbox decoder available")
            }
            return
        }
        // No asynchronous flag: the reconstruction arrives before this returns,
        // on this queue, so the renderer always finds the newest frame already
        // published rather than half-written.
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [],
            infoFlagsOut: nil
        ) { [weak self] status, _, imageBuffer, _, _ in
            guard let self else { return }
            guard status == noErr, let imageBuffer else {
                self.noteDecodeFailure(status)
                return
            }
            self.consecutiveDecodeFailures = 0
            self.publish(pixelBuffer: imageBuffer)
        }
        if status != noErr {
            noteDecodeFailure(status)
        }
    }

    /// A chain that has drifted too far for the decoder to follow is repaired
    /// rather than abandoned: a sync sample rebuilds it and the mosh begins
    /// gathering corruption again from there. Tolerance is deliberately high —
    /// a broken reference chain is supposed to look like trouble.
    private func noteDecodeFailure(_ status: OSStatus) {
        consecutiveDecodeFailures += 1
        lock.withLock { stats.decodeFailures += 1 }
        if consecutiveDecodeFailures > 12 {
            consecutiveDecodeFailures = 0
            requestKeyframe()
        }
        if !reportedDecodeFailure {
            reportedDecodeFailure = true
            GVLog.rendering.error("datamosh decode status \(status)")
        }
    }

    // MARK: - Sessions

    /// The configuration the next encode callback must be read against.
    private var activeConfiguration = Configuration()

    /// Creates or refreshes the decoder from the format the encoder actually
    /// produced, so the parameter sets always agree with the stream.
    ///
    /// A change of size or of codec family mid-stream arrives as a new format
    /// description on the next unit, and rebuilding there is what lets a dragged
    /// SCALE slider recover. Holding on to the previous session would leave a
    /// decoder reading a stream it has no parameter sets for, which looks like a
    /// dead effect rather than like a mosh.
    private func ensureDecoder(for sampleBuffer: CMSampleBuffer) -> VTDecompressionSession? {
        lock.lock()
        defer { lock.unlock() }
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return decoder }
        if let decoder, let decoderFormat,
           CMFormatDescriptionEqual(format, otherFormatDescription: decoderFormat) {
            return decoder
        }
        let retiring = decoder
        decoder = nil
        decoderFormat = nil
        decoderHasSyncSample = false
        if let retiring {
            stats.decoderRebuilds += 1
            codecQueue.async { VTDecompressionSessionInvalidate(retiring) }
        }
        let destinationAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        var session: VTDecompressionSession?
        // No output-callback record: frames are decoded with an output handler
        // below, which keeps the reconstructed image on the codec queue where
        // it belongs rather than on a VideoToolbox thread with a raw pointer.
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: nil,
            imageBufferAttributes: destinationAttributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session
        )
        guard status == noErr, let session else {
            GVLog.rendering.error("datamosh decoder create failed: \(status)")
            return nil
        }
        decoder = session
        decoderFormat = format
        return session
    }

    /// Pushes the frame's intent onto the encoder. Rate control, the sync
    /// interval and the profile are all live properties: changing them between
    /// frames is how the operator steers the corruption while it runs.
    private func apply(configuration: Configuration, to session: VTCompressionSession) {
        lock.lock()
        let changed = encoderBitrate != configuration.bitrateBitsPerSecond
            || encoderKeyframeInterval != configuration.keyframeIntervalFrames
            || encoderDropEvery != configuration.referenceDropEvery
        encoderBitrate = configuration.bitrateBitsPerSecond
        encoderKeyframeInterval = configuration.keyframeIntervalFrames
        encoderDropEvery = configuration.referenceDropEvery
        lock.unlock()
        guard changed else { return }
        let interval = max(1, configuration.keyframeIntervalFrames)
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_AverageBitRate: configuration.bitrateBitsPerSecond,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: interval,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: Double(interval) / 30.0,
            kVTCompressionPropertyKey_AllowTemporalCompression: true,
            kVTCompressionPropertyKey_ExpectedFrameRate: 30
        ]
        let status = VTSessionSetProperties(session, propertyDictionary: properties as CFDictionary)
        if status != noErr {
            GVLog.rendering.error("datamosh encoder properties status \(status)")
        }
    }

    /// Imports the reconstruction into Metal and publishes it. The renderer
    /// picks it up on the next frame, one codec round trip behind the camera.
    private func publish(pixelBuffer: CVImageBuffer) {
        guard let cache = textureCache else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var image: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &image
        )
        guard status == kCVReturnSuccess, let image,
              let texture = CVMetalTextureGetTexture(image)
        else { return }
        decodeGeneration &+= 1
        let frame = DecodedFrame(texture: texture, generation: decodeGeneration, imported: image)
        lock.withLock {
            decoded = frame
            stats.framesDecoded += 1
            stats.decodeLongEdge = max(width, height)
        }
    }

    // MARK: - Encoder session

    /// Builds an encoder for the codec family the effect asked for.
    ///
    /// HEVC is asked for and sometimes refused — a device without an HEVC
    /// encoder, or one whose hardware encoder is already committed to a recording
    /// — so the request degrades to H.264 rather than to nothing. What actually
    /// got built is recorded in `encoderCodec`, both so the next frame stops
    /// asking for a codec that was already refused and so the telemetry can say
    /// which family is on screen.
    private func ensureEncoder(configuration: Configuration) -> VTCompressionSession? {
        lock.lock()
        defer { lock.unlock() }
        if let encoder, encoderCodec == configuration.codec { return encoder }
        let retiring = encoder
        encoder = nil
        encoderCodec = nil
        if let retiring {
            codecQueue.async { VTCompressionSessionInvalidate(retiring) }
        }
        func create(_ codec: Codec) -> (VTCompressionSession?, OSStatus) {
            var created: VTCompressionSession?
            let status = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                width: Int32(encoderWidth),
                height: Int32(encoderHeight),
                codecType: codec.cmCodecType,
                encoderSpecification: nil,
                imageBufferAttributes: nil,
                compressedDataAllocator: nil,
                outputCallback: { refcon, _, status, _, sampleBuffer in
                    guard status == noErr, let refcon, let sampleBuffer else { return }
                    let context = Unmanaged<GVDatamoshEngine>.fromOpaque(refcon).takeUnretainedValue()
                    context.deliver(sampleBuffer: sampleBuffer)
                },
                refcon: Unmanaged.passUnretained(self).toOpaque(),
                compressionSessionOut: &created
            )
            return (created, status)
        }
        var settled = configuration.codec
        var (session, status) = create(settled)
        if session == nil, settled != .h264 {
            GVLog.rendering.notice("datamosh: \(settled.rawValue, privacy: .public) encoder refused (status \(status)); falling back to H.264")
            settled = .h264
            (session, status) = create(.h264)
        }
        guard status == noErr, let session else {
            GVLog.rendering.error("datamosh encoder create failed: \(status)")
            return nil
        }
        // Profile at creation and never afterwards: VideoToolbox treats it as
        // structural to the stream, and Baseline is what guarantees the I/P-only
        // chain this effect predicts against. A refusal is not fatal — the
        // codec's own defaults still describe a real stream.
        let profileStatus = VTSessionSetProperties(
            session,
            propertyDictionary: [kVTCompressionPropertyKey_ProfileLevel: settled.profileLevel] as CFDictionary
        )
        if profileStatus != noErr {
            GVLog.rendering.notice("datamosh: profile for \(settled.rawValue, privacy: .public) refused (status \(profileStatus)); codec defaults accepted")
        }
        encoder = session
        encoderCodec = settled
        stats.codec = settled
        // A fresh session has none of the live properties on it, so the caches
        // that let `apply` skip redundant work are cleared with it.
        encoderBitrate = 0
        encoderKeyframeInterval = 0
        encoderDropEvery = -1
        pendingKeyframe = true
        return session
    }

    // MARK: - Staging ring

    /// The encode resolution actually to be used, with the source's aspect
    /// preserved: a mosh that squashes the frame is not a compression artefact,
    /// it is a resize. Both axes are quantised to macroblock multiples so
    /// dragging the SCALE slider rebuilds the ring a handful of times rather
    /// than on every pixel of travel, and stays even because an inter-predicted
    /// codec cannot code an odd edge.
    private func configuredEncodeSize(configuration: Configuration, sourceSize: CGSize) -> CGSize {
        let sourceEdge = max(sourceSize.width, sourceSize.height)
        guard sourceEdge > 0, sourceSize.width >= 16, sourceSize.height >= 16 else { return .zero }
        let requested = configuration.encodeLongEdge > 0
            ? min(CGFloat(configuration.encodeLongEdge), sourceEdge)
            : sourceEdge
        let scale = requested / sourceEdge
        func quantised(_ value: CGFloat) -> CGFloat {
            max(48, (value * scale / 16).rounded(.down) * 16)
        }
        return CGSize(width: quantised(sourceSize.width), height: quantised(sourceSize.height))
    }

    /// Allocates the encoder-input ring for an encode size: a BGRA image buffer
    /// for the codec and a BGRA Metal texture of the same size for the kernel
    /// that fills it. Same pixel format on both sides, so handing one to the
    /// other is a straight row copy with no swizzle.
    private func stagingRingReady(size: CGSize) -> Bool {
        if stagingSize == size, stagingBuffers.count == stagingSlotCount { return true }
        let width = Int(size.width)
        let height = Int(size.height)
        guard width >= 16, height >= 16 else { return false }
        var buffers: [CVPixelBuffer] = []
        var textures: [MTLTexture] = []
        var imports: [CVMetalTexture] = []
        buffers.reserveCapacity(stagingSlotCount)
        textures.reserveCapacity(stagingSlotCount)
        for _ in 0..<stagingSlotCount {
            guard let buffer = Self.makePixelBuffer(width: width, height: height) else { return false }
            // Prefer the shared surface: importing the encoder's own image buffer
            // hands Metal a texture whose memory *is* that buffer, so the kernel's
            // write is the encoder's read and there is no copy anywhere. On the
            // simulator this is declined — see `pump` — and a private texture plus
            // one memcpy takes its place.
            if let texture = sharedStagingTexture(for: buffer,
                                                  width: width,
                                                  height: height,
                                                  into: &imports) {
                buffers.append(buffer)
                textures.append(texture)
            } else if let texture = stagingTexture(width: width, height: height) {
                buffers.append(buffer)
                textures.append(texture)
            } else {
                return false
            }
        }
        stagingBuffers = buffers
        stagingTextures = textures
        stagingImports = imports
        stagingIsShared = imports.count == stagingSlotCount
        stagingClaimedAt = Array(repeating: 0, count: stagingSlotCount)
        stagingSize = size
        encoderWidth = width
        encoderHeight = height
        // The read-back row buffer is only needed on the copy path; a shared
        // surface never touches it, so it is not sized for it.
        stagingScratch = stagingIsShared ? [] : Array(repeating: 0, count: width * height * 4)
        // A new size is a new stream: the decoder must be rebuilt from the
        // format that size produces, and the encoder must open with a sync
        // sample or the first frame of the new scale decodes against nothing.
        // The outgoing sessions are dropped rather than invalidated here — this
        // runs on the render thread, and invalidating a session another thread
        // is inside EncodeFrame is not something VideoToolbox tolerates.
        let retiringEncoder = encoder
        let retiringDecoder = decoder
        encoder = nil
        decoder = nil
        encoderCodec = nil
        decoderFormat = nil
        decoderHasSyncSample = false
        codecQueue.async { [self] in
            // `self` is captured deliberately: invalidating flushes queued frames
            // and the flush calls back through a pointer to this object, so it has
            // to be alive for as long as the invalidate takes.
            if let retiringEncoder { VTCompressionSessionInvalidate(retiringEncoder) }
            if let retiringDecoder { VTDecompressionSessionInvalidate(retiringDecoder) }
        }
        pendingKeyframe = true
        encoderBitrate = 0
        encoderKeyframeInterval = 0
        encoderDropEvery = -1
        return true
    }

    private let stagingSlotCount = 3

    /// The encoder's image buffer seen from the GPU side.
    ///
    /// This is the zero-copy hand-off: one IOSurface, written by a kernel, read
    /// by the video encoder. It is declined in the simulator, where importing a
    /// shared surface into Metal does not return an error but takes the process
    /// down inside the driver's XPC layer (see `pump`), and declined for any
    /// import Metal will not let a kernel write into.
    private func sharedStagingTexture(for buffer: CVPixelBuffer,
                                      width: Int,
                                      height: Int,
                                      into imports: inout [CVMetalTexture]) -> MTLTexture? {
#if targetEnvironment(simulator)
        // Nothing to hand back: the copy path is chosen instead, and the
        // simulator's Metal driver is not asked to look at a shared surface.
        _ = (buffer, width, height, imports)
        return nil
#else
        guard let cache = textureCache else { return nil }
        var image: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            buffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &image
        )
        guard status == kCVReturnSuccess, let image,
              let texture = CVMetalTextureGetTexture(image),
              texture.usage.contains(.shaderWrite)
        else { return nil }
        // The Metal view of the surface is only valid while the import that
        // produced it lives, so the ring keeps it.
        imports.append(image)
        return texture
#endif
    }

    private func stagingTexture(width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        return device.makeTexture(descriptor: descriptor)
    }

    /// An encoder-input image buffer. IOSurface-backed because that is what a
    /// hardware encoder wants to read; the CPU writes it once per frame under a
    /// lock, which is the same surface seen from the other side.
    private static func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferBytesPerRowAlignmentKey: 64,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault,
                                  width,
                                  height,
                                  kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary,
                                  &buffer) == kCVReturnSuccess, let buffer
        else { return nil }
        return buffer
    }
}

extension GVDatamoshEngine.Variant {
    /// Which instrument this effect plays. Failable so a codec mode added
    /// without a variant lands here as a compile-time question rather than a
    /// runtime shrug: `nil` would silently fall back to DATAMOSH's settings and
    /// the new effect would look like a slightly wrong old one.
    init?(_ effect: WorkspaceAdjustableEffect) {
        switch effect {
        case .datamosh: self = .datamosh
        case .liquidMosh: self = .liquidMosh
        case .heavyMosh: self = .heavyMosh
        default: return nil
        }
    }
}

extension GVDatamoshEngine {
    /// How many live round trips the hardware is allowed to fund at once. Each
    /// one is an encoder, a decoder and its own staging ring; two is what fits
    /// inside the frame budget with the rest of the effect stack still running.
    /// A refused Slot is not dropped — it keeps its place in the chain, and the
    /// three instruments running today take their whole picture from a decoder's
    /// reconstruction, so a refused Slot shows the frame uncorrupted until the
    /// hardware frees up. That is why the refusal is counted in render stats
    /// rather than left for the operator to infer from the image.
    struct Budget {
        static let defaultLimit = 2

        let limit: Int
        private(set) var spent: Int = 0

        init(limit: Int = Budget.defaultLimit) {
            self.limit = limit
        }

        /// Funds `requested` sessions, or nothing. All-or-nothing per Slot: a
        /// cascade that got one of its two sessions would be a mosh that
        /// silently stopped cascading.
        mutating func fund(requested: Int) -> Bool {
            guard requested > 0, spent + requested <= limit else { return false }
            spent += requested
            return true
        }

        mutating func release(_ requested: Int) {
            spent = max(0, spent - requested)
        }

        var liveSessions: Int { spent }
    }
}
