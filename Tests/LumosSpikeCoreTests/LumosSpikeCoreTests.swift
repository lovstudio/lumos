import Darwin
import XCTest
@testable import LumosSpikeCore

final class LumosSpikeCoreTests: XCTestCase {
    func testCurrentProcessCanBeObserved() throws {
        let snapshot = try XCTUnwrap(ProcessProbe.snapshot(pid: getpid()))
        XCTAssertEqual(snapshot.pid, getpid())
        XCTAssertGreaterThan(snapshot.startTimeSeconds, 0)
        XCTAssertFalse(snapshot.identity.isEmpty)
    }

    func testDescendantsTraversesMultipleLevelsAndBreaksCycles() {
        let processes = [
            ProcessSnapshot(pid: 10, parentPID: 1, name: "root", executablePath: nil, startTimeSeconds: 1),
            ProcessSnapshot(pid: 11, parentPID: 10, name: "child", executablePath: nil, startTimeSeconds: 2),
            ProcessSnapshot(pid: 12, parentPID: 11, name: "grandchild", executablePath: nil, startTimeSeconds: 3),
            ProcessSnapshot(pid: 13, parentPID: 12, name: "leaf", executablePath: nil, startTimeSeconds: 4),
            ProcessSnapshot(pid: 10, parentPID: 13, name: "cycle", executablePath: nil, startTimeSeconds: 1),
        ]

        XCTAssertEqual(ProcessProbe.descendants(of: 10, in: processes).map(\.pid), [10, 11, 12, 13])
    }

    func testProcessSnapshotDifferDetectsStartTerminateAndPIDReuse() {
        let previous = [
            ProcessSnapshot(
                pid: 10,
                parentPID: 1,
                name: "old",
                executablePath: nil,
                startTimeSeconds: 100,
                startTimeMicroseconds: 1
            ),
            ProcessSnapshot(pid: 20, parentPID: 1, name: "gone", executablePath: nil, startTimeSeconds: 200),
        ]
        let current = [
            ProcessSnapshot(
                pid: 10,
                parentPID: 1,
                name: "reused",
                executablePath: nil,
                startTimeSeconds: 100,
                startTimeMicroseconds: 2
            ),
            ProcessSnapshot(pid: 30, parentPID: 1, name: "new", executablePath: nil, startTimeSeconds: 400),
        ]

        XCTAssertEqual(
            ProcessSnapshotDiffer.events(previous: previous, current: current),
            [
                .replaced(previous: previous[0], current: current[0]),
                .terminated(previous[1]),
                .started(current[1]),
            ]
        )
    }

    func testProcessObservationProviderUsesBaselineAndCanReset() {
        let first = ProcessSnapshot(
            pid: 10,
            parentPID: 1,
            name: "first",
            executablePath: nil,
            startTimeSeconds: 100
        )
        let second = ProcessSnapshot(
            pid: 20,
            parentPID: 1,
            name: "second",
            executablePath: nil,
            startTimeSeconds: 200
        )
        var samples = [[first], [first, second], [second]]
        let provider = ProcessObservationProvider {
            samples.removeFirst()
        }

        let baseline = provider.sample()
        XCTAssertTrue(baseline.isBaseline)
        XCTAssertEqual(baseline.events, [])

        let update = provider.sample()
        XCTAssertFalse(update.isBaseline)
        XCTAssertEqual(update.events, [.started(second)])

        provider.reset()
        let resetBaseline = provider.sample()
        XCTAssertTrue(resetBaseline.isBaseline)
        XCTAssertEqual(resetBaseline.events, [])
    }

    func testProcessObservationProviderSeesRealProcessStartAndExit() throws {
        let provider = ProcessObservationProvider()
        _ = provider.sample()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["5"]
        try process.run()
        let pid = process.processIdentifier
        defer {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }

        XCTAssertTrue(waitForProcessEvent(from: provider) { event in
            guard case .started(let snapshot) = event else { return false }
            return snapshot.pid == pid
        })

        process.terminate()
        process.waitUntilExit()

        XCTAssertTrue(waitForProcessEvent(from: provider) { event in
            guard case .terminated(let snapshot) = event else { return false }
            return snapshot.pid == pid
        })
    }

    func testProcessObservationIndexToleratesDuplicatePIDs() {
        let older = ProcessSnapshot(
            pid: 10,
            parentPID: 1,
            name: "older",
            executablePath: nil,
            startTimeSeconds: 100
        )
        let newer = ProcessSnapshot(
            pid: 10,
            parentPID: 1,
            name: "newer",
            executablePath: nil,
            startTimeSeconds: 200
        )

        XCTAssertEqual(ProcessSnapshotDiffer.indexByPID([newer, older])[10], newer)
    }

    func testProcessLookupReturnsStableIdentityForCurrentProcess() throws {
        guard case .running(let process) = ProcessProbe.lookup(pid: getpid()) else {
            return XCTFail("Current process should be observable")
        }

        XCTAssertEqual(process.stableIdentity.pid, getpid())
        XCTAssertGreaterThan(process.stableIdentity.startTimeSeconds, 0)
        XCTAssertEqual(process.identity, process.stableIdentity.description)
    }

    private func waitForProcessEvent(
        from provider: ProcessObservationProvider,
        matching predicate: (ProcessObservationEvent) -> Bool
    ) -> Bool {
        for _ in 0..<20 {
            if provider.sample().events.contains(where: predicate) {
                return true
            }
            usleep(25_000)
        }
        return false
    }

    func testSystemIdleAssertionCanBeCreatedAndReleased() throws {
        let assertion = try PowerAssertion(kind: .systemIdleSleep, reason: "Lumos Spike XCTest")
        XCTAssertTrue(assertion.isActive)
        try assertion.release()
        XCTAssertFalse(assertion.isActive)
        try assertion.release()
        XCTAssertFalse(assertion.isActive)
    }

    func testDisplayIdleAssertionCanBeCreatedAndReleased() throws {
        let assertion = try PowerAssertion(kind: .displayIdleSleep, reason: "Lumos Spike XCTest")
        XCTAssertTrue(assertion.isActive)
        try assertion.release()
        XCTAssertFalse(assertion.isActive)
    }

    func testSystemStateUsesKnownThermalLabel() {
        let snapshot = SystemStateProbe.snapshot()
        XCTAssertTrue(["nominal", "fair", "serious", "critical", "unknown"].contains(snapshot.thermalState.rawValue))
        XCTAssertGreaterThan(snapshot.processorCount, 0)
        XCTAssertGreaterThan(snapshot.physicalMemoryBytes, 0)
    }

    func testPowerSourceBuilderCalculatesBatteryPercentage() {
        let snapshot = PowerSourceSnapshotBuilder.build(
            providingSource: "Battery Power",
            currentCapacity: 45,
            maximumCapacity: 60,
            isCharging: false
        )

        XCTAssertTrue(snapshot.isAvailable)
        XCTAssertEqual(snapshot.kind, .battery)
        XCTAssertEqual(snapshot.batteryLevelPercent, 75)
        XCTAssertEqual(snapshot.isCharging, false)
        XCTAssertEqual(snapshot.detail, "电池供电 · 电池 75%")
    }

    func testLivePowerSourceSnapshotDoesNotExposeUnknownValuesAsFacts() {
        let snapshot = PowerSourceProbe.snapshot()

        if snapshot.isAvailable {
            XCTAssertNotEqual(snapshot.kind, .unknown)
        } else {
            XCTAssertEqual(snapshot.kind, .unknown)
        }
        if let batteryLevel = snapshot.batteryLevelPercent {
            XCTAssertTrue((0...100).contains(batteryLevel))
        }
    }

    func testSafetyPolicyUsesNormalFiveSecondCorrectionInterval() {
        let decision = SystemSafetyPolicy.evaluate(
            makeSafetySnapshot(),
            batteryFloorPercent: 20
        )

        XCTAssertEqual(decision.severity, .normal)
        XCTAssertEqual(decision.conditions, [])
        XCTAssertEqual(decision.refreshInterval, 5)
        XCTAssertFalse(decision.shouldReleaseDisplayLease)
        XCTAssertFalse(decision.shouldReleaseSystemLease)
        XCTAssertFalse(decision.shouldEndClamshellProtection)
    }

    func testSafetyPolicyLowersSamplingForLowPowerAndFairThermalState() {
        let decision = SystemSafetyPolicy.evaluate(
            makeSafetySnapshot(lowPowerModeEnabled: true, thermalState: .fair),
            batteryFloorPercent: 20
        )

        XCTAssertEqual(decision.severity, .efficient)
        XCTAssertEqual(Set(decision.conditions), [.lowPowerMode, .thermalFair])
        XCTAssertEqual(decision.refreshInterval, 15)
        XCTAssertFalse(decision.shouldReleaseDisplayLease)
        XCTAssertFalse(decision.shouldReleaseSystemLease)
    }

    func testSafetyPolicyRetractsDisplayAndClamshellAtSeriousThermalState() {
        let decision = SystemSafetyPolicy.evaluate(
            makeSafetySnapshot(thermalState: .serious),
            batteryFloorPercent: 20
        )

        XCTAssertEqual(decision.severity, .degraded)
        XCTAssertTrue(decision.shouldReleaseDisplayLease)
        XCTAssertFalse(decision.shouldReleaseSystemLease)
        XCTAssertTrue(decision.shouldEndClamshellProtection)
    }

    func testSafetyPolicyReleasesAllLeasesAtCriticalThermalState() {
        let decision = SystemSafetyPolicy.evaluate(
            makeSafetySnapshot(thermalState: .critical),
            batteryFloorPercent: 20
        )

        XCTAssertEqual(decision.severity, .critical)
        XCTAssertTrue(decision.shouldReleaseDisplayLease)
        XCTAssertTrue(decision.shouldReleaseSystemLease)
        XCTAssertTrue(decision.shouldEndClamshellProtection)
        XCTAssertEqual(decision.refreshInterval, 60)
    }

    func testSafetyPolicyAppliesBatteryFloorOnlyWhileUsingBattery() {
        let battery = PowerSourceSnapshotBuilder.build(
            providingSource: "Battery Power",
            currentCapacity: 20,
            maximumCapacity: 100,
            isCharging: false
        )
        let ac = PowerSourceSnapshotBuilder.build(
            providingSource: "AC Power",
            currentCapacity: 20,
            maximumCapacity: 100,
            isCharging: false
        )

        let batteryDecision = SystemSafetyPolicy.evaluate(
            makeSafetySnapshot(powerSource: battery),
            batteryFloorPercent: 20
        )
        let acDecision = SystemSafetyPolicy.evaluate(
            makeSafetySnapshot(powerSource: ac),
            batteryFloorPercent: 20
        )

        XCTAssertTrue(batteryDecision.conditions.contains(.batteryAtOrBelowFloor))
        XCTAssertTrue(batteryDecision.shouldEndClamshellProtection)
        XCTAssertFalse(acDecision.conditions.contains(.batteryAtOrBelowFloor))
        XCTAssertFalse(acDecision.shouldEndClamshellProtection)
    }

    func testSafetyPolicyDoesNotEnableHighRiskControlsFromUnknownReadings() {
        let unknownThermal = SystemSafetyPolicy.evaluate(
            makeSafetySnapshot(
                thermalState: .unknown,
                powerSource: .unavailable
            ),
            batteryFloorPercent: 20
        )
        let unknownBatteryLevel = PowerSourceSnapshot(
            isAvailable: true,
            kind: .battery,
            batteryLevelPercent: nil,
            isCharging: nil,
            detail: "电池供电 · 电量未知"
        )
        let unknownBattery = SystemSafetyPolicy.evaluate(
            makeSafetySnapshot(powerSource: unknownBatteryLevel),
            batteryFloorPercent: 20
        )

        XCTAssertEqual(unknownThermal.severity, .degraded)
        XCTAssertTrue(unknownThermal.shouldReleaseDisplayLease)
        XCTAssertTrue(unknownThermal.shouldEndClamshellProtection)
        XCTAssertTrue(unknownBattery.conditions.contains(.batteryLevelUnknown))
        XCTAssertTrue(unknownBattery.shouldEndClamshellProtection)
    }

    func testSafetyStateMachineReportsOnlyDecisionChanges() {
        let machine = SystemSafetyStateMachine()
        let first = machine.ingest(makeSafetySnapshot(), batteryFloorPercent: 20)
        let same = machine.ingest(
            makeSafetySnapshot(observedAt: Date(timeIntervalSince1970: 2)),
            batteryFloorPercent: 20
        )
        let changed = machine.ingest(
            makeSafetySnapshot(thermalState: .serious),
            batteryFloorPercent: 20
        )

        XCTAssertTrue(first.didChange)
        XCTAssertFalse(same.didChange)
        XCTAssertTrue(changed.didChange)
    }

    func testSafetyMonitorRespondsToProcessInfoNotification() {
        let notificationCenter = NotificationCenter()
        let systemState = TestLockedBox(
            makeSystemState(lowPowerModeEnabled: false, thermalState: .nominal)
        )
        let receivedEvent = TestLockedBox<SystemSafetyEvent?>(nil)
        let monitor = SystemSafetyMonitor(
            systemStateReader: { systemState.value },
            powerSourceReader: {
                PowerSourceSnapshotBuilder.build(
                    providingSource: "AC Power",
                    currentCapacity: 100,
                    maximumCapacity: 100,
                    isCharging: false
                )
            },
            clock: { Date(timeIntervalSince1970: 1) },
            notificationCenter: notificationCenter,
            sources: .processInfo
        )
        monitor.start { event in
            if event.reason == .lowPowerMode {
                receivedEvent.value = event
            }
        }

        systemState.value = makeSystemState(
            lowPowerModeEnabled: true,
            thermalState: .nominal
        )
        notificationCenter.post(
            name: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil
        )
        monitor.stop()

        XCTAssertEqual(receivedEvent.value?.reason, .lowPowerMode)
        XCTAssertEqual(receivedEvent.value?.snapshot.systemState.lowPowerModeEnabled, true)
    }

    func testSafetyMonitorRespondsToThermalNotification() {
        let notificationCenter = NotificationCenter()
        let systemState = TestLockedBox(
            makeSystemState(lowPowerModeEnabled: false, thermalState: .nominal)
        )
        let receivedEvent = TestLockedBox<SystemSafetyEvent?>(nil)
        let monitor = SystemSafetyMonitor(
            systemStateReader: { systemState.value },
            powerSourceReader: { .unavailable },
            notificationCenter: notificationCenter,
            sources: .processInfo
        )
        monitor.start { event in
            if event.reason == .thermalState {
                receivedEvent.value = event
            }
        }

        systemState.value = makeSystemState(
            lowPowerModeEnabled: false,
            thermalState: .serious
        )
        notificationCenter.post(
            name: ProcessInfo.thermalStateDidChangeNotification,
            object: nil
        )
        monitor.stop()

        XCTAssertEqual(receivedEvent.value?.reason, .thermalState)
        XCTAssertEqual(receivedEvent.value?.snapshot.systemState.thermalState, .serious)
    }

    func testDisplaySleepCommandIsAvailable() {
        XCTAssertTrue(DisplaySleepProbe.isAvailable)
    }

    func testDefaultPreferencesUseAgentModeWithoutDisplayLease() {
        let preferences = LumosPreferences.defaults

        XCTAssertEqual(preferences.selectedProfileID, LumosPreferences.agentProfileID)
        XCTAssertEqual(preferences.version, LumosPreferences.schemaVersion)
        XCTAssertEqual(preferences.selectedProfile?.name, "Agent 模式")
        XCTAssertEqual(preferences.selectedProfile?.presetKind, .taskGuard)
        XCTAssertEqual(
            preferences.profiles.map(\.name),
            ["Agent 模式", "随时可达", "保持亮屏"]
        )
        XCTAssertTrue(preferences.activeControls.preventSystemIdleSleep)
        XCTAssertFalse(preferences.activeControls.preventDisplayIdleSleep)
        XCTAssertTrue(preferences.activeControls.preferLowPowerMode)
        XCTAssertFalse(preferences.activeControls.requestClamshellProtection)
        XCTAssertEqual(preferences.activeControls.clamshellMaximumDurationMinutes, 120)
        XCTAssertEqual(preferences.activeControls.clamshellBatteryFloorPercent, 20)
    }

    func testCustomProfileCanBeCreatedSelectedAndDeleted() {
        var preferences = LumosPreferences.defaults
        let custom = preferences.duplicateSelectedProfile(name: "夜间构建")

        XCTAssertEqual(preferences.selectedProfileID, custom.id)
        XCTAssertEqual(preferences.profiles.count, 4)
        XCTAssertEqual(custom.presetKind, .taskGuard)

        preferences.deleteProfile(id: custom.id)
        XCTAssertEqual(preferences.selectedProfileID, LumosPreferences.agentProfileID)
        XCTAssertEqual(
            preferences.profiles.map(\.name),
            ["Agent 模式", "随时可达", "保持亮屏"]
        )
    }

    func testPreferencesStoreRoundTripsAndNormalizesWhitelist() throws {
        let suite = "ai.lovstudio.lumos.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = LumosPreferencesStore(defaults: defaults)
        var preferences = LumosPreferences.defaults
        preferences.watchedApplications = [
            WatchedApplication(id: "com.example.agent", displayName: "Agent", executablePath: nil),
            WatchedApplication(id: "com.example.agent", displayName: "Duplicate", executablePath: nil),
        ]
        preferences.normalize()
        try store.save(preferences)

        XCTAssertEqual(store.load(), preferences)
        XCTAssertEqual(store.load().watchedApplications.count, 1)
    }

    func testProfileApplicationTargetsAreDeduplicatedAndBoundToKnownApplications() {
        let application = WatchedApplication(
            id: "com.example.agent",
            displayName: "Agent",
            executablePath: nil
        )
        let profile = LumosProfile(
            name: "Targeted",
            summary: "Test",
            controls: LumosPreferences.agentMode.controls,
            watchedApplicationIDs: [application.id, application.id, "com.example.unknown"]
        )

        let preferences = LumosPreferences(
            selectedProfileID: profile.id,
            activeControls: profile.controls,
            profiles: [profile],
            watchedApplications: [application]
        )

        XCTAssertEqual(preferences.selectedProfile?.watchedApplicationIDs, [application.id])
    }

    func testLegacyProfileWithoutApplicationTargetsStillDecodes() throws {
        let profile = LumosPreferences.agentMode
        let json = """
        {
          "id": "\(profile.id.uuidString)",
          "name": "Agent 模式",
          "summary": "Legacy",
          "controls": {
            "preventDisplayIdleSleep": false,
            "preventSystemIdleSleep": true,
            "requestClamshellProtection": false,
            "preferLowPowerMode": true
          },
          "isBuiltIn": true
        }
        """

        let decoded = try JSONDecoder().decode(LumosProfile.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.watchedApplicationIDs, [])
        XCTAssertEqual(decoded.presetKind, .taskGuard)
        XCTAssertEqual(decoded.controls.clamshellMaximumDurationMinutes, 120)
        XCTAssertEqual(decoded.controls.clamshellBatteryFloorPercent, 20)
    }

    func testLegacyPreferencesAddNewBuiltInsAndAdvanceSchemaVersion() {
        let agent = LumosPreferences.agentMode
        let migrated = LumosPreferences(
            version: 1,
            selectedProfileID: agent.id,
            activeControls: agent.controls,
            profiles: [agent],
            watchedApplications: []
        )

        XCTAssertEqual(migrated.version, 2)
        XCTAssertEqual(
            migrated.profiles.map(\.presetKind),
            [.taskGuard, .alwaysReachable, .keepDisplayAwake]
        )
    }

    func testTaskGuardRunsFromTargetTriggerThroughFinalTargetExit() throws {
        var assertions: [FakeWakeAssertion] = []
        let engine = WakeLeaseEngine { kind, _ in
            let assertion = FakeWakeAssertion(kind: kind)
            assertions.append(assertion)
            return assertion
        }
        let controller = PresetSessionController(wakeLeaseEngine: engine)

        let waiting = try controller.start(
            PresetSessionContext(
                presetKind: .taskGuard,
                leaseKinds: [.systemIdleSleep],
                hasConfiguredTargets: true,
                matchedTargetCount: 0
            ),
            reason: "Task Guard test"
        )
        XCTAssertEqual(waiting.phase, .waitingForTarget)
        XCTAssertTrue(assertions.isEmpty)

        let triggered = try controller.update(
            PresetSessionContext(
                presetKind: .taskGuard,
                leaseKinds: [.systemIdleSleep],
                hasConfiguredTargets: true,
                matchedTargetCount: 2
            ),
            reason: "Task Guard test"
        )
        XCTAssertEqual(triggered.phase, .active)
        XCTAssertEqual(triggered.activeLeaseKinds, [.systemIdleSleep])
        XCTAssertEqual(assertions.count, 1)
        XCTAssertTrue(engine.isActive(.systemIdleSleep))

        let oneTargetRemaining = try controller.update(
            PresetSessionContext(
                presetKind: .taskGuard,
                leaseKinds: [.systemIdleSleep],
                hasConfiguredTargets: true,
                matchedTargetCount: 1
            ),
            reason: "Task Guard test"
        )
        XCTAssertEqual(oneTargetRemaining.phase, .active)
        XCTAssertEqual(assertions[0].releaseCount, 0)

        let completed = try controller.update(
            PresetSessionContext(
                presetKind: .taskGuard,
                leaseKinds: [.systemIdleSleep],
                hasConfiguredTargets: true,
                matchedTargetCount: 0
            ),
            reason: "Task Guard test"
        )
        XCTAssertEqual(completed.phase, .completed)
        XCTAssertEqual(completed.exitReason, .targetsFinished)
        XCTAssertEqual(assertions[0].releaseCount, 1)
        XCTAssertFalse(engine.isActive(.systemIdleSleep))
    }

    func testTaskGuardWithoutConfiguredTargetsUsesManualSession() throws {
        let engine = WakeLeaseEngine { kind, _ in
            FakeWakeAssertion(kind: kind)
        }
        let controller = PresetSessionController(wakeLeaseEngine: engine)

        let active = try controller.start(
            PresetSessionContext(
                presetKind: .taskGuard,
                leaseKinds: [.systemIdleSleep],
                hasConfiguredTargets: false,
                matchedTargetCount: 0
            ),
            reason: "Manual Task Guard test"
        )

        XCTAssertEqual(active.phase, .active)
        XCTAssertTrue(engine.isActive(.systemIdleSleep))
        _ = try controller.stop()
        XCTAssertFalse(engine.isActive(.systemIdleSleep))
    }

    func testKeepDisplayAwakeRunsFromManualTriggerThroughManualExit() throws {
        var assertions: [FakeWakeAssertion] = []
        let engine = WakeLeaseEngine { kind, _ in
            let assertion = FakeWakeAssertion(kind: kind)
            assertions.append(assertion)
            return assertion
        }
        let controller = PresetSessionController(wakeLeaseEngine: engine)

        let active = try controller.start(
            PresetSessionContext(
                presetKind: .keepDisplayAwake,
                leaseKinds: [.displayIdleSleep],
                hasConfiguredTargets: false,
                matchedTargetCount: 0
            ),
            reason: "Keep Display Awake test"
        )
        XCTAssertEqual(active.phase, .active)
        XCTAssertEqual(active.activeLeaseKinds, [.displayIdleSleep])
        XCTAssertTrue(engine.isActive(.displayIdleSleep))
        XCTAssertFalse(engine.isActive(.systemIdleSleep))

        let stopped = try controller.stop()
        XCTAssertEqual(stopped.phase, .stopped)
        XCTAssertEqual(stopped.exitReason, .userStopped)
        XCTAssertEqual(assertions.count, 1)
        XCTAssertEqual(assertions[0].releaseCount, 1)
        XCTAssertFalse(engine.isActive(.displayIdleSleep))
    }

    func testAlwaysReachableIgnoresTargetExitAndReleasesOnlyWhenStopped() throws {
        var assertion: FakeWakeAssertion?
        let engine = WakeLeaseEngine { kind, _ in
            let created = FakeWakeAssertion(kind: kind)
            assertion = created
            return created
        }
        let controller = PresetSessionController(wakeLeaseEngine: engine)

        let active = try controller.start(
            PresetSessionContext(
                presetKind: .alwaysReachable,
                leaseKinds: [.systemIdleSleep],
                hasConfiguredTargets: true,
                matchedTargetCount: 0
            ),
            reason: "Always Reachable test"
        )
        XCTAssertEqual(active.phase, .active)
        XCTAssertTrue(engine.isActive(.systemIdleSleep))

        let stillActive = try controller.update(
            PresetSessionContext(
                presetKind: .alwaysReachable,
                leaseKinds: [.systemIdleSleep],
                hasConfiguredTargets: true,
                matchedTargetCount: 0
            ),
            reason: "Always Reachable test"
        )
        XCTAssertEqual(stillActive.phase, .active)
        XCTAssertEqual(assertion?.releaseCount, 0)

        let stopped = try controller.stop()
        XCTAssertEqual(stopped.phase, .stopped)
        XCTAssertEqual(assertion?.releaseCount, 1)
        XCTAssertFalse(engine.isActive(.systemIdleSleep))
    }

    func testDisplayPresetSuspendsAndRecoversAcrossSafetyBoundary() throws {
        var assertions: [FakeWakeAssertion] = []
        let engine = WakeLeaseEngine { kind, _ in
            let assertion = FakeWakeAssertion(kind: kind)
            assertions.append(assertion)
            return assertion
        }
        let controller = PresetSessionController(wakeLeaseEngine: engine)

        _ = try controller.start(
            PresetSessionContext(
                presetKind: .keepDisplayAwake,
                leaseKinds: [.displayIdleSleep],
                hasConfiguredTargets: false,
                matchedTargetCount: 0
            ),
            reason: "Display safety test"
        )
        let suspended = try controller.update(
            PresetSessionContext(
                presetKind: .keepDisplayAwake,
                leaseKinds: [],
                hasConfiguredTargets: false,
                matchedTargetCount: 0,
                safetySuspended: true
            ),
            reason: "Display safety test"
        )
        XCTAssertEqual(suspended.phase, .suspendedForSafety)
        XCTAssertEqual(assertions[0].releaseCount, 1)

        let recovered = try controller.update(
            PresetSessionContext(
                presetKind: .keepDisplayAwake,
                leaseKinds: [.displayIdleSleep],
                hasConfiguredTargets: false,
                matchedTargetCount: 0
            ),
            reason: "Display safety test"
        )
        XCTAssertEqual(recovered.phase, .active)
        XCTAssertEqual(assertions.count, 2)
        XCTAssertTrue(engine.isActive(.displayIdleSleep))
    }

    func testClamshellStatusParserHandlesLivePmsetOutput() {
        XCTAssertTrue(
            ClamshellSleepOutputParser.isSleepDisabled(
                "System-wide power settings:\nCurrently in use:\n SleepDisabled 1\n"
            )
        )
        XCTAssertFalse(
            ClamshellSleepOutputParser.isSleepDisabled(
                "System-wide power settings:\nCurrently in use:\n standbydelayhigh 4200\n"
            )
        )
    }

    func testClamshellActivationDoesNotTakeOwnershipOfExternalSetting() {
        let marker = temporaryMarkerURL()
        var authorizationCalled = false
        let controller = ClamshellSleepController(
            markerURL: marker,
            processIdentifier: getpid(),
            statusReader: { "SleepDisabled 1" },
            privilegedExecutor: { _ in
                authorizationCalled = true
                return .succeeded
            },
            sleeper: { _ in }
        )

        let result = controller.activate(maximumDurationMinutes: 120, batteryFloorPercent: 20)

        XCTAssertEqual(result.state, .externallyManaged)
        XCTAssertEqual(result.snapshot.ownership, .external)
        XCTAssertFalse(authorizationCalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testClamshellActivationBuildsBoundedWatchdogAndRestoresOnStop() throws {
        let marker = temporaryMarkerURL()
        defer { try? FileManager.default.removeItem(at: marker.deletingLastPathComponent()) }
        var command = ""
        let controller = ClamshellSleepController(
            markerURL: marker,
            processIdentifier: 4242,
            statusReader: {
                FileManager.default.fileExists(atPath: marker.path)
                    ? "SleepDisabled 1"
                    : ""
            },
            privilegedExecutor: {
                command = $0
                return .succeeded
            },
            clock: { Date(timeIntervalSince1970: 1_000) },
            sleeper: { _ in }
        )

        let activated = controller.activate(maximumDurationMinutes: 60, batteryFloorPercent: 25)
        XCTAssertEqual(activated.state, .activated)
        XCTAssertEqual(activated.snapshot.ownership, .lumos)
        XCTAssertTrue(command.contains("/usr/bin/pmset -a disablesleep 1"))
        XCTAssertTrue(command.contains("/usr/bin/pmset -a disablesleep 0"))
        XCTAssertTrue(command.contains("/bin/kill -0 4242"))
        XCTAssertTrue(command.contains("/bin/test -f"))
        XCTAssertTrue(command.contains("-le 25"))
        XCTAssertTrue(command.contains("4600"))

        let syntaxCheck = Process()
        syntaxCheck.executableURL = URL(fileURLWithPath: "/bin/sh")
        syntaxCheck.arguments = ["-n", "-c", command]
        try syntaxCheck.run()
        syntaxCheck.waitUntilExit()
        XCTAssertEqual(syntaxCheck.terminationStatus, 0)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: "/bin/test"))

        let deactivated = controller.deactivate()
        XCTAssertEqual(deactivated.state, .deactivated)
        XCTAssertFalse(deactivated.snapshot.isSleepDisabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testClamshellCancelledAuthorizationLeavesNoMarker() {
        let marker = temporaryMarkerURL()
        defer { try? FileManager.default.removeItem(at: marker.deletingLastPathComponent()) }
        let controller = ClamshellSleepController(
            markerURL: marker,
            processIdentifier: 4242,
            statusReader: { "" },
            privilegedExecutor: { _ in .cancelled },
            sleeper: { _ in }
        )

        let result = controller.activate(maximumDurationMinutes: 120, batteryFloorPercent: 20)

        XCTAssertEqual(result.state, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testLowPowerModeParserReadsCurrentStateAndPowerSource() {
        XCTAssertEqual(
            LowPowerModeOutputParser.isEnabled("Currently in use:\n lowpowermode 1\n"),
            true
        )
        XCTAssertEqual(
            LowPowerModeOutputParser.powerSource("Now drawing from 'AC Power'\n"),
            .acPower
        )
        XCTAssertEqual(
            LowPowerModeOutputParser.powerSource("Now drawing from 'Battery Power'\n"),
            .battery
        )
    }

    func testLowPowerModeChangesOnlyCurrentPowerSourceAndReadsBack() {
        var enabled = false
        var command = ""
        let controller = LowPowerModeController(
            statusReader: {
                (
                    settings: "lowpowermode \(enabled ? 1 : 0)",
                    battery: "Now drawing from 'AC Power'"
                )
            },
            privilegedExecutor: {
                command = $0
                enabled = true
                return .succeeded
            },
            sleeper: { _ in }
        )

        let result = controller.setEnabled(true)

        XCTAssertEqual(result.state, .updated)
        XCTAssertTrue(result.snapshot.isEnabled)
        XCTAssertEqual(command, "/usr/bin/pmset -c lowpowermode 1")
    }

    func testLowPowerModeDoesNotAuthorizeWhenStateAlreadyMatches() {
        var authorizationCalled = false
        let controller = LowPowerModeController(
            statusReader: {
                (settings: "lowpowermode 1", battery: "Now drawing from 'Battery Power'")
            },
            privilegedExecutor: { _ in
                authorizationCalled = true
                return .succeeded
            }
        )

        let result = controller.setEnabled(true)

        XCTAssertEqual(result.state, .unchanged)
        XCTAssertFalse(authorizationCalled)
    }

    func testLowPowerModeCancelledAuthorizationKeepsLiveState() {
        let controller = LowPowerModeController(
            statusReader: {
                (settings: "lowpowermode 0", battery: "Now drawing from 'AC Power'")
            },
            privilegedExecutor: { _ in .cancelled }
        )

        let result = controller.setEnabled(true)

        XCTAssertEqual(result.state, .cancelled)
        XCTAssertFalse(result.snapshot.isEnabled)
    }

    func testWakeLeaseEngineSharesAssertionUntilFinalReceiptReleases() throws {
        var assertions: [FakeWakeAssertion] = []
        let engine = WakeLeaseEngine { kind, _ in
            let assertion = FakeWakeAssertion(kind: kind)
            assertions.append(assertion)
            return assertion
        }

        let first = try engine.acquire(kind: .systemIdleSleep, reason: "first")
        let second = try engine.acquire(kind: .systemIdleSleep, reason: "second")

        XCTAssertEqual(assertions.count, 1)
        XCTAssertEqual(engine.snapshot().referenceCount(for: .systemIdleSleep), 2)

        try first.release()
        try first.release()
        XCTAssertEqual(engine.snapshot().referenceCount(for: .systemIdleSleep), 1)
        XCTAssertEqual(assertions[0].releaseCount, 0)

        try second.release()
        XCTAssertFalse(engine.isActive(.systemIdleSleep))
        XCTAssertEqual(assertions[0].releaseCount, 1)
    }

    func testWakeLeaseEngineMultiKindReceiptReleasesBothAssertions() throws {
        var assertions: [PowerAssertionKind: FakeWakeAssertion] = [:]
        let engine = WakeLeaseEngine { kind, _ in
            let assertion = FakeWakeAssertion(kind: kind)
            assertions[kind] = assertion
            return assertion
        }

        let receipt = try engine.acquire(
            kinds: [.systemIdleSleep, .displayIdleSleep],
            reason: "combined"
        )

        XCTAssertTrue(engine.isActive(.systemIdleSleep))
        XCTAssertTrue(engine.isActive(.displayIdleSleep))
        try receipt.release()
        XCTAssertEqual(assertions[.systemIdleSleep]?.releaseCount, 1)
        XCTAssertEqual(assertions[.displayIdleSleep]?.releaseCount, 1)
        XCTAssertEqual(engine.snapshot().referenceCounts, [:])
    }

    func testWakeLeaseEngineRollsBackPartiallyCreatedAssertions() {
        var systemAssertion: FakeWakeAssertion?
        let engine = WakeLeaseEngine { kind, _ in
            if kind == .displayIdleSleep {
                throw TestWakeLeaseError.expectedFailure
            }
            let assertion = FakeWakeAssertion(kind: kind)
            systemAssertion = assertion
            return assertion
        }

        XCTAssertThrowsError(
            try engine.acquire(
                kinds: [.systemIdleSleep, .displayIdleSleep],
                reason: "must roll back"
            )
        )
        XCTAssertEqual(systemAssertion?.releaseCount, 1)
        XCTAssertEqual(engine.snapshot().referenceCounts, [:])
    }

    func testWakeLeaseReceiptDeinitReturnsReference() throws {
        var assertion: FakeWakeAssertion?
        let engine = WakeLeaseEngine { kind, _ in
            let created = FakeWakeAssertion(kind: kind)
            assertion = created
            return created
        }

        var receipt: WakeLeaseReceipt? = try engine.acquire(
            kind: .displayIdleSleep,
            reason: "temporary"
        )
        XCTAssertNotNil(receipt)
        XCTAssertTrue(engine.isActive(.displayIdleSleep))

        receipt = nil

        XCTAssertFalse(engine.isActive(.displayIdleSleep))
        XCTAssertEqual(assertion?.releaseCount, 1)
    }

    func testWakeLeaseEngineDrivesRealIOKitAssertionLifecycle() throws {
        let engine = WakeLeaseEngine()
        let first = try engine.acquire(kind: .systemIdleSleep, reason: "Lumos Engine XCTest 1")
        let second = try engine.acquire(kind: .systemIdleSleep, reason: "Lumos Engine XCTest 2")

        XCTAssertTrue(engine.isActive(.systemIdleSleep))
        XCTAssertEqual(engine.snapshot().referenceCount(for: .systemIdleSleep), 2)

        try first.release()
        XCTAssertTrue(engine.isActive(.systemIdleSleep))
        try second.release()
        XCTAssertFalse(engine.isActive(.systemIdleSleep))
    }

    func testWakeLeaseEngineRejectsInactiveDriverHandle() {
        let engine = WakeLeaseEngine { kind, _ in
            FakeWakeAssertion(kind: kind, isActive: false)
        }

        XCTAssertThrowsError(
            try engine.acquire(kind: .systemIdleSleep, reason: "inactive")
        ) { error in
            XCTAssertEqual(
                error as? WakeLeaseEngineError,
                .driverReturnedInactive(.systemIdleSleep)
            )
        }
        XCTAssertEqual(engine.snapshot().referenceCounts, [:])
    }

    func testWakeLeaseEngineRejectsMismatchedDriverHandle() {
        let assertion = FakeWakeAssertion(kind: .displayIdleSleep)
        let engine = WakeLeaseEngine { _, _ in assertion }

        XCTAssertThrowsError(
            try engine.acquire(kind: .systemIdleSleep, reason: "mismatch")
        ) { error in
            XCTAssertEqual(
                error as? WakeLeaseEngineError,
                .driverKindMismatch(expected: .systemIdleSleep, actual: .displayIdleSleep)
            )
        }
        XCTAssertEqual(assertion.releaseCount, 1)
        XCTAssertEqual(engine.snapshot().referenceCounts, [:])
    }

    private func temporaryMarkerURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lumos-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("clamshell-session.json")
    }

    private func makeSystemState(
        lowPowerModeEnabled: Bool = false,
        thermalState: ThermalStateLabel = .nominal
    ) -> SystemStateSnapshot {
        SystemStateSnapshot(
            lowPowerModeEnabled: lowPowerModeEnabled,
            thermalState: thermalState,
            operatingSystemVersion: "test",
            processorCount: 8,
            activeProcessorCount: 8,
            physicalMemoryBytes: 16_000_000_000
        )
    }

    private func makeSafetySnapshot(
        lowPowerModeEnabled: Bool = false,
        thermalState: ThermalStateLabel = .nominal,
        powerSource: PowerSourceSnapshot? = nil,
        networkPath: NetworkPathSnapshot? = nil,
        observedAt: Date = Date(timeIntervalSince1970: 1)
    ) -> SystemSafetySnapshot {
        SystemSafetySnapshot(
            systemState: makeSystemState(
                lowPowerModeEnabled: lowPowerModeEnabled,
                thermalState: thermalState
            ),
            powerSource: powerSource ?? PowerSourceSnapshotBuilder.build(
                providingSource: "AC Power",
                currentCapacity: 100,
                maximumCapacity: 100,
                isCharging: false
            ),
            networkPath: networkPath ?? NetworkPathSnapshot(
                status: .satisfied,
                isExpensive: false,
                isConstrained: false,
                supportsIPv4: true,
                supportsIPv6: true,
                supportsDNS: true,
                interfaces: ["wifi:en0"]
            ),
            observedAt: observedAt
        )
    }
}

private enum TestWakeLeaseError: Error {
    case expectedFailure
}

private final class TestLockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value

    init(_ value: Value) {
        storedValue = value
    }

    var value: Value {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = newValue } }
    }
}

private final class FakeWakeAssertion: WakeAssertionHandle {
    let kind: PowerAssertionKind
    private(set) var releaseCount = 0
    private(set) var isActive: Bool

    init(kind: PowerAssertionKind, isActive: Bool = true) {
        self.kind = kind
        self.isActive = isActive
    }

    func release() throws {
        guard isActive else { return }
        isActive = false
        releaseCount += 1
    }
}
