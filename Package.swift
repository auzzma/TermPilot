// swift-tools-version: 6.1

import PackageDescription

let strictSwiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "TermPilot",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "TermPilot", targets: ["TermPilotApp"]),
        .library(name: "TermPilotDomain", targets: ["TermPilotDomain"]),
        .library(name: "TermPilotPersistence", targets: ["TermPilotPersistence"]),
        .library(name: "TermPilotRemote", targets: ["TermPilotRemote"]),
        .library(name: "TermPilotTerminal", targets: ["TermPilotTerminal"]),
        .library(name: "TermPilotTestSupport", targets: ["TermPilotTestSupport"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/groue/GRDB.swift.git",
            exact: "7.11.1"
        ),
        .package(
            url: "https://github.com/migueldeicaza/SwiftTerm.git",
            exact: "1.15.0"
        ),
        .package(
            url: "https://github.com/orlandos-nl/Citadel.git",
            exact: "0.12.1"
        ),
        .package(
            url: "https://github.com/apple/swift-nio.git",
            exact: "2.84.0"
        ),
    ],
    targets: [
        .target(
            name: "TermPilotDomain",
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "TermPilotPersistence",
            dependencies: [
                "TermPilotDomain",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            linkerSettings: [
                .linkedFramework("Security"),
            ]
        ),
        .target(
            name: "TermPilotRemote",
            dependencies: [
                "TermPilotDomain",
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "NIOCore", package: "swift-nio"),
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "TermPilotTerminal",
            dependencies: [
                "TermPilotDomain",
                "TermPilotRemote",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            swiftSettings: strictSwiftSettings,
            linkerSettings: [
                .linkedFramework("AppKit"),
            ]
        ),
        .target(
            name: "TermPilotTestSupport",
            dependencies: [
                "TermPilotDomain",
                "TermPilotPersistence",
                "TermPilotRemote",
            ],
            swiftSettings: strictSwiftSettings
        ),
        .executableTarget(
            name: "TermPilotApp",
            dependencies: [
                "TermPilotDomain",
                "TermPilotPersistence",
                "TermPilotRemote",
                "TermPilotTerminal",
            ],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: strictSwiftSettings,
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Security"),
            ]
        ),
        .testTarget(
            name: "TermPilotTests",
            dependencies: [
                "TermPilotApp",
                "TermPilotDomain",
                "TermPilotPersistence",
                "TermPilotRemote",
                "TermPilotTerminal",
                "TermPilotTestSupport",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
