// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ff400ctl",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "FFCore", targets: ["FFCore"]),
        .library(name: "FFModel", targets: ["FFModel"]),
        .executable(name: "ffctl", targets: ["ffctl"]),
        .executable(name: "FFTray", targets: ["FFTray"]),
        .executable(name: "ffmeter", targets: ["ffmeter"]),
    ],
    targets: [
        .target(name: "FFCore", dependencies: []),
        // Testable view-model layer: no AppKit — the tray app injects the
        // AppKit/CoreAudio bits (presence watcher, detached window,
        // launch-at-login) on top.
        .target(name: "FFModel", dependencies: ["FFCore"]),
        .executableTarget(name: "ffctl", dependencies: ["FFCore"]),
        .executableTarget(
            name: "FFTray",
            dependencies: ["FFCore", "FFModel"],
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        ),
        .executableTarget(name: "fftests", dependencies: ["FFCore", "FFModel"]),
        // Level-meter capture tool for the hardware test (not shipped
        // in the DMG).
        .executableTarget(name: "ffmeter", dependencies: ["FFCore"]),
    ]
)
