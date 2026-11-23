import Foundation
import IOKit.hid

/// 赛睿（SteelSeries）外设 HID 驱动（涵盖 Aerox/Prime/Rival 鼠标与 Arctis/Arctis Nova 全系列耳机）
public final class SteelSeriesHIDDriver: HIDBatteryDriver {
    public let driverName: String = "SteelSeries HID Driver"
    public let vendorID: Int = 0x1038 // SteelSeries ApS

    public let supportedVendorIDs: [Int] = [0x1038]
    public let supportedProductIDs: [Int] = []

    public init() {}

    public func matches(vendorID: Int, productID: Int) -> Bool {
        return vendorID == self.vendorID
    }

    public func queryBattery(device: IOHIDDevice) -> (percentage: Int, isCharging: Bool)? {
        guard let list = queryBatteries(device: device), let first = list.first else {
            return nil
        }
        return (percentage: first.percentage, isCharging: first.isCharging)
    }

    public func queryBatteries(device: IOHIDDevice) -> [PeripheralBatteryReading]? {
        guard let _ = HIDDeviceHelper.getVendorID(device: device),
              let pid = HIDDeviceHelper.getProductID(device: device) else {
            return nil
        }

        let name = HIDDeviceHelper.getProductName(device: device)
        let isHeadset = isSteelSeriesHeadset(pid: pid, name: name)

        if isHeadset {
            if let result = querySteelSeriesHeadset(device: device, pid: pid, name: name) {
                return [result]
            }
        } else {
            if let result = querySteelSeriesMouse(device: device, pid: pid, name: name) {
                return [result]
            }
        }

        return nil
    }

    // MARK: - 鼠标电量查询

    private func querySteelSeriesMouse(device: IOHIDDevice, pid: Int, name: String) -> PeripheralBatteryReading? {
        let isRival = (pid == 0x1830 || pid == 0x1872 || pid == 0x1726 || pid == 0x172B)
        let isGen2 = (pid == 0x1890 || pid == 0x1892)

        if isRival {
            // Rival 3 / 650 协议: 发送 [0xAA, 0x01]
            var req = [UInt8](repeating: 0, count: 64)
            req[0] = 0xAA
            req[1] = 0x01
            if let resp = sendAndReceive(device: device, request: req, timeoutMs: 200), resp.count >= 3 {
                let level = Int(resp[0])
                let isCharging = (resp[2] != 0)
                if (1...100).contains(level) {
                    return PeripheralBatteryReading(
                        id: "steelseries_\(pid)",
                        name: resolveMouseName(pid: pid, fallback: name),
                        symbolName: "magicmouse.fill",
                        percentage: level,
                        isCharging: isCharging
                    )
                }
            }
        } else {
            // Aerox / Prime 协议: 发送 0xD2 (无线) 或 0x92 (有线)
            var req = [UInt8](repeating: 0, count: 64)
            req[0] = 0xD2
            if let resp = sendAndReceive(device: device, request: req, timeoutMs: 200), resp.count >= 3 {
                if isGen2 {
                    // Gen 2: [cmd, status, level, 0]
                    let status = resp[1]
                    let level = Int(resp[2])
                    let isCharging = (status == 1 || status == 2)
                    if (0...100).contains(level) {
                        return PeripheralBatteryReading(
                            id: "steelseries_\(pid)",
                            name: resolveMouseName(pid: pid, fallback: name),
                            symbolName: "magicmouse.fill",
                            percentage: level,
                            isCharging: isCharging
                        )
                    }
                } else {
                    // Gen 1: level = ((resp[1] & 0x7F) - 1) * 5
                    let b = resp[1]
                    let isCharging = (b & 0x80) != 0
                    let raw = (Int(b & 0x7F) - 1) * 5
                    if (0...100).contains(raw) {
                        return PeripheralBatteryReading(
                            id: "steelseries_\(pid)",
                            name: resolveMouseName(pid: pid, fallback: name),
                            symbolName: "magicmouse.fill",
                            percentage: raw,
                            isCharging: isCharging
                        )
                    }
                }
            }
        }
        return nil
    }

    // MARK: - 耳机电量查询

    private func isSteelSeriesHeadset(pid: Int, name: String) -> Bool {
        let lower = name.lowercased()
        if lower.contains("arctis") || lower.contains("nova") || lower.contains("gamebuds") {
            return true
        }
        let headsetPids: Set<Int> = [
            0x12B3, 0x12B6, 0x12D7, 0x12D5, 0x1260, 0x12AD, 0x1252, 0x1280, 0x12C2, 0x12C4,
            0x1290, 0x12E0, 0x12E5, 0x225D, 0x2244, 0x2246, 0x2249, 0x2270, 0x2290, 0x220E,
            0x2212, 0x2216, 0x2236, 0x2202, 0x22A1, 0x227E, 0x2206, 0x2258, 0x229E, 0x22AD,
            0x223A, 0x22A9, 0x227A, 0x22A4, 0x22A5, 0x220A, 0x22A7, 0x2298, 0x2232, 0x2253,
            0x2269, 0x226D, 0x230A
        ]
        return headsetPids.contains(pid)
    }

    private func querySteelSeriesHeadset(device: IOHIDDevice, pid: Int, name: String) -> PeripheralBatteryReading? {
        // 尝试通用 Arctis 报告 [0x06, 0x18] 或 [0x06, 0x12]
        var req = [UInt8](repeating: 0, count: 64)
        req[0] = 0x06
        req[1] = 0x18

        if let resp = sendAndReceive(device: device, request: req, timeoutMs: 250), resp.count >= 4 {
            let level = Int(resp[2])
            let isCharging = (resp[3] != 0)
            if (1...100).contains(level) {
                return PeripheralBatteryReading(
                    id: "steelseries_\(pid)",
                    name: resolveHeadsetName(pid: pid, fallback: name),
                    symbolName: "headphones",
                    percentage: level,
                    isCharging: isCharging
                )
            }
        }

        // 尝试 Arctis 1 [0x06, 0x12]
        req[1] = 0x12
        if let resp = sendAndReceive(device: device, request: req, timeoutMs: 200), resp.count >= 4 {
            if resp[2] != 0x01 {
                let level = Int(resp[3])
                if (1...100).contains(level) {
                    return PeripheralBatteryReading(
                        id: "steelseries_\(pid)",
                        name: resolveHeadsetName(pid: pid, fallback: name),
                        symbolName: "headphones",
                        percentage: level,
                        isCharging: false
                    )
                }
            }
        }

        // 尝试 Arctis Nova 协议 [0x00, 0xB0]
        var novaReq = [UInt8](repeating: 0, count: 64)
        novaReq[1] = 0xB0
        if let resp = sendAndReceive(device: device, request: novaReq, timeoutMs: 200), resp.count >= 4 {
            let level = Int(resp[3])
            if (1...100).contains(level) {
                return PeripheralBatteryReading(
                    id: "steelseries_\(pid)",
                    name: resolveHeadsetName(pid: pid, fallback: name),
                    symbolName: "headphones",
                    percentage: level,
                    isCharging: resp[2] != 0
                )
            }
        }

        return nil
    }

    // MARK: - 底层收发

    private func sendAndReceive(device: IOHIDDevice, request: [UInt8], timeoutMs: UInt32) -> [UInt8]? {
        final class Resp { var data: [UInt8]? }
        let holder = Resp()
        let context = Unmanaged.passUnretained(holder).toOpaque()

        let bufferSize = 64
        let inBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { inBuffer.deallocate() }

        let callback: IOHIDReportCallback = { context, result, sender, type, rID, report, length in
            guard result == kIOReturnSuccess, let context = context, length > 0 else { return }
            let ref = Unmanaged<Resp>.fromOpaque(context).takeUnretainedValue()
            ref.data = Array(UnsafeBufferPointer(start: report, count: length))
        }

        IOHIDDeviceRegisterInputReportCallback(device, inBuffer, bufferSize, callback, context)
        defer {
            IOHIDDeviceRegisterInputReportCallback(device, inBuffer, bufferSize, nil, nil)
        }

        let reportID = CFIndex(request[0])
        var sent = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, reportID, request, request.count)
        if sent != kIOReturnSuccess {
            sent = IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, reportID, request, request.count)
        }
        guard sent == kIOReturnSuccess else { return nil }

        let stepUs: UInt32 = 10_000
        var waitedUs: UInt32 = 0
        let maxUs = timeoutMs * 1_000

        while waitedUs < maxUs {
            CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.01, false)
            if let data = holder.data { return data }
            usleep(stepUs)
            waitedUs += stepUs
        }
        return nil
    }

    private func resolveMouseName(pid: Int, fallback: String) -> String {
        switch pid {
        case 0x1838, 0x1878, 0x183A, 0x187A: return "SteelSeries Aerox 3 Wireless"
        case 0x1890, 0x1892: return "SteelSeries Aerox 3 Wireless Gen 2"
        case 0x1852, 0x185C, 0x1860, 0x1854, 0x185E, 0x1862: return "SteelSeries Aerox 5 Wireless"
        case 0x1858, 0x1874, 0x185A, 0x1876: return "SteelSeries Aerox 9 Wireless"
        case 0x1840, 0x1842: return "SteelSeries Prime Wireless"
        case 0x1848, 0x184A: return "SteelSeries Prime Mini Wireless"
        case 0x1830: return "SteelSeries Rival 3 Wireless"
        case 0x1872: return "SteelSeries Rival 3 Wireless Gen 2"
        case 0x1726, 0x172B: return "SteelSeries Rival 650 Wireless"
        default: return fallback.isEmpty ? "SteelSeries Mouse" : fallback
        }
    }

    private func resolveHeadsetName(pid: Int, fallback: String) -> String {
        switch pid {
        case 0x12B3, 0x12B6, 0x12D7, 0x12D5: return "SteelSeries Arctis 1 Wireless"
        case 0x1260, 0x12AD, 0x1252, 0x1280: return "SteelSeries Arctis 7 Wireless"
        case 0x12C2, 0x12C4: return "SteelSeries Arctis 9"
        case 0x1290: return "SteelSeries Arctis Pro Wireless"
        case 0x220E, 0x2212, 0x2216, 0x2236: return "SteelSeries Arctis 7+"
        case 0x2232, 0x2253, 0x2269, 0x226D: return "SteelSeries Arctis Nova 5"
        case 0x2202, 0x22A1, 0x227E, 0x2206, 0x2258, 0x229E, 0x22AD, 0x223A, 0x22A9, 0x227A, 0x22A4, 0x22A5, 0x220A, 0x22A7, 0x2298:
            return "SteelSeries Arctis Nova 7"
        case 0x12E0, 0x12E5, 0x225D: return "SteelSeries Arctis Nova Pro Wireless"
        case 0x2244, 0x2246, 0x2249, 0x2270: return "SteelSeries Arctis Nova Elite"
        case 0x230A: return "SteelSeries Arctis GameBuds"
        default: return fallback.isEmpty ? "SteelSeries Headset" : fallback
        }
    }
}
