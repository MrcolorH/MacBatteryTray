import Foundation
import AppIntents

/// 静默小组件交互意图（用于吸收桌面小组件空白区域点击，避免误触发系统默认启动主应用行为）
public struct SilentWidgetTapIntent: AppIntent {
    public static var title: LocalizedStringResource = "静默点击"
    public static var isDiscoverable: Bool = false

    public init() {}

    public func perform() async throws -> some IntentResult {
        // 静默返回，不打开宿主 App
        return .result()
    }
}
