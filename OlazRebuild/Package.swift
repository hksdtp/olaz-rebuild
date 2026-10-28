// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "OlazRebuild",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "OlazRebuild",
            path: "Sources/OlazRebuild",
            resources: [.copy("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
