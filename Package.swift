// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MultiDock",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MultiDock",
            path: "Sources/MultiDock"
        )
    ]
)
