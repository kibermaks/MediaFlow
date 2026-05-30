// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ImageViewerNative",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ImageViewerNative", targets: ["ImageViewerNative"]),
        .library(name: "ImageViewerNativeCore", targets: ["ImageViewerNativeCore"])
    ],
    targets: [
        .target(
            name: "ImageViewerNativeCore",
            path: "Sources/ImageViewerNativeCore"
        ),
        .executableTarget(
            name: "ImageViewerNative",
            dependencies: ["ImageViewerNativeCore"],
            path: "Sources/ImageViewerNative"
        ),
        .testTarget(
            name: "ImageViewerNativeCoreTests",
            dependencies: ["ImageViewerNativeCore"]
        )
    ]
)
