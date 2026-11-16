// swift-tools-version:5.9
import PackageDescription

// EditCore is the platform-independent heart of the editor: the project model,
// rational media time, sequence time mapping, editing commands, undo, and
// persistence. It has no AVFoundation / UIKit dependency, so it can be unit
// tested with `swift test` on any Mac without the simulator.
let package = Package(
    name: "EditCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "EditCore", targets: ["EditCore"])
    ],
    targets: [
        .target(name: "EditCore"),
        .testTarget(name: "EditCoreTests", dependencies: ["EditCore"]),
    ]
)
