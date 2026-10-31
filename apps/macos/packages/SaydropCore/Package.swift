// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SaydropCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "SaydropCore", targets: ["SaydropCore"])],
    targets: [
        .target(name: "SaydropCore"),
        .testTarget(name: "SaydropCoreTests", dependencies: ["SaydropCore"])
    ],
    swiftLanguageVersions: [.v5]
)
