import AppKit

/// 主程序生命周期与菜单栏托盘管理
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var menu: NSMenu?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        print("[MacBatteryTray] 应用程序已启动，正在初始化后台引擎...")

        // 初始化通知管理器
        BatteryNotificationManager.shared.setup()

        // 启动 HID 采集引擎
        HIDBatteryManager.shared.start()

        // 创建状态栏菜单项
        setupStatusItem()
    }

    /// 是否在顶部菜单栏显示图标（默认显示，可由用户选择隐藏以实现全隐形运行）
    public static var showMenuBarIcon: Bool {
        if UserDefaults.standard.object(forKey: "showMenuBarIcon") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "showMenuBarIcon")
    }

    private func setupStatusItem() {
        guard Self.showMenuBarIcon else {
            print("[AppDelegate] 顶部菜单栏图标已停用，保持纯后台隐形模式，通过控制中心磁贴交互")
            return
        }

        guard statusItem == nil else { return }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "battery.100.bolt", accessibilityDescription: "外设电量")
            button.toolTip = "MacBatteryTray - 外设电量监控"
        }

        let menu = NSMenu()
        self.menu = menu
        menu.delegate = self
        statusItem?.menu = menu
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // 当用户再次从访达或启动台点击打开应用时，重新唤出菜单栏图标以供配置
        if statusItem == nil {
            UserDefaults.standard.set(true, forKey: "showMenuBarIcon")
            setupStatusItem()
            statusItem?.button?.performClick(nil)
        }
        return true
    }

    public func applicationWillTerminate(_ notification: Notification) {
        print("[MacBatteryTray] 应用程序即将退出")
    }
}

// MARK: - 菜单动态渲染与交互
extension AppDelegate: NSMenuDelegate {
    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // 1. 标题
        let headerItem = NSMenuItem(title: "外设电量状态", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)
        menu.addItem(NSMenuItem.separator())

        // 2. 读取当前外设列表（过滤掉离线与拔出设备，且遵循蓝牙显示配置）
        let batteries = BatteryStore.shared.loadBatteries()
        if batteries.isEmpty {
            let emptyItem = NSMenuItem(title: "未检测到已连接的无线外设", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            let sorted = batteries.sorted { a, b in
                let order: [PeripheralCategory: Int] = [.mouse: 1, .keyboard: 2, .headset: 3, .other: 4]
                return (order[a.category] ?? 99) < (order[b.category] ?? 99)
            }
            for battery in sorted {
                let chargeText = battery.isCharging ? " [⚡充电中]" : ""
                let title = "\(battery.emoji) \(battery.category.rawValue) [\(battery.transport.badge)]: \(battery.name) (\(battery.displayPercentage))\(chargeText)"
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.image = NSImage(systemSymbolName: battery.symbolName, accessibilityDescription: nil)
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())

        // 3. 手动刷新按钮
        let refreshItem = NSMenuItem(title: "立即刷新电量", action: #selector(handleManualRefresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        // 4. 设置选项：展示蓝牙外设电量
        let showBT = BatteryStore.shared.showBluetoothDevices
        let btItem = NSMenuItem(title: "展示蓝牙设备电量", action: #selector(toggleShowBluetooth), keyEquivalent: "b")
        btItem.target = self
        btItem.state = showBT ? .on : .off
        menu.addItem(btItem)

        // 5. 开机自启切换
        let autoLaunchState = AutoLaunchManager.shared.isEnabled ? NSControl.StateValue.on : NSControl.StateValue.off
        let autoLaunchItem = NSMenuItem(title: "开机自动启动", action: #selector(toggleAutoLaunch), keyEquivalent: "")
        autoLaunchItem.target = self
        autoLaunchItem.state = autoLaunchState
        menu.addItem(autoLaunchItem)

        // 6. 隐藏菜单栏图标（完全隐形模式）
        let hideItem = NSMenuItem(title: "隐藏菜单栏图标 (纯控制中心模式)", action: #selector(hideMenuBarIconAction), keyEquivalent: "")
        hideItem.target = self
        menu.addItem(hideItem)

        menu.addItem(NSMenuItem.separator())

        // 7. 退出程序
        let quitItem = NSMenuItem(title: "退出 MacBatteryTray", action: #selector(handleQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func hideMenuBarIconAction() {
        UserDefaults.standard.set(false, forKey: "showMenuBarIcon")
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
        print("[AppDelegate] 顶部栏图标已隐藏，进入纯后台完全隐形模式")
    }

    @objc private func handleManualRefresh() {
        print("[AppDelegate] 用户手动触发电量刷新")
        HIDBatteryManager.shared.pollAllDevices(showNotification: true, forceReloadUI: true, includeHeadsets: true)
    }

    @objc private func toggleShowBluetooth() {
        let current = BatteryStore.shared.showBluetoothDevices
        let next = !current
        BatteryStore.shared.showBluetoothDevices = next
        print("[AppDelegate] 展示蓝牙外设电量状态切换为: \(next)")
        HIDBatteryManager.shared.pollAllDevices(showNotification: false, forceReloadUI: true, includeHeadsets: true)
    }

    @objc private func toggleAutoLaunch() {
        do {
            try AutoLaunchManager.shared.toggle()
            print("[AppDelegate] 开机自启状态切换为: \(AutoLaunchManager.shared.isEnabled)")
        } catch {
            print("[AppDelegate] 切换开机自启失败: \(error.localizedDescription)")
        }
    }

    @objc private func handleQuit() {
        NSApplication.shared.terminate(nil)
    }
}
