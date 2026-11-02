// swift-tools-version:6.2

import PackageDescription

/// Reality Composer Pro content for Sedactive. Open
/// `Package.realitycomposerpro` in Reality Composer Pro to edit the scenes.
let package = Package(
    name: "RealityKitContent",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
        .visionOS(.v26)
    ],
    products: [
        .library(name: "RealityKitContent", targets: ["RealityKitContent"])
    ],
    targets: [
        .target(name: "RealityKitContent")
    ]
)
