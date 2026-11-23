import Foundation
import IOKit.hid

private final class BridgeResponseBox {
    var expectedReportID: UInt8 = 0x01
    var expectedFieldID: UInt8 = 0x21
    var value: UInt8?
}

/// 雷蛇（Razer）无线游戏耳机 HID 驱动
/// 协议严格移植自开源项目 qu1ncky/BatteryTray (src/providers/devices/razer_audio.rs)
public final class RazerHeadsetHIDDriver: HIDBatteryDriver {
    public let driverName: String = "Razer Headset HID Driver"
    public let vendorID: Int = 0x1532

    private static let reportIDBarracudaPro: UInt8 = 0x01
    private static let reportIDV2Pro2023: UInt8 = 0x02
    private static let bridgeReadKind: UInt8 = 0x08
    private static let bridgeLinkKind: UInt8 = 0x0E
    private static let fieldBattery: UInt8 = 0x21
    private static let fieldCharging: UInt8 = 0x2A

    /// 支持 Airoha 桥接协议的雷蛇无线耳机 PID
    public let supportedProductIDs: [Int] = [
        0x053A, // Razer Barracuda Pro 2.4 GHz
        0x0535, // Razer BlackShark V2 Pro (2023)
    ]

    public init() {}

    /// 查询耳机当前电量与充电状态
    public func queryBattery(device: IOHIDDevice) -> (percentage: Int, isCharging: Bool)? {
        // 严格匹配原版 BatteryTray is_bridge_collection 条件：
        // UsagePage == 0xFF00 且 Input/Output 报告长度均为 64
        let usagePage = HIDDeviceHelper.getPrimaryUsagePage(device: device) ?? 0
        let maxInput = HIDDeviceHelper.getMaxInputReportSize(device: device) ?? 0
        let maxOutput = HIDDeviceHelper.getMaxOutputReportSize(device: device) ?? 0
        guard usagePage == 0xFF00, maxInput == 64, maxOutput == 64 else {
            return nil
        }

        let pid = HIDDeviceHelper.getProductID(device: device) ?? 0
        let reportID: UInt8 = (pid == 0x0535) ? Self.reportIDV2Pro2023 : Self.reportIDBarracudaPro

        let openStatus = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openStatus == kIOReturnSuccess else {
            return nil
        }

        return queryAirohaBridge(device: device, reportID: reportID)
    }

    /// 构造原版 BatteryTray 的 bridge_frame（64 字节 Output Report）
    private func buildBridgeFrame(reportID: UInt8, kind: UInt8, body: [UInt8]) -> [UInt8] {
        let isV2Pro = (reportID == Self.reportIDV2Pro2023)
        let offset = isV2Pro ? 5 : 3
        let sequence: UInt8 = isV2Pro ? 0x00 : 0x08

        var frame = [UInt8](repeating: 0, count: 64)
        frame[0] = reportID
        frame[1] = 0x80
        frame[2] = UInt8(4 + body.count)
        frame[offset] = 0x50     // 'P'
        frame[offset + 1] = 0x41 // 'A'
        frame[offset + 2] = kind
        frame[offset + 3] = sequence
        for (idx, byte) in body.enumerated() where offset + 4 + idx < 64 {
            frame[offset + 4 + idx] = byte
        }
        return frame
    }

    /// 解析原版 BatteryTray 的 bridge_value
    private static func parseBridgeValue(data: [UInt8], reportID: UInt8, fieldID: UInt8) -> UInt8? {
        let isV2Pro = (reportID == reportIDV2Pro2023)
        let at = isV2Pro ? 2 : 3
        guard data.count > at + 13 else { return nil }
        guard data[0] == reportID else { return nil }
        guard isV2Pro || data[1] == 0x80 else { return nil }
        guard data[at] == 0x50, data[at + 1] == 0x49 else { return nil } // 'P', 'I'
        // payload 格式：<fieldID> 01 <count> <value>（02 为耳机主动上报，跳过）
        guard data[at + 10] == fieldID, data[at + 11] == 0x01, data[at + 12] >= 1 else {
            return nil
        }
        return data[at + 13]
    }

    /// 严格按原版 BatteryTray barracuda_pro 流程查询：
    /// Remote 模式开 -> 查电量(0x21) -> 查充电(0x2A) -> 无论成败必切回 Local 模式
    /// 注意：绝不发送 0x01 0x40 (AppMode)，避免影响 2.4G 音频通路
    private func queryAirohaBridge(device: IOHIDDevice, reportID: UInt8) -> (percentage: Int, isCharging: Bool)? {
        let box = BridgeResponseBox()
        box.expectedReportID = reportID
        let context = Unmanaged.passUnretained(box).toOpaque()
        guard let runLoop = CFRunLoopGetCurrent() else {
            return nil
        }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)

        IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, { ctx, result, _, _, _, report, len in
            guard result == kIOReturnSuccess, let ctx = ctx, len > 0 else { return }
            let box = Unmanaged<BridgeResponseBox>.fromOpaque(ctx).takeUnretainedValue()
            let data = Array(UnsafeBufferPointer(start: report, count: len))
            if let parsed = RazerHeadsetHIDDriver.parseBridgeValue(
                data: data,
                reportID: box.expectedReportID,
                fieldID: box.expectedFieldID
            ) {
                box.value = parsed
            }
        }, context)

        IOHIDDeviceScheduleWithRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue)

        func sendFrame(_ frame: [UInt8]) -> Bool {
            let status = IOHIDDeviceSetReport(
                device,
                kIOHIDReportTypeOutput,
                CFIndex(reportID),
                frame,
                frame.count
            )
            return status == kIOReturnSuccess
        }

        func setRemoteMode(_ enabled: Bool) -> Bool {
            let frame = buildBridgeFrame(
                reportID: reportID,
                kind: Self.bridgeLinkKind,
                body: [0x02, 0xE1, enabled ? 0x01 : 0x00]
            )
            let ok = sendFrame(frame)
            let waitSec: TimeInterval = (reportID == Self.reportIDV2Pro2023) ? 0.035 : 0.05
            RunLoop.current.run(until: Date().addingTimeInterval(waitSec))
            return ok
        }

        func askField(_ fieldID: UInt8, timeout: TimeInterval = 0.3) -> UInt8? {
            box.expectedFieldID = fieldID
            box.value = nil
            let frame = buildBridgeFrame(
                reportID: reportID,
                kind: Self.bridgeReadKind,
                body: [0x03, fieldID, 0x00, 0x00]
            )
            guard sendFrame(frame) else { return nil }
            let deadline = Date().addingTimeInterval(timeout)
            while box.value == nil && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.015))
            }
            return box.value
        }

        // 排空旧的残留输入包
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))

        var remoteEntered = false
        defer {
            if remoteEntered {
                _ = setRemoteMode(false)
            }
            IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, nil, nil)
            IOHIDDeviceUnscheduleFromRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue)
            buffer.deallocate()
        }

        guard setRemoteMode(true) else {
            return nil
        }
        remoteEntered = true

        // 最多尝试 3 次读取电量（原版 BatteryTray 逻辑）
        var level: UInt8?
        for _ in 0..<3 {
            if let value = askField(Self.fieldBattery, timeout: 0.3) {
                level = value
                break
            }
        }

        guard let batteryLevel = level, batteryLevel <= 100 else {
            return (percentage: -1, isCharging: false)
        }

        // 读取充电状态（0 = 电池供电，非 0 = 充电中）
        let chargingByte = askField(Self.fieldCharging, timeout: 0.3)
        let isCharging = (chargingByte ?? 0) != 0

        return (percentage: Int(batteryLevel), isCharging: isCharging)
    }
}
