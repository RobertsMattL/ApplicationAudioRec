// swift-tools-version: 5.9
import PackageDescription

// Built in Swift 5 language mode (the default for this tools version) to keep
// ScreenCaptureKit's callback-based audio delivery free of strict-concurrency
// friction. The product is a plain executable; build.sh wraps it into a .app.
let package = Package(
    name: "ApplicationAudioRec",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ApplicationAudioRec",
            path: "Sources/ApplicationAudioRec"
        )
    ]
)
