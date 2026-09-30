// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Kay",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Kay",
            path: "Sources/Kay",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
