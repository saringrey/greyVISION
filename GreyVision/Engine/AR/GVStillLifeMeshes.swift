import Metal
import MetalKit
import ModelIO
import simd

/// Procedural models for the AR studio, drawn from the splash film's still
/// lifes: a few plain studio objects (vase, pear, column) and the special
/// pieces the film is built around (a chrome screw, a DNA double helix, a
/// space-frame canopy, a windswept olive tree and a highway interchange).
///
/// Everything is built from two primitives, a parametric surface and a swept
/// tube, so each model is a handful of curves rather than hand-placed
/// triangles. Models sit inside roughly ±0.55 like the existing shapes, and
/// the renderer does not cull, so winding does not matter; normals are taken
/// from the surface and turned to face away from a reference axis.
enum GVStillLifeMeshes {
    static func make(_ shape: ARObjectShape, allocator: MTKMeshBufferAllocator) -> MDLMesh? {
        var builder = Builder()
        switch shape {
        case .vase: buildVase(&builder)
        case .pear: buildPear(&builder)
        case .column: buildColumn(&builder)
        case .screw: buildScrew(&builder)
        case .dna: buildDNA(&builder)
        case .spaceFrame: buildSpaceFrame(&builder)
        case .oliveTree: buildOliveTree(&builder)
        case .interchange: buildInterchange(&builder)
        default: return nil
        }
        return builder.mesh(allocator: allocator)
    }

    // MARK: - Basic still-life objects

    /// An amphora: narrow foot, full belly, pinched neck and a flared lip.
    private static func buildVase(_ b: inout Builder) {
        func radius(_ t: Float) -> Float {
            let belly = 0.22 * exp(-pow((t - 0.36) / 0.21, 2))
            let lip = 0.05 * smoothstep(0.86, 1.0, t)
            return 0.085 + belly + lip
        }
        b.lathe(around: 48, along: 64, radius: { t, _ in radius(t) }, height: { -0.5 + $0 * 1.0 })
        b.disc(y: -0.5, radius: radius(0), around: 48)
        b.disc(y: 0.44, radius: radius(1) - 0.012, around: 48)
    }

    /// A pear: two spheres melted together, with a curled stem.
    private static func buildPear(_ b: inout Builder) {
        let k: Float = 0.035
        func radius(_ y: Float) -> Float {
            let r1 = sqrt(max(0, 0.30 * 0.30 - (y + 0.17) * (y + 0.17)))
            let r2 = sqrt(max(0, 0.17 * 0.17 - (y - 0.17) * (y - 0.17)))
            let blended = k * log(exp(r1 / k) + exp(r2 / k)) - k * log(2)
            return max(0, blended)
        }
        let bottom: Float = -0.47, top: Float = 0.34
        b.lathe(around: 48, along: 60, radius: { t, _ in radius(bottom + (top - bottom) * t) },
                height: { bottom + (top - bottom) * $0 })
        b.tube(along: 16, around: 8, path: { t in
            SIMD3(0.06 * t * t, 0.32 + 0.16 * t, 0.015 * t)
        }, radius: { t, _ in 0.018 - 0.006 * t })
        // One leaf, a flattened ellipsoid off the stem.
        b.ellipsoid(center: SIMD3(0.09, 0.44, 0.02), radii: SIMD3(0.08, 0.012, 0.035), around: 16, along: 10)
    }

    /// A fluted Doric column on a square-ish plinth.
    private static func buildColumn(_ b: inout Builder) {
        b.lathe(around: 96, along: 24, radius: { t, angle in
            let taper: Float = 0.135 - 0.02 * t
            let flute = 0.012 * max(0, cos(angle * 16))
            return taper - flute
        }, height: { -0.40 + $0 * 0.80 })
        for (y0, y1, r) in [(-0.52, -0.46, Float(0.22)), (-0.46, -0.40, Float(0.17)),
                            (0.40, 0.45, Float(0.16)), (0.45, 0.52, Float(0.22))] as [(Float, Float, Float)] {
            b.lathe(around: 4, along: 1, radius: { _, _ in r * 1.41 }, height: { y0 + (y1 - y0) * $0 }, phase: .pi / 4)
            b.disc(y: y0, radius: r * 1.41, around: 4, phase: .pi / 4)
            b.disc(y: y1, radius: r * 1.41, around: 4, phase: .pi / 4)
        }
    }

    // MARK: - Special pieces

    /// A countersunk screw with a real helical thread and a cross slot.
    private static func buildScrew(_ b: inout Builder) {
        let tip: Float = -0.58, shaftTop: Float = 0.28
        func shaft(_ y: Float) -> Float {
            let point = smoothstep(tip, tip + 0.18, y)
            return 0.075 * point + 0.004
        }
        b.lathe(around: 32, along: 40, radius: { t, _ in shaft(tip + (shaftTop - tip) * t) },
                height: { tip + (shaftTop - tip) * $0 })
        // Head: a countersunk cone topped by a shallow dome.
        b.lathe(around: 48, along: 6, radius: { t, _ in 0.08 + 0.12 * t }, height: { shaftTop + 0.08 * $0 })
        b.lathe(around: 48, along: 10, radius: { t, _ in 0.20 * cos(t * 1.25) }, height: { 0.36 + 0.07 * sin($0 * 1.25) })
        b.disc(y: 0.36 + 0.07 * sin(1.25), radius: 0.20 * cos(1.25), around: 48)
        // Cross slot as two thin dark bars just proud of the dome.
        b.box(center: SIMD3(0, 0.43, 0), size: SIMD3(0.26, 0.02, 0.035))
        b.box(center: SIMD3(0, 0.43, 0), size: SIMD3(0.035, 0.02, 0.26))
        // Thread: a helix that rides the shaft radius, fading out at the point.
        let turns: Float = 10
        b.tube(along: 420, around: 6, path: { t in
            let y = tip + 0.06 + (shaftTop - 0.06 - tip - 0.06) * t
            let angle = t * turns * 2 * .pi
            let r = shaft(y) + 0.012
            return SIMD3(cos(angle) * r, y, sin(angle) * r)
        }, radius: { t, _ in 0.026 * smoothstep(0, 0.08, t) * (1 - smoothstep(0.97, 1, t)) + 0.002 })
    }

    /// A DNA double helix: two backbones and base-pair rungs with bead ends.
    private static func buildDNA(_ b: inout Builder) {
        let turns: Float = 2.2, radius: Float = 0.24, height: Float = 1.08
        func strand(_ t: Float, _ phase: Float) -> SIMD3<Float> {
            let a = t * turns * 2 * .pi + phase
            return SIMD3(cos(a) * radius, (t - 0.5) * height, sin(a) * radius)
        }
        // Major and minor grooves: the second strand is offset by 0.75π, not π.
        let phases: [Float] = [0, 0.75 * .pi]
        for phase in phases {
            b.tube(along: 200, around: 10, path: { strand($0, phase) }, radius: { _, _ in 0.03 })
        }
        let rungs = 22
        for i in 0 ..< rungs {
            let t = (Float(i) + 0.5) / Float(rungs)
            let a = strand(t, phases[0]), c = strand(t, phases[1])
            b.tube(along: 1, around: 6, path: { a + (c - a) * $0 }, radius: { _, _ in 0.014 })
            b.ellipsoid(center: a + (c - a) * 0.5, radii: SIMD3(repeating: 0.022), around: 8, along: 6)
        }
    }

    /// A curved space-frame canopy: two offset node grids tied by struts,
    /// like the steel roof in the film.
    private static func buildSpaceFrame(_ b: inout Builder) {
        let n = 6
        let span: Float = 1.0, depth: Float = 0.14
        func bend(_ p: SIMD3<Float>) -> SIMD3<Float> {
            // Arch the whole frame over x and add a gentle saddle over z.
            SIMD3(p.x, p.y - 0.55 * p.x * p.x + 0.18 * p.z * p.z + 0.08, p.z)
        }
        func top(_ i: Int, _ j: Int) -> SIMD3<Float> {
            bend(SIMD3(span * (Float(i) / Float(n) - 0.5), 0, span * 0.75 * (Float(j) / Float(n) - 0.5)))
        }
        func bottom(_ i: Int, _ j: Int) -> SIMD3<Float> {
            bend(SIMD3(span * ((Float(i) + 0.5) / Float(n) - 0.5), -depth,
                       span * 0.75 * ((Float(j) + 0.5) / Float(n) - 0.5)))
        }
        let strut: Float = 0.009
        for i in 0 ... n {
            for j in 0 ... n {
                let p = top(i, j)
                b.ellipsoid(center: p, radii: SIMD3(repeating: 0.016), around: 6, along: 4)
                if i < n { b.strut(p, top(i + 1, j), radius: strut) }
                if j < n { b.strut(p, top(i, j + 1), radius: strut) }
            }
        }
        for i in 0 ..< n {
            for j in 0 ..< n {
                let q = bottom(i, j)
                b.ellipsoid(center: q, radii: SIMD3(repeating: 0.014), around: 6, along: 4)
                if i < n - 1 { b.strut(q, bottom(i + 1, j), radius: strut) }
                if j < n - 1 { b.strut(q, bottom(i, j + 1), radius: strut) }
                for (di, dj) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                    b.strut(q, top(i + di, j + dj), radius: strut * 0.85)
                }
            }
        }
    }

    /// A windswept olive tree on a mound of earth: a gnarled, twisting trunk
    /// that bows sideways before rising, splitting into branches that end in
    /// dense leaf clouds.
    private static func buildOliveTree(_ b: inout Builder) {
        // Earth mound.
        b.lathe(around: 40, along: 8, radius: { t, angle in
            (0.34 + 0.02 * sin(angle * 5)) * cos(t * .pi / 2)
        }, height: { -0.56 + 0.07 * sin($0 * .pi / 2) })

        // Trunk: low sideways arc, then up. Ridges twist along its length.
        func trunk(_ t: Float) -> SIMD3<Float> {
            let x = -0.05 + 0.42 * sin(t * 2.1) - 0.36 * t * t
            let y = -0.50 + 0.62 * t + 0.10 * sin(t * 3.0)
            let z = 0.05 * sin(t * 4.0)
            return SIMD3(x, y, z)
        }
        b.tube(along: 60, around: 20, path: trunk, radius: { t, angle in
            let base: Float = 0.085 - 0.045 * t + 0.03 * (1 - smoothstep(0, 0.12, t))
            return base * (1 + 0.22 * sin(angle * 5 + t * 9))
        })

        // Branches and crowns.
        let crown = trunk(1)
        let branches: [SIMD3<Float>] = [
            SIMD3(-0.30, 0.20, 0.06), SIMD3(-0.08, 0.32, -0.10), SIMD3(0.16, 0.26, 0.08),
            SIMD3(0.30, 0.12, -0.04), SIMD3(-0.18, 0.14, -0.20)
        ]
        for (index, reach) in branches.enumerated() {
            let end = crown + reach
            let bendDir = SIMD3<Float>(0, 0.06, 0)
            b.tube(along: 16, around: 8, path: { t in
                crown + reach * t + bendDir * sin(t * .pi)
            }, radius: { t, _ in 0.034 - 0.022 * t })
            let size: Float = 0.13 + 0.03 * Float(index % 3)
            b.foliage(center: end + SIMD3(0, 0.03, 0), radius: size, seed: Float(index) * 1.7)
            b.foliage(center: crown + reach * 0.6 + SIMD3(0, 0.07, 0), radius: size * 0.75, seed: Float(index) * 2.3 + 5)
        }
    }

    /// Three road decks sweeping past and over each other, like the overpass
    /// knot in the film.
    private static func buildInterchange(_ b: inout Builder) {
        for k in 0 ..< 3 {
            let level = Float(k) - 1
            let yaw = Float(k) * 2 * .pi / 3
            let c = cos(yaw), s = sin(yaw)
            b.tube(along: 120, around: 4, path: { t in
                let x = (t - 0.5) * 1.15
                let z = 0.22 * sin(t * 2 * .pi + Float(k))
                let y = level * 0.16 + 0.10 * sin(t * .pi * 2 + Float(k) * 1.3)
                return SIMD3(x * c - z * s, y, x * s + z * c)
            }, radius: { _, _ in 1 }, crossSection: SIMD2(0.11, 0.016), flatDeck: true)
            // Piers under the lowest point of each deck.
            for t in [Float(0.5)] where k != 2 {
                let x = (t - 0.5) * 1.15
                let z = 0.22 * sin(t * 2 * .pi + Float(k))
                let y = level * 0.16 + 0.10 * sin(t * .pi * 2 + Float(k) * 1.3)
                let top = SIMD3(x * c - z * s, y - 0.02, x * s + z * c)
                if top.y > -0.5 {
                    b.strut(top, SIMD3(top.x, -0.55, top.z), radius: 0.014)
                }
            }
        }
    }

    // MARK: - Builder

    struct Builder {
        var vertices: [Float] = []
        var indices: [UInt32] = []

        /// A grid surface. `u` runs around, `v` along. Normals come from the
        /// surface and are turned away from `axis(u, v)`.
        mutating func surface(
            around uSegs: Int,
            along vSegs: Int,
            position: (Float, Float) -> SIMD3<Float>,
            axis: (Float, Float) -> SIMD3<Float>
        ) {
            let base = UInt32(vertices.count / 6)
            let eps: Float = 0.5 / Float(max(uSegs, vSegs) * 4)
            for j in 0 ... vSegs {
                let v = Float(j) / Float(vSegs)
                for i in 0 ... uSegs {
                    let u = Float(i) / Float(uSegs)
                    let p = position(u, v)
                    let pu = position(min(u + eps, 1), v) - position(max(u - eps, 0), v)
                    let pv = position(u, min(v + eps, 1)) - position(u, max(v - eps, 0))
                    let out = p - axis(u, v)
                    var n = simd_cross(pu, pv)
                    if simd_length(n) < 1e-9 { n = out }
                    if simd_dot(n, out) < 0 { n = -n }
                    let len = simd_length(n)
                    n = len > 1e-9 ? n / len : SIMD3(0, 1, 0)
                    vertices.append(contentsOf: [p.x, p.y, p.z, n.x, n.y, n.z])
                }
            }
            let row = UInt32(uSegs + 1)
            for j in 0 ..< UInt32(vSegs) {
                for i in 0 ..< UInt32(uSegs) {
                    let a = base + j * row + i
                    let b = a + row
                    indices.append(contentsOf: [a, b, a + 1, a + 1, b, b + 1])
                }
            }
        }

        /// A surface of revolution around the y axis.
        mutating func lathe(
            around: Int,
            along: Int,
            radius: @escaping (Float, Float) -> Float,
            height: @escaping (Float) -> Float,
            phase: Float = 0
        ) {
            surface(around: around, along: along, position: { u, v in
                let angle = u * 2 * .pi + phase
                let r = radius(v, angle)
                return SIMD3(cos(angle) * r, height(v), sin(angle) * r)
            }, axis: { _, v in SIMD3(0, height(v), 0) })
        }

        mutating func disc(y: Float, radius: Float, around: Int, phase: Float = 0) {
            let base = UInt32(vertices.count / 6)
            vertices.append(contentsOf: [0, y, 0, 0, y < 0 ? -1 : 1, 0])
            let ny: Float = y < 0 ? -1 : 1
            for i in 0 ... around {
                let a = Float(i) / Float(around) * 2 * .pi + phase
                vertices.append(contentsOf: [cos(a) * radius, y, sin(a) * radius, 0, ny, 0])
            }
            for i in 0 ..< UInt32(around) {
                indices.append(contentsOf: [base, base + 1 + i, base + 2 + i])
            }
        }

        /// A tube swept along `path`. `crossSection` scales the ring into an
        /// ellipse (width, thickness); `flatDeck` keeps the wide side level,
        /// which is what a road needs.
        mutating func tube(
            along: Int,
            around: Int,
            path: @escaping (Float) -> SIMD3<Float>,
            radius: @escaping (Float, Float) -> Float,
            crossSection: SIMD2<Float> = SIMD2(1, 1),
            flatDeck: Bool = false
        ) {
            func tangent(_ t: Float) -> SIMD3<Float> {
                let d: Float = 0.002
                let raw = path(min(t + d, 1)) - path(max(t - d, 0))
                return simd_length(raw) > 1e-9 ? simd_normalize(raw) : SIMD3(0, 1, 0)
            }
            // Parallel-transported frames, so a tube that turns vertical does
            // not flip its ring halfway (which tore the olive trunk). Roads
            // keep a level frame instead, so the deck stays flat.
            var frames: [(SIMD3<Float>, SIMD3<Float>)] = []
            var previous: SIMD3<Float>?
            for i in 0 ... along {
                let t = Float(i) / Float(along)
                let tan = tangent(t)
                var n: SIMD3<Float>
                if flatDeck || previous == nil {
                    let up: SIMD3<Float> = abs(tan.y) > 0.92 && !flatDeck ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
                    n = simd_normalize(simd_cross(tan, up))
                } else {
                    n = previous! - simd_dot(previous!, tan) * tan
                    n = simd_length(n) > 1e-6 ? simd_normalize(n) : simd_normalize(simd_cross(tan, SIMD3(1, 0, 0)))
                }
                previous = n
                frames.append((n, simd_normalize(simd_cross(n, tan))))
            }
            func frame(_ t: Float) -> (SIMD3<Float>, SIMD3<Float>) {
                frames[min(max(Int((t * Float(along)).rounded()), 0), along)]
            }
            surface(around: around, along: along, position: { u, v in
                let angle = u * 2 * .pi + (flatDeck ? .pi / 4 : 0)
                let (n, b) = frame(v)
                let r = radius(v, angle)
                return path(v) + n * (cos(angle) * r * crossSection.x) + b * (sin(angle) * r * crossSection.y)
            }, axis: { _, v in path(v) })
        }

        mutating func strut(_ a: SIMD3<Float>, _ c: SIMD3<Float>, radius: Float) {
            tube(along: 1, around: 6, path: { a + (c - a) * $0 }, radius: { _, _ in radius })
        }

        mutating func ellipsoid(center: SIMD3<Float>, radii: SIMD3<Float>, around: Int, along: Int) {
            surface(around: around, along: along, position: { u, v in
                let theta = v * .pi, phi = u * 2 * .pi
                return center + SIMD3(sin(theta) * cos(phi), -cos(theta), sin(theta) * sin(phi)) * radii
            }, axis: { _, _ in center })
        }

        mutating func box(center: SIMD3<Float>, size: SIMD3<Float>) {
            let h = size / 2
            let faces: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = [
                (SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)),
                (SIMD3(-1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)),
                (SIMD3(0, 1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 1)),
                (SIMD3(0, -1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 1)),
                (SIMD3(0, 0, 1), SIMD3(1, 0, 0), SIMD3(0, 1, 0)),
                (SIMD3(0, 0, -1), SIMD3(1, 0, 0), SIMD3(0, 1, 0))
            ]
            for (n, a, b) in faces {
                let base = UInt32(vertices.count / 6)
                for (sa, sb) in [(Float(-1), Float(-1)), (1, -1), (1, 1), (-1, 1)] {
                    let p = center + n * h + a * h * sa + b * h * sb
                    vertices.append(contentsOf: [p.x, p.y, p.z, n.x, n.y, n.z])
                }
                indices.append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3])
            }
        }

        /// A lumpy leaf cloud: a sphere pushed out by layered noise.
        mutating func foliage(center: SIMD3<Float>, radius: Float, seed: Float) {
            surface(around: 18, along: 12, position: { u, v in
                let theta = v * .pi, phi = u * 2 * .pi
                let dir = SIMD3<Float>(sin(theta) * cos(phi), -cos(theta), sin(theta) * sin(phi))
                let lump = 0.22 * sin(dir.x * 6 + seed) * sin(dir.z * 5 - seed)
                    + 0.14 * sin(dir.y * 9 + seed * 2)
                let squash = SIMD3<Float>(1.15, 0.7, 1.0)
                return center + dir * squash * radius * (1 + lump)
            }, axis: { _, _ in center })
        }

        func mesh(allocator: MTKMeshBufferAllocator) -> MDLMesh {
            let vertexBuffer = allocator.newBuffer(
                with: Data(bytes: vertices, count: vertices.count * MemoryLayout<Float>.size), type: .vertex
            )
            let indexBuffer = allocator.newBuffer(
                with: Data(bytes: indices, count: indices.count * MemoryLayout<UInt32>.size), type: .index
            )
            let submesh = MDLSubmesh(
                indexBuffer: indexBuffer, indexCount: indices.count, indexType: .uInt32,
                geometryType: .triangles, material: nil
            )
            let descriptor = MDLVertexDescriptor()
            descriptor.attributes[0] = MDLVertexAttribute(
                name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0
            )
            descriptor.attributes[1] = MDLVertexAttribute(
                name: MDLVertexAttributeNormal, format: .float3, offset: 12, bufferIndex: 0
            )
            descriptor.layouts[0] = MDLVertexBufferLayout(stride: 24)
            return MDLMesh(
                vertexBuffer: vertexBuffer, vertexCount: vertices.count / 6,
                descriptor: descriptor, submeshes: [submesh]
            )
        }
    }

    private static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
