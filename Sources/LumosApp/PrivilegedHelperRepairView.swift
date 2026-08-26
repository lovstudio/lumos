import SwiftUI

struct PrivilegedHelperRepairView: View {
    @ObservedObject var model: LumosAppModel
    var compact = false

    var body: some View {
        if let presentation {
            HStack(alignment: .top, spacing: compact ? 9 : 11) {
                Image(systemName: presentation.symbol)
                    .font(.system(size: compact ? 14 : 16, weight: .semibold))
                    .foregroundStyle(Color.orange)
                    .frame(width: compact ? 18 : 22)

                VStack(alignment: .leading, spacing: compact ? 5 : 7) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(presentation.title)
                            .font((compact ? Font.caption : .callout).weight(.semibold))
                        Text(presentation.detail)
                            .font(compact ? .caption2 : .caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 10) {
                        if presentation.opensSettings {
                            Button("打开登录项设置") {
                                model.openPrivilegedHelperSettings()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        Button("重新检测") {
                            model.retryPrivilegedHelperConnection()
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(compact ? 9 : 12)
            .background(Color.orange.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.orange.opacity(0.22), lineWidth: 1)
            }
            .help(presentation.diagnostic ?? presentation.detail)
            .accessibilityElement(children: .contain)
        }
    }

    private var presentation: Presentation? {
        switch model.privilegedHelperRepairState {
        case .hidden, .checking:
            nil
        case .approvalRequired:
            Presentation(
                symbol: "lock.trianglebadge.exclamationmark.fill",
                title: "系统辅助程序需要授权",
                detail: "低功耗与合盖控制需要允许 Lumos 在后台运行。",
                diagnostic: nil,
                opensSettings: true
            )
        case .restartRequired(let diagnostic):
            Presentation(
                symbol: "arrow.triangle.2.circlepath",
                title: "需要重新启用辅助程序",
                detail: "升级后旧版辅助程序可能仍在运行。请在登录项设置中将 LumosPrivilegedHelper 关闭后重新打开。",
                diagnostic: diagnostic,
                opensSettings: true
            )
        case .unavailable(let message):
            Presentation(
                symbol: "exclamationmark.triangle.fill",
                title: "系统控制暂不可用",
                detail: message,
                diagnostic: message,
                opensSettings: false
            )
        }
    }
}

private extension PrivilegedHelperRepairView {
    struct Presentation {
        let symbol: String
        let title: String
        let detail: String
        let diagnostic: String?
        let opensSettings: Bool
    }
}
