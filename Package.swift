// swift-tools-version: 6.2
import Foundation
import PackageDescription

// The Info.plist is embedded in the binary (__TEXT,__info_plist): it gives the process a bundle identity
// for the Speech framework without wrapping it in an .app.
let infoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Info.plist").path

let package = Package(
    name: "apple-wyoming",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "apple-wyoming",
            path: "Sources/apple-wyoming",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", infoPlist]),
            ]
        ),
    ]
)
