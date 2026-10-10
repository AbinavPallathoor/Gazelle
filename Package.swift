// swift-tools-version: 6.0
import PackageDescription
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "Gazelle",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GazeKit", targets: ["GazeKit"]),
        .library(name: "GazeVision", targets: ["GazeVision"]),
        .executable(name: "gazespike", targets: ["gazespike"]),
    ],
    targets: [
        // Pure Swift. Foundation only: no AppKit, AVFoundation or Vision.
        .target(name: "GazeKit"),
        // Camera + vision backends implementing GazeKit.FaceFeatureProvider.
        .target(
            name: "GazeVision",
            dependencies: ["GazeKit"],
            resources: [.copy("Resources/mediapipe")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // M0 throwaway harness: record and analyse backend feature streams.
        .executableTarget(
            name: "gazespike",
            dependencies: ["GazeKit", "GazeVision"],
            exclude: ["Info.plist"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist", "-Xlinker", "\(root)/Sources/gazespike/Info.plist",
                ])
            ]
        ),
        .testTarget(
            name: "GazeKitTests",
            dependencies: ["GazeKit"]
        ),
    ]
)
