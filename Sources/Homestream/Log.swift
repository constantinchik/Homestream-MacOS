import Foundation

func hslog(_ msg: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "[\(ts)] \(msg)"
    // stdout — visible when launched from terminal
    print(line)
    // Append to log file using Foundation
    let path = "/tmp/HomeStream.log"
    if let data = (line + "\n").data(using: .utf8) {
        if FileManager.default.fileExists(atPath: path) {
            if let fh = FileHandle(forWritingAtPath: path) {
                fh.seekToEndOfFile()
                fh.write(data)
                fh.closeFile()
            }
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }
}
