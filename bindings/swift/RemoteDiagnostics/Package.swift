// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "RemoteDiagnostics", platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "TermPilotRemoteDiagnostics", targets: ["TermPilotRemoteDiagnostics"])],
    targets: [.target(name: "TermPilotRemoteDiagnostics"),
              .testTarget(name: "TermPilotRemoteDiagnosticsTests", dependencies: ["TermPilotRemoteDiagnostics"])])
