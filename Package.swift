// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "OmpMiniChat",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "OmpMiniChat", targets: ["OmpMiniChat"])
    ],
    targets: [
        .executableTarget(
            name: "OmpMiniChat",
            path: "Sources/OmpMiniChat",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon")
            ]
        )
    ]
)
