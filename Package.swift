// swift-tools-version: 5.9
import PackageDescription
import Foundation
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let package = Package(
    name: "MacCAD",
    platforms: [.macOS(.v14)],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .systemLibrary(name: "CCadCore", path: "native/CCadCore"),
        .executableTarget(name: "MacCAD", dependencies: ["CCadCore", .product(name: "Sparkle", package: "Sparkle")], path: "native/MacCAD",
            linkerSettings: [.unsafeFlags(["-L\(root)/target/release", "-lcad_core", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]), .linkedFramework("AppKit"), .linkedFramework("MetalKit"), .linkedFramework("CoreText")]),
    ]
)
