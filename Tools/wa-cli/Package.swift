// swift-tools-version: 6.2
import PackageDescription

// Smoke-test tool for the bridge (raw FFI) and, for `ingest-capture`, the WAKit data layer.
// Build the bridge first: scripts/build-bridge.sh
let package = Package(
    name: "wa-cli",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(path: "../../Packages/WACoreFFI"),
        .package(path: "../../Packages/WAKit"),
    ],
    targets: [
        .executableTarget(
            name: "wa-cli",
            dependencies: [
                .product(name: "WACoreFFI", package: "WACoreFFI"),
                .product(name: "WAKit", package: "WAKit"),
            ]
        ),
    ]
)
