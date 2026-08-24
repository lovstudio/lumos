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
    }
}
