import AppKit
import SwiftUI

struct LumosMenuView: View {
    @ObservedObject var model: LumosAppModel
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            hero
            guardedApplicationsSection
            basicControls

            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }

            effectSummary
            footer
        }
        .padding(18)
        .frame(width: 390)
    }

    private var hero: some View {
        HStack(spacing: 13) {
            ZStack {
                Circle()
                    .fill(model.isGuardEnabled ? Color.accentColor : Color.secondary.opacity(0.12))
                Image(systemName: model.isGuardActive ? "lightbulb.fill" : "lightbulb")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(model.isGuardEnabled ? .white : .secondary)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text("Lumos")
                        .font(.system(size: 16, weight: .semibold))
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                }
                Text(model.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
    }

    private var basicControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("控制")

            VStack(spacing: 0) {
                LumosToggleRow(
                    icon: "moon.zzz.fill",
                    title: "保持任务运行",
                    info: LumosFeatureInfoCatalog.keepTaskRunning,
                    isOn: Binding(
                        get: { model.preferences.activeControls.preventSystemIdleSleep },
                        set: { model.setControl(\.preventSystemIdleSleep, to: $0) }
                    )
                )

                Divider().padding(.leading, 43)

                LumosToggleRow(
                    icon: "display",
                    title: "保持屏幕唤醒",
                    info: LumosFeatureInfoCatalog.keepDisplayAwake,
                    isOn: Binding(
                        get: { model.preferences.activeControls.preventDisplayIdleSleep },
                        set: { model.setControl(\.preventDisplayIdleSleep, to: $0) }
                    )
                )

                Divider().padding(.leading, 43)

                LumosToggleRow(
                    icon: "laptopcomputer",
                    title: "合盖时保持运行",
                    info: LumosFeatureInfoCatalog.clamshellProtection,
                    isOn: Binding(
                        get: { model.isClamshellControlPresentedOn },
                        set: { model.setClamshellProtection($0) }
                    )
                )

                Divider().padding(.leading, 43)

                LumosToggleRow(
                    icon: "leaf.fill",
                    title: "低功耗模式",
                    info: LumosFeatureInfoCatalog.lowPowerMode,
                    isOn: Binding(
                        get: { model.lowPowerModeState.isEnabled },
                        set: { model.setLowPowerMode($0) }
                    )
                )
            }
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            }
        }
    }

    private var guardedApplicationsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel("正在守护")
                Spacer()
                Button("管理", action: openSettings)
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                LumosInfoButton(info: LumosFeatureInfoCatalog.guardedApplications)
            }

            VStack(spacing: 0) {
                if model.guardedApplications.isEmpty {
                    Button(action: openSettings) {
                        HStack(spacing: 10) {
                            Image(systemName: "plus.app.fill")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 23)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("选择需要守护的 App")
                                    .font(.callout.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text("App 运行时自动防止系统休眠")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                } else {
                    ForEach(Array(model.guardedApplications.prefix(2).enumerated()), id: \.element.id) { index, application in
                        MenuGuardedApplicationRow(
                            application: application,
                            isGuardActive: model.isGuardActive
                        )
                        if index < min(model.guardedApplications.count, 2) - 1 {
                            Divider().padding(.leading, 45)
                        }
                    }

                    if model.guardedApplications.count > 2 {
                        Divider().padding(.leading, 45)
                        Button("还有 \(model.guardedApplications.count - 2) 个 App", action: openSettings)
                            .buttonStyle(.plain)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                            .padding(.leading, 45)
                            .padding(.vertical, 9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            }
        }
    }

    private var effectSummary: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                sectionLabel("守护状态")
                Spacer()
                LumosInfoButton(info: LumosFeatureInfoCatalog.guardStatus)
            }

            Group {
                if model.isGuardEnabled {
                    HStack(spacing: 0) {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            metric(
                                value: elapsedText(at: context.date),
                                label: "守护时长"
                            )
                        }

                        Divider().frame(height: 31)

                        metric(
                            value: "\(model.matchedProcessCount)",
                            label: "运行中目标"
                        )

                        Divider().frame(height: 31)

                        metric(
                            value: "暂无基准",
                            label: "能耗变化"
                        )
                    }
                    .padding(.vertical, 11)
                } else {
                    Text("开启上方功能后，将显示运行时长、运行中目标和能耗变化。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 14)
                }
            }
            .background(Color.accentColor.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            HStack(spacing: 5) {
                Image(systemName: safetySymbol)
                Text(model.systemStatusText)
            }
            .font(.caption2)
            .foregroundStyle(safetyColor)
            .padding(.horizontal, 2)
        }
    }

    private var footer: some View {
        HStack {
            Button(action: openSettings) {
                Label("设置", systemImage: "gearshape")
            }
            .keyboardShortcut(",")

            Spacer()

            Button("退出 Lumos") {
                NSApplication.shared.terminate(nil)
            }
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .tracking(0.6)
            .padding(.horizontal, 2)
    }

    private func metric(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var statusColor: Color {
        switch model.safetyDecision.severity {
        case .critical: .red
        case .degraded: .orange
        case .efficient: model.isGuardEnabled ? .yellow : .secondary.opacity(0.5)
        case .normal: model.isGuardActive ? .green : (model.isGuardEnabled ? .yellow : .secondary.opacity(0.5))
        }
    }

    private var safetyColor: Color {
        switch model.safetyDecision.severity {
        case .critical: .red
        case .degraded: .orange
        case .efficient, .normal: .secondary
        }
    }

    private var safetySymbol: String {
        switch model.safetyDecision.severity {
        case .critical: "exclamationmark.triangle.fill"
        case .degraded: "exclamationmark.circle.fill"
        case .efficient: "leaf.fill"
        case .normal: "checkmark.circle.fill"
        }
    }

    private func elapsedText(at date: Date) -> String {
        guard let start = model.guardStartedAt else { return "—" }
        let total = max(Int(date.timeIntervalSince(start)), 0)
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

}

private struct MenuGuardedApplicationRow: View {
    let application: GuardedApplicationState
    let isGuardActive: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: applicationIcon)
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)

            Text(application.displayName)
                .font(.callout.weight(.medium))
                .lineLimit(1)

            Spacer(minLength: 10)

            HStack(spacing: 5) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                Text(statusText)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var statusText: String {
        if application.isRunning, isGuardActive {
            return application.instanceCount > 1
                ? "守护中 · \(application.instanceCount)"
                : "守护中"
        }
        return application.isRunning ? "运行中" : "等待启动"
    }

    private var statusColor: Color {
        if application.isRunning, isGuardActive { return .green }
        if application.isRunning { return .yellow }
        return .secondary.opacity(0.5)
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
}

private struct LumosToggleRow: View {
    let icon: String
    let title: String
    let info: LumosFeatureInfo
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            rowIcon(icon)
            Text(title).font(.callout.weight(.medium))
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            LumosInfoButton(info: info)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
    }
}

@ViewBuilder
private func rowIcon(_ name: String) -> some View {
    Image(systemName: name)
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(Color.accentColor)
        .frame(width: 23)
}
