import Foundation
@preconcurrency import Metal

struct TexturePoolKey: Hashable, Sendable {
    var width: Int
    var height: Int
    var pixelFormat: MTLPixelFormat
    var usage: MTLTextureUsage
    var storageMode: MTLStorageMode

    var isValid: Bool { width > 0 && height > 0 && pixelFormat != .invalid }

    init(
        width: Int,
        height: Int,
        pixelFormat: MTLPixelFormat = .rgba16Float,
        usage: MTLTextureUsage = [.shaderRead, .shaderWrite],
        storageMode: MTLStorageMode = .private
    ) {
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        self.usage = usage
        self.storageMode = storageMode
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.width == rhs.width &&
            lhs.height == rhs.height &&
            lhs.pixelFormat.rawValue == rhs.pixelFormat.rawValue &&
            lhs.usage.rawValue == rhs.usage.rawValue &&
            lhs.storageMode.rawValue == rhs.storageMode.rawValue
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(width)
        hasher.combine(height)
        hasher.combine(pixelFormat.rawValue)
        hasher.combine(usage.rawValue)
        hasher.combine(storageMode.rawValue)
    }
}

struct TexturePoolDiagnostics: Equatable, Sendable {
    var allocatedTextures: Int
    var availableTextures: Int
    var inFlightTextures: Int
    var allocatedBytes: Int
    var budgetBytes: Int
    var reuseCount: UInt64
    var allocationCount: UInt64
    var rejectedRequests: UInt64
}

final class TexturePool: @unchecked Sendable {
    private let device: MTLDevice
    private let lock = NSLock()
    private var available: [TexturePoolKey: [MTLTexture]] = [:]
    private var keys: [ObjectIdentifier: TexturePoolKey] = [:]
    private var inFlight: Set<ObjectIdentifier> = []
    private var allocatedBytes = 0
    private var reuseCount: UInt64 = 0
    private var allocationCount: UInt64 = 0
    private var rejectedRequests: UInt64 = 0

    let budgetBytes: Int

    init(device: MTLDevice, budgetBytes: Int = 192 * 1024 * 1024) {
        self.device = device
        self.budgetBytes = max(budgetBytes, 1)
    }

    func checkout(_ key: TexturePoolKey, label: String? = nil) -> MTLTexture? {
        lock.withLock {
            guard key.isValid else {
                rejectedRequests &+= 1
                return nil
            }

            if var bucket = available[key], let texture = bucket.popLast() {
                available[key] = bucket
                inFlight.insert(ObjectIdentifier(texture))
                reuseCount &+= 1
                texture.label = label ?? texture.label
                return texture
            }

            let bytes = Self.estimatedBytes(for: key)
            guard allocatedBytes + bytes <= budgetBytes else {
                rejectedRequests &+= 1
                return nil
            }

            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: key.pixelFormat,
                width: key.width,
                height: key.height,
                mipmapped: false
            )
            descriptor.usage = key.usage
            descriptor.storageMode = key.storageMode
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                rejectedRequests &+= 1
                return nil
            }
            texture.label = label ?? "greyVISION pooled texture"
            let identifier = ObjectIdentifier(texture)
            keys[identifier] = key
            inFlight.insert(identifier)
            allocatedBytes += bytes
            allocationCount &+= 1
            return texture
        }
    }

    /// Makes a texture reusable only after every GPU reference in the command
    /// buffer has completed.
    func recycle(_ texture: MTLTexture, after commandBuffer: MTLCommandBuffer) {
        commandBuffer.addCompletedHandler { [weak self, texture] _ in
            self?.recycle(texture)
        }
    }

    func recycle(_ texture: MTLTexture) {
        lock.withLock {
            let identifier = ObjectIdentifier(texture)
            guard inFlight.remove(identifier) != nil, let key = keys[identifier] else { return }
            available[key, default: []].append(texture)
        }
    }

    func purgeAvailable() {
        lock.withLock {
            for bucket in available.values {
                for texture in bucket {
                    let identifier = ObjectIdentifier(texture)
                    if let key = keys.removeValue(forKey: identifier) {
                        allocatedBytes -= Self.estimatedBytes(for: key)
                    }
                }
            }
            available.removeAll(keepingCapacity: false)
            allocatedBytes = max(allocatedBytes, 0)
        }
    }

    var diagnostics: TexturePoolDiagnostics {
        lock.withLock {
            TexturePoolDiagnostics(
                allocatedTextures: keys.count,
                availableTextures: available.values.reduce(0) { $0 + $1.count },
                inFlightTextures: inFlight.count,
                allocatedBytes: allocatedBytes,
                budgetBytes: budgetBytes,
                reuseCount: reuseCount,
                allocationCount: allocationCount,
                rejectedRequests: rejectedRequests
            )
        }
    }

    static func estimatedBytes(for key: TexturePoolKey) -> Int {
        key.width * key.height * bytesPerPixel(key.pixelFormat)
    }

    static func bytesPerPixel(_ format: MTLPixelFormat) -> Int {
        switch format {
        case .r8Unorm, .r8Snorm, .r8Uint, .r8Sint: 1
        case .r16Float, .r16Unorm, .rg8Unorm: 2
        case .rg16Float, .r32Float, .rgba8Unorm, .rgba8Unorm_srgb,
             .bgra8Unorm, .bgra8Unorm_srgb: 4
        case .rgba16Float: 8
        case .rgba32Float: 16
        default: 4
        }
    }
}
