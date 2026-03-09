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
        sources = await availableSources()
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
        ffmpeg?.stop()
        ffmpeg = nil

        isStreaming = false
        activeSource = nil
        statusMessage = "Idle"
    }

    func switchSource(to source: CaptureSource) async {
        guard isStreaming else {
            await startStreaming(source: source)
            return
        }

        statusMessage = "Switching..."
        await stopCapture()

        let needsNewFFmpeg = activeSource.map { existing in
            existing.width != source.width || existing.height != source.height || existing.fps != source.fps
        } ?? true

        if needsNewFFmpeg {
            ffmpeg?.stop()
            ffmpeg = nil
        }

        activeSource = source
        await startPipeline(source: source)
    }

    // MARK: - Private

    private func startPipeline(source: CaptureSource) async {
        log("startPipeline: \(source.name) (\(source.width)x\(source.height) @ \(source.fps)fps)")

        // Create ffmpeg process (launches lazily on first frame)
        if ffmpeg == nil || ffmpeg?.isRunning != true {
            ffmpeg = FFmpegProcess(fps: source.fps, host: host, port: port)
        }

        guard let ffmpeg else { return }

        // Start capture
        do {
            switch source {
            case .screen(let display):
                log("Starting screen capture for display \(display.displayID)")
                let capture = ScreenCapture { pixelBuffer in
                    ffmpeg.writeFrame(pixelBuffer)
                }
                try await capture.start(display: display)
                screenCapture = capture
                log("Screen capture started")

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
            isStreaming = false
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

                    try? await Task.sleep(for: .seconds(3))
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
}
