import CoreVideo
import Foundation

final class FFmpegProcess {
    // Fixed output canvas. Every source is scaled to this at capture time so a
    // single ffmpeg/SRT session survives source switches (reconnecting to the
    // OBS listener costs several seconds).
    static let outputWidth = 1920
    static let outputHeight = 1080
    static let outputFPS = 60

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stderrPipe: Pipe?
    private let fps = FFmpegProcess.outputFPS
    private let pendingLock = NSLock()
    private var pendingWrites = 0
    private var loggedSizeMismatch = false
    private let host: String
    private let port: String
    private let queue = DispatchQueue(label: "homestream.ffmpeg-write", qos: .userInteractive)
    private var isWritable = false
    private var started = false

    private var width: Int = 0
    private var height: Int = 0
    private var pixFmtName: String = "bgra"

    private(set) var lastError: String = ""
    private(set) var lastExitCode: Int32?
    private(set) var framesWritten: UInt64 = 0

    private static let ffmpegPath: String = {
        // Homebrew's plain `ffmpeg` formula dropped libsrt in 9.0; the keg-only
        // `ffmpeg-full` still has it, so prefer that when installed.
        let candidates = [
            "/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg",
            "/usr/local/opt/ffmpeg-full/bin/ffmpeg",
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? "/opt/homebrew/bin/ffmpeg"
    }()

    init(host: String, port: String) {
        self.host = host
        self.port = port
    }

    private func launch(width: Int, height: Int, pixFmt: String) throws {
        self.width = width
        self.height = height
        self.pixFmtName = pixFmt

        let inputPipe = Pipe()
        let errPipe = Pipe()
        let proc = Process()

        proc.executableURL = URL(fileURLWithPath: Self.ffmpegPath)
        proc.arguments = [
            "-y",
            // Timestamp frames by arrival so 30fps cameras and 60fps screens
            // share one input; the CFR output duplicates frames to fill gaps
            // (including the brief pause while switching sources).
            "-use_wallclock_as_timestamps", "1",
            "-f", "rawvideo",
            "-pix_fmt", pixFmt,
            "-s", "\(width)x\(height)",
            "-i", "pipe:0",
            "-fps_mode", "cfr",
            "-r", "\(fps)",
            "-c:v", "h264_videotoolbox",
            "-b:v", "30M",
            "-realtime", "1",
            "-g", "\(fps)",
            "-profile:v", "high",
            "-level", "5.2",
            "-f", "mpegts",
            "srt://\(host):\(port)?mode=caller&latency=100000",
        ]

        hslog("[ffmpeg] Launch: \(width)x\(height) \(pixFmt) \(fps)fps → srt://\(host):\(port)")

        proc.standardInput = inputPipe
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = errPipe

        var stderrBuf = ""
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                stderrBuf += text
                if stderrBuf.count > 2048 { stderrBuf = String(stderrBuf.suffix(2048)) }
                self?.lastError = stderrBuf
            }
        }

        proc.terminationHandler = { [weak self] p in
            self?.isWritable = false
            self?.lastExitCode = p.terminationStatus
            errPipe.fileHandleForReading.readabilityHandler = nil
            let lines = stderrBuf.split(separator: "\n").filter { !$0.isEmpty }
            if let last = lines.last { self?.lastError = String(last) }
            hslog("[ffmpeg] Exited code=\(p.terminationStatus) frames=\(self?.framesWritten ?? 0)")
            if !stderrBuf.isEmpty {
                hslog("[ffmpeg] stderr: \(String(stderrBuf.suffix(300)))")
            }
        }

        try proc.run()
        hslog("[ffmpeg] pid=\(proc.processIdentifier)")
        self.process = proc
        self.stdinPipe = inputPipe
        self.stderrPipe = errPipe
        self.isWritable = true
        self.framesWritten = 0
    }

    func writeFrame(_ pixelBuffer: CVPixelBuffer) {
        let bufW = CVPixelBufferGetWidth(pixelBuffer)
        let bufH = CVPixelBufferGetHeight(pixelBuffer)
        let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
        let fmt = CVPixelBufferGetPixelFormatType(pixelBuffer)

        // Determine ffmpeg pixel format name
        let ffmpegFmt: String
        switch fmt {
        case kCVPixelFormatType_32BGRA: ffmpegFmt = "bgra"
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: ffmpegFmt = "nv12"
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: ffmpegFmt = "nv12"
        default: ffmpegFmt = "bgra"
        }

        // The stream's geometry is fixed for the session; a differently sized
        // frame would corrupt the rawvideo pipe, so drop it.
        if bufW != Self.outputWidth || bufH != Self.outputHeight {
            if !loggedSizeMismatch {
                hslog("[ffmpeg] Dropping \(bufW)x\(bufH) frame (expected \(Self.outputWidth)x\(Self.outputHeight))")
                loggedSizeMismatch = true
            }
            return
        }

        // Lazy start ffmpeg on first frame
        if !started {
            hslog("[ffmpeg] First frame: \(bufW)x\(bufH) planes=\(planeCount) fmt=\(fourCC(fmt)) → \(ffmpegFmt)")
            do {
                try launch(width: bufW, height: bufH, pixFmt: ffmpegFmt)
                started = true
            } catch {
                hslog("[ffmpeg] Failed to launch: \(error)")
                return
            }
        }

        guard isWritable else { return }

        // Back-pressure: if ffmpeg falls behind (or is still connecting), drop
        // frames instead of queueing seconds of stale video.
        pendingLock.lock()
        if pendingWrites >= 2 {
            pendingLock.unlock()
            return
        }
        pendingWrites += 1
        pendingLock.unlock()
        var handedOff = false
        defer {
            if !handedOff {
                pendingLock.lock(); pendingWrites -= 1; pendingLock.unlock()
            }
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let frameData: Data

        if planeCount == 0 {
            // Single-plane format (BGRA)
            guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
            let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let bytesPerPixel = 4  // BGRA
            let rowBytes = bufW * bytesPerPixel

            if stride == rowBytes {
                frameData = Data(bytes: base, count: stride * bufH)
            } else {
                var data = Data(capacity: rowBytes * bufH)
                for row in 0..<bufH {
                    data.append(base.advanced(by: row * stride)
                        .assumingMemoryBound(to: UInt8.self), count: rowBytes)
                }
                frameData = data
            }
        } else if planeCount == 2 {
            // NV12 — two planes
            guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
                  let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else { return }

            let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
            let yH = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
            let uvH = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)

            var data = Data(capacity: bufW * yH + bufW * uvH)

            if yStride == bufW {
                data.append(yBase.assumingMemoryBound(to: UInt8.self), count: yStride * yH)
            } else {
                for row in 0..<yH {
                    data.append(yBase.advanced(by: row * yStride)
                        .assumingMemoryBound(to: UInt8.self), count: bufW)
                }
            }

            if uvStride == bufW {
                data.append(uvBase.assumingMemoryBound(to: UInt8.self), count: uvStride * uvH)
            } else {
                for row in 0..<uvH {
                    data.append(uvBase.advanced(by: row * uvStride)
                        .assumingMemoryBound(to: UInt8.self), count: bufW)
                }
            }
            frameData = data
        } else {
            return
        }

        if framesWritten == 0 {
            hslog("[ffmpeg] Writing first frame: \(frameData.count) bytes")
        }

        handedOff = true
        queue.async { [weak self] in
            guard let self else { return }
            defer {
                self.pendingLock.lock(); self.pendingWrites -= 1; self.pendingLock.unlock()
            }
            guard self.isWritable else { return }
            do {
                try self.stdinPipe?.fileHandleForWriting.write(contentsOf: frameData)
                self.framesWritten += 1
            } catch {
                hslog("[ffmpeg] Pipe write error: \(error.localizedDescription)")
                self.isWritable = false
            }
        }
    }

    var isRunning: Bool {
        if !started { return true }
        return process?.isRunning ?? false
    }

    func stop() {
        isWritable = false
        // Drain pending writes before closing
        queue.sync {}
        try? stdinPipe?.fileHandleForWriting.close()
        stdinPipe = nil

        guard let proc = process else { return }
        process = nil

        // EOF (pipe closed above) lets ffmpeg flush and send an SRT shutdown,
        // so OBS frees its listener immediately. Killing it instead leaves OBS
        // holding a dead peer and the next caller stalls for seconds.
        let deadline = Date().addingTimeInterval(1.0)
        while proc.isRunning && Date() < deadline { usleep(20_000) }
        if proc.isRunning {
            proc.interrupt()  // SIGINT: still a graceful ffmpeg shutdown
            let hardDeadline = Date().addingTimeInterval(0.5)
            while proc.isRunning && Date() < hardDeadline { usleep(20_000) }
        }
        if proc.isRunning { proc.terminate() }
    }
}

private func fourCC(_ fmt: OSType) -> String {
    let chars: [Character] = [
        Character(UnicodeScalar((fmt >> 24) & 0xFF)!),
        Character(UnicodeScalar((fmt >> 16) & 0xFF)!),
        Character(UnicodeScalar((fmt >> 8) & 0xFF)!),
        Character(UnicodeScalar(fmt & 0xFF)!),
    ]
    return String(chars)
}
