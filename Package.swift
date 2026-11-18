// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Veil",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Veil",
            path: "Sources/Veil",
            resources: [.copy("Resources/Server"), .process("Resources/Media")],
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        ),
        .testTarget(
            name: "VeilTests",
            dependencies: ["Veil"],
            path: "Tests/VeilTests"
        ),
    ]
)
