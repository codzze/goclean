// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GoClean",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "GoCleanCore",
            targets: ["GoCleanCore"]
        ),
        .executable(
            name: "GoClean",
            targets: ["GoClean"]
        )
    ],
    targets: [
        .target(
            name: "GoCleanCore",
            path: "Sources/GoCleanCore"
        ),
        .executableTarget(
            name: "GoClean",
            dependencies: ["GoCleanCore"],
            path: "Sources/GoClean"
        ),
        .testTarget(
            name: "GoCleanCoreTests",
            dependencies: ["GoCleanCore"],
            path: "Tests/GoCleanCoreTests"
        )
    ]
)
