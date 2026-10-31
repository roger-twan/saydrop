// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SaydropRealtime",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SaydropRealtime", targets: ["SaydropRealtime"])
    ],
    targets: [
        .target(name: "SaydropRealtime", publicHeadersPath: "include"),
        .testTarget(name: "SaydropRealtimeTests", dependencies: ["SaydropRealtime"])
    ],
    cLanguageStandard: .c11
)
