// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "PeelShell",
    platforms: [.macOS(.v14), .iOS(.v17), .visionOS(.v1)],
    products: [
        .library(name: "PeelShellCore", targets: ["PeelShellCore"]),
        .library(name: "PeelShellTransport", targets: ["PeelShellTransport"]),
        .library(name: "PeelShellUI", targets: ["PeelShellUI"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", revision: "cd3e1152083706d77b223fb29110e590efcc70c0"),
        .package(url: "https://github.com/apple/swift-nio-ssh.git", revision: "8257bc486f448799e94e225c4304d5ee0c19964f"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", revision: "8e7a1e154f470e19c709a00a8768df348ba5fc43")
    ],
    targets: [
        .target(name: "PeelShellCore"),
        .target(name: "PeelShellTransport", dependencies: [
            "PeelShellCore", .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOSSH", package: "swift-nio-ssh")
        ]),
        .target(name: "PeelShellUI", dependencies: [
            "PeelShellCore", "PeelShellTransport", .product(name: "SwiftTerm", package: "SwiftTerm")
        ], resources: [.copy("Resources/ThirdPartyNotices.txt")]),
        .testTarget(name: "PeelShellCoreTests", dependencies: ["PeelShellCore"]),
        .testTarget(name: "PeelShellTransportTests", dependencies: [
            "PeelShellCore", "PeelShellTransport", .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"), .product(name: "NIOSSH", package: "swift-nio-ssh")
        ])
    ],
    swiftLanguageModes: [.v5]
)
