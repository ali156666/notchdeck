// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Xuanyu",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Xuanyu",
            path: "Sources/Xuanyu",
            resources: [
                .copy("Resources")
            ]
        ),
        .testTarget(
            name: "XuanyuTests",
            dependencies: ["Xuanyu"],
            path: "Tests/XuanyuTests"
        ),
    ]
)
