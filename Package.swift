// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Mizu",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "Mizu", targets: ["Mizu"]),
    ],
    targets: [
        .target(name: "Mizu"),
        .testTarget(name: "MizuTests", dependencies: ["Mizu"]),
    ]
)
