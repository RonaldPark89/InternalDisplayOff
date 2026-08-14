// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "InternalDisplayOffCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "InternalDisplayOffCore", targets: ["InternalDisplayOffCore"]),
    ],
    targets: [
        .target(
            name: "InternalDisplayOffCore",
            path: "Sources",
            exclude: [
                "AppDelegate.swift",
                "BrightnessController.swift",
                "DisplayManager.swift",
                "InternalDisplayOffApp.swift",
                "LaunchManager.swift",
                "PopoverView.swift",
                "SceneManager.swift",
                "ToastManager.swift",
            ],
            sources: [
                "DisplayAutomationPolicy.swift",
                "DisplayIdentity.swift",
            ]
        ),
        .testTarget(
            name: "InternalDisplayOffCoreTests",
            dependencies: ["InternalDisplayOffCore"],
            path: "Tests/InternalDisplayOffCoreTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
