// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Counterparty",
    platforms: [.macOS(.v14)],
    targets: [
        // market data: exchange adapters, websocket feed, aggr history
        .target(name: "CounterpartyKit"),
        // the desktop app
        .executableTarget(name: "Counterparty", dependencies: ["CounterpartyKit"])
    ]
)
