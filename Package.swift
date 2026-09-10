// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Pictool",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Pictool",
            path: "Sources/Pictool",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PictoolTests",
            dependencies: ["Pictool"],
            path: "Tests/PictoolTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
