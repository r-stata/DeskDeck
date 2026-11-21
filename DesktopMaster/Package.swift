// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DeskDeck",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "DeskDeck",
            path: "Sources/DeskDeck",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
