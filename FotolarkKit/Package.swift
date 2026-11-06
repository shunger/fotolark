// swift-tools-version: 6.0
import PackageDescription

// FotolarkKit holds all editing logic. It must stay free of AppKit and other
// Mac-only APIs so it also builds for iPadOS and iOS (Phase 6).
let package = Package(
    name: "FotolarkKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "FotolarkKit", targets: ["FotolarkKit"]),
    ],
    targets: [
        .target(name: "FotolarkKit"),
        .testTarget(name: "FotolarkKitTests", dependencies: ["FotolarkKit"]),
    ]
)
