import Foundation
import IOKit.hid

/// Xenta 方案 2.4G 接收器无线鼠标驱动
/// 覆盖品牌：Attack Shark（攻击鲨 X11, X3, X6, R1, V3 Pro, X8 Pro 等）、Delux（多彩 M600 Pro / M900 Pro）、
/// Inphic（英菲克 IN10 / IN9 / IN6）、FURYCUBE（F1 / G3 / G9）、MAMBASNAKE（曼巴蛇）等
public final class XentaHIDDriver: HIDBatteryDriver {
    public let driverName: String = "Xenta Mouse Driver"
    public let vendorID: Int = 0x1D57

    public let supportedVendorIDs: [Int] = [0x1D57]
    public let supportedProductIDs: [Int] = [
        0xFA60, // 标准 2.4G 接收器
        0xFA65, // 8K 接收器
        0xFA55, 0x2155, 0xFA71, 0x2126 // 有线模式 PID
    ]

    // 缓存最后一次收到的电量与状态
    private var lastKnownBattery: [String: (percentage: Int, isCharging: Bool, updatedAt: Date)] = [:]
    private let cacheLock = NSLock()

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
        guard let vid = HIDDeviceHelper.getVendorID(device: device),
              let pid = HIDDeviceHelper.getProductID(device: device) else {
            return nil
        }

        let deviceKey = "\(vid)_\(pid)"

        // 监听并读取 5 字节主动上报报文 (Report ID 0x03)
        // [0x03, modelCode, 0x40/0x41/0x43, state, level]
        if let report = listenForInputReport(device: device, timeoutMs: 300) {
            let modelCode = report[1]
            let frameType = report[2]
            let state = report[3]
            var level = Int(report[4])

            if frameType == 0x40 || frameType == 0x41 || frameType == 0x43 {
                let isCharging = (state == 0x02 || state == 0x03)
                // 针对 0x10 (X6/R1) 等以 10% 为步长的外设
                if modelCode == 0x10 && level <= 10 {
                    level *= 10
                }
                let validPercentage = min(100, max(0, level))

                cacheLock.lock()
                lastKnownBattery[deviceKey] = (percentage: validPercentage, isCharging: isCharging, updatedAt: Date())
                cacheLock.unlock()

                let modelName = resolveModelName(code: modelCode, pid: pid)
                return [
                    PeripheralBatteryReading(
                        id: "xenta_\(deviceKey)",
                        name: modelName,
                        symbolName: "magicmouse.fill",
                        percentage: validPercentage,
                        isCharging: isCharging
                    )
                ]
            }
        }

        // 若本次短暂未监听到且在缓存有效期内（60秒），使用上一次有效电量
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = lastKnownBattery[deviceKey], Date().timeIntervalSince(cached.updatedAt) < 60 {
            let modelName = resolveModelName(code: 0, pid: pid)
            return [
                PeripheralBatteryReading(
                    id: "xenta_\(deviceKey)",
                    name: modelName,
                    symbolName: "magicmouse.fill",
                    percentage: cached.percentage,
                    isCharging: cached.isCharging
                )
            ]
        }

        return nil
    }

    private func listenForInputReport(device: IOHIDDevice, timeoutMs: UInt32) -> [UInt8]? {
        final class ReportHolder { var data: [UInt8]? }
        let holder = ReportHolder()
        let context = Unmanaged.passUnretained(holder).toOpaque()

        let bufferSize = 64
        let inBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { inBuffer.deallocate() }

        let callback: IOHIDReportCallback = { context, result, sender, type, rID, report, length in
            guard result == kIOReturnSuccess, let context = context, length >= 5 else { return }
            let ref = Unmanaged<ReportHolder>.fromOpaque(context).takeUnretainedValue()
            let packet = Array(UnsafeBufferPointer(start: report, count: length))
            if packet[0] == 0x03 {
                ref.data = packet
            }
        }

        IOHIDDeviceRegisterInputReportCallback(device, inBuffer, bufferSize, callback, context)
        defer {
            IOHIDDeviceRegisterInputReportCallback(device, inBuffer, bufferSize, nil, nil)
        }

        let stepUs: UInt32 = 10_000
        var waitedUs: UInt32 = 0
        let maxUs = timeoutMs * 1_000

        while waitedUs < maxUs {
            CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.01, false)
            if let packet = holder.data {
                return packet
            }
            usleep(stepUs)
            waitedUs += stepUs
        }

        return nil
    }

    private func resolveModelName(code: UInt8, pid: Int) -> String {
        switch code {
        case 0x55: return "Attack Shark X11"
        case 0x4E: return "Attack Shark X3 Max"
        case 0xE5: return "Attack Shark V3 Pro"
        case 0x10: return "Attack Shark X6 / R1"
        case 0x07: return "Attack Shark X11 SE"
        case 0x08: return "Attack Shark X8 Pro"
        case 0x24: return "Attack Shark V6"
        case 0x20: return "Delux M600 Pro"
        case 0x30, 0x50: return "Delux M900 Pro"
        case 0x73, 0x74: return "Inphic IN10 MAX"
        case 0x66: return "FURYCUBE G3"
        case 0x05, 0xC2: return "FURYCUBE F1 / F3"
        case 0x95: return "Inphic In9 Pro"
        case 0x01: return "Attack Shark X3 Pro"
        case 0x4D: return "Attack Shark X3"
        default:
            return (pid == 0xFA65) ? "Attack Shark 8K Mouse" : "Attack Shark Wireless Mouse"
        }
    }
}
