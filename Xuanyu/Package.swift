// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Xuanyu",
    platforms: [.macOS("26.0")],
    dependencies: [],
    targets: [
        .binaryTarget(
            name: "SherpaOnnx",
            path: "Vendor/sherpa-onnx.xcframework"
        ),
        .binaryTarget(
            name: "OnnxRuntime",
            path: "Vendor/onnxruntime.xcframework"
        ),
        .executableTarget(
            name: "Xuanyu",
            dependencies: [
                "SherpaOnnx",
                "OnnxRuntime",
            ],
            path: "Sources/Xuanyu",
            resources: [
                .copy("Resources")
            ],
            linkerSettings: [
                .linkedLibrary("c++"),
            ]
        ),
        .testTarget(
            name: "XuanyuTests",
            dependencies: ["Xuanyu"],
            path: "Tests/XuanyuTests"
        ),
    ]
)
