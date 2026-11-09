// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FlowGesture",
    platforms: [.macOS(.v13)],
    products: [.library(name: "FlowGestureCore", targets: ["FlowGestureCore"]), .executable(name: "FlowGesture", targets: ["FlowGestureApp"]), .executable(name: "FlowGestureCapture", targets: ["FlowGestureCapture"])],
    targets: [
        .target(name: "FlowGestureCore"),
        .target(name: "FlowGestureNative", publicHeadersPath: "include", linkerSettings: [.linkedFramework("CoreFoundation", .when(platforms: [.macOS])), .linkedFramework("CoreGraphics", .when(platforms: [.macOS])), .linkedFramework("IOKit", .when(platforms: [.macOS]))]),
        .executableTarget(name: "FlowGestureApp", dependencies: ["FlowGestureCore", "FlowGestureNative"], linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("ApplicationServices")]),
        .executableTarget(name: "FlowGestureCapture", dependencies: ["FlowGestureNative"], linkerSettings: [.linkedFramework("AppKit", .when(platforms: [.macOS]))]),
        .testTarget(name: "FlowGestureCaptureTests", dependencies: ["FlowGestureCapture"]),
        .testTarget(name: "FlowGestureCoreTests", dependencies: ["FlowGestureCore"]),
        .testTarget(name: "FlowGestureAppTests", dependencies: ["FlowGestureApp", "FlowGestureCore"], resources: [.copy("Fixtures")])
    ]
)
