import SwiftUI

@main
struct HomestreamApp: App {
    @StateObject private var streamManager = StreamManager()

    init() {
        // Ignore SIGPIPE — async pipe writes after ffmpeg exit must not crash the app
        signal(SIGPIPE, SIG_IGN)
        hslog("HomeStream started, pid=\(ProcessInfo.processInfo.processIdentifier)")
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(streamManager: streamManager)
        } label: {
            HStack(spacing: 2) {
                Image(systemName: streamManager.isStreaming ? "video.fill" : "video")
                if streamManager.isStreaming {
                    Circle()
                        .fill(.red)
                        .frame(width: 7, height: 7)
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}
