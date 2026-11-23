import Foundation

/// 外设设备基础分类
public enum PeripheralCategory: String, Codable, CaseIterable, Sendable {
    case mouse = "鼠标"
    case keyboard = "键盘"
    case headset = "耳机"
    case other = "外设"

    public var emoji: String {
        switch self {
        case .mouse: return "🖱️"
        case .keyboard: return "⌨️"
        case .headset: return "🎧"
        case .other: return "🎮"
        }
    }

    public var symbolName: String {
        switch self {
        case .mouse: return "magicmouse.fill"
        case .keyboard: return "keyboard.fill"
        case .headset: return "headphones"
        case .other: return "sparkles"
        }
    }

    public var shortTag: String {
        switch self {
        case .mouse: return "鼠"
        case .keyboard: return "键"
        case .headset: return "耳"
        case .other: return "设"
        }
    }
}

/// 外设连接传输通道
public enum PeripheralTransport: String, Codable, CaseIterable, Sendable {
    case wireless24G = "2.4G"
    case bluetooth = "蓝牙"
    case wired = "有线"

    public var badge: String {
        switch self {
        case .wireless24G: return "2.4G"
        case .bluetooth: return "蓝牙"
        case .wired: return "有线"
        }
    }
}

/// 2.4G / 蓝牙 无线外设电量模型
public struct PeripheralBattery: Codable, Identifiable, Hashable, Sendable {
    /// 唯一标识（通常为 VID_PID_Serial 或设备标识）
    public let id: String
    /// 设备名称（如 "Razer Viper V3 Pro"）
    public var name: String
    /// SF Symbol 图标名称（如 "magicmouse.fill", "keyboard.fill"）
    public var symbolName: String
    /// 剩余电量百分比（0 ~ 100，-1 表示设备离线或已休眠）
    public var percentage: Int
    /// 是否正在充电
    public var isCharging: Bool
    /// 连接传输类型（2.4G / 蓝牙 / 有线）
    public var transport: PeripheralTransport
    /// 最近一次更新时间
    public var updatedAt: Date

    public init(
        id: String,
        name: String,
        symbolName: String = "magicmouse.fill",
        percentage: Int,
        isCharging: Bool = false,
        transport: PeripheralTransport = .wireless24G,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.percentage = percentage
        self.isCharging = isCharging
        self.transport = transport
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, symbolName, percentage, isCharging, transport, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.symbolName = try container.decode(String.self, forKey: .symbolName)
        self.percentage = try container.decode(Int.self, forKey: .percentage)
        self.isCharging = try container.decode(Bool.self, forKey: .isCharging)
        self.transport = try container.decodeIfPresent(PeripheralTransport.self, forKey: .transport) ?? .wireless24G
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    /// 是否处于离线或休眠状态
    public var isOffline: Bool {
        percentage < 0
    }

    /// 电量展示文本（离线时显示 "--"）
    public var displayPercentage: String {
        isOffline ? "--" : "\(percentage)%"
    }

    /// 根据设备名称和 SF Symbol 自动推导设备分类
    public var category: PeripheralCategory {
        let lowerName = name.lowercased()
        let lowerSymbol = symbolName.lowercased()

        // 1. 耳机分类
        if lowerName.contains("barracuda") || lowerName.contains("blackshark") ||
           lowerName.contains("kraken") || lowerName.contains("nari") ||
           lowerName.contains("headset") || lowerName.contains("cloud") ||
           lowerName.contains("audio") || lowerName.contains("arctis") ||
           lowerName.contains("headphone") || lowerName.contains("earphone") ||
           lowerSymbol.contains("headphone") {
            return .headset
        }

        // 2. 鼠标分类
        if lowerName.contains("mouse") || lowerName.contains("viper") ||
           lowerName.contains("deathadder") || lowerName.contains("basilisk") ||
           lowerName.contains("cobra") || lowerName.contains("naga") ||
           lowerName.contains("g pro") || lowerName.contains("g502") ||
           lowerName.contains("g304") || lowerName.contains("g703") ||
           lowerName.contains("g903") || lowerName.contains("master") ||
           lowerName.contains("anywhere") || lowerSymbol.contains("mouse") {
            return .mouse
        }

        // 3. 键盘分类
        if lowerName.contains("keyboard") || lowerName.contains("key") ||
           lowerName.contains("blackwidow") || lowerName.contains("huntsman") ||
           lowerName.contains("deathstalker") || lowerName.contains("g913") ||
           lowerName.contains("g915") || lowerName.contains("craft") ||
           lowerSymbol.contains("keyboard") {
            return .keyboard
        }

        return .other
    }

    /// 外设类型简称（如 "鼠", "键", "耳"）
    public var shortTag: String {
        category.shortTag
    }

    /// 外设类型对应 Emoji
    public var emoji: String {
        category.emoji
    }

    /// 控制中心单设备简明摘要，如 "鼠7%"、"耳61%"
    public var shortSummary: String {
        let chargeMark = isCharging ? "⚡" : ""
        return "\(shortTag)\(displayPercentage)\(chargeMark)"
    }

    /// 控制中心单设备富徽标，如 "🖱️ 鼠7%" 或 "🎧 耳61%⚡"
    public var categorizedSummary: String {
        let chargeMark = isCharging ? "⚡" : ""
        return "\(emoji) \(shortTag)\(displayPercentage)\(chargeMark)"
    }
}
