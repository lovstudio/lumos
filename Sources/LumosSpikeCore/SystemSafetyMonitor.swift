import CoreFoundation
import Foundation
import IOKit.ps
import Network

public enum SystemSafetyObservationReason: String, Codable, Equatable, Sendable {
    case initial
    case manual
    case lowPowerMode
    case thermalState
    case powerSource
    case networkPath
}

public struct SystemSafetySnapshot: Codable, Equatable, Sendable {
    public let systemState: SystemStateSnapshot
    public let powerSource: PowerSourceSnapshot
    public let networkPath: NetworkPathSnapshot?
    public let observedAt: Date

    public init(
        systemState: SystemStateSnapshot,
        powerSource: PowerSourceSnapshot,
        networkPath: NetworkPathSnapshot?,
        observedAt: Date
    ) {
        self.systemState = systemState
        self.powerSource = powerSource
        self.networkPath = networkPath
        self.observedAt = observedAt
    }
}

public struct SystemSafetyEvent: Equatable, Sendable {
    public let reason: SystemSafetyObservationReason
    public let snapshot: SystemSafetySnapshot

    public init(reason: SystemSafetyObservationReason, snapshot: SystemSafetySnapshot) {
        self.reason = reason
        self.snapshot = snapshot
    }
}

public enum SystemSafetySeverity: String, Codable, Equatable, Sendable {
    case normal
    case efficient
    case degraded
    case critical
}

public enum SystemSafetyCondition: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case lowPowerMode
    case thermalFair
    case thermalSerious
    case thermalCritical
    case thermalUnknown
    case batteryAtOrBelowFloor
    case batteryLevelUnknown
    case powerSourceUnknown
    case networkUnknown
    case networkUnavailable
    case networkConstrained
    case networkExpensive
}

public struct SystemSafetyDecision: Codable, Equatable, Sendable {
    public let severity: SystemSafetySeverity
    public let conditions: [SystemSafetyCondition]
    public let refreshInterval: TimeInterval
    public let shouldReleaseDisplayLease: Bool
    public let shouldReleaseSystemLease: Bool
    public let shouldEndClamshellProtection: Bool
    public let detail: String

    public init(
        severity: SystemSafetySeverity,
        conditions: [SystemSafetyCondition],
        refreshInterval: TimeInterval,
        shouldReleaseDisplayLease: Bool,
        shouldReleaseSystemLease: Bool,
        shouldEndClamshellProtection: Bool,
        detail: String
    ) {
        self.severity = severity
        self.conditions = conditions
        self.refreshInterval = refreshInterval
        self.shouldReleaseDisplayLease = shouldReleaseDisplayLease
        self.shouldReleaseSystemLease = shouldReleaseSystemLease
        self.shouldEndClamshellProtection = shouldEndClamshellProtection
        self.detail = detail
    }
}

public struct SystemSafetyTransition: Equatable, Sendable {
    public let previous: SystemSafetyDecision?
    public let current: SystemSafetyDecision

    public var didChange: Bool {
        previous != current
    }
}

public enum SystemSafetyPolicy {
    public static func evaluate(
        _ snapshot: SystemSafetySnapshot,
        batteryFloorPercent: Int
    ) -> SystemSafetyDecision {
        var conditions = Set<SystemSafetyCondition>()

        if snapshot.systemState.lowPowerModeEnabled {
            conditions.insert(.lowPowerMode)
        }
        switch snapshot.systemState.thermalState {
        case .nominal:
            break
        case .fair:
            conditions.insert(.thermalFair)
        case .serious:
            conditions.insert(.thermalSerious)
        case .critical:
            conditions.insert(.thermalCritical)
        case .unknown:
            conditions.insert(.thermalUnknown)
        }

        if !snapshot.powerSource.isAvailable {
            conditions.insert(.powerSourceUnknown)
        }
        if snapshot.powerSource.kind == .battery,
           let batteryLevel = snapshot.powerSource.batteryLevelPercent,
           batteryLevel <= min(max(batteryFloorPercent, 1), 100) {
            conditions.insert(.batteryAtOrBelowFloor)
        }
        if snapshot.powerSource.kind == .battery,
           snapshot.powerSource.batteryLevelPercent == nil {
            conditions.insert(.batteryLevelUnknown)
        }

        if let network = snapshot.networkPath {
            if network.status != .satisfied {
                conditions.insert(.networkUnavailable)
            }
            if network.isConstrained {
                conditions.insert(.networkConstrained)
            }
            if network.isExpensive {
                conditions.insert(.networkExpensive)
            }
        } else {
            conditions.insert(.networkUnknown)
        }

        let severity: SystemSafetySeverity
        if conditions.contains(.thermalCritical) {
            severity = .critical
        } else if !conditions.isDisjoint(with: [
            .thermalSerious,
            .thermalUnknown,
            .batteryAtOrBelowFloor,
            .batteryLevelUnknown,
            .powerSourceUnknown,
            .networkUnavailable,
        ]) {
            severity = .degraded
        } else if !conditions.isEmpty {
            severity = .efficient
        } else {
            severity = .normal
        }

        let shouldReleaseDisplayLease = !conditions.isDisjoint(with: [
            .thermalSerious,
            .thermalCritical,
            .thermalUnknown,
            .batteryAtOrBelowFloor,
            .batteryLevelUnknown,
        ])
        let shouldReleaseSystemLease = conditions.contains(.thermalCritical)
        let shouldEndClamshellProtection = !conditions.isDisjoint(with: [
            .thermalSerious,
            .thermalCritical,
            .thermalUnknown,
            .batteryAtOrBelowFloor,
            .batteryLevelUnknown,
            .powerSourceUnknown,
        ])

        let refreshInterval: TimeInterval = switch severity {
        case .normal: 5
        case .efficient: 15
        case .degraded: 30
        case .critical: 60
        }

        return SystemSafetyDecision(
            severity: severity,
            conditions: conditions.sorted { $0.rawValue < $1.rawValue },
            refreshInterval: refreshInterval,
            shouldReleaseDisplayLease: shouldReleaseDisplayLease,
            shouldReleaseSystemLease: shouldReleaseSystemLease,
            shouldEndClamshellProtection: shouldEndClamshellProtection,
            detail: detail(for: severity, conditions: conditions)
        )
    }

    private static func detail(
        for severity: SystemSafetySeverity,
        conditions: Set<SystemSafetyCondition>
    ) -> String {
        if conditions.contains(.thermalCritical) {
            return "温度过高，已把休眠决定交还 macOS"
        }
        if conditions.contains(.thermalSerious) {
            return "温度较高，已撤销亮屏与合盖保护"
        }
        if conditions.contains(.batteryAtOrBelowFloor) {
            return "电量已到安全线，已撤销亮屏与合盖保护"
        }
        if conditions.contains(.batteryLevelUnknown) {
            return "电池电量不可读取，已停止实验性合盖保护"
        }
        if conditions.contains(.thermalUnknown) {
            return "温度状态不可读取，未启用高风险保护"
        }
        if conditions.contains(.networkUnavailable) {
            return "当前网络不可达，任务守护仍按本地状态运行"
        }
        if conditions.contains(.powerSourceUnknown) {
            return "电源状态不可读取，未推断电池安全状态"
        }
        if conditions.contains(.thermalFair) {
            return "温度略高，Lumos 已降低采样频率"
        }
        if conditions.contains(.lowPowerMode) {
            return "低功耗模式开启，Lumos 已降低采样频率"
        }
        if conditions.contains(.networkConstrained) || conditions.contains(.networkExpensive) {
            return "网络受限，Lumos 已减少非必要活动"
        }
        if conditions.contains(.networkUnknown) {
            return "正在确认网络状态"
        }
        return severity == .normal ? "电量、温度与网络状态正常" : "Lumos 已降低后台活动"
    }
}

public final class SystemSafetyStateMachine: @unchecked Sendable {
    private let lock = NSLock()
    private var previous: SystemSafetyDecision?

    public init() {}

    public func ingest(
        _ snapshot: SystemSafetySnapshot,
        batteryFloorPercent: Int
    ) -> SystemSafetyTransition {
        lock.withLock {
            let current = SystemSafetyPolicy.evaluate(
                snapshot,
                batteryFloorPercent: batteryFloorPercent
            )
            defer { previous = current }
            return SystemSafetyTransition(previous: previous, current: current)
        }
    }

    public func reset() {
        lock.withLock { previous = nil }
    }
}

public struct SystemSafetyMonitorSources: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let processInfo = SystemSafetyMonitorSources(rawValue: 1 << 0)
    public static let powerSource = SystemSafetyMonitorSources(rawValue: 1 << 1)
    public static let network = SystemSafetyMonitorSources(rawValue: 1 << 2)
    public static let all: SystemSafetyMonitorSources = [.processInfo, .powerSource, .network]
}

public final class SystemSafetyMonitor: @unchecked Sendable {
    public typealias SystemStateReader = @Sendable () -> SystemStateSnapshot
    public typealias PowerSourceReader = @Sendable () -> PowerSourceSnapshot
    public typealias Clock = @Sendable () -> Date
    public typealias EventHandler = @Sendable (SystemSafetyEvent) -> Void

    private let lock = NSLock()
    private let systemStateReader: SystemStateReader
    private let powerSourceReader: PowerSourceReader
    private let clock: Clock
    private let notificationCenter: NotificationCenter
    private let sources: SystemSafetyMonitorSources
    private let networkQueue = DispatchQueue(label: "ai.lovstudio.lumos.safety.network")
    private var networkMonitor: NWPathMonitor?
    private var latestNetworkPath: NetworkPathSnapshot?
    private var handler: EventHandler?
    private var notificationTokens: [NSObjectProtocol] = []
    private var powerSourceRunLoopSource: CFRunLoopSource?
    private var isStarted = false

    public convenience init() {
        self.init(
            systemStateReader: { SystemStateProbe.snapshot() },
            powerSourceReader: PowerSourceProbe.snapshot,
            clock: Date.init,
            notificationCenter: .default,
            sources: .all
        )
    }

    public init(
        systemStateReader: @escaping SystemStateReader,
        powerSourceReader: @escaping PowerSourceReader,
        clock: @escaping Clock = Date.init,
        notificationCenter: NotificationCenter = .default,
        sources: SystemSafetyMonitorSources = .all
    ) {
        self.systemStateReader = systemStateReader
        self.powerSourceReader = powerSourceReader
        self.clock = clock
        self.notificationCenter = notificationCenter
        self.sources = sources
    }

    public func start(handler: @escaping EventHandler) {
        let shouldStart = lock.withLock {
            self.handler = handler
            guard !isStarted else { return false }
            isStarted = true
            return true
        }
        guard shouldStart else {
            refresh(reason: .manual)
            return
        }

        if sources.contains(.processInfo) {
            notificationTokens = [
                notificationCenter.addObserver(
                    forName: Notification.Name.NSProcessInfoPowerStateDidChange,
                    object: nil,
                    queue: nil
                ) { [weak self] _ in
                    self?.refresh(reason: .lowPowerMode)
                },
                notificationCenter.addObserver(
                    forName: ProcessInfo.thermalStateDidChangeNotification,
                    object: nil,
                    queue: nil
                ) { [weak self] _ in
                    self?.refresh(reason: .thermalState)
                },
            ]
        }

        if sources.contains(.network) {
            let networkMonitor = NWPathMonitor()
            self.networkMonitor = networkMonitor
            networkMonitor.pathUpdateHandler = { [weak self] path in
                guard let self else { return }
                lock.withLock {
                    latestNetworkPath = NetworkProbe.snapshot(path)
                }
                refresh(reason: .networkPath)
            }
            networkMonitor.start(queue: networkQueue)
        }

        if sources.contains(.powerSource) {
            let context = Unmanaged.passUnretained(self).toOpaque()
            if let sourceReference = IOPSNotificationCreateRunLoopSource(
                systemSafetyPowerSourceDidChange,
                context
            ) {
                let source = sourceReference.takeRetainedValue()
                powerSourceRunLoopSource = source
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            }
        }

        refresh(reason: .initial)
    }

    public func refresh(reason: SystemSafetyObservationReason = .manual) {
        let networkPath = lock.withLock { latestNetworkPath }
        let snapshot = SystemSafetySnapshot(
            systemState: systemStateReader(),
            powerSource: powerSourceReader(),
            networkPath: networkPath,
            observedAt: clock()
        )
        let currentHandler = lock.withLock { handler }
        currentHandler?(SystemSafetyEvent(reason: reason, snapshot: snapshot))
    }

    public func stop() {
        let shouldStop = lock.withLock {
            guard isStarted else { return false }
            isStarted = false
            handler = nil
            return true
        }
        guard shouldStop else { return }

        notificationTokens.forEach(notificationCenter.removeObserver)
        notificationTokens.removeAll()
        if sources.contains(.network) {
            networkMonitor?.cancel()
            networkMonitor = nil
        }
        if let powerSourceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSourceRunLoopSource, .commonModes)
            self.powerSourceRunLoopSource = nil
        }
    }

    deinit {
        stop()
    }
}

private func systemSafetyPowerSourceDidChange(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let monitor = Unmanaged<SystemSafetyMonitor>.fromOpaque(context).takeUnretainedValue()
    monitor.refresh(reason: .powerSource)
}
