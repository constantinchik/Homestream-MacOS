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
            if streamManager.isStreaming {
                RecordingIcon()
            } else {
                Image(systemName: "video")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
