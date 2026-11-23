import Foundation
import IOKit.hid

/// 现代国产与海外高阶轻量化鼠标 CompX 17 字节协议统一驱动
/// 覆盖品牌：VXE/VGN (蜻蜓 R1 / F1 / F2), ATK (烈空 F1/X1/A9), Pulsar (X2/Xlite),
/// Lamzu (Atlantis/Thorn/Maya), Scyrox (V8/V6), Kysona, G-Wolves, Corsair (Sabre v2 Pro),
/// Dareu (达尔优 A950/EM901X), Endgame Gear (XM2we/OP1we), Redragon, Hitscan, Areson 等
public final class CompXHIDDriver: HIDBatteryDriver {
    public let driverName: String = "CompX OEM Mouse Driver"
    public let vendorID: Int = 0x3554 // CompX 主控厂商 ID

    public let supportedVendorIDs: [Int] = [
        0x3554, // CompX
        0x373B, // ATK
        0x3710, // Pulsar (CrazyLight)
        0x33E4, // G-Wolves
        0x260D, // Dareu
        0x35BB, // Hecate
        0x046A, // Cherry Xtrfy
        0x3770, // Hitscan
        0x1B1C, // Corsair (Sabre v2 Pro)
        0x3367, // Endgame Gear
        0x25A7, // Areson (Redragon, Ardor)
        0x248A, // OEM 常见接收器方案
        0x2F24, // 常见客制化鼠标方案
    ]

    public let supportedProductIDs: [Int] = [] // 匹配上述厂商下所有支持 17 字节协议的设备

    public init() {}

    public func matches(vendorID: Int, productID: Int) -> Bool {
        return supportedVendorIDs.contains(vendorID)
    }

    public func queryBattery(device: IOHIDDevice) -> (percentage: Int, isCharging: Bool)? {
        guard let readings = queryBatteries(device: device), let first = readings.first else {
            return nil
        }
        return (percentage: first.percentage, isCharging: first.isCharging)
    }

    public func queryBatteries(device: IOHIDDevice) -> [PeripheralBatteryReading]? {
        guard let vid = HIDDeviceHelper.getVendorID(device: device),
              let pid = HIDDeviceHelper.getProductID(device: device) else {
            return nil
        }

        // 1. 构建 17 字节 GetPower 请求帧 (Command 0x04)
        // [0x08, 0x04, 0, ..., 0, Checksum]
        let powerReq = makeFrame(reportID: 0x08, command: 0x04)

        // 发送并接收 17 字节响应
        guard let response = sendAndReceiveCompXFrame(device: device, request: powerReq, timeoutMs: 250) else {
            return nil
        }

        // 校验 17 字节报文完整性与 Checksum (所有 17 字节求和 mod 256 == 0x55)
        guard isValidCompXReply(frame: response, expectedCommand: 0x04) else {
            return nil
        }

        guard response[2] == 0x00, response[5] >= 1 else {
            return nil
        }

        let isAreson10Step = (vid == 0x25A7 && (pid == 0xFA4A || pid == 0xFA07 || pid == 0xFA08))
        let step = isAreson10Step ? 10 : 1
        let rawLevel = Int(response[6]) * step
        let isCharging = response[5] >= 2 && response[7] != 0

        // 电量为 0 且未在充电表示设备离线/休眠
        if rawLevel > 100 || (rawLevel == 0 && !isCharging) {
            return nil
        }

        let percentage = min(100, max(0, rawLevel))
        let modelName = resolveModelName(vid: vid, pid: pid, fallbackProduct: HIDDeviceHelper.getProductName(device: device))
        let deviceID = "compx_\(vid)_\(pid)"

        return [
            PeripheralBatteryReading(
                id: deviceID,
                name: modelName,
                symbolName: "magicmouse.fill",
                percentage: percentage,
                isCharging: isCharging
            )
        ]
    }

    // MARK: - 报文封装与校验

    private func makeFrame(reportID: UInt8, command: UInt8) -> [UInt8] {
        var frame = [UInt8](repeating: 0, count: 17)
        frame[0] = reportID
        frame[1] = command
        var sum: UInt32 = 0
        for i in 0..<16 {
            sum += UInt32(frame[i])
        }
        // 校验和使得前 16 字节之和与第 17 字节累加为 0x55
        frame[16] = UInt8((0x55 - (sum & 0xFF)) & 0xFF)
        return frame
    }

    private func isValidCompXReply(frame: [UInt8], expectedCommand: UInt8) -> Bool {
        guard frame.count >= 17, frame[1] == expectedCommand else { return false }
        var sum: UInt32 = 0
        for i in 0..<17 {
            sum += UInt32(frame[i])
        }
        return (sum & 0xFF) == 0x55
    }

    // MARK: - 底层通信实现

    private func sendAndReceiveCompXFrame(device: IOHIDDevice, request: [UInt8], timeoutMs: UInt32) -> [UInt8]? {
        final class ResponseHolder {
            var data: [UInt8]?
        }
        let holder = ResponseHolder()
        let context = Unmanaged.passUnretained(holder).toOpaque()

        let bufferSize = 64
        let inBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { inBuffer.deallocate() }

        let callback: IOHIDReportCallback = { context, result, sender, type, rID, report, length in
            guard result == kIOReturnSuccess, let context = context, length >= 17 else { return }
            let ref = Unmanaged<ResponseHolder>.fromOpaque(context).takeUnretainedValue()
            let packet = Array(UnsafeBufferPointer(start: report, count: length))
            // 匹配 Report ID 0x08 或 0x09
            if packet[0] == 0x08 || packet[0] == 0x09 {
                ref.data = packet
            }
        }

        IOHIDDeviceRegisterInputReportCallback(device, inBuffer, bufferSize, callback, context)
        defer {
            IOHIDDeviceRegisterInputReportCallback(device, inBuffer, bufferSize, nil, nil)
        }

        // 发送 Output Report 0x08
        var sent = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0x08, request, request.count)
        if sent != kIOReturnSuccess {
            // 备用 Feature Report
            sent = IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 0x08, request, request.count)
        }

        guard sent == kIOReturnSuccess else {
            return nil
        }

        // 轮询等待接收
        let stepUs: UInt32 = 10_000
        var waitedUs: UInt32 = 0
        let maxUs = timeoutMs * 1_000

        while waitedUs < maxUs {
            CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.01, false)
            if let resp = holder.data {
                return resp
            }
            usleep(stepUs)
            waitedUs += stepUs
        }

        return nil
    }

    // MARK: - 型号名称映射表

    private func resolveModelName(vid: Int, pid: Int, fallbackProduct: String) -> String {
        switch (vid, pid) {
        case (0x3554, 0xF58A), (0x3554, 0xF58C), (0x373B, 0x1272): return "VXE R1 PRO / PRO MAX"
        case (0x373B, 0x1085), (0x3554, 0xF58E), (0x3554, 0xF58F): return "VXE R1 SE / SE+"
        case (0x3554, 0xF505), (0x3554, 0xF506): return "VGN Dragonfly R1"
        case (0x3554, 0xFB56), (0x3554, 0xFB57): return "VGN Dragonfly F2"
        case (0x373B, 0x11FE): return "ATK A9 Ultra Max 2.0"
        case (0x373B, 0x1017): return "ATK X1 Pro Max"
        case (0x373B, 0x1115): return "ATK A9 Plus"
        case (0x373B, 0x11E4): return "ATK F1 Ultimate"
        case (0x373B, 0x128E): return "ATK A9 Mini+"
        case (0x3554, 0xF50D), (0x3554, 0xF510), (0x3554, 0xF50F): return "Lamzu Atlantis / Thorn"
        case (0x3554, 0xF517), (0x3554, 0xF515): return "Scyrox V8S"
        case (0x3554, 0xF5F7), (0x3554, 0xF5F6): return "Scyrox V8 / V6"
        case (0x3554, 0xF508), (0x3554, 0xF509), (0x3554, 0xF507): return "Pulsar X2 V2"
        case (0x3710, 0x5406): return "Pulsar CrazyLight"
        case (0x3554, 0xF57C), (0x3554, 0xF57D): return "Kysona M600"
        case (0x33E4, 0x3854), (0x33E4, 0x5618): return "G-Wolves HTX Ultra"
        case (0x260D, 0x1154), (0x260D, 0x1196): return "Dareu A950 Wing"
        case (0x260D, 0x1074), (0x260D, 0x1090): return "Dareu EM901X / A950"
        case (0x35BB, 0xD3FB): return "HECATE G5M PRO"
        case (0x3770, 0x0200), (0x3770, 0x0300), (0x3770, 0x0100): return "Hitscan Hyperlight"
        case (0x1B1C, 0x2B2A), (0x1B1C, 0x2B28): return "Corsair Sabre v2 Pro Ultralight"
        case (0x1B1C, 0x2B34), (0x1B1C, 0x2B29): return "Corsair Sabre v2 Pro MG"
        case (0x1B1C, 0x2B35), (0x1B1C, 0x2B25): return "Corsair Sabre v2 Pro CF"
        case (0x3367, 0x1961), (0x3367, 0x1960): return "Endgame Gear XM2we / OP1we"
        case (0x25A7, 0xFA4A): return "Ardor Renegade"
        case (0x25A7, 0xFA7C), (0x25A7, 0xFA7B): return "Areson Wireless Mouse"
        default:
            return fallbackProduct.isEmpty ? "Wireless Gaming Mouse" : fallbackProduct
        }
    }
}
