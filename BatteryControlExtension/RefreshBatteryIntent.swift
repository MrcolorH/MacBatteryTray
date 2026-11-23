import AppIntents
import Foundation
import AppKit
import WidgetKit

/// 桌面小组件与控制中心点击触发的手动刷新 Intent（无冷却限制，同步等待主程序写入最新状态后再重绘）
public struct RefreshBatteryIntent: AppIntent {
    public static var title: LocalizedStringResource = "刷新外设电量"
    public static var description = IntentDescription("向 MacBatteryTray 后台引擎发送强制刷新指令")

    public init() {}

    public func perform() async throws -> some IntentResult {
        // 1. 若主程序未运行则先拉起
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.local.MacBatteryTray")
        if runningApps.isEmpty {
            let appURL = URL(fileURLWithPath: "/Applications/MacBatteryTray.app")
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        }

        // 2. 记录刷新前 battery.json 的修改时间，用于确认主程序已落盘最新硬件状态
        let fileURL = BatteryStore.shared.storageFileURL
        let beforeDate = Self.modificationDate(of: fileURL)

        // 3. 向主程序发送跨进程强制刷新通知（立即投递，无冷却限制）
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("com.local.MacBatteryTray.ForceRefresh"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )

        // 4. 异步等待主程序查完所有外设并写完 battery.json（每 50ms 检查一次，最长 1.8 秒）
        let deadline = Date().addingTimeInterval(1.8)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if let afterDate = Self.modificationDate(of: fileURL),
               beforeDate == nil || afterDate > beforeDate! {
                break
            }
        }

        // 5. 此时 battery.json 已是最新数据，立即通知桌面小组件与控制中心重绘
        WidgetCenter.shared.reloadAllTimelines()
        if #available(macOS 26.0, *) {
            ControlCenter.shared.reloadAllControls()
        }

        return .result()
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }
}
