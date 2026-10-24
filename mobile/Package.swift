// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "CodexMobileCore",
  platforms: [.macOS(.v13), .iOS(.v17)],
  products: [.library(name: "CodexMobileCore", targets: ["CodexMobileCore"])],
  targets: [
    .target(name: "CodexMobileCore", path: "shared"),
    .testTarget(name: "CodexMobileCoreTests", dependencies: ["CodexMobileCore"], path: "tests")
  ]
)
