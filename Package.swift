// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ff400ctl",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "FFCore", targets: ["FFCore"]),
        .executable(name: "ffctl", targets: ["ffctl"]),
        .executable(name: "FFTray", targets: ["FFTray"]),
    ],
    targets: [
        .target(name: "FFCore", dependencies: []),
        .executableTarget(name: "ffctl", dependencies: ["FFCore"]),
        .executableTarget(
            name: "FFTray",
            dependencies: ["FFCore"],
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        ),
        .executableTarget(name: "fftests", dependencies: ["FFCore"]),
    ]
)
