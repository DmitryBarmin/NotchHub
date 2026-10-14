// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "NotchHub", platforms: [.macOS(.v14)], products: [.executable(name: "NotchHub", targets: ["NotchHub"])], targets: [.executableTarget(name: "NotchHub"), .testTarget(name: "NotchHubTests", dependencies: ["NotchHub"])])
