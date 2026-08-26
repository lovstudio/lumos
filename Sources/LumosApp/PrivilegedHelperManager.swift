import Foundation
import LumosSpikeCore
import ServiceManagement

enum PrivilegedHelperManager {
    static func prepare(presentApprovalSettings: Bool = true) {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            PrivilegedPowerRuntime.shared.configure(.legacyAuthorization)
            print("Lumos privileged helper mode=legacy reason=unbundled")
            return
        }

        guard let configuration = LumosPrivilegedService.configuration(
            forHostBundleIdentifier: Bundle.main.bundleIdentifier
        ) else {
            PrivilegedPowerRuntime.shared.configure(.legacyAuthorization)
            print("Lumos privileged helper mode=legacy reason=unknown-bundle")
            return
        }

        let plistURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchDaemons", isDirectory: true)
            .appendingPathComponent(configuration.daemonPlistName)
        guard FileManager.default.fileExists(atPath: plistURL.path) else {
            PrivilegedPowerRuntime.shared.configure(.helperUnavailable(.incompleteInstallation))
            print("Lumos privileged helper status=missing-plist")
            return
        }

        let service = SMAppService.daemon(plistName: configuration.daemonPlistName)
        switch service.status {
        case .enabled:
            configureHelper(configuration, status: "enabled")
        case .notRegistered, .notFound:
            do {
                try service.register()
                configureAfterRegistration(
                    service,
                    configuration: configuration,
                    presentApprovalSettings: presentApprovalSettings
                )
            } catch {
                if service.status == .requiresApproval {
                    configureApprovalRequired(
                        configuration: configuration,
                        status: "requires-approval-after-registration",
                        presentApprovalSettings: presentApprovalSettings
                    )
                } else {
                    PrivilegedPowerRuntime.shared.configure(
                        .helperUnavailable(.registrationFailed(error.localizedDescription))
                    )
                    print("Lumos privileged helper status=registration-failed error=\(error)")
                }
            }
        case .requiresApproval:
            configureApprovalRequired(
                configuration: configuration,
                status: "requires-approval",
                presentApprovalSettings: presentApprovalSettings
            )
        @unknown default:
            PrivilegedPowerRuntime.shared.configure(
                .helperUnavailable(.unknownStatus)
            )
            print("Lumos privileged helper status=unknown")
        }
    }

    private static func configureAfterRegistration(
        _ service: SMAppService,
        configuration: LumosPrivilegedServiceConfiguration,
        presentApprovalSettings: Bool
    ) {
        switch service.status {
        case .enabled:
            configureHelper(configuration, status: "enabled-after-registration")
        case .requiresApproval, .notRegistered:
            configureApprovalRequired(
                configuration: configuration,
                status: "requires-approval-after-registration",
                presentApprovalSettings: presentApprovalSettings
            )
        case .notFound:
            PrivilegedPowerRuntime.shared.configure(
                .helperUnavailable(.incompleteInstallation)
            )
            print("Lumos privileged helper status=not-found-after-registration")
        @unknown default:
            PrivilegedPowerRuntime.shared.configure(
                .helperUnavailable(.unknownStatus)
            )
            print("Lumos privileged helper status=unknown-after-registration")
        }
    }

    private static func configureHelper(
        _ configuration: LumosPrivilegedServiceConfiguration,
        status: String
    ) {
        PrivilegedPowerRuntime.shared.configure(.helper(configuration))
        print(
            "Lumos privileged helper mode=helper service=\(configuration.machServiceName) status=\(status)"
        )
    }

    private static func configureApprovalRequired(
        configuration: LumosPrivilegedServiceConfiguration,
        status: String,
        presentApprovalSettings: Bool
    ) {
        PrivilegedPowerRuntime.shared.configure(
            .helperUnavailable(.approvalRequired)
        )
        print("Lumos privileged helper status=\(status)")
        if presentApprovalSettings {
            presentApprovalSettingsOnce(configuration: configuration)
        }
    }

    private static func presentApprovalSettingsOnce(
        configuration: LumosPrivilegedServiceConfiguration
    ) {
        let approvalPromptKey = "privilegedHelperApprovalPresented.\(configuration.machServiceName).v1"
        guard !UserDefaults.standard.bool(forKey: approvalPromptKey) else { return }
        UserDefaults.standard.set(true, forKey: approvalPromptKey)
        SMAppService.openSystemSettingsLoginItems()
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
