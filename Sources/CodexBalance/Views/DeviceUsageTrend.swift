import CodexBalanceCore
import Foundation
import SwiftUI

enum DeviceUsageTrendGranularity {
  case hourly
  case daily
}

struct DeviceUsageTrendDevice: Identifiable, Equatable {
  var id: String { deviceID }
  let deviceID: String
  let deviceName: String
  let updatedAt: Date?
  let colorIndex: Int
}

struct DeviceUsageTrendValue: Identifiable, Equatable {
  var id: String { device.id }
  let device: DeviceUsageTrendDevice
  let bucket: TokenBucket?
}

struct DeviceUsageTrendPoint: Identifiable, Equatable {
  var id: String { key }
  let key: String
  let label: String
  let values: [DeviceUsageTrendValue]

  var totalTokens: Int {
    values.compactMap(\.bucket).reduce(0) { $0 + $1.totalTokens }
  }

  var totalCalls: Int {
    values.compactMap(\.bucket).reduce(0) { $0 + $1.calls }
  }
}

struct DeviceUsageTrendData: Equatable {
  let devices: [DeviceUsageTrendDevice]
  let points: [DeviceUsageTrendPoint]
  let omittedDeviceCount: Int
  let usesLocalFallback: Bool

  var isMultiDevice: Bool { devices.count > 1 }
  var tooltipHeight: CGFloat { 54 + CGFloat(devices.count) * 20 }
}

enum DeviceUsageTrendBuilder {
  static let localFallbackID = "local-device"

  static func orderedDevices(
    from snapshots: [CodexDeviceTokenUsage],
    currentDeviceID: String?
  ) -> [DeviceUsageTrendDevice] {
    let sorted = snapshots.sorted { lhs, rhs in
      if lhs.deviceID == currentDeviceID, rhs.deviceID != currentDeviceID { return true }
      if rhs.deviceID == currentDeviceID, lhs.deviceID != currentDeviceID { return false }
      let nameOrder = lhs.deviceName.localizedStandardCompare(rhs.deviceName)
      if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
      return lhs.deviceID < rhs.deviceID
    }

    return sorted.enumerated().map { index, snapshot in
      DeviceUsageTrendDevice(
        deviceID: snapshot.deviceID,
        deviceName: snapshot.deviceName,
        updatedAt: snapshot.updatedAt,
        colorIndex: index
      )
    }
  }

  static func make(
    axisRows: [TokenBucket],
    snapshots: [CodexDeviceTokenUsage],
    currentDeviceID: String?,
    granularity: DeviceUsageTrendGranularity
  ) -> DeviceUsageTrendData {
    guard !snapshots.isEmpty else {
      return localFallback(axisRows: axisRows)
    }

    let axisKeys = Set(axisRows.map(\.key))
    let metadata = orderedDevices(from: snapshots, currentDeviceID: currentDeviceID)
    let snapshotsByID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.deviceID, $0) })
    var bucketsByDevice: [String: [String: TokenBucket]] = [:]
    var visibleDevices: [DeviceUsageTrendDevice] = []

    for device in metadata {
      guard let snapshot = snapshotsByID[device.deviceID] else { continue }
      let rows = granularity == .hourly ? snapshot.hourly : snapshot.daily
      var buckets: [String: TokenBucket] = [:]
      for row in rows {
        buckets[row.key] = row
      }
      guard buckets.keys.contains(where: axisKeys.contains) else { continue }
      bucketsByDevice[device.deviceID] = buckets
      visibleDevices.append(device)
    }

    guard !visibleDevices.isEmpty else {
      let fallbackName = metadata.first(where: { $0.deviceID == currentDeviceID })?.deviceName ?? "本机"
      return localFallback(
        axisRows: axisRows,
        deviceName: fallbackName,
        omittedDeviceCount: snapshots.count
      )
    }

    let points = axisRows.map { axisRow in
      DeviceUsageTrendPoint(
        key: axisRow.key,
        label: axisRow.label,
        values: visibleDevices.map { device in
          DeviceUsageTrendValue(
            device: device,
            bucket: bucketsByDevice[device.deviceID]?[axisRow.key]
          )
        }
      )
    }

    return DeviceUsageTrendData(
      devices: visibleDevices,
      points: points,
      omittedDeviceCount: metadata.count - visibleDevices.count,
      usesLocalFallback: false
    )
  }

  private static func localFallback(
    axisRows: [TokenBucket],
    deviceName: String = "本机",
    omittedDeviceCount: Int = 0
  ) -> DeviceUsageTrendData {
    let device = DeviceUsageTrendDevice(
      deviceID: localFallbackID,
      deviceName: deviceName,
      updatedAt: nil,
      colorIndex: 0
    )
    let points = axisRows.map { row in
      DeviceUsageTrendPoint(
        key: row.key,
        label: row.label,
        values: [DeviceUsageTrendValue(device: device, bucket: row)]
      )
    }
    return DeviceUsageTrendData(
      devices: [device],
      points: points,
      omittedDeviceCount: omittedDeviceCount,
      usesLocalFallback: true
    )
  }
}

enum DeviceUsageColorPalette {
  static func color(for index: Int, palette: DashboardPalette) -> Color {
    switch index {
    case 0: palette.usage24h
    case 1: palette.weekly
    case 2: Color(red: 0.98, green: 0.55, blue: 0.20)
    case 3: Color(red: 0.67, green: 0.50, blue: 0.96)
    case 4: Color(red: 0.95, green: 0.36, blue: 0.64)
    case 5: Color(red: 0.16, green: 0.73, blue: 0.67)
    case 6: Color(red: 0.89, green: 0.70, blue: 0.16)
    case 7: Color(red: 0.32, green: 0.61, blue: 0.91)
    default:
      Color(
        hue: (Double(index) * 0.618_033_988_75).truncatingRemainder(dividingBy: 1),
        saturation: 0.68,
        brightness: 0.88
      )
    }
  }
}

struct DeviceUsageLegend: View {
  let data: DeviceUsageTrendData
  let palette: DashboardPalette

  var body: some View {
    if data.isMultiDevice || data.omittedDeviceCount > 0 {
      VStack(alignment: .leading, spacing: 6) {
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 150), spacing: 10, alignment: .leading)],
          alignment: .leading,
          spacing: 6
        ) {
          ForEach(data.devices) { device in
            HStack(spacing: 6) {
              Circle()
                .fill(DeviceUsageColorPalette.color(for: device.colorIndex, palette: palette))
                .frame(width: 8, height: 8)
              VStack(alignment: .leading, spacing: 1) {
                Text(device.deviceName)
                  .font(.system(size: 10, weight: .bold))
                  .lineLimit(1)
                if let updatedAt = device.updatedAt {
                  Text("更新于 \(updatedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(DashboardColors.subtleText)
                }
              }
            }
          }
        }

        if data.omittedDeviceCount > 0 {
          Text("\(data.omittedDeviceCount) 台设备在当前时间范围暂无可对齐趋势数据，未加入叠加")
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(DashboardColors.subtleText)
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel("设备图例")
    }
  }
}

struct DeviceUsageTrendTooltip: View {
  let point: DeviceUsageTrendPoint
  let palette: DashboardPalette

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(point.label)
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(.secondary)
      Text("合计 \(HourlyTokenTooltipFormatter.compact(point.totalTokens)) Token · \(point.totalCalls) 次调用")
        .font(.system(size: 13, weight: .heavy, design: .rounded))
        .monospacedDigit()

      ForEach(point.values) { value in
        HStack(spacing: 6) {
          Circle()
            .fill(DeviceUsageColorPalette.color(for: value.device.colorIndex, palette: palette))
            .frame(width: 7, height: 7)
          Text(deviceLabel(value.device))
            .font(.system(size: 9, weight: .semibold))
            .lineLimit(1)
          Spacer(minLength: 6)
          if let bucket = value.bucket {
            Text("\(HourlyTokenTooltipFormatter.compact(bucket.totalTokens)) · \(bucket.calls) 次")
              .font(.system(size: 9, weight: .bold, design: .rounded))
              .monospacedDigit()
          } else {
            Text("暂无数据")
              .font(.system(size: 9, weight: .semibold))
              .foregroundStyle(DashboardColors.subtleText)
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .stroke(Color.primary.opacity(0.22), lineWidth: 1)
    }
    .shadow(color: Color.black.opacity(0.18), radius: 8, y: 4)
  }

  private func deviceLabel(_ device: DeviceUsageTrendDevice) -> String {
    guard let updatedAt = device.updatedAt else { return device.deviceName }
    return "\(device.deviceName) · \(updatedAt.formatted(date: .omitted, time: .shortened))"
  }
}

enum DeviceUsageTrendAccessibility {
  static func value(for point: DeviceUsageTrendPoint) -> String {
    let details = point.values.map { value in
      guard let bucket = value.bucket else {
        return "\(value.device.deviceName) 暂无数据"
      }
      return "\(value.device.deviceName) \(BalanceFormatters.exactNumber(bucket.totalTokens)) Token，\(bucket.calls) 次调用"
    }
    return ([
      "合计 \(BalanceFormatters.exactNumber(point.totalTokens)) Token，\(point.totalCalls) 次调用"
    ] + details).joined(separator: "；")
  }
}
