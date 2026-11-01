// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CursorFence",
    platforms: [.macOS("26.0")],
    targets: [
        // Pure geometry and decision logic: no AppKit, fully unit-tested.
        .target(name: "FenceCore"),
        // The Dock app. scripts/build-app.sh wraps it in a signed bundle.
        .executableTarget(name: "CursorFence", dependencies: ["FenceCore"]),
        // Leak-test harness: ScreenCaptureKit recorder plus synthetic driver.
        .executableTarget(name: "FenceHarness", dependencies: ["FenceCore"]),
        .testTarget(name: "FenceCoreTests", dependencies: ["FenceCore"]),
    ]
)
