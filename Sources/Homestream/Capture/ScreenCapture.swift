import CoreMedia
import CoreVideo
import ScreenCaptureKit

final class ScreenCapture: NSObject, SCStreamOutput {
    private var stream: SCStream?
    private let writeFrame: (CVPixelBuffer) -> Void
    private let queue = DispatchQueue(label: "homestream.screen-capture", qos: .userInteractive)

    init(writeFrame: @escaping (CVPixelBuffer) -> Void) {
        self.writeFrame = writeFrame
    }

    func start(display: SCDisplay) async throws {
        let filter = SCContentFilter(display: display, excludingApplications: [],
                                     exceptingWindows: [])

        let config = SCStreamConfiguration()
        // Scale into the fixed stream canvas (letterboxed) so switching sources
        // never changes the ffmpeg input geometry.
        config.width = FFmpegProcess.outputWidth
        config.height = FFmpegProcess.outputHeight
        config.scalesToFit = true
        if #available(macOS 14.0, *) {
            config.preservesAspectRatio = true
        }
        config.backgroundColor = CGColor.black  // unowned(unsafe): must be a long-lived color
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.showsCursor = true
        config.pixelFormat = kCVPixelFormatType_32BGRA

        hslog("[screen] Configuring: \(display.width)x\(display.height) → \(config.width)x\(config.height) BGRA 60fps")

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        hslog("[screen] Capture started")
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        writeFrame(pixelBuffer)
    }
}
