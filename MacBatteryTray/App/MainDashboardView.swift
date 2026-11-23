import SwiftUI
import Combine

/// 控制面板数据视图模型（纯 Property Wrapper，兼容裸编译器与模块化解耦）
public final class DashboardViewModel: ObservableObject {
    @Published public var batteries: [PeripheralBattery] = []
    @Published public var showBluetooth: Bool = BatteryStore.shared.showBluetoothDevices
    @Published public var autoLaunchEnabled: Bool = AutoLaunchManager.shared.isEnabled
    @Published public var isRefreshing: Bool = false
    @Published public var showQuitConfirmAlert: Bool = false
    @Published public var lastRefreshTime: Date = Date()

    private var cancellables = Set<AnyCancellable>()

    public init() {
        reload()

        // 每 3 秒自动拉取最新设备快照
        Timer.publish(every: 3, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.reload()
            }
            .store(in: &cancellables)
    }

    public func reload() {
        self.batteries = BatteryStore.shared.loadBatteries()
        self.showBluetooth = BatteryStore.shared.showBluetoothDevices
        self.autoLaunchEnabled = AutoLaunchManager.shared.isEnabled
    }

    public func toggleBluetooth(_ enable: Bool) {
        showBluetooth = enable
        BatteryStore.shared.showBluetoothDevices = enable
        triggerManualRefresh()
    }

    public func toggleAutoLaunch(_ enable: Bool) {
        autoLaunchEnabled = enable
        if enable != AutoLaunchManager.shared.isEnabled {
            try? AutoLaunchManager.shared.toggle()
        }
    }

    public func triggerManualRefresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        HIDBatteryManager.shared.pollAllDevices(showNotification: false, forceReloadUI: true, includeHeadsets: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self = self else { return }
            self.reload()
            self.lastRefreshTime = Date()
            self.isRefreshing = false
        }
    }
}

/// 现代桌面套壳应用主控制面板视图
public struct MainDashboardView: View {
    @ObservedObject public var viewModel = DashboardViewModel()

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider().opacity(0.4)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 20) {
                    peripheralsSection
                    settingsSection
                    widgetTipsCard
                }
                .padding(20)
            }

            Divider().opacity(0.4)
            footerView
        }
        .frame(minWidth: 540, idealWidth: 580, maxWidth: 620, minHeight: 480, idealHeight: 520, maxHeight: 650)
        .background(Color(NSColor.windowBackgroundColor))
        .alert("确定要彻底退出外设电量服务吗？", isPresented: $viewModel.showQuitConfirmAlert) {
            Button("取消", role: .cancel) {}
            Button("彻底退出", role: .destructive) {
                NSApplication.shared.terminate(nil)
            }
        } message: {
            Text("彻底退出后，后台硬件采集将停止工作，桌面小组件将无法再自动更新电量，直到您下次重新打开本应用。")
        }
    }

    // MARK: - 顶部标题与状态栏
    private var headerView: some View {
        HStack {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.opacity(0.15))
                        .frame(width: 36, height: 36)
                    Image(systemName: "battery.100.bolt")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("外设电量助手")
                        .font(.system(size: 15, weight: .bold))
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                        Text("后台静默守护中 · 桌面小组件就绪")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            Button {
                viewModel.triggerManualRefresh()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(.degrees(viewModel.isRefreshing ? 360 : 0))
                        .animation(viewModel.isRefreshing ? Animation.linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: viewModel.isRefreshing)
                    Text("立即刷新")
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(viewModel.isRefreshing)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - 外设卡片网格
    private var peripheralsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("已连接外设 (\(viewModel.batteries.count))")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("最后更新: \(viewModel.lastRefreshTime, style: .time)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            if viewModel.batteries.isEmpty {
                emptyPeripheralsView
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                    ForEach(viewModel.batteries) { item in
                        deviceCard(for: item)
                    }
                }
            }
        }
    }

    // MARK: - 单个外设卡片
    private func deviceCard(for item: PeripheralBattery) -> some View {
        HStack(spacing: 14) {
            // 环形电量条
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 5)
                    .frame(width: 52, height: 52)
                Circle()
                    .trim(from: 0, to: CGFloat(max(0, min(100, item.percentage))) / 100.0)
                    .stroke(batteryColor(for: item.percentage, isCharging: item.isCharging), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .frame(width: 52, height: 52)
                    .rotationEffect(.degrees(-90))

                Image(systemName: item.symbolName)
                    .font(.system(size: 18))
                    .foregroundStyle(batteryColor(for: item.percentage, isCharging: item.isCharging))
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)

                    transportBadge(for: item.transport)
                }

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(item.percentage)%")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    if item.isCharging {
                        Label("充电中", systemImage: "bolt.fill")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.green)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
                .shadow(color: Color.black.opacity(0.03), radius: 3, x: 0, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    // 通道徽标
    private func transportBadge(for transport: PeripheralTransport) -> some View {
        Text(transport.badge)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(transport == .wireless24G ? Color.purple.opacity(0.15) : Color.blue.opacity(0.15))
            )
            .foregroundStyle(transport == .wireless24G ? Color.purple : Color.blue)
    }

    private var emptyPeripheralsView: some View {
        HStack {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text("暂未检测到已连接的无线外设")
                    .font(.system(size: 13, weight: .medium))
                Text("请插入 2.4G USB 接收器，或在系统蓝牙中连接外设并开启下方蓝牙展示。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(30)
            Spacer()
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.6))
        )
    }

    // MARK: - 偏好设置区域
    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("偏好选项")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                Toggle(isOn: Binding(
                    get: { viewModel.showBluetooth },
                    set: { viewModel.toggleBluetooth($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("展示蓝牙设备电量")
                            .font(.system(size: 13, weight: .medium))
                        Text("除 2.4G 接收器外，同时将系统已连接的标准蓝牙键盘、鼠标同步至小组件")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider().padding(.horizontal, 16)

                Toggle(isOn: Binding(
                    get: { viewModel.autoLaunchEnabled },
                    set: { viewModel.toggleAutoLaunch($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("开机自动启动后台守护")
                            .font(.system(size: 13, weight: .medium))
                        Text("开机登录系统后自动在后台无感运行，保持桌面小组件数据随时鲜活")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )
        }
    }

    // MARK: - 小组件添加引导卡片
    private var widgetTipsCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "macwindow.badge.plus")
                .font(.system(size: 22))
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("如何将电量放到桌面？")
                    .font(.system(size: 12, weight: .semibold))
                Text("右键点击 Mac 桌面空白处 ➔ 选择「编辑小组件」➔ 搜索「外设电量」即可添加。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
        )
    }

    // MARK: - 底部常驻栏
    private var footerView: some View {
        HStack {
            HStack(spacing: 4) {
                Image(systemName: "info.circle")
                Text("关闭窗口后本程序将自动隐形，小组件在后台持续静默同步。")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            Spacer()

            Button(role: .destructive) {
                viewModel.showQuitConfirmAlert = true
            } label: {
                Text("退出服务")
                    .font(.system(size: 12))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func batteryColor(for percentage: Int, isCharging: Bool) -> Color {
        if isCharging { return .green }
        if percentage <= 15 { return .red }
        if percentage <= 35 { return .orange }
        return .green
    }
}
