// swiftlint:disable file_length
@preconcurrency import ARKit
import Combine
import CoreVideo
import Foundation
import ModelIO
import QuartzCore
import SceneKit
import SceneKit.ModelIO
import simd
import UIKit

// MARK: - Shapes, Materials & Motion

enum ARObjectShape: UInt32, CaseIterable, Identifiable, Codable, Sendable {
    case icosahedron = 0
    case box = 1
    case cone = 2
    case cylinder = 3
    case ellipsoid = 4
    case sphere = 5
    case plate = 6
    case torus = 7
    case capsule = 8
    case prism = 9
    case hemisphere = 10
    case ring = 11
    case spike = 12
    case slab = 13
    case baby = 14
    case melissa = 15
    case torusKnot = 16
    case octahedron = 17
    case tetrahedron = 18
    case pyramid = 19
    case stellated = 20
    case helix = 21
    case mobius = 22
    case gyroscope = 23
    case crystal = 24
    case waveGrid = 25
    case asteroid = 26
    case vase = 27
    case pear = 28
    case column = 29
    case screw = 30
    case dna = 31
    case spaceFrame = 32
    case oliveTree = 33
    case interchange = 34

    var id: UInt32 {
        rawValue
    }

    var label: String {
        switch self {
        case .icosahedron: "ICOSAHEDRON"
        case .box: "CUBE"
        case .cone: "CONE"
        case .cylinder: "CYLINDER"
        case .ellipsoid: "ELLIPSOID"
        case .sphere: "SPHERE"
        case .plate: "PLATE"
        case .torus: "TORUS"
        case .capsule: "CAPSULE"
        case .prism: "PRISM"
        case .hemisphere: "HEMISPHERE"
        case .ring: "RING"
        case .spike: "SPIKE"
        case .slab: "SLAB"
        case .baby: "BABY.SCAN"
        case .melissa: "MELISSA.SCAN"
        case .torusKnot: "TORUS KNOT"
        case .octahedron: "OCTAHEDRON"
        case .tetrahedron: "TETRAHEDRON"
        case .pyramid: "PYRAMID"
        case .stellated: "STARBURST"
        case .helix: "HELIX"
        case .mobius: "MOBIUS"
        case .gyroscope: "GYROSCOPE"
        case .crystal: "CRYSTAL"
        case .waveGrid: "WAVE MESH"
        case .asteroid: "ASTEROID"
        case .vase: "VASE"
        case .pear: "PEAR"
        case .column: "COLUMN"
        case .screw: "SCREW"
        case .dna: "DNA"
        case .spaceFrame: "SPACE FRAME"
        case .oliveTree: "OLIVE TREE"
        case .interchange: "INTERCHANGE"
        }
    }

    var shortLabel: String {
        switch self {
        case .icosahedron: "Icosa"
        case .box: "Cube"
        case .cone: "Cone"
        case .cylinder: "Cylinder"
        case .ellipsoid: "Ellipsoid"
        case .sphere: "Sphere"
        case .plate: "Plate"
        case .torus: "Torus"
        case .capsule: "Capsule"
        case .prism: "Prism"
        case .hemisphere: "Dome"
        case .ring: "Ring"
        case .spike: "Obelisk"
        case .slab: "Monolith"
        case .baby: "Bust"
        case .melissa: "Relic"
        case .torusKnot: "Knot"
        case .octahedron: "Octa"
        case .tetrahedron: "Tetra"
        case .pyramid: "Pyramid"
        case .stellated: "Star"
        case .helix: "Helix"
        case .mobius: "Mobius"
        case .gyroscope: "Gyro"
        case .crystal: "Crystal"
        case .waveGrid: "Wave"
        case .asteroid: "Asteroid"
        case .vase: "Vase"
        case .pear: "Pear"
        case .column: "Column"
        case .screw: "Screw"
        case .dna: "DNA"
        case .spaceFrame: "Frame"
        case .oliveTree: "Olive"
        case .interchange: "Overpass"
        }
    }

    var detail: String {
        switch self {
        case .icosahedron: "20-FACE GEODESIC POLYHEDRON"
        case .box: "ORTHOGONAL HEXAHEDRON"
        case .cone: "RADIAL TAPERED CONE"
        case .cylinder: "EXTRUDED RADIAL COLUMN"
        case .ellipsoid: "PROLATE HARMONIC SPHEROID"
        case .sphere: "ISOTROPIC ORB"
        case .plate: "CHAMFERED FLOATING SLATE"
        case .torus: "REVOLVED ORBITAL DOUGHNUT"
        case .capsule: "HEMISPHERIC PILL VESSEL"
        case .prism: "SIX-SIDED FACETED COLUMN"
        case .hemisphere: "HALF-SPHERE POLAR DOME"
        case .ring: "RAZOR ORBITAL HALO"
        case .spike: "NEEDLE OBELISK SPIRE"
        case .slab: "TALL ARCHITECTURAL MONOLITH"
        case .baby: "SCULPTED CRANIAL BUST"
        case .melissa: "TWISTED ARTIFACT RELIC"
        case .torusKnot: "TREFOIL (2,3) KNOTTED TUBE"
        case .octahedron: "DUAL BI-PYRAMID DIAMOND"
        case .tetrahedron: "FOUR-FACE PLATONIC SIMPLEX"
        case .pyramid: "SQUARE-BASE APEX MONUMENT"
        case .stellated: "TWELVE-POINT STELLATED STAR"
        case .helix: "TORSIONAL SPIRAL COIL"
        case .mobius: "NON-ORIENTABLE TWISTED RIBBON"
        case .gyroscope: "TRIPLE ORTHOGONAL GIMBAL"
        case .crystal: "DOUBLE-TERMINATED QUARTZ"
        case .waveGrid: "SINUSOIDAL TOPOGRAPHIC SHEET"
        case .asteroid: "CRATERED FRACTAL METEOROID"
        case .vase: "STILL-LIFE AMPHORA"
        case .pear: "STILL-LIFE PEAR WITH LEAF"
        case .column: "FLUTED DORIC COLUMN"
        case .screw: "THREADED COUNTERSUNK SCREW"
        case .dna: "DOUBLE HELIX WITH BASE PAIRS"
        case .spaceFrame: "ARCHED STEEL SPACE FRAME"
        case .oliveTree: "WINDSWEPT OLIVE ON EARTH"
        case .interchange: "THREE-DECK HIGHWAY KNOT"
        }
    }

    var symbol: String {
        switch self {
        case .icosahedron: "hexagon"
        case .box: "cube"
        case .cone: "cone"
        case .cylinder: "cylinder"
        case .ellipsoid: "oval"
        case .sphere: "globe"
        case .plate: "rectangle"
        case .torus: "circle.circle"
        case .capsule: "capsule"
        case .prism: "triangle.lefthalf.filled"
        case .hemisphere: "circle.tophalf.filled"
        case .ring: "circle"
        case .spike: "arrowtriangle.up"
        case .slab: "rectangle.portrait"
        case .baby: "person.bust"
        case .melissa: "crown"
        case .torusKnot: "infinity"
        case .octahedron: "suit.diamond"
        case .tetrahedron: "triangle"
        case .pyramid: "pyramid"
        case .stellated: "sparkles"
        case .helix: "hurricane"
        case .mobius: "tornado"
        case .gyroscope: "gyroscope"
        case .crystal: "rhombus"
        case .waveGrid: "squareshape.split.3x3"
        case .asteroid: "aqi.medium"
        case .vase: "vase"
        case .pear: "leaf"
        case .column: "building.columns"
        case .screw: "screwdriver"
        case .dna: "allergens"
        case .spaceFrame: "square.grid.3x3.topleft.filled"
        case .oliveTree: "tree"
        case .interchange: "road.lanes"
        }
    }
}

enum ARObjectMaterialMode: UInt32, CaseIterable, Identifiable, Codable, Sendable {
    case solidRim = 0
    case wireframe = 1
    case hologram = 2
    case chrome = 3
    case iridescent = 4
    case xray = 5
    case plasma = 6
    case celToon = 7

    var id: UInt32 { rawValue }

    var label: String {
        switch self {
        case .solidRim: "Solid"
        case .wireframe: "Wire"
        case .hologram: "Holo"
        case .chrome: "Chrome"
        case .iridescent: "Prism"
        case .xray: "X-Ray"
        case .plasma: "Plasma"
        case .celToon: "Toon"
        }
    }

    var symbol: String {
        switch self {
        case .solidRim: "circle.lefthalf.filled"
        case .wireframe: "network"
        case .hologram: "waveform.path.ecg.rectangle"
        case .chrome: "sparkles"
        case .iridescent: "rainbow"
        case .xray: "rays"
        case .plasma: "flame"
        case .celToon: "paintbrush.pointed"
        }
    }
}

enum ARObjectSpinAxis: String, CaseIterable, Identifiable, Codable, Sendable {
    case yaw
    case pitch
    case roll
    case tumble
    case none

    var id: String { rawValue }

    var label: String {
        switch self {
        case .yaw: "Yaw Y"
        case .pitch: "Pitch X"
        case .roll: "Roll Z"
        case .tumble: "Tumble"
        case .none: "Static"
        }
    }
}

enum ARObjectPhysicsMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case float
    case orbit
    case gravity
    case anchored

    var id: String { rawValue }

    var label: String {
        switch self {
        case .float: "Float"
        case .orbit: "Orbit"
        case .gravity: "Gravity"
        case .anchored: "Locked"
        }
    }

    var symbol: String {
        switch self {
        case .float: "wind"
        case .orbit: "atom"
        case .gravity: "hurricane.circle"
        case .anchored: "pin"
        }
    }
}

enum ARObjectSpawnSource: Equatable, Hashable, Sendable {
    case cycle
    case random
    case shape(ARObjectShape)
    case userModel(UUID)

    var label: String {
        switch self {
        case .cycle: "Cycle"
        case .random: "Random"
        case let .shape(shape): shape.shortLabel
        case .userModel: "Custom"
        }
    }
}

// MARK: - User 3D Model Library

struct ARUserModel: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    let fileName: String
    let fileExtension: String
    let vertexCount: Int
    let submeshCount: Int
    let importedAt: Date
    /// Lightweight 3D wireframe points & edge pairs for browser tile previews.
    var previewVertices: [[Float]] = []
    var previewEdges: [[Int]] = []

    var detail: String {
        let verts = vertexCount >= 1_000
            ? String(format: "%.1fk VERTS", Double(vertexCount) / 1_000.0)
            : "\(vertexCount) VERTS"
        return "\(fileExtension.uppercased()) // \(verts) · \(max(submeshCount, 1)) MESH"
    }
}

enum ARUserModelImportError: LocalizedError, Equatable, Sendable {
    case unsupportedFormat(String)
    case unreadableAsset
    case noMeshGeometry
    case storageFailed

    var errorDescription: String? {
        switch self {
        case let .unsupportedFormat(ext):
            "Unsupported 3D format (\(ext.uppercased())). Use USDZ, OBJ, STL, PLY, ABC, SCN, or DAE."
        case .unreadableAsset:
            "Could not read 3D model file."
        case .noMeshGeometry:
            "File contains no 3D triangle mesh geometry."
        case .storageFailed:
            "Could not save 3D model to library."
        }
    }
}

final class ARUserModelStore: @unchecked Sendable {
    static let shared = ARUserModelStore()

    static let supportedExtensions: Set<String> = [
        "usdz", "usd", "usda", "usdc", "obj", "stl", "ply", "abc", "scn", "dae"
    ]

    let directoryURL: URL
    private let manifestURL: URL
    private let lock = NSLock()

    init(directoryURL: URL? = nil) {
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.directoryURL = base
                .appendingPathComponent("GreyVision", isDirectory: true)
                .appendingPathComponent("ARModels", isDirectory: true)
        }
        manifestURL = self.directoryURL.appendingPathComponent("manifest.json")
        try? FileManager.default.createDirectory(at: self.directoryURL, withIntermediateDirectories: true)
    }

    func loadModels() -> [ARUserModel] {
        lock.withLock {
            guard let data = try? Data(contentsOf: manifestURL),
                  let decoded = try? JSONDecoder().decode([ARUserModel].self, from: data)
            else {
                return []
            }
            return decoded.filter { model in
                FileManager.default.fileExists(atPath: fileURL(for: model).path)
            }
        }
    }

    func fileURL(for model: ARUserModel) -> URL {
        directoryURL.appendingPathComponent(model.fileName)
    }

    func fileURL(for id: UUID) -> URL? {
        guard let model = loadModels().first(where: { $0.id == id }) else { return nil }
        return fileURL(for: model)
    }

    func importModel(from sourceURL: URL, customName: String? = nil) throws -> ARUserModel {
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if scoped { sourceURL.stopAccessingSecurityScopedResource() }
        }

        let ext = sourceURL.pathExtension.lowercased()
        guard Self.supportedExtensions.contains(ext) else {
            throw ARUserModelImportError.unsupportedFormat(ext.isEmpty ? "unknown" : ext)
        }

        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let id = UUID()
        let fileName = "\(id.uuidString).\(ext)"
        let destinationURL = directoryURL.appendingPathComponent(fileName)

        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        } catch {
            throw ARUserModelImportError.storageFailed
        }

        guard let summary = Self.inspectMesh(at: destinationURL), summary.vertexCount > 0 else {
            try? FileManager.default.removeItem(at: destinationURL)
            throw ARUserModelImportError.noMeshGeometry
        }

        let rawTitle = (customName ?? sourceURL.deletingPathExtension().lastPathComponent)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = rawTitle.isEmpty ? "MODEL.\(id.uuidString.prefix(4))" : rawTitle

        let model = ARUserModel(
            id: id,
            name: displayName,
            fileName: fileName,
            fileExtension: ext,
            vertexCount: summary.vertexCount,
            submeshCount: summary.submeshCount,
            importedAt: Date(),
            previewVertices: summary.previewVertices,
            previewEdges: summary.previewEdges
        )

        lock.withLock {
            var current = loadUnlocked()
            current.insert(model, at: 0)
            saveUnlocked(current)
        }
        return model
    }

    /// Creates a procedural custom `.obj` sculpture on disk and imports it,
    /// giving creators a ready-to-customize user model or a template they can
    /// inspect and replace.
    func createProceduralSampleModel(named name: String = "Hyperbolic Relic") throws -> ARUserModel {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).obj")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let objText = Self.generateSampleOBJ()
        try objText.write(to: tempURL, atomically: true, encoding: .utf8)
        return try importModel(from: tempURL, customName: name)
    }

    func renameModel(id: UUID, to newName: String) -> [ARUserModel] {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return loadModels() }
        return lock.withLock {
            var current = loadUnlocked()
            if let index = current.firstIndex(where: { $0.id == id }) {
                current[index].name = trimmed
                saveUnlocked(current)
            }
            return current
        }
    }

    func deleteModel(id: UUID) -> [ARUserModel] {
        lock.withLock {
            var current = loadUnlocked()
            if let index = current.firstIndex(where: { $0.id == id }) {
                let removed = current.remove(at: index)
                let url = directoryURL.appendingPathComponent(removed.fileName)
                try? FileManager.default.removeItem(at: url)
                saveUnlocked(current)
            }
            return current
        }
    }

    private func loadUnlocked() -> [ARUserModel] {
        guard let data = try? Data(contentsOf: manifestURL),
              let decoded = try? JSONDecoder().decode([ARUserModel].self, from: data)
        else {
            return []
        }
        return decoded.filter { model in
            FileManager.default.fileExists(atPath: directoryURL.appendingPathComponent(model.fileName).path)
        }
    }

    private func saveUnlocked(_ models: [ARUserModel]) {
        guard let data = try? JSONEncoder().encode(models) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }

    // MARK: Mesh Extraction & Preview Silhouette

    struct MeshInspection {
        let vertexCount: Int
        let submeshCount: Int
        let previewVertices: [[Float]]
        let previewEdges: [[Int]]
    }

    static func loadAllMeshes(from url: URL, allocator: MDLMeshBufferAllocator? = nil) -> [MDLMesh] {
        let ext = url.pathExtension.lowercased()
        if ext == "scn" || ext == "dae" {
            if let scene = try? SCNScene(url: url, options: nil) {
                let asset = MDLAsset(scnScene: scene, bufferAllocator: allocator)
                let meshes = collectMeshes(in: asset)
                if !meshes.isEmpty { return meshes }
            }
        }
        let asset = MDLAsset(url: url, vertexDescriptor: nil, bufferAllocator: allocator)
        asset.loadTextures()
        let meshes = collectMeshes(in: asset)
        if !meshes.isEmpty { return meshes }

        if let scene = try? SCNScene(url: url, options: nil) {
            let fallbackAsset = MDLAsset(scnScene: scene, bufferAllocator: allocator)
            return collectMeshes(in: fallbackAsset)
        }
        return []
    }

    private static func collectMeshes(in asset: MDLAsset) -> [MDLMesh] {
        if let direct = asset.childObjects(of: MDLMesh.self) as? [MDLMesh], !direct.isEmpty {
            return direct
        }
        var found: [MDLMesh] = []
        for index in 0 ..< asset.count {
            collectMeshesRecursive(object: asset.object(at: index), into: &found)
        }
        return found
    }

    private static func collectMeshesRecursive(object: MDLObject, into result: inout [MDLMesh]) {
        if let mesh = object as? MDLMesh {
            result.append(mesh)
        }
        for child in object.children.objects {
            collectMeshesRecursive(object: child, into: &result)
        }
    }

    static func inspectMesh(at url: URL) -> MeshInspection? {
        let meshes = loadAllMeshes(from: url)
        guard !meshes.isEmpty else { return nil }
        var totalVertices = 0
        var totalSubmeshes = 0
        var sampledPoints: [SIMD3<Float>] = []

        for mesh in meshes {
            totalVertices += mesh.vertexCount
            totalSubmeshes += max(mesh.submeshes?.count ?? 1, 1)
            if let posAttr = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributePosition) {
                let count = mesh.vertexCount
                let step = max(1, count / 48)
                for idx in stride(from: 0, to: count, by: step) where sampledPoints.count < 64 {
                    let ptr = posAttr.dataStart.advanced(by: idx * posAttr.stride)
                        .assumingMemoryBound(to: Float.self)
                    sampledPoints.append(SIMD3<Float>(ptr[0], ptr[1], ptr[2]))
                }
            }
        }
        guard totalVertices > 0 else { return nil }

        // Normalize sampled points into [-0.5, 0.5] box for preview canvas
        var minB = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maxB = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for pt in sampledPoints {
            minB = simd_min(minB, pt)
            maxB = simd_max(maxB, pt)
        }
        let extent = maxB - minB
        let longest = max(extent.x, max(extent.y, extent.z), 0.0001)
        let center = (minB + maxB) * 0.5
        let normalized = sampledPoints.map { pt -> [Float] in
            let p = (pt - center) / longest
            return [p.x, p.y, p.z]
        }

        var edges: [[Int]] = []
        if normalized.count >= 2 {
            for i in 0 ..< (normalized.count - 1) {
                edges.append([i, i + 1])
                if i + 3 < normalized.count {
                    edges.append([i, i + 3])
                }
            }
            edges.append([normalized.count - 1, 0])
        }

        return MeshInspection(
            vertexCount: totalVertices,
            submeshCount: totalSubmeshes,
            previewVertices: normalized,
            previewEdges: edges
        )
    }

    private static func generateSampleOBJ() -> String {
        var lines = ["# greyVISION Procedural Sculpture OBJ"]
        let rings = 18
        let sides = 10
        for r in 0 ... rings {
            let t = Float(r) / Float(rings)
            let y = (t - 0.5) * 1.1
            let twist = t * .pi * 2.5
            let radius = 0.28 + 0.16 * sin(t * .pi * 3.0)
            for s in 0 ..< sides {
                let a = Float(s) / Float(sides) * .pi * 2.0 + twist
                let flare: Float = (s % 2 == 0) ? 1.18 : 0.84
                let x = cos(a) * radius * flare
                let z = sin(a) * radius * flare
                lines.append(String(format: "v %.4f %.4f %.4f", x, y, z))
            }
        }
        for r in 0 ..< rings {
            for s in 0 ..< sides {
                let nextS = (s + 1) % sides
                let i0 = r * sides + s + 1
                let i1 = r * sides + nextS + 1
                let i2 = (r + 1) * sides + nextS + 1
                let i3 = (r + 1) * sides + s + 1
                lines.append("f \(i0) \(i1) \(i2)")
                lines.append("f \(i0) \(i2) \(i3)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Descriptors & Parameters

/// Lifecycle of a direct-manipulation gesture, decoupled from UIKit so the
/// runtime does not depend on `UIGestureRecognizer`.
enum ARManipulationPhase: Sendable {
    case began
    case changed
    case ended
}

struct ARObjectDescriptor: Identifiable, Equatable, Sendable {
    let id: UUID
    var shape: ARObjectShape
    var userModelID: UUID?
    var position: SIMD3<Float>
    var scale: Float
    var stretch: SIMD3<Float>
    var orientationDegrees: SIMD3<Float>
    var spinSpeed: Float
    var spinAxis: ARObjectSpinAxis
    var bobAmplitude: Float
    var bobSpeed: Float
    var pulseAmount: Float
    var phase: Float
    var material: ARObjectMaterialMode
    var wire: Bool
    var tintIndex: Int
    var useCustomHue: Bool
    var customHue: Float
    var glow: Float
    var metallic: Float
    var rimSharpness: Float
    var opacity: Float
    var birthTime: TimeInterval
    /// Hidden constellation easter egg: when true, the object renders as a
    /// dark violet "black hole" that gravitationally pulls the others in.
    var isBlackHole: Bool

    init(
        id: UUID = UUID(),
        shape: ARObjectShape,
        userModelID: UUID? = nil,
        position: SIMD3<Float>,
        scale: Float,
        stretch: SIMD3<Float> = SIMD3<Float>(1, 1, 1),
        orientationDegrees: SIMD3<Float> = .zero,
        spinSpeed: Float,
        spinAxis: ARObjectSpinAxis = .yaw,
        bobAmplitude: Float = 0.05,
        bobSpeed: Float = 1.1,
        pulseAmount: Float = 0,
        phase: Float,
        material: ARObjectMaterialMode = .solidRim,
        wire: Bool,
        tintIndex: Int,
        useCustomHue: Bool = false,
        customHue: Float = 0.78,
        glow: Float = 0.9,
        metallic: Float = 0.35,
        rimSharpness: Float = 2.2,
        opacity: Float = 1.0,
        birthTime: TimeInterval,
        isBlackHole: Bool = false
    ) {
        self.id = id
        self.shape = shape
        self.userModelID = userModelID
        self.position = position
        self.scale = scale
        self.stretch = stretch
        self.orientationDegrees = orientationDegrees
        self.spinSpeed = spinSpeed
        self.spinAxis = spinAxis
        self.bobAmplitude = bobAmplitude
        self.bobSpeed = bobSpeed
        self.pulseAmount = pulseAmount
        self.phase = phase
        self.material = material
        self.wire = wire
        self.tintIndex = tintIndex
        self.useCustomHue = useCustomHue
        self.customHue = customHue
        self.glow = glow
        self.metallic = metallic
        self.rimSharpness = rimSharpness
        self.opacity = opacity
        self.birthTime = birthTime
        self.isBlackHole = isBlackHole
    }

    var displayTitle: String {
        if isBlackHole { return "SINGULARITY" }
        if userModelID != nil { return "CUSTOM.3D" }
        return shape.shortLabel.uppercased()
    }

    static let maxObjects = 24
}

struct ARObjectParameters: Codable, Equatable, Sendable {
    /// Object scale 0.2...2.5.
    var size: Double = 0.9
    /// Spin speed 0...3.
    var spin: Double = 0.6
    /// Emissive glow 0.0...2.2.
    var glow: Double = 0.9

    // Material & Surface
    var material: ARObjectMaterialMode = .solidRim
    var wireOverlay: Bool = false
    var tintIndex: Int = 0
    var useCustomHue: Bool = false
    var customHue: Double = 0.78
    var metallic: Double = 0.35
    var rimSharpness: Double = 2.2
    var opacity: Double = 1.0

    // Transform & Geometry
    var stretchX: Double = 1.0
    var stretchY: Double = 1.0
    var stretchZ: Double = 1.0
    var pitchDegrees: Double = 0.0
    var yawDegrees: Double = 0.0
    var rollDegrees: Double = 0.0
    var spawnDistance: Double = 1.3
    var heightOffset: Double = 0.0

    // Motion & Physics
    var spinAxis: ARObjectSpinAxis = .yaw
    var bobAmplitude: Double = 0.05
    var bobSpeed: Double = 1.1
    var pulseAmount: Double = 0.0
    var orbitSpeed: Double = 0.35
    var audioReactivity: Double = 0.0
    var physicsMode: ARObjectPhysicsMode = .float

    static let defaults = ARObjectParameters()

    init(
        size: Double = 0.9,
        spin: Double = 0.6,
        glow: Double = 0.9,
        material: ARObjectMaterialMode = .solidRim,
        wireOverlay: Bool = false,
        tintIndex: Int = 0,
        useCustomHue: Bool = false,
        customHue: Double = 0.78,
        metallic: Double = 0.35,
        rimSharpness: Double = 2.2,
        opacity: Double = 1.0,
        stretchX: Double = 1.0,
        stretchY: Double = 1.0,
        stretchZ: Double = 1.0,
        pitchDegrees: Double = 0.0,
        yawDegrees: Double = 0.0,
        rollDegrees: Double = 0.0,
        spawnDistance: Double = 1.3,
        heightOffset: Double = 0.0,
        spinAxis: ARObjectSpinAxis = .yaw,
        bobAmplitude: Double = 0.05,
        bobSpeed: Double = 1.1,
        pulseAmount: Double = 0.0,
        orbitSpeed: Double = 0.35,
        audioReactivity: Double = 0.0,
        physicsMode: ARObjectPhysicsMode = .float
    ) {
        self.size = size
        self.spin = spin
        self.glow = glow
        self.material = material
        self.wireOverlay = wireOverlay
        self.tintIndex = tintIndex
        self.useCustomHue = useCustomHue
        self.customHue = customHue
        self.metallic = metallic
        self.rimSharpness = rimSharpness
        self.opacity = opacity
        self.stretchX = stretchX
        self.stretchY = stretchY
        self.stretchZ = stretchZ
        self.pitchDegrees = pitchDegrees
        self.yawDegrees = yawDegrees
        self.rollDegrees = rollDegrees
        self.spawnDistance = spawnDistance
        self.heightOffset = heightOffset
        self.spinAxis = spinAxis
        self.bobAmplitude = bobAmplitude
        self.bobSpeed = bobSpeed
        self.pulseAmount = pulseAmount
        self.orbitSpeed = orbitSpeed
        self.audioReactivity = audioReactivity
        self.physicsMode = physicsMode
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.defaults
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? d.size
        spin = try c.decodeIfPresent(Double.self, forKey: .spin) ?? d.spin
        glow = try c.decodeIfPresent(Double.self, forKey: .glow) ?? d.glow
        material = try c.decodeIfPresent(ARObjectMaterialMode.self, forKey: .material) ?? d.material
        wireOverlay = try c.decodeIfPresent(Bool.self, forKey: .wireOverlay) ?? d.wireOverlay
        tintIndex = try c.decodeIfPresent(Int.self, forKey: .tintIndex) ?? d.tintIndex
        useCustomHue = try c.decodeIfPresent(Bool.self, forKey: .useCustomHue) ?? d.useCustomHue
        customHue = try c.decodeIfPresent(Double.self, forKey: .customHue) ?? d.customHue
        metallic = try c.decodeIfPresent(Double.self, forKey: .metallic) ?? d.metallic
        rimSharpness = try c.decodeIfPresent(Double.self, forKey: .rimSharpness) ?? d.rimSharpness
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? d.opacity
        stretchX = try c.decodeIfPresent(Double.self, forKey: .stretchX) ?? d.stretchX
        stretchY = try c.decodeIfPresent(Double.self, forKey: .stretchY) ?? d.stretchY
        stretchZ = try c.decodeIfPresent(Double.self, forKey: .stretchZ) ?? d.stretchZ
        pitchDegrees = try c.decodeIfPresent(Double.self, forKey: .pitchDegrees) ?? d.pitchDegrees
        yawDegrees = try c.decodeIfPresent(Double.self, forKey: .yawDegrees) ?? d.yawDegrees
        rollDegrees = try c.decodeIfPresent(Double.self, forKey: .rollDegrees) ?? d.rollDegrees
        spawnDistance = try c.decodeIfPresent(Double.self, forKey: .spawnDistance) ?? d.spawnDistance
        heightOffset = try c.decodeIfPresent(Double.self, forKey: .heightOffset) ?? d.heightOffset
        spinAxis = try c.decodeIfPresent(ARObjectSpinAxis.self, forKey: .spinAxis) ?? d.spinAxis
        bobAmplitude = try c.decodeIfPresent(Double.self, forKey: .bobAmplitude) ?? d.bobAmplitude
        bobSpeed = try c.decodeIfPresent(Double.self, forKey: .bobSpeed) ?? d.bobSpeed
        pulseAmount = try c.decodeIfPresent(Double.self, forKey: .pulseAmount) ?? d.pulseAmount
        orbitSpeed = try c.decodeIfPresent(Double.self, forKey: .orbitSpeed) ?? d.orbitSpeed
        audioReactivity = try c.decodeIfPresent(Double.self, forKey: .audioReactivity) ?? d.audioReactivity
        physicsMode = try c.decodeIfPresent(ARObjectPhysicsMode.self, forKey: .physicsMode) ?? d.physicsMode
    }

    var sanitized: ARObjectParameters {
        func clamp(_ value: Double, _ range: ClosedRange<Double>, fallback: Double) -> Double {
            guard value.isFinite else { return fallback }
            return min(max(value, range.lowerBound), range.upperBound)
        }
        let d = Self.defaults
        return ARObjectParameters(
            size: clamp(size, 0.2 ... 2.5, fallback: d.size),
            spin: clamp(spin, 0 ... 3.0, fallback: d.spin),
            glow: clamp(glow, 0.0 ... 2.2, fallback: d.glow),
            material: material,
            wireOverlay: wireOverlay,
            tintIndex: max(0, min(tintIndex, ARObjectPalette.colors.count - 1)),
            useCustomHue: useCustomHue,
            customHue: clamp(customHue, 0 ... 1, fallback: d.customHue),
            metallic: clamp(metallic, 0 ... 1, fallback: d.metallic),
            rimSharpness: clamp(rimSharpness, 0.5 ... 5.0, fallback: d.rimSharpness),
            opacity: clamp(opacity, 0.15 ... 1.0, fallback: d.opacity),
            stretchX: clamp(stretchX, 0.25 ... 2.5, fallback: d.stretchX),
            stretchY: clamp(stretchY, 0.25 ... 2.5, fallback: d.stretchY),
            stretchZ: clamp(stretchZ, 0.25 ... 2.5, fallback: d.stretchZ),
            pitchDegrees: clamp(pitchDegrees, -180 ... 180, fallback: d.pitchDegrees),
            yawDegrees: clamp(yawDegrees, -180 ... 180, fallback: d.yawDegrees),
            rollDegrees: clamp(rollDegrees, -180 ... 180, fallback: d.rollDegrees),
            spawnDistance: clamp(spawnDistance, 0.4 ... 4.0, fallback: d.spawnDistance),
            heightOffset: clamp(heightOffset, -1.0 ... 1.0, fallback: d.heightOffset),
            spinAxis: spinAxis,
            bobAmplitude: clamp(bobAmplitude, 0 ... 0.35, fallback: d.bobAmplitude),
            bobSpeed: clamp(bobSpeed, 0 ... 4.0, fallback: d.bobSpeed),
            pulseAmount: clamp(pulseAmount, 0 ... 0.8, fallback: d.pulseAmount),
            orbitSpeed: clamp(orbitSpeed, 0 ... 2.0, fallback: d.orbitSpeed),
            audioReactivity: clamp(audioReactivity, 0 ... 1.0, fallback: d.audioReactivity),
            physicsMode: physicsMode
        )
    }
}

enum ARObjectPalette {
    /// The splash film's still-life colours.
    static let names: [String] = [
        "Cobalt", "Steel", "Green", "Vermilion", "Ocean", "Terracotta", "Olive", "Porcelain"
    ]

    static let colors: [SIMD3<Float>] = [
        SIMD3(0.25, 0.38, 0.92), // cobalt lattice
        SIMD3(0.58, 0.64, 0.74), // chrome steel
        SIMD3(0.36, 0.86, 0.52), // terminal green
        SIMD3(0.93, 0.28, 0.16), // vermilion sphere
        SIMD3(0.12, 0.30, 0.55), // ocean
        SIMD3(0.74, 0.44, 0.30), // terracotta earth
        SIMD3(0.56, 0.62, 0.32), // olive leaf
        SIMD3(0.93, 0.92, 0.89) // porcelain
    ]

    static func rgb(forHue hue: Float) -> SIMD3<Float> {
        let h = (hue.truncatingRemainder(dividingBy: 1.0) + 1.0).truncatingRemainder(dividingBy: 1.0) * 6.0
        let c: Float = 0.88
        let x = c * (1.0 - abs(h.truncatingRemainder(dividingBy: 2.0) - 1.0))
        let m: Float = 0.12
        let raw: SIMD3<Float> = switch Int(h) {
        case 0: SIMD3(c, x, 0)
        case 1: SIMD3(x, c, 0)
        case 2: SIMD3(0, c, x)
        case 3: SIMD3(0, x, c)
        case 4: SIMD3(x, 0, c)
        default: SIMD3(c, 0, x)
        }
        return raw + SIMD3(repeating: m)
    }

    static func resolveTint(for object: ARObjectDescriptor) -> SIMD3<Float> {
        if object.useCustomHue {
            return rgb(forHue: object.customHue)
        }
        let idx = ((object.tintIndex % colors.count) + colors.count) % colors.count
        return colors[idx]
    }
}

// MARK: - Curated Scene Presets

struct GVObjectPreset: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let detail: String
    let symbol: String
    let shapes: [ARObjectShape]
    let parameters: ARObjectParameters

    static let all: [GVObjectPreset] = [
        GVObjectPreset(
            id: "constellation",
            name: "Constellation",
            detail: "Emissive rim polyhedra & alternating wireframe lattice",
            symbol: "sparkles",
            shapes: [.icosahedron, .torus, .octahedron, .sphere, .crystal],
            parameters: ARObjectParameters(
                size: 0.9, spin: 0.6, glow: 0.95, material: .solidRim, wireOverlay: true,
                tintIndex: 0, metallic: 0.4, rimSharpness: 2.2
            ).sanitized
        ),
        GVObjectPreset(
            id: "hologram_lattice",
            name: "Holo Lattice",
            detail: "Scanline phase projection over knotted geometry",
            symbol: "waveform.path.ecg.rectangle",
            shapes: [.torusKnot, .gyroscope, .icosahedron, .helix, .mobius],
            parameters: ARObjectParameters(
                size: 0.95, spin: 0.85, glow: 1.35, material: .hologram, wireOverlay: false,
                tintIndex: 4, metallic: 0.25, rimSharpness: 1.8, opacity: 0.88,
                spinAxis: .tumble, pulseAmount: 0.12
            ).sanitized
        ),
        GVObjectPreset(
            id: "liquid_chrome",
            name: "Liquid Chrome",
            detail: "Studio-reflected metallic forms in slow orbital drift",
            symbol: "circle.hexagongrid.fill",
            shapes: [.torusKnot, .sphere, .mobius, .torus, .capsule],
            parameters: ARObjectParameters(
                size: 1.0, spin: 0.5, glow: 0.75, material: .chrome, wireOverlay: false,
                tintIndex: 1, metallic: 0.92, rimSharpness: 2.8,
                spinAxis: .yaw, orbitSpeed: 0.45, physicsMode: .orbit
            ).sanitized
        ),
        GVObjectPreset(
            id: "monolith_array",
            name: "Monolith Array",
            detail: "Tall architectural slabs, obelisks & pyramids",
            symbol: "rectangle.portrait.fill",
            shapes: [.slab, .spike, .pyramid, .prism, .plate],
            parameters: ARObjectParameters(
                size: 1.15, spin: 0.22, glow: 1.1, material: .solidRim, wireOverlay: false,
                tintIndex: 7, metallic: 0.65, rimSharpness: 3.1, stretchY: 1.35,
                spinAxis: .yaw, bobAmplitude: 0.02, bobSpeed: 0.6
            ).sanitized
        ),
        GVObjectPreset(
            id: "iridescent_prism",
            name: "Spectral Prism",
            detail: "Thin-film iridescent crystals & stellated stars",
            symbol: "rainbow",
            shapes: [.crystal, .stellated, .octahedron, .prism, .gyroscope],
            parameters: ARObjectParameters(
                size: 0.95, spin: 0.75, glow: 1.15, material: .iridescent, wireOverlay: false,
                tintIndex: 5, metallic: 0.78, rimSharpness: 2.0,
                spinAxis: .tumble, pulseAmount: 0.08
            ).sanitized
        ),
        GVObjectPreset(
            id: "plasma_core",
            name: "Plasma Artifacts",
            detail: "3D gyroidal thermal veins with audio-reactive pulse",
            symbol: "flame.fill",
            shapes: [.stellated, .asteroid, .torusKnot, .helix, .icosahedron],
            parameters: ARObjectParameters(
                size: 1.0, spin: 0.95, glow: 1.45, material: .plasma, wireOverlay: false,
                tintIndex: 3, metallic: 0.3, rimSharpness: 1.9,
                spinAxis: .tumble, pulseAmount: 0.18, audioReactivity: 0.65
            ).sanitized
        ),
        GVObjectPreset(
            id: "xray_specimens",
            name: "X-Ray Specimens",
            detail: "Translucent energy shells over Relic & Bust scans",
            symbol: "rays",
            shapes: [.baby, .melissa, .gyroscope, .helix, .waveGrid],
            parameters: ARObjectParameters(
                size: 1.05, spin: 0.45, glow: 1.3, material: .xray, wireOverlay: false,
                tintIndex: 2, metallic: 0.2, rimSharpness: 1.6, opacity: 0.82
            ).sanitized
        ),
        GVObjectPreset(
            id: "cel_pop",
            name: "Cel Construct",
            detail: "Hard-stepped toon shading with ink contour edges",
            symbol: "paintbrush.pointed.fill",
            shapes: [.octahedron, .torus, .box, .cone, .tetrahedron],
            parameters: ARObjectParameters(
                size: 0.95, spin: 0.65, glow: 0.55, material: .celToon, wireOverlay: false,
                tintIndex: 6, metallic: 0.5, rimSharpness: 2.4
            ).sanitized
        ),
        GVObjectPreset(
            id: "still_life",
            name: "Still Life",
            detail: "Porcelain vase, pear and column under studio light",
            symbol: "vase",
            shapes: [.vase, .pear, .column, .sphere, .box],
            parameters: ARObjectParameters(
                size: 1.0, spin: 0.18, glow: 0.45, material: .solidRim, wireOverlay: false,
                tintIndex: 7, metallic: 0.35, rimSharpness: 2.6,
                spinAxis: .yaw
            ).sanitized
        ),
        GVObjectPreset(
            id: "splash_specimens",
            name: "Specimens",
            detail: "The splash film's chrome screw, helix, frame, olive and overpass",
            symbol: "allergens",
            shapes: [.screw, .dna, .spaceFrame, .oliveTree, .interchange],
            parameters: ARObjectParameters(
                size: 1.1, spin: 0.35, glow: 0.8, material: .chrome, wireOverlay: false,
                tintIndex: 1, metallic: 0.9, rimSharpness: 2.6,
                spinAxis: .yaw, bobAmplitude: 0.015, bobSpeed: 0.5
            ).sanitized
        )
    ]

    static func matching(_ parameters: ARObjectParameters) -> GVObjectPreset? {
        all.first { $0.parameters == parameters.sanitized }
    }
}

// MARK: - Capability & State

struct ARObjectCapability: Equatable, Sendable {
    let isSupported: Bool
    let isSynthetic: Bool
    let reason: String

    init(isSupported: Bool, isSynthetic: Bool = false, reason: String) {
        self.isSupported = isSupported
        self.isSynthetic = isSynthetic
        self.reason = reason
    }

    static func discover() -> ARObjectCapability {
        #if targetEnvironment(simulator)
            return ARObjectCapability(
                isSupported: true,
                isSynthetic: true,
                reason: "SYNTHETIC AR STAGE"
            )
        #else
            guard ARWorldTrackingConfiguration.isSupported else {
                return ARObjectCapability(
                    isSupported: false,
                    isSynthetic: false,
                    reason: "WORLD TRACKING IS NOT SUPPORTED"
                )
            }
            return ARObjectCapability(
                isSupported: true,
                isSynthetic: false,
                reason: "WORLD TRACKING READY"
            )
        #endif
    }
}

enum ARObjectRecordingState: Equatable, Sendable {
    case idle
    case recording
    case finalizing
    case saved
    case failed(String)

    var label: String {
        switch self {
        case .idle: "IDLE"
        case .recording: "REC"
        case .finalizing: "SAVING"
        case .saved: "SAVED"
        case let .failed(message): "FAILED \(message)"
        }
    }
}

enum ARObjectRuntimeState: String, Equatable, Sendable {
    case idle
    case starting
    case running
    case interrupted
    case unsupported
    case failed

    var label: String {
        rawValue.uppercased()
    }
}

struct ARObjectSnapshot: Equatable, Sendable {
    var state: ARObjectRuntimeState
    var sourceLabel: String
    var formatLabel: String
    var objectCount: Int
    var orientation: CapturedFrameOrientation
    var errorMessage: String?

    static let idle = ARObjectSnapshot(
        state: .idle,
        sourceLabel: "AR OBJECTS OFFLINE",
        formatLabel: "NO WORLD TRACKING",
        objectCount: 0,
        orientation: .portrait,
        errorMessage: nil
    )
}

// MARK: - Frame transport

struct ARObjectFrame: @unchecked Sendable {
    let capturedImage: CVPixelBuffer
    let camera: ARCamera?
    let cameraTransform: simd_float4x4
    let orientation: CapturedFrameOrientation
    let timestamp: TimeInterval
    /// Metres from the camera per pixel, from LiDAR. Nil without a scanner.
    let sceneDepth: CVPixelBuffer?
    /// Metres to people in frame, and the mask of where they are. Nil where
    /// the device cannot segment people.
    let personDepth: CVPixelBuffer?
    let personMask: CVPixelBuffer?
    /// ARKit's estimate of the room's light, in lumens; ~1000 is neutral.
    let ambientIntensity: Float?

    init(
        capturedImage: CVPixelBuffer,
        camera: ARCamera?,
        cameraTransform: simd_float4x4? = nil,
        orientation: CapturedFrameOrientation,
        timestamp: TimeInterval,
        sceneDepth: CVPixelBuffer? = nil,
        personDepth: CVPixelBuffer? = nil,
        personMask: CVPixelBuffer? = nil,
        ambientIntensity: Float? = nil
    ) {
        self.capturedImage = capturedImage
        self.camera = camera
        self.cameraTransform = cameraTransform ?? camera?.transform ?? matrix_identity_float4x4
        self.orientation = orientation
        self.timestamp = timestamp
        self.sceneDepth = sceneDepth
        self.personDepth = personDepth
        self.personMask = personMask
        self.ambientIntensity = ambientIntensity
    }
}

struct ARObjectFrameMetadata: Equatable, Sendable {
    let sequence: UInt64
    let timestamp: TimeInterval
    let trackingState: Int
    let cameraTransform: simd_float4x4
}

enum ARObjectSourceEvent: Sendable {
    /// The first camera frame arrived: the session owns the camera and the
    /// preview can show it, whether or not tracking has settled yet.
    case firstFrame
    /// Tracking quality changed; the label says why when it is limited.
    case quality(String)
    case tracking(ARObjectFrameMetadata)
    case framePose(ARObjectFrameMetadata)
    case interrupted(String)
    case resumed
    case failed(String)
}

final class LatestARObjectFrameMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var latestFrame: ARObjectFrame?

    func publish(_ frame: ARObjectFrame) {
        lock.withLock {
            latestFrame = frame
        }
    }

    func consumeLatest() -> ARObjectFrame? {
        lock.withLock {
            defer { latestFrame = nil }
            return latestFrame
        }
    }

    func clear() {
        lock.withLock {
            latestFrame = nil
        }
    }
}

// MARK: - AR session source

private struct ARObjectSourceState {
    let isRunning: Bool
    let orientation: CapturedFrameOrientation
}

private typealias ARRaycastContinuation = CheckedContinuation<simd_float4x4?, Never>

/// Owns the ARSession for placed geometry. Delivers every frame to the render
/// mailbox and emits tracking & pose updates. On Simulator, runs a 60Hz
/// synthetic stage so AR Objects can be browsed, placed, and customized.
final class ARObjectSource: NSObject, @unchecked Sendable {
    let mailbox: LatestARObjectFrameMailbox

    private let session = ARSession()
    private let sessionQueue = DispatchQueue(
        label: "com.saringrey.greyvision.objects.session",
        qos: .userInteractive
    )
    private let handlerLock = NSLock()
    private let stateLock = NSLock()

    private var eventHandler: (@Sendable (ARObjectSourceEvent) -> Void)?
    private var orientation = CapturedFrameOrientation.portrait
    private var isRunning = false
    private var isSynthetic = false
    private var didEmitTracking = false
    private var didEmitFirstFrame = false
    private var lastQualityLabel = ""
    private var frameSequence: UInt64 = 0
    private var syntheticTimer: DispatchSourceTimer?
    private var syntheticPixelBuffer: CVPixelBuffer?

    static let syntheticCameraTransform: simd_float4x4 = {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(0, 0.15, 0, 1)
        return m
    }()

    init(mailbox: LatestARObjectFrameMailbox) {
        self.mailbox = mailbox
        super.init()
        session.delegate = self
        session.delegateQueue = sessionQueue
    }

    deinit {
        syntheticTimer?.cancel()
        session.pause()
    }

    func setEventHandler(_ handler: (@Sendable (ARObjectSourceEvent) -> Void)?) {
        handlerLock.withLock {
            eventHandler = handler
        }
    }

    func updateOrientation(_ orientation: CapturedFrameOrientation) {
        stateLock.withLock {
            self.orientation = orientation
        }
    }

    func start(preferSynthetic: Bool = false) async -> Bool {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [self] in
                #if targetEnvironment(simulator)
                    let useSynthetic = true
                #else
                    let useSynthetic = preferSynthetic || !ARWorldTrackingConfiguration.isSupported
                #endif

                if useSynthetic {
                    startSyntheticOnSessionQueue()
                    continuation.resume(returning: true)
                    return
                }

                guard ARWorldTrackingConfiguration.isSupported else {
                    continuation.resume(returning: false)
                    return
                }
                mailbox.clear()
                let configuration = ARWorldTrackingConfiguration()
                configuration.worldAlignment = .gravity
                configuration.planeDetection = [.horizontal, .vertical]
                configuration.environmentTexturing = .none
                configuration.isLightEstimationEnabled = true
                configuration.providesAudioData = false
                // Occlusion: LiDAR depth lets objects hide behind poles and
                // couches; person segmentation lets them pass behind people.
                // Each is asked for only where the device can provide it.
                var semantics: ARConfiguration.FrameSemantics = []
                if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
                    semantics.insert(.smoothedSceneDepth)
                } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                    semantics.insert(.sceneDepth)
                }
                if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) {
                    semantics.insert(.personSegmentationWithDepth)
                }
                configuration.frameSemantics = semantics

                stateLock.withLock {
                    isRunning = true
                    isSynthetic = false
                    didEmitTracking = false
                    didEmitFirstFrame = false
                    lastQualityLabel = ""
                    frameSequence = 0
                }
                session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
                GVLog.capture.notice("ARKit objects source started: world tracking")
                continuation.resume(returning: true)
            }
        }
    }

    private func startSyntheticOnSessionQueue() {
        syntheticTimer?.cancel()
        mailbox.clear()
        if syntheticPixelBuffer == nil {
            syntheticPixelBuffer = Self.makeSyntheticBiPlanarBuffer(width: 640, height: 360)
        }
        stateLock.withLock {
            isRunning = true
            isSynthetic = true
            didEmitTracking = false
            didEmitFirstFrame = false
            lastQualityLabel = ""
            frameSequence = 0
        }
        let timer = DispatchSource.makeTimerSource(queue: sessionQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16))
        timer.setEventHandler { [weak self] in
            self?.stepSyntheticFrame()
        }
        syntheticTimer = timer
        timer.resume()
        GVLog.capture.notice("ARKit objects source started: synthetic stage")
    }

    private func stepSyntheticFrame() {
        let state = stateLock.withLock {
            ARObjectSourceState(isRunning: isRunning, orientation: orientation)
        }
        guard state.isRunning, let pixelBuffer = syntheticPixelBuffer else { return }
        let now = CACurrentMediaTime()
        let camTransform = Self.syntheticCameraTransform

        mailbox.publish(ARObjectFrame(
            capturedImage: pixelBuffer,
            camera: nil,
            cameraTransform: camTransform,
            orientation: state.orientation,
            timestamp: now
        ))

        let (isFirst, seq, emitInitial) = stateLock.withLock { () -> (Bool, UInt64, Bool) in
            let first = !didEmitFirstFrame
            didEmitFirstFrame = true
            frameSequence &+= 1
            let initial = !didEmitTracking
            didEmitTracking = true
            return (first, frameSequence, initial)
        }
        if isFirst {
            emit(.firstFrame)
            emit(.quality("TRACKING NORMAL"))
        }
        let meta = ARObjectFrameMetadata(
            sequence: seq,
            timestamp: now,
            trackingState: 1,
            cameraTransform: camTransform
        )
        if emitInitial {
            emit(.tracking(meta))
        }
        emit(.framePose(meta))
    }

    private static func makeSyntheticBiPlanarBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            attrs as CFDictionary,
            &pb
        ) == kCVReturnSuccess, let pb else {
            return nil
        }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        if let yBase = CVPixelBufferGetBaseAddressOfPlane(pb, 0) {
            let yBpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            let ptr = yBase.assumingMemoryBound(to: UInt8.self)
            for y in 0 ..< height {
                let row = ptr.advanced(by: y * yBpr)
                for x in 0 ..< width {
                    let grid = (x % 32 == 0 || y % 32 == 0) ? UInt8(34) : UInt8(16 + (y * 12) / max(height, 1))
                    row[x] = grid
                }
            }
        }
        if let uvBase = CVPixelBufferGetBaseAddressOfPlane(pb, 1) {
            let uvBpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
            let uvH = CVPixelBufferGetHeightOfPlane(pb, 1)
            let ptr = uvBase.assumingMemoryBound(to: UInt8.self)
            for y in 0 ..< uvH {
                let row = ptr.advanced(by: y * uvBpr)
                for x in 0 ..< (width / 2) {
                    row[x * 2] = 132
                    row[x * 2 + 1] = 126
                }
            }
        }
        return pb
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [self] in
                stopOnSessionQueue()
                continuation.resume()
            }
        }
    }

    func stopSoon() {
        sessionQueue.async { [weak self] in
            self?.stopOnSessionQueue()
        }
    }

    private func stopOnSessionQueue() {
        syntheticTimer?.cancel()
        syntheticTimer = nil
        stateLock.withLock {
            isRunning = false
            didEmitTracking = false
            didEmitFirstFrame = false
            lastQualityLabel = ""
            frameSequence = 0
        }
        session.pause()
        mailbox.clear()
        GVLog.capture.notice("ARKit objects source stopped and detached")
    }

    /// Places geometry at the tapped screen point. Prefers a real plane hit,
    /// then an estimated plane, then a camera-ray fallback at `spawnDistance`
    /// so taps always produce an object even before a plane has been discovered.
    func raycast(
        from point: CGPoint,
        viewportSize: CGSize,
        orientation: CapturedFrameOrientation,
        spawnDistance: Float = 1.3
    ) async -> simd_float4x4? {
        await withCheckedContinuation { (continuation: ARRaycastContinuation) in
            sessionQueue.async { [self] in
                let synthetic = stateLock.withLock { isSynthetic }
                if synthetic {
                    let transform = Self.syntheticRayTransform(
                        point: point,
                        viewportSize: viewportSize,
                        cameraTransform: Self.syntheticCameraTransform,
                        distance: spawnDistance
                    )
                    continuation.resume(returning: transform)
                    return
                }
                guard let frame = session.currentFrame else {
                    continuation.resume(returning: nil)
                    return
                }
                let query = frame.raycastQuery(
                    from: point,
                    allowing: .estimatedPlane,
                    alignment: .any
                )
                let transform = session.raycast(query).first?.worldTransform
                    ?? fallbackTransform(
                        point: point,
                        viewportSize: viewportSize,
                        orientation: orientation,
                        frame: frame,
                        distance: spawnDistance
                    )
                continuation.resume(returning: transform)
            }
        }
    }

    /// Computes a world-space ray `(origin, direction)` for screen-space picking
    /// so floating objects can be grabbed and dragged accurately even without
    /// a background plane.
    func interactionRay(
        from point: CGPoint,
        viewportSize: CGSize,
        orientation: CapturedFrameOrientation
    ) async -> (origin: SIMD3<Float>, direction: SIMD3<Float>)? {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [self] in
                guard viewportSize.width > 0, viewportSize.height > 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                let synthetic = stateLock.withLock { isSynthetic }
                if synthetic {
                    let ray = Self.makeRay(
                        point: point,
                        viewportSize: viewportSize,
                        projection: Self.syntheticProjectionMatrix(viewportSize: viewportSize),
                        cameraTransform: Self.syntheticCameraTransform
                    )
                    continuation.resume(returning: ray)
                    return
                }
                guard let frame = session.currentFrame else {
                    continuation.resume(returning: nil)
                    return
                }
                let interfaceOrientation = Self.interfaceOrientation(for: orientation)
                let projection = frame.camera.projectionMatrix(
                    for: interfaceOrientation,
                    viewportSize: viewportSize,
                    zNear: 0.001,
                    zFar: 25
                )
                let view = frame.camera.viewMatrix(for: interfaceOrientation)
                let ray = Self.makeRay(
                    point: point,
                    viewportSize: viewportSize,
                    projection: projection,
                    viewInverse: view.inverse,
                    cameraTransform: frame.camera.transform
                )
                continuation.resume(returning: ray)
            }
        }
    }

    static func syntheticProjectionMatrix(
        viewportSize: CGSize,
        zNear: Float = 0.001,
        zFar: Float = 25.0
    ) -> simd_float4x4 {
        let aspect = Float(max(viewportSize.width, 1) / max(viewportSize.height, 1))
        let fovY: Float = 60.0 * .pi / 180.0
        let yScale = 1.0 / tan(fovY * 0.5)
        let xScale = yScale / aspect
        let zRange = zFar - zNear
        let zScale = -(zFar + zNear) / zRange
        let wzScale = -2.0 * zFar * zNear / zRange
        return simd_float4x4(columns: (
            SIMD4<Float>(xScale, 0, 0, 0),
            SIMD4<Float>(0, yScale, 0, 0),
            SIMD4<Float>(0, 0, zScale, -1),
            SIMD4<Float>(0, 0, wzScale, 0)
        ))
    }

    private static func makeRay(
        point: CGPoint,
        viewportSize: CGSize,
        projection: simd_float4x4,
        viewInverse: simd_float4x4? = nil,
        cameraTransform: simd_float4x4
    ) -> (origin: SIMD3<Float>, direction: SIMD3<Float>)? {
        let normalized = SIMD4<Float>(
            Float(point.x / viewportSize.width) * 2 - 1,
            1 - Float(point.y / viewportSize.height) * 2,
            0.5,
            1
        )
        var unprojected = projection.inverse * normalized
        guard abs(unprojected.w) > 0.0001 else { return nil }
        unprojected /= unprojected.w
        let invView = viewInverse ?? cameraTransform
        let worldPoint4 = invView * unprojected
        let worldPoint = SIMD3<Float>(worldPoint4.x, worldPoint4.y, worldPoint4.z)
        let cameraOrigin = SIMD3<Float>(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        )
        let delta = worldPoint - cameraOrigin
        let len = simd_length(delta)
        guard len > 0.0001 else { return nil }
        return (cameraOrigin, delta / len)
    }

    private static func syntheticRayTransform(
        point: CGPoint,
        viewportSize: CGSize,
        cameraTransform: simd_float4x4,
        distance: Float
    ) -> simd_float4x4? {
        guard viewportSize.width > 0, viewportSize.height > 0,
              let ray = makeRay(
                  point: point,
                  viewportSize: viewportSize,
                  projection: syntheticProjectionMatrix(viewportSize: viewportSize),
                  cameraTransform: cameraTransform
              )
        else { return nil }
        var transform = cameraTransform
        transform.columns.3 = SIMD4<Float>(ray.origin + ray.direction * distance, 1)
        return transform
    }

    private func fallbackTransform(
        point: CGPoint,
        viewportSize: CGSize,
        orientation: CapturedFrameOrientation,
        frame: ARFrame,
        distance: Float
    ) -> simd_float4x4? {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return nil }
        let interfaceOrientation = Self.interfaceOrientation(for: orientation)
        let projection = frame.camera.projectionMatrix(
            for: interfaceOrientation,
            viewportSize: viewportSize,
            zNear: 0.001,
            zFar: 25
        )
        let view = frame.camera.viewMatrix(for: interfaceOrientation)
        guard let ray = Self.makeRay(
            point: point,
            viewportSize: viewportSize,
            projection: projection,
            viewInverse: view.inverse,
            cameraTransform: frame.camera.transform
        ) else {
            return nil
        }
        let position = ray.origin + ray.direction * distance
        var transform = frame.camera.transform
        transform.columns.3 = SIMD4(position, 1)
        return transform
    }

    private static func interfaceOrientation(for orientation: CapturedFrameOrientation) -> UIInterfaceOrientation {
        switch orientation {
        case .portrait: .portrait
        case .portraitUpsideDown: .portraitUpsideDown
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        }
    }

    private func emit(_ event: ARObjectSourceEvent) {
        let handler = handlerLock.withLock { eventHandler }
        handler?(event)
    }
}

extension ARObjectSource: ARSessionDelegate {
    func session(_: ARSession, didUpdate frame: ARFrame) {
        let state = stateLock.withLock {
            ARObjectSourceState(isRunning: isRunning, orientation: orientation)
        }
        guard state.isRunning else { return }

        mailbox.publish(ARObjectFrame(
            capturedImage: frame.capturedImage,
            camera: frame.camera,
            cameraTransform: frame.camera.transform,
            orientation: state.orientation,
            timestamp: frame.timestamp,
            sceneDepth: (frame.smoothedSceneDepth ?? frame.sceneDepth)?.depthMap,
            personDepth: frame.estimatedDepthData,
            personMask: frame.segmentationBuffer,
            ambientIntensity: frame.lightEstimate.map { Float($0.ambientIntensity) }
        ))

        let quality = Self.qualityLabel(frame.camera.trackingState)
        let (isFirst, qualityChanged) = stateLock.withLock { () -> (Bool, Bool) in
            let first = !didEmitFirstFrame
            didEmitFirstFrame = true
            let changed = quality != lastQualityLabel
            lastQualityLabel = quality
            return (first, changed)
        }
        if isFirst { emit(.firstFrame) }
        if qualityChanged { emit(.quality(quality)) }

        let (initialTrackingMeta, poseMeta) = stateLock.withLock { () -> (ARObjectFrameMetadata?, ARObjectFrameMetadata) in
            frameSequence &+= 1
            let current = ARObjectFrameMetadata(
                sequence: frameSequence,
                timestamp: frame.timestamp,
                trackingState: frame.camera.trackingState == .normal ? 1 : 0,
                cameraTransform: frame.camera.transform
            )
            if !didEmitTracking, frame.camera.trackingState == .normal {
                didEmitTracking = true
                return (current, current)
            }
            return (nil, current)
        }
        if let initialTrackingMeta {
            emit(.tracking(initialTrackingMeta))
        }
        emit(.framePose(poseMeta))
    }

    static func qualityLabel(_ state: ARCamera.TrackingState) -> String {
        switch state {
        case .normal: "TRACKING NORMAL"
        case .notAvailable: "TRACKING UNAVAILABLE"
        case let .limited(reason):
            switch reason {
            case .initializing: "TRACKING · INITIALIZING — MOVE SLOWLY"
            case .excessiveMotion: "TRACKING · SLOW DOWN"
            case .insufficientFeatures: "TRACKING · POINT AT DETAIL OR ADD LIGHT"
            case .relocalizing: "TRACKING · RELOCALIZING"
            @unknown default: "TRACKING · LIMITED"
            }
        }
    }

    func session(_: ARSession, didFailWithError error: Error) {
        stateLock.withLock {
            isRunning = false
        }
        emit(.failed(error.localizedDescription))
    }

    func sessionWasInterrupted(_: ARSession) {
        emit(.interrupted("ARKIT SESSION INTERRUPTED"))
    }

    func sessionInterruptionEnded(_: ARSession) {
        emit(.resumed)
    }
}

// MARK: - Runtime

@MainActor
final class ARObjectRuntime: ObservableObject {
    @Published private(set) var snapshot = ARObjectSnapshot.idle
    @Published private(set) var objects: [ARObjectDescriptor] = []
    @Published var parameters = ARObjectParameters.defaults {
        didSet {
            let clean = parameters.sanitized
            if parameters != clean {
                parameters = clean
                return
            }
            applyLiveParametersToTarget()
        }
    }
    @Published var spawnSource: ARObjectSpawnSource = .cycle
    /// Objects hide behind real things nearer the camera: scene depth on
    /// LiDAR devices, people on devices that can segment them.
    @Published var occlusionEnabled = true

    /// What this device can hide objects behind, for the studio's label.
    static var occlusionSupport: String {
        let scene = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        let people = ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth)
        switch (scene, people) {
        case (true, true): return "SCENE + PEOPLE"
        case (true, false): return "SCENE"
        case (false, true): return "PEOPLE"
        case (false, false): return "UNSUPPORTED"
        }
    }
    @Published var selectedObjectID: UUID?
    @Published private(set) var userModels: [ARUserModel] = []
    @Published private(set) var recordingState = ARObjectRecordingState.idle
    @Published private(set) var startRequested = false
    /// One-shot notice surfaced as a top line when the constellation easter egg
    /// fires ("CONSTELLATION WITNESSED" / "CONSTELLATION CONSUMED").
    @Published private(set) var constellationMessage: String?

    /// Where the recording transaction hears the outcome of a finished objects
    /// take, including one kept in the library because Photos refused it.
    var takeOutcomeHandler: (@MainActor (Result<GVTake, any Error>) -> Void)?

    let capability: ARObjectCapability
    let mailbox: LatestARObjectFrameMailbox
    let modelStore: ARUserModelStore

    private let source: ARObjectSource
    private var hasSeededField = false
    private var recordingSession: GVRealtimeRecordingSession?
    private var blackHoleActive = false
    private var latestCameraTransform: simd_float4x4 = ARObjectSource.syntheticCameraTransform
    private var activePresetShapes: [ARObjectShape]?
    private var isSyncingSelection = false
    private var spawnCounter: Int = 0

    var isRecording: Bool {
        recordingState == .recording
    }

    var activeRecordingSession: GVRealtimeRecordingSession? {
        recordingSession
    }

    var selectedObject: ARObjectDescriptor? {
        guard let selectedObjectID else { return nil }
        return objects.first(where: { $0.id == selectedObjectID })
    }

    init(
        capability: ARObjectCapability = .discover(),
        modelStore: ARUserModelStore = .shared
    ) {
        self.capability = capability
        self.modelStore = modelStore
        userModels = modelStore.loadModels()
        let mailbox = LatestARObjectFrameMailbox()
        self.mailbox = mailbox
        source = ARObjectSource(mailbox: mailbox)
        source.setEventHandler { [weak self] event in
            Task { @MainActor [weak self] in
                self?.consume(event)
            }
        }
    }

    var isActive: Bool {
        switch snapshot.state {
        case .starting, .running, .interrupted:
            true
        case .idle, .unsupported, .failed:
            false
        }
    }

    func start() async -> Bool {
        guard capability.isSupported else {
            snapshot = ARObjectSnapshot(
                state: .unsupported,
                sourceLabel: "AR OBJECTS UNAVAILABLE",
                formatLabel: capability.reason,
                objectCount: 0,
                orientation: snapshot.orientation,
                errorMessage: capability.reason
            )
            return false
        }

        refreshOrientation()
        hasSeededField = false
        snapshot = ARObjectSnapshot(
            state: .starting,
            sourceLabel: "AR OBJECTS STARTING",
            formatLabel: capability.reason,
            objectCount: 0,
            orientation: snapshot.orientation,
            errorMessage: nil
        )

        let started = await source.start(preferSynthetic: capability.isSynthetic)
        guard started else {
            snapshot.state = .failed
            snapshot.sourceLabel = "AR OBJECTS FAILURE"
            snapshot.errorMessage = "ARKit failed to start world tracking."
            return false
        }

        for _ in 0 ..< 40 {
            guard !Task.isCancelled else {
                await source.stop()
                snapshot = .idle
                return false
            }
            if snapshot.state == .running {
                return true
            }
            if snapshot.state == .failed {
                await source.stop()
                return false
            }
            try? await Task.sleep(for: .milliseconds(100))
        }

        await source.stop()
        snapshot.state = .failed
        snapshot.sourceLabel = "AR OBJECTS TIMEOUT"
        snapshot.errorMessage = "ARKit did not deliver a camera frame within four seconds."
        return false
    }

    func stop() async {
        if isRecording {
            stopRecording()
        }
        await source.stop()
        snapshot = .idle
        hasSeededField = false
    }

    func stopSoon() {
        source.stopSoon()
        snapshot = .idle
    }

    func refreshOrientation(_ requestedOrientation: UIInterfaceOrientation? = nil) {
        let interfaceOrientation = requestedOrientation ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?
            .interfaceOrientation ?? .portrait
        let orientation: CapturedFrameOrientation? = switch interfaceOrientation {
        case .portrait:
            .portrait
        case .portraitUpsideDown:
            .portraitUpsideDown
        case .landscapeLeft:
            .landscapeLeft
        case .landscapeRight:
            .landscapeRight
        default:
            nil
        }
        guard let orientation else { return }
        snapshot.orientation = orientation
        source.updateOrientation(orientation)
    }

    // MARK: - Spawning, Presets & User Models

    func placeObject(at point: CGPoint, viewportSize: CGSize) async {
        guard snapshot.state == .running, objects.count < ARObjectDescriptor.maxObjects else { return }
        let orientation = snapshot.orientation
        let distance = Float(parameters.spawnDistance)
        guard let transform = await source.raycast(
            from: point,
            viewportSize: viewportSize,
            orientation: orientation,
            spawnDistance: distance
        ) else {
            return
        }
        let position = SIMD3<Float>(
            transform.columns.3.x,
            transform.columns.3.y + Float(parameters.heightOffset),
            transform.columns.3.z
        )
        appendObject(position: position)
    }

    /// Spawns a new object directly in front of the current camera pose at
    /// `parameters.spawnDistance`, without requiring a screen tap or plane.
    @discardableResult
    func spawnObjectInFrontOfCamera(source overrideSource: ARObjectSpawnSource? = nil) -> ARObjectDescriptor? {
        guard objects.count < ARObjectDescriptor.maxObjects else { return nil }
        let cam = latestCameraTransform
        let origin = SIMD3<Float>(cam.columns.3.x, cam.columns.3.y, cam.columns.3.z)
        let forward = SIMD3<Float>(-cam.columns.2.x, -cam.columns.2.y, -cam.columns.2.z)
        let right = SIMD3<Float>(cam.columns.0.x, cam.columns.0.y, cam.columns.0.z)
        let up = SIMD3<Float>(cam.columns.1.x, cam.columns.1.y, cam.columns.1.z)

        let spreadIndex = objects.count
        let angle = Float(spreadIndex) * 1.15
        let radial: Float = spreadIndex == 0 ? 0.0 : min(0.28, Float(spreadIndex) * 0.04)
        let distance = Float(parameters.spawnDistance)
        let position = origin
            + forward * distance
            + right * (cos(angle) * radial)
            + up * (sin(angle) * radial * 0.6 + Float(parameters.heightOffset))
        return appendObject(position: position, overrideSource: overrideSource)
    }

    @discardableResult
    func duplicateSelectedObject() -> ARObjectDescriptor? {
        guard objects.count < ARObjectDescriptor.maxObjects else { return nil }
        guard let sourceObject = selectedObject ?? objects.last else {
            return spawnObjectInFrontOfCamera()
        }
        var copy = ARObjectDescriptor(
            shape: sourceObject.shape,
            userModelID: sourceObject.userModelID,
            position: sourceObject.position + SIMD3<Float>(0.22, 0.06, -0.12),
            scale: sourceObject.scale,
            stretch: sourceObject.stretch,
            orientationDegrees: sourceObject.orientationDegrees,
            spinSpeed: sourceObject.spinSpeed,
            spinAxis: sourceObject.spinAxis,
            bobAmplitude: sourceObject.bobAmplitude,
            bobSpeed: sourceObject.bobSpeed,
            pulseAmount: sourceObject.pulseAmount,
            phase: sourceObject.phase + 0.618,
            material: sourceObject.material,
            wire: sourceObject.wire,
            tintIndex: (sourceObject.tintIndex + 1) % ARObjectPalette.colors.count,
            useCustomHue: sourceObject.useCustomHue,
            customHue: sourceObject.customHue,
            glow: sourceObject.glow,
            metallic: sourceObject.metallic,
            rimSharpness: sourceObject.rimSharpness,
            opacity: sourceObject.opacity,
            birthTime: CACurrentMediaTime()
        )
        copy.isBlackHole = false
        objects.append(copy)
        snapshot.objectCount = objects.count
        selectObject(copy.id)
        detectConstellation()
        return copy
    }

    func removeSelectedObject() {
        if let selectedObjectID, let idx = objects.firstIndex(where: { $0.id == selectedObjectID }) {
            objects.remove(at: idx)
            self.selectedObjectID = objects.last?.id
        } else if !objects.isEmpty {
            objects.removeLast()
        }
        snapshot.objectCount = objects.count
        blackHoleActive = objects.contains(where: \.isBlackHole)
    }

    func selectObject(_ id: UUID?) {
        selectedObjectID = id
        guard let id, let obj = objects.first(where: { $0.id == id }) else { return }
        isSyncingSelection = true
        defer { isSyncingSelection = false }
        var synced = parameters
        synced.size = Double(obj.scale)
        synced.spin = Double(obj.spinSpeed)
        synced.glow = Double(obj.glow)
        synced.material = obj.material
        synced.wireOverlay = obj.wire
        synced.tintIndex = obj.tintIndex
        synced.useCustomHue = obj.useCustomHue
        synced.customHue = Double(obj.customHue)
        synced.metallic = Double(obj.metallic)
        synced.rimSharpness = Double(obj.rimSharpness)
        synced.opacity = Double(obj.opacity)
        synced.stretchX = Double(obj.stretch.x)
        synced.stretchY = Double(obj.stretch.y)
        synced.stretchZ = Double(obj.stretch.z)
        synced.pitchDegrees = Double(obj.orientationDegrees.x)
        synced.yawDegrees = Double(obj.orientationDegrees.y)
        synced.rollDegrees = Double(obj.orientationDegrees.z)
        synced.spinAxis = obj.spinAxis
        synced.bobAmplitude = Double(obj.bobAmplitude)
        synced.bobSpeed = Double(obj.bobSpeed)
        synced.pulseAmount = Double(obj.pulseAmount)
        parameters = synced.sanitized
    }

    func apply(_ preset: GVObjectPreset) {
        activePresetShapes = preset.shapes
        selectedObjectID = nil
        spawnSource = .cycle
        parameters = preset.parameters.sanitized
        if !objects.isEmpty {
            for idx in objects.indices where !objects[idx].isBlackHole {
                let shape = preset.shapes[idx % preset.shapes.count]
                objects[idx].shape = shape
                objects[idx].userModelID = nil
                objects[idx].tintIndex = (preset.parameters.tintIndex + idx) % ARObjectPalette.colors.count
                applyParameters(parameters, to: &objects[idx], preserveTint: true)
            }
        }
    }

    func selectSpawnShape(_ shape: ARObjectShape, spawnImmediatelyIfRunning: Bool = true) {
        spawnSource = .shape(shape)
        if let selectedObjectID, let idx = objects.firstIndex(where: { $0.id == selectedObjectID }) {
            objects[idx].shape = shape
            objects[idx].userModelID = nil
        } else if spawnImmediatelyIfRunning, snapshot.state == .running {
            spawnObjectInFrontOfCamera(source: .shape(shape))
        }
    }

    func selectUserModel(_ model: ARUserModel, spawnImmediatelyIfRunning: Bool = true) {
        spawnSource = .userModel(model.id)
        if let selectedObjectID, let idx = objects.firstIndex(where: { $0.id == selectedObjectID }) {
            objects[idx].userModelID = model.id
        } else if spawnImmediatelyIfRunning, snapshot.state == .running {
            spawnObjectInFrontOfCamera(source: .userModel(model.id))
        }
    }

    @discardableResult
    func importUserModel(from url: URL, customName: String? = nil) throws -> ARUserModel {
        let model = try modelStore.importModel(from: url, customName: customName)
        userModels = modelStore.loadModels()
        spawnSource = .userModel(model.id)
        return model
    }

    @discardableResult
    func createSampleUserModel(named name: String = "Hyperbolic Relic") throws -> ARUserModel {
        let model = try modelStore.createProceduralSampleModel(named: name)
        userModels = modelStore.loadModels()
        spawnSource = .userModel(model.id)
        return model
    }

    func renameUserModel(_ id: UUID, to newName: String) {
        userModels = modelStore.renameModel(id: id, to: newName)
    }

    func deleteUserModel(_ id: UUID) {
        userModels = modelStore.deleteModel(id: id)
        if spawnSource == .userModel(id) {
            spawnSource = .cycle
        }
        for idx in objects.indices where objects[idx].userModelID == id {
            objects[idx].userModelID = nil
            objects[idx].shape = .icosahedron
        }
    }

    private func applyLiveParametersToTarget() {
        guard !isSyncingSelection else { return }
        if let selectedObjectID, let idx = objects.firstIndex(where: { $0.id == selectedObjectID }) {
            applyParameters(parameters, to: &objects[idx], preserveTint: false)
        } else {
            for idx in objects.indices where !objects[idx].isBlackHole {
                applyParameters(parameters, to: &objects[idx], preserveTint: false)
            }
        }
    }

    private func applyParameters(
        _ p: ARObjectParameters,
        to object: inout ARObjectDescriptor,
        preserveTint: Bool
    ) {
        object.scale = Float(p.size)
        object.stretch = SIMD3<Float>(Float(p.stretchX), Float(p.stretchY), Float(p.stretchZ))
        object.orientationDegrees = SIMD3<Float>(Float(p.pitchDegrees), Float(p.yawDegrees), Float(p.rollDegrees))
        object.spinSpeed = Float(p.spin)
        object.spinAxis = p.spinAxis
        object.bobAmplitude = Float(p.bobAmplitude)
        object.bobSpeed = Float(p.bobSpeed)
        object.pulseAmount = Float(p.pulseAmount)
        object.material = p.material
        object.wire = p.wireOverlay
        if !preserveTint {
            object.tintIndex = p.tintIndex
        }
        object.useCustomHue = p.useCustomHue
        object.customHue = Float(p.customHue)
        object.glow = Float(p.glow)
        object.metallic = Float(p.metallic)
        object.rimSharpness = Float(p.rimSharpness)
        object.opacity = Float(p.opacity)
    }

    // MARK: - Direct manipulation

    private var grabbedIndex: Int?
    private var grabbedDistance: Float = 1.3
    private var grabbedScale: Float = 1
    private var grabbedPhase: Float = 0

    /// Picks the object nearest the touch using both 3D ray-to-sphere closest
    /// approach and plane raycast distance so floating objects and surface
    /// objects are equally easy to grab.
    private func nearestObject(to point: CGPoint, viewportSize: CGSize) async -> Int? {
        guard !objects.isEmpty else { return nil }

        if let ray = await source.interactionRay(
            from: point,
            viewportSize: viewportSize,
            orientation: snapshot.orientation
        ) {
            var bestRay: (index: Int, perpendicular: Float, along: Float)?
            for (index, object) in objects.enumerated() {
                let toCenter = object.position - ray.origin
                let along = simd_dot(toCenter, ray.direction)
                guard along > 0.05 else { continue }
                let closestPoint = ray.origin + ray.direction * along
                let perp = simd_distance(object.position, closestPoint)
                let hitRadius = max(0.18, object.scale * 0.42)
                guard perp < hitRadius else { continue }
                if bestRay == nil || perp < bestRay!.perpendicular {
                    bestRay = (index, perp, along)
                }
            }
            if let bestRay {
                grabbedDistance = bestRay.along
                return bestRay.index
            }
        }

        guard let transform = await source.raycast(
            from: point,
            viewportSize: viewportSize,
            orientation: snapshot.orientation,
            spawnDistance: Float(parameters.spawnDistance)
        ) else { return nil }

        let target = SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        var best: (index: Int, distance: Float)?
        for (index, object) in objects.enumerated() {
            let distance = simd_distance(object.position, target)
            guard distance < max(0.22, object.scale * 0.40) else { continue }
            if best == nil || distance < best!.distance {
                best = (index, distance)
            }
        }
        return best?.index
    }

    /// Drag an existing object across the world plane or camera ray.
    func dragObject(at point: CGPoint, viewportSize: CGSize, phase: ARManipulationPhase) async {
        switch phase {
        case .began:
            grabbedIndex = await nearestObject(to: point, viewportSize: viewportSize)
            if let index = grabbedIndex, objects.indices.contains(index) {
                selectObject(objects[index].id)
            }
        case .changed:
            guard let index = grabbedIndex, objects.indices.contains(index) else { return }
            if let ray = await source.interactionRay(
                from: point,
                viewportSize: viewportSize,
                orientation: snapshot.orientation
            ) {
                objects[index].position = ray.origin + ray.direction * max(0.35, grabbedDistance)
                return
            }
            guard let transform = await source.raycast(
                from: point,
                viewportSize: viewportSize,
                orientation: snapshot.orientation,
                spawnDistance: grabbedDistance
            ) else { return }
            objects[index].position = SIMD3(
                transform.columns.3.x,
                transform.columns.3.y,
                transform.columns.3.z
            )
        case .ended:
            if grabbedIndex != nil { detectConstellation() }
            grabbedIndex = nil
        }
    }

    /// Pinch scale. Applies to the grabbed/selected object, or to the most recent one.
    func scaleObject(_ factor: CGFloat, phase: ARManipulationPhase) {
        let index = grabbedIndex
            ?? objects.firstIndex(where: { $0.id == selectedObjectID })
            ?? objects.indices.last
        guard let index, objects.indices.contains(index) else { return }
        switch phase {
        case .began:
            grabbedScale = objects[index].scale
        case .changed:
            let next = min(max(grabbedScale * Float(factor), 0.15), 4.0)
            objects[index].scale = next
        case .ended:
            grabbedScale = objects[index].scale
        }
    }

    /// Two-finger twist, folded into the object's yaw orientation & spin phase.
    func rotateObject(_ radians: CGFloat, phase: ARManipulationPhase) {
        let index = grabbedIndex
            ?? objects.firstIndex(where: { $0.id == selectedObjectID })
            ?? objects.indices.last
        guard let index, objects.indices.contains(index) else { return }
        switch phase {
        case .began:
            grabbedPhase = objects[index].phase
        case .changed:
            objects[index].phase = grabbedPhase + Float(radians)
        case .ended:
            grabbedPhase = objects[index].phase
        }
    }

    /// Long press removes the object under the finger.
    func removeObject(at point: CGPoint, viewportSize: CGSize) async {
        guard let index = await nearestObject(to: point, viewportSize: viewportSize),
              objects.indices.contains(index)
        else { return }
        let removedID = objects[index].id
        objects.remove(at: index)
        if selectedObjectID == removedID {
            selectedObjectID = nil
        }
        snapshot.objectCount = objects.count
        blackHoleActive = objects.contains(where: \.isBlackHole)
        detectConstellation()
    }

    func clearObjects() {
        objects = []
        selectedObjectID = nil
        snapshot.objectCount = 0
        blackHoleActive = false
        constellationMessage = nil
    }

    // MARK: - Recording

    @discardableResult
    func requestStartRecording() -> Bool {
        guard !startRequested, recordingSession == nil else { return false }
        startRequested = true
        return true
    }

    func cancelRecordingStart() {
        startRequested = false
    }

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            requestStartRecording()
        }
    }

    func consumeStartRequest(size: CGSize) {
        guard startRequested else { return }
        startRequested = false
        startRecording(size: size)
    }

    private func startRecording(size: CGSize) {
        guard snapshot.state == .running, recordingSession == nil,
              size.width > 0, size.height > 0
        else {
            return
        }
        guard let url = try? GVTakeArchive.shared.makeRecordingURL() else {
            recordingState = .failed(GVRecordingError.writerSetupFailed.localizedDescription)
            takeOutcomeHandler?(.failure(GVRecordingError.writerSetupFailed))
            return
        }
        let session = GVRealtimeRecordingSession(outputURL: url, size: size, saveToPhotos: false)
        guard session.start() else {
            recordingState = .failed(GVRecordingError.writerSetupFailed.localizedDescription)
            takeOutcomeHandler?(.failure(GVRecordingError.writerSetupFailed))
            return
        }
        recordingSession = session
        recordingState = .recording
        UISelectionFeedbackGenerator().selectionChanged()
        GVLog.recording.notice("AR objects recording started")
    }

    func stopRecording() {
        guard let session = recordingSession else { return }
        recordingSession = nil
        recordingState = .finalizing
        session.finish { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case let .success(url):
                    self.recordingState = .saved
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    await self.fileCompletedTake(url)
                case let .failure(error):
                    self.recordingState = .failed(error.localizedDescription)
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                    self.takeOutcomeHandler?(.failure(error))
                }
            }
        }
    }

    private func fileCompletedTake(_ url: URL) async {
        do {
            let take = try await GVTakeArchive.shared.completeRecording(at: url, source: .objects, exporter: GVSystemPhotosExporter())
            takeOutcomeHandler?(.success(take))
        } catch {
            takeOutcomeHandler?(.failure(error))
        }
    }

    @discardableResult
    private func appendObject(
        position: SIMD3<Float>,
        overrideSource: ARObjectSpawnSource? = nil
    ) -> ARObjectDescriptor {
        let activeSource = overrideSource ?? spawnSource
        let count = spawnCounter
        spawnCounter &+= 1

        let resolvedShape: ARObjectShape
        let resolvedUserModelID: UUID?
        let resolvedTint: Int

        switch activeSource {
        case .cycle:
            let pool = activePresetShapes ?? ARObjectShape.allCases
            resolvedShape = pool[count % pool.count]
            resolvedUserModelID = nil
            resolvedTint = (parameters.tintIndex + count) % ARObjectPalette.colors.count
        case .random:
            let pool = ARObjectShape.allCases
            resolvedShape = pool[(count * 7 + 3) % pool.count]
            resolvedUserModelID = nil
            resolvedTint = (count * 5 + parameters.tintIndex) % ARObjectPalette.colors.count
        case let .shape(shape):
            resolvedShape = shape
            resolvedUserModelID = nil
            resolvedTint = parameters.tintIndex
        case let .userModel(modelID):
            resolvedShape = .icosahedron
            resolvedUserModelID = modelID
            resolvedTint = parameters.tintIndex
        }

        let phase = Float(count) * 0.6180339
        let descriptor = ARObjectDescriptor(
            shape: resolvedShape,
            userModelID: resolvedUserModelID,
            position: position,
            scale: Float(parameters.size),
            stretch: SIMD3<Float>(
                Float(parameters.stretchX),
                Float(parameters.stretchY),
                Float(parameters.stretchZ)
            ),
            orientationDegrees: SIMD3<Float>(
                Float(parameters.pitchDegrees),
                Float(parameters.yawDegrees),
                Float(parameters.rollDegrees)
            ),
            spinSpeed: Float(parameters.spin),
            spinAxis: parameters.spinAxis,
            bobAmplitude: Float(parameters.bobAmplitude),
            bobSpeed: Float(parameters.bobSpeed),
            pulseAmount: Float(parameters.pulseAmount),
            phase: phase,
            material: parameters.material,
            wire: parameters.wireOverlay,
            tintIndex: resolvedTint,
            useCustomHue: parameters.useCustomHue,
            customHue: Float(parameters.customHue),
            glow: Float(parameters.glow),
            metallic: Float(parameters.metallic),
            rimSharpness: Float(parameters.rimSharpness),
            opacity: Float(parameters.opacity),
            birthTime: CACurrentMediaTime()
        )
        objects.append(descriptor)
        snapshot.objectCount = objects.count
        detectConstellation()
        return descriptor
    }

    // MARK: - Constellation & Physics

    private func detectConstellation() {
        guard !blackHoleActive, objects.count >= 3 else { return }
        let candidates = objects.filter { !$0.isBlackHole }
        for firstIndex in 0 ..< candidates.count {
            for secondIndex in (firstIndex + 1) ..< candidates.count {
                for thirdIndex in (secondIndex + 1) ..< candidates.count {
                    let first = candidates[firstIndex]
                    let second = candidates[secondIndex]
                    let third = candidates[thirdIndex]
                    let ab = second.position - first.position
                    let ac = third.position - first.position
                    let abLength = length(ab)
                    let acLength = length(ac)
                    guard abLength > 0.05, acLength > 0.05 else { continue }
                    guard length(cross(ab, ac)) / (abLength * acLength) < 0.14 else { continue }
                    let axis = ab / abLength
                    let projections = [
                        dot(first.position - first.position, axis),
                        dot(second.position - first.position, axis),
                        dot(third.position - first.position, axis)
                    ].sorted()
                    let gap1 = projections[1] - projections[0]
                    let gap2 = projections[2] - projections[1]
                    let larger = max(gap1, gap2)
                    guard larger > 0.04 else { continue }
                    let spacingRatio = min(gap1, gap2) / larger
                    guard spacingRatio > 0.55 else { continue }
                    spawnBlackHole(belt: [first, second, third])
                    return
                }
            }
        }
    }

    func triggerSingularity() {
        guard !objects.isEmpty else {
            _ = spawnObjectInFrontOfCamera()
            return
        }
        guard !blackHoleActive else { return }
        spawnBlackHole(belt: Array(objects.prefix(3)))
    }

    private func spawnBlackHole(belt: [ARObjectDescriptor]) {
        let midpoint = belt.reduce(SIMD3<Float>.zero) { $0 + $1.position } / Float(max(belt.count, 1))
        blackHoleActive = true
        objects.append(ARObjectDescriptor(
            shape: .icosahedron,
            position: midpoint + SIMD3(0, 0.28, 0),
            scale: 0.38,
            spinSpeed: 0.16,
            phase: 0.5,
            wire: false,
            tintIndex: 0,
            birthTime: CACurrentMediaTime(),
            isBlackHole: true
        ))
        snapshot.objectCount = objects.count
        constellationMessage = "CONSTELLATION WITNESSED"
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        GVLog.capture.notice("AR objects: black hole born from a collinear field")
    }

    private func stepScenePhysics() {
        if blackHoleActive || parameters.physicsMode == .gravity {
            if !blackHoleActive, objects.count >= 2 {
                spawnBlackHole(belt: Array(objects.prefix(min(3, objects.count))))
            }
            updateGravity()
            return
        }
        guard parameters.physicsMode == .orbit, objects.count >= 1 else { return }
        let center = SIMD3<Float>(
            latestCameraTransform.columns.3.x,
            latestCameraTransform.columns.3.y,
            latestCameraTransform.columns.3.z - Float(parameters.spawnDistance)
        )
        let angularStep = Float(parameters.orbitSpeed) * (1.0 / 60.0)
        let cosA = cos(angularStep)
        let sinA = sin(angularStep)
        for index in objects.indices where !objects[index].isBlackHole {
            let rel = objects[index].position - center
            let nextX = rel.x * cosA - rel.z * sinA
            let nextZ = rel.x * sinA + rel.z * cosA
            objects[index].position = SIMD3<Float>(center.x + nextX, objects[index].position.y, center.z + nextZ)
        }
    }

    private func updateGravity() {
        guard let blackHole = objects.first(where: \.isBlackHole) else {
            blackHoleActive = false
            return
        }
        var survivors: [ARObjectDescriptor] = []
        survivors.reserveCapacity(objects.count)
        for object in objects where !object.isBlackHole {
            let delta = blackHole.position - object.position
            let distance = max(length(delta), 0.0001)
            if distance < 0.05 {
                UISelectionFeedbackGenerator().selectionChanged()
                continue
            }
            var falling = object
            let pull = 0.9 / 60.0 * min(1.0, 0.22 / max(distance * 0.5, 0.03))
            let tangent = normalize(SIMD3<Float>(-delta.z, 0, delta.x))
            falling.position = object.position
                + (delta / distance) * min(pull, 0.05)
                + tangent * min(pull * 0.65, 0.03)
            falling.spinSpeed = min(falling.spinSpeed * 1.02, 2.8)
            survivors.append(falling)
        }
        survivors.append(blackHole)
        objects = survivors
        snapshot.objectCount = objects.count
        if survivors.count == 1 {
            objects = []
            selectedObjectID = nil
            snapshot.objectCount = 0
            blackHoleActive = false
            if parameters.physicsMode == .gravity {
                parameters.physicsMode = .float
            }
            constellationMessage = "CONSTELLATION CONSUMED"
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    private func seedInitialField(cameraTransform: simd_float4x4) {
        guard !hasSeededField, objects.isEmpty else { return }
        hasSeededField = true
        let cameraPosition = SIMD3(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        )
        let forward = SIMD3(
            -cameraTransform.columns.2.x,
            -cameraTransform.columns.2.y,
            -cameraTransform.columns.2.z
        )
        let right = SIMD3(
            cameraTransform.columns.0.x,
            cameraTransform.columns.0.y,
            cameraTransform.columns.0.z
        )
        let up = SIMD3(
            cameraTransform.columns.1.x,
            cameraTransform.columns.1.y,
            cameraTransform.columns.1.z
        )
        let placements: [SIMD3<Float>] = [
            SIMD3(1.15, -0.45, 0.20),
            SIMD3(1.45, 0.50, -0.10),
            SIMD3(1.25, 0.02, 0.32),
            SIMD3(1.75, -0.25, -0.18),
            SIMD3(0.95, 0.36, 0.22)
        ]
        for placement in placements {
            let position = cameraPosition + forward * placement.x +
                right * placement.y + up * placement.z
            appendObject(position: position)
        }
        GVLog.capture.notice("AR objects: seeded \(self.objects.count) objects in environment")
    }

    private func consume(_ event: ARObjectSourceEvent) {
        switch event {
        case .firstFrame:
            snapshot.state = .running
            snapshot.sourceLabel = capability.isSynthetic ? "AR OBJECTS STAGE" : "AR OBJECTS WORLD"
            snapshot.objectCount = objects.count
            snapshot.errorMessage = nil
        case let .quality(label):
            snapshot.formatLabel = label
        case let .tracking(metadata):
            latestCameraTransform = metadata.cameraTransform
            snapshot.state = .running
            snapshot.sourceLabel = capability.isSynthetic ? "AR OBJECTS STAGE" : "AR OBJECTS WORLD"
            snapshot.formatLabel = "TRACKING NORMAL"
            snapshot.objectCount = objects.count
            snapshot.errorMessage = nil
            seedInitialField(cameraTransform: metadata.cameraTransform)
        case let .framePose(metadata):
            latestCameraTransform = metadata.cameraTransform
            if snapshot.state == .running {
                stepScenePhysics()
            }
        case let .interrupted(reason):
            snapshot.state = .interrupted
            snapshot.errorMessage = reason
        case .resumed:
            snapshot.state = .starting
            snapshot.errorMessage = nil
        case let .failed(message):
            snapshot.state = .failed
            snapshot.sourceLabel = "AR OBJECTS FAILURE"
            snapshot.errorMessage = message
        }
    }
}

// swiftlint:enable file_length
