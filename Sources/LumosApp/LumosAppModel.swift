import AppKit
import Foundation
import LumosSpikeCore

struct ApplicationCandidate: Identifiable, Equatable {
    let id: String
    let displayName: String
    let executablePath: String?
    let instanceCount: Int
}

@MainActor
final class LumosAppModel: ObservableObject {
    @Published private(set) var preferences: LumosPreferences
    @Published private(set) var systemLeaseActive = false
    @Published private(set) var displayLeaseActive = false
    @Published private(set) var guardStartedAt: Date?
    @Published private(set) var systemState = SystemStateProbe.snapshot()
    @Published private(set) var clamshellSleepState: ClamshellSleepSnapshot
    @Published private(set) var lowPowerModeState: LowPowerModeSnapshot
    @Published private(set) var runningApplications: [ApplicationCandidate] = []
    @Published private(set) var lastError: String?

    var statusDidChange: (() -> Void)?

    private let store: LumosPreferencesStore
    private let clamshellSleepController: ClamshellSleepController
    private let lowPowerModeController: LowPowerModeController
    private var systemAssertion: PowerAssertion?
    private var displayAssertion: PowerAssertion?
    private var refreshTimer: Timer?

    init(
        store: LumosPreferencesStore = LumosPreferencesStore(),
        clamshellSleepController: ClamshellSleepController = ClamshellSleepController(),
        lowPowerModeController: LowPowerModeController = LowPowerModeController()
    ) {
        self.store = store
        self.clamshellSleepController = clamshellSleepController
        self.lowPowerModeController = lowPowerModeController
        self.preferences = store.load()
        self.clamshellSleepState = clamshellSleepController.reconcileStaleSession()
        self.lowPowerModeState = lowPowerModeController.snapshot()
        refreshAll()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAll()
            }
        }
        if let refreshTimer {
            RunLoop.main.add(refreshTimer, forMode: .common)
        }
    }

    var selectedProfile: LumosProfile {
        preferences.selectedProfile ?? LumosPreferences.agentMode
    }

    var isGuardActive: Bool {
        guardStartedAt != nil
    }

    var statusText: String {
        guard isGuardActive else { return "守护已暂停" }
        if preferences.activeControls.requestClamshellProtection,
           clamshellSleepState.isSleepDisabled {
            return clamshellSleepState.ownership == .lumos
                ? "实验性合盖守护正在运行"
                : "合盖守护正在运行，由外部设置提供"
        }
        return switch (systemLeaseActive, displayLeaseActive) {
        case (true, true): "任务与显示器正在保持唤醒"
        case (true, false): "任务继续运行，显示器可按时熄灭"
        case (false, true): "显示器正在保持唤醒"
        case (false, false): "当前方案没有可执行的守护项"
        }
    }

    var thermalText: String {
        switch systemState.thermalState {
        case .nominal: "温度正常"
        case .fair: "温度略高"
        case .serious: "温度较高"
        case .critical: "温度过高"
        case .unknown: "温度未知"
        }
    }

    var powerModeText: String {
        lowPowerModeState.detail
    }

    var clamshellModeText: String {
        if clamshellSleepState.isSleepDisabled {
            return clamshellSleepState.ownership == .lumos
                ? "已由 Lumos 启用"
                : "系统睡眠已关闭 · 非本次 Lumos 控制"
        }
        if preferences.activeControls.requestClamshellProtection {
            return "守护开始时请求管理员授权"
        }
        return "实验性 · 需管理员授权"
    }

    var matchedProcessCount: Int {
        let targetIDs = Set(selectedProfile.watchedApplicationIDs)
        return runningApplications
            .filter { targetIDs.contains($0.id) }
            .reduce(0) { $0 + $1.instanceCount }
    }

    var targetApplicationCount: Int {
        selectedProfile.watchedApplicationIDs.count
    }

    func refreshAll() {
        systemState = SystemStateProbe.snapshot()
        let previousClamshellState = clamshellSleepState
        clamshellSleepState = clamshellSleepController.snapshot()
        lowPowerModeState = lowPowerModeController.snapshot()
        refreshRunningApplications()

        if previousClamshellState.ownership == .lumos,
           !clamshellSleepState.isSleepDisabled,
           isGuardActive,
           preferences.activeControls.requestClamshellProtection {
            lastError = "合盖模式已由安全 watchdog 结束；当前仍保留普通任务守护。"
        }

        if clamshellSleepState.ownership == .lumos,
           (systemState.thermalState == .serious || systemState.thermalState == .critical) {
            stopGuard()
            lastError = "检测到温度过高，Lumos 已结束合盖模式并恢复系统休眠。"
        }
    }

    func refreshRunningApplications() {
        var candidates: [String: ApplicationCandidate] = [:]

        for application in ProcessProbe.runningApplications() {
            guard let displayName = application.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !displayName.isEmpty,
                  application.pid != getpid()
            else { continue }

            let id = application.bundleIdentifier
                ?? application.executablePath
                ?? "pid:\(application.pid)"
            let existing = candidates[id]
            candidates[id] = ApplicationCandidate(
                id: id,
                displayName: existing?.displayName ?? displayName,
                executablePath: existing?.executablePath ?? application.executablePath,
                instanceCount: (existing?.instanceCount ?? 0) + 1
            )
        }

        runningApplications = candidates.values.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    func toggleGuard() {
        isGuardActive ? stopGuard() : startGuard()
    }

    func startGuard() {
        var controls = preferences.activeControls
        guard controls.preventSystemIdleSleep
                || controls.preventDisplayIdleSleep
                || controls.requestClamshellProtection else {
            lastError = "当前方案没有可执行的守护项。请先开启“防止自动锁屏”或“防止空闲休眠”。"
            return
        }

        if controls.requestClamshellProtection {
            let transition = clamshellSleepController.activate(
                maximumDurationMinutes: controls.clamshellMaximumDurationMinutes,
                batteryFloorPercent: controls.clamshellBatteryFloorPercent
            )
            clamshellSleepState = transition.snapshot
            switch transition.state {
            case .cancelled, .failed:
                lastError = transition.message
                return
            case .activated, .externallyManaged:
                controls.preventSystemIdleSleep = true
            case .deactivated:
                break
            }
        }

        do {
            try synchronizeAssertions(with: controls)
            guardStartedAt = Date()
            lastError = nil
        } catch {
            releaseAllAssertions()
            if preferences.activeControls.requestClamshellProtection {
                clamshellSleepState = clamshellSleepController.deactivate().snapshot
            }
            lastError = String(describing: error)
        }
        statusDidChange?()
    }

    func stopGuard() {
        releaseAllAssertions()
        if preferences.activeControls.requestClamshellProtection
            || clamshellSleepState.ownership == .lumos {
            let transition = clamshellSleepController.deactivate()
            clamshellSleepState = transition.snapshot
            if transition.state == .failed {
                lastError = transition.message
                statusDidChange?()
                return
            }
        }
        guardStartedAt = nil
        statusDidChange?()
    }

    func selectProfile(id: UUID) {
        mutatePreferences { $0.selectProfile(id: id) }
        synchronizeActiveGuard()
    }

    func duplicateSelectedProfile() {
        let baseName = "\(selectedProfile.name) · 自定义"
        let names = Set(preferences.profiles.map(\.name))
        var name = baseName
        var suffix = 2
        while names.contains(name) {
            name = "\(baseName) \(suffix)"
            suffix += 1
        }
        mutatePreferences { _ = $0.duplicateSelectedProfile(name: name) }
    }

    func deleteSelectedProfile() {
        let id = preferences.selectedProfileID
        mutatePreferences { $0.deleteProfile(id: id) }
        synchronizeActiveGuard()
    }

    func renameSelectedProfile(_ name: String) {
        guard !selectedProfile.isBuiltIn else { return }
        mutateSelectedProfile { profile in
            profile.name = name
        }
    }

    func updateSelectedProfileSummary(_ summary: String) {
        guard !selectedProfile.isBuiltIn else { return }
        mutateSelectedProfile { profile in
            profile.summary = summary
        }
    }

    func setControl(
        _ keyPath: WritableKeyPath<AtomicControlPreferences, Bool>,
        to value: Bool
    ) {
        ensureEditableProfile()
        mutateSelectedProfile { profile in
            profile.controls[keyPath: keyPath] = value
        }
        synchronizeActiveGuard()
    }

    func setClamshellMaximumDuration(_ minutes: Int) {
        ensureEditableProfile()
        mutateSelectedProfile { profile in
            profile.controls.clamshellMaximumDurationMinutes = minutes
            profile.controls.normalize()
        }
        stopOwnedClamshellAfterSafetySettingChange()
    }

    func setClamshellBatteryFloor(_ percent: Int) {
        ensureEditableProfile()
        mutateSelectedProfile { profile in
            profile.controls.clamshellBatteryFloorPercent = percent
            profile.controls.normalize()
        }
        stopOwnedClamshellAfterSafetySettingChange()
    }

    func setClamshellProtection(_ enabled: Bool) {
        ensureEditableProfile()
        mutateSelectedProfile { profile in
            profile.controls.requestClamshellProtection = enabled
            if enabled {
                profile.controls.preventSystemIdleSleep = true
            }
        }
        synchronizeActiveGuard()
    }

    func setLowPowerMode(_ enabled: Bool) {
        let transition = lowPowerModeController.setEnabled(enabled)
        lowPowerModeState = transition.snapshot
        systemState = SystemStateProbe.snapshot()

        switch transition.state {
        case .updated, .unchanged:
            if preferences.activeControls.preferLowPowerMode != enabled {
                ensureEditableProfile()
                mutateSelectedProfile { profile in
                    profile.controls.preferLowPowerMode = enabled
                }
            }
            lastError = nil
        case .cancelled, .failed:
            lastError = transition.message
        }
        statusDidChange?()
    }

    func isApplicationTargeted(_ id: String) -> Bool {
        selectedProfile.watchedApplicationIDs.contains(id)
    }

    func setApplicationTarget(_ application: ApplicationCandidate, enabled: Bool) {
        ensureEditableProfile()
        var updated = preferences

        if enabled, !updated.watchedApplications.contains(where: { $0.id == application.id }) {
            updated.watchedApplications.append(
                WatchedApplication(
                    id: application.id,
                    displayName: application.displayName,
                    executablePath: application.executablePath
                )
            )
        }

        guard let index = updated.profiles.firstIndex(where: { $0.id == updated.selectedProfileID }) else {
            return
        }
        if enabled {
            if !updated.profiles[index].watchedApplicationIDs.contains(application.id) {
                updated.profiles[index].watchedApplicationIDs.append(application.id)
            }
        } else {
            updated.profiles[index].watchedApplicationIDs.removeAll { $0 == application.id }
        }
        updated.activeControls = updated.profiles[index].controls
        preferences = updated
        persistPreferences()
    }

    func sleepDisplayNow() {
        do {
            let result = try DisplaySleepProbe.sleepNow()
            if result.terminationStatus != 0 {
                lastError = result.standardError.isEmpty
                    ? "显示器休眠命令失败（\(result.terminationStatus)）。"
                    : result.standardError
            } else {
                lastError = nil
            }
        } catch {
            lastError = String(describing: error)
        }
    }

    func shutdown() {
        refreshTimer?.invalidate()
        if isGuardActive || clamshellSleepState.ownership == .lumos {
            stopGuard()
        }
    }

    private func ensureEditableProfile() {
        guard selectedProfile.isBuiltIn else { return }
        duplicateSelectedProfile()
    }

    private func stopOwnedClamshellAfterSafetySettingChange() {
        guard isGuardActive, clamshellSleepState.ownership == .lumos else { return }
        stopGuard()
        guard clamshellSleepState.ownership != .lumos else { return }
        lastError = "合盖安全参数已改变，请重新开始守护并完成管理员授权。"
        statusDidChange?()
    }

    private func mutateSelectedProfile(_ mutation: (inout LumosProfile) -> Void) {
        var updated = preferences
        guard let index = updated.profiles.firstIndex(where: { $0.id == updated.selectedProfileID }) else {
            return
        }
        mutation(&updated.profiles[index])
        updated.activeControls = updated.profiles[index].controls
        preferences = updated
        persistPreferences()
    }

    private func mutatePreferences(_ mutation: (inout LumosPreferences) -> Void) {
        var updated = preferences
        mutation(&updated)
        updated.normalize()
        preferences = updated
        persistPreferences()
    }

    private func persistPreferences() {
        do {
            try store.save(preferences)
            lastError = nil
        } catch {
            lastError = "设置保存失败：\(error)"
        }
        statusDidChange?()
    }

    private func synchronizeActiveGuard() {
        guard isGuardActive else {
            statusDidChange?()
            return
        }
        let controls = preferences.activeControls
        guard controls.preventSystemIdleSleep
                || controls.preventDisplayIdleSleep
                || controls.requestClamshellProtection else {
            stopGuard()
            return
        }
        if !controls.requestClamshellProtection,
           clamshellSleepState.ownership == .lumos {
            let transition = clamshellSleepController.deactivate()
            clamshellSleepState = transition.snapshot
            if transition.state == .failed {
                lastError = transition.message
            }
        }
        if controls.requestClamshellProtection,
           !clamshellSleepState.isSleepDisabled {
            stopGuard()
            lastError = "合盖模式设置已改变，请重新开始守护并完成管理员授权。"
            return
        }
        var effectiveControls = controls
        if controls.requestClamshellProtection {
            effectiveControls.preventSystemIdleSleep = true
        }
        do {
            try synchronizeAssertions(with: effectiveControls)
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
        statusDidChange?()
    }

    private func synchronizeAssertions(with controls: AtomicControlPreferences) throws {
        if controls.preventSystemIdleSleep, systemAssertion == nil {
            systemAssertion = try PowerAssertion(
                kind: .systemIdleSleep,
                reason: "Lumos task guard - \(selectedProfile.id.uuidString)"
            )
        } else if !controls.preventSystemIdleSleep {
            try systemAssertion?.release()
            systemAssertion = nil
        }

        if controls.preventDisplayIdleSleep, displayAssertion == nil {
            displayAssertion = try PowerAssertion(
                kind: .displayIdleSleep,
                reason: "Lumos display guard - \(selectedProfile.id.uuidString)"
            )
        } else if !controls.preventDisplayIdleSleep {
            try displayAssertion?.release()
            displayAssertion = nil
        }

        systemLeaseActive = systemAssertion?.isActive == true
        displayLeaseActive = displayAssertion?.isActive == true
    }

    private func releaseAllAssertions() {
        do {
            try systemAssertion?.release()
            try displayAssertion?.release()
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
        systemAssertion = nil
        displayAssertion = nil
        systemLeaseActive = false
        displayLeaseActive = false
    }
}
