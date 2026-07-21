// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DealWithPR",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "DealWithPR",
            path: "Sources/DealWithPR"
        )
    ]
)
