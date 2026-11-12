// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "NanoLoroCompatibility",
    platforms: [.macOS(.v13)],
    dependencies: [.package(url: "https://github.com/loro-dev/loro-swift.git", exact: "1.13.3")],
    targets: [.executableTarget(name: "LoroCompatibility", dependencies: [.product(name: "Loro", package: "loro-swift")])]
)
