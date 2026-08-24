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

    func testDisplaySleepCommandIsAvailable() {
        XCTAssertTrue(DisplaySleepProbe.isAvailable)
    }

    func testDefaultPreferencesUseAgentModeWithoutDisplayLease() {
        let preferences = LumosPreferences.defaults

        XCTAssertEqual(preferences.selectedProfileID, LumosPreferences.agentProfileID)
        XCTAssertEqual(preferences.selectedProfile?.name, "Agent 模式")
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
        XCTAssertEqual(preferences.profiles.count, 2)

        preferences.deleteProfile(id: custom.id)
        XCTAssertEqual(preferences.selectedProfileID, LumosPreferences.agentProfileID)
        XCTAssertEqual(preferences.profiles.map(\.name), ["Agent 模式"])
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
        XCTAssertEqual(decoded.controls.clamshellMaximumDurationMinutes, 120)
        XCTAssertEqual(decoded.controls.clamshellBatteryFloorPercent, 20)
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
}

private enum TestWakeLeaseError: Error {
    case expectedFailure
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
