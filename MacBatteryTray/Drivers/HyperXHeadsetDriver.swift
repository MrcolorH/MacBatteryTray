import Foundation
import IOKit.hid

/// HyperX、美商海盗船（Corsair）及索尼（Sony INZONE）无线耳机统一电量驱动
/// 覆盖：HyperX Cloud Alpha / Cloud II / Cloud III / Cloud Flight / Cloud Stinger,
/// Corsair HS80 RGB / Void / Virtuoso, Sony INZONE Buds / H5 等
public final class HyperXHeadsetDriver: HIDBatteryDriver {
    public let driverName: String = "Universal Wireless Headset Driver"
    public let vendorID: Int = 0x03F0 // HP Inc. (HyperX)

    public let supportedVendorIDs: [Int] = [
        0x03F0, // HP Inc. (HyperX)
        0x0951, // Kingston (HyperX)
        0x1B1C, // Corsair
        0x054C, // Sony (INZONE)
    ]

    public let supportedProductIDs: [Int] = []

    public init() {}

    public func matches(vendorID: Int, productID: Int) -> Bool {
        return supportedVendorIDs.contains(vendorID)
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

        let name = HIDDeviceHelper.getProductName(device: device)

        // 1. HyperX 系列
        if vid == 0x03F0 || vid == 0x0951 {
            if let result = queryHyperX(device: device, vid: vid, pid: pid, name: name) {
                return [result]
            }
        }

        // 2. Corsair 系列 (HS80, Void, Virtuoso)
        if vid == 0x1B1C {
            if let result = queryCorsair(device: device, pid: pid, name: name) {
                return [result]
            }
        }

        // 3. Sony INZONE 系列
        if vid == 0x054C {
            if let result = querySonyInzone(device: device, pid: pid, name: name) {
                return [result]
            }
        }

        return nil
    }

    // MARK: - HyperX 协议实现

    private func queryHyperX(device: IOHIDDevice, vid: Int, pid: Int, name: String) -> PeripheralBatteryReading? {
        // Cloud Alpha Wireless: [0x21, 0xBB, 0x03] (link), [0x21, 0xBB, 0x0C] (charge), [0x21, 0xBB, 0x0B] (level)
        if pid == 0x098D || pid == 0x1743 || pid == 0x1765 {
            var linkReq = [UInt8](repeating: 0, count: 64)
            linkReq[0] = 0x21
            linkReq[1] = 0xBB
            linkReq[2] = 0x03
            guard let linkResp = sendAndReceive(device: device, request: linkReq, timeoutMs: 150),
                  linkResp.count > 3, linkResp[3] != 0x01 else {
                return nil
            }

            var chargeReq = linkReq
            chargeReq[2] = 0x0C
            let isCharging = sendAndReceive(device: device, request: chargeReq, timeoutMs: 100).map { $0.count > 3 && $0[3] == 0x01 } ?? false

            var levelReq = linkReq
            levelReq[2] = 0x0B
            if let levelResp = sendAndReceive(device: device, request: levelReq, timeoutMs: 150), levelResp.count > 3 {
                let level = Int(levelResp[3])
                if (0...100).contains(level) {
                    return PeripheralBatteryReading(
                        id: "hyperx_\(pid)",
                        name: "HyperX Cloud Alpha Wireless",
                        symbolName: "headphones",
                        percentage: level,
                        isCharging: isCharging
                    )
                }
            }
        }

        // Cloud II / Stinger 2 (HP & Kingston)
        if pid == 0x0696 || pid == 0x018B || pid == 0x1718 || pid == 0x0D93 || pid == 0x16EA {
            var req = [UInt8](repeating: 0, count: 52)
            req[0] = 0x06
            req[1] = 0xFF
            req[2] = 0xBB
            req[3] = 0x02
            if let resp = sendAndReceive(device: device, request: req, timeoutMs: 200), resp.count >= 8 {
                let level = Int(resp[7])
                req[3] = 0x03
                let isCharging = sendAndReceive(device: device, request: req, timeoutMs: 100).map { $0.count >= 5 && $0[4] == 0x01 } ?? false
                if (0...100).contains(level) {
                    let dName = (pid == 0x0D93) ? "HyperX Cloud Stinger 2" : "HyperX Cloud II Wireless"
                    return PeripheralBatteryReading(
                        id: "hyperx_\(pid)",
                        name: dName,
                        symbolName: "headphones",
                        percentage: level,
                        isCharging: isCharging
                    )
                }
            }
        }

        // Cloud III / Core: [0x66, 0x82], [0x66, 0x89]
        if pid == 0x05B7 || pid == 0x0C9D || pid == 0x069F || pid == 0x0995 {
            var req = [UInt8](repeating: 0, count: 62)
            req[0] = 0x66
            req[1] = 0x82
            if let link = sendAndReceive(device: device, request: req, timeoutMs: 150), link.count > 2, link[2] == 0x01 {
                req[1] = 0x8A
                let isCharging = sendAndReceive(device: device, request: req, timeoutMs: 100).map { $0.count > 2 && $0[2] == 1 } ?? false
                req[1] = 0x89
                if let resp = sendAndReceive(device: device, request: req, timeoutMs: 150), resp.count > 4 {
                    let level = Int(resp[4])
                    if (0...100).contains(level) {
                        return PeripheralBatteryReading(
                            id: "hyperx_\(pid)",
                            name: "HyperX Cloud III Wireless",
                            symbolName: "headphones",
                            percentage: level,
                            isCharging: isCharging
                        )
                    }
                }
            }
        }

        // Cloud Flight: [0x21, 0xFF, 0x05]
        if pid == 0x16C4 || pid == 0x1723 || pid == 0x1749 || pid == 0x0E90 {
            var req = [UInt8](repeating: 0, count: 20)
            req[0] = 0x21
            req[1] = 0xFF
            req[2] = 0x05
            if let resp = sendAndReceive(device: device, request: req, timeoutMs: 150), resp.count >= 5 {
                let mv = (Int(resp[3]) << 8) | Int(resp[4])
                if mv > 4107 {
                    return PeripheralBatteryReading(id: "hyperx_\(pid)", name: "HyperX Cloud Flight", symbolName: "headphones", percentage: 100, isCharging: true)
                }
                if mv >= 3000 {
                    let pct = min(100, max(0, Int((Double(mv - 3400) / 750.0) * 100.0)))
                    return PeripheralBatteryReading(id: "hyperx_\(pid)", name: "HyperX Cloud Flight", symbolName: "headphones", percentage: pct, isCharging: false)
                }
            }
        }

        return nil
    }

    // MARK: - Corsair 协议实现

    private func queryCorsair(device: IOHIDDevice, pid: Int, name: String) -> PeripheralBatteryReading? {
        // Corsair HS80 RGB / Void / Virtuoso 通用 64 字节 Feature/Output 报告
        var req = [UInt8](repeating: 0, count: 64)
        req[0] = 0x08 // Common Corsair control report ID
        req[1] = 0x01
        req[2] = 0x03

        if let resp = sendAndReceive(device: device, request: req, timeoutMs: 200), resp.count >= 5 {
            let level = Int(resp[2])
            let isCharging = (resp[3] == 1 || resp[3] == 2)
            if (1...100).contains(level) {
                let dName = name.contains("Corsair") ? name : "Corsair \(name)"
                return PeripheralBatteryReading(
                    id: "corsair_\(pid)",
                    name: dName,
                    symbolName: "headphones",
                    percentage: level,
                    isCharging: isCharging
                )
            }
        }
        return nil
    }

    // MARK: - Sony INZONE 协议实现

    private func querySonyInzone(device: IOHIDDevice, pid: Int, name: String) -> PeripheralBatteryReading? {
        // Sony INZONE H5 / Buds: 64 字节 Output 报文
        var req = [UInt8](repeating: 0, count: 64)
        req[0] = 0x00
        req[1] = 0x11
        if let resp = sendAndReceive(device: device, request: req, timeoutMs: 200), resp.count >= 6 {
            let level = Int(resp[3])
            let isCharging = (resp[4] == 1)
            if (1...100).contains(level) {
                return PeripheralBatteryReading(
                    id: "sony_\(pid)",
                    name: name.isEmpty ? "Sony INZONE Headset" : name,
                    symbolName: "headphones",
                    percentage: level,
                    isCharging: isCharging
                )
            }
        }
        return nil
    }

    // MARK: - 底层收发

    private func sendAndReceive(device: IOHIDDevice, request: [UInt8], timeoutMs: UInt32) -> [UInt8]? {
        final class RespHolder { var data: [UInt8]? }
        let holder = RespHolder()
        let context = Unmanaged.passUnretained(holder).toOpaque()

        let bufferSize = 64
        let inBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { inBuffer.deallocate() }

        let callback: IOHIDReportCallback = { context, result, sender, type, rID, report, length in
            guard result == kIOReturnSuccess, let context = context, length > 0 else { return }
            let ref = Unmanaged<RespHolder>.fromOpaque(context).takeUnretainedValue()
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
}
