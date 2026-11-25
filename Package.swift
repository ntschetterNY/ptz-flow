// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PTZFlow",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PTZFlow", targets: ["PTZFlow"]),
    ],
    targets: [
        // Camera protocol, motion math, update checks and the local control server.
        // No UI code here, so it can be unit tested.
        .target(name: "PTZFlowCore"),
        // The SwiftUI Mac app.
        .executableTarget(name: "PTZFlow", dependencies: ["PTZFlowCore"]),
        .testTarget(name: "PTZFlowCoreTests", dependencies: ["PTZFlowCore"]),
    ]
)
