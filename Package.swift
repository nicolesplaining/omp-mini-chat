// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MiniChat",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "MiniChat", targets: ["MiniChat"])
    ],
    targets: [
        .executableTarget(
            name: "MiniChat",
            path: "Sources/MiniChat",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon")
            ]
        )
    ]
)
