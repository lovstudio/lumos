import Darwin
import Foundation

public enum ProcessObservationEvent: Equatable, Sendable {
    case started(ProcessSnapshot)
    case terminated(ProcessSnapshot)
    case replaced(previous: ProcessSnapshot, current: ProcessSnapshot)
}

public struct ProcessObservationFrame: Equatable, Sendable {
    public let processes: [ProcessSnapshot]
    public let events: [ProcessObservationEvent]
    public let isBaseline: Bool

    public init(
        processes: [ProcessSnapshot],
        events: [ProcessObservationEvent],
        isBaseline: Bool
    ) {
        self.processes = processes
        self.events = events
        self.isBaseline = isBaseline
    }

    public var processesByPID: [pid_t: ProcessSnapshot] {
        ProcessSnapshotDiffer.indexByPID(processes)
    }
}

public enum ProcessSnapshotDiffer {
    public static func indexByPID(_ processes: [ProcessSnapshot]) -> [pid_t: ProcessSnapshot] {
        Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { existing, candidate in
            candidate.stableIdentity.startTimestamp >= existing.stableIdentity.startTimestamp
                ? candidate
                : existing
        })
    }

    public static func events(
        previous: [ProcessSnapshot],
        current: [ProcessSnapshot]
    ) -> [ProcessObservationEvent] {
        let previousByPID = indexByPID(previous)
        let currentByPID = indexByPID(current)
        let allPIDs = Set(previousByPID.keys).union(currentByPID.keys).sorted()

        return allPIDs.compactMap { pid in
            switch (previousByPID[pid], currentByPID[pid]) {
            case (.none, .some(let process)):
                .started(process)
            case (.some(let process), .none):
                .terminated(process)
            case (.some(let old), .some(let new)) where old.stableIdentity != new.stableIdentity:
                .replaced(previous: old, current: new)
            case (.some, .some), (.none, .none):
                nil
            }
        }
    }
}

private extension ProcessIdentity {
    var startTimestamp: (UInt64, UInt64) {
        (startTimeSeconds, startTimeMicroseconds)
    }
}

/// Produces ordered process snapshots and lifecycle deltas. The first sample is
/// a baseline and intentionally emits no synthetic "started" events.
public final class ProcessObservationProvider: @unchecked Sendable {
    public typealias ProcessReader = () -> [ProcessSnapshot]

    private let lock = NSLock()
    private let processReader: ProcessReader
    private var previous: [ProcessSnapshot]?

    public convenience init() {
        self.init(processReader: ProcessProbe.allProcesses)
    }

    public init(processReader: @escaping ProcessReader) {
        self.processReader = processReader
    }

    public func sample() -> ProcessObservationFrame {
        lock.withLock {
            let current = processReader().sorted { $0.pid < $1.pid }
            guard let previous else {
                self.previous = current
                return ProcessObservationFrame(
                    processes: current,
                    events: [],
                    isBaseline: true
                )
            }

            let events = ProcessSnapshotDiffer.events(previous: previous, current: current)
            self.previous = current
            return ProcessObservationFrame(
                processes: current,
                events: events,
                isBaseline: false
            )
        }
    }

    public func reset() {
        lock.withLock {
            previous = nil
        }
    }
}
