import ServiceManagement

enum LaunchAtLoginStatus: Equatable {
    case disabled
    case enabled
    case requiresApproval
    case unavailable
}

struct LaunchAtLoginSnapshot: Equatable {
    let status: LaunchAtLoginStatus

    var isRegistered: Bool {
        status == .enabled || status == .requiresApproval
    }

    var detail: String {
        switch status {
        case .disabled:
            "登录后不会自动启动"
        case .enabled:
            "登录后自动在菜单栏启动"
        case .requiresApproval:
            "已登记，等待在系统设置中允许"
        case .unavailable:
            "仅正式安装的 Lumos 可配置"
        }
    }
}

enum LaunchAtLoginUpdateState: Equatable {
    case updated
    case unchanged
    case requiresApproval
    case unavailable
    case failed
}

struct LaunchAtLoginUpdate: Equatable {
    let state: LaunchAtLoginUpdateState
    let snapshot: LaunchAtLoginSnapshot
    let message: String?
}

@MainActor
final class LaunchAtLoginController {
    private let service: SMAppService

    init(service: SMAppService = .mainApp) {
        self.service = service
    }

    func snapshot() -> LaunchAtLoginSnapshot {
        LaunchAtLoginSnapshot(status: status(for: service.status))
    }

    func setEnabled(_ enabled: Bool) -> LaunchAtLoginUpdate {
        let previous = snapshot()

        if enabled {
            switch previous.status {
            case .enabled:
                return LaunchAtLoginUpdate(
                    state: .unchanged,
                    snapshot: previous,
                    message: nil
                )
            case .requiresApproval:
                return approvalRequiredUpdate(snapshot: previous)
            case .unavailable:
                break
            case .disabled:
                break
            }
        } else {
            switch previous.status {
            case .disabled:
                return LaunchAtLoginUpdate(
                    state: .unchanged,
                    snapshot: previous,
                    message: nil
                )
            case .unavailable:
                return unavailableUpdate(snapshot: previous)
            case .enabled, .requiresApproval:
                break
            }
        }

        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            return LaunchAtLoginUpdate(
                state: .failed,
                snapshot: snapshot(),
                message: "无法更新登录时启动：\(error.localizedDescription)"
            )
        }

        let current = snapshot()
        if current.status == .requiresApproval {
            return approvalRequiredUpdate(snapshot: current)
        }
        if current.status == .unavailable {
            return unavailableUpdate(snapshot: current)
        }

        let reachedRequestedState = enabled
            ? current.status == .enabled
            : current.status == .disabled
        return LaunchAtLoginUpdate(
            state: reachedRequestedState ? .updated : .failed,
            snapshot: current,
            message: reachedRequestedState
                ? nil
                : "macOS 没有应用新的登录项状态，请稍后重试。"
        )
    }

    private func status(for status: SMAppService.Status) -> LaunchAtLoginStatus {
        switch status {
        case .notRegistered:
            .disabled
        case .enabled:
            .enabled
        case .requiresApproval:
            .requiresApproval
        case .notFound:
            .unavailable
        @unknown default:
            .unavailable
        }
    }

    private func approvalRequiredUpdate(
        snapshot: LaunchAtLoginSnapshot
    ) -> LaunchAtLoginUpdate {
        LaunchAtLoginUpdate(
            state: .requiresApproval,
            snapshot: snapshot,
            message: "Lumos 已登记为登录项，但 macOS 仍在等待你在“系统设置 > 通用 > 登录项与扩展”中允许。"
        )
    }

    private func unavailableUpdate(
        snapshot: LaunchAtLoginSnapshot
    ) -> LaunchAtLoginUpdate {
        LaunchAtLoginUpdate(
            state: .unavailable,
            snapshot: snapshot,
            message: "登录时启动只能由放在“应用程序”文件夹中的正式 Lumos 配置。"
        )
    }
}
