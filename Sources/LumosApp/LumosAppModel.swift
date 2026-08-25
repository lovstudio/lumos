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

struct GuardedApplicationState: Identifiable, Equatable {
    let id: String
    let displayName: String
    let executablePath: String?
    let instanceCount: Int

    var isRunning: Bool { instanceCount > 0 }
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
            return "未在守护"
        case .active:
            break
        }
        if preferences.activeControls.requestClamshellProtection,
           clamshellSleepState.isSleepDisabled {
            return "合盖后任务将继续运行"
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
        guard lowPowerModeState.isAvailable else {
            return "暂时无法读取当前状态"
        }
        let source = switch lowPowerModeState.powerSource {
        case .acPower: "接通电源"
        case .battery: "电池供电"
        case .ups: "UPS 供电"
        case .unknown: "当前电源"
        }
        return "\(source) · 当前已\(lowPowerModeState.isEnabled ? "开启" : "关闭")"
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
            return "合盖后任务继续运行"
        }
        if preferences.activeControls.requestClamshellProtection {
            if isGuardActive, safetyDecision.shouldEndClamshellProtection {
                return "合盖后电脑正常休眠"
            }
            return "开启后，合盖不影响任务运行"
        }
        return "合盖后电脑正常休眠"
    }

    var isClamshellControlPresentedOn: Bool {
        preferences.activeControls.requestClamshellProtection
            || clamshellSleepState.isSleepDisabled
    }

    var hasExternalClamshellControl: Bool {
        clamshellSleepState.isSleepDisabled
            && clamshellSleepState.ownership == .external
    }

    var systemStatusText: String {
        switch safetyDecision.severity {
        case .normal:
            return "\(powerSourceState.detail) · \(thermalText) · \(networkText)"
        case .efficient, .degraded, .critical:
            return safetyDecision.detail
        }
    }

    var matchedProcessCount: Int {
        let targetIDs = Set(preferences.watchedApplications.map(\.id))
        return runningApplications
            .filter { targetIDs.contains($0.id) }
            .reduce(0) { $0 + $1.instanceCount }
    }

    var targetApplicationCount: Int {
        preferences.watchedApplications.count
    }

    var guardedApplications: [GuardedApplicationState] {
        let runningByID = Dictionary(
            uniqueKeysWithValues: runningApplications.map { ($0.id, $0) }
        )
        return preferences.watchedApplications.map { application in
            let running = runningByID[application.id]
            return GuardedApplicationState(
                id: application.id,
                displayName: application.displayName,
                executablePath: application.executablePath,
                instanceCount: running?.instanceCount ?? 0
            )
        }
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
            lastError = "合盖时保持运行已由安全保护机制结束；当前仍保留普通任务守护。"
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
        if presetSessionPhase == .completed,
           presetSessionExitReason == .targetsFinished,
           matchedProcessCount > 0 {
            startGuard()
        } else {
            reconcilePresetSession()
        }
    }

    func activateConfiguredControls() {
        applyConfiguredControlsImmediately()
    }

    func startGuard() {
        var controls = preferences.activeControls
        guard controls.preventSystemIdleSleep
                || controls.preventDisplayIdleSleep
                || controls.requestClamshellProtection else {
            lastError = "当前没有可执行的守护项。请先开启“保持任务运行”或“保持屏幕唤醒”。"
            return
        }

        guard !safetyDecision.shouldReleaseSystemLease else {
            lastError = "当前温度不允许启用守护，请等待系统恢复正常。"
            statusDidChange?()
            return
        }

        if controls.requestClamshellProtection,
           safetyDecision.shouldEndClamshellProtection {
            lastError = "当前电源、电量或温度状态不允许启用合盖守护。"
            statusDidChange?()
            return
        }

        if !activateClamshellIfNeeded(controls: &controls) {
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

    func setControl(
        _ keyPath: WritableKeyPath<AtomicControlPreferences, Bool>,
        to value: Bool
    ) {
        mutatePreferences { preferences in
            preferences.activeControls[keyPath: keyPath] = value
        }
        applyConfiguredControlsImmediately()
    }

    func setClamshellMaximumDuration(_ minutes: Int) {
        mutatePreferences { preferences in
            preferences.activeControls.clamshellMaximumDurationMinutes = minutes
        }
        reapplyOwnedClamshellAfterSafetySettingChange()
    }

    func setClamshellBatteryFloor(_ percent: Int) {
        mutatePreferences { preferences in
            preferences.activeControls.clamshellBatteryFloorPercent = percent
        }
        reapplyOwnedClamshellAfterSafetySettingChange()
    }

    func setClamshellProtection(_ enabled: Bool) {
        if !enabled, hasExternalClamshellControl {
            restoreExternalClamshellDefault()
            return
        }
        mutatePreferences { preferences in
            preferences.activeControls.requestClamshellProtection = enabled
            if enabled {
                preferences.activeControls.preventSystemIdleSleep = true
            }
        }
        applyConfiguredControlsImmediately()
    }

    func restoreExternalClamshellDefault() {
        let transition = clamshellSleepController.restoreSystemDefault()
        clamshellSleepState = transition.snapshot

        switch transition.state {
        case .deactivated:
            if preferences.activeControls.requestClamshellProtection {
                mutatePreferences { preferences in
                    preferences.activeControls.requestClamshellProtection = false
                }
            }
            lastError = nil
            applyConfiguredControlsImmediately()
        case .cancelled, .failed, .externallyManaged:
            lastError = transition.message
        case .activated:
            break
        }
        statusDidChange?()
    }

    func setLowPowerMode(_ enabled: Bool) {
        let transition = lowPowerModeController.setEnabled(enabled)
        lowPowerModeState = transition.snapshot
        safetyMonitor.refresh(reason: .lowPowerMode)

        switch transition.state {
        case .updated, .unchanged:
            if preferences.activeControls.preferLowPowerMode != enabled {
                mutatePreferences { preferences in
                    preferences.activeControls.preferLowPowerMode = enabled
                }
            }
            lastError = nil
        case .cancelled, .failed:
            lastError = transition.message
        }
        statusDidChange?()
    }

    func isApplicationTargeted(_ id: String) -> Bool {
        preferences.watchedApplications.contains { $0.id == id }
    }

    func setApplicationTarget(_ application: ApplicationCandidate, enabled: Bool) {
        mutatePreferences { preferences in
            if enabled {
                let watchedApplication = WatchedApplication(
                    id: application.id,
                    displayName: application.displayName,
                    executablePath: application.executablePath
                )
                if let index = preferences.watchedApplications.firstIndex(where: {
                    $0.id == application.id
                }) {
                    preferences.watchedApplications[index] = watchedApplication
                } else {
                    preferences.watchedApplications.append(watchedApplication)
                }
            } else {
                preferences.watchedApplications.removeAll { $0.id == application.id }
            }
        }
        applyConfiguredControlsImmediately()
    }

    func removeApplicationTarget(_ id: String) {
        mutatePreferences { preferences in
            preferences.watchedApplications.removeAll { $0.id == id }
        }
        applyConfiguredControlsImmediately()
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

    private func reapplyOwnedClamshellAfterSafetySettingChange() {
        guard isGuardEnabled, clamshellSleepState.ownership == .lumos else { return }
        stopGuard()
        applyConfiguredControlsImmediately()
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
        reconcilePresetSession()
    }

    private func applyConfiguredControlsImmediately() {
        let controls = preferences.activeControls
        let hasGuardCapability = controls.preventSystemIdleSleep
            || controls.preventDisplayIdleSleep
            || controls.requestClamshellProtection

        guard hasGuardCapability else {
            if isGuardEnabled || clamshellSleepState.ownership == .lumos {
                stopGuard()
            } else {
                statusDidChange?()
            }
            return
        }

        if isGuardEnabled {
            synchronizeActiveGuard()
        } else {
            startGuard()
        }
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
            presetKind: .taskGuard,
            leaseKinds: kinds,
            hasConfiguredTargets: targetApplicationCount > 0,
            matchedTargetCount: matchedProcessCount,
            safetySuspended: kinds.isEmpty
        )
    }

    private var sessionReason: String {
        "Lumos app guard"
    }

    private func activateClamshellIfNeeded(
        controls: inout AtomicControlPreferences
    ) -> Bool {
        guard controls.requestClamshellProtection else {
            return true
        }
        controls.preventSystemIdleSleep = true

        if clamshellSleepState.ownership == .lumos {
            return true
        }

        let transition = clamshellSleepController.activate(
            maximumDurationMinutes: controls.clamshellMaximumDurationMinutes,
            batteryFloorPercent: controls.clamshellBatteryFloorPercent,
            takeOverExisting: true
        )
        clamshellSleepState = transition.snapshot
        switch transition.state {
        case .cancelled, .failed:
            lastError = transition.message
            return false
        case .externallyManaged:
            lastError = transition.message
            return false
        case .activated:
            controls.preventSystemIdleSleep = true
            return true
        case .deactivated:
            return true
        }
    }

    private func reconcilePresetSession() {
        guard isGuardEnabled else { return }
        var controls = preferences.activeControls
        if !activateClamshellIfNeeded(controls: &controls) {
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
