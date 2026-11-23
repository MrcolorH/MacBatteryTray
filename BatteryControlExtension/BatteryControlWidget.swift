import WidgetKit
import SwiftUI
import AppIntents

/// 控制中心展示的外设电量快照
public struct BatteryControlValue: Sendable {
    public let title: String
    public let summary: String
    public let symbolName: String
    public let isCharging: Bool
    public let lowestPercentage: Int
    public let deviceCount: Int

    public init(
        title: String = "外设电量",
        summary: String,
        symbolName: String = "battery.100.bolt",
        isCharging: Bool = false,
        lowestPercentage: Int = 100,
        deviceCount: Int = 0
    ) {
        self.title = title
        self.summary = summary
        self.symbolName = symbolName
        self.isCharging = isCharging
        self.lowestPercentage = lowestPercentage
        self.deviceCount = deviceCount
    }

    public var tintColor: Color {
        if isCharging {
            return .green
        }
        if deviceCount == 0 {
            return .secondary
        }
        if lowestPercentage <= 15 {
            return .red
        }
        if lowestPercentage <= 35 {
            return .orange
        }
        return .green
    }
}

/// 控制中心数据提供器（当调用 ControlCenter.shared.reloadAllControls 时重新拉取）
@available(macOS 26.0, *)
public struct BatteryControlValueProvider: ControlValueProvider {
    public init() {}

    public var previewValue: BatteryControlValue {
        BatteryControlValue(
            title: "外设电量 (2)",
            summary: "🖱️ 鼠85%   🎧 耳60%",
            symbolName: "battery.75",
            isCharging: false,
            lowestPercentage: 60,
            deviceCount: 2
        )
    }

    public func currentValue() async throws -> BatteryControlValue {
        let batteries = BatteryStore.shared.loadBatteries()
        guard !batteries.isEmpty else {
            return BatteryControlValue(
                title: "外设电量",
                summary: "未检测到外设",
                symbolName: "battery.0",
                isCharging: false,
                lowestPercentage: 0,
                deviceCount: 0
            )
        }

        let anyCharging = batteries.contains { $0.isCharging }
        let lowest = batteries.map(\.percentage).min() ?? 100

        // 动态计算代表性电池图标（SF Symbols: battery.0, battery.25, battery.50, battery.75, battery.100）
        let symbolName: String
        if anyCharging {
            symbolName = "battery.100.bolt"
        } else if lowest <= 10 {
            symbolName = "battery.0"
        } else if lowest <= 35 {
            symbolName = "battery.25"
        } else if lowest <= 65 {
            symbolName = "battery.50"
        } else if lowest <= 85 {
            symbolName = "battery.75"
        } else {
            symbolName = "battery.100"
        }

        // 聚合多设备分类富徽标，如 "🖱️ 鼠7%   🎧 耳61%"
        let summary = BatteryStore.shared.multiDeviceSummary()

        let titleText: String
        if batteries.count == 1, let single = batteries.first {
            titleText = "\(single.category.rawValue)电量"
        } else {
            titleText = "外设电量 (\(batteries.count))"
        }

        return BatteryControlValue(
            title: titleText,
            summary: summary,
            symbolName: symbolName,
            isCharging: anyCharging,
            lowestPercentage: lowest,
            deviceCount: batteries.count
        )
    }
}

/// macOS 控制中心磁贴组件
@available(macOS 26.0, *)
public struct BatteryControlWidget: ControlWidget {
    public static let kind: String = "com.local.MacBatteryTray.BatteryControl"

    public init() {}

    public var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind, provider: BatteryControlValueProvider()) { value in
            ControlWidgetButton(action: RefreshBatteryIntent()) {
                Label(value.title, systemImage: value.symbolName)
                Text(value.summary)
            }
            .tint(value.tintColor)
        }
        .displayName("外设电量")
        .description("查看 2.4G 无线外设电量并点击手动刷新")
    }
}
