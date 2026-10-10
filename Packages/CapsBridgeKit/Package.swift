// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CapsBridgeKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "CapsBridgeKit", targets: ["CapsBridgeKit"]),
    ],
    targets: [
        .target(name: "CapsBridgeKit"),
        .testTarget(name: "CapsBridgeKitTests", dependencies: ["CapsBridgeKit"]),
    ]
)
