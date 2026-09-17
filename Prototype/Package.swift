// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "audiomixctl",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "audiomixctl",
            path: "Sources/audiomixctl"
        )
    ]
)
