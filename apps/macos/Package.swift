// swift-tools-version: 6.1

import PackageDescription
import Foundation

let sharedRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let sharedCoreLibrary = ProcessInfo.processInfo.environment["TERMPILOT_CORE_LIBRARY"]
    ?? sharedRoot.appendingPathComponent("target/release/libtermpilot_core.a").path

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
        .package(path: "../../bindings/swift/SyncUI"),
        .package(path: "../../bindings/swift/RemoteDiagnostics"),
        .package(
            url: "https://github.com/groue/GRDB.swift.git",
            exact: "7.11.1"
        ),
        .package(
            url: "https://github.com/migueldeicaza/SwiftTerm.git",
            exact: "1.15.0"
        ),
    ],
    targets: [
        .target(name: "CTermPilotCore", publicHeadersPath: "include",
                linkerSettings: [.unsafeFlags([sharedCoreLibrary])]),
        .target(name: "TermPilotCore", dependencies: ["CTermPilotCore"], swiftSettings: strictSwiftSettings),
        .target(
            name: "TermPilotDomain",
            dependencies: ["TermPilotCore"],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "TermPilotPersistence",
            dependencies: [
                "TermPilotCore",
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
                "TermPilotCore",
                "TermPilotDomain",
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
        .target(
            name: "TermPilotScreenSharing",
            dependencies: ["TermPilotDomain", "TermPilotCore", .product(name: "TermPilotRemoteDiagnostics", package: "RemoteDiagnostics")],
            swiftSettings: strictSwiftSettings,
            linkerSettings: [.linkedFramework("MetalKit"), .linkedFramework("AVFoundation")]
        ),
        .executableTarget(
            name: "TermPilotApp",
            dependencies: [
                .product(name: "TermPilotSyncUI", package: "SyncUI"),
                "TermPilotDomain",
                "TermPilotPersistence",
                "TermPilotRemote",
                "TermPilotTerminal",
                "TermPilotScreenSharing",
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
                "TermPilotScreenSharing",
                "TermPilotCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
