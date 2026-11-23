import Foundation
import IOKit.hid

/// 雷蛇（Razer）2.4G 无线外设 HID 驱动（基于 OpenRazer 90 字节 Feature Report 协议）
public final class RazerHIDDriver: HIDBatteryDriver {
    public let driverName: String = "Razer HID Driver"
    public let vendorID: Int = 0x1532 // Razer Inc.

    /// 内置常见雷蛇 2.4G 接收器与有线/无线双模 PID
    public let supportedProductIDs: [Int] = [
        // MARK: - 鼠标系列 (Mice)
        0x001F, // Naga Epic
        0x0024, 0x0025, // Mamba 2012
        0x0032, // Ouroboros
        0x003E, 0x003F, // Naga Epic Chroma
        0x0044, 0x0045, // Mamba
        0x0059, 0x005A, // Lancehead
        0x0062, // Atheris
        0x006F, 0x0070, // Lancehead Wireless
        0x0072, 0x0073, // Mamba Wireless
        0x0077, 0x0080, // Pro Click
        0x007A, 0x007B, // Viper Ultimate
        0x007C, 0x007D, // DeathAdder V2 Pro
        0x0083, // Basilisk X HyperSpeed
        0x0086, 0x0088, // Basilisk Ultimate
        0x008F, 0x0090, // Naga Pro
        0x0094, 0x0095, // Orochi V2
        0x009A, // Pro Click Mini
        0x009C, // DeathAdder V2 X HyperSpeed
        0x009E, 0x009F, // Viper Mini Signature Edition
        0x00A5, 0x00A6, // Viper V2 Pro
        0x00A7, 0x00A8, // Naga V2 Pro
        0x00AA, 0x00AB, // Basilisk V3 Pro
        0x00AF, 0x00B0, // Cobra Pro
        0x00B2, // Viper V3 HyperSpeed
        0x00B3, // HyperPolling Wireless Dongle
        0x00B4, // Naga V2 HyperSpeed
        0x00B6, 0x00B7, // DeathAdder V3 Pro
        0x00B8, // Viper V3 HyperSpeed
        0x00B9, // Basilisk V3 X HyperSpeed
        0x00BA, // DeathAdder V3 HyperSpeed
        0x00BE, 0x00BF, // DeathAdder V4 Pro
        0x00C0, 0x00C1, // Viper V3 Pro
        0x00C2, 0x00C3, // DeathAdder V3 Pro
        0x00C4, 0x00C5, // DeathAdder V3 HyperSpeed
        0x00C7, 0x00C8, // Pro Click V2 Vertical
        0x00CC, 0x00CD, // Basilisk V3 Pro 35K
        0x00D0, 0x00D1, // Pro Click V2
        0x00D3, 0x00D4, // Basilisk Mobile
        0x00D6, 0x00D7, // Basilisk V3 Pro 35K Phantom Green
        0x00DA, 0x00DB, // Cobra HyperSpeed
        0x00DE, 0x00DF, // Viper V3 Pro SE
        0x00E0, // Orochi V2
        0x00E2, 0x00E3, // Basilisk V4 Pro
        0x00E5, 0x00E6, // Viper V4 Pro
        0x00E7, 0x00E8, // Naga V3 Pro
        0x00EA, 0x00EB, // Basilisk V4 HyperSpeed
        0x00EF, 0x00F0, // DeathAdder V4 Pro
        0x00A3, // Mouse Dock Pro

        // MARK: - 键盘系列 (Keyboards)
        0x0258, 0x0271, // BlackWidow V3 Mini HyperSpeed
        0x025A, 0x025C, // BlackWidow V3 Pro
        0x0292, 0x0290, // DeathStalker V2 Pro
        0x0298, 0x0296, // DeathStalker V2 Pro TKL
        0x02B9, 0x02BA, // BlackWidow V4 Mini HyperSpeed
        0x02D7, 0x02D5, // BlackWidow V4 TKL HyperSpeed
        0x02CD, // Joro
        0x02CC, 0x02C9, // BlackWidow V4 Low-Profile HyperSpeed
        0x02D4, 0x02D2, // BlackWidow V4 Low-Profile TKL HyperSpeed
        0x0277, 0x027B, // Pro Type Ultra
        0x02C4, 0x02C2, // Pro Type Ergo
        0x00BC, // Huntsman V3 Pro Mini
    ]

    public init() {}

    /// 查询雷蛇设备电量及充电状态
    public func queryBattery(device: IOHIDDevice) -> (percentage: Int, isCharging: Bool)? {
        // 雷蛇复合设备暴露多个 HID 句柄（鼠标、键盘宏、配置通道等），仅 MaxFeatureReportSize >= 90 的通道支持 OpenRazer 报文
        if let maxFeature = HIDDeviceHelper.getIntProperty(device: device, key: kIOHIDMaxFeatureReportSizeKey), maxFeature < 90 {
            return nil
        }

        // 1. 发送查询电量报告（Command Class 0x07, Command ID 0x80）
        guard let batteryReport = sendRazerReport(device: device, commandClass: 0x07, commandID: 0x80) else {
            return nil
        }

        let statusByte = batteryReport[0]
        // OpenRazer 状态码:
        // 0x02 = 成功 (RAZER_STATUS_SUCCESS)
        // 0x04 = 超时 (RAZER_STATUS_TIMEOUT，无线鼠标进入休眠或断连)
        // 0x03 = 失败 (RAZER_STATUS_FAILURE)
        if statusByte == 0x04 || statusByte == 0x03 {
            // 接收器在线，但无线外设已休眠/关机
            return (percentage: -1, isCharging: false)
        }

        // OpenRazer 协议中，电量存放在 arguments[1]（即全包索引 9）
        // 取值范围 0x00 ~ 0xFF (0 ~ 255)
        let rawLevel = batteryReport[9]
        let percentage: Int
        if rawLevel == 0 && batteryReport[8] > 0 {
            // 部分固件备选存放在 arguments[0]（索引 8）
            percentage = min(100, max(0, Int((Double(batteryReport[8]) / 255.0) * 100.0)))
        } else {
            percentage = min(100, max(0, Int((Double(rawLevel) / 255.0) * 100.0)))
        }

        // 2. 发送查询充电状态报告（Command Class 0x07, Command ID 0x84）
        var isCharging = false
        if let chargingReport = sendRazerReport(device: device, commandClass: 0x07, commandID: 0x84) {
            // arguments[1] 非 0 表示正在充电
            isCharging = (chargingReport[9] != 0 || chargingReport[8] != 0)
        }

        return (percentage: percentage, isCharging: isCharging)
    }

    /// 发送标准的 90 字节 OpenRazer Feature Report 并读取返回结果
    private func sendRazerReport(device: IOHIDDevice, commandClass: UInt8, commandID: UInt8) -> [UInt8]? {
        var report = [UInt8](repeating: 0, count: 90)
        report[0] = 0x00 // Status: New
        report[1] = 0x1F // Transaction ID (标准魔数)
        report[2] = 0x00 // Remaining Packets MSB
        report[3] = 0x00 // Remaining Packets LSB
        report[4] = 0x00 // Protocol Type
        report[5] = 0x02 // Data Size (参数长度)
        report[6] = commandClass // Command Class (0x07: Power/Battery)
        report[7] = commandID    // Command ID (0x80: Battery, 0x84: Charging)
        // report[8...87] 为 80 字节 arguments 参数，默认为 0

        // 第 88 字节为校验和（XOR 校验索引 2..<88）
        var checksum: UInt8 = 0
        for i in 2..<88 {
            checksum ^= report[i]
        }
        report[88] = checksum
        report[89] = 0x00 // Reserved

        // 发送 Feature Report (Report ID = 0x00)
        let setStatus = IOHIDDeviceSetReport(
            device,
            kIOHIDReportTypeFeature,
            0x00,
            report,
            report.count
        )

        guard setStatus == kIOReturnSuccess else {
            return nil
        }

        // 雷蛇外设响应需延时 30ms 确保 MCU 处理完成
        usleep(30_000)

        // 读取 Feature Report 响应
        var response = [UInt8](repeating: 0, count: 90)
        var responseLength = CFIndex(response.count)
        let getStatus = IOHIDDeviceGetReport(
            device,
            kIOHIDReportTypeFeature,
            0x00,
            &response,
            &responseLength
        )

        guard getStatus == kIOReturnSuccess && responseLength >= 90 else {
            return nil
        }

        return response
    }
}
