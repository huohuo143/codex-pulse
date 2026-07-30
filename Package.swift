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
    // 主应用仅使用 macOS 13 可用的 AppKit / SwiftUI API。桌面小组件作为
    // 独立的 App Extension，仍由 Xcode target 保持 macOS 14 部署目标。
    .macOS(.v13)
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
