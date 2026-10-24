// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MeetingAgent",
    platforms: [.macOS("15.0")],
    targets: [
        .executableTarget(
            name: "MeetingAgent",
            path: "Sources/MeetingAgent"
        ),
        .testTarget(
            name: "MeetingAgentTests",
            dependencies: ["MeetingAgent"],
            path: "Tests/MeetingAgentTests"
        ),
    ]
)
