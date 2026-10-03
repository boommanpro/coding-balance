// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CodingBalance",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "CodingBalance",
            path: "Sources/CodingBalance"
        )
    ]
)
