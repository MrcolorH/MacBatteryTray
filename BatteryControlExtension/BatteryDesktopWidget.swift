import WidgetKit
import SwiftUI
import AppIntents

/// 桌面与通知中心 Widget 时间线数据项
public struct BatteryTimelineEntry: TimelineEntry {
    public let date: Date
    public let batteries: [PeripheralBattery]

    public init(date: Date, batteries: [PeripheralBattery]) {
        self.date = date
        self.batteries = batteries
    }
}

/// 桌面 Widget 数据提供器
public struct BatteryTimelineProvider: TimelineProvider {
    public init() {}

    public func placeholder(in context: Context) -> BatteryTimelineEntry {
        BatteryTimelineEntry(date: Date(), batteries: [
            PeripheralBattery(id: "demo_mouse", name: "DeathAdder V3 Pro", symbolName: "computermouse.fill", percentage: 85, isCharging: false),
            PeripheralBattery(id: "demo_headset", name: "Barracuda Pro 2.4", symbolName: "headphones", percentage: 68, isCharging: false),
            PeripheralBattery(id: "demo_kb", name: "Wireless Keyboard", symbolName: "keyboard.fill", percentage: 92, isCharging: false)
        ])
    }

    public func getSnapshot(in context: Context, completion: @escaping (BatteryTimelineEntry) -> Void) {
        let list = BatteryStore.shared.loadBatteries()
        completion(BatteryTimelineEntry(date: Date(), batteries: list))
    }

    public func getTimeline(in context: Context, completion: @escaping (Timeline<BatteryTimelineEntry>) -> Void) {
        let list = BatteryStore.shared.loadBatteries()
        let entry = BatteryTimelineEntry(date: Date(), batteries: list)
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 5, to: Date()) ?? Date().addingTimeInterval(300)
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }
}

/// 桌面 Widget 视图呈现（类苹果原生电池小组件，兼容浅/深色与单色玻璃渲染模式）
public struct BatteryDesktopWidgetEntryView: View {
    public var entry: BatteryTimelineProvider.Entry
    @Environment(\.widgetFamily) var family

    public init(entry: BatteryTimelineProvider.Entry) {
        self.entry = entry
    }

    private var activeBatteries: [PeripheralBattery] {
        let valid = entry.batteries.filter { $0.percentage >= 0 }
        let order: [PeripheralCategory: Int] = [.mouse: 1, .keyboard: 2, .headset: 3, .other: 4]
        return valid.sorted { (order[$0.category] ?? 99) < (order[$1.category] ?? 99) }
    }

    public var body: some View {
        ZStack(alignment: .topTrailing) {
            // 1. 全局底层交互拦截：吸收小组件背景处的点击，抑制系统默认误唤起宿主 App
            Button(intent: SilentWidgetTapIntent()) {
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // 2. 主体外设电量展示
            Group {
                if activeBatteries.isEmpty {
                    emptyStateView
                } else {
                    switch family {
                    case .systemSmall:
                        smallLayout
                    case .systemLarge:
                        largeLayout
                    default:
                        mediumLayout
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .invalidatableContent()

            // 3. 右上角操作区：设置齿轮按钮（唤起 App）+ 刷新按钮（静默刷新）
            HStack(spacing: 4) {
                // 齿轮设置按钮：仅点击此处才打开 App 本体配置面板
                Link(destination: URL(string: "macbatterytray://open")!) {
                    ZStack {
                        Circle()
                            .strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.8)
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 18, height: 18)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)

                // 刷新按钮：静默刷新电量，绝不唤起 App
                Button(intent: RefreshBatteryIntent()) {
                    ZStack {
                        Circle()
                            .strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.8)
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 18, height: 18)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .invalidatableContent()
            }
            .offset(x: 5, y: -5)
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    // MARK: - 苹果原生电量色彩
    private func batteryColor(for percentage: Int, isCharging: Bool) -> Color {
        if isCharging { return .green }
        if percentage <= 20 { return .red }
        if percentage <= 35 { return .orange }
        return .green
    }

    /// 去掉冗余品牌前缀与尾部 2.4，保留干净型号名
    private func compactName(for name: String) -> String {
        let prefixes = ["Razer ", "Logitech ", "SteelSeries ", "HyperX ", "2.4G "]
        var trimmed = name
        for prefix in prefixes {
            if trimmed.hasPrefix(prefix) {
                trimmed = String(trimmed.dropFirst(prefix.count))
                break
            }
        }
        if trimmed.hasSuffix(" 2.4") {
            trimmed = String(trimmed.dropLast(4))
        }
        return trimmed
    }

    private func sfSymbol(for item: PeripheralBattery) -> String {
        switch item.category {
        case .mouse: return "computermouse.fill"
        case .keyboard: return "keyboard.fill"
        case .headset: return "headphones"
        case .other: return "dot.radiowaves.left.and.right"
        }
    }

    // MARK: - 1. 小尺寸 (systemSmall)：最多 4 个设备
    @ViewBuilder
    private var smallLayout: some View {
        let items = Array(activeBatteries.prefix(4))
        if items.count == 1, let item = items.first {
            VStack(spacing: 10) {
                batteryRing(for: item, diameter: 74, lineWidth: 7, iconSize: 24)
                VStack(spacing: 2) {
                    percentageLabel(for: item, fontSize: 22, boltSize: 12)
                    Text(compactName(for: item.name))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.top, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if items.count <= 3 {
            VStack(spacing: items.count == 2 ? 14 : 10) {
                ForEach(items) { item in
                    compactRow(for: item)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 10) {
                ForEach(items) { item in
                    VStack(spacing: 4) {
                        batteryRing(for: item, diameter: 44, lineWidth: 4.5, iconSize: 15)
                        percentageLabel(for: item, fontSize: 12, boltSize: 9)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - 2. 中尺寸 (systemMedium)：最多 4 个设备
    @ViewBuilder
    private var mediumLayout: some View {
        let items = Array(activeBatteries.prefix(4))
        if items.count <= 2 {
            VStack(spacing: items.count == 1 ? 0 : 14) {
                ForEach(items) { item in
                    mediumRow(for: item)
                }
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let ringDiameter: CGFloat = items.count == 3 ? 52 : 48
            let iconSize: CGFloat = items.count == 3 ? 18 : 16
            HStack(spacing: items.count == 3 ? 8 : 6) {
                ForEach(items) { item in
                    VStack(spacing: 6) {
                        batteryRing(for: item, diameter: ringDiameter, lineWidth: 5.0, iconSize: iconSize)
                        VStack(spacing: 2) {
                            percentageLabel(for: item, fontSize: items.count == 3 ? 16 : 14, boltSize: items.count == 3 ? 11 : 10)
                            Text(compactName(for: item.name))
                                .font(.system(size: items.count == 3 ? 10.5 : 9.5, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.68)
                                .allowsTightening(true)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 8)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - 3. 大尺寸 (systemLarge)：最多 6 个设备
    private var largeLayout: some View {
        let items = Array(activeBatteries.prefix(6))
        return VStack(spacing: 12) {
            ForEach(items) { item in
                mediumRow(for: item)
            }
            if items.count < 4 {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 电量数字与充电闪电标签（无背景色块，单色玻璃态同样清晰）
    @ViewBuilder
    private func percentageLabel(for item: PeripheralBattery, fontSize: CGFloat, boltSize: CGFloat) -> some View {
        HStack(spacing: 2) {
            if item.isCharging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: boltSize, weight: .bold))
                    .foregroundStyle(.green)
            }
            Text("\(item.percentage)%")
                .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                .foregroundStyle(item.percentage <= 20 && !item.isCharging ? .red : .primary)
        }
    }

    // MARK: - 中/大尺寸饱满单行组件
    @ViewBuilder
    private func mediumRow(for item: PeripheralBattery) -> some View {
        let color = batteryColor(for: item.percentage, isCharging: item.isCharging)
        let progress = max(0.0, min(1.0, Double(item.percentage) / 100.0))

        HStack(spacing: 12) {
            batteryRing(for: item, diameter: 42, lineWidth: 4.5, iconSize: 16)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(compactName(for: item.name))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    percentageLabel(for: item, fontSize: 15, boltSize: 10)
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.primary.opacity(0.10))
                        Capsule()
                            .fill(color)
                            .frame(width: max(6, geo.size.width * progress))
                    }
                }
                .frame(height: 6)
            }
        }
    }

    // MARK: - 小尺寸紧凑行组件
    @ViewBuilder
    private func compactRow(for item: PeripheralBattery) -> some View {
        let color = batteryColor(for: item.percentage, isCharging: item.isCharging)
        let progress = max(0.0, min(1.0, Double(item.percentage) / 100.0))

        HStack(spacing: 8) {
            Image(systemName: sfSymbol(for: item))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(compactName(for: item.name))
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    percentageLabel(for: item, fontSize: 12, boltSize: 9)
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.primary.opacity(0.10))
                        Capsule()
                            .fill(color)
                            .frame(width: max(5, geo.size.width * progress))
                    }
                }
                .frame(height: 5)
            }
        }
    }

    // MARK: - 原生圆环电量组件（去掉圆形底衬，防止单色玻璃态变实心圆点）
    @ViewBuilder
    private func batteryRing(for item: PeripheralBattery, diameter: CGFloat, lineWidth: CGFloat, iconSize: CGFloat) -> some View {
        let progress = max(0.0, min(1.0, Double(item.percentage) / 100.0))
        let color = batteryColor(for: item.percentage, isCharging: item.isCharging)

        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.12), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    color,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            Image(systemName: sfSymbol(for: item))
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(.primary)
        }
        .frame(width: diameter, height: diameter)
    }

    // MARK: - 空状态
    private var emptyStateView: some View {
        VStack(spacing: 6) {
            Image(systemName: "battery.0")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.secondary)
            Text("无已连接设备")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 桌面与通知中心 Widget 定义
public struct BatteryDesktopWidget: Widget {
    public static let kind: String = "com.local.MacBatteryTray.BatteryDesktopWidget"

    public init() {}

    public var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: BatteryTimelineProvider()) { entry in
            BatteryDesktopWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("外设电量")
        .description("简约显示无线外设剩余电量")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
