// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AITranscribePro",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "AITranscribePro",
            path: "Sources/AITranscribePro"
        )
    ]
)
