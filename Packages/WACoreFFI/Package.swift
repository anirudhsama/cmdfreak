// swift-tools-version: 6.2
import PackageDescription

// Run scripts/build-bridge.sh first; it produces WACoreFFI.xcframework and Sources/WACoreFFI/wa_bridge.swift.
let package = Package(
    name: "WACoreFFI",
    platforms: [.macOS(.v26)],
    products: [.library(name: "WACoreFFI", targets: ["WACoreFFI"])],
    targets: [
        .binaryTarget(name: "wa_bridgeFFI", path: "WACoreFFI.xcframework"),
        .target(
            name: "WACoreFFI",
            dependencies: ["wa_bridgeFFI"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("CoreFoundation"),
                .linkedLibrary("sqlite3"),
            ]
        ),
    ]
)
