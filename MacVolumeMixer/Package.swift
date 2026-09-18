// swift-tools-version:6.0
import PackageDescription

// This package is buildable two ways:
//   1. `swift build` / `swift run` from the command line (fastest inner loop).
//   2. Opening this folder's Package.swift directly in Xcode ("Open" a
//      Package.swift is a first-class Xcode project as of Xcode 13+), which
//      also gives you Instruments, breakpoints, and Developer ID signing UI.
//
// The Info.plist embedded via `-sectcreate __TEXT __info_plist` below is what
// makes LSUIElement (menu-bar-only, no Dock icon) and the bundle identifier
// take effect even when launched as a bare Mach-O built by SwiftPM, without
// requiring a full .xcodeproj. See README.md "Build & Run" for the two paths
// and their tradeoffs, and for how to wrap this into a signed/notarized .app
// for Developer ID distribution.
let package = Package(
    name: "MacVolumeMixer",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "MacVolumeMixer",
            path: "Sources/MacVolumeMixer",
            exclude: ["Resources/Info.plist"],
            resources: [
                .copy("Resources/MenuBarIcon.png"),
                .copy("Resources/ControlPanelIcon.png")
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/MacVolumeMixer/Resources/Info.plist"
                ])
            ]
        ),
        .testTarget(
            name: "MacVolumeMixerTests",
            dependencies: ["MacVolumeMixer"],
            path: "Tests/MacVolumeMixerTests"
        )
    ]
)
