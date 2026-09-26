// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MedBot",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "MedBot", targets: ["MedBot"]),
        .executable(name: "medbot-cli", targets: ["medbot-cli"]),
        .executable(name: "MedBotApp", targets: ["MedBotApp"]),
        .executable(name: "medbot-server", targets: ["medbot-server"]),
    ],
    targets: [
        .target(name: "MedBot"),
        .executableTarget(name: "medbot-cli", dependencies: ["MedBot"]),
        .executableTarget(name: "MedBotApp", dependencies: ["MedBot"]),
        .executableTarget(name: "medbot-server", dependencies: ["MedBot"]),
        .testTarget(name: "MedBotTests", dependencies: ["MedBot"]),
    ]
)
