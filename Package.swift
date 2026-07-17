// swift-tools-version: 6.0

import PackageDescription
import Foundation

let developerDir = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] ?? "/Library/Developer/CommandLineTools"
let testingFrameworks = developerDir + "/Library/Developer/Frameworks"
let testingLibraries = developerDir + "/Library/Developer/usr/lib"
let testingFlags: [SwiftSetting] = FileManager.default.fileExists(atPath: testingFrameworks + "/Testing.framework")
  ? [.unsafeFlags(["-F", testingFrameworks], .when(platforms: [.macOS]))]
  : []
let testingLinkerFlags: [LinkerSetting] = FileManager.default.fileExists(atPath: testingFrameworks + "/Testing.framework")
  ? [.unsafeFlags([
    "-F", testingFrameworks,
    "-Xlinker", "-rpath", "-Xlinker", testingFrameworks,
    "-Xlinker", "-rpath", "-Xlinker", testingLibraries
  ], .when(platforms: [.macOS]))]
  : []

let package = Package(
  name: "CodexSuanliMeter",
  defaultLocalization: "zh-Hans",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(name: "CodexSuanliMeter", targets: ["CodexBalance"]),
    .executable(name: "CodexSuanliWidgets", targets: ["CodexSuanliWidgets"])
  ],
  targets: [
    .target(name: "CodexBalanceCore"),
    .executableTarget(
      name: "CodexBalance",
      dependencies: ["CodexBalanceCore"]
    ),
    .executableTarget(
      name: "CodexSuanliWidgets",
      dependencies: ["CodexBalanceCore"],
      swiftSettings: [
        .unsafeFlags(["-application-extension"], .when(platforms: [.macOS]))
      ]
    ),
    .executableTarget(
      name: "TestRunner",
      dependencies: ["CodexBalanceCore"],
      swiftSettings: testingFlags,
      linkerSettings: testingLinkerFlags
    ),
    .testTarget(
      name: "CodexBalanceCoreTests",
      dependencies: ["CodexBalanceCore"],
      swiftSettings: testingFlags,
      linkerSettings: testingLinkerFlags
    ),
    .testTarget(
      name: "CodexBalanceViewTests",
      dependencies: ["CodexBalance"],
      swiftSettings: testingFlags,
      linkerSettings: testingLinkerFlags
    )
  ]
)
