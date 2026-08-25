import Foundation

public enum LumosPresetKind: String, Codable, CaseIterable, Equatable, Sendable {
    case taskGuard
    case alwaysReachable
    case keepDisplayAwake

    public var title: String {
        switch self {
        case .taskGuard: "任务守护"
        case .alwaysReachable: "随时可达"
        case .keepDisplayAwake: "保持亮屏"
        }
    }

    public var triggerDescription: String {
        switch self {
        case .taskGuard: "关注应用出现后自动开始"
        case .alwaysReachable: "用户开启后立即开始"
        case .keepDisplayAwake: "用户开启后立即开始"
        }
    }

    public var exitDescription: String {
        switch self {
        case .taskGuard: "最后一个关注应用退出后自动停止"
        case .alwaysReachable: "用户停止或达到安全边界"
        case .keepDisplayAwake: "用户停止或达到安全边界"
        }
    }
}

public enum PresetSessionPhase: String, Codable, Equatable, Sendable {
    case stopped
    case waitingForTarget
    case active
    case suspendedForSafety
    case completed

    public var isEnabled: Bool {
        switch self {
        case .waitingForTarget, .active, .suspendedForSafety: true
        case .stopped, .completed: false
        }
    }
}

public enum PresetSessionExitReason: String, Codable, Equatable, Sendable {
    case none
    case userStopped
    case targetsFinished
    case safetyBoundary
}

public struct PresetSessionContext: Equatable, Sendable {
    public let presetKind: LumosPresetKind
    public let leaseKinds: Set<PowerAssertionKind>
    public let hasConfiguredTargets: Bool
    public let matchedTargetCount: Int
    public let safetySuspended: Bool

    public init(
        presetKind: LumosPresetKind,
        leaseKinds: Set<PowerAssertionKind>,
        hasConfiguredTargets: Bool,
        matchedTargetCount: Int,
        safetySuspended: Bool = false
    ) {
        self.presetKind = presetKind
        self.leaseKinds = leaseKinds
        self.hasConfiguredTargets = hasConfiguredTargets
        self.matchedTargetCount = max(matchedTargetCount, 0)
        self.safetySuspended = safetySuspended
    }
}

public struct PresetSessionSnapshot: Equatable, Sendable {
    public let presetKind: LumosPresetKind?
    public let phase: PresetSessionPhase
    public let activeLeaseKinds: Set<PowerAssertionKind>
    public let exitReason: PresetSessionExitReason
    public let didObserveTarget: Bool

    public init(
        presetKind: LumosPresetKind?,
        phase: PresetSessionPhase,
        activeLeaseKinds: Set<PowerAssertionKind>,
        exitReason: PresetSessionExitReason,
        didObserveTarget: Bool
    ) {
        self.presetKind = presetKind
        self.phase = phase
        self.activeLeaseKinds = activeLeaseKinds
        self.exitReason = exitReason
        self.didObserveTarget = didObserveTarget
    }

    public static let stopped = PresetSessionSnapshot(
        presetKind: nil,
        phase: .stopped,
        activeLeaseKinds: [],
        exitReason: .none,
        didObserveTarget: false
    )
}

/// Owns one user-visible Preset session from trigger through assertion release.
///
/// Task Guard is armed while no configured target is running, acquires its
/// lease when the first target appears, and completes after the final target
/// exits. The other P0 presets are explicit user sessions and ignore process
/// count for both trigger and exit.
public final class PresetSessionController: @unchecked Sendable {
    private let lock = NSLock()
    private let wakeLeaseEngine: WakeLeaseEngine
    private var receipt: WakeLeaseReceipt?
    private var storedSnapshot: PresetSessionSnapshot = .stopped

    public init(wakeLeaseEngine: WakeLeaseEngine = WakeLeaseEngine()) {
        self.wakeLeaseEngine = wakeLeaseEngine
    }

    public var snapshot: PresetSessionSnapshot {
        lock.withLock { storedSnapshot }
    }

    @discardableResult
    public func start(_ context: PresetSessionContext, reason: String) throws -> PresetSessionSnapshot {
        try lock.withLock {
            try releaseReceipt()
            storedSnapshot = PresetSessionSnapshot(
                presetKind: context.presetKind,
                phase: .stopped,
                activeLeaseKinds: [],
                exitReason: .none,
                didObserveTarget: false
            )
            return try reconcile(context, reason: reason)
        }
    }

    @discardableResult
    public func update(_ context: PresetSessionContext, reason: String) throws -> PresetSessionSnapshot {
        try lock.withLock {
            guard storedSnapshot.phase.isEnabled else { return storedSnapshot }
            guard storedSnapshot.presetKind == context.presetKind else {
                try releaseReceipt()
                storedSnapshot = PresetSessionSnapshot(
                    presetKind: context.presetKind,
                    phase: .stopped,
                    activeLeaseKinds: [],
                    exitReason: .none,
                    didObserveTarget: false
                )
                return try reconcile(context, reason: reason)
            }
            return try reconcile(context, reason: reason)
        }
    }

    @discardableResult
    public func stop(
        reason: PresetSessionExitReason = .userStopped
    ) throws -> PresetSessionSnapshot {
        try lock.withLock {
            try releaseReceipt()
            storedSnapshot = PresetSessionSnapshot(
                presetKind: storedSnapshot.presetKind,
                phase: reason == .userStopped ? .stopped : .completed,
                activeLeaseKinds: [],
                exitReason: reason,
                didObserveTarget: storedSnapshot.didObserveTarget
            )
            return storedSnapshot
        }
    }

    private func reconcile(
        _ context: PresetSessionContext,
        reason: String
    ) throws -> PresetSessionSnapshot {
        let triggerSatisfied: Bool
        let didObserveTarget: Bool

        switch context.presetKind {
        case .taskGuard where context.hasConfiguredTargets:
            triggerSatisfied = context.matchedTargetCount > 0
            didObserveTarget = storedSnapshot.didObserveTarget || triggerSatisfied
            if !triggerSatisfied, didObserveTarget {
                try releaseReceipt()
                storedSnapshot = PresetSessionSnapshot(
                    presetKind: context.presetKind,
                    phase: .completed,
                    activeLeaseKinds: [],
                    exitReason: .targetsFinished,
                    didObserveTarget: true
                )
                return storedSnapshot
            }
        case .taskGuard, .alwaysReachable, .keepDisplayAwake:
            triggerSatisfied = true
            didObserveTarget = storedSnapshot.didObserveTarget
        }

        guard triggerSatisfied else {
            try releaseReceipt()
            storedSnapshot = PresetSessionSnapshot(
                presetKind: context.presetKind,
                phase: .waitingForTarget,
                activeLeaseKinds: [],
                exitReason: .none,
                didObserveTarget: didObserveTarget
            )
            return storedSnapshot
        }

        guard !context.safetySuspended, !context.leaseKinds.isEmpty else {
            try releaseReceipt()
            storedSnapshot = PresetSessionSnapshot(
                presetKind: context.presetKind,
                phase: .suspendedForSafety,
                activeLeaseKinds: [],
                exitReason: .none,
                didObserveTarget: didObserveTarget
            )
            return storedSnapshot
        }

        try synchronizeReceipt(kinds: context.leaseKinds, reason: reason)
        storedSnapshot = PresetSessionSnapshot(
            presetKind: context.presetKind,
            phase: .active,
            activeLeaseKinds: context.leaseKinds,
            exitReason: .none,
            didObserveTarget: didObserveTarget
        )
        return storedSnapshot
    }

    private func synchronizeReceipt(
        kinds: Set<PowerAssertionKind>,
        reason: String
    ) throws {
        guard receipt?.kinds != kinds else { return }
        let replacement = try wakeLeaseEngine.acquire(kinds: kinds, reason: reason)
        let previous = receipt
        receipt = replacement
        do {
            try previous?.release()
        } catch {
            try? replacement.release()
            receipt = nil
            throw error
        }
    }

    private func releaseReceipt() throws {
        let previous = receipt
        receipt = nil
        try previous?.release()
    }

    deinit {
        try? receipt?.release()
    }
}
