# HomeStream

Native macOS menu bar app that streams your screen or camera to OBS via SRT.

Uses Apple's **AVCaptureSession** for cameras (which triggers macOS camera controls like Center Stage, Portrait Mode, and Studio Light) and **ScreenCaptureKit** for screen capture with cursor support. Frames are piped to **ffmpeg** for H.264 hardware encoding via VideoToolbox and SRT transport.

## Features

- Menu bar app with live recording indicator
- Screen capture via ScreenCaptureKit (60fps, cursor included)
- Camera capture via AVCaptureSession (triggers macOS camera controls)
- Hardware H.264 encoding via VideoToolbox
- SRT streaming to OBS (caller mode)
- Source switching while streaming
- Auto-retry on connection failure
- Configurable SRT destination (persisted in UserDefaults)
- No external Swift dependencies — only Apple frameworks + ffmpeg

## Requirements

- macOS 13+
- ffmpeg with SRT and VideoToolbox support (`brew install ffmpeg`)
- OBS with SRT input configured on the receiving end

## Build

```sh
make build      # Build release binary + app bundle
make install    # Copy to /Applications
make run        # Build and launch
make clean      # Clean build artifacts
```

## Usage

1. Launch HomeStream — a video camera icon appears in the menu bar
2. Click the icon to see available screens and cameras
3. Set SRT destination (default: `192.168.2.100:9000`)
4. Click a source to start streaming
5. In OBS, add a Media Source with `srt://0.0.0.0:9000?mode=listener` (or your configured port)

The icon shows a red dot while streaming. Click a different source to switch without stopping. Click "Stop Streaming" or "Quit" to end.

## Architecture

```
Sources/Homestream/
├── App.swift                  # @main, MenuBarExtra with live indicator
├── Log.swift                  # File + stdout logging
├── StreamManager.swift        # Start/stop/switch orchestrator with retry
├── Capture/
│   ├── CaptureSource.swift    # Unified source enum + device enumeration
│   ├── ScreenCapture.swift    # ScreenCaptureKit → BGRA frames
│   └── CameraCapture.swift    # AVCaptureSession → BGRA frames
├── Encoding/
│   └── FFmpegProcess.swift    # Manages ffmpeg subprocess + stdin pipe
└── Views/
    └── MenuBarView.swift      # Source list, start/stop, status
```

Frames flow as: Native Capture → BGRA pixel buffers → stdin pipe → ffmpeg (h264_videotoolbox) → SRT → OBS
