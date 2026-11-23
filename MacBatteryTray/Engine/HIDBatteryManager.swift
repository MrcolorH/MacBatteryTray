import Foundation
import AppKit
import IOKit.hid
import WidgetKit

/// HID 外设电量采集与事件管理引擎
public final class HIDBatteryManager: @unchecked Sendable {
    public static let shared = HIDBatteryManager()

    /// 强制刷新通知名（供跨进程分布式通知、桌面小组件与控制中心磁贴交互）
    public static let forceRefreshNotification = NSNotification.Name("com.local.MacBatteryTray.ForceRefresh")

    /// 常态轮询间隔：60 秒全量轮询一次（配合右上角手动刷新无冷却限制）
    private static let pollingInterval: TimeInterval = 60

    /// 已注册的硬件驱动列表
    public private(set) var drivers: [HIDBatteryDriver] = []

    /// 当前已连接的符合条件的 HID 设备句柄
    private var connectedDevices: Set<IOHIDDevice> = []

    private var hidManager: IOHIDManager?
    private var pollingTimer: Timer?
    private var pollTickCount: Int = 0
    private var usbEventDebounceWorkItem: DispatchWorkItem?
    private var lastSnapshotSignature: String = ""
    /// 缓存最近一次读取到的耳机电量（供仅查键鼠的快速轮询周期复用）
    private var cachedHeadsetReadings: [String: PeripheralBattery] = [:]

    private let queue = DispatchQueue(label: "com.local.MacBatteryTray.hidEngine", qos: .utility)
    private let lock = NSLock()

    private init() {
        registerDriver(RazerHIDDriver())
        registerDriver(RazerHeadsetHIDDriver())
        registerDriver(LogitechHIDDriver())
        registerDriver(CompXHIDDriver())
        registerDriver(RongyuanHIDDriver())
        registerDriver(SteelSeriesHIDDriver())
        registerDriver(HyperXHeadsetDriver())
        registerDriver(XentaHIDDriver())
        registerDriver(IrokHIDDriver())
        registerDriver(StandardHIDBatteryDriver())
    }

    /// 注册新的硬件驱动
    public func registerDriver(_ driver: HIDBatteryDriver) {
        drivers.append(driver)
    }

    /// 启动引擎：申请权限、初始化 IOHIDManager、配置高频分层轮询与通知监听
    public func start() {
        // 1. 检查并申请输入监听权限
        requestHIDPermissions()

        // 2. 初始化 IOHIDManager 并注册匹配规则与插拔回调
        setupHIDManager()

        // 3. 启动 3 秒分层轮询（键鼠 3s，耳机 15s；仅在状态变化时重载小组件）
        startPollingTimer()

        // 4. 监听系统休眠唤醒事件（延迟 2 秒以待 USB 与 2.4G 重新协商）
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            print("[HIDBatteryManager] 系统已唤醒，2 秒后执行全量轮询...")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self?.pollAllDevices(forceReloadUI: true, includeHeadsets: true)
            }
        }

        // 5. 监听分布式通知（来自桌面小组件或控制中心 ControlWidget 的手动立即刷新）
        DistributedNotificationCenter.default().addObserver(
            forName: Self.forceRefreshNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            print("[HIDBatteryManager] 收到手动刷新指令，立即执行全量查询...")
            self?.pollAllDevices(showNotification: false, forceReloadUI: true, includeHeadsets: true)
        }

        // 首次启动立即执行一次全量扫描查询
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.pollAllDevices(forceReloadUI: true, includeHeadsets: true)
        }
    }

    /// 请求 macOS 输入监控权限（IOHIDLib）
    private func requestHIDPermissions() {
        let hasAccess = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        print("[HIDBatteryManager] IOHIDRequestAccess 授权状态: \(hasAccess)")
    }

    /// 设置 IOHIDManager 并监听 USB 设备插拔
    private func setupHIDManager() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.hidManager = manager

        var matchingArray: [[String: Any]] = []
        var registeredVIDs = Set<Int>()
        for driver in drivers {
            for vid in driver.supportedVendorIDs where vid != 0 {
                if !registeredVIDs.contains(vid) {
                    registeredVIDs.insert(vid)
                    matchingArray.append([kIOHIDVendorIDKey: vid])
                }
            }
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matchingArray as CFArray)

        let context = Unmanaged.passUnretained(self).toOpaque()

        let matchingCallback: IOHIDDeviceCallback = { context, _, _, device in
            guard let context = context else { return }
            let instance = Unmanaged<HIDBatteryManager>.fromOpaque(context).takeUnretainedValue()
            instance.handleDeviceConnected(device: device)
        }

        let removalCallback: IOHIDDeviceCallback = { context, _, _, device in
            guard let context = context else { return }
            let instance = Unmanaged<HIDBatteryManager>.fromOpaque(context).takeUnretainedValue()
            instance.handleDeviceDisconnected(device: device)
        }

        IOHIDManagerRegisterDeviceMatchingCallback(manager, matchingCallback, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, removalCallback, context)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if openResult != kIOReturnSuccess {
            print("[HIDBatteryManager] IOHIDManagerOpen 返回状态: \(openResult)")
        }
    }

    /// 处理新匹配到的 HID 设备（如插上鼠标 USB 充电线或插入接收器）
    private func handleDeviceConnected(device: IOHIDDevice) {
        lock.lock()
        connectedDevices.insert(device)
        lock.unlock()

        let name = HIDDeviceHelper.getProductName(device: device)
        let vid = HIDDeviceHelper.getVendorID(device: device) ?? 0
        let pid = HIDDeviceHelper.getProductID(device: device) ?? 0
        print("[HIDBatteryManager] 检测到设备接入: \(name) (VID: 0x\(String(vid, radix: 16)), PID: 0x\(String(pid, radix: 16)))")

        scheduleDebouncedUSBRefresh()
    }

    /// 处理拔出或断开的 HID 设备（如拔下 USB 充电线或接收器）
    private func handleDeviceDisconnected(device: IOHIDDevice) {
        lock.lock()
        connectedDevices.remove(device)
        lock.unlock()

        let name = HIDDeviceHelper.getProductName(device: device)
        let vid = HIDDeviceHelper.getVendorID(device: device) ?? 0
        let pid = HIDDeviceHelper.getProductID(device: device) ?? 0
        print("[HIDBatteryManager] 设备已拔出: \(name) (VID: 0x\(String(vid, radix: 16)), PID: 0x\(String(pid, radix: 16)))")

        // 若拔出的是耳机接收器，清除对应耳机缓存
        queue.async { [weak self] in
            let idKey = "\(vid)_\(pid)"
            self?.cachedHeadsetReadings.removeValue(forKey: idKey)
        }

        scheduleDebouncedUSBRefresh(delay: 0.6)
    }

    /// USB 插拔防抖刷新（0.8 秒初查 + 3 秒复查，兜住外设电源芯片握手延迟）
    private func scheduleDebouncedUSBRefresh(delay: TimeInterval = 0.8) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.usbEventDebounceWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.pollAllDevices(showNotification: false, forceReloadUI: true, includeHeadsets: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
                    self?.pollAllDevices(showNotification: false, forceReloadUI: false, includeHeadsets: true)
                }
            }
            self.usbEventDebounceWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    /// 启动 60 秒定时轮询
    private func startPollingTimer() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.pollingTimer?.invalidate()
            self.pollingTimer = Timer.scheduledTimer(withTimeInterval: Self.pollingInterval, repeats: true) { [weak self] _ in
                self?.pollAllDevices(showNotification: false, forceReloadUI: false, includeHeadsets: true)
            }
        }
    }

    /// 轮询当前已连接的所有外设（可选择本轮是否主动查询耳机桥接通道）
    public func pollAllDevices(showNotification: Bool = false, forceReloadUI: Bool = false, includeHeadsets: Bool = true) {
        queue.async { [weak self] in
            guard let self = self else { return }

            self.lock.lock()
            let devices = Array(self.connectedDevices)
            self.lock.unlock()

            var activeList: [PeripheralBattery] = []
            var seenHeadsetIDs = Set<String>()

            for device in devices {
                let isHeadsetDevice = self.isAirohaHeadsetDevice(device: device)
                if isHeadsetDevice && !includeHeadsets {
                    // 非耳机查询轮次：复用最近一次缓存的耳机状态，避免每 3 秒切换 Remote/Local
                    if let vid = HIDDeviceHelper.getVendorID(device: device),
                       let pid = HIDDeviceHelper.getProductID(device: device),
                       let cached = self.cachedHeadsetReadings["\(vid)_\(pid)"] {
                        seenHeadsetIDs.insert(cached.id)
                        Self.mergeBattery(cached, into: &activeList)
                    }
                    continue
                }

                let batteries = self.readBatteriesFromDevice(device: device)
                for battery in batteries where battery.percentage >= 0 {
                    if isHeadsetDevice {
                        self.cachedHeadsetReadings[battery.id] = battery
                        seenHeadsetIDs.insert(battery.id)
                    }
                    Self.mergeBattery(battery, into: &activeList)
                }
            }

            // 清理已断开的耳机缓存
            if includeHeadsets {
                self.cachedHeadsetReadings = self.cachedHeadsetReadings.filter { seenHeadsetIDs.contains($0.key) }
            }

            // 查询系统已连接且上报了电量的蓝牙外设（通过 IORegistry，零侵入）
            let bluetoothDevices = BluetoothHIDBatteryReader.shared.readConnectedDevices()
            for btDevice in bluetoothDevices where btDevice.percentage >= 0 {
                Self.mergeBattery(btDevice, into: &activeList)
            }

            let sorted = activeList.sorted { $0.id < $1.id }
            let signature = sorted.map { "\($0.id):\($0.percentage):\($0.isCharging)" }.joined(separator: "|")
            let changed = (signature != self.lastSnapshotSignature)
            self.lastSnapshotSignature = signature

            // 仅在数据变化或手动强制刷新时写盘并重载界面（手动刷新一定落盘以更新 mtime）
            if changed || forceReloadUI {
                BatteryStore.shared.saveBatteries(sorted)
                self.notifyControlCenter()
            }

            if showNotification {
                BatteryNotificationManager.shared.showBatterySummary(batteries: sorted)
            }
        }
    }

    private func isAirohaHeadsetDevice(device: IOHIDDevice) -> Bool {
        guard let vid = HIDDeviceHelper.getVendorID(device: device),
              let pid = HIDDeviceHelper.getProductID(device: device) else {
            return false
        }
        return vid == 0x1532 && (pid == 0x053A || pid == 0x0535)
    }

    private static func mergeBattery(_ battery: PeripheralBattery, into list: inout [PeripheralBattery]) {
        if let idx = list.firstIndex(where: { $0.id == battery.id }) {
            list[idx] = battery
        } else if let sameNameIdx = list.firstIndex(where: { normalizedName($0.name) == normalizedName(battery.name) }) {
            // 同型号不同连接通道时，优先保留正在充电的一条；若都不在充电，优先保留 2.4G 专属驱动读数
            let existing = list[sameNameIdx]
            if battery.isCharging && !existing.isCharging {
                list[sameNameIdx] = battery
            } else if existing.transport == .bluetooth && battery.transport == .wireless24G {
                list[sameNameIdx] = battery
            }
        } else {
            list.append(battery)
        }
    }

    private static func normalizedName(_ name: String) -> String {
        return name
            .lowercased()
            .replacingOccurrences(of: " 2.4", with: "")
            .replacingOccurrences(of: " wireless", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 读取设备电量核心流程
    private func readBatteriesFromDevice(device: IOHIDDevice) -> [PeripheralBattery] {
        guard let vid = HIDDeviceHelper.getVendorID(device: device),
              let pid = HIDDeviceHelper.getProductID(device: device) else {
            return []
        }

        let matchedDrivers = drivers.filter { $0.matches(vendorID: vid, productID: pid) }
        guard !matchedDrivers.isEmpty else {
            return []
        }

        _ = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))

        for driver in matchedDrivers {
            if let readings = driver.queryBatteries(device: device), !readings.isEmpty {
                return readings.map { reading in
                    PeripheralBattery(
                        id: reading.id,
                        name: reading.name,
                        symbolName: reading.symbolName,
                        percentage: reading.percentage,
                        isCharging: reading.isCharging,
                        updatedAt: Date()
                    )
                }
            }
        }

        return []
    }

    /// 刷新控制中心 ControlWidget 与桌面 WidgetKit 时间线
    private func notifyControlCenter() {
        DispatchQueue.main.async {
            WidgetCenter.shared.reloadAllTimelines()
            if #available(macOS 26.0, *) {
                ControlCenter.shared.reloadAllControls()
            }
        }
    }

    deinit {
        pollingTimer?.invalidate()
        usbEventDebounceWorkItem?.cancel()
        if let manager = hidManager {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
    }
}
