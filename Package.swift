// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Kay",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Kay",
            path: "Sources/Kay",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
