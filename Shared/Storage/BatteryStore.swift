import Foundation

/// 轮询时间单位
public enum PollingTimeUnit: String, Codable, CaseIterable, Sendable {
    case seconds = "秒"
    case minutes = "分"
    case hours = "时"

    public var multiplier: Int {
        switch self {
        case .seconds: return 1
        case .minutes: return 60
        case .hours: return 3600
        }
    }
}

/// 用户偏好设置模型
public struct BatteryAppSettings: Codable, Sendable {
    /// 是否在界面中展示蓝牙外设电量（默认 false，用户按需开启）
    public var showBluetoothDevices: Bool
    /// 轮询间隔数值（最低 1，仅支持整数）
    public var pollingIntervalValue: Int
    /// 轮询时间单位（默认秒）
    public var pollingIntervalUnit: PollingTimeUnit

    /// 换算为实际生效的轮询秒数（最低 1 秒）
    public var effectivePollingIntervalSeconds: Int {
        let total = max(1, pollingIntervalValue) * pollingIntervalUnit.multiplier
        return max(1, total)
    }

    public init(
        showBluetoothDevices: Bool = false,
        pollingIntervalValue: Int = 60,
        pollingIntervalUnit: PollingTimeUnit = .seconds
    ) {
        self.showBluetoothDevices = showBluetoothDevices
        self.pollingIntervalValue = max(1, pollingIntervalValue)
        self.pollingIntervalUnit = pollingIntervalUnit
    }

    private enum CodingKeys: String, CodingKey {
        case showBluetoothDevices
        case pollingIntervalValue
        case pollingIntervalUnit
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.showBluetoothDevices = try container.decodeIfPresent(Bool.self, forKey: .showBluetoothDevices) ?? false
        self.pollingIntervalValue = max(1, try container.decodeIfPresent(Int.self, forKey: .pollingIntervalValue) ?? 60)
        self.pollingIntervalUnit = try container.decodeIfPresent(PollingTimeUnit.self, forKey: .pollingIntervalUnit) ?? .seconds
    }
}

/// 跨进程外设电量存储器（支持 App Group 共享容器与本地降级）
public final class BatteryStore: @unchecked Sendable {
    public static let shared = BatteryStore()

    /// App Group 标识符（实际签名时会带上 $(TEAM_ID) 前缀，如 ABCDE12345.group.com.local.MacBatteryTray）
    public static let defaultGroupIdentifier = "group.com.local.MacBatteryTray"
    private static let fileName = "battery.json"
    private static let settingsFileName = "settings.json"

    private let fileManager = FileManager.default
    private let lock = NSLock()
    private let groupIdentifier: String

    public init(groupIdentifier: String = BatteryStore.defaultGroupIdentifier) {
        self.groupIdentifier = groupIdentifier
    }

    /// 获取配置存储路径
    public var settingsFileURL: URL {
        let dir = storageFileURL.deletingLastPathComponent()
        return dir.appendingPathComponent(Self.settingsFileName)
    }

    /// 读取用户设置
    public func loadSettings() -> BatteryAppSettings {
        let url = settingsFileURL
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(BatteryAppSettings.self, from: data) else {
            return BatteryAppSettings()
        }
        return settings
    }

    /// 保存用户设置
    public func saveSettings(_ settings: BatteryAppSettings) {
        let url = settingsFileURL
        let dir = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if let data = try? JSONEncoder().encode(settings) {
            try? data.write(to: url, options: [.atomic])
        }
    }

    /// 是否展示蓝牙外设电量快捷访问器
    public var showBluetoothDevices: Bool {
        get {
            loadSettings().showBluetoothDevices
        }
        set {
            var s = loadSettings()
            s.showBluetoothDevices = newValue
            saveSettings(s)
        }
    }

    /// 轮询间隔数值
    public var pollingIntervalValue: Int {
        get {
            loadSettings().pollingIntervalValue
        }
        set {
            var s = loadSettings()
            s.pollingIntervalValue = max(1, newValue)
            saveSettings(s)
        }
    }

    /// 轮询间隔单位
    public var pollingIntervalUnit: PollingTimeUnit {
        get {
            loadSettings().pollingIntervalUnit
        }
        set {
            var s = loadSettings()
            s.pollingIntervalUnit = newValue
            saveSettings(s)
        }
    }

    /// 获取系统真实的用户主目录（即使在沙盒环境中也能解析出真实路径，供临时例外路径读写）
    private var realUserHomeDirectory: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir))
        }
        return fileManager.homeDirectoryForCurrentUser
    }

    /// 获取共享文件存储路径（优先真实 Application Support，沙盒下通过临时例外打通）
    public var storageFileURL: URL {
        // 1. 尝试使用 App Group 共享目录（当通过正式开发者证书签名并配置 Provisioning Profile 时）
        if let containerURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier) {
            let groupFile = containerURL.appendingPathComponent(Self.fileName)
            if fileManager.fileExists(atPath: groupFile.path) {
                return groupFile
            }
        }

        // 2. 真实用户主目录: ~/Library/Application Support/MacBatteryTray/battery.json
        // (在 App Sandbox 扩展中，通过 temporary-exception.files.home-relative-path.read-write 获得读写权限)
        let realAppSupportDir = realUserHomeDirectory
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("MacBatteryTray")
        let realFileURL = realAppSupportDir.appendingPathComponent(Self.fileName)

        if fileManager.fileExists(atPath: realFileURL.path) {
            return realFileURL
        }

        // 3. 沙盒容器自身路径降级
        let containerFallbackDir = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("MacBatteryTray")
        let containerFallbackURL = containerFallbackDir.appendingPathComponent(Self.fileName)
        if fileManager.fileExists(atPath: containerFallbackURL.path) {
            return containerFallbackURL
        }

        // 默认确保真实目录存在并返回
        if !fileManager.fileExists(atPath: realAppSupportDir.path) {
            try? fileManager.createDirectory(at: realAppSupportDir, withIntermediateDirectories: true)
        }
        return realFileURL
    }

    /// 从存储中读取所有当前在线的外设电量记录（拔出或离线设备自动过滤，并根据偏好设置过滤蓝牙外设）
    public func loadBatteries() -> [PeripheralBattery] {
        lock.lock()
        defer { lock.unlock() }

        let url = storageFileURL
        guard fileManager.fileExists(atPath: url.path) else {
            return []
        }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let list = try decoder.decode([PeripheralBattery].self, from: data)
            let active = list.filter { $0.percentage >= -1 }
            let order: [PeripheralCategory: Int] = [.mouse: 1, .keyboard: 2, .headset: 3, .other: 4]
            let sorted = active.sorted { a, b in
                let aOnline = a.percentage >= 0
                let bOnline = b.percentage >= 0
                if aOnline != bOnline {
                    return aOnline && !bOnline // 在线优先在前，离线默认沉底
                }
                let aOrder = order[a.category] ?? 99
                let bOrder = order[b.category] ?? 99
                if aOrder != bOrder {
                    return aOrder < bOrder
                }
                return a.id < b.id
            }

            // 若未开启“展示蓝牙设备”，过滤掉蓝牙外设
            if !showBluetoothDevices {
                return sorted.filter { $0.transport != .bluetooth }
            }
            return sorted
        } catch {
            print("[BatteryStore] 读取电量缓存失败: \(error.localizedDescription)")
            return []
        }
    }

    /// 保存外设电量列表至文件（包含在线活跃与休眠离线设备）
    public func saveBatteries(_ batteries: [PeripheralBattery]) {
        lock.lock()
        defer { lock.unlock() }

        let activeBatteries = batteries.filter { $0.percentage >= -1 }
        let url = storageFileURL
        let directoryURL = url.deletingLastPathComponent()

        do {
            if !fileManager.fileExists(atPath: directoryURL.path) {
                try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(activeBatteries)
            try data.write(to: url, options: [.atomic])
        } catch {
            print("[BatteryStore] 写入电量数据失败: \(error.localizedDescription)")
        }
    }

    /// 更新或添加单个外设电量
    public func updateOrInsertBattery(_ battery: PeripheralBattery) {
        var list = loadBatteries()
        if let idx = list.firstIndex(where: { $0.id == battery.id }) {
            list[idx] = battery
        } else {
            list.append(battery)
        }
        saveBatteries(list)
    }

    /// 生成用于控制中心副标题的聚合摘要文本，如 "鼠9% · 耳61%" 或 "未连接"
    public func summaryText() -> String {
        let batteries = loadBatteries().filter { $0.percentage >= 0 }
        guard !batteries.isEmpty else {
            return "未连接外设"
        }
        return batteries.map { $0.shortSummary }.joined(separator: " · ")
    }

    /// 聚合多设备分类富徽标，用于控制中心副标题展示，如 "🖱️ 鼠7%   🎧 耳61%"
    public func multiDeviceSummary() -> String {
        let batteries = loadBatteries().filter { $0.percentage >= 0 }
        guard !batteries.isEmpty else {
            return "未连接任何外设"
        }

        // 按分类排序：鼠标 -> 键盘 -> 耳机 -> 其他
        let sorted = batteries.sorted { a, b in
            let order: [PeripheralCategory: Int] = [.mouse: 1, .keyboard: 2, .headset: 3, .other: 4]
            return (order[a.category] ?? 99) < (order[b.category] ?? 99)
        }

        return sorted.map { $0.categorizedSummary }.joined(separator: "   ")
    }
}
