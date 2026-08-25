import Foundation
import LumosSpikeCore
import ServiceManagement

enum PrivilegedHelperManager {
    private static let approvalPromptKey = "privilegedHelperApprovalPresented.v1"

    static func prepare() {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            PrivilegedPowerRuntime.shared.configure(.legacyAuthorization)
            print("Lumos privileged helper mode=legacy reason=unbundled")
            return
        }

        let plistURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchDaemons", isDirectory: true)
            .appendingPathComponent(LumosPrivilegedService.daemonPlistName)
        guard FileManager.default.fileExists(atPath: plistURL.path) else {
            PrivilegedPowerRuntime.shared.configure(.legacyAuthorization)
            print("Lumos privileged helper mode=legacy reason=missing-plist")
            return
        }

        let service = SMAppService.daemon(plistName: LumosPrivilegedService.daemonPlistName)
        switch service.status {
        case .enabled:
            PrivilegedPowerRuntime.shared.configure(.helper)
            print("Lumos privileged helper mode=helper status=enabled")
        case .notRegistered, .notFound:
            do {
                try service.register()
                configureAfterRegistration(service)
            } catch {
                PrivilegedPowerRuntime.shared.configure(
                    .helperUnavailable("系统控制初始化失败：\(error.localizedDescription)")
                )
                print("Lumos privileged helper status=registration-failed error=\(error)")
            }
        case .requiresApproval:
            PrivilegedPowerRuntime.shared.configure(
                .helperUnavailable("请先在“系统设置 > 通用 > 登录项与扩展”中允许 Lumos。")
            )
            print("Lumos privileged helper status=requires-approval")
            presentApprovalSettingsOnce()
        @unknown default:
            PrivilegedPowerRuntime.shared.configure(
                .helperUnavailable("无法确认 Lumos 系统辅助程序状态。")
            )
            print("Lumos privileged helper status=unknown")
        }
    }

    private static func configureAfterRegistration(_ service: SMAppService) {
        switch service.status {
        case .enabled:
            PrivilegedPowerRuntime.shared.configure(.helper)
            print("Lumos privileged helper mode=helper status=enabled-after-registration")
        case .requiresApproval, .notRegistered:
            PrivilegedPowerRuntime.shared.configure(
                .helperUnavailable("请先在“系统设置 > 通用 > 登录项与扩展”中允许 Lumos。")
            )
            print("Lumos privileged helper status=requires-approval-after-registration")
            presentApprovalSettingsOnce()
        case .notFound:
            PrivilegedPowerRuntime.shared.configure(
                .helperUnavailable("Lumos 系统辅助程序不完整，请重新安装。")
            )
            print("Lumos privileged helper status=not-found-after-registration")
        @unknown default:
            PrivilegedPowerRuntime.shared.configure(
                .helperUnavailable("无法确认 Lumos 系统辅助程序状态。")
            )
            print("Lumos privileged helper status=unknown-after-registration")
        }
    }

    private static func presentApprovalSettingsOnce() {
        guard !UserDefaults.standard.bool(forKey: approvalPromptKey) else { return }
        UserDefaults.standard.set(true, forKey: approvalPromptKey)
        SMAppService.openSystemSettingsLoginItems()
    }
}
