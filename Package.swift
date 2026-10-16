// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LibreTVCore",
    platforms: [.macOS(.v13), .tvOS(.v17)],
    products: [.library(name: "LibreTVCore", targets: ["LibreTVCore"])],
    targets: [
        .target(name: "LibreTVCore", path: "Core"),
        .testTarget(name: "LibreTVCoreTests", dependencies: ["LibreTVCore"], path: "Tests")
    ],
    swiftLanguageVersions: [.v5]
)
