// swift-tools-version:6.2
import PackageDescription

// The macOS app. Shared/ is compiled into it directly, as the iOS project does with the same folder,
// so the shared code needs no module boundary. iOS/ is an Xcode project and is not part of the package.
let package = Package(
    name: "Kay",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Kay",
            path: ".",
            sources: ["macOS/Sources/Kay", "Shared"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
