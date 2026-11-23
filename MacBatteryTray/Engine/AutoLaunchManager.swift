import Foundation
import ServiceManagement

/// 基于 SMAppService.mainApp 的开机自启动管理封装
public final class AutoLaunchManager: @unchecked Sendable {
    public static let shared = AutoLaunchManager()

    private init() {}

    /// 当前是否已启用开机自启
    public var isEnabled: Bool {
        return SMAppService.mainApp.status == .enabled
    }

    /// 当前注册状态
    public var status: SMAppService.Status {
        return SMAppService.mainApp.status
    }

    /// 启用开机自启
    public func register() throws {
        try SMAppService.mainApp.register()
    }

    /// 禁用开机自启
    public func unregister() throws {
        try SMAppService.mainApp.unregister()
    }

    /// 切换开机自启状态
    public func toggle() throws {
        if isEnabled {
            try unregister()
        } else {
            try register()
        }
    }
}
