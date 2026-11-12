# HomeStream

Native macOS menu bar app that streams your screen or camera to OBS via SRT.

Uses Apple's **AVCaptureSession** for cameras (which triggers macOS camera controls like Center Stage, Portrait Mode, and Studio Light) and **ScreenCaptureKit** for screen capture with cursor support. Frames are piped to **ffmpeg** for H.264 hardware encoding via VideoToolbox and SRT transport.

## Features

- Menu bar app with live recording indicator
- Screen capture via ScreenCaptureKit (60fps, cursor included)
- **Streaming mode**: AirPlay-style 1920×1080 desktop for a full-frame 16:9 stream
- Camera capture via AVCaptureSession (triggers macOS camera controls)
- Hardware H.264 encoding via VideoToolbox
- SRT streaming to OBS (caller mode)
- Near-instant source switching: one SRT session is kept across switches
- Auto-retry on connection failure
- Configurable SRT destination (persisted in UserDefaults)
- No external Swift dependencies: only Apple frameworks + ffmpeg

## Requirements

- macOS 13+ on Apple Silicon (Streaming mode verified on macOS 27)
- **`ffmpeg-full`** from Homebrew: `brew install ffmpeg-full`
  - Homebrew's plain `ffmpeg` formula dropped SRT support in 9.0, so it can't stream. HomeStream looks for `/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg` first, then falls back to `ffmpeg` on the usual paths.
  - Check SRT support: `$(brew --prefix ffmpeg-full)/bin/ffmpeg -hide_banner -protocols | grep -w srt`
- OBS with an SRT listener on the receiving machine

## Install

### From a release

1. Install ffmpeg: `brew install ffmpeg-full`
2. Download `HomeStream.app.zip` from [Releases](https://github.com/constantinchik/Homestream-MacOS/releases)
3. Unzip and move `HomeStream.app` to `/Applications`
4. The app is ad-hoc signed (not notarized), so clear the download quarantine before first launch:
   ```sh
   xattr -dr com.apple.quarantine /Applications/HomeStream.app
   ```
5. Launch it, grant **Screen Recording** and **Camera** permissions when prompted, then **quit and relaunch**.

### From source

```sh
brew install ffmpeg-full
make install    # build, then replace /Applications/HomeStream.app
open /Applications/HomeStream.app
```

Each build is ad-hoc signed with a new signature. If macOS stops capturing after an update, run `make reset` to clear the old Screen Recording/Camera grants and approve again (`make dev` does install + reset + launch).

## Build

```sh
make build      # Build release binary + app bundle in .build/HomeStream.app
make install    # Build and replace /Applications/HomeStream.app
make run        # Build and launch from .build
make zip        # Build and zip the bundle to .build/HomeStream.app.zip
make clean      # Clean build artifacts
make reset      # Reset Screen Recording + Camera permissions
make dev        # install + reset + launch
```

## Release

Releases are GitHub releases with the zipped app bundle attached. On a clean `main`:

```sh
make release VERSION=1.1.0
```

This:
1. Sets `CFBundleShortVersionString`/`CFBundleVersion` in `Info.plist`
2. Builds and zips the app
3. Commits `Release v1.1.0`, then tags and pushes `v1.1.0`
4. Creates the GitHub release with `HomeStream.app.zip` and auto-generated notes (needs an authenticated `gh` CLI)

Edit the notes on GitHub afterwards to add highlights and requirement changes (for example the `ffmpeg-full` switch).

## Usage

1. Launch HomeStream. A video camera icon appears in the menu bar.
2. Click the icon to see available sources.
3. Set the SRT destination (default: `192.168.2.100:9000`).
4. Click a source to start streaming.
5. In OBS, add a Media Source with `srt://0.0.0.0:9000?mode=listener` (or your configured port). Set its **Reconnect Delay** to 1s for fast restarts.

Each display appears twice:

| Source | What it streams |
|---|---|
| `Display 1 — 1710×1107 (As is)` | The display at its own resolution, fitted (letterboxed) into the 1920×1080 stream |
| `Display 1 — 1920×1080 (Streaming)` | **Streaming mode**: the desktop switches to 1080p, like AirPlay mirroring to a TV, and the stream gets the full 16:9 frame |

The icon shows a red dot while streaming. Click a different source to switch without stopping. Click "Stop Streaming" or "Quit" to end. Logs go to `/tmp/HomeStream.log`.

### How it works

- **Fixed output:** every source is scaled to 1920×1080 at capture time and encoded at 60fps CFR. Frames are timestamped by arrival time, so 30fps cameras are frame-doubled. Because ffmpeg's input never changes, switching sources only swaps the capture. The SRT session to OBS stays up, so there's no reconnect delay.
- **Clean shutdown:** on stop, ffmpeg gets EOF so it sends an SRT shutdown and OBS frees its listener right away.
- **Streaming mode** creates a virtual 1920×1080@60 display with CoreGraphics' private `CGVirtualDisplay` API and mirrors the physical display onto it (configuration is `forSession` only). The virtual display lives only as long as the app: if it quits or crashes, macOS removes it and the mirror with it. Because the API is private, a future macOS update may break this mode. The "As is" sources don't depend on it.

## Architecture

```
Sources/
├── CGVirtualDisplayBridge/        # Header-only ObjC bridge to the private CGVirtualDisplay API
└── Homestream/
    ├── App.swift                  # @main, MenuBarExtra with live indicator
    ├── Log.swift                  # File + stdout logging
    ├── StreamManager.swift        # Start/stop/switch orchestrator with retry
    ├── Capture/
    │   ├── CaptureSource.swift    # Unified source enum + device enumeration
    │   ├── ScreenCapture.swift    # ScreenCaptureKit → 1920×1080 BGRA frames
    │   ├── CameraCapture.swift    # AVCaptureSession → 1920×1080 BGRA frames
    │   └── VirtualDisplayMirror.swift  # Streaming mode: virtual 1080p display + mirroring
    ├── Encoding/
    │   └── FFmpegProcess.swift    # ffmpeg subprocess, stdin pipe, back-pressure
    └── Views/
        └── MenuBarView.swift      # Source list, start/stop, status
```

Frames flow as: Native Capture → BGRA pixel buffers → stdin pipe → ffmpeg (h264_videotoolbox) → SRT → OBS
