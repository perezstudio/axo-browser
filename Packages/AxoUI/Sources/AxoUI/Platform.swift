import AxoWeb
import SwiftUI

extension Image {
    /// An image from the platform's image type (`NSImage` or `UIImage`).
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

extension View {
    /// Runs `action` when the person presses Esc, on the Mac. iPhone and iPad close overlays
    /// with their own controls.
    func onExitCommandIfAvailable(perform action: @escaping () -> Void) -> some View {
        #if os(macOS)
        onExitCommand(perform: action)
        #else
        self
        #endif
    }
}
