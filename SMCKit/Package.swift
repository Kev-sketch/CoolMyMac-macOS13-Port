// swift-tools-version: 5.8
import PackageDescription

let package = Package(
    name: "SMCKit",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "SMCKit",
            targets: ["SMCKit"]
        )
    ],
    targets: [
        .target(
            name: "SMCKit",
            path: "Sources/SMCKit"
        ),
        .testTarget(
            name: "SMCKitTests",
            dependencies: ["SMCKit"],
            path: "Tests/SMCKitTests"
        )
    ]
)
