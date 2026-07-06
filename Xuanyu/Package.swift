// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Xuanyu",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Xuanyu", targets: ["XuanyuApp"]),
    ],
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
        .target(
            name: "Xuanyu",
            dependencies: [
                "SherpaOnnx",
                "OnnxRuntime",
            ],
            path: "Sources/Xuanyu",
            resources: [
                .copy("Resources")
            ],
            swiftSettings: [
                .unsafeFlags(["-enable-testing"], .when(configuration: .debug)),
            ],
            linkerSettings: [
                .linkedLibrary("c++"),
            ]
        ),

        .executableTarget(
            name: "XuanyuApp",
            dependencies: ["Xuanyu"],
            path: "Sources/XuanyuApp"
        ),
        .executableTarget(
            name: "XuanyuRegressionTests",
            dependencies: ["Xuanyu"],
            path: "Tests/XuanyuRegressionTests"
        ),
        .testTarget(
            name: "SwiftPMPlaceholderTests",
            path: "Tests/SwiftPMPlaceholderTests"
        ),
    ]
)
