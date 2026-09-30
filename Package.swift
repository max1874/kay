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
            // Everything else under the root is not the package's business. Without this SwiftPM also
            // picks up the .lproj folders (macOS/Resources, build/Kay.app) as package resources and refuses.
            exclude: ["macOS/Resources", "macOS/scripts", "build", "tools", "iOS", "README.md", "LICENSE", "Makefile"],
            sources: ["macOS/Sources/Kay", "Shared"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
