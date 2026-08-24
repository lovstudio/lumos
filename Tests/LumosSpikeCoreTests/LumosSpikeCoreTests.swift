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
}
