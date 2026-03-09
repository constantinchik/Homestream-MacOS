import SwiftUI

struct MenuBarView: View {
    @ObservedObject var streamManager: StreamManager
    @State private var hostInput: String = ""
    @State private var portInput: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Status
            HStack {
                Circle()
                    .fill(streamManager.isStreaming ? .green : .gray)
                    .frame(width: 8, height: 8)
                Text(streamManager.statusMessage)
                    .font(.headline)
            }
            .padding(.bottom, 4)

            // SRT destination
            Text("SRT Destination")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 4) {
                TextField("Host", text: $hostInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { saveDestination() }
                Text(":")
                    .foregroundStyle(.secondary)
                TextField("Port", text: $portInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 56)
                    .onSubmit { saveDestination() }
            }
            .disabled(streamManager.isStreaming)

            Divider()

            // Sources
            Text("Sources")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(streamManager.sources) { source in
                Button {
                    Task {
                        if streamManager.isStreaming {
                            await streamManager.switchSource(to: source)
                        } else {
                            await streamManager.startStreaming(source: source)
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: source.iconName)
                            .frame(width: 16)
                        Text(source.name)
                        Spacer()
                        if streamManager.activeSource == source {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .buttonStyle(.plain)
            }

            Divider()

            // Start/Stop
            if streamManager.isStreaming {
                Button("Stop Streaming") {
                    Task { await streamManager.stopStreaming() }
                }
                .foregroundStyle(.red)
            }

            Button("Quit") {
                Task {
                    await streamManager.stopStreaming()
                    NSApp.terminate(nil)
                }
            }
        }
        .padding(12)
        .frame(width: 280)
        .task {
            hostInput = streamManager.host
            portInput = streamManager.port
            await streamManager.refreshSources()
        }
    }

    private func saveDestination() {
        let h = hostInput.trimmingCharacters(in: .whitespaces)
        let p = portInput.trimmingCharacters(in: .whitespaces)
        if !h.isEmpty { streamManager.host = h }
        if !p.isEmpty { streamManager.port = p }
    }
}

extension CaptureSource {
    var iconName: String {
        switch self {
        case .screen: return "display"
        case .camera: return "camera"
        }
    }
}
