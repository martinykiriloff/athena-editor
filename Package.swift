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
        .package(
            url: "https://github.com/vapor/postgres-nio",
            .upToNextMajor(from: "1.21.0")
        ),
    ],
    targets: [
        .executableTarget(
            name: "Athena",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
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
        // Kept separate from AthenaTests: FileWatchServiceTests spins up real
        // DispatchSource/kqueue watches and was flaky when sharing a process
        // (and its concurrent Task scheduling) with ~200 unrelated tests —
        // see that file's header comment.
        .testTarget(
            name: "AthenaFileWatchTests",
            dependencies: ["Athena"]
        ),
    ]
)
