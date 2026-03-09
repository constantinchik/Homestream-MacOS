import AppKit
import SwiftUI

struct RecordingIcon: View {
    @State private var bright = true

    var body: some View {
        // MenuBarExtra labels don't support SwiftUI animation,
        // so use a Timer to toggle opacity manually
        Image(nsImage: recordingMenuBarIcon(bright: bright))
            .onReceive(
                Timer.publish(every: 0.8, on: .main, in: .common).autoconnect()
            ) { _ in
                bright.toggle()
            }
    }
}

private func recordingMenuBarIcon(bright: Bool) -> NSImage {
    let size = NSSize(width: 20, height: 14)
    let color: NSColor = bright ? .systemRed : .white
    let image = NSImage(size: size, flipped: false) { rect in
        guard let symbol = NSImage(systemSymbolName: "video.fill", accessibilityDescription: nil) else {
            return false
        }
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let configured = symbol.withSymbolConfiguration(config) ?? symbol

        let symbolRect = CGRect(
            x: (rect.width - configured.size.width) / 2,
            y: (rect.height - configured.size.height) / 2,
            width: configured.size.width,
            height: configured.size.height
        )
        configured.draw(in: symbolRect, from: .zero, operation: .sourceOver, fraction: 1.0)

        color.set()
        symbolRect.fill(using: .sourceAtop)

        return true
    }
    image.isTemplate = false
    return image
}
