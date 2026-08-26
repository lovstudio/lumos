import AppKit
import SwiftUI

private enum LumosSettingsSection: String, CaseIterable, Identifiable {
    case applications = "守护 App"
    case controls = "控制"
    case capabilities = "能力状态"
    case about = "关于"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .applications: "app.badge.checkmark"
        case .controls: "switch.2"
        case .capabilities: "checkmark.shield"
        case .about: "info.circle"
        }
    }
}

struct LumosSettingsView: View {
    @ObservedObject var model: LumosAppModel
    @State private var selection: LumosSettingsSection = .applications

    var body: some View {
        NavigationSplitView {
            List(LumosSettingsSection.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.icon)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 210)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 8) {
                    Image(systemName: model.isGuardActive ? "lightbulb.fill" : "lightbulb")
                        .foregroundStyle(model.isGuardEnabled ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.statusText)
                            .font(.caption.weight(.medium))
                        Text("守护 \(model.targetApplicationCount) 个 App · 运行中 \(model.matchedProcessCount) 个进程")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(12)
            }
        } detail: {
            Group {
                switch selection {
                case .applications:
                    ApplicationSettingsView(model: model)
                case .controls:
                    ControlSettingsView(model: model)
                case .capabilities:
                    CapabilitySettingsView(model: model)
                case .about:
                    AboutSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 760, idealWidth: 820, minHeight: 520, idealHeight: 580)
    }
}

private struct ControlSettingsView: View {
    @ObservedObject var model: LumosAppModel
    @State private var confirmDisplaySleep = false

    var body: some View {
        SettingsPage(title: "控制", subtitle: "直接设置 Lumos 当前使用的守护能力，修改后立即生效。") {
            SettingsCard(title: "启动") {
                SettingsToggleRow(
                    icon: "power",
                    title: "登录时自动启动",
                    detail: model.launchAtLoginState.detail,
                    info: LumosFeatureInfoCatalog.launchAtLogin,
                    isOn: Binding(
                        get: { model.isLaunchAtLoginPresentedOn },
                        set: { model.setLaunchAtLogin($0) }
                    )
                )
            }

            SettingsCard(title: "睡眠与显示器") {
                SettingsToggleRow(
                    icon: "moon.zzz.fill",
                    title: "保持任务运行",
                    info: LumosFeatureInfoCatalog.keepTaskRunning,
                    isOn: Binding(
                        get: { model.preferences.activeControls.preventSystemIdleSleep },
                        set: { model.setControl(\.preventSystemIdleSleep, to: $0) }
                    )
                )

                SettingsDivider()

                SettingsToggleRow(
                    icon: "display",
                    title: "保持屏幕唤醒",
                    info: LumosFeatureInfoCatalog.keepDisplayAwake,
                    isOn: Binding(
                        get: { model.preferences.activeControls.preventDisplayIdleSleep },
                        set: { model.setControl(\.preventDisplayIdleSleep, to: $0) }
                    )
                )

                SettingsDivider()

                SettingsToggleRow(
                    icon: "laptopcomputer",
                    title: "合盖时保持运行",
                    info: LumosFeatureInfoCatalog.clamshellProtection,
                    isOn: Binding(
                        get: { model.isClamshellControlPresentedOn },
                        set: { model.setClamshellProtection($0) }
                    )
                )

                if model.preferences.activeControls.requestClamshellProtection {
                    SettingsDivider()

                    SettingsPickerRow(
                        icon: "timer",
                        title: "最长持续时间",
                        info: LumosFeatureInfoCatalog.clamshellDuration,
                        selection: Binding(
                            get: { model.preferences.activeControls.clamshellMaximumDurationMinutes },
                            set: { model.setClamshellMaximumDuration($0) }
                        ),
                        options: [30, 60, 120, 240, 480],
                        valueLabel: { "\($0) 分钟" }
                    )

                    SettingsDivider()

                    SettingsPickerRow(
                        icon: "battery.25percent",
                        title: "电池安全线",
                        info: LumosFeatureInfoCatalog.batteryFloor,
                        selection: Binding(
                            get: { model.preferences.activeControls.clamshellBatteryFloorPercent },
                            set: { model.setClamshellBatteryFloor($0) }
                        ),
                        options: [10, 15, 20, 25, 30, 40, 50],
                        valueLabel: { "\($0)%" }
                    )
                }
            }

            SettingsCard(title: "能效") {
                SettingsToggleRow(
                    icon: "leaf.fill",
                    title: "低功耗模式",
                    info: LumosFeatureInfoCatalog.lowPowerMode,
                    isOn: Binding(
                        get: { model.lowPowerModeState.isEnabled },
                        set: { model.setLowPowerMode($0) }
                    )
                )

                if model.privilegedHelperRepairState.isPresented {
                    SettingsDivider()
                    PrivilegedHelperRepairView(model: model)
                        .padding(12)
                }
            }

            SettingsCard(title: "立即操作") {
                SettingsActionRow(
                    icon: "display.trianglebadge.exclamationmark",
                    title: "立即关闭显示器",
                    info: LumosFeatureInfoCatalog.displaySleepNow,
                    buttonTitle: "立即关闭"
                ) {
                    confirmDisplaySleep = true
                }
            }
        }
        .confirmationDialog(
            "现在关闭显示器？",
            isPresented: $confirmDisplaySleep
        ) {
            Button("关闭显示器") { model.sleepDisplayNow() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("移动鼠标或按下键盘即可再次点亮。")
        }
    }
}

private struct ApplicationSettingsView: View {
    @ObservedObject var model: LumosAppModel
    @State private var searchText = ""

    var body: some View {
        SettingsPage(title: "守护 App", subtitle: "直接选择不能因 Mac 休眠而中断的 App。守护状态会同步显示在主面板。") {
            SettingsCard(
                title: "正在守护",
                info: LumosFeatureInfoCatalog.guardedApplications
            ) {
                if model.guardedApplications.isEmpty {
                    HStack(spacing: 12) {
                        settingsIcon("app.badge.checkmark", color: .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("还没有守护 App")
                                .font(.callout.weight(.medium))
                            Text("从下方正在运行的 App 中选择")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(14)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.guardedApplications.enumerated()), id: \.element.id) { index, application in
                            GuardedApplicationSettingsRow(application: application) {
                                model.removeApplicationTarget(application.id)
                            }
                            if index != model.guardedApplications.count - 1 {
                                Divider().padding(.leading, 54)
                            }
                        }
                    }
                }
            }

            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索正在运行的应用", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            SettingsCard(
                title: "添加正在运行的 App",
                info: LumosFeatureInfoCatalog.addGuardedApplication
            ) {
                if filteredApplications.isEmpty {
                    ContentUnavailableView(
                        "没有匹配的应用",
                        systemImage: "app.dashed",
                        description: Text("打开应用后，它会自动出现在这里。")
                    )
                    .frame(height: 210)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filteredApplications.enumerated()), id: \.element.id) { index, application in
                            ApplicationTargetRow(
                                application: application,
                                isOn: Binding(
                                    get: { model.isApplicationTargeted(application.id) },
                                    set: { model.setApplicationTarget(application, enabled: $0) }
                                )
                            )
                            if index != filteredApplications.count - 1 {
                                Divider().padding(.leading, 54)
                            }
                        }
                    }
                }
            }

            Label(
                model.targetApplicationCount == 0
                    ? "没有指定 App 时，开启控制后立即生效，直到你手动关闭。"
                    : "首个守护 App 开始运行时自动生效，最后一个退出后自动停止。",
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { model.refreshRunningApplications() }
    }

    private var filteredApplications: [ApplicationCandidate] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.runningApplications }
        return model.runningApplications.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.id.localizedCaseInsensitiveContains(query)
        }
    }
}

private struct CapabilitySettingsView: View {
    @ObservedObject var model: LumosAppModel

    var body: some View {
        SettingsPage(title: "能力状态", subtitle: "查看 Lumos 当前可用的系统能力，以及需要授权或尚未就绪的功能。") {
            SettingsCard(title: "直接可用") {
                CapabilityRow(
                    icon: "moon.zzz.fill",
                    title: "防止空闲休眠",
                    detail: "让任务持续运行，屏幕仍可按时熄灭",
                    status: "可用",
                    color: .green,
                    info: LumosFeatureInfoCatalog.keepTaskRunning
                )
                SettingsDivider()
                CapabilityRow(
                    icon: "display",
                    title: "保持屏幕唤醒",
                    detail: "防止屏幕因闲置自动熄灭",
                    status: "可用",
                    color: .green,
                    info: LumosFeatureInfoCatalog.keepDisplayAwake
                )
                SettingsDivider()
                CapabilityRow(
                    icon: "thermometer.medium",
                    title: "温度与低功耗状态",
                    detail: "持续关注系统温度与节能状态",
                    status: model.thermalText,
                    color: thermalColor,
                    info: LumosFeatureInfoCatalog.thermalState
                )
                SettingsDivider()
                CapabilityRow(
                    icon: "battery.75percent",
                    title: "电源与电池",
                    detail: "实时读取供电方式与电池电量",
                    status: model.powerSourceState.detail,
                    color: powerSourceColor,
                    info: LumosFeatureInfoCatalog.powerSource
                )
                SettingsDivider()
                CapabilityRow(
                    icon: "network",
                    title: "网络状态",
                    detail: "持续关注网络是否可用或受限",
                    status: model.networkText,
                    color: model.networkPathState?.status == .satisfied ? .green : .orange,
                    info: LumosFeatureInfoCatalog.networkState
                )
            }

            SettingsCard(title: "需要授权或尚未就绪") {
                CapabilityRow(
                    icon: "laptopcomputer",
                    title: "合盖时保持运行",
                    detail: clamshellCapabilityDetail,
                    status: clamshellCapabilityStatus,
                    color: clamshellCapabilityColor,
                    info: LumosFeatureInfoCatalog.clamshellProtection
                )
                SettingsDivider()
                CapabilityRow(
                    icon: "leaf.fill",
                    title: "切换低功耗模式",
                    detail: "仅调整当前使用的电源来源；切换时需要管理员授权",
                    status: lowPowerCapabilityStatus,
                    color: lowPowerCapabilityColor,
                    info: LumosFeatureInfoCatalog.lowPowerMode
                )
                SettingsDivider()
                CapabilityRow(
                    icon: "chart.bar.xaxis",
                    title: "能耗对比",
                    detail: "尚未完成同一设备、同一负载下的基准采样",
                    status: "暂无基准",
                    color: .secondary,
                    info: LumosFeatureInfoCatalog.energyComparison
                )
            }
        }
    }

    private var clamshellCapabilityStatus: String {
        model.clamshellSleepState.isSleepDisabled ? "已开启" : "未开启"
    }

    private var clamshellCapabilityDetail: String {
        model.clamshellSleepState.isSleepDisabled
            ? "合盖后任务继续运行"
            : "合盖后电脑正常休眠"
    }

    private var clamshellCapabilityColor: Color {
        guard model.clamshellSleepState.isSleepDisabled else { return .secondary }
        return model.clamshellSleepState.ownership == .lumos ? .green : .orange
    }

    private var lowPowerCapabilityStatus: String {
        guard model.lowPowerModeState.isAvailable else { return "不可用" }
        return model.lowPowerModeState.isEnabled ? "已开启" : "已关闭"
    }

    private var lowPowerCapabilityColor: Color {
        guard model.lowPowerModeState.isAvailable else { return .orange }
        return model.lowPowerModeState.isEnabled ? .green : .secondary
    }

    private var thermalColor: Color {
        switch model.systemState.thermalState {
        case .critical: .red
        case .serious, .unknown: .orange
        case .fair: .yellow
        case .nominal: .green
        }
    }

    private var powerSourceColor: Color {
        guard model.powerSourceState.isAvailable else { return .orange }
        if model.safetyDecision.conditions.contains(.batteryAtOrBelowFloor)
            || model.safetyDecision.conditions.contains(.batteryLevelUnknown) {
            return .orange
        }
        return .green
    }
}

private struct AboutSettingsView: View {
    private let website = URL(string: "https://lumos.lovstudio.ai")!

    var body: some View {
        SettingsPage(
            title: "关于 Lumos",
            subtitle: "产品版本、设计理念与品牌信息。"
        ) {
            VStack(spacing: 11) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor)
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 72, height: 72)

                VStack(spacing: 4) {
                    Text("Lumos")
                        .font(.system(size: 26, weight: .bold))
                    Text("为未完成的事情，留一盏灯。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(versionText)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity)

            SettingsCard(title: "产品信息") {
                AboutInfoRow(
                    icon: "shippingbox.fill",
                    title: "Bundle ID",
                    value: "ai.lovstudio.lumos"
                )

                SettingsDivider()

                AboutInfoRow(
                    icon: "bolt.heart.fill",
                    title: "产品理念",
                    value: "不让任务睡着，也不让电脑白白醒着。"
                )
            }

            SettingsCard(title: "品牌") {
                AboutInfoRow(
                    icon: "hammer.fill",
                    title: "设计与开发",
                    value: "手工川工作室 · LovStudio"
                )

                SettingsDivider()

                Link(destination: website) {
                    HStack(spacing: 12) {
                        settingsIcon("globe")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("官方网站")
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.primary)
                            Text("了解手工川工作室与更多 LovStudio 产品")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("lumos.lovstudio.ai")
                            .font(.callout)
                            .foregroundStyle(Color.accentColor)
                        Image(systemName: "arrow.up.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    .padding(14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Text("© 2026 手工川工作室 · LovStudio")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.top, 2)
        }
    }

    private var versionText: String {
        let dictionary = Bundle.main.infoDictionary
        guard let version = dictionary?["CFBundleShortVersionString"] as? String,
              !version.isEmpty else {
            return "开发预览版"
        }

        guard let build = dictionary?["CFBundleVersion"] as? String,
              !build.isEmpty,
              build != version else {
            return "版本 \(version)"
        }
        return "版本 \(version)（\(build)）"
    }
}

private struct AboutInfoRow: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 12) {
            settingsIcon(icon)
            Text(title)
                .font(.callout.weight(.medium))
            Spacer(minLength: 18)
            Text(value)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .padding(14)
    }
}

private struct SettingsPage<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 24, weight: .bold))
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                content
            }
            .padding(24)
            .frame(maxWidth: 650, alignment: .leading)
        }
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let info: LumosFeatureInfo?
    @ViewBuilder let content: Content

    init(
        title: String,
        info: LumosFeatureInfo? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.info = info
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let info {
                    LumosInfoButton(info: info)
                }
            }
            .padding(.horizontal, 4)
            VStack(spacing: 0) { content }
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.78))
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                }
        }
    }
}

private struct SettingsToggleRow: View {
    let icon: String
    let title: String
    let detail: String?
    let info: LumosFeatureInfo
    @Binding var isOn: Bool

    init(
        icon: String,
        title: String,
        detail: String? = nil,
        info: LumosFeatureInfo,
        isOn: Binding<Bool>
    ) {
        self.icon = icon
        self.title = title
        self.detail = detail
        self.info = info
        self._isOn = isOn
    }

    var body: some View {
        HStack(spacing: 12) {
            settingsIcon(icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(title)
            LumosInfoButton(info: info)
        }
        .padding(14)
    }
}

private struct SettingsPickerRow: View {
    let icon: String
    let title: String
    let info: LumosFeatureInfo
    @Binding var selection: Int
    let options: [Int]
    let valueLabel: (Int) -> String

    var body: some View {
        HStack(spacing: 12) {
            settingsIcon(icon)
            Text(title).font(.callout.weight(.medium))
            Spacer()
            Picker("", selection: $selection) {
                ForEach(options, id: \.self) { option in
                    Text(valueLabel(option)).tag(option)
                }
            }
            .labelsHidden()
            .frame(width: 120)
            LumosInfoButton(info: info)
        }
        .padding(14)
    }
}

private struct SettingsActionRow: View {
    let icon: String
    let title: String
    let info: LumosFeatureInfo
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            settingsIcon(icon)
            Text(title).font(.callout.weight(.medium))
            Spacer()
            Button(buttonTitle, action: action)
            LumosInfoButton(info: info)
        }
        .padding(14)
    }
}

private struct CapabilityRow: View {
    let icon: String
    let title: String
    let detail: String
    let status: String
    let color: Color
    let info: LumosFeatureInfo

    var body: some View {
        HStack(spacing: 12) {
            settingsIcon(icon, color: color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(status)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
            LumosInfoButton(info: info)
        }
        .padding(14)
    }
}

private struct GuardedApplicationSettingsRow: View {
    let application: GuardedApplicationState
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            Image(nsImage: applicationIcon(for: application.executablePath))
                .resizable()
                .scaledToFit()
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(application.displayName)
                    .font(.callout.weight(.medium))
                HStack(spacing: 5) {
                    Circle()
                        .fill(application.isRunning ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 6, height: 6)
                    Text(application.isRunning ? runningDetail : "未运行 · 等待启动")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button("移除", role: .destructive, action: remove)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var runningDetail: String {
        application.instanceCount == 1
            ? "运行中 · 1 个进程"
            : "运行中 · \(application.instanceCount) 个进程"
    }
}

private struct ApplicationTargetRow: View {
    let application: ApplicationCandidate
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 11) {
            Image(nsImage: applicationIcon(for: application.executablePath))
                .resizable()
                .scaledToFit()
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(application.displayName)
                    .font(.callout.weight(.medium))
                Text(applicationProcessDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var applicationProcessDetail: String {
        let count = application.instanceCount == 1
            ? "1 个进程"
            : "\(application.instanceCount) 个进程"
        guard application.unobservableInstanceCount > 0 else { return count }
        return "\(count) · \(application.unobservableInstanceCount) 个身份不可读取"
    }
}

private func applicationIcon(for executablePath: String?) -> NSImage {
    guard var path = executablePath else {
        return NSWorkspace.shared.icon(for: .application)
    }
    if let range = path.range(of: ".app/") {
        path = String(path[..<range.upperBound].dropLast())
    }
    return NSWorkspace.shared.icon(forFile: path)
}

private struct SettingsDivider: View {
    var body: some View {
        Divider().padding(.leading, 54)
    }
}

@ViewBuilder
private func settingsIcon(_ name: String, color: Color = .accentColor) -> some View {
    ZStack {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(color.opacity(0.12))
        Image(systemName: name)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(color)
    }
    .frame(width: 30, height: 30)
}
