import AppKit
import Foundation
import LumosSpikeCore

struct ApplicationCandidate: Identifiable, Equatable {
    let id: String
    let displayName: String
    let executablePath: String?
    let instanceCount: Int
    let unobservableInstanceCount: Int
}

@MainActor
final class LumosAppModel: ObservableObject {
    @Published private(set) var preferences: LumosPreferences
    @Published private(set) var systemLeaseActive = false
    @Published private(set) var displayLeaseActive = false
    @Published private(set) var guardStartedAt: Date?
    @Published private(set) var presetSessionPhase: PresetSessionPhase = .stopped
    @Published private(set) var presetSessionExitReason: PresetSessionExitReason = .none
    @Published private(set) var systemState: SystemStateSnapshot
    @Published private(set) var powerSourceState: PowerSourceSnapshot
    @Published private(set) var networkPathState: NetworkPathSnapshot?
    @Published private(set) var safetyDecision: SystemSafetyDecision
    @Published private(set) var clamshellSleepState: ClamshellSleepSnapshot
    @Published private(set) var lowPowerModeState: LowPowerModeSnapshot
    @Published private(set) var runningApplications: [ApplicationCandidate] = []
    @Published private(set) var recentProcessEvents: [ProcessObservationEvent] = []
    @Published private(set) var lastError: String?

    var statusDidChange: (() -> Void)?

    private let store: LumosPreferencesStore
    private let clamshellSleepController: ClamshellSleepController
    private let lowPowerModeController: LowPowerModeController
    private let presetSessionController: PresetSessionController
    private let processObservationProvider: ProcessObservationProvider
    private let safetyMonitor: SystemSafetyMonitor
    private let safetyStateMachine: SystemSafetyStateMachine
    private var refreshTimer: Timer?
    private var refreshTimerInterval: TimeInterval?
    private var workspaceObservationTokens: [NSObjectProtocol] = []

    init(
        store: LumosPreferencesStore = LumosPreferencesStore(),
        clamshellSleepController: ClamshellSleepController = ClamshellSleepController(),
        lowPowerModeController: LowPowerModeController = LowPowerModeController(),
        wakeLeaseEngine: WakeLeaseEngine = WakeLeaseEngine(),
        processObservationProvider: ProcessObservationProvider = ProcessObservationProvider(),
        safetyMonitor: SystemSafetyMonitor = SystemSafetyMonitor(),
        safetyStateMachine: SystemSafetyStateMachine = SystemSafetyStateMachine()
    ) {
        let loadedPreferences = store.load()
        let initialSystemState = SystemStateProbe.snapshot()
        let initialPowerSource = PowerSourceProbe.snapshot()
        let initialSafetySnapshot = SystemSafetySnapshot(
            systemState: initialSystemState,
            powerSource: initialPowerSource,
            networkPath: nil,
            observedAt: Date()
        )

        self.store = store
        self.clamshellSleepController = clamshellSleepController
        self.lowPowerModeController = lowPowerModeController
        self.presetSessionController = PresetSessionController(wakeLeaseEngine: wakeLeaseEngine)
        self.processObservationProvider = processObservationProvider
        self.safetyMonitor = safetyMonitor
        self.safetyStateMachine = safetyStateMachine
        self.preferences = loadedPreferences
        self.systemState = initialSystemState
        self.powerSourceState = initialPowerSource
        self.networkPathState = nil
        self.safetyDecision = SystemSafetyPolicy.evaluate(
            initialSafetySnapshot,
            batteryFloorPercent: loadedPreferences.activeControls.clamshellBatteryFloorPercent
        )
        self.clamshellSleepState = clamshellSleepController.reconcileStaleSession()
        self.lowPowerModeState = lowPowerModeController.snapshot()
        refreshRunningApplications()
        observeWorkspaceLifecycle()
        safetyMonitor.start { [weak self] event in
            Task { @MainActor in
                self?.applySafetyEvent(event)
            }
        }
        scheduleRefreshTimer(interval: safetyDecision.refreshInterval)
    }

    var selectedProfile: LumosProfile {
        preferences.selectedProfile ?? LumosPreferences.agentMode
    }

    var isGuardActive: Bool {
        presetSessionPhase == .active
    }

    var isGuardEnabled: Bool {
        presetSessionPhase.isEnabled
    }

    var statusText: String {
        if safetyDecision.severity == .critical {
            return safetyDecision.detail
        }
        switch presetSessionPhase {
        case .waitingForTarget:
            return "正在观察，等待关注应用开始"
        case .suspendedForSafety:
            return "安全保护已暂停当前能力，状态恢复后重试"
        case .completed where presetSessionExitReason == .targetsFinished:
            return "关注应用已全部退出，守护已自动停止"
        case .completed where presetSessionExitReason == .safetyBoundary:
            return "已达到安全边界，守护已停止"
        case .stopped, .completed:
            return "守护已暂停"
        case .active:
            break
        }
        if preferences.activeControls.requestClamshellProtection,
           clamshellSleepState.isSleepDisabled {
            return clamshellSleepState.ownership == .lumos
                ? "实验性合盖守护正在运行"
                : "合盖守护正在运行，由外部设置提供"
        }
        if selectedProfile.presetKind == .alwaysReachable, systemLeaseActive {
            return "整机保持必要唤醒，等待远程连接"
        }
        if selectedProfile.presetKind == .keepDisplayAwake, displayLeaseActive {
            return "显示器正在保持唤醒"
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

    var networkText: String {
        guard let networkPathState else { return "正在确认网络状态" }
        if networkPathState.status != .satisfied {
            return "网络不可达"
        }
        if networkPathState.isConstrained {
            return "网络受限"
        }
        if networkPathState.isExpensive {
            return "计费网络"
        }
        return "网络正常"
    }

    var clamshellModeText: String {
        if clamshellSleepState.isSleepDisabled {
            return clamshellSleepState.ownership == .lumos
                ? "已由 Lumos 启用"
                : "系统睡眠已关闭 · 非本次 Lumos 控制"
        }
        if preferences.activeControls.requestClamshellProtection {
            if isGuardActive, safetyDecision.shouldEndClamshellProtection {
                return "已因安全状态结束 · 重新开始后授权"
            }
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

    var presetTriggerText: String {
        if selectedProfile.presetKind == .taskGuard, targetApplicationCount == 0 {
            return "未限定应用，用户开启后立即开始"
        }
        return selectedProfile.presetKind.triggerDescription
    }

    var presetExitText: String {
        if selectedProfile.presetKind == .taskGuard, targetApplicationCount == 0 {
            return "用户停止或达到安全边界"
        }
        return selectedProfile.presetKind.exitDescription
    }

    func refreshAll() {
        lowPowerModeState = lowPowerModeController.snapshot()
        refreshCorrectionSnapshots()
        safetyMonitor.refresh(reason: .manual)
    }

    private func refreshCorrectionSnapshots() {
        let previousClamshellState = clamshellSleepState
        clamshellSleepState = clamshellSleepController.snapshot()
        refreshRunningApplications()

        if previousClamshellState.ownership == .lumos,
           !clamshellSleepState.isSleepDisabled,
           isGuardActive,
           preferences.activeControls.requestClamshellProtection {
            lastError = "合盖模式已由安全 watchdog 结束；当前仍保留普通任务守护。"
        }
    }

    func refreshRunningApplications() {
        let observation = processObservationProvider.sample()
        recentProcessEvents = observation.events
        let processesByPID = observation.processesByPID
        var candidates: [String: ApplicationCandidate] = [:]
        var seenInstances: [String: Set<String>] = [:]

        for application in ProcessProbe.runningApplications() {
            guard let displayName = application.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !displayName.isEmpty,
                  application.pid != getpid()
            else { continue }

            let id = application.bundleIdentifier
                ?? application.executablePath
                ?? "pid:\(application.pid)"
            let observedProcess = processesByPID[application.pid]
            let instanceIdentity = observedProcess?.stableIdentity.description
                ?? "unobservable:\(application.pid)"
            guard seenInstances[id, default: []].insert(instanceIdentity).inserted else {
                continue
            }
            let existing = candidates[id]
            candidates[id] = ApplicationCandidate(
                id: id,
                displayName: existing?.displayName ?? displayName,
                executablePath: existing?.executablePath ?? application.executablePath,
                instanceCount: (existing?.instanceCount ?? 0) + 1,
                unobservableInstanceCount: (existing?.unobservableInstanceCount ?? 0)
                    + (observedProcess == nil ? 1 : 0)
            )
        }

        runningApplications = candidates.values.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
        reconcilePresetSession()
    }

    func toggleGuard() {
        isGuardEnabled ? stopGuard() : startGuard()
    }

    func startGuard() {
        var controls = preferences.activeControls
        guard controls.preventSystemIdleSleep
                || controls.preventDisplayIdleSleep
                || controls.requestClamshellProtection else {
            lastError = "当前方案没有可执行的守护项。请先开启“防止自动锁屏”或“防止空闲休眠”。"
            return
        }

        guard !safetyDecision.shouldReleaseSystemLease else {
            lastError = "当前温度不允许开始守护。请等待 macOS 恢复正常热状态。"
            statusDidChange?()
            return
        }

        if controls.requestClamshellProtection,
           safetyDecision.shouldEndClamshellProtection {
            lastError = "当前电源、电量或温度状态不允许启用合盖守护。"
            statusDidChange?()
            return
        }

        if shouldCurrentPresetTrigger,
           !activateClamshellIfNeeded(controls: &controls) {
            statusDidChange?()
            return
        }

        do {
            let effectiveControls = effectiveControlsForSafety(controls)
            let snapshot = try presetSessionController.start(
                sessionContext(controls: effectiveControls),
                reason: sessionReason
            )
            applySessionSnapshot(snapshot)
            lastError = nil
        } catch {
            _ = try? presetSessionController.stop(reason: .userStopped)
            applySessionSnapshot(presetSessionController.snapshot)
            if preferences.activeControls.requestClamshellProtection {
                clamshellSleepState = clamshellSleepController.deactivate().snapshot
            }
            lastError = String(describing: error)
        }
        statusDidChange?()
    }

    func stopGuard() {
        stopGuard(reason: .userStopped)
    }

    private func stopGuard(reason: PresetSessionExitReason) {
        do {
            applySessionSnapshot(try presetSessionController.stop(reason: reason))
        } catch {
            applySessionSnapshot(presetSessionController.snapshot)
            lastError = String(describing: error)
        }
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
        statusDidChange?()
    }

    func selectProfile(id: UUID) {
        let wasEnabled = isGuardEnabled
        if wasEnabled {
            stopGuard()
        }
        mutatePreferences { $0.selectProfile(id: id) }
        if wasEnabled {
            startGuard()
        }
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
        safetyMonitor.refresh(reason: .lowPowerMode)

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
        synchronizeActiveGuard()
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
        refreshTimerInterval = nil
        safetyMonitor.stop()
        let notificationCenter = NSWorkspace.shared.notificationCenter
        workspaceObservationTokens.forEach(notificationCenter.removeObserver)
        workspaceObservationTokens.removeAll()
        if isGuardEnabled || clamshellSleepState.ownership == .lumos {
            stopGuard()
        }
    }

    private func observeWorkspaceLifecycle() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        let names: [NSNotification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ]
        workspaceObservationTokens = names.map { name in
            notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshRunningApplications()
                }
            }
        }
    }

    private func applySafetyEvent(_ event: SystemSafetyEvent) {
        systemState = event.snapshot.systemState
        powerSourceState = event.snapshot.powerSource
        networkPathState = event.snapshot.networkPath
        lowPowerModeState = lowPowerSnapshot(from: event.snapshot)

        let transition = safetyStateMachine.ingest(
            event.snapshot,
            batteryFloorPercent: preferences.activeControls.clamshellBatteryFloorPercent
        )
        safetyDecision = transition.current
        scheduleRefreshTimer(interval: transition.current.refreshInterval)

        guard isGuardEnabled else {
            statusDidChange?()
            return
        }

        if transition.current.shouldReleaseSystemLease {
            stopGuard(reason: .safetyBoundary)
            return
        }

        if transition.current.shouldEndClamshellProtection,
           clamshellSleepState.ownership == .lumos {
            let clamshellTransition = clamshellSleepController.deactivate()
            clamshellSleepState = clamshellTransition.snapshot
            if clamshellTransition.state == .failed {
                lastError = clamshellTransition.message
                statusDidChange?()
                return
            }
        }

        reconcilePresetSession()
    }

    private func scheduleRefreshTimer(interval: TimeInterval) {
        guard refreshTimerInterval != interval else { return }
        refreshTimer?.invalidate()
        refreshTimerInterval = interval

        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshCorrectionSnapshots()
                self?.safetyMonitor.refresh(reason: .manual)
            }
        }
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func effectiveControlsForSafety(
        _ controls: AtomicControlPreferences
    ) -> AtomicControlPreferences {
        var effective = controls
        if controls.requestClamshellProtection,
           clamshellSleepState.isSleepDisabled {
            effective.preventSystemIdleSleep = true
        }
        if safetyDecision.shouldReleaseDisplayLease {
            effective.preventDisplayIdleSleep = false
        }
        if safetyDecision.shouldReleaseSystemLease {
            effective.preventSystemIdleSleep = false
        }
        return effective
    }

    private func lowPowerSnapshot(
        from safetySnapshot: SystemSafetySnapshot
    ) -> LowPowerModeSnapshot {
        let source: LowPowerModePowerSource = switch safetySnapshot.powerSource.kind {
        case .acPower: .acPower
        case .battery: .battery
        case .ups: .ups
        case .unknown: .unknown
        }
        let sourceLabel = switch source {
        case .acPower: "接通电源时"
        case .battery: "使用电池时"
        case .ups: "使用 UPS 时"
        case .unknown: "当前"
        }
        let isAvailable = safetySnapshot.powerSource.isAvailable && source != .unknown
        return LowPowerModeSnapshot(
            isAvailable: isAvailable,
            isEnabled: safetySnapshot.systemState.lowPowerModeEnabled,
            powerSource: source,
            detail: isAvailable
                ? "\(sourceLabel)低功耗已\(safetySnapshot.systemState.lowPowerModeEnabled ? "开启" : "关闭")"
                : "无法确认当前电源来源的低功耗状态。"
        )
    }

    private func ensureEditableProfile() {
        guard selectedProfile.isBuiltIn else { return }
        duplicateSelectedProfile()
    }

    private func stopOwnedClamshellAfterSafetySettingChange() {
        guard isGuardEnabled, clamshellSleepState.ownership == .lumos else { return }
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
        guard isGuardEnabled else {
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
           !clamshellSleepState.isSleepDisabled,
           !safetyDecision.shouldEndClamshellProtection {
            stopGuard()
            lastError = "合盖模式设置已改变，请重新开始守护并完成管理员授权。"
            return
        }
        reconcilePresetSession()
    }

    private func sessionContext(controls: AtomicControlPreferences) -> PresetSessionContext {
        var kinds = Set<PowerAssertionKind>()
        if controls.preventSystemIdleSleep {
            kinds.insert(.systemIdleSleep)
        }
        if controls.preventDisplayIdleSleep {
            kinds.insert(.displayIdleSleep)
        }

        return PresetSessionContext(
            presetKind: selectedProfile.presetKind,
            leaseKinds: kinds,
            hasConfiguredTargets: targetApplicationCount > 0,
            matchedTargetCount: matchedProcessCount,
            safetySuspended: kinds.isEmpty
        )
    }

    private var sessionReason: String {
        "Lumos preset \(selectedProfile.presetKind.rawValue) - \(selectedProfile.id.uuidString)"
    }

    private var shouldCurrentPresetTrigger: Bool {
        selectedProfile.presetKind != .taskGuard
            || targetApplicationCount == 0
            || matchedProcessCount > 0
    }

    private func activateClamshellIfNeeded(
        controls: inout AtomicControlPreferences
    ) -> Bool {
        guard controls.requestClamshellProtection,
              !clamshellSleepState.isSleepDisabled else {
            if controls.requestClamshellProtection {
                controls.preventSystemIdleSleep = true
            }
            return true
        }

        let transition = clamshellSleepController.activate(
            maximumDurationMinutes: controls.clamshellMaximumDurationMinutes,
            batteryFloorPercent: controls.clamshellBatteryFloorPercent
        )
        clamshellSleepState = transition.snapshot
        switch transition.state {
        case .cancelled, .failed:
            lastError = transition.message
            return false
        case .activated, .externallyManaged:
            controls.preventSystemIdleSleep = true
            return true
        case .deactivated:
            return true
        }
    }

    private func reconcilePresetSession() {
        guard isGuardEnabled else { return }
        var controls = preferences.activeControls
        if shouldCurrentPresetTrigger,
           !activateClamshellIfNeeded(controls: &controls) {
            statusDidChange?()
            return
        }

        do {
            let snapshot = try presetSessionController.update(
                sessionContext(controls: effectiveControlsForSafety(controls)),
                reason: sessionReason
            )
            applySessionSnapshot(snapshot)
            if snapshot.phase == .completed,
               clamshellSleepState.ownership == .lumos {
                clamshellSleepState = clamshellSleepController.deactivate().snapshot
            }
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
        statusDidChange?()
    }

    private func applySessionSnapshot(_ snapshot: PresetSessionSnapshot) {
        let wasActive = presetSessionPhase == .active
        presetSessionPhase = snapshot.phase
        presetSessionExitReason = snapshot.exitReason
        systemLeaseActive = snapshot.activeLeaseKinds.contains(.systemIdleSleep)
        displayLeaseActive = snapshot.activeLeaseKinds.contains(.displayIdleSleep)

        if snapshot.phase == .active, !wasActive {
            guardStartedAt = Date()
        } else if snapshot.phase == .stopped
                    || snapshot.phase == .waitingForTarget
                    || snapshot.phase == .completed {
            guardStartedAt = nil
        }
    }
}
