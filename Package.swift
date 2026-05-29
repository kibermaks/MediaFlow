// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ImageViewerNative",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ImageViewerNative", targets: ["ImageViewerNative"])
    ],
    targets: [
        .executableTarget(
            name: "ImageViewerNative",
            path: "Sources/ImageViewerNative"
        )
    ]
)
