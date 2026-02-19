// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "voxd",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", from: "1.20.0"),
    ],
    targets: [
        .executableTarget(
            name: "voxd",
            dependencies: [
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
            ],
            path: "Sources/voxd"
        ),
        .testTarget(
            name: "VoxdTests",
            dependencies: ["voxd"]
        ),
    ]
)
