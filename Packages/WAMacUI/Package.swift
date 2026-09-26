// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WAMacUI",
    platforms: [.macOS(.v26)],
    products: [.library(name: "WAMacUI", targets: ["WAMacUI"])],
    dependencies: [.package(path: "../WAKit")],
    targets: [
        .target(name: "WAMacUI", dependencies: ["WAKit"]),
    ]
)
