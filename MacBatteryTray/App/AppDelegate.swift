import AppKit
import SwiftUI

/// 主程序生命周期与窗口管理
public final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var mainWindow: NSWindow?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        print("[MacBatteryTray] 应用程序启动中，正在初始化硬件守护引擎...")

        // 1. 初始化通知管理与后台 HID 硬件采集引擎
        BatteryNotificationManager.shared.setup()
        HIDBatteryManager.shared.start()

        // 2. 初始展示现代主窗口
        setupAndShowMainWindow()
    }

    /// 创建并展示主控制面板窗口
    public func setupAndShowMainWindow() {
        // 设置为常规 App 模式，Dock 栏显示图标并激活前台
        NSApp.setActivationPolicy(.regular)

        if let existing = mainWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let contentView = MainDashboardView()
        let hostingController = NSHostingController(rootView: contentView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.setFrameAutosaveName("MacBatteryTrayMainWindow")
        window.contentViewController = hostingController
        window.title = "外设电量助手"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.delegate = self

        self.mainWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - NSWindowDelegate 窗口关闭时转入无感静默守护
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        // 隐藏窗口
        sender.orderOut(nil)

        // 切换为配件后台模式：Dock 栏图标自动退出消失，前端完全无残留
        NSApp.setActivationPolicy(.accessory)
        print("[AppDelegate] 窗口已关闭，Dock 栏图标已隐藏，进入纯后台静默守护模式，小组件持续工作")

        // 返回 false 阻止系统销毁窗口实例，方便下次快速唤起
        return false
    }

    // MARK: - 用户从启动台/访达再次点击应用图标时重新唤出窗口
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        print("[AppDelegate] 用户再次打开应用，唤出主控制面板...")
        setupAndShowMainWindow()
        return true
    }

    public func applicationWillTerminate(_ notification: Notification) {
        print("[MacBatteryTray] 应用程序即将退出")
    }
}
