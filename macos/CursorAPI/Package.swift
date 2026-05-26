// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CursorAPI",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "CursorAPICore", targets: ["CursorAPICore"]),
        .executable(name: "CursorAPI", targets: ["CursorAPI"])
    ],
    targets: [
        .target(
            name: "CursorAPICore",
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .executableTarget(
            name: "CursorAPI",
            dependencies: ["CursorAPICore"],
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .testTarget(
            name: "CursorAPITests",
            dependencies: ["CursorAPICore", "CursorAPI"],
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny")
            ]
        )
    ]
)
