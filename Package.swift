// swift-tools-version:6.2
import PackageDescription

// The macOS app. Shared/ is compiled into it directly, as the iOS project does with the same folder,
// so the shared code needs no module boundary. iOS/ is an Xcode project and is not part of the package.
let package = Package(
    name: "Kay",
    platforms: [.macOS(.v26)],
    dependencies: [
        // Auto-update: Kay is a notarized download, so it has to replace itself (as Lumo does).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0")
    ],
    targets: [
        .executableTarget(
            name: "Kay",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: ".",
            // Everything else under the root is not the package's business. Without this SwiftPM also
            // picks up the .lproj folders (macOS/Resources, build/Kay.app) as package resources and refuses.
            exclude: ["macOS/Resources", "macOS/scripts", "build", "tools", "iOS", "README.md", "LICENSE", "Makefile", "appcast.xml"],
            sources: ["macOS/Sources/Kay", "Shared"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            // macOS/scripts/build-app.sh copies Sparkle.framework into Contents/Frameworks; without this
            // rpath the executable looks for it next to itself and does not launch.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        )
    ]
)
