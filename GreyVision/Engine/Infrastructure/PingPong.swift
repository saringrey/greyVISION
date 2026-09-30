import Metal

final class PingPongTextures: @unchecked Sendable {
    private(set) var read: MTLTexture
    private(set) var write: MTLTexture

    init?(device: MTLDevice, key: TexturePoolKey, label: String) {
        guard key.isValid else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: key.pixelFormat,
            width: key.width,
            height: key.height,
            mipmapped: false
        )
        descriptor.usage = key.usage
        descriptor.storageMode = key.storageMode
        guard let read = device.makeTexture(descriptor: descriptor),
              let write = device.makeTexture(descriptor: descriptor)
        else { return nil }
        read.label = "\(label) read"
        write.label = "\(label) write"
        self.read = read
        self.write = write
    }

    func swap() {
        Swift.swap(&read, &write)
    }
}
