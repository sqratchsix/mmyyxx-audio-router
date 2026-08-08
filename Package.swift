// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "mmyyxx",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "mmyyxx",
            path: "Sources",
            swiftSettings: [
                // Strict concurrency fights CoreAudio's C callback model for no
                // real benefit here; the render thread is guarded by hand.
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
