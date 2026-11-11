// swift-tools-version: 6.1
import PackageDescription
let package = Package(name:"TermPilotSyncUI", platforms:[.macOS(.v14),.iOS(.v17)],
    products:[.library(name:"TermPilotSyncUI",targets:["TermPilotSyncUI"])],
    targets:[.target(name:"TermPilotSyncUI")])
