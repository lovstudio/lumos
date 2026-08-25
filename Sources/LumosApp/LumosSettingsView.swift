import AppKit
import SwiftUI

private enum LumosSettingsSection: String, CaseIterable, Identifiable {
    case controls = "控制"
    case profiles = "Profiles"
    case applications = "应用白名单"
    case capabilities = "能力状态"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .controls: "switch.2"
        case .profiles: "slider.horizontal.3"
        case .applications: "app.badge.checkmark"
        case .capabilities: "checkmark.shield"
        }
    }
}

struct LumosSettingsView: View {
    @ObservedObject var model: LumosAppModel
    @State private var selection: LumosSettingsSection = .controls

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
                        Text(model.selectedProfile.name)
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
                case .controls:
                    ControlSettingsView(model: model)
                case .profiles:
                    ProfileSettingsView(model: model)
                case .applications:
                    ApplicationSettingsView(model: model)
                case .capabilities:
                    CapabilitySettingsView(model: model)
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
    @State private var confirmClamshellMode = false

    var body: some View {
        SettingsPage(title: "控制", subtitle: "为当前 Profile 组合原子能力。修改内置方案时，Lumos 会自动创建自定义副本。") {
            SettingsCard(title: "睡眠与显示器") {
                SettingsToggleRow(
                    icon: "moon.zzz.fill",
                    title: "防止空闲休眠",
                    detail: "任务可继续运行，显示器仍可按时熄灭。",
                    isOn: Binding(
                        get: { model.preferences.activeControls.preventSystemIdleSleep },
                        set: { model.setControl(\.preventSystemIdleSleep, to: $0) }
                    )
                )

                SettingsDivider()

                SettingsToggleRow(
                    icon: "display",
                    title: "防止自动锁屏",
                    detail: "保持显示器唤醒；通常比仅守护任务更耗电。",
                    isOn: Binding(
                        get: { model.preferences.activeControls.preventDisplayIdleSleep },
                        set: { model.setControl(\.preventDisplayIdleSleep, to: $0) }
                    )
                )

                SettingsDivider()

                SettingsToggleRow(
                    icon: "laptopcomputer",
                    title: "防止合盖休眠（实验性）",
                    detail: model.clamshellModeText,
                    isOn: Binding(
                        get: { model.preferences.activeControls.requestClamshellProtection },
                        set: { enabled in
                            if enabled {
                                confirmClamshellMode = true
                            } else {
                                model.setClamshellProtection(false)
                            }
                        }
                    )
                )

                if model.preferences.activeControls.requestClamshellProtection {
                    SettingsDivider()

                    SettingsPickerRow(
                        icon: "timer",
                        title: "最长持续时间",
                        detail: "到时后由 root watchdog 自动恢复系统休眠。",
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
                        detail: "使用电池并低于安全线时自动结束合盖模式。",
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
                    detail: model.powerModeText,
                    isOn: Binding(
                        get: { model.lowPowerModeState.isEnabled },
                        set: { model.setLowPowerMode($0) }
                    )
                )
            }

            SettingsCard(title: "立即操作") {
                SettingsActionRow(
                    icon: "display.trianglebadge.exclamationmark",
                    title: "立即关闭显示器",
                    detail: "调用 macOS 自带 pmset；不会让正在守护的任务休眠。",
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
        .confirmationDialog(
            "启用实验性合盖模式？",
            isPresented: $confirmClamshellMode
        ) {
            Button("启用实验性模式") {
                model.setClamshellProtection(true)
            }
            Button("取消", role: .cancel) {}
        } message: {
            let controls = model.preferences.activeControls
            Text("开始守护时需要管理员授权。该设置会阻止所有系统休眠；Lumos 使用独立 watchdog 在退出、异常终止、超时或低电量时恢复。请保持电脑通风。当前系统状态：\(model.clamshellSleepState.detail) 最长 \(controls.clamshellMaximumDurationMinutes) 分钟，电池安全线 \(controls.clamshellBatteryFloorPercent)% 。")
        }
    }
}

private struct ProfileSettingsView: View {
    @ObservedObject var model: LumosAppModel

    var body: some View {
        SettingsPage(title: "Profiles", subtitle: "把原子控制与应用白名单保存为可复用的工作方式。") {
            SettingsCard(title: "当前方案") {
                HStack(spacing: 12) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 28)

                    LumosProfileMenu(model: model, size: .regular)

                    Spacer()

                    Button("复制") { model.duplicateSelectedProfile() }
                    Button("删除", role: .destructive) { model.deleteSelectedProfile() }
                        .disabled(model.selectedProfile.isBuiltIn)
                }
                .padding(14)
            }

            SettingsCard(title: "方案信息") {
                VStack(spacing: 12) {
                    LabeledContent("名称") {
                        TextField("Profile 名称", text: Binding(
                            get: { model.selectedProfile.name },
                            set: { model.renameSelectedProfile($0) }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 290)
                        .disabled(model.selectedProfile.isBuiltIn)
                    }

                    LabeledContent("说明") {
                        TextField("用途说明", text: Binding(
                            get: { model.selectedProfile.summary },
                            set: { model.updateSelectedProfileSummary($0) }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 290)
                        .disabled(model.selectedProfile.isBuiltIn)
                    }
                }
                .padding(14)

                if model.selectedProfile.isBuiltIn {
                    Divider()
                    Label("这是 Lumos 内置预设。修改任意控制或白名单时会自动创建副本。", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(14)
                }
            }

            SettingsCard(title: "组合摘要") {
                VStack(alignment: .leading, spacing: 12) {
                    LabeledContent("场景") {
                        Text(model.selectedProfile.presetKind.title)
                    }
                    LabeledContent("触发") {
                        Text(model.presetTriggerText)
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("退出") {
                        Text(model.presetExitText)
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    HStack(spacing: 8) {
                        CapabilityChip(
                            title: "任务唤醒",
                            enabled: model.preferences.activeControls.preventSystemIdleSleep
                        )
                        CapabilityChip(
                            title: "保持亮屏",
                            enabled: model.preferences.activeControls.preventDisplayIdleSleep
                        )
                        CapabilityChip(
                            title: "低功耗",
                            enabled: model.preferences.activeControls.preferLowPowerMode
                        )
                        CapabilityChip(
                            title: "合盖实验",
                            enabled: model.preferences.activeControls.requestClamshellProtection
                        )
                    }

                    Label(
                        model.targetApplicationCount == 0
                            ? "未限定应用"
                            : "包含 \(model.targetApplicationCount) 个白名单应用",
                        systemImage: "app.badge.checkmark"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                .padding(14)
            }
        }
    }
}

private struct ApplicationSettingsView: View {
    @ObservedObject var model: LumosAppModel
    @State private var searchText = ""

    var body: some View {
        SettingsPage(title: "应用白名单", subtitle: "为“\(model.selectedProfile.name)”选择需要关注的应用。匹配数会显示在主界面。") {
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

            SettingsCard(title: "正在运行") {
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
                "任务守护已使用白名单作为自动触发边界：首个关注应用出现时开始，最后一个退出时释放系统 lease。其他 Preset 不依赖白名单触发。",
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
        SettingsPage(title: "能力状态", subtitle: "Lumos 只把系统真实执行的能力标记为可用。") {
            SettingsCard(title: "直接可用") {
                CapabilityRow(
                    icon: "moon.zzz.fill",
                    title: "防止空闲休眠",
                    detail: "IOKit PreventUserIdleSystemSleep",
                    status: "可用",
                    color: .green
                )
                SettingsDivider()
                CapabilityRow(
                    icon: "display",
                    title: "防止显示器休眠",
                    detail: "IOKit PreventUserIdleDisplaySleep",
                    status: "可用",
                    color: .green
                )
                SettingsDivider()
                CapabilityRow(
                    icon: "thermometer.medium",
                    title: "温度与低功耗状态",
                    detail: "ProcessInfo 事件驱动监听",
                    status: model.thermalText,
                    color: thermalColor
                )
                SettingsDivider()
                CapabilityRow(
                    icon: "battery.75percent",
                    title: "电源与电池",
                    detail: "IOPowerSources 实时回读",
                    status: model.powerSourceState.detail,
                    color: powerSourceColor
                )
                SettingsDivider()
                CapabilityRow(
                    icon: "network",
                    title: "当前网络路径",
                    detail: "NWPathMonitor 持续监听",
                    status: model.networkText,
                    color: model.networkPathState?.status == .satisfied ? .green : .orange
                )
            }

            SettingsCard(title: "受限能力") {
                CapabilityRow(
                    icon: "laptopcomputer",
                    title: "合盖休眠",
                    detail: "pmset disablesleep + 限时安全 watchdog",
                    status: model.clamshellSleepState.isSleepDisabled ? "已开启" : "需授权",
                    color: model.clamshellSleepState.isSleepDisabled ? .green : .orange
                )
                SettingsDivider()
                CapabilityRow(
                    icon: "leaf.fill",
                    title: "切换低功耗模式",
                    detail: "仅修改当前电源来源，执行后真实回读",
                    status: model.lowPowerModeState.isEnabled ? "已开启" : "需授权",
                    color: model.lowPowerModeState.isEnabled ? .green : .orange
                )
                SettingsDivider()
                CapabilityRow(
                    icon: "chart.bar.xaxis",
                    title: "同类产品功耗对比",
                    detail: "尚未完成统一硬件与负载基线采样",
                    status: "待校准",
                    color: .secondary
                )
            }
        }
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
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
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
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            settingsIcon(icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(14)
    }
}

private struct SettingsPickerRow: View {
    let icon: String
    let title: String
    let detail: String
    @Binding var selection: Int
    let options: [Int]
    let valueLabel: (Int) -> String

    var body: some View {
        HStack(spacing: 12) {
            settingsIcon(icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: $selection) {
                ForEach(options, id: \.self) { option in
                    Text(valueLabel(option)).tag(option)
                }
            }
            .labelsHidden()
            .frame(width: 120)
        }
        .padding(14)
    }
}

private struct SettingsActionRow: View {
    let icon: String
    let title: String
    let detail: String
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            settingsIcon(icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(buttonTitle, action: action)
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
        }
        .padding(14)
    }
}

private struct CapabilityChip: View {
    let title: String
    let enabled: Bool

    var body: some View {
        Label(title, systemImage: enabled ? "checkmark.circle.fill" : "minus.circle")
            .font(.caption.weight(.medium))
            .foregroundStyle(enabled ? Color.accentColor : .secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background((enabled ? Color.accentColor : Color.secondary).opacity(0.1))
            .clipShape(Capsule())
    }
}

private struct ApplicationTargetRow: View {
    let application: ApplicationCandidate
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 11) {
            Image(nsImage: applicationIcon)
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

    private var applicationIcon: NSImage {
        guard var path = application.executablePath else {
            return NSWorkspace.shared.icon(for: .application)
        }
        if let range = path.range(of: ".app/") {
            path = String(path[..<range.upperBound].dropLast())
        }
        return NSWorkspace.shared.icon(forFile: path)
    }

    private var applicationProcessDetail: String {
        let count = application.instanceCount == 1
            ? "1 个进程"
            : "\(application.instanceCount) 个进程"
        guard application.unobservableInstanceCount > 0 else { return count }
        return "\(count) · \(application.unobservableInstanceCount) 个身份不可读取"
    }
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
