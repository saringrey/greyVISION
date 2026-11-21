import CoreMediaIO
import Foundation

if #available(macOS 13.0, *) {
    let providerSource = GVVirtualCameraProviderSource()
    CMIOExtensionProvider.startService(provider: providerSource.provider)
    dispatchMain()
}
