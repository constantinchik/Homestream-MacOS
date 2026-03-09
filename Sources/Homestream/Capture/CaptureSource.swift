import AVFoundation
import ScreenCaptureKit

enum CaptureSource: Identifiable, Hashable {
    case screen(SCDisplay)
    case camera(AVCaptureDevice)

    var id: String {
        switch self {
        case .screen(let display):
            return "screen-\(display.displayID)"
        case .camera(let device):
            return "camera-\(device.uniqueID)"
        }
    }

    var name: String {
        switch self {
        case .screen(let display):
            return "Display \(display.displayID) (\(display.width)×\(display.height))"
        case .camera(let device):
            return device.localizedName
        }
    }

    var fps: Int {
        switch self {
        case .screen: return 60
        case .camera: return 30
        }
    }

    var width: Int {
        switch self {
        case .screen(let display):
            return display.width
        case .camera:
            return 1920
        }
    }

    var height: Int {
        switch self {
        case .screen(let display):
            return display.height
        case .camera:
            return 1080
        }
    }

    static func == (lhs: CaptureSource, rhs: CaptureSource) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

@MainActor
func availableSources() async -> [CaptureSource] {
    var sources: [CaptureSource] = []

    // Screens via ScreenCaptureKit
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        for display in content.displays {
            sources.append(.screen(display))
        }
        hslog("[sources] Found \(content.displays.count) displays")
    } catch {
        hslog("[sources] Screen capture permission error: \(error.localizedDescription)")
    }

    // Cameras via AVFoundation
    var deviceTypes: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
    if #available(macOS 14.0, *) {
        deviceTypes.append(.external)
    } else {
        deviceTypes.append(.externalUnknown)
    }
    let discovery = AVCaptureDevice.DiscoverySession(
        deviceTypes: deviceTypes,
        mediaType: .video,
        position: .unspecified
    )
    for device in discovery.devices {
        sources.append(.camera(device))
    }

    return sources
}
