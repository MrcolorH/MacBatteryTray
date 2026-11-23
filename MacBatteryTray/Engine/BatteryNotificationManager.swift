import Foundation
import UserNotifications

/// macOS 系统通知管理器（用于在点击控制中心刷新或快捷键时向用户弹出电量横幅）
public final class BatteryNotificationManager: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    public static let shared = BatteryNotificationManager()

    private override init() {
        super.init()
    }

    /// 初始化并请求系统通知权限
    public func setup() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                print("[BatteryNotificationManager] 请求通知权限失败: \(error.localizedDescription)")
            } else {
                print("[BatteryNotificationManager] 通知授权状态: \(granted ? "已授权" : "未授权")")
            }
        }
    }

    /// 当应用处于前台或后台活跃时，允许直接显示横幅与播放提示音
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// 发送外设电量即时反馈横幅（按设备类型分类展示）
    public func showBatterySummary(batteries: [PeripheralBattery]) {
        let content = UNMutableNotificationContent()
        content.title = "🔋 外设电量已更新"

        let validBatteries = batteries.filter { $0.percentage >= 0 }
        if validBatteries.isEmpty {
            content.body = "未检测到已连接的无线外设"
        } else {
            let sorted = validBatteries.sorted { a, b in
                let order: [PeripheralCategory: Int] = [.mouse: 1, .keyboard: 2, .headset: 3, .other: 4]
                return (order[a.category] ?? 99) < (order[b.category] ?? 99)
            }
            let details = sorted.map { b in
                let charging = b.isCharging ? " [⚡充电中]" : ""
                return "• \(b.emoji) \(b.category.rawValue) (\(b.name)): \(b.displayPercentage)\(charging)"
            }.joined(separator: "\n")
            content.body = details
        }
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "com.local.MacBatteryTray.RefreshBanner-\(UUID().uuidString)",
            content: content,
            trigger: nil // nil 表示立即投递
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("[BatteryNotificationManager] 投递通知异常: \(error.localizedDescription)")
            }
        }
    }
}
