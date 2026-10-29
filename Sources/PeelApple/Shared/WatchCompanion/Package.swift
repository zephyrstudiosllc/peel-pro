// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PeelWatchCore",
    platforms: [.iOS(.v17), .watchOS(.v10), .macOS(.v14)],
    products: [.library(name: "PeelWatchCore", targets: ["PeelWatchCore"])],
    targets: [
        .target(name: "PeelWatchCore"),
        .testTarget(name: "PeelWatchCoreTests", dependencies: ["PeelWatchCore"])
    ],
    swiftLanguageVersions: [.v5]
)
