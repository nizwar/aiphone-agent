// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AIPhone",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "AIPhone",
            targets: ["AIPhone"]
        )
    ],
    targets: [
        .executableTarget(
            name: "AIPhone",
            path: "Sources/AiphoneGUI",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
