// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "ScreeningAutomation",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "ScreeningAutomation",
            targets: ["ScreeningAutomation"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.9.1")
    ],
    targets: [
        .executableTarget(
            name: "ScreeningAutomation",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
