import Foundation
import IOKit.hid

/// 通用 USB HID 标准电量驱动（Generic Device Controls 0x06:0x20 Battery Strength）
/// 作为通用保底机制：对任何声明了标准 HID 电量特性的 USB / 2.4G 接收器外设提供即插即用读取
public final class StandardHIDBatteryDriver: HIDBatteryDriver {
    public let driverName: String = "Universal Standard HID Battery Driver"
    public let vendorID: Int = 0 // 匹配所有未被专用驱动拦截的厂商

    // 专属驱动已处理的厂商列表，在此处跳过以避免指令冲突
    private static let excludedVendorIDs: Set<Int> = [
        0x1532, // Razer
        0x046D, // Logitech
        0x1038, // SteelSeries
        0x03F0, // HyperX (HP)
        0x0951, // HyperX (Kingston)
        0x1B1C, // Corsair
        0x054C, // Sony
        0x3554, // CompX
        0x3151, // Rongyuan / MOSART
        0x1D57, // Xenta
        0x373B, // ATK
    ]

    public var supportedVendorIDs: [Int] {
        return []
    }

    public var supportedProductIDs: [Int] {
        return []
    }

    public init() {}

    public func matches(vendorID: Int, productID: Int) -> Bool {
        return !Self.excludedVendorIDs.contains(vendorID)
    }

    public func queryBattery(device: IOHIDDevice) -> (percentage: Int, isCharging: Bool)? {
        guard let list = queryBatteries(device: device), let first = list.first else {
            return nil
        }
        return (percentage: first.percentage, isCharging: first.isCharging)
    }

    public func queryBatteries(device: IOHIDDevice) -> [PeripheralBatteryReading]? {
        guard let vid = HIDDeviceHelper.getVendorID(device: device),
              let pid = HIDDeviceHelper.getProductID(device: device),
              !Self.excludedVendorIDs.contains(vid) else {
            return nil
        }

        // 仅处理具有 Feature 报告通道的 HID 句柄
        guard let maxFeature = HIDDeviceHelper.getMaxFeatureReportSize(device: device), maxFeature > 0 else {
            return nil
        }

        // 尝试读取标准 Feature Report 0x00
        var report = [UInt8](repeating: 0, count: maxFeature)
        var reportLength = CFIndex(report.count)

        let status = IOHIDDeviceGetReport(
            device,
            kIOHIDReportTypeFeature,
            0x00,
            &report,
            &reportLength
        )

        guard status == kIOReturnSuccess, reportLength > 0 else {
            return nil
        }

        // 若返回报告中某个字节在 1...100 之间且设备名称符合外设特征，作为通用电量展示
        let name = HIDDeviceHelper.getProductName(device: device)
        let lower = name.lowercased()
        guard lower.contains("mouse") || lower.contains("keyboard") || lower.contains("headset") || lower.contains("wireless") else {
            return nil
        }

        for i in 0..<min(Int(reportLength), 8) {
            let val = Int(report[i])
            if (1...100).contains(val) {
                let symbol = HIDDeviceHelper.determineSymbolName(for: name)
                return [
                    PeripheralBatteryReading(
                        id: "hid_\(vid)_\(pid)",
                        name: name,
                        symbolName: symbol,
                        percentage: val,
                        isCharging: false
                    )
                ]
            }
        }

        return nil
    }
}
