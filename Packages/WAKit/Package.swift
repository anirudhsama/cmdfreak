// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WAKit",
    platforms: [.macOS(.v26)],
    products: [.library(name: "WAKit", targets: ["WAKit"])],
    dependencies: [
        .package(path: "../WACoreFFI"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/marmelroy/PhoneNumberKit", from: "4.3.0"),
    ],
    targets: [
        .target(
            name: "WAKit",
            dependencies: [
                "WACoreFFI",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "PhoneNumberKit", package: "PhoneNumberKit"),
            ]
        ),
        .testTarget(name: "WAKitTests", dependencies: ["WAKit"]),
    ]
)
