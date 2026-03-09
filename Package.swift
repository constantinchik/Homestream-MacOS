// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Homestream",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Homestream",
            path: "Sources/Homestream",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("ScreenCaptureKit"),
            ]
        ),
    ]
)
