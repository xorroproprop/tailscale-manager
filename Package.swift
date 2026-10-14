// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TailnetManager",
    platforms: [.macOS(.v14)],
    dependencies: [
        // embedded terminal (VT emulator + pty) — libghostty isn't embeddable yet
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.20.0"),
    ],
    targets: [
        .target(name: "TailnetCore", dependencies: ["SwiftTerm"]),
        .executableTarget(name: "TailnetManager", dependencies: ["TailnetCore"]),
        .testTarget(name: "TailnetCoreTests", dependencies: ["TailnetCore"]),
    ]
)
