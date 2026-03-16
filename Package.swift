// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "iMessageSearch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "iMessageSearch",
            path: "Sources",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        )
    ]
)
