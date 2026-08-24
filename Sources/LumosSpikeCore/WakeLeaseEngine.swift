import Foundation

public enum WakeLeaseEngineError: Error, CustomStringConvertible, Equatable, Sendable {
    case emptyRequest
    case driverKindMismatch(expected: PowerAssertionKind, actual: PowerAssertionKind)
    case driverReturnedInactive(PowerAssertionKind)

    public var description: String {
        switch self {
        case .emptyRequest:
            "Wake lease must request at least one control."
        case .driverKindMismatch(let expected, let actual):
            "Assertion driver returned \(actual.rawValue) for \(expected.rawValue)."
        case .driverReturnedInactive(let kind):
            "Assertion driver returned an inactive \(kind.rawValue) handle."
        }
    }
}

public struct WakeLeaseEngineSnapshot: Equatable, Sendable {
    public let referenceCounts: [PowerAssertionKind: Int]

    public init(referenceCounts: [PowerAssertionKind: Int]) {
        self.referenceCounts = referenceCounts
    }

    public func referenceCount(for kind: PowerAssertionKind) -> Int {
        referenceCounts[kind, default: 0]
    }

    public func isActive(_ kind: PowerAssertionKind) -> Bool {
        referenceCount(for: kind) > 0
    }
}

public final class WakeLeaseReceipt: @unchecked Sendable {
    public let id: UUID
    public let kinds: Set<PowerAssertionKind>
    public let reason: String

    private let lock = NSLock()
    private weak var engine: WakeLeaseEngine?
    private var released = false

    fileprivate init(
        id: UUID,
        kinds: Set<PowerAssertionKind>,
        reason: String,
        engine: WakeLeaseEngine
    ) {
        self.id = id
        self.kinds = kinds
        self.reason = reason
        self.engine = engine
    }

    public var isReleased: Bool {
        lock.withLock { released }
    }

    public func release() throws {
        let target = lock.withLock { () -> WakeLeaseEngine? in
            guard !released else { return nil }
            released = true
            return engine
        }
        try target?.releaseReceipt(id: id)
    }

    deinit {
        try? release()
    }
}

/// The only owner of process-scoped IOPM assertions.
///
/// Every caller receives a receipt. Assertions are shared by kind and released
/// only after the final receipt for that kind is returned.
public final class WakeLeaseEngine: @unchecked Sendable {
    public typealias AssertionFactory = (
        _ kind: PowerAssertionKind,
        _ reason: String
    ) throws -> any WakeAssertionHandle

    private struct KindState {
        let assertion: any WakeAssertionHandle
        var receiptIDs: Set<UUID>
    }

    private let lock = NSLock()
    private let assertionFactory: AssertionFactory
    private var states: [PowerAssertionKind: KindState] = [:]
    private var receiptKinds: [UUID: Set<PowerAssertionKind>] = [:]

    public convenience init() {
        self.init { kind, reason in
            try PowerAssertion(kind: kind, reason: reason)
        }
    }

    public init(assertionFactory: @escaping AssertionFactory) {
        self.assertionFactory = assertionFactory
    }

    public func acquire(
        kinds: Set<PowerAssertionKind>,
        reason: String
    ) throws -> WakeLeaseReceipt {
        guard !kinds.isEmpty else { throw WakeLeaseEngineError.emptyRequest }

        let id = UUID()
        return try lock.withLock {
            var created: [PowerAssertionKind: any WakeAssertionHandle] = [:]
            do {
                for kind in PowerAssertionKind.allCases where kinds.contains(kind) && states[kind] == nil {
                    let assertion = try assertionFactory(kind, reason)
                    guard assertion.kind == kind else {
                        try? assertion.release()
                        throw WakeLeaseEngineError.driverKindMismatch(
                            expected: kind,
                            actual: assertion.kind
                        )
                    }
                    guard assertion.isActive else {
                        try? assertion.release()
                        throw WakeLeaseEngineError.driverReturnedInactive(kind)
                    }
                    created[kind] = assertion
                }
            } catch {
                for assertion in created.values {
                    try? assertion.release()
                }
                throw error
            }

            for kind in kinds {
                if var state = states[kind] {
                    state.receiptIDs.insert(id)
                    states[kind] = state
                } else if let assertion = created[kind] {
                    states[kind] = KindState(assertion: assertion, receiptIDs: [id])
                }
            }
            receiptKinds[id] = kinds

            return WakeLeaseReceipt(
                id: id,
                kinds: kinds,
                reason: reason,
                engine: self
            )
        }
    }

    public func acquire(
        kind: PowerAssertionKind,
        reason: String
    ) throws -> WakeLeaseReceipt {
        try acquire(kinds: [kind], reason: reason)
    }

    public func snapshot() -> WakeLeaseEngineSnapshot {
        lock.withLock {
            WakeLeaseEngineSnapshot(
                referenceCounts: states.mapValues(\.receiptIDs.count)
            )
        }
    }

    public func isActive(_ kind: PowerAssertionKind) -> Bool {
        lock.withLock {
            guard let state = states[kind] else { return false }
            return !state.receiptIDs.isEmpty && state.assertion.isActive
        }
    }

    public func releaseAll() throws {
        let assertions = lock.withLock { () -> [any WakeAssertionHandle] in
            let assertions = states.values.map(\.assertion)
            states.removeAll()
            receiptKinds.removeAll()
            return assertions
        }
        try Self.release(assertions)
    }

    fileprivate func releaseReceipt(id: UUID) throws {
        let assertions = lock.withLock { () -> [any WakeAssertionHandle] in
            guard let kinds = receiptKinds.removeValue(forKey: id) else { return [] }
            var released: [any WakeAssertionHandle] = []
            for kind in kinds {
                guard var state = states[kind] else { continue }
                state.receiptIDs.remove(id)
                if state.receiptIDs.isEmpty {
                    states.removeValue(forKey: kind)
                    released.append(state.assertion)
                } else {
                    states[kind] = state
                }
            }
            return released
        }
        try Self.release(assertions)
    }

    private static func release(_ assertions: [any WakeAssertionHandle]) throws {
        var firstError: (any Error)?
        for assertion in assertions {
            do {
                try assertion.release()
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }

    deinit {
        try? releaseAll()
    }
}
