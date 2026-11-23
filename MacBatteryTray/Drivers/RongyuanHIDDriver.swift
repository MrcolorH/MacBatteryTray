import Foundation
import IOKit.hid

/// 荣渊（Rongyuan / RY）方案 2.4G 接收器多模电量驱动（适配艾石头 IROK、Attack Shark、Akko、MonsGeek 等）
/// 协议基于 qu1ncky/BatteryTray (rongyuan.rs) 并结合 macOS IOKit (reportID=0 无前导字节) 与实机 WebHID 抓包校准：
/// - SendFeature(id=0): [0xF7, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x08, 0x00...]
/// - GetFeature(id=0):  [canRead, kbBattery, mouseBattery, kbOffline, mouseOffline, canSend, ...]
public final class RongyuanHIDDriver: HIDBatteryDriver {
    public let driverName: String = "Rongyuan 2.4G Driver"
    public let vendorID: Int = 0x3151 // MOSART Semiconductor

    public let supportedVendorIDs: [Int] = [
        0x3151, // MOSART / IROK / Attack Shark
        0x0DB0, // Micro-Star
        0x145F, // Trust
        0x14A5, // Courant
        0x25AA, // OEM
        0x342D, // YiChip
        0x347A, // OEM
        0x374A, // OEM
        0x379A, // OEM
        0x38A9, // OEM
        0x38EE, // OEM
        0x391D, // OEM
        0x39AB, // OEM
        0x258A, // SinoWealth OEM
    ]

    /// 88 种荣渊官方 Web 驱动所支持的 2.4G 接收器组合键 (VID << 16 | PID)
    private static let receiverKeys: Set<UInt32> = [
        0x0DB0197E, 0x0DB08E9A, 0x145F0376, 0x145F038D, 0x14A5C045, 0x25AA2008, 0x25AA4008, 0x25AA4018, 0x31514011,
        0x31514014, 0x31514017, 0x31514021, 0x31514027, 0x3151402D, 0x31514038, 0x31515006, 0x31515007, 0x31515008,
        0x31515020, 0x31515026, 0x3151502B, 0x31515031, 0x31515037, 0x31515038, 0x3151503D, 0x3151503F, 0x31515040,
        0x31515042, 0x31515045, 0x3151504B, 0x3151504E, 0x31515050, 0x31515052, 0x31515055, 0x3151505A, 0x342DE3E0,
        0x342DE3E1, 0x342DE3E2, 0x342DE3E6, 0x342DE3E7, 0x342DE3E8, 0x342DE3F5, 0x342DE3F6, 0x342DE3F7, 0x342DE3FB,
        0x342DE3FC, 0x342DE3FD, 0x347AA302, 0x347AA305, 0x374AA205, 0x374AA217, 0x374AA220, 0x374AA223, 0x374AA226,
        0x374AA229, 0x374AA234, 0x374AA237, 0x374AA251, 0x374AA263, 0x374AA268, 0x374AA311, 0x374AA314, 0x374AA319,
        0x374AA322, 0x374AA329, 0x374AA355, 0x379A1804, 0x379A1807, 0x38A90002, 0x38EE0000, 0x38EE0002, 0x38EE0039,
        0x391D1A04, 0x391D1A08, 0x391D1A0E, 0x391D1A13, 0x391D1A25, 0x391D1A2B, 0x391D1A34, 0x391D2017, 0x391D2A05,
        0x39AB7000, 0x39AB7003, 0x39AB7006, 0x39AB7007, 0x39AB7008, 0x39AB7009, 0x38EE0004
    ]

    public let supportedProductIDs: [Int] = []

    public init() {}

    public func matches(vendorID: Int, productID: Int) -> Bool {
        let key = (UInt32(vendorID) << 16) | UInt32(productID)
        return Self.receiverKeys.contains(key)
    }

    public func queryBattery(device: IOHIDDevice) -> (percentage: Int, isCharging: Bool)? {
        guard let list = queryBatteries(device: device), let first = list.first else {
            return nil
        }
        return (percentage: first.percentage, isCharging: first.isCharging)
    }

    public func queryBatteries(device: IOHIDDevice) -> [PeripheralBatteryReading]? {
        guard let vid = HIDDeviceHelper.getVendorID(device: device),
              let pid = HIDDeviceHelper.getProductID(device: device) else {
            return nil
        }

        // 严格匹配 UsagePage == 0xFFFF, Usage == 2, Feature 报告长度 >= 7
        let usagePage = HIDDeviceHelper.getPrimaryUsagePage(device: device) ?? 0
        let usage = HIDDeviceHelper.getPrimaryUsage(device: device) ?? 0
        let maxFeature = HIDDeviceHelper.getMaxFeatureReportSize(device: device) ?? 0
        guard usagePage == 0xFFFF, usage == 2, maxFeature >= 7 else {
            return nil
        }

        let reportLen = max(64, maxFeature)
        var validResponse: [UInt8]?

        // macOS IOKit 在 reportID == 0 时不带前导 ReportID 字节：
        // 实机抓包：[0xF7, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x08, 0x00...]
        for attempt in 0..<3 {
            if attempt > 0 {
                usleep(100_000)
            }

            var command = [UInt8](repeating: 0, count: reportLen)
            command[0] = 0xF7
            command[7] = 0x08 // 0xFF - 0xF7 校验字节（与艾石头网页驱动实测抓包一致）

            let setStatus = IOHIDDeviceSetReport(
                device,
                kIOHIDReportTypeFeature,
                0x00,
                command,
                command.count
            )

            guard setStatus == kIOReturnSuccess else {
                return nil
            }

            usleep(25_000)

            var response = [UInt8](repeating: 0, count: reportLen)
            var responseLength = CFIndex(response.count)
            let getStatus = IOHIDDeviceGetReport(
                device,
                kIOHIDReportTypeFeature,
                0x00,
                &response,
                &responseLength
            )

            if getStatus == kIOReturnSuccess,
               responseLength >= 6,
               (response[1] | response[2] | response[3] | response[4] | response[5]) != 0 {
                validResponse = response
                break
            }
        }

        guard let response = validResponse else {
            return nil
        }

        // macOS IOKit (reportID=0 无前导 0x00 字节) 响应结构：
        // response[0] = canRead / status
        // response[1] = 键盘电量 (0~100，例如 0x23 = 35%)
        // response[2] = 鼠标电量 (0~100)
        // response[3] = 键盘离线标志 (0 = 在线，非 0 = 离线/休眠)
        // response[4] = 鼠标离线标志 (0 = 在线，非 0 = 离线/休眠)
        // response[5] = canSend
        let kbBattery = Int(response[1])
        let mouseBattery = Int(response[2])
        let kbOnline = (response[3] == 0 && (1...100).contains(kbBattery))
        let mouseOnline = (response[4] == 0 && (1...100).contains(mouseBattery))

        var readings: [PeripheralBatteryReading] = []
        let baseName = HIDDeviceHelper.getProductName(device: device)

        if kbOnline {
            let kbName = baseName.lowercased().contains("keyboard") ? baseName : "\(baseName) Keyboard"
            readings.append(
                PeripheralBatteryReading(
                    id: "ry_\(vid)_\(pid)_kb",
                    name: kbName,
                    symbolName: "keyboard.fill",
                    percentage: kbBattery,
                    isCharging: false
                )
            )
        }

        if mouseOnline {
            let mouseName = baseName.lowercased().contains("mouse") ? baseName : "\(baseName) Mouse"
            readings.append(
                PeripheralBatteryReading(
                    id: "ry_\(vid)_\(pid)_mouse",
                    name: mouseName,
                    symbolName: "magicmouse.fill",
                    percentage: mouseBattery,
                    isCharging: false
                )
            )
        }

        if readings.isEmpty {
            let defaultSymbol = HIDDeviceHelper.determineSymbolName(for: baseName)
            readings.append(
                PeripheralBatteryReading(
                    id: "ry_\(vid)_\(pid)",
                    name: baseName,
                    symbolName: defaultSymbol,
                    percentage: -1,
                    isCharging: false
                )
            )
        }

        return readings
    }
}
