import Foundation
import Metal
import simd

// MARK: - Live signal bundle

/// The render-thread snapshot of every live signal the particle emitters
/// react to. All fields are normalized to 0...1; `depthPresent` gates the
/// LiDAR term so devices without depth never read a stale value.
///
/// This struct is intentionally decoupled from the app's signal owners
/// (`GVSignal`, the audio analyser mailbox, the motion field). The render
/// loop (or whoever wires the slot) publishes into
/// ``GVParticleSignalMailbox`` once per frame; the engine only ever reads
/// the mailbox. That keeps the simulation deterministic and testable, and
/// means this file never touches MainActor-owned singletons.
struct GVParticleSignals: Equatable, Sendable {
    /// Broadband audio amplitude (analyser RMS).
    var audio: Float = 0
    /// Low-frequency band energy. Drives ember spawn rate.
    var bass: Float = 0
    /// Onset / transient detector. Pops static, fires glitch bursts.
    var transient: Float = 0
    /// Camera-motion magnitude from the temporal motion field.
    var motion: Float = 0
    /// Reserved for a future luminance-reactive term. Wired as 0 for now.
    var luminance: Float = 0
    /// Normalized LiDAR depth (0 = near, 1 = far). Ember size only.
    var depth: Float = 0
    /// False on devices without LiDAR; the depth term is skipped then.
    var depthPresent: Bool = false

    static let idle = GVParticleSignals()

    /// Builds a bundle from the app's audio analyser snapshot plus the
    /// motion/depth terms the render loop already computes per frame.
    /// Every field is clamped to 0...1 and NaN-proofed.
    static func from(
        audio: AudioReactiveSnapshot,
        motion: Float,
        depth: Float,
        depthPresent: Bool
    ) -> GVParticleSignals {
        GVParticleSignals(
            audio: clamp01(audio.rms),
            bass: clamp01(audio.bass),
            transient: clamp01(audio.transient),
            motion: clamp01(motion),
            depth: clamp01(depth),
            depthPresent: depthPresent
        )
    }

    private static func clamp01(_ value: Float) -> Float {
        min(max(value.isFinite ? value : 0, 0), 1)
    }
}

/// Render-thread handoff for ``GVParticleSignals``. Published from the
/// render loop once per frame, read by ``GVParticleEngine/update`` on the
/// same thread. Mirrors `AudioReactiveSnapshotMailbox`.
final class GVParticleSignalMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = GVParticleSignals.idle

    var latest: GVParticleSignals {
        lock.withLock { value }
    }

    func publish(_ signals: GVParticleSignals) {
        lock.withLock { value = signals }
    }

    func clear() {
        lock.withLock { value = .idle }
    }
}

// MARK: - Particle storage

/// One simulated particle. Positions and sizes are in output pixels with a
/// top-left origin, matching the vertex layout the shader expects.
/// `baseColor` is unpremultiplied linear RGB; `alpha` is baked into the
/// vertex color (premultiplied) at upload time in
/// ``GVParticleEngine/writeVertices(into:capacity:)``.
struct GVParticle: Sendable {
    var position: SIMD2<Float>
    var velocity: SIMD2<Float>
    /// Seconds remaining. The particle is reaped at zero.
    var life: Float
    var maxLife: Float
    /// Diameter in pixels, before the size parameter is applied at spawn.
    var size: Float
    /// Per-particle random phase for sway / flicker.
    var seed: Float
    var baseColor: SIMD3<Float>
    var alpha: Float
    /// 0 = soft disc, 1 = hard square. Matches the fragment shader.
    var shape: Float
}

/// Must match the `GVParticleVertex` struct in `ParticleShaders.metal`
/// (32 bytes: float2 + float + float + float4).
struct GVParticleVertexData {
    var position: SIMD2<Float>
    var size: Float
    var shape: Float
    var color: SIMD4<Float>
}

/// Deterministic xorshift64* generator. No `SystemRandomNumberGenerator`
/// here: the engine must be seedable so bursts and tests are reproducible.
struct GVParticleRNG: Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        var x = state
        x ^= x >> 12
        x ^= x << 25
        x ^= x >> 27
        state = x
        return x &* 0x2545_F491_4F6C_DD1D
    }

    /// Uniform float in 0..<1.
    mutating func nextFloat() -> Float {
        Float(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    mutating func nextRange(_ range: ClosedRange<Float>) -> Float {
        range.lowerBound + nextFloat() * (range.upperBound - range.lowerBound)
    }
}

// MARK: - Engine

/// CPU particle simulation for one emitter. Owned by
/// ``GVParticleOverlayEffect`` and confined to the render thread, exactly
/// like the app's other GPU hosts (`CameraReactionDiffusion` pattern):
/// failable-free construction, persistent resources, no force unwraps,
/// and a `false`-style fail-closed posture (here: zero particles) if
/// anything is misconfigured.
///
/// Cost model: the simulation is O(alive) with a tiny constant. `update`
/// self-times with a rolling average exposed as
/// ``estimatedCostMilliseconds`` so the frame governor can fold particles
/// into its adaptive budget next to `WorkspaceAdjustableEffect.estimatedCost`.
final class GVParticleEngine: @unchecked Sendable {
    let emitter: GVParticleEmitterKind
    let maxParticles: Int

    private var particles: [GVParticle] = []
    private var aliveCount = 0
    private var rng: GVParticleRNG
    private var time: Float = 0
    private var costAverageMs = 0.0
    private var qualityScale: Float = 1

    var activeCount: Int { aliveCount }
    var estimatedCostMilliseconds: Double { costAverageMs }

    /// `seed` is exposed for tests; production passes nil for a time-based
    /// seed so every launch looks slightly different.
    init(emitter: GVParticleEmitterKind, device: MTLDevice, seed: UInt64? = nil) {
        self.emitter = emitter
        self.maxParticles = Self.capacity(for: device)
        particles.reserveCapacity(maxParticles)
        let fallback = UInt64(bitPattern: Int64(Date().timeIntervalSinceReferenceDate * 1000))
        rng = GVParticleRNG(seed: seed ?? fallback)
    }

    /// Device capability scaling. A14-class and newer (Apple7 family)
    /// simulate up to 4096 particles; older GPUs cap at 2048. The density
    /// parameter then takes a fraction of this budget, so low-end devices
    /// degrade gracefully instead of dropping frames.
    static func capacity(for device: MTLDevice) -> Int {
        device.supportsFamily(.apple7) ? 4096 : 2048
    }

    /// Governor input: 1 = full detail, 0.5 = reduced. Set from the render
    /// thread alongside `process`; scales the population target directly.
    func noteQualityScale(_ scale: Float) {
        qualityScale = min(max(scale.isFinite ? scale : 1, 0.25), 1)
    }

    func reset() {
        aliveCount = 0
        time = 0
    }

    // MARK: Update

    /// Advances the simulation one frame. `viewportSize` is the output
    /// texture size in pixels. Never throws and never traps: degenerate
    /// inputs collapse to zero particles, never to a crash.
    func update(
        signals: GVParticleSignals,
        config: GVParticleConfiguration,
        deltaTime: TimeInterval,
        viewportSize: SIMD2<Float>
    ) {
        let start = ProcessInfo.processInfo.systemUptime
        let dt = Float(min(max(deltaTime.isFinite ? deltaTime : 1.0 / 60.0, 1.0 / 240.0), 0.25))
        time += dt
        let size = SIMD2<Float>(max(viewportSize.x, 1), max(viewportSize.y, 1))

        let target = targetCount(signals: signals, config: config)
        if emitter == .glitch {
            // Glitch bursts are self-limiting by their short lifetimes, so
            // only trim a generous headroom instead of the exact target.
            while aliveCount < target {
                spawn(signals: signals, config: config, viewportSize: size)
            }
            maybeGlitchBurst(signals: signals, config: config, viewportSize: size)
            while aliveCount > target + 96 {
                killLast()
            }
        } else {
            while aliveCount < target {
                spawn(signals: signals, config: config, viewportSize: size)
            }
            while aliveCount > target {
                killLast()
            }
        }

        switch emitter {
        case .staticNoise:
            integrateStatic(signals: signals, config: config, dt: dt)
        case .ember:
            integrateEmber(signals: signals, config: config, dt: dt)
        case .dust:
            integrateDust(signals: signals, config: config, dt: dt, viewportSize: size)
        case .glitch:
            integrateGlitch(signals: signals, config: config, dt: dt)
        }
        reapDead(viewportSize: size, margin: 64)

        let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
        costAverageMs = costAverageMs * 0.92 + elapsed * 0.08
    }

    /// Writes alive particles into `buffer` as ``GVParticleVertexData``.
    /// Returns the vertex count. The caller owns the buffer and guarantees
    /// `capacity` entries; no allocation happens here.
    func writeVertices(into buffer: UnsafeMutableRawPointer, capacity: Int) -> Int {
        let count = min(aliveCount, capacity, particles.count)
        guard count > 0 else { return 0 }
        let dst = buffer.assumingMemoryBound(to: GVParticleVertexData.self)
        for i in 0 ..< count {
            let p = particles[i]
            dst[i] = GVParticleVertexData(
                position: p.position,
                size: max(p.size, 0.5),
                shape: p.shape,
                color: SIMD4(p.baseColor * max(p.alpha, 0), 1)
            )
        }
        return count
    }

    // MARK: Population

    private func targetCount(signals: GVParticleSignals, config: GVParticleConfiguration) -> Int {
        let base = Float(maxParticles) * config.density * qualityScale
        let modulated: Float
        switch emitter {
        case .staticNoise:
            // The field breathes with the music but never fully dies.
            modulated = base * (0.35 + 0.65 * min(max(signals.audio * 1.4, 0), 1))
        case .ember:
            modulated = base * (0.5 + 0.9 * min(max(signals.bass * 1.6, 0), 1))
        case .dust:
            modulated = base
        case .glitch:
            // Near-silent baseline; bursts do the talking.
            modulated = base * 0.06
        }
        return min(max(Int(modulated.rounded()), 0), maxParticles)
    }

    private func spawn(signals: GVParticleSignals, config: GVParticleConfiguration, viewportSize: SIMD2<Float>) {
        guard aliveCount < maxParticles else { return }
        let particle: GVParticle
        switch emitter {
        case .staticNoise:
            particle = makeStatic(signals: signals, config: config, viewportSize: viewportSize)
        case .ember:
            particle = makeEmber(signals: signals, config: config, viewportSize: viewportSize)
        case .dust:
            particle = makeDust(signals: signals, config: config, viewportSize: viewportSize)
        case .glitch:
            particle = makeGlitch(signals: signals, config: config, viewportSize: viewportSize)
        }
        if aliveCount < particles.count {
            particles[aliveCount] = particle
        } else {
            particles.append(particle)
        }
        aliveCount += 1
    }

    private func killLast() {
        guard aliveCount > 0 else { return }
        aliveCount -= 1
    }

    /// Swap-removes dead and out-of-bounds particles. Dust wraps toroidally
    /// in its integrator so it never goes out of bounds.
    private func reapDead(viewportSize: SIMD2<Float>, margin: Float) {
        var i = 0
        while i < aliveCount {
            let p = particles[i]
            let offscreen = p.position.x < -margin || p.position.x > viewportSize.x + margin
                || p.position.y < -margin || p.position.y > viewportSize.y + margin
            if p.life <= 0 || offscreen {
                aliveCount -= 1
                particles[i] = particles[aliveCount]
            } else {
                i += 1
            }
        }
    }

    // MARK: Emitters

    private func makeStatic(signals: GVParticleSignals, config: GVParticleConfiguration, viewportSize: SIMD2<Float>) -> GVParticle {
        let flicker = min(max(0.3 + signals.audio * 0.9 + signals.transient * 1.2, 0), 1.6)
        let brightness = rng.nextRange(0.35 ... 1.0) * flicker * config.glow
        let life = rng.nextRange(1.0 ... 3.0) / 60
        return GVParticle(
            position: SIMD2(rng.nextFloat() * viewportSize.x, rng.nextFloat() * viewportSize.y),
            velocity: .zero,
            life: life,
            maxLife: life,
            size: rng.nextRange(1.0 ... 3.0) * (0.6 + config.size * 1.6),
            seed: rng.nextFloat() * 100,
            baseColor: SIMD3(repeating: brightness),
            alpha: 1,
            shape: 0
        )
    }

    private func integrateStatic(signals _: GVParticleSignals, config _: GVParticleConfiguration, dt: Float) {
        for i in 0 ..< aliveCount {
            particles[i].life -= dt
        }
    }

    private func makeEmber(signals: GVParticleSignals, config: GVParticleConfiguration, viewportSize: SIMD2<Float>) -> GVParticle {
        let heat = rng.nextFloat()
        let rgb = SIMD3<Float>(1.0, 0.32 + 0.5 * heat, 0.08 + 0.22 * heat)
        let bassBoost = 1 + min(max(signals.bass, 0), 1) * 0.8
        let rise = rng.nextRange(50 ... 130) * bassBoost * (0.5 + config.speed)
        let life = rng.nextRange(2.0 ... 4.0)
        var sizePx = rng.nextRange(2.0 ... 5.0) * (0.5 + config.size * 1.8)
        if signals.depthPresent {
            // Near embers read larger, far embers smaller. Subtle on purpose.
            sizePx *= 1.25 - 0.5 * min(max(signals.depth, 0), 1)
        }
        return GVParticle(
            position: SIMD2(rng.nextFloat() * viewportSize.x, viewportSize.y * rng.nextRange(0.96 ... 1.0)),
            velocity: SIMD2(rng.nextRange(-14 ... 14), -rise),
            life: life,
            maxLife: life,
            size: sizePx,
            seed: rng.nextFloat() * 100,
            baseColor: rgb,
            alpha: 0,
            shape: 0
        )
    }

    private func integrateEmber(signals _: GVParticleSignals, config: GVParticleConfiguration, dt: Float) {
        let sway = config.turbulence * 46
        for i in 0 ..< aliveCount {
            particles[i].velocity.y -= 26 * dt
            particles[i].velocity.x *= max(1 - 0.6 * dt, 0)
            let phase = time * (1.5 + particles[i].seed * 0.02) + particles[i].seed
            particles[i].position.x += (particles[i].velocity.x + sin(phase) * sway) * dt
            particles[i].position.y += particles[i].velocity.y * dt
            particles[i].life -= dt
            let age = 1 - max(particles[i].life, 0) / max(particles[i].maxLife, 0.001)
            let fade = min(age * 6, 1) * min(max(particles[i].life * 2.5, 0), 1)
            particles[i].alpha = config.glow * fade
        }
    }

    private func makeDust(signals _: GVParticleSignals, config: GVParticleConfiguration, viewportSize: SIMD2<Float>) -> GVParticle {
        let angle = rng.nextFloat() * Float.pi * 2
        let drift = rng.nextRange(2.0 ... 9.0)
        let life = rng.nextRange(8.0 ... 16.0)
        let tone = rng.nextRange(0.7 ... 1.0)
        return GVParticle(
            position: SIMD2(rng.nextFloat() * viewportSize.x, rng.nextFloat() * viewportSize.y),
            velocity: SIMD2(cos(angle) * drift, sin(angle) * drift),
            life: life,
            maxLife: life,
            size: rng.nextRange(1.0 ... 3.5) * (0.6 + config.size * 1.6),
            seed: rng.nextFloat() * 100,
            baseColor: SIMD3(0.72 * tone, 0.8 * tone, 0.9 * tone),
            alpha: 0,
            shape: 0
        )
    }

    private func integrateDust(signals: GVParticleSignals, config: GVParticleConfiguration, dt: Float, viewportSize: SIMD2<Float>) {
        let stir = 1 + min(max(signals.motion, 0), 1) * 2.5
        let wobble = config.turbulence * 14
        let rate = 0.3 + config.speed
        for i in 0 ..< aliveCount {
            let phase = time * 0.7 + particles[i].seed
            particles[i].position.x += (particles[i].velocity.x * stir + sin(phase) * wobble) * rate * dt
            particles[i].position.y += (particles[i].velocity.y * stir + cos(phase * 0.8) * wobble) * rate * dt
            if particles[i].position.x < 0 { particles[i].position.x += viewportSize.x }
            if particles[i].position.x > viewportSize.x { particles[i].position.x -= viewportSize.x }
            if particles[i].position.y < 0 { particles[i].position.y += viewportSize.y }
            if particles[i].position.y > viewportSize.y { particles[i].position.y -= viewportSize.y }
            particles[i].life -= dt
            let age = 1 - max(particles[i].life, 0) / max(particles[i].maxLife, 0.001)
            let fade = min(age * 4, 1) * min(max(particles[i].life * 1.5, 0), 1)
            particles[i].alpha = 0.28 * config.glow * fade
        }
    }

    private func makeGlitch(signals _: GVParticleSignals, config: GVParticleConfiguration, viewportSize: SIMD2<Float>) -> GVParticle {
        let pick = rng.nextFloat()
        let rgb: SIMD3<Float>
        if pick < 0.5 {
            rgb = SIMD3(1, 1, 1)
        } else if pick < 0.75 {
            rgb = SIMD3(0.65, 1.0, 0.25)
        } else {
            rgb = SIMD3(0.7, 0.55, 1.0)
        }
        let life = rng.nextRange(0.08 ... 0.35)
        return GVParticle(
            position: SIMD2(rng.nextFloat() * viewportSize.x, rng.nextFloat() * viewportSize.y),
            velocity: .zero,
            life: life,
            maxLife: life,
            size: rng.nextRange(3.0 ... 9.0) * (0.5 + config.size),
            seed: rng.nextFloat() * 100,
            baseColor: rgb,
            alpha: 0,
            shape: 1
        )
    }

    private func maybeGlitchBurst(signals: GVParticleSignals, config: GVParticleConfiguration, viewportSize: SIMD2<Float>) {
        let excitement = min(max(signals.transient * 1.5, signals.motion * 1.2), 1)
        guard excitement > 0.32 else { return }
        let burst = min(Int(6 + excitement * 30), maxParticles - aliveCount)
        guard burst > 0 else { return }
        for _ in 0 ..< burst {
            spawn(signals: signals, config: config, viewportSize: viewportSize)
        }
    }

    private func integrateGlitch(signals: GVParticleSignals, config: GVParticleConfiguration, dt: Float) {
        let jitter = (4 + 36 * config.turbulence) * (0.5 + min(max(signals.motion, 0), 1))
        for i in 0 ..< aliveCount {
            // Teleport jitter: shards snap between quantized offsets instead
            // of drifting, which reads as pixel scatter, not motion.
            particles[i].position.x += rng.nextRange(-jitter ... jitter)
            particles[i].position.y += rng.nextRange(-jitter ... jitter)
            particles[i].life -= dt
            particles[i].alpha = config.glow * min(max(particles[i].life * 8, 0), 1)
        }
    }
}
