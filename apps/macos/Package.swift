// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SaydropUI",
    platforms: [.macOS(.v14)],
    products: [.library(name: "SaydropUI", targets: ["SaydropUI"])],
    dependencies: [.package(path: "packages/SaydropCore"),
                   .package(path: "packages/SaydropRealtime"),
                   .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", exact: "3.1.0")],
    targets: [
        .target(name: "SaydropUI", dependencies: [.product(name: "SaydropCore", package: "SaydropCore"),
                 .product(name: "SaydropRealtime", package: "SaydropRealtime"),
                 .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")],
                path: "SaydropApp", exclude: ["SaydropApp.swift", "Info.plist", "Info-Debug.plist"], resources: [.copy("Resources")]),
        .testTarget(name: "SaydropUITests", dependencies: ["SaydropUI"], path: "SaydropUITests")
    ],
    swiftLanguageVersions: [.v5]
)
