// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "Winnow",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "WinnowCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "Winnow", dependencies: ["WinnowCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        // `swift test` needs full Xcode; this runs the core checks with just the Command Line Tools.
        .executableTarget(name: "WinnowCheck", dependencies: ["WinnowCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
