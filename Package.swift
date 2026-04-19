// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ByeByeBytes",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ByeByeBytes", targets: ["ByeByeBytes"])
    ],
    targets: [
        .executableTarget(
            name: "ByeByeBytes",
            path: "Sources/ByeByeBytes"
        )
    ]
)
