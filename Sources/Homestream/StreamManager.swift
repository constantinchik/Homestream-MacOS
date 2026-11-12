import AVFoundation
import Foundation
import ScreenCaptureKit

private func log(_ msg: String) { hslog("[stream] \(msg)") }

@MainActor
final class StreamManager: ObservableObject {
    @Published var isStreaming = false
    @Published var activeSource: CaptureSource?
    @Published var sources: [CaptureSource] = []
    @Published var statusMessage = "Idle"

    private var screenCapture: ScreenCapture?
    private var cameraCapture: CameraCapture?
    private var ffmpeg: FFmpegProcess?
    private var retryTask: Task<Void, Never>?
    /// Active Streamer-mode mirror. Survives ffmpeg retries; released on stop or when
    /// switching to any other source.
    private var mirror: VirtualDisplayMirror?

    var host: String {
        get { UserDefaults.standard.string(forKey: "srt_host") ?? "192.168.2.100" }
        set { UserDefaults.standard.set(newValue, forKey: "srt_host") }
    }

    var port: String {
        get { UserDefaults.standard.string(forKey: "srt_port") ?? "9000" }
        set { UserDefaults.standard.set(newValue, forKey: "srt_port") }
    }

    var srtTarget: String { "srt://\(host):\(port)" }

    func refreshSources() async {
        var fresh = await availableSources()
        // While mirroring, macOS hides the physical display (it's a mirror
        // slave), so keep its entries from before to allow switching back.
        if let mirror {
            let id = mirror.physicalID
            let hasPhysical = fresh.contains { $0.displayID == id }
            if !hasPhysical {
                let kept = sources.filter { $0.displayID == id }
                fresh.insert(contentsOf: kept, at: 0)
            }
        }
        sources = fresh
    }

    func startStreaming(source: CaptureSource) async {
        await stopStreaming()

        activeSource = source
        isStreaming = true
        statusMessage = "Starting..."

        await startPipeline(source: source)
    }

    func stopStreaming() async {
        retryTask?.cancel()
        retryTask = nil

        await stopCapture()
        await releaseMirror()
        ffmpeg?.stop()
        ffmpeg = nil

        isStreaming = false
        activeSource = nil
        statusMessage = "Idle"
    }

    func switchSource(to source: CaptureSource) async {
        guard isStreaming, ffmpeg?.isRunning == true else {
            await startStreaming(source: source)
            return
        }

        // Keep the ffmpeg process and its SRT connection: all sources share
        // one fixed output size, so only the capture side changes.
        retryTask?.cancel()
        retryTask = nil
        statusMessage = "Switching..."
        await stopCapture()
        if case .streamerScreen(let display) = source, mirror?.physicalID == display.displayID {
            // same Streamer-mode display: keep the mirror
        } else {
            await releaseMirror()
        }

        activeSource = source
        await startPipeline(source: source)
    }

    // MARK: - Private

    private func startPipeline(source: CaptureSource) async {
        log("startPipeline: \(source.name) (\(source.width)x\(source.height) @ \(source.fps)fps)")

        // Create ffmpeg process (launches lazily on first frame)
        if ffmpeg == nil || ffmpeg?.isRunning != true {
            ffmpeg = FFmpegProcess(host: host, port: port)
        }

        guard let ffmpeg else { return }

        // Start capture
        do {
            switch source {
            case .screen(let display):
                log("Starting screen capture for display \(display.displayID)")
                // Re-resolve: the SCDisplay may be stale after leaving Streamer mode
                let target = await resolveDisplay(display.displayID) ?? display
                let capture = ScreenCapture { pixelBuffer in
                    ffmpeg.writeFrame(pixelBuffer)
                }
                try await capture.start(display: target)
                screenCapture = capture
                log("Screen capture started")

            case .streamerScreen(let display):
                let virtualDisplay: SCDisplay
                if let mirror, mirror.physicalID == display.displayID,
                   let existing = await resolveDisplay(mirror.virtualID) {
                    virtualDisplay = existing
                } else {
                    await releaseMirror()
                    log("Starting Streamer mode for display \(display.displayID)")
                    let newMirror = VirtualDisplayMirror(mirroring: display.displayID)
                    mirror = newMirror
                    virtualDisplay = try await newMirror.start()
                }
                let capture = ScreenCapture { pixelBuffer in
                    ffmpeg.writeFrame(pixelBuffer)
                }
                try await capture.start(display: virtualDisplay)
                screenCapture = capture
                log("Streamer mode capture started on virtual display \(virtualDisplay.displayID)")

            case .camera(let device):
                log("Starting camera capture: \(device.localizedName)")
                let capture = CameraCapture { pixelBuffer in
                    ffmpeg.writeFrame(pixelBuffer)
                }
                try capture.start(device: device)
                cameraCapture = capture
                log("Camera capture started")
            }
            statusMessage = "Streaming"
        } catch {
            log("Capture error: \(error)")
            statusMessage = "Capture error: \(error.localizedDescription)"
            await stopCapture()
            await releaseMirror()
            ffmpeg.stop()
            self.ffmpeg = nil
            isStreaming = false
            activeSource = nil
            return
        }

        // Monitor ffmpeg and retry on failure
        startRetryMonitor(source: source)
    }

    private func startRetryMonitor(source: CaptureSource) {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.isStreaming else { return }

                if self.ffmpeg?.isRunning != true {
                    let err = self.ffmpeg?.lastError ?? ""
                    let frames = self.ffmpeg?.framesWritten ?? 0
                    let exitCode = self.ffmpeg?.lastExitCode.map { "exit \($0)" } ?? "?"
                    self.statusMessage = "Retry (\(exitCode), \(frames)f) \(err.prefix(60))"
                    await self.stopCapture()
                    self.ffmpeg = nil

                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { return }

                    await self.startPipeline(source: source)
                    return  // startPipeline creates a new monitor
                }
            }
        }
    }

    private func stopCapture() async {
        await screenCapture?.stop()
        screenCapture = nil
        cameraCapture?.stop()
        cameraCapture = nil
    }

    private func releaseMirror() async {
        guard let current = mirror else { return }
        mirror = nil
        await current.stop()
    }

    /// Fresh SCDisplay for an ID, waiting briefly for it to (re)appear after a
    /// display reconfiguration.
    private func resolveDisplay(_ id: CGDirectDisplayID) async -> SCDisplay? {
        for _ in 0..<20 {
            if let content = try? await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true),
               let display = content.displays.first(where: { $0.displayID == id }) {
                return display
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }
}

extension CaptureSource {
    /// Physical display this source captures, if any.
    var displayID: CGDirectDisplayID? {
        switch self {
        case .screen(let d), .streamerScreen(let d): return d.displayID
        case .camera: return nil
        }
    }
}
