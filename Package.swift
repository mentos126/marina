// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Marina",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MarinaApp", targets: ["MarinaApp"]),
        .executable(name: "marina", targets: ["MarinaCLI"]),
        .library(name: "MarinaCore", targets: ["MarinaCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "MarinaCore",
            dependencies: [],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "MarinaApp",
            dependencies: [
                "MarinaCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "MarinaCLI",
            dependencies: [
                "MarinaCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MarinaAppTests",
            dependencies: ["MarinaApp", "MarinaCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
