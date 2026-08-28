// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MirrorPod",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "mirrorpod", targets: ["MirrorPod"])
    ],
    targets: [
        .executableTarget(
            name: "MirrorPod",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
