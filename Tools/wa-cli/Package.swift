// swift-tools-version: 6.2
import PackageDescription

// M1 smoke-test tool. Depends on the raw FFI package only (not WAKit). Build the bridge first:
// scripts/build-bridge.sh
let package = Package(
    name: "wa-cli",
    platforms: [.macOS(.v26)],
    dependencies: [.package(path: "../../Packages/WACoreFFI")],
    targets: [
        .executableTarget(
            name: "wa-cli",
            dependencies: [.product(name: "WACoreFFI", package: "WACoreFFI")]
        ),
    ]
)
