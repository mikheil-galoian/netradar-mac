// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "netradar",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "netradar",
            path: "Sources/netradar"
        )
    ]
)
