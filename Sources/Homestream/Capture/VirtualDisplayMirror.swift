import CGVirtualDisplayBridge
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// "Streamer mode" (AirPlay-style): creates a virtual 1920×1080@60 display and makes a
/// physical display mirror it. macOS re-renders the desktop at 1080p (the
/// physical screen shows it letterboxed) and we capture the virtual display at
/// its native resolution: no scaling, no black bars in the stream.
///
/// Safety: the virtual display only lives as long as this object (and this
/// process). If the app quits or crashes, macOS removes the display and the
/// mirror set with it. Mirroring is applied `.forSession` only.
@MainActor
final class VirtualDisplayMirror {
    /// Display IDs of virtual displays we own, so source listing can hide them.
    private(set) static var ownedDisplayIDs: Set<CGDirectDisplayID> = []

    private static let vendorID: UInt32 = 0x4853   // "HS"
    private static let productID: UInt32 = 0x1080
    private static let serialKey = "tv_virtual_serial"

    let physicalID: CGDirectDisplayID
    private var virtualDisplay: CGVirtualDisplay?
    private let originalMode: CGDisplayMode?

    var virtualID: CGDirectDisplayID { virtualDisplay?.displayID ?? kCGNullDirectDisplay }

    init(mirroring physicalID: CGDirectDisplayID) {
        self.physicalID = physicalID
        self.originalMode = CGDisplayCopyDisplayMode(physicalID)
    }

    /// Creates the virtual display, mirrors the physical display onto it and
    /// returns the SCDisplay to capture.
    func start() async throws -> SCDisplay {
        let display = try await createOnlineDisplay()
        let vid = display.displayID

        // Physical mirrors virtual → virtual becomes the master (1080p desktop),
        // exactly like AirPlay mirroring does.
        try Self.configure { CGConfigureDisplayMirrorOfDisplay($0, self.physicalID, vid) }
        hslog("[mirror] Display \(physicalID) now mirrors \(vid)")

        var found: SCDisplay?
        try await waitUntil(timeout: 4) {
            let content = try? await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
            found = content?.displays.first { $0.displayID == vid }
            return found != nil
        }
        guard let found else { throw MirrorError.notCapturable }
        return found
    }

    /// Removes the virtual display and restores the physical display.
    func stop() async {
        guard let display = virtualDisplay else { return }
        let vid = display.displayID

        // Drop the virtual display first: macOS dissolves the mirror set with
        // it. Un-mirroring first would briefly turn it into an extended
        // desktop and windows could jump onto it.
        virtualDisplay = nil
        Self.ownedDisplayIDs.remove(vid)
        try? await waitUntil(timeout: 2) { !Self.onlineDisplays().contains(vid) }

        if CGDisplayMirrorsDisplay(physicalID) != kCGNullDirectDisplay {
            try? Self.configure { CGConfigureDisplayMirrorOfDisplay($0, self.physicalID, kCGNullDirectDisplay) }
        }
        if let originalMode,
           CGDisplayCopyDisplayMode(physicalID)?.ioDisplayModeID != originalMode.ioDisplayModeID {
            try? Self.configure { CGConfigureDisplayWithDisplayMode($0, self.physicalID, originalMode, nil) }
        }
        let gone = !Self.onlineDisplays().contains(vid)
        hslog("[mirror] Virtual display \(vid) released (offline=\(gone)), display \(physicalID) restored")
    }

    // MARK: - Virtual display

    /// macOS can permanently reject a given vendor/product/serial identity
    /// (seen on macOS 27: the display is accepted but never comes online). The
    /// serial is persisted so display preferences stay stable, and rotated
    /// once if the current identity doesn't come online.
    private func createOnlineDisplay() async throws -> CGVirtualDisplay {
        let defaults = UserDefaults.standard
        var serial = UInt32(truncatingIfNeeded: defaults.integer(forKey: Self.serialKey))
        if serial == 0 { serial = 0x4853_0001 }

        for attempt in 0..<2 {
            let display = try makeDisplay(serial: serial)
            virtualDisplay = display
            let vid = display.displayID
            Self.ownedDisplayIDs.insert(vid)
            do {
                try await waitUntil(timeout: 2.5) {
                    Self.onlineDisplays().contains(vid) && CGDisplayCopyDisplayMode(vid) != nil
                }
                defaults.set(Int(serial), forKey: Self.serialKey)
                hslog("[mirror] Virtual display \(vid) online (serial \(String(serial, radix: 16)))")
                return display
            } catch {
                hslog("[mirror] Virtual display serial \(String(serial, radix: 16)) never came online (attempt \(attempt + 1))")
                virtualDisplay = nil
                Self.ownedDisplayIDs.remove(vid)
                serial &+= 1
            }
        }
        throw MirrorError.timeout
    }

    private func makeDisplay(serial: UInt32) throws -> CGVirtualDisplay {
        let w = UInt32(FFmpegProcess.outputWidth)
        let h = UInt32(FFmpegProcess.outputHeight)

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = DispatchQueue.main
        descriptor.setDispatchQueue(DispatchQueue.main)
        descriptor.name = "HomeStream Streamer"
        descriptor.maxPixelsWide = w
        descriptor.maxPixelsHigh = h
        descriptor.sizeInMillimeters = CGSize(width: 1210, height: 680)  // ~55" 16:9
        descriptor.vendorID = Self.vendorID
        descriptor.productID = Self.productID
        descriptor.serialNum = serial
        // sRGB / D65 colorimetry; a display without it may never activate
        descriptor.redPrimary = CGPoint(x: 0.64, y: 0.33)
        descriptor.greenPrimary = CGPoint(x: 0.30, y: 0.60)
        descriptor.bluePrimary = CGPoint(x: 0.15, y: 0.06)
        descriptor.whitePoint = CGPoint(x: 0.3127, y: 0.3290)
        descriptor.terminationHandler = { _, _ in
            hslog("[mirror] Virtual display terminated by system")
        }

        let display = CGVirtualDisplay(descriptor: descriptor)
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 0
        settings.modes = [
            CGVirtualDisplayMode(width: w, height: h,
                                 refreshRate: Double(FFmpegProcess.outputFPS)),
        ]
        guard display.apply(settings), display.displayID != kCGNullDirectDisplay else {
            throw MirrorError.createFailed
        }
        return display
    }

    // MARK: - Helpers

    private static func configure(_ body: (CGDisplayConfigRef?) -> CGError) throws {
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success else { throw MirrorError.configFailed }
        guard body(cfg) == .success else {
            CGCancelDisplayConfiguration(cfg)
            throw MirrorError.configFailed
        }
        guard CGCompleteDisplayConfiguration(cfg, .forSession) == .success else {
            throw MirrorError.configFailed
        }
    }

    private static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return ids
    }

    private func waitUntil(timeout: TimeInterval, _ check: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await check() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw MirrorError.timeout
    }

    enum MirrorError: Error, LocalizedError {
        case createFailed, configFailed, timeout, notCapturable

        var errorDescription: String? {
            switch self {
            case .createFailed: return "Could not create 1080p virtual display"
            case .configFailed: return "Could not configure display mirroring"
            case .timeout: return "Virtual display did not come online"
            case .notCapturable: return "Virtual display not available to capture"
            }
        }
    }
}
