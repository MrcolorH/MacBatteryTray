import Foundation
import IOKit

/// macOS 原生蓝牙外设电量读取器（通过 IORegistry 的 AppleDeviceManagementHIDEventService）
/// 具备：零权限弹窗、无侵入、极低能耗、无音频卡顿/丢包风险
public final class BluetoothHIDBatteryReader: @unchecked Sendable {
    public static let shared = BluetoothHIDBatteryReader()

    /// 针对 Apple 官方及第三方蓝牙键鼠/耳机的系统注册表服务类名
    private static let candidateServiceClasses: [String] = [
        "AppleDeviceManagementHIDEventService",
        "BNBMouseDevice",
        "BNBTrackpadDevice",
        "AppleBluetoothHIDDevice"
    ]

    /// 过滤内置硬件（如 MacBook 自带键盘触控板、光线感应器、Touch Bar 等）
    private static let ignoredKeywords: [String] = [
        "internal keyboard",
        "internal trackpad",
        "apple internal",
        "ambient light sensor",
        "touch bar",
        "dfrminidisplay",
        "touchbar"
    ]

    public init() {}

    /// 读取系统 IORegistry 中所有当前已连接并上报了有效电量的蓝牙外设
    public func readConnectedDevices() -> [PeripheralBattery] {
        var results: [PeripheralBattery] = []
        var seenIDs = Set<String>()

        for className in Self.candidateServiceClasses {
            var iterator: io_iterator_t = 0
            let matchingDict = IOServiceMatching(className)
            let kernResult = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict, &iterator)
            guard kernResult == KERN_SUCCESS else { continue }

            var service = IOIteratorNext(iterator)
            while service != 0 {
                defer {
                    IOObjectRelease(service)
                    service = IOIteratorNext(iterator)
                }

                var props: Unmanaged<CFMutableDictionary>?
                guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                      let dict = props?.takeRetainedValue() as? [String: Any] else {
                    continue
                }

                // 提取设备名称
                guard let name = dict["Product"] as? String ?? dict["Name"] as? String,
                      !name.isEmpty else {
                    continue
                }

                // 过滤 MacBook 内建硬件
                let lowerName = name.lowercased()
                if Self.ignoredKeywords.contains(where: { lowerName.contains($0) }) {
                    continue
                }

                // 提取电量百分比 (0...100)
                guard let batteryPercent = dict["BatteryPercent"] as? Int ?? dict["BatteryPercentage"] as? Int,
                      (0...100).contains(batteryPercent) else {
                    continue
                }

                // 提取充电状态 (BatteryStatusFlags 最低位为 1 表示充电中)
                let statusFlags = dict["BatteryStatusFlags"] as? Int ?? 0
                let isCharging = (statusFlags & 0x01) != 0

                // 提取设备唯一标识
                let address = dict["DeviceAddress"] as? String ?? dict["SerialNumber"] as? String ?? name
                let normalizedID = "bt_" + address
                    .replacingOccurrences(of: ":", with: "")
                    .replacingOccurrences(of: "-", with: "")
                    .lowercased()

                if seenIDs.contains(normalizedID) {
                    continue
                }
                seenIDs.insert(normalizedID)

                let symbol = determineSymbol(for: name)
                let item = PeripheralBattery(
                    id: normalizedID,
                    name: name,
                    symbolName: symbol,
                    percentage: batteryPercent,
                    isCharging: isCharging,
                    transport: .bluetooth,
                    updatedAt: Date()
                )
                results.append(item)
            }
            IOObjectRelease(iterator)
        }

        return results
    }

    /// 根据设备名称推导适合的 SF Symbol 图标
    private func determineSymbol(for name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("mouse") || lower.contains("master") || lower.contains("anywhere") ||
           lower.contains("viper") || lower.contains("deathadder") || lower.contains("g pro") {
            return "magicmouse.fill"
        } else if lower.contains("keyboard") || lower.contains("key") || lower.contains("bt1") || lower.contains("bt2") {
            return "keyboard.fill"
        } else if lower.contains("headset") || lower.contains("headphone") || lower.contains("earphone") ||
                  lower.contains("airpod") || lower.contains("buds") || lower.contains("tws") || lower.contains("xm") {
            return "headphones"
        } else if lower.contains("trackpad") {
            return "hand.tap.fill"
        }
        return "sparkles"
    }
}
