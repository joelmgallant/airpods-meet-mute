// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AirPodsMeetMute",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "MeetMuteCore"),
        .executableTarget(name: "AirPodsMeetMute", dependencies: ["MeetMuteCore"]),
        .executableTarget(name: "MeetMuteSpike"),
        .testTarget(name: "MeetMuteCoreTests", dependencies: ["MeetMuteCore"]),
    ],
    swiftLanguageModes: [.v5]
)
