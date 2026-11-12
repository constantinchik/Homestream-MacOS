// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Homestream",
    platforms: [.macOS(.v13)],
    targets: [
        // Header-only bridge to CoreGraphics' private CGVirtualDisplay API
        .target(
            name: "CGVirtualDisplayBridge",
            path: "Sources/CGVirtualDisplayBridge"
        ),
        .executableTarget(
            name: "Homestream",
            dependencies: ["CGVirtualDisplayBridge"],
            path: "Sources/Homestream",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("ScreenCaptureKit"),
            ]
        ),
    ]
)
