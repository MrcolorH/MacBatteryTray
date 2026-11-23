import Foundation
import IOKit.hid

/// 罗技（Logitech）HID++ 2.0 / 1.0 全系列外设电量驱动
/// 支持：Lightspeed / Bolt / Unifying / Nano 接收器（Slots 1~6）及 USB 直连（0xFF / 0x00）
/// 涵盖 G 系列鼠标（GPX, G502 等）、键盘（G913/G915, MX Keys 等）、耳机（G533, G733, G PRO X 2 等）及 MX 办公系列
public final class LogitechHIDDriver: HIDBatteryDriver {
    public let driverName: String = "Logitech HID++ Driver"
    public let vendorID: Int = 0x046D // Logitech Inc.

    public let supportedVendorIDs: [Int] = [0x046D]
    // 支持所有罗技外设（忽略摄像头 0x0800~0x09FF）
    public let supportedProductIDs: [Int] = []

    private let softwareID: UInt8 = 0x0C // 用于区分请求与响应的 Software ID
    private let featureName: UInt16 = 0x0005
    private let batteryFeatures: [UInt16] = [0x1004, 0x1000, 0x1001, 0x1F20]

    public init() {}

    public func matches(vendorID: Int, productID: Int) -> Bool {
        guard vendorID == self.vendorID else { return false }
        // 排除罗技网络摄像头（避免握手时设备挂起）
        if (0x0800...0x09FF).contains(productID) {
            return false
        }
        return true
    }

    /// 查询罗技设备/接收器下的所有外设电量
    public func queryBatteries(device: IOHIDDevice) -> [PeripheralBatteryReading]? {
        guard let pid = HIDDeviceHelper.getProductID(device: device) else { return nil }

        // 接收器 PID 范围通常为 0xC500...0xC5FF
        let isReceiver = (0xC500...0xC5FF).contains(pid)
        let slotIndices: [UInt8] = isReceiver ? [1, 2, 3, 4, 5, 6] : [0xFF, 0x00]

        var results: [PeripheralBatteryReading] = []

        for devIndex in slotIndices {
            guard let reading = querySlot(device: device, devIndex: devIndex, isReceiver: isReceiver, pid: pid) else {
                continue
            }
            results.append(reading)
        }

        return results.isEmpty ? nil : results
    }

    /// 单槽位查询
    private func querySlot(device: IOHIDDevice, devIndex: UInt8, isReceiver: Bool, pid: Int) -> PeripheralBatteryReading? {
        // 1. 发送 Ping 确认槽位状态与协议版本
        guard let pingResult = pingSlot(device: device, devIndex: devIndex) else {
            return nil
        }

        let isHidpp20: Bool
        switch pingResult {
        case .hidpp20:
            isHidpp20 = true
        case .hidpp10:
            isHidpp20 = false
        case .offline, .empty:
            return nil
        }

        var deviceName = "Logitech Device"
        var deviceKind = "mouse"

        if isHidpp20 {
            // 获取外设真实型号与类型 (Feature 0x0005)
            if let (name, kind) = fetchDeviceMetadata(device: device, devIndex: devIndex) {
                deviceName = name
                deviceKind = kind
            }
        } else {
            deviceName = HIDDeviceHelper.getProductName(device: device)
        }

        let deviceID = "logitech_\(pid)_\(devIndex)"
        let symbolName: String
        switch deviceKind {
        case "keyboard": symbolName = "keyboard.fill"
        case "headset": symbolName = "headphones"
        default: symbolName = "magicmouse.fill"
        }

        // 2. 读取电量
        if isHidpp20 {
            if let battery = readHIDPP20Battery(device: device, devIndex: devIndex) {
                return PeripheralBatteryReading(
                    id: deviceID,
                    name: deviceName,
                    symbolName: symbolName,
                    percentage: battery.percentage,
                    isCharging: battery.isCharging
                )
            }
        } else {
            if let battery = readHIDPP10Battery(device: device, devIndex: devIndex) {
                return PeripheralBatteryReading(
                    id: deviceID,
                    name: deviceName,
                    symbolName: symbolName,
                    percentage: battery.percentage,
                    isCharging: battery.isCharging
                )
            }
        }

        return nil
    }

    // MARK: - 协议探测与 Ping

    private enum PingResult {
        case hidpp20
        case hidpp10
        case offline
        case empty
    }

    private func pingSlot(device: IOHIDDevice, devIndex: UInt8) -> PingResult? {
        // Short Report (0x10): 7 bytes
        // [0x10, devIndex, 0x00, 0x1C, 0x00, 0x00, 0x55] (0x1C: func 0x01 | swID 0x0C)
        let pingPacket: [UInt8] = [0x10, devIndex, 0x00, 0x1C, 0x00, 0x00, 0x55]

        guard let response = sendAndReceiveReport(
            device: device,
            request: pingPacket,
            expectedReportIDs: [0x10, 0x11],
            timeoutMs: 150
        ) else {
            return nil
        }

        if response[0] == 0x11 && response[1] == devIndex && response[2] == 0x00 && response[3] == 0x1C {
            return .hidpp20
        }

        if response[0] == 0x10 && response[1] == devIndex && response[2] == 0x8F && response[4] == 0x1C {
            let errCode = response[5]
            if errCode == 0x01 { return .hidpp10 }
            if errCode == 0x08 { return .empty }
            if errCode == 0x04 || errCode == 0x09 { return .offline }
        }

        return nil
    }

    // MARK: - HID++ 2.0 特性读取

    private func getFeatureIndex(device: IOHIDDevice, devIndex: UInt8, featureID: UInt16) -> UInt8? {
        // Root.GetFeature(id): Long Report 0x11
        // [0x11, devIndex, 0x00, 0x0C, idHi, idLo, 0x00...]
        var req = [UInt8](repeating: 0, count: 20)
        req[0] = 0x11
        req[1] = devIndex
        req[2] = 0x00 // Root feature index
        req[3] = 0x0C // func 0 (GetFeature) | swID 0x0C
        req[4] = UInt8((featureID >> 8) & 0xFF)
        req[5] = UInt8(featureID & 0xFF)

        guard let resp = sendAndReceiveReport(device: device, request: req, expectedReportIDs: [0x11], timeoutMs: 150) else {
            return nil
        }

        guard resp.count >= 7, resp[1] == devIndex, resp[2] == 0x00 && resp[3] == 0x0C else { return nil }
        let index = resp[4]
        return index == 0 ? nil : index
    }

    private func callFeature(device: IOHIDDevice, devIndex: UInt8, featureIndex: UInt8, funcID: UInt8, params: [UInt8]) -> [UInt8]? {
        var req = [UInt8](repeating: 0, count: 20)
        req[0] = 0x11
        req[1] = devIndex
        req[2] = featureIndex
        req[3] = (funcID << 4) | (softwareID & 0x0F)
        for i in 0..<min(params.count, 16) {
            req[4 + i] = params[i]
        }

        guard let resp = sendAndReceiveReport(device: device, request: req, expectedReportIDs: [0x11], timeoutMs: 200) else {
            return nil
        }

        guard resp.count >= 20, resp[1] == devIndex, resp[2] == featureIndex, resp[3] == req[3] else {
            return nil
        }

        return Array(resp[4...])
    }

    private func fetchDeviceMetadata(device: IOHIDDevice, devIndex: UInt8) -> (name: String, kind: String)? {
        guard let nameIndex = getFeatureIndex(device: device, devIndex: devIndex, featureID: featureName) else {
            return nil
        }

        var fullName = ""
        var deviceKind = "mouse"

        // 1. 获取名字长度
        if let lenResp = callFeature(device: device, devIndex: devIndex, featureIndex: nameIndex, funcID: 0, params: []),
           let totalLen = lenResp.first, totalLen > 0 {
            var nameBytes: [UInt8] = []
            while nameBytes.count < Int(totalLen) {
                let offset = UInt8(nameBytes.count)
                guard let chunk = callFeature(device: device, devIndex: devIndex, featureIndex: nameIndex, funcID: 1, params: [offset]) else {
                    break
                }
                let needed = min(16, Int(totalLen) - nameBytes.count)
                nameBytes.append(contentsOf: chunk.prefix(needed))
            }
            if let str = String(bytes: nameBytes, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters.union(.whitespaces)) {
                fullName = str.lowercased().hasPrefix("logitech") ? str : "Logitech \(str)"
            }
        }

        // 2. 获取设备类型
        if let kindResp = callFeature(device: device, devIndex: devIndex, featureIndex: nameIndex, funcID: 2, params: []),
           let typeByte = kindResp.first {
            switch typeByte {
            case 0, 2: deviceKind = "keyboard"
            case 3...5: deviceKind = "mouse"
            case 8: deviceKind = "headset"
            default: deviceKind = "other"
            }
        }

        return (fullName.isEmpty ? "Logitech Peripheral" : fullName, deviceKind)
    }

    private func readHIDPP20Battery(device: IOHIDDevice, devIndex: UInt8) -> (percentage: Int, isCharging: Bool)? {
        for featureID in batteryFeatures {
            guard let idx = getFeatureIndex(device: device, devIndex: devIndex, featureID: featureID) else {
                continue
            }

            switch featureID {
            case 0x1004: // UnifiedBattery
                if let r = callFeature(device: device, devIndex: devIndex, featureIndex: idx, funcID: 1, params: []) {
                    var level = Int(r[0])
                    if level == 0 {
                        switch r[1] {
                        case 8: level = 90
                        case 4: level = 50
                        case 2: level = 20
                        case 1: level = 5
                        default: level = 0
                        }
                    }
                    let isCharging = (r[2] == 1 || r[2] == 2 || r[2] == 4)
                    return (percentage: min(100, max(0, level)), isCharging: isCharging)
                }

            case 0x1000: // BatteryStatus
                if let r = callFeature(device: device, devIndex: devIndex, featureIndex: idx, funcID: 0, params: []) {
                    var level = Int(r[0])
                    if level == 0 && r[2] == 3 { level = 100 }
                    let isCharging = (r[2] == 1 || r[2] == 2 || r[2] == 4)
                    return (percentage: min(100, max(0, level)), isCharging: isCharging)
                }

            case 0x1001: // BatteryVoltage
                if let r = callFeature(device: device, devIndex: devIndex, featureIndex: idx, funcID: 0, params: []) {
                    let mv = (Int(r[0]) << 8) | Int(r[1])
                    let isCharging = (r[2] & 0x80) != 0
                    let percent = voltageToPercent(mv)
                    return (percentage: percent, isCharging: isCharging)
                }

            case 0x1F20: // ADC measurement (Headsets)
                if let r = callFeature(device: device, devIndex: devIndex, featureIndex: idx, funcID: 0, params: []) {
                    guard (r[2] & 0x01) != 0 else { return (-1, false) } // 耳机未激活
                    let mv = (Int(r[0]) << 8) | Int(r[1])
                    let isCharging = (r[2] & 0x02) != 0
                    let percent = voltageToPercent(mv)
                    return (percentage: percent, isCharging: isCharging)
                }

            default:
                break
            }
        }
        return nil
    }

    // MARK: - HID++ 1.0 寄存器读取

    private func readHIDPP10Battery(device: IOHIDDevice, devIndex: UInt8) -> (percentage: Int, isCharging: Bool)? {
        // 读取 0x0D 寄存器（电量百分比）
        let req: [UInt8] = [0x10, devIndex, 0x81, 0x0D, 0x00, 0x00, 0x00]
        if let resp = sendAndReceiveReport(device: device, request: req, expectedReportIDs: [0x10], timeoutMs: 150) {
            let level = Int(resp[4])
            if (1...100).contains(level) {
                let isCharging = (resp[6] & 0xF0) == 0x50
                return (percentage: level, isCharging: isCharging)
            }
        }
        return nil
    }

    // MARK: - 电池电压曲线转换

    private func voltageToPercent(_ mv: Int) -> Int {
        if mv >= 4150 { return 100 }
        if mv <= 3400 { return 0 }
        let curve: [(Int, Int)] = [
            (4150, 100), (4050, 90), (3960, 75), (3880, 50),
            (3790, 30), (3700, 15), (3600, 5), (3400, 0)
        ]
        for i in 0..<(curve.count - 1) {
            let (v1, p1) = curve[i]
            let (v2, p2) = curve[i + 1]
            if mv <= v1 && mv >= v2 {
                let ratio = Double(mv - v2) / Double(v1 - v2)
                return p2 + Int(ratio * Double(p1 - p2))
            }
        }
        return 50
    }

    // MARK: - HID 通信核心底层

    private func sendAndReceiveReport(
        device: IOHIDDevice,
        request: [UInt8],
        expectedReportIDs: [UInt8],
        timeoutMs: UInt32
    ) -> [UInt8]? {
        let reportID = CFIndex(request[0])

        // 注册 Input Report 异步监听
        final class ResponseBox {
            var data: [UInt8]?
        }
        let box = ResponseBox()
        let context = Unmanaged.passUnretained(box).toOpaque()

        let bufferSize = 64
        let inBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { inBuffer.deallocate() }

        let callback: IOHIDReportCallback = { context, result, sender, type, rID, report, length in
            guard result == kIOReturnSuccess, let context = context, length > 0 else { return }
            let boxRef = Unmanaged<ResponseBox>.fromOpaque(context).takeUnretainedValue()
            let packet = Array(UnsafeBufferPointer(start: report, count: length))
            boxRef.data = packet
        }

        IOHIDDeviceRegisterInputReportCallback(device, inBuffer, bufferSize, callback, context)
        defer {
            IOHIDDeviceRegisterInputReportCallback(device, inBuffer, bufferSize, nil, nil)
        }

        // 优先发送 Output Report，若不支持则尝试 Feature Report
        var setStatus = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, reportID, request, request.count)
        if setStatus != kIOReturnSuccess {
            setStatus = IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, reportID, request, request.count)
        }
        guard setStatus == kIOReturnSuccess else {
            return nil
        }

        // 轮询等待响应到达
        let stepIntervalUs: UInt32 = 10_000
        var waitedUs: UInt32 = 0
        let maxWaitUs = timeoutMs * 1_000

        while waitedUs < maxWaitUs {
            CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.01, false)
            if let resp = box.data, expectedReportIDs.contains(resp[0]) {
                return resp
            }
            usleep(stepIntervalUs)
            waitedUs += stepIntervalUs
        }

        return nil
    }
}
