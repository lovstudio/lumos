import AppKit
import SwiftUI

struct LumosMenuView: View {
    @ObservedObject var model: LumosAppModel
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            hero
            basicControls
            profileSection

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
                    .fill(model.isGuardActive ? Color.accentColor : Color.secondary.opacity(0.12))
                Image(systemName: model.isGuardActive ? "lightbulb.fill" : "lightbulb")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(model.isGuardActive ? .white : .secondary)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text("Lumos")
                        .font(.system(size: 16, weight: .semibold))
                    Circle()
                        .fill(model.isGuardActive ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 7, height: 7)
                }
                Text(model.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button(model.isGuardActive ? "停止" : "开始") {
                model.toggleGuard()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(model.isGuardActive ? .red : .accentColor)
        }
    }

    private var basicControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("基本")

            VStack(spacing: 0) {
                LumosToggleRow(
                    icon: "display",
                    title: "防止自动锁屏",
                    detail: "保持显示器唤醒",
                    isOn: Binding(
                        get: { model.preferences.activeControls.preventDisplayIdleSleep },
                        set: { model.setControl(\.preventDisplayIdleSleep, to: $0) }
                    )
                )

                Divider().padding(.leading, 43)

                LumosUnavailableRow(
                    icon: "laptopcomputer",
                    title: "防止合盖休眠",
                    detail: "macOS 公共接口暂不支持",
                    badge: "不可用"
                )

                Divider().padding(.leading, 43)

                LumosActionRow(
                    icon: "leaf.fill",
                    title: "低功耗模式",
                    detail: model.powerModeText,
                    value: "设置",
                    action: openBatterySettings
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

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("高级")

            HStack(spacing: 11) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Profile")
                        .font(.callout.weight(.medium))
                    Text(profileTargetSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Picker("", selection: Binding(
                    get: { model.preferences.selectedProfileID },
                    set: { model.selectProfile(id: $0) }
                )) {
                    ForEach(model.preferences.profiles) { profile in
                        Text(profile.name).tag(profile.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 150)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var effectSummary: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionLabel("本次效果")

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
                    label: "匹配进程"
                )

                Divider().frame(height: 31)

                metric(
                    value: "待校准",
                    label: "功耗对比"
                )
            }
            .padding(.vertical, 11)
            .background(Color.accentColor.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            HStack(spacing: 5) {
                Image(systemName: "thermometer.medium")
                Text(model.thermalText)
                Text("·")
                Text("功耗数据将在真实采样后显示")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 2)
        }
    }

    private var footer: some View {
        HStack {
            Button(action: openSettings) {
                Label("设置…", systemImage: "gearshape")
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

    private var profileTargetSummary: String {
        if model.targetApplicationCount == 0 {
            return "\(model.selectedProfile.name) · 未限定应用"
        }
        return "\(model.selectedProfile.name) · \(model.targetApplicationCount) 个应用"
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

    private func openBatterySettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Battery-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.energysaver"
        ]
        for address in candidates {
            if let url = URL(string: address), NSWorkspace.shared.open(url) {
                break
            }
        }
    }
}

private struct LumosToggleRow: View {
    let icon: String
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            rowIcon(icon)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

private struct LumosUnavailableRow: View {
    let icon: String
    let title: String
    let detail: String
    let badge: String

    var body: some View {
        HStack(spacing: 10) {
            rowIcon(icon)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(badge)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.secondary.opacity(0.1))
                .clipShape(Capsule())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

private struct LumosActionRow: View {
    let icon: String
    let title: String
    let detail: String
    let value: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            rowIcon(icon)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(value, action: action)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

@ViewBuilder
private func rowIcon(_ name: String) -> some View {
    Image(systemName: name)
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(Color.accentColor)
        .frame(width: 23)
}
