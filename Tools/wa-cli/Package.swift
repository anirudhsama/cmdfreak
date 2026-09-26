// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "wa-cli",
    platforms: [.macOS(.v26)],
    dependencies: [.package(path: "../../Packages/WAKit")],
    targets: [
        .executableTarget(name: "wa-cli", dependencies: [.product(name: "WAKit", package: "WAKit")]),
    ]
)
