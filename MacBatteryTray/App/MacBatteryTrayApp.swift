import SwiftUI

@main
struct MacBatteryTrayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // 后台常驻应用，不提供主应用窗口，通过托盘和控制中心交互
        Settings {
            EmptyView()
        }
    }
}
