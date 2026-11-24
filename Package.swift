// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Mane",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Mane",
            path: "App",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("WebKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
            ]
        ),
    ]
)
