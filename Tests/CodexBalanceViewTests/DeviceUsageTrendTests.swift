import CodexBalanceCore
import Foundation
import Testing
@testable import CodexBalance

@Suite("Device usage trend aggregation")
struct DeviceUsageTrendTests {
  @Test
  func alignsBucketsAndAggregatesIndependentlyOfSnapshotOrder() {
    let axis = [
      bucket("h1", "09时", tokens: 0),
      bucket("h2", "10时", tokens: 0)
    ]
    let current = snapshot(
      id: "current",
      name: "MacBook Pro",
      hourly: [
        bucket("h1", "09时", tokens: 10, calls: 1),
        bucket("h2", "10时", tokens: 0, calls: 0)
      ]
    )
    let remote = snapshot(
      id: "remote",
      name: "Mac Studio",
      hourly: [bucket("h1", "09时", tokens: 20, calls: 2)]
    )

    let forward = DeviceUsageTrendBuilder.make(
      axisRows: axis,
      snapshots: [current, remote],
      currentDeviceID: "current",
      granularity: .hourly
    )
    let reversed = DeviceUsageTrendBuilder.make(
      axisRows: axis,
      snapshots: [remote, current],
      currentDeviceID: "current",
      granularity: .hourly
    )

    #expect(forward == reversed)
    #expect(forward.devices.map(\.deviceID) == ["current", "remote"])
    #expect(forward.points.map(\.totalTokens) == [30, 0])
    #expect(forward.points.map(\.totalCalls) == [3, 0])
  }

  @Test
  func distinguishesExplicitZeroFromMissingBucket() throws {
    let data = DeviceUsageTrendBuilder.make(
      axisRows: [
        bucket("h1", "09时", tokens: 0),
        bucket("h2", "10时", tokens: 0)
      ],
      snapshots: [
        snapshot(
          id: "current",
          name: "MacBook Pro",
          hourly: [
            bucket("h1", "09时", tokens: 0),
            bucket("h2", "10时", tokens: 0)
          ]
        ),
        snapshot(
          id: "remote",
          name: "Mac Studio",
          hourly: [bucket("h1", "09时", tokens: 9)]
        )
      ],
      currentDeviceID: "current",
      granularity: .hourly
    )

    let point = try #require(data.points.last)
    let currentValue = try #require(point.values.first { $0.device.deviceID == "current" })
    let remoteValue = try #require(point.values.first { $0.device.deviceID == "remote" })
    #expect(currentValue.bucket?.totalTokens == 0)
    #expect(remoteValue.bucket == nil)
    #expect(data.omittedDeviceCount == 0)
  }

  @Test
  func keepsMissingValuesForPartialLegacyDailyCoverage() throws {
    let days = [
      bucket("2026-07-19", "7/19", tokens: 0),
      bucket("2026-07-20", "7/20", tokens: 0),
      bucket("2026-07-21", "7/21", tokens: 0)
    ]
    let current = snapshot(
      id: "current",
      name: "MacBook Pro",
      daily: [
        bucket("2026-07-19", "7/19", tokens: 10),
        bucket("2026-07-20", "7/20", tokens: 20),
        bucket("2026-07-21", "7/21", tokens: 30)
      ]
    )
    let legacy = snapshot(
      schema: 3,
      id: "legacy",
      name: "Old Mac",
      daily: [bucket("2026-07-20", "7/20", tokens: 5)]
    )

    let data = DeviceUsageTrendBuilder.make(
      axisRows: days,
      snapshots: [current, legacy],
      currentDeviceID: "current",
      granularity: .daily
    )

    #expect(data.points.map(\.totalTokens) == [10, 25, 30])
    let firstLegacy = try #require(data.points[0].values.first { $0.device.deviceID == "legacy" })
    let middleLegacy = try #require(data.points[1].values.first { $0.device.deviceID == "legacy" })
    #expect(firstLegacy.bucket == nil)
    #expect(middleLegacy.bucket?.totalTokens == 5)
    #expect(DeviceUsageTrendAccessibility.value(for: data.points[0]).contains("Old Mac 暂无数据"))
  }

  @Test
  func omitsSchemaWithoutMatchingTrendButKeepsStableColorSlots() {
    let current = snapshot(
      id: "current",
      name: "MacBook Pro",
      hourly: [bucket("h1", "09时", tokens: 10)],
      daily: [bucket("d1", "7/21", tokens: 10)]
    )
    let legacy = snapshot(
      schema: 2,
      id: "legacy",
      name: "Old Mac",
      daily: [bucket("d1", "7/21", tokens: 5)]
    )
    let hourly = DeviceUsageTrendBuilder.make(
      axisRows: [bucket("h1", "09时", tokens: 0)],
      snapshots: [legacy, current],
      currentDeviceID: "current",
      granularity: .hourly
    )
    let daily = DeviceUsageTrendBuilder.make(
      axisRows: [bucket("d1", "7/21", tokens: 0)],
      snapshots: [current, legacy],
      currentDeviceID: "current",
      granularity: .daily
    )

    #expect(hourly.devices.map(\.deviceID) == ["current"])
    #expect(hourly.omittedDeviceCount == 1)
    #expect(daily.devices.map(\.deviceID) == ["current", "legacy"])
    #expect(hourly.devices.first?.colorIndex == daily.devices.first?.colorIndex)
    #expect(daily.devices.first { $0.deviceID == "legacy" }?.colorIndex == 1)
  }

  @Test
  func fallsBackToLocalSeriesWhenICloudSnapshotsAreUnavailable() {
    let axis = [bucket("h1", "09时", tokens: 42, calls: 3)]

    let data = DeviceUsageTrendBuilder.make(
      axisRows: axis,
      snapshots: [],
      currentDeviceID: nil,
      granularity: .hourly
    )

    #expect(data.usesLocalFallback)
    #expect(data.devices.count == 1)
    #expect(data.devices.first?.deviceID == DeviceUsageTrendBuilder.localFallbackID)
    #expect(data.points.first?.totalTokens == 42)
    #expect(data.points.first?.totalCalls == 3)
  }

  @Test
  func accessibilityTextIncludesTotalsDevicesAndMissingState() throws {
    let data = DeviceUsageTrendBuilder.make(
      axisRows: [bucket("d1", "7/21", tokens: 0)],
      snapshots: [
        snapshot(
          id: "current",
          name: "MacBook Pro",
          daily: [bucket("d1", "7/21", tokens: 12, calls: 1)]
        ),
        snapshot(
          id: "remote",
          name: "Mac Studio",
          daily: [bucket("d0", "7/20", tokens: 8)]
        )
      ],
      currentDeviceID: "current",
      granularity: .daily
    )
    let point = try #require(data.points.first)
    let text = DeviceUsageTrendAccessibility.value(for: point)

    #expect(text.contains("合计 12 Token"))
    #expect(text.contains("MacBook Pro 12 Token"))
    #expect(data.omittedDeviceCount == 1)
  }

  private func bucket(
    _ key: String,
    _ label: String,
    tokens: Int,
    calls: Int = 0
  ) -> TokenBucket {
    TokenBucket(key: key, label: label, totalTokens: tokens, calls: calls)
  }

  private func snapshot(
    schema: Int = 4,
    id: String,
    name: String,
    hourly: [TokenBucket] = [],
    daily: [TokenBucket] = []
  ) -> CodexDeviceTokenUsage {
    CodexDeviceTokenUsage(
      schemaVersion: schema,
      deviceID: id,
      deviceName: name,
      hostName: id,
      updatedAt: Date(timeIntervalSince1970: 1_753_070_400),
      todayTokens: daily.last?.totalTokens ?? 0,
      monthTokens: daily.reduce(0) { $0 + $1.totalTokens },
      sampleCount: hourly.reduce(0) { $0 + $1.calls } + daily.reduce(0) { $0 + $1.calls },
      hourly: hourly,
      daily: daily,
      monthly: []
    )
  }
}
