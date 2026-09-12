// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "OmpMiniChat",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "OmpMiniChat", targets: ["OmpMiniChat"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0")
    ],
    targets: [
        .executableTarget(
            name: "OmpMiniChat",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "Sources/OmpMiniChat",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CryptoKit")
            ]
        ),
        .testTarget(name: "OmpMiniChatTests", dependencies: ["OmpMiniChat"], path: "Tests",
                    exclude: ["CollabSmoke", "RegistrySmoke"])
    ],
    swiftLanguageModes: [.v5]
)
