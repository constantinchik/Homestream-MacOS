import AVFoundation
import CoreMedia
import CoreVideo

final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let writeFrame: (CVPixelBuffer) -> Void
    private let queue = DispatchQueue(label: "homestream.camera-capture", qos: .userInteractive)

    init(writeFrame: @escaping (CVPixelBuffer) -> Void) {
        self.writeFrame = writeFrame
    }

    func start(device: AVCaptureDevice) throws {
        hslog("[camera] Configuring session for: \(device.localizedName)")

        session.beginConfiguration()
        session.sessionPreset = session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw CaptureError.cannotAddInput
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        // Use BGRA for camera too — simpler, and VideoToolbox handles conversion
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            // Fixed stream canvas, shared with screen capture
            kCVPixelBufferWidthKey as String: FFmpegProcess.outputWidth,
            kCVPixelBufferHeightKey as String: FFmpegProcess.outputHeight,
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)

        guard session.canAddOutput(output) else {
            throw CaptureError.cannotAddOutput
        }
        session.addOutput(output)

        session.commitConfiguration()
        hslog("[camera] Session configured, starting on background queue")

        // startRunning() is synchronous and blocks — must not be on main thread
        queue.async { [weak self] in
            self?.session.startRunning()
            hslog("[camera] Session running=\(self?.session.isRunning ?? false)")
        }
    }

    func stop() {
        session.stopRunning()
        hslog("[camera] Session stopped")
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        writeFrame(pixelBuffer)
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // Frame dropped — expected under back-pressure
    }

    enum CaptureError: Error, LocalizedError {
        case cannotAddInput
        case cannotAddOutput

        var errorDescription: String? {
            switch self {
            case .cannotAddInput: return "Cannot add camera input to session"
            case .cannotAddOutput: return "Cannot add camera output to session"
            }
        }
    }
}
