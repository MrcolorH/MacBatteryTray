import Foundation
import IOKit.hid

/// 单个外设电量读取结果（支持复合接收器下挂载的多个外设）
public struct PeripheralBatteryReading: Sendable {
    public var id: String
    public var name: String
    public var symbolName: String
    public var percentage: Int // 0~100，-1 表示离线/休眠
    public var isCharging: Bool

    public init(id: String, name: String, symbolName: String, percentage: Int, isCharging: Bool) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.percentage = percentage
        self.isCharging = isCharging
    }
}

/// 统一的外设 HID 电量采集驱动协议
public protocol HIDBatteryDriver: AnyObject {
    /// 驱动显示名称
    var driverName: String { get }
    /// 设备主厂商 Vendor ID
    var vendorID: Int { get }
    /// 支持的所有厂商 Vendor ID 列表（默认为 [vendorID]）
    var supportedVendorIDs: [Int] { get }
    /// 支持的产品 Product ID 列表（为空表示支持该厂商下所有符合协议的设备）
    var supportedProductIDs: [Int] { get }

    /// 检查指定 VID / PID 是否与当前驱动匹配
    func matches(vendorID: Int, productID: Int) -> Bool

    /// 查询设备当前电量（单设备简化接口）
    /// - Parameter device: 原生 IOHIDDevice 句柄
    /// - Returns: (percentage: 0~100 或 -1 表示离线/休眠, isCharging: Bool)，读取失败返回 nil
    func queryBattery(device: IOHIDDevice) -> (percentage: Int, isCharging: Bool)?

    /// 查询该 HID 句柄下的所有设备电量（支持多通道/多槽位接收器如罗技 Unifying/Lightspeed 或荣渊多模接收器）
    /// - Parameter device: 原生 IOHIDDevice 句柄
    /// - Returns: 外设电量列表，读取失败或无匹配设备时返回 nil
    func queryBatteries(device: IOHIDDevice) -> [PeripheralBatteryReading]?
}

public extension HIDBatteryDriver {
    var supportedVendorIDs: [Int] {
        return [vendorID]
    }

    var supportedProductIDs: [Int] {
        return []
    }

    func matches(vendorID: Int, productID: Int) -> Bool {
        return supportedVendorIDs.contains(vendorID) && (supportedProductIDs.isEmpty || supportedProductIDs.contains(productID))
    }

    func queryBattery(device: IOHIDDevice) -> (percentage: Int, isCharging: Bool)? {
        return nil
    }

    func queryBatteries(device: IOHIDDevice) -> [PeripheralBatteryReading]? {
        if let (percentage, isCharging) = queryBattery(device: device) {
            let vid = HIDDeviceHelper.getVendorID(device: device) ?? vendorID
            let pid = HIDDeviceHelper.getProductID(device: device) ?? 0
            let name = HIDDeviceHelper.getProductName(device: device)
            let deviceID = "\(vid)_\(pid)"
            let symbolName = HIDDeviceHelper.determineSymbolName(for: name)
            return [PeripheralBatteryReading(id: deviceID, name: name, symbolName: symbolName, percentage: percentage, isCharging: isCharging)]
        }
        return nil
    }
}

/// HID 设备通用属性读取辅助工具
public enum HIDDeviceHelper {
    public static func getIntProperty(device: IOHIDDevice, key: String) -> Int? {
        guard let prop = IOHIDDeviceGetProperty(device, key as CFString) else { return nil }
        if CFGetTypeID(prop) == CFNumberGetTypeID() {
            var value: Int = 0
            CFNumberGetValue((prop as! CFNumber), .sInt64Type, &value)
            return value
        }
        return nil
    }

    public static func getStringProperty(device: IOHIDDevice, key: String) -> String? {
        guard let prop = IOHIDDeviceGetProperty(device, key as CFString) else { return nil }
        if CFGetTypeID(prop) == CFStringGetTypeID() {
            return prop as? String
        }
        return nil
    }

    public static func getVendorID(device: IOHIDDevice) -> Int? {
        return getIntProperty(device: device, key: kIOHIDVendorIDKey)
    }

    public static func getProductID(device: IOHIDDevice) -> Int? {
        return getIntProperty(device: device, key: kIOHIDProductIDKey)
    }

    public static func getProductName(device: IOHIDDevice) -> String {
        return getStringProperty(device: device, key: kIOHIDProductKey) ?? "Unknown Peripheral"
    }

    public static func getSerialNumber(device: IOHIDDevice) -> String? {
        return getStringProperty(device: device, key: kIOHIDSerialNumberKey)
    }

    public static func getPrimaryUsagePage(device: IOHIDDevice) -> Int? {
        return getIntProperty(device: device, key: kIOHIDPrimaryUsagePageKey)
    }

    public static func getPrimaryUsage(device: IOHIDDevice) -> Int? {
        return getIntProperty(device: device, key: kIOHIDPrimaryUsageKey)
    }

    public static func getMaxFeatureReportSize(device: IOHIDDevice) -> Int? {
        return getIntProperty(device: device, key: kIOHIDMaxFeatureReportSizeKey)
    }

    public static func getMaxInputReportSize(device: IOHIDDevice) -> Int? {
        return getIntProperty(device: device, key: kIOHIDMaxInputReportSizeKey)
    }

    public static func getMaxOutputReportSize(device: IOHIDDevice) -> Int? {
        return getIntProperty(device: device, key: kIOHIDMaxOutputReportSizeKey)
    }

    public static func determineSymbolName(for deviceName: String) -> String {
        let lower = deviceName.lowercased()
        if lower.contains("barracuda") || lower.contains("blackshark") || lower.contains("kraken") ||
            lower.contains("nari") || lower.contains("headset") || lower.contains("headphone") ||
            lower.contains("audio") || lower.contains("arctis") || lower.contains("cloud") ||
            lower.contains("flight") || lower.contains("void") || lower.contains("hs70") ||
            lower.contains("hs80") || lower.contains("virtuoso") || lower.contains("inzone") ||
            lower.contains("astro") {
            return "headphones"
        } else if lower.contains("mouse") || lower.contains("viper") || lower.contains("deathadder") ||
                    lower.contains("basilisk") || lower.contains("cobra") || lower.contains("naga") ||
                    lower.contains("aerox") || lower.contains("prime") || lower.contains("rival") ||
                    lower.contains("dragonfly") || lower.contains("r1") || lower.contains("pulsar") ||
                    lower.contains("lamzu") || lower.contains("scyrox") || lower.contains("kysona") ||
                    lower.contains("furycube") || lower.contains("delux") || lower.contains("inphic") ||
                    lower.contains("sabre") || lower.contains("superlight") || lower.contains("g pro") ||
                    lower.contains("g304") || lower.contains("g305") || lower.contains("g502") ||
                    lower.contains("g703") || lower.contains("g903") || lower.contains("mx master") ||
                    lower.contains("mx anywhere") {
            return "magicmouse.fill"
        } else if lower.contains("keyboard") || lower.contains("key") || lower.contains("blackwidow") ||
                    lower.contains("huntsman") || lower.contains("deathstalker") || lower.contains("mx keys") ||
                    lower.contains("craft") || lower.contains("f87") || lower.contains("f99") ||
                    lower.contains("ak820") || lower.contains("x85") || lower.contains("x87") ||
                    lower.contains("g913") || lower.contains("g915") || lower.contains("azoth") ||
                    lower.contains("falchion") {
            return "keyboard.fill"
        }
        return "antenna.radiowaves.left.and.right"
    }
}

