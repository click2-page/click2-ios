// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Click2",
    platforms: [
        .iOS(.v14),
        // macOS only so the core logic can be tested with `swift test`.
        .macOS(.v12),
    ],
    products: [
        .library(name: "Click2", targets: ["Click2"]),
    ],
    targets: [
        .target(name: "Click2", path: "Sources/Click2"),
        .testTarget(
            name: "Click2Tests",
            dependencies: ["Click2"],
            path: "Tests/Click2Tests",
            // Shared test cases, identical to the ones in click2-android.
            resources: [.copy("Fixtures")]
        ),
    ]
)
