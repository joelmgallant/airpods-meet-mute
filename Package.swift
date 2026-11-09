// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AirPodsMeetMute",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "MeetMuteSpike"),
    ],
    swiftLanguageModes: [.v5]
)
