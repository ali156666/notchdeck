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
        // 来自 CodeIsland（MIT）的会话监控内核：纯 Foundation，零第三方依赖。
        // 独立成 target 既保留上游结构，也避开与 Xuanyu 自身 AgentStatus 等类型的重名。
        .target(
            name: "CodeWatchCore",
            path: "Sources/CodeWatchCore",
            exclude: ["LICENSE.CodeIsland"]
        ),
        .target(
            name: "Xuanyu",
            dependencies: [
                "SherpaOnnx",
                "OnnxRuntime",
                "CodeWatchCore",
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
