// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Athena",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(
            url: "https://github.com/groue/GRDB.swift",
            .upToNextMajor(from: "6.0.0")
        ),
        .package(
            url: "https://github.com/migueldeicaza/SwiftTerm",
            .upToNextMajor(from: "1.2.0")
        ),
    ],
    targets: [
        .executableTarget(
            name: "Athena",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Sources/Athena",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "AthenaTests",
            dependencies: ["Athena"]
        ),
    ]
)
