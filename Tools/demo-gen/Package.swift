// swift-tools-version: 6.2
import PackageDescription

// Builds CmdFreak/Demo/Resources/Demo/demo.sqlite, the database the demo app ships with.
// Build the bridge first (scripts/build-bridge.sh), then: swift run --package-path Tools/demo-gen
let package = Package(
    name: "demo-gen",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(path: "../../Packages/WAKit"),
    ],
    targets: [
        .executableTarget(
            name: "demo-gen",
            dependencies: [.product(name: "WAKit", package: "WAKit")]
        ),
    ]
)
